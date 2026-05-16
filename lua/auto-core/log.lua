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

---@type { level: integer, ring_capacity: integer, notify: boolean }
local _cfg = {
  level         = M.levels.INFO,
  ring_capacity = DEFAULT_RING_CAPACITY,
  notify        = true,
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
}

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

  -- vim.schedule the user-visible side-effect: dispatch may be
  -- called from libuv callbacks where `vim.notify` is unsafe.
  vim.schedule(function()
    if level == M.levels.ERROR then
      pcall(vim.notify, full, vim.log.levels.ERROR, { title = "auto-core" })
    elseif level == M.levels.WARN then
      pcall(vim.notify, full, vim.log.levels.WARN,  { title = "auto-core" })
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
  --   1. If `component` is not a string, treat it as the first message
  --      part and emit with component=nil. Preserves the
  --      auto-agents/claudecode legacy signature.
  --   2. After (1), check whether the LAST parts element is an
  --      options table (sentinel-key detection — see extract_opts).
  --      If so, pop it and pass through to dispatch as the 4th arg.
  local parts
  if type(component) ~= "string" then
    parts = { component, ... }
    component = nil
  else
    parts = { ... }
  end
  local opts = extract_opts(parts)
  dispatch(level, component, parts, opts)
end

function M.error(component, ...) level_call(M.levels.ERROR, component, ...) end
function M.warn(component, ...)  level_call(M.levels.WARN,  component, ...) end
function M.info(component, ...)  level_call(M.levels.INFO,  component, ...) end
function M.debug(component, ...) level_call(M.levels.DEBUG, component, ...) end
function M.trace(component, ...) level_call(M.levels.TRACE, component, ...) end

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

-- ── inspection helpers (used by :checkhealth) ────────────────

---Active config snapshot. Test + introspection use only — don't
---mutate the returned table.
---@return { level: integer, ring_capacity: integer, notify: boolean, count: integer }
function M.inspect()
  return {
    level         = _cfg.level,
    ring_capacity = _cfg.ring_capacity,
    notify        = _cfg.notify,
    count         = _count,
  }
end

---Test-only — clears the ring AND restores defaults.
function M._reset_for_tests()
  _ring         = {}
  _next_idx     = 1
  _count        = 0
  _cfg.level    = M.levels.INFO
  _cfg.notify   = true
  _cfg.ring_capacity = DEFAULT_RING_CAPACITY
end

return M
