---Cached Git executable version probing.
---@module 'auto-core.git.version'

local M = {}

local attempted = false
local cached = nil
local cached_error = nil

local function copy_version(version)
  if not version then return nil end
  return {
    major = version.major,
    minor = version.minor,
    patch = version.patch,
  }
end

local function parse_version(stdout)
  local line = tostring(stdout or ""):match("^([^\r\n]*)") or ""
  local major, minor, patch, suffix = line:match(
    "^git version (%d+)%.(%d+)%.(%d+)(.*)$")
  if not major then
    major, minor, suffix = line:match("^git version (%d+)%.(%d+)(.*)$")
  end
  if not major or (suffix ~= "" and not suffix:match("^[%s%.%-%+%(]")) then
    return nil
  end
  return {
    major = tonumber(major),
    minor = tonumber(minor),
    patch = patch and tonumber(patch) or nil,
  }
end

---Return the Git executable version. Success and failure are session-cached.
---@return { major: integer, minor: integer, patch: integer? }? version
---@return string? error
function M.version()
  if attempted then return copy_version(cached), cached_error end
  attempted = true

  local ok, process = pcall(vim.system, { "git", "--version" }, { text = true })
  if not ok or not process then
    cached_error = "git --version failed: " .. tostring(process)
    return nil, cached_error
  end
  local waited, result = pcall(function() return process:wait() end)
  if not waited or not result or result.code ~= 0 then
    local detail = ""
    if waited and result then
      detail = vim.trim(tostring(result.stderr or "") .. " " .. tostring(result.stdout or ""))
    end
    cached_error = "git --version failed: " .. (detail ~= "" and detail or "unknown error")
    return nil, cached_error
  end

  cached = parse_version(result.stdout)
  if not cached then
    cached_error = "malformed git --version output"
    return nil, cached_error
  end
  return copy_version(cached), nil
end

---Whether Git's version is at least the requested version, lexicographically.
---@param major integer
---@param minor integer
---@param patch integer?
---@return boolean
function M.version_at_least(major, minor, patch)
  local version = M.version()
  if not version then return false end
  local have = { version.major, version.minor, version.patch or 0 }
  local want = { major, minor, patch or 0 }
  for i = 1, 3 do
    if have[i] ~= want[i] then return have[i] > want[i] end
  end
  return true
end

return M
