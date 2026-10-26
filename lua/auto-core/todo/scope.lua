---auto-core.todo.scope — the project an assignment is made in (ADR 1791532020 r15 §2.5a).
---
---Since the daemon owns the todo store, every Neovim's notifier reads one change log, so a
---bare assignee (`agent:gold-man`) would be delivered by every Neovim with an agent of that
---name. An assignment therefore carries its assigner's scope, which AutoDoc keeps and never
---reads (todos.assign's `scope`, protocol 30), and a notifier delivers a bare assignee only
---when the scope is its own.
---
---The scope is the host's: auto-agents sets `"auto-agents:" .. session_project_key` at setup,
---a key that survives a restart where the mailbox instance id does not. auto-core knows nothing
---of auto-agents. With no scope set, an assignment carries none.
---@module 'auto-core.todo.scope'

local M = {}

-- The protocol todos.assign takes a scope at (AutoDoc's rpc Protocol 30).
M.PROTOCOL = 30

local _scope = nil -- the host's; nil until set

---set records this Neovim's scope; nil or "" clears it.
---@param scope string|nil
function M.set(scope)
  if scope == "" then scope = nil end
  if scope ~= nil and type(scope) ~= "string" then
    error("auto-core.todo.scope.set: a string or nil, not a " .. type(scope), 2)
  end
  _scope = scope
end

---get is this Neovim's scope, nil for none.
---@return string|nil
function M.get() return _scope end

-- A test seam: the protocol autodoc.nvim's contracts declare, or a replacement.
local _protocol = nil

---protocol is the protocol autodoc.nvim speaks, read from its generated contracts (the plugin
---and the daemon ship from one commit, and its session says hello at that protocol). 0 when
---autodoc.nvim can't be loaded.
---@return integer
function M.protocol()
  if _protocol then return _protocol end
  local ok, c = pcall(require, "autodoc.contracts")
  return (ok and type(c) == "table" and tonumber(c.protocol)) or 0
end

---_set_protocol replaces the protocol read (tests); nil reads autodoc.nvim's again.
function M._set_protocol(p) _protocol = p end

---scoped is whether assignments are scoped here: AutoDoc carries a scope (protocol 30 or later).
---Below it, the notifier keeps its v0.5.0 rule (a bare name, by this instance's registry).
---@return boolean
function M.scoped() return M.protocol() >= M.PROTOCOL end

---assign_params are todos.assign's params after id and rev: the assignee, the reason, and this
---Neovim's scope when AutoDoc takes one and a scope is set. The one place both writers (the
---panel's Assign and the todos.assign mailbox verb) build them.
---@param assignee string "" clears
---@param reason string|nil
---@return any[]
function M.assign_params(assignee, reason)
  local p = { assignee }
  local scope = M.get()
  if scope and M.scoped() then
    p[2], p[3] = reason or "", scope
  elseif reason and reason ~= "" then
    p[2] = reason
  end
  return p
end

---add_params are todos.add's params after where: the spec, then this Neovim's scope when the spec
---has an assignee (creating with one is an assignment), AutoDoc takes a scope and one is set.
---@param spec table
---@return any[]
function M.add_params(spec)
  local p = { spec }
  local scope = M.get()
  if scope and M.scoped() and type(spec) == "table" and type(spec.assignee) == "string" and spec.assignee ~= "" then
    p[2] = scope
  end
  return p
end

---bare is whether assignee names an agent by name alone (`gold-man`, `agent:gold-man`), as
---against a full mailbox id (`agent:gold-man:<instance>`), which names its instance.
---@param assignee string
---@return boolean
function M.bare(assignee)
  if type(assignee) ~= "string" or assignee == "" then return false end
  local _, colons = assignee:gsub(":", "")
  return colons == 0 or (colons == 1 and assignee:sub(1, 6) == "agent:")
end

return M
