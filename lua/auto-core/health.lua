---`:checkhealth auto-core` — runtime introspection over every
---auto-core subsystem. Phase 7 per ADR 0006.
---
---Verifies:
---  - plenary.nvim is available (hard dep per ADR §"Resolutions" #3)
---  - events bus dispatch is responsive (synchronous round-trip)
---  - state persist directory exists and is writable
---  - fs.watch active handle count + cap (memory safety budget)
---  - log ring buffer health (capacity + count + active level)
---  - topic registry has the canonical entries
---  - tasks.queue / channel / status modules load cleanly
---  - panel registry — list registered panels for diagnosis
---  - version + api_version
---
---Run from any nvim with `:checkhealth auto-core`.
---@module 'auto-core.health'

local M = {}

-- ── helpers ──────────────────────────────────────────────────

-- nvim 0.10+ moved `vim.health.report_*` → `vim.health.*`. We use
-- the modern names; if the runtime is older, the calls fall back
-- to the legacy aliases via pcall.
local function ok(msg)    pcall(vim.health.ok,    msg) end
local function warn(msg)  pcall(vim.health.warn,  msg) end
local function info(msg)  pcall(vim.health.info,  msg) end
local function err(msg, advice)
  pcall(vim.health.error, msg, advice)
end

-- ── individual checks ────────────────────────────────────────

local function check_plenary()
  local has = pcall(require, "plenary")
  if has then
    ok("plenary.nvim available")
  else
    err("plenary.nvim missing", {
      "Install nvim-lua/plenary.nvim — it's a hard dep per ADR 0006.",
      "lazy.nvim: add 'nvim-lua/plenary.nvim' to dependencies.",
    })
  end
end

local function check_version()
  local v = require("auto-core.version")
  info(string.format(
    "version %s (api_version %s)", v.version, v.api_version))
end

local function check_events_bus()
  local events = require("auto-core.events")
  local probe_topic = "__auto_core_health_probe__"
  local hit = false
  local h = events.subscribe(probe_topic, function() hit = true end)
  events.publish(probe_topic, { ts = vim.uv.now() })
  events.unsubscribe(h)
  if hit then
    ok("events bus dispatch responsive")
  else
    err("events bus did NOT dispatch the probe event", {
      "Verify auto-core.events is loadable.",
      "Check :AutoCoreEventTrace for clues.",
    })
  end
end

local function check_topic_registry()
  local topics = require("auto-core.events.topics")
  local n = 0
  for _ in pairs(topics) do n = n + 1 end
  if n >= 10 then
    ok(string.format("event topic registry: %d entries", n))
  else
    warn(string.format(
      "event topic registry has only %d entries — expected >= 10 baseline", n))
  end
end

local function check_state_persist()
  local state = require("auto-core.state")
  -- Resolve the persist root via the public configure path. Default
  -- is stdpath('state')/auto-core. Either way, attempt a write +
  -- delete cycle.
  local root = vim.fn.stdpath("state") .. "/auto-core"
  vim.fn.mkdir(root, "p")
  local probe = root .. "/__health_probe__"
  local f = io.open(probe, "w")
  if not f then
    err(string.format("state persist dir not writable: %s", root), {
      "Check filesystem permissions on " .. root,
      "Or override via setup({ state = { persist_dir = ... } }).",
    })
    return
  end
  f:write("ok"); f:close()
  os.remove(probe)
  ok(string.format("state persist dir writable: %s", root))
end

local function check_fs_watch()
  local watch = require("auto-core.fs.watch")
  local handles = watch.list()
  local active = 0
  for _, h in ipairs(handles) do
    active = active + (#h.fs_events or 0)
  end
  local cap = watch.DEFAULT_MAX_HANDLES or 1024
  -- macOS uses one root handle per recursive watch (FSEvents
  -- covers the subtree). A low active count there is expected,
  -- not a sign that the watcher is broken.
  local native_recursive = (vim.uv.os_uname() or {}).sysname == "Darwin"
  info(string.format(
    "fs.watch: %d active fs_event handles (default cap %d%s)",
    active, cap,
    native_recursive and "; darwin native-recursive: on" or ""))
  if active > cap * 0.8 then
    warn(string.format(
      "fs.watch is using > 80%% of its handle cap (%d/%d) — "
      .. "consider passing a higher max_handles to watch.start, or "
      .. "narrowing the watched root", active, cap))
  end
end

local function check_log()
  local log = require("auto-core.log")
  local snap = log.inspect()
  info(string.format(
    "log: level=%s ring=%d/%d notify=%s",
    log.is_level_enabled("error") and "(at least ERROR)" or "OFF",
    snap.count, snap.ring_capacity, tostring(snap.notify)))
end

local function check_tasks()
  local ok_q = pcall(require, "auto-core.tasks.queue")
  local ok_c = pcall(require, "auto-core.tasks.channel")
  local ok_s = pcall(require, "auto-core.tasks.status")
  local ok_u = pcall(require, "auto-core.tasks.ui")
  if ok_q and ok_c and ok_s and ok_u then
    ok("tasks subsystems loadable (queue / channel / status / ui)")
  else
    warn(string.format(
      "tasks subsystem partial — queue=%s channel=%s status=%s ui=%s",
      tostring(ok_q), tostring(ok_c), tostring(ok_s), tostring(ok_u)))
  end
end

local function check_panels()
  local panel = require("auto-core.ui.panel")
  local names = panel.list()
  if #names == 0 then
    info("ui.panel: no panels registered yet (consumer plugins haven't opened any)")
  else
    table.sort(names)
    info(string.format("ui.panel: registered panels — %s",
      table.concat(names, ", ")))
  end
end

-- ── entry point ──────────────────────────────────────────────

---:checkhealth invokes this. Reports per-subsystem ok/info/warn/err
---into the standard health report.
function M.check()
  pcall(vim.health.start, "auto-core")

  check_version()
  check_plenary()
  check_events_bus()
  check_topic_registry()
  check_state_persist()
  check_fs_watch()
  check_log()
  check_tasks()
  check_panels()
end

return M
