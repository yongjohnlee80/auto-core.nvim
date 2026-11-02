---auto-core.commands — the whitelisted command registry.
---
---The security boundary that decides what a caller may run in this Neovim: only a
---registered name is dispatchable, and a family plugin registers its own handler
---under it. It never runs raw Lua, Vimscript, shell or RPC strings. auto-agents'
---editor socket dispatches through it (`get`, then `validate_args` against the
---verb's schema, then the handler).
---
---It was `auto-core.mailbox.commands` until v0.6.0, which retires the file mailbox
---(ADR 1793271500 phase 5): the registry and the validator outlive it, the
---file-envelope dispatch (`handle_message`, `reject_unknown`) does not.
---
---@module 'auto-core.commands'

local events = require("auto-core.events")

local M = {}

---@class AutoCoreCommandSpec
---@field owner       string         -- which plugin registered it (informational)
---@field handler     fun(args: table, ctx: table): table   -- returns response value; ctx is the
---                  caller's dispatch context plus `from`, the command message's sender
---@field schema      table?         -- optional shape hint, e.g. `{ file = "string?" }`
---@field description string?

---@type table<string, AutoCoreCommandSpec>
local _registry = {}

-- ── helpers ─────────────────────────────────────────────────

---@param name any
---@return boolean ok, string? err
local function valid_name(name)
  if type(name) ~= "string" or #name == 0 then
    return false, "command name must be a non-empty string"
  end
  -- v0.1.44: permit `.` as a namespace separator (e.g.
  -- `todos.list`, `todos.assign`, `auth.login`). The leading
  -- char must still be a letter or underscore (not a digit or
  -- separator), but the tail may include `.` alongside the
  -- existing `-` / `_` / digits / letters. Two adjacent dots
  -- or a trailing dot are rejected — the namespace must be a
  -- non-empty identifier followed by at least one verb segment.
  if not name:match("^[A-Za-z_][A-Za-z0-9_%-%.]*$") then
    return false,
      "command name must match [A-Za-z_][A-Za-z0-9_.-]* (got " .. name .. ")"
  end
  if name:find("%.%.") or name:sub(-1) == "." then
    return false,
      "command name must not contain consecutive dots or end with a dot (got "
        .. name .. ")"
  end
  return true
end

-- ── public API ──────────────────────────────────────────────

---Register a command name → handler binding. Returns ok, err?.
---Re-registering the same name with the same owner is allowed
---(useful for plugin hot-reload). Re-registering with a different
---owner is a fail-fast — owners shouldn't accidentally clobber
---another plugin's command.
---@param name string
---@param spec AutoCoreCommandSpec
---@return boolean ok, string? err
function M.register(name, spec)
  local ok, err = valid_name(name)
  if not ok then return false, err end
  if type(spec) ~= "table" then
    return false, "register: spec must be a table"
  end
  if type(spec.handler) ~= "function" then
    return false, "register: spec.handler must be a function"
  end
  if type(spec.owner) ~= "string" or spec.owner == "" then
    return false, "register: spec.owner must be a non-empty string"
  end

  local existing = _registry[name]
  if existing and existing.owner ~= spec.owner then
    return false, string.format(
      "register: command '%s' is already owned by '%s' (refused new owner '%s')",
      name, existing.owner, spec.owner)
  end

  _registry[name] = {
    owner       = spec.owner,
    handler     = spec.handler,
    schema      = spec.schema,
    description = spec.description,
  }
  events.publish("core.command:registered", {
    name        = name,
    owner       = spec.owner,
    description = spec.description,
  })
  return true
end

---Look up a command spec. Returns nil for unregistered names.
---@param name string
---@return AutoCoreCommandSpec?
function M.get(name)
  return _registry[name]
end

---List all registered command names + owners + arg schemas. The
---returned table is a fresh copy; mutating it does NOT affect the
---registry. The per-entry `schema` (v0.1.45) makes the command
---surface self-describing — discovery consumers (`commands_list`)
---can show callers exactly which args each verb takes, so agents
---stop guessing and hitting `bad_args`. `schema` is the same
---shape the verb declared at register time (a `{field = type}`
---table) or nil when the verb declared none.
---@return { name: string, owner: string, description: string?, schema: table? }[]
function M.list()
  local out = {}
  for name, spec in pairs(_registry) do
    -- Shallow-copy the schema so callers can't mutate the registry's
    -- copy through the returned table.
    local schema_copy = nil
    if type(spec.schema) == "table" then
      schema_copy = {}
      for k, v in pairs(spec.schema) do schema_copy[k] = v end
    end
    out[#out + 1] = {
      name        = name,
      owner       = spec.owner,
      description = spec.description,
      schema      = schema_copy,
    }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

---Unregister a command (rare — typically only used in tests or
---plugin teardown). Idempotent.
---@param name string
function M.unregister(name)
  _registry[name] = nil
end

-- ── schema validator ───────────────────────────────────────

---Minimal schema validator a dispatcher runs before a verb's handler. The schema is
---a table keyed by field name; the value is a type-string like
---`"string"`, `"integer"`, `"number"`, `"boolean"`, `"table"`, or
---`"any"`. Append `?` to make a field optional (`"string?"`).
---
---Unknown fields in `args` are permitted (forward-compatibility);
---callers that want strict-shape enforcement can layer their own
---check on top.
---
---Note: Mutates `args` in-place when optional fields carry `vim.NIL`
---(JSON null), normalizing them to `nil` so `vim.NIL` userdata
---cannot leak into command handlers.
---
---Returns ok, err_msg?, field?. err_msg is a human-readable
---explanation; field is the offending field name (or nil).
---@param args   table
---@param schema table<string, string>
---@return boolean ok, string? err, string? field
function M.validate_args(args, schema)
  if type(schema) ~= "table" then
    return true
  end
  for field, type_spec in pairs(schema) do
    if type(type_spec) ~= "string" then
      return false, "schema entry for '" .. field
        .. "' must be a string (got " .. type(type_spec) .. ")", field
    end
    local optional = type_spec:sub(-1) == "?"
    local want = optional and type_spec:sub(1, -2) or type_spec
    local got = args[field]
    local is_nil_val = (got == nil) or (vim and vim.NIL and got == vim.NIL)
    if is_nil_val then
      if not optional then
        return false, "missing required field '" .. field
          .. "' (expected " .. want .. ")", field
      else
        args[field] = nil
      end
    else
      local got_t = type(got)
      local ok_t
      if want == "any" then
        ok_t = true
      elseif want == "integer" then
        ok_t = (got_t == "number") and (math.floor(got) == got)
      elseif want == "number" or want == "string"
          or want == "boolean" or want == "table"
          or want == "function"
      then
        ok_t = (got_t == want)
      else
        return false, "schema entry for '" .. field
          .. "' has unknown type '" .. want .. "'", field
      end
      if not ok_t then
        return false, "field '" .. field .. "' expected " .. want
          .. ", got " .. got_t, field
      end
    end
  end
  return true
end

---Test-only — empties the registry.
function M._reset_for_tests()
  _registry = {}
end

return M
