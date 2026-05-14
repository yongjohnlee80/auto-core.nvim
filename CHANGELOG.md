# Changelog

All notable changes to `auto-core.nvim` are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com),
and from `v0.1.0` onward this project follows the
[`auto-core-maintenance`](https://github.com/yongjohnlee80/auto-agents)
convention's **additive-only minor-bump** rule: no `v0.X.Y` will ever
rename, remove, or break-shape an existing function, state-namespace
key, event topic, or persisted schema. Removals require a deprecation
cycle plus a major bump.

## [v0.1.6] — 2026-05-14 — remote-branch management primitives + events for git.repo/git.worktree

Additive patch-line release. Adds the git-side primitives that the
`worktree.nvim` graph uses for its `R` / `C` / `D` / `W` keybindings
(toggle remotes, checkout, destroy, new branch).

### Added — git.repo

- `repo.checkout_status(path, branch)` — sync probe. Returns
  `{ ok, reason?, dirty?, worktree? }`. Detects: not-a-repo,
  branch-already-checked-out-in-another-worktree, dirty working tree.
- `repo.checkout(path, branch, on_done)` — async checkout. Publishes
  `core.git.repo.checkout:started` / `:completed`.
- `repo.create_branch(path, name, base, on_done)` — async branch
  creation via `git checkout -b name base`. Publishes
  `core.git.repo.branch:created`.
- `repo.delete_remote(path, remote, branch, on_done)` — async
  `git push remote --delete branch`. Publishes
  `core.git.repo.remote:deleted`.

### Added — git.worktree

- `worktree.list_remote_branches(repo_path)` — sync. Returns
  `origin/<branch>` style strings, excluding `*/HEAD` pseudo-refs.
- `worktree.track(repo, remote_ref, local_name, target_path, on_done)`
  — async `git worktree add --track -b local_name target remote_ref`.
  Publishes `core.git.worktree:added`.
- `worktree.create(repo, branch_name, target_path, base_ref, on_done)`
  — async `git worktree add -b branch target base`. Publishes
  `core.git.worktree:added`.

### Callback shape — unified across the new primitives

All four async functions above use the same `on_done(res)` shape:

```lua
on_done = function(res)
  -- res.ok :: boolean
  -- res.stderr :: string?   -- present only on failure
end
```

This matches the existing `repo.checkout` shape and avoids the
two-arg/table-arg asymmetry that an earlier draft mixed in. Callers
can pattern-match against the table; old `(ok, err)` shape is NOT
shipped.

### Added — event topics (all additive)

- `core.git.repo.checkout:started`
- `core.git.repo.checkout:completed`
- `core.git.repo.remote:deleted`
- `core.git.repo.branch:created`
- `core.git.worktree:added`

### Version metadata

- `version` → `0.1.6` (additive patch line per
  [[auto-core-maintenance]]).
- `api_version` unchanged at `0.1`. New surface is feature-detected
  via `type(require("auto-core").git.repo.checkout) == "function"`.

### Migration

No source-level migration. The corresponding consumer-side wiring
ships in `worktree.nvim` v0.4.4.

## [v0.1.5] — 2026-05-14 — mailbox transport + command registry skeleton (ADR 0013 Phase 1)

Additive patch-line release. Adds `auto-core.mailbox` — a durable,
file-backed cross-process transport that gives sandboxed CLI agents
a way to coordinate with each other and with Neovim through atomic
JSON writes to a shared directory tree. Sockets, loopback HTTP, and
Neovim RPC are not reachable from the default agent sandbox; file
I/O is. See ADR 0013 for the full rationale.

### Added

- `M.mailbox` namespace with submodules: `path`, `message`,
  `registry`, `transport`, `consumer`, `commands`.
- `M.mailbox.configure({ root })` — override the resolved mailbox
  root. Default is durable + global, NOT tied to any worktree:
  `$AUTO_AGENTS_MAILBOX_ROOT` → `$AUTO_AGENTS_CONFIG_DIR/mailbox` →
  `dirname($AUTO_AGENTS_KB_ROOT)/mailbox` →
  `~/.config/nvim/.auto-agents-config/mailbox`. The default
  intentionally survives worktree creation/destruction so
  coordination state is never orphaned.
- `M.mailbox.register(id)` — ensure
  `<root>/<id>/{inbox,outbox,processing,archive,responses}/` exist.
  Mailbox ids may include `:` (e.g. `agent:lector`); path-traversal
  and slash characters are rejected.
- `M.mailbox.send(opts)` — atomic enqueue: write tmp file in the
  target inbox, fsync, rename into place. Generates a stable id
  and ISO-8601 `created_at` if not supplied; validates the baseline
  message shape (kind/from/to/command).
- `M.mailbox.claim/complete/fail` — state transitions
  (`inbox → processing → archive`), with optional response envelope
  written to the sender's `responses/<correlation_id>.json`.
- `M.mailbox.consume(id, opts)` — observe an inbox via
  `auto-core.fs.watch` or a uv-timer polling fallback
  (`mode = "auto" | "watch" | "poll"`). Emits
  `core.mailbox:message_queued` for newly-arrived files.
- `M.mailbox.commands` — command registry skeleton:
  `register/get/list/unregister` plus `handle_message` and
  `reject_unknown`. The registry is the security boundary:
  unknown commands return a structured `{ok=false, code="unknown_command"}`
  response; raw Lua/Vimscript/shell/RPC strings are never executed.
- New event topics: `core.mailbox:registered`,
  `core.mailbox:message_queued`, `core.mailbox:message_claimed`,
  `core.mailbox:message_completed`, `core.mailbox:message_failed`,
  `core.mailbox:response_written`, `core.command:registered`,
  `core.command:executed`, `core.command:rejected`.

### Version metadata

- `version` → `0.1.5` (additive patch line per
  [[auto-core-maintenance]]).
- `api_version` unchanged at `0.1`. New surface is feature-detected
  via `type(require("auto-core").mailbox) == "table"`.

### Migration

No source-level migration. Follow-up worktrees will move
`md-harpoon` (harpoon command), `auto-agents` (openDiff /
closeDiff / send_slot / send_user), and the diff-queue review
flow onto the command registry; this release does NOT touch
those plugins.

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
