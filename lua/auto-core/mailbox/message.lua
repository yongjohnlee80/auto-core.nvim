---auto-core.mailbox.message — baseline message shape, id/timestamp
---generation, and validation.
---
---Messages are JSON files on disk. This module is the single source
---of truth for what a well-formed mailbox message looks like —
---producers and consumers both validate against it.
---
---Baseline shape (per ADR 0013 §2):
---
---  {
---    "id":              "<monotonic-ms>-<rand-hex>",
---    "kind":            "message" | "command" | "response" | "event",
---    "from":            "agent:gemini",
---    "to":              "agent:lector",
---    "subject":         "Ready for review",
---    "body":            "Implementation is complete on branch ...",
---    "command":         null,
---    "args":            {},
---    "reply_to":        null,
---    "correlation_id":  null,
---    "status":          "queued",
---    "created_at":      "2026-05-14T00:00:00Z",
---    "expires_at":      null
---  }
---
---@module 'auto-core.mailbox.message'

local M = {}

M.KINDS = { message = true, command = true, response = true, event = true }

-- Monotonic counter so two messages produced within the same
-- millisecond still get distinct ids. Combined with the random
-- suffix this gives stable ordering even under bursts.
local _seq = 0

-- ── helpers ──────────────────────────────────────────────────

---Return an ISO-8601 UTC timestamp (`2026-05-14T00:00:00Z`).
---@return string
function M.now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

---Generate a fresh message id: `<ms>-<seq>-<rand>`. The ms component
---is `vim.uv.now()` (monotonic, ms since vim start) plus an offset
---from the wall clock to keep ids globally sortable.
---@return string
function M.new_id()
  _seq = _seq + 1
  local ms = vim.uv.now()
  local rand = string.format("%06x", math.random(0, 0xffffff))
  return string.format("%013d-%04d-%s", ms, _seq, rand)
end

---Fresh correlation id. Reuses the message-id format but distinguishes
---by a `cor-` prefix so log greps separate the two.
---@return string
function M.new_correlation_id()
  return "cor-" .. M.new_id()
end

-- ── construction + validation ────────────────────────────────

---@class AutoCoreMailboxMessageOpts
---@field from           string
---@field to             string
---@field kind           "message"|"command"|"response"|"event"?
---@field subject        string?
---@field body           string?
---@field command        string?
---@field args           table?
---@field reply_to       string?
---@field correlation_id string?
---@field expires_at     string?
---@field id             string?    -- override (rare; tests use this)
---@field created_at     string?    -- override (rare; tests use this)
---@field status         string?    -- override (rare; default "queued")

---Build a message table from caller-supplied fields. Validates the
---input and fills in defaults. Returns msg, err — exactly one is nil.
---@param opts AutoCoreMailboxMessageOpts
---@return table? msg, string? err
function M.build(opts)
  if type(opts) ~= "table" then
    return nil, "message opts must be a table"
  end
  local kind = opts.kind or "message"
  if not M.KINDS[kind] then
    return nil, "invalid message kind: " .. tostring(kind)
  end
  if type(opts.from) ~= "string" or opts.from == "" then
    return nil, "message.from must be a non-empty string"
  end
  if type(opts.to) ~= "string" or opts.to == "" then
    return nil, "message.to must be a non-empty string"
  end
  if kind == "command" then
    if type(opts.command) ~= "string" or opts.command == "" then
      return nil, "kind='command' requires a non-empty command name"
    end
  end
  if kind == "response" then
    if (opts.reply_to == nil or opts.reply_to == "")
        and (opts.correlation_id == nil or opts.correlation_id == "")
    then
      return nil, "kind='response' requires reply_to or correlation_id"
    end
  end

  local msg = {
    id             = opts.id             or M.new_id(),
    kind           = kind,
    from           = opts.from,
    to             = opts.to,
    subject        = opts.subject        or vim.NIL,
    body           = opts.body           or vim.NIL,
    command        = opts.command        or vim.NIL,
    args           = opts.args           or vim.empty_dict(),
    reply_to       = opts.reply_to       or vim.NIL,
    correlation_id = opts.correlation_id or vim.NIL,
    status         = opts.status         or "queued",
    created_at     = opts.created_at     or M.now_iso(),
    expires_at     = opts.expires_at     or vim.NIL,
  }
  return msg
end

---Validate a message loaded from disk. Returns ok, err? — checks
---only the contract fields the transport relies on. Callers that
---need stricter (per-command) schema checks layer them on top.
---@param msg table
---@return boolean ok, string? err
function M.validate(msg)
  if type(msg) ~= "table" then return false, "message is not a table" end
  if type(msg.id) ~= "string" or msg.id == "" then
    return false, "message.id missing"
  end
  if not M.KINDS[msg.kind] then
    return false, "message.kind invalid: " .. tostring(msg.kind)
  end
  if type(msg.from) ~= "string" or msg.from == "" then
    return false, "message.from missing"
  end
  if type(msg.to) ~= "string" or msg.to == "" then
    return false, "message.to missing"
  end
  if msg.kind == "command"
      and (type(msg.command) ~= "string" or msg.command == "")
  then
    return false, "command message missing command name"
  end
  return true
end

---Encode a message table to a JSON string. Centralized so we can
---swap encoders if needed (vim.json is the current choice — fast +
---always available in nvim 0.10+).
---@param msg table
---@return string
function M.encode(msg)
  return vim.json.encode(msg)
end

---Decode JSON text into a message table. Returns msg, err? — never
---throws on malformed input; the caller decides how to surface it.
---@param text string
---@return table? msg, string? err
function M.decode(text)
  if type(text) ~= "string" or text == "" then
    return nil, "decode: empty input"
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then return nil, "decode: " .. tostring(decoded) end
  if type(decoded) ~= "table" then
    return nil, "decode: top-level value is not an object"
  end
  return decoded
end

---Test-only — resets the monotonic counter so id strings are stable
---across test cases that don't care about cross-test ordering.
function M._reset_for_tests()
  _seq = 0
end

return M