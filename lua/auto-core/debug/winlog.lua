---Window/buffer lifecycle logger — diagnostic probe for singleton
---panel bugs, stray panel-buffer hijacks, and unexplained splits.
---
---Why this exists. The auto-core panel singleton (`auto-core.ui.panel`)
---is protected by a window-local marker + a `WinEnter`/`BufWinEnter`
---leak-guard. When the guard *doesn't* fire (e.g. the offending split
---was created with `noautocmd = true` or under `eventignore = "all"`)
---a duplicate panel can land in the layout and the user sees two
---copies of the same buffer next to each other. Pure-autocmd probes
---miss exactly those cases. This module pairs autocmds with a uv-timer
---poll so a stray window is logged regardless of how it was created.
---
---Use case: turn it on, reproduce the bug, read the log, turn it off.
---The log file lives in `vim.fn.stdpath("cache")` by default so it's
---per-machine + survives nvim restarts.
---
---API:
---  winlog.start(opts?)   -- begin logging
---  winlog.stop()         -- end logging
---  winlog.toggle(opts?)
---  winlog.is_running()   -- boolean
---  winlog.status()       -- { running, log_path, poll_interval_ms, events,
---                            event_count, started_at }
---  winlog.tail(n?)       -- last N lines from the log (default 40)
---  winlog.clear()        -- truncate the log file
---  winlog.path()         -- absolute path to the active log file
---
---opts.log_path           -- override the default
---opts.poll_interval_ms   -- default 200; clamp [50, 5000]
---opts.events             -- autocmd events to subscribe to; default
---                          { "WinNew", "WinClosed", "BufWinEnter",
---                            "WinEnter", "VimResized", "CmdlineLeave" }
---opts.panel_filter       -- when true, only log BufWinEnter/WinEnter
---                          arrivals of buffers carrying
---                          `b:auto_core_panel_owner` — quieter when
---                          you only care about panel hijacks
---@module 'auto-core.debug.winlog'

local M = {}

local AUGROUP_NAME = "AutoCoreDebugWinlog"

---Single source of truth for the module's running state. When
---`running` is false every accessor short-circuits — calling
---`stop()` repeatedly is harmless and reading `status()` works
---before the probe has ever been started.
---@type { running: boolean, log_path: string?, poll_interval_ms: integer, events: string[], panel_filter: boolean, started_at: integer?, event_count: integer, known_wins: table<integer, boolean>?, timer: any?, augroup: integer? }
local S = {
  running = false,
  log_path = nil,
  poll_interval_ms = 200,
  events = {},
  panel_filter = false,
  event_count = 0,
}

local DEFAULT_EVENTS = {
  "WinNew", "WinClosed", "BufWinEnter", "WinEnter",
  "VimResized", "CmdlineLeave",
}

---Resolve the default log path. Lives under `stdpath("cache")` so
---it's per-machine, durable across nvim restarts, and not synced via
---dotfiles repos that mirror `config/state`.
---@return string
local function default_log_path()
  return vim.fn.stdpath("cache") .. "/auto-core-winlog.log"
end

---Append one line to the active log file with a millisecond-precision
---timestamp. Cheap (open/write/close per line) but the probe is opt-in
---and short-lived so the I/O cost is acceptable. Buffering across
---calls would risk losing data when the user kills the session before
---the cache flushes.
---@param line string
local function append(line)
  if not S.log_path then return end
  local f = io.open(S.log_path, "a")
  if not f then return end
  local ms = math.floor((vim.loop.hrtime() / 1e6) % 1000)
  f:write(os.date("%H:%M:%S.") .. string.format("%03d", ms) .. " " .. line .. "\n")
  f:close()
  S.event_count = S.event_count + 1
end

---Render the current tab's windows as a single-line summary.
---Includes window/buffer ids, the float-or-split discriminator
---(`relative` is "" for splits, e.g. "editor"/"win"/"cursor" for
---floats), the panel marker (set by `auto-core.ui.panel:_stamp`),
---the buffer-owner stamp (set by `Panel:_stamp_buffer`), and the
---buffer filetype.
---@return string
local function win_summary()
  local rows = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      local cfg = vim.api.nvim_win_get_config(w)
      local ok_m, m = pcall(vim.api.nvim_win_get_var, w, "auto_core_panel_name")
      local ok_o, owner = pcall(vim.api.nvim_buf_get_var, b, "auto_core_panel_owner")
      rows[#rows + 1] = string.format(
        "w%d/b%d/rel=%s/marker=%s/owner=%s/ft=%s",
        w, b, cfg.relative,
        (ok_m and type(m) == "string") and m or "-",
        (ok_o and type(owner) == "string") and owner or "-",
        vim.bo[b].filetype
      )
    end
  end
  return table.concat(rows, " | ")
