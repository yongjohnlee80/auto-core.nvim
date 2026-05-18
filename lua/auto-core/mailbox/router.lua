---auto-core.mailbox.router — the single central watcher that drives
---outbox routing, inbox-arrival events, response-arrival events,
---and wake-hook dispatch.
---
---Architecture (ADR 0013, revised):
---
---  - The router opens ONE walk-and-watch per UNIQUE registered
---    root. So claude-backed mailboxes under `~/.claude/mailbox`
---    share one watcher; gemini-backed ones under `~/.gemini/
---    mailbox` get their own; host-side `nvim`/`user` share the
---    fallback root's watcher. Typical session: 2–4 root watchers.
---  - libuv's fs_event isn't recursive on Linux, so we walk each
---    root at start and open one fs_event handle per existing
---    subdirectory (matching the proven pattern in
---    `auto-core.fs.watch`).
---  - On any event, the router classifies the path:
---       <root>/<mailbox-id>/<subdir>/<name>.json
---    and dispatches:
---       outbox    → atomic rename → recipient inbox; publish
---                   `core.mailbox:outbox_routed` or
---                   `core.mailbox:outbox_undeliverable` on no-recipient.
---       inbox     → publish `core.mailbox:message_queued`; dispatch
---                   wake hook via command registry.
---       responses → publish `core.mailbox:response_received`; dispatch
---                   wake hook (the sender unblocks).
---       processing/archive → no-op (informational; sender or
---                   recipient owns those).
---  - The router pre-seeds a `seen` set per (mailbox, subdir) at
---    start time so the initial scan doesn't fire events for
---    pre-existing files (replay storm protection).
---
---Lifecycle:
---  - `router.start()`   idempotent; opens watchers for every
---                       currently-registered unique root.
---  - `router.refresh()` re-scans the registry, opens watchers for
---                       any newly-registered root, closes watchers
---                       for roots that no longer have any mailbox.
---  - `router.stop()`    closes everything.
---
---Auto-core's `setup()` does NOT call `start()` for you — the host
---decides when to begin routing. Family plugins that want default-
---on behavior should call `mailbox.router.start()` from their own
---setup once they've registered the mailboxes they care about.
---
---@module 'auto-core.mailbox.router'

local events    = require("auto-core.events")
local fs_path   = require("auto-core.fs.path")
local mb_path   = require("auto-core.mailbox.path")
local registry  = require("auto-core.mailbox.registry")
local message   = require("auto-core.mailbox.message")
local commands  = require("auto-core.mailbox.commands")
local transport = require("auto-core.mailbox.transport")
local log       = require("auto-core.log")

-- Component name used on every log entry from this module. Pairs
-- with the `mailbox.router.*` event names registered in
-- plugin/auto-core.lua so `:AutoCoreLog` triage can filter by either
-- the component (`auto-core.mailbox.router`) or the event id.
local LOG_COMPONENT = "auto-core.mailbox.router"

local M = {}

local DEFAULT_DEBOUNCE_MS    = 25
local DEFAULT_MAX_HANDLES    = 1024
local DEFAULT_POLL_INTERVAL  = 1000   -- ms; honored when any root falls back to poll, or when mode='poll'

---@class AutoCoreMailboxRouterConfig
---@field mode             "auto"|"watch"|"poll"?    default "auto"
---@field poll_interval_ms integer|false?            default 1000; false disables polling fallback
---@field stale_threshold_ms integer?                default 5*60*1000 — used by start() recovery sweep
---@field stale_policy     "fail"|"requeue"?         default "fail"
---@field stale_recover_on_start boolean?            default true

---@class AutoCoreMailboxRouterState
---@field running    boolean
---@field roots      table<string, AutoCoreMailboxRouterRootEntry>
---@field seen       table<string, table<string, boolean>>  -- per-subdir-path id-sets
---@field debounce   table<string, integer>                 -- path → last-event-ms
---@field poll_timer userdata?                              -- single global timer for poll mode
---@field cfg        AutoCoreMailboxRouterConfig

---@class AutoCoreMailboxRouterRootEntry
---@field root        string
---@field handles     userdata[]   -- fs_event objects we own
---@field watched     string[]     -- subdir paths under this root that have a handle
---@field poll_active boolean      -- true if this root relies on the poll timer (watch unavailable or mode='poll')

