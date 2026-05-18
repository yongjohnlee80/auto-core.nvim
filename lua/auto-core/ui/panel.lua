---Singleton vsplit panel host for the AutoVim plugin family.
---
---Lifts the panel pattern from `auto-agents/init.lua:ensure_main_window`
---and `auto-finder/panel/host.lua` into one canonical implementation
---per ADR 0006 §3 + the iteration patterns in
---`<auto-agents-kb>/shared/synthesis/nvim-plugin-iteration-patterns.md`.
---
---A panel is:
---  - a vsplit anchored to one side ("left" or "right")
---  - identified by a window-local marker (`w:<name>_panel = 1`)
---    so the singleton-guard can adopt an orphan window after lazy
---    reload / session restore / `:Lazy reload`
---  - protected by `winfixwidth` (layout ops can't squash) and
---    `winfixbuf` (`:edit` / `:b` / bufferline-clicks bounce off)
---  - sized via a `width = { default, percentage, min, max }` spec
---    with optional user pin (`panel:resize(N)`) that survives
---    `:VimResized`
---  - publishes `panel:opened`, `panel:closed`, `panel:focused` on
---    the auto-core events bus so siblings can react
---
---Hard rules from ADR 0006 §3 + the iteration patterns:
---  1. Never `require` a family plugin. Pure infrastructure.
---  2. The marker pattern is the singleton guarantee — DON'T rely
---     on `state.panel_winid` alone. Always re-discover via the
---     marker before creating a new vsplit.
---  3. `with_unfixed_buf` wraps any legitimate buffer swap so our
---     own internal mounts don't bounce off `winfixbuf`.
---@module 'auto-core.ui.panel'

local events = require("auto-core.events")
local winbar_mod = require("auto-core.ui.winbar")
local log = require("auto-core.log")
local log_guard = log.namespace("ui.panel.guard")
local log_panel = log.namespace("ui.panel")

local M = {}

-- ── module-level registry of live panels ─────────────────────
-- Keyed by panel name. Used by ui.section + the winbar click
-- router to resolve a panel by its name without the consumer
-- having to thread the instance through.
---@type table<string, AutoCorePanel>
local _registry = {}

-- Buffer-local var stamped on every buffer that has been displayed in
-- a panel window. Paired with `w:auto_core_panel_name` on the panel
-- window, this lets the BufWinEnter guard distinguish "panel buffer
-- in its panel window" (legitimate) from "panel buffer in a stray
-- editor split" (a leak — bounce it).
local BUF_OWNER_VAR = "auto_core_panel_owner"

---Look up a panel by name. Returns nil if not registered.
---@param name string
---@return AutoCorePanel?
function M.get(name)
  return _registry[name]
end

---List every registered panel name (registration order not
---preserved — Lua pairs is unordered).
---@return string[]
function M.list()
  local out = {}
  for name in pairs(_registry) do out[#out + 1] = name end
  return out
end

-- ── width resolution ────────────────────────────────────────

---@param spec { default: integer?, percentage: number?, min: integer, max: integer }
---@param cols integer
---@return integer
local function resolve_width(spec, cols)
  local n
  if spec.default ~= nil then
    n = spec.default
  elseif spec.percentage ~= nil and cols and cols > 0 then
    n = math.floor(spec.percentage * cols + 0.5)
  else
    n = spec.min
  end
  if n < spec.min then n = spec.min end
  if n > spec.max then n = spec.max end
  -- Defensive: if the terminal is too narrow, drop to leave at
  -- least 10 cols for the editor side.
  if cols and cols > 0 and n + 10 > cols then
    n = math.max(spec.min, math.max(1, cols - 10))
  end
  return n
end

-- ── leak guard against panel-buffer hijacks ──────────────
--
-- `winfixbuf` on the panel window prevents an external `:edit` /
-- `:b` / bufferline-click from REPLACING the panel's buffer with
-- something else. It does NOT stop the panel's own buffer from
-- being SHOWN in another window — `:vert sb`, `:bnext` in the
-- editor, bufferline cycling, session restore, etc. all happily
-- pull the agent terminal / file tree into a stray editor split,
-- producing duplicate-looking panels next to the real one.
--
-- Strategy:
--   1. Panel buffers are marked with `b:auto_core_panel_owner =
--      <panel name>` by `Panel:_stamp_buffer`, called explicitly
--      from `Panel:open` (for the scratch placeholder) and
--      `Panel:with_unfixed_buf` (for any consumer-supplied buffer
--      that gets swapped in). We don't rely on autocmds for the
--      stamp — `BufWinEnter` doesn't fire when a buffer already
--      visible elsewhere is displayed again, and `with_unfixed_buf`
--      runs without changing the current window so `WinEnter`
--      doesn't fire either.
--   2. A `WinEnter`/`BufWinEnter` autocmd watches for a marked
--      buffer landing in a non-panel window and CLOSES that window.
--      Closing matches user expectation: a stray `:vert sb <panel-buf>`
--      should disappear entirely, not leave an empty placeholder
--      window. When the close would leave an empty tabpage (last
--      window in the tab), we fall back to swapping in a wipe-scratch
--      so the visible buffer still goes away.

local function _get_var(getter, target, name)
  local ok, v = pcall(getter, target, name)
  if ok then return v end
  return nil
end

local function _bounce_buffer(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    log_guard.info("bounce skipped — winid no longer valid",
      { fields = { winid = winid } })
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local owner = _get_var(vim.api.nvim_buf_get_var, bufnr, BUF_OWNER_VAR) or ""
  local was_current = vim.api.nvim_get_current_win() == winid

  -- Prefer closing the stray window outright. `nvim_win_close` errors
  -- when the target is the last window in its tabpage; the pcall
  -- swallows that and we fall back to the scratch swap below.
  local closed, close_err = pcall(vim.api.nvim_win_close, winid, false)
  if closed then
    log_guard.info("bounce — closed stray window",
      { fields = {
          winid = winid, bufnr = bufnr, owner = owner,
          was_current = was_current,
        } })
    return
  end

  -- `nvim_win_close` failed (last in tab, or refused for some other
  -- reason — e.g. modified buffer). Fall back to swapping in a
  -- private scratch so the panel buffer at least leaves THIS window.
  log_guard.warn("bounce — close refused, trying scratch swap",
    { fields = {
        winid = winid, bufnr = bufnr, owner = owner,
        was_current = was_current, close_err = tostring(close_err or ""),
      } })

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[scratch].buftype   = "nofile"
  vim.bo[scratch].swapfile  = false
  local set_ok, set_err = pcall(vim.api.nvim_win_set_buf, winid, scratch)
  if not set_ok then
    log_guard.error("bounce — scratch swap also failed; panel buffer remains in stray window",
      { fields = {
          winid = winid, bufnr = bufnr, scratch = scratch, owner = owner,
          set_err = tostring(set_err or ""),
        } })
  else
    log_guard.info("bounce — scratch swap applied",
      { fields = {
          winid = winid, prev_bufnr = bufnr, scratch = scratch,
          owner = owner,
        } })
  end
end

local _guard_group = vim.api.nvim_create_augroup(
  "AutoCorePanelGuard", { clear = true })
vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
  group = _guard_group,
  callback = function(args)
    local winid = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(winid) then return end
    -- Floating windows opt out — overlays may legitimately preview
    -- a panel buffer (the float owner is responsible for cleanup).
    if vim.api.nvim_win_get_config(winid).relative ~= "" then return end

    local win_panel = _get_var(vim.api.nvim_win_get_var, winid,
      "auto_core_panel_name")
    if type(win_panel) == "string" and #win_panel > 0 then
      -- Window is a legitimate panel — guard is a no-op here.
      -- DEBUG: cheap when level >= DEBUG; off in production.
      log_guard.debug("fired — skip (window is a panel)",
        { fields = { event = args.event, winid = winid, panel = win_panel } })
      return
    end

    local bufnr = vim.api.nvim_win_get_buf(winid)
    local owner = _get_var(vim.api.nvim_buf_get_var, bufnr, BUF_OWNER_VAR)
    if type(owner) == "string" and #owner > 0 then
      -- A panel-owned buffer is in a non-panel window. Bounce.
      -- INFO level — this is the rare interesting case the guard exists for.
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      local buftype = vim.bo[bufnr].buftype
      local n_wins_with_buf = 0
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == bufnr then
          n_wins_with_buf = n_wins_with_buf + 1
        end
      end
      log_guard.info("fired — bouncing panel buffer from stray window",
        { fields = {
            event = args.event,
            winid = winid, bufnr = bufnr,
            owner = owner, buftype = buftype, bufname = bufname,
            n_wins_with_buf = n_wins_with_buf,
            -- Lua traceback into the autocmd context — points at the
            -- dispatcher, but useful for distinguishing direct
            -- (vim.cmd "split") vs Lua-driven (nvim_open_win) origins
            -- once you correlate by surrounding ring entries.
            traceback = debug.traceback("", 2),
          } })
      _bounce_buffer(winid)
      return
    end

    -- Normal traffic: non-panel window, non-panel buffer. No-op,
    -- not logged (would flood the ring on every WinEnter).
  end,
})

-- ── the Panel class ────────────────────────────────────────

---@class AutoCorePanelOpts
---@field name string                  -- unique; used for the marker var + click routing
---@field side "left"|"right"?         -- default "left"
---@field width { default: integer?, percentage: number?, min: integer, max: integer }
---@field filetype string?             -- consumer-owned filetype set on the host buffer's first mount
---@field on_open fun(winid: integer)?
---@field on_close fun(winid: integer)?
---@field on_focus fun(winid: integer)?

---@class AutoCorePanel
---@field opts AutoCorePanelOpts
---@field winid integer?
---@field user_width integer?           -- sticky pin set by :resize(N); cleared by :reset_width
---@field _marker_var string            -- e.g. "auto_finder_panel"
local Panel = {}
Panel.__index = Panel

---Stamp the marker on a window. Window-local var, dies with window.
---@private
function Panel:_stamp(winid)
  pcall(vim.api.nvim_win_set_var, winid, self._marker_var, 1)
  -- Also stamp the panel name for the winbar click router.
  pcall(vim.api.nvim_win_set_var, winid, "auto_core_panel_name", self.opts.name)
end

---Stamp the panel-owner marker on a buffer. Paired with the leak
---guard autocmd above — any buffer carrying this marker that ends
---up in a non-panel window is bounced back to a scratch.
---@private
---@param bufnr integer?
function Panel:_stamp_buffer(bufnr)
  if not bufnr or bufnr == 0 then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  -- Check the prior owner so a re-stamp (legitimate panel cycling
  -- the same buffer through with_unfixed_buf) is distinguishable
  -- from a first stamp.
  local prev = _get_var(vim.api.nvim_buf_get_var, bufnr, BUF_OWNER_VAR)
  pcall(vim.api.nvim_buf_set_var, bufnr, BUF_OWNER_VAR, self.opts.name)
  -- DEBUG: stamp events happen on every with_unfixed_buf swap;
  -- valuable for correlating "buffer X became panel-owned at time T"
  -- with a later "buffer X leaked at T+δ" bounce event.
  log_guard.debug("buffer stamped",
    { fields = {
        panel = self.opts.name, bufnr = bufnr,
        bufname = vim.api.nvim_buf_get_name(bufnr),
        buftype = vim.bo[bufnr].buftype,
        prev_owner = tostring(prev or ""),
      } })
end

---Scan the current tabpage for an existing window carrying our
---marker. The cure for the orphan-duplicate bug — see
---`<auto-agents-kb>/shared/synthesis/nvim-plugin-iteration-patterns.md`
---("Singleton windows need a window-local marker").
---@private
---@return integer?
function Panel:_find_existing_in_tab()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(w) then
      local ok, marker = pcall(vim.api.nvim_win_get_var, w, self._marker_var)
      if ok and marker == 1 then return w end
    end
  end
  return nil
end

---@private
function Panel:_is_open()
  return self.winid ~= nil
    and vim.api.nvim_win_is_valid(self.winid)
end

---Resolve the column count this panel should sit at — honouring the
---user pin if set, otherwise the configured width spec.
---@private
---@return integer
function Panel:_resolved_width()
  if self.user_width and self.user_width > 0 then return self.user_width end
  return resolve_width(self.opts.width, vim.o.columns)
end

---Run `fn` with our `winfixbuf` temporarily disabled. Used by
---consumers' section-mount paths so their own legitimate buffer
---swaps aren't bounced off the same protection that keeps external
---hijacks out.
---@param fn fun(): any
---@return boolean ok, any result_or_err
function Panel:with_unfixed_buf(fn)
  if not self:_is_open() then return pcall(fn) end
  local prev_buf = vim.api.nvim_win_get_buf(self.winid)
  local was = vim.wo[self.winid].winfixbuf
  if was then vim.wo[self.winid].winfixbuf = false end
  local ok, result = pcall(fn)
  if was and vim.api.nvim_win_is_valid(self.winid) then
    vim.wo[self.winid].winfixbuf = true
  end
  -- Whatever buffer the consumer just placed in the panel is now
  -- panel-owned. Stamping here is the only reliable hook: nvim
  -- doesn't fire BufWinEnter for re-displays of an already-loaded
  -- buffer, and `nvim_win_set_buf` doesn't change the current
  -- window so WinEnter doesn't fire either.
  if vim.api.nvim_win_is_valid(self.winid) then
    local new_buf = vim.api.nvim_win_get_buf(self.winid)
    self:_stamp_buffer(new_buf)
    if new_buf ~= prev_buf then
      log_panel.debug("with_unfixed_buf — buffer swapped",
        { fields = {
            panel = self.opts.name, winid = self.winid,
            prev_buf = prev_buf, new_buf = new_buf,
            ok = ok,
          } })
    end
  end
  return ok, result
end

---Open the panel. If a window with the marker already exists in
---the current tabpage, adopt it instead of creating a duplicate
---(the orphan-duplicate guard).
---@param force boolean?  -- bypass min-width check
---@return integer? winid
function Panel:open(force)
  -- Marker-based discovery first (singleton guard). Wins even if
  -- self.winid has gone stale via :Lazy reload / session restore.
  local existing = self:_find_existing_in_tab()
  if existing then
    self.winid = existing
    return existing
  end

  local cols = vim.o.columns
  if not force and cols < (self.opts.width.min + 10) then
    vim.notify(
      "auto-core.ui.panel: terminal width " .. cols ..
        " too narrow; force=true to bypass",
      vim.log.levels.WARN)
    return nil
  end

  local width = self:_resolved_width()
  local placement = (self.opts.side == "right") and "botright" or "topleft"

  -- Suppress autocmds during the split so the inherited buffer
  -- doesn't fire BufWinEnter handlers inside our half-built panel.
  -- We immediately swap in a private scratch buffer to break
  -- inheritance. Same protection auto-agents and auto-finder both
  -- evolved independently.
  local saved_eventignore = vim.o.eventignore
  vim.o.eventignore = "all"
  local ok_cmd = pcall(vim.cmd, placement .. " " .. width .. "vsplit")
  local winid = vim.api.nvim_get_current_win()
  if ok_cmd then
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].bufhidden = "wipe"
    vim.bo[scratch].buftype   = "nofile"
    vim.bo[scratch].swapfile  = false
    if self.opts.filetype then
      vim.bo[scratch].filetype = self.opts.filetype
    end
    pcall(vim.api.nvim_win_set_buf, winid, scratch)
    self:_stamp_buffer(scratch)
  end
  vim.o.eventignore = saved_eventignore
  if not ok_cmd then
    vim.notify("auto-core.ui.panel: failed to open '" .. self.opts.name .. "'",
      vim.log.levels.ERROR)
    return nil
  end

  self.winid = winid
  self:_stamp(winid)

  -- Window-local appearance: drop signs/numbers/foldcolumn — panel
  -- contents are usually trees / repls, none of those add value.
  vim.api.nvim_set_option_value("number",        false, { win = winid })
  vim.api.nvim_set_option_value("relativenumber",false, { win = winid })
  vim.api.nvim_set_option_value("signcolumn",    "no",  { win = winid })
  vim.api.nvim_set_option_value("foldcolumn",    "0",   { win = winid })
  vim.api.nvim_set_option_value("winfixwidth",   true,  { win = winid })
  vim.api.nvim_set_option_value("winfixbuf",     true,  { win = winid })

  events.publish("panel:opened", { name = self.opts.name, winid = winid })
  if self.opts.on_open then pcall(self.opts.on_open, winid) end

  log_panel.info("panel opened",
    { fields = {
        panel = self.opts.name, winid = winid, width = width,
        side = self.opts.side or "left",
        marker_var = self._marker_var,
      } })

  return winid
