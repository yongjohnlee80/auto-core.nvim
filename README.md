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

**`v0.2.x` — solid beta.** `v0.1.0` (2026-05-11) was the first release
covered by the **additive-only minor-bump** stability rule: every
`v0.X.Y` from there forward will never rename, remove, or break-shape an
existing function, state-namespace key, event topic, or persisted schema.
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
| **v0.1.0 bundle** — `lsp.reset` (tech-stack-aware) + `ui.float.multi` (gitsgraph-shaped multi-pane) + `git.graph` (multi-repo discovery + commit caches) + `git.fetch` + `git.pull` + `git.worktree.destroy` (consultative round-trip) + `files` (global file-filter prefs) + `state.namespace` `VimLeavePre` flush + `doc:pinned`/`doc:unpinned` topics | `v0.1.0` |
| `ui.grid` — reusable tabular result model + window-owning view (ADR 0058, autodb M7) | `v0.1.64` |
| `git.log` + `git.diff` + `ui.marks` + `ui.diffview` | `v0.2.0` |
| `ui.edit.open` + the `editor.open` mailbox verb — open a file from outside the layout | **`v0.2.x` ← here** |
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

## `ui.grid` — tabular results (ADR 0058)

A reusable result grid: SQL rows today, any tabular data tomorrow. It is
split into a **pure model** and a **window-owning view**, so every data
rule is testable without a window, a server or a database.

```lua
local grid = require("auto-core").ui.grid

local model = grid.model({
  columns = { { name = "id", type = "integer" }, "title" },
  rows    = { { 1, "alpha" }, { 2, vim.NIL } },   -- RAW values
})

model:cell(r, c)   --> { value = <raw>, text = <display>, null, binary }
model:row(r)       --> raw values
model:csv(r)       --> one RFC-4180 record
model:json(r)      --> one object, duplicate column names disambiguated
model:json_all()   --> { columns = [...], rows = [...] }, positional

local view = grid.attach(model, { win = winid })   -- header = "line" for headless
view:cell()  view:move_cell(dr, dc)  view:yank_row("csv"|"json")
view:yank_cell()  view:toggle_view()  view:set_model(m)  view:dispose()
```

The model keeps **raw values and display text separately**, because they
are not interchangeable: a yank must reproduce what the source returned,
embedded newlines and all, while the grid on screen stays one line per
row. Keeping only the rendered string loses data the moment a value
contains a comma, a quote or a newline.

| Case | Displayed | CSV | JSON |
|---|---|---|---|
| `vim.NIL` / missing | the null text (default `NULL`) | **empty field** | `null` |
| non-UTF-8 bytes | `0x…` hex | `0x…` | `0x…` (never invalid UTF-8) |
| embedded newline | `␤` (row stays one line) | real newline, quoted | real newline |
| duplicate column names | both shown | both | `name`, `name#2` in object form; positional in `json_all` |

Widths and truncation are measured in **display cells** via
`strdisplaywidth`, never bytes, so CJK and other wide glyphs align.

The view derives the current cell from the **real cursor** instead of
trapping motions, so every native motion, search and count keeps working
while selection stays cell-wise. It owns its own buffer, restores the
window's prior buffer and options on `dispose`, and freezes the header in
the window-local `winbar` — clipped to the window's `leftcol` and
refreshed on `WinScrolled`, since a winbar does not scroll with the text.

> Header rendering has one supported composition, `grid.render_header(raw,
> leftcol)`: **clip first, escape second.** A winbar is evaluated as a
> statusline, and escaping before clipping adds a cell per literal `%`,
> which shifts every label after it and can leave a live statusline item.

`WinScrolled` does not fire in a headless Neovim, so that wiring is
covered by `tests/ui/run.sh` (a real pty) rather than `tests/smoke.lua`.

## `ui.edit` — opening a file from outside the layout

`auto-core.ui.panel` sets `winfixbuf = true` on every panel it creates
(see **Known integrations** below for why). That protection has a cost
for anything driving Neovim from the outside — an agent, a remote call,
a hook:

```
nvim --server $NVIM --remote-silent <file>
-> E1513: Cannot switch buffer. 'winfixbuf' is enabled
```

`ui.edit.open` is the sanctioned way to do it. It finds a window that
can actually take a file, opens the buffer there, positions the cursor,
and reports where the file went.

```lua
local res, err = require("auto-core").ui.edit.open("/abs/path/file.lua", {
  line  = 42,     -- 1-based, optional
  col   = 7,      -- 1-based, optional
  focus = false,  -- default: do NOT move the cursor there
})
-- res = {
--   win, buf, path,
--   line, col,                  -- where the cursor ACTUALLY is
--   created_window,             -- true when nothing usable existed
--   panel_windows_skipped,      -- how many panels were passed over
-- }
```

**Four properties are part of the contract, not implementation detail:**

