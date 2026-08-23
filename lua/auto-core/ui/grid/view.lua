---Window-owning half of `auto-core.ui.grid` — the EFFECTS.
---
---A view binds one model to one window: it owns the rendered buffer,
---the frozen header, the cell cursor and the keymaps, and it puts every
---one of them back on `dispose`.
---
---Four facts drove this design, each measured rather than assumed
---(ADR-0058 §3.4, review finding R2-3):
---
---  1. A winbar freezes the header VERTICALLY but does not scroll with
---     the text. With `nowrap`, `400|` drove `leftcol` to 359 while a
---     literal winbar stayed at column 0 — the labels would have
---     described the wrong cells. So the header is clipped by the
---     window's current `leftcol` on every refresh.
---  2. `WinScrolled` — not `CursorMoved` — is the horizontal signal. It
---     fires on horizontal-only motion, carries `leftcol` in
---     `v:event[winid]`, and fires when the VIEWPORT moves with the
---     cursor untouched, which `CursorMoved` cannot see at all.
---     CAVEAT: it does NOT fire in a headless Neovim, because with no
---     UI there is no redraw to trigger it. Headless tests therefore
---     drive `refresh_header()` directly; `tests/ui/grid_scroll.lua`
---     covers the event wiring under a real pty.
---  3. A winbar is evaluated AS A STATUSLINE. A literal `"100%s done"`
---     renders as `"100 done"` — the `%s` is consumed as an item. Every
---     column name is escaped before it goes in.
---  4. `winbar` is a global-local option, so writes carry an explicit
---     `scope = "local"` per [[0028-panel-window-options-must-be-local-scope]],
---     and `dispose` restores the window's prior value — but only if
---     the window still carries the value THIS view wrote, since
---     something else may have taken over in between.
---
---The current cell is DERIVED from the real cursor rather than trapped:
---every native motion, search and count keeps working, and selection is
---still cell-wise.
---@module 'auto-core.ui.grid.view'

local model_mod = require("auto-core.ui.grid.model")
local highlights = require("auto-core.ui.highlights")

local M = {}

local NS_PREFIX = "auto_core_grid_"
local AUG_PREFIX = "AutoCoreGrid"

local next_id = 0

---escape_statusline neutralizes `%`, which a winbar interprets.
---
---Call `render_header` instead of composing this yourself — ORDER IS
---PART OF CORRECTNESS (see below).
---@param s string
---@return string
function M.escape_statusline(s)
  return (s:gsub("%%", "%%%%"))
end

