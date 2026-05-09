---Path utilities for the AutoVim plugin family.
---
---Normalization, joining, hierarchy queries, and project-root
---resolution (git root / workspace root / generic project root).
---These replace ad-hoc `vim.fn.fnamemodify` chains, repeated
---`git rev-parse` shell-outs, and per-plugin root-walking loops
---scattered across the family.
---
---Pure module — no module state, no events, no async. Each function
---is a referentially transparent input → output mapping over the
---filesystem.
---
---Companion modules: `auto-core.git.repo` for git-specific
---introspection that talks to the `git` binary.
---
---API per ADR 0006 §4 (`fs.path`):
---
---  M.normalize(path)              expand ~, resolve .., collapse /, strip trailing /
---  M.join(...)                    concatenate components with `/`
---  M.parent(path)                 dirname
---  M.basename(path)               last component
---  M.relative(path, base)         relative path from base to path
---  M.is_under(child, parent)      is `child` a descendant of `parent`?
---  M.exists(path)                 file or dir?
---  M.is_dir(path) / .is_file(p)   type predicates
---  M.project_root(opts?)          walk up looking for project markers
---  M.git_root(opts?)              walk up looking for `.git`
---  M.workspace_root(opts?)        parent of the nearest `.bare`/`.git` container
---@module 'auto-core.fs.path'

local M = {}

-- Project-root markers, in priority order. The first match wins.
-- Mirrors LazyVim.root() spirit but auto-core-curated.
local DEFAULT_PROJECT_MARKERS = {
  ".git",
  "go.mod",
  "package.json",
  "pyproject.toml",
  "Cargo.toml",
  "lazy-lock.json",  -- lazy.nvim project (autovim itself uses this)
  ".luarc.json",
  "deno.json",
  "deno.jsonc",
  "build.zig",
}

-- ── normalization + structural helpers ────────────────────────

---Normalize a path: expand `~`, make absolute, lexically resolve
---`..` / `.`, collapse double slashes, strip a trailing `/`. Returns
---an absolute path. Pure-lexical for `..` collapse — does NOT
---require the intermediate directories to exist on disk.
---
---Implementation detail: `:p` (fnamemodify) absolutizes + expands
---`~` but does NOT collapse `..` for paths whose components don't
---exist. `vim.fs.normalize` is lexical and handles that case. Run
---both: absolutize first, then lexically collapse.
---@param path string
---@return string
function M.normalize(path)
  if path == nil or path == "" then return "" end
  local abs = vim.fn.fnamemodify(path, ":p")
  local lex = vim.fs.normalize(abs)
  return (lex:gsub("/$", ""))
end

