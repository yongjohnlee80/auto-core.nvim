---Structured logger for the AutoVim family. Phase 7 per ADR 0006.
---
---Replaces each consumer's local `logger.lua` (auto-agents has one
---adapted from claudecode; auto-finder has its own; etc.). Drop-in
---compatible with auto-agents's signature so migration is a search-
---and-replace from `require("auto-agents.logger")` to
---`require("auto-core").log`.
---
---API surface:
---
---  log.configure({ level?, ring_capacity?, notify? })
---  log.error(component?, ...) / .warn / .info / .debug / .trace
---  log.is_level_enabled(name)            → boolean
---  log.recent(n?)                        → entry[]   (oldest first)
---  log.clear()                           — wipe the ring buffer
---  log.namespace(name)                   → handle    -- pre-bound component
---
---Levels (lower = more severe, matching auto-agents/claudecode):
---  ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5
---  Default level: INFO. Level filters BOTH the ring buffer AND
---  the `vim.notify` mirror.
---
---Output sinks:
---  - **ring buffer** — every record at-or-above the active level
---    is appended to an in-memory ring (default capacity 500). Use
---    `log.recent(n)` for diagnostics; `:checkhealth auto-core`
---    surfaces the cap + count.
---  - **vim.notify** — ERROR/WARN go to `vim.notify` with the
---    appropriate severity. INFO/DEBUG/TRACE go to `nvim_echo`
---    (silent unless the user inspects messages). Toggle with
---    `configure({ notify = false })` for fully silent operation.
---
---Format:
---  `[AutoCore]` prefix, optional `[component]`, level tag, then
---  the joined message parts. Tables/booleans are run through
---  `vim.inspect`; strings are concatenated with spaces.
---@module 'auto-core.log'

local M = {}

M.levels = {
  ERROR = 1,
  WARN  = 2,
  INFO  = 3,
  DEBUG = 4,
  TRACE = 5,
}

local LEVEL_NAMES = { "ERROR", "WARN", "INFO", "DEBUG", "TRACE" }
local NAME_TO_LEVEL = {
  error = 1, warn = 2, info = 3, debug = 4, trace = 5,
  ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5,
}

local DEFAULT_RING_CAPACITY = 500

---@class AutoCoreLogConfig
---@field level         (string|integer)?  -- "info" | M.levels.INFO; default "info"
---@field ring_capacity integer?            -- ring buffer size; default 500
---@field notify        boolean?            -- mirror to vim.notify; default true
---@field echo          boolean?            -- v0.1.12+: also `nvim_echo` non-toast emissions
---                                            into `:messages`. Default false (ring-only by
---                                            default). Per-call override via `opts.echo`.

---@type { level: integer, ring_capacity: integer, notify: boolean, echo: boolean }
local _cfg = {
  level         = M.levels.INFO,
  ring_capacity = DEFAULT_RING_CAPACITY,
  notify        = true,
  echo          = false,
}

-- ── ring buffer ─────────────────────────────────────────────

---@class AutoCoreLogEntry
---@field ts         integer  -- vim.uv.now() ms
---@field level      integer  -- 1..5
---@field level_name string   -- "ERROR" | "WARN" | "INFO" | "DEBUG" | "TRACE"
---@field component  string?
---@field message    string
---@field event_type string?  -- registered event id, e.g. "auto-finder.scan.started"
---@field fields     table?   -- structured payload preserved unflattened
---
---ADR 0021 §3 — `event_type` and `fields` are additive optional slots.
---Entries emitted via the pre-existing API (no options table) leave
---both as `nil`. Consumers reading `recent()` must nil-check both.

---@type AutoCoreLogEntry[]
local _ring     = {}
local _next_idx = 1
local _count    = 0

local function ring_push(entry)
  _ring[_next_idx] = entry
  _next_idx = (_next_idx % _cfg.ring_capacity) + 1
  if _count < _cfg.ring_capacity then _count = _count + 1 end
end

-- ── core dispatch ────────────────────────────────────────────

