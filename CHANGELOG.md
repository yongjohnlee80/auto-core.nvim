# Changelog

All notable changes to `auto-core.nvim` are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com),
and from `v0.1.0` onward this project follows the
[`auto-core-maintenance`](https://github.com/yongjohnlee80/auto-agents)
convention's **additive-only minor-bump** rule: no `v0.X.Y` will ever
rename, remove, or break-shape an existing function, state-namespace
key, event topic, or persisted schema. Removals require a deprecation
cycle plus a major bump.

## [v0.1.5] — 2026-05-14 — mailbox subsystem: durable file-backed transport + router + executioner (ADR 0013 phase 1)

Additive patch-line release. Adds `auto-core.mailbox` — a
sandbox-friendly, file-backed cross-process transport that lets
sandboxed CLI agents (Claude / Codex / Gemini / …) coordinate with
each other and with Neovim through atomic JSON writes to per-tool-
config-dir mailboxes. Implements ADR 0013 phase 1 in full.

### Why

Sandboxed agents can't reach Neovim via socket, loopback HTTP, or
RPC. They CAN read/write their own `~/.<tool>/` config dir. Mailbox
data therefore lives at `<tool-root>/mailbox/<id>/` where it's
sandbox-allowed without permission prompts.

### Added — public surface

- `M.mailbox` namespace with submodules: `path`, `message`,
  `registry`, `transport`, `commands`, `router`, `bootstrap`, `ui`.
- `M.mailbox.configure({ root, autostart, mode, poll_interval_ms,
  stale_threshold_ms, stale_policy, stale_recover_on_start })`
  forwarded through to path / router subsystems.
- `M.mailbox.path.tool_root(tool)` for agent-backed mailboxes
  (`claude`/`gemini`/`codex` and extensible via `path.TOOL_DIRS`).
- `M.mailbox.path.host_fallback_root()` for non-sandboxed actors
  (`nvim`, `user`) — resolves `$AUTO_AGENTS_MAILBOX_ROOT` →
  `$AUTO_AGENTS_CONFIG_DIR/mailbox` →
  `dirname($AUTO_AGENTS_KB_ROOT)/mailbox` →
  `~/.config/nvim/.auto-agents-config/mailbox`.
- `M.mailbox.register(id, { root, wake, executioner })` ensures
  the canonical 5-subdir layout and upserts the bootstrap doc.
- `M.mailbox.send/claim/complete/fail` for state transitions, with
  durable claim stamps (`claimed_at`, `claimed_at_unix`,
  `claimed_by`, `attempt`).
- `M.mailbox.recover_stale(mailbox, opts)` and `recover_stale_all`
  for processing recovery (policies: `'fail'` default, `'requeue'`).
- `M.mailbox.start/stop/refresh/scan_now/is_running`.
- `M.mailbox.commands.register/get/list/unregister/handle_message/
  reject_unknown/validate_args` — whitelisted dispatch with schema
  validation. Schemas accept `string | integer | number | boolean |
  table | function | any` with `?` for optional fields. Failures
  produce structured `{ ok=false, code, field, error }` rejections;
  raw Lua/Vimscript/shell/RPC strings are NEVER executed.
- `:AutoCoreMailbox [open|close|toggle|refresh]` — three-pane
  viewer on `auto-core.ui.float.multi` (owner-tree | messages
  newest-first with state icons | preview). Backlog indicator
  `⚠ inbox=N` per ADR §2 observability.
- `:AutoCoreDebug mailbox status | tail [N] | registry | follow
  [on|off|toggle] | clear` — read-only probe filtering the event
  trace to mailbox/command topics with payload-aware pretty
  printing.

### Added — bootstrap doc contract (ADR §9 anchor)

- `<mailbox-dir>/bootstrap-mailbox.md` rewritten from a versioned
  template on every `register()`. Frontmatter carries
  `revision: <sha256-of-rendered-body>`.
- Doc body instructs agents to audit the revision on every wake,
  distill the protocol into durable agent memory on FIRST read,
  and refresh that memory whenever the revision changes.
- Documents the Codex `writable_roots` sandbox requirement so
  codex-backed agents can add their mailbox dir to
  `~/.codex/config.toml`.

### Added — central router (ADR §3)

- One logical walk-and-watch per UNIQUE registered root. Multi-
  agent-per-tool collapses cleanly (`agent:jarvis` +
  `agent:hephaestus` under `~/.claude/mailbox/` → one watcher).
- libuv `fs_event` + walk-and-watch for the Linux recursion gap.
- Path classifier dispatches:
  - `outbox/`    → atomic rename to recipient inbox (`core.mailbox:
                   outbox_routed` / `outbox_undeliverable`).
  - `inbox/`     → `core.mailbox:message_queued` + executioner OR
                   wake hook.
  - `responses/` → `core.mailbox:response_received` + wake hook.
- Polling fallback: `mode = 'auto'|'watch'|'poll'`,
  `poll_interval_ms` (default 1000, `false` disables). Per-root
  `poll_active` flag surfaced via `router.status()`.

### Added — default `nvim` executioner (ADR §4)

- `register('nvim')` defaults `executioner = true`. When a
  `kind="command"` message lands in an executioner mailbox's inbox,
  the router auto-claims (`claimed_by='nvim-executioner'`),
  dispatches via `commands.handle_message`, and `transport.complete`
  writes the response envelope back to the sender's
  `responses/<correlation_id>.json` so blocking pollers unblock.
- Unknown / bad-args commands produce structured rejection
  envelopes through the same path.

### Added — event topics (all additive, public)

- `core.mailbox:registered / outbox_routed / outbox_undeliverable /
  message_queued / message_claimed / message_completed /
  message_failed / response_received / response_written /
  stale_recovered`.
- `core.command:registered / executed / rejected`.

### Version metadata

- `version` → `0.1.5` (additive patch line per
  [[auto-core-maintenance]] — no rename / removal / shape break).
- `api_version` unchanged at `0.1`. New surface is feature-detected
  via `type(require("auto-core").mailbox) == "table"`.

### Migration

No source-level migration. The contract is now in place for the
downstream wiring described in the ADR's "Implementation Plan"
steps 9–10:

- `auto-agents.nvim` registers `send_slot` / `openDiff` /
  `closeDiff` / `getDiffStatus`, calls `mailbox.register(...)` at
  agent-spawn time, and generates the mailbox section in
  `AGENTS.md` / `CLAUDE.md` / `GEMINI.md`.
- `md-harpoon.nvim` registers the `harpoon` command.

This release ships the foundation only; family plugins land in
follow-up worktrees on their own repos.

### Live test

Architectural validation done end-to-end with real Claude (jarvis)
and Codex (lector) agents — `send_slot` command flows through the
mailbox path, `nvim` executioner dispatches the registered handler,
response envelope routes back; Lector reads his bootstrap on wake,
saves the protocol to durable Codex memory per the first-read
directive, and acks via his outbox. Zero nvim-RPC indirection from
the agent side.

## [v0.1.4] — 2026-05-11 — percentage-based widths for multi-float panes

Feature. `ui.float.multi`'s `_compute_layout` now treats width values
between 0 and 1 as percentages of the total inner width. Enables
responsive layouts for multi-pane floats (like the worktree graph).

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
