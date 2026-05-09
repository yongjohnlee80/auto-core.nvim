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
---Pre-1.0 (today): `api_version = "0.0"` — the surface is unstable;
---consumers pin a specific package version. `api_version` flips to
---"0.1" once Phase 2 ships and the events + state surfaces are
---declared stable.
---
---@module 'auto-core.version'

return {
  version     = "0.0.4",
  api_version = "0.0",
}
