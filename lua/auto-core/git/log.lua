---auto-core.git.log — structured commit history and working-tree changes.
---
---ADR-0060 P1. Everything else in `auto-core.git` answers a question about
---*state* (status, worktrees, fetch/pull). Nothing returned COMMITS: the
---worktree graph delegates rendering to the external `gitgraph.nvim`, and
---`graph.show_diff` hands back raw `git show` text. A repos panel that lists
---"the work in flight" needs commit OBJECTS, the range policy that bounds
---them, and the uncommitted change set — so they live here, once, rather than
---being re-derived per consumer
---([[shared-resolver-single-source-of-truth]]).
---
---**Nothing here is cached, deliberately.** `graph.show_diff` may cache
---because a commit's diff is immutable once its hash exists. A commit LIST is
---not: it changes the moment a branch moves, a commit lands, or a rebase
---rewrites history. A cache here would serve a stale "work in flight" list,
---which is precisely the thing the panel exists to show truthfully. Callers
---that want caching own the invalidation.
---
---Reads only — no command in this module mutates a repository.
---@module 'auto-core.git.log'

local M = {}

-- Field/record separators. `--format` interpolates commit metadata that can
-- contain anything a human typed, including tabs, pipes and newlines, so the
-- delimiters are ASCII US/RS — bytes git will not emit from `%s`/`%an`.
local US, RS = "\31", "\30"
local FMT = "%H\31%h\31%P\31%an\31%ae\31%at\31%s\30"

---@class AutoCoreCommit
---@field sha string        full 40-char hash
---@field short string      abbreviated hash as git chose it
---@field parents string[]  parent hashes; 0 for a root commit, 2+ for a merge
---@field author string     author name
---@field email string      author email
---@field ts integer        author timestamp, unix seconds
---@field subject string    first line of the message
---@field merge boolean     #parents > 1

---@class AutoCoreWorkingChange
---@field path string           repo-relative path (the NEW path for a rename)
---@field orig string?          the OLD path, renames/copies only
---@field x string              index status letter (porcelain v1 column 1)
---@field y string              worktree status letter (column 2)
---@field kind string           added | modified | deleted | renamed | untracked | conflicted
---@field staged boolean        the index differs from HEAD
---@field unstaged boolean      the worktree differs from the index

---_run executes argv synchronously and returns (code, stdout, stderr).
---
---`vim.system`, NOT `vim.fn.system`: Vimscript strings cannot hold a NUL, so
---`vim.fn.system` REPLACES every NUL in the output with SOH (0x01). Every read
---here that uses `-z` (status, diff-tree) would then arrive as one
---un-splittable blob — silently losing every rename and every path containing
---a space or quote. libuv hands back the literal bytes.
---@param argv string[]
---@return integer code, string stdout, string stderr
local function _run(argv)
  local res = vim.system(argv, {}):wait()
  return res.code or -1, res.stdout or "", res.stderr or ""
end

---_git builds an argv against a repository's common dir. `--git-dir` is
---enough for history queries: they never need a working tree, so this works
---identically for a bare repo and for a checkout.
local function _git(common_dir, args)
  local argv = { "git", "--git-dir=" .. common_dir, "--no-pager" }
  vim.list_extend(argv, args)
  return argv
end