---Join path components with `/`. Treats absolute components in the
---middle of the list as a path reset (matches python's os.path.join
---semantics + vim's own concatenation conventions).
---@param ... string
---@return string
function M.join(...)
  local parts = { ... }
  if #parts == 0 then return "" end
  local out = parts[1] or ""
  for i = 2, #parts do
    local p = parts[i]
    if p == nil or p == "" then
      -- skip
    elseif p:sub(1, 1) == "/" then
      out = p  -- absolute reset
    else
      out = (out:sub(-1) == "/") and (out .. p) or (out .. "/" .. p)
    end
  end
  return out
end

---Parent directory. Empty input returns empty.
---@param path string
---@return string
function M.parent(path)
  if path == nil or path == "" then return "" end
  return vim.fn.fnamemodify(path, ":h")
end

---Last path component (filename or last directory).
---@param path string
---@return string
function M.basename(path)
  if path == nil or path == "" then return "" end
  return vim.fn.fnamemodify(path, ":t")
end

---Relative path from `base` to `path`. Returns `nil` if `path` isn't
---under `base` (no `..` traversal — keeps the API safe). Both inputs
---are normalized.
---@param path string
---@param base string
---@return string?
function M.relative(path, base)
  local p = M.normalize(path)
  local b = M.normalize(base)
  if p == b then return "." end
  -- Append `/` to base for prefix-matching so "/foo" doesn't match
  -- "/foobar".
  local prefix = b .. "/"
  if p:sub(1, #prefix) ~= prefix then return nil end
  return p:sub(#prefix + 1)
end

---Is `child` a descendant of `parent`? Both normalized.
---@param child string
---@param parent string
---@return boolean
function M.is_under(child, parent)
  if not child or not parent or child == "" or parent == "" then return false end
  local c = M.normalize(child)
  local p = M.normalize(parent)
  if c == p then return true end
  return c:sub(1, #p + 1) == p .. "/"
end

---Whether the path exists (file OR dir). Single fs.stat call.
---@param path string
---@return boolean
function M.exists(path)
  if path == nil or path == "" then return false end
  return vim.uv.fs_stat(path) ~= nil
end

---Whether the path is an existing directory.
---@param path string
---@return boolean
function M.is_dir(path)
  if path == nil or path == "" then return false end
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---Whether the path is an existing regular file.
---@param path string
---@return boolean
function M.is_file(path)
  if path == nil or path == "" then return false end
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

-- ── root resolvers ────────────────────────────────────────────

---Walk up from `start` (default cwd), return the first ancestor
---that contains any of the `markers`. Markers can be filenames OR
---directory names. The check uses `vim.uv.fs_stat` so we don't shell
---out per ancestor.
---@param start string?       -- starting path (default cwd)
---@param markers string[]?   -- defaults to DEFAULT_PROJECT_MARKERS
---@return string?            -- absolute root, or nil if no marker found before /
local function walk_up_for_markers(start, markers)
  local cur = M.normalize(start or vim.fn.getcwd())
  if cur == "" then return nil end
  while cur ~= "" and cur ~= "/" do
    for _, marker in ipairs(markers) do
      if M.exists(M.join(cur, marker)) then
        return cur
      end
    end
    local parent = M.parent(cur)
    if parent == cur then break end
    cur = parent
  end
  return nil
end

---Resolve the project root by walking up from `opts.start` looking
---for any of `opts.markers` (default: git/go/node/pyproject/cargo/
---lazy/luarc/deno/zig). First match wins.
---@param opts { start: string?, markers: string[]? }?
---@return string?
function M.project_root(opts)
  opts = opts or {}
  return walk_up_for_markers(opts.start, opts.markers or DEFAULT_PROJECT_MARKERS)
end

---Walk up looking for `.git` only. Equivalent to
---`git rev-parse --show-toplevel` but pure-Lua (no shell). Returns
---the directory containing `.git` (file or dir form). For a linked
---worktree, returns the worktree's own root, not the bare-repo
---container.
---@param opts { start: string? }?
---@return string?
function M.git_root(opts)
  opts = opts or {}
  return walk_up_for_markers(opts.start, { ".git" })
end

---The "workspace root" is the parent of the nearest git container
---(`.bare` directory, or the parent of `.git`). Conceptually:
---
---   ~/Source/Projects/MyProject/.bare    → workspace_root = ~/Source/Projects/MyProject
---   ~/Source/Projects/MyProject/.git     → workspace_root = ~/Source/Projects/MyProject
---   ~/Source/Projects/MyProject/branch-A/.git  → walks up to MyProject (the parent of .git's parent)
---
---This is the parent dir that `<leader>gQ` / `<leader>gW` should
---return to reliably (closing the user-reported "wandering parent"
---pain documented in ADR 0006 §"State surface inventory"). The
---live state value `core.workspace_root` is set ONCE at session
---start and updated only via explicit user action — this resolver
---is the initial-pin computation.
---@param opts { start: string? }?
---@return string?
function M.workspace_root(opts)
  opts = opts or {}
  local start = M.normalize(opts.start or vim.fn.getcwd())

  -- Strategy: find the nearest container that hosts BOTH a `.bare`
  -- dir AND/OR multiple sibling worktrees. Falls back to the parent
  -- of the nearest `.git` if no bare container is found.
  local cur = start
  while cur ~= "" and cur ~= "/" do
    -- If cur contains a .bare, cur IS the workspace root.
    if M.is_dir(M.join(cur, ".bare")) then return cur end
    local parent = M.parent(cur)
    if parent == cur then break end
    cur = parent
  end

  -- Fallback: parent of the nearest .git ancestor.
  local gr = M.git_root(opts)
  if gr then return M.parent(gr) end

  -- Last resort: cwd's parent.
  return M.parent(start)
end

---Public read of the marker list (consumers may want to extend it).
M.DEFAULT_PROJECT_MARKERS = DEFAULT_PROJECT_MARKERS

return M
