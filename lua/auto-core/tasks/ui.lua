---`:AutoCoreChannel` panel — eat-our-own-dogfood UI built on
---`auto-core.ui.panel` + `auto-core.ui.section`. Renders the live
---message channel + an at-a-glance per-agent status strip.
---
---Phase 5 per ADR 0006 + auto-core-todos.
---
---Public surface:
---
---  ui.open()       — open (or focus) the channel panel
---  ui.close()      — close the panel
---  ui.toggle()     — open if closed, close if open
---  ui.refresh()    — re-render explicitly (auto-fires on events)
---
---Sections (numeric switch via 0..9 keys inside the panel):
---  0: messages      — recent channel log, newest at the bottom
---  1: status        — per-agent idle/waiting/working strip
---  2: queues        — outstanding per-agent task queues
---
---Panel anchored RIGHT (the left slot is conventionally taken by
---auto-finder; auto-agents takes its own right slot in the
---agent-config flow — when this panel is opened it occupies the
---right slot for the duration). Side override is in opts if a
---consumer needs to relocate.
---@module 'auto-core.tasks.ui'

local panel_mod   = require("auto-core.ui.panel")
local section_mod = require("auto-core.ui.section")
local events      = require("auto-core.events")
local channel     = require("auto-core.tasks.channel")
local status_mod  = require("auto-core.tasks.status")
local queue_mod   = require("auto-core.tasks.queue")

local M = {}

local PANEL_NAME = "auto-core-channel"
local FILETYPE   = "auto-core-channel"

local _panel    = nil    -- AutoCorePanel singleton
local _registry = nil    -- section registry

-- Per-section bufnr cache (assigned on first focus). Cleared on
-- panel close so a re-open re-mounts cleanly.
local _bufs = { messages = nil, status = nil, queues = nil }

-- ── render helpers ───────────────────────────────────────────

local function fmt_message(m)
  local who
  if m.to and m.to ~= "" then
    who = string.format("%s → %s", m.from, m.to)
  else
    who = m.from
  end
  return string.format("[%s] %-7s %s: %s",
    m.sent_at_iso or "", "(" .. m.kind .. ")", who, m.body or "")
end