---_parse_commits turns the RS/US stream into records. Tolerant by design: a
---truncated trailing record (killed subprocess, output cap) is dropped rather
---than yielding a commit with nil fields that a renderer would crash on.
---@param blob string
---@return AutoCoreCommit[]
local function _parse_commits(blob)
  local out = {}
  for record in tostring(blob or ""):gmatch("([^" .. RS .. "]+)") do
    -- git emits a newline AFTER each --format record, so every record but the
    -- first arrives with that separator glued to the front of its hash field.
    -- Left unstripped it fails the hash check below and the commit is silently
    -- DROPPED -- a two-commit history parsed as one.
    record = record:gsub("^[\r\n]+", "")
    local f = vim.split(record, US, { plain = true })
    -- 7 fields exactly; anything shorter is a partial record.
    if #f >= 7 and f[1]:match("^%x%x%x%x%x%x%x+$") then
      local parents = {}
      for p in tostring(f[3]):gmatch("%S+") do parents[#parents + 1] = p end
      out[#out + 1] = {
        sha     = vim.trim(f[1]),
        short   = vim.trim(f[2]),
        parents = parents,
        author  = f[4],
        email   = f[5],
        ts      = tonumber(f[6]) or 0,
        -- The subject is last so an embedded US would only ever eat its own
        -- tail; re-join defensively rather than losing text.
        subject = table.concat(vim.list_slice(f, 7, #f), US),
        merge   = #parents > 1,
      }
      out[#out].subject = vim.trim(out[#out].subject:gsub("^%s*\n", ""))
    end
  end
  return out
end

---_log_args builds the `git log` argv for a resolved revision spec.
local function _log_args(opts)
  local args = { "log", "--format=" .. FMT, "--no-color" }
  if opts.limit and opts.limit > 0 then
    args[#args + 1] = "-n"
    args[#args + 1] = tostring(opts.limit)
  end
  if opts.skip and opts.skip > 0 then
    args[#args + 1] = "--skip=" .. tostring(opts.skip)
  end
  if opts.first_parent then args[#args + 1] = "--first-parent" end
  args[#args + 1] = opts.rev and opts.rev ~= "" and opts.rev or "HEAD"
  -- `--` guards a rev that collides with a path name.
  args[#args + 1] = "--"
  return args
end

---commits lists commits for a revision or range.
---@param common_dir string
---@param opts { rev: string?, limit: integer?, skip: integer?, first_parent: boolean? }?
---@return AutoCoreCommit[] commits, string? err
function M.commits(common_dir, opts)
  if not common_dir or common_dir == "" then return {}, "no common_dir" end
  opts = opts or {}
  local code, out, errtxt = _run(_git(common_dir, _log_args(opts)))
  if code ~= 0 then
    return {}, "git log failed: " .. vim.trim(errtxt ~= "" and errtxt or out)
  end
  return _parse_commits(out), nil
end

---commits_async is `commits` off the UI thread; `cb(commits, err)` runs on the
---main loop. History reads can take hundreds of ms on a large repo, and the
---panel must not block on cursor movement.
---@param common_dir string
---@param opts table?
---@param cb fun(commits: AutoCoreCommit[], err: string?)
function M.commits_async(common_dir, opts, cb)
  if type(cb) ~= "function" then return end
  if not common_dir or common_dir == "" then
    vim.schedule(function() cb({}, "no common_dir") end)
    return
  end
  vim.system(_git(common_dir, _log_args(opts or {})), { text = true },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 then
        cb({}, "git log failed: " .. vim.trim(tostring(res.stderr or "")))
        return
      end
      cb(_parse_commits(res.stdout or ""), nil)
    end))
end

---merge_base returns the common ancestor of two revisions, or nil when they
---share none (unrelated histories) — nil is DATA here, not an error.
---@param common_dir string
---@param a string
---@param b string
---@return string? sha, string? err
function M.merge_base(common_dir, a, b)
  if not (common_dir and a and b) or a == "" or b == "" then
    return nil, "merge_base: needs common_dir, a, b"
  end
  local code, out = _run(_git(common_dir, { "merge-base", a, b }))
  if code ~= 0 then return nil, nil end
  local sha = vim.trim(out)
  return sha ~= "" and sha or nil, nil
end

---rev_exists reports whether a revision resolves — used to tell "this branch
---has no upstream base" from "this branch is broken".
---@param common_dir string
---@param rev string
---@return boolean
function M.rev_exists(common_dir, rev)
  if not (common_dir and rev) or rev == "" then return false end
  local code = _run(_git(common_dir, { "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }))
  return code == 0
end

---range applies ADR-0060 §2.4's commit-range policy.
---
---A branch that diverged from a base shows its OWN work — everything since the
---merge-base — because that is the reviewable unit. The base branch itself has
---no divergence to bound it, so it gets a fixed window (default 15, Johno
---2026-08-22) that `skip` pages through.
---
---Returns the commits plus the resolution, so a caller can render "since
---<base>" versus "last N" honestly instead of guessing which it got.
---@param common_dir string
---@param opts { rev: string, base: string?, limit: integer?, skip: integer? }
---@return AutoCoreCommit[] commits, { mode: string, base: string?, merge_base: string?, limit: integer?, skip: integer? } meta, string? err
function M.range(common_dir, opts)
  opts = opts or {}
  local rev = opts.rev
  if not common_dir or common_dir == "" or not rev or rev == "" then
    return {}, { mode = "none" }, "range: needs common_dir and rev"
  end
  local limit = opts.limit or M.DEFAULT_WINDOW
  local skip = opts.skip or 0

  -- Divergence path: a base that exists, differs from rev, and shares history.
  if opts.base and opts.base ~= "" and opts.base ~= rev
    and M.rev_exists(common_dir, opts.base) then
    local mb = M.merge_base(common_dir, rev, opts.base)
    if mb then
      -- `base..rev` is exactly "on rev, not on base" — the divergence.
      local commits, err = M.commits(common_dir, {
        rev = opts.base .. ".." .. rev, skip = skip,
      })
      if not err then
        return commits, {
          mode = "since_divergence", base = opts.base,
          merge_base = mb, skip = skip,
        }, nil
      end
      return {}, { mode = "since_divergence", base = opts.base, merge_base = mb }, err
    end
  end

  -- Window path: the base branch itself, an unrelated history, or no base.
  local commits, err = M.commits(common_dir, { rev = rev, limit = limit, skip = skip })
  return commits, { mode = "window", limit = limit, skip = skip }, err
end

---DEFAULT_WINDOW is the base-branch commit window (ADR-0060 §6.1).
M.DEFAULT_WINDOW = 15

-- ── working tree ─────────────────────────────────────────────

---_kind classifies a porcelain XY pair into the label the repos panel renders.
---Order matters: conflict before anything else, then untracked, then the
---strongest of the two columns.
local function _kind(x, y)
  if x == "U" or y == "U" or (x == "A" and y == "A") or (x == "D" and y == "D") then
    return "conflicted"
  end
  if x == "?" and y == "?" then return "untracked" end
  if x == "R" or y == "R" then return "renamed" end
  if x == "C" or y == "C" then return "renamed" end -- a copy renders as a rename
  if x == "A" or y == "A" then return "added" end
  if x == "D" or y == "D" then return "deleted" end
  return "modified"
end

---_parse_status parses `git status --porcelain=v1 -z`.
---
---NUL-delimited because a path may contain a newline or a quote; `-z` also
---turns OFF git's own path quoting, so the bytes are literal. A rename or
---copy emits TWO records — `XY <new>\0<old>\0` — so the parser must consume
---the extra field or every subsequent entry shifts by one.
---@param blob string
---@return AutoCoreWorkingChange[]
local function _parse_status(blob)
  local fields = vim.split(tostring(blob or ""), "\0", { plain = true })
  local out, i = {}, 1
  while i <= #fields do
    local entry = fields[i]
    i = i + 1
    if entry and #entry > 3 then
      local x, y = entry:sub(1, 1), entry:sub(2, 2)
      local path = entry:sub(4)
      local orig = nil
      if x == "R" or x == "C" or y == "R" or y == "C" then
        orig = fields[i]      -- the old path is its own NUL-terminated field
        i = i + 1
      end
      out[#out + 1] = {
        path = path, orig = orig, x = x, y = y,
        kind = _kind(x, y),
        staged = x ~= " " and x ~= "?",
        unstaged = y ~= " " and y ~= "?",
      }
    end
  end
  table.sort(out, function(a, b) return a.path < b.path end)
  return out
end

---_status_args: `--porcelain=v1 -z` plus the same hardening flags the family
---already applies to git reads — never touch the index (`--no-optional-locks`),
---never let a user's `gc.auto`/color config change the output.
local function _status_args()
  return {
    "--no-optional-locks", "-c", "core.quotepath=off", "-c", "color.status=false",
    "status", "--porcelain=v1", "-z", "--untracked-files=normal",
  }
end

---working_changes lists a worktree's uncommitted changes — the UNCOMMITTED
---node's children (ADR-0060 §2.2/§2.4).
---
---Takes a WORKTREE path, not a common dir: status is meaningless without a
---working tree, so this is `git -C <worktree>`, unlike the history reads above.
---@param worktree string
---@return AutoCoreWorkingChange[] changes, string? err
function M.working_changes(worktree)
  if not worktree or worktree == "" then return {}, "no worktree" end
  local argv = { "git", "-C", worktree }
  vim.list_extend(argv, _status_args())
  local code, out, errtxt = _run(argv)
  if code ~= 0 then
    return {}, "git status failed: " .. vim.trim(errtxt ~= "" and errtxt or out)
  end
  return _parse_status(out), nil
end

---working_changes_async delivers `cb(changes, err)` on the main loop.
---@param worktree string
---@param cb fun(changes: AutoCoreWorkingChange[], err: string?)
function M.working_changes_async(worktree, cb)
  if type(cb) ~= "function" then return end
  if not worktree or worktree == "" then
    vim.schedule(function() cb({}, "no worktree") end)
    return
  end
  local argv = { "git", "-C", worktree }
  vim.list_extend(argv, _status_args())
  -- No `text = true`: it normalises line endings, and `-z` output must stay
  -- byte-exact (a path may legitimately contain a CR).
  vim.system(argv, {}, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      cb({}, "git status failed: " .. vim.trim(tostring(res.stderr or "")))
      return
    end
    cb(_parse_status(res.stdout or ""), nil)
  end))
end

---commit_files lists the paths a commit touched, with the same `kind` labels
---as `working_changes`, so the panel renders a commit's children and the
---UNCOMMITTED node's children through one code path.
---@param common_dir string
---@param sha string
---@return AutoCoreWorkingChange[] files, string? err
function M.commit_files(common_dir, sha)
  if not common_dir or not sha or sha == "" then return {}, "commit_files: needs common_dir and sha" end
  -- `--no-commit-id --name-status -z -m --first-parent` keeps a merge from
  -- reporting nothing at all (a plain diff-tree on a merge is empty).
  local code, out, errtxt = _run(_git(common_dir, {
    "diff-tree", "--no-commit-id", "--name-status", "-z", "-r",
    "-m", "--first-parent", sha,
  }))
  if code ~= 0 then
    return {}, "git diff-tree failed: " .. vim.trim(errtxt ~= "" and errtxt or out)
  end
  local fields = vim.split(out, "\0", { plain = true })
  local files, i = {}, 1
  while i <= #fields do
    local st = fields[i]; i = i + 1
    -- name-status emits STATUS \0 PATH [\0 NEWPATH for R/C]
    if st and st ~= "" and st:match("^[A-Z]") then
      local letter = st:sub(1, 1)
      local path = fields[i]; i = i + 1
      local orig = nil
      if letter == "R" or letter == "C" then
        orig, path = path, fields[i]; i = i + 1
      end
      if path and path ~= "" then
        files[#files + 1] = {
          path = path, orig = orig, x = letter, y = " ",
          kind = _kind(letter, " "), staged = true, unstaged = false,
        }
      end
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  return files, nil
end

return M
