# auto-core.nvim

Foundation library for the AutoVim plugin family — a publish/subscribe
event bus, namespaced state management, reusable UI primitives, fs/git
introspection, and an agent task-queue infrastructure.

`auto-core.nvim` is consumed by:

- [`auto-agents.nvim`](https://github.com/yongjohnlee80/auto-agents) — multi-agent orchestration
- [`auto-finder.nvim`](https://github.com/yongjohnlee80/auto-finder.nvim) — multi-resource panel
- [`md-harpoon.nvim`](https://github.com/yongjohnlee80/md-harpoon.nvim) — document pinning
- [`worktree.nvim`](https://github.com/yongjohnlee80/worktree.nvim) — multi-repo workspace
- [`gitsgraph.nvim`](https://github.com/yongjohnlee80/gitsgraph.nvim) — cross-worktree commit graph
- [`remote-sync.nvim`](https://github.com/yongjohnlee80/remote-sync.nvim) — LAN-to-VPS deploy
- [`gobugger.nvim`](https://github.com/yongjohnlee80/gobugger.nvim) — Go debugger

`auto-core.nvim` itself depends only on Neovim ≥ 0.10 and
[`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim).

## Status

**Pre-1.0 (`v0.0.x`).** Surface is unstable; pin via exact version
during the iteration phases. The first stable line opens at `v0.1.0`
(end of Phase 2 — events + state + first consumer migration). API
freezes at `v1.0.0`.

| Phase | Subsystem | Ship as |
|-------|-----------|---------|
| 0     | Scaffold + smoke harness | `v0.0.1` ← here |
| 1     | Pub/sub event bus | `v0.0.x` |
| 2     | Namespaced state management + first consumer migration (auto-agents) | `v0.1.0` |
| 3     | UI primitives (panel + winbar + section) | `v0.2.0` |
| 4     | fs.watch + git.worktree (canonical worktree implementation) | `v0.3.0` |
| 5     | Agent task queue + channel | `v0.4.0` |
| 6     | Float helpers | `v0.5.0` |
| 7     | Logger + health | `v0.6.0` |
| 8     | Family-wide cleanup | `v0.7.0` |
| 9     | API freeze | `v1.0.0` |

See ADR 0006 in the project's auto-agents kb for the full
architecture and migration plan.

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
