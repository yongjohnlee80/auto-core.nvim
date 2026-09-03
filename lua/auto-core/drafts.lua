---auto-core.drafts — pending, unsaved work, reachable by every plugin.
---
---ADR-0081 §2.2/§2.5. A draft is work a reader has produced but not committed:
---annotations typed into the diff view before a submit, and by extension any
---set of pending items a surface wants to hold across a close. It lived in
---auto-finder, which meant the plugin holding it was the one no other plugin may
---depend on — so an agent could not read a draft, and the composer that FILLS a
---draft (auto-core's diff view) sat one plugin away from the store it appended
---to. Both are fixed by it living here.
---
---**Nothing here knows what a review is.** Items are opaque tables; `meta` is
---the caller's. The word "verdict" does not appear.
---
---### The contract (ADR-0081 §2.5, lector SF2)
---
---  * **Lifetime is process memory.** Not restart-persistent. A draft is
---    unsaved work, and a store that outlived the editor would resurrect
---    something the reader may have abandoned deliberately.
---  * **It survives every view close** — `q`, `<Esc>`, a lost pane, a
---    programmatic dispose, a `resume`. This is what makes a "close and keep"
---    answer truthful (ADR-0065 §2.10); the draft is not owned by the float.
---  * **It clears on exactly two events:** an explicit `discard`, or a caller
---    reporting a fully successful commit via `clear`. A failed submit and a
---    partial delete leave it intact — losing work on the path where the write
---    already failed is the worst possible moment to lose it.
---  * **The scope is opaque and caller-resolved.** It must be derived from
---    resolved identity — never a window id, never an abbreviation. A caller
---    keying on something that changes under it will silently split or merge
---    drafts.
---  * **Content and context are separate, and only content is work.** `items`
---    and an explicit `touched` bit mean unsaved work; `meta` never does. This
---    predicate first treated any non-empty value in `meta` as content, so a
---    draft holding only the reviewer snapshot §2.5 REQUIRES — zero items —
---    reported dirty, and the close guard would have offered to keep an empty
---    draft the moment it stored the identity it was told to store (lector MF4).
---@module 'auto-core.drafts'

local M = {}

---_store maps scope → draft. Module state, so process-lifetime by construction.
M._store = {}

---new_draft is the empty shape. `items` is an ordered list; `meta` is a free
---table the caller owns — the place a reviewer snapshot belongs, so a draft kept
---across an identity change cannot silently acquire a different author (§2.5).
local function new_draft()
  return { items = {}, meta = {}, touched = false }
end

---_ok validates a scope. A scope must be a non-empty string: a table would be
---compared by identity and a nil would collapse every caller into one bucket.
local function _ok(scope)
  return type(scope) == "string" and scope ~= ""
end

---get returns (and lazily creates) the draft for `scope`.
---
---Returns the LIVE table, deliberately: a caller appends to `items` in place,
---which is what lets a composer in one module and a submit in another see the
---same pending work without a write-back step.
---@param scope string
---@return table? draft
function M.get(scope)
  if not _ok(scope) then return nil end
  M._store[scope] = M._store[scope] or new_draft()
  return M._store[scope]
end

---peek returns the draft for `scope` WITHOUT creating one.
---
---The read a lister needs. `get` would materialise an empty draft for every
---scope it asked about, which would then show up in `scopes()` as work that does
---not exist.
---@param scope string
---@return table?
function M.peek(scope)
  if not _ok(scope) then return nil end
  return M._store[scope]
end

---dirty reports whether a draft holds anything worth keeping.
---
---ONE predicate, and every caller must use it. Three inline variants is how a
---close guard once let a draft go without a prompt while the submit path
---separately refused to write it (ADR-0065 §2.10). Accepts a scope or a draft
---table so a caller with either in hand has no excuse to write its own.
---@param scope_or_draft string|table
---@return boolean
function M.dirty(scope_or_draft)
  local d = scope_or_draft
  if type(d) == "string" then d = M._store[d] end
  if type(d) ~= "table" then return false end
  if #(d.items or {}) > 0 then return true end
  -- `meta` is CONTEXT and never makes a draft dirty. Inferring content from
  -- arbitrary metadata values cannot work: this store is domain-agnostic, so it
  -- has no way to tell a reviewer snapshot (identity the caller was told to
  -- record) from a typed summary (work the reader would lose). A caller with
  -- content outside `items` says so explicitly, via `touch`.
  return d.touched == true
end

---discard drops a draft outright. One of the two events that may clear one.
---@param scope string
---@return boolean removed
function M.discard(scope)
  if not _ok(scope) then return false end
  local had = M._store[scope] ~= nil
  M._store[scope] = nil
  return had
end

---clear drops a draft after a caller reports a FULLY successful commit.
---
---Distinct from `discard` only in intent, and the distinction is the point: it
---documents at the call site that the work was written, not abandoned. A caller
---must not call this on a partial success — §2.5 is explicit that a failed or
---half-completed write leaves the draft alone.
---@param scope string
---@return boolean removed
function M.clear(scope)
  return M.discard(scope)
end

---scopes lists every scope currently holding a draft, sorted.
---
---What a lister needs to show unsaved work beside saved work — a panel section,
---or an agent asked to pick up pre-commit feedback. Sorted so a rendering is
---stable between repaints rather than following hash order.
---@param opts { dirty_only: boolean? }?
---@return string[]
function M.scopes(opts)
  opts = opts or {}
  local out = {}
  for scope, d in pairs(M._store) do
    if not opts.dirty_only or M.dirty(d) then out[#out + 1] = scope end
  end
  table.sort(out)
  return out
end

---touch marks (or unmarks) a draft as holding content that is not an item.
---
---The explicit bit that replaces guessing from `meta`. A composer with a
---summary and no comments calls `touch(scope)`; clearing it back to false is
---allowed so a caller that empties its own field can stop claiming work.
---@param scope string
---@param value boolean?   defaults to true
---@return boolean touched
function M.touch(scope, value)
  local d = M.get(scope)
  if not d then return false end
  d.touched = (value ~= false)
  return d.touched
end

---count returns how many items a draft holds, 0 for an absent one.
---@param scope string
---@return integer
function M.count(scope)
  local d = M.peek(scope)
  return d and #(d.items or {}) or 0
end

---_reset_for_tests empties the store.
function M._reset_for_tests() M._store = {} end

return M
