---Pub/sub event bus for the AutoVim plugin family.
---
---Synchronous-default dispatch with per-subscriber pcall isolation,
---a configurable reentrancy cap, an opt-in autocmd-fire compatibility
---shim, glob-style pattern subscription, and a ring-buffer trace
---feeding `:AutoCoreEventTrace`.
---
---API per ADR 0006 §1:
---
---  M.subscribe(topic, fn)        → handle      (exact OR pattern)
---  M.unsubscribe(handle)
---  M.once(topic, fn)             → handle
---  M.publish(topic, payload?)    → ok, errors  (sync)
---  M.publish_async(topic, ...)   defers via vim.schedule
---
---Topic naming convention (also enforced by the registry in
---`auto-core.events.topics`):
---
---    <namespace>[.<sub>]:<event>
---
---e.g. `core.cwd:changed`, `panel:opened`, `agent.task:queued`.
---Patterns use `*` to match a single path segment between
---`.` / `:` separators:
---
---    "agent.*"      matches agent.task:queued, agent.status:changed
---    "*:opened"     matches panel:opened, ... (one segment before `:opened`)
---    "agent.task:*" matches agent.task:queued, agent.task:completed
---
---@module 'auto-core.events'

local M = {}

local trace = require("auto-core.events.trace")
local topics_registry = require("auto-core.events.topics")

-- ── module state ───────────────────────────────────────────────
local _next_id = 1

---@class AutoCoreSubHandle
---@field id integer
---@field topic string
---@field callback fun(payload?: any, topic?: string)
---@field once boolean
---@field is_pattern boolean
---@field _pattern_lua string?  -- precompiled lua pattern for wildcard subs
---@field _unsubscribed boolean

---Exact-topic subscribers: topic → handle list (registration order).
---@type table<string, AutoCoreSubHandle[]>
local _exact = {}

---Pattern subscribers: single flat list, scanned per publish.
---@type AutoCoreSubHandle[]
local _patterns = {}

-- Reentrancy guard. Tracks publish-call depth GLOBALLY so a runaway
-- A→B→A loop is capped regardless of which topics are involved.
local _depth = 0
local MAX_REENTRY = 8

-- ── public API toggles (set by setup) ──────────────────────────
local _fire_autocmds = false
local _strict_topics = false

---Configure events module. Called by `auto-core.setup` so consumers
---don't reach in here directly.
---@param opts { fire_autocmds: boolean?, strict_topics: boolean?, trace_capacity: integer? }?
function M.configure(opts)
  opts = opts or {}
  if opts.fire_autocmds ~= nil then _fire_autocmds = opts.fire_autocmds == true end
  if opts.strict_topics ~= nil then _strict_topics = opts.strict_topics == true end
  if opts.trace_capacity ~= nil then trace.configure(opts.trace_capacity) end
end

-- ── internal helpers ───────────────────────────────────────────

---Detect whether a topic string is a pattern (contains `*`).
---@param topic string
---@return boolean
local function is_pattern(topic)
  return topic:find("*", 1, true) ~= nil
end

---Convert a glob-style pattern (`*`) to an anchored Lua pattern. The
---wildcard is GREEDY — `*` matches any non-empty sequence including
---`.` and `:` separators. So `agent.*` matches `agent.task:queued`
---AND `agent.status:changed` AND `agent.kb.ingest:done`. This
---matches the ADR §1's description: `agent.*` matches every event
---in the agent namespace, period. If a stricter "single-segment"
---wildcard is needed in the future, we'll add `**` for greedy and
---reserve `*` for single-segment — but that's a YAGNI we'll wait
---for.
---@param glob string
---@return string lua_pattern
local function compile_pattern(glob)
  -- Escape Lua magic chars first, then translate the escaped `%*`
  -- back to our wildcard. Ordering matters — if we replaced `*`
  -- before escaping, the wildcard's `.+` would itself be re-escaped
  -- and break.
  local escaped = glob:gsub("([%%%-%.%+%[%]%(%)%^%$%?])", "%%%1")
  escaped = escaped:gsub("%*", ".+")
  return "^" .. escaped .. "$"
end

---Warn about an unregistered topic when strict mode is on.
local function maybe_warn_unregistered(topic)
  if not _strict_topics then return end
  if topics_registry[topic] then return end
  -- Don't error — just notify. The publish proceeds.
  vim.schedule(function()
    vim.notify(
      "auto-core.events: unregistered topic '" .. topic ..
        "' (strict mode). Add an entry in events/topics.lua to silence.",
      vim.log.levels.WARN
    )
  end)
end

