---auto-core.mailbox.path — mailbox root + per-mailbox path resolution.
---
---### Workspace-scoped mailbox layout (v0.1.33+)
---
---The mailbox tree lives **inside the workspace**, at
---`<workspace_root>/.auto-agents/mailbox/`. This replaces the
---v0.1.8 per-tool-root layout (`~/.claude/mailbox`, `~/.codex/
---mailbox`, `~/.gemini/mailbox`). Rationale: visibility (the user
---sees mailbox files alongside their code), prunability (one tree
---per workspace; nuke when done), and accessibility (agents whose
---cwd is at or under the workspace root get native filesystem
---access without per-kind sandbox grants).
---
---Per-mailbox dir layout:
---
---   <root>/<instance_id>/<name>/inbox/
---                              /outbox/
---                              /processing/
---                              /archive/
---                              /responses/
---
---  - `<root>` is `workspace_mailbox_root()` (the workspace
---    `.auto-agents/mailbox/` dir) unless `register()` was passed
---    an explicit `root` opt.
---  - `<instance_id>` scopes the tree to this nvim process so two
---    nvims sharing a workspace get non-overlapping subtrees.
---  - `<name>` is the filesystem-safe name extracted from the
---    mailbox id: `agent:jarvis:1747-3478` → `jarvis`,
---    `nvim:1747-3478` → `nvim`, `user` → `user`. The type prefix
---    (`agent:`, `nvim:`) is dropped at filesystem level because
---    it's redundant once you're already in the instance subtree.
---
---Per-agent seen-revision file (for bootstrap re-ingestion):
---
---   <root>/seen_revisions/<name>/seen_revision
---
---Per-workspace bootstrap doc:
---
---   <root>/bootstrap-mailbox.md
---
---### Addressing scheme is unchanged
---
---Messages still carry `to = "agent:jarvis"` (bare) and
---`from = "agent:jarvis:1747-3478"` (full). The colons live in the
---**addressing layer** only; the filesystem layer strips them. The
---router resolves bare ids to full ids via the registry exactly as
---before.
---
---### Workspace root resolution
---
---`workspace_mailbox_root(opts)` calls `auto-core.fs.path.workspace_root`
---to find the bare-repo parent (or `.git` parent) of the current cwd,
---then appends `.auto-agents/mailbox`. Overrides:
---
---  1. `cfg.root` — explicit override set via `mailbox.configure`
---     or `auto-core.setup({ mailbox = { root = ... } })`.
---  2. `$AUTO_AGENTS_MAILBOX_ROOT` — env override for one-off shells.
---  3. Otherwise: `<workspace_root>/.auto-agents/mailbox`.
---
---@module 'auto-core.mailbox.path'

local fs_path = require("auto-core.fs.path")

local M = {}

local WORKSPACE_MAILBOX_SUFFIX = ".auto-agents/mailbox"

-- v0.1.8 instance_id state. Set once per nvim process (or overridden
-- via M.set_instance_id by tests / consumers). Format:
-- `<unix-seconds>-<pid>` — sortable, globally unique even when two
-- nvims spawn in the same second.
local _instance_id   = nil ---@type string?
local _instance_lock = false  -- guards lazy init

-- Pattern that matches the instance_id suffix at the tail of a full
-- mailbox id (`...:<digits>-<digits>$`). Used to detect whether an
-- incoming id is bare or already-suffixed.
local INSTANCE_SUFFIX_PATTERN = ":[0-9]+%-[0-9]+$"

-- Filesystem-safe mailbox-id pattern. Allow `[A-Za-z0-9_-]` plus `:`
-- so the `agent:lector` form documented in the ADR works as-is on
-- Linux. Path separators, `..`, leading dots are rejected.
local ID_PATTERN = "^[A-Za-z0-9][A-Za-z0-9:_%-]*$"

-- Module-local override (set by `mailbox.configure`). Used as the
-- workspace-mailbox root override.
local _override_root = nil

---Configure an explicit mailbox root override. nil clears it (fall
---back to env / workspace resolution).
---@param root string?
function M.configure(root)
  if root == nil or root == "" then
    _override_root = nil
  else
    _override_root = fs_path.normalize(root)
  end
end

---Expand `~` and normalize a caller-supplied root.
---@param root string
---@return string
function M.normalize_root(root)
  if root == nil or root == "" then return "" end
  if root:sub(1, 1) == "~" then
    local home = vim.env.HOME or ""
    root = home .. root:sub(2)
  end
  return fs_path.normalize(root)
end

