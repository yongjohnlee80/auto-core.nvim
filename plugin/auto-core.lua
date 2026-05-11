if vim.g.loaded_auto_core then
  return
end
vim.g.loaded_auto_core = true

-- :AutoCoreEventTrace — open a buffer showing the recent N events
-- recorded by the trace ring buffer. Each line shows time-ago,
-- topic, subscriber count, error count (when > 0), and the top-
-- level payload keys (NOT values — payloads can carry secrets).
--
-- The buffer is regenerated each time the command runs; previous
-- viewer buffers are wiped. Filetype is `auto-core-trace` so users
-- can hook syntax highlighting if they want.
vim.api.nvim_create_user_command("AutoCoreEventTrace", function(opts)
  local events = require("auto-core").events
  local trace = events.trace
  local n = tonumber(opts.fargs[1]) or trace._count
  local entries = trace.recent(n)
  local now_ns = vim.uv.hrtime()

  local lines = {
    "auto-core event trace — most recent " .. #entries
      .. " of " .. trace._count .. " (cap " .. trace._cap .. ")",
    string.rep("─", 78),
  }
  if #entries == 0 then
    lines[#lines + 1] = "  (no events recorded yet)"
  else
    for _, e in ipairs(entries) do
      lines[#lines + 1] = trace.format_line(e, now_ns)
    end
  end

  -- Replace any existing trace buffer with a fresh one. Avoids
  -- accumulating viewer buffers across repeated invocations.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b)
      and vim.bo[b].filetype == "auto-core-trace"
    then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end

  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, "auto-core://event-trace")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "auto-core-trace"
end, {
  nargs = "?",
  desc = "Show the auto-core event trace ring buffer (optional N entries)",
})

vim.api.nvim_create_user_command("AutoCoreEventTraceClear", function()
  require("auto-core").events.trace.clear()
  vim.notify("auto-core: event trace cleared", vim.log.levels.INFO)
end, { desc = "Clear the auto-core event trace ring buffer" })

-- :AutoCoreChannel [open|close|toggle] — control the channel panel.
-- No arg → toggle.
vim.api.nvim_create_user_command("AutoCoreChannel", function(opts)
  local ui = require("auto-core").tasks.ui
  local sub = opts.fargs[1] or "toggle"
  if sub == "open" then
    ui.open()
  elseif sub == "close" then
    ui.close()
  elseif sub == "toggle" then
    ui.toggle()
  elseif sub == "refresh" then
    ui.refresh()
  else
    vim.notify("AutoCoreChannel: unknown subcommand '" .. sub
      .. "' — expected open|close|toggle|refresh",
      vim.log.levels.ERROR)
  end
end, {
  nargs = "?",
  complete = function() return { "open", "close", "toggle", "refresh" } end,
  desc = "Open/close/toggle/refresh the auto-core channel panel",
})

-- :AutoCoreDebug <probe> <subcmd> — opt-in diagnostic probes.
-- Currently shipping: winlog. Subcommands per probe vary; for winlog:
--   :AutoCoreDebug winlog                 → toggle on/off
--   :AutoCoreDebug winlog on              → start
--   :AutoCoreDebug winlog off             → stop
--   :AutoCoreDebug winlog status          → show running state + counts
--   :AutoCoreDebug winlog tail [N=40]     → show last N log lines
--   :AutoCoreDebug winlog clear           → truncate log file
--   :AutoCoreDebug winlog path            → echo the log file path
local function _winlog_dispatch(sub, rest)
  local winlog = require("auto-core").debug.winlog
  if not sub or sub == "toggle" or sub == "" then
    local running = winlog.toggle()
    vim.notify("auto-core winlog: " .. (running and "ON" or "OFF")
      .. " → " .. winlog.path(), vim.log.levels.INFO)
    return
  end
  if sub == "on" or sub == "start" then
    winlog.start()
    vim.notify("auto-core winlog: ON → " .. winlog.path(), vim.log.levels.INFO)
    return
  end
  if sub == "off" or sub == "stop" then
    winlog.stop()
    vim.notify("auto-core winlog: OFF", vim.log.levels.INFO)
    return
  end
  if sub == "status" then
    local s = winlog.status()
    vim.notify(
      "auto-core winlog status:\n"
        .. "  running:     " .. tostring(s.running) .. "\n"
        .. "  log_path:    " .. s.log_path .. "\n"
        .. "  poll:        " .. s.poll_interval_ms .. " ms\n"
        .. "  events:      " .. table.concat(s.events, ",") .. "\n"
        .. "  panel_only:  " .. tostring(s.panel_filter) .. "\n"
        .. "  events_seen: " .. tostring(s.event_count),
      vim.log.levels.INFO)
    return
  end
  if sub == "tail" then
    local n = tonumber(rest[1]) or 40
    local lines = winlog.tail(n)
    if #lines == 0 then
      vim.notify("auto-core winlog: log empty (path=" .. winlog.path() .. ")",
        vim.log.levels.INFO)
      return
    end
    -- Render in a scratch buffer rather than vim.notify so long logs
    -- aren't truncated by notify backends.
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_buf_set_name, buf, "auto-core://winlog-tail")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "auto-core-winlog"
    return
  end
  if sub == "clear" then
    winlog.clear()
    vim.notify("auto-core winlog: log cleared", vim.log.levels.INFO)
    return
  end
  if sub == "path" then
    vim.notify(winlog.path(), vim.log.levels.INFO)
    return
  end
  vim.notify("AutoCoreDebug winlog: unknown subcmd '" .. sub
    .. "' — expected on|off|toggle|status|tail|clear|path",
    vim.log.levels.ERROR)
end

vim.api.nvim_create_user_command("AutoCoreDebug", function(opts)
  local args = opts.fargs
  local probe = args[1]
  if not probe or probe == "" then
    vim.notify("AutoCoreDebug: usage `:AutoCoreDebug <probe> <subcmd>`\n"
      .. "  probes: winlog", vim.log.levels.INFO)
    return
  end
  if probe == "winlog" then
    local sub = args[2]
    local rest = {}
    for i = 3, #args do rest[#rest + 1] = args[i] end
    _winlog_dispatch(sub, rest)
    return
  end
  vim.notify("AutoCoreDebug: unknown probe '" .. probe
    .. "' — known: winlog", vim.log.levels.ERROR)
end, {
  nargs = "*",
  complete = function(_, line)
    local parts = vim.split(line, "%s+")
    if #parts <= 2 then
      return { "winlog" }
    end
    if parts[2] == "winlog" and #parts == 3 then
      return { "on", "off", "toggle", "status", "tail", "clear", "path" }
    end
    return {}
  end,
  desc = "auto-core diagnostic probes (winlog)",
})

-- The auto-core module itself is required lazily on first use by a
-- consumer plugin. We do NOT call setup() here — consumers install
-- via lazy.nvim's `dependencies = { "yongjohnlee80/auto-core.nvim" }`
-- and call setup themselves at the appropriate event.
