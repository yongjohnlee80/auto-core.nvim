---auto-core.mailbox.registry — mailbox registration + directory
---layout management + bootstrap-doc upsert.
---
---A mailbox is identified by a string id (e.g. `user`, `nvim`,
---`agent:lector`). v0.1.8 introduces **per-instance scoping**:
---bare ids passed to `register` are auto-suffixed with the current
---nvim's `instance_id` (`<unix-seconds>-<pid>`) so that multiple
---nvim processes sharing a tool root (~/.codex/mailbox/...) get
---non-overlapping mailbox subtrees. Callers can pass an already-
---suffixed id to address a specific instance (rare; cross-instance
---is intentionally explicit).
---
---Registering a mailbox:
---
---  1. Resolves the on-disk root. The caller may pass an explicit
---     `root` (e.g. `~/.claude/mailbox` for a claude-backed agent)
---     so the sandbox-allowed location is used. Without `root`,
---     auto-core falls back to the host-side default — see
---     `auto-core.mailbox.path.host_fallback_root`.
---  2. Resolves the full id via `path.full_id(bare_id)` so each
---     registration is scoped to this nvim's instance_id.
---  3. Ensures `<root>/<full_id>/{inbox,outbox,processing,archive,
---     responses}/` exist.
---  4. Stores the optional `wake = { command, args }` config so the
---     central router can dispatch a wake-up through the command
---     registry when new inbox/responses files arrive.
---  5. Upserts `<root>/bootstrap-mailbox.md` from the canonical
---     template (per-tool-root, shared across every mailbox in
---     that root — v0.1.8 hoist). v0.1.7's revision-skip keeps
---     this cheap on repeat calls.
---  6. Publishes `core.mailbox:registered`.
---
---Re-registering a mailbox is idempotent for filesystem state (it
---does NOT clear inbox / processing / archive contents). The
---`core.mailbox:registered` event fires every time — consumers
---that want first-time-only behavior can dedupe on the `mailbox`
---field.
---
---@module 'auto-core.mailbox.registry'

local events    = require("auto-core.events")
local fs_path   = require("auto-core.fs.path")
local mb_path   = require("auto-core.mailbox.path")
local message   = require("auto-core.mailbox.message")
local bootstrap = require("auto-core.mailbox.bootstrap")

local M = {}

---@type table<string, AutoCoreMailboxRecord>
local _by_id = {}

---@class AutoCoreMailboxWakeSpec
---@field command string                  -- registered command name to dispatch on arrival
---@field args    table?                  -- args passed to the handler

---@class AutoCoreMailboxRegisterOpts
---@field root        string?                    -- per-mailbox root (e.g. "~/.claude/mailbox"); falls back to host default
---@field wake        AutoCoreMailboxWakeSpec?   -- dispatch on inbox/responses arrival
---@field executioner boolean?                   -- when true, the central router auto-claims+dispatches command messages via the registry and writes the response; default true for id='nvim', false elsewhere

---@class AutoCoreMailboxRecord
---@field id            string                       -- full id including `:<instance_id>` suffix
---@field bare_id       string                       -- caller's input form (without instance suffix)
---@field root          string                       -- resolved fallback or explicit root
---@field dir           string                       -- `<root>/<full_id>/`
---@field subs          table<string, string>        -- subdir name → absolute path
---@field wake          AutoCoreMailboxWakeSpec?
---@field executioner   boolean                      -- when true, router auto-dispatches commands addressed to this mailbox
---@field bootstrap     { path: string, revision: string, wrote: boolean }
---@field registered_at string

-- ── helpers ──────────────────────────────────────────────────

---@param path string
local function ensure_dir(path)
  if fs_path.is_dir(path) then return true end
  return vim.fn.mkdir(path, "p") == 1
end

-- ── public API ───────────────────────────────────────────────

