---auto-core.todo.where — from a Neovim project root to the daemon's store.
---
---The old store was "the root's override, else <root>/.todo-list". The daemon
---names a store by an `At` (ADR 1791532020 §2.4): a workspace's name, or
---`{root = "/abs/project"}`. The daemon's `$WORKSPACE` is the At's root, so the
---At matters: the rule (design note 2026-10-13 §3, decided) is
---
---  1. S = the root's Lua override (frozen in state `todo.dir_overrides`), else
---     <root>/.todo-list;
---  2. the At is the workspace whose <root>/.todo-list is S, else {root};
---  3. the daemon learns the root once: set_dir(override) or register(root);
---  4. todos.open(At, {kb_root});
---  5. the first call claims the store (the cutover, ADR §3 step 3), with
---     legacy_workspace = the Neovim root, which is what Lua's $WORKSPACE meant.
---
---A claim runs once per root (recorded in state `todo.cutover`, by store id). A
---store this Neovim claimed and later finds unclaimed was released on purpose (a
---rollback): it is never claimed again until `:AutoCoreTodoClaim`.
---
---Every function here except `local_dir`, `cached` and `reset` runs inside
---`daemon.run`.
---@module 'auto-core.todo.where'

local daemon  = require("auto-core.todo.daemon")
local paths   = require("auto-core.todo.paths")
local fs_path = require("auto-core.fs.path")

local LOG_COMPONENT = "auto-core.todo"

local M = {}

M.MARKER = ".autodoc-owner"

local _ctx = {}       -- root → { root, at, store, store_id, claimed, released, writable }
local _vars_sent = {} -- store id → true once Lua's user vars were offered to the daemon
local _warned = {}

local function state()
  return require("auto-core.state").namespace("todo", { persist = "json" })
end

---warn_once notifies a message once per session per key.
---@param key string
---@param msg string
function M.warn_once(key, msg)
  if _warned[key] then return end
  _warned[key] = true
  local ok, log = pcall(require, "auto-core.log")
  if ok and log and type(log.notify) == "function" then
    pcall(log.notify, msg, { level = "warn", component = LOG_COMPONENT })
  end
end

local function realpath(p)
  local r = vim.uv.fs_realpath(p)
  if type(r) == "string" and r ~= "" then return r end
  return fs_path.normalize(p)
end

---root is the session's project root, as Lua's $WORKSPACE resolves it.
---@return string
function M.root() return paths.workspace_root() end

---override is the root's Lua-side override, or nil.
---@param root string
---@return string?
function M.override(root)
  local o = (state():get("dir_overrides") or {})[root]
  if type(o) == "string" and o ~= "" then return o end
  return nil
end

---local_dir is the store directory as Lua resolves it: the override, else
---<root>/.todo-list. It touches nothing, so it answers without the daemon.
---@param root string
---@return string
function M.local_dir(root)
  local o = M.override(root)
  if o then return paths.resolve_todo_dir(o) end
  return paths.default_todo_dir(root)
end

