---auto-core.fs.atomic — shared atomic-write primitive (ADR-0038 Batch E).
---
---Write-temp → best-effort fsync → rename. The rename is the commit
---step: readers either see the old file or the complete new one,
---never a partial write. Previously implemented three times with
---drifting details (mailbox/transport required the parent dir,
---todo/init mkdir-p'd it, mailbox/bootstrap didn't check at all);
---this is the single canonical copy — the callers delegate here and
---keep their semantics via `opts.mkdir`.
---@module 'auto-core.fs.atomic'

local fs_path = require("auto-core.fs.path")

local M = {}

---@class AutoCoreFsAtomicWriteOpts
---@field mkdir boolean?  create the parent dir (mkdir -p) when missing; default false → error

---Atomically write `text` to `final_path`.
---@param final_path string
---@param text string
---@param opts AutoCoreFsAtomicWriteOpts?
---@return boolean ok, string? err
function M.write(final_path, text, opts)
  opts = opts or {}
  local dir = fs_path.parent(final_path)
  if not fs_path.is_dir(dir) then
    if opts.mkdir then
      local mkok, mkerr = pcall(vim.fn.mkdir, dir, "p")
      if not mkok then return false, "mkdir: " .. tostring(mkerr) end
    else
      return false, "atomic_write: target dir missing: " .. tostring(dir)
    end
  end
  local tmp = dir .. "/.tmp-" .. tostring(vim.uv.hrtime())
    .. "-" .. tostring(math.random(1, 1e9))
  local fd, open_err = vim.uv.fs_open(tmp, "w", 420) -- 0644
  if not fd then return false, "fs_open: " .. tostring(open_err) end
  local _, write_err = vim.uv.fs_write(fd, text, 0)
  if write_err then
    pcall(vim.uv.fs_close, fd)
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_write: " .. tostring(write_err)
  end
  -- Best-effort fsync; some filesystems / sandboxes refuse it (e.g.
  -- tmpfs may return ENOSYS). Don't fail the write on that — the
  -- rename below is the durable commit.
  pcall(vim.uv.fs_fsync, fd)
  local _, close_err = vim.uv.fs_close(fd)
  if close_err then
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_close: " .. tostring(close_err)
  end
  local rok, rename_err = vim.uv.fs_rename(tmp, final_path)
  if not rok then
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_rename: " .. tostring(rename_err)
  end
  return true
end

return M
