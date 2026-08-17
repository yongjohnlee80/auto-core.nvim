-- Reproducible scaling benchmarks for auto-core.rpc.frame.
--
--   nvim --headless --clean -u tests/bench/frame_scaling.lua
--
-- These exist because "linear" is a claim about an AXIS, and this
-- decoder can be driven along four of them. Three separate quadratics
-- were shipped here, each hidden behind a green measurement of a
-- different axis (ADR-0058 §3.2.2, KB convention T2b):
--
--   A. one frame, dripped one byte per callback   — retained-string append
--   B. many complete frames in one callback        — per-frame suffix slice
--   C. many separate feeds, drained at the end     — chunk-array rebuild
--   D. physical bytes pinned after a drain         — immutable head chunk
--
-- A benchmark that exercises one of these says nothing about the other
-- three. Run all four whenever the storage shape changes.
--
-- Reading the ratios: each row doubles the load, so ~2x is linear and
-- ~4x is quadratic. Ratios are printed rather than absolute times
-- because they survive a different machine.

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
vim.opt.rtp:prepend(plugin_root)

local frame = require("auto-core.rpc.frame")
local enc = vim.mpack.encode

local out = {}
local function say(fmt, ...) out[#out + 1] = string.format(fmt, ...) end

local function ratios(label, sizes, times)
  say("")
  say("  %s", label)
  for i, n in ipairs(sizes) do
    local r = i > 1 and string.format("  %.2fx", times[i] / math.max(times[i - 1], 1e-9)) or ""
    say("    %-28s %7.3f s%s", n, times[i], r)
  end
end

local BIG = { max_buffer = 64 * 1024 * 1024, max_string = 64 * 1024 * 1024,
  max_frame = 64 * 1024 * 1024, max_tokens = 5000000 }

-- ── A. one frame dripped one byte per callback ────────────────────
local a_sizes, a_times = {}, {}
for i, n in ipairs({ 25000, 50000, 100000 }) do
  local payload = enc(string.rep("x", n))
  local d = frame.decoder(BIG)
  local t0 = os.clock()
  for k = 1, #payload do
    d:feed(payload:sub(k, k))
    d:next()
  end
  a_sizes[i] = string.format("%d KB frame", n / 1024)
  a_times[i] = os.clock() - t0
end
ratios("A. one frame, one byte per callback", a_sizes, a_times)

-- ── B. many complete frames in ONE callback ───────────────────────
local b_sizes, b_times = {}, {}
for i, k in ipairs({ 1000, 2000, 4000 }) do
  local parts = {}
  for j = 1, k do parts[j] = enc({ 1, j, vim.NIL, string.rep("r", 200) }) end
  local blob = table.concat(parts)
  local d = frame.decoder(BIG)
  local t0 = os.clock()
  d:feed(blob)
  while (d:next()) == "ok" do end
  b_sizes[i] = string.format("%d frames, one feed", k)
  b_times[i] = os.clock() - t0
end
ratios("B. many frames in one callback", b_sizes, b_times)

-- ── C. many separate feeds, drained at the end ────────────────────
local c_sizes, c_times = {}, {}
for i, k in ipairs({ 1000, 2000, 4000 }) do
  local parts = {}
  for j = 1, k do parts[j] = enc({ 1, j, vim.NIL, string.rep("s", 200) }) end
  local d = frame.decoder(BIG)
  local t0 = os.clock()
  for j = 1, k do d:feed(parts[j]) end
  while (d:next()) == "ok" do end
  c_sizes[i] = string.format("%d feeds, drained after", k)
  c_times[i] = os.clock() - t0
end
ratios("C. many feeds queued, drained at the end", c_sizes, c_times)

-- ── D. physical retention after draining a batch ──────────────────
-- Not a timing test: does a drained callback stay pinned? A Lua string
-- is immutable, so holding the head chunk holds all of it.
local function heap_kb()
  collectgarbage("collect"); collectgarbage("collect")
  return collectgarbage("count")
end

say("")
say("  D. physical retention after a full drain")
do
  -- Positive control FIRST: this instrument has to be able to see the
  -- effect, or a null result proves nothing (T2b).
  local base = heap_kb()
  local probe = (function()
    local parts = {}
    for j = 1, 2000 do parts[j] = enc({ 1, j, vim.NIL, string.rep("p", 400) }) end
    return table.concat(parts)
  end)()
  local with_probe = heap_kb()
  local control = with_probe - base
  probe = nil
  local without = heap_kb()
  say("    control: heap sees a held blob   %+8.0f KB", control)
  say("    control: and its release         %+8.0f KB", without - with_probe)
  if control < 500 then
    say("    !! instrument cannot observe the effect — the rest is meaningless")
  end

  local before = heap_kb()
  local d = frame.decoder(BIG)
  do
    local parts = {}
    for j = 1, 2000 do parts[j] = enc({ 1, j, vim.NIL, string.rep("p", 400) }) end
    local blob = table.concat(parts) .. string.char(0xdb) -- + partial header
    d:feed(blob)
    blob, parts = nil, nil     -- the decoder is now the only holder
  end
  local drained = 0
  while (d:next()) == "ok" do drained = drained + 1 end
  local held = heap_kb()
  local logical, physical = d:pending(), d:retained()
  d = nil
  local released = heap_kb()
  say("    frames drained                   %8d", drained)
  say("    pending()  — logical bytes       %8d", logical)
  say("    retained() — physical bytes      %8d", physical)
  say("    bound: physical <= 2*logical+4096  %s",
    physical <= 2 * logical + 4096 and "OK" or "VIOLATED")
  say("    heap pinned by the decoder       %8.0f KB", held - released)
end

print("auto-core.rpc.frame — scaling (~2x per row = linear, ~4x = quadratic)")
print(table.concat(out, "\n"))
vim.cmd("qa!")
