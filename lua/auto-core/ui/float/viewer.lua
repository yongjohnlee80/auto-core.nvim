---auto-core.ui.float.viewer — a scrollable float for CONTENT.
---
---Per [[0066-autodb-lua-grid-selection-mode-and-detail-views]] §2.1. This
---exists because `help_overlay` is a primitive for KEY HINTS and kept being
---used for values: it runs `format_help_line()` over its input, dismisses on
---`<cr>`, and auto-closes on `BufLeave`. Two consumers hit the same wall —
---`autodb/lua/autodb/results.lua` (rendering `(no help entries)` instead of a
---cell) and `auto-finder/views/dbase/tree.lua:613`. A detail view needs the
---opposite of all three: render what it is given, stay open while the reader
---presses keys inside it, and close only when asked.
---
---Contract:
---
---  * `lines` are rendered as given. No padding, no key/description
---    alignment. A string containing newlines IS split across buffer lines,
---    because that is the only faithful way to put it in a buffer — nothing
---    else about it is altered.
---  * Closing happens on `opts.close_keys` (default `q` / `<esc>`), on
---    `handle.close()`, or when the window/buffer is destroyed by any other
---    in-session route. **Not** on `<cr>`, and **not** on `BufLeave`.
---  * `opts.on_close` fires EXACTLY ONCE for every in-session close. Process
---    exit (`:qa`) is deliberately exempt: it emits neither `WinClosed` nor
---    `BufWipeout`, and it cannot leak anything, since the process and every
---    float in it cease together. Binding `VimLeavePre` to make the callback
---    merely look complete would run cleanup for windows that are about to
---    stop existing (ADR §2.1, r3).
---  * `opts.opener` is refocused on close IF still valid. That is the whole
---    of what this primitive knows about nesting; parent/child ownership
---    belongs to the consumer, which is the only side that knows what a row
---    and a cell are.
---@module 'auto-core.ui.float.viewer'

local events = require("auto-core.events")
local hl     = require("auto-core.ui.highlights")

local DEFAULT_CLOSE_KEYS = { "q", "<esc>" }

