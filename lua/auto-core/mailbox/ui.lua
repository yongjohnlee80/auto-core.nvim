---auto-core.mailbox.ui — mailbox viewer on auto-core.ui.float.multi.
---
---Three-pane float per ADR 0013 §8:
---
---    left              middle                       preview
---    owner / inbox     messages ordered by time     selected message
---    / outbox          desc (filtered by selection) contents (rendered JSON)
---
---Selection semantics (left pane):
---   - `<owner>`         → combined inbox+outbox+processing+archive+responses
---   - `<owner>/inbox`   → inbox messages only
---   - `<owner>/outbox`  → outbox messages currently pending delivery
---   - `<owner>/archive` → archived (completed/failed)
---   - `<owner>/responses` → responses to messages this owner sent
---
---Each row in the middle pane is `STATE  HH:MM:SS  from→to  subject`.
---STATE icons: ⏳ queued, ⚙ claimed, ✓ completed, ✗ failed, ↩ response,
---⌛ pending. Inbox-backlog warning is appended to the owner's left-
---pane row when its inbox count crosses the configurable threshold
---(default 5).
---
---Pure data-pipeline + render module. The viewer's reactivity (refresh
---on `core.mailbox:*` events) is wired up in `open()` via an event
---subscription that calls `refresh()` on the registered float.
---
---@module 'auto-core.mailbox.ui'

local events    = require("auto-core.events")
local multi     = require("auto-core.ui.float.multi")
local registry  = require("auto-core.mailbox.registry")
local transport = require("auto-core.mailbox.transport")

local M = {}

M.DEFAULT_BACKLOG_THRESHOLD = 5

local FLOAT_NAME = "auto-core-mailbox-viewer"

---@class AutoCoreMailboxUIState
---@field selection   { mailbox: string?, scope: string? }   left-pane selection
---@field entries     AutoCoreMailboxMessageEntry[]           middle-pane data
---@field focused_id  string?                                  currently-previewed msg
---@field tree_lines  string[]                                 left-pane lines
---@field tree_map    { mailbox: string?, scope: string? }[]   one entry per tree line
---@field sub_handle  AutoCoreSubHandle?                       event re-render subscription
---@field backlog_threshold integer
local _state = {
  selection         = { mailbox = nil, scope = nil },
  entries           = {},
  focused_id        = nil,
  tree_lines        = {},
  tree_map          = {},
  sub_handle        = nil,
  backlog_threshold = M.DEFAULT_BACKLOG_THRESHOLD,
}

-- ── data pipeline ──────────────────────────────────────────

local STATE_ICONS = {
  queued       = "⏳",
  claimed      = "⚙",
  completed    = "✓",
  failed       = "✗",
  response     = "↩",
  pending      = "⌛",
  decode_error = "!",
}

local function icon_for(state)
  return STATE_ICONS[state or ""] or " "
end

local function short_time(mtime)
  -- mtime is epoch seconds; format as local HH:MM:SS for the
  -- middle-pane row. We don't surface the full date here since the
  -- list is sorted newest-first and the viewer is a real-time tool.
  return os.date("%H:%M:%S", mtime)
end

