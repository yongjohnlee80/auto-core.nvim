#!/usr/bin/env bash
# Run the UI-attached tests.
#
# These are separate from tests/smoke.lua because they assert on behaviour
# Neovim only exhibits with a UI attached — WinScrolled, in particular,
# never fires headlessly, because with no UI there is no redraw to trigger
# it. A headless assertion on that path passes while testing nothing.
#
# `script` supplies the pty that makes nvim attach a real UI.
#
#   tests/ui/run.sh            # all UI tests
#   tests/ui/run.sh grid_scroll
#
# Hardening (2026-08-23): every assertion in these suites runs inside a
# `vim.defer_fn` chain, and a throw in a deferred callback does NOT kill
# nvim — it just stops that timer, so a regression HANGS the runner
# forever instead of failing. We wrap each run in a `timeout` watchdog
# and capture the pty transcript so a hang or an early exit produces a
# diagnostic instead of silence.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
root="$PWD"
status=0

# Watchdog: GNU coreutils `timeout` (Linux) or `gtimeout` (macOS via
# `brew install coreutils`). Kept as an unquoted string, not a bash
# array, so it stays safe under `set -u` on macOS's bash 3.2 (an empty
# array expansion is an "unbound variable" error there). SIGTERM at
# 120s, SIGKILL 10s later if nvim ignores the term.
TIMEOUT="timeout -k 10 120"
if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT="gtimeout -k 10 120"
  else
    TIMEOUT=""
    echo "[ui] WARNING: no 'timeout'/'gtimeout' on PATH — pty tests run"
    echo "[ui]          WITHOUT a watchdog; a hung deferred assertion will"
    echo "[ui]          block forever. Install GNU coreutils to guard CI."
  fi
fi

for test_file in tests/ui/*.lua; do
  name="$(basename "$test_file" .lua)"
  if [ $# -gt 0 ] && [ "$name" != "$1" ]; then continue; fi

  out="$root/tests/ui/.${name}.out"
  cap="$root/tests/ui/.${name}.log"
  rm -f "$out" "$cap"

  # `script`'s stdout (the pty transcript = nvim's stdout+stderr) is
  # captured to $cap rather than discarded, so the NO OUTPUT / TIMED OUT
  # paths have something to show. nvim still attaches a UI: the pty comes
  # from `script`, independent of where script's own stdout is pointed.
  # We pass `--cmd "set nomore shortmess+=F cmdheight=2"` so unexpected
  # startup messages (e.g. terminal DSR probes) never block on a hit-enter
  # prompt, and redirect stdin from /dev/null so background/CI runners
  # do not stall or catch SIGTTIN.
  $TIMEOUT script -qec "nvim --clean --cmd 'set nomore shortmess+=F cmdheight=2' -u $test_file" /dev/null </dev/null >"$cap" 2>&1
  rc=$?

  if [ "$rc" -eq 124 ]; then
    echo "[ui] $name — TIMED OUT (watchdog fired; nvim hung or timed out after 120s)"
    [ -s "$cap" ] && { echo "     ── transcript ──"; sed 's/^/     /' "$cap"; }
    status=1
    continue
  fi

  if [ -f "$out" ]; then
    cat "$out"
    # Output written but nvim still exited non-zero → surface the tail.
    if [ "$rc" -ne 0 ]; then
      echo "[ui] $name — nvim exited $rc AFTER writing results:"
      [ -s "$cap" ] && sed 's/^/     /' "$cap"
      status=1
    fi
  else
    echo "[ui] $name — NO OUTPUT (nvim exited $rc before writing results)"
    [ -s "$cap" ] && { echo "     ── transcript ──"; sed 's/^/     /' "$cap"; }
    status=1
  fi
done

exit $status