---Resolve the workspace mailbox root. Appends `.auto-agents/mailbox`
---to the canonical workspace location.
---
---Per `shared/conventions/auto-family-state-ownership.md` rule #2,
---`auto-core.git.worktree` owns "where this session lives". This
---resolver consults that state rather than inventing a parallel
---workspace answer in `auto-agents`.
---
---Resolution order (highest precedence first):
---  1. `_override_root` — `configure()` / `mailbox.setup({ root })`.
---  2. `$AUTO_AGENTS_MAILBOX_ROOT` env var.
---  3. `auto-core.git.worktree.get_workspace_root()` — session-scoped
---     family container (the typical multi-worktree-shared mailbox
---     tree case, set by `worktree.nvim` at session start).
---  4. `auto-core.git.worktree.get_active()` — session-scoped active
---     worktree (more specific than workspace_root; used when only
---     active is set, e.g. a plain single-repo session).
---  5. `opts.cwd` — defensive fallback when auto-core state is unset
---     (typically a headless smoke / out-of-band call).
---  6. `vim.fn.getcwd()` — last resort.
---
---**Removed in v0.1.33:** the `fs_path.workspace_root` walk-up. It
---returned `parent(git_root)` for plain single-repo layouts (e.g.
---`~/Source/Projects/nvim-plugins`), placing the mailbox one level
---above the project root — surprising and incorrect. Consumers
---should populate `auto-core.git.worktree` state (worktree.nvim
---does this automatically at session start) rather than rely on
---path-walk heuristics in the mailbox layer.
---@param opts { cwd: string? }?
---@return string
function M.workspace_mailbox_root(opts)
  if _override_root and _override_root ~= "" then
    return _override_root
  end
  local env_mb = vim.env.AUTO_AGENTS_MAILBOX_ROOT
  if env_mb and env_mb ~= "" then
    return fs_path.normalize(env_mb)
  end
  local ok, worktree = pcall(require, "auto-core.git.worktree")
  if ok and worktree then
    local ws = worktree.get_workspace_root()
    if ws and ws ~= "" then
      return fs_path.normalize(fs_path.join(ws, WORKSPACE_MAILBOX_SUFFIX))
    end
    local active = worktree.get_active()
    if active and active ~= "" then
      return fs_path.normalize(fs_path.join(active, WORKSPACE_MAILBOX_SUFFIX))
    end
  end
  opts = opts or {}
  local start = opts.cwd or vim.fn.getcwd()
  return fs_path.normalize(fs_path.join(start, WORKSPACE_MAILBOX_SUFFIX))
end

---Back-compat alias for the v0.1.5..v0.1.32 host-fallback resolver.
---Now resolves to `workspace_mailbox_root()`; existing callers see a
---workspace-scoped path instead of `~/.config/nvim/.auto-agents-config/
---mailbox`. The legacy AUTO_AGENTS_CONFIG_DIR / AUTO_AGENTS_KB_ROOT
---fallback chain is gone (replaced by workspace walk-up).
---@return string
function M.host_fallback_root() return M.workspace_mailbox_root() end

---Legacy alias for v0.1.5 callers — same as `host_fallback_root`.
---@deprecated prefer workspace_mailbox_root().
---@return string
function M.root() return M.workspace_mailbox_root() end

---Reserved bare names that the host coordination layer owns. An
---agent named `nvim` or `user` would alias the host/user mailbox
---under the v0.1.33 layout (both resolve to `<root>/<instance>/nvim`
---or `<root>/<instance>/user` after the type prefix is stripped),
---causing routing isolation to break. Reject these at validation.
M.RESERVED_AGENT_NAMES = { nvim = true, user = true }

---Validate a mailbox id. Returns ok, err_string?. The id is
---used as a directory name; we reject anything that could escape
---the root OR collide with reserved host names.
---@param id string
---@return boolean ok, string? err
function M.validate_id(id)
  if type(id) ~= "string" or #id == 0 then
    return false, "mailbox id must be a non-empty string"
  end
  if not id:match(ID_PATTERN) then
    return false, "mailbox id contains forbidden characters or shape: " .. id
  end
  -- Reject agent ids that collide with host/user reserved names.
  -- `agent:nvim` / `agent:user` would resolve to the same filesystem
  -- name as `nvim` / `user` after `_name_from_id` strips the prefix.
  local agent_name = id:match("^agent:([^:]+)")
  if agent_name and M.RESERVED_AGENT_NAMES[agent_name] then
    return false, "agent name '" .. agent_name
      .. "' is reserved (would collide with host/user mailbox)"
  end
  return true
end

-- Extract the filesystem-safe name from a mailbox id (bare or full).
-- Strips the type prefix (`agent:`, `tool:`, etc.) AND the instance
-- suffix. Examples:
--   "agent:jarvis:1747-3478" → "jarvis"
--   "agent:jarvis"           → "jarvis"
--   "nvim:1747-3478"         → "nvim"
--   "nvim"                   → "nvim"
--   "user"                   → "user"
local function _name_from_id(id)
  local bare = M.is_full_id(id) and M.bare_id(id) or id
  -- bare may be "agent:jarvis" or "nvim" — strip up to the first ':'
  -- if present (the type prefix).
  local _, after = bare:match("^([^:]+):(.+)$")
  return after or bare
end
M._name_from_id = _name_from_id

-- Extract the instance_id (without the leading colon) from a full id.
-- Returns nil for bare ids.
local function _instance_from_full(id)
  local suffix = id and id:match(INSTANCE_SUFFIX_PATTERN)
  return suffix and suffix:sub(2) or nil
end
M._instance_from_full = _instance_from_full

