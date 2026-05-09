---Float helpers for the AutoVim family.
---
---Phase 6 per ADR 0006 + auto-core-todos. Three primitives:
---
---  M.help_overlay(lines, opts?)   → handle    -- centered help float
---  M.ghost(opts?)                 → handle    -- invisible 1×1 keystroke target
---  M.confirm(prompt, opts?)                   -- yes/no via vim.ui.select
---
---Each primitive that creates a window publishes:
---  float:opened { kind, buf, win }
---  float:closed { kind, buf, win }
---
---Closing semantics:
---  - help_overlay closes on `q`, `<esc>`, `<cr>`, or any of the
---    user-overridable keys in `opts.dismiss_keys`. Also auto-
---    closes when focus leaves the float (BufLeave).
---  - ghost provides an explicit `:close()` method on its handle.
---    No auto-close — ghosts are intentional.
---  - confirm is a thin wrapper around `vim.ui.select`; its
---    lifecycle is whatever the active select-implementation does.
---
---Highlight wiring:
---  Floats use `AutoCoreFloatNormal` / `AutoCoreFloatBorder` /
---  `AutoCoreFloatTitle` from the canonical registry
---  (`auto-core.ui.highlights`). `M.ensure()` runs once per first
---  use; consumers can call `theme_override` to restyle.
---@module 'auto-core.ui.float'

local events = require("auto-core.events")
local hl     = require("auto-core.ui.highlights")

local M = {}

---@class AutoCoreFloatHandle
---@field buf integer
---@field win integer
---@field close fun(): nil

-- ── help_overlay ─────────────────────────────────────────────

---Normalize a line entry into a string. Accepts:
---  "free-form text"
---  { key, desc }              -- positional pair
---  { key = "?", desc = "…" }  -- named pair
---@param line any
---@return string
local function format_help_line(line)
  if type(line) == "string" then return "  " .. line end
  if type(line) == "table" then
    local key  = line[1] or line.key  or ""
    local desc = line[2] or line.desc or ""
    if key == "" and desc == "" then return "" end
    return string.format("  %-12s  %s", key, desc)
  end
  return "  " .. tostring(line)
end

---@class AutoCoreHelpOverlayOpts
---@field title       string?      -- optional centered title
---@field width       integer?     -- override auto-sized width
---@field height      integer?     -- override auto-sized height
---@field border      ("rounded"|"single"|"double"|"shadow"|"none"|string[])?
---@field dismiss_keys string[]?   -- extra keys that close the overlay; default {q,<esc>,<cr>,?}
---@field on_close    fun()?       -- fired after the float closes

