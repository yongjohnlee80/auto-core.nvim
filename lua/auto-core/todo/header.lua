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

---Returns the header-comment block as a multi-line string, **not**
---including a trailing blank line — callers concatenate the header
---in front of the YAML body and add their own separator.
---@return string
function M.emit()
  return table.concat({
    "# ─── auto-core.todo schema v1 — managed file ───",
    "# HAND-EDIT FREELY: title, description, notes, priority, assignee, tags,",
    "#                   adr, wip, pr, review, links, blocked, status.",
    "#   • Direct `status` edits to a valid enum value are honored — refresh",
    "#     reconciles the file's directory. BUT side effects (mailbox",
    "#     notifications, assignee fan-out) only fire when status changes",
    "#     go through the API (`todo.status` / `todo.assign`). Prefer the",
    "#     API when other agents need to know.",
    "# DO NOT HAND-EDIT: id, version, created, updated, status_changed,",
    "#                   completed_at, archived_at, errors.",
    "#   • id + created are frozen at creation.",
    "#   • version / updated / lifecycle timestamps / errors are written by",
    "#     refresh + API calls. Manual edits silently break archive timing",
    "#     and cross-references.",
    "# ───────────────────────────────────────────────",
  }, "\n")
end

---True iff the supplied source string already starts with the
---canonical header (lenient match — only looks at the first line).
---Useful for refresh-driven rewrites that want to preserve a header
---written by an earlier version of the emitter.
---@param src string
---@return boolean
function M.is_present(src)
  if type(src) ~= "string" then return false end
  return src:match("^# ─── auto%-core%.todo schema v1") ~= nil
end

return M
