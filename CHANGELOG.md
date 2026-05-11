# Changelog

All notable changes to `auto-core.nvim` are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com),
and from `v0.1.0` onward this project follows the
[`auto-core-maintenance`](https://github.com/yongjohnlee80/auto-agents)
convention's **additive-only minor-bump** rule: no `v0.X.Y` will ever
rename, remove, or break-shape an existing function, state-namespace
key, event topic, or persisted schema. Removals require a deprecation
cycle plus a major bump.

## [v0.1.3] — 2026-05-11 — debug.winlog probe + `:AutoCoreDebug winlog` command

Additive patch-line release. Adds an opt-in window/buffer lifecycle
logger for diagnosing panel-singleton violations, stray panel-buffer
hijacks, and splits made under `eventignore = "all"` / `noautocmd =
true` that bypass the `auto-core.ui.panel` leak guard. Productized
version of the ad-hoc probe used to track down the duplicate-auto-
agents-panel bug seen on terminal resize.

### Added

- `M.debug` namespace (Lua surface). First subsystem: `M.debug.winlog`.
- `M.debug.winlog.start(opts?)` / `stop()` / `toggle(opts?)` /
  `is_running()` / `status()` / `tail(n?)` / `clear()` / `path()`.
- `:AutoCoreDebug winlog [on|off|toggle|status|tail [N]|clear|path]`
  user command. Bare `:AutoCoreDebug winlog` toggles. `tail` opens a
  scratch buffer with the last N log lines.
- Probe pairs an autocmd set (`WinNew`, `WinClosed`, `BufWinEnter`,
  `WinEnter`, `VimResized`, `CmdlineLeave`) with a uv-timer poll
  (default 200ms, clamped to [50ms, 5000ms]) so windows created with
  `noautocmd = true` — invisible to the autocmd path — still get
  logged with full info: split/relative discriminator, panel marker,
  buffer-owner stamp, ft, buftype, dimensions, and the post-creation
  layout snapshot.
- Default log path `vim.fn.stdpath("cache")/auto-core-winlog.log` —
  per-machine, durable across nvim restarts, overridable via
  `opts.log_path`. Suitable for cross-machine workflows where you
  reproduce on one box and analyze on another.
- `opts.panel_filter` (default false): when true, the `BufWinEnter`
  / `WinEnter` handlers only log events involving buffers stamped
  with `b:auto_core_panel_owner` (set by `Panel:_stamp_buffer`).
  Quieter when you only care about panel-hijack arrivals.

### Version metadata

- `version` → `0.1.3` (additive patch line, consistent with v0.1.x
  cadence: every v0.1.Z so far has been additive, including the prior
  fixes at v0.1.1 and v0.1.2).
- `api_version` unchanged at `0.1`. New surface is feature-detected
  via `type(require("auto-core").debug) == "table"` (or
  `type(require("auto-core").debug.winlog) == "table"` for the probe
  specifically) — auto-core stays on the additive-only minor-bump
  rule per [[auto-core-maintenance]], so the soft branch is safe.

## [v0.1.2] — 2026-05-11 — winbar click router resolves panel via getmousepos

Bug fix. `auto-core.ui.winbar.click()` resolved the panel by
reading `w:auto_core_panel_name` of `nvim_get_current_win()`. Vim's
clickable-statusline contract says clicking a winbar region moves
focus to that window, but in practice the `@func@` callback often
fires while `nvim_get_current_win()` still reflects the editor
window the user was clicking from — the lookup fails, no router
is called, the click silently no-ops. Users saw winbar clicks
"work sometimes" because the timing was sensitive to mouse mode,
terminal multiplexer, and pending redraws.

### Fixed

- `M.click()` now prefers `vim.fn.getmousepos().winid` (the window
  directly UNDER the click) over `nvim_get_current_win()` for
  panel resolution. Falls back to `nvim_get_current_win()` for
  programmatic invocations (smoke tests / RPC probes) where no
  mouse event fired. No API or topic changes; existing consumers
  using `register_click_router` see the same surface — clicks
  just actually arrive now.

### Notes

This unblocks the auto-finder winbar (sections `0:config` /
`1:files` / `2:repos` clickable to focus). Auto-agents has its
own `panel/winbar.lua` with a direct click handler so it was
unaffected; the auto-core route is what auto-finder + future
consumers use. A separate follow-up could migrate auto-agents
onto the shared `auto-core.ui.winbar` for a single click path
across the family — additive, not required for this fix.

## [v0.1.1] — 2026-05-11 — workspace/active/agent_status no longer persist

Bug fix. The `core` namespace's `workspace_root`, `active_worktree`,
and `agent_status` keys were persisted to `~/.local/state/nvim/auto-core/core.json`
under `persist = "json"`. Two failure modes followed:

1. A `workspace_root` written during one session (e.g. `~/.config/nvim`
   while iterating on the plugin) survived restart. On every subsequent
   launch `worktree.nvim`'s `_ensure_root_now()` saw a non-nil
   `get_workspace_root()` and skipped its launch-cwd capture — so the
   workspace stayed pinned to the stale value forever, breaking
   `<leader>gA` / `<leader>gW` / repo discovery / the entire worktree
   feature surface regardless of where the user actually launched nvim.
2. Concurrent nvim instances clobbered each other's values through the
   shared `core.json` file (last-writer-wins).

### Changed

- `auto-core.git.worktree.{set,get}_workspace_root` and
  `{set,get}_active` now hold their value in module-local Lua state,
  per nvim process. Function signatures, return shapes, and the
  `core.workspace_root:changed` / `core.active_worktree:changed`
  events are unchanged.
- `auto-core.tasks.status.{set,get,list,clear}` likewise hold the
  agent map in module-local memory. The `agent.status:changed` event
  is unchanged.
- `core.json` no longer contains `workspace_root`, `active_worktree`,
  or `agent_status`. Other keys in the `core` namespace
  (`files.show_hidden`, `files.show_dotfiles`) continue to persist
  unchanged — those are global user preferences, not session state.

### Notes for consumers

No source-level migration is required. Subscribers of the
`core.workspace_root:changed` / `core.active_worktree:changed` /
`agent.status:changed` events keep working. Consumers that read
through `auto-core.git.worktree.get_workspace_root()` /
`auto-core.tasks.status.get()` also keep working.

Subscribers of the **state-namespace** flavor of these topics
(`state.core:workspace_root:changed`, `state.core:active_worktree:changed`,
`state.core:agent_status:changed`) no longer fire — but no consumer in
the AutoVim family used those (the explicit topics above were always
the canonical signal).

If your `~/.local/state/nvim/auto-core/core.json` still contains the
old keys, they are harmless dead bytes — the new code never reads
them. Auto-core overwrites the file with only the live keys on the
next `files.*` toggle.

## [v0.1.0] — 2026-05-11 — solid beta

First release under the additive-only stability contract. Bundles all
foundation work consumed by the AutoVim family migration (ADR 0007).
Consumers can pin via `version = "^0.1.0"` (caret) and trust the
surface forward.

### Added

- `auto-core.lsp.reset` — tech-stack-aware LSP restart driven by a
  marker table (`go.mod`, `package.json`, `Cargo.toml`, `pyproject.toml`,
  …). Publishes `core.lsp:reset` on start and finish.
- `auto-core.ui.float.multi` — multi-pane float primitive shaped like
  the absorbed gitsgraph dashboard: bg / left / middle / preview /
  footer panes, with `bind_pane_action_keys` for cross-pane navigation
  (`Tab`, `<C-h>`, `<C-l>`) and `q` / `<Esc>` close stamps.
- `auto-core.git.graph` — multi-repo discovery (`fan_out`),
  `show_stat`, and `show_diff` with topic-driven cache invalidation.
- `auto-core.git.fetch` — async `fetch_one` + `fetch_all` with
  bare-repo refspec back-fill. Publishes `core.git.fetch:started` /
  `core.git.fetch:completed`.
- `auto-core.git.pull` — `pull_status` + `pull_apply` +
  `worktree_dirty`, designed for the consultative round-trip pattern
  (auto-core stays silent; consumer probes status, prompts the user,
  retries with a force flag). Publishes `core.git.pull:started` /
  `core.git.pull:completed`.
- `auto-core.git.worktree.destroy(repo, wt, opts?, on_done?)` — same
  consultative round-trip; auto-core never prompts. Publishes
  `core.git.worktree:destroyed`.
- `auto-core.files` — global file-filter prefs (`show_hidden`,
  `show_dotfiles`) stored in `state.namespace("core")`. Consumed by
  both auto-finder and md-harpoon so toggles stay in sync across the
  family.
- New event topics registered in `events/topics.lua`: `core.lsp:reset`,
  `core.git.fetch:started`, `core.git.fetch:completed`,
  `core.git.pull:started`, `core.git.pull:completed`,
  `core.git.worktree:destroyed`, `doc:pinned`, `doc:unpinned`.

### Changed

- `state.namespace` now flushes every namespace synchronously on
  `VimLeavePre`, so debounced 100 ms persists no longer get dropped on
  `:qa`. Registered once at module load.

### Migration

- ADR 0007 — worktree.nvim absorbs the gitsgraph dashboard via
  `ui.float.multi` + `git.graph`; gitsgraph.nvim is archived.
- auto-finder.nvim → `v0.2.0`: state.namespace, ui.panel singleton,
  ui.section registry, logger shim. File-filter verbs write through to
  `auto-core.files`.
- worktree.nvim → `v0.2.0`: git delegated to auto-core, workspace_root
  through auto-core, `lsp.reset` on switch, `worktree:switched` event,
  absorbed `worktree.graph` dashboard.
- md-harpoon.nvim — per-project pin persistence keyed by
  `sha256(workspace_root):sub(1,16)`; resubscribes to
  `worktree:switched` and `core.file:modified`; reads
  `auto-core.files` for filter prefs.

### Deferred

- `gobugger.nvim` and `remote-sync.nvim` migrations are deferred to a
  later auto-core minor.

## [v0.0.10] — Phase 7

`log` + `health` (`:checkhealth auto-core`).

## [v0.0.9] — Phase 6

`ui.float` (`help_overlay`, `ghost`, `confirm`) + `ui.highlights`
registry.

## [v0.0.8] — Phase 5

Tasks: queue + channel + status + `:AutoCoreChannel`.

## [v0.0.7] — Phase 4c

`fs.tree` + canonical `git.worktree`.

## [v0.0.6] — Phase 4b

`fs.watch` + `git.status`.

## [v0.0.5] — Phase 4a

`fs.path` + `git.repo`.

## [v0.0.4] — Phase 3

UI primitives: `panel` + `winbar` + `section`.

## [v0.0.3] — Phase 2

Namespaced state store with `json` + `ephemeral` persist backends.

## [v0.0.2] — Phase 1

Pub/sub event bus.

## [v0.0.1] — Phase 0

Scaffold + smoke harness.
