#!/usr/bin/env bash
# tests/todo-shim-mutants.sh — every rule of the todo shim and the assignment
# notifier (ADR 1791532020; design note 2026-10-13) must be load-bearing in its
# suite.
#
# Copies the tree, applies ONE mutation, runs the suite that owns the rule, and
# requires it to FAIL. The unmutated copy must pass all three suites first (an
# always-red suite "catches" every mutant), and each mutation must match exactly
# once (a no-op mutant would read as killed if the suite were red for another
# reason).
#
# Needs AUTOCORE_TEST_AUTODOC and AUTOCORE_TEST_AUTODOC_BIN (tests/todo-daemon.sh).
# Run on VM43: bash tests/todo-shim-mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
: "${AUTOCORE_TEST_AUTODOC:?}" "${AUTOCORE_TEST_AUTODOC_BIN:?}"
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# run_suite <dir> <shim|notifier|required>
run_suite() {
  if [ "$2" = required ]; then
    (cd "$1" && timeout 120 nvim --headless -u NONE -l tests/todo-shim-required.lua 2>&1)
  else
    (cd "$1" && bash tests/todo-daemon.sh "$2" 2>&1)
  fi
}
summary_of() { printf '%s\n' "$1" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1; }

cp -r "$SRC" "$WORK/base"
for s in required shim notifier; do
  out="$(run_suite "$WORK/base" "$s")"
  summary="$(summary_of "$out")"
  if [ -z "$summary" ] || [ "${summary##*, }" != "0 failed" ]; then
    echo "BASELINE NOT GREEN ($s): ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
  fi
  echo "baseline $s: $summary"
done

I=lua/auto-core/todo/init.lua
W=lua/auto-core/todo/where.lua
N=lua/auto-core/todo/notifier.lua
D=lua/auto-core/todo/daemon.lua
# file|suite|name|old|new — literal strings; old must occur exactly once in file.
mutants=(
  "$W|shim|the first call does not claim|      claim(at, root, r.store_id, r.store)\n      c.claimed = true|      c.claimed = false"
  "$W|shim|the claim drops legacy_workspace|{ at, { legacy_workspace = legacy } }|{ at }"
  "$W|shim|{root} even when a workspace owns the store|      at = ws.name|      at = nil"
  "$W|shim|a released store is claimed again|    if mine then|    if false then"
  "$I|shim|refs cross as the caller wrote them|  absolute_refs(s)\n|  -- absolute_refs(s)\n"
  "$I|shim|a stale write is retried|    local task, err = daemon.rpc(\"todos.update\", { ctx.at, id, cur.rev, p })|    local task, err = daemon.rpc(\"todos.update\", { ctx.at, id, cur.rev, p })\n    if err and err.code == daemon.STALE then\n      cur = get_task(ctx, id)\n      task, err = daemon.rpc(\"todos.update\", { ctx.at, id, cur.rev, p })\n    end"
  "$I|shim|assignee:changed is published again|  publish(\"core.todo:changed\", { kind = \"assign\", id = id })|  publish(\"core.todo:changed\", { kind = \"assign\", id = id })\n  publish(\"core.todo.assignee:changed\", { id = id, to = assignee })"
  "$I|shim|update forwards assignee|  if patch.assignee ~= nil then|  if false then"
  "$I|shim|set_todo_dir publishes core.todo:changed|  op(function() return true end) -- resolve (and claim) the new store now|  op(function() return true end) -- resolve (and claim) the new store now\n  publish(\"core.todo:changed\", { kind = \"set_dir\" })"
  "$I|shim|a store not created yet lists as an error|  if err and err.code == daemon.NOT_A_STORE then return {} end|  if false then return {} end"
  "$W|required|the AutoDoc-required notice repeats|  if _warned[key] then return end|  if false then return end"
  "$D|required|a fast event waits|  if vim.in_fast_event() then|  if false then"
  "$N|notifier|a failed send is acked past|            stopped = true\n            break|            stopped = false"
  "$N|notifier|past the window a recipient is still held|  return \"skip\"\nend\n\nlocal function ack|  return \"hold\"\nend\n\nlocal function ack"
  "$N|notifier|a new consumer replays the retained log|  if floor == nil then floor = M.watermark(store.id) end|  if floor == nil then floor = 0 end"
  "$N|notifier|a resync notifies nobody|        elseif verdict == \"deliver\" and send(at, store, rec, mid, { id = row.id,|        elseif false and send(at, store, rec, mid, { id = row.id,"
  "$N|notifier|the timer keeps running while disconnected|local function on_disconnected()\n  stop_timer(_timer); _timer = nil|local function on_disconnected()"
  "$N|notifier|an unregistered recipient is not held|  if _started_at and now_ms() - _started_at < grace then return \"hold\" end|  if false then return \"hold\" end"
  "$N|notifier|no poll when a mailbox registers|        vim.schedule(function() if _running then M.poll_all() end end)|        vim.schedule(function() end)"
  "$N|notifier|the watermark passes a held change|      if handled and not held then acked = seq end|      acked = seq"
  "$N|notifier|the ack passes a held change|    if acked then\n      if ack(at, acked) then bump_watermark(store.id, acked) end|    if acked then\n      ack(at, changes[#changes] and changes[#changes].seq or acked)\n      if true then bump_watermark(store.id, acked) end"
  "$N|notifier|the held change's re-read is written twice|  if delivered(rec, mid) then return \"done\" end|  if false then return \"done\" end"
)

killed=0; survived=0; broken=0; i=0
for m in "${mutants[@]}"; do
  file="${m%%|*}"; rest="${m#*|}"
  suite="${rest%%|*}"; rest="${rest#*|}"
  name="${rest%%|*}"; rest="${rest#*|}"
  old="${rest%%|*}"; new="${rest#*|}"
  i=$((i + 1)); dir="$WORK/m$i"
  cp -r "$SRC" "$dir"
  if ! python3 - "$dir/$file" "$old" "$new" <<'PY'
import sys
p = sys.argv[1]
old = sys.argv[2].replace("\\n", "\n")
new = sys.argv[3].replace("\\n", "\n")
s = open(p).read()
n = s.count(old)
if n != 1:
    print(f"    mutation matched {n} times"); sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  then
    echo "NOT APPLIED  $name"; broken=$((broken + 1)); continue
  fi
  out="$(run_suite "$dir" "$suite")"
  summary="$(summary_of "$out")"
  if [ -n "$summary" ] && [ "${summary##*, }" = "0 failed" ]; then
    echo "SURVIVED     $name ($suite)"; survived=$((survived + 1))
  else
    echo "KILLED       $name ($suite: ${summary:-aborted})"
    printf '%s\n' "$out" | grep -E 'FAIL' | head -3 | sed 's/^/               /'
    killed=$((killed + 1))
  fi
  rm -rf "$dir"
done
echo "mutants: $killed killed, $survived survived, $broken not applied"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
