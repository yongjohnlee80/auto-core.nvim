-- tests/todo-shim.lua — auto-core.todo v0.3.4 forwards to a REAL AutoDoc daemon
-- (ADR 1791532020 §3 step 3; design note 2026-10-13 §3, §4).
--
-- Run through tests/todo-daemon.sh (it builds nothing; it needs
-- AUTOCORE_TEST_AUTODOC and AUTOCORE_TEST_AUTODOC_BIN).
local env = require("todo-daemon-env")
local ok, run, section = env.ok, env.run, env.section
env.require_daemon()
env.start_daemon()

local todo    = require("auto-core.todo")
local where   = require("auto-core.todo.where")
local daemon  = require("auto-core.todo.daemon")
local events  = require("auto-core.events")

-- Every event the shim publishes, by topic.
local seen = {}
for _, topic in ipairs({ "core.todo:changed", "core.todo.status:changed", "core.todo:refreshed",
  "core.todo.assignee:changed" }) do
  seen[topic] = {}
  events.subscribe(topic, function(p) table.insert(seen[topic], p) end)
end

-- ── the fixture: the global KB's shape ─────────────────────────
-- A KB workspace "kb" with a store; a project root whose Lua override points
-- at that store; a legacy $WORKSPACE ref that only the project root holds.
local kb = env.new_kb("kb")
local proj = env.tmp .. "/proj"
local store = kb .. "/.todo-list"
env.write(proj .. "/docs/legacy.md", "# legacy\n")
env.write(store .. "/open/2026-10-01-legacy-ref.md", env.task_text({
  id = "2026-10-01-legacy-ref", title = "Legacy ref", adr = { "$WORKSPACE/docs/legacy.md" } }))
env.write(store .. "/open/2026-10-01-plain.md", env.task_text({
  id = "2026-10-01-plain", title = "Plain open task" }))
env.write(store .. "/deferred/2026-10-01-deferred.md", env.task_text({
  id = "2026-10-01-deferred", title = "Deferred task", status = "deferred" }))
env.write(store .. "/archived/2026/09/2026-09-01-old.md", env.task_text({
  id = "2026-09-01-old", title = "Old archived", status = "archived",
  completed_at = "2026-09-01T10:00:00+00:00", archived_at = "2026-09-02T10:00:00+00:00" }))
local plain_before = env.read(store .. "/open/2026-10-01-plain.md")
local plain_mtime = vim.uv.fs_stat(store .. "/open/2026-10-01-plain.md").mtime.sec

local _, werr = env.call("workspace.add", { "kb", kb })
ok("fixture: workspace kb added", werr == nil, werr and werr.message)
env.set_project(proj, store)

section("before the first call: unclaimed, and the shim has written nothing")
run("unclaimed", function()
  local r = env.call("todos.resolve", { "kb" })
  ok("the store is not claimed yet", r and r.claimed == false, vim.inspect(r))
  ok("no marker yet", not env.exists(store .. "/.autodoc-owner"))
end)

