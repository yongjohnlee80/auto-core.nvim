---Adaptive tab-strip renderer for auto-core panels.
---
---Pure rendering — no module state, no side effects. Consumers
---compute their section list (number, name, optional active state)
---and pass it in. The function returns a vim winbar string with
---clickable regions wired to a per-panel click router.
---
---Three modes, picked by `available_width`:
---
---  FULL          " 0: config " " 1: files " " 2: repos "       (full labels)
---  FOCUSED-ONLY  " 0 " "[1: files]" " 2 "                       (label only on focused)
---  COMPACT       " 0 " "[1]" " 2 "                              (numbers + bracket)
---
---We pick the widest mode that fits in `available_width`. Each
---section is wrapped in a vim clickable region
---(`%<minwid>@v:lua.require'auto-core.ui.winbar'.click@…%X`) — the
---numeric `minwid` is the section number; vim passes it back to the
---click callback as the first arg.
---
---Click routing: a global router table keyed by panel name. When a
---click fires, the router resolves the panel by its current winid
---(via `vim.fn.win_getid()`) and dispatches to the panel's
---`on_section_click` handler.
---@module 'auto-core.ui.winbar'

local M = {}

---@class AutoCoreSection
---@field number integer
---@field name string

---Click router state: panel-name → handler. Populated by
---`ui.panel` when a panel attaches a winbar; consumers don't touch
---this directly.
---@type table<string, fun(slot: integer)>
local _click_routers = {}

---Register a click handler for a panel. When a vim click region
---fires, we look up the panel by current winid → panel name →
---handler. Idempotent — re-register replaces.
---@param panel_name string
---@param handler fun(slot: integer)
function M.register_click_router(panel_name, handler)
  _click_routers[panel_name] = handler
end

---Unregister (called from panel close / dispose).
---@param panel_name string
function M.unregister_click_router(panel_name)
  _click_routers[panel_name] = nil
end

---Click entry point — referenced from the winbar string itself
---via `v:lua.require'auto-core.ui.winbar'.click`. nvim invokes
---this with (minwid, clicks, button, mods); we only care about
---minwid (the section number) and route via the current window's
---panel name.
---@param minwid integer
---@param _clicks integer
---@param _button string
---@param _mods string
function M.click(minwid, _clicks, _button, _mods)
  -- Resolve the panel by the window-local marker on the current
  -- window. Each auto-core panel stamps `w:auto_core_panel_name` on
  -- open; ui.panel sets it.
  local cur = vim.api.nvim_get_current_win()
  local ok, name = pcall(vim.api.nvim_win_get_var, cur, "auto_core_panel_name")
  if not ok or type(name) ~= "string" then return end
  local handler = _click_routers[name]
  if handler then pcall(handler, minwid) end
end

-- ── pure rendering ────────────────────────────────────────────

---Compute the FULL-mode plain-text length (excluding `%…%` markup).
---@param sections AutoCoreSection[]
---@return integer
local function len_full(sections)
  local n = 0
  for _, s in ipairs(sections) do
    n = n + 4 + #tostring(s.number) + #s.name  -- " N: name "
  end
  return n + (#sections - 1)  -- inter-section single space
end

---Compute the FOCUSED-ONLY mode plain-text length.
---@param sections AutoCoreSection[]
---@param focused integer
---@return integer
local function len_focused_only(sections, focused)
  local n = 0
  for _, s in ipairs(sections) do
    if s.number == focused then
      n = n + 4 + #tostring(s.number) + #s.name
    else
      n = n + 3  -- " N "
    end
  end
  return n + (#sections - 1)
end

---Render the winbar string. Pure function.
---@param focused integer  -- focused section number
---@param sections AutoCoreSection[]
---@param available_width integer?  -- panel window width; nil disables fit check
---@return string
function M.render(focused, sections, available_width)
  if not sections or #sections == 0 then return "" end

  local mode = "full"
  if available_width and available_width > 0 then
    if len_full(sections) > available_width then
      mode = (len_focused_only(sections, focused) <= available_width)
        and "focused-only"
        or "compact"
    end
  end

  local parts = {}
  for _, s in ipairs(sections) do
    local text
    if s.number == focused then
      if mode == "compact" then
        text = string.format("%%#AutoCoreSectionActive#[%d]%%*", s.number)
      else
        text = string.format(
          "%%#AutoCoreSectionActive#[%d: %s]%%*", s.number, s.name)
      end
    else
      if mode == "full" then
        text = string.format(" %d: %s ", s.number, s.name)
      else
        text = string.format(" %d ", s.number)
      end
    end
    table.insert(parts, string.format(
      "%%%d@v:lua.require'auto-core.ui.winbar'.click@%s%%X",
      s.number, text))
  end
  return table.concat(parts, " ")
end

---Ensure default highlight links exist. Idempotent. Consumers may
---override `AutoCoreSectionActive` in their own theme/colorscheme
---hook.
function M.ensure_highlights()
  if vim.fn.hlexists("AutoCoreSectionActive") == 0 then
    vim.api.nvim_set_hl(0, "AutoCoreSectionActive",
      { link = "Title", default = true })
  end
end

return M
