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
---@field events { fire_autocmds: boolean }?  -- opt-in vim-native autocmd-fire compatibility shim (default false)
---@field log    { level: string }?           -- "error" | "warn" | "info" | "debug" | "trace"
---@field state  { persist_dir: string }?     -- override the default persist root (~/.config/nvim/.auto-core/)
M.defaults = {
  events = { fire_autocmds = false },
  log    = { level = "info" },
  state  = { persist_dir = nil },
}

---@type AutoCoreConfig
M.config = vim.deepcopy(M.defaults)

M._initialized = false

---Initialize auto-core. Idempotent — re-calling re-applies opts.
---Phase 0: no subsystems wired yet; setup just merges config and
---records initialization for `:checkhealth`.
---@param opts AutoCoreConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  M._initialized = true
end

return M