---Open a centered help overlay listing key/description pairs.
---Returns a handle with the buffer + window IDs and a `close()`
---method.
---@param lines (string|{[1]: string, [2]: string}|{key: string, desc: string})[]
---@param opts AutoCoreHelpOverlayOpts?
---@return AutoCoreFloatHandle
function M.help_overlay(lines, opts)
  hl.ensure()
  opts = opts or {}

  local rendered = {}
  for _, line in ipairs(lines) do
    rendered[#rendered + 1] = format_help_line(line)
  end
  if #rendered == 0 then rendered = { "  (no help entries)" } end

  -- Auto-size: width = longest line + 2, capped to leave editor margin.
  local width = opts.width
  if not width then
    width = 30
    for _, l in ipairs(rendered) do
      if #l + 2 > width then width = #l + 2 end
    end
  end
  width  = math.min(width,  math.max(20, vim.o.columns - 4))
  local height = opts.height or #rendered
  height = math.min(height, math.max(3,  vim.o.lines   - 4))

  local row = math.floor((vim.o.lines   - height) / 2)
  local col = math.floor((vim.o.columns - width)  / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype   = "auto-core-help"

  local win_opts = {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = opts.border or "rounded",
  }
  if opts.title then
    win_opts.title     = opts.title
    win_opts.title_pos = "center"
  end
  local win = vim.api.nvim_open_win(buf, true, win_opts)

  pcall(vim.api.nvim_set_option_value, "winhl",
    "Normal:AutoCoreFloatNormal,FloatBorder:AutoCoreFloatBorder,FloatTitle:AutoCoreFloatTitle",
    { win = win })

  -- Closer used by every dismiss path.
  local closed = false
  local function do_close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    events.publish("float:closed", {
      kind = "help_overlay", buf = buf, win = win,
    })
    if opts.on_close then pcall(opts.on_close) end
  end

  -- Buffer-local dismiss keys.
  local default_keys = { "q", "<esc>", "<cr>", "?" }
  local keys = opts.dismiss_keys or default_keys
  for _, key in ipairs(keys) do
    pcall(vim.keymap.set, "n", key, do_close, {
      buffer = buf, nowait = true, silent = true,
      desc   = "auto-core: dismiss help overlay",
    })
  end

  -- Auto-close when focus leaves the float (e.g. user clicks
  -- outside or runs `:wincmd p`).
  pcall(vim.api.nvim_create_autocmd, "BufLeave", {
    buffer  = buf,
    once    = true,
    callback = do_close,
  })

  events.publish("float:opened", {
    kind = "help_overlay", buf = buf, win = win,
  })

  return { buf = buf, win = win, close = do_close }
end

-- ── ghost ─────────────────────────────────────────────

---@class AutoCoreGhostOpts
---@field focus boolean?    -- default true: take focus immediately
---@field row   integer?    -- default lines-1 (bottom-left)
---@field col   integer?    -- default 0

---Open an invisible 1×1 floating window — a keystroke target
---without visible UI. Used by auto-agents's diff-parity flow:
---open a ghost, set buffer-local mappings to absorb keys, close
---when done.
---@param opts AutoCoreGhostOpts?
---@return AutoCoreFloatHandle
function M.ghost(opts)
  hl.ensure()
  opts = opts or {}
  local focus = opts.focus
  if focus == nil then focus = true end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "auto-core-ghost"

  local row = opts.row or math.max(0, vim.o.lines - 1)
  local col = opts.col or 0

  local win = vim.api.nvim_open_win(buf, focus, {
    relative  = "editor",
    width     = 1,
    height    = 1,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "none",
    focusable = true,
    -- noautocmd minimizes side-effects from the window flip.
    noautocmd = true,
  })

  -- Hide it visually: blank the cell + dim cursor presence by
  -- tying Normal to FloatNormal (consumers can theme_override
  -- AutoCoreFloatNormal to make it truly invisible).
  pcall(vim.api.nvim_set_option_value, "winhl",
    "Normal:AutoCoreFloatNormal", { win = win })

  local closed = false
  local function do_close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    events.publish("float:closed", {
      kind = "ghost", buf = buf, win = win,
    })
  end

  events.publish("float:opened", {
    kind = "ghost", buf = buf, win = win,
  })

  return { buf = buf, win = win, close = do_close }
end

-- ── confirm ─────────────────────────────────────────────

---@class AutoCoreConfirmOpts
---@field items       string[]?                  -- override yes/no with custom list
---@field default     string?                    -- prompt-time hint
---@field on_choice   (fun(choice: string?))?    -- nil if cancelled
---@field format_item (fun(item: string): string)?

---Yes/no prompt via `vim.ui.select` with a consistent shape.
---Calls `opts.on_choice(choice)` once the user picks; `choice` is
---nil when they cancel. The default item list is `{ "yes", "no" }`
---— pass `opts.items` to use a different set (e.g. for a
---three-way confirm).
---@param prompt string
---@param opts   AutoCoreConfirmOpts?
function M.confirm(prompt, opts)
  opts = opts or {}
  local items = opts.items or { "yes", "no" }
  vim.ui.select(items, {
    prompt      = prompt,
    format_item = opts.format_item,
  }, function(choice)
    if opts.on_choice then pcall(opts.on_choice, choice) end
  end)
end

return M