---@type AutoCoreMailboxRouterState
local _state = {
  running    = false,
  roots      = {},
  seen       = {},
  debounce   = {},
  poll_timer = nil,
  cfg = {
    mode                    = "auto",
    poll_interval_ms        = DEFAULT_POLL_INTERVAL,
    stale_threshold_ms      = 5 * 60 * 1000,
    stale_policy            = "fail",
    stale_recover_on_start  = true,
  },
}

---Internal: snapshot of configuration with sensible defaults applied.
---Exposed for tests + the `mailbox.configure` forwarder.
---@param opts AutoCoreMailboxRouterConfig?
function M.configure(opts)
  opts = opts or {}
  if opts.mode ~= nil then
    if opts.mode ~= "auto" and opts.mode ~= "watch" and opts.mode ~= "poll" then
      error("router.configure: invalid mode '" .. tostring(opts.mode)
        .. "' (expected 'auto'|'watch'|'poll')")
    end
    _state.cfg.mode = opts.mode
  end
  if opts.poll_interval_ms ~= nil then
    _state.cfg.poll_interval_ms = opts.poll_interval_ms
  end
  if opts.stale_threshold_ms ~= nil then
    _state.cfg.stale_threshold_ms = opts.stale_threshold_ms
  end
  if opts.stale_policy ~= nil then
    _state.cfg.stale_policy = opts.stale_policy
  end
  if opts.stale_recover_on_start ~= nil then
    _state.cfg.stale_recover_on_start = opts.stale_recover_on_start
  end
end

-- ── helpers ────────────────────────────────────────────────

---@param path string
---@return boolean
local function is_json_id(path)
  if path == nil or path == "" then return false end
  local base = path:match("([^/]+)$")
  if not base then return false end
  if base:sub(1, 1) == "." then return false end          -- dotfile / tmp
  if base:sub(-5) ~= ".json" then return false end
  return true
end

---@param path string
---@return string
local function id_from_filename(path)
  local base = path:match("([^/]+)$") or ""
  return base:sub(1, -6)  -- strip ".json"
end

