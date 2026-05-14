---Version + API-version metadata for auto-core.nvim.
---
---`version` is the package version (`v0.X.Y` git tag — used by lazy.nvim
---when consumers pin via `version = "^0.X.0"`). It bumps on every
---release.
---
---`api_version` is a SEPARATE semver string covering the public Lua
---surface (`require("auto-core").events`, `.state`, `.ui`, `.fs`,
---`.git`, `.tasks`, `.log`, `.health`). It bumps independently of
---`version`:
---  - patch: bug fixes only, no API change
---  - minor: API additions (new functions, new topics, new state keys)
---  - major: API removals or behavior changes
---
---Consumers branch on `api_version` when they need feature-detection
---without pinning a specific package version:
---
---  if require("auto-core").api_version >= "0.2" then ... end
---
---v0.1.0 (2026-05-11) is the **solid beta** — first release covered
---by the `auto-core-maintenance` convention's additive-only minor-
---bump rule. Consumers can safely pin via `version = "^0.1.0"` (caret)
---and trust that no future v0.X.Y will rename, remove, or break-shape
---any existing function, state key, topic, or persisted schema.
---
---@module 'auto-core.version'

return {
  -- v0.1.5 is the last *committed* tag. The mailbox feature is
  -- in-flight on the queue-mailbox branch; we tag the next bump
  -- once the whole feature lands (router + bootstrap + debug
  -- probe + family-plugin wiring). Until then, the working tree
  -- stays at v0.1.5 even as new work is committed onto this branch.
  version     = "0.1.5",
  api_version = "0.1",
}
