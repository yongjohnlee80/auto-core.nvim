-- tests/todo-where.lua — what auto-core keeps of the todo system after the shim
-- went (ADR 1791532020 §3 step 5, r12), against a REAL AutoDoc daemon:
--
--   * auto-core.todo.where: a project root to the daemon's At, the claim once per
--     root with the legacy $WORKSPACE rewrite, the rollback guard and the
--     explicit claim;
--   * auto-core.todo.buffers: open buffers follow a file the daemon moved;
--   * auto-core.todo.vars: a user var is given to the daemon too;
--   * :AutoCoreTodoClaim, :AutoCoreTodoRefresh and the BufWritePost refresh;
--   * auto-core.todo itself (the forwarding shim) and its Lua writer are gone.
--
-- The direct clients (auto-finder's panel, auto-agents' todos.* verbs) call the
-- daemon's verbs themselves; their suites test that. Here the verbs are sent
-- through auto-core's door (daemon.rpc), as the clients' store resolution does.
--
-- Run through tests/todo-daemon.sh (it needs AUTOCORE_TEST_AUTODOC and
-- AUTOCORE_TEST_AUTODOC_BIN).
local env = require("todo-daemon-env")
local ok, run, section = env.ok, env.run, env.section
env.require_daemon()
env.start_daemon()

local where   = require("auto-core.todo.where")
local daemon  = require("auto-core.todo.daemon")
local buffers = require("auto-core.todo.buffers")
local events  = require("auto-core.events")
local todo    = env.client()
vim.cmd("runtime! plugin/auto-core.lua")

local seen = {}
for _, topic in ipairs({ "core.todo:refreshed" }) do
  seen[topic] = {}
  events.subscribe(topic, function(p) table.insert(seen[topic], p) end)
end

---ensure resolves the current project root, claiming its store the first time.
local function ensure()
  return daemon.sync(function() return where.ensure(where.root()) end)
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
env.write(store .. "/completed/2026-08-01-done-long-ago.md", env.task_text({
  id = "2026-08-01-done-long-ago", title = "Done long ago", status = "completed",
  completed_at = "2026-08-01T10:00:00+00:00" }))
local plain_before = env.read(store .. "/open/2026-10-01-plain.md")
local plain_mtime = vim.uv.fs_stat(store .. "/open/2026-10-01-plain.md").mtime.sec

local _, werr = env.call("workspace.add", { "kb", kb })
ok("fixture: workspace kb added", werr == nil, werr and werr.message)
env.set_project(proj, store)

section("the forwarding shim and the Lua writer are gone (v0.4.1)")
run("gone", function()
  for _, mod in ipairs({ "auto-core.todo", "auto-core.todo.automation", "auto-core.todo.cron",
      "auto-core.todo.import", "auto-core.todo.md", "auto-core.todo.yaml", "auto-core.todo.schema",
      "auto-core.todo.header" }) do
    package.loaded[mod] = nil
    ok(mod .. " no longer exists", pcall(require, mod) == false)
  end
  for _, mod in ipairs({ "auto-core.todo.where", "auto-core.todo.daemon", "auto-core.todo.buffers",
      "auto-core.todo.notifier", "auto-core.todo.vars", "auto-core.todo.paths" }) do
    ok("control — " .. mod .. " is still there", pcall(require, mod) == true)
  end
end)

section("before the first resolution: unclaimed, and nothing written")
run("unclaimed", function()
  local r = env.call("todos.resolve", { "kb" })
  ok("the store is not claimed yet", r and r.claimed == false, vim.inspect(r))
  ok("no marker yet", not env.exists(store .. "/.autodoc-owner"))
end)

