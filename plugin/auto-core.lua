if vim.g.loaded_auto_core then
  return
end
vim.g.loaded_auto_core = true

-- Phase 0: no user commands shipped yet. Subsystems register their
-- :AutoCore* user commands as they land in subsequent phases:
--   Phase 1: :AutoCoreEventTrace (events ring-buffer viewer)
--   Phase 5: :AutoCoreChannel    (agent communication monitor)
--   Phase 7: :checkhealth auto-core
--
-- The auto-core module itself is required lazily on first use by a
-- consumer plugin (or by the user calling require("auto-core").setup).
-- We do NOT call setup() here — consumers are expected to install
-- via lazy.nvim's `dependencies = { "yongjohnlee80/auto-core.nvim" }`
-- and call setup themselves at the appropriate event.
