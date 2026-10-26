-- tests/todo-notifier.lua — AutoDoc's assignment changes become mailbox messages
-- (ADR 1791532020 §2.5; design note 2026-10-13 §5 and the decisions: a consumer
-- per Neovim, local recipients only, skip and ack the rest).
--
-- Run through tests/todo-daemon.sh, against a REAL daemon.
local env = require("todo-daemon-env")
local ok, run, section = env.ok, env.run, env.section
env.require_daemon()
env.start_daemon()

-- The fixture client (auto-core.todo, the shim, went at v0.4.1): it stands in
-- for the direct clients, through auto-core's door, so the spies below see it.
local todo     = env.client()
local daemon   = require("auto-core.todo.daemon")
local notifier = require("auto-core.todo.notifier")
local mailbox  = require("auto-core.mailbox")
local mb_path  = mailbox.path
local registry = require("auto-core.mailbox.registry")
local events   = require("auto-core.events")
local scope    = require("auto-core.todo.scope")

-- This Neovim's project, as auto-agents sets it at setup (ADR 1791532020 §2.5a):
-- the fixture client's assignments carry it, and so do the direct calls below
-- that stand in for another Neovim of the same project.
local SCOPE = "auto-agents:project-a"
scope.set(SCOPE)

-- The cells up to the hold sections run with grace_ms = 0: a recipient not
-- registered here is past the window at once (skipped and acked), as the
-- notifier treats it after GRACE_MS. The hold sections set a window.

-- ── fixture ─────────────────────────────────────────────────────
local kb = env.new_kb("kb")
local store = kb .. "/.todo-list"
local proj = env.tmp .. "/proj"
local _, werr = env.call("workspace.add", { "kb", kb })
ok("fixture: workspace kb added", werr == nil, werr and werr.message)
env.set_project(proj, store)
for i = 1, 6 do
  env.write(store .. "/open/2026-10-01-task-" .. i .. ".md", env.task_text({
    id = "2026-10-01-task-" .. i, title = "Task " .. i }))
