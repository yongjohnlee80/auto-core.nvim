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

-- The auto-core module itself is required lazily on first use by a
-- consumer plugin. We do NOT call setup() here — consumers install
-- via lazy.nvim's `dependencies = { "yongjohnlee80/auto-core.nvim" }`
-- and call setup themselves at the appropriate event.
