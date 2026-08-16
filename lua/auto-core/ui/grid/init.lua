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

local M = {}

---model builds a grid data model. See `auto-core.ui.grid.model`.
M.model = model.new

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
