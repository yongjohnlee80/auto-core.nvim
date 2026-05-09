---Ring-buffer event trace for auto-core's pub/sub bus.
---
---Records the last N events (default 200, configurable via
---`cfg.events.trace_capacity`) so a user diagnosing an event-driven
---bug can see what fired, in what order, with what subscriber count
---and how many errors occurred. Surfaced via `:AutoCoreEventTrace`.
---
---The trace is fully ephemeral — never persisted, never sent
---anywhere. Cheap to keep on by default; the per-publish overhead
---is one table allocation + one wraparound write.
---@module 'auto-core.events.trace'

local M = {}

local DEFAULT_CAP = 200

---@class AutoCoreTraceEntry
---@field ts integer        -- nanoseconds since epoch (vim.uv.hrtime)
---@field topic string
---@field subscribers integer
---@field errors integer
---@field payload_keys string[]  -- top-level keys of the payload (small, no values to avoid leaking secrets)

---@type AutoCoreTraceEntry[]
M._buf = {}
M._cap = DEFAULT_CAP
M._head = 0   -- next write index, modulo cap
M._count = 0  -- number of entries actually written (caps at _cap)

---Configure the trace capacity. Idempotent. Resizing past the
---existing entries truncates the older ones.
---@param cap integer
function M.configure(cap)
  if type(cap) ~= "number" or cap < 1 then return end
  M._cap = math.floor(cap)
  -- Drop entries that no longer fit; preserve the most-recent ones.
  if M._count > M._cap then
    local recent = M.recent(M._cap)
    M._buf = {}
    for i = 1, #recent do M._buf[i - 1] = recent[i] end
    M._head = #recent % M._cap
    M._count = #recent
  end
end

---Append one trace entry. Called by `events.publish` after dispatch.
---@param topic string
---@param payload any
---@param subscribers integer
---@param errors integer
function M.record(topic, payload, subscribers, errors)
  local keys = {}
  if type(payload) == "table" then
    for k in pairs(payload) do
      keys[#keys + 1] = tostring(k)
      if #keys >= 8 then break end  -- bound the listing
    end
  end
  M._buf[M._head] = {
    ts          = vim.uv.hrtime(),
    topic       = topic,
    subscribers = subscribers,
    errors      = errors,
    payload_keys = keys,
  }
  M._head = (M._head + 1) % M._cap
  if M._count < M._cap then M._count = M._count + 1 end
end

---Return the N most-recent entries, oldest-first.
---@param n integer?  -- defaults to all available
---@return AutoCoreTraceEntry[]
function M.recent(n)
  n = n or M._count
  if n > M._count then n = M._count end
  local out = {}
  -- Walk backwards from head, then reverse.
  local idx = (M._head - 1 + M._cap) % M._cap
  for _ = 1, n do
    out[#out + 1] = M._buf[idx]
    idx = (idx - 1 + M._cap) % M._cap
  end
  -- Reverse in place to oldest-first.
  for i = 1, math.floor(#out / 2) do
    out[i], out[#out - i + 1] = out[#out - i + 1], out[i]
  end
  return out
end

---Clear the trace. Useful when a user runs the same scenario twice
---and wants a clean window.
function M.clear()
  M._buf = {}
  M._head = 0
  M._count = 0
end

---Format an entry as one display line. Centralized so the
---`:AutoCoreEventTrace` viewer and any test inspection share one
---layout.
---@param e AutoCoreTraceEntry
---@param now_ns integer  -- reference timestamp for relative formatting
---@return string
function M.format_line(e, now_ns)
  local age_ms = (now_ns - e.ts) / 1e6
  local err_marker = e.errors > 0 and (" [errors=" .. e.errors .. "]") or ""
  local keys = (#e.payload_keys > 0)
    and ("  payload={" .. table.concat(e.payload_keys, ",") .. "}") or ""
  return string.format("  %7.1f ms ago  %-40s  subs=%d%s%s",
    age_ms, e.topic, e.subscribers, err_marker, keys)
end

return M