section("the first call claims the store, through the workspace's At")
run("claim", function()
  local list = todo.list({ status = "open" })
  ok("list(open) answers the seeded open tasks", #list == 2, #list)
  local r = env.call("todos.resolve", { "kb" })
  ok("the store is claimed now", r and r.claimed == true, vim.inspect(r))
  ok("the marker exists", env.exists(store .. "/.autodoc-owner"))
  local c = where.cached(proj)
  ok("the At is the workspace that owns the store", c and c.at == "kb", vim.inspect(c and c.at))
  ok("the cached store is the KB store", c and c.store == store, c and c.store)
  local legacy = todo.get("2026-10-01-legacy-ref")
  local ref = legacy and legacy.adr and legacy.adr[1] or ""
  local home = vim.env.HOME or ""
  local resolved = ref:gsub("^%$HOME", home)
  ok("the legacy $WORKSPACE ref was rewritten by the claim", ref:sub(1, 10) ~= "$WORKSPACE", ref)
  ok("the rewritten ref names the project's file", env.realpath(resolved) == proj .. "/docs/legacy.md",
    ref .. " → " .. resolved)
  ok("a file the rewrite did not touch keeps its bytes",
    env.read(store .. "/open/2026-10-01-plain.md") == plain_before)
  ok("… and its mtime",
    vim.uv.fs_stat(store .. "/open/2026-10-01-plain.md").mtime.sec == plain_mtime)
  local memo = require("auto-core.state").namespace("todo", { persist = "json" }):get("cutover")
  ok("the claim is recorded for this root", type(memo) == "table" and memo[r.store_id]
    and memo[r.store_id].roots[proj] ~= nil, vim.inspect(memo))
end)

section("reads keep the old shapes")
run("reads", function()
  local t, err = todo.get("2026-10-01-plain")
  ok("get answers a task", t and t.id == "2026-10-01-plain", err)
  ok("… with its rev", t and type(t.rev) == "string" and #t.rev == 64, t and t.rev)
  ok("… its store-relative path", t and t.path == "open/2026-10-01-plain.md", t and t.path)
  ok("… and its absolute file_path", t and t.file_path == store .. "/open/2026-10-01-plain.md")
  local none, nerr = todo.get("no-such-task")
  ok("get of an unknown id is (nil, err)", none == nil and tostring(nerr):find("todos.not_found", 1, true), nerr)
  local all = todo.list()
  ok("list() without a status includes the archive (the old contract)", #all == 4, #all)
  local arch = todo.list({ status = "archived" })
  ok("list({status=archived}) reads the archive by month", #arch == 1 and arch[1].id == "2026-09-01-old",
    vim.inspect(arch))
  ok("list({status=automated}) is empty", #todo.list({ status = "automated" }) == 0)
  local s = todo.scan()
  ok("scan answers tasks and malformed", #s.tasks == 4 and #s.malformed == 0, vim.inspect(#s.tasks))
  ok("get_todo_dir is the store", todo.get_todo_dir() == store, todo.get_todo_dir())
  local dirs = todo.known_dirs()
  local found
  for _, d in ipairs(dirs) do if d.todo_dir == store then found = d end end
  ok("known_dirs lists the store, claimed", found and found.claimed == true, vim.inspect(dirs))
end)

section("scan_async: active first, then the archive")
run("scan_async", function()
  local calls = {}
  todo.scan_async(function(r, done, err) calls[#calls + 1] = { n = r and #r.tasks, done = done, err = err } end)
  ok("nothing answers before scan_async returns", #calls == 0)
  env.wait(10000, function() return #calls >= 2 end)
  ok("two deliveries", #calls == 2, vim.inspect(calls))
  ok("the active buckets first (done=false, 3 tasks)", calls[1] and calls[1].done == false and calls[1].n == 3,
    vim.inspect(calls[1]))
  ok("then the archive (done=true, 4 tasks)", calls[2] and calls[2].done == true and calls[2].n == 4,
    vim.inspect(calls[2]))
  local cancelled = {}
  local cancel = todo.scan_async(function() cancelled[#cancelled + 1] = true end)
  cancel()
  env.wait(500, function() return false end)
  ok("a cancelled scan delivers nothing", #cancelled == 0)
end)

section("writes go through the daemon")
local new_id
run("add / update", function()
  new_id = todo.add({ title = "Shim adds", adr = { "$WORKSPACE/docs/legacy.md" } })
  ok("add returns the id", type(new_id) == "string" and new_id:match("shim%-adds$"), new_id)
  ok("the daemon wrote it in open/", env.exists(store .. "/open/" .. new_id .. ".md"))
  local t = todo.get(new_id)
  local ref = t and t.adr and t.adr[1] or ""
  ok("a $WORKSPACE ref crosses absolute: it names the project's file, not the KB's",
    env.realpath((ref:gsub("^%$HOME", vim.env.HOME or ""))) == proj .. "/docs/legacy.md", ref)
  ok("add published core.todo:changed", #seen["core.todo:changed"] > 0)
  local u, uerr = todo.update(new_id, { priority = "high", tags = { "x" } })
  ok("update changes a hand-editable field", u and u.priority == "high", uerr)
  local _, aerr = todo.update(new_id, { assignee = "agent:x" })
  ok("update refuses assignee, pointing at assign", tostring(aerr):find("M.assign", 1, true), aerr)
  local _, serr = todo.update(new_id, { status = "completed" })
  ok("update refuses status", tostring(serr):find("M.status", 1, true), serr)
  local ok_add, add_err = pcall(todo.add, { title = "x", status = "automated" })
  ok("add refuses the automated status", not ok_add and tostring(add_err):find("automation was removed", 1, true),
    add_err)
end)

run("status moves the file and the open buffer follows", function()
  local open_path = store .. "/open/" .. new_id .. ".md"
  local buf = vim.fn.bufadd(open_path)
  vim.fn.bufload(buf)
  local before = #seen["core.todo.status:changed"]
  local t, err = todo.status(new_id, "completed")
  ok("status(completed) answers the task", t and t.status == "completed", err)
  local done_path = store .. "/completed/" .. new_id .. ".md"
  ok("the file moved to completed/", env.exists(done_path) and not env.exists(open_path))
  ok("the buffer was retargeted", vim.api.nvim_buf_get_name(buf) == done_path, vim.api.nvim_buf_get_name(buf))
  ok("core.todo.status:changed was published", #seen["core.todo.status:changed"] == before + 1)
  local _, aerr = todo.status(new_id, "automated")
  ok("status(automated) is refused", tostring(aerr):find("automation was removed", 1, true), aerr)
  local same = todo.status(new_id, "completed")
  ok("the same status is a no-op", same and same.status == "completed")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

run("assign: D1, events, never assignee:changed", function()
  local before_changed = #seen["core.todo:changed"]
  local open_path = store .. "/open/2026-10-01-plain.md"
  local t, err = todo.assign("2026-10-01-plain", "agent:lector", "start here")
  ok("assign answers the task", t and t.assignee == "agent:lector", err)
  ok("assigning an open task makes it in-progress (D1)", t and t.status == "in-progress", t and t.status)
  ok("… and moves its file", env.exists(store .. "/in-progress/2026-10-01-plain.md") and not env.exists(open_path))
  ok("core.todo:changed (kind assign) was published", (function()
    for i = before_changed + 1, #seen["core.todo:changed"] do
      if seen["core.todo:changed"][i].kind == "assign" then return true end
    end
  end)())
  ok("core.todo.assignee:changed is never published", #seen["core.todo.assignee:changed"] == 0,
    #seen["core.todo.assignee:changed"])
  local c, cerr = todo.assign("2026-10-01-plain", nil)
  ok("assign(nil) clears the assignee", c and c.assignee == nil, cerr)
end)

run("a stale rev is an error, never retried", function()
  -- Between the shim's todos.get and its write, edit the file by hand, ONCE: a
  -- shim that re-read and retried would then succeed, and must not.
  local file = store .. "/deferred/2026-10-01-deferred.md"
  local edited = false
  daemon._set_transport(function(method, params, cb)
    daemon._real_request(method, params, function(r, e)
      if method == "todos.get" and not edited then
        edited = true
        env.write(file, env.read(file) .. "\nA hand edit.\n")
      end
      cb(r, e)
    end)
  end)
  local t, err = todo.update("2026-10-01-deferred", { priority = "low" })
  daemon._set_transport(nil)
  ok("update answers todos.stale", t == nil and tostring(err):find("todos.stale", 1, true), err)
  local cur = todo.get("2026-10-01-deferred")
  ok("the task was not changed", cur and cur.priority ~= "low", cur and cur.priority)
end)

run("remove, malformed files", function()
  local rid = todo.add({ title = "To be removed" })
  local okr, rerr = todo.remove(rid)
  ok("remove answers true", okr == true, rerr)
  ok("the file is gone", not env.exists(store .. "/open/" .. rid .. ".md"))
  local bad = store .. "/open/2026-10-02-broken.md"
  env.write(bad, "---\nid: [unclosed\n---\n# Broken\n")
  local auto = store .. "/open/2026-10-02-automated.md"
  env.write(auto, (env.task_text({ id = "2026-10-02-automated", title = "Uses automation" })
    :gsub("\nstatus: open\n", "\nstatus: open\ncondition:\n  - \"0 0 * * *\"\n", 1)))
  local s = todo.scan()
  local m = {}
  for _, e in ipairs(s.malformed) do m[e.filename] = e end
  ok("scan lists the malformed file with its absolute path",
    m["2026-10-02-broken.md"] and m["2026-10-02-broken.md"].file_path == bad
    and m["2026-10-02-broken.md"].bucket == "open", vim.inspect(s.malformed))
  ok("a file using automation is malformed with the removal reason",
    m["2026-10-02-automated.md"] and tostring(m["2026-10-02-automated.md"].err):find("automation", 1, true),
    vim.inspect(m["2026-10-02-automated.md"]))
  local okm, merr = todo.remove_malformed(bad)
  ok("remove_malformed deletes it", okm == true and not env.exists(bad), merr)
  local oka, aerr = todo.remove_malformed(auto)
  ok("remove_malformed refuses a file using automation", oka == false and env.exists(auto), aerr)
  vim.fn.delete(auto)
end)

run("refresh: the 28-day archive", function()
  env.write(store .. "/completed/2026-08-01-done-long-ago.md", env.task_text({
    id = "2026-08-01-done-long-ago", title = "Done long ago", status = "completed",
    completed_at = "2026-08-01T10:00:00+00:00" }))
  local before = #seen["core.todo:refreshed"]
  local s = todo.refresh()
  ok("refresh answers the summary", type(s) == "table" and s.archived >= 1, vim.inspect(s))
  ok("… with Lua's skipped name kept", s.skipped == s.malformed)
  ok("the old completed task was archived", not env.exists(store .. "/completed/2026-08-01-done-long-ago.md"))
  ok("core.todo:refreshed was published", #seen["core.todo:refreshed"] == before + 1)
end)

section("a project of its own: register, claim, scaffold; set_dir; move_store")
run("own store", function()
  local other = env.tmp .. "/other"
  vim.fn.mkdir(other, "p")
  env.set_project(env.tmp .. "/proj2", nil)
  local empty = todo.list()
  ok("a project with no store yet lists as empty, not as an error", type(empty) == "table" and #empty == 0)
  local okr, rs = pcall(todo.refresh)
  ok("… and refreshes to a zero summary", okr and rs.scanned == 0, rs)
  local id = todo.add({ title = "First in a new project" })
  local store2 = env.tmp .. "/proj2/.todo-list"
  ok("the first add scaffolded <root>/.todo-list", env.exists(store2 .. "/open/" .. id .. ".md"))
  ok("… and the claim's marker is there", env.exists(store2 .. "/.autodoc-owner"))
  ok("the At is {root}", type(where.cached(env.tmp .. "/proj2").at) == "table")
  local events_before = #seen["core.todo:changed"]
  todo.set_todo_dir(other)
  ok("set_todo_dir points the project at an existing directory", todo.get_todo_dir() == other, todo.get_todo_dir())
  ok("… and publishes no core.todo:changed, as before the cutover",
    #seen["core.todo:changed"] == events_before, #seen["core.todo:changed"] - events_before)
  local id2 = todo.add({ title = "In the other directory" })
  ok("a task lands there (scaffolded on first add)", env.exists(other .. "/open/" .. id2 .. ".md"))
  local moved = todo.move_store(env.tmp .. "/moved")
  ok("move_store answers the new path", moved == env.tmp .. "/moved", moved)
  ok("the files moved", env.exists(env.tmp .. "/moved/open/" .. id2 .. ".md") and not env.exists(other))
  local r = env.call("todos.resolve", { { root = env.tmp .. "/proj2" } })
  ok("the moved store is still claimed", r and r.claimed == true and r.store == env.tmp .. "/moved", vim.inspect(r))
  local okm, merr = pcall(todo.move_store, env.tmp .. "/no-parent/x")
  ok("move_store refuses a missing parent", not okm, merr)
  env.set_project(proj, store)
end)

section("rollback: a released store is never claimed again")
run("rollback guard", function()
  local okr, rerr = todo.release()
  ok("release answers true", okr == true, rerr)
  ok("the marker is gone", not env.exists(store .. "/.autodoc-owner"))
  where.reset()
  local list = todo.list({ status = "open" })
  ok("reads still work", type(list) == "table")
  local r = env.call("todos.resolve", { "kb" })
  ok("the shim did NOT claim it again", r and r.claimed == false, vim.inspect(r))
  local okadd, aerr = pcall(todo.add, { title = "Refused" })
  ok("a write answers todos.unclaimed", not okadd and tostring(aerr):find("todos.unclaimed", 1, true), aerr)
  local okc, cerr = todo.claim()
  ok(":AutoCoreTodoClaim (todo.claim) claims it on purpose", okc == true, cerr)
  local r2 = env.call("todos.resolve", { "kb" })
  ok("claimed again", r2 and r2.claimed == true)
end)

section("vars, import, automation")
run("vars", function()
  local okv = todo.vars.set("SHIMVAR", proj)
  ok("vars.set answers true", okv == true)
  local got = env.wait(5000, function()
    local list = env.call("todos.vars", { "kb" })
    for _, v in ipairs(list or {}) do if v.name == "SHIMVAR" and v.value == proj then return true end end
  end)
  ok("the daemon has the var too", got)
  todo.vars.remove("SHIMVAR")
  local gone = env.wait(5000, function()
    for _, v in ipairs(env.call("todos.vars", { "kb" }) or {}) do if v.name == "SHIMVAR" then return false end end
    return true
  end)
  ok("… and loses it with vars.remove", gone)
end)

run("import and automation", function()
  local oki, ierr = pcall(todo.import, "/x", {})
  ok("import is refused (D3)", not oki and tostring(ierr):find("D3", 1, true), ierr)
  local automation = require("auto-core.todo.automation")
  local r, err = automation.fire("2026-10-01-plain")
  ok("automation.fire refuses", r == nil and tostring(err):find("automation was removed", 1, true), err)
  automation.start()
  ok("automation.start is a no-op", automation.list_pending().running == false)
end)

env.finish()
