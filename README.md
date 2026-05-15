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

## License

MIT. See [LICENSE](./LICENSE).

Copyright (c) 2026 Yong Sung John Lee
