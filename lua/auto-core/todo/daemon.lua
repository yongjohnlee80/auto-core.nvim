---auto-core.todo.daemon — the one door from auto-core.todo to AutoDoc's daemon.
---
---AutoDoc owns the todo system (ADR 1791532020): the format, the rules and every
---write. auto-core.todo forwards to its `todos.*` verbs through autodoc.nvim's
---client, reached by a SOFT require (Johno, 2026-10-13): no plugin spec declares
---the dependency, as `auto-core.kb` soft-requires `auto-agents.kb` during its own
---transition. The edge goes with the shim at auto-core v0.4.0.
---
---There is no Lua fallback (ADR §4): without AutoDoc every call answers
---"AutoDoc required". A fallback would be a second implementation.
---
---Calls run inside a coroutine (`run`): `rpc` yields until the daemon answers, so
---one body serves both shapes, asynchronous (`run` with a callback) and
---synchronous (`sync`, which waits for the coroutine, bounded).
---@module 'auto-core.todo.daemon'

local M = {}

-- NOTE: deadline. The daemon is another process; a synchronous caller waits for
-- its answer, bounded, so a daemon that does not answer is an error and never a
-- hang (autodoc's own sync verbs do the same, autodoc/verbs.lua). It covers a
-- whole operation: connecting (which may start the daemon), the store's first
-- resolution and claim, and the verb itself.
M.WAIT_MS = 15000

M.REQUIRED = "AutoDoc required: auto-core.todo forwards to AutoDoc's daemon "
  .. "(ADR 1791532020). Install autodoc (v0.1.39 or later) and its binary."

-- The daemon's public codes, by number (autodoc core/todo/module.go, rpc).
M.CODES = {
  [-32060] = "todos.no_such_workspace",
  [-32071] = "todos.stale",
  [-32072] = "todos.not_found",
  [-32073] = "todos.invalid",
  [-32074] = "todos.not_a_store",
  [-32075] = "todos.exists",
  [-32076] = "todos.not_writable",
  [-32077] = "todos.unclaimed",
  [-32601] = "rpc.method_not_found",
  [-32602] = "rpc.invalid_params",
}
M.STALE, M.NOT_FOUND, M.NOT_A_STORE, M.UNCLAIMED = -32071, -32072, -32074, -32077

-- Test seam: replaces the transport. fn(method, params, cb(result, err)).
local _transport = nil
function M._set_transport(fn) _transport = fn end

---format turns a daemon error ({code, message}) into the string auto-core.todo
---returns: "<name>: <message>".
---@param err any
---@return string
function M.format(err)
  if type(err) ~= "table" then return tostring(err) end
  local msg = tostring(err.message or err.msg or "unknown error")
  if err.code == -32601 then
    msg = "AutoDoc's daemon does not know this verb: it is older than protocol 20. "
      .. "Restart it (:AutodocMaintenance restart). " .. msg
  end
  local name = M.CODES[err.code]
  if name and not msg:find(name, 1, true) then return name .. ": " .. msg end
  return msg
end

---available is whether autodoc.nvim can be loaded at all.
---@return boolean
function M.available()
  if _transport then return true end
  local ok, todos = pcall(require, "autodoc.todos")
  return ok and type(todos) == "table" and type(todos.call) == "function"
end

---real_request sends one verb to the daemon. `todos.*` goes through
---autodoc.todos (the approved door); anything else (workspace.list) through
---autodoc's session. cb always receives (result, err) with err as {code,
---message}; it may run synchronously when autodoc.nvim is missing.
---@param method string
---@param params any[]
---@param cb fun(result: any, err: table|nil)
local function real_request(method, params, cb)
  local ok_call, cerr = pcall(function()
    if method:sub(1, 6) == "todos." then
      local ok, todos = pcall(require, "autodoc.todos")
      if not ok or type(todos) ~= "table" or type(todos.call) ~= "function" then
        return cb(nil, { message = M.REQUIRED })
      end
      return todos.call(method:sub(7), params, cb)
    end
    local ok, session = pcall(require, "autodoc.session")
    if not ok or type(session) ~= "table" or type(session.call) ~= "function" then
      return cb(nil, { message = M.REQUIRED })
    end
    session.call(method, params, cb)
  end)
  if not ok_call then cb(nil, { message = "autodoc: " .. tostring(cerr) }) end