---Classify a path observed under `<root>/<mailbox-id>/<sub>/<file>`
---into (mailbox_record, sub, message_id). Returns nil on no-match
---(e.g. the bootstrap-mailbox.md doc, or a file under an unknown
---subdir, or a non-json file).
---
---ADR 0023 Track D: when the path matches the expected layout but
---the mailbox isn't registered with the live router (i.e. it's an
---orphan from a decommissioned nvim instance, or a stale dir from
---a resumed agent writing to its old instance's path), we now
---emit `core.mailbox:stale_orphan_detected` BEFORE returning nil.
---The router itself still doesn't deliver these files — the event
---is for observability + cleanup hooks (`prune({ drop_orphans =
---true })`). Pre-ADR-0023 behavior was a silent drop with zero
---surface for diagnostics.
---@param root string
---@param path string
---@return AutoCoreMailboxRecord?, string?, string?
local function classify(root, path)
  if not is_json_id(path) then return nil end
  -- Strip the root prefix; expect `<mailbox-id>/<sub>/<id>.json`.
  if path:sub(1, #root + 1) ~= root .. "/" then return nil end
  local rel = path:sub(#root + 2)
  local mid, sub, fname = rel:match("^([^/]+)/([^/]+)/([^/]+)$")
  if not mid or not sub or not fname then return nil end

  -- Layout matched. Two reject cases below — emit the orphan
  -- event for the registry-rejection case ONLY (the
  -- "unknown-subdir" case is benign file noise; we don't want
  -- to flood observability for those).
  local rec = registry.get(mid)
  if not rec or rec.root ~= root then
    events.publish("core.mailbox:stale_orphan_detected", {
      path        = path,
      mailbox_id  = mid,
      sub         = sub,
      message_id  = id_from_filename(path),
      reason      = (not rec) and "unregistered_mailbox" or "wrong_root",
      context     = "router.classify",
    })
    return nil
  end

  -- Subdir must be in the standard list, otherwise ignore.
  local valid = false
  for _, s in ipairs({ "inbox", "outbox", "processing", "archive", "responses" }) do
    if s == sub then valid = true; break end
  end
  if not valid then return nil end
  return rec, sub, id_from_filename(path)
end

---@param key string
---@return boolean fire   -- true if the event should be dispatched now
local function debounce_check(key)
  local now = vim.uv.now()
  local last = _state.debounce[key]
  if last and (now - last) < DEFAULT_DEBOUNCE_MS then
    _state.debounce[key] = now
    return false
  end
  _state.debounce[key] = now
  return true
end

---@param dir_key string
local function seen_set(dir_key)
  _state.seen[dir_key] = _state.seen[dir_key] or {}
  return _state.seen[dir_key]
end

---@param dir   string
---@return string[]
local function scan_ids(dir)
  return transport._list_dir_ids(dir)
end

-- ── wake-hook dispatch ────────────────────────────────────

---Build a synthetic command message for wake-hook dispatch. The
---host-side executioner is bypassed — we go directly through the
---command registry. If the wake command isn't registered (because
---auto-agents hasn't loaded yet, or this is host-side), nothing
---happens; the event is still published.
---@param rec   AutoCoreMailboxRecord
---@param kind  "inbox"|"responses"
---@param mid   string
local function dispatch_wake(rec, kind, mid)
  local wake = rec.wake
  if type(wake) ~= "table" or type(wake.command) ~= "string" then
    -- No wake configured on this mailbox. Emit at DEBUG so triage
    -- can confirm the recipient simply opted out, not that the
    -- dispatcher crashed silently.
    log.debug(LOG_COMPONENT, "wake skipped — no wake config on mailbox", {
      event  = "auto-core.mailbox.router.wake_skipped",
      fields = {
        mailbox        = rec.bare_id,
        mailbox_full   = rec.id,
        arrival_kind   = kind,
        arrival_id     = mid,
        reason         = "no_wake_config",
      },
    })
    return
  end
  local spec = commands.get(wake.command)
  if not spec then
    -- No handler yet; we don't error or notify. Wake hooks are a
    -- nice-to-have — the upstream event is the source of truth. Log
    -- at WARN so the missing handler is visible during triage; a
    -- wake configured against an unregistered command is almost
    -- always a setup bug (handler module not loaded yet).
    log.warn(LOG_COMPONENT,
      "wake skipped — command not registered: " .. tostring(wake.command), {
      event  = "auto-core.mailbox.router.wake_skipped",
      fields = {
        mailbox        = rec.bare_id,
        mailbox_full   = rec.id,
        arrival_kind   = kind,
        arrival_id     = mid,
        command        = wake.command,
        reason         = "command_not_registered",
      },
    })
    return
  end
  -- Synthesize a command message just for the registry's shape
  -- check. The handler receives args + ctx; ctx tells it which
  -- mailbox + arrival kind triggered the wake.
  local msg = {
    id      = message.new_id(),
    kind    = "command",
    from    = "auto-core",
    to      = rec.id,
    command = wake.command,
    args    = wake.args or {},
  }
  local ctx = {
    reason       = "mailbox_wake",
    mailbox      = rec.bare_id,
    mailbox_full = rec.id,
    arrival_kind = kind,
    arrival_id   = mid,
    -- ADR 0023 Track A — agent-side drift detection. Carries the
    -- LIVE host's authoritative identity for the addressed mailbox
    -- so a resumed agent (whose AUTO_AGENTS_* env is fork-frozen
    -- with the OLD instance) can compare on every wake and
    -- self-correct via `refresh_agent_id`. The hint is wire-format
    -- only at this layer — auto-agents Phase 2 owns the consumer-
    -- side comparison + recovery logic.
    identity_hint = {
      expected_instance_id = mb_path.get_instance_id(),
      expected_mailbox_id  = rec.id,
      expected_bare_id     = rec.bare_id,
    },
  }
  -- handle_message never raises; failures come back in the response
  -- table. We don't surface those further — wake is fire-and-forget.
  -- Log the dispatch so `:AutoCoreLog` triage can see every wake
  -- attempt + the structured outcome. handle_message itself emits its
  -- own command_executed entry (component `auto-core.mailbox.commands`)
  -- carrying the ok/code/error fields; this entry captures the
  -- router-side decision to dispatch.
  log.info(LOG_COMPONENT, "wake dispatched: " .. wake.command, {
    event  = "auto-core.mailbox.router.wake_dispatched",
    fields = {
      mailbox        = rec.bare_id,
      mailbox_full   = rec.id,
      arrival_kind   = kind,
      arrival_id     = mid,
      command        = wake.command,
      synthesized_id = msg.id,
    },
  })
  commands.handle_message(msg, ctx)
end

-- ── outbox routing ────────────────────────────────────────

---@param rec AutoCoreMailboxRecord
---@param mid string
local function route_outbox(rec, mid)
  local src = rec.subs.outbox .. "/" .. mid .. ".json"
  -- The message may have been removed by another consumer (or by
  -- the test harness). Read-decode failures are non-fatal.
  local msg, derr = transport.read_from(rec.id, "outbox", mid)
  if not msg then
    if derr then
      events.publish("core.mailbox:outbox_undeliverable", {
        from   = rec.bare_id,
        from_full = rec.id,
        id     = mid,
        reason = "decode_failed",
        error  = derr,
      })
    end
    return
  end

  local recipient = registry.get(msg.to)
  if not recipient then
    events.publish("core.mailbox:outbox_undeliverable", {
      from   = rec.bare_id,
      from_full = rec.id,
      to     = msg.to,
      id     = mid,
      reason = "recipient_unregistered",
      path   = src,
    })
    return
  end

  local dst = recipient.subs.inbox .. "/" .. mid .. ".json"
  local ok, err = vim.uv.fs_rename(src, dst)
  if not ok then
    events.publish("core.mailbox:outbox_undeliverable", {
      from   = rec.bare_id,
      from_full = rec.id,
      to     = msg.to,
      id     = mid,
      reason = "rename_failed",
      error  = err,
      path   = src,
    })
    return
  end

  -- v0.1.8: event payloads use bare ids for consumer-friendly
  -- pattern matching. Use `from_full` / `to_resolved` when you need
  -- the full instance-suffixed form (e.g. for cross-instance routing).
  events.publish("core.mailbox:outbox_routed", {
    from        = rec.bare_id,
    from_full   = rec.id,
    to          = mb_path.bare_id(msg.to),
    to_resolved = recipient.id,
    id          = mid,
    path        = dst,
  })
end

-- ── arrival handling ──────────────────────────────────────

---Host executioner path. For mailboxes registered with
---`executioner = true` (default for `nvim`), incoming command
---messages are auto-claimed, dispatched through the command
---registry, and the response is written back to the sender so
---blocking pollers unblock.
---
---Non-command messages on an executioner mailbox fall through to
---the normal wake-hook path (the host may still want to surface
---plain messages to a UI). Unknown commands go through
---`commands.handle_message` which returns a structured
---`unknown_command` rejection — the rejection IS the response.
---
---@param rec AutoCoreMailboxRecord
---@param mid string
---@param msg table
local function execute_command(rec, mid, msg)
  local claimed, claim_err = transport.claim(rec.id, mid,
    { claimed_by = "nvim-executioner" })
  if not claimed then
    -- Race: another consumer claimed it first, or the file vanished.
    -- Not an error condition we need to surface — the other consumer
    -- owns the response now.
    return
  end
  -- ctx surfaces THREE distinct concerns to the command handler:
  --   * mailbox / mailbox_full — the EXECUTOR's mailbox (where this code is
  --     dispatching from; usually `nvim`).
  --   * sender / sender_bare   — the SENDER's mailbox (the agent that
  --     authored msg.from). Handlers that care about "who asked me to do
  --     this" (audit logs, capability checks, per-sender attribution like
  --     the diff_queue handler in auto-agents) read sender_bare. Without
  --     these fields, handlers historically had to guess from
  --     `ctx.mailbox` — which is the executor, not the sender.
  --   * correlation_id / message_id — the round-trip identity of the
  --     originating command. Handlers that defer a user-driven verdict
  --     past the synchronous response (auto-agents' diff_queue stashes
  --     correlation_id on its queue entry so the eventual reject/accept
  --     can route a follow-up message back to the sender) need both.
  --     message_id is the executor-path file basename; correlation_id is
  --     `msg.correlation_id` (auto-core treats absent correlation as
  --     "use the message id" — but handlers that want explicit semantics
  --     read the field directly).
  local cor = claimed.correlation_id
  local response = commands.handle_message(claimed, {
    reason         = "mailbox_executioner",
    mailbox        = rec.bare_id,
    mailbox_full   = rec.id,
    sender         = claimed.from,
    sender_bare    = type(claimed.from) == "string"
                       and mb_path.bare_id(claimed.from)
                       or nil,
    correlation_id = (type(cor) == "string" and cor ~= "") and cor or nil,
    message_id     = mid,
  })
  -- complete() handles the response envelope routing back to the
  -- sender. Errors during complete are logged but don't propagate;
  -- the executioner is fire-and-forget from the router's PoV.
  transport.complete(rec.id, mid, response)
