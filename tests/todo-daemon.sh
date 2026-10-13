#!/usr/bin/env bash
# tests/todo-daemon.sh — the suites that run auto-core.todo against a REAL AutoDoc
# daemon (ADR 1791532020): tests/todo-shim.lua and tests/todo-notifier.lua.
#
#   AUTOCORE_TEST_AUTODOC=/path/to/autodoc            a checkout (its lua/ is autodoc.nvim)
#   AUTOCORE_TEST_AUTODOC_BIN=/path/to/autodoc/binary  built from it, protocol >= 20
#   tests/todo-daemon.sh [shim|notifier]
#
# Each suite runs in its own HOME and XDG dirs, and starts its own daemon from
# its own config (socket, state and data under a temp root), so nothing reaches a
# live store. A daemon outlives its nvim (the binary starts it detached): this
# runner stops every daemon of that binary after each suite.
#
# The summary contract is run-all.sh's: a missing "<P> passed, <F> failed" line
# is an abort, a non-zero failed count or exit is a failure.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

: "${AUTOCORE_TEST_AUTODOC:?set AUTOCORE_TEST_AUTODOC to an autodoc checkout}"
: "${AUTOCORE_TEST_AUTODOC_BIN:?set AUTOCORE_TEST_AUTODOC_BIN to an autodoc binary}"
export AUTOCORE_TEST_AUTODOC AUTOCORE_TEST_AUTODOC_BIN

stop_daemons() { pkill -f "^$AUTOCORE_TEST_AUTODOC_BIN --serve" 2>/dev/null || true; }
trap stop_daemons EXIT

overall=0
run_suite() {
  local name="$1" file="$2"
  echo "── $name ─────────────────────────────────────"
  local sandbox out rc summary fail_n
  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/auto-core-todo.XXXXXX")"
  out="$(HOME="$sandbox/home" XDG_CONFIG_HOME="$sandbox/config" XDG_DATA_HOME="$sandbox/data" \
    XDG_STATE_HOME="$sandbox/state" XDG_CACHE_HOME="$sandbox/cache" XDG_RUNTIME_DIR="$sandbox/run" \
    TMPDIR="$sandbox/tmp" LUA_PATH="$PWD/tests/?.lua;;" \
    AUTO_AGENTS_KB_ROOT= AUTO_AGENTS_MAILBOX_ROOT= \
    bash -c 'mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMPDIR" && chmod 700 "$XDG_RUNTIME_DIR" &&
      timeout 600 nvim --headless -u NONE -l "$0"' "$file" 2>&1)"
  rc=$?
  stop_daemons
  printf '%s\n' "$out" | grep -oE "  (PASS|FAIL)  .*" | sed 's/^/   /'
  summary="$(printf '%s\n' "$out" | grep -oE "[0-9]+ passed, [0-9]+ failed" | tail -1 || true)"
  if [ -z "$summary" ]; then
    echo "   ✗ $name: NO SUMMARY LINE — the suite aborted mid-run"
    printf '%s\n' "$out" | tail -30 | sed 's/^/     /'
    overall=1; rm -rf "$sandbox" 2>/dev/null; return
  fi
  echo "   $name: $summary (exit=$rc)"
  fail_n="${summary##* passed, }"; fail_n="${fail_n%% failed}"
  if [ "$fail_n" -ne 0 ]; then echo "   ✗ $name: $fail_n failed"; overall=1
  elif [ "$rc" -ne 0 ]; then echo "   ✗ $name: exit=$rc despite '$summary'"; overall=1
  else echo "   ✓ $name OK"; fi
  rm -rf "$sandbox" 2>/dev/null || true
}

only="${1:-}"
[ -z "$only" ] || [ "$only" = shim ]     && run_suite "todo shim (real daemon)" tests/todo-shim.lua
[ -z "$only" ] || [ "$only" = notifier ] && run_suite "todo notifier (real daemon)" tests/todo-notifier.lua
echo "──────────────────────────────────────────────"
[ "$overall" -eq 0 ] && echo "todo-daemon: OK" || echo "todo-daemon: FAILED"
exit "$overall"