end
M._real_request = real_request

---request sends one verb: through the test transport when one is set, else to
---the daemon.
---@param method string
---@param params any[]
---@param cb fun(result: any, err: table|nil)
function M.request(method, params, cb)
  if _transport then return _transport(method, params, cb) end
  real_request(method, params, cb)
end

---normalize replaces msgpack nils (vim.NIL) with nil, deeply: Go's nil slices and
---absent values arrive as vim.NIL.
---@param v any
---@return any
function M.normalize(v)
  if v == vim.NIL then return nil end
  if type(v) ~= "table" then return v end
  for k, x in pairs(v) do
    if x == vim.NIL then v[k] = nil else M.normalize(x) end
  end
  return v
end

---list_of is v when it is a list, else an empty list.
function M.list_of(v)
  if type(v) == "table" then return v end
  return {}
end

-- ── the coroutine runner ─────────────────────────────────────────

-- Each running coroutine's completion callback.
local _runs = setmetatable({}, { __mode = "k" })

local function settle(co, ok, ...)
  local done = _runs[co]
  if not ok then
    _runs[co] = nil
    if done then done(false, (...)) end
    return
  end
  if coroutine.status(co) == "dead" then
    _runs[co] = nil
    if done then done(true, ...) end
  end
  -- otherwise it yielded on an rpc, whose callback resumes it
end

local function resume(co, ...)
  settle(co, coroutine.resume(co, ...))
end

---run starts fn in a coroutine; fn may call `rpc`. done(ok, ...) receives fn's
---results, or (false, err) when fn raised.
---@param fn fun(): ...
---@param done fun(ok: boolean, ...)?
function M.run(fn, done)
  local co = coroutine.create(fn)
  _runs[co] = done or function() end
  resume(co)
end

---rpc sends one verb from inside `run` and returns (result, err), the result with
---vim.NIL normalized away.
---@param method string
---@param params any[]
---@return any result, table|nil err
function M.rpc(method, params)
  local co, main = coroutine.running()
  if not co or main or _runs[co] == nil then
    error("auto-core.todo.daemon.rpc: called outside daemon.run", 2)
  end
  local box, waiting = { done = false }, false
  M.request(method, params, function(r, e)
    box.r, box.e, box.done = r, e, true
    if waiting then
      waiting = false
      resume(co)
    end
  end)
  if not box.done then
    waiting = true
    coroutine.yield()
  end
  return M.normalize(box.r), M.normalize(box.e)
end

---fail raises err (a daemon error or a string) as auto-core.todo's message.
---@param err any
function M.fail(err)
  error(M.format(err), 0)
end

---sync runs fn as `run` does and waits for it, bounded by WAIT_MS. Returns
---(true, ...) with fn's results, or (false, message).
---@param fn fun(): ...
---@param wait_ms integer?
---@return boolean ok, any ...
function M.sync(fn, wait_ms)
  if vim.in_fast_event() then
    return false, "auto-core.todo: called from a fast event; vim.schedule the call"
  end
  local finished, res = false, nil
  M.run(fn, function(...) finished, res = true, { n = select("#", ...), ... } end)
  if not finished then
    vim.wait(wait_ms or M.WAIT_MS, function() return finished end, 10)
  end
  if not finished then
    return false, "AutoDoc did not answer within " .. (wait_ms or M.WAIT_MS) .. " ms"
  end
  return unpack(res, 1, res.n)
end

return M
