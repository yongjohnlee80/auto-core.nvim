---auto-core.lsp — LSP-related primitives.
---
---Currently exposes:
---  M.reset    -- tech-stack-aware restart-on-workspace-switch
---             (see auto-core/lsp/reset.lua + ADR 0007 §1.1)
---@module 'auto-core.lsp'

local M = {}

M.reset = require("auto-core.lsp.reset")

return M
