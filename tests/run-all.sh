#!/usr/bin/env bash
# tests/run-all.sh — the single entry point that runs every auto-core
# test suite and turns a silent abort into a loud failure.
#
#   tests/run-all.sh              # smoke + pty + bench
#   AC_SKIP_PTY=1 tests/run-all.sh  # skip the UI-attached suite (no pty)
#
# Why this exists (2026-08-23 runner-hardening):
#
#   1. smoke.lua is the per-iteration gate, but on its own an abort
#      mid-run is easy to miss: read the exit code alone and a crash
#      before the summary looks the same as success under the wrong
#      invocation. This runner parses the `<P> passed, <F> failed`
#      line and treats its ABSENCE — or a non-zero exit with zero
#      counted failures — as a hard failure. That is the
#      summary-presence / crash-before-assertions guard the family
#      runner-contract calls for. auto-core is the foundation every
#      sibling depends on, so a silent abort here is the most
#      expensive one in the family.
#
#   2. tests/ui/*.lua (pty, UI-attached) landed 2026-08-17 and was
#      never wired into any routine gate — only tests/smoke.lua was
#      ever mentioned as the per-iteration check. It is run here now.
#
#   3. tests/bench/frame_scaling.lua was an orphan (globbed by
#      nothing). Its TIMING ratios are machine-dependent and stay
#      informational, but it also carries one real invariant — the
#      retained-bytes bound and a heap positive-control — which this
#      runner promotes to a pass/fail gate (fail on VIOLATED or a
#      blind instrument).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

overall=0

# ── SELF-STAGE GUARD (KB todo 2026-09-02) ──────────────────────────
# No suite may touch THIS worktree's git state. A suite that runs a git
# WRITE (`git add`, commit, …) against the process cwd instead of a
# fixture stages the plugin's own files — and a later bare `git commit`
# then writes them into a release. That bit the family once (a PRs/ body
# into a tagged auto-finder release); auto-finder v0.4.26 added this same
# gate. auto-core is the foundation every sibling depends on, so it earns
# the guard even though no suite currently trips it: this keeps it that way.
#
# The snapshot is COMPOSITE, not porcelain alone, because porcelain is blind to
# three mutations a rogue suite can make and still leave porcelain unchanged
# (the first two proven with a temp-repo probe, lector PR #45 MF1; the third is
# lector's PR #45 non-blocking note, folded here):
#   • a stage-PLUS-commit against the plugin worktree — the working tree ends
#     clean, so porcelain is unchanged, but the HEAD commit moved;
#   • re-staging DIFFERENT content for an already-staged path — the status
#     glyph (`M `/`A `) is unchanged, but the staged blob changed;
#   • switching the checked-out BRANCH to another ref at the same commit — the
#     commit and tree are identical, but the symbolic HEAD ref changed.
# So it fingerprints the HEAD commit + the symbolic branch + porcelain status +
# the staged blob set, all of which are read-only.
#
# A before/after INVARIANT, not a clean-tree check — a dev on a dirty branch
# is fine as long as the run leaves that state untouched. Skipped when this is
# not a git checkout (a CI tarball) so the runner stays usable.
git_state_snapshot() {
  echo "# HEAD";   git rev-parse --verify -q HEAD 2>/dev/null    || echo "(none)"
  echo "# BRANCH"; git symbolic-ref -q HEAD 2>/dev/null          || echo "(detached)"
  echo "# STATUS"; git status --porcelain 2>/dev/null
  echo "# INDEX";  git ls-files -s 2>/dev/null
}
GIT_GUARD_ACTIVE=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_GUARD_ACTIVE=1
  GIT_STATE_BEFORE="$(git_state_snapshot)"
fi

run_smoke() {
  echo "── smoke ─────────────────────────────────────"
  local out rc summary fail_n
  out="$(nvim --headless -u NONE -l tests/smoke.lua 2>&1)"
  rc=$?
  # The `<P> passed, <F> failed` summary is the AUTHORITATIVE result: its
  # counters are bumped inside ok() regardless of how stdout interleaves.
  # (In the async sections a PASS/FAIL line can be concatenated onto a
  # header line, so grepping `^  FAIL` alone can undercount.) Gate on the
  # counter; use grep only to SHOW which assertions failed.
  summary="$(printf '%s\n' "$out" | grep -oE "[0-9]+ passed, [0-9]+ failed" | tail -1 || true)"
  printf '%s\n' "$out" | grep -E "^  FAIL" | head -20

  # Summary-presence: its absence means execution aborted before the
  # summary — a silent, partial run masquerading as green.
  if [ -z "$summary" ]; then
    echo "   ✗ smoke: NO SUMMARY LINE — the suite aborted mid-run (silent abort)"
    echo "     ── tail of output ──"
    printf '%s\n' "$out" | tail -20 | sed 's/^/     /'
    overall=1
    return
  fi
  echo "   smoke: $summary (exit=$rc)"

  fail_n="${summary##* passed, }"
  fail_n="${fail_n% failed}"
  if [ "$fail_n" -gt 0 ]; then
    echo "   ✗ smoke: $fail_n assertion(s) failed"
    overall=1
    return
  fi
  # A clean summary but a non-zero exit means the process aborted AFTER
  # printing it (e.g. a crash in teardown) — not a pass.
  if [ "$rc" -ne 0 ]; then
    echo "   ✗ smoke: exit=$rc despite '$summary' — crashed after the summary"
    overall=1
    return
  fi
  echo "   ✓ smoke OK"
}

