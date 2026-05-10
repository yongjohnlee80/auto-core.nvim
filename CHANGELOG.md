# Changelog

All notable changes to `auto-core.nvim` are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com),
and from `v0.1.0` onward this project follows the
[`auto-core-maintenance`](https://github.com/yongjohnlee80/auto-agents)
convention's **additive-only minor-bump** rule: no `v0.X.Y` will ever
rename, remove, or break-shape an existing function, state-namespace
key, event topic, or persisted schema. Removals require a deprecation
cycle plus a major bump.

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