---Match a published topic against every pattern subscriber.
---@param topic string
---@return AutoCoreSubHandle[]
local function pattern_matches(topic)
  local out = {}
  for _, h in ipairs(_patterns) do
    if not h._unsubscribed and topic:match(h._pattern_lua) then
      out[#out + 1] = h
    end
  end
  return out
end

---Translate a topic name to an autocmd User-pattern. nvim's autocmd
---patterns disallow `:` and certain other chars; flatten to `_`.
---@param topic string
---@return string
local function topic_to_autocmd_pattern(topic)
  return "AutoCore_" .. (topic:gsub("[%.%:]", "_"))
end

-- ── public API ─────────────────────────────────────────────────

---Subscribe to a topic. The topic may be exact (e.g. `panel:opened`)
---or a glob pattern (e.g. `agent.*`). Returns a handle suitable for
---passing back to `M.unsubscribe`.
---@param topic string
---@param callback fun(payload?: any, topic?: string)
---@return AutoCoreSubHandle
function M.subscribe(topic, callback)
  assert(type(topic) == "string" and #topic > 0,
    "auto-core.events.subscribe: topic must be a non-empty string")
  assert(type(callback) == "function",
    "auto-core.events.subscribe: callback must be a function")

  local handle = {
    id            = _next_id,
    topic         = topic,
    callback      = callback,
    once          = false,
    is_pattern    = is_pattern(topic),
    _unsubscribed = false,
  }
  _next_id = _next_id + 1

  if handle.is_pattern then
    handle._pattern_lua = compile_pattern(topic)
    table.insert(_patterns, handle)
  else
    _exact[topic] = _exact[topic] or {}
    table.insert(_exact[topic], handle)
  end
  return handle
end

---One-shot subscribe — auto-unsubscribes after the first fire.
---@param topic string
---@param callback fun(payload?: any, topic?: string)
---@return AutoCoreSubHandle
function M.once(topic, callback)
  local handle = M.subscribe(topic, callback)
  handle.once = true
  return handle
end

---Unsubscribe a handle returned from `subscribe` or `once`.
---Idempotent — calling twice is harmless.
---@param handle AutoCoreSubHandle
function M.unsubscribe(handle)
  if not handle or handle._unsubscribed then return end
  handle._unsubscribed = true

  -- Remove from the appropriate list. We don't compact eagerly during
  -- dispatch (see publish() — uses _unsubscribed flag); compact here.
  if handle.is_pattern then
    for i, h in ipairs(_patterns) do
      if h.id == handle.id then table.remove(_patterns, i); break end
    end
  else
    local list = _exact[handle.topic]
    if list then
      for i, h in ipairs(list) do
        if h.id == handle.id then table.remove(list, i); break end
      end
      if #list == 0 then _exact[handle.topic] = nil end
    end
  end
end

---Publish a topic synchronously. Subscribers fire in registration
---order (exact first, then patterns). Each subscriber is wrapped in
---`pcall`; a failing subscriber logs but does not break the chain.
---
---Returns (subscribers_invoked, errors_caught) so callers and the
---trace ring can record dispatch shape.
---@param topic string
---@param payload? any
---@return integer subscribers_invoked
---@return integer errors_caught
function M.publish(topic, payload)
  assert(type(topic) == "string" and #topic > 0,
    "auto-core.events.publish: topic must be a non-empty string")

  -- Reentrancy guard.
  if _depth >= MAX_REENTRY then
    vim.schedule(function()
      vim.notify(
        "auto-core.events: reentrancy cap hit (depth " .. MAX_REENTRY ..
          ") on topic '" .. topic .. "' — publish dropped",
        vim.log.levels.ERROR
      )
    end)
    trace.record(topic, payload, 0, 1)
    return 0, 1
  end

  maybe_warn_unregistered(topic)

  -- Snapshot the subscriber lists. We iterate the snapshot because a
  -- subscriber may unsubscribe itself (or others) during dispatch;
  -- iterating the live list while mutating it is unsafe.
  local exact_subs = _exact[topic] or {}
  local pattern_subs = pattern_matches(topic)

  local snap = {}
  for _, h in ipairs(exact_subs) do
    if not h._unsubscribed then snap[#snap + 1] = h end
  end
  for _, h in ipairs(pattern_subs) do
    snap[#snap + 1] = h
  end

  local invoked, errors = 0, 0
  _depth = _depth + 1
  for _, h in ipairs(snap) do
    if not h._unsubscribed then
      invoked = invoked + 1
      local ok, err = pcall(h.callback, payload, topic)
      if not ok then
        errors = errors + 1
        vim.schedule(function()
          vim.notify(
            "auto-core.events: subscriber for '" .. topic ..
              "' raised: " .. tostring(err),
            vim.log.levels.ERROR
          )
        end)
      end
      if h.once then M.unsubscribe(h) end
    end
  end
  _depth = _depth - 1

  trace.record(topic, payload, invoked, errors)

  -- Optional autocmd-fire compat shim (off by default per ADR §6).
  if _fire_autocmds then
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = topic_to_autocmd_pattern(topic),
      data    = payload,
    })
  end

  return invoked, errors
end

---Publish asynchronously via `vim.schedule`. Useful for hot paths
---like libuv fs-watcher callbacks where we must not block the
---callback. Same return contract as `publish` is NOT available
---(dispatch happens on the next tick).
---@param topic string
---@param payload? any
function M.publish_async(topic, payload)
  vim.schedule(function() M.publish(topic, payload) end)
end

-- ── inspection helpers (test + diagnostic surface) ─────────────

---Number of currently-registered subscribers for a given topic
---(exact + matching patterns). Useful in tests + `:checkhealth`.
---@param topic string
---@return integer
function M.count_subscribers(topic)
  local n = 0
  for _, h in ipairs(_exact[topic] or {}) do
    if not h._unsubscribed then n = n + 1 end
  end
  for _, h in ipairs(_patterns) do
    if not h._unsubscribed and topic:match(h._pattern_lua) then
      n = n + 1
    end
  end
  return n
end

---Test-only: reset all subscriber state. Production code never
---calls this. Smoke tests use it between cases for isolation.
function M._reset_for_tests()
  _exact = {}
  _patterns = {}
  _depth = 0
  _next_id = 1
  trace.clear()
end

-- Re-export the trace module so consumers / tests can introspect.
M.trace = trace

return M
