---auto-core.ui — UI primitives for the AutoVim plugin family.
---
---Aggregates the panel, winbar, and section sub-modules into one
---table so consumers can `local ui = require("auto-core").ui` and
---reach `ui.panel.new`, `ui.winbar.render`, `ui.section.attach`
---without three separate requires.
---@module 'auto-core.ui'

local M = {}

M.panel   = require("auto-core.ui.panel")
M.winbar  = require("auto-core.ui.winbar")
M.section = require("auto-core.ui.section")

return M
