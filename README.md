# auto-core.nvim

Foundation library for the AutoVim plugin family — a publish/subscribe
event bus, namespaced state management, reusable UI primitives, fs/git
introspection, and an agent task-queue infrastructure.

`auto-core.nvim` is consumed by:

- [`auto-agents.nvim`](https://github.com/yongjohnlee80/auto-agents) — multi-agent orchestration
- [`auto-finder.nvim`](https://github.com/yongjohnlee80/auto-finder.nvim) — multi-resource panel
- [`md-harpoon.nvim`](https://github.com/yongjohnlee80/md-harpoon.nvim) — document pinning
- [`worktree.nvim`](https://github.com/yongjohnlee80/worktree.nvim) — multi-repo workspace
- [`worktree.nvim`](https://github.com/yongjohnlee80/worktree.nvim) — multi-repo workspace + absorbed graph dashboard (replaces gitsgraph.nvim)
- [`remote-sync.nvim`](https://github.com/yongjohnlee80/remote-sync.nvim) — LAN-to-VPS deploy *(migration deferred to a later auto-core minor)*
- [`gobugger.nvim`](https://github.com/yongjohnlee80/gobugger.nvim) — Go debugger *(migration deferred to a later auto-core minor)*

`auto-core.nvim` itself depends only on Neovim ≥ 0.10 and
[`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim).

## Status

**`v0.1.0` — solid beta (2026-05-11).** First release covered by the
**additive-only minor-bump** stability rule: every `v0.X.Y` from
here forward will never rename, remove, or break-shape an existing
function, state-namespace key, event topic, or persisted schema.
Removals require deprecation + a major bump. See the
[`auto-core-maintenance` convention](https://github.com/yongjohnlee80/auto-agents)
in the auto-agents kb for the full eleven-rule contract.

| Phase / Surface | Ship as |
|---|---|
| Phase 0 — scaffold + smoke | `v0.0.1` |
| Phase 1 — pub/sub event bus | `v0.0.2` |
| Phase 2 — namespaced state | `v0.0.3` |
| Phase 3 — UI primitives (panel/winbar/section) | `v0.0.4` |
| Phase 4a — `fs.path` + `git.repo` | `v0.0.5` |
| Phase 4b — `fs.watch` + `git.status` | `v0.0.6` |
| Phase 4c — `fs.tree` + canonical `git.worktree` | `v0.0.7` |
| Phase 5 — tasks queue + channel + status + `:AutoCoreChannel` | `v0.0.8` |
| Phase 6 — `ui.float` (help_overlay/confirm) + `ui.highlights` | `v0.0.9` |
| Phase 7 — `log` + `health` (`:checkhealth auto-core`) | `v0.0.10` |
| **v0.1.0 bundle** — `lsp.reset` (tech-stack-aware) + `ui.float.multi` (gitsgraph-shaped multi-pane) + `git.graph` (multi-repo discovery + commit caches) + `git.fetch` + `git.pull` + `git.worktree.destroy` (consultative round-trip) + `files` (global file-filter prefs) + `state.namespace` `VimLeavePre` flush + `doc:pinned`/`doc:unpinned` topics | **`v0.1.0` ← here** |
| Family cleanup + post-1.0 prep | `v0.X.0` minors (additive only) |
| API freeze | `v1.0.0` |

See [ADR 0006](https://github.com/yongjohnlee80/auto-agents) in the
auto-agents kb for the full architecture, [ADR 0007](https://github.com/yongjohnlee80/auto-agents)
for the migration that drove v0.1.0, and the
[`auto-core-maintenance`](https://github.com/yongjohnlee80/auto-agents)
convention for the contract every release honors going forward.

## Install

```lua
-- lazy.nvim, as a dependency of any AutoVim family plugin:
{
  "yongjohnlee80/auto-finder.nvim",
  dependencies = {
    "yongjohnlee80/auto-core.nvim",  -- foundation
    "nvim-lua/plenary.nvim",
    -- ...
  },
}
```

`auto-core.nvim` is rarely installed directly — your AutoVim family
plugins pull it in.

## Usage (consumer plugins)

```lua
local core = require("auto-core")

-- Phase 0: only setup() is wired. Subsystems light up in subsequent phases.
core.setup({
  events = { fire_autocmds = false },  -- opt-in :autocmd User AutoCore<topic> shim
  log    = { level = "info" },
})
```

Once Phase 1 lands:

```lua
local h = core.events.subscribe("worktree:switched", function(payload)
  -- payload.from, payload.to, payload.cwd
end)
core.events.publish("file:modified", { path = "/foo/bar.lua", buf = 12 })
```

Once Phase 2 lands:

```lua
local s = core.state.namespace("auto-finder", {
  defaults = { panel = { user_width = nil, last_section = 1 } },
  persist  = "json",
})
s:set("panel.user_width", 42)  -- publishes state.auto-finder:panel.user_width:changed
local w = s:watch("panel.user_width", function(new, old) ... end)
```

## Logging — the family contract (ADR 0021 / v0.1.11+)

`auto-core.log` is the single ring for the entire AutoVim family.
Every plugin's emissions land here; users inspect, filter, and
route notifications from one place. Three rules govern adoption:

### 1. Wrapper rule — each plugin owns one `lua/<plugin>/log.lua`

Feature code in a consumer plugin calls **its own wrapper module**,
never `require("auto-core").log` directly. The wrapper:

- Auto-prefixes `component` and `event_type` with the plugin's
  namespace (`"scan"` → `"auto-finder.scan"`).
- Exposes `notify` / `notifyIf` / `register_events` as thin
  pass-throughs to auto-core.
- Soft-deps the new surface so the plugin keeps working on an
  older auto-core that lacks Phase 1 — degraded to a ring-only
  fallback, no crash.

Skeleton (per ADR 0021 §6):

```lua
-- lua/auto-finder/log.lua
local core_log = require("auto-core").log
local NS = "auto-finder"
local M = { levels = core_log.levels }

local function ns(c)
  if type(c) ~= "string" or c == "" then return NS end
  if c == NS or c:sub(1, #NS + 1) == NS .. "." then return c end
  return NS .. "." .. c
end

function M.error(c, ...) core_log.error(ns(c), ...) end
function M.warn (c, ...) core_log.warn (ns(c), ...) end
function M.info (c, ...) core_log.info (ns(c), ...) end
function M.debug(c, ...) core_log.debug(ns(c), ...) end
function M.trace(c, ...) core_log.trace(ns(c), ...) end

function M.notify(msg, opts)
  opts = opts or {}
  if opts.component then opts.component = ns(opts.component) end
  if type(core_log.notify) ~= "function" then        -- soft-dep
    return M.info(opts.component, msg)
  end
  return core_log.notify(msg, opts)
end

function M.notifyIf(event, msg, opts)
  opts = opts or {}
  if opts.component then opts.component = ns(opts.component) end
  local fq = (event == NS or event:sub(1, #NS + 1) == NS .. ".")
    and event or (NS .. "." .. event)
  if type(core_log.notifyIf) ~= "function" then      -- soft-dep
    return M.info(opts.component, msg)
  end
  return core_log.notifyIf(fq, msg, opts)
end

function M.register_events(events)
  if type(core_log.events) ~= "table"
      or type(core_log.events.register) ~= "function" then
    return                                            -- soft-dep
  end
  return core_log.events.register(NS, events)
end

return M
```

### 2. No bare `vim.notify`

Use `log.notify` or `log.notifyIf` so every toast also lands in
the ring. Direct `vim.notify` leaves no trail and silently breaks
`:AutoCoreLog` triage. Enforce at PR review:

```bash
grep -rnE 'vim\.notify' lua/ | grep -v 'lua/<plugin>/log\.lua'
```

Exempt cases (rare): pre-`setup()` bootstrap toasts that must
survive auto-core not being loaded.

### 3. Register events at setup; user controls toasts

Plugins declare their event types in `M.setup()`:

```lua
require("auto-finder.log").register_events({
  "scan.started",
  "scan.completed.slow",
  "panel.section.switched",
})
```

Users toggle notification per event:

```vim
:AutoCoreLogEvent list                              " show all registered + subscription state
:AutoCoreLogEvent notify auto-finder.scan.completed.slow
:AutoCoreLogEvent silence auto-finder.scan.completed.slow
```

The subscription set persists via `auto-core.state.namespace(
"auto-core.log.events")` — survives `:qa`.

### Hot-loop guard

Logging inside a per-entry loop MUST use the throttled variant or
have a written exemption in the PR description:

```lua
log.info_throttled("scan-progress", 250, "scan", "found", path)
```

`every_ms` is the window per `key`. Stable keys (per-call-site or
per-resource within a bounded set) keep the throttle map bounded.

### What auto-core provides

```lua
local log = require("auto-core").log

-- v0.1.0 base surface
log.error(component?, ...) / .warn / .info / .debug / .trace
log.is_level_enabled(name)         -- "debug" → boolean
log.recent(n?)                     -- AutoCoreLogEntry[]
log.clear()
log.configure({ level?, ring_capacity?, notify? })
log.namespace(component)           -- pre-bound handle
log.inspect()                      -- config snapshot
log.levels                         -- { ERROR=1, WARN=2, INFO=3, DEBUG=4, TRACE=5 }

-- v0.1.11 additions (ADR 0021 Phase 1)
log.notify(msg, opts?)             -- force toast + ring
log.notifyIf(event, msg, opts?)    -- ring + gated toast
log.error_throttled(key, every_ms, component?, ...)
log.warn_throttled  (...)
log.info_throttled  (...)
log.debug_throttled (...)
log.trace_throttled (...)
log.events.register(plugin, events)
log.events.list(plugin?)           -- → { { event, plugin }, ... }
log.events.enable_notify(event)
log.events.disable_notify(event)
log.events.is_notify_enabled(event)
```

Ring: 500 entries default, configurable, in-memory, FIFO eviction.
Filtered by level BEFORE write — DEBUG/TRACE at default INFO level
never reach the ring.

See the binding [`auto-family-logging`](https://github.com/yongjohnlee80/auto-agents)
convention page in the auto-agents kb for the full enforcement
contract (PR-review checklist, detection grep recipes, exemption
rules).

## Hard rules

1. **`auto-core` never `require`s a family plugin.** Dependency
   direction is one-way: `auto-core ← consumers`.
2. **Family plugins NEVER call each other directly.** All
   cross-plugin signaling goes through `auto-core.events` and
   `auto-core.state`.
3. **Topic names are part of the API.** Renaming a topic requires
   the same deprecation cycle as renaming a function (≥ 1 minor
   release with both names live + a warning on use of the old).
4. **Smoke tests every iteration.** Per the
   `lua-nvim-plugin-development` convention in the project's
   auto-agents kb: `tests/smoke.lua` extends every iteration; the
   suite runs green headless before any commit is reported done.
5. **No bare `vim.notify` in family plugins.** Route through
   `lua/<plugin>/log.lua` so every toast lands in the ring (rule
   1 of the [`auto-family-logging`](https://github.com/yongjohnlee80/auto-agents)
   convention).

## License

MIT. See [LICENSE](./LICENSE).

Copyright (c) 2026 Yong Sung John Lee
