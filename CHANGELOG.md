# Changelog

All notable changes to `auto-core.nvim` are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com),
and from `v0.1.0` onward this project follows the
[`auto-core-maintenance`](https://github.com/yongjohnlee80/auto-agents)
convention's **additive-only minor-bump** rule: no `v0.X.Y` will ever
rename, remove, or break-shape an existing function, state-namespace
key, event topic, or persisted schema. Removals require a deprecation
cycle plus a major bump.

## [v0.1.28] — 2026-05-20 — `ui.float.multi` opener-winid restore on close

Fixes "I closed the `:AutoCoreLog` dumps viewer with `q` and ended up
in the auto-finder panel instead of back in my editor." Pre-v0.1.28
`Float:close()` left focus to whatever window nvim's default
window-traversal algorithm picked next — frequently the tallest
remaining window, which is the auto-finder panel on the left.

### Fixed

- **`lua/auto-core/ui/float/multi.lua`** `Float:open()` snapshots
  `vim.api.nvim_get_current_win()` into `self._opener_winid`
  BEFORE opening any pane (so we capture the user's real
  pre-float window, not the bg). `Float:close()` snapshots pane
  winids BEFORE the close loop (so they can be excluded from
  the restore check), and after closing, restores focus to the
  opener via `nvim_set_current_win`. Skipped when:
  - opener is nil (open didn't capture — e.g. invoked from a
    context where `nvim_get_current_win` returned an invalid
    winid);
  - opener is no longer valid (window closed during the float's
    lifetime — e.g. a `:q` from a sibling pane via tab-cycle);
  - opener was itself a pane of this float (the self-spawn case
    — a sub-float opened from one of this float's own panes).

  Idempotent re-open of an already-open float short-circuits
  before the capture, so a second `open()` doesn't overwrite the
  original opener.

### Verified

- `tests/smoke.lua` section `[43]` adds 7 assertions covering
  capture-on-open, focus-moved-off-opener, restored-on-close,
  cleared-after-close, captured-is-not-bg-pane, survives-
  invalidated-opener (kill the opener mid-float-lifetime via
  `nvim_win_close`), and the no-restore-attempted invariant
  when the opener went stale. Suite green at **764 passed / 0
  failed** (was 757/0).

### Consumer impact

Strictly additive. No API surface change. Consumers pinning
`version = "^0.1.0"` pick up via `:Lazy update`. The new
`self._opener_winid` field is module-internal — not part of the
public Registry API and not documented for consumers to read.
`api_version` stays at `0.1`.

## [v0.1.27] — 2026-05-21 — macOS native-recursive `fs.watch` handler (segregated)

Adds an FSEvents-backed recursive watcher for macOS. The Linux walker
exhausts the macOS process fd ceiling around ~7000 dirs — past that
`vim.uv.new_fs_event` returns nil and the watcher silently has no
coverage. The original `fix(fs.watch): use native recursive watcher on
Darwin` (dc79b66) added the branch inline inside the existing walker;
it has been reverted on main and the same logic re-introduced as a
**separate handler** so future Darwin-only changes cannot perturb the
Linux walker. Also includes a long-overdue debounce-table prune that
the recursive handler would otherwise amplify into a memory leak on
macOS.

### Reverted

- `dc79b66 fix(fs.watch): use native recursive watcher on Darwin`
  — the substance of the fix is good but the structure mixed Darwin
  and Linux branches inside one function. Reverted on main via a
  proper revert commit; re-introduced below in segregated form.

### Added

- **`fs/watch.lua` — `IS_DARWIN` module-load constant.** Computed
  once via `vim.uv.os_uname()` at require time, so the dispatcher in
  `M.start` is a pure conditional check (no per-call syscall).

- **`fs/watch.lua` — separate Darwin handler section.** Introduces
  `_darwin_join_event_path`, `_darwin_start_one`, and `_darwin_start`
  in a clearly-marked block above the public API. `M.start`
  short-circuits into `_darwin_start(root, opts)` on
  `IS_DARWIN and opts.recursive` BEFORE any walked code runs. The
  Linux walker (`start_one_dir`) is byte-identical to v0.1.26 — no
  signature change, no shared code with the Darwin path, no chance
  of cross-platform regression from future macOS-only edits.

  `_darwin_join_event_path` handles the FSEvents-vs-inotify path-
  delivery asymmetry: FSEvents callbacks deliver ABSOLUTE filenames,
  inotify delivers relative. Subscribers see one path shape on both
  platforms.

- **`fs/watch.lua` — `debounce_check` opportunistic prune.** New
  `state._debounce_size` counter triggers an O(N) sweep of entries
  older than `DEBOUNCE_PRUNE_TTL_MULT × debounce_ms` (default
  `100 × 100ms = 10s`) only when the live count crosses
  `DEBOUNCE_PRUNE_THRESHOLD` (default 4096). Amortized O(1) on the
  hot path. `state._debounce` would otherwise grow without bound —
  pre-Darwin this leaked slowly (Linux walker pre-filters ignored
  subtrees at walk time, so their paths never reach `debounce_check`)
  but the Darwin recursive handler routes every event under the
  subtree through it, so the leak rate on macOS is much higher.

- **`health.lua` — `check_fs_watch` darwin hint.** Appends
  `; darwin native-recursive: on` to the active-handle count info
  line on macOS. A `:checkhealth auto-core` on macOS otherwise reads
  "fs.watch: 1 active fs_event handles" and looks broken.

### Changed (docs only)

- **Docstring header** acknowledges the platform asymmetry: Darwin
  auto-watches subdirs created AFTER `watch.start` (FSEvents covers
  the subtree); the Linux walker does NOT (existing baseline,
  unchanged). Ignore patterns apply at walk time on Linux but at
  callback time on Darwin — the hot path runs on every event under
  the Darwin subtree including events Linux would have skipped
  entirely. Acceptable because the Darwin alternative is no coverage
  at all on large workspaces.

### Verified

- `tests/smoke.lua` section `[26] fs.watch` is green (13/13) on
  Linux. No Darwin-specific assertions added in this release — the
  prior attempt to add them in dc79b66 pushed the smoke driver past
  Lua's `>200 main-chunk locals` parse limit. Darwin coverage will
  return in a follow-up that also scopes section [26]'s locals via
  `do ... end`.
- Pre-revert smoke at HEAD = `dc79b66` failed to parse (`E5112: main
  function has more than 200 local variables at line 2224`); post-
  revert + post-Darwin-handler at HEAD = v0.1.27 parses and passes.

### Consumer impact

Strictly additive. Linux consumers see only the debounce prune fix
(memory bound on long sessions) and the health-check copy edit; no
behavior change otherwise. macOS consumers gain actual `fs.watch`
coverage on large workspaces for the first time. `api_version` stays
at `0.1`.

## [v0.1.26] — 2026-05-20 — `fs.watch` defaults for large bare-repo parents

Closes the `would exceed max_handles cap (0 active + 12318 new > 1024)`
warning that `auto-finder.core.watchers` emitted when started under a
bare-repo parent housing a TypeScript monorepo with ~17 worktrees. The
recursive walk collected 12k+ dirs even after `node_modules` / `.git/` /
`.bare/` exclusion — the leftovers were ecosystem-standard build and
cache subtrees that no consumer wants watched, and the 1024 cap was
sized when the foundation library only ever saw single-worktree usage.

### Changed

- **`DEFAULT_IGNORE`** (`lua/auto-core/fs/watch.lua`). Added anchored
  patterns for the dirs no consumer wants in the recursive walk:
  - JS/web bundler output: `/dist/`, `/build/`, `/coverage/`,
    `/%.next/`, `/%.cache/`, `/%.turbo/`, `/%.parcel%-cache/`.
  - Other ecosystems: `/target/` (rust/maven), `/__pycache__/`,
    `/%.venv/`, `/venv/`, `/%.pytest_cache/`, `/%.mypy_cache/`,
    `/%.ruff_cache/`, `/%.tox/`.
  - IDE metadata: `/%.idea/`, `/%.vscode/`.

  Existing patterns (`/%.git/`, `/%.bare/`, `/node_modules/`, `/%.svn/`,
  swap/backup/probe file suffixes) are unchanged.

- **`DEFAULT_MAX_HANDLES`** raised `1024` → `131072`. The cap was
  always a "catch a runaway bug" belt (e.g. `watch.start("/")`),
  not a real budget — legitimate large bare-repo parents legitimately
  have tens of thousands of source dirs. `131072` is ¼ of Linux's
  `fs.inotify.max_user_watches` default (524288), leaving the other
  ¾ for everything else under the user's uid (JetBrains, file
  managers, other nvim instances). Callers that want a smaller cap
  still pass `max_handles` to `watch.start` per call.

### Verified

- `tests/smoke.lua` section `[26] fs.watch` is green (start/stop,
  events, debounce, ignore filter on `.git/`, max_handles refusal
  with explicit `max_handles = 1` opt).
- `health.lua:109` already reads `watch.DEFAULT_MAX_HANDLES`, so the
  80 %-threshold "consider raising max_handles" advisory auto-tracks
  the new value — no health-check tweak needed.

### Consumer impact

Strictly additive. Pinning `version = "^0.1.0"` picks this up on
`:Lazy update`. Consumers that explicitly passed `ignore = …` or
`max_handles = …` to `watch.start` are unaffected — defaults only
apply when the opt is nil. `api_version` stays at `0.1`.

## [v0.1.25] — 2026-05-20 — `ui.section.Registry:section_did_remount` hook

Public hook for async-mount sections that swap their panel buffer
after `Registry:focus` has already cached the buffer returned by
`get_buffer()`. Motivating bug: auto-finder's dbase view returns a
`shared.loading` placeholder from `get_buffer()` and lets a
`vim.schedule`-deferred mount inside `on_focus` swap the real dbee
drawer in. The registry's cache, the buffer-local `0..9`/`q`
keymaps, and the panel winbar all stayed bound to the discarded
placeholder. User-facing symptom: navigating to dbase for the first
time hid the winbar and broke numeric section-hop until a later
redraw (`<leader>e` toggle, auto-agents `<F5>`, anything that pokes
`_refresh_winbar`) healed it.

KB: `shared/synthesis/2026-05-20-auto-finder-dbase-winbar-remount-bug-analysis.md`,
`shared/synthesis/auto-core-registry-keymap-rebind-hook.md`.

### Added

- **`Registry:section_did_remount(section_number, real_bufnr)`**
  (`lua/auto-core/ui/section.lua`). Public method. After a section's
  deferred mount swaps the panel to a new "real" buffer, the section
  calls this hook to repair the registry's bindings:
  - Updates `_bufs[section_number]` so a subsequent `focus()` reuses
    the real buffer instead of issuing the placeholder dance again.
  - Re-applies the private `apply_keymap` on the real buffer
    (`0..9` → focus(i); `q` → panel close) — only when
    `section_number` is the currently active section, since the
    keymap surface is buffer-local.
  - Refreshes the panel winbar (only when active).

  Idempotent; short-circuits on invalid `real_bufnr` or inactive
  section. Recommended call site: inside the section's deferred
  `vim.schedule` callback, immediately after the real buffer is
  placed in the panel window. Guard with whatever still-current
  predicate the section already uses for cancellation.

### Rationale

ADR 0026 §A3 (auto-finder state/UI separation) leaned on a
placeholder-buffer pattern for every async view. Phase 7 of that
work narrowed the rollout to `dbase` only because the synchronous
`Registry:focus` contract bound the keymap surface + winbar to the
buffer `get_buffer()` returned — there was no public way to tell the
registry "the active section now lives on a different bufnr." The
companion KB todo `auto-core-registry-keymap-rebind-hook.md` proposed
this exact surface so any future async-mount view (auto-finder
neo-tree views, hypothetical remote/SSH views, etc.) can adopt the
placeholder pattern without re-deriving the registry's private
keymap helper.

### Verified

- Loads cleanly; method is dispatched off the existing Registry
  metatable so no caller is affected unless they opt in.
- Live test path: pointing `~/.config/nvim/lua/plugins/auto-core.lua`
  at this worktree via `dir=` + `:Lazy reload auto-core.nvim`, then
  cold-focusing dbase via `:AutoFinderFocus dbase`. Pre-fix: winbar
  empty, `0..9` no-op on the dbee drawer. Post-fix (with the dbase
  consumer-side flip in `auto-finder@dbase-rebind-on-remount`):
  winbar populated, `0..9` switches views.

### Consumer impact

Additive. Existing `Registry:focus` path is unchanged; no break-
shape. Consumers pinning `version = "^0.1.0"` pick up v0.1.25 on
`:Lazy update` and gain the new method on every Registry returned by
`require("auto-core").ui.section.attach(...)`.

`api_version` stays at `0.1`. The new method rides along with the
v0.1.x line's additive contract.

## [v0.1.24] — 2026-05-18 — mailbox router + commands log observability

Closes the silent-router gap that left wake dispatch and command
execution invisible to `:AutoCoreLog`. Motivating incident: on
2026-05-18 the claude-backed agents Ultron and Vision both missed
their wake nudges (`hi-ultron`, `hi-vision` probe messages landed in
their inboxes but no terminal output fired). The router had zero log
emissions across its entire codepath — every wake dispatch, every
command execution, every rejection ran silently — so there was
nothing to triage from.

This patch wires structured log entries through the router and the
command registry. The asymmetry between claude-vs-gemini wake delivery
that the probe surfaced can now be diagnosed by re-running the probe
and inspecting `:AutoCoreLog`.

### Added

- **`auto-core.mailbox.router` log entries** (component
  `auto-core.mailbox.router`):
  - `auto-core.mailbox.router.inbox_arrival` — INFO. Every unseen
    file landing in any registered mailbox's `inbox/` (fires once per
    arrival, after the seen-set check). Fields:
    `mailbox`/`mailbox_full`/`arrival_kind`/`arrival_id`/`msg_kind`/
    `msg_from`/`msg_command`/`decode_error`/`executioner`.
  - `auto-core.mailbox.router.response_arrival` — INFO. Same shape
    for `responses/` arrivals.
  - `auto-core.mailbox.router.wake_dispatched` — INFO. Emitted
    immediately before `commands.handle_message` runs the wake hook.
    Fields:
    `mailbox`/`mailbox_full`/`arrival_kind`/`arrival_id`/`command`/
    `synthesized_id`.
  - `auto-core.mailbox.router.wake_skipped` — DEBUG when the
    mailbox has no wake config (informational only), WARN when the
    configured `wake.command` references a command not in the
    registry (almost always a setup-order bug). Fields include a
    `reason` discriminator (`no_wake_config` /
    `command_not_registered`).