end

---Snapshot the current tab's window set as a `{[winid] = true}`
---lookup. Used to detect additions and removals on each poll tick.
---@return table<integer, boolean>
local function snapshot_wins()
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    out[w] = true
  end
  return out
end

---Inspect a window and write a one-line description suitable for the
---POLL-NEW / AC log entries. Pulls everything a panel-leak diagnosis
---typically needs: win/buf ids, split-or-float discriminator,
---window-local panel marker, buffer-local owner stamp, filetype,
---buftype, and the dimensional snapshot.
---@param w integer
---@return string
local function describe_new_win(w)
  if not vim.api.nvim_win_is_valid(w) then
    return string.format("w=%d <invalid>", w)
  end
  local b = vim.api.nvim_win_get_buf(w)
  local cfg = vim.api.nvim_win_get_config(w)
  local ok_m, m = pcall(vim.api.nvim_win_get_var, w, "auto_core_panel_name")
  local ok_o, owner = pcall(vim.api.nvim_buf_get_var, b, "auto_core_panel_owner")
  return string.format(
    "w=%d buf=%d rel=%s split=%s marker=%s buf-owner=%s ft=%s buftype=%s width=%d height=%d",
    w, b, cfg.relative, tostring(cfg.split),
    (ok_m and type(m) == "string") and m or "-",
    (ok_o and type(owner) == "string") and owner or "-",
    vim.bo[b].filetype, vim.bo[b].buftype,
    vim.api.nvim_win_get_width(w), vim.api.nvim_win_get_height(w)
  )
end

---Per-tick poll. Emits POLL-NEW-WIN / POLL-CLOSED-WIN lines for any
---window-set delta vs. the prior tick. The poll is what catches
---windows opened with `noautocmd = true` — the autocmd subscribers
---would miss those by design.
local function tick()
  if not S.running then return end
  local current = snapshot_wins()
  for w in pairs(current) do
    if not S.known_wins[w] then
      append("POLL-NEW-WIN " .. describe_new_win(w))
      append("  layout: " .. vim.inspect(vim.fn.winlayout()):gsub("\n", " "))
      append("  full-snap: " .. win_summary())
    end
  end
  for w in pairs(S.known_wins) do
    if not current[w] then
      append("POLL-CLOSED-WIN w=" .. w)
    end
  end
  S.known_wins = current
end

---Predicate the panel-filter mode uses to skip non-panel events.
---Avoid logging arrivals of unrelated buffers (e.g. file edits, fugitive
---blame windows) so the log stays focused when you're hunting a panel
---hijack.
---@param bufnr integer?
---@return boolean
local function buf_is_panel_owned(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local ok, owner = pcall(vim.api.nvim_buf_get_var, bufnr, "auto_core_panel_owner")
  return ok and type(owner) == "string" and #owner > 0
end

---Validate and merge `opts` against the running defaults. Returns
---a copy — never mutates the input. Out-of-range or bad-type values
---fall back to the prior value (or the module default).
---@param opts table?
---@return string log_path, integer poll_interval_ms, string[] events, boolean panel_filter
local function resolve_opts(opts)
  opts = opts or {}
  local log_path = opts.log_path
  if type(log_path) ~= "string" or #log_path == 0 then
    log_path = S.log_path or default_log_path()
  end

  local poll = opts.poll_interval_ms
  if type(poll) ~= "number" or poll ~= poll then  -- NaN
    poll = S.poll_interval_ms
  end
  if poll < 50 then poll = 50 end
  if poll > 5000 then poll = 5000 end
  poll = math.floor(poll)

  local events = opts.events
  if type(events) ~= "table" or #events == 0 then
    events = (#S.events > 0) and S.events or DEFAULT_EVENTS
  end

  local panel_filter = (opts.panel_filter == true)

  return log_path, poll, events, panel_filter
end

---Install the autocmds for the requested events on a fresh augroup.
---The augroup is cleared first so toggling start→stop→start without
---an intermediate `disable` doesn't accumulate handlers. Returns the
---augroup id so `stop()` can blow it away symmetrically.
---@param events string[]
---@return integer
local function install_autocmds(events)
  local g = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })

  ---Map event-name → handler. Centralized so the handler that runs
  ---for each event is small and uniform — the per-event content lives
  ---in branches rather than five separate registrations.
  local function handler(args)
    if not S.running then return end
    local event = args.event
    if event == "WinNew" then
      local w = vim.api.nvim_get_current_win()
      local b = vim.api.nvim_win_get_buf(w)
      append("AC WinNew w=" .. w .. " buf=" .. b)
    elseif event == "WinClosed" then
      append("AC WinClosed match=" .. tostring(args.match))
    elseif event == "BufWinEnter" then
      if S.panel_filter and not buf_is_panel_owned(args.buf) then return end
      local w = vim.api.nvim_get_current_win()
      append(string.format("AC BufWinEnter w=%d buf=%d match=%s",
        w, args.buf, tostring(args.match)))
    elseif event == "WinEnter" then
      if S.panel_filter then
        local w = vim.api.nvim_get_current_win()
        local b = vim.api.nvim_win_get_buf(w)
        if not buf_is_panel_owned(b) then return end
      end
      local w = vim.api.nvim_get_current_win()
      local b = vim.api.nvim_win_get_buf(w)
      append("AC WinEnter w=" .. w .. " buf=" .. b)
    elseif event == "VimResized" then
      append("AC VimResized cols=" .. vim.o.columns .. " lines=" .. vim.o.lines)
    elseif event == "CmdlineLeave" then
      if args.match == ":" then
        append("AC Cmd: " .. vim.fn.getcmdline())
      end
    end
  end

  for _, e in ipairs(events) do
    vim.api.nvim_create_autocmd(e, { group = g, callback = handler })
  end

  return g
