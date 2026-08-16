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
---    the allocation is virtual until the payload touches it. Five bytes
---    from a peer must not cost half a gigabyte of address space.
---
---**Single pass.** Parser state persists across chunks: `pos` only ever
---moves forward, so each received byte is examined exactly once. A
---decoder that rescanned the buffer from the start on every chunk would
---be quadratic against a peer that drips a frame one byte at a time —
---the cheapest denial-of-service there is against a streaming parser.
---
---Every limit is a hard refusal, never a truncation: a violation means
---the peer is not speaking the protocol we agreed to, so the caller
---closes the epoch rather than resyncing on peer-chosen bytes.
---@module 'auto-core.rpc.frame'

local M = {}

---@class AutoCoreRpcLimits
---@field max_frame integer?     bytes in one complete value (default 8388608)
---@field max_string integer?    bytes in one str/bin/ext payload (default 4194304)
---@field max_depth integer?     nested container levels (default 32)
---@field max_tokens integer?    msgpack tokens in one frame, keys AND values (default 1000000)
---@field max_buffer integer?    bytes retained while a frame is incomplete (default 16777216)

local DEFAULTS = {
  max_frame = 8 * 1024 * 1024,
  max_string = 4 * 1024 * 1024,
  max_depth = 32,
  max_tokens = 1000000,
  max_buffer = 16 * 1024 * 1024,
}

M.DEFAULTS = DEFAULTS

---limits fills in the defaults for a partial table.
---@param opts AutoCoreRpcLimits?
---@return AutoCoreRpcLimits
function M.limits(opts)
  return vim.tbl_extend("force", vim.deepcopy(DEFAULTS), opts or {})
end

-- Big-endian unsigned reads. msgpack length fields are at most 32-bit,
-- well inside Lua's exact-integer range.
local function u8(s, i) return s:byte(i) end
local function u16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Fixed-size payloads, in bytes after the type byte. The fixext entries
-- include their one extension-type byte.
local SCALAR = {
  [0xc0] = 0, [0xc2] = 0, [0xc3] = 0,             -- nil, false, true
  [0xca] = 4, [0xcb] = 8,                          -- float 32/64
  [0xcc] = 1, [0xcd] = 2, [0xce] = 4, [0xcf] = 8,  -- uint 8/16/32/64
  [0xd0] = 1, [0xd1] = 2, [0xd2] = 4, [0xd3] = 8,  -- int 8/16/32/64
  [0xd4] = 2, [0xd5] = 3, [0xd6] = 5, [0xd7] = 9, [0xd8] = 17, -- fixext
}

-- Length-prefixed payloads: {length-field bytes, reader, extra payload}
local LEN = {
  [0xc4] = { 1, u8, 0 }, [0xc5] = { 2, u16, 0 }, [0xc6] = { 4, u32, 0 }, -- bin
  [0xd9] = { 1, u8, 0 }, [0xda] = { 2, u16, 0 }, [0xdb] = { 4, u32, 0 }, -- str
  [0xc7] = { 1, u8, 1 }, [0xc8] = { 2, u16, 1 }, [0xc9] = { 4, u32, 1 }, -- ext
}

