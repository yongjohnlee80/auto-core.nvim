---auto-core.tasks — agent task queue, message channel, status surface.
---
---Phase 5 per ADR 0006 + auto-core-todos. Three coordinated subsystems
---for cross-agent communication:
---
---  M.queue   — per-agent FIFO + priority dispatch (in-memory)
---  M.channel — append-only inter-agent message log (persistent)
---  M.status  — canonical idle/waiting/working state per agent
---  M.ui      — `:AutoCoreChannel` panel host (see plugin/auto-core.lua)
---
---Each submodule is independent; consumers can require any subset.
---@module 'auto-core.tasks'

local M = {}

M.queue   = require("auto-core.tasks.queue")
M.channel = require("auto-core.tasks.channel")
M.status  = require("auto-core.tasks.status")
M.ui      = require("auto-core.tasks.ui")

return M
