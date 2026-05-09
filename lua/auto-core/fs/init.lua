---auto-core.fs — filesystem introspection primitives.
---
---Phase 4a ships `fs.path`. Phase 4b adds `fs.watch` (libuv watcher
---publishing `core.file:created/modified/deleted`). Phase 4c will
---add `fs.tree` (`.git`/`.bare`-aware walker).
---@module 'auto-core.fs'

local M = {}

M.path  = require("auto-core.fs.path")
M.watch = require("auto-core.fs.watch")
-- Phase 4c will attach: M.tree = require("auto-core.fs.tree")

return M