---Register `id` as a mailbox. Returns the record. Auto-suffixes
---bare ids with the current nvim's instance_id (v0.1.8).
---@param id   string  -- bare ("agent:lector") or full ("agent:lector:111-222")
---@param opts AutoCoreMailboxRegisterOpts?
---@return AutoCoreMailboxRecord
function M.register(id, opts)
  opts = opts or {}
  -- Capture the caller's bare form for display + executioner checks
  -- BEFORE we suffix it. This way "nvim" still triggers the
  -- executioner default even though the on-disk dir becomes
  -- `nvim:<instance_id>/`.
  local bare = mb_path.bare_id(id)
  local full_id = mb_path.full_id(id)

  local ok, err = mb_path.validate_id(full_id)
  if not ok then
    error("auto-core.mailbox.registry: " .. tostring(err))
  end

  local root = opts.root and mb_path.normalize_root(opts.root)
                       or mb_path.workspace_mailbox_root()
  local dir = mb_path.mailbox_dir(full_id, root)
  ensure_dir(dir)

  local subs = {}
  for _, sub in ipairs(mb_path.SUBDIRS) do
    local p = mb_path.subdir(full_id, sub, root)
    ensure_dir(p)
    subs[sub] = p
  end

  local previous = _by_id[full_id]
  local registered_at = previous and previous.registered_at or message.now_iso()

  -- v0.1.8: bootstrap doc is per-tool-root (one doc shared across
  -- every mailbox under this root), not per-mailbox. v0.1.7's
  -- revision-skip keeps repeat calls free.
  local boot = bootstrap.upsert({ root = root })

  -- Executioner default keyed on the BARE id, so "nvim" still
  -- triggers the host-side executioner convention after the
  -- instance suffix is applied.
  local executioner
  if opts.executioner ~= nil then
    executioner = opts.executioner == true
  elseif bare == "nvim" then
    executioner = true
  else
    executioner = false
  end

  local record = {
    id            = full_id,
    bare_id       = bare,
    root          = root,
    dir           = dir,
    subs          = subs,
    wake          = opts.wake,
    executioner   = executioner,
    bootstrap     = boot,
    registered_at = registered_at,
  }
  _by_id[full_id] = record

  events.publish("core.mailbox:registered", {
    mailbox            = full_id,
    bare_id            = bare,
    dir                = dir,
    root               = root,
    wake               = opts.wake,
    executioner        = executioner,
    bootstrap_path     = boot.path,
    bootstrap_revision = boot.revision,
    first_time         = previous == nil,
  })
  return record
end

---Get an already-registered mailbox record. Returns nil if not
---registered (does NOT auto-register — callers that want
---auto-register should call `register`). Accepts bare or full ids;
---a bare id resolves against THIS nvim's instance_id, so cross-
---instance lookups must use the full id explicitly. This is
---intentional — bare addressing always means "in my instance."
---@param id string
---@return AutoCoreMailboxRecord?
function M.get(id)
  if type(id) ~= "string" or id == "" then return nil end
  local full_id = mb_path.full_id(id)
  return _by_id[full_id]
end

---List all registered mailbox ids.
---@return string[]
function M.list()
  local out = {}
  for id in pairs(_by_id) do out[#out + 1] = id end
  table.sort(out)
  return out
end

---Snapshot of every registered mailbox record. The router consumes
---this to figure out which unique roots to watch.
---@return AutoCoreMailboxRecord[]
function M.records()
  local out = {}
  for _, rec in pairs(_by_id) do out[#out + 1] = rec end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

---Set of unique watch roots across registered mailboxes. The
---router opens one walk-and-watch per root.
---@return string[]
function M.unique_roots()
  local set = {}
  for _, rec in pairs(_by_id) do
    set[rec.root] = true
  end
  local out = {}
  for r in pairs(set) do out[#out + 1] = r end
  table.sort(out)
  return out
end

---Forget a mailbox from the in-memory registry. Does NOT delete any
---on-disk directories — those persist for audit. Accepts bare or
---full ids (bare resolves against this nvim's instance_id).
---@param id string
---@return AutoCoreMailboxRecord? removed
function M.unregister(id)
  if type(id) ~= "string" or id == "" then return nil end
  local full = mb_path.full_id(id)
  local previous = _by_id[full]
  _by_id[full] = nil
  if previous then
    events.publish("core.mailbox:unregistered", {
      mailbox = previous.id,
      bare_id = previous.bare_id,
      dir     = previous.dir,
      root    = previous.root,
    })
  end
  return previous
end

---Test-only — clears the in-memory registry. Does NOT delete the
---directories on disk; tests that want a clean fs should use a
---temp root.
function M._reset_for_tests()
  _by_id = {}
end

return M
