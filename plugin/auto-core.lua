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

-- :AutoCoreMailbox [open|close|toggle] — the mailbox viewer.
--   open / close are explicit; bare command toggles. Idempotent on
--   either side. The viewer subscribes to core.mailbox:* internally
--   so it refreshes live as the router fires events.
vim.api.nvim_create_user_command("AutoCoreMailbox", function(opts)
  local mailbox = require("auto-core").mailbox
  local sub = opts.fargs[1] or "toggle"
  if sub == "open" then
    mailbox.ui.open()
  elseif sub == "close" then
    mailbox.ui.close()
  elseif sub == "toggle" then
    mailbox.ui.toggle()
  elseif sub == "refresh" then
    mailbox.ui.refresh()
  else
    vim.notify("AutoCoreMailbox: unknown subcommand '" .. tostring(sub)
      .. "' — expected open|close|toggle|refresh",
      vim.log.levels.ERROR)
  end
end, {
  nargs = "?",
  complete = function() return { "open", "close", "toggle", "refresh" } end,
  desc = "Open/close/toggle the auto-core mailbox viewer",
})

-- Mailbox probe dispatcher. Subcommands mirror the winlog shape so
-- :h AutoCoreDebug stays one mental model.
local function _mailbox_dispatch(sub, rest)
  local probe = require("auto-core").debug.mailbox
  sub = (sub == "" or sub == nil) and "status" or sub

  local function render_lines_in_scratch(buf_name, lines, ft)
    -- Replace any existing viewer with the same name so repeated
    -- invocations don't accumulate buffers.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b)
          and vim.api.nvim_buf_get_name(b):find(buf_name, 1, true)
      then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_buf_set_name, buf, buf_name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype    = "nofile"
    vim.bo[buf].bufhidden  = "wipe"
    vim.bo[buf].swapfile   = false
    vim.bo[buf].modifiable = false
    if ft then vim.bo[buf].filetype = ft end
  end

  if sub == "status" or sub == "registry" then
    render_lines_in_scratch("auto-core://mailbox-registry",
      probe.registry_lines(), "auto-core-mailbox")
    return
  end
  if sub == "tail" then
    local n = tonumber(rest[1]) or 40
    render_lines_in_scratch("auto-core://mailbox-tail",
      probe.tail_lines(n), "auto-core-mailbox")
    return
  end
  if sub == "follow" then
    local act = rest[1] or "toggle"
    if act == "on" or act == "start" then
      probe.follow_start()
      vim.notify("auto-core mailbox follow: ON", vim.log.levels.INFO)
      return
    end
    if act == "off" or act == "stop" then
      probe.follow_stop()
      vim.notify("auto-core mailbox follow: OFF", vim.log.levels.INFO)
      return
    end
    -- toggle
    if probe.follow_is_running() then
      probe.follow_stop()
      vim.notify("auto-core mailbox follow: OFF", vim.log.levels.INFO)
    else
      probe.follow_start()
      vim.notify("auto-core mailbox follow: ON", vim.log.levels.INFO)
    end
    return
  end
  if sub == "clear" then
    probe.clear()
    vim.notify("auto-core: event trace cleared (global)", vim.log.levels.INFO)
    return
  end
  vim.notify("AutoCoreDebug mailbox: unknown subcmd '" .. tostring(sub)
    .. "' — expected status|tail|registry|follow|clear",
    vim.log.levels.ERROR)
end

vim.api.nvim_create_user_command("AutoCoreDebug", function(opts)
  local args = opts.fargs
  local probe = args[1]
  if not probe or probe == "" then
    vim.notify("AutoCoreDebug: usage `:AutoCoreDebug <probe> <subcmd>`\n"
      .. "  probes: winlog, mailbox", vim.log.levels.INFO)
    return
  end
  if probe == "winlog" then
    local sub = args[2]
    local rest = {}
    for i = 3, #args do rest[#rest + 1] = args[i] end
    _winlog_dispatch(sub, rest)
    return
  end
  if probe == "mailbox" then
    local sub = args[2]
    local rest = {}
    for i = 3, #args do rest[#rest + 1] = args[i] end
    _mailbox_dispatch(sub, rest)
    return
  end
  vim.notify("AutoCoreDebug: unknown probe '" .. probe
    .. "' — known: winlog, mailbox", vim.log.levels.ERROR)
end, {
  nargs = "*",
  complete = function(_, line)
    local parts = vim.split(line, "%s+")
    if #parts <= 2 then
      return { "winlog", "mailbox" }
    end
    if parts[2] == "winlog" and #parts == 3 then
      return { "on", "off", "toggle", "status", "tail", "clear", "path" }
    end
    if parts[2] == "mailbox" and #parts == 3 then
      return { "status", "tail", "registry", "follow", "clear" }
    end
    if parts[2] == "mailbox" and parts[3] == "follow" and #parts == 4 then
      return { "on", "off", "toggle" }
    end
    return {}
  end,
  desc = "auto-core diagnostic probes (winlog, mailbox)",
})