end

---Close the panel. Section-cached buffers (managed by ui.section)
---are torn down via the section module's `on_close` hooks; this
---method just closes the window and clears state.
function Panel:close()
  local winid = self.winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
  self.winid = nil
  events.publish("panel:closed",
    { name = self.opts.name, winid = winid or -1 })
  if self.opts.on_close then pcall(self.opts.on_close, winid or -1) end
  log_panel.info("panel closed",
    { fields = { panel = self.opts.name, winid = winid or -1 } })
end

---Toggle: close if open, open otherwise.
---@param force boolean?
function Panel:toggle(force)
  if self:_is_open() then self:close() else self:open(force) end
end

---Focus the panel (no-op if not open).
function Panel:focus()
  if not self:_is_open() then return end
  pcall(vim.api.nvim_set_current_win, self.winid)
  events.publish("panel:focused", { name = self.opts.name, winid = self.winid })
  if self.opts.on_focus then pcall(self.opts.on_focus, self.winid) end
end

---Pin the panel to N columns. Survives :VimResized; clear via
---`reset_width`.
---@param n integer
function Panel:resize(n)
  local w = self.opts.width
  if type(n) ~= "number" or n < 1 then
    vim.notify("auto-core.ui.panel: resize N must be a positive integer",
      vim.log.levels.ERROR)
    return
  end
  if n < w.min or n > w.max then
    vim.notify(string.format(
      "auto-core.ui.panel: resize %d out of range [%d..%d]", n, w.min, w.max),
      vim.log.levels.ERROR)
    return
  end
  self.user_width = n
  if self:_is_open() then
    pcall(vim.api.nvim_win_set_width, self.winid, n)
  end
