---auto-core.git.pull — pull state probe + apply.
---
---Per ADR 0007 Phase 3.5 (amendment 2026-05-10). Lifted from
---gitsgraph.nvim's git.lua so any consumer can introspect a
---worktree's pull state and apply a fast-forward / hard-reset
---without re-implementing the rev-parse + merge-base + status
---probes.
---
---Public surface:
---
---  pull_status(wt)              → { state, branch, remote_ref, dirty,
---                                   dirty_count, ahead_count?,
---                                   local_sha, remote_sha }
---  pull_apply(wt, mode, opts?, on_done)
---  worktree_dirty(wt)           → { dirty, dirty_count }
---
---wt shape: `{ path: string, branch: string?, sha: string? }`.
---
---pull_status `state` ∈
---  "detached"   — wt.branch is nil (HEAD is detached)
---  "no_remote"  — origin/<branch> doesn't exist
---  "uptodate"   — local == remote
---  "ff"         — fast-forwardable (local is ancestor of remote)
---  "ahead"      — local is ahead of remote (no fetch needed)
---  "diverged"   — split history; ahead_count counts commits HEAD has
---                 that remote_ref doesn't (would be discarded by
---                 `reset --hard`)
---
---Topics published per `pull_apply`:
---  core.git.pull:started   { wt, mode }
---  core.git.pull:completed { wt, mode, ok, stderr }
---@module 'auto-core.git.pull'

local events = require("auto-core.events")

local M = {}

local function _git_at(wt_path, args)
  local cmd = { "git", "-C", wt_path }
  for _, a in ipairs(args) do cmd[#cmd + 1] = a end
  return vim.system(cmd, { text = true }):wait()
end

---Probe the pull state of `wt`. Sync — local rev-parse / merge-base
---/ status reads only.
---@param wt { path: string, branch: string?, sha: string? }
---@return table
function M.pull_status(wt)
  if not wt or type(wt.path) ~= "string" or wt.path == "" then
    return { state = "detached" }
  end
  if not wt.branch then return { state = "detached" } end

  local remote_ref = "origin/" .. wt.branch
  local rcheck = _git_at(wt.path, { "rev-parse", "--verify", "--quiet", remote_ref })
  if rcheck.code ~= 0 then
    return {
      state      = "no_remote",
      branch     = wt.branch,
      remote_ref = remote_ref,
    }
  end
  local remote_sha = vim.trim(rcheck.stdout or "")
  local local_sha  = vim.trim(_git_at(wt.path, { "rev-parse", "HEAD" }).stdout or "")

  -- `--untracked-files=no` so untracked content (e.g. wt-local
  -- symlinks, build artifacts) doesn't trip the prompt. `git reset
  -- --hard` and `git merge --ff-only` only touch tracked files.
  local porcelain = vim.trim(
    _git_at(wt.path, { "status", "--porcelain", "--untracked-files=no" }).stdout or ""
  )
  local dirty_count = 0
  if porcelain ~= "" then
    for _ in porcelain:gmatch("[^\r\n]+") do dirty_count = dirty_count + 1 end
  end
  local dirty = dirty_count > 0

  local state, ahead_count
  if local_sha == remote_sha then
    state = "uptodate"
  else
    local local_anc  = _git_at(wt.path, { "merge-base", "--is-ancestor", "HEAD", remote_ref })
    local remote_anc = _git_at(wt.path, { "merge-base", "--is-ancestor", remote_ref, "HEAD" })
    if local_anc.code == 0 then
      state = "ff"
    elseif remote_anc.code == 0 then
      state = "ahead"
    else
      state = "diverged"
      local rev = _git_at(wt.path, { "rev-list", "--count", remote_ref .. "..HEAD" })
      ahead_count = tonumber(vim.trim(rev.stdout or "")) or 0
    end
  end

  return {
    state        = state,
    branch       = wt.branch,
    remote_ref   = remote_ref,
    dirty        = dirty,
    dirty_count  = dirty_count,
    ahead_count  = ahead_count,
    local_sha    = local_sha,
    remote_sha   = remote_sha,
  }
end

---Apply a pull to `wt` asynchronously.
---@param wt { path: string, branch: string }
---@param mode "ff"|"reset"
---@param opts { timeout_ms: integer? }?
---@param on_done fun(ok: boolean, stderr: string?)?
function M.pull_apply(wt, mode, opts, on_done)
  opts = opts or {}
  if not wt or type(wt.path) ~= "string" or wt.path == ""
      or type(wt.branch) ~= "string" then
    if on_done then on_done(false, "pull_apply: wt.path + wt.branch required") end
    return
  end
  local remote_ref = "origin/" .. wt.branch
  local cmd
  if mode == "ff" then
    cmd = { "git", "-C", wt.path, "merge", "--ff-only", remote_ref }
  elseif mode == "reset" then
    cmd = { "git", "-C", wt.path, "reset", "--hard", remote_ref }
  else
    if on_done then on_done(false, "pull_apply: unknown mode '" .. tostring(mode) .. "'") end
    return
  end

  events.publish("core.git.pull:started", { wt = wt, mode = mode })

  local sys_opts = { text = true }
  if opts.timeout_ms then sys_opts.timeout = opts.timeout_ms end
  vim.system(cmd, sys_opts, vim.schedule_wrap(function(result)
    local ok = result.code == 0
    local stderr = vim.trim(result.stderr or "")
    events.publish("core.git.pull:completed", {
      wt     = wt,
      mode   = mode,
      ok     = ok,
      stderr = ok and nil or stderr,
    })
    if on_done then on_done(ok, ok and nil or stderr) end
  end))
end

---Quick dirty-check including untracked files. Mirrors what
---`git worktree remove` itself refuses on, so consumers can prompt
---before destroying.
---@param wt { path: string }
---@return { dirty: boolean, dirty_count: integer }
function M.worktree_dirty(wt)
  if not wt or type(wt.path) ~= "string" or wt.path == "" then
    return { dirty = false, dirty_count = 0 }
  end
  local res = vim.system(
    { "git", "-C", wt.path, "status", "--porcelain" },
    { text = true }
  ):wait()
  if res.code ~= 0 then return { dirty = false, dirty_count = 0 } end
  local count = 0
  for _ in (res.stdout or ""):gmatch("[^\r\n]+") do count = count + 1 end
  return { dirty = count > 0, dirty_count = count }
end

return M
