---auto-core.instance — this Neovim's instance id.
---
---`<unix-seconds>-<pid>`, set once per process: sortable, and unique even when two
---Neovims start in the same second. The todo notifier's consumer is
---`auto-core:<id>`, an instance scope is `@<id>`, and auto-agents suffixes its agents'
---ids with it (`agent:<name>:<id>`).
---
---It was `auto-core.mailbox.path.get_instance_id` until v0.6.0, which retires the
---file mailbox (ADR 1793271500 phase 5).
---
---@module 'auto-core.instance'

local M = {}

local _id = nil ---@type string?

---id answers the process's instance id, computing it on first use.
---@return string
function M.id()
  if not _id then _id = string.format("%d-%d", os.time(), vim.fn.getpid()) end
  return _id
end

---set_id overrides the id (a test, or a consumer that must name the instance before
---anything reads it); nil clears the override. Only `[0-9A-Za-z-]` is accepted: the id
---ends up in names and scopes, where a separator would split it.
---@param id string?
function M.set_id(id)
  if id == nil then _id = nil; return end
  if type(id) ~= "string" or not id:match("^[0-9A-Za-z%-]+$") then
    error("auto-core.instance.set_id: invalid id; expected a non-empty [0-9A-Za-z-]+ string")
  end
  _id = id
end

return M
