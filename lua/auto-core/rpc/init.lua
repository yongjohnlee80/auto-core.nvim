---auto-core.rpc — an asynchronous msgpack-RPC client for Neovim.
---
---Speaks msgpack-RPC to a socket **without enabling Neovim's own RPC
---mode**, which is the whole point: `sockconnect(..., {rpc = true})`
---makes Neovim a bidirectional endpoint the instant the connection is
---accepted, so any process that owns the port can call `nvim_exec_lua`
---before it has proved anything. A client that owns its own framing
---grants the peer no Neovim authority at all.
---
---Two properties fall out of owning the decode, both measured
---(ADR-0058 §3.2):
---
---  * **Structured errors survive.** `vim.rpcrequest` flattens a
---    server's `{code, message}` to the string "unknown error"; reading
---    the msgpack error slot directly keeps it intact.
---  * **Nothing blocks.** `rpcrequest` blocks the editor; here a request
---    is a write and a reply is an `on_data` callback.
---
---This module is TRANSPORT ONLY. It knows nothing about any particular
---server: no address policy, no credential rules, no error vocabulary
---beyond the wire's own. An application layers those on top — see
---`lua/autodb/client.lua` for the consumer this was built for.
---
---Additive-only contract: the surface below is frozen. Every rule in it
---is normative, because two consumers must not be able to read the same
---call differently.
---
---```lua
---local rpc = require("auto-core.rpc")
---local conn, err = rpc.connect({ addr = "127.0.0.1:7419" })
---local id = conn:request("sys.hello", {}, {}, function(outcome) end)
---conn:cancel(id)
---conn:close()
---```
---@module 'auto-core.rpc'

local frame = require("auto-core.rpc.frame")
local log = require("auto-core.log")

local M = {}

---Stable client-side codes. Distinct from server codes, which arrive
---untouched in `outcome.error`.
M.E_CAPACITY     = "E_CAPACITY"
M.E_DEADLINE     = "E_DEADLINE"
M.E_DISCONNECTED = "E_DISCONNECTED"
M.E_ABANDONED    = "E_ABANDONED"
M.E_ENCODE       = "E_ENCODE"
M.E_TRANSPORT    = "E_TRANSPORT"

local DEFAULT_CAPACITY = 64
local DEFAULT_DEADLINE = 120000  -- ms; long enough for real SQL

-- msgpack-RPC message kinds.
local REQUEST, RESPONSE, NOTIFY = 0, 1, 2

-- The server codec rejects any msgid outside uint32, so ids are
-- uint32-monotonic and a reconnect is forced before the space is
-- exhausted — not at Lua's safe-integer range.
local MAX_MSGID = 0xFFFFFFFF

---@class AutoCoreRpcOutcome
---@field status string   -- "ok" | "error" | "deadline" | "disconnected" | "abandoned"
---@field id integer
---@field value any?      -- on "ok": the result slot
---@field error any?      -- on "error": the RAW msgpack error slot
---@field code string?    -- on non-"ok"/"error": one of the E_* codes

---@class AutoCoreRpcConn
local Conn = {}
Conn.__index = Conn

---connect opens a connection. **Synchronous, and fails synchronously.**
---
---Returns `nil, err` on a malformed address or a socket that will not
---open. It never throws and never returns a half-open handle. The
---returned connection OWNS the channel.
---
---Note what it does NOT do: judge the endpoint. Address policy belongs
---to the application — a generic family module must not inherit one
---application's rules about where it may connect.
---@param opts { addr: string, mode: string?, limits: AutoCoreRpcLimits?, capacity: integer?, deadline: integer?, on_epoch_lost: function? }
---@return AutoCoreRpcConn|nil, string?
function M.connect(opts)
  opts = opts or {}
  local addr = opts.addr
  if type(addr) ~= "string" or addr == "" then
    return nil, "auto-core.rpc: opts.addr must be a non-empty string"
  end
  -- "pipe" is Neovim's name for a unix socket (and a named pipe on
  -- Windows); "tcp" takes host:port. The caller decides, because only it
  -- knows which endpoint it resolved — a transport default guessed here
  -- would be a second opinion about where to meet.
  local mode = opts.mode or "tcp"
  if mode ~= "tcp" and mode ~= "pipe" then
    return nil, string.format("auto-core.rpc: opts.mode must be \"tcp\" or \"pipe\", got %q", mode)
  end

  local self = setmetatable({}, Conn)
  self._addr = addr
  self._mode = mode
  self._decoder = frame.decoder(opts.limits)
  self._capacity = opts.capacity or DEFAULT_CAPACITY
  self._deadline = opts.deadline or DEFAULT_DEADLINE
  self._on_epoch_lost = opts.on_epoch_lost
  self._next_id = 1
  self._live = {}       -- id -> { cb, timer }
  self._tombs = {}      -- id -> true; abandoned locally, still live on the wire
  self._count = 0       -- live + tombstoned, both charged against capacity
  self._dead = false

  local ok, chan = pcall(vim.fn.sockconnect, mode, addr, {
    rpc = false,
    on_data = function(_, data) self:_on_data(data) end,
  })
  if not ok or not chan or chan == 0 then
    return nil, string.format("auto-core.rpc: cannot connect to %s: %s", addr,
      ok and "connection refused" or tostring(chan))
  end
  self._chan = chan
  return self
