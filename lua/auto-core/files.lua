---auto-core.files — global user preferences for file-tree visibility.
---
---Two booleans, both default `true`:
---
---  files.show_hidden    -- show gitignored files (false = hide them)
---  files.show_dotfiles  -- show files starting with `.` (false = hide them)
---
---Backed by `state.namespace("core")` JSON-persisted, so the prefs
---survive nvim restart. Scope is **global** (user preference; not
---per-project) — same toggles affect every workspace.
---
---Consumers:
---  - auto-finder's `files show/hide hidden|dotfiles` admin verbs
---    (writes through to keep auto-core canonical)
---  - md-harpoon's `find()` snacks-picker invocation (reads to set
---    `hidden` / `ignored` opts so picker matches the panel's filter)
---  - any future plugin that wants the same prefs
---
---Public surface:
---
---  files.get_show_hidden()              → boolean
---  files.set_show_hidden(value)
---  files.get_show_dotfiles()            → boolean
---  files.set_show_dotfiles(value)
---  files.watch_show_hidden(callback)    → handle
---  files.watch_show_dotfiles(callback)  → handle
---
---Each watch_* helper subscribes the callback to
---`state.core:files.show_hidden:changed` /
---`state.core:files.show_dotfiles:changed`. Callbacks receive the
---auto-core state-change payload `{ namespace, key, new, old }`.
---@module 'auto-core.files'

local state_mod = require("auto-core.state")

local M = {}

-- Lazy-init: state.namespace runs file IO; deferring keeps `require`
-- cheap. Same idempotent pattern as auto-core.git.worktree's
-- claim_state — additional defaults non-destructively merge into the
-- existing "core" namespace claim from worktree (active_worktree +
-- workspace_root keys live in the same namespace).
local _ns = nil
local function _claim()
  if _ns then return _ns end
  _ns = state_mod.namespace("core", {
    defaults = {
      files = {
        show_hidden   = true,
        show_dotfiles = true,
      },
    },
    persist = "json",
  })
  return _ns
end

---@return boolean
function M.get_show_hidden()
  local v = _claim():get("files.show_hidden")
  if v == nil then return true end
  return v == true
end

---@param value boolean
function M.set_show_hidden(value)
  _claim():set("files.show_hidden", value == true)
end

---@return boolean
function M.get_show_dotfiles()
  local v = _claim():get("files.show_dotfiles")
  if v == nil then return true end
  return v == true
end

---@param value boolean
function M.set_show_dotfiles(value)
  _claim():set("files.show_dotfiles", value == true)
end

---@param callback fun(payload: { namespace: string, key: string, new: any, old: any })
---@return any
function M.watch_show_hidden(callback)
  return _claim():watch("files.show_hidden", callback)
end

---@param callback fun(payload: { namespace: string, key: string, new: any, old: any })
---@return any
function M.watch_show_dotfiles(callback)
  return _claim():watch("files.show_dotfiles", callback)
end

---Test-only — restore both flags to defaults (true).
function M._reset_for_tests()
  if _ns then
    pcall(function()
      _ns:set("files.show_hidden", true)
      _ns:set("files.show_dotfiles", true)
    end)
  end
  _ns = nil
end

return M
