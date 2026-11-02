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

-- ─── the todo store — user commands + autocmd (ADR 1791532020) ───
--
-- AutoDoc's daemon owns the todo store. auto-core keeps only where a project's
-- store is (auto-core.todo.where, which also claims it once per root) and the
-- door to the daemon (auto-core.todo.daemon); `auto-core.todo` itself, the
-- forwarding shim, went at v0.4.1. These call the daemon through that door.
--
-- :AutoCoreTodoRefresh asks the daemon to reconcile the store's active buckets
-- (dir == status, the 28-day archive, refs and errors[]) and prints the summary.
--
-- The BufWritePost autocmd asks for the same refresh, without waiting, when a
-- saved .md file is under the project's store: a hand edit is picked up at once,
-- and `:w` never waits on the daemon.
--
-- :AutoCoreTodoClaim claims the project's store again after a rollback released
-- it (auto-core never re-claims a store it saw released).

---refresh_body runs todos.refresh for the project's store, inside daemon.run.
---A project with no store yet has nothing to reconcile: a zero summary.
local function todo_refresh_body(daemon, where)
  local c = where.ensure(where.root())
  local s, err = daemon.rpc("todos.refresh", { c.at })
  if err and err.code == daemon.NOT_A_STORE then s, err = {}, nil end
  if err then daemon.fail(err) end
  return s or {}
end

local function todo_mods()
  local ok_d, daemon = pcall(require, "auto-core.todo.daemon")
  local ok_w, where = pcall(require, "auto-core.todo.where")
  if not (ok_d and ok_w) then return nil end
  return daemon, where
end

local function todo_publish(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok then pcall(events.publish, topic, payload) end
end

vim.api.nvim_create_user_command("AutoCoreTodoRefresh", function()
  local daemon, where = todo_mods()
  if not daemon then
    vim.notify("auto-core: the todo store resolution is unavailable", vim.log.levels.ERROR)
    return
  end
  local ok_run, s = daemon.sync(function() return todo_refresh_body(daemon, where) end)
  if not ok_run then
    vim.notify("auto-core: todos.refresh failed: " .. tostring(s), vim.log.levels.ERROR)
    return
  end
  todo_publish("core.todo:refreshed", { summary = s })
  vim.notify(string.format(
    "todos: scanned=%d moved=%d archived=%d malformed=%d errors_set=%d rewritten=%d",
    tonumber(s.scanned) or 0, tonumber(s.moved) or 0, tonumber(s.archived) or 0,
    tonumber(s.malformed) or 0, tonumber(s.errors_set) or 0, tonumber(s.rewritten) or 0),
    vim.log.levels.INFO)
end, { desc = "Ask AutoDoc to reconcile .todo-list/ (status ↔ dir, 28-day auto-archive, refs)" })

vim.api.nvim_create_user_command("AutoCoreTodoClaim", function()
  local daemon, where = todo_mods()
  if not daemon then
    vim.notify("auto-core: the todo store resolution is unavailable", vim.log.levels.ERROR)
    return
  end
  local ok_claim, err = daemon.sync(function() return where.claim(where.root()) end)
  if ok_claim then
    vim.notify("auto-core: the todo store is claimed: AutoDoc writes it", vim.log.levels.INFO)
  else
    vim.notify("auto-core: claim failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end, { desc = "Claim the project's todo store for AutoDoc again (after a rollback released it)" })

do
  local group = vim.api.nvim_create_augroup("AutoCoreTodo", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group   = group,
    pattern = "*.md",
    callback = function(args)
      local daemon, where = todo_mods()
      if not daemon or not daemon.available() then return end
      local ok_p, fs_path = pcall(require, "auto-core.fs.path")
      if not ok_p then return end
      local root = where.root()
      local c = where.cached(root)
      local td = c and c.store or where.local_dir(root)
      if type(td) ~= "string" or td == "" then return end
      local saved_file = args.file
      if type(saved_file) ~= "string" or saved_file == "" then return end
      -- Only a file under the project's store. Other Markdown is a no-op.
      if not fs_path.is_under(vim.fn.fnamemodify(saved_file, ":p"), td) then return end
      -- Asynchronous: `:w` never waits on the daemon.
      daemon.run(function() return todo_refresh_body(daemon, where) end, function(ok_run, s)
        if ok_run then
          todo_publish("core.todo:refreshed", { summary = s })
        elseif tostring(s):find("todos.unclaimed", 1, true) then
          where.reset(root) -- the store was released: resolve again next time
        end
      end)
    end,
  })
end