end

---_settle delivers an outcome exactly once and releases the slot.
function Conn:_settle(id, outcome)
  local entry = self._live[id]
  if not entry then return end
  self._live[id] = nil
  if entry.timer then
    pcall(function() entry.timer:stop(); entry.timer:close() end)
  end
  -- A locally abandoned request keeps its wire slot until the reply or
  -- the epoch ends, so repeated cancellation cannot free capacity while
  -- the server still holds real work.
  if outcome.status == "abandoned" then
    self._tombs[id] = true
  else
    self._count = self._count - 1
  end
  outcome.id = id
  if entry.cb then
    local ok, err = pcall(entry.cb, outcome)
    if not ok then
      vim.schedule(function()
        log.error("rpc", "callback error: " .. tostring(err))
      end)
    end
  end
end

---_lose_epoch settles everything and drops the channel, exactly once.
---
---The registry is DETACHED before any callback runs, so a callback that
---re-enters (`request`, `cancel`, `close`) sees a dead connection and
---gets a deterministic answer rather than mutating a table being walked.
---@param reason string  -- "eof" | "budget" | "malformed" | "protocol" | "closed"
function Conn:_lose_epoch(reason)
  if self._dead then return end
  self._dead = true

  local live, chan = self._live, self._chan
  self._live, self._tombs, self._count, self._chan = {}, {}, 0, nil

  for id, entry in pairs(live) do
    if entry.timer then
      pcall(function() entry.timer:stop(); entry.timer:close() end)
    end
    if entry.cb then
      local ok, err = pcall(entry.cb, {
        status = "disconnected", id = id, code = M.E_DISCONNECTED,
      })
      if not ok then
        vim.schedule(function()
          log.error("rpc", "callback error during epoch teardown: " .. tostring(err))
        end)
      end
    end
  end

  if chan then pcall(vim.fn.chanclose, chan) end

  -- AFTER every settlement, so a consumer that reconnects here cannot
  -- then receive a stale callback from the epoch it just left.
  if self._on_epoch_lost then pcall(self._on_epoch_lost, reason) end
end

function Conn:_on_data(data)
  if self._dead then return end
  -- Neovim signals EOF as a single empty string.
  if #data == 1 and data[1] == "" then
    return self:_lose_epoch("eof")
  end

  local ok = self._decoder:feed(data)
  if not ok then return self:_lose_epoch("budget") end

  while true do
    local status, value = self._decoder:next()
    if status == "incomplete" then return end
    if status == "error" then
      -- A budget violation and malformed bytes are both terminal: the
      -- stream position is no longer trustworthy, so we never resync on
      -- peer-chosen bytes.
      local reason = tostring(value):find("over max_", 1, true) and "budget" or "malformed"
      return self:_lose_epoch(reason)
    end
    if not self:_dispatch(value) then return end
  end
end

