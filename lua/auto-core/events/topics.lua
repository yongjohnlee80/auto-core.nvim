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
}

return M
