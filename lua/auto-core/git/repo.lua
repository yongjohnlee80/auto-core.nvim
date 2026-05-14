---Git repository introspection helpers — minimal, synchronous,
---shell-out where necessary.
---
---Phase 4a foundation. Companion modules in subsequent slices:
---  - `auto-core.git.status`   — cached `git status --porcelain`
---  - `auto-core.git.worktree` — canonical worktree implementation
---                               (replaces worktree.nvim's internals
---                                via the legacy-fallback rollout
---                                per ADR 0006 §"worktree.nvim
---                                migration plan")
---
---API:
---
---  M.is_git(path)         path resides in a git repo (.git dir|file or bare)
---  M.root(path?)          repo toplevel (what `git rev-parse --show-toplevel` returns)
---  M.git_dir(path?)       `.git` path (may be a file pointing elsewhere for linked worktrees)
---  M.common_dir(path?)    `git rev-parse --git-common-dir` — shared metadata across worktrees
---  M.is_bare(path?)       true if the repo is bare-mode
---
---All `path` args default to `vim.fn.getcwd()`. Functions return
---`nil` when the input isn't in a git repo (no errors thrown for
---ergonomic chaining; callers branch on nil).
---@module 'auto-core.git.repo'

local fs_path = require("auto-core.fs.path")

local M = {}