---_dispatch validates one frame strictly and settles its request.
---@return boolean alive  -- false once the epoch has been closed
function Conn:_dispatch(msg)
  -- Strict shape: exactly [1, msgid, error, result]. Valid msgpack in
  -- the wrong shape is a PROTOCOL violation, not malformed bytes.
  if type(msg) ~= "table" or #msg ~= 4 or msg[1] ~= RESPONSE then
    if type(msg) == "table" and (msg[1] == REQUEST or msg[1] == NOTIFY) then
      -- This client is not a server. A peer that sends us a request is
      -- speaking a protocol we did not agree to.
      self:_lose_epoch("protocol")
      return false
    end
    self:_lose_epoch("protocol")
    return false
  end

  local id = msg[2]
  if type(id) ~= "number" or id % 1 ~= 0 or id < 0 or id > MAX_MSGID then
    self:_lose_epoch("protocol")
    return false
  end

  -- A reply for an abandoned request retires its wire slot without
  -- invoking anything: the callback was settled when it was abandoned.
  if self._tombs[id] then
    self._tombs[id] = nil
    self._count = self._count - 1
    return true
  end

  local err, result = msg[3], msg[4]
  if err ~= nil and err ~= vim.NIL then
    -- The error slot is carried RAW. The wire permits any value here,
    -- and `code`/`message` are one application's convention, not a
    -- transport vocabulary.
    self:_settle(id, { status = "error", error = err })
  else
    self:_settle(id, { status = "ok", value = result })
  end
  return true
end

---request sends a call. Returns an integer id, or `nil, err`.
---
---**One admission rule, no overlap.** The registry entry is STAGED,
---then the frame is encoded and sent; if admission, encoding or the
---synchronous send fails, the entry is ROLLED BACK and this returns
---`nil, err` having never invoked `cb`. Once the send returns, the id
---is live and `cb` fires exactly once.
---
---So: an id guarantees exactly one callback; a `nil` guarantees none.
---A successful send still proves nothing about delivery — that is why
---it settles nothing and the id stays live.
---@param method string
---@param params table
---@param opts { deadline: integer? }?
---@param cb fun(outcome: AutoCoreRpcOutcome)
---@return integer|nil, string?
function Conn:request(method, params, opts, cb)
  opts = opts or {}
  if self._dead or not self._chan then
    return nil, M.E_DISCONNECTED
  end
  if self._count >= self._capacity then
    return nil, M.E_CAPACITY
  end

  local id = self._next_id
  if id > MAX_MSGID then
    -- Reuse within an epoch would let a late reply settle an unrelated
    -- call. Force a reconnect instead.
    return nil, M.E_CAPACITY
  end

  local ok, encoded = pcall(vim.mpack.encode, { REQUEST, id, method, params or {} })
  if not ok then
    return nil, M.E_ENCODE
  end

  -- Stage, then send; roll back if the send refuses.
  self._next_id = id + 1
  self._live[id] = { cb = cb }
  self._count = self._count + 1

  local sent_ok, sent = pcall(vim.fn.chansend, self._chan, encoded)
  if not sent_ok or sent == 0 then
    self._live[id] = nil
    self._count = self._count - 1
    return nil, M.E_TRANSPORT
  end

  local ms = opts.deadline or self._deadline
  if ms and ms > 0 then
    local timer = vim.uv.new_timer()
    self._live[id].timer = timer
    timer:start(ms, 0, vim.schedule_wrap(function()
      self:_settle(id, { status = "deadline", code = M.E_DEADLINE })
    end))
  end
  return id
end

---cancel abandons a request LOCALLY. Total and idempotent: unknown,
---already-settled and already-cancelled ids are no-ops returning false.
---
---This retires the callback, NOT the server's work — golib cancels
---handler contexts only when a connection ends, so the query keeps
---running. The outcome is named `abandoned` so nothing reads it as
---server-side cancellation, and its wire slot stays charged until the
---reply arrives or the epoch ends.
---@param id integer
---@return boolean
function Conn:cancel(id)
  if self._dead or not self._live[id] then return false end
  self:_settle(id, { status = "abandoned", code = M.E_ABANDONED })
  return true
end

---close settles every outstanding request as `disconnected`, then drops
---the channel. Idempotent.
function Conn:close()
  self:_lose_epoch("closed")
end

function Conn:is_closed() return self._dead end

---in_flight reports live requests plus tombstones — both charged
---against `capacity`, which is what makes the bound real.
---@return integer
function Conn:in_flight() return self._count end

function Conn:addr() return self._addr end
function Conn:mode() return self._mode end

return M
