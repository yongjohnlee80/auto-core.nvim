#!/usr/bin/env bash
# tests/adr0200-mutants.sh — every guarantee of auto-core.fs.scan must be load-bearing (ADR-0200 §5 cell 5).
#
# Copies the tree, applies ONE mutation to lua/auto-core/fs/scan.lua, runs tests/adr0200-fs-scan.lua, and
# requires it to FAIL. The unmutated copy must pass first: an always-red suite "catches" every mutant.
# Each mutation must match exactly once, or the mutant is reported as not applied (a silent no-op mutant
# would read as "killed" if the suite happened to be red for another reason).
#
# Run on VM43: bash tests/adr0200-mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_suite() { (cd "$1" && timeout 300 nvim --headless -u NONE -l tests/adr0200-fs-scan.lua 2>&1); }

cp -r "$SRC" "$WORK/base"
out="$(run_suite "$WORK/base")"
summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
if [ "$summary" = "" ] || [ "${summary##*, }" != "0 failed" ]; then
  echo "BASELINE NOT GREEN: ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
fi
echo "baseline: $summary"

# name|python expression old|new  (applied to scan.lua; must occur exactly once)
mutants=(
  "single-flight: every request starts its own read|  local slot = _slots[path]\n  if not slot then|  local slot = nil\n  if not slot then"
  "rerun: fresh requests join the running read|  if slot.state == \"reading\" and fresh then|  if false then"
  "interval: never defer|  local wait = last and (M.MIN_INTERVAL_MS - (vim.uv.now() - last)) or 0|  local wait = 0"
  "owner dedupe: waiters stack instead of replacing|    slot.waiters[owner] = cb\n  end|    slot.waiters[{}] = cb\n  end"
  "batch: drain the whole directory in one tick|        for _ = 1, M.BATCH do|        for _ = 1, math.huge do"
  "yield: vim.schedule chain instead of a libuv timer|        local t = vim.uv.new_timer()\n        t:start(0, 0, function()\n          t:close()\n          vim.schedule(drain)\n        end)|        vim.schedule(drain)"
  "cancel: a no-op|  if type(owner) ~= \"table\" then return end|  do return end"
  "stat window: unbounded link resolution|    while outstanding < M.STAT_WINDOW and next_i <= #links do|    while next_i <= #links do"
)

# git.status mutants (applied to lua/auto-core/git/status.lua)
git_mutants=(
  "raw output: text mode rewrites CRLF|  local result = vim.system(argv(root, opts), {}):wait()|  local result = vim.system(argv(root, opts), { text = true }):wait()"
)

killed=0; survived=0; broken=0
for m in "${mutants[@]}"; do
  name="${m%%|*}"; rest="${m#*|}"; old="${rest%%|*}"; new="${rest#*|}"
  dir="$WORK/m$((killed + survived + broken))"
  cp -r "$SRC" "$dir"
  if ! python3 - "$dir/lua/auto-core/fs/scan.lua" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2].encode().decode("unicode_escape"), sys.argv[3].encode().decode("unicode_escape")
s = open(p).read()
n = s.count(old)
if n != 1:
    print(f"    mutation matched {n} times"); sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  then
    echo "NOT APPLIED  $name"; broken=$((broken + 1)); continue
  fi
  out="$(run_suite "$dir")"
  summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  if [ -n "$summary" ] && [ "${summary##*, }" = "0 failed" ]; then
    echo "SURVIVED     $name"; survived=$((survived + 1))
  else
    echo "KILLED       $name  (${summary:-aborted})"
    printf '%s\n' "$out" | grep -E '^  FAIL' | head -4 | sed 's/^/               /'
    killed=$((killed + 1))
  fi
done
for m in "${git_mutants[@]}"; do
  name="${m%%|*}"; rest="${m#*|}"; old="${rest%%|*}"; new="${rest#*|}"
  dir="$WORK/g$((killed + survived + broken))"
  cp -r "$SRC" "$dir"
  if ! python3 - "$dir/lua/auto-core/git/status.lua" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
if n != 1:
    print(f"    mutation matched {n} times"); sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  then
    echo "NOT APPLIED  $name"; broken=$((broken + 1)); continue
  fi
  out="$(run_suite "$dir")"
  summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  if [ -n "$summary" ] && [ "${summary##*, }" = "0 failed" ]; then
    echo "SURVIVED     $name"; survived=$((survived + 1))
  else
    echo "KILLED       $name  (${summary:-aborted})"
    printf '%s\n' "$out" | grep -E '^  FAIL' | head -4 | sed 's/^/               /'
    killed=$((killed + 1))
  fi
done
echo "mutants: $killed killed, $survived survived, $broken not applied"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
