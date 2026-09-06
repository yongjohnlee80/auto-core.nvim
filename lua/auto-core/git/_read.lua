---Private argv and raw-output utilities for ADR-0069 repository reads.
---@module 'auto-core.git._read'

local version = require("auto-core.git.version")

local M = {}

M.UNSUPPORTED_ERROR = "Git 2.15+ required"

---Build the exact hardened repository-read argv prefix.
---@param path string
---@param args string[]
---@return string[]? argv
---@return string? error
function M.argv(path, args)
  if not version.version_at_least(2, 15) then
    return nil, M.UNSUPPORTED_ERROR
  end
  local argv = {
    "git",
    "--no-pager",
    "--no-optional-locks",
    "-c", "gc.auto=0",
    "-c", "core.quotepath=off",
    "-c", "color.ui=false",
    "-c", "color.diff=false",
    "--literal-pathspecs",
    "-C", path,
  }
  vim.list_extend(argv, args)
  return argv, nil
end

local function native_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

---Remove only Git's process-record terminator, preserving legal path bytes.
---@param stdout string?
---@param windows boolean?
---@return string
function M.strip_terminator(stdout, windows)
  local value = tostring(stdout or "")
  if windows == nil then windows = native_windows() end
  if windows and value:sub(-2) == "\r\n" then
    return value:sub(1, -3)
  end
  if value:sub(-1) == "\n" then
    return value:sub(1, -2)
  end
  return value
end

return M