---clip_header shifts a rendered header line by `leftcol` display cells
---so it stays aligned with horizontally-scrolled text.
---
---Pure, and separated out precisely because `WinScrolled` cannot be
---observed headlessly: this is the part a smoke test can assert.
---@param header string
---@param leftcol integer
---@return string
function M.clip_header(header, leftcol)
  if leftcol <= 0 then return header end
  local width = vim.fn.strdisplaywidth(header)
  if leftcol >= width then return "" end
  -- Walk characters so a multibyte glyph is never cut in half, and so a
  -- wide glyph straddling the cut is replaced by a space rather than
  -- shifting everything after it by one cell.
  local out, seen = {}, 0
  for _, ch in ipairs(vim.fn.split(header, "\\zs")) do
    local cw = vim.fn.strdisplaywidth(ch)
    if seen >= leftcol then
      out[#out + 1] = ch
    elseif seen + cw > leftcol then
      out[#out + 1] = string.rep(" ", seen + cw - leftcol)
    end
    seen = seen + cw
  end
  return table.concat(out)
end

---render_header is the ONE supported way to turn a raw header into a
---winbar value: **clip first, escape second.**
---
---The order is not stylistic. Escaping inserts a second cell for every
---literal `%`, so clipping the ESCAPED string by `leftcol` measures
---cells the winbar will never render — every label after a `%` shifts,
---and a cut landing between the two halves of a `%%` pair leaves a live
---`%x` statusline item that eats the text after it. Clipping the raw
---header keeps the arithmetic in the same units the window scrolls in.
---@param raw string      -- the padded header, UNESCAPED
---@param leftcol integer -- the target window's current leftcol
---@return string
function M.render_header(raw, leftcol)
  -- Trailing `%<` is the truncation point. A header wider than the
  -- window is the normal case (many columns), and a winbar with no `%<`
  -- truncates from the START — Neovim would paint the RIGHTMOST columns
  -- with a leading `<`, while the body, scrolled to leftcol, shows the
  -- LEFT ones. Header and body would truncate from opposite ends and
  -- never line up. `%<` at the very end truncates from the right instead,
  -- keeping the left columns aligned with the body. It is inert when the
  -- header already fits, and it must sit AFTER escaping so it stays a
  -- live statusline item rather than a literal `%<`.
  local body = M.escape_statusline(M.clip_header(raw, leftcol))
  -- An empty header stays empty: nothing to truncate, and JSON mode
  -- relies on "" to clear the winbar (a lone "%<" would leave a bar).
  if body == "" then return "" end
  -- Colour the column titles distinctly from the surrounding WinBar with
  -- a zero-width `%#group#…%*` wrap (no display cells, so alignment and
  -- the clip arithmetic are untouched); `%<` stays last so a too-wide
  -- header still truncates from the right.
  return "%#AutoCoreGridHeader#" .. body .. "%*%<"
end

---render_winbar composes what the view actually writes to the winbar: the
---clipped, escaped header, plus a right-aligned mode marker.
---
---This is a separate function from `render_header` because the two answer
---different questions, and a test that wants to check the HEADER shift must
---not have to know the marker's format string. The marker goes last on
---purpose: `render_header` escapes `%` in the column labels (so a raw `%=`
---composed in earlier would be escaped into a literal), and its trailing
---`%<` is the truncation point — items after it survive while the header
---itself truncates from the right, which is what keeps the LEFT columns
---aligned with the body underneath.
---@param raw string      the unclipped header text
---@param leftcol integer the window's horizontal scroll, in display cells
---@param marker string?  "" or a mode indicator such as "[ROW]"
---@return string
function M.render_winbar(raw, leftcol, marker)
  local text = M.render_header(raw, leftcol)
  if text == "" or not marker or marker == "" then return text end
  return text .. "%=%#AutoCoreGridHeader#" .. marker .. "%*"
end

---@class AutoCoreGridView
---@field _id integer                 unique per attach; names ns + augroup
---@field _model AutoCoreGridModel
---@field _win integer                the window this view borrows
---@field _buf integer                the rendered buffer this view OWNS
---@field _header_mode string         "winbar" (default) | "line" (headless)
---@field _max_width integer?         per-column display-width cap
---@field _on_inspect function?       consumer's detail-modal hook
---@field _json_mode boolean
---@field _sel_mode string           "cell" (default) | "row"
---@field _on_selection_mode fun(mode: string)?
---@field _disposed boolean
---@field _ns integer                 extmark namespace (cell cursor)
---@field _augroup integer
---@field _widths integer[]?          current column widths
---@field _ranges table?              per-line cell byte ranges
---@field _owned_winbar string?       the winbar value THIS view wrote
---@field _prior_buf integer          restored on dispose, so the window lives
---@field _prior_winbar string        restored on dispose, if still ours
---@field _prior_wrap boolean
---@field _prior_cursorline boolean
local View = {}
View.__index = View

---The selection modes. `cell` is the default so that every existing
---consumer keeps its current behaviour without opting in.
local SEL_MODES = { cell = true, row = true }
local DEFAULT_SEL_MODE = "cell"

local DEFAULT_KEYMAPS = {
  yank_cell    = "y",
  yank_row_csv = "Y",
  yank_row_json = "gy",
  toggle_view  = "J",
  inspect      = "<CR>",
  -- `s` (substitute) has no meaning in a read-only grid, and the grid
  -- already claims y/Y/gy/J. Overridable like every other binding.
  toggle_selection = "s",
  next_cell    = "<Tab>",
  prev_cell    = "<S-Tab>",
}

---attach binds `model` to `opts.win` and renders it.
---@param model AutoCoreGridModel
---@param opts { win: integer?, header: string?, keymaps: table|boolean?, max_width: integer?, on_inspect: function?, name: string?, selection_mode: string?, on_selection_mode: fun(mode: string)? }
---@return AutoCoreGridView
function M.attach(model, opts)
  opts = opts or {}
  highlights.ensure()
  next_id = next_id + 1

  local self = setmetatable({}, View)
  self._id = next_id
  self._model = model
  self._win = opts.win or vim.api.nvim_get_current_win()
  self._header_mode = opts.header or "winbar"
  self._max_width = opts.max_width
  self._on_inspect = opts.on_inspect
  self._json_mode = false
  -- Seeded, not set: `on_selection_mode` must NOT fire here. This value is
  -- the consumer's own persisted mode arriving (the view is disposed and
  -- re-attached on every query), so echoing it straight back out would make
  -- attach-order a source of writes for something that never changed.
  --
  -- `nil` selects the default; an invalid non-nil value is REJECTED, loudly.
  -- It used to coerce to `cell`, which contradicted the very rule this
  -- boundary exists to enforce — a typo in a consumer's persisted mode must
  -- not silently become a mode. `attach` is construction, where a bad
  -- argument is a programming error and failing fast is the whole point;
  -- `set_selection_mode` stays a soft no-op because it is called from a
  -- keymap at runtime, where refusing is better than throwing at the user.
  if opts.selection_mode ~= nil and not SEL_MODES[opts.selection_mode] then
    error(string.format(
      "auto-core grid: invalid selection_mode %q — expected \"cell\", \"row\", or nil",
      tostring(opts.selection_mode)), 2)
  end
  self._sel_mode = opts.selection_mode or DEFAULT_SEL_MODE
  self._on_selection_mode = opts.on_selection_mode
  self._disposed = false
  self._ns = vim.api.nvim_create_namespace(NS_PREFIX .. self._id)
  self._augroup = vim.api.nvim_create_augroup(AUG_PREFIX .. self._id, { clear = true })

  -- Each view owns its OWN buffer: two views never share one, which is
  -- what makes their extmarks, keymaps and options independent.
  self._buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self._buf].bufhidden = "wipe"
  vim.bo[self._buf].buftype = "nofile"
  vim.bo[self._buf].swapfile = false
  vim.bo[self._buf].modifiable = false
  vim.bo[self._buf].filetype = "autocoregrid"

  -- Snapshot what we are about to borrow, so dispose can give it back.
  -- The BUFFER is part of that: the window belongs to the consumer (a
  -- docked result split, say) and must outlive the grid. Deleting our
  -- own buffer while the window still shows it takes the window down
  -- with it, which would collapse the panel layout on every dispose.
  self._prior_buf = vim.api.nvim_win_get_buf(self._win)
  self._prior_winbar = vim.api.nvim_get_option_value("winbar", { win = self._win, scope = "local" })
  self._prior_wrap = vim.api.nvim_get_option_value("wrap", { win = self._win, scope = "local" })
  self._prior_cursorline = vim.api.nvim_get_option_value("cursorline", { win = self._win, scope = "local" })
  self._prior_number = vim.api.nvim_get_option_value("number", { win = self._win, scope = "local" })
  self._prior_relativenumber = vim.api.nvim_get_option_value("relativenumber", { win = self._win, scope = "local" })
  self._prior_signcolumn = vim.api.nvim_get_option_value("signcolumn", { win = self._win, scope = "local" })
  self._prior_foldcolumn = vim.api.nvim_get_option_value("foldcolumn", { win = self._win, scope = "local" })

  vim.api.nvim_win_set_buf(self._win, self._buf)
  -- Remember what we WROTE, not just what was there: dispose restores an
  -- option only while the window still carries this view's value.
  self._owned_wrap, self._owned_cursorline = false, false
  vim.api.nvim_set_option_value("wrap", false, { win = self._win, scope = "local" })
  vim.api.nvim_set_option_value("cursorline", false, { win = self._win, scope = "local" })

  -- The winbar header spans the window from column 0, but the buffer text
  -- is pushed right by ANY gutter (number, relativenumber, signcolumn,
  -- foldcolumn). A gutter slides every data cell out from under its
  -- header label, which is the classic "header does not match the values"
  -- misalignment. The grid owns these off for the life of the view and
  -- restores them on dispose, exactly as it does wrap/cursorline. They
  -- must be set EXPLICITLY: a fresh buffer's window-local defaults vary by
  -- the user's globals, so relying on the buffer swap to clear them is not
  -- enough (e.g. signcolumn="auto" still reserves a variable-width gutter).
  self._owned_number, self._owned_relativenumber = false, false
  self._owned_signcolumn, self._owned_foldcolumn = "no", "0"
  vim.api.nvim_set_option_value("number", false, { win = self._win, scope = "local" })
  vim.api.nvim_set_option_value("relativenumber", false, { win = self._win, scope = "local" })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = self._win, scope = "local" })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = self._win, scope = "local" })

  self:_bind_keymaps(opts.keymaps)
  self:_bind_autocmds()
  self:render()
  return self
