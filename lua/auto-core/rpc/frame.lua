---msgpack frame decoder — the resource boundary for `auto-core.rpc`.
---
---INTERNAL. Consumers bind to the `auto-core.rpc` facade, not to this.
---
---The job is narrow on purpose: accept bytes as they arrive, decide
---when one COMPLETE msgpack value has been received, and refuse
---anything outside its budget — **without building any of it**. Only a
---complete, in-budget frame is handed to the documented
---`vim.mpack.decode`. Nothing here decodes.
---
---Why not stream with `vim.mpack.Unpacker` (ADR-0058 §3.2.2):
---
---  * `:help vim.mpack` documents exactly two symbols, `encode` and
---    `decode`. `Unpacker` and `Session` exist at runtime but appear
---    nowhere in the docs, and auto-core publishes against a Neovim
---    >= 0.10 floor. A published module should not make an undocumented
---    upstream symbol its only backend.
---  * It allocates a DECLARED length before the bytes exist. Measured on
---    0.12.2: feeding a 5-byte `str32` header claiming 512 MiB grows
---    VmSize by 512 MB; a second such frame adds another 512 MB. RSS
---    stays flat, which is why an RSS-based measurement sees nothing —
---    the allocation is virtual until the payload touches it.
---
---**Linear work, in BOTH cursor and storage, on BOTH axes.** Parser
---state persists across chunks, so each received byte is examined once.
---Storage matters just as much, and it has two separate ways to go
---quadratic — each measured, each fixed:
---
---  * ONE frame dripped over many callbacks. Appending each chunk to a
---    retained immutable string recopies the growing prefix: 2.77x and
---    2.93x per doubling. Chunks are held in a QUEUE instead.
---  * MANY frames in one callback. Slicing the unconsumed remainder
---    after each frame recopies the rest of the batch every time: 3.74x
---    and 4.83x per doubling. A chunk still holding live bytes is kept
---    as is, with an offset into it.
---
---Bytes are joined exactly once, when a complete frame is handed to
---`vim.mpack.decode`.
---
---Every limit is a hard refusal, never a truncation: a violation means
---the peer is not speaking the protocol we agreed to, so the caller
---closes the epoch rather than resyncing on peer-chosen bytes.
---@module 'auto-core.rpc.frame'

local M = {}

---@class AutoCoreRpcLimits
---@field max_frame integer?     bytes in one complete value (default 8388608)
---@field max_string integer?    bytes of str/bin/ext DATA, excluding the ext type tag (default 4194304)
---@field max_depth integer?     container levels, empty containers included (default 32)
---@field max_tokens integer?    msgpack values in one frame, keys AND values (default 100000)
---@field max_buffer integer?    bytes retained for ONE incomplete frame (default 16777216)

local DEFAULTS = {
  max_frame = 8 * 1024 * 1024,
  max_string = 4 * 1024 * 1024,
  max_depth = 32,
  -- An EDITOR-STALL budget, not only a memory one: the whole allowance
  -- is materialized SYNCHRONOUSLY by vim.mpack.decode on the main loop
  -- the instant a frame completes, so "linear" is necessary but not
  -- sufficient — the entire allowed unit runs without yielding.
  -- Measured on 0.12.2, string-heavy rows (the expensive shape):
  --
  --     10 000 rows x 20 cols  (~210k values, 2.0 MB)  ->  43.6 ms
  --      5 000 rows x 20 cols  (~105k values, 1.0 MB)  ->  23.6 ms
  --      1 000 rows x 10 cols  (~11k values,   91 KB)  ->   1.6 ms
  --
  -- ~4.8k values per ms. This bound exists for a HOSTILE or defective
  -- peer: autodb pages reads at 500 rows (exec.DefaultMaxRows), so a
  -- legitimate frame tops out near 500 x 100 columns ~= 50k values. The
  -- default sits at twice that — high enough never to refuse a wide real
  -- table, low enough that a maximum-size frame costs ~21 ms.
  --
  -- Stated plainly rather than dressed up: 21 ms is longer than one
  -- 60 Hz interval (16.7 ms), and scanning, projection and rendering
  -- come on top. This transport accepts that stall for a worst-case
  -- frame; the answer to a legitimately larger result is server-side
  -- paging, not a bigger synchronous bite.
  max_tokens = 100000,
  max_buffer = 16 * 1024 * 1024,
}

M.DEFAULTS = DEFAULTS

