---Per-machine variable store + `$VAR/...` path resolver for the
---auto-core todo subsystem (ADR-0031 — variable substitution,
---added in v0.1.40).
---
---Motivating use case: a `.todo-list/` directory is intentionally
---portable — it gets synced across machines via git. Hard-coding
---an absolute path like `/Users/alice/.config/nvim/.auto-agents-
---config/kb/shared/adrs/0031-foo.md` works on Alice's laptop but
---is broken everywhere else. Hard-coding a relative path like
---`shared/adrs/0031-foo.md` works only when the resolver knows
---about KB-relative joining — which itself depends on env vars
---that may not be set on every machine.
---
---Variables decouple portable identity from machine-specific
---resolution. The task file stores the portable form:
---
---    adr:
---      - $KB_ROOT/shared/adrs/0031-foo.md
---
---…and each machine resolves `$KB_ROOT` to whatever its local KB
---root actually is. The variable NAMES are wire-format (committed
---to the .todo-list/ via git). The variable VALUES are local-only
---(per-machine, stored in `auto-core.state.namespace('todo.vars',
---{persist='json'})`, never reach git).
---
---Two classes of variables:
---
---  • **Built-in** (auto-resolved, read-only): `$KB_ROOT`,
---    `$WORKSPACE`, `$HOME`, `$CWD`. The values come from existing
---    auto-core infrastructure (KB env vars, git.worktree, expand,
---    getcwd). These are always available — no setup needed.
---
---  • **User-defined** (editable via panel or `M.set`): everything
---    else. Stored in state. The auto-finder panel's Vars section
---    surfaces them with `e` to edit / `a` to add / `d` to delete.
---
---Resolver order, given an input path:
---  1. Path starts with `$VAR/...` or is exactly `$VAR` →
---     lookup VAR in (a) built-ins, (b) user-defined state vars,
---     (c) `vim.env`. First non-nil wins. The matched value
---     replaces the `$VAR` segment.
---  2. Path starts with `~` or `/` → absolute, expand and return.
---  3. Otherwise (plain relative) → caller's responsibility
---     (auto-core.todo's refresh treats these as KB-relative for
---     backwards compat; auto-finder's panel tries multi-root
---     candidates). This module returns `{ ok = true, path = <rel>,
---     unresolved = false }` so the caller can layer its own logic.
---
---@module 'auto-core.todo.vars'

local fs_path = require("auto-core.fs.path")

local M = {}

-- ─── built-in resolvers ───────────────────────────────────────

---Built-in variable resolvers. Each returns the absolute string
---value (or nil when not available on this machine). The keys are
---listed in stable order so the panel can render them
---deterministically.
---@type { name: string, resolver: fun(): string?, doc: string }[]
M.BUILTINS = {
  {
    name = "KB_ROOT",
    doc  = "Auto-agents knowledge-base root. Resolved from env: "
      .. "AUTO_AGENTS_KB_ROOT > AUTO_AGENTS_KB_READ[0] > AUTO_AGENTS_KB_WRITE.",
    resolver = function()
      local r = vim.env.AUTO_AGENTS_KB_ROOT
      if r and r ~= "" then return fs_path.normalize(r) end
      local rd = vim.env.AUTO_AGENTS_KB_READ
      if rd and rd ~= "" then
        local first = rd:match("^([^:]+)")
        if first and first ~= "" then return fs_path.normalize(first) end
      end
      local w = vim.env.AUTO_AGENTS_KB_WRITE
      if w and w ~= "" then return fs_path.normalize(w) end
      return nil
    end,
  },
  {
    name = "WORKSPACE",
    doc  = "Current workspace root (git.worktree.set_workspace_root, "
      .. "else the repo root walk-up from cwd).",
    resolver = function()
      local ok, paths = pcall(require, "auto-core.todo.paths")
      if not ok then return nil end
      local ws = paths.workspace_root()
      if ws and ws ~= "" then return fs_path.normalize(ws) end
      return nil
    end,
  },
  {
    name = "HOME",
    doc  = "User's home directory (vim.fn.expand('~')).",
    resolver = function()
      local h = vim.fn.expand("~")
      if h and h ~= "" then return fs_path.normalize(h) end
      return nil
    end,
  },
  {
    name = "CWD",
    doc  = "Current working directory at lookup time.",
    resolver = function()
      local c = vim.fn.getcwd()
      if c and c ~= "" then return fs_path.normalize(c) end
      return nil
    end,
  },
}