local function render_messages(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local lines = {}
  for _, m in ipairs(channel.recent(200)) do
    lines[#lines + 1] = fmt_message(m)
  end
  if #lines == 0 then
    lines = { "(no messages yet — call `auto-core.tasks.channel.send{...}`)" }
  end
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].buftype    = "nofile"
  vim.bo[bufnr].swapfile   = false
  vim.bo[bufnr].filetype   = FILETYPE
end

local function render_status(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local lines = {}
  local list = status_mod.list()
  -- Sort agent names so the strip is stable across renders.
  local agents = {}
  for name in pairs(list) do agents[#agents + 1] = name end
  table.sort(agents)
  for _, name in ipairs(agents) do
    lines[#lines + 1] = string.format("  %-20s  %s", name, list[name])
  end
  if #lines == 0 then
    lines = { "(no agents reporting status — call `tasks.status.set(name, 'working')`)" }
  end
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].buftype    = "nofile"
  vim.bo[bufnr].swapfile   = false
  vim.bo[bufnr].filetype   = FILETYPE
end

local function render_queues(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local lines = {}
  local tasks = queue_mod.list()
  -- Group by agent.
  local by_agent = {}
  for _, t in ipairs(tasks) do
    by_agent[t.agent] = by_agent[t.agent] or {}
    by_agent[t.agent][#by_agent[t.agent] + 1] = t
  end
  local agent_names = {}
  for name in pairs(by_agent) do agent_names[#agent_names + 1] = name end
  table.sort(agent_names)
  for _, name in ipairs(agent_names) do
    lines[#lines + 1] = name .. ":"
    for _, t in ipairs(by_agent[name]) do
      lines[#lines + 1] = string.format(
        "  #%d  %-7s  %-8s  %s",
        t.id, t.priority, t.status,
        type(t.payload) == "string" and t.payload or
          (t.payload ~= nil and vim.inspect(t.payload) or ""))
    end
  end
  if #lines == 0 then
    lines = { "(no queued tasks — call `tasks.queue.enqueue(agent, {...})`)" }
  end
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].buftype    = "nofile"
  vim.bo[bufnr].swapfile   = false
  vim.bo[bufnr].filetype   = FILETYPE
end

local function ensure_section_buf(slot_name, render_fn)
  if _bufs[slot_name] and vim.api.nvim_buf_is_valid(_bufs[slot_name]) then
    render_fn(_bufs[slot_name])
    return _bufs[slot_name]
  end
  local b = vim.api.nvim_create_buf(false, true)
  _bufs[slot_name] = b
  render_fn(b)
  return b
end

-- Subscribe once: any time data changes, re-render the active
-- section. Idempotent — `_subscribed` flag prevents double-wiring.
local _subscribed = false
local function ensure_subscriptions()
  if _subscribed then return end
  _subscribed = true
  events.subscribe("agent.message:sent", function() M.refresh() end)
  events.subscribe("agent.status:changed", function() M.refresh() end)
  events.subscribe("agent.task:queued", function() M.refresh() end)
  events.subscribe("agent.task:claimed", function() M.refresh() end)
  events.subscribe("agent.task:completed", function() M.refresh() end)
end

-- ── public API ───────────────────────────────────────────────

---Open the channel panel. Idempotent — safe to re-call.
function M.open()
  ensure_subscriptions()
  if not _panel then
    _panel = panel_mod.new({
      name     = PANEL_NAME,
      side     = "right",
      width    = { default = 60, min = 40, max = 120 },
      filetype = FILETYPE,
      on_close = function()
        -- Wipe section buffers so a re-open re-mounts cleanly.
        for k, b in pairs(_bufs) do
          if b and vim.api.nvim_buf_is_valid(b) then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
          end
          _bufs[k] = nil
        end
        _registry = nil
      end,
    })
  end
  local winid = _panel:open()
  if not winid then return end

  if not _registry then
    _registry = section_mod.attach(_panel, {
      {
        number      = 0,
        name        = "messages",
        get_buffer  = function() return ensure_section_buf("messages", render_messages) end,
        on_focus    = function(_, b)
          if b and vim.api.nvim_buf_is_valid(b) then render_messages(b) end
        end,
      },
      {
        number      = 1,
        name        = "status",
        get_buffer  = function() return ensure_section_buf("status", render_status) end,
        on_focus    = function(_, b)
          if b and vim.api.nvim_buf_is_valid(b) then render_status(b) end
        end,
      },
      {
        number      = 2,
        name        = "queues",
        get_buffer  = function() return ensure_section_buf("queues", render_queues) end,
        on_focus    = function(_, b)
          if b and vim.api.nvim_buf_is_valid(b) then render_queues(b) end
        end,
      },
    })
  end

  _registry:focus(0)
end

---Close the panel.
function M.close()
  if _panel and _panel:_is_open() then _panel:close() end
end

---Toggle.
function M.toggle()
  if _panel and _panel:_is_open() then M.close() else M.open() end
end

---Force a re-render of whatever section is currently focused. Cheap
---— hands off to the section's render function. Safe to call when
---the panel isn't open (no-op).
function M.refresh()
  if not _panel or not _panel:_is_open() or not _registry then return end
  -- The registry exposes the active section index via
  -- `_active`/`active()` internally; section_mod's contract gives
  -- us no public reader, so we just render every section's buffer.
  -- Cheap and correct.
  if _bufs.messages and vim.api.nvim_buf_is_valid(_bufs.messages) then
    render_messages(_bufs.messages)
  end
  if _bufs.status and vim.api.nvim_buf_is_valid(_bufs.status) then
    render_status(_bufs.status)
  end
  if _bufs.queues and vim.api.nvim_buf_is_valid(_bufs.queues) then
    render_queues(_bufs.queues)
  end
end

---Test-only: tear down panel, registry, buffers, and reset
---subscription wiring. Production code never calls this.
function M._reset_for_tests()
  if _panel then pcall(function() _panel:dispose() end) end
  _panel    = nil
  _registry = nil
  for k, b in pairs(_bufs) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    _bufs[k] = nil
  end
  _subscribed = false
end

return M
