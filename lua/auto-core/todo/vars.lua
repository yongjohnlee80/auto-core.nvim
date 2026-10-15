---The `$VAR/...` variables of the session project's todo store, and the path
---resolver over them (ADR-0031 variable substitution; ADR 1792015069 §2.5).
---
---A `.todo-list/` is portable: it is synced across machines with git, so a task
---stores the portable form of a ref,
---
---    adr:
---      - $KB_ROOT/adrs/0031-foo.md
---
---…and each machine resolves `$KB_ROOT` to its own KB root. The NAMES are
---wire-format (committed with the store); the VALUES are each machine's.
---
---**AutoDoc's daemon owns the values** (ADR 1792015069 "variables belong to the
---store, not the route"). A store's variables are computed once, from the
---store's location and the `.autodoc-vars.toml` beside it, and answered by
---`todos.vars(at)`, the same from every route to the store. This module asks the
---daemon instead of computing its own: before, it resolved `$KB_ROOT` and
---`$WORKSPACE` from this Neovim's session, and the panel and the daemon read the
---same ref differently.
---
---  • **Built-ins**, derived per store: `$KB_ROOT`, `$WORKSPACE`, `$PROJECT_ROOT`,
---    `$HOME`. `$CWD` is gone: the daemon has no working directory to give it.
---  • **User variables**: the store's file, this machine's values for the store,
---    and the daemon's global vars.
---
---The store is the session project's (`auto-core.todo.where`). Its table is
---cached per store and read again in the background once older than
---`M.FRESH_MS`; a change publishes `core.todo.vars:changed`. Without AutoDoc there
---are no values: `get` answers nil and the reason, as every todo verb answers
---"AutoDoc required" since v0.4.1.
---
---Asking which KB a project uses is a different question, `auto-core.kb.root()`:
---a project's store may lie outside any KB.
---
---@module 'auto-core.todo.vars'

local fs_path = require("auto-core.fs.path")

local M = {}

