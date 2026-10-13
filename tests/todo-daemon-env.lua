-- tests/todo-daemon-env.lua — the shared fixture of the suites that run
-- auto-core.todo against a REAL AutoDoc daemon (ADR 1791532020).
--
--   AUTOCORE_TEST_AUTODOC      an autodoc checkout (its lua/ is autodoc.nvim)
--   AUTOCORE_TEST_AUTODOC_BIN  an autodoc binary built from it (protocol >= 20)
--
-- The daemon is this suite's own: its config names a socket, a state dir and a
-- data dir under a temp root, so nothing reaches a live store. tests/todo-daemon.sh
-- also gives the nvim process its own HOME and XDG dirs.
local M = {}

M.plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(M.plugin_root)
vim.o.swapfile = false

M.autodoc = os.getenv("AUTOCORE_TEST_AUTODOC")
M.bin = os.getenv("AUTOCORE_TEST_AUTODOC_BIN")
if M.autodoc and M.autodoc ~= "" then vim.opt.runtimepath:prepend(M.autodoc) end

local pass, fail = 0, 0
function M.ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail ~= nil and ("  — " .. tostring(detail)) or ""))
  io.stdout:write((line:gsub("[\r\n]+", " ")), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end
function M.section(title) io.stdout:write("\n", title, "\n"); io.stdout:flush() end
function M.run(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then M.ok(name .. " (raised)", false, err) end
end
function M.finish()
  io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
  pcall(function() require("auto-core.todo.notifier").stop() end)
  os.exit(fail == 0 and 0 or 1)
end

function M.realpath(p) return vim.uv.fs_realpath(p) or p end
function M.read(p)
  local f = io.open(p, "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end
function M.write(p, s)
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local f = assert(io.open(p, "w")); f:write(s); f:close()
end
function M.exists(p) return vim.uv.fs_stat(p) ~= nil end
function M.wait(ms, cond) return vim.wait(ms, cond, 20) end

M.tmp = M.realpath(vim.fn.tempname()) .. "-todo"
vim.fn.mkdir(M.tmp, "p")
M.tmp = M.realpath(M.tmp)

---require_daemon stops the suite with a clear failure when the env is missing.
function M.require_daemon()
  if not (M.autodoc and M.bin and M.autodoc ~= "" and M.bin ~= "") then
    M.ok("AUTOCORE_TEST_AUTODOC and AUTOCORE_TEST_AUTODOC_BIN are set (run tests/todo-daemon.sh)", false)
    M.finish()
  end
end

---start_daemon sets autodoc.nvim up against this suite's own daemon.
function M.start_daemon()
  local cfg = M.tmp .. "/autodoc/config.toml"
  M.write(cfg, table.concat({
    "[server]",
    string.format("socket = %q", M.tmp .. "/autodoc/run/autodoc.sock"),
    string.format("state_dir = %q", M.tmp .. "/autodoc/state"),
    string.format("data_dir = %q", M.tmp .. "/autodoc/data"),
  }, "\n") .. "\n")
  require("autodoc").setup({ bin = M.bin, config = cfg, preview = false,
    offer_restart = false, offer_link = false })
end

---call is one daemon verb, synchronous (the test's own path, not the shim's).
function M.call(method, params)
  local session = require("autodoc.session")
  local done, res, err = false, nil, nil
  session.call(method, params or {}, function(r, e) res, err, done = r, e, true end)
  vim.wait(20000, function() return done end, 20)
  if not done then return nil, { message = "timed out" } end
  return require("auto-core.todo.daemon").normalize(res), err
end

---task_text is a valid task file, rendered by auto-core's own encoder (a fixture
---as v0.3.3 would have written it).
function M.task_text(fields)
  local schema = require("auto-core.todo.schema")
  local md = require("auto-core.todo.md")
  local t = schema.blank(vim.tbl_extend("force", {
    created = "2026-10-01T10:00:00+00:00",
    updated = "2026-10-01T10:00:00+00:00",
    status_changed = "2026-10-01T10:00:00+00:00",
  }, fields))
  return md.encode(t)
end

---new_kb makes a KB workspace with a store, and a project root whose Lua
---override points at it (the global KB's shape: nvim-plugins → the KB store).
function M.new_kb(name)
  local kb = M.tmp .. "/" .. name
  for _, b in ipairs({ "open", "in-progress", "deferred", "completed", "archived" }) do
    vim.fn.mkdir(kb .. "/.todo-list/" .. b, "p")
  end
  M.write(kb .. "/AGENTS.md", "# KB\n")
  return kb
end

---set_project points auto-core at a project root with a Lua override.
function M.set_project(root, override)
  vim.fn.mkdir(root, "p")
  require("auto-core.git.worktree").set_workspace_root(root)
  local ns = require("auto-core.state").namespace("todo", { persist = "json" })
  local o = vim.deepcopy(ns:get("dir_overrides") or {})
  o[root] = override
  ns:set("dir_overrides", o)
  require("auto-core.todo.where").reset()
end

return M