1. **`line` and `col` are both 1-based.** Neovim is inconsistent here —
   `nvim_win_set_cursor` takes a 1-based line and a **0-based** column —
   and a public API that inherits that inconsistency arrives later as an
   off-by-one bug report. The conversion happens inside. Non-integers are
   refused rather than truncated.
2. **The returned `line`/`col` are read back off the window**, not echoed
   from `opts`. A request past the end of the file is clamped, and the
   result tells you where the cursor landed — so a caller reporting "opened
   at 42:7" is never reporting a position that does not exist.
3. **Focus is not stolen.** An agent moving the cursor while somebody is
   typing is exactly the hijack `winfixbuf` exists to prevent, so `focus`
   defaults to `false`: the file is opened and positioned, and the caller's
   window keeps the cursor. Pass `focus = true` to jump.
4. **The path must be absolute.** A relative path is refused with an error
   rather than resolved — an agent's cwd is not the user's, so a relative
   path would resolve against whichever the host happens to have.

A window qualifies as usable when it is not a panel, not floating, has
`buftype == ""`, and does not have `winfixbuf`. In one measured session
there were ~50 windows and exactly **one** could take a file, which is why
`panel_windows_skipped` is reported: an agent that cannot tell where the
file went cannot report it.

When nothing usable exists, a split is created with
`nvim_open_win(buf, false, { split = "below", win = anchor })`. The Ex-command
form (`botright new`, `topleft split <file>`) is deliberately **not** used:
a panel's autocmds intercept it, and the observed outcome is `ok = true`,
window count unchanged, and the panel's own buffer replaced by the file.
`nvim_open_win` is not interceptable, so success means a window.

### The `editor.open` mailbox verb

The same surface is registered on auto-core's command registry at
`setup()`, so anything speaking the mailbox protocol can use it. The
fields that matter (a real message also carries `id` / `from` / `to`):

```json
{ "kind": "command", "command": "editor.open",
  "args": { "path": "/abs/path/file.lua", "line": 42, "col": 7 } }
```

```
schema: { path = "string", line = "integer?", col = "integer?", focus = "boolean?" }
```

Only `path` is required; the `?` suffix marks a field optional, and the
schema is validated **before** the handler runs, so a bad call comes back
as `bad_args` rather than a Lua error.

**This verb lives in auto-core alone — there is no matching change in
auto-agents.** auto-core owns the whole surface an agent talks to: the
registry is `auto-core.mailbox.commands`, dispatch is
`auto-core.mailbox.router` calling `commands.handle_message`, and discovery
is auto-agents' `commands_list`, whose handler is a **relay** — it calls
`commands.list()` and forwards the entries, schema included. A verb
registered here is therefore discovered and dispatched with no auto-agents
change at all. Registering it in both places would be a second implementation
of the window logic, which is the thing this module exists to prevent.

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
   auto-agents kb, `tests/smoke.lua` extends every iteration and runs
   green headless — `nvim --headless -u NONE -l tests/smoke.lua` (NOT
   `-c 'qa!'`: under `-l` a mid-run abort exits non-zero instead of
   silently green) — before any commit is reported done. The full
   gate is `tests/run-all.sh`, which runs the smoke suite behind a
   summary-presence / crash-before-assertions guard, the UI-attached
   pty suite (`tests/ui/`, watchdog-guarded), and the `rpc.frame`
   scaling bench.
5. **No bare `vim.notify` in family plugins.** Route through
   `lua/<plugin>/log.lua` so every toast lands in the ring (rule
   1 of the [`auto-family-logging`](https://github.com/yongjohnlee80/auto-agents)
   convention).

## Known integrations — snacks.picker + `winfixbuf` panels

`auto-core.ui.panel` sets `winfixbuf = true` on every panel window it
creates. That protection is intentional — it stops generic `:buffer`
/ `:edit` / bufferline / picker actions from replacing the panel's
contents from underneath the consumer.

The trade-off is that any picker which dispatches a jump via
`:buffer <bufnr>` in the **currently focused window** will raise
`E1513: Cannot switch buffer. 'winfixbuf' is enabled` when focus
happens to be on a panel — or when the picker's internal "main
window" selection lands on a panel (e.g. snacks.picker's
`core/main.lua` filters by `buftype` but **not** by `winfixbuf`, so an
auto-core admin/scratch panel slot passes the filter and gets picked
as `picker.main`; `picker:close()` then restores focus there before
the buffer load).

