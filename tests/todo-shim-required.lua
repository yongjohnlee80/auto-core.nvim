-- tests/todo-shim-required.lua — auto-core.todo without AutoDoc (ADR 1791532020
-- §4: AutoDoc is required, and there is no Lua fallback).
--
-- autodoc.nvim is NOT on the runtimepath here. Every function answers "AutoDoc
-- required", the user is told once, and nothing on disk changes. A daemon that
-- never answers is a bounded error, never a hang. No daemon is needed, so this
-- suite runs in tests/run-all.sh.
--
-- Run: nvim --headless -u NONE -l tests/todo-shim-required.lua
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail ~= nil and ("  — " .. tostring(detail)) or ""))
  io.stdout:write((line:gsub("[\r\n]+", " ")), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end
local function section(t) io.stdout:write("\n", t, "\n"); io.stdout:flush() end

-- Sandbox auto-core's state: this suite must not touch the developer's.
local state_tmp = vim.fn.tempname() .. "-state"
vim.fn.mkdir(state_tmp, "p")
require("auto-core.state").configure({ persist_dir = state_tmp })

local todo   = require("auto-core.todo")
local daemon = require("auto-core.todo.daemon")

ok("autodoc.nvim is not loadable here", not pcall(require, "autodoc.todos"))

-- A store as v0.3.3 left it.
local root = vim.fn.tempname() .. "-proj"
local store = root .. "/.todo-list"
vim.fn.mkdir(store .. "/open", "p")
local task = require("auto-core.todo.md").encode(require("auto-core.todo.schema").blank({
  id = "2026-10-01-keep", title = "Keep me" }))
local f = assert(io.open(store .. "/open/2026-10-01-keep.md", "w")); f:write(task); f:close()
require("auto-core.git.worktree").set_workspace_root(root)

local function snapshot()
  local out = {}
  for _, p in ipairs(vim.fn.globpath(root, "**", true, true)) do
    local st = vim.uv.fs_stat(p)
    out[p] = st and (st.type .. ":" .. st.size .. ":" .. st.mtime.sec .. ":" .. st.mtime.nsec) or "?"
  end
  return out
end
local before = snapshot()

-- Count the toasts (log.notify → vim.notify).
local toasts = {}
local real_notify = vim.notify
vim.notify = function(msg, level, opts) toasts[#toasts + 1] = tostring(msg); return real_notify(msg, level, opts) end

local function has_required(s) return tostring(s):find("AutoDoc required", 1, true) ~= nil end

section("every function answers \"AutoDoc required\"")
local okl, lerr = pcall(todo.list)
ok("list raises it", not okl and has_required(lerr), lerr)
local oks, serr = pcall(todo.scan)
ok("scan raises it", not oks and has_required(serr), serr)
local t, gerr = todo.get("2026-10-01-keep")
ok("get answers (nil, it)", t == nil and has_required(gerr), gerr)
local oka, aerr = pcall(todo.add, { title = "Never written" })
ok("add raises it", not oka and has_required(aerr), aerr)
local u, uerr = todo.update("2026-10-01-keep", { priority = "high" })
ok("update answers (nil, it)", u == nil and has_required(uerr), uerr)
local st, sterr = todo.status("2026-10-01-keep", "completed")
ok("status answers (nil, it)", st == nil and has_required(sterr), sterr)
local as, aserr = todo.assign("2026-10-01-keep", "agent:x", "go")
ok("assign answers (nil, it)", as == nil and has_required(aserr), aserr)
local rm, rmerr = todo.remove("2026-10-01-keep")
ok("remove answers (false, it)", rm == false and has_required(rmerr), rmerr)
local rmm, rmmerr = todo.remove_malformed(store .. "/open/2026-10-01-keep.md")
ok("remove_malformed answers (false, it)", rmm == false and has_required(rmmerr), rmmerr)
local okr, rerr = pcall(todo.refresh)
ok("refresh raises it", not okr and has_required(rerr), rerr)
local okk, kerr = pcall(todo.known_dirs)
ok("known_dirs raises it", not okk and has_required(kerr), kerr)
local okd, derr = pcall(todo.set_todo_dir, root .. "/elsewhere")
ok("set_todo_dir raises it", not okd and has_required(derr), derr)
local done, dres, ddone_err = false, nil, nil
todo.scan_async(function(r, d, e) done, dres, ddone_err = d, r, e end)
ok("scan_async answers nothing before it returns", done == false)
vim.wait(2000, function() return done end, 10)
ok("scan_async answers (nil, true, it)", done == true and dres == nil and has_required(ddone_err), ddone_err)

section("get_todo_dir still answers, without the daemon")
ok("get_todo_dir is the directory Lua resolves", todo.get_todo_dir() == store, todo.get_todo_dir())

section("nothing on disk changed; the user was told once")
vim.wait(300, function() return false end, 10)
ok("no file was created, changed or removed", vim.deep_equal(before, snapshot()))
local n = 0
for _, m in ipairs(toasts) do if has_required(m) then n = n + 1 end end
ok("one \"AutoDoc required\" notice for the session", n == 1, n)

section("a daemon that never answers is a bounded error")
daemon._set_transport(function() end) -- accepts every request, answers none
daemon.WAIT_MS = 300
local t0 = vim.uv.hrtime()
local nt, nerr = todo.get("2026-10-01-keep")
local ms = (vim.uv.hrtime() - t0) / 1e6
ok("get answers \"did not answer\"", nt == nil and tostring(nerr):find("did not answer", 1, true), nerr)
ok("… within the deadline", ms < 2000, ms)
daemon._set_transport(nil)
daemon.WAIT_MS = 15000

section("never from a fast event")
local fast_err
local timer = vim.uv.new_timer()
timer:start(1, 0, function()
  local _, e = todo.get("2026-10-01-keep")
  fast_err = e or "no error"
  timer:close()
end)
vim.wait(2000, function() return fast_err ~= nil end, 10)
ok("a call in a fast event is refused by the shim's own guard, before any work",
  tostring(fast_err):find("auto-core.todo: called from a fast event", 1, true), fast_err)

section("the removed surfaces refuse")
local oki, ierr = pcall(todo.import, "/x", {})
ok("import is refused (D3)", not oki and tostring(ierr):find("D3", 1, true), ierr)
local automation = require("auto-core.todo.automation")
local fr, ferr = automation.fire("2026-10-01-keep")
ok("automation.fire refuses", fr == nil and tostring(ferr):find("automation was removed", 1, true), ferr)
automation.start()
ok("automation.start starts nothing", automation.list_pending().running == false)
local okv = todo.vars.set("REQ_VAR", root)
ok("vars.set still works on the Neovim side", okv == true and todo.vars.get("REQ_VAR") == root)

section("the notifier stays off without AutoDoc")
local notifier = require("auto-core.todo.notifier")
notifier.start()
notifier._connect()
vim.wait(200, function() return false end, 10)
ok("it starts (as the mailbox router does) and asks nothing", notifier.is_running())
notifier.stop()

vim.notify = real_notify
vim.fn.delete(root, "rf")
vim.fn.delete(state_tmp, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
os.exit(fail == 0 and 0 or 1)