---@type table<string, fun(): string?>
local BUILTIN_BY_NAME = {}
do
  for _, b in ipairs(M.BUILTINS) do BUILTIN_BY_NAME[b.name] = b.resolver end
end

---@param name string
---@return boolean
function M.is_builtin(name) return BUILTIN_BY_NAME[name] ~= nil end

-- ─── state namespace ──────────────────────────────────────────

local _state = nil
---Lazy state namespace handle. Tests can reset by setting
---`_state = nil` and re-calling.
local function state()
  if _state then return _state end
  local ok, mod = pcall(require, "auto-core.state")
  if not ok or type(mod) ~= "table" or type(mod.namespace) ~= "function" then
    error("auto-core.todo.vars: auto-core.state module unavailable")
  end
  _state = mod.namespace("todo.vars", { persist = "json" })
  return _state
end

---Read the user-defined vars map from state. Returns a fresh
---copy so callers can mutate without poisoning the cached value.
---@return table<string, string>
local function read_user_vars()
  local s = state()
  local v = s:get("entries") or {}
  if type(v) ~= "table" then v = {} end
  local out = {}
  for k, val in pairs(v) do
    if type(k) == "string" and type(val) == "string" then
      out[k] = val
    end
  end
  return out
end

---Publish `core.todo.vars:changed` so subscribers re-render.
local function publish_changed(kind, name)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events and type(events.publish) == "function" then
    pcall(events.publish, "core.todo.vars:changed",
      { kind = kind, name = name })
  end
end

-- ─── public: get / set / list / remove ────────────────────────

---Look up a variable by name. Order: built-ins → user-defined
---(state) → `vim.env`. Returns the resolved string value or nil
---when no source has it.
---@param name string  variable name WITHOUT the leading `$`
---@return string?
function M.get(name)
  if type(name) ~= "string" or name == "" then return nil end
  local builtin = BUILTIN_BY_NAME[name]
  if builtin then return builtin() end
  local users = read_user_vars()
  local u = users[name]
  if type(u) == "string" and u ~= "" then return u end
  local e = vim.env[name]
  if type(e) == "string" and e ~= "" then return e end
  return nil
end

---Set or update a user-defined variable. Built-in names are
---rejected (they auto-resolve). Empty values clear the entry.
---@param name string
---@param value string
---@return boolean ok, string? err
function M.set(name, value)
  if type(name) ~= "string" or name == "" then
    return false, "name must be a non-empty string"
  end
  if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
    return false,
      "name '" .. name .. "' is not a valid shell-style identifier "
      .. "(letters, digits, underscores; must not start with a digit)"
  end
  if BUILTIN_BY_NAME[name] then
    return false,
      "'" .. name .. "' is a built-in variable and auto-resolves; "
      .. "user overrides are not permitted"
  end
  if type(value) ~= "string" then
    return false, "value must be a string"
  end

  local s = state()
  local entries = s:get("entries") or {}
  if type(entries) ~= "table" then entries = {} end
  if value == "" then
    entries[name] = nil
  else
    entries[name] = value
  end
  s:set("entries", entries)
  publish_changed("set", name)
  return true
end

