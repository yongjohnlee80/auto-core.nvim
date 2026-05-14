---auto-core.mailbox — durable, file-backed mailbox transport with
---central router + command registry.
---
---Phase 1 surface per ADR 0013 (revised after the per-tool-config-
---dir decision):
---
---  * Per-mailbox roots so claude-backed agents live under
---    `~/.claude/mailbox`, gemini-backed under `~/.gemini/mailbox`,
---    etc — the sandbox already grants the agent read/write on
---    its own config dir.
---  * Per-mailbox `bootstrap-mailbox.md` upserted on every
---    `register()` from the canonical template. Agents audit the
---    `revision:` frontmatter field on wake to detect protocol
---    changes (see `lua/auto-core/mailbox/templates/bootstrap.md`).
---  * Central walk-and-watch router (one watcher per unique root)
---    that routes outbox → recipient inbox, fires
---    `core.mailbox:message_queued` on arrival, and dispatches a
---    `wake` command via the command registry (so auto-agents'
---    `send_slot` directive can wake the agent's terminal slot).
---  * Whitelisted command registry — unknown commands rejected
---    with a structured response, never executed as raw code.
---
---Public re-exports for ergonomics:
---
---  M.configure(opts)          configure mailbox subsystem
---  M.host_fallback_root()     resolved host-side default root
---  M.register(id, opts?)      ensure dirs + upsert bootstrap doc
---  M.send(opts)               atomic enqueue (host-side helper —
---                             writes directly to recipient inbox)
---  M.claim/complete/fail      state transitions
---  M.start/stop/refresh       router lifecycle
---  M.scan_now()               one-shot routing + arrival pass
---
---  M.path, M.message, M.registry, M.transport, M.commands, M.router,
---  M.bootstrap, M.ui   submodule access for callers that need the raw surface
---
---@module 'auto-core.mailbox'

local path_mod      = require("auto-core.mailbox.path")
local message_mod   = require("auto-core.mailbox.message")
local registry_mod  = require("auto-core.mailbox.registry")
local transport_mod = require("auto-core.mailbox.transport")
local commands_mod  = require("auto-core.mailbox.commands")
local router_mod    = require("auto-core.mailbox.router")
local bootstrap_mod = require("auto-core.mailbox.bootstrap")
local ui_mod        = require("auto-core.mailbox.ui")

local M = {}

-- Sub-namespaces.
M.path      = path_mod
M.message   = message_mod
M.registry  = registry_mod
M.transport = transport_mod
M.commands  = commands_mod
M.router    = router_mod
M.bootstrap = bootstrap_mod
M.ui        = ui_mod

---@class AutoCoreMailboxConfig
---@field root             string?                   -- override the host-side fallback root
---@field autostart        boolean?                  -- auto-start router on setup (default false)
---@field mode             "auto"|"watch"|"poll"?    -- router event-source mode (default "auto")
---@field poll_interval_ms integer|false?            -- polling fallback interval; false disables
---@field stale_threshold_ms integer?                -- recover-stale age threshold (ms)
---@field stale_policy     "fail"|"requeue"?         -- recover-stale policy
---@field stale_recover_on_start boolean?            -- run recover_stale_all on router start (default true)

local _cfg = { root = nil, autostart = false }

---Configure the mailbox subsystem. Forwards relevant subsets to
---`path`, `router`, and the autostart hook. Accepts:
---   root              — host-side fallback root for nvim/user
---                       mailboxes (agents pass their own root on
---                       register).
---   autostart         — when true, calls `router.start()`.
---   mode              — router event source: "auto" tries fs_event
---                       and falls back to poll per-root; "watch"
---                       requires fs_event (no fallback); "poll"
---                       skips fs_event entirely.
---   poll_interval_ms  — interval for the poll fallback. Default
---                       1000ms. Pass `false` to disable polling.
---   stale_threshold_ms / stale_policy / stale_recover_on_start —
---                       forwarded to router; control the stale-
---                       processing sweep on start.
---@param opts AutoCoreMailboxConfig?
function M.configure(opts)
  opts = opts or {}
  if opts.root ~= nil then
    path_mod.configure(opts.root)
    _cfg.root = opts.root
  end
  if opts.autostart ~= nil then
    _cfg.autostart = opts.autostart == true
  end
  -- Forward router-shape opts. Each is optional; nil means "leave
  -- alone."
  router_mod.configure({
    mode                    = opts.mode,
    poll_interval_ms        = opts.poll_interval_ms,
    stale_threshold_ms      = opts.stale_threshold_ms,
    stale_policy            = opts.stale_policy,
    stale_recover_on_start  = opts.stale_recover_on_start,
  })
  -- If the router is running and the root was reconfigured, refresh
  -- so any new fallback-rooted mailboxes get picked up.
  if router_mod.is_running() then router_mod.refresh() end
  -- Honor autostart on every configure call (idempotent).
  if _cfg.autostart and not router_mod.is_running() then
    router_mod.start()
  end
end

---Currently-resolved host-side fallback root.
---@return string
function M.host_fallback_root() return path_mod.host_fallback_root() end

---Register a mailbox. The opts table carries per-mailbox `root`
---(typically a tool config dir like `~/.claude/mailbox`) and an
---optional `wake = { command, args }` for the router to dispatch
---on inbox/responses arrival.
---@param id   string
---@param opts AutoCoreMailboxRegisterOpts?
function M.register(id, opts)
  local rec = registry_mod.register(id, opts)
  if router_mod.is_running() then router_mod.refresh() end
  return rec
end

---Send a message via the host-side helper. Writes directly to the
---recipient's inbox (Neovim is trusted; no need to round-trip
---through Neovim's own outbox). External agents send by writing
---into THEIR OWN outbox/ — the router picks it up and delivers.
---@param opts AutoCoreMailboxMessageOpts
function M.send(opts) return transport_mod.send(opts) end

---Claim a message off the inbox into processing. `opts.claimed_by`
---is stamped durably onto the processing file so `recover_stale`
---can identify abandoned work.
---@param mailbox_id string
---@param message_id string
---@param opts       { claimed_by: string? }?
function M.claim(mailbox_id, message_id, opts)
  return transport_mod.claim(mailbox_id, message_id, opts)
end

---Complete a claimed message; optionally write a response.
function M.complete(mailbox_id, message_id, response)
  return transport_mod.complete(mailbox_id, message_id, response)
end

---Mark a claimed message as failed.
function M.fail(mailbox_id, message_id, err_info, opts)
  return transport_mod.fail(mailbox_id, message_id, err_info, opts)
end

---Recover stale processing messages for `mailbox_id`. Default
---policy is "fail" — archives with status='failed' and writes a
---structured response so blocking senders unblock. Pass
---`{ policy = "requeue" }` to send them back to inbox.
---@param mailbox_id string
---@param opts AutoCoreMailboxStaleRecoveryOpts?
function M.recover_stale(mailbox_id, opts)
  return transport_mod.recover_stale(mailbox_id, opts)
end

---Recover stale processing across every registered mailbox.
---@param opts AutoCoreMailboxStaleRecoveryOpts?
function M.recover_stale_all(opts)
  return transport_mod.recover_stale_all(opts)
end

---Start the central router (idempotent).
function M.start() return router_mod.start() end

---Stop the central router.
function M.stop() return router_mod.stop() end

---Refresh the router (open watchers for newly-registered roots,
---close watchers for emptied ones).
function M.refresh() return router_mod.refresh() end

---@return boolean
function M.is_running() return router_mod.is_running() end

---Force a one-shot pass over every registered mailbox.
function M.scan_now() return router_mod.scan_now() end

---Test-only — resets every mailbox submodule. Does NOT delete
---on-disk directories.
function M._reset_for_tests()
  ui_mod._reset_for_tests()
  router_mod._reset_for_tests()
  commands_mod._reset_for_tests()
  registry_mod._reset_for_tests()
  message_mod._reset_for_tests()
  path_mod._reset_for_tests()
  _cfg = { root = nil, autostart = false }
end

return M