---Stringify the variadic tail. Tables and booleans pass through
---`vim.inspect`; everything else through `tostring`. Joined with
---a single space.
---@param parts any[]
---@return string
local function join_parts(parts)
  local out = {}
  for i, p in ipairs(parts) do
    if type(p) == "table" or type(p) == "boolean" then
      out[i] = vim.inspect(p)
    else
      out[i] = tostring(p)
    end
  end
  return table.concat(out, " ")
end

local function format_prefix(level_name, component)
  local pieces = { "[AutoCore]" }
  if component and #component > 0 then pieces[#pieces + 1] = "[" .. component .. "]" end
  pieces[#pieces + 1] = "[" .. level_name .. "]"
  return table.concat(pieces, " ")
end

---@class AutoCoreLogCallOpts
---@field event          string?           -- registered event id (ADR 0021 §5)
---@field fields         table?            -- structured payload preserved unflattened
---@field notify         boolean|"auto"|nil -- ADR 0021 §4 routing; Phase 1 records but does NOT yet act on it
---@field level_override integer?          -- escalate/downgrade at call site; Phase 1 reserved, not yet honored
local _OPTS_SENTINELS = {
  event          = true,
  fields         = true,
  notify         = true,
  level_override = true,
  echo           = true,
}

---Map a logger level to `vim.log.levels.*` for `vim.notify`.
---@param level integer
---@return integer
local function to_vim_log_level(level)
  if level == M.levels.ERROR then return vim.log.levels.ERROR end
  if level == M.levels.WARN  then return vim.log.levels.WARN  end
  if level == M.levels.INFO  then return vim.log.levels.INFO  end
  if level == M.levels.DEBUG then return vim.log.levels.DEBUG end
  return vim.log.levels.TRACE
end

---Resolve `opts.notify` to a routing decision per ADR 0021 §4.
---  - `true`           → always toast
---  - `false`          → never toast
---  - `"auto"`         → toast iff `opts.event` is subscribed via
---                       `M.events.is_notify_enabled` (Step 3
---                       registry; Phase 1 stub returns false)
---  - `nil` (omitted)  → defer to the level's default sink
---                       (ERROR/WARN → toast, else silent)
---@param opts AutoCoreLogCallOpts?
---@param level integer
---@return boolean
local function should_toast(opts, level)
  local n = opts and opts.notify
  if n == true  then return true  end
  if n == false then return false end
  if n == "auto" then
    if opts and opts.event and M.events and M.events.is_notify_enabled then
      return M.events.is_notify_enabled(opts.event) == true
    end
    return false
  end
  -- Default routing (n == nil): keep the pre-ADR-0021 behavior.
  return level == M.levels.ERROR or level == M.levels.WARN
end

local function dispatch(level, component, message_parts, opts)
  if level > _cfg.level then return end

  local level_name = LEVEL_NAMES[level] or "UNKNOWN"
  local message    = join_parts(message_parts)
  local prefix     = format_prefix(level_name, component)
  local full       = prefix .. " " .. message

  ring_push({
    ts         = vim.uv.now(),
    level      = level,
    level_name = level_name,
    component  = component,
    message    = full,
    event_type = opts and opts.event or nil,
    fields     = opts and opts.fields or nil,
  })

  if not _cfg.notify then return end

  local toast = should_toast(opts, level)
  local title = (opts and opts.title) or "auto-core"

  -- vim.schedule the user-visible side-effect: dispatch may be
  -- called from libuv callbacks where `vim.notify` is unsafe.
  --
  -- v0.1.12 behavior change: when the routing decision is "no toast"
  -- we now stay completely silent — no `nvim_echo` echo to
  -- `:messages`. The ring entry above is the audit trail; `:messages`
  -- spam was the user-visible cost we paid by default and was the
  -- single biggest UX complaint after the Phase 1 ship (busy paths
  -- like `auto-finder.scan` emit one INFO line per scan; over a
  -- session that fills `:messages` with routine noise the user has no
  -- way to opt out of). The replacement audit path is the
  -- in-flight `:AutoCoreLog` viewer (ADR 0021 Phase 4) + the existing
  -- `log.recent()` programmatic surface.
  --
  -- Migrations:
  --   - Users who want the OLD nvim_echo behavior on a per-call
  --     basis: pass `opts.echo = true` (recognized as a sentinel
  --     below).
  --   - Users who want it globally: `log.configure({ echo = true })`.
  if not toast then
    local explicit_echo = (opts and opts.echo == true) or _cfg.echo
    if not explicit_echo then return end
  end

  vim.schedule(function()
    if toast then
      pcall(vim.notify, full, to_vim_log_level(level), { title = title })
    else
      pcall(vim.api.nvim_echo, { { full, "Normal" } }, true, {})
    end
  end)
end

-- ── public level functions ──────────────────────────────────

---Apply (or re-apply) configuration. Idempotent — safe to call
---multiple times. `level` accepts strings ("info") or numerics
---(`M.levels.INFO`).
---@param opts AutoCoreLogConfig?
function M.configure(opts)
  opts = opts or {}
  if opts.level ~= nil then
    if type(opts.level) == "string" then
      _cfg.level = NAME_TO_LEVEL[opts.level] or M.levels.INFO
    elseif type(opts.level) == "number" then
      _cfg.level = opts.level
    end
  end
  if opts.ring_capacity ~= nil and opts.ring_capacity > 0 then
    -- Re-sizing mid-run: clamp the existing ring to the new cap.
    _cfg.ring_capacity = opts.ring_capacity
    if _count > _cfg.ring_capacity then
      _count    = _cfg.ring_capacity
      _next_idx = 1
      -- We don't migrate the contents — at this scale, dropping
      -- the in-flight buffer is fine. Practitioners only resize at
      -- setup time.
      _ring     = {}
    end
  end
  if opts.notify ~= nil then _cfg.notify = opts.notify end
  if opts.echo   ~= nil then _cfg.echo   = opts.echo   end
end

---Extract an options table from the tail of `parts` if (and only if)
---the last element is a table with at least one ADR 0021 §4 sentinel
---key (`event`, `fields`, `notify`, `level_override`). Mutates `parts`
---in place by popping the recognized table; otherwise leaves `parts`
---untouched and returns nil.
---
---**Why sentinel-key detection?** Existing callers pass structured
---tables as ordinary message parts (e.g.
---`log.info("comp", "msg", { path = "/x" })`) and expect them to
---render via `vim.inspect`. A blanket "trailing table = opts" rule
---would silently break every such call site. Sentinel keys are the
---narrow opt-in.
---@param parts any[]
---@return AutoCoreLogCallOpts?
local function extract_opts(parts)
  local n = #parts
  if n == 0 then return nil end
  local last = parts[n]
  if type(last) ~= "table" then return nil end
  for k in pairs(_OPTS_SENTINELS) do
    if last[k] ~= nil then
      parts[n] = nil
      return last
    end
  end
  return nil
end

local function level_call(level, component, ...)
  -- Arg-shape rules:
  --   1a. `component` is a string → use as component, rest is parts.
  --   1b. `component` is nil      → no component, rest is parts.
  --       (Distinguishing nil from non-nil-non-string matters: a leading
  --       nil prepended to `parts` produces an array-length hole that
  --       corrupts `#parts` and any iteration. `M.notify`/`notifyIf`
  --       route here with component=nil when opts.component is omitted.)
  --   1c. `component` is anything else (table / boolean / number) →
  --       treat it as a leading message part for the auto-agents /
  --       claudecode legacy signature compat.
  --   2. After 1a/1b/1c, check whether the LAST parts element is an
  --      options table (sentinel-key detection — see extract_opts).
  --      If so, pop it and pass through to dispatch as the 4th arg.
  local parts
  if type(component) == "string" then
    parts = { ... }
  elseif component == nil then
    parts = { ... }
  else
    parts = { component, ... }
    component = nil
  end
  local opts = extract_opts(parts)
  dispatch(level, component, parts, opts)
end

function M.error(component, ...) level_call(M.levels.ERROR, component, ...) end
function M.warn(component, ...)  level_call(M.levels.WARN,  component, ...) end
function M.info(component, ...)  level_call(M.levels.INFO,  component, ...) end
function M.debug(component, ...) level_call(M.levels.DEBUG, component, ...) end
function M.trace(component, ...) level_call(M.levels.TRACE, component, ...) end

-- ── throttled emission (ADR 0021 §11 — hot-loop guard) ──────

---@type table<string, integer>
local _throttle_last = {}

---Emit at most once per `every_ms` window, bucketed by `key`. Within
---the window subsequent calls are silently dropped — no ring write,
---no toast. Keys are arbitrary strings; use a stable identifier per
---call site (typically a call-site name or a bounded resource
---identifier — never an unbounded stream value, which would leak
---one map entry per distinct value).
---@param level    integer
---@param key      string
---@param every_ms number
---@param component any
local function _throttled_call(level, key, every_ms, component, ...)
  assert(type(key) == "string" and #key > 0,
    "log.<level>_throttled: key must be a non-empty string")
  assert(type(every_ms) == "number" and every_ms > 0,
    "log.<level>_throttled: every_ms must be a positive number")
  local now = vim.uv.now()
  local last = _throttle_last[key]
  if last and (now - last) < every_ms then
    return
  end
  _throttle_last[key] = now
  level_call(level, component, ...)
end

function M.error_throttled(key, every_ms, component, ...)
  _throttled_call(M.levels.ERROR, key, every_ms, component, ...)
end
function M.warn_throttled(key, every_ms, component, ...)
  _throttled_call(M.levels.WARN, key, every_ms, component, ...)
end
function M.info_throttled(key, every_ms, component, ...)
  _throttled_call(M.levels.INFO, key, every_ms, component, ...)
end
function M.debug_throttled(key, every_ms, component, ...)
  _throttled_call(M.levels.DEBUG, key, every_ms, component, ...)
end
function M.trace_throttled(key, every_ms, component, ...)
  _throttled_call(M.levels.TRACE, key, every_ms, component, ...)
end

---True if `level_name` would currently produce output. Useful for
---guarding expensive `vim.inspect` formatting at debug+ levels.
---@param level_name string
---@return boolean
function M.is_level_enabled(level_name)
  local lvl = NAME_TO_LEVEL[level_name]
  if not lvl then return false end
  return lvl <= _cfg.level
end

---Return up to `n` most-recent ring entries, oldest first.
---Default n = full ring contents.
---@param n integer?
---@return AutoCoreLogEntry[]
function M.recent(n)
  n = n or _count
  if _count == 0 then return {} end

  -- Walk from oldest to newest. Oldest index = _next_idx (the
  -- about-to-be-overwritten slot) when full; index 1 when not yet
  -- wrapped.
  local out = {}
  if _count < _cfg.ring_capacity then
    -- Not yet wrapped: 1 .. _count.
    local first = math.max(1, _count - n + 1)
    for i = first, _count do out[#out + 1] = _ring[i] end
  else
    -- Wrapped: oldest = _next_idx (next to be overwritten).
    -- Walk _count slots forward.
    local start = _next_idx
    local skip  = math.max(0, _cfg.ring_capacity - n)
    for i = 0, _cfg.ring_capacity - 1 do
      if i >= skip then
        local idx = ((start - 1 + i) % _cfg.ring_capacity) + 1
        out[#out + 1] = _ring[idx]
      end
    end
  end
  return out
end

---Drop every ring entry and reset the cursor. The active level
---and notify config are NOT touched.
function M.clear()
  _ring     = {}
  _next_idx = 1
  _count    = 0
end

---@class AutoCoreLogHandle
---@field error fun(...)
---@field warn  fun(...)
---@field info  fun(...)
---@field debug fun(...)
---@field trace fun(...)

---Pre-bind a component name onto the level functions. The
---returned handle's methods accept message parts directly:
---
---  local L = require("auto-core").log.namespace("watch")
---  L.info("started", { dir = "/tmp" })
---@param component string
---@return AutoCoreLogHandle
function M.namespace(component)
  return {
    error = function(...) level_call(M.levels.ERROR, component, ...) end,
    warn  = function(...) level_call(M.levels.WARN,  component, ...) end,
    info  = function(...) level_call(M.levels.INFO,  component, ...) end,
    debug = function(...) level_call(M.levels.DEBUG, component, ...) end,
    trace = function(...) level_call(M.levels.TRACE, component, ...) end,
  }
end

-- ── notify / notifyIf (ADR 0021 §5 — single-emission sugar) ─

---@class AutoCoreLogNotifyOpts
---@field level     (string|integer)?  -- default INFO; "warn" / `M.levels.ERROR` etc.
---@field component string?
---@field title     string?            -- vim.notify title; default "auto-core"
---@field fields    table?             -- structured payload preserved on the ring entry

---Single-emission toast + ring write. Use this instead of bare
---`vim.notify(...)` so every visible toast also lands in the ring
---for `:AutoCoreLog` triage. Default level INFO — pass
---`opts.level = "warn"` or similar to escalate. The level filter is
---honored: emissions below the active config level are dropped from
---BOTH ring and toast.
---@param msg any
---@param opts AutoCoreLogNotifyOpts?
function M.notify(msg, opts)
  opts = opts or {}
  local level = opts.level or M.levels.INFO
  if type(level) == "string" then
    level = NAME_TO_LEVEL[level] or M.levels.INFO
  end
  -- Pass via the standard level_call path so the trailing-table
  -- sentinel detection is exercised end-to-end. `notify = true`
  -- forces the toast regardless of severity default.
  level_call(level, opts.component, msg, {
    notify = true,
    fields = opts.fields,
    title  = opts.title,
  })
end

---Ring write + conditional toast. Toasts iff `event` is in the
---user's subscribed set (the registry lookup goes through
---`M.events.is_notify_enabled` against the persistent state
---namespace `auto-core.log.events:notify_subscriptions`). Default
---level INFO.
---@param event string                     -- registered event id (ADR 0021 §5)
---@param msg any
---@param opts AutoCoreLogNotifyOpts?
function M.notifyIf(event, msg, opts)
  opts = opts or {}
  local level = opts.level or M.levels.INFO
  if type(level) == "string" then
    level = NAME_TO_LEVEL[level] or M.levels.INFO
  end
  level_call(level, opts.component, msg, {
    event  = event,
    notify = "auto",
    fields = opts.fields,
    title  = opts.title,
  })
end

-- ── events sub-namespace (ADR 0021 §5 — registry + persistence) ─

---@class AutoCoreLogEventRecord
---@field event  string  -- fully-qualified, dotted, plugin-namespace-prefixed
---@field plugin string  -- owning plugin (the `<plugin>` arg from register)

---@class AutoCoreLogEventsAPI
---@field is_notify_enabled fun(event: string): boolean
---@field register          fun(plugin: string, events: string|string[])
---@field list              fun(plugin: string?): AutoCoreLogEventRecord[]
---@field enable_notify     fun(event: string)
---@field disable_notify    fun(event: string)

-- Module-local registry of declared event types. Re-populated on
-- every nvim startup as plugins call `register()` in setup; NOT
-- persisted (the source of truth is the plugin's `register_events`
-- call in its own setup function — auto-core is just the index).
---@type table<string, { plugin: string }>
local _registered = {}

-- Lazy handle to the persisted state namespace. Loaded on first
-- subscription-API call so log.lua doesn't have to require
-- auto-core.state at top of file (avoids an init-order hazard
-- if log is touched before state is configured).
local _events_ns = nil

local function _events_namespace()
  if _events_ns ~= nil then return _events_ns end
  local ok, state = pcall(require, "auto-core.state")
  if not ok or type(state) ~= "table" then return nil end
  _events_ns = state.namespace("auto-core.log.events", { persist = "json" })
  return _events_ns
end

local function _subs_snapshot()
  local ns = _events_namespace()
  if not ns then return {} end
  return ns:get("notify_subscriptions") or {}
end

-- ADR 0021 §5: enforce plugin-namespace prefixing on registered
-- event names. Wrappers call `register("auto-finder", "scan.started")`
-- and auto-core fully-qualifies to `"auto-finder.scan.started"`.
-- Pre-fully-qualified inputs (already prefixed) are passed through
-- unchanged.
local function _fully_qualify(plugin, event)
  if event == plugin then return event end
  if plugin == "" then return event end
  if event:sub(1, #plugin + 1) == (plugin .. ".") then
    return event
  end
  return plugin .. "." .. event
end

local function _register(plugin, events)
  assert(type(plugin) == "string" and #plugin > 0,
    "log.events.register: plugin must be a non-empty string")
  if type(events) == "string" then events = { events } end
  assert(type(events) == "table",
    "log.events.register: events must be a string or array of strings")
  for _, ev in ipairs(events) do
    assert(type(ev) == "string" and #ev > 0,
      "log.events.register: every event name must be a non-empty string")
    local fq = _fully_qualify(plugin, ev)
    _registered[fq] = { plugin = plugin }
  end
end

local function _list(plugin)
  local out = {}
  for ev, meta in pairs(_registered) do
    if plugin == nil or meta.plugin == plugin then
      out[#out + 1] = { event = ev, plugin = meta.plugin }
    end
  end
  table.sort(out, function(a, b) return a.event < b.event end)
  return out
end

local function _enable_notify(event)
  assert(type(event) == "string" and #event > 0,
    "log.events.enable_notify: event must be a non-empty string")
  local s = vim.deepcopy(_subs_snapshot())
  s[event] = true
  local ns = _events_namespace()
  if ns then ns:set("notify_subscriptions", s) end
end

local function _disable_notify(event)
  assert(type(event) == "string" and #event > 0,
    "log.events.disable_notify: event must be a non-empty string")
  local s = vim.deepcopy(_subs_snapshot())
  s[event] = nil
  local ns = _events_namespace()
  if ns then ns:set("notify_subscriptions", s) end
end

local function _is_notify_enabled(event)
  if type(event) ~= "string" then return false end
  return _subs_snapshot()[event] == true
end

---Event-type registry. Plugins call `register(plugin, events)` at
---`setup()` time; users toggle per-event notification with
---`enable_notify` / `disable_notify`. Subscriptions persist across
---nvim restarts via `auto-core.state.namespace("auto-core.log.events")`
---(json-backed). The registry itself is in-memory only — plugins
---re-declare their events every startup.
---
---Behavioral notes:
---- `register` is idempotent. Re-registering the same event no-ops.
---- `enable_notify` for an unregistered event is honored (tolerant
---  of registration order). When the event is later registered AND
---  emitted via `notifyIf`, the subscription kicks in.
---- `is_notify_enabled` returns `false` if `auto-core.state` is
---  unavailable (e.g. during early test bootstrap) — fail closed.
---@type AutoCoreLogEventsAPI
M.events = {
  register          = _register,
  list              = _list,
  enable_notify     = _enable_notify,
  disable_notify    = _disable_notify,
  is_notify_enabled = _is_notify_enabled,
}

-- ── inspection helpers (used by :checkhealth) ────────────────

---Active config snapshot. Test + introspection use only — don't
---mutate the returned table.
---@return { level: integer, ring_capacity: integer, notify: boolean, echo: boolean, count: integer }
function M.inspect()
  return {
    level         = _cfg.level,
    ring_capacity = _cfg.ring_capacity,
    notify        = _cfg.notify,
    echo          = _cfg.echo,
    count         = _count,
  }
end

---Test-only — clears the ring, restores defaults, and drops the
---in-memory event registry + cached state-namespace handle. Callers
---wanting a clean slate for the persisted subscription set should
---ALSO reset `auto-core.state` (this function deliberately does
---NOT call into the state subsystem to keep the module surface
---narrow).
function M._reset_for_tests()
  _ring         = {}
  _next_idx     = 1
  _count        = 0
  _cfg.level    = M.levels.INFO
  _cfg.notify   = true
  _cfg.echo     = false
  _cfg.ring_capacity = DEFAULT_RING_CAPACITY
  _registered   = {}
  _events_ns    = nil
  _throttle_last = {}
end

return M
