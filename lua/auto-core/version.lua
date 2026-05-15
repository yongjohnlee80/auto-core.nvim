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
  -- v0.1.8: per-instance mailbox isolation. `register("agent:foo")`
  -- now stores the mailbox under `<root>/agent:foo:<instance_id>/`
  -- where instance_id = `<unix-seconds>-<pid>` for this nvim
  -- process. Two nvims sharing a tool root coexist cleanly — no
  -- lock, no cross-talk, hard-isolation by directory. Bootstrap
  -- doc hoisted to `<tool-root>/bootstrap-mailbox.md` (shared
  -- across all mailboxes in that root) with agent identity now
  -- carried via spawn-time env vars rather than per-call template
  -- substitution. Adds `mailbox.env_for_agent(record)` and
  -- `mailbox.prune({ root, max_age_seconds })` helpers. Event
  -- payloads carry bare ids in `mailbox` / `from` fields with
  -- `_full` / `_resolved` companions for cross-instance routing.
  -- Persisted schema change (mailbox dir layout) shipped as patch
  -- per user decision; only known consumer (auto-agents) updates
  -- alongside.
  version     = "0.1.8",
  api_version = "0.1",
}
