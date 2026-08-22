---auto-core.ui — UI primitives for the AutoVim plugin family.
---
---Phase 3 ships panel/winbar/section. Phase 6 adds float (help
---overlay / confirm) and the canonical highlight registry. Grid adds
---tabular result rendering (ADR-0058), shared rather than owned by any
---one frontend.
---
---Aggregates the sub-modules into one table so consumers can
---`local ui = require("auto-core").ui` and reach `ui.panel.new`,
---`ui.winbar.render`, `ui.section.attach`, `ui.float.help_overlay`,
---`ui.grid.model`, `ui.highlights.theme_override` without separate
---requires.
---@module 'auto-core.ui'

local M = {}

M.panel      = require("auto-core.ui.panel")
M.winbar     = require("auto-core.ui.winbar")
M.section    = require("auto-core.ui.section")
M.float      = require("auto-core.ui.float")
M.grid       = require("auto-core.ui.grid")
M.highlights = require("auto-core.ui.highlights")
M.marks      = require("auto-core.ui.marks")

return M