run_pty() {
  echo "── pty (UI-attached) ─────────────────────────"
  if [ "${AC_SKIP_PTY:-0}" = "1" ]; then
    echo "   ⚠ pty suite skipped (AC_SKIP_PTY=1)"
    return
  fi
  if ! command -v script >/dev/null 2>&1; then
    echo "   ⚠ pty suite skipped: 'script' (util-linux / bsdutils) not on PATH"
    return
  fi
  # run.sh has its own timeout watchdog + pass/fail accounting.
  bash tests/ui/run.sh
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "   ✗ pty: tests/ui/run.sh exited $rc"
    overall=1
  else
    echo "   ✓ pty OK"
  fi
}

run_bench() {
  echo "── bench: rpc.frame scaling ──────────────────"
  local out rc
  out="$(nvim --headless --clean -u tests/bench/frame_scaling.lua 2>&1)"
  rc=$?
  printf '%s\n' "$out" | sed 's/^/   /'
  if [ "$rc" -ne 0 ]; then
    echo "   ✗ bench: nvim exited $rc"
    overall=1
    return
  fi
  if printf '%s\n' "$out" | grep -q "VIOLATED"; then
    echo "   ✗ bench: retained-bytes bound VIOLATED — a real regression"
    overall=1
    return
  fi
  if printf '%s\n' "$out" | grep -q "instrument cannot observe"; then
    echo "   ✗ bench: heap instrument blind — the null result proves nothing"
    overall=1
    return
  fi
  echo "   ✓ bench OK (timing ratios above are informational; machine-dependent)"
}

run_standalone() {
  # A focused headless suite that prints the same `<P> passed, <F> failed`
  # summary as smoke, guarded the same way: a missing summary is an abort.
  local name="$1" file="$2"
  echo "── $name ─────────────────────────────────────"
  local out rc summary fail_n
  out="$(nvim --headless -u NONE -l "$file" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | grep -E "^  (PASS|FAIL)" | sed 's/^/   /'
  summary="$(printf '%s\n' "$out" | grep -oE "[0-9]+ passed, [0-9]+ failed" | tail -1 || true)"
  if [ -z "$summary" ]; then
    echo "   ✗ $name: NO SUMMARY LINE — the suite aborted mid-run (silent abort)"
    overall=1; return
  fi
  echo "   $name: $summary (exit=$rc)"
  fail_n="${summary##* passed, }"; fail_n="${fail_n%% failed}"
  if [ "$fail_n" -ne 0 ]; then echo "   ✗ $name: $fail_n failed"; overall=1
  elif [ "$rc" -ne 0 ]; then echo "   ✗ $name: exit=$rc despite '$summary'"; overall=1
  else echo "   ✓ $name OK"; fi
}

run_smoke
run_standalone "diff-align (r1 MF4)" tests/adr0060-r1-diff-align.lua
run_standalone "grid selection + viewer (ADR-0066)" tests/grid_selection.lua
run_standalone "git write (ADR-0060)" tests/git_write.lua
# ADR-0065 P0 — the multi-float close contract. Registered here rather than
# left to a glob because this runner names its suites explicitly: an
# unregistered file under tests/ is simply never run.
run_standalone "close-contract (ADR-0065 P0)" tests/adr0065-p0-close-contract.lua
run_standalone "annotate surface (ADR-0065 P1)" tests/adr0065-p1-annotate.lua
run_standalone "highlighting (ADR-0065 P2)" tests/adr0065-p2-highlight.lua
run_standalone "docstore + drafts (ADR-0081 P1-P3)" tests/adr0081-docstore.lua
run_standalone "git.worktree identity (ADR-0081 §2.5)" tests/git-worktree-id.lua
run_standalone "diffview-nav (ADR-0083 Phase 2)" tests/adr0083-diffview-nav.lua
run_standalone "diffview-keys (f/F/T, every pane, real dispatch)" tests/adr0083-diffview-keys.lua
run_standalone "review draft domain (auto-core.review.draft)" tests/review-draft.lua
run_standalone "float offsets + repo_at" tests/float-offset-and-repo-at.lua
run_pty
run_bench

# ── SELF-STAGE GUARD: verdict ──────────────────────────────────────
if [ "$GIT_GUARD_ACTIVE" -eq 1 ]; then
  GIT_STATE_AFTER="$(git_state_snapshot)"
  if [ "$GIT_STATE_BEFORE" != "$GIT_STATE_AFTER" ]; then
    echo "── self-stage guard ──────────────────────────"
    echo "   ✗ a suite changed THIS worktree's git state — a git write"
    echo "     (stage, and/or commit) reached the plugin worktree instead of"
    echo "     a fixture (KB todo 2026-09-02). Before → after (HEAD/STATUS/INDEX):"
    diff <(printf '%s\n' "$GIT_STATE_BEFORE") \
         <(printf '%s\n' "$GIT_STATE_AFTER") | sed 's/^/     /'
    overall=1
  fi
fi

echo "──────────────────────────────────────────────"
if [ "$overall" -eq 0 ]; then
  echo "run-all: OK"
else
  echo "run-all: FAILED"
fi
exit "$overall"