end

---Drop the user pin. Width reverts to spec on next refresh.
function Panel:reset_width()
  self.user_width = nil
  if self:_is_open() then
    pcall(vim.api.nvim_win_set_width, self.winid, self:_resolved_width())
  end
end

---Refresh the resolved width — e.g. after `:VimResized`. Honors
---the user pin if set; otherwise re-resolves from spec + current
---`vim.o.columns`.
function Panel:refresh_width()
  if not self:_is_open() then return end
  pcall(vim.api.nvim_win_set_width, self.winid, self:_resolved_width())
end

---Re-clamp the panel back to the user pin if anyone (notably a
---`:wincmd =` from a sibling plugin) grew it past the pin. Hooked
---to `WinResized` by the panel's own autocmd group.
function Panel:enforce_pin()
  if not self:_is_open() then return end
  if not (self.user_width and self.user_width > 0) then return end
  local live = vim.api.nvim_win_get_width(self.winid)
  if live ~= self.user_width then
    pcall(vim.api.nvim_win_set_width, self.winid, self.user_width)
    log_panel.info("pin enforced — width re-clamped",
      { fields = {
          panel       = self.opts.name,
          winid       = self.winid,
          before      = live,
          after       = self.user_width,
          marker_var  = self._marker_var,
        } })
  end