end

function View:_bind_keymaps(spec)
  if spec == false then return end
  local keys = vim.tbl_extend("force", {}, DEFAULT_KEYMAPS)
  if type(spec) == "table" then keys = vim.tbl_extend("force", keys, spec) end
  -- Every binding is a thin wrapper over a public method, so a consumer
  -- can drive the grid without synthesizing keypresses.
  local actions = {
    -- `y` is the ONE mode-dependent key (§2.3). `Y`/`gy` stay absolute in
    -- both modes, so no yank key ever changes meaning under the reader.
    yank_cell     = function() self:yank_selection() end,
    yank_row_csv  = function() self:yank_row("csv") end,
    yank_row_json = function() self:yank_row("json") end,
    toggle_view   = function() self:toggle_view() end,
    inspect       = function() self:inspect() end,
    toggle_selection = function() self:toggle_selection_mode() end,
    next_cell     = function() self:move_cell(0, 1) end,
    prev_cell     = function() self:move_cell(0, -1) end,
  }
  for action, lhs in pairs(keys) do
    if lhs and actions[action] then
      vim.keymap.set("n", lhs, actions[action], {
        buffer = self._buf, nowait = true, silent = true,
        desc = "auto-core grid: " .. action:gsub("_", " "),
      })
    end
  end
