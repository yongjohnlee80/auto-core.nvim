---auto-core.mailbox.commands — whitelisted command registry.
---
---The mailbox transport is a generic JSON queue. The command
---registry is the security boundary that decides what a `kind =
---"command"` message is allowed to do. **Only** registered command
---names are dispatchable; an inbound command message whose name is
---not in the registry is rejected with a structured response.
---
---This module deliberately does NOT execute raw Lua, Vimscript,
---shell, or Neovim RPC strings. Family plugins ship their own
---handlers and register them by name.
---
---Phase 1 (this file): registry + rejection helper. The host-side
---executioner that actually pulls command messages off the `nvim`
---mailbox and routes them lives in a follow-up phase; the ADR's
---intent is that this skeleton is the SAFE no-op default until a
---family plugin opts in.
---
---@module 'auto-core.mailbox.commands'

local events = require("auto-core.events")
local log    = require("auto-core.log")

-- Component used on every log entry from this module. Routing the
-- wrapper-rule wakes (auto-core.mailbox.router.dispatch_wake) and the
-- executor-path commands (auto-core.mailbox.router.execute_command)
-- both flow through M.handle_message, so a single log emission here
-- captures every command attempt regardless of dispatch path.
local LOG_COMPONENT = "auto-core.mailbox.commands"

local M = {}

---@class AutoCoreCommandSpec
---@field owner       string         -- which plugin registered it (informational)
---@field handler     fun(args: table, ctx: table): table   -- returns response value
---@field schema      table?         -- optional shape hint, e.g. `{ file = "string?" }`
---@field description string?

---@class AutoCoreCommandResponse
---@field ok    boolean
---@field value any?
---@field error string?
---@field code  string?           -- machine-readable error code on rejections

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

