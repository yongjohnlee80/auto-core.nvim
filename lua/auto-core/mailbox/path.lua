---auto-core.mailbox.path — mailbox root + per-mailbox path resolution.
---
---Two distinct concepts. **Do not conflate them.**
---
---### Agent mailbox roots — `tool_root(tool)`
---
---Per ADR 0013 §3, an agent-backed mailbox lives under the
---CLI agent's own durable global config dir, where the agent's
---sandbox already grants read/write without an explicit permission
---prompt:
---
---  - claude → `~/.claude/mailbox`
---  - gemini → `~/.gemini/mailbox`
---  - codex  → `~/.codex/mailbox`
---
---Call `path.tool_root("claude")` etc. when registering an agent
---mailbox so its data lives in the agent's natural workspace.
---
---### Host coordination root — `host_fallback_root()`
---
---The `nvim` and `user` mailboxes don't have a tool config dir;
---they run on the host. They fall back to a Neovim-side
---coordination root, resolved (first hit wins):
---
---  1. `cfg.root` — explicit override set via `mailbox.configure`
---     or `auto-core.setup({ mailbox = { root = ... } })`.
---  2. `$AUTO_AGENTS_MAILBOX_ROOT` — env override for one-off shells.
---  3. `$AUTO_AGENTS_CONFIG_DIR/mailbox`  — when the auto-agents
---     config dir is exported.
---  4. `dirname($AUTO_AGENTS_KB_ROOT)/mailbox` — derive the config
---     dir from the kb root env var.
---  5. `~/.config/nvim/.auto-agents-config/mailbox` — last-resort
---     default matching the auto-agents host config convention.
---
---**This host root is intentionally NOT the default for agent
---mailboxes** — it's the host coordination dir, used only when
---no explicit `root` was passed on register and the id is a
---host-side actor.
---
---No hard dependency on `vim.fn.getcwd()` or any worktree path.
---
---@module 'auto-core.mailbox.path'

local fs_path = require("auto-core.fs.path")

local M = {}

local DEFAULT_RELATIVE = ".config/nvim/.auto-agents-config/mailbox"

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
-- HOST-SIDE FALLBACK ROOT for mailboxes registered without an
-- explicit per-mailbox root.
local _override_root = nil

---Configure the host-side fallback root. nil clears it (fall back
---to env / default).
---@param root string?
function M.configure(root)
  if root == nil or root == "" then
    _override_root = nil
  else
    _override_root = fs_path.normalize(root)
  end
end

---Expand `~` and normalize a caller-supplied root. Centralized so
---`register({ root = "~/.claude/mailbox" })` behaves identically
---to absolute-path callers.
---@param root string
---@return string
function M.normalize_root(root)
  if root == nil or root == "" then return "" end
  -- Manually expand the leading `~` because vim.fs.normalize alone
  -- doesn't on every nvim version. fs_path.normalize composes
  -- fnamemodify(":p") which DOES expand it, but we keep this
  -- self-contained so callers don't need to know the chain.
  if root:sub(1, 1) == "~" then
    local home = vim.env.HOME or ""
    root = home .. root:sub(2)
  end
  return fs_path.normalize(root)
end

---Resolve the host-side fallback root using the documented order.
---Used when register() is called without an explicit `root` —
---typically for `nvim` and `user` mailboxes.
---@return string
function M.host_fallback_root()
  if _override_root and _override_root ~= "" then
    return _override_root
  end
  local env_mb = vim.env.AUTO_AGENTS_MAILBOX_ROOT
  if env_mb and env_mb ~= "" then
    return fs_path.normalize(env_mb)
  end
  local env_cfg = vim.env.AUTO_AGENTS_CONFIG_DIR
  if env_cfg and env_cfg ~= "" then
    return fs_path.normalize(fs_path.join(env_cfg, "mailbox"))
  end
  local env_kb = vim.env.AUTO_AGENTS_KB_ROOT
  if env_kb and env_kb ~= "" then
    return fs_path.normalize(fs_path.join(fs_path.parent(env_kb), "mailbox"))
  end
  return fs_path.normalize(fs_path.join(vim.env.HOME or "~", DEFAULT_RELATIVE))
end

---Legacy alias for v0.1.5 callers — same as `host_fallback_root`.
---@deprecated prefer host_fallback_root() (for nvim/user mailboxes)
---            or tool_root(tool) (for agent-backed mailboxes).
---@return string
function M.root() return M.host_fallback_root() end

-- Known CLI agent tools and their canonical config-dir layout.
-- Agents launched in their respective sandboxes already have r/w
-- on these paths, so the mailbox tree under <tool_root>/mailbox/
-- needs no special permission grant.
local TOOL_DIRS = {
  claude = ".claude/mailbox",
  gemini = ".gemini/mailbox",
  codex  = ".codex/mailbox",
}