end

function View:_bind_autocmds()
  -- CursorMoved drives the CELL cursor; WinScrolled drives the HEADER.
  -- They are different signals: zH scrolls without moving the cursor,
  -- and a vertical motion moves the cursor without scrolling.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = self._augroup, buffer = self._buf,
    callback = function() self:_paint_cursor() end,
  })
  -- These are GLOBAL events (a scroll in any window fires them), so the
  -- ownership check is what keeps this view's writes inside its own
  -- window. Losing the window is also the end of the view's life: hold
  -- nothing once someone else owns the display.
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized" }, {
    group = self._augroup,
    callback = function()
      if self._disposed then return end
      if not self:owns_window() then return self:dispose() end
      self:refresh_header()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self._augroup,
    pattern = tostring(self._win),
    callback = function() self:dispose() end,
  })
end

---owns_window reports whether this view may still touch `self._win`.
---
---Existence is not ownership. If another component swapped its own
---buffer into the window, the view's global `WinScrolled`/resize
---callbacks would otherwise keep writing this grid's winbar into
---somebody else's view — for the whole period between the swap and
---disposal. Ownership ends the instant the window stops displaying this
---view's buffer, not at `dispose`.
---@return boolean
function View:owns_window()
  return not self._disposed
    and vim.api.nvim_win_is_valid(self._win)
    and vim.api.nvim_buf_is_valid(self._buf)
    and vim.api.nvim_win_get_buf(self._win) == self._buf
end

---_valid gates every window read and write.
function View:_valid()
  return self:owns_window()
end

---set_model swaps the data and re-renders, keeping the window.
---@param model AutoCoreGridModel
function View:set_model(model)
  self._model = model
  self._json_mode = false
  self:render()
end

function View:model() return self._model end

