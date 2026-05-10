---auto-core.git — git repository introspection.
---
---Phase 4a ships `git.repo`. Phase 4b adds `git.status` (cached
---porcelain, auto-invalidated by `core.file:*` events). Phase 4c
---adds `git.worktree` — the **canonical worktree implementation**
---(REVERSED dep direction per ADR 0006 §"worktree.nvim migration
---plan"). Bulk worktree logic lives here; worktree.nvim becomes a
---thin wrapper that preserves its public API for external users.
---@module 'auto-core.git'

local M = {}

M.repo     = require("auto-core.git.repo")
M.status   = require("auto-core.git.status")
M.worktree = require("auto-core.git.worktree")
M.graph    = require("auto-core.git.graph")
M.fetch    = require("auto-core.git.fetch")
M.pull     = require("auto-core.git.pull")

return M
