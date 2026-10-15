-- tests/todo-daemon-env.lua — the shared fixture of the suites that run
-- auto-core's todo surface (where, daemon, buffers, notifier) against a REAL
-- AutoDoc daemon (ADR 1791532020).
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
  for _, d in ipairs({ "run", "state", "data" }) do vim.fn.mkdir(M.tmp .. "/autodoc/" .. d, "p") end
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

---task_text is a valid task file, as v0.3.3's Lua writer rendered it (schema
---v1: frontmatter in FRONTMATTER_ORDER, then `# title`). Written literally: the
---Lua encoder went with the shim (v0.4.1), and AutoDoc reads a file as it is.
function M.task_text(fields)
  local t = vim.tbl_extend("force", {
    version = 1, status = "open",
    created = "2026-10-01T10:00:00+00:00",
    updated = "2026-10-01T10:00:00+00:00",
    status_changed = "2026-10-01T10:00:00+00:00",
  }, fields)
  local order = { "id", "version", "status", "title", "priority", "assignee", "due", "tags", "adr",
    "review", "blocked", "created", "updated", "status_changed", "completed_at", "archived_at" }
  local lines = { "---" }
  for _, k in ipairs(order) do
    local v = t[k]
    if type(v) == "table" then
      if #v > 0 then
        lines[#lines + 1] = k .. ":"
        for _, item in ipairs(v) do lines[#lines + 1] = "  - " .. string.format("%q", item) end
      end
    elseif v ~= nil then
      local text = tostring(v)
      if type(v) == "string" and (text:find("[:#$]") or text:match("^%d")) then text = string.format("%q", text) end
      lines[#lines + 1] = k .. ": " .. text
    end
  end
  lines[#lines + 1] = "---"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "# " .. tostring(t.title)
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

---client is the suites' synchronous todo client: the few calls a fixture needs,
---each one or two daemon verbs, through auto-core's door (daemon.rpc, so the
---suites' transport spies see them) and its store resolution (where.ensure,
---which claims the store the first time). It holds no rule of its own: the
---direct clients (auto-finder, auto-agents) are what this stands in for.
function M.client()
  local daemon = require("auto-core.todo.daemon")
  local where = require("auto-core.todo.where")
  local C = {}
  local function op(fn)
    return daemon.sync(function() return fn(where.ensure(where.root())) end)
  end
  local function rpc(verb, params)
    local r, e = daemon.rpc(verb, params)
    if e then daemon.fail(e) end
    return r
  end
  local function decorate(c, t)
    if type(t) == "table" and type(t.path) == "string" then t.file_path = c.store .. "/" .. t.path end
    return t
  end
  local function poke() pcall(function() require("auto-core.todo.notifier").poll_soon() end) end
  function C.get(id)
    local ok, t = op(function(c) return decorate(c, rpc("todos.get", { c.at, id })) end)
    if not ok then return nil, t end
    return t
  end
  function C.list(opts)
    local ok, out = op(function(c)
      local params = { c.at }
      if opts and opts.status then params[2] = { buckets = { opts.status } } end
      local l, e = daemon.rpc("todos.list", params)
      local o = {}
      if e and e.code == daemon.NOT_A_STORE then return o end
      if e then daemon.fail(e) end
      for _, t in ipairs(daemon.list_of(l and l.tasks)) do o[#o + 1] = decorate(c, t) end
      return o
    end)
    if not ok then error(out, 0) end
    return out
  end
  function C.add(spec)
    local ok, t = op(function(c)
      local task, e = daemon.rpc("todos.add", { c.at, spec })
      if e and e.code == daemon.NOT_A_STORE then
        rpc("todos.scaffold", { c.at })
        task, e = daemon.rpc("todos.add", { c.at, spec })
      end
      if e then daemon.fail(e) end
      return decorate(c, task)
    end)
    if not ok then error(t, 0) end
    if spec.assignee then poke() end
    return t.id
  end
  local function mutate(verb, id, ...)
    local extra = { ... }
    local ok, t = op(function(c)
      local cur = rpc("todos.get", { c.at, id })
      local params = { c.at, id, cur.rev }
      for i = 1, #extra do params[#params + 1] = extra[i] end
      return decorate(c, rpc("todos." .. verb, params))
    end)
    if not ok then return nil, t end
    return t
  end
  function C.update(id, patch) return mutate("update", id, patch) end
  function C.status(id, new) return mutate("status", id, new) end
  function C.assign(id, who, reason)
    local t, e = mutate("assign", id, who or "", reason)
    if t and who and who ~= "" then poke() end
    return t, e
  end
  function C.remove(id) return mutate("remove", id) end
  function C.refresh()
    local ok, s = op(function(c)
      local r, e = daemon.rpc("todos.refresh", { c.at })
      if e and e.code == daemon.NOT_A_STORE then return {} end
      if e then daemon.fail(e) end
      return r or {}
    end)
    if not ok then error(s, 0) end
    return s
  end
  return C
end

---new_kb makes a KB workspace with a store, and a project root whose Lua
---override points at it (the global KB's shape: nvim-plugins → the KB store).
function M.new_kb(name)
  local kb = M.tmp .. "/" .. name
  for _, b in ipairs({ "open", "in-progress", "deferred", "completed", "archived" }) do
    vim.fn.mkdir(kb .. "/.todo-list/" .. b, "p")
  end
  -- a KB's AGENTS.md says so in its frontmatter: AutoDoc derives a store's $KB_ROOT
  -- from it (ADR 1792015069 §2.2), and a project's plain AGENTS.md is no KB
  M.write(kb .. "/AGENTS.md", "---\ntype: kb\n---\n\n# KB\n")
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
