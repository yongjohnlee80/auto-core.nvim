---Diagnostic probes for the AutoVim family — opt-in, off-path,
---off-cost. Anything on `auto-core.debug.*` is a tool the user turns
---ON to investigate a bug, then turns OFF. Nothing under this
---namespace runs at setup time.
---
---Sub-modules (probes):
---   `winlog` — window/buffer lifecycle logger. Detects panel
---     singleton violations, stray panel-buffer hijacks, and splits
---     made under `eventignore = "all"` / `noautocmd = true` that
---     bypass the leak-guard autocmd.
---
---Routing rule: each probe is a self-contained module
---(`auto-core.debug.<probe>`) that exposes a small, uniform API
---(start / stop / toggle / status / is_running). The umbrella
---command `:AutoCoreDebug <probe> <subcmd>` is defined in
---`plugin/auto-core.lua`.
---@module 'auto-core.debug'

local M = {}

M.winlog = require("auto-core.debug.winlog")

return M