end

---Close any window that holds this panel's tracked buffer but
---lacks the panel marker. These are "unmarked siblings" —
---typically created by nvim's internal layout reflow on
---`VimResized` when a hard-pinned `winfixwidth` panel doesn't fit
---in the post-resize column budget. The reflow can synthesize a
---horizontal split inside the panel column whose new window
---inherits the panel buffer but isn't routed through
---`Panel:open()` (so no marker, no log).
---
---Called from the `VimResized` handler via `vim.schedule()` so
---`nvim_win_close` runs OUTSIDE the autocmd context where E1312
---(`Not allowed to change the window layout in this autocmd`)
---would otherwise block it.
---
---Logs `unmarked sibling closed` at INFO with the offending winid
---+ buffer, the closer's stack, and the surviving panel winid.
---Silent fast-path when no siblings exist (the common case).
---
---Per ADR? + incident
---`agents/white-vision/incidents/2026-05-18-auto-agents-panel-duplicated-recurrence.md`.
function Panel:_cleanup_unmarked_siblings()
  if not self:_is_open() then return end
  local panel_winid = self.winid
  local panel_bufnr = nil
  do
    local ok, b = pcall(vim.api.nvim_win_get_buf, panel_winid)
    if ok then panel_bufnr = b end
  end
  if not panel_bufnr then return end

  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= panel_winid then
      local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, w)
      if ok_buf and buf == panel_bufnr then
        -- Found a non-panel window holding the same buffer.
        -- Verify it actually lacks the marker (defensive — the
        -- panel singleton could in principle stamp two windows
        -- with the same marker on adoption, though it shouldn't).
        local ok_var, marker = pcall(vim.api.nvim_win_get_var,
          w, self._marker_var)
        local has_marker = ok_var and marker == 1
        if not has_marker then
          local ok_close, close_err = pcall(
            vim.api.nvim_win_close, w, true)
          log_panel.info("unmarked sibling closed",
            { fields = {
                panel        = self.opts.name,
                panel_winid  = panel_winid,
                panel_bufnr  = panel_bufnr,
                closed_winid = w,
                marker_var   = self._marker_var,
                ok           = ok_close,
                err          = ok_close and nil or tostring(close_err),
              } })
        end
      end
    end
  end
end

---Render the winbar to the panel window. `sections` is a list of
---`{ number, name }` entries; `focused` is the active number.
---Idempotent — safe to call after every section switch / config
---change.
---@param sections AutoCoreSection[]
---@param focused integer
function Panel:set_winbar(sections, focused)
  if not self:_is_open() then return end
  winbar_mod.ensure_highlights()
  local w = vim.api.nvim_win_get_width(self.winid)
  pcall(vim.api.nvim_set_option_value, "winbar",
    winbar_mod.render(focused, sections, w),
    { win = self.winid })
end

---Tear down. Removes the panel from the registry and unregisters
---its winbar click router. Closes the window if still open.
function Panel:dispose()
  self:close()
  winbar_mod.unregister_click_router(self.opts.name)
  _registry[self.opts.name] = nil
end

-- ── public constructor ────────────────────────────────────

---@param opts AutoCorePanelOpts
---@return AutoCorePanel
function M.new(opts)
  assert(type(opts) == "table" and type(opts.name) == "string" and #opts.name > 0,
    "auto-core.ui.panel.new: opts.name is required")
  assert(type(opts.width) == "table" and type(opts.width.min) == "number"
    and type(opts.width.max) == "number",
    "auto-core.ui.panel.new: opts.width = { default?, percentage?, min, max } required")

  if _registry[opts.name] then
    -- Idempotent: re-calling .new for an existing name returns the
    -- same instance (after a non-destructive opts merge so consumers
    -- can adjust callbacks without touching the live winid).
    local existing = _registry[opts.name]
    existing.opts = vim.tbl_deep_extend("force", existing.opts, opts)
    return existing
  end

  local p = setmetatable({
    opts         = opts,
    winid        = nil,
    user_width   = nil,
    _marker_var  = opts.name:gsub("[^%w_]", "_") .. "_panel",
  }, Panel)

  -- Set up auto-pin enforcement at module level. Cheap (the
  -- callback is a no-op when no pin is set or panel is closed).
  local group = vim.api.nvim_create_augroup(
    "AutoCorePanel_" .. p._marker_var, { clear = true })

  -- WinResized fires once per window-geometry mutation — and can come
  -- in bursts during a drag-resize or chained `:wincmd =`. The pin
  -- enforcer is cheap to run on every fire, but the LOG emission is
  -- throttled per panel so we don't blow the ring during a drag.
  -- `v:event.windows` carries the affected winids; we record that
  -- payload because it's load-bearing for "did anything touch the
  -- panel" investigations after the fact.
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      p:enforce_pin()
      local windows = (vim.v.event and vim.v.event.windows) or {}
      local panel_in_event = false
      for _, w in ipairs(windows) do
        if w == p.winid then panel_in_event = true; break end
      end
      log_panel.debug_throttled("win-resized:" .. p._marker_var, 250,
        "WinResized fired",
        { fields = {
            panel             = opts.name,
            panel_winid       = p.winid,
            panel_in_event    = panel_in_event,
            affected_winids   = windows,
            live_panel_width  = (p:_is_open()
              and vim.api.nvim_win_get_width(p.winid)) or nil,
            user_pin          = p.user_width,
            columns           = vim.o.columns,
            lines             = vim.o.lines,
          } })
    end,
  })

  -- VimResized = nvim's outer terminal got resized (host terminal,
  -- tmux pane, alacritty grow/shrink, e.g. omarchy/hyprland tile-
  -- shrink on workspace co-tile). Single-fire per resize, so plain
  -- INFO is appropriate; this is the high-signal anchor for "what
  -- was the screen state when X happened" forensics.
  --
  -- v0.1.21 rewrite (panel-visibility branch). Three changes from
  -- the original v0.1.18 shape:
  --
  --   1. **Log FIRST, refresh_width SECOND.** The v0.1.18 form put
  --      refresh_width before the log call AND computed the
  --      `live_panel_width` field via
  --      `(p:_is_open() and nvim_win_get_width(p.winid)) or nil`
  --      inside the field-table literal. If `p.winid` was racily
  --      invalid (panel closed mid-handler), the field-table
  --      evaluation threw BEFORE log_panel.info ever ran — and the
  --      autocmd's implicit pcall swallowed the error. Net result:
  --      no ring entry on VimResized in real sessions despite the
  --      handler being correctly registered. Logging first
  --      guarantees the anchor even if width-refresh fails.
  --   2. **Defensive field computation via pcall**. `live_panel_width`
  --      now goes through pcall so a stale winid produces `nil`
  --      instead of an unlogged abort. The default falls back to
  --      the singleton's cached `panel_width` known via
  --      `_resolved_width()` so the field is always populated.
  --   3. **Schedule the column-cleanup pass async.** After the
  --      resize, nvim's layout reflow can split the panel column
  --      horizontally (the load-bearing root cause from incident
  --      `agents/white-vision/incidents/2026-05-18-auto-agents-panel-duplicated-recurrence.md`).
  --      The new window inherits the panel buffer but lacks the
  --      panel marker. We schedule a cleanup that closes any such
  --      unmarked siblings OUTSIDE the autocmd context (where
  --      `nvim_win_close` is forbidden with E1312). The cleanup
  --      itself logs at INFO when it acts.
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      -- (1) Log first. Compute throwable fields defensively.
      local live_width = nil
      do
        local ok, w = pcall(function()
          if p:_is_open() then
            return vim.api.nvim_win_get_width(p.winid)
          end
        end)
        if ok then live_width = w end
      end
      log_panel.info("VimResized — terminal geometry changed",
        { fields = {
            panel             = opts.name,
            panel_winid       = p.winid,
            columns           = vim.o.columns,
            lines             = vim.o.lines,
            live_panel_width  = live_width,
            user_pin          = p.user_width,
          } })
      -- (2) Now refresh the pin.
      pcall(function() p:refresh_width() end)
      -- (3) Schedule a layout-recovery cleanup pass for any
      -- unmarked siblings that nvim's reflow created in the panel
      -- column. Deferred so `nvim_win_close` is permitted.
      vim.schedule(function() p:_cleanup_unmarked_siblings() end)
    end,
  })

  -- WinNew: log when a new window comes into existence whose
  -- buffer matches this panel's tracked buffer but whose window
  -- lacks the marker. Closes the visibility gap from incident
  -- `agents/white-vision/incidents/2026-05-18-auto-agents-panel-duplicated-recurrence.md`
  -- — before this autocmd, unmarked siblings created by layout
  -- reflow / `:split` / plugin-driven `nvim_open_win` were invisible
  -- to the singleton's logging (no `panel opened` event fired
  -- because the window wasn't created via `Panel:open()`).
  --
  -- Detection is deferred via `vim.schedule()` because at WinNew
  -- firing time the new window's buffer may not yet be set
  -- (`:split` initially places the parent's buffer, then nvim's
  -- next BufWinEnter retargets if a different buffer was
  -- requested). One main-loop tick later, the buffer is stable.
  --
  -- This is a DETECTION-only event — it does NOT close the
  -- sibling itself; the post-VimResized scheduled
  -- `_cleanup_unmarked_siblings` pass owns the close. A separate
  -- detection event lets us tell apart "a layout reflow created
  -- this sibling" (paired with a VimResized cleanup log ~ms later)
  -- vs "some other path created it" (no VimResized cleanup follows,
  -- so the sibling persists until next reflow or until the panel
  -- guard's WinEnter swap fires).
  vim.api.nvim_create_autocmd("WinNew", {
    group = group,
    callback = function()
      vim.schedule(function()
        if not p:_is_open() then return end
        local panel_bufnr = nil
        do
          local ok, b = pcall(vim.api.nvim_win_get_buf, p.winid)
          if ok then panel_bufnr = b end
        end
        if not panel_bufnr then return end

        -- Look for windows that are NOT the panel itself but hold
        -- the panel's tracked buffer + lack the panel marker.
        local siblings = {}
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if w ~= p.winid then
            local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, w)
            if ok_buf and buf == panel_bufnr then
              local ok_var, marker = pcall(
                vim.api.nvim_win_get_var, w, p._marker_var)
              local has_marker = ok_var and marker == 1
              if not has_marker then
                siblings[#siblings + 1] = w
              end
            end
          end
        end
        if #siblings == 0 then return end

        log_panel.info("unmarked sibling detected (WinNew)",
          { fields = {
              panel             = opts.name,
              panel_winid       = p.winid,
              panel_bufnr       = panel_bufnr,
              sibling_winids    = siblings,
              n_siblings        = #siblings,
              marker_var        = p._marker_var,
              traceback         = debug.traceback("", 2),
              columns           = vim.o.columns,
              lines             = vim.o.lines,
            } })
      end)
    end,
  })

  -- WinClosed: log when a window dies. If it's the panel's own
  -- window, log INFO (correlates with the "panel went away without a
  -- close() call" path that bypasses singleton tracking). For other
  -- windows we don't emit — would be too chatty.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      if not closed then return end
      if closed == p.winid then
        log_panel.info("panel window closed externally",
          { fields = {
              panel       = opts.name,
              winid       = closed,
              marker_var  = p._marker_var,
              via         = "WinClosed autocmd",
            } })
      end
    end,
  })

  _registry[opts.name] = p
  return p
end

---Test-only: blow away the registry. Production code never calls
---this.
function M._reset_for_tests()
  for _, p in pairs(_registry) do
    pcall(p.dispose, p)
  end
  _registry = {}
end

return M
