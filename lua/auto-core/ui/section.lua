---Multi-section registry for an auto-core panel.
---
---A panel can host N sections (one buffer per section). Section 0
---is conventional admin / REPL; 1..N are typed (auto-finder uses
---config/files/repos; auto-agents uses admin + agent slots).
---
---Each section module owns:
---  - get_buffer(panel) → bufnr   how to render its buffer (called once,
---                                cached until on_close fires)
---  - on_focus(panel, bufnr)?     hook fired AFTER the buffer is placed
---  - on_close(bufnr)?            cleanup hook fired on dispose / close
---
---The section registry handles:
---  - swapping the panel's buffer to the section's bufnr (via
---    `panel:with_unfixed_buf` so `winfixbuf` doesn't bounce)
---  - buffer-local keymaps: `0..9` to switch sections, `q` to close
---    the panel (overrides neo-tree-default `q = close_window`)
---  - winbar refresh on every focus
---  - section bufnr cache (cleared on dispose)
---
---Lifts the section pattern from `auto-finder/sections/` into a
---primitive any panel can attach to.
---@module 'auto-core.ui.section'

local M = {}

---@class AutoCoreSectionDef
---@field number integer                    -- 0..9; 0 conventional admin
---@field name string                       -- shown in winbar tab strip
---@field get_buffer fun(panel: any): integer?  -- builds/returns the bufnr
---@field on_focus fun(panel: any, bufnr: integer)?
---@field on_close fun(bufnr: integer)?

---@class AutoCoreSectionRegistry
---@field panel any                          -- AutoCorePanel
---@field sections AutoCoreSectionDef[]      -- in number order
---@field active integer                     -- current section number
---@field _bufs table<integer, integer>      -- section_number → bufnr
local Registry = {}
Registry.__index = Registry

---Apply our buffer-local keymap surface to a buffer:
---  - 0..9 → switch to that section
---  - q    → close the panel (overrides neo-tree's `q = close_window`
---           which would otherwise trigger nvim_win_set_buf against
---           winfixbuf and crash E1513)
---Idempotent — safe to call repeatedly on the same buffer.
---@private
---@param self AutoCoreSectionRegistry
---@param bufnr integer
local function apply_keymap(self, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  for i = 0, 9 do
    pcall(vim.keymap.set, "n", tostring(i), function()
      self:focus(i)
    end, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = "auto-core: focus section " .. i,
    })
  end
  pcall(vim.keymap.set, "n", "q", function()
    self.panel:close()
  end, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "auto-core: close panel",
  })
end

---Resolve a section by number or name. Returns the def or nil.
---@private
---@param key integer|string
---@return AutoCoreSectionDef?
function Registry:_resolve(key)
  for _, s in ipairs(self.sections) do
    if s.number == key or s.name == key then return s end
  end
  return nil
end