---limits fills in the defaults for a partial table.
---@param opts AutoCoreRpcLimits?
---@return AutoCoreRpcLimits
function M.limits(opts)
  return vim.tbl_extend("force", vim.deepcopy(DEFAULTS), opts or {})
end

-- Fixed-size payloads, in bytes after the type byte. The fixext entries
-- include their one extension-type byte.
local SCALAR = {
  [0xc0] = 0, [0xc2] = 0, [0xc3] = 0,             -- nil, false, true
  [0xca] = 4, [0xcb] = 8,                          -- float 32/64
  [0xcc] = 1, [0xcd] = 2, [0xce] = 4, [0xcf] = 8,  -- uint 8/16/32/64
  [0xd0] = 1, [0xd1] = 2, [0xd2] = 4, [0xd3] = 8,  -- int 8/16/32/64
}
-- fixext carries DATA, so its payload is bounded by max_string like any
-- other opaque blob. Kept separate from SCALAR for exactly that reason.
local FIXEXT = { [0xd4] = 2, [0xd5] = 3, [0xd6] = 5, [0xd7] = 9, [0xd8] = 17 }

-- Length-prefixed payloads: {length-field bytes, extra payload bytes}
local LEN = {
  [0xc4] = { 1, 0 }, [0xc5] = { 2, 0 }, [0xc6] = { 4, 0 }, -- bin 8/16/32
  [0xd9] = { 1, 0 }, [0xda] = { 2, 0 }, [0xdb] = { 4, 0 }, -- str 8/16/32
  [0xc7] = { 1, 1 }, [0xc8] = { 2, 1 }, [0xc9] = { 4, 1 }, -- ext 8/16/32
}

local CONTAINER = {
  [0xdc] = { 2, 1 }, [0xdd] = { 4, 1 }, -- array 16/32
  [0xde] = { 2, 2 }, [0xdf] = { 4, 2 }, -- map 16/32 (2 values per entry)
}

---@class AutoCoreRpcDecoder
local Decoder = {}
Decoder.__index = Decoder

---decoder builds a persistent incremental decoder.
---@param lim AutoCoreRpcLimits?
---@return AutoCoreRpcDecoder
function M.decoder(lim)
  local self = setmetatable({}, Decoder)
  self.lim = M.limits(lim)
  self:reset()
  return self
end

---reset clears the queue and all parse state.
function Decoder:reset()
  self.q = {}       -- chunk queue, exactly as the channel delivered them
  self.qs = 0       -- bytes at the front of q[1] already consumed by past frames
  self.qi = 1       -- chunk holding the cursor
  self.qo = 0       -- absolute offset within q[qi] (bytes of it consumed)
  self.avail = 0    -- unconsumed bytes across the whole queue
  self.consumed = 0 -- bytes consumed in the CURRENT frame
  self.need = 1     -- values still required to finish the current frame
  self.stack = {}   -- saved `need` per open container
  self.depth = 0
  self.tokens = 0
  self.skip = 0     -- payload bytes still to walk past
  self.failed = nil
end