---render paints the whole view: lines, header, cursor.
function View:render()
  if not self:_valid() then return end
  local m = self._model
  local lines, ranges = {}, {}

  if self._json_mode then
    lines = vim.split(m:json_rows(), "\n", { plain = true })
  elseif m:kind() == "rows" then
    self._widths = m:widths({ max = self._max_width })
    for r = 1, m:nrows() do
      local line, rg = m:line(r, self._widths)
      lines[r] = line
      ranges[r] = rg
    end
    if self._header_mode == "line" then
      -- Header as buffer line 1: what headless tests use, since a
      -- winbar cannot be observed without a UI.
      local hline = m:header_line(self._widths)
      table.insert(lines, 1, hline)
      table.insert(ranges, 1, false)
    end
  else
    lines = { m:summary() }
  end
  if #lines == 0 then lines = { "" } end

  self._ranges = ranges
  vim.bo[self._buf].modifiable = true
  vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, lines)
  vim.bo[self._buf].modifiable = false

  self:refresh_header()
  self:_paint_cursor()
end

---header_text builds the RAW header for the current model — padded on
---the column grid, and deliberately NOT escaped: escaping happens after
---clipping, at write time, via `render_header`.
---@return string
function View:header_text()
  local m = self._model
  if self._json_mode or m:kind() ~= "rows" then return "" end
  -- Parenthesized: header_line also returns cell ranges, which callers
  -- of header_text must not receive as a second return value.
  return (m:header_line(self._widths or m:widths({ max = self._max_width })))
end

---refresh_header re-clips the header to the window's current leftcol.
---Bound to WinScrolled/resize; callable directly (which is how it is
---tested, since WinScrolled needs a UI).
function View:refresh_header()
  if not self:_valid() then return end
  if self._header_mode ~= "winbar" then return end
  local leftcol = vim.api.nvim_win_call(self._win, function()
    return vim.fn.winsaveview().leftcol
  end)
  local text = M.render_winbar(self:header_text(), leftcol, self:mode_marker())
  vim.api.nvim_set_option_value("winbar", text, { win = self._win, scope = "local" })
  self._owned_winbar = text
end

---row_offset is 1 when the header occupies buffer line 1.
function View:row_offset()
  return (self._header_mode == "line" and self._model:kind() == "rows") and 1 or 0
end

---cell reports the CURRENT cell, derived from the real cursor.
---@return { row: integer, col: integer, cell: AutoCoreGridCell? }|nil
function View:cell()
  if not self:_valid() then return nil end
  if self._json_mode or self._model:kind() ~= "rows" then return nil end
  local pos = vim.api.nvim_win_get_cursor(self._win)
  local row = pos[1] - self:row_offset()
  if row < 1 or row > self._model:nrows() then return nil end
  local rg = self._ranges and self._ranges[pos[1]]
  local col = rg and model_mod.column_at(rg, pos[2]) or 1
  return { row = row, col = col, cell = self._model:cell(row, col) }
end

function View:_paint_cursor()
  if not self:_valid() then return end
  -- Clearing first is what makes the two marks EXCLUSIVE (§2.2, criterion
  -- 13): the mode selects which single extmark exists, never both. Note it
  -- is an extmark and not `cursorline` — attach deliberately turns
  -- cursorline OFF and restores the caller's prior value on dispose, so
  -- riding that option would fight the view's own owned-option discipline.
  vim.api.nvim_buf_clear_namespace(self._buf, self._ns, 0, -1)
  local cur = self:cell()
  if not cur then return end
  local rg = self._ranges[cur.row + self:row_offset()]
  if not rg or not rg[cur.col] then return end
  local line = cur.row + self:row_offset() - 1

  if self._sel_mode == "row" then
    pcall(vim.api.nvim_buf_set_extmark, self._buf, self._ns, line, 0, {
      end_row = line + 1,
      end_col = 0,
      hl_group = "Visual",
      hl_eol = true,
      priority = 200,
    })
    return
  end

  pcall(vim.api.nvim_buf_set_extmark, self._buf, self._ns, line, rg[cur.col].start, {
    end_col = rg[cur.col].stop,
    hl_group = "Visual",
    priority = 200,
  })
end

---move_cell moves the cursor by whole cells, in cell units.
---@param dr integer
---@param dc integer
function View:move_cell(dr, dc)
  local cur = self:cell()
  if not cur then return end
  local row = math.min(math.max(cur.row + dr, 1), self._model:nrows())
  local col = math.min(math.max(cur.col + dc, 1), self._model:ncols())
  local rg = self._ranges[row + self:row_offset()]
  if not rg or not rg[col] then return end
  vim.api.nvim_win_set_cursor(self._win, { row + self:row_offset(), rg[col].start })
  self:_paint_cursor()
