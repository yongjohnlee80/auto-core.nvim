---auto-core.git — git repository introspection.
---
---Phase 4a ships `git.repo`. Phase 4b adds `git.status` (cached
---porcelain). Phase 4c adds `git.worktree` (the canonical worktree
---implementation, REVERSED dep direction per ADR 0006 §"worktree.nvim
---migration plan" — bulk implementation moves here, worktree.nvim
---becomes a thin wrapper).
---@module 'auto-core.git'

local M = {}

M.repo = require("auto-core.git.repo")
-- Phase 4b will attach: M.status   = require("auto-core.git.status")
-- Phase 4c will attach: M.worktree = require("auto-core.git.worktree")

return M