section("where.ensure claims the store, through the workspace's At")
run("claim", function()
  local okc, c = ensure()
  ok("ensure answers the resolution", okc and type(c) == "table", c)
  local r = env.call("todos.resolve", { "kb" })
  ok("the store is claimed now", r and r.claimed == true, vim.inspect(r))
  ok("the marker exists", env.exists(store .. "/.autodoc-owner"))
  ok("the At is the workspace that owns the store", c and c.at == "kb", vim.inspect(c and c.at))
  ok("the cached store is the KB store", where.cached(proj) and where.cached(proj).store == store)
  local legacy = todo.get("2026-10-01-legacy-ref")
  local ref = legacy and legacy.adr and legacy.adr[1] or ""
  local resolved = ref:gsub("^%$HOME", vim.env.HOME or "")
  ok("the legacy $WORKSPACE ref was rewritten by the claim", ref:sub(1, 10) ~= "$WORKSPACE", ref)
  ok("the rewritten ref names the project's file", env.realpath(resolved) == proj .. "/docs/legacy.md",
    ref .. " → " .. resolved)
  ok("a file the rewrite did not touch keeps its bytes",
    env.read(store .. "/open/2026-10-01-plain.md") == plain_before)
  ok("… and its mtime", vim.uv.fs_stat(store .. "/open/2026-10-01-plain.md").mtime.sec == plain_mtime)
  local memo = require("auto-core.state").namespace("todo", { persist = "json" }):get("cutover")
  ok("the claim is recorded for this root", type(memo) == "table" and memo[r.store_id]
    and memo[r.store_id].roots[proj] ~= nil, vim.inspect(memo))
  local n = 0
  daemon._set_transport(function(method, params, cb)
    if method == "todos.claim" then n = n + 1 end
    daemon._real_request(method, params, cb)
  end)
  where.reset()
  ensure()
  daemon._set_transport(nil)
  ok("a second resolution of the same root does not claim again", n == 0, n)
end)