-- :AutoCoreLogEvent — manage per-event notification subscriptions
-- registered via `auto-core.log.events`. ADR 0021 §5.
--
--   :AutoCoreLogEvent list [plugin]   — list registered events with
--                                       subscription state, optionally
--                                       filtered to a single plugin
--   :AutoCoreLogEvent notify <event>  — subscribe (toast on next emit)
--   :AutoCoreLogEvent silence <event> — unsubscribe (ring entry only)
--
-- Subscriptions persist across nvim restarts via
-- `auto-core.state.namespace("auto-core.log.events")`.
vim.api.nvim_create_user_command("AutoCoreLogEvent", function(opts)
  local log = require("auto-core").log
  local args = opts.fargs
  local sub = args[1]

  if not sub or sub == "" or sub == "list" then
    local plugin_filter = args[2]
    local rows = log.events.list(plugin_filter)
    if #rows == 0 then
      if plugin_filter then
        vim.notify(("auto-core log events: no events registered for plugin '%s'")
          :format(plugin_filter), vim.log.levels.INFO)
      else
        vim.notify(
          "auto-core log events: no events registered yet "
            .. "(plugins call `log.events.register` in their setup)",
          vim.log.levels.INFO)
      end
      return
    end
    local subbed = 0
    for _, r in ipairs(rows) do
      if log.events.is_notify_enabled(r.event) then subbed = subbed + 1 end
    end
    local header = ("auto-core log events — %d registered, %d subscribed%s")
      :format(#rows, subbed, plugin_filter and (" (plugin: " .. plugin_filter .. ")") or "")
    local lines = { header, string.rep("─", #header) }
    for _, r in ipairs(rows) do
      local state = log.events.is_notify_enabled(r.event)
        and "[notify]" or "[silent]"
      lines[#lines + 1] = ("  %s %s"):format(state, r.event)
    end
    vim.api.nvim_echo(
      vim.tbl_map(function(l) return { l, "Normal" } end, lines),
      true, {})
    return
  end

  if sub == "notify" then
    local event = args[2]
    if not event or event == "" then
      vim.notify("AutoCoreLogEvent notify: missing <event> argument",
        vim.log.levels.ERROR)
      return
    end
    log.events.enable_notify(event)
    vim.notify(("auto-core: notify enabled for `%s`"):format(event),
      vim.log.levels.INFO, { title = "auto-core" })
    return
  end

  if sub == "silence" then
    local event = args[2]
    if not event or event == "" then
      vim.notify("AutoCoreLogEvent silence: missing <event> argument",
        vim.log.levels.ERROR)
      return
    end
    log.events.disable_notify(event)
    vim.notify(("auto-core: notify silenced for `%s`"):format(event),
      vim.log.levels.INFO, { title = "auto-core" })
    return
  end

  vim.notify(("AutoCoreLogEvent: unknown subcommand '%s' — expected list|notify|silence")
    :format(sub), vim.log.levels.ERROR)
end, {
  nargs = "*",
  complete = function(_, line)
    local log = require("auto-core").log
    local parts = vim.split(line, "%s+")
    -- parts[1] is "AutoCoreLogEvent"; parts[2] is the subcommand;
    -- parts[3+] is its argument(s).
    if #parts <= 2 then
      return { "list", "notify", "silence" }
    end
    local sub = parts[2]
    if sub == "list" then
      -- Suggest plugin names from the current registry.
      local seen = {}
      for _, r in ipairs(log.events.list()) do
        seen[r.plugin] = true
      end
      local plugins = {}
      for p in pairs(seen) do plugins[#plugins + 1] = p end
      table.sort(plugins)
      return plugins
    end
    if sub == "notify" then
      -- Offer registered events the user hasn't subscribed to yet.
      local out = {}
      for _, r in ipairs(log.events.list()) do
        if not log.events.is_notify_enabled(r.event) then
          out[#out + 1] = r.event
        end
      end
      return out
    end
    if sub == "silence" then
      -- Offer currently-subscribed events.
      local out = {}
      for _, r in ipairs(log.events.list()) do
        if log.events.is_notify_enabled(r.event) then
          out[#out + 1] = r.event
        end
      end
      return out
    end
    return {}
  end,
  desc = "Manage auto-core log event-type subscriptions (ADR 0021 §5)",
})

-- :AutoCoreLog [open|close|toggle] — the on-demand log viewer.
-- ADR 0021 §7 + §16 Q2. A 3-pane snapshot viewer over
-- `auto-core.ui.float.multi` for incident triage of the in-memory
-- ring + any on-disk JSONL dumps under
-- `stdpath('cache')/auto-core/dumps/`.
vim.api.nvim_create_user_command("AutoCoreLog", function(opts)
  local viewer = require("auto-core.log.viewer")
  local sub = opts.fargs[1] or "toggle"
  if sub == "open" then
    viewer.open()
  elseif sub == "close" then
    viewer.close()
  elseif sub == "toggle" then
    viewer.toggle()
  else
    vim.notify("AutoCoreLog: unknown subcommand '" .. tostring(sub)
      .. "' — expected open|close|toggle",
      vim.log.levels.ERROR)
  end
end, {
  nargs = "?",
  complete = function() return { "open", "close", "toggle" } end,
  desc = "Open/close/toggle the auto-core log viewer (ADR 0021 §7)",
})

-- The auto-core module itself is required lazily on first use by a
-- consumer plugin. We do NOT call setup() here — consumers install
-- via lazy.nvim's `dependencies = { "yongjohnlee80/auto-core.nvim" }`
-- and call setup themselves at the appropriate event.

-- Register auto-core's OWN log events so `:AutoCoreLogEvent list`
-- discovers them (ADR 0021 §5). These cover the mailbox router +
-- command-execution observability surface added in v0.1.24 — every
-- inbox arrival, response arrival, wake dispatch, wake skip, command
-- execution, and command rejection emits an entry to the
-- `auto-core.log` ring tagged with one of the event ids below.
--
-- Events fire at INFO (normal dispatch), WARN (rejections / setup
-- bugs like an unregistered wake command), DEBUG (wake-skipped on a
-- mailbox with no wake config — informational only), or ERROR (a
-- handler raised inside the pcall barrier). Subscribe via
-- `:AutoCoreLogEvent notify <event>` to also see them as toasts.
do
  local ok, log_mod = pcall(require, "auto-core.log")
  if ok and log_mod and log_mod.events and log_mod.events.register then
    log_mod.events.register("auto-core", {
      "mailbox.router.inbox_arrival",
      "mailbox.router.response_arrival",
      "mailbox.router.wake_dispatched",
      "mailbox.router.wake_skipped",
      "mailbox.commands.command_executed",
      "mailbox.commands.command_rejected",
    })
  end
end

-- ─── auto-core.todo — user command + autocmd (ADR-0031 §3) ────
--
-- :AutoCoreTodoRefresh reconciles the resolved `.todo-list/`
-- directory: enforces dir == status, applies the 28-day auto-archive
-- rule, re-validates references, and updates errors[]. A summary is
-- printed via vim.notify so the user sees what changed.
--
-- The BufWritePost autocmd fires for any .yaml save inside the
-- currently-resolved todo dir (honoring set_todo_dir overrides). It
-- uses a callback-time filter rather than a fixed pattern so the
-- dir override can change at runtime without re-registering the
-- autocmd.
vim.api.nvim_create_user_command("AutoCoreTodoRefresh", function()
  local ok, todo = pcall(require, "auto-core.todo")
  if not ok then
    vim.notify("auto-core.todo unavailable: " .. tostring(todo), vim.log.levels.ERROR)
    return
  end
  local ok_run, summary = pcall(todo.refresh)
  if not ok_run then
    vim.notify("auto-core.todo.refresh failed: " .. tostring(summary), vim.log.levels.ERROR)
    return
  end
  vim.notify(string.format(
    "auto-core.todo: scanned=%d moved=%d archived=%d skipped=%d errors_set=%d rewritten=%d",
    summary.scanned, summary.moved, summary.archived, summary.skipped,
    summary.errors_set, summary.rewritten), vim.log.levels.INFO)
end, { desc = "Reconcile .todo-list/ files (status ↔ dir, 28-day auto-archive, refs)" })

do
  local group = vim.api.nvim_create_augroup("AutoCoreTodo", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group   = group,
    pattern = "*.yaml",
    callback = function(args)
      local ok_t, todo = pcall(require, "auto-core.todo")
      if not ok_t then return end
      local ok_p, fs_path = pcall(require, "auto-core.fs.path")
      if not ok_p then return end
      local td = todo.get_todo_dir()
      if type(td) ~= "string" or td == "" then return end
      local saved_file = args.file
      if type(saved_file) ~= "string" or saved_file == "" then return end
      -- Only fire when the saved file is under the currently-resolved
      -- todo dir. Buffers in unrelated yaml files (pubspec.yaml,
      -- action workflows, etc.) get a no-op short-circuit here.
      if fs_path.is_under(saved_file, td) then
        pcall(todo.refresh)
      end
    end,
  })
end
