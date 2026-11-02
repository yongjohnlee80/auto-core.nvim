#!/usr/bin/env bash
# tests/todo-daemon.sh — the suites that run auto-core's todo surface against a
# REAL AutoDoc daemon (ADR 1791532020): tests/todo-where.lua (the store resolution,
# the claim, buffers, vars and the commands) and tests/todo-notifier.lua.
#
#   AUTOCORE_TEST_AUTODOC=/path/to/autodoc            a checkout (its lua/ is autodoc.nvim)
#   AUTOCORE_TEST_AUTODOC_BIN=/path/to/autodoc/binary  built from it, protocol >= 20
#   tests/todo-daemon.sh [where|notifier]
#
# Each suite runs in its own HOME and XDG dirs, and starts its own daemon from
# its own config (socket, state and data under a temp root), so nothing reaches a
# live store. A daemon outlives its nvim (the binary starts it detached): this
# runner stops each suite's daemons after it, and on its own exit, by the
# suite's sandbox (their --config lies under it), never by the binary's path: a
# daemon runs under its binary's resolved path, so a checkout reached through a
# symlink would name no daemon, and every suite's would outlive the run.
#
# The summary contract is run-all.sh's: a missing "<P> passed, <F> failed" line
# is an abort, a non-zero failed count or exit is a failure.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

: "${AUTOCORE_TEST_AUTODOC:?set AUTOCORE_TEST_AUTODOC to an autodoc checkout}"
: "${AUTOCORE_TEST_AUTODOC_BIN:?set AUTOCORE_TEST_AUTODOC_BIN to an autodoc binary}"
export AUTOCORE_TEST_AUTODOC AUTOCORE_TEST_AUTODOC_BIN

# sandbox_daemons: the pids of the daemons started with a config under sandbox $1.
sandbox_daemons() {
  local p
  for p in $(pgrep -f -- '--serve --config' 2>/dev/null); do
    case "$(ps -o command= -p "$p" 2>/dev/null)" in
      *" --serve --config $1/"*) echo "$p" ;;
    esac
  done
}

# stop_sandbox_daemons: stop sandbox $1's daemons, TERM then KILL, until none is
# left (10 s at most); say which, if any, still runs.
stop_sandbox_daemons() {
  local i pids
  for i in $(seq 1 20); do
    pids="$(sandbox_daemons "$1")"
    [ -z "$pids" ] && return 0
    if [ "$i" -le 10 ]; then kill $pids 2>/dev/null; else kill -KILL $pids 2>/dev/null; fi
    sleep 0.5
  done
  pids="$(sandbox_daemons "$1")"
  [ -z "$pids" ] || echo "   ⚠ $1's daemons still run: $(echo $pids)"
}

sandboxes=()
stop_all() { local s; for s in "${sandboxes[@]}"; do stop_sandbox_daemons "$s"; done; }
trap stop_all EXIT

overall=0
run_suite() {
  local name="$1" file="$2"
  echo "── $name ─────────────────────────────────────"
  local sandbox out rc summary fail_n
  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/auto-core-todo.XXXXXX")"
  sandboxes+=("$sandbox")
  out="$(HOME="$sandbox/home" XDG_CONFIG_HOME="$sandbox/config" XDG_DATA_HOME="$sandbox/data" \
    XDG_STATE_HOME="$sandbox/state" XDG_CACHE_HOME="$sandbox/cache" XDG_RUNTIME_DIR="$sandbox/run" \
    TMPDIR="$sandbox/tmp" LUA_PATH="$PWD/tests/?.lua;;" \
    AUTO_AGENTS_KB_ROOT= AUTO_AGENTS_MAILBOX_ROOT= \
    bash -c 'mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMPDIR" && chmod 700 "$XDG_RUNTIME_DIR" &&
      timeout 600 nvim --headless -u NONE -l "$0"' "$file" 2>&1)"
  rc=$?
  stop_sandbox_daemons "$sandbox"
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
[ -z "$only" ] || [ "$only" = where ]    && run_suite "todo where (real daemon)" tests/todo-where.lua
[ -z "$only" ] || [ "$only" = notifier ] && run_suite "todo notifier (real daemon)" tests/todo-notifier.lua
echo "──────────────────────────────────────────────"
[ "$overall" -eq 0 ] && echo "todo-daemon: OK" || echo "todo-daemon: FAILED"
exit "$overall"