---set_override mirrors a store directory into Lua state, for readers of the
---frozen key (autodoc's kb.migrate) during the one minor the shim lives.
---@param root string
---@param dir string?
function M.set_override(root, dir)
  local ns = state()
  local o = vim.deepcopy(ns:get("dir_overrides") or {})
  o[root] = dir
  ns:set("dir_overrides", o)
end

function M.cached(root) return _ctx[root] end

---reset forgets a root's resolution (all roots without one).
---@param root string?
function M.reset(root)
  if root then _ctx[root] = nil else _ctx = {} end
end

---memo is the record of the claims this Neovim made, by store id.
---@return table<string, { roots: table<string, string> }>
local function memo_get()
  local m = state():get("cutover")
  return type(m) == "table" and vim.deepcopy(m) or {}
end

local function memo_set(m) state():set("cutover", m) end

---forget_release clears the rollback guard for a store, so the next call claims
---it again (:AutoCoreTodoClaim).
---@param store_id string
function M.forget_release(store_id)
  local m = memo_get()
  m[store_id] = nil
  memo_set(m)
  M.reset()
end

local function check(err, tolerate)
  if err and err.code ~= tolerate then daemon.fail(err) end
end

---claim claims the At's store with legacy_workspace = root, and records it.
local function claim(at, root, store_id, store)
  local legacy = realpath(root)
  local _, err = daemon.rpc("todos.claim", { at, { legacy_workspace = legacy } })
  check(err)
  local m = memo_get()
  m[store_id] = m[store_id] or { roots = {} }
  m[store_id].roots = m[store_id].roots or {}
  m[store_id].roots[legacy] = os.date("!%Y-%m-%dT%H:%M:%SZ")
  memo_set(m)
  -- The daemon marks a directory that is a store at the claim, and one that is
  -- not a store yet (no buckets) at its scaffold.
  if fs_path.is_dir(store .. "/open") and not fs_path.exists(store .. "/" .. M.MARKER) then
    M.warn_once("marker:" .. store_id, "auto-core.todo: the store " .. store
      .. " is claimed but has no " .. M.MARKER .. " marker")
  end
end

---offer_vars gives the daemon Lua's user vars it lacks, once per store per
---session: refs resolve against the daemon's vars after the cutover.
local function offer_vars(at, store_id)
  if _vars_sent[store_id] then return end
  _vars_sent[store_id] = true
  local have = {}
  local list = daemon.rpc("todos.vars", { at })
  for _, v in ipairs(daemon.list_of(list)) do
    if type(v) == "table" and v.name then have[v.name] = v.value end
  end
  local ok, user = pcall(function()
    local out = {}
    for _, v in ipairs(require("auto-core.todo.vars").list()) do
      if not v.builtin and type(v.value) == "string" then out[#out + 1] = v end
    end
    return out
  end)
  if not ok then return end
  for _, v in ipairs(user) do
    if have[v.name] ~= v.value then
      daemon.rpc("todos.set_var", { v.name, v.value })
    end
  end
end

---ensure resolves a root to its store, claiming it on the first call. Runs inside
---daemon.run; raises on a daemon error.
---@param root string
---@return table ctx { root, at, store, store_id, claimed, released, writable }
function M.ensure(root)
  local c = _ctx[root]
  if c then return c end

  local S = realpath(M.local_dir(root))
  local at
  local list, lerr = daemon.rpc("workspace.list", {})
  check(lerr)
  for _, ws in ipairs(daemon.list_of(list)) do
    if type(ws) == "table" and type(ws.root) == "string" and type(ws.name) == "string"
      and realpath(ws.root) .. "/.todo-list" == S then
      at = ws.name
      break
    end
  end

  local override = M.override(root)
  if override then
    if fs_path.is_dir(override) then
      local _, err = daemon.rpc("todos.set_dir", { { root = root }, override })
      check(err)
    else
      M.warn_once("override:" .. root, "auto-core.todo: the store directory " .. override
        .. " set for " .. root .. " does not exist")
    end
  elseif not at then
    local _, err = daemon.rpc("todos.register", { root })
    check(err)
  end
  at = at or { root = root }

  local ok_kb, kb = pcall(require, "auto-core.kb")
  local kb_root = ok_kb and type(kb.root) == "function" and kb.root(root) or nil
  local open_params = { at }
  if type(kb_root) == "string" and kb_root ~= "" then open_params[2] = { kb_root = kb_root } end
  local _, oerr = daemon.rpc("todos.open", open_params)
  check(oerr, daemon.NOT_A_STORE)

  local r, rerr = daemon.rpc("todos.resolve", { at })
  check(rerr)
  c = { root = root, at = at, store = r.store, store_id = r.store_id,
        writable = r.writable, claimed = r.claimed == true, released = false }

  local mine = memo_get()[r.store_id]
  if not c.claimed then
    if mine then
      -- This Neovim claimed it and it is unclaimed now: a deliberate release.
      c.released = true
      M.warn_once("released:" .. r.store_id, "auto-core.todo: the store " .. r.store
        .. " was released (a rollback?); auto-core will not claim it again. "
        .. ":AutoCoreTodoClaim claims it on purpose.")
    else
      claim(at, root, r.store_id, r.store)
      c.claimed = true
    end
  elseif not (mine and mine.roots and mine.roots[realpath(root)]) then
    -- Claimed already (another root, or another Neovim): run this root's legacy
    -- $WORKSPACE rewrite once.
    claim(at, root, r.store_id, r.store)
  end

  offer_vars(at, r.store_id) -- best effort: its rpc errors are ignored, never raised
  _ctx[root] = c
  return c
end

---Test seam.
function M._reset_for_tests()
  _ctx, _vars_sent, _warned = {}, {}, {}
end

return M
