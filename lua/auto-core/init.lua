---auto-core.nvim — foundation library for the AutoVim plugin family.
---
---Provides the shared event bus, namespaced state management,
---reusable UI primitives, fs/git introspection, and agent task-queue
---infrastructure that auto-agents, auto-finder, md-harpoon,
---worktree, gitsgraph, remote-sync, and gobugger all consume.
---
---Architecture: see ADR 0006 in the auto-agents kb.
---  ~/.config/nvim/.auto-agents-config/kb/shared/adrs/0006-auto-core-shared-library.md
---
---Public surface (Phase 0 — empty stubs only; subsystems land in
---subsequent phases per the ADR's migration plan):
---
---  M.version       package semver
---  M.api_version   API surface semver (independent of package)
---  M.setup(opts)   one-time configuration entrypoint
---  M.events        pub/sub bus       (Phase 1)
---  M.state         namespaced state  (Phase 2)
---  M.ui            UI primitives     (Phase 3)
---  M.fs            fs introspection  (Phase 4)
---  M.git           git introspection (Phase 4)
---  M.tasks         agent tasks       (Phase 5)
---  M.log           structured logger (Phase 7)
---  M.health        :checkhealth      (Phase 7)
---
---Hard rule from ADR 0006: this module never `require`s a family
---plugin (no `require("auto-agents")`, etc.). Dependency direction
---is one-way: auto-core ← family plugins.
---@module 'auto-core'

local M = {}

local v = require("auto-core.version")
M.version     = v.version
M.api_version = v.api_version

---@class AutoCoreConfig
---@field events { fire_autocmds: boolean?, strict_topics: boolean?, trace_capacity: integer? }?
---@field log    { level: string }?           -- "error" | "warn" | "info" | "debug" | "trace"
---@field state  { persist_dir: string }?     -- override the default persist root (~/.config/nvim/.auto-core/)
M.defaults = {
  events = {
    -- Opt-in compatibility shim per ADR §6: when true, `publish(topic)`
    -- ALSO fires `:autocmd User AutoCore_<flattened_topic>` so legacy
    -- autocmd-style subscribers can listen. Default off — the publish
    -- path stays lean.
    fire_autocmds  = false,
    -- When true, publishing a topic that isn't in events/topics.lua
    -- emits a one-time warn-level notification. Default off — unknown
    -- topics are allowed at runtime; strict mode is for development.
    strict_topics  = false,
    -- Ring-buffer capacity for `:AutoCoreEventTrace`. 200 ≈ 16 KB of
    -- entries; raise for noisy debugging sessions.
    trace_capacity = 200,
  },
  log    = { level = "info" },
  state  = { persist_dir = nil },
}

---@type AutoCoreConfig
M.config = vim.deepcopy(M.defaults)

M._initialized = false

-- ── subsystems (lazy-required so Phase-N code only loads when used) ──
-- Phase 1: events (pub/sub bus).
-- Phase 2: state  (namespaced store).
-- Phase 3: ui     (panel + winbar + section primitives).
-- Subsequent phases attach further subsystems on this table the same
-- way.
M.events = require("auto-core.events")
M.state  = require("auto-core.state")
M.ui     = require("auto-core.ui")

---Initialize auto-core. Idempotent — re-calling re-applies opts and
---propagates the relevant subset to each subsystem.
---@param opts AutoCoreConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  -- Forward events config. Done on every setup so a re-setup with
  -- new opts (e.g. flipping fire_autocmds on mid-session) takes
  -- effect immediately.
  M.events.configure({
    fire_autocmds  = M.config.events and M.config.events.fire_autocmds,
    strict_topics  = M.config.events and M.config.events.strict_topics,
    trace_capacity = M.config.events and M.config.events.trace_capacity,
  })

  -- Forward state config. The persist_dir override (when set)
  -- redirects every namespace's on-disk file. NB: this only takes
  -- effect for namespaces claimed AFTER setup; pre-claimed ones
  -- keep their resolved paths (rare in practice — setup runs before
  -- consumer plugins).
  M.state.configure({
    persist_dir = M.config.state and M.config.state.persist_dir,
  })

  M._initialized = true
end

return M