end

---set_clipboard is the grid's yank rule: always the unnamed register, and
---the system register too when `clipboard` asks for it.
---
---Exported (as `grid.set_clipboard`) because the detail views a consumer
---opens from the grid must yank IDENTICALLY to the grid itself — two copies
---of this drift the moment one of them learns about a new clipboard setting.
---@param text string
function M.set_clipboard(text)
  vim.fn.setreg('"', text)
  local cb = vim.o.clipboard or ""
  if cb:find("unnamedplus", 1, true) then vim.fn.setreg("+", text)
  elseif cb:find("unnamed", 1, true) then vim.fn.setreg("*", text) end
end

---yank_cell copies the current cell's RAW text.
---@return string|nil
function View:yank_cell()
  local cur = self:cell()
  if not cur or not cur.cell then return nil end
  local text = cur.cell.null and "" or model_mod.raw_text(cur.cell.value, "")
  M.set_clipboard(text)
  return text
end

---yank_row copies the current row as RFC-4180 CSV or as JSON.
---@param fmt string  -- "csv" | "json"
---@return string|nil
function View:yank_row(fmt)
  local cur = self:cell()
  if not cur then return nil end
  local text = (fmt == "json") and self._model:json(cur.row) or self._model:csv(cur.row)
  if not text then return nil end
  M.set_clipboard(text)
  return text
end

---mode_applies reports whether a selection mode means anything right now.
---
---Per §2.6. `cell()` is the operand for every mode-dependent key, and it
---returns nil in the JSON layout AND for any non-`rows` model (a message or
---an error result has no cells either). Where there is no operand, an
---active-looking ROW marker would advertise a capability that does not
---exist — the same defect class as the `(no help entries)` this ADR removes.
---@return boolean
function View:mode_applies()
  return not self._json_mode and self._model:kind() == "rows"
end

---selection_mode returns the current mode, whether or not it applies.
---@return string
function View:selection_mode() return self._sel_mode end

---set_selection_mode is the ONE mutation path for the mode.
---
---It REJECTS an unknown mode rather than coercing it: a typo in a
---consumer's persisted value must not silently become a mode. The callback
---fires only on an EFFECTIVE change, so a set to the current mode is inert.
---@param mode string
---@return boolean changed
function View:set_selection_mode(mode)
  if not SEL_MODES[mode] then return false end
  if mode == self._sel_mode then return false end
  self._sel_mode = mode
  self:_paint_cursor()
  self:refresh_header()
  if self._on_selection_mode then pcall(self._on_selection_mode, mode) end
  return true
end

---toggle_selection_mode flips cell↔row.
---
---Inert where the mode does not apply (§2.6): it says so once rather than
---silently doing nothing, and it leaves the stored mode ALONE — so `J` into
---the JSON layout and back returns the reader to the mode they chose, rather
---than discarding that choice as a side effect of looking at the JSON form.
---@return string mode
function View:toggle_selection_mode()
  if not self:mode_applies() then
    vim.notify("auto-core grid: selection mode applies to the table view",
      vim.log.levels.INFO)
    return self._sel_mode
  end
  self:set_selection_mode(self._sel_mode == "row" and "cell" or "row")
  return self._sel_mode
end

---mode_marker is the winbar indicator — EMPTY where the mode does not
---apply, because §2.5 asks for absent rather than merely unlit.
---@return string
function View:mode_marker()
  if not self:mode_applies() then return "" end
  return self._sel_mode == "row" and "[ROW]" or "[CELL]"
end

---yank_selection is what `y` is bound to: the one mode-dependent key.
---@return string|nil
function View:yank_selection()
  if self._sel_mode == "row" and self:mode_applies() then
    return self:yank_row("csv")
  end
  return self:yank_cell()
end

---toggle_view switches between the table and JSON layouts.
function View:toggle_view()
  self._json_mode = not self._json_mode
  self:render()
  return self._json_mode
end

function View:is_json() return self._json_mode end

