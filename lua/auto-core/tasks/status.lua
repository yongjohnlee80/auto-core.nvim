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
---  Persists to `state.namespace("core")` key `agent_status`. The
---  state table is a flat `{ [agent_name] = "idle"|"waiting"|"working" }`.
---  Nil state removes the agent from the table — useful when an
---  agent shuts down or is renamed.
---@module 'auto-core.tasks.status'

local events    = require("auto-core.events")
local state_mod = require("auto-core.state")

local M = {}

local VALID_STATES = {
  idle    = true,
  waiting = true,
  working = true,
}

local _ns = nil
local function ns()
  if _ns then return _ns end
  _ns = state_mod.namespace("core", {
    defaults = { agent_status = {} },
    persist  = "json",
  })
  return _ns
end

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
  local map = vim.deepcopy(ns():get("agent_status") or {})
  local prev = map[agent]
  if prev == state then return end
  map[agent] = state  -- nil removes the key in Lua tables
  ns():set("agent_status", map)
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
  local map = ns():get("agent_status") or {}
  return map[agent]
end

---Snapshot of every recorded agent's state.
---@return table<string, "idle"|"waiting"|"working">
function M.list()
  return vim.deepcopy(ns():get("agent_status") or {})
end

---Drop a single agent's recorded state, or every agent's.
---@param agent string?
function M.clear(agent)
  if agent then
    M.set(agent, nil)
  else
    -- Bulk clear — emit one event per cleared agent so subscribers
    -- can react. This matches the granularity of `set`.
    local map = ns():get("agent_status") or {}
    for name, _ in pairs(map) do M.set(name, nil) end
  end
end

---Test-only: clear state + re-claim the namespace.
function M._reset_for_tests()
  if _ns then pcall(function() _ns:set("agent_status", {}) end) end
  _ns = nil
end

M.VALID_STATES = VALID_STATES

return M
