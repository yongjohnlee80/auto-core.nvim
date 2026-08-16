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
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
root="$PWD"
status=0

for test_file in tests/ui/*.lua; do
  name="$(basename "$test_file" .lua)"
  if [ $# -gt 0 ] && [ "$name" != "$1" ]; then continue; fi

  out="$root/tests/ui/.${name}.out"
  rm -f "$out"
  script -qec "nvim --clean -u $test_file" /dev/null >/dev/null 2>&1
  rc=$?

  if [ -f "$out" ]; then
    cat "$out"
  else
    echo "[ui] $name — NO OUTPUT (nvim exited $rc before writing results)"
    rc=1
  fi
  [ $rc -ne 0 ] && status=1
done

exit $status
