---auto-core.ui.float.multi — multi-pane floating-window primitive.
---
---Per ADR 0007 Phase 2. Extracts the layout pattern gitsgraph
---built (per `gitsgraph/ui.lua:586-805`): one background float that
---holds the border + title, with up to four content panes
---(left / middle / preview / footer) stacked above. The first
---consumer is `worktree.graph` in Phase 3.
---
---Layout model:
---
---    ┌─────────────────────────────────────────────────────────┐
---    │                       title                             │
---    │ ┌──────┐ ┌─────────────────────────┐ ┌─────────────────┐│
---    │ │ left │ │         middle          │ │     preview     ││
---    │ │      │ │                         │ │                 ││
---    │ │      │ │                         │ │                 ││
---    │ └──────┘ └─────────────────────────┘ └─────────────────┘│
---    │ footer                                                  │
---    └─────────────────────────────────────────────────────────┘
---
---Any subset of panes may be omitted: a `left+middle` view drops
---preview + footer; a `middle+preview+footer` view drops left.
---Geometry adapts so the present panes fill the available inner
---rectangle.
---
---Public surface:
---
---  M.new(opts)               → MultiFloat
---  M.get(name)               → MultiFloat?
---  M.dispose(name)           → ()
---
---  m:open()                  -- creates buffers (or uses provided), opens windows
---  m:close()                 -- closes windows + wipes auto-spawned buffers
---  m:dispose()               -- close + remove from registry
---  m:is_open()               → boolean
---  m:focus(name)             -- e.g. m:focus("middle")
---  m:cycle(direction)        -- "forward" | "backward"
---  m:set_buffer(name, bufnr) -- swap a pane's buffer
---  m:resize()                -- recompute layout + apply
---  m:winid(name)             → integer? (read pane winid)
---  m:bufnr(name)             → integer? (read pane bufnr)
---
---Topics: `float:opened` / `float:closed` published per multi-float
---instance with payload `{ kind = "multi", name = <opts.name>, ... }`.
---
---Marker: every pane's window carries `w:auto_core_multi_float =
---<name>` so the panel-buffer leak guard from
---`auto-core/ui/panel.lua` knows these are panel-class floats and
---opts out of the bounce path.
---@module 'auto-core.ui.float.multi'

local events = require("auto-core.events")

local M = {}

---@type table<string, AutoCoreMultiFloat>
local _registry = {}

---@class AutoCoreMultiFloatOuter
---@field width_pct number?      default 0.85
---@field height_pct number?     default 0.85
---@field max_width integer?     optional cap
---@field max_height integer?    optional cap
---@field border any?            see :h nvim_open_win — default "rounded"
---@field title string?          rendered on the bg float; nil = no title
---@field title_pos string?      "left"|"center"|"right"; default "center"

---@class AutoCoreMultiFloatPane
---@field width integer?         fixed columns (left/preview)
---@field min_width integer?     preview only — below this, drop preview
---@field min_middle integer?    preview only — middle floor before considering preview
---@field height integer?        footer only (default 1)
---@field title string?          per-pane title
---@field title_pos string?      per-pane title position
---@field bufnr integer?         0 / nil = auto-core creates a wipe-scratch
---@field filetype string?       set on the auto-spawned scratch
---@field cursorline boolean?    sets `cursorline` on the pane window
---@field content string|string[]? static initial buffer content (footer)
---@field zindex integer?        default 20 (panes); bg uses 10

---@class AutoCoreMultiFloatOpts
---@field name string                                  unique; used for registry + marker var
---@field outer AutoCoreMultiFloatOuter?
---@field panes table<string, AutoCoreMultiFloatPane>  any subset of left/middle/preview/footer
---@field initial_focus string?                        default "middle" if present, else first available
---@field on_open fun(self: AutoCoreMultiFloat)?
---@field on_close fun()?
---@field on_click table<string, fun(row, col, button, mods)>?

---@class AutoCoreMultiFloat
---@field opts AutoCoreMultiFloatOpts
---@field panes table<string, { winid: integer?, bufnr: integer?, _spawned_buf: boolean? }>
---@field _augroup integer?
local Float = {}
Float.__index = Float

local PANE_ORDER = { "left", "middle", "preview", "footer" }

---Walk the pane order and return the names that are configured.
---@private
local function _present_panes(panes)
  local out = {}
  for _, name in ipairs(PANE_ORDER) do
    if panes[name] then out[#out + 1] = name end
  end
  return out
end

---Compute the layout rectangle for every present pane. Returns
---`{ bg = {...}, <pane_name> = {...} }` with absolute row/col/
---width/height. Mirrors gitsgraph's `compute_layout` shape but
---degrades gracefully when panes are omitted.
---@private
function Float:_compute_layout()
  local outer = self.opts.outer or {}
  local cols  = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight - 1
  local outer_w = math.floor(cols  * (outer.width_pct  or 0.85))
  local outer_h = math.floor(lines * (outer.height_pct or 0.85))
  if outer.max_width  then outer_w = math.min(outer_w, outer.max_width)  end
  if outer.max_height then outer_h = math.min(outer_h, outer.max_height) end
  local row = math.floor((lines - outer_h) / 2)
  local col = math.floor((cols  - outer_w) / 2)

  -- Inner rect (border eats 2 cols + 2 rows).
  local inner_w = outer_w - 2
  local inner_h = outer_h - 2

  local panes = self.opts.panes or {}
  local has_footer = panes.footer ~= nil
  local footer_h = has_footer and (panes.footer.height or 1) or 0
  local pane_h = inner_h - footer_h

  local layout = {
    bg = {
      row = row, col = col, width = outer_w, height = outer_h,
    },
  }

  -- Horizontal partition for left / middle / preview within pane_h rows.
  local has_left    = panes.left    ~= nil
  local has_middle  = panes.middle  ~= nil
  local has_preview = panes.preview ~= nil

  local left_w    = has_left and (panes.left.width or 28) or 0
  local preview_w = 0
  if has_preview and has_middle then
    local pv = panes.preview
    local available =
      inner_w - left_w - (pv.min_middle or 40) - (has_left and 1 or 0) - 1
    preview_w = math.min(pv.width or 90, math.max(0, available))
    if preview_w < (pv.min_width or 0) then preview_w = 0 end
  end

  -- Gap counts: one column gutter between every present neighbor pair.
  local gaps = 0
  if has_left and has_middle then gaps = gaps + 1 end
  if has_middle and preview_w > 0 then gaps = gaps + 1 end
  -- left-only or preview-only without middle: the middle slot still
  -- consumed; but the consumer should provide middle as the canonical
  -- "rest" pane.
  local middle_w = inner_w - left_w - preview_w - gaps

  if has_left then
    layout.left = {
      row    = row + 1,
      col    = col + 1,
      width  = left_w,
      height = pane_h,
    }
  end
  if has_middle then
    layout.middle = {
      row    = row + 1,
      col    = col + 1 + (has_left and (left_w + 1) or 0),
      width  = math.max(1, middle_w),
      height = pane_h,
    }
  end
  if preview_w > 0 then
    layout.preview = {
      row    = row + 1,
      col    = col + 1 + (has_left and (left_w + 1) or 0)
                     + middle_w + 1,
      width  = preview_w,
      height = pane_h,
    }
  end
  if has_footer then
    layout.footer = {
      row    = row + 1 + pane_h,
      col    = col + 1,
      width  = inner_w,
      height = footer_h,
    }
  end
  return layout
end

---@private
local function _scratch_buf(opts)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype  = "nofile"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile  = false
  if opts and opts.filetype then vim.bo[b].filetype = opts.filetype end
  if opts and opts.content then
    local lines = type(opts.content) == "table"
      and opts.content
      or vim.split(opts.content, "\n", { plain = true })
    pcall(vim.api.nvim_buf_set_lines, b, 0, -1, false, lines)
  end
  return b
end

---@private
local function _stamp(winid, name)
  pcall(vim.api.nvim_win_set_var, winid, "auto_core_multi_float", name)
end

---@private
function Float:_open_pane(name, geom)
  local pane_opts = self.opts.panes[name] or {}
  local p = self.panes[name] or {}
  local bufnr = p.bufnr
  if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = _scratch_buf({
      filetype = pane_opts.filetype,
      content  = pane_opts.content,
    })
    p._spawned_buf = true
  end
  p.bufnr = bufnr

  -- Per-pane border decoration. middle gets a left vertical
  -- separator; preview gets a left vertical separator; left + footer
  -- have no border. Mirrors gitsgraph's visual split.
  local border = "none"
  if name == "middle" then
    border = { "", "", "", "│", "", "", "", "│" }
  elseif name == "preview" then
    border = { "", "", "", "", "", "", "", "│" }
  end
  local win_opts = {
    relative  = "editor",
    row       = geom.row,
    col       = geom.col,
    width     = geom.width,
    height    = geom.height,
    style     = "minimal",
    border    = border,
    zindex    = pane_opts.zindex or 20,
    focusable = name ~= "footer",
  }
  if pane_opts.title then
    win_opts.title     = pane_opts.title
    win_opts.title_pos = pane_opts.title_pos or "left"
  end
  local winid = vim.api.nvim_open_win(bufnr, false, win_opts)
  if pane_opts.cursorline then
    vim.wo[winid].cursorline = true
  end
  vim.wo[winid].wrap = false
  vim.wo[winid].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:Visual"

  _stamp(winid, self.opts.name)
  -- Buffer-local q closes the whole instance unless overridden.
  pcall(vim.keymap.set, "n", "q", function() self:close() end, {
    buffer = bufnr, silent = true, nowait = true,
    desc = "auto-core.multi: close",
  })
  pcall(vim.keymap.set, "n", "<Esc>", function() self:close() end, {
    buffer = bufnr, silent = true, nowait = true,
    desc = "auto-core.multi: close (Esc)",
  })

  p.winid = winid
  self.panes[name] = p
end

---@private
function Float:_open_bg(geom)
  local outer = self.opts.outer or {}
  local b = _scratch_buf({})
  local winopts = {
    relative  = "editor",
    row       = geom.row,
    col       = geom.col,
    width     = geom.width - 2,
    height    = geom.height - 2,
    style     = "minimal",
    border    = outer.border or "rounded",
    focusable = false,
    zindex    = 10,
  }
  if outer.title then
    winopts.title     = outer.title
    winopts.title_pos = outer.title_pos or "center"
  end
  local winid = vim.api.nvim_open_win(b, false, winopts)
  vim.wo[winid].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  _stamp(winid, self.opts.name)
  self.panes.bg = { winid = winid, bufnr = b, _spawned_buf = true }
end

---@private
function Float:_install_autocmds()
  local g = vim.api.nvim_create_augroup(
    "AutoCoreMultiFloat_" .. self.opts.name:gsub("[^%w_]", "_"),
    { clear = true })
  self._augroup = g
  -- Closing any pane closes the whole instance.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = g,
    callback = function(ev)
      local closed = tonumber(ev.match)
      for _, p in pairs(self.panes) do
        if p.winid == closed then
          vim.schedule(function() self:close() end)
          return
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = g,
    callback = function() self:resize() end,
  })
end

---Open the multi-float. Idempotent: re-calling on an already-open
---instance focuses the initial pane.
function Float:open()
  if self:is_open() then
    self:focus(self.opts.initial_focus or "middle")
    return
  end
  local layout = self:_compute_layout()
  self.panes = {}
  self:_open_bg(layout.bg)
  for _, name in ipairs(_present_panes(self.opts.panes)) do
    if layout[name] then self:_open_pane(name, layout[name]) end
  end
  self:_install_autocmds()

  local initial = self.opts.initial_focus
  if not initial or not self.panes[initial] then
    -- First focusable pane in canonical order.
    for _, n in ipairs(PANE_ORDER) do
      if self.panes[n] and n ~= "footer" then initial = n; break end
    end
  end
  if initial then self:focus(initial) end

  events.publish("float:opened", {
    kind = "multi",
    name = self.opts.name,
    buf  = self.panes.bg and self.panes.bg.bufnr or -1,
    win  = self.panes.bg and self.panes.bg.winid or -1,
  })
  if self.opts.on_open then pcall(self.opts.on_open, self) end
end

function Float:is_open()
  local bg = self.panes and self.panes.bg
  return bg and bg.winid and vim.api.nvim_win_is_valid(bg.winid) or false
end

---Close every pane window and wipe auto-spawned buffers. Safe to
---call multiple times.
function Float:close()
  if self._augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
    self._augroup = nil
  end
  if self.panes then
    for _, p in pairs(self.panes) do
      if p.winid and vim.api.nvim_win_is_valid(p.winid) then
        pcall(vim.api.nvim_win_close, p.winid, true)
      end
      if p._spawned_buf and p.bufnr and vim.api.nvim_buf_is_valid(p.bufnr) then
        pcall(vim.api.nvim_buf_delete, p.bufnr, { force = true })
      end
    end
  end
  self.panes = {}
  events.publish("float:closed", {
    kind = "multi",
    name = self.opts.name,
    buf  = -1,
    win  = -1,
  })
  if self.opts.on_close then pcall(self.opts.on_close) end
end

---Final cleanup. Removes from the registry too.
function Float:dispose()
  self:close()
  _registry[self.opts.name] = nil
end

---Move cursor focus to the named pane (no-op if not open).
---@param name string
function Float:focus(name)
  local p = self.panes and self.panes[name]
  if not p or not p.winid or not vim.api.nvim_win_is_valid(p.winid) then return end
  pcall(vim.api.nvim_set_current_win, p.winid)
end

---Cycle focus through focusable panes (left → middle → preview).
---Footer is skipped (focusable = false on open).
---@param direction "forward"|"backward"|nil   default "forward"
function Float:cycle(direction)
  direction = direction or "forward"
  local cur = vim.api.nvim_get_current_win()
  local order = {}
  for _, name in ipairs(PANE_ORDER) do
    if self.panes[name] and name ~= "footer"
        and self.panes[name].winid
        and vim.api.nvim_win_is_valid(self.panes[name].winid) then
      order[#order + 1] = name
    end
  end
  if #order == 0 then return end
  local idx = 1
  for i, n in ipairs(order) do
    if self.panes[n].winid == cur then idx = i; break end
  end
  if direction == "forward" then
    idx = (idx % #order) + 1
  else
    idx = ((idx - 2) % #order) + 1
  end
  self:focus(order[idx])
end

---Swap a pane's buffer. The previous buffer is wiped if it was
---auto-spawned by us; consumer-supplied buffers are left alone.
---@param name string
---@param bufnr integer
function Float:set_buffer(name, bufnr)
  local p = self.panes and self.panes[name]
  if not p then return end
  if p.winid and vim.api.nvim_win_is_valid(p.winid) then
    pcall(vim.api.nvim_win_set_buf, p.winid, bufnr)
  end
  if p._spawned_buf and p.bufnr and p.bufnr ~= bufnr
      and vim.api.nvim_buf_is_valid(p.bufnr) then
    pcall(vim.api.nvim_buf_delete, p.bufnr, { force = true })
  end
  p.bufnr = bufnr
  p._spawned_buf = false
  _stamp(p.winid, self.opts.name)
end

function Float:winid(name)
  local p = self.panes and self.panes[name]
  return p and p.winid or nil
end
function Float:bufnr(name)
  local p = self.panes and self.panes[name]
  return p and p.bufnr or nil
end

---Recompute layout and re-apply geometry to every open pane. Called
---automatically by the VimResized autocmd; consumers can call
---manually after toggling pane visibility.
function Float:resize()
  if not self:is_open() then return end
  local layout = self:_compute_layout()
  -- Resize bg.
  if self.panes.bg and self.panes.bg.winid then
    pcall(vim.api.nvim_win_set_config, self.panes.bg.winid, {
      relative = "editor",
      row    = layout.bg.row,
      col    = layout.bg.col,
      width  = layout.bg.width  - 2,
      height = layout.bg.height - 2,
    })
  end
  for _, name in ipairs(PANE_ORDER) do
    local p = self.panes[name]
    if p and p.winid and layout[name]
        and vim.api.nvim_win_is_valid(p.winid) then
      pcall(vim.api.nvim_win_set_config, p.winid, {
        relative = "editor",
        row    = layout[name].row,
        col    = layout[name].col,
        width  = layout[name].width,
        height = layout[name].height,
      })
    end
  end
end

-- ── public constructor ────────────────────────────────────

---@param opts AutoCoreMultiFloatOpts
---@return AutoCoreMultiFloat
function M.new(opts)
  assert(type(opts) == "table" and type(opts.name) == "string"
    and #opts.name > 0,
    "auto-core.ui.float.multi.new: opts.name is required")
  assert(type(opts.panes) == "table",
    "auto-core.ui.float.multi.new: opts.panes is required")

  if _registry[opts.name] then
    -- Idempotent: re-calling .new merges opts non-destructively.
    local existing = _registry[opts.name]
    existing.opts = vim.tbl_deep_extend("force", existing.opts, opts)
    return existing
  end

  local m = setmetatable({
    opts  = opts,
    panes = {},
  }, Float)
  _registry[opts.name] = m
  return m
end

---Look up a previously-created instance.
---@param name string
---@return AutoCoreMultiFloat?
function M.get(name) return _registry[name] end

---Dispose by name (removes from registry + closes if open).
---@param name string
function M.dispose(name)
  local m = _registry[name]
  if m then m:dispose() end
end

---Test-only.
function M._reset_for_tests()
  for n, m in pairs(_registry) do
    pcall(m.close, m)
    _registry[n] = nil
  end
end

return M
