# Changelog

All notable changes to `auto-core.nvim` are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com),
and from `v0.1.0` onward this project follows the
[`auto-core-maintenance`](https://github.com/yongjohnlee80/auto-agents)
convention's **additive-only minor-bump** rule: no `v0.X.Y` will ever
rename, remove, or break-shape an existing function, state-namespace
key, event topic, or persisted schema. Removals require a deprecation
cycle plus a major bump.

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