end

---@param rec AutoCoreMailboxRecord
---@param mid string
local function handle_inbox(rec, mid)
  local seen = seen_set(rec.subs.inbox)
  if seen[mid] then return end
  seen[mid] = true
  local msg, err = transport.read_from(rec.id, "inbox", mid)
  events.publish("core.mailbox:message_queued", {
    mailbox        = rec.bare_id,
    mailbox_full   = rec.id,
    id             = mid,
    kind           = msg and msg.kind or nil,
    from           = msg and msg.from or nil,
    path           = rec.subs.inbox .. "/" .. mid .. ".json",
    correlation_id = msg and (type(msg.correlation_id) == "string"
                              and msg.correlation_id or nil) or nil,
    message        = msg,
    decode_error   = err,
  })
  log.info(LOG_COMPONENT, "inbox arrival: " .. mid, {
    event  = "auto-core.mailbox.router.inbox_arrival",
    fields = {
      mailbox      = rec.bare_id,
      mailbox_full = rec.id,
      arrival_kind = "inbox",
      arrival_id   = mid,
      msg_kind     = msg and msg.kind or nil,
      msg_from     = msg and msg.from or nil,
      msg_command  = msg and (msg.kind == "command" and msg.command or nil) or nil,
      decode_error = err,
      executioner  = rec.executioner == true,
    },
  })
  -- Executioner path: auto-dispatch command kind through the
  -- registry. Non-command messages still fall through to wake.
  if rec.executioner and msg and msg.kind == "command" then
    execute_command(rec, mid, msg)
    return
  end
  dispatch_wake(rec, "inbox", mid)
