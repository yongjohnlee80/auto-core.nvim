---Canonical topic registry for auto-core's event bus.
---
---Each entry documents a topic: who publishes it, what the payload
---looks like, and a one-line description. The registry is the
---contract — adding a new topic is a deliberate API addition that
---requires an entry here.
---
---`auto-core.events` consults this registry at two points:
---
---  1. On `publish(topic, ...)` — if `topic` isn't registered AND
---     `cfg.events.strict_topics == true`, log a warn-level message.
---     With strict mode off (default) the publish proceeds — we
---     don't want unknown topics to break runtime behavior, just to
---     surface them.
---
---  2. On `:AutoCoreEventTrace` — registered topics get formatted
---     with their payload doc; unregistered ones surface as such.
---
---Phase 1 ships a minimal registry covering the panel + core
---ambient state events. Producers (auto-agents, auto-finder, etc.)
---will add their own topic entries as they migrate in subsequent
---phases.
---@module 'auto-core.events.topics'

---@class AutoCoreTopicSpec
---@field doc string             -- one-line description
---@field payload string         -- pseudo-typedef of the payload table shape
---@field publishers string[]    -- which plugins emit this (informational)

---@type table<string, AutoCoreTopicSpec>
local M = {
  -- ── core ambient state ────────────────────────────────────────
  ["core.cwd:changed"] = {
    doc = "Vim's global working directory changed (DirChanged).",
    payload = "{ from = string, to = string }",
    publishers = { "auto-core" },
  },
  ["core.workspace_root:changed"] = {
    doc = "The session's sticky workspace root was updated explicitly.",
    payload = "{ from = string?, to = string }",
    publishers = { "auto-core", "worktree.nvim" },
  },
  ["core.active_worktree:changed"] = {
    doc = "The currently-selected worktree under workspace_root changed.",
    payload = "{ from = string?, to = string, cwd = string }",
    publishers = { "worktree.nvim" },
  },

  -- ── panel lifecycle ───────────────────────────────────────────
  ["panel:opened"] = {
    doc = "An auto-core.ui.panel singleton just opened.",
    payload = "{ name = string, winid = integer }",
    publishers = { "auto-agents.nvim", "auto-finder.nvim" },
  },
  ["panel:closed"] = {
    doc = "An auto-core.ui.panel singleton just closed.",
    payload = "{ name = string, winid = integer }",
    publishers = { "auto-agents.nvim", "auto-finder.nvim" },
  },
  ["panel:focused"] = {
    doc = "Focus moved INTO an auto-core.ui.panel.",
    payload = "{ name = string, winid = integer }",
    publishers = { "auto-agents.nvim", "auto-finder.nvim" },
  },

  -- ── filesystem (Phase 4b — fs.watch ships these) ──────────────
  -- Three discrete topics so subscribers can filter by change-kind
  -- (e.g. `core.file:deleted` for cleanup-only handlers). Use the
  -- wildcard `core.file:*` to subscribe to all three.
  ["core.file:created"] = {
    doc = "A file or directory was created under a watched dir.",
    payload = "{ path = string, change = 'created', buf = integer? }",
    publishers = { "auto-core" },
  },
  ["core.file:modified"] = {
    doc = "A file under a watched dir was modified (content change).",
    payload = "{ path = string, change = 'modified', buf = integer? }",
    publishers = { "auto-core" },
  },
  ["core.file:deleted"] = {
    doc = "A file or directory was deleted under a watched dir.",
    payload = "{ path = string, change = 'deleted', buf = integer? }",
    publishers = { "auto-core" },
  },
  ["core.fs.watch:partial"] = {
    doc = "fs.watch self-extension (ADR 0042, Linux walker) could not fully cover a "
      .. "runtime-created subtree because the max_handles cap was reached. Live refresh "
      .. "under `path` is partial until handles free up; a manual rescan still sees everything.",
    payload = "{ root = string, path = string, active = integer, attempted = integer, dropped = integer, max = integer }",
    publishers = { "auto-core" },
  },

  -- ── agent task queue + channel + status (Phase 5) ─────────────
  ["agent.task:queued"] = {
    doc = "A task was enqueued for an agent (auto-core.tasks.queue).",
    payload = "{ id = integer, agent = string, priority = string }",
    publishers = { "auto-core", "auto-agents.nvim" },
  },
  ["agent.task:claimed"] = {
    doc = "A queued task was claimed (transitioned to in-progress).",
    payload = "{ id = integer, agent = string }",
    publishers = { "auto-core", "auto-agents.nvim" },
  },
  ["agent.task:completed"] = {
    doc = "A claimed task finished. `result` is opaque per consumer.",
    payload = "{ id = integer, agent = string, result = any? }",
    publishers = { "auto-core", "auto-agents.nvim" },
  },
  ["agent.message:sent"] = {
    doc = "A message was appended to the inter-agent channel log.",
    payload = "{ id, from, to?, body, kind, sent_at, sent_at_iso }",
    publishers = { "auto-core" },
  },
  ["agent.status:changed"] = {
    doc = "An agent's idle/waiting/working state transitioned.",
    payload = "{ agent = string, from = string?, to = string? }",
    publishers = { "auto-core", "auto-agents.nvim" },
  },

  -- ── float lifecycle (Phase 6 — auto-core.ui.float) ───────────
  ["float:opened"] = {
    doc = "An auto-core.ui.float (help_overlay / confirm) just opened.",
    payload = "{ kind = string, buf = integer, win = integer }",
    publishers = { "auto-core" },
  },
  ["float:closed"] = {
    doc = "An auto-core.ui.float closed (dismissed / focus lost / explicit).",
    payload = "{ kind = string, buf = integer, win = integer }",
    publishers = { "auto-core" },
  },

  -- ── lsp lifecycle (auto-core.lsp.reset, ADR 0007 Phase 1) ────
  ["core.lsp:reset"] = {
    doc = "auto-core.lsp.reset.reset_for(path) ran. `stopped` is empty for dry_run or no-op resets.",
    payload = "{ path = string, stopped = { name = string, id = integer }[], detected_stack = string[], dry_run = boolean }",
    publishers = { "auto-core" },
  },

  -- ── git mutations (auto-core.git.{fetch,pull,worktree}, ADR 0007 Phase 3.5) ───
  ["core.git.fetch:started"] = {
    doc = "git.fetch.fetch_one started for one repo.",
    payload = "{ repo = { common_dir, label }, label }",
    publishers = { "auto-core" },
  },
  ["core.git.fetch:completed"] = {
    doc = "git.fetch.fetch_one completed (success or error).",
    payload = "{ repo = { common_dir, label }, label, ok, stderr? }",
    publishers = { "auto-core" },
  },
  ["core.git.pull:started"] = {
    doc = "git.pull.pull_apply started against a worktree.",
    payload = "{ wt = { path, branch }, mode = 'ff'|'reset' }",
    publishers = { "auto-core" },
  },
  ["core.git.pull:completed"] = {
    doc = "git.pull.pull_apply completed (success or error).",
    payload = "{ wt = { path, branch }, mode, ok, stderr? }",
    publishers = { "auto-core" },
  },
  ["core.git.worktree:destroyed"] = {
    doc = "git.worktree.destroy ran (success or error). On success, `branch_err` may carry a non-fatal branch-delete error.",
    payload = "{ repo = { common_dir }, wt = { path, branch?, sha? }, force, ok, err?, branch_err? }",
    publishers = { "auto-core" },
  },
  ["core.git.worktree:added"] = {
    doc = "A new worktree was created via track() or create().",
    payload = "{ repo = { common_dir }, path = string, branch = string, ok = boolean, stderr = string? }",
    publishers = { "auto-core" },
  },
  ["core.git.repo.checkout:started"] = {
    doc = "git.repo.checkout started.",
    payload = "{ path = string, branch = string }",
    publishers = { "auto-core" },
  },
  ["core.git.repo.checkout:completed"] = {
    doc = "git.repo.checkout completed.",
    payload = "{ path = string, branch = string, ok = boolean, stderr = string? }",
    publishers = { "auto-core" },
  },
  ["core.git.repo.remote:deleted"] = {
    doc = "A remote branch was deleted via delete_remote().",
    payload = "{ path = string, remote = string, branch = string, ok = boolean, stderr = string? }",
    publishers = { "auto-core" },
  },
  ["core.git.repo.branch:created"] = {
    doc = "A new branch was created via create_branch().",
    payload = "{ path = string, name = string, base = string, ok = boolean, stderr = string? }",
    publishers = { "auto-core" },
  },
  -- External git-state mutations (commit / checkout / reset / staging /
  -- merge / rebase performed outside this process). Coarse-grained;
  -- subscribers refresh git-derived UI state. Per ADR 0025.
  -- In-process git WRITES (auto-core.git.write, ADR-0060). Distinct from
  -- `core.git.state:changed` below, which means a mutation this process did
  -- NOT make: conflating them would make the external-change signal
  -- untrustworthy. A `:started`/`:completed` pair for the network-bound push,
  -- a single past-tense topic for the fast local ones — matching the
  -- granularity fetch/pull/checkout already use above.
  ["core.git.index:changed"] = {
    doc = "The index was written by THIS process (stage / unstage / stage_all). Published by auto-core.git.write.",
    payload = "{ cwd = string, action = 'stage'|'unstage'|'stage_all'|'reset_soft'|'restore', paths = string[], ok = boolean, stderr = string? }",
    publishers = { "auto-core" },
  },
  ["core.git.commit:completed"] = {
    doc = "A commit made by THIS process finished. Published by auto-core.git.write.",
    payload = "{ cwd = string, ok = boolean, stderr = string? }",
    publishers = { "auto-core" },
  },
  ["core.git.push:started"] = {
    doc = "auto-core.git.write.push began publishing to a remote.",
    payload = "{ cwd = string, label = string }",
    publishers = { "auto-core" },
  },
  ["core.git.push:completed"] = {
    doc = "auto-core.git.write.push finished; `ok` false carries git's stderr.",
    payload = "{ cwd = string, label = string, ok = boolean, stderr = string? }",
    publishers = { "auto-core" },
  },

  ["core.git.state:changed"] = {
    doc = "Repo's .git/ plumbing mutated externally. Published by auto-core.git.watch on libuv fs_event firings under git_dir/ (HEAD/index/ORIG_HEAD/MERGE_HEAD) or git_dir/logs/HEAD (reflog tip).",
    payload = "{ repo_root = string, git_dir = string, kind = 'head'|'index'|'merge'|'reflog'|'other', path = string }",
    publishers = { "auto-core" },
  },

  -- ── mailbox lifecycle (ADR 0013 Phase 1 — auto-core.mailbox) ────
  -- File-backed cross-process transport; topics signal arrival,
  -- claim, completion, failure, and response writes. Subscribers
  -- typically scope by `mailbox` field.
  ["core.mailbox:registered"] = {
    doc = "auto-core.mailbox.register ensured a mailbox's 5-subdir layout + bootstrap doc.",
    payload = "{ mailbox = string, dir = string, root = string, wake = table?, bootstrap_path = string, bootstrap_revision = string, first_time = boolean }",
    publishers = { "auto-core" },
  },
  ["core.mailbox:outbox_routed"] = {
    doc = "The router atomically delivered <sender>/outbox/<id>.json → <recipient>/inbox/<id>.json.",
    payload = "{ from = string, to = string, id = string, path = string }",
    publishers = { "auto-core" },
  },
  ["core.mailbox:outbox_undeliverable"] = {
    doc = "Outbox routing failed (recipient unregistered, rename failed, decode failed). File left in sender's outbox/ for retry.",
    payload = "{ from = string, to = string?, id = string, reason = string, error = string?, path = string? }",
    publishers = { "auto-core" },
  },
  ["core.mailbox:message_queued"] = {
    doc = "A new message landed in <mailbox>/inbox/. The central router fires this on arrival (post-routing).",
    payload = "{ mailbox = string, id = string, kind = string?, from = string?, path = string, correlation_id = string?, message = table?, decode_error = string? }",
    publishers = { "auto-core" },
  },
  ["core.mailbox:response_received"] = {
    doc = "A new response landed in <mailbox>/responses/. Triggers wake hook for the original sender.",
    payload = "{ mailbox = string, correlation_id = string, path = string }",
    publishers = { "auto-core" },
  },
  ["core.mailbox:message_claimed"] = {
    doc = "transport.claim moved a message from inbox/ to processing/.",
    payload = "{ mailbox = string, id = string, path = string }",
    publishers = { "auto-core" },
  },
  ["core.mailbox:message_completed"] = {
    doc = "transport.complete archived a processed message (and optionally wrote a response).",
    payload = "{ mailbox = string, id = string, path = string, response_path = string? }",
    publishers = { "auto-core" },
  },
  ["core.mailbox:message_failed"] = {
    doc = "transport.fail archived a message with status='failed'.",
    payload = "{ mailbox = string, id = string, path = string, error = string?, response_path = string? }",
    publishers = { "auto-core" },
  },
  ["core.mailbox:stale_recovered"] = {
    doc = "recover_stale moved a stale processing/ message — to inbox (requeue) or archive (fail).",
    payload = "{ mailbox = string, id = string, policy = 'fail'|'requeue', age_ms = integer, attempt = integer?, path = string, response_path = string? }",
    publishers = { "auto-core" },
  },
  ["core.mailbox:response_written"] = {
    doc = "A response envelope landed in the sender's responses/ dir.",
    payload = "{ mailbox = string, reply_to = string, correlation_id = string, path = string, ok = boolean }",
    publishers = { "auto-core" },
  },
  ["core.mailbox:response_write_failed"] = {
    doc = "transport.complete failed after an executioner command ran — the sender will never "
      .. "see a response file for this correlation_id. Observability surface for disk-full / "
      .. "permission failures that previously vanished silently (ADR-0038 Batch A).",
    payload = "{ mailbox = string, id = string, error = string }",
    publishers = { "auto-core" },
  },
  ["core.command:registered"] = {
    doc = "commands.register stored a new command handler.",
    payload = "{ name = string, owner = string, description = string? }",
    publishers = { "auto-core", "md-harpoon.nvim", "auto-agents.nvim" },
  },
  ["core.command:executed"] = {
    doc = "commands.handle_message dispatched a registered command.",
    payload = "{ name = string, ok = boolean }",
    publishers = { "auto-core" },
  },
  ["core.command:rejected"] = {
    doc = "commands.reject_unknown / handle_message rejected an unknown command.",
    payload = "{ name = string, reason = string, message_id = string?, from = string?, to = string?, correlation_id = string? }",
    publishers = { "auto-core" },
  },

  -- ── dbase section (database browsing/querying) ──
  -- These six topics were registered for the dbase section's original
  -- nvim-dbee event bridge (ADR 0020). **dbee and that bridge are gone**
  -- — retired in auto-finder v0.4.0, completing the ADR 0049 → 0052
  -- Option-C cutover to autodb as the only dbase backend. The topic KEYS
  -- are a stable cross-plugin contract and stay exactly as they are; only
  -- the metadata below is corrected to describe who publishes them today.
  --
  -- `dbase.connection:changed` is live and published by **autodb**
  -- (`autodb/lua/autodb/session.lua`, TOPIC_SELECTION).
  --
  -- The `dbase.call:*` and `dbase.result:shown` topics currently have
  -- **no publisher**: the dbee bridge that emitted them was deleted and
  -- autodb does not yet surface per-call lifecycle. They remain
  -- registered and reserved so that (a) existing subscribers keep
  -- resolving, and (b) autodb can adopt them without re-minting names.
  -- A subscriber to those five will simply never fire today — an honest
  -- empty `publishers` list is how that is advertised.
  ["dbase.connection:changed"] = {
    doc = "The active database connection switched.",
    payload = "{ id = string, name = string?, type = string? }",
    publishers = { "autodb" },
  },
  -- NOTE on `conn_id` on the call.* topics: best-effort, may be nil.
  -- It was optional because dbee's CallDetails carried no connection id
  -- and the bridge enriched it after the fact; the field stays optional
  -- for whoever publishes these next, since a call archived late can
  -- still outlive the connection it ran under.
  ["dbase.call:started"] = {
    doc = "A query was submitted (call enters pending/executing state). No current publisher.",
    payload = "{ call_id = string, conn_id = string?, query = string }",
    publishers = {},
  },
  ["dbase.call:state_changed"] = {
    doc = "A call's internal state transitioned (e.g. pending → executing → archived). Use this for fine-grained progress UIs; the discrete completed/failed topics below are the standard terminal signals. No current publisher.",
    payload = "{ call_id = string, conn_id = string?, from = string?, to = string }",
    publishers = {},
  },
  ["dbase.call:completed"] = {
    doc = "A call finished successfully. No current publisher.",
    payload = "{ call_id = string, conn_id = string?, rows = integer?, duration_ms = integer? }",
    publishers = {},
  },
  ["dbase.call:failed"] = {
    doc = "A call ended in error. No current publisher.",
    payload = "{ call_id = string, conn_id = string?, err = string }",
    publishers = {},
  },
  ["dbase.result:shown"] = {
    doc = "The result view rendered a call's output (or paged within it). No current publisher.",
    payload = "{ call_id = string, page = integer?, total_pages = integer? }",
    publishers = {},
  },

  -- ── doc pinning (md-harpoon — ADR 0006 + auto-core-todos) ───────
  ["doc:pinned"] = {
    doc = "A document was pinned to one of md-harpoon's slots (or repinned to a different path).",
    payload = "{ slot = string, path = string, source_bufnr = integer? }",
    publishers = { "md-harpoon.nvim" },
  },
  ["doc:unpinned"] = {
    doc = "A previously-pinned slot was cleared (or the panel was closed).",
    payload = "{ slot = string, path = string? }",
    publishers = { "md-harpoon.nvim" },
  },
}

return M
