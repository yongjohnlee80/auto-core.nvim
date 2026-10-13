---auto-core.todo.buffers — open buffers follow a task file the daemon moved or
---rewrote. This is Neovim UI, not a write: the daemon writes the store
---(ADR 1791532020); these keep a buffer from resurrecting the bucket a task left.
---@module 'auto-core.todo.buffers'

local LOG_COMPONENT = "auto-core.todo"

local M = {}

---Retarget every loaded buffer naming `from_path` onto `to_path`.
---
---A task file physically moves between bucket directories on every
---status change, and a buffer opened on it keeps naming the OLD path.
---The user's next `:w` then RECREATES the task in the bucket it just
---left — a duplicate carrying whatever stale frontmatter the buffer
---still held. Reported case: a task edited in `in-progress` while an
---agent completed it, saved back into `in-progress` as a new task.
---
---Unsaved user edits are never discarded: a modified buffer is only
---renamed, so the edits survive, and the user is warned that it happened.
---Their next `:w` is then refused with `E13: File exists (add ! to
---override)` rather than silently clobbering the frontmatter auto-core
---wrote — verified, and locked by a cell. (`:set writeany` defeats that
---refusal; a caller who has opted out of Neovim's overwrite protection
---keeps what they chose.) An unmodified buffer is reloaded, so the reader
---sees the frontmatter the daemon just rewrote.
---@param from_path string
---@param to_path string
function M.retarget(from_path, to_path)
  if from_path == to_path then return end
  local function apply()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b)
        and not vim.api.nvim_buf_is_loaded(b)
        and vim.api.nvim_buf_get_name(b) == from_path then
        -- ALREADY UNLOADED before the move (`:bdelete`, a restored session).
        -- Only the NAME survives, and that name is the resurrection vector:
        -- reopen it with `:buffer` and the next `:w` recreates the vacated
        -- bucket. Deleting it is safe because Neovim REFUSES to unload a
        -- modified buffer (`E89: No write since last change`), so unloaded
        -- implies unmodified — there is no unsaved work to lose. Same policy
        -- the stale sweep below applies to a name set_name leaves behind;
        -- this applies it to one that was already there.
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      elseif vim.api.nvim_buf_is_loaded(b)
        and vim.api.nvim_buf_get_name(b) == from_path then
        local modified = vim.api.nvim_get_option_value("modified", { buf = b })
        local ok_name = pcall(vim.api.nvim_buf_set_name, b, to_path)
        if ok_name then
          -- set_name leaves the old name behind as an unlisted buffer;
          -- drop it, or a later `:w` from it resurrects the old bucket.
          for _, stale in ipairs(vim.api.nvim_list_bufs()) do
            if stale ~= b
              and vim.api.nvim_buf_get_name(stale) == from_path
              and not vim.api.nvim_get_option_value("modified", { buf = stale })
            then
              pcall(vim.api.nvim_buf_delete, stale, { force = true })
            end
          end
          if not modified then
            -- Unmodified: adopt the file the daemon just wrote. `edit!` also
            -- clears the modified flag set_name raises on the rename.
            vim.api.nvim_buf_call(b, function()
              pcall(vim.cmd, "silent! keepalt edit!")
            end)
          else
            -- The user has unsaved edits and we just renamed the buffer under
            -- them. Say so: without this they meet a bare "E13: File exists"
            -- on their next :w with no idea the path moved, and THEY are the
            -- one who has to resolve the divergence.
            -- log.notify, not log.warn + a bare vim.notify: its doc says
            -- "Use this instead of bare vim.notify(...) so every visible toast
            -- also lands in the ring for :AutoCoreLog triage". The pair emits
            -- the same event twice in two shapes AND lets the toast bypass the
            -- level filter, so a user who set ERROR still gets it.
            local ok_log, log = pcall(require, "auto-core.log")
            if ok_log and log and type(log.notify) == "function" then
              pcall(log.notify, string.format(
                "task moved while you had unsaved edits; buffer %d now points at %s (was %s). "
                .. "Your edits are intact; :w will refuse with E13 until you resolve the divergence.",
                b, to_path, from_path),
                { level = "warn", component = LOG_COMPONENT })
            end
          end
        end
      end
    end
  end
  -- Buffer APIs are unavailable in a fast event (uv callbacks, fs watchers).
  if vim.in_fast_event() then vim.schedule(apply) else apply() end
end

---Reload unmodified open buffers naming `path` after an in-place rewrite.
---An unmodified buffer is reloaded so the reader sees the frontmatter
---the daemon just rewrote, preventing a subsequent `:w` from reverting the
---disk file with stale memory (MF2).
---
---A modified buffer is preserved intact without reload. Neovim's built-in
---file modification time (mtime) check guards against silent clobbering:
---a subsequent bare `:w` triggers a W12 conflict prompt ("The file has been
---changed since reading it!!!") rather than silently overwriting disk state.
---Like retarget_buffers, we notify via log.notify so the user is informed
---that the underlying file changed while they held unsaved edits.
---@param path string
function M.reload(path)
  local function apply()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b)
        and vim.api.nvim_buf_is_loaded(b)
        and vim.api.nvim_buf_get_name(b) == path
      then
        local modified = vim.api.nvim_get_option_value("modified", { buf = b })
        if not modified then
          vim.api.nvim_buf_call(b, function()
            pcall(vim.cmd, "silent! keepalt edit!")
          end)
        else
          local ok_log, log = pcall(require, "auto-core.log")
          if ok_log and log and type(log.notify) == "function" then
            pcall(log.notify, string.format(
              "task modified on disk while you had unsaved edits; buffer %d points at %s. "
              .. "Your edits are intact; :w will prompt (file changed on disk) until you resolve the divergence.",
              b, path),
              { level = "warn", component = LOG_COMPONENT })
          end
        end
      end
    end
  end
  if vim.in_fast_event() then vim.schedule(apply) else apply() end
end

return M