---feed queues bytes. Accepts a string, or the string LIST Neovim hands
---to `on_data` (see `channel_bytes`).
---
---Queuing only: budgets that depend on what is COMPLETE are enforced by
---`next`, after complete frames have been drained. Refusing here would
---reject a callback carrying several valid frames whose total exceeds
---the single-incomplete-frame budget.
---@param chunk string|string[]
---@return boolean ok, string? err
function Decoder:feed(chunk)
  if self.failed then return false, self.failed end
  local bytes = type(chunk) == "table" and M.channel_bytes(chunk) or chunk
  if #bytes == 0 then return true end
  self.q[#self.q + 1] = bytes
  self.avail = self.avail + #bytes
  return true
end

function Decoder:_fail(msg)
  self.failed = msg
  return "error", msg
end

---_byte returns the n-th UNCONSUMED byte (1-based), or nil.
---Only ever called for a token header, so the walk is at most 4 chunks.
function Decoder:_byte(n)
  if n > self.avail then return nil end
  local i, o = self.qi, self.qo
  while true do
    local chunk = self.q[i]
    local left = #chunk - o
    if n <= left then return chunk:byte(o + n) end
    n = n - left
    i, o = i + 1, 0
  end
end

---_u reads a big-endian unsigned integer of `width` bytes starting at
---the n-th unconsumed byte. msgpack length fields are at most 32-bit.
function Decoder:_u(n, width)
  local v = 0
  for k = 0, width - 1 do
    v = v * 256 + self:_byte(n + k)
  end
  return v
end

---_advance moves the cursor forward by n unconsumed bytes.
function Decoder:_advance(n)
  self.avail = self.avail - n
  self.consumed = self.consumed + n
  while n > 0 do
    local chunk = self.q[self.qi]
    local left = #chunk - self.qo
    if n < left then
      self.qo = self.qo + n
      return
    end
    n = n - left
    self.qi = self.qi + 1
    self.qo = 0
  end
end

---_take_frame joins this frame's bytes into ONE string and advances the
---queue past them.
---
---It must NOT slice the unconsumed remainder. One `on_data` callback can
---carry many complete replies in a single string; copying that string's
---suffix after each frame costs N + (N-f) + (N-2f) + … — quadratic in
---the number of frames, measured at 3.7× and 4.8× per doubling. So a
---chunk that still holds live bytes is kept AS IS and the queue simply
---remembers how far into it we are. Only fully consumed chunks are
---dropped, and each byte is copied exactly once: into its own frame.
function Decoder:_take_frame()
  local parts = {}
  if self.qi == 1 then
    parts[1] = self.q[1]:sub(self.qs + 1, self.qo)
  else
    parts[1] = self.q[1]:sub(self.qs + 1)
    for i = 2, self.qi - 1 do parts[#parts + 1] = self.q[i] end
    if self.qo > 0 then parts[#parts + 1] = self.q[self.qi]:sub(1, self.qo) end
  end
  local frame = table.concat(parts)

  -- Drop chunks the cursor has left behind; keep the one it sits in.
  if self.qi > 1 then
    local rest = {}
    for i = self.qi, #self.q do rest[#rest + 1] = self.q[i] end
    self.q = rest
    self.qi = 1
  end
  self.qs = self.qo
  if self.q[1] and self.qs >= #self.q[1] then
    table.remove(self.q, 1)   -- fully consumed; the next frame starts clean
    self.qs = 0
  end
  self.qo = self.qs
  return frame
end

---next returns the next complete frame, if one has arrived.
---
---Resumes exactly where the previous call stopped: a partial token is
---retried in place and a partial payload is walked incrementally, so no
---byte is examined twice.
---@return string status  -- "ok" | "incomplete" | "error"
---@return any            -- decoded value | nil | error message
function Decoder:next()
  if self.failed then return "error", self.failed end
  local lim = self.lim

  while true do
    -- Walk past a payload that may be spread over several chunks.
    if self.skip > 0 then
      local take = math.min(self.skip, self.avail)
      if take > 0 then
        self:_advance(take)
        self.skip = self.skip - take
      end
      if self.skip > 0 then return self:_incomplete() end
    end

    if self.need == 0 then break end
    if self.avail == 0 then return self:_incomplete() end

    local t = self:_byte(1)
    -- `payload` is bytes to walk past; `opaque` is str/bin/ext DATA and
    -- is the only thing max_string bounds. They differ: a float64 has 8
    -- payload bytes and no opaque data, and an ext's one type-tag byte
    -- is payload but not data — counting it made an extension carrying
    -- exactly max_string bytes fail by one.
    local header, payload, opaque, children = 1, 0, 0, 0
    local is_container = false

    if t <= 0x7f or t >= 0xe0 then            -- fixint
      payload = 0
    elseif t >= 0x80 and t <= 0x8f then       -- fixmap
      children, is_container = (t - 0x80) * 2, true
    elseif t >= 0x90 and t <= 0x9f then       -- fixarray
      children, is_container = t - 0x90, true
    elseif t >= 0xa0 and t <= 0xbf then       -- fixstr
      payload = t - 0xa0
      opaque = payload
    elseif t == 0xc1 then
      return self:_fail("invalid msgpack type byte 0xc1")
    elseif SCALAR[t] then
      payload = SCALAR[t]
    elseif FIXEXT[t] then
      payload = FIXEXT[t]
      opaque = payload - 1                    -- minus the extension type tag
    elseif LEN[t] then
      local spec = LEN[t]
      -- Not enough bytes for the length field: retry this token later.
      -- Nothing is charged and nothing advances, so a header split
      -- across chunks costs exactly what an unsplit one costs.
      if self.avail < 1 + spec[1] then return self:_incomplete() end
      local len = self:_u(2, spec[1])
      if len > lim.max_string then
        return self:_fail(string.format(
          "value declares %d bytes, over max_string (%d)", len, lim.max_string))
      end
      header = 1 + spec[1]
      payload = len + spec[2]                 -- spec[2] is the ext type tag
      opaque = len
    elseif CONTAINER[t] then
      local spec = CONTAINER[t]
      if self.avail < 1 + spec[1] then return self:_incomplete() end
      local count = self:_u(2, spec[1])
      children, is_container = count * spec[2], true
      -- Refuse an absurd declared count now: max_tokens would catch it
      -- eventually, but only after walking that far.
      if children > lim.max_tokens then
        return self:_fail(string.format(
          "container declares %d values, over max_tokens (%d)", count, lim.max_tokens))
      end
      header = 1 + spec[1]
    else
      return self:_fail(string.format("unknown msgpack type byte 0x%02x", t))
    end

    -- fixstr/fixext are opaque data too, so a caller that sets
    -- max_string below 31 gets the bound it asked for. Numeric scalars
    -- are NOT data and are never measured against it.
    if opaque > lim.max_string then
      return self:_fail(string.format(
        "value carries %d bytes, over max_string (%d)", opaque, lim.max_string))
    end
    if self.consumed + header + payload > lim.max_frame then
      return self:_fail(string.format("frame exceeds max_frame (%d bytes)", lim.max_frame))
    end

    -- Charged only now that the token's header is complete and accepted:
    -- charging earlier would bill a token again on every retry, so how
    -- TCP split the stream could push a valid frame over the limit.
    self.tokens = self.tokens + 1
    if self.tokens > lim.max_tokens then
      return self:_fail(string.format("frame exceeds max_tokens (%d)", lim.max_tokens))
    end

    self:_advance(header)
    self.skip = payload
    self.need = self.need - 1

    -- An EMPTY array or map is still a container level: without this,
    -- nested empty containers could exceed max_depth unrefused. The
    -- level is charged, then only pushed if it has children to wait for.
    if is_container then
      if self.depth + 1 > lim.max_depth then
        return self:_fail(string.format("nesting deeper than max_depth (%d)", lim.max_depth))
      end
      if children > 0 then
        self.depth = self.depth + 1
        self.stack[self.depth] = self.need
        self.need = children
      end
    end

    -- Close every container this value completed.
    while self.need == 0 and self.depth > 0 do
      self.need = self.stack[self.depth]
      self.stack[self.depth] = nil
      self.depth = self.depth - 1
    end
  end

  local frame = self:_take_frame()
  local ok, value = pcall(vim.mpack.decode, frame)
  if not ok then
    -- The scanner accepted it but the decoder refused: the stream
    -- position is no longer trustworthy, so this is terminal.
    return self:_fail("malformed frame: " .. tostring(value))
  end

  -- Start the next frame with a clean slate.
  self.consumed, self.need, self.stack = 0, 1, {}
  self.depth, self.tokens, self.skip = 0, 0, 0
  return "ok", value
end

---_incomplete enforces the retained-bytes budget on the way out.
---
---Applied HERE rather than in `feed` because everything still queued at
---this point belongs to the current incomplete frame — complete frames
---have already been drained by earlier `next` calls. Enforcing it on
---arrival would refuse a callback carrying several valid frames.
function Decoder:_incomplete()
  local retained = self.consumed + self.avail
  if retained > self.lim.max_buffer then
    return self:_fail(string.format(
      "retained %d bytes for one incomplete frame, over max_buffer (%d)",
      retained, self.lim.max_buffer))
  end
  return "incomplete"
end

---pending reports how many bytes are retained for the current frame.
---@return integer
function Decoder:pending() return self.consumed + self.avail end

---channel_bytes reverses Neovim's channel encoding.
---
---`:h channel-lines`: the list is split on real `0x0A`, and a `\n`
---INSIDE an element is a `0x00`. Measured reversible — `printf
---'a\0b\nc\0d'` arrives as `{"a\nb", "c\nd"}` and maps back to exactly
---those bytes — which is what makes binary msgpack safe to carry over a
---non-RPC channel.
---@param chunk string[]
---@return string
function M.channel_bytes(chunk)
  local parts = {}
  for i, s in ipairs(chunk) do parts[i] = (s:gsub("\n", "\0")) end
  return table.concat(parts, "\n")
end

---channel_encode is the inverse, for `chansend`.
---
---Measured: `chansend` delivers a plain Lua string byte-exactly,
---embedded NULs included, so this is the identity today. It exists as
---the named counterpart to `channel_bytes` so the asymmetry is a stated
---fact rather than a silent assumption.
---@param bytes string
---@return string
function M.channel_encode(bytes) return bytes end

return M
