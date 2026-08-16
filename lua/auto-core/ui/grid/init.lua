---auto-core.ui.grid — tabular result rendering, split model / view.
---
---`grid.model(opts)` is PURE: columns, raw values, display text, column
---widths, CSV and JSON serialization. No windows, no buffers, no
---autocmds — every rule it implements is testable headlessly.
---
---The view half (added alongside) owns the effects: the rendered
---buffer, the cell cursor, the winbar header and the window options it
---borrows. Keeping them apart is what lets the data rules be verified
---without a database, a server, or a UI — and the split is deliberate:
---a headless test cannot observe `WinScrolled`, because Neovim only
---fires it when a UI is attached to drive a redraw. Anything the model
---owns stays testable; anything that needs a real window is the view's.
---@module 'auto-core.ui.grid'

local model = require("auto-core.ui.grid.model")
local view = require("auto-core.ui.grid.view")

local M = {}

---model builds a grid data model. See `auto-core.ui.grid.model`.
M.model = model.new

---attach binds a model to a window. See `auto-core.ui.grid.view`.
M.attach = view.attach

---render_header turns a raw header into a winbar value, clipping by
---`leftcol` FIRST and escaping second.
---
---This is the only supported header composition. `clip_header` and
---`escape_statusline` stay on `auto-core.ui.grid.view` (internal, and
---reachable for tests) and are deliberately NOT re-exported here:
---published side by side with this one they invite the wrong order,
---which shifts every label after a literal `%` and can leave a live
---statusline item where a `%%` pair was cut in half.
M.render_header = view.render_header

---NULL is the sentinel for a missing value when `vim.NIL` is awkward.
M.NULL = model.NULL

-- Value-level helpers, exposed because consumers (yank, detail modal,
-- the JSON view) need the SAME rules the grid renders with.
M.display_text = model.display_text
M.raw_text     = model.raw_text
M.csv_field    = model.csv_field
M.json_value   = model.json_value
M.is_printable = model.is_printable
M.truncate     = model.truncate
M.column_at    = model.column_at

return M
