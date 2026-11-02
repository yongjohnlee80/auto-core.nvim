---auto-core.mailbox.commands — the file mailbox's command envelopes.
---
---The registry itself is `auto-core.commands` (v0.6.0, ADR 1793271500 phase 5): this
---module re-exports it, and keeps only the file-envelope dispatch (`handle_message`,
---`reject_unknown`), which goes with the file mailbox.
---
---@module 'auto-core.mailbox.commands'

local events   = require("auto-core.events")
local log      = require("auto-core.log")
local registry = require("auto-core.commands")

-- Component used on every log entry from this module. Routing the
-- wrapper-rule wakes (auto-core.mailbox.router.dispatch_wake) and the
-- executor-path commands (auto-core.mailbox.router.execute_command)
-- both flow through M.handle_message, so a single log emission here
-- captures every command attempt regardless of dispatch path.
local LOG_COMPONENT = "auto-core.mailbox.commands"

local M = {}

M.register      = registry.register
M.get           = registry.get
M.list          = registry.list
M.unregister    = registry.unregister
M.validate_args = registry.validate_args
M._reset_for_tests = registry._reset_for_tests

---@class AutoCoreCommandResponse
---@field ok    boolean
---@field value any?
---@field error string?
---@field code  string?           -- machine-readable error code on rejections

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
  local spec = registry.get(name)
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
    local v_ok, v_err, v_field = registry.validate_args(args, spec.schema)
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

  -- the sender rides on the handler's ctx (the caller's ctx untouched): a verb that records who
  -- asked (todos.assign's "Assigned by") reads ctx.from
  local hctx = vim.tbl_extend("force", {}, ctx or {}, { from = msg.from })
  local ok_call, ret = pcall(spec.handler, args, hctx)
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

return M
