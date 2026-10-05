---The project's primary knowledge base, and the ONE KB-root resolver
---(ADR 1791209945 §5).
---
---Every plugin and agent that asks "which KB does this project use?"
---asks here. Before this module there were two answers that could
---disagree — `todo/vars.lua`'s `$KB_ROOT` built-in (env ROOT → READ[0]
---→ WRITE → `auto-agents.kb.root()`) and `todo/init.lua`'s private
---`kb_root()` (the same env chain, without the auto-agents fallback) —
---and both now delegate to `M.root`
---([[shared-resolver-single-source-of-truth]]).
---
---  M.primary(project_root?)                       → { workspace, root } | nil
---  M.root(project_root?)                          → root | nil
---  M.set_primary(project_root, spec, { confirmed = true }) → ok, err
---
---Resolution order of `M.root`:
---  1. the project's primary (this module's state);
---  2. `$AUTO_AGENTS_KB_ROOT` — set inside a spawned agent;
---  3. the first-run import (below), then nil.
---`AUTO_AGENTS_KB_READ` / `AUTO_AGENTS_KB_WRITE` are no longer read:
---a spawned agent always receives ROOT, and READ/WRITE are scoped
---sub-directories, never the root.
---
---**First run is an idempotent import.** A project with no primary
---keeps the legacy answer — `require("auto-agents.kb").root()`, a soft
---dependency — and records it as the project's primary once, logged.
---It is recorded only when it names an existing directory (auto-agents
---answers `<project>/.auto-agents/kb` whether or not that exists, and a
---phantom root must not become permanent), and only for the session's
---own project (auto-agents resolves for the session, so its answer says
---nothing about any other project). Once recorded, step 1 answers and
---the import never runs again for that real path — an alias included.
---Nothing on disk changes besides this module's state file.
---
---**Re-entrancy.** auto-agents' `kb.root()` becomes a shim over this
---module for one minor. The import calls auto-agents, which calls back
---here; while an import is in flight a nested `M.root` skips the
---import step (answering from steps 1–2 only), so the shim falls
---through to its own legacy resolution instead of recursing.
---
---**The todo store is untouched.** `set_primary` changes only which KB
---a project uses; `auto-core.todo`'s directory, its overrides and the
---`todos.*` surface are not read or written here.
---
---Storage: one record per project under the `primaries` key of
---`auto-core.state.namespace("kb")`, keyed by the project root's REAL
---path (`vim.uv.fs_realpath`), so a symlinked or aliased root maps to
---one entry. Records are read/written as whole tables (never via
---dot-path traversal) because a real path contains dots
---(`~/.config/...`) that the state store's nested-key syntax would
---split — the same reason `auto-core.trust` stores its capabilities
---whole.
---
---Per [[auto-core-maintenance]] #6 this module never notifies; it
---returns `(ok, err)` pairs and consumers own the UX (the confirmation
---modal in front of `set_primary` is theirs).
---@module 'auto-core.kb'

local fs_path = require("auto-core.fs.path")

local M = {}

local STATE_NS = "kb"

-- The component axis for this module's log records (see todo/init.lua's
-- LOG_COMPONENT for why it is an axis and not a message prefix).
local LOG_COMPONENT = "auto-core.kb"

local TOPIC_CHANGED = "core.kb:primary_changed"