If you use [snacks.nvim](https://github.com/folke/snacks.nvim)'s
picker alongside auto-core panels, drop the following plugin spec
somewhere in your config to defensively retarget `:buffer` away from
`winfixbuf` windows. It monkey-patches
`snacks.picker.actions.jump` at the module level — the only override
point that survives snacks' string-resolved `confirm = "jump"`
dispatch path *and* the insert-mode reschedule at `actions.lua:42`:

```lua
-- lua/plugins/snacks-picker-winfixbuf.lua
return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      local function find_non_winfixbuf_win()
        local wins = vim.api.nvim_list_wins()
        for i = #wins, 1, -1 do
          local w = wins[i]
          local cfg_ok, cfg = pcall(vim.api.nvim_win_get_config, w)
          if cfg_ok and cfg.relative == "" then
            local ok, wfb = pcall(function() return vim.wo[w].winfixbuf end)
            if ok and not wfb then return w end
          end
        end
        return nil
      end

      local function ensure_picker_main_safe(picker)
        if not (picker and picker.main and vim.api.nvim_win_is_valid(picker.main)) then return end
        local ok, wfb = pcall(function() return vim.wo[picker.main].winfixbuf end)
        if not (ok and wfb) then return end
        local target = find_non_winfixbuf_win()
        if target then
          picker.main = target
        else
          vim.cmd("aboveleft new")
          picker.main = vim.api.nvim_get_current_win()
        end
      end

      local snacks_actions = require("snacks.picker.actions")
      local original_jump = snacks_actions.jump
      if not snacks_actions.__wfb_wrapped then
        snacks_actions.__wfb_wrapped = true
        snacks_actions.jump = function(picker, item, action)
          ensure_picker_main_safe(picker)
          return original_jump(picker, item, action)
        end
      end
    end,
  },
}
```

The same pattern applies to any other current-window opener
(bufferline tab-click handlers, custom `:edit` keymaps, etc.) — wrap
or retarget before letting the default action fire. A reference
implementation lives in
[autovim](https://github.com/yongjohnlee80/autovim)'s
`lua/plugins/snacks-picker-winfixbuf.lua`.

This is tracked as **ADR 0027** in the auto-agents knowledge base.

## Continuous integration

`.github/workflows/ci.yml` runs one job, `lua`, on **every push to `main`
and every pull request**. It installs the toolchain and then hands the
verdict to `tests/run-all.sh` — CI does not reimplement the gate, it
supplies the environment and lets the runner be the judge.

| Pinned by | What | Why |
|---|---|---|
| commit SHA | `actions/checkout` | a tag can be moved to different code under the same name |
| version **and SHA-256** | Neovim (`v0.12.5`) | a release asset can be replaced under the same tag and name, so the version alone is not reproducible |
| commit SHA | `plenary.nvim` | the only plugin dependency the suites need |

A step named **`assert the toolchain matches the pin`** compares the
running Neovim against the pinned version and fails on a mismatch. It is
called *assert*, not *verify*, because it can fail: a step that only prints
a version is present-and-blind, and converts "nobody checked" into
"checked and fine".

**`tests/run-all.sh` is the whole gate.** It runs the smoke suite, the
standalone suites, the UI-attached pty suite and the `rpc.frame` bench, and
it treats a **missing** `N passed, M failed` summary line as a hard failure
rather than parsing whatever partial PASS lines a suite emitted. That
sentinel is the only thing that catches a C-level crash mid-run, which is
why running a single suite by hand is not a substitute. On failure the
workflow tails the pty runner's transcript into the log — locally you open
`tests/ui/.<name>.log`, but in CI the runner is gone and cannot be
reproduced, so the gate's likeliest failure would otherwise arrive with no
evidence attached.

### Why the workflow attaches HEAD

`actions/checkout` leaves a **detached HEAD with no local branches** on a
`pull_request` event, and auto-core's own suites read its refs —
`git.worktree.default_branch()` runs `git symbolic-ref --short HEAD`. So the
workflow attaches HEAD (`git checkout -B ci-head`) and names the default
branch before the suites run, with `fetch-depth: 0`.

The obvious shortcut is wrong and worth recording. `git branch --force main
origin/main` **alone** makes the branch assertions pass for the wrong
reason: on a detached HEAD `symbolic-ref` fails and `default_branch()`
returns its literal fallback string `"main"`, so creating a branch of that
name reduces the assertion to "the workflow created a branch called main" —
a test of the workflow, by the workflow. Attaching HEAD is what makes those
cells pass for the same reason they pass on a developer machine. The order
is load-bearing too: on a `push` event `actions/checkout` does *not* detach,
so creating the branch first fails with `cannot force update the branch
'main' used by worktree`.

### auto-core has no `drift` job — its consumers do

Every other family repo's workflow carries a second job, `drift`, that
resolves **auto-core at its default branch** instead of the commit its
gating job pins. auto-core is the dependency, so it has nothing to drift
against; the reason the consumers need it is that a regression here reaches
them before anyone notices, and a consumer pinned to a frozen auto-core is
precisely the thing that cannot notice.

Practical consequence when landing a change here: a consumer's `lua` job
stays green because it pins, and its `drift` job is what goes red. Those
run on a schedule (Mondays, 06:00 UTC) and on manual dispatch — **not** on
push — so a breaking change on `main` here is not visible in the consumers'
PR checks. If a change is expected to need consumer updates, dispatch the
consumers' `drift` jobs rather than waiting for Monday.

## License

MIT. See [LICENSE](./LICENSE).

Copyright (c) 2026 Yong Sung John Lee
