---The `$VAR/...` variables a file's refs resolve with, and the path resolver over
---them (ADR-0031 variable substitution; ADR 1792132105 "variables belong to the
---workspace").
---
---A `.todo-list/` and a KB are portable: they are synced across machines with git,
---so a document stores the portable form of a ref,
---
---    adr:
---      - $KB_ROOT/adrs/0031-foo.md
---
---…and each machine resolves `$KB_ROOT` to its own KB root. The NAMES are
---wire-format (committed with the KB); the VALUES are each machine's.
---
---**AutoDoc's daemon owns the values, and the workspace (the KB) owns its
---variables.** A file's refs resolve with the variables of the workspace that owns
---the file, which the daemon names (`workspace.of(path)`), whichever workspace is
---active: `workspace.vars(workspace)` answers them, each with its source. This
---module asks the daemon and never computes its own.
---
---  • **Built-ins**, derived per workspace on each machine: `$KB_ROOT` and `$HOME`.
---    `$PROJECT_ROOT` is a user variable, set where a KB serves a project.
---    `$WORKSPACE` is retired: an ordinary name, unresolved unless set.
---  • **User variables**: this machine's value, the KB's `.autodoc-vars.toml`
---    (relative to the KB root, carried by git), the daemon's global vars, the
---    environment, in that order (the daemon's precedence).
---  • **A conflict**: a name a pending migration holds in conflict is unresolved
---    unless this machine sets it.
---
---Every reader takes an optional `{ from = path }`: the file whose refs these are.
---Without it, it is the session project's store (`auto-core.todo.where`), whose
---`todos.vars` answers its workspace's variables. A daemon older than protocol 24
---has neither `workspace.of` nor `workspace.vars`: a `from` is then read as the
---session store, as before.
---
---Each table is cached: a read of one older than `M.FRESH_MS` reads it again
---first, and once read it is read again every `M.FRESH_MS` in the background; a
---change publishes `core.todo.vars:changed`. A leading `~` is the table's `$HOME`,
---as the daemon reads it. Without AutoDoc there are no values: `get` answers nil
---and the reason, as every todo verb answers "AutoDoc required" since v0.4.1.
---
---Asking which KB a project uses is a different question, `auto-core.kb.root()`:
---a project's store may lie outside any KB.
---
---@module 'auto-core.todo.vars'

local fs_path = require("auto-core.fs.path")

local M = {}

-- NOTE: staleness bound, a poll because the daemon cannot announce. The daemon
-- tells Neovim of no variable change (its events go to its own log), so a value set
-- elsewhere (AutoDoc's Variables tab, a hand edit of the KB's .autodoc-vars.toml,
-- another Neovim) is found by reading again:
--   * a read of a table older than this reads it again first (REREAD_WAIT_MS);
--   * once the session has read a table, it is read again every FRESH_MS in the
--     background, and a change is published (core.todo.vars:changed), so a panel
--     nobody touches shows it too.
M.FRESH_MS = 2000

-- NOTE: deadline. A stale table's re-read is waited for at most this long; past it
-- the read answers the table it had, and the background read carries on: a render
-- never stalls on a slow daemon.
M.REREAD_WAIT_MS = 500

---now_ms is a monotonic clock in milliseconds, current inside a long synchronous call too.
local function now_ms() return vim.uv.hrtime() / 1e6 end

-- ─── built-ins ────────────────────────────────────────────────

---The daemon's built-in variables (ADR 1792132105 §2.2), in its order: derived per
---workspace on each machine. A machine or KB value overrides the derived one.
---`$PROJECT_ROOT` is a user variable now, and `$WORKSPACE` is retired (§2.6).
---@type { name: string, resolver: fun(): string?, doc: string }[]
M.BUILTINS = {
  { name = "KB_ROOT",
    doc = "The workspace's root: the KB its documents belong to." },
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

-- ─── the tables, from the daemon ──────────────────────────────

-- A table is a source's variables:
--   { kind = "store" }                  the session project's store (todos.vars);
--   { kind = "ws", workspace = name }   a workspace's (workspace.vars);
--   { kind = "none" }                   a file no workspace owns: its refs resolve
--                                       with the environment alone here.
local _cache = {}   -- key → entry { key, src, at?, store_id?, workspace?, rows, by, read }
local _reading = {} -- key → true while a background read runs
local _owner = {}   -- a file's directory → { key, read }: the table its files resolve with
local _old = false  -- the daemon refused workspace.of: older than protocol 24
local _poll         -- the timer of the background read, once a table was read

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

---rows_of reads a todos.vars or workspace.vars answer into rows, and rows by name.
local function rows_of(daemon, list)
  local rows, by = {}, {}
  for _, v in ipairs(daemon.list_of(list)) do
    if type(v) == "table" and type(v.name) == "string" then
      local row = {
        name     = v.name,
        value    = (type(v.value) == "string" and v.value ~= "") and v.value or nil,
        builtin  = v.builtin == true,
        source   = v.source,
        derived  = v.derived,
        machine  = v.machine == true,
        conflict = v.conflict == true,
      }
      for _, b in ipairs(M.BUILTINS) do
        if b.name == v.name then row.doc = b.doc end
      end
      rows[#rows + 1] = row
      by[v.name] = row
    end
  end
  return rows, by
end

---fetch reads src's table. Runs inside daemon.run; raises on an error.
---@return table entry
local function fetch(daemon, where, src)
  if src.kind == "none" then
    return { key = "none", src = src, rows = {}, by = {}, read = now_ms() }
  end
  if src.kind == "ws" then
    local list, err = daemon.rpc("workspace.vars", { src.workspace })
    if err then daemon.fail(err) end
    local rows, by = rows_of(daemon, list)
    return { key = "ws:" .. src.workspace, src = src, workspace = src.workspace, rows = rows, by = by,
      read = now_ms() }
  end
  local c = where.ensure(where.root())
  local list, err = daemon.rpc("todos.vars", { c.at })
  if err then daemon.fail(err) end
  local rows, by = rows_of(daemon, list)
  return { key = "store:" .. c.store_id, src = src, at = c.at, store_id = c.store_id, rows = rows, by = by,
    read = now_ms() }
end

---dir_of is the directory a file's owner is recorded by: the directory of an
---absolute path, the path itself for a directory.
local function dir_of(abs)
  if vim.fn.isdirectory(abs) == 1 then return (abs:gsub("/+$", "")) end
  return abs:match("^(.*)/[^/]*$") or abs
end

---fetch_for reads the table a file's refs resolve with: workspace.of names its
---workspace (ADR 1792132105 §2.5), then its table. A daemon that does not know
---workspace.of (older than protocol 24) answers the session store's, as before.
---Runs inside daemon.run; raises on an error.
local function fetch_for(daemon, where, abs)
  local got, err = daemon.rpc("workspace.of", { abs })
  if err then
    if type(err) == "table" and err.code == -32601 then
      _old = true
      return fetch(daemon, where, { kind = "store" })
    end
    daemon.fail(err)
  end
  got = daemon.normalize(got)
  local ws = type(got) == "table" and type(got.workspace) == "string" and got.workspace ~= "" and got.workspace
  local e = fetch(daemon, where, ws and { kind = "ws", workspace = ws } or { kind = "none" })
  _owner[dir_of(abs)] = { key = e.key, read = e.read }
  return e
end

local function same(a, b)
  if not a or #a.rows ~= #b.rows then return false end
  for i, r in ipairs(a.rows) do
    local s = b.rows[i]
    if r.name ~= s.name or r.value ~= s.value or r.source ~= s.source or r.conflict ~= s.conflict then
      return false
    end
  end
  return true
end

---keep caches e and says whether it differs from what was cached.
local function keep(e)
  local changed = not same(_cache[e.key], e)
  _cache[e.key] = e
  return changed
end

---read_again runs body (a fetch of the table cached at key) in the background, and
---publishes a change.
local function read_again(daemon, key, body)
  if _reading[key] then return end
  _reading[key] = true
  daemon.run(body, function(ok, e)
    _reading[key] = nil
    if ok and keep(e) then publish_changed("read") end
  end)
end

---poll starts the background read (FRESH_MS), once: every table read, read again
---while Neovim runs; the session store's as where resolves it then.
local function poll()
  if _poll then return end
  _poll = vim.uv.new_timer()
  _poll:start(M.FRESH_MS, M.FRESH_MS, vim.schedule_wrap(function()
    local daemon, where = deps()
    if not daemon or not daemon.available() then return end
    for key, e in pairs(_cache) do
      local src = e.src
      local fresh = src.kind == "ws"
      if src.kind == "store" then
        local c = where.cached(where.root())
        fresh = c ~= nil and "store:" .. c.store_id == key
      end
      if fresh then read_again(daemon, key, function() return fetch(daemon, where, src) end) end
    end
  end))
end

---read runs body (a fetch) now: inside daemon.run by its rpc, else waiting at most
---wait_ms (the daemon's own deadline when nil). A change is published.
---@return table|nil entry, string? why
local function read(daemon, body, wait_ms)
  local ok, got
  if daemon.in_run() then
    ok, got = pcall(body)
  else
    ok, got = daemon.sync(body, wait_ms)
  end
  if not ok then return nil, tostring(got) end
  if keep(got) then publish_changed("read") end
  poll()
  return got
end

---table_now is the table the refs of opts.from resolve with (the session store's
---without one), or nil and why. A table older than FRESH_MS is read again first,
---waited for at most REREAD_WAIT_MS; when the read cannot finish (a fast event, a
---slow daemon) the old one answers.
---@param opts? { from?: string }
---@return table|nil entry, string? why
local function table_now(opts)
  local daemon, where = deps()
  if not daemon or not daemon.available() then
    return nil, daemon and daemon.REQUIRED or "auto-core.todo.daemon is unavailable"
  end
  local from = type(opts) == "table" and opts.from or nil
  local e, body, read_at
  if type(from) == "string" and from ~= "" and not _old then
    local abs = vim.fn.fnamemodify(from, ":p")
    local o = _owner[dir_of(abs)]
    e = o and _cache[o.key]
    read_at = e and math.min(o.read, e.read) -- the owner may have moved too
    body = function() return fetch_for(daemon, where, abs) end
  else
    local c = where.cached(where.root())
    e = c and _cache["store:" .. c.store_id]
    read_at = e and e.read
    body = function() return fetch(daemon, where, { kind = "store" }) end
  end
  if not e then return read(daemon, body, nil) end
  if now_ms() - read_at <= M.FRESH_MS then return e end
  if vim.in_fast_event() then
    vim.schedule(function() read_again(daemon, e.key, body) end)
    return e
  end
  return read(daemon, body, M.REREAD_WAIT_MS) or e
end

---home is the table's $HOME, as the daemon resolves a leading "~" with it; nil when
---it has none.
local function home_of(e)
  local h = e and e.by.HOME and e.by.HOME.value
  if type(h) == "string" and h ~= "" then return (h:gsub("/+$", "")) end
  return nil
end

---expand_home is p with a leading "~" or "~/" read as the table's $HOME, as the
---daemon does (autodoc core/todo/vars.go expandHome): another "~name" form, or a
---table with no $HOME, leaves p as it is. Without the daemon's table it is
---Neovim's home: there is no workspace to ask.
local function expand_home(p, opts)
  if p ~= "~" and p:sub(1, 2) ~= "~/" then return p end
  local e = table_now(opts)
  if not e then return vim.fn.expand(p) end
  local h = home_of(e)
  if not h then return p end
  return h .. p:sub(2)
end

-- ─── public: get / set / list / remove ────────────────────────

---get is a variable's value for the refs of opts.from (the session store's without
---it), or nil (and why, when the daemon could not answer). A name the table does
---not know falls back to `vim.env`, as the daemon falls back to its own
---environment; a name it holds in conflict never does (ADR 1792132105 §2.3).
---@param name string  without the leading `$`
---@param opts? { from?: string }  the file whose refs these are
---@return string? value, string? why
function M.get(name, opts)
  if type(name) ~= "string" or name == "" then return nil end
  local e, why = table_now(opts)
  if not e then return nil, why end
  local row = e.by[name]
  if row then return row.value end
  local env = vim.env[name]
  if type(env) == "string" and env ~= "" then return env end
  return nil
end

---list is the variables of opts.from's workspace (the session store's without it)
---for display, built-ins first in the daemon's order: { name, value, builtin, doc,
---source, derived, machine, conflict }. A variable with no value here (a built-in
---that derives none, a machine-only name not set on this machine, a name in
---conflict) has `value = nil`. An empty list and why when the daemon cannot answer.
---@param opts? { from?: string }
---@return table[] rows, string? why
function M.list(opts)
  local e, why = table_now(opts)
  if not e then return {}, why end
  return vim.deepcopy(e.rows)
end

---workspace is the workspace whose variables the refs of opts.from resolve with
---(ADR 1792132105 §2.5); nil for a file no workspace owns, for the session store
---on a daemon older than protocol 24, or when the daemon cannot answer (and why).
---@param opts? { from?: string }
---@return string? workspace, string? why
function M.workspace(opts)
  local e, why = table_now(opts)
  if not e then return nil, why end
  return e.workspace
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

---put writes name's value where scope says, for table e, and drops every cached
---table (a global var is every workspace's):
---  * a workspace's table: workspace.set_var, scope "machine" (an absolute path)
---    or "kb" (the KB's file, relative to its root), machine_only declaring the
---    name machine-only in the KB's file; scope "global", the daemon's global vars;
---  * the session store's (no workspace, or a daemon older than protocol 24):
---    todos.set_var, as before.
local function put(e, name, value, scope, machine_only)
  local daemon = deps()
  local method, params
  if scope == "global" then
    method, params = "todos.set_var", { name, value, { scope = "global" } }
  elseif e.workspace then
    local o = { scope = scope }
    if machine_only then o.machine_only = true end
    method, params = "workspace.set_var", { e.workspace, name, value, o }
  elseif e.at then
    local o = { scope = scope == "kb" and "store" or scope, at = e.at }
    if machine_only then o.machine_only = true end
    method, params = "todos.set_var", { name, value, o }
  else
    return false, "no workspace owns this file: set the variable in a workspace, or globally"
  end
  local ok, res = daemon.sync(function()
    local _, err = daemon.rpc(method, params)
    if err then daemon.fail(err) end
    return true
  end)
  if not ok then return false, tostring(res) end
  _cache, _owner = {}, {}
  publish_changed(value == "" and "remove" or "set", name)
  return true
end

---source_scope is where a row's value is written back: the KB's file, the global
---vars, or this machine.
local function source_scope(row)
  local src = row and row.source
  if src == "kb" or src == "store" then return "kb" end
  if src == "global" then return "global" end
  return "machine"
end

---set sets a user variable for the workspace of opts.from (the session store's
---without it): in opts.scope, "machine" (this machine's value, an absolute path),
---"kb" (the KB's file, relative to the KB root, carried by git) or "global";
---without one, where its value comes from now, and a new name on this machine
---only, so its value never reaches git. opts.machine_only declares the name
---machine-only in the KB's file (which settles a conflict, ADR 1792132105 §2.7).
---Built-ins are read-only here (AutoDoc's Variables tab overrides one). An empty
---value clears it.
---@param name string
---@param value string
---@param opts? { from?: string, scope?: "machine"|"kb"|"global", machine_only?: boolean }
---@return boolean ok, string? err
function M.set(name, value, opts)
  local okn, nerr = valid_name(name)
  if not okn then return false, nerr end
  if BUILTIN[name] then
    return false, "'" .. name .. "' is a built-in variable and auto-resolves; "
      .. "override it in AutoDoc's Variables tab"
  end
  if type(value) ~= "string" then return false, "value must be a string" end
  opts = opts or {}
  local scope = opts.scope
  if scope ~= nil and scope ~= "machine" and scope ~= "kb" and scope ~= "global" then
    return false, "scope must be machine, kb or global"
  end
  local e, why = table_now(opts)
  if not e then return false, why end
  return put(e, name, value, scope or source_scope(e.by[name]), opts.machine_only)
end

---remove clears a user variable of opts.from's workspace where its value comes
---from. Built-ins are refused; a name with no value set is a no-op.
---@param name string
---@param opts? { from?: string }
---@return boolean ok, string? err
function M.remove(name, opts)
  local okn, nerr = valid_name(name)
  if not okn then return false, nerr end
  if BUILTIN[name] then
    return false, "'" .. name .. "' is a built-in variable and cannot be removed"
  end
  local e, why = table_now(opts)
  if not e then return false, why end
  local row = e.by[name]
  if not (row and row.value) or row.source == "derived" or row.source == "env" then return true end
  return put(e, name, "", source_scope(row))
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
---with the variables of opts.from's workspace, the file the ref is written in (the
---session store's without it). An unresolved variable keeps the literal in `path`,
---so an editor shows what was written, and `why` says when the daemon could not
---answer. An absolute path is returned as it is, and a leading `~` is the
---workspace's `$HOME`; a plain relative one is returned for the caller to resolve
---(AutoDoc reads it as KB-relative, ADR 1791532020 D2).
---@param input string
---@param opts? { from?: string }
---@return { ok: boolean, path: string?, var_name: string?, unresolved: boolean, why: string? }
function M.resolve_path(input, opts)
  if type(input) ~= "string" or input == "" then
    return { ok = false, path = nil, unresolved = false }
  end
  local var_name, rest = split_var_prefix(input)
  if var_name then
    local val, why = M.get(var_name, opts)
    if val == nil or val == "" then
      return { ok = false, path = input, var_name = var_name, unresolved = true, why = why }
    end
    local joined = val
    if rest ~= nil and rest ~= "" then
      joined = val:gsub("/+$", "") .. "/" .. rest:gsub("^/+", "")
    end
    return { ok = true, path = joined, var_name = var_name, unresolved = false }
  end
  if input:sub(1, 1) == "/" then
    return { ok = true, path = input, unresolved = false }
  end
  if input:sub(1, 1) == "~" then
    return { ok = true, path = expand_home(input, opts), unresolved = false }
  end
  return { ok = true, path = input, unresolved = false }
end

-- ─── public: symbolize_path (inverse of resolve_path) ──────────

---symbolize_path is the daemon's symbolize (autodoc core/todo/vars.go), with the
---variables of opts.from's workspace, the file the ref is written into (the
---session store's without it): an absolute or `~` path is written against the
---root with the longest matching prefix, among `$KB_ROOT`, `$PROJECT_ROOT`, the
---user variables by name and `$HOME`, the earlier one winning a tie; kept as it is
---when none holds it. `$WORKSPACE` is never written (ADR 1792132105 §2.6), nor a
---name in conflict. A bare relative path the KB holds becomes `$KB_ROOT/…`. A
---`$VAR` input is returned unchanged, and so is every input when the daemon
---cannot answer.
---@param path string
---@param opts? { from?: string }
---@return string
function M.symbolize_path(path, opts)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) == "$" then return path end
  local e = table_now(opts)
  if not e then return path end

  local roots = {}
  local function add(name, value)
    if type(value) == "string" and value ~= "" then
      roots[#roots + 1] = { name = name, value = (value:gsub("/+$", "")) }
    end
  end
  for _, n in ipairs({ "KB_ROOT", "PROJECT_ROOT" }) do
    add(n, e.by[n] and e.by[n].value)
  end
  local users = {}
  for _, r in ipairs(e.rows) do
    if not BUILTIN[r.name] and r.name ~= "PROJECT_ROOT" and r.name ~= "WORKSPACE" then
      users[#users + 1] = r.name
    end
  end
  table.sort(users)
  for _, n in ipairs(users) do add(n, e.by[n].value) end
  add("HOME", e.by.HOME and e.by.HOME.value)

  if path:sub(1, 1) == "/" or path:sub(1, 1) == "~" then
    local abs = expand_home(path, opts)
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
  _cache, _reading, _owner, _old = {}, {}, {}, false
  if _poll then
    _poll:stop()
    _poll:close()
    _poll = nil
  end
end

return M