---List all registered command names + owners. The returned table
---is a fresh copy; mutating it does NOT affect the registry.
---@return { name: string, owner: string, description: string? }[]
function M.list()
  local out = {}
  for name, spec in pairs(_registry) do
    out[#out + 1] = {
      name        = name,
      owner       = spec.owner,
      description = spec.description,
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

---Build a structured rejection response for an unknown command.
---Publishes `core.command:rejected` as a side effect. Returns the
---response table — callers (the executioner) feed it into
---`transport.complete(...,response)` or `transport.fail`. The shape
---matches the response envelope written to `responses/`.
---@param msg table        -- the original command message
---@param reason string?
---@return AutoCoreCommandResponse
function M.reject_unknown(msg, reason)
  local cmd = (type(msg) == "table" and type(msg.command) == "string") and msg.command or "<missing>"
  local payload = {
    ok    = false,
    code  = "unknown_command",
    error = reason or ("unknown command: " .. cmd),
  }
  events.publish("core.command:rejected", {
    name           = cmd,
    reason         = "unknown_command",
    message_id     = (type(msg) == "table") and msg.id or nil,
    from           = (type(msg) == "table") and msg.from or nil,
    to             = (type(msg) == "table") and msg.to or nil,
    correlation_id = (type(msg) == "table" and type(msg.correlation_id) == "string")
                      and msg.correlation_id or nil,
  })
  return payload
end

---Inner body of `handle_message` — returns the response table without
---logging. The outer `handle_message` wraps this and emits one log
---entry per call so the ring captures every command attempt
---(wake-dispatch path AND executor path) with the final response
---shape attached as structured fields.
---@param msg table
---@param ctx table?
---@return AutoCoreCommandResponse
local function _handle_message_inner(msg, ctx)
  if type(msg) ~= "table" then
    return { ok = false, code = "bad_message", error = "message is not a table" }
  end
  if msg.kind ~= "command" then
    return {
      ok    = false,
      code  = "not_a_command",
      error = "message.kind must be 'command' (got " .. tostring(msg.kind) .. ")",
    }
  end
  local name = msg.command
  if type(name) ~= "string" or name == "" then
    return { ok = false, code = "missing_command", error = "command name missing" }
  end
  local spec = _registry[name]
  if not spec then
    return M.reject_unknown(msg)
  end

  local args = msg.args or {}
  if type(args) ~= "table" then
    return {
      ok    = false,
      code  = "bad_args",
      error = "args must be a table (got " .. type(args) .. ")",
    }
  end

  -- Schema validation. When the command was registered with a
  -- `schema` field, args is checked against it BEFORE dispatch.
  -- Schemas are part of the public command contract per ADR §4,
  -- so failures produce a structured rejection with
  -- `core.command:rejected` for traceability.
  if type(spec.schema) == "table" then
    local v_ok, v_err, v_field = M.validate_args(args, spec.schema)
    if not v_ok then
      events.publish("core.command:rejected", {
        name           = name,
        reason         = "bad_args",
        message_id     = msg.id,
        from           = msg.from,
        to             = msg.to,
        correlation_id = (type(msg.correlation_id) == "string"
                          and msg.correlation_id ~= "")
                         and msg.correlation_id or nil,
        field          = v_field,
      })
      return {
        ok    = false,
        code  = "bad_args",
        field = v_field,
        error = v_err,
      }
    end
  end

  local ok_call, ret = pcall(spec.handler, args, ctx or {})
  if not ok_call then
    return {
      ok    = false,
      code  = "handler_error",
      error = tostring(ret),
    }
  end
  -- Handlers can return either a raw value or an explicit response
  -- table. Wrap raw returns as `{ok=true, value=...}` so the response
  -- envelope is consistent.
  if type(ret) == "table" and ret.ok ~= nil then
    events.publish("core.command:executed", {
      name = name,
      ok   = ret.ok ~= false,
    })
    return ret
  end
  events.publish("core.command:executed", { name = name, ok = true })
  return { ok = true, value = ret }
end

---Convenience: dispatch a command message through the registry.
---Returns a response table — `{ok, value?, error?, code?}`. The
---caller (typically the host-side executioner that watches the
---`nvim` mailbox) is responsible for translating this into a
---`transport.complete` or `transport.fail`. This helper never
---raises — handler errors are pcall'd and turned into
---`{ok=false, code="handler_error", error=...}`.
---
---Every call emits one log entry to component
---`auto-core.mailbox.commands` so `:AutoCoreLog` triage can see the
---full command stream — wake-dispatched + executor-path + rejections.
---@param msg table
---@param ctx table?
---@return AutoCoreCommandResponse
function M.handle_message(msg, ctx)
  local response = _handle_message_inner(msg, ctx)

  -- One log emission per call captures every command attempt with
  -- the final response shape. `:AutoCoreLog` filtered to the
  -- `auto-core.mailbox.commands` component shows the full command
  -- execution stream — wake-dispatched commands (router synthesizes
  -- the message), executor-path commands (router pulls from the
  -- `nvim` inbox), and even bad inputs (bad_message / not_a_command
  -- / unknown_command) so misuse is observable.
  --
  -- Level routing:
  --   * ok=true               → INFO (normal dispatch).
  --   * ok=false bad_*        → WARN (caller bug; schema or shape).
  --   * ok=false unknown_*    → WARN (registry miss; usually setup bug).
  --   * ok=false handler_error → ERROR (handler raised; surface loudly).
  --   * any other ok=false    → WARN (handler rejected for app reason).
  local response_ok = response and response.ok == true
  local code = response and response.code or nil
  local level
  if response_ok then
    level = "info"
  elseif code == "handler_error" then
    level = "error"
  else
    level = "warn"
  end

  local action = "command_executed"
  if not response_ok then
    if code == "bad_message" or code == "not_a_command"
        or code == "missing_command" or code == "bad_args"
        or code == "unknown_command" then
      action = "command_rejected"
    end
  end

  -- Message ID handy for cross-referencing with router arrival logs.
  local msg_id   = (type(msg) == "table") and msg.id      or nil
  local msg_from = (type(msg) == "table") and msg.from    or nil
  local msg_to   = (type(msg) == "table") and msg.to      or nil
  local cor      = (type(msg) == "table") and msg.correlation_id or nil
  if type(cor) ~= "string" or cor == "" then cor = nil end

  local log_fn = log[level]
  local summary
  if response_ok then
    summary = "command ok: " .. tostring((type(msg) == "table") and msg.command or "?")
  else
    summary = string.format("command rejected (%s): %s",
      tostring(code or "?"),
      tostring((type(msg) == "table") and msg.command or "?"))
  end

  log_fn(LOG_COMPONENT, summary, {
    event  = "auto-core.mailbox.commands." .. action,
    fields = {
      command        = (type(msg) == "table") and msg.command or nil,
      ok             = response_ok,
      code           = code,
      error          = response and response.error or nil,
      msg_id         = msg_id,
      msg_from       = msg_from,
      msg_to         = msg_to,
      correlation_id = cor,
      dispatch_path  = (ctx and ctx.reason) or nil,  -- "mailbox_wake" | "mailbox_executioner"
      executor_mbox  = (ctx and ctx.mailbox) or nil,
    },
  })

  return response
end

-- ── schema validator ───────────────────────────────────────

---Minimal schema validator used by `handle_message`. The schema is
---a table keyed by field name; the value is a type-string like
---`"string"`, `"integer"`, `"number"`, `"boolean"`, `"table"`, or
---`"any"`. Append `?` to make a field optional (`"string?"`).
---
---Unknown fields in `args` are permitted (forward-compatibility);
---callers that want strict-shape enforcement can layer their own
---check on top.
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
    if got == nil then
      if not optional then
        return false, "missing required field '" .. field
          .. "' (expected " .. want .. ")", field
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