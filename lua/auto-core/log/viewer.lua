---auto-core.log.viewer — `:AutoCoreLog` 3-pane snapshot viewer.
---
---Per ADR 0021 §7. Mounts `auto-core.ui.float.multi` with three
---content panes:
---
---  left    — list of dump sources. Slot 1 is always **Memory**
---            (`log.recent()` snapshot at open time); slots 2..N
---            are JSONL dump files found in
---            `stdpath('cache')/auto-core/dumps/`.
---  middle  — entries from the currently-selected source, after
---            substring + level filters.
---  preview — formatted detail view of the entry under the middle
---            pane's cursor.
---
---Snapshot semantics: the Memory pane reads the live ring once at
---open time and caches the result for the viewer's lifetime. Live
---tail is explicitly out of scope (ADR §16 Q1). The `R` binding
---re-snapshots Memory in place — cheap, addresses the only material
---drawback of the snapshot-only model (ADR §16 Q2; decided yes by
---ultron-prime on reassignment).
---
---Bindings table (ADR §7 + §16 Q2):
---
---  | Key            | Pane    | Action                                       |
---  |----------------|---------|----------------------------------------------|
---  | `1`..`9`       | left    | select dump at that slot                     |
---  | `<CR>`         | left    | load dump under cursor                       |
---  | `E`            | left    | export Memory → dump file                    |
---  | `D`            | left    | delete: Memory → `log.clear()`; file → unlink|
---  | `R`            | left    | re-snapshot Memory (§16 Q2)                  |
---  | `/`            | middle  | substring filter over rendered rows          |
---  | `f`            | middle  | cycle level filter ALL→INFO+→WARN+→ERROR     |
---  | `<Tab>`/`<S-Tab>` | any  | cycle panes forward / backward               |
---  | `<C-h>`/`<C-l>`   | any  | directional pane move                        |
---  | `q` / `<Esc>`  | any     | close (inherited from `ui.float.multi`)      |
---@module 'auto-core.log.viewer'

local M = {}

local NAME = "auto_core_log_viewer"

local mfloat = require("auto-core.ui.float.multi")
local log    = require("auto-core.log")
local dumps  = require("auto-core.log.dumps")

-- Module-level singleton. `_state` is `nil` when the viewer is
-- closed; the multi-float instance's `on_close` callback clears it.
---@type table?
local _state = nil

-- ── filter table ─────────────────────────────────────────────

-- Level numbering matches `log.levels`: ERROR=1 WARN=2 INFO=3
-- DEBUG=4 TRACE=5. A filter passes an entry if its level is `<=`
-- `min_level`, so smaller `min_level` is stricter.
local LEVEL_FILTERS = {
  { name = "ALL",   min_level = 5 },
  { name = "INFO+", min_level = 3 },
  { name = "WARN+", min_level = 2 },
  { name = "ERROR", min_level = 1 },
}
M._LEVEL_FILTERS = LEVEL_FILTERS

