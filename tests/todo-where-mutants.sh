#!/usr/bin/env bash
# tests/todo-where-mutants.sh — every rule of what auto-core keeps of the todo
# system (the store resolution and claim, the daemon door, the assignment
# notifier; ADR 1791532020 r12) must be load-bearing in its suite.
#
# Copies the tree, applies ONE mutation, runs the suite that owns the rule, and
# requires it to FAIL. The unmutated copy must pass all three suites first (an
# always-red suite "catches" every mutant), and each mutation must match exactly
# once (a no-op mutant would read as killed if the suite were red for another
# reason).
#
# Needs AUTOCORE_TEST_AUTODOC and AUTOCORE_TEST_AUTODOC_BIN (tests/todo-daemon.sh).
# Run on VM43: bash tests/todo-where-mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
: "${AUTOCORE_TEST_AUTODOC:?}" "${AUTOCORE_TEST_AUTODOC_BIN:?}"
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# run_suite <dir> <where|notifier|required|smoke>
run_suite() {
  if [ "$2" = required ]; then
    (cd "$1" && timeout 120 nvim --headless -u NONE -l tests/todo-where-required.lua 2>&1)
  elif [ "$2" = smoke ]; then
    (cd "$1" && timeout 600 nvim --headless -u NONE -l tests/smoke.lua 2>&1)
  else
    (cd "$1" && bash tests/todo-daemon.sh "$2" 2>&1)
  fi
}
summary_of() { printf '%s\n' "$1" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1; }

cp -r "$SRC" "$WORK/base"
for s in required where notifier smoke; do
  out="$(run_suite "$WORK/base" "$s")"
  summary="$(summary_of "$out")"
  if [ -z "$summary" ] || [ "${summary##*, }" != "0 failed" ]; then
    echo "BASELINE NOT GREEN ($s): ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
  fi
  echo "baseline $s: $summary"
done

W=lua/auto-core/todo/where.lua
N=lua/auto-core/todo/notifier.lua
D=lua/auto-core/todo/daemon.lua
V=lua/auto-core/todo/vars.lua
# file|suite|name|old|new — literal strings; old must occur exactly once in file.
mutants=(
  "$W|where|the first call does not claim|      claim(at, root, r.store_id, r.store)\n      c.claimed = true|      c.claimed = false"
  "$W|where|the claim drops legacy_workspace|{ at, { legacy_workspace = legacy } }|{ at }"
  "$W|where|{root} even when a workspace owns the store|      at = ws.name|      at = nil"
  "$W|where|a released store is claimed again|    if mine then|    if false then"
  "$W|where|the explicit claim trusts the cached claim|  M.reset()\n  local c = locate(root)\n  claim(c.at, root, c.store_id, c.store, true)|  local c = M.ensure(root)\n  if c.claimed then return c end\n  claim(c.at, root, c.store_id, c.store, true)"
  "$W|where|an error without a code passes as success|  if err and (tolerate == nil or err.code ~= tolerate) then daemon.fail(err) end|  if err and err.code ~= tolerate then daemon.fail(err) end"
  "$W|where|the explicit claim does not check the daemon's answer|  if not c.claimed then\n    daemon.fail(|  if false then\n    daemon.fail("
  "$D|required|a fast event waits|  if vim.in_fast_event() then|  if false then"
  "$W|where|todos.open sends the session's kb_root again|  local _, oerr = daemon.rpc(\"todos.open\", { at })|  local _, oerr = daemon.rpc(\"todos.open\", { at, { kb_root = vim.fn.getcwd() } })"
  "$V|where|Lua computes \$KB_ROOT itself again|  if row then return row.value end|  if row then\n    if name == \"KB_ROOT\" then return require(\"auto-core.kb\").root() end\n    return row.value\n  end"
  "$V|where|a new name is kept globally, not for this machine|    or \"machine\"\n  return put(name, value, scope)|    or \"global\"\n  return put(name, value, scope)"
  "$V|required|without AutoDoc a variable falls back to vim.env|  local e, why = table_now()\n  if not e then return nil, why end\n  local row = e.by[name]|  local e, why = table_now()\n  if not e then return vim.env[name] end\n  local row = e.by[name]"
  "$V|smoke|an old table is never read again|  if now_ms() - e.read <= M.FRESH_MS then return e end|  if true then return e end"
  "$V|smoke|a set leaves the old table cached|  _cache = {}\n  publish_changed(value == \"\" and \"remove\" or \"set\", name)|  publish_changed(value == \"\" and \"remove\" or \"set\", name)"
  "$V|smoke|symbolize: the tie goes to \$WORKSPACE, not \$KB_ROOT|  for _, n in ipairs({ \"KB_ROOT\", \"WORKSPACE\", \"PROJECT_ROOT\" }) do\n    add(n, e.by[n] and e.by[n].value)\n  end|  for _, n in ipairs({ \"PROJECT_ROOT\", \"WORKSPACE\", \"KB_ROOT\" }) do\n    add(n, e.by[n] and e.by[n].value)\n  end"
  "$V|smoke|remove ignores where the value comes from|  local scope = row and row.value and row.source\n|  local scope = row and row.value and \"machine\"\n"
  "$V|smoke|a stale read answers the old table|  return read(daemon, where, root, M.REREAD_WAIT_MS) or e|  read_again(daemon, where, root)\n  return e"
  "$V|smoke|no background read|  if _poll then return end\n  _poll = vim.uv.new_timer()|  do return end\n  _poll = vim.uv.new_timer()"
  "$V|where|~ is Neovim's home, not the store's|  if p ~= \"~\" and p:sub(1, 2) ~= \"~/\" then return p end|  do return vim.fn.expand(p) end"
  "$W|smoke|the old vars are offered every session|  if ns:get(\"carried\") then return end|  if false then return end"
  "$W|smoke|a name the daemon knows is carried over it|    if type(name) == \"string\" and type(value) == \"string\" and value ~= \"\" and not have[name] then|    if type(name) == \"string\" and type(value) == \"string\" and value ~= \"\" then"
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
  "$N|notifier|the watermark is one shared read-modify-write file|  local path = watermark_dir() .. \"/\" .. inst .. \".json\"\n  -- Its own file seeds the map once (the same instance after a restart): only\n  -- this instance writes it, so reading it is no read-modify-write of another's.\n  local w = vim.deepcopy(_own[inst] or read_json(path) or {})|  local path = watermark_dir() .. \"/shared.json\"\n  local w = read_json(path) or {}"
  "$N|notifier|a pruner removes before carrying the maximum|  if not write_own(inst, maximum(files)) then return {} end -- carry the maximum first|  -- the maximum is not carried"
  "$N|notifier|a process prunes its own file|  if name == own_name then return false end|  if false then return false end"
  "$N|notifier|a live process's file is pruned|  return pid ~= nil and not alive(pid)|  return true"
  "$N|notifier|a file past the consumer silence is kept|  if os.time() - f.mtime > SILENCE_S then return true end|  if false then return true end"
  "$N|notifier|a read is not repeated when the listing changed|    if table.concat(list_names(dir), |    if true or table.concat(list_names(dir), "
  "$N|notifier|a new process does not prune|  if floor == nil then prepare_once() end|  if false then prepare_once() end"
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
