-- tests/todo-where-required.lua — auto-core's todo surface without AutoDoc (ADR
-- 1791532020 §4: AutoDoc is required, and there is no Lua fallback).
--
-- autodoc.nvim is NOT on the runtimepath here. The store resolution answers
-- "AutoDoc required", the commands say so, nothing on disk changes, and the
-- notifier stays idle. A daemon that never answers is a bounded error, never a
-- hang. No daemon is needed, so this suite runs in tests/run-all.sh.
--
-- Run: nvim --headless -u NONE -l tests/todo-where-required.lua
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail ~= nil and ("  — " .. tostring(detail)) or ""))
  io.stdout:write("\n", (line:gsub("[\r\n]+", " ")), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end
local function section(t) io.stdout:write("\n", t, "\n"); io.stdout:flush() end

-- Sandbox auto-core's state: this suite must not touch the developer's.
local state_tmp = vim.fn.tempname() .. "-state"
vim.fn.mkdir(state_tmp, "p")
require("auto-core.state").configure({ persist_dir = state_tmp })

local where  = require("auto-core.todo.where")
local daemon = require("auto-core.todo.daemon")
vim.cmd("runtime! plugin/auto-core.lua")

ok("autodoc.nvim is not loadable here", not pcall(require, "autodoc.todos"))

-- A store as v0.3.3 left it.
local root = vim.fn.tempname() .. "-proj"
local store = root .. "/.todo-list"
vim.fn.mkdir(store .. "/open", "p")
local task = table.concat({ "---", "id: \"2026-10-01-keep\"", "version: 1", "status: open",
  "title: Keep me", "---", "", "# Keep me", "" }, "\n")
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

local toasts = {}
local real_notify = vim.notify
-- Recorded, not passed on: under `nvim -l` an ERROR-level notify inside a
-- :command raises (E5113), and these cells read the message, not the screen.
vim.notify = function(msg) toasts[#toasts + 1] = tostring(msg) end
local function has_required(s) return tostring(s):find("AutoDoc required", 1, true) ~= nil end

section("the forwarding shim is gone")
ok("require(\"auto-core.todo\") fails (removed in v0.4.1)", pcall(require, "auto-core.todo") == false)

section("the store resolution answers \"AutoDoc required\"")
local oke, eerr = daemon.sync(function() return where.ensure(root) end)
ok("where.ensure is an error naming AutoDoc", oke == false and has_required(eerr), eerr)
local okc, cerr = daemon.sync(function() return where.claim(root) end)
ok("where.claim is an error naming AutoDoc", okc == false and has_required(cerr), cerr)
ok("daemon.available() is false", daemon.available() == false)
ok("where.local_dir still answers, without the daemon", where.local_dir(root) == store, where.local_dir(root))

section("the commands say so")
toasts = {}
vim.cmd("AutoCoreTodoRefresh")
ok(":AutoCoreTodoRefresh says AutoDoc is required", (function()
  for _, m in ipairs(toasts) do if has_required(m) then return true end end
end)(), vim.inspect(toasts))
toasts = {}
vim.cmd("AutoCoreTodoClaim")
ok(":AutoCoreTodoClaim says AutoDoc is required", (function()
  for _, m in ipairs(toasts) do if has_required(m) then return true end end
end)(), vim.inspect(toasts))
vim.cmd("edit " .. vim.fn.fnameescape(store .. "/open/2026-10-01-keep.md"))
toasts = {}
vim.cmd("silent write")
vim.wait(200, function() return false end, 10)
ok("saving a task file without AutoDoc asks nothing and says nothing", #toasts == 0, vim.inspect(toasts))
vim.cmd("bwipeout!")

section("nothing on disk changed, except the file the user saved")
local after = snapshot()
local changed = {}
for p, v in pairs(after) do
  if before[p] ~= v and not p:find("2026-10-01-keep.md", 1, true) then changed[#changed + 1] = p end
end
for p in pairs(before) do if after[p] == nil then changed[#changed + 1] = p end end
ok("no other file was created, changed or removed", #changed == 0, vim.inspect(changed))

section("a daemon that never answers is a bounded error")
daemon._set_transport(function() end) -- accepts every request, answers none
local t0 = vim.uv.hrtime()
local okn, nerr = daemon.sync(function() return where.ensure(root) end, 300)
local ms = (vim.uv.hrtime() - t0) / 1e6
ok("ensure answers \"did not answer\"", okn == false and tostring(nerr):find("did not answer", 1, true), nerr)
ok("… within the deadline", ms < 2000, ms)
daemon._set_transport(nil)

section("never from a fast event")
local fast_err
local timer = vim.uv.new_timer()
timer:start(1, 0, function()
  local _, e = daemon.sync(function() return where.ensure(root) end)
  fast_err = e or "no error"
  timer:close()
end)
vim.wait(2000, function() return fast_err ~= nil end, 10)
ok("a sync call in a fast event is refused, before any work",
  tostring(fast_err):find("called from a fast event", 1, true), fast_err)

section("vars work on the Neovim side")
local vars = require("auto-core.todo.vars")
local okv = vars.set("REQ_VAR", root)
ok("vars.set still works", okv == true and vars.get("REQ_VAR") == root)
vars.remove("REQ_VAR")

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
