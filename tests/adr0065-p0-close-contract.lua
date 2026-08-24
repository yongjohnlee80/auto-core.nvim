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
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
