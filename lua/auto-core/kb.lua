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
---  M.provide_managed(provider, { version_key, files })    → ok, err, report
---  M.managed()                                            → { [rel] = record }
---  M.sync_managed(root?)                                  → ok, err, report
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
---**Managed KB documents.** Some files in a KB belong to the tool that
---ships them, not to the KB: AutoDoc's `KB_OPERATIONS.md` and
---`_schema/frontmatter.yaml` (ADR 1791209946 §3.1). Their provider hands
---auto-core the current text on every load (`provide_managed`), and
---auto-core keeps the newest copy of each, persisted, so the copy is at
---hand even in a session where the provider never loads. `sync_managed`
---is the ONE writer that brings a KB's existing copies up to it: a file
---is replaced only when it exists and declares an older version (under
---the provider's `version_key`), and nothing is ever created. auto-agents
---calls it for the primary KB before each spawn, so an agent always
---starts on the operations document of the installed AutoDoc.
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
local TOPIC_MANAGED_PROVIDED = "core.kb:managed_provided"
local TOPIC_MANAGED_SYNCED = "core.kb:managed_synced"

-- The `kb` namespace key holding the provided managed documents, as one
-- whole table keyed by KB-relative path (paths contain dots and slashes,
-- which the state store's nested-key syntax would split).
local MANAGED_KEY = "managed"

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

---The KB root for a project: its primary, then (for the session's own
---project only) `$AUTO_AGENTS_KB_ROOT`, then the first-run import, then
---nil. See the module doc.
---@param project_root string?  default: the session's project
---@return string|nil
function M.root(project_root)
  local key = _project_key(project_root)
  local rec = _read(key)
  if rec then return rec.root end
  -- `$AUTO_AGENTS_KB_ROOT` and the import both describe the SESSION's project: another project
  -- asked for by name has its recorded primary or nothing, never the session's KB
  if key ~= _project_key(nil) then return nil end
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

-- ─── managed KB documents ──────────────────────────────────────────

---@param v any
---@return integer[]|nil
local function _semver(v)
  if type(v) ~= "string" then return nil end
  local a, b, c = v:match("^v?(%d+)%.(%d+)%.(%d+)")
  if not a then return nil end
  return { tonumber(a), tonumber(b), tonumber(c) }
end

----1, 0 or 1; nil when either side is not a version.
local function _semver_cmp(a, b)
  local x, y = _semver(a), _semver(b)
  if not x or not y then return nil end
  for i = 1, 3 do
    if x[i] < y[i] then return -1 end
    if x[i] > y[i] then return 1 end
  end
  return 0
end

---The version a managed file declares under `key`: a YAML frontmatter or
---top-level line `key: X` (optionally quoted), or a leading comment line
---`# key: X` (how a YAML file that has no frontmatter carries it).
---@param text string|nil
---@param key string
---@return string|nil
local function _declared_version(text, key)
  if type(text) ~= "string" then return nil end
  local k = key:gsub("%p", "%%%0")
  local t = "\n" .. text
  return t:match("\n" .. k .. ":%s*\"?([^\"\n]-)\"?%s*\n")
    or t:match("\n#%s*" .. k .. ":%s*([^\n]-)%s*\n")
end

---A KB-relative path that stays inside the KB: no absolute path, no `..`.
local function _safe_rel(rel)
  if type(rel) ~= "string" or rel == "" or rel:sub(1, 1) == "/" or rel:find("\\", 1, true) then
    return false
  end
  for seg in rel:gmatch("[^/]+") do
    if seg == ".." or seg == "." then return false end
  end
  return true
end

local function _managed_all()
  local all = _ns():get(MANAGED_KEY)
  return type(all) == "table" and all or {}
end

local function _emit(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events and type(events.publish) == "function" then
    pcall(events.publish, topic, payload)
  end
end

---Record a provider's current managed KB documents. Each file is kept
---only when it is newer than the stored copy of the same path (a semver
---compare; an equal version keeps the stored copy), so an older build
---loaded alongside a newer one never rolls the documents back.
---
---`spec.files[i]` is `{ rel, version, text }`: `rel` is KB-relative,
---`version` a semver, and `text` must itself declare `version` under
---`spec.version_key` — the same field `sync_managed` reads back from a
---KB's copy, so a file whose declaration disagrees is refused rather
---than stored to be rewritten forever.
---
---Reasons on the false path: `"invalid_provider"`, `"invalid_version_key"`,
---`"invalid_files"`, `"invalid_file"` (with the offending path in the
---report's `invalid`). Publishes `core.kb:managed_provided` when
---anything was stored.
---@param provider string
---@param spec { version_key: string, files: { rel: string, version: string, text: string }[] }
---@return boolean ok, string? err, { stored: string[], kept: string[], invalid: string[] }
function M.provide_managed(provider, spec)
  local report = { stored = {}, kept = {}, invalid = {} }
  if type(provider) ~= "string" or provider == "" then return false, "invalid_provider", report end
  if type(spec) ~= "table" or type(spec.version_key) ~= "string" or not spec.version_key:match("^[%w_%-]+$") then
    return false, "invalid_version_key", report
  end
  if type(spec.files) ~= "table" or #spec.files == 0 then return false, "invalid_files", report end
  for _, f in ipairs(spec.files) do
    if type(f) ~= "table" or not _safe_rel(f.rel) or not _semver(f.version) or type(f.text) ~= "string"
        or _declared_version(f.text, spec.version_key) ~= f.version then
      report.invalid[#report.invalid + 1] = type(f) == "table" and tostring(f.rel) or "?"
    end
  end
  if #report.invalid > 0 then return false, "invalid_file", report end

  local all = vim.deepcopy(_managed_all())
  for _, f in ipairs(spec.files) do
    local cur = all[f.rel]
    if type(cur) ~= "table" or _semver_cmp(cur.version, f.version) == -1 then
      all[f.rel] = { provider = provider, version_key = spec.version_key, version = f.version,
        text = f.text, provided_at = _now_iso() }
      report.stored[#report.stored + 1] = f.rel
    else
      report.kept[#report.kept + 1] = f.rel
    end
  end
  if #report.stored > 0 then
    _ns():set(MANAGED_KEY, all)
    local versions = {}
    for _, rel in ipairs(report.stored) do versions[rel] = all[rel].version end
    _log_info(string.format("%s provided %s", provider, table.concat(report.stored, ", ")))
    _emit(TOPIC_MANAGED_PROVIDED, { provider = provider, files = versions })
  end
  return true, nil, report
end

---The stored managed documents, by KB-relative path: `{ provider,
---version_key, version, text, provided_at }`. A copy; editing it changes
---nothing.
---@return table<string, table>
function M.managed()
  return vim.deepcopy(_managed_all())
end

---Bring a KB's managed documents up to the stored copies. For each stored
---path, the KB's file is replaced (atomically) only when it EXISTS and
---declares an older version; a missing file stays missing (that KB chose
---not to have it, or is not a KB), and a same, newer or unreadable
---declaration is kept. Nothing else in the KB is read or written.
---
---Reasons on the false path: `"no_kb_root"` (no root given and the
---project resolves none), `"root_not_a_directory"`. Publishes
---`core.kb:managed_synced` when a file was replaced.
---@param root string?  default: `M.root()`, the session project's KB
---@return boolean ok, string? err, { root: string?, updated: string[], kept: string[], missing: string[], failed: string[], reasons: table<string,string> }
function M.sync_managed(root)
  local report = { root = nil, updated = {}, kept = {}, missing = {}, failed = {}, reasons = {} }
  if type(root) ~= "string" or root == "" then root = M.root() end
  if type(root) ~= "string" or root == "" then return false, "no_kb_root", report end
  root = fs_path.normalize(vim.fn.expand(root))
  if not fs_path.is_dir(root) then return false, "root_not_a_directory", report end
  report.root = root

  local all = _managed_all()
  local rels = vim.tbl_keys(all)
  table.sort(rels)
  for _, rel in ipairs(rels) do
    local rec = all[rel]
    local path = root .. "/" .. rel
    if not _safe_rel(rel) or type(rec) ~= "table" or type(rec.text) ~= "string" then
      report.failed[#report.failed + 1] = rel
      report.reasons[rel] = "invalid stored record"
    elseif vim.fn.filereadable(path) ~= 1 then
      report.missing[#report.missing + 1] = rel
    else
      local have = _declared_version(table.concat(vim.fn.readfile(path, "b"), "\n") .. "\n", rec.version_key)
      local cmp = _semver_cmp(have, rec.version)
      if cmp == -1 then
        local ok, err = require("auto-core.fs.atomic").write(path, rec.text)
        if ok then
          report.updated[#report.updated + 1] = rel
          report.reasons[rel] = string.format("%s -> %s", have, rec.version)
        else
          report.failed[#report.failed + 1] = rel
          report.reasons[rel] = tostring(err)
        end
      else
        report.kept[#report.kept + 1] = rel
        report.reasons[rel] = cmp == nil and "no readable version: kept" or "same or newer version"
      end
    end
  end
  if #report.updated > 0 then
    _log_info(string.format("synced %s in %s", table.concat(report.updated, ", "), root))
    _emit(TOPIC_MANAGED_SYNCED, { root = root, updated = vim.deepcopy(report.updated) })
  end
  return true, nil, report
end

---Test-only: wipe every recorded primary, the provided managed documents
---and the re-entrancy flag. Not part of the public API stability contract.
function M._reset_for_tests()
  _importing = false
  _ns():set("primaries", nil)
  _ns():set(MANAGED_KEY, nil)
end

return M