end

---@param rec AutoCoreMailboxRecord
---@param cor string
local function handle_response(rec, cor)
  local seen = seen_set(rec.subs.responses)
  if seen[cor] then return end
  seen[cor] = true
  events.publish("core.mailbox:response_received", {
    mailbox        = rec.bare_id,
    mailbox_full   = rec.id,
    correlation_id = cor,
    path           = rec.subs.responses .. "/" .. cor .. ".json",
  })
  log.info(LOG_COMPONENT, "response arrival: " .. cor, {
    event  = "auto-core.mailbox.router.response_arrival",
    fields = {
      mailbox        = rec.bare_id,
      mailbox_full   = rec.id,
      arrival_kind   = "responses",
      arrival_id     = cor,
      correlation_id = cor,
    },
  })
  dispatch_wake(rec, "responses", cor)
end

---@param rec AutoCoreMailboxRecord
---@param mid string
local function handle_outbox(rec, mid)
  -- Outbox routing — we don't dedupe; the rename removes the source
  -- file so a successful route can't be repeated. If route fails
  -- (e.g. recipient missing), we publish undeliverable once and
  -- leave the file in place; subsequent watcher fires will retry —
  -- that retry is intentional, it covers the "recipient registers
  -- later" recovery case.
  route_outbox(rec, mid)
end

