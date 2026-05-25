---Canonical header-comment emitter for auto-core todo task files.
---
---Every new file emitted by `auto-core.todo.add()` begins with the
---block returned by `header.emit()`. The header is informational only —
---parsers ignore comments — but it is the first thing a human opening
---the file sees, and it draws a clear line between fields a human may
---safely hand-edit and fields the system manages.
---
---The exact text below is the canonical form per ADR-0031 §2. If you
---change it, update the ADR and the bootstrap todo doc in lockstep.
---@module 'auto-core.todo.header'

local M = {}

---Returns the header-comment block as a multi-line HTML comment,
---suitable for embedding inside the markdown body between the
---YAML frontmatter and the H1 title. **Not** including a trailing
---blank line — callers concatenate the header into the body and
---add their own separator.
---@return string
function M.emit()
  return table.concat({
    "<!-- ─── auto-core.todo schema v1 — managed file ───",
    "     HAND-EDIT FREELY in this body (the description) or the",
    "       hand-editable frontmatter fields: title, status, due,",
    "       priority, assignee, tags, adr, review, blocked.",
    "       Direct `status` edits to a valid enum value are honored —",
    "       refresh reconciles the file's directory. BUT side effects",
    "       (mailbox notifications, assignee fan-out) only fire when",
    "       status changes go through the API (`todo.status` /",
    "       `todo.assign`). Prefer the API when other agents need",
    "       to know.",
    "     DO NOT HAND-EDIT frontmatter: id, version, created, updated,",
    "       status_changed, completed_at, archived_at, errors.",
    "         • id + created are frozen at creation.",
    "         • version / updated / lifecycle timestamps / errors are",
    "           written by refresh + API calls. Manual edits silently",
    "           break archive timing and cross-references.",
    "     ─────────────────────────────────────────────── -->",
  }, "\n")
end

---True iff the supplied body string already carries the canonical
---HTML-comment header somewhere in its first few hundred bytes.
---Useful for refresh-driven rewrites that want to detect a header
---written by an earlier version of the emitter.
---@param body string  the markdown body (post-frontmatter)
---@return boolean
function M.is_present(body)
  if type(body) ~= "string" then return false end
  return body:find("<!%-%- ─── auto%-core%.todo schema v1", 1, false) ~= nil
end

return M