end

---Start the probe. Idempotent — calling `start()` while already
---running re-applies the new opts (poll interval, events, filter,
---log path) without dropping log data. Re-entering with no opts
---preserves whatever's already configured.
---@param opts table?
function M.start(opts)
  local log_path, poll, events, panel_filter = resolve_opts(opts)

  -- Stop any prior timer / augroup before reconfiguring so we don't
  -- end up with a stale timer firing into the new state. We do NOT
  -- truncate the log — the caller decides when to clear via `clear()`.
  if S.timer then
    pcall(S.timer.stop, S.timer)
    pcall(S.timer.close, S.timer)
    S.timer = nil
  end
  if S.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, S.augroup)
    S.augroup = nil
  end

  S.log_path = log_path
  S.poll_interval_ms = poll
  S.events = events
  S.panel_filter = panel_filter
  S.started_at = os.time()
  S.event_count = S.event_count -- preserve across restart; clear() resets
  S.known_wins = snapshot_wins()
  S.running = true

  append("=== winlog started; poll=" .. poll .. "ms events=" ..
    table.concat(events, ",") .. " filter=" .. tostring(panel_filter) ..
    " cols=" .. vim.o.columns .. " lines=" .. vim.o.lines)
  append("INITIAL: " .. win_summary())

  S.augroup = install_autocmds(events)

  local timer = vim.uv.new_timer()
  S.timer = timer
  timer:start(poll, poll, vim.schedule_wrap(tick))
end

---Stop the probe. No-op when not running.
function M.stop()
  if not S.running then return end
  S.running = false
  if S.timer then
    pcall(S.timer.stop, S.timer)
    pcall(S.timer.close, S.timer)
    S.timer = nil
  end
  if S.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, S.augroup)
    S.augroup = nil
  end
  append("=== winlog stopped; events_captured=" .. S.event_count)
end

---Toggle. Returns the new running state.
---@param opts table?
---@return boolean
function M.toggle(opts)
  if S.running then M.stop() else M.start(opts) end
  return S.running
end

---@return boolean
function M.is_running() return S.running end

---Inspect probe state without touching the log file.
---@return table
function M.status()
  return {
    running = S.running,
    log_path = S.log_path or default_log_path(),
    poll_interval_ms = S.poll_interval_ms,
    events = vim.list_extend({}, S.events),
    panel_filter = S.panel_filter,
    event_count = S.event_count,
    started_at = S.started_at,
  }
end

---Read the last `n` lines from the log file. Default 40. Returns
---an empty table when the file doesn't exist yet.
---@param n integer?
---@return string[]
function M.tail(n)
  n = (type(n) == "number" and n > 0) and math.floor(n) or 40
  local path = S.log_path or default_log_path()
  local f = io.open(path, "r")
  if not f then return {} end
  local all = {}
  for line in f:lines() do all[#all + 1] = line end
  f:close()
  local start = math.max(1, #all - n + 1)
  local out = {}
  for i = start, #all do out[#out + 1] = all[i] end
  return out
end

---Truncate the log file. Also resets the in-memory event count so
---`status().event_count` matches what's on disk.
function M.clear()
  local path = S.log_path or default_log_path()
  local f = io.open(path, "w")
  if f then f:close() end
  S.event_count = 0
end

---@return string
function M.path() return S.log_path or default_log_path() end

return M