---Central dispatcher invoked for every relevant fs_event.
---@param root string
---@param path string
local function on_event(root, path)
  -- Quick path: ignore tmp / dotfiles BEFORE we even classify.
  local base = path:match("([^/]+)$") or ""
  if base:sub(1, 1) == "." or base:sub(-5) ~= ".json" then return end
  if not debounce_check(path) then return end

  local rec, sub, mid = classify(root, path)
  if not rec then return end

  if sub == "inbox" then
    handle_inbox(rec, mid)
  elseif sub == "outbox" then
    handle_outbox(rec, mid)
  elseif sub == "responses" then
    handle_response(rec, mid)
  end
  -- processing / archive: no-op.
end

-- ── walk + watch ──────────────────────────────────────────

---@param dir string
---@return string[]
local function collect_dirs(dir)
  local out = {}
  if not fs_path.is_dir(dir) then return out end
  out[#out + 1] = dir
  local todo = { dir }
  while #todo > 0 do
    local cur = table.remove(todo)
    local sd = vim.uv.fs_scandir(cur)
    if sd then
      while true do
        local name, type_ = vim.uv.fs_scandir_next(sd)
        if not name then break end
        if type_ == "directory" then
          local sub = cur .. "/" .. name
          out[#out + 1] = sub
          todo[#todo + 1] = sub
        end
      end
    end
  end
  return out
end

---@param dir  string
---@param root string
---@return userdata?
local function watch_one_dir(dir, root)
  local handle = vim.uv.new_fs_event()
  if not handle then return nil end
  local ok = pcall(function()
    handle:start(dir, {}, function(uv_err, filename)
      if uv_err or not filename then return end
      local full = dir .. "/" .. filename
      vim.schedule(function() on_event(root, full) end)
    end)
  end)
  if not ok then
    pcall(handle.close, handle)
    return nil
  end
  return handle
end

---@param root string
local function open_root(root)
  if _state.roots[root] then return end
  local dirs = collect_dirs(root)
  local handles = {}
  local watched = {}
  -- mode 'poll' deliberately skips opening fs_event handles.
  if _state.cfg.mode ~= "poll" then
    for _, d in ipairs(dirs) do
      if #handles >= DEFAULT_MAX_HANDLES then break end
      local h = watch_one_dir(d, root)
      if h then
        handles[#handles + 1] = h
        watched[#watched + 1] = d
      end
    end
  end
  -- Poll-active when we couldn't (or chose not to) open any watcher
  -- for this root. In mode 'watch', this is a hard failure and the
  -- caller can see it via router.status().
  local poll_active = (#handles == 0 and _state.cfg.mode ~= "watch")
  _state.roots[root] = {
    root        = root,
    handles     = handles,
    watched     = watched,
    poll_active = poll_active,
  }
  -- Pre-seed seen sets for inbox/responses across every mailbox under
  -- this root, so existing files don't replay as new arrivals.
  for _, rec in ipairs(registry.records()) do
    if rec.root == root then
      for _, sub in ipairs({ "inbox", "responses" }) do
        local seen = seen_set(rec.subs[sub])
        for _, mid in ipairs(scan_ids(rec.subs[sub])) do
          seen[mid] = true
        end
      end
    end
  end
end

---@param root string
local function close_root(root)
  local entry = _state.roots[root]
  if not entry then return end
  for _, h in ipairs(entry.handles) do
    pcall(h.stop, h)
    pcall(h.close, h)
  end
  _state.roots[root] = nil
end

---Internal: returns true when at least one root needs the poll
---timer (either fs_event failed there OR mode='poll').
local function _any_root_polls()
  for _, entry in pairs(_state.roots) do
    if entry.poll_active then return true end
  end
  return false
end

---Internal: start/stop the global poll timer as needed.
local function _sync_poll_timer()
  local needs_poll = _any_root_polls()
  local interval   = _state.cfg.poll_interval_ms
  if needs_poll and interval and interval ~= false and interval > 0 then
    if _state.poll_timer then return end
    local timer = vim.uv.new_timer()
    if not timer then return end
    _state.poll_timer = timer
    timer:start(interval, interval, vim.schedule_wrap(function()
      if _state.running then M.scan_now() end
    end))
  else
    if _state.poll_timer then
      pcall(function()
        _state.poll_timer:stop()
        _state.poll_timer:close()
      end)
      _state.poll_timer = nil
    end
  end
end

-- ── public API ─────────────────────────────────────────────

---Start the router. Opens watchers for every currently-registered
---unique root. Idempotent — second call is a no-op (use `refresh`
---to pick up roots registered after start).
---
---When fs_event handles fail to open for any root (sandboxed env,
---fs that doesn't support inotify, etc.) AND the configured
---`poll_interval_ms` is non-zero, the router falls back to a
---uv-timer that calls `scan_now` periodically. The status flag is
---visible via `router.status()`.
function M.start()
  if _state.running then return end
  _state.running = true
  for _, root in ipairs(registry.unique_roots()) do
    open_root(root)
  end
  _sync_poll_timer()

  -- Optional stale-processing recovery sweep on startup. Any message
  -- in <mailbox>/processing/ older than the threshold gets the
  -- configured policy applied. Default is "fail" so a crashed
  -- previous session's claimed-but-not-completed messages get
  -- archived with a structured response rather than disappearing.
  if _state.cfg.stale_recover_on_start then
    local transport = require("auto-core.mailbox.transport")
    transport.recover_stale_all({
      threshold_ms = _state.cfg.stale_threshold_ms,
      policy       = _state.cfg.stale_policy,
    })
  end

  -- After opening every root, do an initial outbox sweep — any
  -- messages already sitting in outbox/ get routed immediately
  -- (the watcher only sees NEW writes, so pre-existing outbox
  -- files would otherwise hang indefinitely).
  for _, rec in ipairs(registry.records()) do
    for _, mid in ipairs(scan_ids(rec.subs.outbox)) do
      route_outbox(rec, mid)
    end
  end
end

---Re-scan the registry. Opens watchers for any newly-registered
---root and closes watchers for roots that no longer have a mailbox.
---Safe to call frequently; opening an already-open root is a no-op.
function M.refresh()
  if not _state.running then return end
  local active = {}
  for _, root in ipairs(registry.unique_roots()) do
    active[root] = true
    open_root(root)
  end
  for root in pairs(_state.roots) do
    if not active[root] then close_root(root) end
  end
  _sync_poll_timer()
end

---Stop the router. Closes every open watcher + the poll timer.
function M.stop()
  if not _state.running then return end
  for root in pairs(_state.roots) do close_root(root) end
  _state.roots = {}
  if _state.poll_timer then
    pcall(function()
      _state.poll_timer:stop()
      _state.poll_timer:close()
    end)
    _state.poll_timer = nil
  end
  _state.running = false
end

---@return boolean
function M.is_running() return _state.running end

---@return AutoCoreMailboxRouterState
function M.status()
  local root_summary = {}
  for r, entry in pairs(_state.roots) do
    root_summary[r] = {
      root        = r,
      handles     = #entry.handles,
      watched     = #entry.watched,
      poll_active = entry.poll_active == true,
    }
  end
  return {
    running          = _state.running,
    roots            = root_summary,
    mode             = _state.cfg.mode,
    poll_interval_ms = _state.cfg.poll_interval_ms,
    poll_running     = _state.poll_timer ~= nil,
  }
end

---Force a one-shot pass over every registered mailbox: scan outbox
---for routes, scan inbox/responses for new arrivals. Useful for
---tests that want to verify dispatch without waiting on fs_event
---latency, and for the rare case where a wake hook missed an event.
function M.scan_now()
  for _, rec in ipairs(registry.records()) do
    for _, mid in ipairs(scan_ids(rec.subs.outbox)) do
      route_outbox(rec, mid)
    end
    for _, mid in ipairs(scan_ids(rec.subs.inbox)) do
      handle_inbox(rec, mid)
    end
    for _, cor in ipairs(scan_ids(rec.subs.responses)) do
      handle_response(rec, cor)
    end
  end
end

---Test-only — stops the router and drops every internal table.
function M._reset_for_tests()
  M.stop()
  _state = {
    running    = false,
    roots      = {},
    seen       = {},
    debounce   = {},
    poll_timer = nil,
    cfg = {
      mode                    = "auto",
      poll_interval_ms        = DEFAULT_POLL_INTERVAL,
      stale_threshold_ms      = 5 * 60 * 1000,
      stale_policy            = "fail",
      stale_recover_on_start  = true,
    },
  }
end

return M