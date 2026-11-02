#!/usr/bin/env bash
# tests/todo-daemon-stop.sh — todo-daemon.sh stops the daemons its suites start,
# whatever path the binary was given by. A daemon runs under its binary's resolved
# path, so a checkout reached through a symlink (a gate's linked AutoDoc build) once
# named no daemon to the runner's stop, and every suite's daemon outlived the run.
#
#   AUTOCORE_TEST_AUTODOC=/path/to/autodoc   AUTOCORE_TEST_AUTODOC_BIN=/path/to/binary
#   tests/todo-daemon-stop.sh
#
# It runs the `where` suite with the binary named through a symlinked folder, then
# looks for any daemon still running from that run's sandboxes; it stops those it
# finds, so a failure leaves nothing behind either.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

: "${AUTOCORE_TEST_AUTODOC:?set AUTOCORE_TEST_AUTODOC to an autodoc checkout}"
: "${AUTOCORE_TEST_AUTODOC_BIN:?set AUTOCORE_TEST_AUTODOC_BIN to an autodoc binary}"

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1  ${2:-}"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/auto-core-daemon-stop.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
ln -s "$(cd "$(dirname "$AUTOCORE_TEST_AUTODOC_BIN")" && pwd)" "$work/linked-bin"
linked="$work/linked-bin/$(basename "$AUTOCORE_TEST_AUTODOC_BIN")"

# the run's daemons are those of a todo-daemon.sh sandbox (its mktemp, under the same TMPDIR) that
# weren't running before it: nothing else is looked at or stopped. The run removes its sandboxes as
# it ends, so the daemons are told by their config's path, not by a folder left behind. Its TMPDIR
# is left as it is: a deeper one would put the daemon's socket past its path limit.
tmp="${TMPDIR:-/tmp}"
todo_daemons() {
  local p
  for p in $(pgrep -f -- '--serve --config' 2>/dev/null); do
    case "$(ps -o command= -p "$p" 2>/dev/null)" in
      *" --serve --config $tmp/auto-core-todo."*) echo "$p" ;;
    esac
  done | sort
}
before="$(todo_daemons)"
AUTOCORE_TEST_AUTODOC_BIN="$linked" bash tests/todo-daemon.sh where > "$work/run.txt" 2>&1
rc=$?
grep -qE "todo where \(real daemon\): [0-9]+ passed, 0 failed" "$work/run.txt" \
  && ok "the where suite ran, with the binary named through a symlink" \
  || bad "the where suite ran, with the binary named through a symlink" "rc=$rc: $(tail -3 "$work/run.txt" | tr '\n' ' ')"

sleep 1
left="$(comm -13 <(echo "$before") <(todo_daemons) | tr '\n' ' ')"
left="${left% }"
if [ -z "$left" ]; then
  ok "*** no daemon of the run's sandboxes outlives it ***"
else
  bad "*** no daemon of the run's sandboxes outlives it ***" "still running: $left"
  kill -KILL $left 2>/dev/null
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