---Resolve the on-disk dir for a mailbox id. Returns
---`<root>/<instance>/<name>/` for full ids; `<root>/<name>/` for
---bare ids (test/special-case path — production register() always
---works with full ids). When `root` is omitted, uses
---`workspace_mailbox_root()`.
---@param id   string
---@param root string?
---@return string
function M.mailbox_dir(id, root)
  local ok, err = M.validate_id(id)
  if not ok then error("auto-core.mailbox.path: " .. tostring(err)) end
  local r = root and M.normalize_root(root) or M.workspace_mailbox_root()
  local name = _name_from_id(id)
  local instance = _instance_from_full(id)
  if instance then
    return fs_path.join(r, instance, name)
  end
  return fs_path.join(r, name)
end

---The five subdirectories every mailbox has, in stable order.
M.SUBDIRS = { "inbox", "outbox", "processing", "archive", "responses" }

---Resolve `<mailbox_dir>/<sub>/`. Pass `root` to override; omit to
---use the workspace mailbox root.
---@param id   string
---@param sub  string
---@param root string?
---@return string
function M.subdir(id, sub, root)
  local found = false
  for _, s in ipairs(M.SUBDIRS) do
    if s == sub then found = true; break end
  end
  if not found then
    error("auto-core.mailbox.path: unknown subdir '" .. tostring(sub)
      .. "'; expected one of " .. table.concat(M.SUBDIRS, "/"))
  end
  return fs_path.join(M.mailbox_dir(id, root), sub)
end

---Resolve the per-agent seen-revision file path. Used by agents to
---record which revision of `bootstrap-mailbox.md` they last ingested
---so they can detect protocol-doc updates and re-ingest on demand.
---Per-agent (keyed on name, not instance) so the value persists
---across nvim restarts — the doc revision is global, not per-spawn.
---@param id   string  bare or full mailbox id
---@param root string?
---@return string
function M.seen_revision_path(id, root)
  local ok, err = M.validate_id(id)
  if not ok then error("auto-core.mailbox.path: " .. tostring(err)) end
  local r = root and M.normalize_root(root) or M.workspace_mailbox_root()
  return fs_path.join(r, "seen_revisions", _name_from_id(id), "seen_revision")
end

-- ── instance_id (v0.1.8) ─────────────────────────────────────

---Return the currently-resolved instance_id, computing the default
---on first call. Stable for the lifetime of this nvim process
---(unless explicitly overridden).
---@return string
function M.get_instance_id()
  if _instance_id then return _instance_id end
  if _instance_lock then
    return "0-0"
  end
  _instance_lock = true
  _instance_id = string.format("%d-%d", os.time(), vim.fn.getpid())
  _instance_lock = false
  return _instance_id
end

---Override the instance_id. Consumers (typically tests) call this
---before any `register()` to set the suffix used for subsequent
---registrations. Pass `nil` to clear and fall back to the default
---computation.
---@param id string?
function M.set_instance_id(id)
  if id == nil then _instance_id = nil; return end
  if type(id) ~= "string" or not id:match("^[0-9A-Za-z%-]+$") then
    error("auto-core.mailbox.path.set_instance_id: invalid id; expected "
      .. "non-empty [0-9A-Za-z-]+ string")
  end
  _instance_id = id
end

---True iff `id` already carries an instance_id suffix
---(matches `...:<digits>-<digits>$`).
---@param id string
---@return boolean
function M.is_full_id(id)
  return type(id) == "string" and id:match(INSTANCE_SUFFIX_PATTERN) ~= nil
end

---Strip the instance_id suffix from a full id, returning the bare
---form (`agent:lector:1747-3478` → `agent:lector`). If the id has no
---suffix, returns it unchanged.
---@param id string
---@return string
function M.bare_id(id)
  if type(id) ~= "string" then return id end
  if M.is_full_id(id) then
    return (id:gsub(INSTANCE_SUFFIX_PATTERN, ""))
  end
  return id
end

---Resolve a bare mailbox id to its full per-instance form. Already-
---full ids pass through unchanged so callers can pin to a specific
---instance (e.g. cross-instance addressing in `send`).
---@param id string
---@return string
function M.full_id(id)
  if type(id) ~= "string" or id == "" then
    error("auto-core.mailbox.path.full_id: id must be non-empty string")
  end
  if M.is_full_id(id) then return id end
  return id .. ":" .. M.get_instance_id()
end

---Path to the workspace-scoped bootstrap-mailbox.md. One doc per
---workspace mailbox root (since all agents under a workspace share
---the same protocol contract).
---@param root string?
---@return string
function M.bootstrap_doc_path(root)
  local r = root and M.normalize_root(root) or M.workspace_mailbox_root()
  return fs_path.join(r, "bootstrap-mailbox.md")
end

---Test-only — clears the override so each test starts from defaults.
function M._reset_for_tests()
  _override_root = nil
  _instance_id   = nil
  _instance_lock = false
end

M.WORKSPACE_MAILBOX_SUFFIX = WORKSPACE_MAILBOX_SUFFIX
M.ID_PATTERN               = ID_PATTERN
M.INSTANCE_SUFFIX_PATTERN  = INSTANCE_SUFFIX_PATTERN

return M