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

return M