- **`auto-core.mailbox.commands` log entries** (component
  `auto-core.mailbox.commands`):
  - `auto-core.mailbox.commands.command_executed` — fires on every
    `M.handle_message` call where the handler ran. INFO on ok=true;
    ERROR on `handler_error` (handler raised inside the pcall
    barrier); WARN on app-level rejections (handler returned
    ok=false with a non-rejection code). Fields:
    `command`/`ok`/`code`/`error`/`msg_id`/`msg_from`/`msg_to`/
    `correlation_id`/`dispatch_path`/`executor_mbox`.
  - `auto-core.mailbox.commands.command_rejected` — WARN. Fires
    when the call short-circuits before handler dispatch:
    `bad_message`, `not_a_command`, `missing_command`, `bad_args`,
    `unknown_command`. Same fields as `command_executed`.

  Both event ids share component, level routing, and field shape so
  `:AutoCoreLog` filtered to the component shows the full command
  stream regardless of dispatch path (wake-dispatched commands and
  executor-path commands flow through the same `handle_message`).

- **Event registration in `plugin/auto-core.lua`.** All six event
  ids registered under the `auto-core` plugin slug at load time;
  `:AutoCoreLogEvent list` discovers them; users can subscribe to
  any subset for toast notification via
  `:AutoCoreLogEvent notify <event>`. Default is ring-only.