---Remove a user-defined variable. Built-ins are rejected (they
---can't be removed). Removing a non-existent var is a no-op.
---@param name string
---@return boolean ok, string? err
function M.remove(name)
  if type(name) ~= "string" or name == "" then
    return false, "name must be a non-empty string"
  end
  if BUILTIN_BY_NAME[name] then
    return false, "'" .. name .. "' is a built-in variable and cannot be removed"
  end
  local s = state()
  local entries = s:get("entries") or {}
  if type(entries) ~= "table" then entries = {} end
  if entries[name] == nil then return true end
  entries[name] = nil
  s:set("entries", entries)
  publish_changed("remove", name)
  return true
end

---Return the full variable surface for UI display. Built-ins
---come first in stable order, then user-defined entries sorted
---lexicographically. Each row:
---
---  { name = "KB_ROOT", value = "/abs/...", builtin = true,  doc = "..." }
---  { name = "MY_VAR",  value = "/abs/...", builtin = false, doc = nil    }
---
---For a built-in whose resolver returns nil on this machine, the
---entry is still emitted (with `value = nil`) so the panel can
---show "(unset)" — handy diagnostic when KB env vars aren't set.
---@return table[]
function M.list()
  local out = {}
  for _, b in ipairs(M.BUILTINS) do
    out[#out + 1] = {
      name    = b.name,
      value   = b.resolver(),
      builtin = true,
      doc     = b.doc,
    }
  end
  local users = read_user_vars()
  local sorted = {}
  for k in pairs(users) do sorted[#sorted + 1] = k end
  table.sort(sorted)
  for _, k in ipairs(sorted) do
    out[#out + 1] = {
      name    = k,
      value   = users[k],
      builtin = false,
      doc     = nil,
    }
  end
  return out
end

-- ─── public: resolve_path ─────────────────────────────────────

---Detect `$VAR/...` or `$VAR` prefix on `input`. Returns
---(var_name, rest) where `rest` is the path tail after the var
---segment (may be empty), or (nil, nil) when input doesn't start
---with a variable reference.
---
---Supports `${VAR}/...` form as well (shell-style) so users
---familiar with that syntax aren't surprised. Both `$VAR` and
---`${VAR}` resolve identically.
---@param input string
---@return string? var_name, string? rest
local function split_var_prefix(input)
  if type(input) ~= "string" or input == "" then return nil, nil end
  if input:sub(1, 1) ~= "$" then return nil, nil end

  -- `${VAR}/...` form
  local brace_name, brace_rest = input:match("^%${([A-Za-z_][A-Za-z0-9_]*)}(.*)$")
  if brace_name then return brace_name, brace_rest end

  -- `$VAR/...` form (greedy name match)
  local name, rest = input:match("^%$([A-Za-z_][A-Za-z0-9_]*)(.*)$")
  if name then return name, rest end

  return nil, nil
end

---Resolve a reference path that may begin with a `$VAR/...`
---substitution. Returns:
---
---  {
---    ok         = boolean,
---    path       = string?,   -- substituted path (best-effort
---                            -- when unresolved; nil only on
---                            -- malformed input)
---    var_name   = string?,   -- the variable name we tried to
---                            -- resolve, when input had one
---    unresolved = boolean,   -- true iff a $VAR prefix was
---                            -- present and lookup returned nil
---  }
---
---When `unresolved = true`, the caller (refresh's reference
---validator, or the panel's open path) can decide whether to
---error or fall back. We DON'T silently drop the dollar — the
---returned `path` includes the literal `$VAR/...` so a broken-
---file editor still shows the user what they wrote.
---
---Inputs without a `$VAR` prefix pass through unchanged:
---absolute / `~`-rooted paths are expanded; plain relative
---paths are returned as-is for the caller to resolve.
---@param input string
---@return { ok: boolean, path: string?, var_name: string?, unresolved: boolean }
function M.resolve_path(input)
  if type(input) ~= "string" or input == "" then
    return { ok = false, path = nil, unresolved = false }
  end

  local var_name, rest = split_var_prefix(input)
  if var_name then
    local val = M.get(var_name)
    if val == nil or val == "" then
      return {
        ok         = false,
        path       = input,  -- preserve literal for diagnostics
        var_name   = var_name,
        unresolved = true,
      }
    end
    -- Join: strip leading slashes off `rest` and a trailing slash
    -- off the var value to produce a single normalized path.
    local joined
    if rest == nil or rest == "" then
      joined = val
    else
      joined = val:gsub("/+$", "") .. "/" .. rest:gsub("^/+", "")
    end
    return {
      ok         = true,
      path       = joined,
      var_name   = var_name,
      unresolved = false,
    }
  end

  if input:sub(1, 1) == "/" or input:sub(1, 1) == "~" then
    return { ok = true, path = vim.fn.expand(input), unresolved = false }
  end

  -- Plain relative — caller's responsibility.
  return { ok = true, path = input, unresolved = false }
end

return M