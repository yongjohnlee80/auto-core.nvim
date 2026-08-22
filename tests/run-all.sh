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

run_smoke
run_pty
run_bench

echo "──────────────────────────────────────────────"
if [ "$overall" -eq 0 ]; then
  echo "run-all: OK"
else
  echo "run-all: FAILED"
fi
exit "$overall"
