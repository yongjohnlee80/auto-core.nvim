---`.git`/`.bare`-aware directory walker.
---
---Replaces ad-hoc `vim.uv.fs_scandir` recursion scattered across
---auto-finder, gitsgraph, md-harpoon, and worktree.nvim. Phase 4c
---per ADR 0006 + auto-core-todos.
---
---Public surface:
---
---  tree.walk(root, opts?)        → entries[]
---  tree.walk_dirs(root, opts?)   → entries[]   (filter type=='directory')
---  tree.walk_files(root, opts?)  → entries[]   (filter type=='file')
---
---Each entry: { path, name, type } where `type` is "file" |
---"directory" | "link".
---
---Default behavior — what gets EXCLUDED:
---  - `.git/` subtree (and bare `.git` files for linked worktrees)
---  - `.bare/` subtree (bare-repo plumbing)
---  - `/node_modules/` (canonical js dependency dir)
---  - hidden entries (`name` starts with `.`) — toggle with
---    `opts.include_hidden = true`
---
---**Open question (deferred per auto-core-todos Phase 4c):** whether
---to ALSO parse `.gitignore` rules. Baseline does NOT — `.git`/`.bare`
---exclusion only. `.gitignore` parsing can layer on top later via
---an `opts.respect_gitignore = true` flag without breaking callers.
---
---Iterative (no recursion) so deep trees don't blow the Lua stack.
---@module 'auto-core.fs.tree'

local path_mod = require("auto-core.fs.path")

local M = {}

-- Anchored Lua patterns matched against the FULL path (with a
-- trailing `/` appended for directories). Anchoring to `/` prevents
-- spurious matches like a file literally named "foo.git".
local DEFAULT_EXCLUDE = {
  "/%.git/",          -- .git subtree
  "/%.bare/",         -- .bare subtree
  "/%.git$",          -- the .git entry itself (file form for linked wt)
  "/%.bare$",         -- .bare itself
  "/node_modules/",
}

---@class AutoCoreTreeEntry
---@field path string   -- absolute path
---@field name string   -- basename
---@field type "file"|"directory"|"link"|"unknown"

---@class AutoCoreTreeWalkOpts
---@field exclude string[]?       -- override DEFAULT_EXCLUDE (Lua patterns)
---@field depth integer?          -- max depth (0 = root only); default unbounded
---@field include_hidden boolean? -- default false (skips dotfiles)
---@field follow_links boolean?   -- default false (don't recurse through symlinks)

---@param p string
---@param exclude string[]
---@return boolean
local function should_exclude(p, exclude)
  for _, pat in ipairs(exclude) do
    if p:find(pat) then return true end
  end
  return false
end

---Walk `root` and return a flat list of entries. Visits in BFS order
---(predictable for tests). Entries are added in the order they're
---discovered.
---@param root string
---@param opts AutoCoreTreeWalkOpts?
---@return AutoCoreTreeEntry[]
function M.walk(root, opts)
  opts = opts or {}
  local exclude        = opts.exclude or DEFAULT_EXCLUDE
  local depth_max      = opts.depth or math.huge
  local include_hidden = opts.include_hidden == true
  local follow_links   = opts.follow_links == true

  local norm_root = path_mod.normalize(root)
  if not path_mod.is_dir(norm_root) then return {} end

  local out  = {}
  local todo = { { dir = norm_root, depth = 0 } }
  while #todo > 0 do
    -- BFS: take from the front. table.remove(t, 1) is O(n); we'd
    -- prefer DFS-via-pop for perf, but BFS gives sibling-grouped
    -- output which makes test assertions stable. Trees we walk are
    -- usually small; if profiling shows this hot, switch to DFS.
    local cur = table.remove(todo, 1)
    local sd = vim.uv.fs_scandir(cur.dir)
    if sd then
      while true do
        local name, type_ = vim.uv.fs_scandir_next(sd)
        if not name then break end
        if include_hidden or name:sub(1, 1) ~= "." then
          local full = cur.dir .. "/" .. name
          local probe = (type_ == "directory") and (full .. "/") or full
          if not should_exclude(probe, exclude) then
            out[#out + 1] = {
              path = full,
              name = name,
              type = type_ or "unknown",
            }
            local descend = type_ == "directory"
              or (follow_links and type_ == "link" and path_mod.is_dir(full))
            if descend and cur.depth + 1 <= depth_max then
              todo[#todo + 1] = { dir = full, depth = cur.depth + 1 }
            end
          end
        end
      end
    end
  end
  return out
end

---Walk and return only directory entries.
---@param root string
---@param opts AutoCoreTreeWalkOpts?
---@return AutoCoreTreeEntry[]
function M.walk_dirs(root, opts)
  local out = {}
  for _, e in ipairs(M.walk(root, opts)) do
    if e.type == "directory" then out[#out + 1] = e end
  end
  return out
end

---Walk and return only file entries.
---@param root string
---@param opts AutoCoreTreeWalkOpts?
---@return AutoCoreTreeEntry[]
function M.walk_files(root, opts)
  local out = {}
  for _, e in ipairs(M.walk(root, opts)) do
    if e.type == "file" then out[#out + 1] = e end
  end
  return out
end

M.DEFAULT_EXCLUDE = DEFAULT_EXCLUDE

return M
