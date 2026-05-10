---auto-core.git.fetch — async fetch operations.
---
---Per ADR 0007 Phase 3.5 (amendment 2026-05-10). Lifted from
---gitsgraph.nvim's git.lua so any consumer (worktree.graph today,
---future auto-finder git panel, etc.) can fetch one or many repos
---without re-implementing the bare-repo refspec gotcha.
---
---Public surface:
---
---  fetch_one(repo, opts?, on_done?)            -- one repo
---  fetch_all(repos, opts?, on_progress?, on_done?)  -- sequential fan-out
---
---repo shape: `{ common_dir = string, label? = string }`.
---
---opts (all optional):
---  timeout_ms : default 30000
---  all        : pass --all (default true)
---  prune      : pass --prune (default true)
---
---Topics published per `fetch_one`:
---  core.git.fetch:started   { repo, label }
---  core.git.fetch:completed { repo, label, ok, stderr }
---
---Auto-core itself does NOT call `vim.notify`. Consumers subscribe
---to the topics if they want user-visible feedback (worktree.graph
---does — see lua/worktree/graph.lua). Keeps the foundation quiet
---and gives consumers control over UX.
---
---Bare-repo refspec back-fill: `git clone --bare` ships with a
---mirror refspec `+refs/heads/*:refs/heads/*`. When that's unset
---without a replacement, `git fetch --all` reports success but
---writes no `refs/remotes/<name>/*`. We back-fill the conventional
---refspec for any remote missing one, never overwriting existing
---non-empty values.
---@module 'auto-core.git.fetch'

local events = require("auto-core.events")

local M = {}

local DEFAULT_TIMEOUT_MS = 30 * 1000

---Back-fill a missing fetch refspec on every remote of `common_dir`.
---Never overwrites an existing non-empty refspec.
---@param common_dir string
local function _ensure_refspecs(common_dir)
  local remotes = vim.system(
    { "git", "--git-dir=" .. common_dir, "remote" },
    { text = true }
  ):wait()
  if remotes.code ~= 0 then return end
  for name in (remotes.stdout or ""):gmatch("[^\r\n]+") do
    local existing = vim.system(
      { "git", "--git-dir=" .. common_dir, "config", "--get",
        "remote." .. name .. ".fetch" },
      { text = true }
    ):wait()
    if existing.code ~= 0 or vim.trim(existing.stdout or "") == "" then
      vim.system(
        { "git", "--git-dir=" .. common_dir, "config",
          "remote." .. name .. ".fetch",
          "+refs/heads/*:refs/remotes/" .. name .. "/*" },
        { text = true }
      ):wait()
    end
  end
end

---Fetch one repo asynchronously. Calls `on_done(ok, stderr)` on the
---main loop after completion.
---@param repo { common_dir: string, label: string? }
---@param opts { timeout_ms: integer?, all: boolean?, prune: boolean? }?
---@param on_done fun(ok: boolean, stderr: string?)?
function M.fetch_one(repo, opts, on_done)
  if not repo or type(repo.common_dir) ~= "string" or repo.common_dir == "" then
    if on_done then on_done(false, "fetch_one: repo.common_dir required") end
    return
  end
  opts = opts or {}
  local label = repo.label or repo.common_dir
  _ensure_refspecs(repo.common_dir)

  events.publish("core.git.fetch:started", {
    repo  = { common_dir = repo.common_dir, label = label },
    label = label,
  })

  local args = { "git", "--git-dir=" .. repo.common_dir, "fetch" }
  if opts.all   ~= false then args[#args + 1] = "--all" end
  if opts.prune ~= false then args[#args + 1] = "--prune" end

  vim.system(args,
    { text = true, timeout = opts.timeout_ms or DEFAULT_TIMEOUT_MS },
    vim.schedule_wrap(function(result)
      local ok = result.code == 0
      local stderr = vim.trim(result.stderr or "")
      events.publish("core.git.fetch:completed", {
        repo   = { common_dir = repo.common_dir, label = label },
        label  = label,
        ok     = ok,
        stderr = ok and nil or stderr,
      })
      if on_done then on_done(ok, ok and nil or stderr) end
    end)
  )
end

---Sequentially fetch every repo in `repos`. One at a time so we don't
---swamp a single remote with parallel connections.
---@param repos { common_dir: string, label: string? }[]
---@param opts { timeout_ms: integer?, all: boolean?, prune: boolean? }?
---@param on_progress fun(idx: integer, ok: boolean, repo: { common_dir: string, label: string })?
---@param on_done fun()?
function M.fetch_all(repos, opts, on_progress, on_done)
  if not repos or #repos == 0 then
    if on_done then on_done() end
    return
  end
  local i = 0
  local function next_one()
    i = i + 1
    if i > #repos then
      if on_done then on_done() end
      return
    end
    local r = repos[i]
    M.fetch_one(r, opts, function(ok)
      if on_progress then
        on_progress(i, ok, {
          common_dir = r.common_dir,
          label      = r.label or r.common_dir,
        })
      end
      next_one()
    end)
  end
  next_one()
end

return M
