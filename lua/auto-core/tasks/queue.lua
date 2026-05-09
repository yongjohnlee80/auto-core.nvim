---Per-agent task queue with FIFO + priority dispatch.
---
---Replaces ad-hoc "send a thing to agent X" patterns scattered
---across the family. Phase 5 per ADR 0006 + auto-core-todos.
---
---Public surface:
---
---  queue.enqueue(agent, opts)   → task
---  queue.claim(agent)            → task?      -- highest priority queued
---  queue.peek(agent)             → task?      -- without claiming
---  queue.complete(task_id, result?)  → boolean
---  queue.list(agent?)            → task[]
---  queue.clear(agent?)           — drops queued+claimed tasks
---
---Each task: { id, agent, payload, priority, status, queued_at,
---claimed_at?, completed_at?, result? }.
---
---Priority ordering (claim picks the lowest rank first):
---  urgent < high < normal < low
---
---Within a priority, FIFO (`queued_at` ascending). The dispatch is
---STABLE — two enqueues with the same priority claim in the order
---they were added.
---
---Topics published:
---  agent.task:queued    { id, agent, priority }
---  agent.task:claimed   { id, agent }
---  agent.task:completed { id, agent, result }
---
---In-memory only at this phase. Cross-restart persistence can layer
---on later by snapshotting `_by_agent` to `state.namespace("core")`.
---For now the queue is session-local — agents that need durable
---inboxes can use `tasks.channel` (which IS persisted).
---@module 'auto-core.tasks.queue'

local events = require("auto-core.events")

local M = {}

local PRIORITY_RANK = {
  urgent = 0,
  high   = 1,
  normal = 2,
  low    = 3,
}

local _next_id  = 0
---@type table<string, AutoCoreTask[]>  -- agent → tasks (queued + claimed; completed are removed)
local _by_agent = {}
---@type table<integer, AutoCoreTask>
local _by_id    = {}

---@class AutoCoreTaskOpts
---@field payload      any?
---@field priority     "urgent"|"high"|"normal"|"low"?  -- default "normal"

---@class AutoCoreTask
---@field id            integer
---@field agent         string
---@field payload       any?
---@field priority      "urgent"|"high"|"normal"|"low"
---@field status        "queued"|"claimed"|"completed"
---@field queued_at     integer            -- vim.uv.now() ms
---@field claimed_at    integer?
---@field completed_at  integer?
---@field result        any?

---Enqueue a task for `agent`. Returns the task record.
---@param agent string
---@param opts  AutoCoreTaskOpts?
---@return AutoCoreTask
function M.enqueue(agent, opts)
  assert(type(agent) == "string" and #agent > 0,
    "auto-core.tasks.queue.enqueue: agent must be a non-empty string")
  opts = opts or {}
  local priority = opts.priority or "normal"
  assert(PRIORITY_RANK[priority] ~= nil,
    "auto-core.tasks.queue.enqueue: invalid priority: " .. tostring(priority))

  _next_id = _next_id + 1
  local task = {
    id        = _next_id,
    agent     = agent,
    payload   = opts.payload,
    priority  = priority,
    status    = "queued",
    queued_at = vim.uv.now(),
  }
  _by_id[task.id] = task
  _by_agent[agent] = _by_agent[agent] or {}
  _by_agent[agent][#_by_agent[agent] + 1] = task

  events.publish("agent.task:queued", {
    id       = task.id,
    agent    = agent,
    priority = priority,
  })
  return task
end

---Pick the highest-priority queued task for `agent` WITHOUT
---transitioning it. Returns nil if none.
---@param agent string
---@return AutoCoreTask?
function M.peek(agent)
  local q = _by_agent[agent]
  if not q then return nil end
  local best, best_rank, best_queued = nil, math.huge, math.huge
  for _, t in ipairs(q) do
    if t.status == "queued" then
      local rank = PRIORITY_RANK[t.priority]
      -- Stable: ties broken by FIFO order via queued_at ascending.
      if rank < best_rank
          or (rank == best_rank and t.queued_at < best_queued) then
        best, best_rank, best_queued = t, rank, t.queued_at
      end
    end
  end
  return best
end

---Claim the highest-priority queued task for `agent`. Transitions
---it from "queued" → "claimed", stamps `claimed_at`, publishes
---`agent.task:claimed`. Returns nil if no queued task.
---@param agent string
---@return AutoCoreTask?
function M.claim(agent)
  local t = M.peek(agent)
  if not t then return nil end
  t.status     = "claimed"
  t.claimed_at = vim.uv.now()
  events.publish("agent.task:claimed", {
    id    = t.id,
    agent = agent,
  })
  return t
end

---Mark a claimed task as complete. Stamps `completed_at`, attaches
---`result`, removes from the agent's active queue, publishes
---`agent.task:completed`. Returns false if the id isn't known or
---the task isn't claimed.
---@param task_id integer
---@param result  any?
---@return boolean
function M.complete(task_id, result)
  local t = _by_id[task_id]
  if not t then return false end
  if t.status == "completed" then return false end
  t.status       = "completed"
  t.completed_at = vim.uv.now()
  t.result       = result

  -- Remove from active per-agent list (kept by_id for late lookup).
  local q = _by_agent[t.agent]
  if q then
    for i, e in ipairs(q) do
      if e.id == task_id then table.remove(q, i); break end
    end
  end

  events.publish("agent.task:completed", {
    id     = t.id,
    agent  = t.agent,
    result = result,
  })
  return true
end

---List tasks. With `agent`, returns just that agent's active queue
---(queued + claimed, in insertion order). Without, returns every
---active task across every agent.
---@param agent string?
---@return AutoCoreTask[]
function M.list(agent)
  if agent then
    local q = _by_agent[agent]
    if not q then return {} end
    local out = {}
    for _, t in ipairs(q) do out[#out + 1] = t end
    return out
  end
  local all = {}
  for _, q in pairs(_by_agent) do
    for _, t in ipairs(q) do all[#all + 1] = t end
  end
  return all
end

---Drop pending+claimed tasks. With `agent`, only that one;
---without, every queue is wiped. Completed tasks are not affected
---(they're already removed from the active queue).
---@param agent string?
function M.clear(agent)
  if agent then
    _by_agent[agent] = nil
  else
    _by_agent = {}
    -- _by_id intentionally retained for completed-task lookups.
  end
end

---Test-only — clears every queue + the id counter.
function M._reset_for_tests()
  _by_agent = {}
  _by_id    = {}
  _next_id  = 0
end

M.PRIORITY_RANK = PRIORITY_RANK

return M
