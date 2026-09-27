---auto-core.fs — filesystem introspection primitives.
---
---Phase 4a ships `fs.path`. Phase 4b adds `fs.watch` (libuv watcher
---publishing `core.file:created/modified/deleted`). Phase 4c adds
---`fs.tree` (`.git`/`.bare`-aware directory walker). ADR-0038 Batch E
---adds `fs.atomic` (shared write-temp→fsync→rename primitive). ADR-0200 adds `fs.scan` (bounded
---single-flight directory reads).
---@module 'auto-core.fs'

local M = {}

M.path   = require("auto-core.fs.path")
M.watch  = require("auto-core.fs.watch")
M.tree   = require("auto-core.fs.tree")
M.atomic = require("auto-core.fs.atomic")
M.scan   = require("auto-core.fs.scan")

return M