end
ok("fixture: the first call claims the store", #todo.list({ status = "open" }) == 6)
local store_id = env.call("todos.resolve", { "kb" }).store_id

local mbroot = env.tmp .. "/mailbox"
local wm = env.tmp .. "/state/todo_notifier"
mb_path.configure(mbroot)
mb_path.set_instance_id("1111111111-22222")
registry.register("nvim", { root = mbroot })
local lector = registry.register("agent:lector", { root = mbroot })

local function inbox(rec) return vim.fn.glob(rec.subs.inbox .. "/todo-*.json", false, true) end
local function inbox_json(rec, mid)
  local text = env.read(rec.subs.inbox .. "/" .. mid .. ".json")
  return text and vim.json.decode(text)
end

-- Every daemon call the fixture client and the notifier make, recorded; an optional
-- one-shot fault per verb: fault(params, cb, pass) where pass(params, cb) sends
-- it for real.
local calls, faults = {}, {}
local acks_fail = false -- every todos.ack is lost while set
daemon._set_transport(function(method, params, cb)
  calls[#calls + 1] = { method = method, params = params }
  if method == "todos.ack" and acks_fail then
    return cb(nil, { message = "injected: the ack was lost" })
  end
  local f = faults[method]
  if f then
    faults[method] = nil
    return f(params, cb, function(p, c) daemon._real_request(method, p, c) end)
  end
  daemon._real_request(method, params, cb)
end)

local function count(method)
  local n = 0
  for _, c in ipairs(calls) do if c.method == method then n = n + 1 end end
  return n
end

---assign_seq is the seq of the last assign change of a task (read with a probe
---consumer that never acks, so it always sees the whole retained log).
local function assign_seq(id)
  local p = env.call("todos.changes", { "kb", "probe", 1000 })
  local s = 0
  for _, c in ipairs((p and p.changes) or {}) do
    if c.kind == "assign" and c.id == id then s = math.max(s, c.seq) end
  end
  return s
end

local function head()
  local p = env.call("todos.changes", { "kb", "probe", 1000 })
  return (p and p.cursor) or 0
end

local function poll()
  local done = false
  notifier.poll_all(function() done = true end)
  env.wait(10000, function() return done end)
  return done
end

notifier._configure({ poll_ms = false, watermark_dir = wm, grace_ms = 0 })
notifier.start()
notifier._connect()
env.wait(5000, function() return count("todos.stores") > 0 end)

section("an assignment made here reaches the local agent once, then the cursor moves")
run("deliver", function()
  ok("the consumer is per Neovim", notifier.consumer() == "auto-core:1111111111-22222", notifier.consumer())
  local t = todo.assign("2026-10-01-task-1", "agent:lector", "start with the tests")
  ok("the assignment landed (D1)", t and t.status == "in-progress")
  local seq = assign_seq("2026-10-01-task-1")
  local mid = notifier.message_id(store_id, seq)
  env.wait(5000, function() return env.exists(lector.subs.inbox .. "/" .. mid .. ".json") end)
  local msg = inbox_json(lector, mid)
  ok("one message, id todo-<store_id>-<seq>", msg and msg.id == mid, mid)
  ok("its subject names the task", msg and tostring(msg.subject):find("Task 1", 1, true), msg and msg.subject)
  ok("its body carries the reason", msg and tostring(msg.body):find("Reason: start with the tests", 1, true))
  ok("its body carries the file path",
    msg and tostring(msg.body):find(store .. "/in-progress/2026-10-01-task-1.md", 1, true), msg and msg.body)
  ok("it is from the host mailbox", msg and msg.from == "nvim")
  ok("then the change is acked: the watermark is its seq", env.wait(5000, function()
    return notifier.watermark(store_id) == seq end), notifier.watermark(store_id))
  poll()
  ok("a second poll sends nothing more", #inbox(lector) == 1, #inbox(lector))
end)

section("recipients this Neovim does not host, past the grace window (0 here): skipped and acked")
run("skip", function()
  todo.assign("2026-10-01-task-2", "agent:ghost", "nobody here")
  todo.assign("2026-10-01-task-3", "user")
  todo.assign("2026-10-01-task-4", "autodoc:helper")
  poll()
  ok("nothing for ghost, user or autodoc:helper", #inbox(lector) == 1 and vim.fn.isdirectory(mbroot
    .. "/1111111111-22222/ghost") == 0, vim.inspect(inbox(lector)))
  local before = #inbox(lector)
  todo.assign("2026-10-01-task-2", "agent:lector", "now for you")
  poll()
  ok("a later local assignment is not blocked behind them", #inbox(lector) == before + 1, #inbox(lector))
  local other = registry.get("agent:lector:9999999999-1")
  ok("another instance's full id is never local", notifier.local_recipient("agent:lector:9999999999-1") == nil
    and other == nil)
  ok("a bare name is tried as agent:<name>", notifier.local_recipient("lector") ~= nil)
end)

section("add with an assignee notifies; a hand edit of assignee does not")
run("add and hand edit", function()
  local before = #inbox(lector)
  local id = todo.add({ title = "Created assigned", assignee = "agent:lector" })
  poll()
  ok("todos.add with an assignee is delivered", #inbox(lector) == before + 1, #inbox(lector))
  local f = store .. "/open/2026-10-01-task-5.md"
  env.write(f, (env.read(f):gsub("\nstatus: open\n", "\nstatus: open\nassignee: agent:lector\n", 1)))
  todo.refresh()
  poll()
  ok("a hand edit of assignee sends nothing", #inbox(lector) == before + 1, #inbox(lector))
  local _ = id
end)

section("at-least-once")
run("ack fails after the send", function()
  acks_fail = true
  todo.assign("2026-10-01-task-6", "agent:lector", "ack lost")
  poll()
  local seq = assign_seq("2026-10-01-task-6")
  local mid = notifier.message_id(store_id, seq)
  local path = lector.subs.inbox .. "/" .. mid .. ".json"
  ok("the message was written before the (lost) ack", env.exists(path))
  ok("the cursor did not move", (notifier.watermark(store_id) or 0) < seq, notifier.watermark(store_id))
  -- the recipient processed it: it is in archive/ now
  vim.uv.fs_rename(path, lector.subs.archive .. "/" .. mid .. ".json")
  acks_fail = false
  poll()
  ok("the change came again (its ack was lost) and was NOT written again", not env.exists(path),
    vim.inspect(inbox(lector)))
  ok("the cursor moved on the retry", notifier.watermark(store_id) == seq, notifier.watermark(store_id))
end)

run("a failed send stops the page; the next poll resumes at the same seq", function()
  vim.fn.setfperm(lector.subs.inbox, "r-xr-xr-x")
  local t = todo.get("2026-10-01-task-3")
  todo.assign(t.id, "agent:lector", "inbox is read-only")
  poll()
  local seq = assign_seq(t.id)
  local mid = notifier.message_id(store_id, seq)
  ok("nothing written while the inbox refuses", not env.exists(lector.subs.inbox .. "/" .. mid .. ".json"))
  ok("the cursor did not move past it", (notifier.watermark(store_id) or 0) < seq, notifier.watermark(store_id))
  vim.fn.setfperm(lector.subs.inbox, "rwxr-xr-x")
  poll()
  ok("delivered on the next poll, under the same id", env.exists(lector.subs.inbox .. "/" .. mid .. ".json"))
  ok("then acked", notifier.watermark(store_id) == seq)
end)

section("the timer delivers an assignment made outside this Neovim; it stops on disconnect")
run("timer", function()
  notifier.stop()
  notifier._configure({ poll_ms = 200, watermark_dir = wm, grace_ms = 0 })
  notifier.start()
  notifier._connect()
  local t = env.call("todos.get", { "kb", "2026-10-01-task-4" })
  local _, aerr = env.call("todos.assign", { "kb", t.id, t.rev, "agent:lector", "from outside", SCOPE })
  ok("assigned directly on the daemon (as AutoDoc's GUI would)", aerr == nil, aerr and aerr.message)
  local seq = assign_seq(t.id)
  local mid = notifier.message_id(store_id, seq)
  ok("the timer delivered it", env.wait(5000, function()
    return env.exists(lector.subs.inbox .. "/" .. mid .. ".json") end))
  events.publish("autodoc.session:disconnected", { reason = "test" })
  env.wait(300, function() return false end)
  local t2 = env.call("todos.get", { "kb", "2026-10-01-task-5" })
  env.call("todos.assign", { "kb", t2.id, t2.rev, "agent:lector", "while disconnected", SCOPE })
  local seq2 = assign_seq(t2.id)
  local mid2 = notifier.message_id(store_id, seq2)
  ok("no delivery while disconnected", not env.wait(1000, function()
    return env.exists(lector.subs.inbox .. "/" .. mid2 .. ".json") end))
  events.publish("autodoc.session:connected", {})
  ok("delivered on reconnect (the catch-up)", env.wait(5000, function()
    return env.exists(lector.subs.inbox .. "/" .. mid2 .. ".json") end))
  notifier.stop()
  notifier._configure({ poll_ms = false, watermark_dir = wm, grace_ms = 0 })
  notifier.start()
end)

run("polls never overlap", function()
  local before = count("todos.stores")
  local finished = 0
  for _ = 1, 5 do notifier.poll_all(function() finished = finished + 1 end) end
  env.wait(5000, function() return finished >= 1 end)
  env.wait(300, function() return false end)
  ok("five requests during one poll make at most two polls", count("todos.stores") - before <= 2,
    count("todos.stores") - before)
end)

section("a new Neovim: it starts after the watermark, not at the log's beginning")
run("watermark", function()
  notifier.stop()
  local delivered_before = #inbox(lector)
  -- while no Neovim polls, an assignment lands
  local t = env.call("todos.get", { "kb", "2026-10-01-task-6" })
  env.call("todos.assign", { "kb", t.id, t.rev, "agent:lector", "while every Neovim was closed", SCOPE })
  local seq = assign_seq(t.id)
  -- a new process: a new instance id, so a new consumer
  notifier._reset_for_tests()
  mb_path.set_instance_id("3333333333-44444")
  registry.register("nvim", { root = mbroot })
  local lector2 = registry.register("agent:lector", { root = mbroot })
  notifier._configure({ poll_ms = false, watermark_dir = wm, grace_ms = 0 })
  notifier.start()
  notifier._connect()
  poll()
  local got = vim.fn.glob(lector2.subs.inbox .. "/todo-*.json", false, true)
  ok("the new consumer delivered exactly the change made while closed", #got == 1
    and got[1]:find(notifier.message_id(store_id, seq), 1, true), vim.inspect(got))
  ok("nothing older was replayed to the old instance either", #inbox(lector) == delivered_before)
  -- no watermark at all: the first poll starts at the head
  notifier._reset_for_tests()
  vim.fn.delete(wm, "rf")
  mb_path.set_instance_id("5555555555-66666")
  registry.register("nvim", { root = mbroot })
  local lector3 = registry.register("agent:lector", { root = mbroot })
  notifier._configure({ poll_ms = false, watermark_dir = wm, grace_ms = 0 })
  notifier.start()
  notifier._connect()
  poll()
  ok("with no watermark, nothing retained is replayed",
    #vim.fn.glob(lector3.subs.inbox .. "/todo-*.json", false, true) == 0)
  ok("… and the head is recorded", notifier.watermark(store_id) == nil or notifier.watermark(store_id) >= seq)
  lector = lector3
end)

section("resync: each assigned task once, then the page's cursor is acked")
run("resync", function()
  local h = head()
  local acked
  faults["todos.changes"] = function(_, cb)
    cb({ resync = true, cursor = h, snapshot = {
      { id = "2026-10-01-task-1", path = "in-progress/2026-10-01-task-1.md", assignee = "agent:lector" },
      { id = "2026-10-01-task-2", path = "in-progress/2026-10-01-task-2.md", assignee = "agent:ghost" },
    } }, nil)
  end
  faults["todos.ack"] = function(params, cb, pass)
    acked = params[3]
    pass(params, cb)
  end
  poll()
  local mid = string.format("todo-%s-r%d-%s", store_id, h, "2026-10-01-task-1")
  local msg = inbox_json(lector, mid)
  ok("the assigned task was sent once, saying the reason was lost", msg
    and tostring(msg.body):find("resync", 1, true), mid)
  ok("not to the agent this Neovim does not host",
    #vim.fn.glob(lector.subs.inbox .. "/todo-*task-2*.json", false, true) == 0)
  ok("then the page's cursor was acked", acked == h, tostring(acked) .. " vs " .. h)
end)

section("held: an assignment made before its agent registers is delivered when it registers")
run("hold", function()
  notifier._reset_for_tests()
  notifier._configure({ poll_ms = false, watermark_dir = wm, grace_ms = 60000 })
  notifier.start()
  notifier._connect()
  poll()
  local nid = todo.add({ title = "For an agent that starts later", assignee = "agent:newbie" })
  poll()
  local nseq = assign_seq(nid)
  local nmid = notifier.message_id(store_id, nseq)
  ok("nothing is written while the agent is not registered", vim.fn.isdirectory(mbroot
    .. "/" .. mb_path.get_instance_id() .. "/newbie") == 0)
  ok("the watermark does not pass the held change", (notifier.watermark(store_id) or 0) < nseq,
    tostring(notifier.watermark(store_id)) .. " vs " .. nseq)
  local lid = todo.add({ title = "Meanwhile, for lector", assignee = "agent:lector" })
  poll()
  local lmid = notifier.message_id(store_id, assign_seq(lid))
  local lpath = lector.subs.inbox .. "/" .. lmid .. ".json"
  ok("a later change is delivered while the earlier one is held", env.exists(lpath))
  local st = vim.uv.fs_stat(lpath)
  local n_lector = #inbox(lector)
  poll()
  local st2 = vim.uv.fs_stat(lpath)
  ok("the next poll reads it again and writes nothing twice", st2 and st.ino == st2.ino
    and st.mtime.nsec == st2.mtime.nsec and #inbox(lector) == n_lector)
  ok("the watermark still does not pass the held change", (notifier.watermark(store_id) or 0) < nseq)
  -- the agent spawns: registration alone must deliver (the test polls no more)
  local newbie = registry.register("agent:newbie", { root = mbroot })
  ok("delivered when the agent registers, within the window", env.wait(5000, function()
    return env.exists(newbie.subs.inbox .. "/" .. nmid .. ".json") end))
  ok("then the watermark passes both changes", env.wait(5000, function()
    return (notifier.watermark(store_id) or 0) >= assign_seq(lid) end), notifier.watermark(store_id))
  local st3 = vim.uv.fs_stat(lpath)
  ok("lector's message was still written once", st3 and st3.ino == st.ino and #inbox(lector) == n_lector)
end)

section("past the grace window: a recipient still not registered is skipped and acked, once, as an audit line")
run("grace", function()
  notifier._reset_for_tests()
  notifier._configure({ poll_ms = false, watermark_dir = wm, grace_ms = 300 })
  notifier.start()
  notifier._connect()
  env.wait(500, function() return false end)
  poll()
  local log = require("auto-core.log")
  local toasts = 0
  local real = vim.notify
  vim.notify = function(...) toasts = toasts + 1; return real(...) end
  local gid = todo.add({ title = "For an agent that never starts", assignee = "agent:never" })
  poll()
  poll()
  vim.notify = real
  local gseq = assign_seq(gid)
  local gmid = notifier.message_id(store_id, gseq)
  ok("acked: the watermark passes it", (notifier.watermark(store_id) or 0) >= gseq,
    tostring(notifier.watermark(store_id)) .. " vs " .. gseq)
  local lines = 0
  for _, e in ipairs(log.recent()) do
    if tostring(e.message):find(gmid, 1, true) and tostring(e.message):find("skipped", 1, true) then
      lines = lines + 1
    end
  end
  ok("one audit line names it", lines == 1, lines)
  ok("and no notice reached the user", toasts == 0, toasts)
end)

section("several Neovims: one watermark file per process, the maximum read, never lowered")
-- Each cell plays several processes in this one: the seams write or prune AS an
-- instance, and before_write/after_list run another process's step at the
-- worst moment, deterministically. pid 1 is always alive; 999999999 never is
-- (above Linux's PID_MAX_LIMIT).
local W, P = notifier._watermark_write, notifier._watermark_prune
local function with_dir(name, hooks)
  local dir = env.tmp .. "/" .. name
  notifier._configure(vim.tbl_extend("force", { poll_ms = false, watermark_dir = dir, grace_ms = 0 }, hooks or {}))
  return dir
end
local function files(dir)
  local out = {}
  for _, f in ipairs(vim.fn.glob(dir .. "/*.json", false, true)) do out[vim.fn.fnamemodify(f, ":t")] = true end
  return out
end
local A, B = "1000000001-1", "1000000002-1"

run("two writers interleave on one store", function()
  notifier.stop()
  notifier._reset_for_tests()
  with_dir("wm-race")
  W(A, { S = 100 })
  W(B, { S = 100 })
  local once = true
  with_dir("wm-race", { before_write = function(inst)
    if inst == A and once then once = false; W(B, { S = 102 }) end
  end })
  W(A, { S = 101 }) -- A has updated its map; B writes 102 before A writes 101
  ok("B's write ran between A's update and A's write", not once)
  ok("a third process starts after 102, not 101", notifier.watermark("S") == 102, notifier.watermark("S"))
end)

run("two writers interleave on different stores", function()
  notifier._reset_for_tests()
  local once = true
  with_dir("wm-race2", { before_write = function(inst)
    if inst == A and once then once = false; W(B, { Y = 7 }) end
  end })
  W(A, { X = 5 })
  ok("B's store survives A's write", notifier.watermark("Y") == 7, notifier.watermark("Y"))
  ok("… and A's", notifier.watermark("X") == 5, notifier.watermark("X"))
end)

run("pruning removes the files of processes that are gone, never lowering the maximum", function()
  notifier._reset_for_tests()
  local dir = with_dir("wm-prune")
  local me = "1000000006-" .. vim.fn.getpid()
  local dead = "1000000003-999999999"
  local live = "1000000004-" .. vim.fn.getpid()
  local aged = "1000000005-1"
  W(dead, { S = 500, T = 3 })
  W(live, { S = 10 })
  W(aged, { T = 9 })
  local old = os.time() - 100 * 24 * 3600
  vim.uv.fs_utime(dir .. "/" .. aged .. ".json", old, old)
  local removed = P(me)
  table.sort(removed)
  ok("the dead process's file and the 100-day-old one were pruned",
    vim.deep_equal(removed, { dead .. ".json", aged .. ".json" }), vim.inspect(removed))
  local f = files(dir)
  ok("a live process's file is kept", f[live .. ".json"], vim.inspect(f))
  ok("the pruner's own file carries the maximum", f[me .. ".json"], vim.inspect(f))
  ok("the starting point is still 500 for S", notifier.watermark("S") == 500, notifier.watermark("S"))
  ok("… and 9 for T (from the aged file)", notifier.watermark("T") == 9, notifier.watermark("T"))
end)

run("a process never prunes its own file", function()
  notifier._reset_for_tests()
  local dir = with_dir("wm-own")
  local mine = "1000000007-999999999" -- its pid reads as gone, as the test instance ids do
  W(mine, { S = 42 })
  W("1000000008-999999999", { S = 1 })
  P(mine)
  ok("its own file is still there", files(dir)[mine .. ".json"], vim.inspect(files(dir)))
  ok("and the starting point is 42", notifier.watermark("S") == 42, notifier.watermark("S"))
end)

run("a prune between a reader's listing and its reads", function()
  notifier._reset_for_tests()
  local dir = with_dir("wm-scan")
  W("1000000009-999999999", { S = 300 })
  local once, pruned = true, nil
  with_dir("wm-scan", { after_list = function()
    if once then once = false; pruned = P("1000000010-1") end
  end })
  local got = notifier.watermark("S")
  ok("the pruner ran after the reader listed the dead file", pruned and #pruned == 1, vim.inspect(pruned))
  ok("the reader read again and found 300 in the pruner's file", got == 300, got)
  ok("only the pruner's file is left", vim.deep_equal(files(dir), { ["1000000010-1.json"] = true }),
    vim.inspect(files(dir)))
end)

run("a new Neovim prunes once, at its first floor", function()
  notifier._reset_for_tests()
  local dir = with_dir("wm-start")
  W("1000000011-999999999", { [store_id] = head() })
  mb_path.set_instance_id("7777777777-" .. vim.fn.getpid())
  registry.register("nvim", { root = mbroot })
  notifier.start()
  notifier._connect()
  poll()
  local f = files(dir)
  ok("the dead process's file is gone", not f["1000000011-999999999.json"], vim.inspect(f))
  ok("this process's file carries the floor", f["7777777777-" .. vim.fn.getpid() .. ".json"]
    and notifier.watermark(store_id) == head(), vim.inspect(f))
end)

section("a bare assignee is its own project's agent (ADR 1791532020 §2.5a)")
-- One Neovim of project A. The others sharing the store are stood in for by
-- the scope their assignments carry: B's, or none (a legacy change, a hand
-- edit, an unscoped --call).
local function fresh(inst)
  notifier._reset_for_tests()
  mb_path.set_instance_id(inst)
  registry.register("nvim", { root = mbroot })
  local rec = registry.register("agent:vision", { root = mbroot })
  notifier._configure({ poll_ms = false, watermark_dir = env.tmp .. "/wm-scope", grace_ms = 0 })
  notifier.start()
  notifier._connect()
  poll()
  return rec
end
---assigned makes an assignment as a client of scope s would (nil: none), and
---returns its message id once this Neovim's notifier has polled past it.
local function assigned(title, who, s)
  local id = todo.add({ title = title })
  local t = env.call("todos.get", { "kb", id })
  local params = { "kb", t.id, t.rev, who, "scoped" }
  if s then params[6] = s end
  local _, err = env.call("todos.assign", params)
  ok("assigned: " .. title, err == nil, err and err.message)
  local seq = assign_seq(id)
  poll()
  return notifier.message_id(store_id, seq), seq
end
local function delivered(rec, mid) return env.exists(rec.subs.inbox .. "/" .. mid .. ".json") end

run("the scope decides who delivers a bare name", function()
  local vision = fresh("8888888888-11111")
  ok("this Neovim is project A", scope.get() == SCOPE and scope.scoped(), scope.get())
  local mine = assigned("S1", "agent:vision", SCOPE)
  ok("A's bare assignment is delivered in A", delivered(vision, mine), mine)
  local theirs, tseq = assigned("S2", "agent:vision", "auto-agents:project-b")
  ok("B's bare assignment is not delivered in A", not delivered(vision, theirs), theirs)
  ok("… and A acks it: it is B's to deliver", notifier.watermark(store_id) >= tseq, notifier.watermark(store_id))
  local legacy, lseq = assigned("S3", "gold-man", nil)
  ok("a bare name with no scope is delivered by none", not delivered(vision, legacy), legacy)
  ok("… and acked", notifier.watermark(store_id) >= lseq)
  local full = assigned("S4", "agent:vision:8888888888-11111", "auto-agents:project-b")
  ok("a full id reaches its instance, whatever the scope", delivered(vision, full), full)
end)

run("a restart keeps the project: a new instance id still delivers A's bare names", function()
  local vision = fresh("9999999999-22222")
  local mid = assigned("S5", "agent:vision", SCOPE)
  ok("delivered after the restart", delivered(vision, mid), mid)
end)

run("the rollout guard: below protocol 30, no scope is sent and the v0.5.0 rule stands", function()
  scope._set_protocol(29)
  local p = scope.assign_params("agent:vision", "why")
  ok("no scope in the params", #p == 2 and p[2] == "why", vim.inspect(p))
  local vision = fresh("1212121212-33333")
  local mid = assigned("S6", "agent:vision", nil)
  ok("a bare name with no scope is delivered by name, as before", delivered(vision, mid), mid)
  scope._set_protocol(nil)
  local q = scope.assign_params("agent:vision", nil)
  ok("at 30 the scope follows an empty reason", #q == 3 and q[2] == "" and q[3] == SCOPE, vim.inspect(q))
end)

notifier.stop()
env.finish()
