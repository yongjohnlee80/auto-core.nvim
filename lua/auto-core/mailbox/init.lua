---auto-core.mailbox — durable, file-backed mailbox transport with
---central router + command registry.
---
---Phase 1 surface per ADR 0013 (revised for the v0.1.33
---workspace-scoped layout):
---
---  * Workspace-scoped mailbox root — every agent registered in
---    this nvim session lives under
---    `<workspace_root>/.auto-agents/mailbox/<instance>/<name>/`.
---    The workspace root resolves via `auto-core.git.worktree`
---    state per the auto-family state-ownership convention; agents
---    inherit native filesystem access when their cwd is at or
---    under the workspace.
---  * Per-workspace `bootstrap-mailbox.md` upserted on every
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

---Register a mailbox. The opts table carries an explicit
---`root` override (rare — typically a test or out-of-band caller)
---and an optional `wake = { command, args }` for the router to
---dispatch on inbox/responses arrival. Without `root`, auto-core
---resolves the workspace mailbox root via
---`path.workspace_mailbox_root()`. v0.1.8 auto-suffixes bare ids
---with this nvim's `instance_id` — see `mailbox.get_instance_id`.
---@param id   string
---@param opts AutoCoreMailboxRegisterOpts?
function M.register(id, opts)
  local rec = registry_mod.register(id, opts)
  if router_mod.is_running() then router_mod.refresh() end
  return rec
end

---Forget a live mailbox registration and release any router watcher
---coverage that only existed for that mailbox. On-disk mailbox dirs are
---preserved for audit; this only changes live routing state.
---@param id string
---@return AutoCoreMailboxRecord? removed
function M.unregister(id)
  local removed = registry_mod.unregister(id)
  if router_mod.is_running() then router_mod.refresh() end
  return removed
end

---This nvim's mailbox `instance_id` (`<unix-seconds>-<pid>` by
---default; stable for the lifetime of this nvim process). All
---bare mailbox ids registered via `register` are suffixed with
---this value; the v0.1.33 layout uses `<instance>` as a directory
---level under the workspace root so two nvims sharing a workspace
---get non-overlapping mailbox subtrees.
---@return string
function M.get_instance_id() return path_mod.get_instance_id() end

---Override the instance_id. Rare — primarily for tests pinning
---to a known value, or consumers that want a project-scoped id
---instead of the process-scoped default. Must be called before
---any `register()` to be useful. Pass `nil` to revert to default.
---@param id string?
function M.set_instance_id(id) return path_mod.set_instance_id(id) end

---Build the env-var table an agent needs at spawn time so it can
---locate its own mailbox without socket access (sandbox-safe).
---Pass a registered mailbox record; returns a flat map ready to
---splat into the agent's spawn env.
---
---  AUTO_AGENTS_INSTANCE_ID            — this nvim's instance_id
---  AUTO_AGENTS_MAILBOX_ID             — agent's full mailbox id
---  AUTO_AGENTS_MAILBOX_DIR            — agent's mailbox dir
---  AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC  — per-workspace bootstrap doc
---@param record AutoCoreMailboxRecord
---@return table<string, string>
function M.env_for_agent(record)
  if type(record) ~= "table" or type(record.id) ~= "string" then
    error("auto-core.mailbox.env_for_agent: pass a registered record "
      .. "(result of mailbox.register)")
  end
  return {
    AUTO_AGENTS_INSTANCE_ID           = path_mod.get_instance_id(),
    AUTO_AGENTS_MAILBOX_ID            = record.id,
    AUTO_AGENTS_MAILBOX_DIR           = record.dir,
    AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC = record.bootstrap.path,
  }
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