---Split `lines` into buffer-safe strings, REJECTING anything else.
---
---The only transformation is the one a buffer makes unavoidable: a buffer
---line cannot contain a newline, so a line TERMINATOR (`\n` or `\r\n`)
---becomes a line break. Everything else is preserved, including a **lone
---`\r`**, which is data rather than structure — an earlier version stripped
---every `\r` and rendered `a\rb` as `ab`, silently losing a byte from a
---primitive whose entire contract is to show what it was given.
---
---Bad input ERRORS rather than being coerced. It previously ran `tostring`
---over elements and let a non-table, non-string argument fall through to an
---opaque `ipairs` failure, so `viewer(12345)` threw from the middle of this
---function instead of saying what was wrong.
---@param lines string|string[]
---@return string[]
local function to_buffer_lines(lines)
  local list
  if type(lines) == "string" then
    list = { lines }
  elseif type(lines) == "table" then
    -- A table with keys but no array part is almost always a handle passed
    -- by accident (`h.set_lines(h)`), which used to render as one blank line.
    if #lines == 0 and next(lines) ~= nil then
      error("auto-core viewer: `lines` is a table with no array part — "
        .. "expected a string or a list of strings", 3)
    end
    list = lines
  else
    error("auto-core viewer: `lines` must be a string or a list of strings, got "
      .. type(lines), 3)
  end

  local out = {}
  for i, l in ipairs(list) do
    if type(l) ~= "string" then
      error(string.format("auto-core viewer: line %d must be a string, got %s",
        i, type(l)), 3)
    end
    -- CRLF and LF are terminators; a bare CR stays in the line.
    for _, part in ipairs(vim.split((l:gsub("\r\n", "\n")), "\n", { plain = true })) do
      out[#out + 1] = part
    end
  end
  if #out == 0 then out = { "" } end
  return out
end

---@class AutoCoreViewerOpts
---@field title      string?                    -- centered border title
---@field width      integer?                   -- override auto-sized width
---@field height     integer?                   -- override auto-sized height
---@field border     (string|string[])?         -- default "rounded"
---@field wrap       boolean?                   -- default false
---@field cursorline boolean?                   -- default false
---@field filetype   string?                    -- default "auto-core-viewer"
---@field close_keys string[]?                  -- default { "q", "<esc>" }
---@field keymaps    table<string, function>?   -- lhs → fn(handle); normal mode
---@field opener     integer?                   -- window refocused on close if valid
---@field on_close   fun()?                     -- fired once per in-session close

---@class AutoCoreViewerHandle
---@field buf       fun(self): integer
---@field win       fun(self): integer
---@field close     fun(self)
---@field is_open   fun(self): boolean
---@field set_lines fun(self, lines: string|string[])

---Open a scrollable content float.
---@param lines any
---@param opts AutoCoreViewerOpts?
---@return AutoCoreViewerHandle
return function(lines, opts)
  hl.ensure()
  opts = opts or {}

  local rendered = to_buffer_lines(lines)

  local width = opts.width
  if not width then
    width = 30
    for _, l in ipairs(rendered) do
      local w = vim.fn.strdisplaywidth(l) + 2
      if w > width then width = w end
    end
  end
  width = math.min(width, math.max(20, vim.o.columns - 4))
  local height = math.min(opts.height or #rendered, math.max(3, vim.o.lines - 4))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype   = opts.filetype or "auto-core-viewer"

  local win_opts = {
    relative = "editor",
    width    = width,
    height   = height,
    row      = math.floor((vim.o.lines - height) / 2),
    col      = math.floor((vim.o.columns - width) / 2),
    style    = "minimal",
    border   = opts.border or "rounded",
  }
  if opts.title then
    win_opts.title     = opts.title
    win_opts.title_pos = "center"
  end
  local win = vim.api.nvim_open_win(buf, true, win_opts)

  pcall(vim.api.nvim_set_option_value, "winhl",
    "Normal:AutoCoreFloatNormal,FloatBorder:AutoCoreFloatBorder,FloatTitle:AutoCoreFloatTitle",
    { win = win })
  -- The viewer OWNS this window outright — unlike the grid, which borrows a
  -- caller's window and must restore what it changed.
  pcall(vim.api.nvim_set_option_value, "wrap", opts.wrap == true, { win = win })
  pcall(vim.api.nvim_set_option_value, "cursorline", opts.cursorline == true, { win = win })

  local handle
  local closed = false

  ---One closer behind every route, so `on_close` cannot fire twice. Modelled
  ---on `help_overlay`'s `do_close` (`float.lua:122-133`); the difference is
  ---that this one is also reachable from `WinClosed`/`BufWipeout`, because
  ---this float has no `BufLeave` auto-close to catch external destruction.
  local function do_close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    events.publish("float:closed", { kind = "viewer", buf = buf, win = win })
    if opts.on_close then pcall(opts.on_close) end
    -- Last: a cascading `on_close` above may have closed the opener too.
    if opts.opener and vim.api.nvim_win_is_valid(opts.opener) then
      pcall(vim.api.nvim_set_current_win, opts.opener)
    end
  end

  -- METHODS, not fields plus dot-closures. The published contract is
  -- `:close()` / `:is_open()` / `:buf()` / `:win()` / `:set_lines(lines)`, and
  -- a handle that ALSO exposed `buf`/`win` as bare numbers invited
  -- `h:set_lines({"x"})` — which passed the handle itself as `lines` and
  -- rendered one blank line, silently. One calling convention only.
  handle = setmetatable({}, {
    __index = {
      buf     = function() return buf end,
      win     = function() return win end,
      close   = function() return do_close() end,
      is_open = function()
        return (not closed) and vim.api.nvim_win_is_valid(win)
      end,
      set_lines = function(self, new_lines)
        if self ~= handle then
          error("auto-core viewer: call set_lines with `:`, not `.`", 2)
        end
        if closed or not vim.api.nvim_buf_is_valid(buf) then return end
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, to_buffer_lines(new_lines))
        vim.bo[buf].modifiable = false
      end,
    },
  })

  for _, key in ipairs(opts.close_keys or DEFAULT_CLOSE_KEYS) do
    pcall(vim.keymap.set, "n", key, do_close, {
      buffer = buf, nowait = true, silent = true,
      desc   = "auto-core: close viewer",
    })
  end

  for lhs, fn in pairs(opts.keymaps or {}) do
    pcall(vim.keymap.set, "n", lhs, function() fn(handle) end, {
      buffer = buf, nowait = true, silent = true,
      desc   = "auto-core: viewer " .. lhs,
    })
  end

  -- Every OTHER in-session way this window can die. `help_overlay` gets this
  -- for free from its `BufLeave` autocmd; this float drops that on purpose,
  -- so without these two a `:q`, `:only` or layout change would never fire
  -- `on_close` — and a consumer whose `on_close` cascades to a child float
  -- would orphan it.
  pcall(vim.api.nvim_create_autocmd, "WinClosed", {
    pattern = tostring(win), once = true, callback = do_close,
  })
  pcall(vim.api.nvim_create_autocmd, "BufWipeout", {
    buffer = buf, once = true, callback = do_close,
  })

  events.publish("float:opened", { kind = "viewer", buf = buf, win = win })
  return handle
end