local CONTAINER = {
  [0xdc] = { 2, u16, 1 }, [0xdd] = { 4, u32, 1 }, -- array
  [0xde] = { 2, u16, 2 }, [0xdf] = { 4, u32, 2 }, -- map (2 tokens per entry)
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

---reset clears the buffer and all parse state.
function Decoder:reset()
  self.buf = ""
  self.pos = 1      -- next unexamined byte; NEVER moves backwards
  self.need = 1     -- values still required to finish the current frame
  self.stack = {}   -- saved `need` per open container
  self.depth = 0
  self.tokens = 0
  self.skip = 0     -- payload bytes still to walk past
  self.failed = nil
end

---feed appends bytes. Accepts a string, or the string LIST Neovim hands
---to `on_data` (see `channel_bytes`).
---@param chunk string|string[]
---@return boolean ok, string? err  -- false once the buffer budget is blown
function Decoder:feed(chunk)
  if self.failed then return false, self.failed end
  local bytes = type(chunk) == "table" and M.channel_bytes(chunk) or chunk
  if #bytes == 0 then return true end
  self.buf = self.buf .. bytes
  -- The budget that actually stops a peer dribbling an endless frame:
  -- without it, "incomplete" is an unbounded invitation.
  if #self.buf > self.lim.max_buffer then
    self.failed = string.format(
      "buffered %d bytes without a complete frame, over max_buffer (%d)",
      #self.buf, self.lim.max_buffer)
    return false, self.failed
  end
  return true
end

function Decoder:_fail(msg)
  self.failed = msg
  return "error", msg
end

---next returns the next complete frame, if one has arrived.
---
---Resumes exactly where the previous call stopped — a partial token is
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
      local available = #self.buf - self.pos + 1
      local take = math.min(self.skip, available)
      self.pos = self.pos + take
      self.skip = self.skip - take
      if self.skip > 0 then return "incomplete" end
    end

    if self.need == 0 then break end

    if self.pos > #self.buf then return "incomplete" end

    self.tokens = self.tokens + 1
    if self.tokens > lim.max_tokens then
      return self:_fail(string.format("frame exceeds max_tokens (%d)", lim.max_tokens))
    end

    local buf, pos = self.buf, self.pos
    local t = buf:byte(pos)
    local header, payload, children = 1, 0, 0

    if t <= 0x7f or t >= 0xe0 then            -- fixint
      payload = 0
    elseif t >= 0x80 and t <= 0x8f then       -- fixmap
      children = (t - 0x80) * 2
    elseif t >= 0x90 and t <= 0x9f then       -- fixarray
      children = t - 0x90
    elseif t >= 0xa0 and t <= 0xbf then       -- fixstr
      payload = t - 0xa0
    elseif t == 0xc1 then
      return self:_fail("invalid msgpack type byte 0xc1")
    elseif SCALAR[t] then
      payload = SCALAR[t]
    elseif LEN[t] then
      local spec = LEN[t]
      if pos + spec[1] > #buf then return "incomplete" end  -- retry this token
      local len = spec[2](buf, pos + 1)
      if len > lim.max_string then
        return self:_fail(string.format(
          "value declares %d bytes, over max_string (%d)", len, lim.max_string))
      end
      header = 1 + spec[1]
      payload = len + spec[3]
    elseif CONTAINER[t] then
      local spec = CONTAINER[t]
      if pos + spec[1] > #buf then return "incomplete" end  -- retry this token
      local count = spec[2](buf, pos + 1)
      children = count * spec[3]
      -- Refuse an absurd declared count now: max_tokens would catch it
      -- eventually, but only after walking that far.
      if children > lim.max_tokens then
        return self:_fail(string.format(
          "container declares %d items, over max_tokens (%d)", count, lim.max_tokens))
      end
      header = 1 + spec[1]
    else
      return self:_fail(string.format("unknown msgpack type byte 0x%02x", t))
    end

    if (pos - 1) + header + payload > lim.max_frame then
      return self:_fail(string.format("frame exceeds max_frame (%d bytes)", lim.max_frame))
    end

    self.pos = pos + header
    self.skip = payload
    self.need = self.need - 1

    if children > 0 then
      self.depth = self.depth + 1
      if self.depth > lim.max_depth then
        return self:_fail(string.format("nesting deeper than max_depth (%d)", lim.max_depth))
      end
      self.stack[self.depth] = self.need
      self.need = children
    end

    -- Close every container this value completed.
    while self.need == 0 and self.depth > 0 do
      self.need = self.stack[self.depth]
      self.stack[self.depth] = nil
      self.depth = self.depth - 1
    end
  end

  -- One complete frame occupies buf[1 .. pos-1].
  local frame = self.buf:sub(1, self.pos - 1)
  local rest = self.buf:sub(self.pos)

  local ok, value = pcall(vim.mpack.decode, frame)
  if not ok then
    -- The scanner accepted it but the decoder refused: the stream
    -- position is no longer trustworthy, so this is terminal.
    return self:_fail("malformed frame: " .. tostring(value))
  end

  -- Start the next frame with a clean slate; consumed bytes are dropped
  -- so the retained buffer only ever holds live data.
  self.buf = rest
  self.pos = 1
  self.need = 1
  self.stack = {}
  self.depth = 0
  self.tokens = 0
  self.skip = 0
  return "ok", value
end

---pending reports how many bytes are held for an incomplete frame.
---@return integer
function Decoder:pending() return #self.buf end

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