---Resolve `<tool>`'s default mailbox root. Returns the absolute
---path under `$HOME`. Use this when registering an agent mailbox
---so the per-mailbox `root` opt matches the sandbox-allowed
---location for that tool.
---
---Example:
---   mailbox.register("agent:lector", {
---     root = path.tool_root("codex"),
---     wake = { command = "send_slot", args = { slot = "lector" } },
---   })
---
---Returns nil for unrecognized tools — callers can extend the
---table via `M.TOOL_DIRS["foo"] = ".foo/mailbox"` if a new tool
---joins the family.
---@param tool string
---@return string?
function M.tool_root(tool)
  if type(tool) ~= "string" or tool == "" then return nil end
  local rel = TOOL_DIRS[tool]
  if not rel then return nil end
  return fs_path.normalize(fs_path.join(vim.env.HOME or "~", rel))
end

---Set of recognized tool names (for tests + dynamic discovery).
M.TOOL_DIRS = TOOL_DIRS

---Validate a mailbox id. Returns ok, err_string?. The id is
---used as a directory name; we reject anything that could escape
---the root.
---@param id string
---@return boolean ok, string? err
function M.validate_id(id)
  if type(id) ~= "string" or #id == 0 then
    return false, "mailbox id must be a non-empty string"
  end
  if not id:match(ID_PATTERN) then
    return false, "mailbox id contains forbidden characters or shape: " .. id
  end
  return true
end

---Resolve `<root>/<mailbox-id>/`. Does NOT create the directory.
---When `root` is omitted, uses the host-side fallback.
---@param id   string
---@param root string?
---@return string
function M.mailbox_dir(id, root)
  local ok, err = M.validate_id(id)
  if not ok then error("auto-core.mailbox.path: " .. tostring(err)) end
  local r = root and M.normalize_root(root) or M.host_fallback_root()
  return fs_path.join(r, id)
end

---The five subdirectories every mailbox has, in stable order.
M.SUBDIRS = { "inbox", "outbox", "processing", "archive", "responses" }

---Resolve `<root>/<mailbox-id>/<sub>/`. Pass `root` to address a
---specific tool config dir; omit to use the host-side fallback.
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

-- ── instance_id (v0.1.8) ─────────────────────────────────────
--
-- The instance_id is the per-nvim suffix that scopes mailbox ids
-- to a particular nvim process. ADR 0013 / v0.1.8: each nvim
-- instance has its own subtree under the tool root, so two nvims
-- can run `agent:jarvis` simultaneously without misdelivery.
--
-- Default value is `<os.time>-<getpid>`, computed lazily on first
-- read. We don't compute at module-load to keep _reset_for_tests
-- deterministic and to let consumers override via `set_instance_id`
-- before the first registration.

---Return the currently-resolved instance_id, computing the default
---on first call. Stable for the lifetime of this nvim process
---(unless explicitly overridden).
---@return string
function M.get_instance_id()
  if _instance_id then return _instance_id end
  if _instance_lock then
    -- defensive — should not happen, but avoid recursion
    return "0-0"
  end
  _instance_lock = true
  _instance_id = string.format("%d-%d", os.time(), vim.fn.getpid())
  _instance_lock = false
  return _instance_id
end

---Override the instance_id. Consumers (typically tests, or auto-agents
---when it wants to pin to a project-scoped id) call this before any
---`register()` to set the suffix used for subsequent registrations.
---Pass `nil` to clear and fall back to the default computation.
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
---suffix, returns it unchanged. Useful for executioner / role checks
---and for display purposes.
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

---Path to the per-tool-root bootstrap doc. ADR 0013 v0.1.8 hoists
---the bootstrap doc from `<mailbox-dir>/bootstrap-mailbox.md` to
---`<tool-root>/bootstrap-mailbox.md` so a single canonical doc is
---shared across every agent under that tool. Pass either the tool
---name (`"codex"`) — resolves via `tool_root` — or a literal root
---path (must already be absolute).
---@param tool_or_root string
---@return string
function M.bootstrap_doc_path(tool_or_root)
  if type(tool_or_root) ~= "string" or tool_or_root == "" then
    error("auto-core.mailbox.path.bootstrap_doc_path: pass a tool name "
      .. "or absolute root path")
  end
  local root
  if TOOL_DIRS[tool_or_root] then
    root = M.tool_root(tool_or_root)
  else
    root = M.normalize_root(tool_or_root)
  end
  return fs_path.join(root, "bootstrap-mailbox.md")
end

---Test-only — clears the override so each test starts from defaults.
function M._reset_for_tests()
  _override_root = nil
  _instance_id   = nil
  _instance_lock = false
end

M.DEFAULT_RELATIVE       = DEFAULT_RELATIVE
M.ID_PATTERN             = ID_PATTERN
M.INSTANCE_SUFFIX_PATTERN = INSTANCE_SUFFIX_PATTERN

return M