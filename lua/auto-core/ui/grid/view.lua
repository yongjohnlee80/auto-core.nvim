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
---     `v:event[winid]`, and fires on `zH` when the cursor has not moved
---     at all. CAVEAT: it does NOT fire in a headless Neovim, because
---     with no UI there is no redraw to trigger it. Headless tests
---     therefore drive `refresh_header()` directly.
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
  return M.escape_statusline(M.clip_header(raw, leftcol))
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

local DEFAULT_KEYMAPS = {
  yank_cell    = "y",
  yank_row_csv = "Y",
  yank_row_json = "gy",
  toggle_view  = "J",
  inspect      = "<CR>",
  next_cell    = "<Tab>",
  prev_cell    = "<S-Tab>",
}

---attach binds `model` to `opts.win` and renders it.
---@param model AutoCoreGridModel
---@param opts { win: integer?, header: string?, keymaps: table|boolean?, max_width: integer?, on_inspect: function?, name: string? }
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

  vim.api.nvim_win_set_buf(self._win, self._buf)
  vim.api.nvim_set_option_value("wrap", false, { win = self._win, scope = "local" })
  vim.api.nvim_set_option_value("cursorline", false, { win = self._win, scope = "local" })

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
    yank_cell     = function() self:yank_cell() end,
    yank_row_csv  = function() self:yank_row("csv") end,
    yank_row_json = function() self:yank_row("json") end,
    toggle_view   = function() self:toggle_view() end,
    inspect       = function() self:inspect() end,
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
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized" }, {
    group = self._augroup,
    callback = function() self:refresh_header() end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self._augroup,
    pattern = tostring(self._win),
    callback = function() self:dispose() end,
  })
end

function View:_valid()
  return not self._disposed
    and vim.api.nvim_buf_is_valid(self._buf)
    and vim.api.nvim_win_is_valid(self._win)
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
  return m:header_line(self._widths or m:widths({ max = self._max_width }))
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
  local text = M.render_header(self:header_text(), leftcol)
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
  vim.api.nvim_buf_clear_namespace(self._buf, self._ns, 0, -1)
  local cur = self:cell()
  if not cur then return end
  local rg = self._ranges[cur.row + self:row_offset()]
  if not rg or not rg[cur.col] then return end
  local line = cur.row + self:row_offset() - 1
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

local function set_clipboard(text)
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
  set_clipboard(text)
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
  set_clipboard(text)
  return text
end

---toggle_view switches between the table and JSON layouts.
function View:toggle_view()
  self._json_mode = not self._json_mode
  self:render()
  return self._json_mode
end

function View:is_json() return self._json_mode end

---inspect hands the current cell to the consumer's detail modal.
function View:inspect()
  local cur = self:cell()
  if not cur then return nil end
  if self._on_inspect then self._on_inspect(cur, self._model) end
  return cur
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
    local now = vim.api.nvim_get_option_value("winbar", { win = self._win, scope = "local" })
    local ours = (now == self._owned_winbar)

    -- Put a buffer back BEFORE deleting ours, and only if the window is
    -- still showing ours (someone may have swapped it since). A scratch
    -- stands in when the original is gone — the window survives either
    -- way, which is the invariant the consumer depends on.
    if vim.api.nvim_win_get_buf(self._win) == self._buf then
      local restore = self._prior_buf
      if not (restore and vim.api.nvim_buf_is_valid(restore)) then
        restore = vim.api.nvim_create_buf(false, true)
      end
      pcall(vim.api.nvim_win_set_buf, self._win, restore)
    end

    vim.api.nvim_set_option_value("winbar", ours and self._prior_winbar or now,
      { win = self._win, scope = "local" })
    vim.api.nvim_set_option_value("wrap", self._prior_wrap, { win = self._win, scope = "local" })
    vim.api.nvim_set_option_value("cursorline", self._prior_cursorline,
      { win = self._win, scope = "local" })
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