---Render the winbar with current sections + active number.
---@private
function Registry:_refresh_winbar()
  local strip = {}
  for _, s in ipairs(self.sections) do
    strip[#strip + 1] = { number = s.number, name = s.name }
  end
  self.panel:set_winbar(strip, self.active)
end

---Switch the panel to a section. The section's `get_buffer` is
---called (or its cached bufnr is reused) and the buffer is swapped
---into the panel window.
---@param key integer|string
---@return boolean ok
---@return string? err
function Registry:focus(key)
  local section = self:_resolve(key)
  if not section then return false, "no such section: " .. tostring(key) end

  if not self.panel.winid or not vim.api.nvim_win_is_valid(self.panel.winid) then
    self.panel:open()
    if not self.panel.winid then return false, "panel could not be opened" end
  end

  -- Section bufnr — cached, or computed via get_buffer.
  local bufnr = self._bufs[section.number]
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    local ok, b = self.panel:with_unfixed_buf(function()
      return section.get_buffer(self.panel)
    end)
    if not ok or not b or not vim.api.nvim_buf_is_valid(b) then
      return false, "section '" .. section.name .. "' returned no buffer"
    end
    bufnr = b
    self._bufs[section.number] = bufnr
  end

  -- Place the buffer in the panel window. winfixbuf is on; need
  -- to temporarily disable so our own swap doesn't bounce.
  self.panel:with_unfixed_buf(function()
    pcall(vim.api.nvim_win_set_buf, self.panel.winid, bufnr)
  end)
  pcall(vim.api.nvim_set_current_win, self.panel.winid)

  self.active = section.number
  apply_keymap(self, bufnr)

  if section.on_focus then
    self.panel:with_unfixed_buf(function()
      pcall(section.on_focus, self.panel, bufnr)
    end)
  end

  self:_refresh_winbar()
  return true, nil
end

---Notify the registry that a section has swapped from the buffer
---returned by `get_buffer()` to a different "real" buffer — the
---placeholder-to-real transition used by async-mount views.
---
---Without this hook, the registry's cache + buffer-local keymaps +
---winbar are bound to the bufnr `get_buffer()` originally returned.
---When a section later does its own `nvim_win_set_buf` (e.g.
---auto-finder's dbase view swapping a `shared.loading` placeholder
---for the real dbee drawer in its `vim.schedule`-deferred mount),
---the new buffer carries none of those bindings: `0..9` and `q`
---don't switch sections / close the panel, and the registry would
---next focus() against a stale cached bufnr.
---
---Calling `section_did_remount(N, real_bufnr)` repairs all three:
---  - updates `_bufs[N]` so the next focus() reuses the real buffer
---  - re-applies `apply_keymap` on the real buffer (only when N is
---    the active section — keymap surface is buffer-local)
---  - refreshes the winbar (only when N is the active section)
---
---Idempotent — safe to call twice, safe to call from inside a
---deferred callback that lost its still-current race (the buffer
---check + active-section guard short-circuit).
---@param section_number integer
---@param real_bufnr integer
function Registry:section_did_remount(section_number, real_bufnr)
  if type(section_number) ~= "number" then return end
  if not real_bufnr or not vim.api.nvim_buf_is_valid(real_bufnr) then
    return
  end
  self._bufs[section_number] = real_bufnr
  if self.active == section_number then
    apply_keymap(self, real_bufnr)
    self:_refresh_winbar()
  end
end

---Add a section at runtime. Re-renders the winbar.
---@param def AutoCoreSectionDef
function Registry:add(def)
  table.insert(self.sections, def)
  table.sort(self.sections, function(a, b) return a.number < b.number end)
  self:_refresh_winbar()
end

---Remove a section. Calls its `on_close` hook + drops cached bufnr.
---@param key integer|string
function Registry:remove(key)
  for i, s in ipairs(self.sections) do
    if s.number == key or s.name == key then
      local b = self._bufs[s.number]
      if b and vim.api.nvim_buf_is_valid(b) and s.on_close then
        pcall(s.on_close, b)
      end
      if b and vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
      self._bufs[s.number] = nil
      table.remove(self.sections, i)
      self:_refresh_winbar()
      return true
    end
  end
  return false
end

---Tear down. Calls every section's `on_close`, deletes cached
---buffers, drops the click router. Does NOT close the panel
---window — call `panel:close()` separately.
function Registry:dispose()
  for _, s in ipairs(self.sections) do
    local b = self._bufs[s.number]
    if b and vim.api.nvim_buf_is_valid(b) then
      if s.on_close then pcall(s.on_close, b) end
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  self._bufs = {}
  -- Unhook the winbar click router from this panel.
  require("auto-core.ui.winbar").unregister_click_router(self.panel.opts.name)
end

-- ── public attach ──────────────────────────────────────────

---Attach a section registry to a panel. Returns the registry; the
---caller drives the panel via `registry:focus(N)`.
---
---The panel's winbar click router is wired so winbar clicks call
---`registry:focus(N)`.
---@param panel any                     -- AutoCorePanel
---@param sections AutoCoreSectionDef[]
---@param opts { default: integer? }?
---@return AutoCoreSectionRegistry
function M.attach(panel, sections, opts)
  opts = opts or {}
  -- Sort sections by number for stable winbar ordering.
  local sorted = {}
  for _, s in ipairs(sections) do sorted[#sorted + 1] = s end
  table.sort(sorted, function(a, b) return a.number < b.number end)

  local r = setmetatable({
    panel    = panel,
    sections = sorted,
    active   = opts.default or (sorted[1] and sorted[1].number) or 0,
    _bufs    = {},
  }, Registry)

  -- Wire winbar clicks for this panel → our focus().
  require("auto-core.ui.winbar").register_click_router(
    panel.opts.name,
    function(slot) r:focus(slot) end)

  return r
end

return M