-- True while `_import` is calling out to auto-agents. A nested `M.root`
-- (auto-agents' shim calling back in) must not start a second import.
local _importing = false

local function _ns()
  return require("auto-core.state").namespace(STATE_NS, { persist = "json" })
end

---@class AutoCoreKbPrimary
---@field workspace string|nil  AutoDoc workspace name (nil for an imported primary until one is named)
---@field root string           absolute KB root

---The persistence key for a project root: its real path, or — when the
---path does not exist, so there is nothing to resolve — its normalized
---form. `project_root = nil` resolves the session's project the same
---way the todo store resolves its workspace (`todo.paths.workspace_root`:
---git.worktree workspace, active worktree, cwd).
---@param project_root string?
---@return string
local function _project_key(project_root)
  local p = project_root
  if type(p) ~= "string" or p == "" then
    p = require("auto-core.todo.paths").workspace_root()
  end
  p = fs_path.normalize(vim.fn.expand(p))
  local real = vim.uv.fs_realpath(p)
  if type(real) == "string" and real ~= "" then return real end
  return p
end

---@param key string
---@return table|nil
local function _read(key)
  local all = _ns():get("primaries")
  if type(all) ~= "table" then return nil end
  local rec = all[key]
  if type(rec) ~= "table" or type(rec.root) ~= "string" or rec.root == "" then
    return nil
  end
  return rec
end

---@param key string
---@param rec table
local function _write(key, rec)
  local ns = _ns()
  local all = ns:get("primaries")
  all = type(all) == "table" and vim.deepcopy(all) or {}
  all[key] = rec
  ns:set("primaries", all)
end

local function _now_iso()
  return tostring(os.date("!%Y-%m-%dT%H:%M:%SZ"))
end

---@param rec table|nil
---@return AutoCoreKbPrimary|nil
local function _public(rec)
  if not rec then return nil end
  return { workspace = rec.workspace, root = rec.root }
end

local function _publish(key, rec, old, source)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events and type(events.publish) == "function" then
    pcall(events.publish, TOPIC_CHANGED, {
      project_root = key,
      workspace    = rec.workspace,
      root         = rec.root,
      old          = _public(old),
      source       = source,
    })
  end
end

local function _log_info(msg)
  local ok, log = pcall(require, "auto-core.log")
  if ok and log and type(log.info) == "function" then
    pcall(log.info, LOG_COMPONENT, msg)
  end
end

---The legacy answer, recorded once. Returns the root auto-agents
---resolved (normalized) whether or not it was recorded, so a project
---without a primary still gets today's answer; nil when auto-agents is
---absent, errors, or answers nothing.
---@param key string
---@return string|nil
local function _import(key)
  if _importing then return nil end
  _importing = true
  local ok, root = pcall(function()
    local ok_m, aa = pcall(require, "auto-agents.kb")
    if not ok_m or type(aa) ~= "table" or type(aa.root) ~= "function" then
      return nil
    end
    local ok_r, r = pcall(aa.root)
    if ok_r and type(r) == "string" and r ~= "" then return r end
    return nil
  end)
  _importing = false
  if not ok or type(root) ~= "string" then return nil end
  root = fs_path.normalize(vim.fn.expand(root))

  if key == _project_key(nil) and fs_path.is_dir(root) and not _read(key) then
    local rec = { root = root, set_at = _now_iso() }
    _write(key, rec)
    _log_info(string.format(
      "imported the primary KB for %s from auto-agents: %s", key, root))
    _publish(key, rec, nil, "import")
  end
  return root
end

---The project's primary KB, or nil when none is recorded.
---@param project_root string?  default: the session's project
---@return AutoCoreKbPrimary|nil
function M.primary(project_root)
  return _public(_read(_project_key(project_root)))
end

---The KB root for a project: its primary, then `$AUTO_AGENTS_KB_ROOT`,
---then the first-run import, then nil. See the module doc.
---@param project_root string?  default: the session's project
---@return string|nil
function M.root(project_root)
  local key = _project_key(project_root)
  local rec = _read(key)
  if rec then return rec.root end
  local env = vim.env.AUTO_AGENTS_KB_ROOT
  if type(env) == "string" and env ~= "" then return fs_path.normalize(env) end
  return _import(key)
end

---Make `spec` the project's primary KB. Interactive only: it refuses
---unless `opts.confirmed == true`, which the caller passes after the
---user confirmed, and it is deliberately NOT a mailbox verb — a remote
---agent can never re-point a project's KB (as `trust.acknowledge_first_run`
---is never reachable from a mailbox handler).
---
---Reasons on the false path: `"not_confirmed"`, `"invalid_spec"`,
---`"invalid_workspace"`, `"root_not_a_directory"`. Re-setting the same
---value is a no-op (no write, no event). Each change publishes
---`core.kb:primary_changed` with `source = "set"`.
---@param project_root string?  default: the session's project
---@param spec { workspace: string?, root: string }
---@param opts { confirmed: boolean? }?
---@return boolean ok, string? err
function M.set_primary(project_root, spec, opts)
  if type(opts) ~= "table" or opts.confirmed ~= true then
    return false, "not_confirmed"
  end
  if type(spec) ~= "table" or type(spec.root) ~= "string" or spec.root == "" then
    return false, "invalid_spec"
  end
  if spec.workspace ~= nil
      and (type(spec.workspace) ~= "string" or spec.workspace == "") then
    return false, "invalid_workspace"
  end
  local root = fs_path.normalize(vim.fn.expand(spec.root))
  if not fs_path.is_dir(root) then
    return false, "root_not_a_directory"
  end

  local key = _project_key(project_root)
  local old = _read(key)
  if old and old.root == root and old.workspace == spec.workspace then
    return true, nil
  end
  local rec = { workspace = spec.workspace, root = root, set_at = _now_iso() }
  _write(key, rec)
  _publish(key, rec, old, "set")
  return true, nil
end

---Test-only: wipe every recorded primary and the re-entrancy flag. Not
---part of the public API stability contract.
function M._reset_for_tests()
  _importing = false
  _ns():set("primaries", nil)
end

return M
