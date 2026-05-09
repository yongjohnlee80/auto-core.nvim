---Append-only message log for inter-agent communication.
---
---Where `tasks.queue` is "give this agent something to DO",
---`tasks.channel` is "say this in front of everyone (or to a
---specific agent)". Logs survive nvim restart via
---`auto-core.state` namespace `core` key `messages`.
---
---Phase 5 per ADR 0006 + auto-core-todos.
---
---Public surface:
---
---  channel.send(opts)       → message
---  channel.list(filter?)    → message[]
---  channel.recent(n?)       → last `n` messages (default 100)
---  channel.clear()          — drops every message
---
---Each message: { id, from, to?, body, kind, sent_at, sent_at_iso }.
---  `to` nil → broadcast (visible to anyone reading).
---  `kind` one of "info" | "warn" | "error" | "debug" | custom string.
---
---Topics published:
---  agent.message:sent  { id, from, to?, body, kind, sent_at }
---
---Storage:
---  Persists to `state.namespace("core")` key `messages` (json
---  backend). Capped at 1000 entries via FIFO eviction — older
---  messages drop off. Bumping the cap is safe (no migration), but
---  reducing it doesn't retroactively trim — cleanup is on next send.
---
---Cross-restart `id` continuity:
---  `_next_id` bootstraps from the max persisted id on first
---  `send()` so message IDs remain monotonically increasing across
---  sessions. The bootstrap runs lazily.
---@module 'auto-core.tasks.channel'

local events    = require("auto-core.events")
local state_mod = require("auto-core.state")

local M = {}

local MAX_MESSAGES = 1000

local _next_id   = 0
local _bootstrapped = false
local _ns        = nil

local function ns()
  if _ns then return _ns end
  _ns = state_mod.namespace("core", {
    defaults = { messages = {} },
    persist  = "json",
  })
  return _ns
end

---Lazy bootstrap of `_next_id` from persisted messages so IDs stay
---monotonically increasing across nvim restarts.
local function bootstrap_next_id()
  if _bootstrapped then return end
  _bootstrapped = true
  local list = ns():get("messages") or {}
  local max = 0
  for _, m in ipairs(list) do
    if type(m.id) == "number" and m.id > max then max = m.id end
  end
  if max >= _next_id then _next_id = max end
end

---Format a UTC ISO-8601 timestamp from a uv.now() ms reading.
---Used for human-readable display and for cross-tool grep.
---@param uv_now_ms integer
---@return string
local function iso_from_uv_ms(uv_now_ms)
  local t = math.floor(uv_now_ms / 1000)
  -- vim.fn.strftime defaults to local time; override via vim.uv.utime
  -- isn't available, so use os.date with !"format" for UTC.
  return tostring(os.date("!%Y-%m-%dT%H:%M:%SZ", t))
end

---@class AutoCoreMessageOpts
---@field from string                              -- required: sender (agent name)
---@field to   string?                             -- optional: receiver (nil = broadcast)
---@field body string                              -- the message body
---@field kind ("info"|"warn"|"error"|"debug"|string)?  -- default "info"

---@class AutoCoreMessage
---@field id          integer
---@field from        string
---@field to          string?
---@field body        string
---@field kind        string
---@field sent_at     integer    -- vim.uv.now() ms
---@field sent_at_iso string     -- UTC ISO-8601

---Append a message. Returns the message record. Publishes
---`agent.message:sent` with the same payload.
---@param opts AutoCoreMessageOpts
---@return AutoCoreMessage
function M.send(opts)
  assert(type(opts) == "table",
    "auto-core.tasks.channel.send: opts table required")
  assert(type(opts.from) == "string" and #opts.from > 0,
    "auto-core.tasks.channel.send: opts.from must be a non-empty string")
  assert(type(opts.body) == "string",
    "auto-core.tasks.channel.send: opts.body must be a string")

  bootstrap_next_id()
  _next_id = _next_id + 1

  local now_ms = vim.uv.now()
  local msg = {
    id          = _next_id,
    from        = opts.from,
    to          = opts.to,
    body        = opts.body,
    kind        = opts.kind or "info",
    sent_at     = now_ms,
    sent_at_iso = iso_from_uv_ms(now_ms),
  }

  local list = ns():get("messages") or {}
  list[#list + 1] = msg
  -- Cap at MAX_MESSAGES with FIFO eviction. table.remove(t, 1) is
  -- O(n); rare cleanup makes that fine — channels grow slowly.
  while #list > MAX_MESSAGES do
    table.remove(list, 1)
  end
  ns():set("messages", list)

  events.publish("agent.message:sent", msg)
  return msg
end

---@class AutoCoreMessageFilter
---@field from  string?     -- match exact sender
---@field to    string?     -- match exact receiver (use "" to filter for broadcasts only)
---@field since integer?    -- only messages where sent_at >= this (uv.now() ms)
---@field kind  string?     -- match exact kind

---List messages, optionally filtered.
---@param filter AutoCoreMessageFilter?
---@return AutoCoreMessage[]
function M.list(filter)
  filter = filter or {}
  local out = {}
  local broadcast_only = filter.to == ""
  for _, m in ipairs(ns():get("messages") or {}) do
    local keep = true
    if filter.from and m.from ~= filter.from        then keep = false end
    if not broadcast_only and filter.to
        and m.to ~= filter.to                        then keep = false end
    if broadcast_only   and m.to ~= nil              then keep = false end
    if filter.since     and m.sent_at < filter.since then keep = false end
    if filter.kind      and m.kind ~= filter.kind    then keep = false end
    if keep then out[#out + 1] = m end
  end
  return out
end

---Last `n` messages (default 100). Convenience over `list()` for the
---`:AutoCoreChannel` UI's render path.
---@param n integer?
---@return AutoCoreMessage[]
function M.recent(n)
  n = n or 100
  local list = ns():get("messages") or {}
  if #list <= n then return list end
  local out = {}
  for i = #list - n + 1, #list do out[#out + 1] = list[i] end
  return out
end

---Drop every message. Idempotent.
function M.clear()
  ns():set("messages", {})
end

---Test-only: clear messages + reset bootstrap state so next send
---re-bootstraps from the (cleared) persisted list.
function M._reset_for_tests()
  if _ns then pcall(function() _ns:set("messages", {}) end) end
  _ns           = nil
  _next_id      = 0
  _bootstrapped = false
end

M.MAX_MESSAGES = MAX_MESSAGES

return M
