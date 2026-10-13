-- tests/todo-cutover-rehearsal.lua — one phase of the cutover rehearsal (design
-- note 2026-10-13 §7.1), driven by tests/todo-cutover-rehearsal.sh on a COPY of a
-- store. Never point it at a live store.
--
--   nvim --headless -u NONE -l tests/todo-cutover-rehearsal.lua <phase>
--
-- Env: REH_ROOT (the scratch root: kb/, nvim-plugins/, mailbox/, out/),
-- REH_AUTOCORE (the auto-core tree this phase runs: v0.3.3 or the candidate),
-- AUTOCORE_TEST_AUTODOC(_BIN) for the daemon phases. Each phase prints
-- "REH key=value" lines the script checks, then "<P> passed, <F> failed".
local phase = arg and arg[1] or "?"
local R = assert(os.getenv("REH_ROOT"), "REH_ROOT")
local AC = assert(os.getenv("REH_AUTOCORE"), "REH_AUTOCORE")
vim.opt.runtimepath:prepend(AC)
vim.o.swapfile = false
local AD, BIN = os.getenv("AUTOCORE_TEST_AUTODOC"), os.getenv("AUTOCORE_TEST_AUTODOC_BIN")
if AD and AD ~= "" then vim.opt.runtimepath:prepend(AD) end

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail ~= nil and ("  — " .. tostring(detail)) or ""))
  io.stdout:write((line:gsub("[\r\n]+", " ")), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end
local function out(k, v) io.stdout:write("REH ", k, "=", tostring(v), "\n"); io.stdout:flush() end
local function finish()
  pcall(function() require("auto-core.state").namespace("todo", { persist = "json" }):persist_now() end)
  pcall(function() require("auto-core.todo.notifier").stop() end)
  io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
  os.exit(fail == 0 and 0 or 1)
end

local KB = R .. "/kb"
local STORE = KB .. "/.todo-list"
local PROJ = R .. "/nvim-plugins"
local MB = R .. "/mailbox"
local INSTANCE = "1700000000-4242"

require("auto-core.git.worktree").set_workspace_root(PROJ)
local ns = require("auto-core.state").namespace("todo", { persist = "json" })
ns:set("dir_overrides", { [PROJ] = STORE })

local function call(method, params)
  local session = require("autodoc.session")
  local done, res, err = false, nil, nil
  session.call(method, params or {}, function(r, e) res, err, done = r, e, true end)
  vim.wait(30000, function() return done end, 20)
  if not done then return nil, { message = "timed out" } end
  return res, err
end

local function start_daemon()
  local cfg = R .. "/autodoc/config.toml"
  for _, d in ipairs({ "state", "data" }) do vim.fn.mkdir(R .. "/autodoc/" .. d, "p") end
  local f = assert(io.open(cfg, "w"))
  f:write(table.concat({ "[server]",
    string.format("socket = %q", R .. "/autodoc/autodoc.sock"),
    string.format("state_dir = %q", R .. "/autodoc/state"),
    string.format("data_dir = %q", R .. "/autodoc/data") }, "\n") .. "\n")
  f:close()
  require("autodoc").setup({ bin = BIN, config = cfg, preview = false, offer_restart = false, offer_link = false })
  local list = call("workspace.list", {})
  local have = false
  for _, w in ipairs(type(list) == "table" and list or {}) do if w.name == "kb" then have = true end end
  if not have then
    local _, err = call("workspace.add", { "kb", KB })
    ok("the KB copy is a workspace", err == nil, err and err.message)
  end
end

local function mailbox(instance)
  local mb = require("auto-core.mailbox")
  mb.path.configure(MB)
  mb.path.set_instance_id(instance)
  local reg = require("auto-core.mailbox.registry")
  reg.register("nvim", { root = MB })
  return reg.register("agent:lector", { root = MB })
end

if phase == "old-scan" then
  -- v0.3.3, before the cutover: what Lua sees (it writes nothing on a scan).
  local todo = require("auto-core.todo")
  local s = todo.scan()
  local by = {}
  for _, t in ipairs(s.tasks) do by[t.status] = (by[t.status] or 0) + 1 end
  out("lua_tasks", #s.tasks)
  out("lua_malformed", #s.malformed)
  for k, v in pairs(by) do out("lua_" .. k, v) end
  local names = {}
  for _, m in ipairs(s.malformed) do names[#names + 1] = m.filename end
  table.sort(names)
  out("lua_malformed_files", table.concat(names, ","))
  ok("v0.3.3 scanned the copy", #s.tasks > 0)
  finish()
end

if phase == "claim" then
  start_daemon()
  local r0 = call("todos.resolve", { "kb" })
  ok("unclaimed before the first call", r0 and r0.claimed == false, vim.inspect(r0))
  local todo = require("auto-core.todo")
  local t0 = vim.uv.hrtime()
  local open = todo.list({ status = "open" })
  out("first_call_ms", math.floor((vim.uv.hrtime() - t0) / 1e6))
  local r = call("todos.resolve", { "kb" })
  ok("claimed by the first call", r and r.claimed == true, vim.inspect(r))
  ok("the marker exists", vim.uv.fs_stat(STORE .. "/.autodoc-owner") ~= nil)
  out("store_id", r and r.store_id)
  local by = {}
  local s = todo.scan()
  for _, t in ipairs(s.tasks) do by[t.status] = (by[t.status] or 0) + 1 end
  out("daemon_tasks", #s.tasks)
  out("daemon_malformed", #s.malformed)
  for k, v in pairs(by) do out("daemon_" .. k, v) end
  local names = {}
  for _, m in ipairs(s.malformed) do names[#names + 1] = m.filename .. "[" .. m.err .. "]" end
  table.sort(names)
  out("daemon_malformed_files", table.concat(names, ","))
  local months = call("todos.list", { "kb", { buckets = { "archived" } } })
  local sum = 0
  for _, p in ipairs(months and months.partitions or {}) do sum = sum + (p.files or p.count or 0) end
  out("archive_month_files", sum)
  out("open", #open)
  finish()
end

if phase == "assign-crash" or phase == "assign-resume" then
  start_daemon()
  local lector = mailbox(INSTANCE)
  local todo = require("auto-core.todo")
  local notifier = require("auto-core.todo.notifier")
  local daemon = require("auto-core.todo.daemon")
  notifier._configure({ poll_ms = false, watermark_path = R .. "/state-notifier.json" })
  if phase == "assign-crash" then
    -- the ack never reaches the daemon: this Neovim dies right after the send
    local armed = false
    daemon._set_transport(function(method, params, cb)
      if method == "todos.ack" and armed then
        local files = vim.fn.glob(lector.subs.inbox .. "/todo-*.json", false, true)
        out("crash_inbox_files", #files)
        out("crash_inbox_ids", table.concat(vim.tbl_map(function(p) return vim.fn.fnamemodify(p, ":t:r") end, files), ","))
        io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
        os.exit(fail == 0 and 0 or 1)
      end
      daemon._real_request(method, params, cb)
    end)
    notifier.start()
    local first = false
    notifier.poll_all(function() first = true end) -- the baseline poll, before the assignment
    vim.wait(20000, function() return first end, 50)
    armed = true
    local id = todo.list({ status = "open" })[1].id
    out("assigned_id", id)
    local t, err = todo.assign(id, "agent:lector", "rehearsal: the cutover assignment")
    ok("the assignment landed", t and t.status == "in-progress", err)
    vim.wait(20000, function() return false end, 50) -- the ack's os.exit ends this phase
    ok("the notifier sent and tried to ack", false, "no ack happened")
    finish()
  else
    -- the same Neovim instance again: its cursor never moved
    notifier.start()
    local finished = false
    notifier.poll_all(function() finished = true end)
    vim.wait(20000, function() return finished end, 50)
    local files = vim.fn.glob(lector.subs.inbox .. "/todo-*.json", false, true)
    out("resume_inbox_files", #files)
    out("resume_inbox_ids", table.concat(vim.tbl_map(function(p) return vim.fn.fnamemodify(p, ":t:r") end, files), ","))
    local r = call("todos.resolve", { "kb" })
    local page = call("todos.changes", { "kb", notifier.consumer(), 1000 })
    local left = 0
    for _, c in ipairs(page and type(page.changes) == "table" and page.changes or {}) do
      if c.kind == "assign" then left = left + 1 end
    end
    out("unacked_assigns_after_resume", left)
    ok("the store is still claimed", r and r.claimed == true)
    finish()
  end
end

if phase == "release" then
  start_daemon()
  local todo = require("auto-core.todo")
  local okr, err = todo.release()
  ok("release", okr == true, err)
  ok("the marker is gone", vim.uv.fs_stat(STORE .. "/.autodoc-owner") == nil)
  local okadd, aerr = pcall(todo.add, { title = "Rehearsal: refused after release" })
  ok("a write through the shim answers todos.unclaimed", not okadd
    and tostring(aerr):find("todos.unclaimed", 1, true), aerr)
  require("auto-core.todo.where").reset()
  local _ = todo.list({ status = "open" })
  local r = call("todos.resolve", { "kb" })
  ok("the shim did not claim it again", r and r.claimed == false, vim.inspect(r))
  finish()
end

if phase == "old-write" then
  -- v0.3.3 restored: Lua writes again, the daemon only reads.
  start_daemon()
  local todo = require("auto-core.todo")
  local okadd, id = pcall(todo.add, { title = "Rehearsal: v0.3.3 writes again" })
  ok("v0.3.3 add writes the copy", okadd and vim.uv.fs_stat(STORE .. "/open/" .. id .. ".md") ~= nil, id)
  local _, err = call("todos.add", { "kb", { title = "Rehearsal: daemon refused" } })
  ok("the daemon refuses its own write (-32077)", err and err.code == -32077, vim.inspect(err))
  finish()
end

ok("known phase", false, phase)
finish()