### Changed

- `lua/auto-core/mailbox/commands.lua` — `M.handle_message` is now a
  thin wrapper around a private `_handle_message_inner` that returns
  the response without logging. The outer `M.handle_message` calls
  the inner, derives the log level + event id from the response, and
  emits exactly one entry per call. **Public API unchanged**: same
  signature, same return shape; only the structural refactor and the
  added log emission are new.

- `lua/auto-core/mailbox/router.lua` — `handle_inbox` and
  `handle_response` now log after publishing their respective
  `core.mailbox:*` events (unchanged event topics). `dispatch_wake`
  logs at every exit point with a `reason` field on the
  short-circuits.

### Rationale

ADR 0021 §10 flagged router observability as deferred work. This
ships it as a focused patch: the existing log surface (auto-core's
own ring + `:AutoCoreLog` viewer + persisted dump files under
`stdpath('cache')/auto-core/dumps/`) is the natural channel — no new
plumbing, just emissions at the right points. Components and event
ids follow the conventions already established in ADR 0021 §5 / §6.

### Verified

- Smoke suite: 757 passed, 0 failed (unchanged from v0.1.23; the new
  log emissions don't break any existing assertions since the ring
  is internal and the tests don't pin its contents).
- Loads cleanly via `require("auto-core")` — registration in
  `plugin/auto-core.lua` happens lazily-safe (pcall'd) and skips if
  the log module isn't available.

### Consumer impact

None — additive. No removals, no break-shape. Consumers continue to
pin `version = "^0.1.0"` and pick up v0.1.24 on `:Lazy update`. The
new event ids are opt-in for notification; the ring entries surface
in `:AutoCoreLog` regardless without any consumer action.

`api_version` stays at `0.1`.

## [v0.1.23] — 2026-05-18 — mailbox.router executor `ctx`: surface `correlation_id` + `message_id`

Closes the round-trip-identity gap left by v0.1.12. v0.1.12 added
`sender` / `sender_bare` to the executor ctx so command handlers
could attribute calls to the actual sender. This patch adds the
matching round-trip identity — `correlation_id` (from
`claimed.correlation_id`) and `message_id` (executor-path file
basename) — for handlers that need to defer a verdict past the
synchronous response and route a follow-up message back to the
sender keyed by correlation.

The consumer side ships in auto-agents v0.2.19: the `diff_queue`
mailbox handler now stashes the originator's full mailbox id +
the command's correlation_id on its queue entry, so the eventual
panel reject/accept emits a `kind="message"` verdict back to the
originator's inbox via the standard router (wake fires
automatically via `dispatch_wake`).

### Changed

- `mailbox/router.lua` `execute_command` ctx now carries two
  additional fields on top of the v0.1.12 set:
  - `correlation_id` — `claimed.correlation_id` when present (non-
    empty string), nil otherwise.
  - `message_id` — the executor-path file basename (`mid`).
  Both are additive; existing handlers continue to work unchanged.

### Compatibility

Additive — no removals, no break-shape. `api_version` stays at
`0.1`. Patch within v0.1.x per `auto-core-maintenance`.

## [v0.1.22] — 2026-05-18 — Lector follow-ups on the v0.1.21 visibility-gap fix

Two non-blocking observations from `agent:lector`'s 2026-05-18 10:30 UTC review of v0.1.21, addressed in a fast-follow patch.

### Changed

- **`Panel:_cleanup_unmarked_siblings` scopes to the current tab**
  via `nvim_tabpage_list_wins(0)` instead of `nvim_list_wins()`.
  Aligns with the incident language ("two stacked panels" is
  always intra-tab) and prevents a theoretical cross-tab race
  where a sibling editor split in tab B holding the panel buffer
  would be force-closed by a VimResized cleanup pass in tab A.
  Panels are tab-singletons in the auto-family model. Docstring
  updated to call this out explicitly.

### Tests

Section [52] smoke now exercises the WinNew detection log path
explicitly (was previously cleanup-only). Two new assertions:
"WinNew detection logged 'unmarked sibling detected (WinNew)'" +
"WinNew detection did NOT close the sibling (detection-only)".
Section grows 11 → 13 assertions. Suite green at **755 passed, 0
failed**.

### Versioning

Patch within v0.1.x — additive only; api_version stays at 0.1.

## [v0.1.21] — 2026-05-18 — ui.panel visibility-gap fix + VimResized log-anchor regression closed

Closes [yongjohnlee80/auto-agents issue #3](https://github.com/yongjohnlee80/auto-agents/issues/3) — the recurring "two stacked auto-agents panels" bug surfaces after host-terminal resize (Hyprland tile-share, manual `<C-w>` window ops, tmux pane resize). Source-of-truth incident note: `agents/white-vision/incidents/2026-05-18-auto-agents-panel-duplicated-recurrence.md`.

### Fixed

- **VimResized log anchor regression (silent since v0.1.18).** The
  `VimResized` autocmd registered in `panel.new()` would never
  produce a ring entry in real sessions despite being correctly
  installed (`AutoCorePanel_<name>:VimResized` confirmed via
  `nvim_get_autocmds`). Root cause: the field-table literal
  evaluated `(p:_is_open() and nvim_win_get_width(p.winid)) or nil`
  for `live_panel_width` INSIDE the `{ fields = { ... } }` table.
  When `p.winid` was racy-invalid (panel closed mid-handler), that
  expression threw BEFORE `log_panel.info` saw the message. The
  autocmd's implicit pcall swallowed the error. Net: the
  observability ship's marquee anchor was effectively absent from
  every real session ring dump. **The new form logs first,
  computes throwable fields via explicit pcall, then refreshes
  width.** The anchor lands reliably.

### Added

- **`WinNew` autocmd on the panel-singleton group.** Deferred via
  `vim.schedule` so the new window's buffer is stable at check
  time. When a new non-floating window appears holding the panel's
  tracked buffer but lacking the panel marker, logs INFO with
  `sibling_winids`, `panel_winid`, `panel_bufnr`, `marker_var`,
  `columns` / `lines`, and `debug.traceback("", 2)`. Closes the
  visibility gap from issue #3's recommendation #1 — previously
  layout-reflow-created siblings were invisible to the singleton's
  logging path because they bypassed `Panel:open()`. **Detection-
  only**; doesn't close. Pairs with the cleanup pass below to
  distinguish "reflow created this sibling" (paired with cleanup
  log ~ms later) vs "some other path" (no cleanup log follows).
- **`Panel:_cleanup_unmarked_siblings()` method**, scheduled via
  `vim.schedule()` from the VimResized handler. Scans the tab for
  windows holding the panel's tracked buffer but lacking the marker;
  closes them. Runs OUTSIDE the autocmd context so `nvim_win_close`
  is permitted (avoids the `E1312: Not allowed to change the window
  layout in this autocmd` fallback-scratch-swap dance that left the
  duplicate window visible in v0.1.18–v0.1.20). Logs INFO on each
  close with `closed_winid`, `panel_winid`, `panel_bufnr`, `ok`,
  `err`. Silent fast-path when no siblings exist.

### Tests

Section [52] of `tests/smoke.lua` adds 11 assertions covering: panel
open sanity, VimResized log lands in ring (the regression guard),
VimResized still logs when `p.winid` is racy-invalid, synthetic
unmarked sibling spawnable via `nvim_open_win({split="below"})`,
sibling has the panel buffer + lacks the marker, cleanup pass closes
the sibling + logs `unmarked sibling closed` at INFO, idempotent
fast-path silent when no siblings exist. Suite green at **753 passed,
0 failed**.

### What this patch does NOT do (deferred)

- **Issue #3 recommendation #2 — panel-singleton invariant probe**
  (periodic / `WinResized`-debounced check that "at most one window
  per tab holds a given `BUF_OWNER_VAR` value"). Defer to a follow-up
  patch once this patch proves itself in production.
- **Issue #3 ancillary diff-cleanup audit items** at
  `auto-agents/mcp/ws-server/diff.lua:671,677` +
  `auto-agents/diff/ui.lua:199-214`. Out of scope; recommend a
  dedicated `auto-agents` worktree.

### Versioning

Patch within v0.1.x per `auto-core-maintenance` additive-only
discipline. Linear descendant of v0.1.20 (`cac427a`,
"fix(log): add *_throttled methods to namespace handles"). Autovim
consumer caret `^0.1.0` already covers.

## [v0.1.19] — 2026-05-17 — auto-core.git.watch + core.git.state:changed (ADR 0025 Phase 1)

Closes the refresh-trigger gap that left UI consumers (auto-finder
files panel) rendering stale git decorations after external
`git add` / `commit` / `checkout` / `reset`. Root cause: the family-
wide `auto-core.fs.watch` deliberately excludes `/.git/` (its
`DEFAULT_IGNORE` would otherwise drown subscribers in
object/refs/reflog churn), so no `core.file:*` ever fires for
`.git/` mutations.

### Added

- **`lua/auto-core/git/watch.lua`** — narrow opt-in libuv `fs_event`
  watcher scoped to a repo's `.git/` plumbing. Two non-recursive
  handles per repo: `git_dir/` filtered to filename in
  `{ HEAD, index, ORIG_HEAD, MERGE_HEAD }`, and `git_dir/logs/`
  filtered to filename `HEAD` (the reflog tip). Resolves git_dir via
  `auto-core.git.repo.git_dir(repo_root)` so **linked worktrees
  attach to their per-worktree git_dir, not the shared common_dir**
  — sibling worktrees' mutations don't cross-fire. Filters `.lock`
  filenames at the publisher; debounce 200 ms. Public surface
  mirrors `fs.watch.start / stop / list / stop_all` and exposes
  `DEFAULT_DEBOUNCE_MS = 200` / `DEFAULT_MAX_HANDLES = 64` /
  `FILENAME_KINDS`.
- **Topic `core.git.state:changed`** registered in
  `events/topics.lua` with payload `{ repo_root, git_dir, kind =
  'head' | 'index' | 'merge' | 'reflog' | 'other', path }`. Single
  coarse topic; the `kind` discriminator lets subscribers filter.
- **`git/status.lua`** subscribes to the new topic and invalidates
  `_cache[normalize(payload.repo_root)]`. The existing `core.file:*`
  invalidation misses `.git/`-only mutations for the same fs.watch
  reason, so the two subscriptions cover disjoint event sources.

### Deliberately NOT watched

`refs/remotes/`, `FETCH_HEAD`, and `logs/refs/remotes/` — all
written by `git fetch` and noisy without changing local panel
state. ADR 0007 Phase 3.5's `core.git.fetch:completed` already
covers callers that care about remote refs. `refs/heads/` is also
not watched recursively (Linux `fs_event` can't observe namespaced
subdirs non-recursively); `logs/HEAD` catches every HEAD movement
those branches produce, including commits on `feature/*` etc.

### Unchanged

`auto-core.fs.watch`'s `DEFAULT_IGNORE` keeps the `/%.git/` anchor.
Per ADR 0025 §2.5, un-ignoring it would flood every subscriber in
the family with high-rate irrelevant events. The new module is the
narrow companion, not a replacement.

### Tests

Section [51] adds 21 assertions covering: nil/non-repo error paths,
two-handle layout, kind classification across `index` / `reflog` /
`head` from real `git add` / `commit` / `checkout -b`,
`refs/remotes/` exclusion, `.lock` filename filter, debounce
coalescing on burst writes, max_handles cap, `stop` / `stop_all` /
restart, default constants, and status cache invalidation via the
new topic (including the "different repo_root doesn't invalidate
this cache" cross-check). Suite green at 744 passed, 0 failed.

### Wiring

Opt-in — consumers call `git.watch.start(repo_root)` explicitly.
The `auto-finder` companion patch lands in a separate worktree per
ADR 0025 §6.

## [v0.1.15] — 2026-05-17 — mailbox bootstrap seen-revision uses tool-root state

Corrects the agent-facing bootstrap audit instructions so the
`seen-revision` marker is persisted beside the shared per-tool-root
`bootstrap-mailbox.md`, not only inside the per-instance mailbox
directory.

### Changed

- **`mailbox/templates/bootstrap.md`** now points agents at
  `$(dirname "$AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC")/.agent-state/seen-revision`
  as the default durable acknowledgement file.
- The doc explicitly warns agents not to rely only on
  `$AUTO_AGENTS_MAILBOX_DIR/.agent-state/seen-revision`, because
  `$AUTO_AGENTS_MAILBOX_DIR` is instance-scoped and pruneable.
- `schema_version` bumped from `5` to `6` so agents re-read the
  corrected protocol text on their next bootstrap audit.
- `version.lua` bumped from `0.1.14` to `0.1.15`.

### Compatibility

Doc/protocol clarification only. No Lua API, event, state, or
mailbox envelope shape changed. `api_version` stays at `0.1`.

## [v0.1.14] — 2026-05-17 — dbase event topics (ADR 0020)

Six new `dbase.*` event topics registered in
`lua/auto-core/events/topics.lua` for the auto-finder dbase
section (ADR 0020) to publish onto. The topics let other
auto-family plugins react to database UI activity without
coupling to nvim-dbee's internal `Handler:register_event_listener`
surface — the section's event bridge subscribes there and
forwards translated payloads onto these auto-core topics.

### Added

- **`dbase.connection:changed`** — the active dbee connection
  switched. Payload: `{ id, name?, type? }`.
- **`dbase.call:started`** — a dbee query was submitted (call
  enters pending/executing state). Payload:
  `{ call_id, conn_id?, query }`.
- **`dbase.call:state_changed`** — a dbee call's internal state
  transitioned (e.g. `pending → executing → archived`). Use this
  for fine-grained progress UIs; the discrete `completed` /
  `failed` topics below are the standard terminal signals.
  Payload: `{ call_id, conn_id?, from?, to }`.
- **`dbase.call:completed`** — a dbee call finished successfully.
  Payload: `{ call_id, conn_id?, rows?, duration_ms? }`.
- **`dbase.call:failed`** — a dbee call ended in error. Payload:
  `{ call_id, conn_id?, err }`.
- **`dbase.result:shown`** — the result tile rendered a call's
  output (or paged within it). Payload:
  `{ call_id, page?, total_pages? }`.

All six topics carry `publishers = { "auto-finder.nvim" }` in
their registry entries.

### Notes

- `conn_id` is optional (`string?`) on every `call.*` topic
  because dbee's `CallDetails` shape carries no connection id —
  the section's bridge enriches via `get_current_connection()`
  which can return nil for archived calls fired late or while a
  different connection is active. Subscribers should treat
  `conn_id` as best-effort.

### Compatibility

Additive — no removals, no break-shape. Per
`auto-core-maintenance`'s additive-only minor-bump rule this is
a patch within the v0.1.x line. `api_version` stays at `0.1`.
Consumers pinned to `version = "^0.1.0"` pick this up
automatically.

## [v0.1.13] — 2026-05-16 — ADR 0023 Phase 1 (resumed-agent reconciliation) + log :messages silence

Three additive surface changes:

1. **`log.lua` — INFO+ is RING-ONLY by default.** Toasts no
   longer leak to `:messages` unless the caller opts in via
   `opts.echo = true` per-call or `configure({ echo = true })`
   globally. ERROR + WARN still toast as before. Pre-v0.1.13
   behavior was firehose `:messages` echo on every emission;
   the new default mirrors the auto-family-logging convention's
   "no noisy `:messages`" stance.

2. **`mailbox/router.lua` — `mailbox.stale_orphan_detected`
   event topic.** `classify()` now emits this event whenever a
   poll finds an outbox path whose mailbox component matches a
   KNOWN bare id but at a NON-CURRENT instance suffix. Payload:
   `{ mailbox_bare, observed_instance, current_instance, path }`.
   Subscribed via `auto-core.log.events` for the resumed-agent
   diagnostic per [ADR 0023](https://github.com/yongjohnlee80/auto-agents/blob/main/shared/adrs/0023-resumed-agent-identity-reconciliation.md)
   §3.1. Pure observability addition — no existing classification
   outcome changes.

3. **`mailbox/router.lua` + `templates/bootstrap.md` —
   `identity_hint` on wake payloads + bootstrap §"Resumed-agent
   identity reconciliation".** Wake payloads now carry
   `identity_hint` (the live full mailbox id) so resumed agents
   can detect drift between their fork-frozen
   `$AUTO_AGENTS_MAILBOX_DIR` env and the actual mailbox the host
   expects them to read. The bootstrap doc gains a new section
   documenting the drift, the new event, the `identity_hint`
   field, and the consumer-side `refresh_agent_id` verb (shipped
   in auto-agents v0.2.13). Bootstrap `schema_version` bumped
   4 → 5; resumed agents see revision mismatch on next wake and
   re-ingest the doc.

### Added

- **`mailbox.stale_orphan_detected`** event topic in
  `auto-core.log.events`. Auto-registered at module load; users
  may subscribe via `:AutoCoreLogEvent notify
  mailbox.stale_orphan_detected`.
- **`identity_hint`** field on wake-message payloads dispatched
  through `mailbox/router.lua::dispatch_wake`. Type: full mailbox
  id string (e.g. `"agent:jarvis:1778927609-1176981"`). Nil for
  non-agent destinations.
- **`templates/bootstrap.md` §"Resumed-agent identity
  reconciliation"** — agent-facing documentation of the drift
  scenario, the new event, the `identity_hint` field, and the
  consumer `refresh_agent_id` verb.

### Changed

- **`log.dispatch` routing default.** When `opts.echo` is
  omitted, `INFO`/`WARN`/`ERROR` emissions no longer call
  `nvim_echo` after the toast — eliminating the duplicate
  `[AutoCore] [...] [INFO] ...` line in `:messages`. The ring
  write and toast both still fire; only the `nvim_echo` mirror
  is suppressed. ERROR and WARN toasts continue to use
  `vim.notify` at their normal severities, which most users have
  configured to surface via notify.nvim or fidget.nvim already.
- **`templates/bootstrap.md`** `schema_version` bumped from `4`
  to `5`. Agents that have previously acknowledged revision `4`
  will see a mismatch on next wake and re-ingest the doc.

### Tests

Smoke section `[10] mailbox/router` extended with the Phase 1
event + identity_hint assertions (7 assertions, all green). The
`:messages` silence change validated via section `[39] log`
behaviour checks (`opts.echo = true` → echoes; omitted → silent).

### Notes

- All three changes are **additive**. Existing consumers that
  reading `ctx.mailbox`, `msg.payload.body`, ring entries via
  `log.entries()`, or subscribing to other event topics continue
  to work byte-identically.
- Per the `auto-core-maintenance` convention §additive-only
  minor-bump rule, this is a patch within the v0.1.x line.
  `api_version` stays at `0.1`.
- **Companion consumer change:** auto-agents v0.2.13 ships
  `refresh_agent_id` (the agent-initiated reconciliation verb)
  and `:AutoAgentsAdoptResumedAgent` (the host-initiated
  reconciliation command). See ADR 0023 §3.2 + §3.3.

### Files touched

- `lua/auto-core/log.lua` (echo-routing logic)
- `lua/auto-core/mailbox/router.lua` (event emission +
  identity_hint payload field)
- `lua/auto-core/mailbox/templates/bootstrap.md`
  (schema_version + Resumed-agent reconciliation section)
- `lua/auto-core/version.lua` (0.1.12 → 0.1.13)
- `tests/smoke.lua` (Phase 1 assertions under `[10]`)

## [v0.1.11] — 2026-05-16 — ADR 0021 Phase 1: centralized logging surface for the family

Additive minor-surface extension to `auto-core.log` per
[ADR 0021](https://github.com/yongjohnlee80/auto-agents/blob/main/shared/adrs/0021-auto-family-centralized-logging.md).
Every existing call site keeps working byte-identically; the new
options-table form is opt-in via sentinel-key detection.

### Added

- **`AutoCoreLogEntry` schema**: optional `event_type :: string?`
  (registered event id, e.g. `"auto-finder.scan.completed.slow"`)
  and `fields :: table?` (structured payload preserved unflattened
  for the eventual `:AutoCoreLog` viewer). Existing entries leave
  both as `nil`.
- **Options-table sentinel detection** in `level_call`. The last
  message-parts element is interpreted as options iff it's a table
  with at least one of `event`, `fields`, `notify`,
  `level_override`. Backward-compatible — trailing tables WITHOUT
  sentinel keys still render via `vim.inspect`.
- **`log.notify(msg, opts?)`** — single-emission sugar that
  unconditionally writes the ring AND fires `vim.notify`. Default
  level INFO; override via `opts.level = "warn"` etc. Honors
  `opts.component`, `opts.title`, `opts.fields`.
- **`log.notifyIf(event, msg, opts?)`** — ring write +
  gated toast. Toasts iff `event` is in the user's subscribed set.
  The ring entry is always written, so the audit trail is
  preserved for `:AutoCoreLog` regardless of notification routing.
- **`opts.notify` three-state routing** inside `dispatch`:
  - `true` → always toast (level → severity icon)
  - `false` → never toast
  - `"auto"` → toast iff `opts.event` is subscribed
  - omitted → pre-ADR-0021 default (ERROR/WARN toast, else silent)
- **`log.events.register / list / enable_notify / disable_notify
  / is_notify_enabled`**. Plugins call `register(plugin, events)`
  at setup; users toggle subscriptions via the user command below.
  Subscriptions persist via
  `auto-core.state.namespace("auto-core.log.events")` (json
  backend). The registry itself is in-memory and re-declared on
  every nvim startup.
- **`log.<level>_throttled(key, every_ms, component?, ...)`** for
  every level. At most one emission per `(key, every_ms)` window;
  subsequent calls are dropped silently. Required guard for any
  per-loop logging — see the convention page below.
- **`:AutoCoreLogEvent list [plugin] | notify <event> | silence
  <event>`** user command. Context-aware tab completion suggests
  plugin names for `list`, unsubscribed events for `notify`,
  subscribed events for `silence`.

### Changed

- **`level_call(level, component, ...)` arg-shape rules**: the
  three-way distinction between `string component`,
  `nil component`, and `non-nil-non-string component` is now
  explicit. Pre-ADR-0021 callers that pass nil were silently
  putting nil at `parts[1]`, creating an array-length hole that
  corrupted `#parts`. The fix is internal — no public API change.
- **`_reset_for_tests`** now also clears the in-memory event
  registry and the cached state-namespace handle. Tests
  exercising the persisted registry should additionally call
  `auto-core.state._reset_for_tests` + a `state.configure({
  persist_dir = tempdir })` override for isolation.

### Convention

A new family-wide binding convention lives in the auto-agents KB
at `shared/conventions/auto-family-logging.md`. Highlights:

- **Wrapper rule**: every consumer plugin owns exactly one
  `lua/<plugin>/log.lua` that delegates to `auto-core.log`.
  Feature code calls the wrapper, never `auto-core.log` directly.
- **No bare `vim.notify`**: use `log.notify` or `log.notifyIf` so
  every toast also lands in the ring.
- **Required event registration** at plugin `setup()` before
  first `notifyIf` emission.
- **Hot-loop guard**: any emission inside a per-entry loop uses
  `log.<level>_throttled`.
- **In-memory only**: no background disk I/O. Persistence is
  on-demand via the future `:AutoCoreLog` viewer's export action.

### Migration

This is a **patch** within the v0.1.x line per
[`auto-core-maintenance`](https://github.com/yongjohnlee80/auto-agents/blob/main/shared/conventions/auto-core-maintenance.md)'s
additive-only rule. Consumers pinned via `version = "^0.1.0"`
auto-update on next `:Lazy sync`. The legacy
`auto-finder/logger.lua` and `auto-agents/logger.lua` shims
remain — Phase 2 renames them to `log.lua` and broadens to cover
`notify` / `notifyIf` / `register_events`, but the rename is
non-breaking and lives in each plugin's own repo.

Soft-dep tolerance is the family discipline going forward:
plugins that adopt the new surface (`log.notify` /
`log.notifyIf` / `register_events`) MUST degrade gracefully
when run against an older auto-core that lacks them. Pattern:

```lua
if type(core_log.notifyIf) ~= "function" then
  return M.info(opts.component, msg)  -- ring-only fallback
end
return core_log.notifyIf(fq_event, msg, opts)
```

### Tests

Smoke section `[39] log` grew from ~120 to ~370 lines:
- 10 assertions for the schema + sentinel detection
- 14 for `notify` / `notifyIf` / `opts.notify` routing
- 16 for the event registry + persistence round-trip
- 8 for the `:AutoCoreLogEvent` user command
- 8 for the throttled emission family

Suite: 662 passed, 1 failed (the pre-existing
`bootstrap doc still documents Codex writable_roots setup`
assertion on `comms-1` from `e4754d4`, unrelated to logging).

### Files touched

- `lua/auto-core/log.lua` (~290 → ~530 lines)
- `plugin/auto-core.lua` (registers `:AutoCoreLogEvent`)
- `lua/auto-core/version.lua` (0.1.10 → 0.1.11)
- `tests/smoke.lua` (+250 lines under `[39]`)

## [v0.1.12] — 2026-05-16 — mailbox.router: ctx.sender / ctx.sender_bare on executor dispatch

Additive ctx fields on the executor-path dispatch — closes a latent
attribution gap reported via auto-agents ADR 0011 §D3. Renumbered
from the pre-rebase v0.1.11 because v0.1.11 was claimed upstream by
the ADR 0021 Phase 1 logging surface; this change rebases on top of
that work and bumps to v0.1.12.

Pre-patch, `mailbox.router.execute_command` populated the
`commands.handle_message` ctx with `mailbox = rec.bare_id` and
`mailbox_full = rec.id` — both pointing at the EXECUTOR (always
`nvim` for the host-side dispatcher). Command handlers that wanted
the SENDER's identity ("who asked me to do this work?") had no
field for it and resorted to guessing from `ctx.mailbox` — which
returned `"nvim"`. The auto-agents `diff_queue` mailbox handler hit
this exact wall: it tried to parse `agent:<name>` from
`ctx.mailbox`, always got `"nvim"`, and rendered every
mailbox-routed diff with the wrong attribution.

### Added

- **`auto-core/mailbox/router.lua`** `execute_command` ctx now
  carries two new fields alongside the existing `mailbox` /
  `mailbox_full`:
  - `sender` — `msg.from` verbatim (the sender's full mailbox id,
    e.g. `agent:jarvis:1778927609-1176981`).
  - `sender_bare` — `mb_path.bare_id(msg.from)` (the bare form,
    e.g. `agent:jarvis`). Stable across instance restarts.
  Both are nil when `msg.from` isn't a string (defensive — should
  not happen in practice; transport validates on receive).

### Tests

- `tests/smoke.lua` §49 (executioner-path test) extended with two
  new assertions: `ctx.sender == cmd_msg.from` and
  `ctx.sender_bare == "agent:jarvis"`. Existing executor
  assertions (`ctx.reason`, `ctx.mailbox`) unchanged.

### Notes

- **Additive only.** Existing handlers reading `ctx.mailbox` /
  `ctx.mailbox_full` continue to work unchanged. New handlers opt
  into `ctx.sender_bare` (the recommended field for attribution).
- Per the `auto-core-maintenance` convention §additive-only
  minor-bump rule, this is a patch bump (additive ctx field on the
  same dispatch path). `api_version` stays at `0.1`.
- Companion consumer change: auto-agents v0.2.12 Patch 4 (mailbox
  `diff_queue` handler) reads `ctx.sender_bare` here.

## [v0.1.10] — 2026-05-16 — git.graph.fan_out: is_bare now reflects the repo, not the probed dir

Bug fix. `git.graph.fan_out` was probing each candidate dir with
`git -C <dir> rev-parse --is-bare-repository`, which reports the
**probed dir's** bareness rather than the underlying repo's. From
inside a linked worktree of a bare repo, that returns `"false"`
even though `<common_dir>/config` has `core.bare = true`. Repos
discovered while standing inside one of their worktrees were
therefore mis-flagged non-bare.

Downstream symptom (the reproducer): in worktree.nvim's graph
dashboard (`<leader>gt`), pressing **`C`** (Checkout) on a remote
branch row of a bare repo fell into the non-bare branch
(`graph.lua:766`) and ran `git checkout <branch>` against the
current working tree instead of `git worktree add --track -b
<local> <path> <remote-ref>`. The user lost their checked-out
state where they expected a new tracking worktree.

### Changed

- **`lua/auto-core/git/graph.lua` — `_probe(dir)`**: drop
  `--is-bare-repository` from the rev-parse batch. After
  resolving `common_dir`, read bareness from the common-dir's
  own config:
  ```
  git --git-dir=<common> config --bool --default false core.bare
  ```
  Adds one git invocation per probed dir (fan_out probes at most
  a handful, bounded by `max_depth=3`).
- **`version.lua`** bumped to `0.1.10`.

### Notes

- `AutoCoreGraphRepo.is_bare` is unchanged in shape; only its
  derivation changed. Consumers that branch on it (worktree.nvim
  `checkout_at_cursor` / `new_at_cursor`) need no source updates —
  worktree.nvim picks the fix up via its caret pin (`^0.1.0`).
- The smoke test for non-bare repos (`[44] fan_out repo-a not
  bare`) continues to pass: a freshly `git init`-ed repo has no
  `core.bare` in config and the new probe defaults to `false`.

## [v0.1.9] — 2026-05-14 — bootstrap template instructs agents on `wake` + `addressbook`

The agent-facing protocol doc (`mailbox/templates/bootstrap.md`)
referenced `send_slot` as the wake command and listed legacy
example commands (`harpoon, send_slot, openDiff, ...`). Now that
the canonical wake command is registered as `wake` (auto-agents
v0.2.8) and `addressbook` is the agreed peer-discovery primitive,
the template tells agents how to use them.

### Changed

- **`mailbox/templates/bootstrap.md`**:
  - `schema_version: 2` → `3`. Agents that audit revisions per
    the protocol will re-read the doc on next wake.
  - Wake-protocol section now references `wake` (was `send_slot`).
  - "Whitelisted commands only" bullet replaced with a concrete
    table of the current command surface: `wake`, `addressbook`,
    `send_user`. Notes that other plugins may register their own.
  - New **`## Discovering peers — the addressbook command`** section
    showing the exact JSON shape an agent sends to query the
    addressbook + the response shape (with `value.addresses[]`).
  - Closing line "`send_slot` wakes lightweight" → "`wake` nudges
    lightweight".
- **`version.lua`** bumped to `0.1.9`.

### Notes

- The doc revision is sha256 of the template body, so this edit
  auto-generates a new revision. On next `mailbox.register()`,
  every existing per-tool-root bootstrap doc is re-upserted with
  the new content + revision; agents detect the change via their
  `seen-revision` audit and re-read the doc.
- No Lua-API change. Consumers (auto-agents v0.2.8+) already
  registered `wake` + `addressbook` with the registry; this
  patch lets agents discover that surface from the doc instead
  of guessing.

## [v0.1.8] — 2026-05-14 — mailbox per-instance isolation + per-tool-root bootstrap doc

Major reshape of the mailbox directory layout to support running
multiple nvim instances on the same user account without cross-
talk. The shared `~/.<tool>/mailbox/` tree is now subdivided by
**instance_id** (`<unix-seconds>-<pid>` of the nvim process), so
`agent:jarvis` in nvim-A and `agent:jarvis` in nvim-B live at
non-overlapping paths and the kernel itself enforces isolation —
no router lock, no host-id stamping, no response-routing logic
needed.

This is technically a persisted-schema change (existing
pre-v0.1.8 `<root>/agent:<name>/` dirs become orphaned), shipped
as a patch bump per explicit user decision. The only known
consumer (auto-agents) updates alongside; orphan dirs are
eligible for the new `mailbox.prune` sweep.

### Added

- **`mailbox.get_instance_id()` / `mailbox.set_instance_id(id)`**
  — read/override the per-nvim instance id. Default is computed
  lazily as `<os.time>-<getpid>`; set_instance_id is primarily
  for tests pinning to a known value.
- **`mailbox.path.full_id(id)` / `path.bare_id(id)` /
  `path.is_full_id(id)`** — id-shape helpers. Bare ids are the
  human form (`agent:lector`); full ids carry the instance
  suffix (`agent:lector:1747309200-3478472`). `full_id` is the
  identity transform for already-suffixed inputs.
- **`mailbox.path.bootstrap_doc_path(tool_or_root)`** — resolves
  to `<tool-root>/bootstrap-mailbox.md` (per-tool-root layout).
- **`mailbox.env_for_agent(record)`** — returns the env-var table
  an agent needs at spawn time so it can locate its own mailbox
  without socket access (sandbox-safe). Keys:
  `AUTO_AGENTS_INSTANCE_ID`, `AUTO_AGENTS_MAILBOX_ID` (full),
  `AUTO_AGENTS_MAILBOX_DIR`, `AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC`.
- **`mailbox.prune({ root, max_age_seconds })`** — sweeps stale
  instance dirs under `root` (or every registered root). Skips
  currently-registered live ids; deletes anything whose mtime is
  older than `max_age_seconds` (default 7 days). Returns
  `{ removed, kept_alive, kept_recent, failed }`. Bare-id orphan
  dirs from pre-v0.1.8 are pruneable by age (they can never be
  "live" in v0.1.8 since registrations are always full now).

### Changed

- **`mailbox.register(id, opts)`** — auto-suffixes bare ids
  (`agent:lector` → `agent:lector:<instance_id>`). Already-full
  ids pass through. Returns a record with `id` = full,
  `bare_id` = caller's input. The on-disk dir layout becomes
  `<root>/<full_id>/{inbox,outbox,responses,processing,archive}/`.
- **`mailbox.bootstrap.upsert(opts)`** — accepts
  `{ tool_root }` and writes to
  `<tool_root>/bootstrap-mailbox.md` (one doc per tool root,
  shared across every mailbox in that root). The previous
  `{ id, dir, wake }` shape is gone; bootstrap rendering is now
  agent-agnostic (identity flows through env vars, not template
  substitutions).
- **`mailbox.bootstrap.render(opts?)`** — template-only render
  with no per-call substitutions beyond `revision` /
  `upserted_at`. Two calls produce identical revisions
  regardless of caller-side state. The doc no longer bakes in
  any specific agent id or wake hook.
- **Bootstrap template (`templates/bootstrap.md`)** — rewritten
  to schema_version 2. Agents discover their identity via the
  four `AUTO_AGENTS_*` env vars at spawn; the doc walks them
  through the audit protocol, mailbox layout, message shape,
  and Codex writable_roots config without ever naming a
  specific agent.
- **Event payloads** — `core.mailbox:*` events emit **bare ids**
  in `mailbox` / `from` / `to` fields (human-friendly for
  filtering), with companion `_full` / `_resolved` fields
  carrying the full instance-suffixed form when needed (e.g.,
  for cross-instance routing).
- **`registry.get(id)` / `registry.unregister(id)`** — accept
  bare or full ids; bare resolves against this nvim's
  instance_id. Cross-instance lookups must use full ids
  explicitly.
- **Schema version** — template frontmatter bumped 1 → 2.
  Agent-side seen-revision check naturally catches the
  protocol update on next wake.

### Removed

- **Per-mailbox `bootstrap-mailbox.md` writes** at
  `<mailbox-dir>/bootstrap-mailbox.md` — replaced by the
  per-tool-root layout. Orphan files at the old locations are
  harmless (no longer read) and will be swept by `prune` once
  their parent dir's mtime trips the age threshold.

### Tests — `tests/smoke.lua`

- Section `[49c]` flipped to expect `<root>/<full_id>/` dirs.
  `lector_rec.id == FULL("agent:lector")` and friends; bare-id
  retained on `record.bare_id` for executioner / display checks.
- Section `[49c2]` rewritten end-to-end: doc at tool root,
  shared across same-root agents, agent-agnostic content,
  v0.1.7's revision-skip carried through. Adds env_for_agent
  coverage.
- Section `[49p]` (new) — `mailbox.prune` round trip: plant
  stale instance dirs + a pre-v0.1.8 bare-id orphan, backdate
  them past the threshold, assert removal vs. live-id
  preservation vs. recent-dir retention. Bootstrap doc at
  tool root is left intact.
- The whole section pins `instance_id` to `"9999999999-12345"`
  via `path.set_instance_id` so exact-equality assertions are
  deterministic across runs. Pin is applied AFTER the
  `[49a]` env-var resets (each reset clears the pin).

## [v0.1.7] — 2026-05-14 — mailbox bootstrap: revision-based no-op short-circuit

Additive patch on the mailbox subsystem. `register(id, opts)` no
longer rewrites `bootstrap-mailbox.md` when the existing doc's
revision already matches the rendered revision — the most common
case once an agent is established.

Motivation: the existing always-rewrite path bumped the bootstrap
doc's mtime on every `register()` call, even when the protocol
hadn't changed. That fires the router's fs.watch on the same file,
publishes spurious `core.mailbox:bootstrap_upserted` events, and
forces any agent-side caches that watch the doc to re-evaluate
for no gain. The skip path removes all of that without changing
the agent-side audit semantics (agents still compare the
`revision:` frontmatter to their persisted `seen-revision`).

### Changed — `auto-core.mailbox.bootstrap.upsert`

- Renders the doc into memory, computes the revision (sha256 of
  the rendered body with `revision` + `upserted_at` placeholders),
  then reads the **first ~512 bytes** of the existing doc on disk
  to extract its `revision:` frontmatter line.
- If the existing revision matches the rendered revision, returns
  `{ path, revision, wrote = false }` and does NOT touch the file.
- If they differ (or the doc is missing / malformed), performs
  the same atomic write as before and returns `{ path, revision,
  wrote = true }`.
- The frontmatter read is anchored at line-start (`\nrevision:`)
  so a `revision:` token appearing in the body cannot mis-match.

### Added — return-shape

- **`bootstrap.upsert` return value** now carries `wrote:
  boolean`. `path` and `revision` keep their existing meaning;
  callers that read only those fields are unaffected.
- `registry.register` propagates the new field through the
  `record.bootstrap` table — `record.bootstrap.wrote` is `false`
  on a no-op upsert, `true` on a real write.
- The published `core.mailbox:registered` event payload's
  `bootstrap_path` + `bootstrap_revision` are unchanged.

### Tests — `tests/smoke.lua` [49c2]

- Flipped the long-standing "re-register bumps mtime" assertion:
  re-registering with identical inputs now MUST leave mtime
  unchanged, and the returned record carries `wrote == false`.
- Added a positive-case assertion: re-registering with a different
  `wake.args.slot` MUST bump mtime, return `wrote == true`, and
  produce a different revision than the first registration.
- Restored the canonical wake at the end of the section so the
  downstream [49d]+ tests see the wake shape they expect.

### Maintenance — stale literal-version assertions

The smoke `[1]` and `[48]` sections carried hardcoded
`v.version == "0.1.5"` assertions that were left "stale on
purpose so the failure stays discoverable" (per the in-source
comments). Updated both to assert the version matches the
`^0%.1%.%d+$` pattern, so patch bumps stop generating
maintenance noise. The api_version assertion (`"0.1"`) is
unchanged.

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