-- NOTE: staleness bound. The daemon announces no variable change to Neovim (its
-- events go to its own log), so a value set elsewhere (AutoDoc's Variables tab,
-- a hand edit of the store's .autodoc-vars.toml, another Neovim) is seen here
-- within this long: a read of an older table answers it and reads it again in the
-- background.
M.FRESH_MS = 2000

-- ─── built-ins ────────────────────────────────────────────────

---The daemon's built-in variables (autodoc core/todo/vars.go), in its order. A
---value set in the store's file or for this machine overrides the derived one.
---@type { name: string, resolver: fun(): string?, doc: string }[]
M.BUILTINS = {
  { name = "KB_ROOT",
    doc = "The KB the store is in: the nearest directory at or above the store's "
      .. "parent whose AGENTS.md says `type: kb`." },
  { name = "WORKSPACE",
    doc = "The store's home: its parent directory." },
  { name = "PROJECT_ROOT",
    doc = "The project the store serves, from the store's .autodoc-vars.toml." },
  { name = "HOME",
    doc = "The daemon user's home directory." },
}

---@type table<string, true>
local BUILTIN = {}
for _, b in ipairs(M.BUILTINS) do
  BUILTIN[b.name] = true
  b.resolver = function() return M.get(b.name) end
end

---@param name string
---@return boolean
function M.is_builtin(name) return BUILTIN[name] == true end

-- ─── the store's table, from the daemon ───────────────────────

local _cache = {}   -- store id → { at, rows, by, read }
local _reading = {} -- root → true while a background read runs

local function deps()
  local ok_d, daemon = pcall(require, "auto-core.todo.daemon")
  local ok_w, where = pcall(require, "auto-core.todo.where")
  if not (ok_d and ok_w) then return nil end
  return daemon, where
end

local function publish_changed(kind, name)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events and type(events.publish) == "function" then
    pcall(events.publish, "core.todo.vars:changed", { kind = kind, name = name })
  end
end

---fetch reads root's store's table. Runs inside daemon.run; raises on an error.
---@return table entry { at, store_id, rows, by, read }
local function fetch(daemon, where, root)
  local c = where.ensure(root)
  local list, err = daemon.rpc("todos.vars", { c.at })
  if err then daemon.fail(err) end
  local rows, by = {}, {}
  for _, v in ipairs(daemon.list_of(list)) do
    if type(v) == "table" and type(v.name) == "string" then
      local row = {
        name    = v.name,
        value   = (type(v.value) == "string" and v.value ~= "") and v.value or nil,
        builtin = v.builtin == true,
        source  = v.source,
        derived = v.derived,
        machine = v.machine == true,
      }
      for _, b in ipairs(M.BUILTINS) do
        if b.name == v.name then row.doc = b.doc end
      end
      rows[#rows + 1] = row
      by[v.name] = row
    end
  end
  return { at = c.at, store_id = c.store_id, rows = rows, by = by, read = vim.uv.now() }
end

local function same(a, b)
  if not a or #a.rows ~= #b.rows then return false end
  for i, r in ipairs(a.rows) do
    local s = b.rows[i]
    if r.name ~= s.name or r.value ~= s.value or r.source ~= s.source then return false end
  end
  return true
end

---keep caches e and says whether it differs from what was cached.
local function keep(e)
  local changed = not same(_cache[e.store_id], e)
  _cache[e.store_id] = e
  return changed
end

---read_again reads root's store's table in the background, and publishes a change.
local function read_again(daemon, where, root)
  if _reading[root] then return end
  _reading[root] = true
  daemon.run(function() return fetch(daemon, where, root) end, function(ok, e)
    _reading[root] = nil
    if ok and keep(e) then publish_changed("read") end
  end)
end

---table is the session store's variable table, or nil and why.
---@return table|nil entry, string? why
local function table_now()
  local daemon, where = deps()
  if not daemon or not daemon.available() then
    return nil, daemon and daemon.REQUIRED or "auto-core.todo.daemon is unavailable"
  end
  local root = where.root()
  local c = where.cached(root)
  local e = c and _cache[c.store_id]
  if e then
    if vim.uv.now() - e.read > M.FRESH_MS and not vim.in_fast_event() then
      read_again(daemon, where, root)
    end
    return e
  end
  if daemon.in_run() then
    local ok, got = pcall(fetch, daemon, where, root)
    if not ok then return nil, tostring(got) end
    keep(got)
    return got
  end
  local ok, got = daemon.sync(function() return fetch(daemon, where, root) end)
  if not ok then return nil, tostring(got) end
  keep(got)
  return got
end

-- ─── public: get / set / list / remove ────────────────────────

---get is a variable's value for the session's store, or nil (and why, when the
---daemon could not answer). A name the store does not know falls back to
---`vim.env`, as the daemon falls back to its own environment.
---@param name string  without the leading `$`
---@return string? value, string? why
function M.get(name)
  if type(name) ~= "string" or name == "" then return nil end
  local e, why = table_now()
  if not e then return nil, why end
  local row = e.by[name]
  if row then return row.value end
  local env = vim.env[name]
  if type(env) == "string" and env ~= "" then return env end
  return nil
end

---list is the store's variables for display, built-ins first in the daemon's
---order: { name, value, builtin, doc, source, derived, machine }. A variable with
---no value here (a built-in that derives none, a machine-only name not set on this
---machine) has `value = nil`. An empty list and why when the daemon cannot answer.
---@return table[] rows, string? why
function M.list()
  local e, why = table_now()
  if not e then return {}, why end
  return vim.deepcopy(e.rows)
end

local function valid_name(name)
  if type(name) ~= "string" or name == "" then
    return false, "name must be a non-empty string"
  end
  if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
    return false, "name '" .. name .. "' is not a valid shell-style identifier "
      .. "(letters, digits, underscores; must not start with a digit)"
  end
  return true
end

---put sends todos.set_var for the session's store and drops every cached table
---(a global var is every store's).
local function put(name, value, scope)
  local e, why = table_now()
  if not e then return false, why end
  local daemon = deps()
  local opts = { scope = scope }
  if scope ~= "global" then opts.at = e.at end
  local ok, res = daemon.sync(function()
    local _, err = daemon.rpc("todos.set_var", { name, value, opts })
    if err then daemon.fail(err) end
    return true
  end)
  if not ok then return false, tostring(res) end
  _cache = {}
  publish_changed(value == "" and "remove" or "set", name)
  return true
end

---set sets a user variable for the session's store: where its value comes from
---now (the store's file, this machine, or the daemon's global vars); a new name
---for this machine only, so its value never reaches git. Built-ins are read-only
---here (AutoDoc's Variables tab overrides one). An empty value clears it.
---@param name string
---@param value string
---@return boolean ok, string? err
function M.set(name, value)
  local okn, nerr = valid_name(name)
  if not okn then return false, nerr end
  if BUILTIN[name] then
    return false, "'" .. name .. "' is a built-in variable and auto-resolves; "
      .. "override it in AutoDoc's Variables tab"
  end
  if type(value) ~= "string" then return false, "value must be a string" end
  local e, why = table_now()
  if not e then return false, why end
  local row = e.by[name]
  local scope = row and (row.source == "store" or row.source == "global") and row.source
    or "machine"
  return put(name, value, scope)
end

---remove clears a user variable where its value comes from. Built-ins are
---refused; a name with no value set is a no-op.
---@param name string
---@return boolean ok, string? err
function M.remove(name)
  local okn, nerr = valid_name(name)
  if not okn then return false, nerr end
  if BUILTIN[name] then
    return false, "'" .. name .. "' is a built-in variable and cannot be removed"
  end
  local e, why = table_now()
  if not e then return false, why end
  local row = e.by[name]
  local scope = row and row.value and row.source
  if scope ~= "store" and scope ~= "global" and scope ~= "machine" then return true end
  return put(name, "", scope)
end

-- ─── public: resolve_path ─────────────────────────────────────

---split_var_prefix splits `$VAR/rest` or `${VAR}/rest` into (VAR, rest).
---@param input string
---@return string? var_name, string? rest
local function split_var_prefix(input)
  if type(input) ~= "string" or input:sub(1, 1) ~= "$" then return nil, nil end
  local brace_name, brace_rest = input:match("^%${([A-Za-z_][A-Za-z0-9_]*)}(.*)$")
  if brace_name then return brace_name, brace_rest end
  local name, rest = input:match("^%$([A-Za-z_][A-Za-z0-9_]*)(.*)$")
  if name then return name, rest end
  return nil, nil
end

---resolve_path resolves a ref that may begin with `$VAR` or `${VAR}`:
---
---  { ok, path, var_name?, unresolved, why? }
---
---An unresolved variable keeps the literal in `path`, so an editor shows what was
---written, and `why` says when the daemon could not answer. An absolute or `~`
---path is expanded; a plain relative one is returned for the caller to resolve
---(AutoDoc reads it as KB-relative, ADR 1791532020 D2).
---@param input string
---@return { ok: boolean, path: string?, var_name: string?, unresolved: boolean, why: string? }
function M.resolve_path(input)
  if type(input) ~= "string" or input == "" then
    return { ok = false, path = nil, unresolved = false }
  end
  local var_name, rest = split_var_prefix(input)
  if var_name then
    local val, why = M.get(var_name)
    if val == nil or val == "" then
      return { ok = false, path = input, var_name = var_name, unresolved = true, why = why }
    end
    local joined = val
    if rest ~= nil and rest ~= "" then
      joined = val:gsub("/+$", "") .. "/" .. rest:gsub("^/+", "")
    end
    return { ok = true, path = joined, var_name = var_name, unresolved = false }
  end
  if input:sub(1, 1) == "/" or input:sub(1, 1) == "~" then
    return { ok = true, path = vim.fn.expand(input), unresolved = false }
  end
  return { ok = true, path = input, unresolved = false }
end

-- ─── public: symbolize_path (inverse of resolve_path) ──────────

---symbolize_path is the daemon's symbolize (autodoc core/todo/vars.go): an
---absolute or `~` path is written against the root with the longest matching
---prefix, among `$KB_ROOT`, `$WORKSPACE`, `$PROJECT_ROOT`, the user variables by
---name and `$HOME`, the earlier one winning a tie; kept as it is when none holds
---it. A bare relative path the KB holds becomes `$KB_ROOT/…`. A `$VAR` input is
---returned unchanged, and so is every input when the daemon cannot answer.
---@param path string
---@return string
function M.symbolize_path(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) == "$" then return path end
  local e = table_now()
  if not e then return path end

  local roots = {}
  local function add(name, value)
    if type(value) == "string" and value ~= "" then
      roots[#roots + 1] = { name = name, value = (value:gsub("/+$", "")) }
    end
  end
  for _, n in ipairs({ "KB_ROOT", "WORKSPACE", "PROJECT_ROOT" }) do
    add(n, e.by[n] and e.by[n].value)
  end
  local users = {}
  for _, r in ipairs(e.rows) do
    if not BUILTIN[r.name] then users[#users + 1] = r.name end
  end
  table.sort(users)
  for _, n in ipairs(users) do add(n, e.by[n].value) end
  add("HOME", e.by.HOME and e.by.HOME.value)

  if path:sub(1, 1) == "/" or path:sub(1, 1) == "~" then
    local abs = vim.fn.expand(path)
    local best
    for _, r in ipairs(roots) do
      if abs == r.value or abs:sub(1, #r.value + 1) == r.value .. "/" then
        if not best or #r.value > #best.value then best = r end
      end
    end
    if not best then return path end
    return "$" .. best.name .. abs:sub(#best.value + 1)
  end
  local kb = e.by.KB_ROOT and e.by.KB_ROOT.value
  if kb and fs_path.exists(fs_path.join(kb, path)) then
    return "$KB_ROOT/" .. path:gsub("^/+", "")
  end
  return path
end

---Test seam: forgets every cached table.
function M._reset_for_tests()
  _cache, _reading = {}, {}
end

return M