---inspect hands the current selection to the consumer's detail modal.
---
---The third argument is the selection mode, so the consumer opens the CELL
---detail or the ROW detail without re-deriving it (§2.4). `cur` keeps its
---shape, so an existing consumer that ignores the extra argument behaves
---exactly as before.
function View:inspect()
  local cur = self:cell()
  if not cur then return nil end
  local mode = self:mode_applies() and self._sel_mode or DEFAULT_SEL_MODE
  if self._on_inspect then self._on_inspect(cur, self._model, mode) end
  return cur, mode
end

---dispose returns every borrowed resource. Idempotent.
---
---The winbar is restored only if the window still carries the value
---this view wrote: if something else has taken the winbar over since,
---clobbering it would be worse than leaving it.
function View:dispose()
  if self._disposed then return end
  self._disposed = true
  pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
  if vim.api.nvim_win_is_valid(self._win) then
    -- Decide ownership BEFORE touching the buffer. Measured: swapping a
    -- window's buffer also restores the window-local options Neovim
    -- remembers for THAT buffer — the swap below silently reinstated
    -- the pre-attach winbar even when this view had correctly decided
    -- to leave a third party's value alone. So: read first, swap, then
    -- write the intended value explicitly in BOTH branches. Nothing
    -- here may rely on an option surviving the swap.
    -- Ownership is per-OPTION and per-BUFFER, decided before anything is
    -- touched. If another component has taken the window over, disposal
    -- must remove this view's own resources WITHOUT mutating whatever
    -- replaced it — a window we no longer own is not ours to restore.
    local owns_buf = vim.api.nvim_win_get_buf(self._win) == self._buf
    local function get(opt)
      return vim.api.nvim_get_option_value(opt, { win = self._win, scope = "local" })
    end

    if owns_buf then
      -- Read every option BEFORE the swap: swapping a window's buffer
      -- also restores the window-local options Neovim remembers for THAT
      -- buffer, so anything not written explicitly afterwards is decided
      -- by that implicit restore rather than by us.
      local observed = { winbar = get("winbar"), wrap = get("wrap"),
        cursorline = get("cursorline"), number = get("number"),
        relativenumber = get("relativenumber"), signcolumn = get("signcolumn"),
        foldcolumn = get("foldcolumn") }
      local prior = { winbar = self._prior_winbar, wrap = self._prior_wrap,
        cursorline = self._prior_cursorline, number = self._prior_number,
        relativenumber = self._prior_relativenumber, signcolumn = self._prior_signcolumn,
        foldcolumn = self._prior_foldcolumn }
      local written = { winbar = self._owned_winbar, wrap = self._owned_wrap,
        cursorline = self._owned_cursorline, number = self._owned_number,
        relativenumber = self._owned_relativenumber, signcolumn = self._owned_signcolumn,
        foldcolumn = self._owned_foldcolumn }

      local restore = self._prior_buf
      if not (restore and vim.api.nvim_buf_is_valid(restore)) then
        restore = vim.api.nvim_create_buf(false, true)
      end
      pcall(vim.api.nvim_win_set_buf, self._win, restore)

      -- Per option: give back OUR value only where the window still
      -- carried what this view wrote. Where a third party changed it,
      -- write their value back — the buffer swap above would otherwise
      -- silently discard it. Either way the net effect on someone
      -- else's choice is zero.
      for _, opt in ipairs({ "winbar", "wrap", "cursorline",
        "number", "relativenumber", "signcolumn", "foldcolumn" }) do
        local ours = observed[opt] == written[opt]
        vim.api.nvim_set_option_value(opt, ours and prior[opt] or observed[opt],
          { win = self._win, scope = "local" })
      end
    end
    -- If the buffer is no longer ours the window belongs to something
    -- else entirely: remove this view's private resources and touch
    -- nothing in the window (R4-4).
  end
  if vim.api.nvim_buf_is_valid(self._buf) then
    pcall(vim.api.nvim_buf_clear_namespace, self._buf, self._ns, 0, -1)
    pcall(vim.api.nvim_buf_delete, self._buf, { force = true })
  end
end

function View:buf() return self._buf end
function View:win() return self._win end
function View:disposed() return self._disposed end

return M