---Prune old per-instance mailbox dirs. Walks each registered
---mailbox root (or `opts.root` if explicitly passed) and removes
---any `<instance>/<name>/` dir that isn't currently registered in
---this nvim's live registry and whose mtime is older than
---`opts.max_age_seconds` (default: 7 days).
---
---v0.1.33 layout: `<root>/<instance>/<name>/`. Empty `<instance>/`
---parent dirs are rmdir'd after their children are pruned. The
---workspace bootstrap-mailbox.md and `seen_revisions/` tree are
---left intact.
---
---**Safety rail (Lector audit round-2 deferred):** when an explicit
---`opts.root` is passed that has ZERO live registrations in this
---nvim's registry (e.g. cleaning up a legacy
---`~/.claude/mailbox/` tree), the call refuses by default — returns
---`{ refused = true, reason = "no_live_registrations", root = ... }`
---without touching the filesystem. Bypass with `opts.force = true`
---to confirm you want to wipe a non-live tree. Implicit-root calls
---(no `opts.root`, which prune every registered root) are
---unaffected because they only walk roots that ARE registered.
---
---Returns either:
---  - `{ refused = true, reason, root }` on safety-rail trip
---  - `{ removed[], kept_alive[], kept_recent[], failed[] }` otherwise
---Errors during individual rm are non-fatal — the path is reported
---in `failed`.
---@param opts { root: string?, max_age_seconds: integer?, force: boolean? }?
---@return table
function M.prune(opts)
  opts = opts or {}
  local explicit_root = type(opts.root) == "string" and opts.root ~= ""
  local roots
  if explicit_root then
    roots = { path_mod.normalize_root(opts.root) }
  else
    roots = registry_mod.unique_roots()
  end
  local max_age = tonumber(opts.max_age_seconds) or (7 * 24 * 60 * 60)
  local now = os.time()

  -- Live record dirs keyed by absolute path. rec.dir already encodes
  -- the new <root>/<instance>/<name>/ layout via the registry's call
  -- to mb_path.mailbox_dir at register-time, so this match stays
  -- layout-agnostic.
  local live = {}
  local live_roots = {}
  for _, rec in ipairs(registry_mod.records()) do
    live[rec.dir] = true
    live_roots[rec.root] = (live_roots[rec.root] or 0) + 1
  end

  -- Safety rail: explicit root with no live registrations refuses
  -- unless force=true. Protects accidental cleanup of legacy roots
  -- (e.g. `~/.claude/mailbox`) from wiping the whole tree.
  if explicit_root and opts.force ~= true then
    local target = roots[1]
    if not live_roots[target] then
      return {
        refused = true,
        reason  = "no_live_registrations",
        root    = target,
      }
    end
  end

  local out = { removed = {}, kept_alive = {}, kept_recent = {}, failed = {} }

  local function rmdir_if_empty(p)
    local s = vim.uv.fs_scandir(p)
    if s and not vim.uv.fs_scandir_next(s) then
      pcall(vim.uv.fs_rmdir, p)
    end
  end

  for _, root in ipairs(roots) do
    if vim.fn.isdirectory(root) == 1 then
      local sd_inst = vim.uv.fs_scandir(root)
      if sd_inst then
        while true do
          local instance, t1 = vim.uv.fs_scandir_next(sd_inst)
          if not instance then break end
          -- Skip non-instance entries (seen_revisions/, bootstrap doc,
          -- anything that doesn't match the <unix>-<pid> shape).
          if t1 == "directory"
             and instance:match("^[0-9]+%-[0-9]+$") then
            local inst_dir = root .. "/" .. instance
            local sd_name = vim.uv.fs_scandir(inst_dir)
            if sd_name then
              while true do
                local name, t2 = vim.uv.fs_scandir_next(sd_name)
                if not name then break end
                if t2 == "directory" then
                  local dir = inst_dir .. "/" .. name
                  if live[dir] then
                    out.kept_alive[#out.kept_alive + 1] = dir
                  else
                    local stat = vim.uv.fs_stat(dir)
                    local mtime = stat and stat.mtime and stat.mtime.sec or now
                    if (now - mtime) >= max_age then
                      local ok = pcall(vim.fn.delete, dir, "rf")
                      if ok and vim.fn.isdirectory(dir) == 0 then
                        out.removed[#out.removed + 1] = dir
                      else
                        out.failed[#out.failed + 1] = dir
                      end
                    else
                      out.kept_recent[#out.kept_recent + 1] = dir
                    end
                  end
                end
              end
            end
            -- Tidy: drop the now-empty instance dir.
            rmdir_if_empty(inst_dir)
          end
        end
      end
    end
  end

  return out
end

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
