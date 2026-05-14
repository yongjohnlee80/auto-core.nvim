---auto-core.debug.mailbox — read-only diagnostic probe for the
---mailbox subsystem.
---
---The event trace ring buffer already records every mailbox/command
---event by virtue of `events.publish` going through `trace.record`,
---so this probe doesn't subscribe to anything new. It just:
---
---  - Filters the existing trace for `core.mailbox:*` /
---    `core.command:*` topics.
---  - Pretty-formats per-event payloads (mailbox id, from→to, kind,
---    correlation_id) so the operator sees a coherent timeline.
---  - Dumps the registry (mailboxes + paths + wake + bootstrap rev).
---  - Reports router status (running? roots? handle count?).
---  - Optional `follow` mode: opens a scratch buffer and appends a
---    line every time a relevant topic fires. The subscriber is
---    cheap (one pattern subscribe), stays off by default.
---
---Public surface mirrors the `winlog` probe so the
---`:AutoCoreDebug` dispatcher in `plugin/auto-core.lua` can route
---both consistently.
---
---@module 'auto-core.debug.mailbox'

local M = {}

local TOPIC_PREFIXES = { "core.mailbox:", "core.command:" }

---@return boolean
local function topic_matches(topic)
  for _, p in ipairs(TOPIC_PREFIXES) do
    if topic:sub(1, #p) == p then return true end
  end
  return false
end

-- ── trace filtering ───────────────────────────────────────

---Recent mailbox/command events from the global trace ring, oldest
---first. `n` caps the number returned (default: every match in the
---ring, up to its current size).
---@param n integer?
---@return table[]
function M.recent(n)
  local trace = require("auto-core.events").trace
  local all = trace.recent()
  local out = {}
  for _, e in ipairs(all) do
    if topic_matches(e.topic) then out[#out + 1] = e end
  end
  if n and n > 0 and #out > n then
    -- Keep the LATEST n.
    local sliced = {}
    for i = #out - n + 1, #out do sliced[#sliced + 1] = out[i] end
    return sliced
  end
  return out
end

-- ── pretty formatting ─────────────────────────────────────

---Format a payload subset into a short single-line summary. Picks
---the fields that matter per topic family — for `core.mailbox:*`,
---that's mailbox id, optional from→to, kind, correlation_id; for
---`core.command:*`, the command name + ok flag.
---@param topic string
---@param p table?
---@return string
local function summarize_payload(topic, p)
  if type(p) ~= "table" then return "" end
  if topic:sub(1, 13) == "core.mailbox:" then
    local parts = {}
    if p.mailbox then parts[#parts + 1] = "mb=" .. tostring(p.mailbox) end
    if p.from and p.to then
      parts[#parts + 1] = string.format("%s→%s", p.from, p.to)
    elseif p.from then
      parts[#parts + 1] = "from=" .. tostring(p.from)
    end
    if p.id then parts[#parts + 1] = "id=" .. tostring(p.id) end
    if p.kind then parts[#parts + 1] = "kind=" .. tostring(p.kind) end
    if type(p.correlation_id) == "string" then
      parts[#parts + 1] = "cor=" .. p.correlation_id
    end
    if p.reason then parts[#parts + 1] = "reason=" .. tostring(p.reason) end
    return table.concat(parts, " ")
  elseif topic:sub(1, 13) == "core.command:" then
    local parts = {}
    if p.name then parts[#parts + 1] = "cmd=" .. tostring(p.name) end
    if p.owner then parts[#parts + 1] = "owner=" .. tostring(p.owner) end
    if p.ok ~= nil then parts[#parts + 1] = "ok=" .. tostring(p.ok) end
    if p.reason then parts[#parts + 1] = "reason=" .. tostring(p.reason) end
    if type(p.correlation_id) == "string" then
      parts[#parts + 1] = "cor=" .. p.correlation_id
    end
    return table.concat(parts, " ")
  end
  return ""
end

---Render one trace entry into a single line: `HH:MM:SS  topic
---summary`.
---@param e table
---@return string
function M.format_entry(e)
  local secs   = math.floor((e.t_ns or vim.uv.hrtime()) / 1e9)
  local hh, mm, ss = secs % 86400, 0, 0
  hh, mm, ss = math.floor(hh / 3600), math.floor((secs % 3600) / 60), secs % 60
  local stamp = string.format("%02d:%02d:%02d", hh, mm, ss)
  return string.format("%s  %-32s %s",
    stamp, e.topic, summarize_payload(e.topic, e.payload))
end

-- ── follow mode ───────────────────────────────────────────

---@class AutoCoreDebugMailboxFollowState
---@field running   boolean
---@field bufnr     integer?
---@field handle    AutoCoreSubHandle?
local _follow = { running = false, bufnr = nil, handle = nil }

local function append_to_follow_buf(line)
  if not _follow.bufnr or not vim.api.nvim_buf_is_valid(_follow.bufnr) then
    return
  end
  local was_modifiable = vim.bo[_follow.bufnr].modifiable
  vim.bo[_follow.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(_follow.bufnr, -1, -1, false, { line })
  vim.bo[_follow.bufnr].modifiable = was_modifiable
  -- Scroll the bottom of every window showing this buffer.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == _follow.bufnr then
      local lc = vim.api.nvim_buf_line_count(_follow.bufnr)
      pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 })
    end
  end
end

---Start follow mode: open a scratch buffer and append a line on
---every matching event. Idempotent. Returns the buffer handle.
---@return integer bufnr
function M.follow_start()
  if _follow.running then return _follow.bufnr end
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_set_name, buf, "auto-core://mailbox-follow")
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].filetype   = "auto-core-mailbox-follow"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "auto-core mailbox follow — appends a line on every core.mailbox:* / core.command:* event",
    string.rep("─", 78),
  })
  vim.bo[buf].modifiable = false
  _follow.bufnr = buf
  _follow.running = true

  local events = require("auto-core.events")
  _follow.handle = events.subscribe("core.mailbox:*", function(payload, topic)
    append_to_follow_buf(M.format_entry({
      topic   = topic,
      payload = payload,
      t_ns    = vim.uv.hrtime(),
    }))
  end)
  -- Two patterns can't be combined cleanly; we register a second
  -- one for the command namespace.
  _follow.handle_cmd = events.subscribe("core.command:*", function(payload, topic)
    append_to_follow_buf(M.format_entry({
      topic   = topic,
      payload = payload,
      t_ns    = vim.uv.hrtime(),
    }))
  end)
  return buf
end

function M.follow_stop()
  if not _follow.running then return end
  local events = require("auto-core.events")
  if _follow.handle then events.unsubscribe(_follow.handle) end
  if _follow.handle_cmd then events.unsubscribe(_follow.handle_cmd) end
  _follow.handle = nil
  _follow.handle_cmd = nil
  _follow.running = false
  -- Leave the buffer in place; user can read scrollback and close
  -- manually. Wiping it would lose history they may want.
end

---@return boolean
function M.follow_is_running() return _follow.running end

-- ── status + registry dumps ───────────────────────────────

---Snapshot of router status + the registry.
---@return table
function M.status()
  local mailbox = require("auto-core.mailbox")
  local registry = mailbox.registry
  local router = mailbox.router

  local roots = {}
  for r, entry in pairs(router.status().roots or {}) do
    roots[r] = entry
  end
  local mailboxes = {}
  for _, rec in ipairs(registry.records()) do
    mailboxes[#mailboxes + 1] = {
      id       = rec.id,
      root     = rec.root,
      dir      = rec.dir,
      wake     = rec.wake,
      bootstrap_revision = rec.bootstrap and rec.bootstrap.revision or nil,
    }
  end
  return {
    router_running = router.is_running(),
    roots          = roots,
    mailboxes      = mailboxes,
    follow_running = _follow.running,
  }
end

---Render the registry as a list of lines suitable for `vim.notify`
---or a scratch buffer.
---@return string[]
function M.registry_lines()
  local s = M.status()
  local lines = {
    "auto-core mailbox registry",
    string.rep("─", 78),
    string.format("router running:   %s", tostring(s.router_running)),
    string.format("follow running:   %s", tostring(s.follow_running)),
    "",
    "watched roots:",
  }
  if next(s.roots) == nil then
    lines[#lines + 1] = "  (none — router not running or no mailboxes registered)"
  else
    for r, entry in pairs(s.roots) do
      lines[#lines + 1] = string.format("  %s  (%d handles)",
        r, entry.handles or 0)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "registered mailboxes:"
  if #s.mailboxes == 0 then
    lines[#lines + 1] = "  (none)"
  else
    for _, mb in ipairs(s.mailboxes) do
      local wake = "—"
      if type(mb.wake) == "table" and mb.wake.command then
        wake = mb.wake.command
        if type(mb.wake.args) == "table" then
          local key, val = next(mb.wake.args)
          if key then wake = wake .. "(" .. tostring(key) .. "=" .. tostring(val) .. ")" end
        end
      end
      lines[#lines + 1] = string.format("  %-22s root=%s  wake=%s  rev=%s",
        mb.id, mb.root,
        wake,
        (mb.bootstrap_revision or ""):sub(1, 12))
    end
  end
  return lines
end

---Pretty-render the recent mailbox/command events as a list of
---lines suitable for a scratch buffer.
---@param n integer?
---@return string[]
function M.tail_lines(n)
  local entries = M.recent(n)
  local lines = {
    string.format("auto-core mailbox event tail — last %d of %d in trace",
      #entries, #(require("auto-core.events").trace.recent())),
    string.rep("─", 78),
  }
  if #entries == 0 then
    lines[#lines + 1] = "  (no events recorded yet — try sending a message or starting the router)"
  else
    for _, e in ipairs(entries) do
      lines[#lines + 1] = M.format_entry(e)
    end
  end
  return lines
end

---Clear the GLOBAL event trace (not just mailbox entries). Same
---behavior as `:AutoCoreEventTraceClear` but accessible from the
---mailbox probe namespace for ergonomics.
function M.clear()
  require("auto-core.events").trace.clear()
end

return M