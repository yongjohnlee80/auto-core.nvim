---auto-core.mailbox.registry — mailbox registration + directory
---layout management + bootstrap-doc upsert.
---
---A mailbox is identified by a string id (e.g. `user`, `nvim`,
---`agent:lector`). Registering a mailbox:
---
---  1. Resolves the on-disk root. The caller may pass an explicit
---     `root` (e.g. `~/.claude/mailbox` for a claude-backed agent)
---     so the sandbox-allowed location is used. Without `root`,
---     auto-core falls back to the host-side default — see
---     `auto-core.mailbox.path.host_fallback_root`.
---  2. Ensures `<root>/<id>/{inbox,outbox,processing,archive,
---     responses}/` exist.
---  3. Stores the optional `wake = { command, args }` config so the
---     central router can dispatch a wake-up through the command
---     registry when new inbox/responses files arrive.
---  4. Upserts `<root>/<id>/bootstrap-mailbox.md` from the canonical
---     template. Always rewritten — agents detect protocol changes
---     via the doc's `revision:` frontmatter field.
---  5. Publishes `core.mailbox:registered`.
---
---Re-registering a mailbox is idempotent for filesystem state (it
---does NOT clear inbox / processing / archive contents) but it
---DOES re-upsert the bootstrap doc with current template content.
---The `core.mailbox:registered` event fires every time — consumers
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
---@field id            string
---@field root          string                       -- resolved fallback or explicit root
---@field dir           string                       -- `<root>/<id>/`
---@field subs          table<string, string>        -- subdir name → absolute path
---@field wake          AutoCoreMailboxWakeSpec?
---@field executioner   boolean                      -- when true, router auto-dispatches commands addressed to this mailbox
---@field bootstrap     { path: string, revision: string }
---@field registered_at string

-- ── helpers ──────────────────────────────────────────────────

---@param path string
local function ensure_dir(path)
  if fs_path.is_dir(path) then return true end
  return vim.fn.mkdir(path, "p") == 1
end

-- ── public API ───────────────────────────────────────────────

---Register `id` as a mailbox. Returns the record. Always upserts
---the bootstrap doc.
---@param id   string
---@param opts AutoCoreMailboxRegisterOpts?
---@return AutoCoreMailboxRecord
function M.register(id, opts)
  opts = opts or {}
  local ok, err = mb_path.validate_id(id)
  if not ok then
    error("auto-core.mailbox.registry: " .. tostring(err))
  end

  local root = opts.root and mb_path.normalize_root(opts.root)
                       or mb_path.host_fallback_root()
  local dir = fs_path.join(root, id)
  ensure_dir(dir)

  local subs = {}
  for _, sub in ipairs(mb_path.SUBDIRS) do
    local p = fs_path.join(dir, sub)
    ensure_dir(p)
    subs[sub] = p
  end

  local previous = _by_id[id]
  local registered_at = previous and previous.registered_at or message.now_iso()

  -- Upsert the bootstrap doc with the current template. Always.
  local boot = bootstrap.upsert({ id = id, dir = dir, wake = opts.wake })

  -- Executioner default: nvim is the host-side executioner by
  -- convention (ADR 0013 §4). Other mailboxes default off; callers
  -- can flip it on explicitly per mailbox.
  local executioner
  if opts.executioner ~= nil then
    executioner = opts.executioner == true
  elseif id == "nvim" then
    executioner = true
  else
    executioner = false
  end

  local record = {
    id            = id,
    root          = root,
    dir           = dir,
    subs          = subs,
    wake          = opts.wake,
    executioner   = executioner,
    bootstrap     = boot,
    registered_at = registered_at,
  }
  _by_id[id] = record

  events.publish("core.mailbox:registered", {
    mailbox            = id,
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
---auto-register should call `register`).
---@param id string
---@return AutoCoreMailboxRecord?
function M.get(id)
  return _by_id[id]
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
---on-disk directories — those persist for audit.
---@param id string
function M.unregister(id)
  _by_id[id] = nil
end

---Test-only — clears the in-memory registry. Does NOT delete the
---directories on disk; tests that want a clean fs should use a
---temp root.
function M._reset_for_tests()
  _by_id = {}
end

return M