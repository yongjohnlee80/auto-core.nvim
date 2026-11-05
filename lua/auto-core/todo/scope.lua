---auto-core.todo.scope — the project an assignment is made in (ADR 1791532020 r15 §2.5a).
---
---Since the daemon owns the todo store, every Neovim's notifier reads one change log, so a
---bare assignee (`agent:gold-man`) would be delivered by every Neovim with an agent of that
---name. An assignment therefore carries its assigner's scope, which AutoDoc keeps and never
---reads (todos.assign's `scope`, protocol 30), and a notifier delivers a bare assignee only
---when the scope is its own.
---
---The scope is the host's: auto-agents sets `"auto-agents:" .. session_project_key` at setup,
---a key that survives a restart where the instance id (auto-core.instance) does not. auto-core knows nothing
---of auto-agents. With no scope set, an assignment carries none.
---@module 'auto-core.todo.scope'

local M = {}

-- The protocol todos.assign takes a scope at (AutoDoc's rpc Protocol 30).
M.PROTOCOL = 30

-- The protocol todos.changes takes scoped at (AutoDoc's rpc Protocol 33): a reader that doesn't
-- pass it is answered a scoped assignment without its assignee, so a notifier that ignores scopes
-- (one still loaded in a Neovim from before an upgrade) can't deliver it in every project.
M.READER_PROTOCOL = 33

-- The protocol todos.assign and todos.add take crew at (AutoDoc's rpc Protocol 54): the assigner's
-- crew scope, from which the answer's reach says where a bare agent assignee is told.
M.CREW_PROTOCOL = 54

-- A scope that names one instance, not a project: "@" .. its instance id. It routes one
-- delivery to that instance alone; see route_of.
M.INSTANCE_PREFIX = "@"

local _scope = nil -- the host's; nil until set
local _crew = nil -- the host's crew scope reader (set_crew); nil until set

---set records this Neovim's scope; nil or "" clears it.
---@param scope string|nil
function M.set(scope)
  if scope == "" then scope = nil end
  if scope ~= nil and type(scope) ~= "string" then
    error("auto-core.todo.scope.set: a string or nil, not a " .. type(scope), 2)
  end
  if scope ~= nil and scope:sub(1, #M.INSTANCE_PREFIX) == M.INSTANCE_PREFIX then
    -- "@<instance>" is an instance route (route_of); a project scope read as one would be
    -- delivered by no Neovim of the project, or by the one instance it happens to name
    error("auto-core.todo.scope.set: a project scope can't start with " .. M.INSTANCE_PREFIX
      .. ", which marks an instance route: " .. scope, 2)
  end
  _scope = scope
end

---get is this Neovim's scope, nil for none.
---@return string|nil
function M.get() return _scope end

---set_crew sets how this Neovim's crew scope is read (or clears it: nil): fn() answers the scope
---its crew claim holds now (autovim:<project>), or nil while it holds none. It is read at each
---assignment, never kept: a claim is taken and lost while Neovim runs. auto-agents sets it.
---@param fn (fun(): string|nil)|nil
function M.set_crew(fn)
  if fn ~= nil and type(fn) ~= "function" then
    error("auto-core.todo.scope.set_crew: a function or nil, not a " .. type(fn), 2)
  end
  _crew = fn
end

---crew is this Neovim's crew scope now, nil for none (no reader set, no claim held, or a reader
---that failed): what todos.assign's and todos.add's crew carry.
---@return string|nil
function M.crew()
  if not _crew then return nil end
  local ok, sc = pcall(_crew)
  if ok and type(sc) == "string" and sc ~= "" then return sc end
  return nil
end

---reach_message is what an assignment's answer says of who it reaches (AutoDoc's reach, protocol
---54): its warning when nobody will be told, else its note when another project's agent is, else
---nil. The daemon words both, so every surface says it the same way.
---@param answer any todos.assign's or todos.add's answer
---@return string|nil message
---@return boolean warn true for a warning (nobody will be told), false for a note
function M.reach_message(answer)
  local r = type(answer) == "table" and answer.reach or nil
  if type(r) ~= "table" then return nil, false end
  if type(r.warning) == "string" and r.warning ~= "" then return r.warning, true end
  if type(r.note) == "string" and r.note ~= "" then return r.note, false end
  return nil, false
end

-- A test seam: the protocol autodoc.nvim's contracts declare, or a replacement.
local _protocol = nil

---protocol is the protocol autodoc.nvim speaks, read from its generated contracts, never probed
---from the running daemon: the plugin and the daemon ship from one commit, and its session says
---hello at that protocol, which an older daemon refuses, so a session never pairs a scoping plugin
---with a daemon that drops the scope. 0 when autodoc.nvim can't be loaded.
---@return integer
function M.protocol()
  if _protocol then return _protocol end
  local ok, c = pcall(require, "autodoc.contracts")
  return (ok and type(c) == "table" and tonumber(c.protocol)) or 0
end

---_set_protocol replaces the protocol read (tests); nil reads autodoc.nvim's again.
function M._set_protocol(p) _protocol = p end

---reads_scoped is whether this notifier tells todos.changes it reads scopes (protocol 33 or later).
---@return boolean
function M.reads_scoped() return M.protocol() >= M.READER_PROTOCOL end

---route_of splits an assignee into the name a task keeps and the scope that routes it. A task's
---assignee is the agent's name only (Johno, 2026-10-29: "the full address is only temp"), so a full
---agent id, `agent:<name>:<instance>`, keeps `agent:<name>` and routes this one delivery to its
---instance with the scope `@<instance>`. Any other assignee is kept as it is, with no route.
---@param assignee string
---@return string name, string|nil scope
function M.route_of(assignee)
  local name, inst = tostring(assignee):match("^(agent:[^:]+):(.+)$")
  if not name then return assignee, nil end
  return name, M.INSTANCE_PREFIX .. inst
end

---instance_of is the instance an instance scope (`@<instance>`) names, nil for any other scope.
---@param scope any
---@return string|nil
function M.instance_of(scope)
  if type(scope) == "string" and #scope > 1 and scope:sub(1, 1) == M.INSTANCE_PREFIX then
    return scope:sub(2)
  end
  return nil
end

---scoped is whether assignments are scoped here: AutoDoc carries a scope (protocol 30 or later).
---Below it, the notifier keeps its v0.5.0 rule (a bare name, by this instance's registry).
---@return boolean
function M.scoped() return M.protocol() >= M.PROTOCOL end

---assign_params are todos.assign's params after id and rev: the assignee, the reason, this
---Neovim's scope when AutoDoc takes one and a scope is set, and its crew scope when AutoDoc takes
---crew (protocol 54) and a claim is held, so the answer says who the assignee reaches. The one
---place both writers (the panel's Assign and the todos.assign verb) build them.
---@param assignee string "" clears
---@param reason string|nil
---@return any[]
function M.assign_params(assignee, reason)
  local p = { assignee }
  local scope = M.get()
  if M.scoped() then
    -- a full id keeps only the name, its instance routing this delivery (route_of)
    local name, routed = M.route_of(assignee)
    scope = routed or scope
    if scope then
      p[1], p[2], p[3] = name, reason or "", scope
    end
  end
  local crew = M.protocol() >= M.CREW_PROTOCOL and M.crew() or nil
  if crew then
    -- positional: crew follows scope, so an unset reason or scope is sent as "" (none)
    p[2], p[3], p[4] = p[2] or reason or "", p[3] or "", crew
    return p
  end
  if p[3] == nil and reason and reason ~= "" then
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
  if M.scoped() and type(spec) == "table" and type(spec.assignee) == "string" and spec.assignee ~= "" then
    local name, routed = M.route_of(spec.assignee)
    if routed then
      p[1] = vim.tbl_extend("force", {}, spec, { assignee = name }) -- the caller's spec untouched
    end
    p[2] = routed or scope
    local crew = M.protocol() >= M.CREW_PROTOCOL and M.crew() or nil
    if crew then
      p[2], p[3] = p[2] or "", crew -- positional: crew follows scope
    end
  end
  return p
end

---bare is whether assignee names an agent by name alone (`gold-man`, `agent:gold-man`), as
---against a full agent id (`agent:gold-man:<instance>`), which names its instance.
---@param assignee string
---@return boolean
function M.bare(assignee)
  if type(assignee) ~= "string" or assignee == "" then return false end
  local _, colons = assignee:gsub(":", "")
  return colons == 0 or (colons == 1 and assignee:sub(1, 6) == "agent:")
end

return M
