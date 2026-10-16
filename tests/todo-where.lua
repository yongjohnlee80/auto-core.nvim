-- tests/todo-where.lua — what auto-core keeps of the todo system after the shim
-- went (ADR 1791532020 §3 step 5, r12), against a REAL AutoDoc daemon:
--
--   * auto-core.todo.where: a project root to the daemon's At, the claim once per
--     root with the legacy $WORKSPACE rewrite, the rollback guard and the
--     explicit claim;
--   * auto-core.todo.buffers: open buffers follow a file the daemon moved;
--   * auto-core.todo.vars: a file's workspace's variables (ADR 1792132105), the
--     same from every route;
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

section("vars: the workspace's, the same from every route (ADR 1792132105)")
run("vars", function()
  local vars = require("auto-core.todo.vars")
  vars._reset_for_tests()
  vim.env.WORKSPACE = nil -- the environment is the last layer: keep it from answering $WORKSPACE
  local function table_of(at)
    local out = {}
    for _, v in ipairs(env.call("todos.vars", { at }) or {}) do out[v.name] = v end
    return out
  end
  local function ws_table(name)
    local out = {}
    for _, v in ipairs(env.call("workspace.vars", { name }) or {}) do out[v.name] = v end
    return out
  end
  local by_ws, by_root = table_of("kb"), table_of({ root = proj })
  ok("fixture: the daemon derives a $KB_ROOT for the store", by_ws.KB_ROOT and by_ws.KB_ROOT.value ~= nil
    and by_ws.KB_ROOT.value ~= "", vim.inspect(by_ws.KB_ROOT))
  for _, n in ipairs({ "KB_ROOT", "HOME" }) do
    local w = by_ws[n] and by_ws[n].value
    ok("$" .. n .. ": the workspace route, the folder route, workspace.vars and Lua agree",
      w ~= nil and w == (by_root[n] and by_root[n].value) and w == (ws_table("kb")[n] or {}).value
        and vars.get(n) == w,
      ("workspace=%s folder=%s lua=%s"):format(tostring(w), tostring(by_root[n] and by_root[n].value),
        tostring(vars.get(n))))
  end
  ok("$WORKSPACE is not derived (§2.6): unresolved for the daemon and for Lua",
    (by_ws.WORKSPACE or {}).value == nil and vars.get("WORKSPACE") == nil
      and vars.resolve_path("$WORKSPACE/docs/legacy.md").unresolved == true,
    vim.inspect({ by_ws.WORKSPACE, vars.get("WORKSPACE") }))
  ok("… nor a built-in for Lua", not vars.is_builtin("WORKSPACE") and not vars.is_builtin("PROJECT_ROOT"))
  local ref = "$KB_ROOT/adrs/x.md"
  ok("Lua resolves a ref to the daemon's value", vars.resolve_path(ref).path == by_ws.KB_ROOT.value .. "/adrs/x.md",
    vars.resolve_path(ref).path)

  local sent = {}
  daemon._set_transport(function(method, params, cb)
    sent[#sent + 1] = { method = method, params = vim.deepcopy(params) }
    daemon._real_request(method, params, cb)
  end)
  where.reset()
  ensure()
  daemon._set_transport(nil)
  local open_params
  for _, c in ipairs(sent) do if c.method == "todos.open" then open_params = c.params end end
  ok("todos.open sends no kb_root", open_params and #open_params == 1, vim.inspect(open_params))

  -- this machine's value: a DB row, the KB's file untouched
  local kbfile = kb .. "/.autodoc-vars.toml"
  local okv, verr = vars.set("COREVAR", proj)
  ok("vars.set answers true", okv == true, verr)
  local cv = ws_table("kb").COREVAR
  ok("the daemon has it, for this machine", cv and cv.value == proj and cv.source == "machine", vim.inspect(cv))
  ok("… and the KB's file does not", not (env.exists(kbfile) and env.read(kbfile):find("COREVAR", 1, true)))
  ok("… and the folder route sees it too", (table_of({ root = proj }).COREVAR or {}).value == proj)
  ok("… and so does Lua", vars.get("COREVAR") == proj)
  ok("vars.remove clears it", vars.remove("COREVAR") == true and (ws_table("kb").COREVAR or {}).value == nil)

  -- the KB's value: relative to the KB root, in its file, carried by git
  vim.fn.mkdir(kb .. "/sub", "p")
  okv, verr = vars.set("RELVAR", kb .. "/sub", { scope = "kb" })
  ok("vars.set scope kb answers true", okv == true, verr)
  ok("… the KB's file holds it relative to the KB root",
    env.exists(kbfile) and env.read(kbfile):find("RELVAR", 1, true) ~= nil
      and not env.read(kbfile):find(kb .. "/sub", 1, true), env.exists(kbfile) and env.read(kbfile))
  ok("… and it resolves absolute", vars.get("RELVAR") == by_ws.KB_ROOT.value .. "/sub", vars.get("RELVAR"))
  ok("vars.remove clears it from the file (gone with its last value, or without the name)",
    vars.remove("RELVAR") == true and not (env.exists(kbfile) and env.read(kbfile):find("RELVAR", 1, true)))
  -- machine_only: the name declared in the KB's file, its value this machine's
  okv, verr = vars.set("MONLY", env.tmp .. "/monly", { machine_only = true })
  ok("vars.set machine_only answers true", okv == true, verr)
  ok("… the KB's file declares the name machine-only, without its value",
    env.read(kbfile):find("MONLY", 1, true) ~= nil and not env.read(kbfile):find(env.tmp .. "/monly", 1, true),
    env.read(kbfile))
  vars.remove("MONLY")

  -- $PROJECT_ROOT is a user variable: set, it symbolizes; $WORKSPACE never does
  local legacy = proj .. "/docs/legacy.md"
  ok("unset, a project path is not symbolized to $WORKSPACE", vars.symbolize_path(legacy) == legacy,
    vars.symbolize_path(legacy))
  okv, verr = vars.set("PROJECT_ROOT", proj)
  ok("$PROJECT_ROOT can be set (not a built-in)", okv == true, verr)
  ok("… and a project path symbolizes to it", vars.symbolize_path(legacy) == "$PROJECT_ROOT/docs/legacy.md",
    vars.symbolize_path(legacy))
  vars.remove("PROJECT_ROOT")

  -- a file of another workspace resolves with ITS variables, whichever store is the session's (§2.5)
  local kb2 = env.new_kb("kb2")
  local note2 = kb2 .. "/notes/n.md"
  env.write(note2, "# n\n")
  local _, w2err = env.call("workspace.add", { "kb2", kb2 })
  ok("fixture: workspace kb2 added", w2err == nil, w2err and w2err.message)
  local _, s1 = env.call("workspace.set_var", { "kb", "SHARED", env.tmp .. "/from-kb", { scope = "machine" } })
  local _, s2 = env.call("workspace.set_var", { "kb2", "SHARED", env.tmp .. "/from-kb2", { scope = "machine" } })
  ok("fixture: SHARED set apart in each workspace", s1 == nil and s2 == nil, vim.inspect({ s1, s2 }))
  vars._reset_for_tests()
  local kb2_root = (ws_table("kb2").KB_ROOT or {}).value
  ok("a kb2 file's $KB_ROOT is kb2's, not the session's",
    kb2_root ~= nil and vars.get("KB_ROOT", { from = note2 }) == kb2_root and vars.get("KB_ROOT") == by_ws.KB_ROOT.value,
    ("kb2=%s from=%s session=%s"):format(tostring(kb2_root), tostring(vars.get("KB_ROOT", { from = note2 })),
      tostring(vars.get("KB_ROOT"))))
  ok("… and its refs resolve with kb2's values",
    vars.resolve_path("$SHARED/x.md", { from = note2 }).path == env.tmp .. "/from-kb2/x.md"
      and vars.resolve_path("$SHARED/x.md").path == env.tmp .. "/from-kb/x.md",
    vars.resolve_path("$SHARED/x.md", { from = note2 }).path)
  ok("… vars.workspace names kb2 for it", vars.workspace({ from = note2 }) == "kb2", vars.workspace({ from = note2 }))
  local outside = env.tmp .. "/elsewhere/f.md"
  env.write(outside, "x\n")
  ok("a file no workspace owns has no $KB_ROOT, and no workspace's values",
    vars.get("KB_ROOT", { from = outside }) == nil and vars.resolve_path("$SHARED/x", { from = outside }).unresolved,
    tostring(vars.get("KB_ROOT", { from = outside })))

  -- a daemon older than protocol 24: workspace.of refused, the session store's table answers, once asked
  vars._reset_for_tests()
  local asked = 0
  daemon._set_transport(function(method, params, cb)
    if method == "workspace.of" then
      asked = asked + 1
      return cb(nil, { code = -32601, message = "the verb is unknown" })
    end
    daemon._real_request(method, params, cb)
  end)
  local old = vars.get("KB_ROOT", { from = note2 })
  vars.get("KB_ROOT", { from = outside })
  daemon._set_transport(nil)
  ok("an old daemon: a from reads the session store's table", old == by_ws.KB_ROOT.value, tostring(old))
  ok("… and workspace.of is not asked again", asked == 1, asked)
  env.call("workspace.set_var", { "kb", "SHARED", "", { scope = "machine" } })
  env.call("workspace.set_var", { "kb2", "SHARED", "", { scope = "machine" } })
  vars._reset_for_tests()

  -- ~ is the workspace's $HOME: an override in the KB's file moves it for the daemon and for Lua alike
  local home = env.tmp .. "/home-override"
  vim.fn.mkdir(home, "p")
  local _, herr = env.call("todos.set_var", { "HOME", home, { at = "kb", scope = "store" } })
  ok("fixture: the KB overrides $HOME", herr == nil, herr and herr.message)
  vars._reset_for_tests()
  ok("Lua reads ~ under the KB's $HOME", vars.resolve_path("~/no-such.md").path == home .. "/no-such.md",
    vars.resolve_path("~/no-such.md").path)
  local t = todo.add({ id = "2026-10-02-home-ref", title = "A ~ ref", adr = { "~/no-such.md" } })
  ok("fixture: the task was added", t ~= nil)
  env.call("todos.refresh", { "kb" })
  local got = env.call("todos.get", { "kb", "2026-10-02-home-ref" }) or {}
  local msg = ""
  for _, e in ipairs(got.errors or {}) do msg = msg .. tostring(e.message) end
  local daemon_path = msg:match("resolved: ([^)]+)%)")
  ok("the daemon resolved the same ref to the same path",
    daemon_path ~= nil and daemon_path == vars.resolve_path((got.adr or {})[1] or "").path,
    ("daemon=%s lua=%s ref=%s"):format(tostring(daemon_path), vars.resolve_path((got.adr or {})[1] or "").path,
      tostring((got.adr or {})[1])))
  ok("… under the overridden $HOME", daemon_path == home .. "/no-such.md", daemon_path)
  env.call("todos.set_var", { "HOME", "", { at = "kb", scope = "store" } })
  vars._reset_for_tests()
end)

env.finish()