section("buffers follow a file the daemon moved")
run("buffers", function()
  local open_path = store .. "/open/2026-10-01-plain.md"
  local buf = vim.fn.bufadd(open_path)
  vim.fn.bufload(buf)
  local t = todo.status("2026-10-01-plain", "deferred")
  ok("fixture: the daemon moved it to deferred/", t and t.file_path == store .. "/deferred/2026-10-01-plain.md",
    t and t.file_path)
  buffers.retarget(open_path, t.file_path)
  ok("the buffer now names the new path", vim.api.nvim_buf_get_name(buf) == t.file_path,
    vim.api.nvim_buf_get_name(buf))
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

section(":AutoCoreTodoRefresh and the save hook")
run("refresh", function()
  local before = #seen["core.todo:refreshed"]
  vim.cmd("AutoCoreTodoRefresh")
  ok(":AutoCoreTodoRefresh ran AutoDoc's refresh (the 28-day archive)",
    not env.exists(store .. "/completed/2026-08-01-done-long-ago.md"))
  ok("… and published core.todo:refreshed", #seen["core.todo:refreshed"] == before + 1)
  local t = todo.get("2026-10-01-plain")
  local f = t.file_path
  vim.cmd("edit " .. vim.fn.fnameescape(f))
  -- a hand edit that misplaces the task: status says open, the file is in deferred/
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, l in ipairs(lines) do
    if l == "status: deferred" then lines[i] = "status: open" end
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  before = #seen["core.todo:refreshed"]
  vim.cmd("silent write")
  ok("saving a task file refreshes the store, without waiting", env.wait(10000, function()
    return #seen["core.todo:refreshed"] == before + 1 end))
  ok("… and AutoDoc moved the hand-edited task to its bucket",
    env.exists(store .. "/open/2026-10-01-plain.md"))
  vim.cmd("bwipeout!")
  before = #seen["core.todo:refreshed"]
  env.write(env.tmp .. "/elsewhere.md", "# not a task\n")
  vim.cmd("edit " .. vim.fn.fnameescape(env.tmp .. "/elsewhere.md"))
  vim.cmd("silent write")
  env.wait(500, function() return false end)
  ok("saving Markdown outside the store refreshes nothing", #seen["core.todo:refreshed"] == before)
  vim.cmd("bwipeout!")
end)

section("a project of its own: register and claim on resolution, scaffold on the first add")
run("own store", function()
  local proj2 = env.tmp .. "/proj2"
  env.set_project(proj2, nil)
  local okc, c = ensure()
  ok("a project with no store resolves", okc and type(c) == "table", c)
  ok("the At is {root}", type(c.at) == "table" and c.at.root == proj2, vim.inspect(c and c.at))
  local id = todo.add({ title = "First in a new project" })
  local store2 = proj2 .. "/.todo-list"
  ok("the first add scaffolded <root>/.todo-list", env.exists(store2 .. "/open/" .. id .. ".md"))
  ok("… and the claim's marker is there", env.exists(store2 .. "/.autodoc-owner"))
  env.set_project(proj, store)
end)

section("rollback: a released store is never claimed again by resolution")
run("rollback guard", function()
  ensure()
  local _, rerr = env.call("todos.release", { "kb" })
  ok("fixture: the store was released (the rollback)", rerr == nil and not env.exists(store .. "/.autodoc-owner"),
    rerr and rerr.message)
  local n = 0
  daemon._set_transport(function(method, params, cb)
    if method == "todos.claim" then n = n + 1 end
    daemon._real_request(method, params, cb)
  end)
  where.reset()
  local okc, c = ensure()
  daemon._set_transport(nil)
  ok("resolution still answers", okc and type(c) == "table", c)
  ok("… knowing the store was released", c and c.claimed == false and c.released == true, vim.inspect(c))
  ok("… and it sent no todos.claim", n == 0, n)
  local r = env.call("todos.resolve", { "kb" })
  ok("the store is still unclaimed, with no marker", r and r.claimed == false
    and not env.exists(store .. "/.autodoc-owner"), vim.inspect(r))
  local okadd, aerr = pcall(todo.add, { title = "Refused" })
  ok("a write answers todos.unclaimed", not okadd and tostring(aerr):find("todos.unclaimed", 1, true), aerr)
end)

section(":AutoCoreTodoClaim claims it on purpose, and answers what the daemon says")
run("explicit claim", function()
  local n = 0
  daemon._set_transport(function(method, params, cb)
    if method == "todos.claim" then n = n + 1 end
    daemon._real_request(method, params, cb)
  end)
  vim.cmd("AutoCoreTodoClaim")
  daemon._set_transport(nil)
  ok(":AutoCoreTodoClaim sent todos.claim", n == 1, n)
  ok("the marker came back", env.exists(store .. "/.autodoc-owner"))
  local r = env.call("todos.resolve", { "kb" })
  ok("the daemon reports the store claimed", r and r.claimed == true, vim.inspect(r))
  local c = where.cached(proj)
  ok("the cache holds the daemon's answer", c and c.claimed == true and c.released == false, vim.inspect(c))
  local okadd, id = pcall(todo.add, { title = "Written after the explicit claim" })
  ok("writes work again", okadd and type(id) == "string", id)

  daemon._set_transport(function(method, params, cb)
    if method == "todos.claim" then return cb(nil, { message = "injected: the claim was refused" }) end
    daemon._real_request(method, params, cb)
  end)
  local okc, cerr = daemon.sync(function() return where.claim(where.root()) end)
  daemon._set_transport(nil)
  ok("a refused claim is an error, not the cached claim",
    okc == false and tostring(cerr):find("injected: the claim was refused", 1, true), cerr)
  local _ = env.call("todos.release", { "kb" })
  daemon._set_transport(function(method, params, cb)
    if method == "todos.claim" then return cb({}, nil) end -- answered, but never applied
    daemon._real_request(method, params, cb)
  end)
  local okc2, cerr2 = daemon.sync(function() return where.claim(where.root()) end)
  daemon._set_transport(nil)
  ok("a claim the daemon does not report applied is an error",
    okc2 == false and tostring(cerr2):find("still not claimed", 1, true), cerr2)
  local okc3, cerr3 = daemon.sync(function() return where.claim(where.root()) end)
  ok("fixture: claimed again", okc3 == true, cerr3)

  -- another client releases the store this Neovim cached as claimed (as AutoDoc's
  -- GUI or `autodoc --call todos.release` would): the cache is never told, and the
  -- explicit claim must ask the daemon, not trust it (review r0, P2 1)
  local c0 = where.cached(proj)
  ok("fixture: this Neovim cached the store as claimed", c0 and c0.claimed == true, vim.inspect(c0))
  local _, rerr = env.call("todos.release", { "kb" })
  ok("fixture: another client released it", rerr == nil and not env.exists(store .. "/.autodoc-owner"))
  local n2 = 0
  daemon._set_transport(function(method, params, cb)
    if method == "todos.claim" then n2 = n2 + 1 end
    daemon._real_request(method, params, cb)
  end)
  vim.cmd("AutoCoreTodoClaim")
  daemon._set_transport(nil)
  ok("the explicit claim sent todos.claim despite the cached claim", n2 == 1, n2)
  ok("… and the marker came back", env.exists(store .. "/.autodoc-owner"))
end)

section("vars: a user var is given to the daemon too")
run("vars", function()
  local vars = require("auto-core.todo.vars")
  local okv = vars.set("COREVAR", proj)
  ok("vars.set answers true", okv == true)
  local got = env.wait(5000, function()
    for _, v in ipairs(env.call("todos.vars", { "kb" }) or {}) do
      if v.name == "COREVAR" and v.value == proj then return true end
    end
  end)
  ok("the daemon has the var too", got)
  vars.remove("COREVAR")
  local gone = env.wait(5000, function()
    for _, v in ipairs(env.call("todos.vars", { "kb" }) or {}) do if v.name == "COREVAR" then return false end end
    return true
  end)
  ok("… and loses it with vars.remove", gone)
end)

env.finish()
