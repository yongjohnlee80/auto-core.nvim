-- tests/todo-notifier.lua — AutoDoc's assignment changes become mailbox messages
-- (ADR 1791532020 §2.5; design note 2026-10-13 §5 and the decisions: a consumer
-- per Neovim, local recipients only, skip and ack the rest).
--
-- Run through tests/todo-daemon.sh, against a REAL daemon.
local env = require("todo-daemon-env")
local ok, run, section = env.ok, env.run, env.section
env.require_daemon()
env.start_daemon()

local todo     = require("auto-core.todo")
local daemon   = require("auto-core.todo.daemon")
local notifier = require("auto-core.todo.notifier")
local mailbox  = require("auto-core.mailbox")
local mb_path  = mailbox.path
local registry = require("auto-core.mailbox.registry")
local events   = require("auto-core.events")

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
local wm = env.tmp .. "/state/todo_notifier.json"
mb_path.configure(mbroot)
mb_path.set_instance_id("1111111111-22222")
registry.register("nvim", { root = mbroot })
local lector = registry.register("agent:lector", { root = mbroot })

local function inbox(rec) return vim.fn.glob(rec.subs.inbox .. "/todo-*.json", false, true) end
local function inbox_json(rec, mid)
  local text = env.read(rec.subs.inbox .. "/" .. mid .. ".json")
  return text and vim.json.decode(text)
end

-- Every daemon call the shim and the notifier make, recorded; an optional
-- one-shot fault per verb: fault(params, cb, pass) where pass(params, cb) sends
-- it for real.
local calls, faults = {}, {}
daemon._set_transport(function(method, params, cb)
  calls[#calls + 1] = { method = method, params = params }
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

notifier._configure({ poll_ms = false, watermark_path = wm })
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

section("recipients this Neovim does not host: skipped and acked")
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
  local before = #inbox(lector)
  faults["todos.ack"] = function(_, cb) cb(nil, { message = "injected: the ack was lost" }) end
  todo.assign("2026-10-01-task-6", "agent:lector", "ack lost")
  poll()
  local seq = assign_seq("2026-10-01-task-6")
  local mid = notifier.message_id(store_id, seq)
  local path = lector.subs.inbox .. "/" .. mid .. ".json"
  ok("the message was written before the (failed) ack", env.exists(path))
  -- the recipient processed it: it is in archive/ now
  local archived = lector.subs.archive .. "/" .. mid .. ".json"
  vim.uv.fs_rename(path, archived)
  local n_send = #vim.fn.glob(lector.subs.inbox .. "/todo-*.json", false, true)
  poll()
  ok("the change came again (its ack was lost) and was NOT written again",
    not env.exists(path) and #inbox(lector) == n_send, vim.inspect(inbox(lector)))
  ok("the cursor moved on the retry", notifier.watermark(store_id) == seq, notifier.watermark(store_id))
  local _ = before
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
  notifier._configure({ poll_ms = 200, watermark_path = wm })
  notifier.start()
  notifier._connect()
  local t = env.call("todos.get", { "kb", "2026-10-01-task-4" })
  local _, aerr = env.call("todos.assign", { "kb", t.id, t.rev, "agent:lector", "from outside" })
  ok("assigned directly on the daemon (as AutoDoc's GUI would)", aerr == nil, aerr and aerr.message)
  local seq = assign_seq(t.id)
  local mid = notifier.message_id(store_id, seq)
  ok("the timer delivered it", env.wait(5000, function()
    return env.exists(lector.subs.inbox .. "/" .. mid .. ".json") end))
  events.publish("autodoc.session:disconnected", { reason = "test" })
  env.wait(300, function() return false end)
  local t2 = env.call("todos.get", { "kb", "2026-10-01-task-5" })
  env.call("todos.assign", { "kb", t2.id, t2.rev, "agent:lector", "while disconnected" })
  local seq2 = assign_seq(t2.id)
  local mid2 = notifier.message_id(store_id, seq2)
  ok("no delivery while disconnected", not env.wait(1000, function()
    return env.exists(lector.subs.inbox .. "/" .. mid2 .. ".json") end))
  events.publish("autodoc.session:connected", {})
  ok("delivered on reconnect (the catch-up)", env.wait(5000, function()
    return env.exists(lector.subs.inbox .. "/" .. mid2 .. ".json") end))
  notifier.stop()
  notifier._configure({ poll_ms = false, watermark_path = wm })
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
  env.call("todos.assign", { "kb", t.id, t.rev, "agent:lector", "while every Neovim was closed" })
  local seq = assign_seq(t.id)
  -- a new process: a new instance id, so a new consumer
  notifier._reset_for_tests()
  mb_path.set_instance_id("3333333333-44444")
  registry.register("nvim", { root = mbroot })
  local lector2 = registry.register("agent:lector", { root = mbroot })
  notifier._configure({ poll_ms = false, watermark_path = wm })
  notifier.start()
  notifier._connect()
  poll()
  local got = vim.fn.glob(lector2.subs.inbox .. "/todo-*.json", false, true)
  ok("the new consumer delivered exactly the change made while closed", #got == 1
    and got[1]:find(notifier.message_id(store_id, seq), 1, true), vim.inspect(got))
  ok("nothing older was replayed to the old instance either", #inbox(lector) == delivered_before)
  -- no watermark at all: the first poll starts at the head
  notifier._reset_for_tests()
  vim.fn.delete(wm)
  mb_path.set_instance_id("5555555555-66666")
  registry.register("nvim", { root = mbroot })
  local lector3 = registry.register("agent:lector", { root = mbroot })
  notifier._configure({ poll_ms = false, watermark_path = wm })
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

notifier.stop()
env.finish()
