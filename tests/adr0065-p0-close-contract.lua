-- auto-core — ADR-0065 P0: the multi-float close contract.
--
-- Run headless:
--   nvim --headless -u NONE -l tests/adr0065-p0-close-contract.lua
--
-- Every close path is exercised through the REAL float, because the defect
-- this contract exists to prevent was a consumer guarding `q` while `<Esc>`,
-- a lost pane and `dispose()` all tore the window down behind its back.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; io.stdout:write("  PASS  " .. n .. "\n")
  else fail = fail + 1; io.stdout:write("  FAIL  " .. n .. "  " .. tostring(d or "") .. "\n") end
  io.stdout:flush()
end
vim.o.columns, vim.o.lines = 160, 48
local multi = require("auto-core.ui.float.multi")

local function mk(name, before_close, on_close)
  return multi.new({ name = name, panes = { left = { width = 20 }, middle = {}, preview = { width = 0.4 } },
    before_close = before_close, on_close = on_close })
end

io.stdout:write("\n[1] veto on a key close\n")
local seen = {}
local f = mk("p0-veto", function(r) seen[#seen+1] = r; return r == "key" and "cancel" or nil end)
f:open()
ok("open", f:is_open())
f:close("key")
ok("*** a vetoed key close leaves the float OPEN ***", f:is_open(), vim.inspect(seen))
ok("the hook saw reason=key", seen[1] == "key", vim.inspect(seen))
f:close("resume")
ok("*** resume is a DIFFERENT reason and closes ***", not f:is_open(), vim.inspect(seen))
ok("hook saw resume", seen[2] == "resume", vim.inspect(seen))

io.stdout:write("\n[2] close is once-only\n")
local closes = 0
local g = mk("p0-once", nil, function() closes = closes + 1 end)
g:open(); g:close(); g:close(); g:dispose()
ok("*** on_close ran exactly once across close/close/dispose ***", closes == 1, tostring(closes))

io.stdout:write("\n[3] pane-lost notifies but cannot veto\n")
local got
local h = mk("p0-panelost", function(r) got = r; return "cancel" end)
h:open()
h:close("pane-lost")
ok("*** a cancel on pane-lost is IGNORED ***", not h:is_open(), tostring(h:is_open()))
ok("but the hook was still told", got == "pane-lost", tostring(got))

io.stdout:write("\n[4] reopen clears the guard\n")
local n2 = 0
local i = mk("p0-reopen", nil, function() n2 = n2 + 1 end)
i:open(); i:close(); i:open()
ok("reopened", i:is_open())
i:close()
ok("*** the second close still works (guard cleared on open) ***", not i:is_open())
ok("and on_close ran twice, once per lifecycle", n2 == 2, tostring(n2))

io.stdout:write("\n[5] tearing down our own panes does not re-enter the veto\n")
local calls = 0
local j = mk("p0-reentry", function() calls = calls + 1; return "cancel" end)
j:open()
j:close("programmatic")
ok("*** a hook that ALWAYS cancels still cannot block programmatic close ***",
  not j:is_open(), tostring(j:is_open()))
ok("and the hook was consulted once, not once per pane", calls == 1, tostring(calls))

io.stdout:write("\n[6] q and <Esc> both carry reason=key\n")
local reasons = {}
local k = mk("p0-keys", function(r) reasons[#reasons+1] = r; return "cancel" end)
k:open()
local buf = k:bufnr("middle")
local function press(lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == lhs and m.callback then pcall(m.callback); return true end
  end
  return false
end
ok("q is mapped", press("q"))
ok("<Esc> is mapped", press("<Esc>"))
ok("*** BOTH report reason=key, so neither bypasses the guard ***",
  #reasons == 2 and reasons[1] == "key" and reasons[2] == "key", vim.inspect(reasons))
ok("and the float survived both", k:is_open())
k:close("resume")

multi._reset_for_tests()
io.stdout:write("\n[7] diffview.close HONOURS the veto it asked for\n")
-- The wrapper asked the float to close and then cleared its own `_state` and
-- disposed the registry entry unconditionally. A consumer whose hook answered
-- "cancel" therefore kept its WINDOWS (the float layer is correct) while the
-- state driving them was destroyed: is_open() went false and the panes were
-- left showing a diff the view no longer knew about. auto-finder only ever
-- calls close("resume"), which cannot be vetoed, so nothing exercised it.
do
  local gitdiff = require("auto-core.git.diff")
  local dv = require("auto-core.ui.diffview")
  local files = gitdiff.parse(table.concat({
    "diff --git a/f.lua b/f.lua", "--- a/f.lua", "+++ b/f.lua",
    "@@ -1,2 +1,2 @@", " keep", "-old", "+new",
  }, "\n"))
  ok("[7] fixture parses", #files == 1, tostring(#files))

  local reasons = {}
  dv.open({ files = files, annotate = {
    on_add = function() end, on_remove = function() end,
    pending = function() return {} end,
    before_close = function(reason)
      reasons[#reasons + 1] = reason
      return reason == "key" and "cancel" or nil
    end,
  } })
  ok("[7] the view opens", dv.is_open() == true)

  dv.close("key")
  ok("[7] *** a VETOED close leaves the view open ***", dv.is_open() == true,
    vim.inspect(reasons))
  ok("[7] *** and its state intact, so the panes still have what drives them ***",
    dv._state_for_tests() ~= nil and dv.current_file() ~= nil,
    tostring(dv.current_file() and dv.current_file().path))
  ok("[7] the hook was consulted with reason=key",
    reasons[#reasons] == "key", vim.inspect(reasons))

  -- A second vetoed close must not degrade either — the wrapper is idempotent.
  dv.close("key")
  ok("[7] a repeated vetoed close is still open with state",
    dv.is_open() == true and dv._state_for_tests() ~= nil)

  -- "resume" is the reason a consumer uses to finish after its prompt, and it
  -- cannot be vetoed. CONTROL: without this the assertions above would also
  -- pass if close() had simply stopped working.
  dv.close("resume")
  ok("[7] *** CONTROL: an unvetoable reason still tears the view down ***",
    dv.is_open() == false and dv._state_for_tests() == nil)
  ok("[7] and the hook saw that reason too",
    reasons[#reasons] == "resume", vim.inspect(reasons))
end

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