local function _apply_filters(entries, substring, level_idx)
  local lf = LEVEL_FILTERS[level_idx] or LEVEL_FILTERS[1]
  local needle = (substring or ""):lower()
  local out = {}
  for _, e in ipairs(entries) do
    local lvl_ok = (e.level or 5) <= lf.min_level
    local sub_ok = needle == ""
      or (e.message    and e.message:lower():find(needle, 1, true) ~= nil)
      or (e.component  and e.component:lower():find(needle, 1, true) ~= nil)
      or (e.event_type and e.event_type:lower():find(needle, 1, true) ~= nil)
    if lvl_ok and sub_ok then
      out[#out + 1] = e
    end
  end
  return out
end
M._apply_filters = _apply_filters

-- ── rendering ────────────────────────────────────────────────

local function _render_dump_list(state)
  local lines = {}
  for i, d in ipairs(state.dumps) do
    local marker = (i == state.selected_idx) and "›" or " "
    if d.kind == "memory" then
      lines[i] = string.format("%s [%d] Memory (%d)",
        marker, i, #state.memory_entries)
    else
      lines[i] = string.format("%s  %d  %s", marker, i, d.label)
    end
  end
  if #lines == 0 then lines[1] = "  (no sources)" end
  return lines
end

-- Strip the `[AutoCore] [<comp>] [<lvl>] ` prefix from the stored
-- `message` for compact rendering in the middle pane. The prefix
-- carries no information the row already shows in dedicated columns.
local function _strip_prefix(message, component, level_name)
  if not message then return "" end
  local m = message
  m = m:gsub("^%[AutoCore%] ", "", 1)
  if component and component ~= "" then
    m = m:gsub("^%[" .. vim.pesc(component) .. "%] ", "", 1)
  end
  if level_name and level_name ~= "" then
    m = m:gsub("^%[" .. vim.pesc(level_name) .. "%] ", "", 1)
  end
  return m
end

local function _render_entries(state)
  local filtered = state.filtered_entries
  if #filtered == 0 then
    return { "  (no entries match the current filter)" }
  end
  local lines = {}
  for i, e in ipairs(filtered) do
    local ts_iso = e._ts_display or "????-??-??T??:??:??Z"
    -- Compact HH:MM:SS for the middle column.
    local short_ts = ts_iso:match("T(%d%d:%d%d:%d%d)") or ts_iso
    local comp  = e.component or "-"
    local lvl   = e.level_name or "?"
    local body  = _strip_prefix(e.message, e.component, e.level_name)
    lines[i] = string.format("%s %-5s %-28s %s", short_ts, lvl, comp, body)
  end
  return lines
end

local function _render_detail(state)
  local filtered = state.filtered_entries
  if #filtered == 0 then return { "  (no entry selected)" } end
  local e = filtered[state.cursor_idx or 1]
  if not e then return { "  (invalid selection)" } end

  local lines = {
    "ts:         " .. (e._ts_display or "-"),
    "level:      " .. (e.level_name or "-"),
    "component:  " .. (e.component or "-"),
    "event_type: " .. (e.event_type or "-"),
    "",
    "message:",
  }
  for _, ml in ipairs(vim.split(e.message or "", "\n", { plain = true })) do
    lines[#lines + 1] = "  " .. ml
  end
  if e.fields ~= nil then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "fields:"
    for _, fl in ipairs(vim.split(vim.inspect(e.fields), "\n", { plain = true })) do
      lines[#lines + 1] = "  " .. fl
    end
  end
  return lines
end

local function _set_lines(bufnr, lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

local function _redraw(state)
  _set_lines(state.float:bufnr("left"),    _render_dump_list(state))
  _set_lines(state.float:bufnr("middle"),  _render_entries(state))
  _set_lines(state.float:bufnr("preview"), _render_detail(state))
end

-- ── state mutation ───────────────────────────────────────────

local function _refilter(state)
  state.filtered_entries = _apply_filters(
    state.current_entries, state.filter_substring, state.filter_level_idx)
  if state.cursor_idx == nil or state.cursor_idx < 1 then
    state.cursor_idx = 1
  elseif state.cursor_idx > #state.filtered_entries then
    state.cursor_idx = math.max(1, #state.filtered_entries)
  end
end

local function _attach_display_ts_memory(entries, now_wall_s, now_mono_ms)
  for _, e in ipairs(entries) do
    e._ts_display = dumps.iso_from_mono(e.ts, now_wall_s, now_mono_ms)
  end
end

local function _attach_display_ts_disk(entries)
  for _, e in ipairs(entries) do e._ts_display = e.ts_iso end
end

local function _snapshot_memory(state)
  -- Defensive shallow-copy so future ring mutations don't leak into
  -- the snapshot. ADR §7 acceptance: "ring snapshot is read-only
  -- (mutations don't leak back into the live ring)" — by copying we
  -- protect the snapshot from the OPPOSITE direction (live ring
  -- mutations leaking into our cached view).
  local live = log.recent()
  local copy = {}
  for i, e in ipairs(live) do
    copy[i] = vim.tbl_extend("force", {}, e)
  end
  state.memory_entries = copy
  state.snapshot_wall  = os.time()
  state.snapshot_mono  = vim.uv.now()
  _attach_display_ts_memory(copy, state.snapshot_wall, state.snapshot_mono)
end

local function _load_selected(state)
  local src = state.dumps[state.selected_idx]
  if not src then
    state.current_entries = {}
  elseif src.kind == "memory" then
    state.current_entries = state.memory_entries
  else
    local entries, err = dumps.read(src.path)
    if not entries then
      log.error("auto-core.log.viewer", "failed to read dump",
        { fields = { path = src.path, err = err } })
      state.current_entries = {}
    else
      _attach_display_ts_disk(entries)
      state.current_entries = entries
    end
  end
  state.cursor_idx = 1
  _refilter(state)
end

local function _rescan_dumps(state)
  state.dumps = { { kind = "memory", label = "Memory" } }
  for _, f in ipairs(dumps.scan()) do
    state.dumps[#state.dumps + 1] = {
      kind = "file",
      path = f.path,
      label = f.name,
    }
  end
end

-- ── keymaps ──────────────────────────────────────────────────

local function _bind(buf, lhs, fn, desc)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.keymap.set("n", lhs, fn, {
    buffer = buf, silent = true, nowait = true, desc = desc,
  })
end

local function _bind_pane_navigation(state)
  -- Tab / S-Tab / C-h / C-l on every pane buffer. q / Esc are
  -- inherited from `ui.float.multi`.
  for _, pane in ipairs({ "left", "middle", "preview" }) do
    local buf = state.float:bufnr(pane)
    _bind(buf, "<Tab>",   function() state.float:cycle("forward")  end,
      "auto-core.log.viewer: cycle panes forward")
    _bind(buf, "<S-Tab>", function() state.float:cycle("backward") end,
      "auto-core.log.viewer: cycle panes backward")
    -- Directional C-h / C-l. left → middle → preview chain.
    if pane == "left" then
      _bind(buf, "<C-l>", function() state.float:focus("middle") end,
        "auto-core.log.viewer: focus middle")
    elseif pane == "middle" then
      _bind(buf, "<C-h>", function() state.float:focus("left")    end,
        "auto-core.log.viewer: focus left")
      _bind(buf, "<C-l>", function() state.float:focus("preview") end,
        "auto-core.log.viewer: focus preview")
    elseif pane == "preview" then
      _bind(buf, "<C-h>", function() state.float:focus("middle")  end,
        "auto-core.log.viewer: focus middle")
    end
  end
end

local function _bind_left(state)
  local buf = state.float:bufnr("left")
  if not buf then return end

  -- Digit selectors. `nowait` so a single keystroke fires without
  -- the default ambiguity timeout.
  for n = 1, 9 do
    _bind(buf, tostring(n), function()
      if state.dumps[n] then
        state.selected_idx = n
        _load_selected(state)
        _redraw(state)
        -- Move the left pane's cursor to keep the marker in sync.
        local lwin = state.float:winid("left")
        if lwin and vim.api.nvim_win_is_valid(lwin) then
          pcall(vim.api.nvim_win_set_cursor, lwin, { n, 0 })
        end
      end
    end, "auto-core.log.viewer: select dump " .. n)
  end

  -- <CR>: load the dump under the left pane's cursor.
  _bind(buf, "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if state.dumps[row] then
      state.selected_idx = row
      _load_selected(state)
      _redraw(state)
    end
  end, "auto-core.log.viewer: load dump at cursor")

  -- E: export Memory → JSONL.
  _bind(buf, "E", function()
    if state.selected_idx ~= 1 then
      log.warn("auto-core.log.viewer",
        "E exports Memory only — current selection is a dump file")
      return
    end
    local path, err = dumps.write(state.memory_entries)
    if not path then
      log.error("auto-core.log.viewer", "export failed",
        { fields = { err = err } })
      return
    end
    log.notify("exported → " .. vim.fn.fnamemodify(path, ":~"), {
      level = "info",
      component = "auto-core.log.viewer",
    })
    _rescan_dumps(state)
    _redraw(state)
  end, "auto-core.log.viewer: export Memory")

  -- D: delete.
  _bind(buf, "D", function()
    local src = state.dumps[state.selected_idx]
    if not src then return end
    if src.kind == "memory" then
      vim.ui.input({ prompt = "Clear in-memory log ring? (y/N) " }, function(input)
        if input == "y" or input == "Y" then
          log.clear()
          _snapshot_memory(state)
          if state.selected_idx == 1 then
            state.current_entries = state.memory_entries
            _refilter(state)
          end
          _redraw(state)
        end
      end)
    else
      vim.ui.input({ prompt = "Delete " .. src.label .. "? (y/N) " }, function(input)
        if input == "y" or input == "Y" then
          local ok, err = dumps.delete(src.path)
          if not ok then
            log.error("auto-core.log.viewer", "delete failed",
              { fields = { path = src.path, err = err } })
            return
          end
          _rescan_dumps(state)
          if state.selected_idx > #state.dumps then
            state.selected_idx = 1
          end
          _load_selected(state)
          _redraw(state)
        end
      end)
    end
  end, "auto-core.log.viewer: delete selection")

  -- R: re-snapshot Memory (ADR §16 Q2).
  _bind(buf, "R", function()
    _snapshot_memory(state)
    if state.selected_idx == 1 then
      state.current_entries = state.memory_entries
      _refilter(state)
    end
    _redraw(state)
  end, "auto-core.log.viewer: re-snapshot Memory")
end

local function _bind_middle(state)
  local buf = state.float:bufnr("middle")
  if not buf then return end

  -- /: substring filter input.
  _bind(buf, "/", function()
    vim.ui.input({
      prompt  = "Filter: ",
      default = state.filter_substring or "",
    }, function(input)
      state.filter_substring = input or ""
      _refilter(state)
      _redraw(state)
    end)
  end, "auto-core.log.viewer: substring filter")

  -- f: cycle level filter.
  _bind(buf, "f", function()
    state.filter_level_idx = (state.filter_level_idx % #LEVEL_FILTERS) + 1
    _refilter(state)
    _redraw(state)
    log.notify("level filter → " .. LEVEL_FILTERS[state.filter_level_idx].name, {
      level = "info",
      component = "auto-core.log.viewer",
    })
  end, "auto-core.log.viewer: cycle level filter")
end

local function _install_cursor_autocmd(state)
  local middle_win = state.float:winid("middle")
  if not middle_win then return end
  local g = vim.api.nvim_create_augroup("AutoCoreLogViewerCursor", { clear = true })
  state._cursor_augroup = g
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = g,
    callback = function()
      if not (_state and _state.float and _state.float:is_open()) then return end
      if vim.api.nvim_get_current_win() ~= _state.float:winid("middle") then return end
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if _state.cursor_idx ~= row then
        _state.cursor_idx = row
        _set_lines(_state.float:bufnr("preview"), _render_detail(_state))
      end
    end,
  })
end

-- ── public surface ───────────────────────────────────────────

---True iff the viewer is currently open.
---@return boolean
function M.is_open()
  return _state ~= nil and _state.float ~= nil and _state.float:is_open()
end

---Open the viewer. Snapshots Memory + scans the dumps dir once, then
---mounts the multi-float. Idempotent — re-opening focuses the middle
---pane instead of recreating the float.
function M.open()
  if _state ~= nil and _state.float ~= nil and _state.float:is_open() then
    _state.float:focus("middle")
    return
  end

  local state = {
    dumps              = {},
    selected_idx       = 1,
    memory_entries     = {},
    current_entries    = {},
    filtered_entries   = {},
    filter_substring   = "",
    filter_level_idx   = 1,
    cursor_idx         = 1,
    snapshot_wall      = 0,
    snapshot_mono      = 0,
  }
  _snapshot_memory(state)
  _rescan_dumps(state)
  state.current_entries = state.memory_entries
  _refilter(state)

  state.float = mfloat.new({
    name  = NAME,
    outer = {
      width_pct  = 0.9,
      height_pct = 0.85,
      title      = " AutoCore Log ",
    },
    panes = {
      left    = { width = 32, title = " Dumps ",   cursorline = true },
      middle  = {              title = " Entries ", cursorline = true },
      preview = { width = 60, min_width = 30, min_middle = 30,
                  title = " Detail " },
    },
    initial_focus = "middle",
    on_close = function()
      if _state and _state._cursor_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, _state._cursor_augroup)
      end
      _state = nil
    end,
  })
  state.float:open()
  _state = state

  _redraw(state)
  _bind_pane_navigation(state)
  _bind_left(state)
  _bind_middle(state)
  _install_cursor_autocmd(state)
end

---Close the viewer. No-op when already closed.
function M.close()
  if _state == nil or _state.float == nil then return end
  _state.float:close()
  -- `_state` is reset to `nil` via the `on_close` callback above.
end

---Toggle the viewer.
function M.toggle()
  if M.is_open() then M.close() else M.open() end
end

---Test-only — drop the module singleton without going through the
---float's close path. Used by smoke tests that want a clean slate
---before exercising open/close idempotency.
function M._reset_for_tests()
  if _state and _state._cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, _state._cursor_augroup)
  end
  if _state and _state.float then pcall(_state.float.close, _state.float) end
  _state = nil
end

---Test-only — return the live module state (or `nil` when closed).
---@return table?
function M._state() return _state end

return M