---Run `git -C <cwd> <args...>` synchronously. Returns the trimmed
---first line of stdout, or nil on any non-zero exit.
---@param cwd string
---@param args string[]
---@return string?
local function git_lines_first(cwd, args)
  local cmd = { "git", "-C", cwd }
  for _, a in ipairs(args) do cmd[#cmd + 1] = a end
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then return nil end
  if not out or not out[1] or out[1] == "" then return nil end
  return out[1]
end

---Whether `path` is in a git repo. Uses the local check first
---(cheap, no fork) and falls back to `git rev-parse` for edge
---cases like submodules and detached worktrees outside the
---obvious `.git` discovery.
---@param path string?
---@return boolean
function M.is_git(path)
  local p = fs_path.normalize(path or vim.fn.getcwd())
  if p == "" then return false end
  -- Fast local probe — covers regular repos, bare repos, AND linked
  -- worktrees (`.git` is a file pointing at the bare's worktree dir).
  if fs_path.is_dir(p .. "/.git") or fs_path.is_file(p .. "/.git") then
    return true
  end
  -- Walk up — any ancestor with `.git` makes us in-repo.
  if fs_path.git_root({ start = p }) then return true end
  -- Final shell probe for edge cases (submodules, GIT_DIR-overridden
  -- env, bare layouts where the cwd IS the bare dir).
  local out = git_lines_first(p, { "rev-parse", "--is-inside-work-tree" })
  if out == "true" then return true end
  -- Bare repos report `--is-bare-repository = true` even if not in a worktree.
  out = git_lines_first(p, { "rev-parse", "--is-bare-repository" })
  return out == "true"
end

---Repo toplevel (the work-tree root). Equivalent to
---`git rev-parse --show-toplevel`. Returns nil when not in a repo
---OR when in a bare repo (bare repos have no work tree).
---@param path string?
---@return string?
function M.root(path)
  local p = fs_path.normalize(path or vim.fn.getcwd())
  if p == "" then return nil end
  -- Pure-lua walk first — avoids the shell on the common case.
  local gr = fs_path.git_root({ start = p })
  if gr then return gr end
  -- Shell fallback for linked worktrees / GIT_DIR-overridden env.
  local out = git_lines_first(p, { "rev-parse", "--show-toplevel" })
  return out and fs_path.normalize(out) or nil
end

---Path of the `.git` location for the given path. May be a
---directory (regular / bare repo) OR a regular file (linked
---worktree — the file contains `gitdir: <path>`).
---@param path string?
---@return string?
function M.git_dir(path)
  local p = fs_path.normalize(path or vim.fn.getcwd())
  if p == "" then return nil end
  local out = git_lines_first(p, {
    "rev-parse", "--path-format=absolute", "--git-dir",
  })
  return out and fs_path.normalize(out) or nil
end

---Common dir — where shared metadata lives (refs, objects, hooks).
---For a regular repo, equals `git_dir`. For a linked worktree,
---points back to the bare repo's gitdir. Used as the "stable repo
---identity" anchor across all linked worktrees of one repo.
---@param path string?
---@return string?
function M.common_dir(path)
  local p = fs_path.normalize(path or vim.fn.getcwd())
  if p == "" then return nil end
  local out = git_lines_first(p, {
    "rev-parse", "--path-format=absolute", "--git-common-dir",
  })
  return out and fs_path.normalize(out) or nil
end

---Whether the repo at `path` is bare (no work tree).
---@param path string?
---@return boolean
function M.is_bare(path)
  local p = fs_path.normalize(path or vim.fn.getcwd())
  if p == "" then return false end
  local out = git_lines_first(p, { "rev-parse", "--is-bare-repository" })
  return out == "true"
end

---Probe the status of a potential checkout. Sync.
---@param path string
---@param branch string
---@return { ok: boolean, reason: string?, dirty: boolean?, worktree: string? }
function M.checkout_status(path, branch)
  local p = fs_path.normalize(path)
  if not M.is_git(p) then
    return { ok = false, reason = "not a git repository" }
  end

  -- Check for existing worktree for this branch.
  local wt_mod = require("auto-core.git.worktree")
  local existing_wt = wt_mod.worktree_for_branch(p, branch)
  if existing_wt then
    return { ok = false, reason = "branch already checked out in " .. existing_wt, worktree = existing_wt }
  end

  -- Check for dirty working tree.
  local pull_mod = require("auto-core.git.pull")
  local status = pull_mod.worktree_dirty({ path = p })
  if status.dirty then
    return { ok = false, reason = "working tree is dirty (" .. status.dirty_count .. " files)", dirty = true }
  end

  return { ok = true }
end

---Checkout a branch in the repo at `path`. Async.
---@param path string
---@param branch string
---@param on_done fun(res: { ok: boolean, stderr: string? })?
function M.checkout(path, branch, on_done)
  local events = require("auto-core.events")
  events.publish("core.git.repo.checkout:started", { path = path, branch = branch })
  local args = { "git", "-C", path, "checkout", branch }
  vim.system(args, { text = true }, vim.schedule_wrap(function(res)
    local ok = res.code == 0
    local stderr = ok and nil or vim.trim(res.stderr or "")
    events.publish("core.git.repo.checkout:completed", {
      path = path, branch = branch, ok = ok, stderr = stderr
    })
    if on_done then on_done({ ok = ok, stderr = stderr }) end
  end))
end

---Delete a remote branch. Async.
---@param path string
---@param remote string
---@param branch string
---@param on_done fun(res: { ok: boolean, stderr: string? })?
function M.delete_remote(path, remote, branch, on_done)
  local events = require("auto-core.events")
  local args = { "git", "-C", path, "push", remote, "--delete", branch }
  vim.system(args, { text = true }, vim.schedule_wrap(function(res)
    local ok = res.code == 0
    local stderr = ok and nil or vim.trim(res.stderr or "")
    events.publish("core.git.repo.remote:deleted", {
      path = path, remote = remote, branch = branch, ok = ok, stderr = stderr
    })
    if on_done then on_done({ ok = ok, stderr = stderr }) end
  end))
end

---Create and checkout a new branch from a base ref. Async.
---@param path string
---@param name string
---@param base string
---@param on_done fun(res: { ok: boolean, stderr: string? })?
function M.create_branch(path, name, base, on_done)
  local events = require("auto-core.events")
  local args = { "git", "-C", path, "checkout", "-b", name, base }
  vim.system(args, { text = true }, vim.schedule_wrap(function(res)
    local ok = res.code == 0
    local stderr = ok and nil or vim.trim(res.stderr or "")
    events.publish("core.git.repo.branch:created", {
      path = path, name = name, base = base, ok = ok, stderr = stderr
    })
    if on_done then on_done({ ok = ok, stderr = stderr }) end
  end))
end

return M
