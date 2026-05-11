---Per-agent status surface — canonical idle/waiting/working state.
---
---Phase 5 per ADR 0006 + auto-core-todos. Lifts the canonical
---STATE MODEL from auto-agents's `status/observer.lua` to a
---reusable surface. The observer mechanics (terminal-buffer
---attachment, libuv timer, pattern-matching for "waiting") stay
---in auto-agents; auto-agents migrates to call `status.set` here
---instead of its private `M.set_status`.
---
---Public surface:
---
---  status.set(agent, state)     -- "idle" | "waiting" | "working" | nil
---  status.get(agent)            → state?
---  status.list()                → table<agent, state>
---  status.clear(agent?)         — drop one or every recorded state
---
---Topics published:
---  agent.status:changed { agent, from, to }
---
---Storage:
---  Session-scoped — module-local table, NOT persisted to disk.
---  Each nvim process keeps its own map; concurrent instances do
---  not clobber each other. State is re-asserted on launch by
---  auto-agents's observer attaching to its terminal buffers.
---  The map shape is `{ [agent_name] = "idle"|"waiting"|"working" }`.
---  Setting nil removes the agent from the map — useful when an
---  agent shuts down or is renamed.
---@module 'auto-core.tasks.status'

local events = require("auto-core.events")

local M = {}

local VALID_STATES = {
  idle    = true,
  waiting = true,
  working = true,
}

-- Per-nvim-process status map. Previously round-tripped through
-- `state.namespace("core")` key `agent_status` with persist="json",
-- which meant concurrent nvim instances clobbered each other's
-- agent telemetry through the shared core.json file. Held in
-- module memory now; auto-agents's observer re-asserts state at
-- startup.
local _status_map = {}

---Set `agent`'s status. Pass nil to clear (e.g. when the agent
---shuts down). Publishes `agent.status:changed` only on transition.
---Idempotent — re-setting the same state is a no-op.
---@param agent string
---@param state ("idle"|"waiting"|"working")?
function M.set(agent, state)
  assert(type(agent) == "string" and #agent > 0,
    "auto-core.tasks.status.set: agent must be a non-empty string")
  if state ~= nil and not VALID_STATES[state] then
    error("auto-core.tasks.status.set: invalid state '" .. tostring(state) ..
      "' — must be 'idle' | 'waiting' | 'working' | nil")
  end
  local prev = _status_map[agent]
  if prev == state then return end
  _status_map[agent] = state  -- nil removes the key in Lua tables
  events.publish("agent.status:changed", {
    agent = agent,
    from  = prev,
    to    = state,
  })
end

---Read `agent`'s current state. Returns nil if not set.
---@param agent string
---@return ("idle"|"waiting"|"working")?
function M.get(agent)
  return _status_map[agent]
end

---Snapshot of every recorded agent's state.
---@return table<string, "idle"|"waiting"|"working">
function M.list()
  return vim.deepcopy(_status_map)
end

---Drop a single agent's recorded state, or every agent's.
---@param agent string?
function M.clear(agent)
  if agent then
    M.set(agent, nil)
  else
    -- Bulk clear — emit one event per cleared agent so subscribers
    -- can react. This matches the granularity of `set`. Snapshot
    -- the keys first so we don't mutate the table mid-iteration.
    local names = {}
    for name, _ in pairs(_status_map) do names[#names + 1] = name end
    for _, name in ipairs(names) do M.set(name, nil) end
  end
end

---Test-only: clear session-scoped storage so smoke tests start clean.
function M._reset_for_tests()
  _status_map = {}
end

M.VALID_STATES = VALID_STATES

return M