---Build the left-pane tree as parallel `tree_lines` + `tree_map`.
---Each line corresponds to one entry in tree_map. tree_map[i] is a
---`{ mailbox = ..., scope = ... }` tuple identifying what `<n>j`
---would select.
---@return string[] lines
---@return { mailbox: string?, scope: string? }[] map
local function build_tree()
  local lines, map = {}, {}
  for _, rec in ipairs(registry.records()) do
    local inbox_count = #transport.list_inbox(rec.id)
    local owner_line = rec.id
    if inbox_count >= _state.backlog_threshold then
      owner_line = string.format("%s  ⚠ inbox=%d", rec.id, inbox_count)
    elseif inbox_count > 0 then
      owner_line = string.format("%s  (inbox=%d)", rec.id, inbox_count)
    end
    lines[#lines + 1] = owner_line
    map[#map + 1]    = { mailbox = rec.id, scope = "all" }
    for _, scope in ipairs({ "inbox", "outbox", "processing", "archive", "responses" }) do
      lines[#lines + 1] = "  " .. scope
      map[#map + 1]    = { mailbox = rec.id, scope = scope }
    end
  end
  if #lines == 0 then
    lines[#lines + 1] = "(no mailboxes registered)"
    map[#map + 1]    = { mailbox = nil, scope = nil }
  end
  return lines, map
end

---Snapshot entries for the active selection.
---@param mailbox string?
---@param scope   string?
---@return AutoCoreMailboxMessageEntry[]
local function entries_for(mailbox, scope)
  if not mailbox or not scope then return {} end
  if scope == "all" then return transport.list_all(mailbox) end
  return transport.list_entries(mailbox, scope)
end

---Render the middle-pane lines from a list of entries.
---@param entries AutoCoreMailboxMessageEntry[]
---@return string[] lines
---@return AutoCoreMailboxMessageEntry[] order  -- parallel to lines, for click→focus
local function render_message_list(entries)
  local lines = {}
  for _, e in ipairs(entries) do
    local fr = e.from or "?"
    local to = e.to   or "?"
    local sj = e.subject and (e.subject ~= "")
                and e.subject:gsub("[\r\n]", " ")
                or  (e.body and ("…" .. (tostring(e.body):sub(1, 40)):gsub("[\r\n]", " ")) or "")
    -- responded annotation (for archive entries).
    local resp_mark = e.responded and " ↩" or ""
    -- subdir hint when scope is "all" — helps distinguish.
    local subhint = (e.subdir and e.subdir ~= "inbox") and (" [" .. e.subdir .. "]") or ""
    lines[#lines + 1] = string.format(
      "%s  %s  %-22s → %-22s  %s%s%s",
      icon_for(e.state),
      short_time(e.mtime),
      fr,
      to,
      tostring(sj),
      resp_mark,
      subhint
    )
  end
  if #lines == 0 then
    lines[#lines + 1] = "(no messages in this view)"
  end
  return lines
end

---Render the preview pane for a single entry. Returns a list of
---lines. Renders the underlying JSON pretty-printed for inspection.
---@param entry AutoCoreMailboxMessageEntry?
---@return string[]
local function render_preview(entry)
  if not entry then
    return { "Select a message in the middle pane to preview." }
  end
  local lines = {
    "id:             " .. tostring(entry.id),
    "state:          " .. tostring(entry.state),
    "subdir:         " .. tostring(entry.subdir),
    "from:           " .. tostring(entry.from),
    "to:             " .. tostring(entry.to),
    "kind:           " .. tostring(entry.kind),
    "correlation_id: " .. tostring(entry.correlation_id),
    "path:           " .. tostring(entry.path),
    "",
    "── raw JSON ─────────────────────────────────────────────────",
  }
  local fd = vim.uv.fs_open(entry.path, "r", 420)
  if fd then
    local stat = vim.uv.fs_fstat(fd)
    local text = stat and vim.uv.fs_read(fd, stat.size, 0)
    pcall(vim.uv.fs_close, fd)
    if text then
      -- Pretty-print: decode then re-encode with indentation. Falls
      -- back to raw text on decode failure.
      local ok_dec, decoded = pcall(vim.json.decode, text)
      if ok_dec then
        -- vim.inspect gives a lua-table view; for JSON-style we'd
        -- want true indented JSON. inspect is good enough for
        -- inspection — it's readable and lua-aware.
        local pretty = vim.inspect(decoded, { indent = "  ", depth = 6 })
        for line in (pretty .. "\n"):gmatch("([^\n]*)\n") do
          lines[#lines + 1] = line
        end
      else
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
          lines[#lines + 1] = line
        end
      end
    end
  end
  return lines
end

-- ── buffer plumbing ────────────────────────────────────────

---@param bufnr integer?
---@param lines string[]
local function set_buf_lines(bufnr, lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = was_modifiable
end

---@param mf AutoCoreMultiFloat
local function refresh_panes(mf)
  -- Left.
  _state.tree_lines, _state.tree_map = build_tree()
  set_buf_lines(mf:bufnr("left"), _state.tree_lines)

  -- Middle.
  _state.entries = entries_for(_state.selection.mailbox, _state.selection.scope)
  set_buf_lines(mf:bufnr("middle"), render_message_list(_state.entries))

  -- Preview: keep focused entry if still present; otherwise show
  -- the first entry in the new list (or the placeholder).
  local focused_entry
  for _, e in ipairs(_state.entries) do
    if e.id == _state.focused_id then focused_entry = e; break end
  end
  if not focused_entry and _state.entries[1] then
    focused_entry = _state.entries[1]
    _state.focused_id = focused_entry.id
  elseif not focused_entry then
    _state.focused_id = nil
  end
  set_buf_lines(mf:bufnr("preview"), render_preview(focused_entry))
end

-- ── selection handling ────────────────────────────────────

---Move the cursor into the left pane and pin the selection from
---the line under the cursor.
---@param mf AutoCoreMultiFloat
local function attach_left_pane_keymaps(mf)
  local lwin = mf:winid("left")
  local lbuf = mf:bufnr("left")
  if not lwin or not lbuf then return end
  local function select_under_cursor()
    local row = vim.api.nvim_win_get_cursor(lwin)[1]
    local entry = _state.tree_map[row]
    if not entry or not entry.mailbox or not entry.scope then return end
    _state.selection = entry
    _state.focused_id = nil
    refresh_panes(mf)
    mf:focus("middle")
  end
  vim.keymap.set("n", "<CR>", select_under_cursor,
    { buffer = lbuf, nowait = true, silent = true,
      desc = "auto-core mailbox: select" })
  vim.keymap.set("n", "<2-LeftMouse>", select_under_cursor,
    { buffer = lbuf, nowait = true, silent = true,
      desc = "auto-core mailbox: select" })
end

---Move the cursor in the middle pane → previews that entry.
---@param mf AutoCoreMultiFloat
local function attach_middle_pane_keymaps(mf)
  local mwin = mf:winid("middle")
  local mbuf = mf:bufnr("middle")
  if not mwin or not mbuf then return end
  local function preview_under_cursor()
    local row = vim.api.nvim_win_get_cursor(mwin)[1]
    local entry = _state.entries[row]
    if not entry then return end
    _state.focused_id = entry.id
    set_buf_lines(mf:bufnr("preview"), render_preview(entry))
  end
  vim.keymap.set("n", "<CR>", preview_under_cursor,
    { buffer = mbuf, nowait = true, silent = true,
      desc = "auto-core mailbox: preview" })
  vim.keymap.set("n", "j", function()
    vim.cmd("normal! j")
    preview_under_cursor()
  end, { buffer = mbuf, nowait = true, silent = true })
  vim.keymap.set("n", "k", function()
    vim.cmd("normal! k")
    preview_under_cursor()
  end, { buffer = mbuf, nowait = true, silent = true })
end

-- ── public API ─────────────────────────────────────────────

---@class AutoCoreMailboxUIOpts
---@field backlog_threshold integer?
---@field initial_mailbox  string?
---@field initial_scope    string?

---Open the viewer. Idempotent — if already open, refocuses it.
---@param opts AutoCoreMailboxUIOpts?
---@return AutoCoreMultiFloat
function M.open(opts)
  opts = opts or {}
  if opts.backlog_threshold then
    _state.backlog_threshold = opts.backlog_threshold
  end

  -- Default selection: first registered mailbox, all-scope. Caller
  -- can override via opts.initial_*.
  if opts.initial_mailbox then
    _state.selection = {
      mailbox = opts.initial_mailbox,
      scope   = opts.initial_scope or "all",
    }
  elseif not _state.selection.mailbox then
    local recs = registry.records()
    if recs[1] then
      _state.selection = { mailbox = recs[1].id, scope = "all" }
    end
  end

  local mf = multi.new({
    name  = FLOAT_NAME,
    outer = {
      width_pct  = 0.92,
      height_pct = 0.88,
      title      = " auto-core mailbox viewer ",
    },
    panes = {
      left = {
        width      = 32,
        title      = " mailboxes ",
        filetype   = "auto-core-mailbox-tree",
        cursorline = true,
      },
      middle = {
        title      = " messages (time desc) ",
        filetype   = "auto-core-mailbox-list",
        cursorline = true,
      },
      preview = {
        width      = 0.40,
        title      = " message ",
        filetype   = "auto-core-mailbox-preview",
      },
      footer = {
        height  = 1,
        content = " <CR> select  j/k preview  q / <Esc> close ",
      },
    },
    initial_focus = "left",
    on_open = function(self)
      refresh_panes(self)
      attach_left_pane_keymaps(self)
      attach_middle_pane_keymaps(self)
      -- Close on q / <Esc> from any pane.
      for _, p in ipairs({ "left", "middle", "preview" }) do
        local b = self:bufnr(p)
        if b then
          vim.keymap.set("n", "q", function() M.close() end,
            { buffer = b, nowait = true, silent = true,
              desc = "auto-core mailbox: close" })
          vim.keymap.set("n", "<Esc>", function() M.close() end,
            { buffer = b, nowait = true, silent = true })
        end
      end
    end,
    on_close = function()
      if _state.sub_handle then
        events.unsubscribe(_state.sub_handle)
        _state.sub_handle = nil
      end
    end,
  })

  if not mf:is_open() then mf:open() end

  -- Auto-refresh on any mailbox / command event.
  if _state.sub_handle then events.unsubscribe(_state.sub_handle) end
  _state.sub_handle = events.subscribe("core.mailbox:*", function()
    vim.schedule(function()
      local cur = multi.get(FLOAT_NAME)
      if cur and cur:is_open() then refresh_panes(cur) end
    end)
  end)

  return mf
end

---Close the viewer (if open). Idempotent.
function M.close()
  local mf = multi.get(FLOAT_NAME)
  if mf then mf:dispose() end
  if _state.sub_handle then
    events.unsubscribe(_state.sub_handle)
    _state.sub_handle = nil
  end
end

---Toggle the viewer.
function M.toggle()
  local mf = multi.get(FLOAT_NAME)
  if mf and mf:is_open() then M.close() else M.open() end
end

---Force a refresh of an open viewer. Useful from tests; users
---don't normally need this (the event subscription handles it).
function M.refresh()
  local mf = multi.get(FLOAT_NAME)
  if mf and mf:is_open() then refresh_panes(mf) end
end

---Read-only access to the viewer's internal state — used by tests
---to assert the data pipeline without rendering UI.
---@return AutoCoreMailboxUIState
function M._state() return _state end

---Force a selection without opening the UI. Used by tests to
---exercise the entry pipeline.
---@param mailbox string
---@param scope   string
function M._select(mailbox, scope)
  _state.selection = { mailbox = mailbox, scope = scope }
  _state.entries   = entries_for(mailbox, scope)
end

---Recompute the tree/entries WITHOUT touching any windows.
---Returns the same data the panes would render. For tests.
---@return { tree: string[], tree_map: table[], entries: AutoCoreMailboxMessageEntry[] }
function M._render_data()
  local lines, map = build_tree()
  return {
    tree     = lines,
    tree_map = map,
    entries  = entries_for(_state.selection.mailbox, _state.selection.scope),
  }
end

---Test-only — wipe state.
function M._reset_for_tests()
  _state = {
    selection         = { mailbox = nil, scope = nil },
    entries           = {},
    focused_id        = nil,
    tree_lines        = {},
    tree_map          = {},
    sub_handle        = nil,
    backlog_threshold = M.DEFAULT_BACKLOG_THRESHOLD,
  }
  pcall(multi.dispose, FLOAT_NAME)
end

return M