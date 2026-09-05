-- UI-attached test: verify pty test harness hit-enter prompt immunity.
--
-- Neovim running under pseudo-terminals without interactive DSR support
-- emits startup warnings (E1568). When combined with initial commands
-- (like `only`), multiple messages overflow cmdheight and trigger a
-- hit-enter prompt ("Press ENTER or type command to continue"), deadlocking
-- headless test runners.
--
-- This test asserts that:
-- 1. A real UI is attached via `script`.
-- 2. Harness options `nomore`, `cmdheight >= 2`, and `shortmess+=F` are active.
-- 3. Deliberate multi-line startup echoes and commands do NOT block execution.
--
-- Run:  tests/ui/run.sh pty_startup_noise

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
vim.opt.rtp:prepend(plugin_root)

local out, pass, fail = {}, 0, 0
local function ok(name, cond, detail)
  if cond then
    pass = pass + 1
    out[#out + 1] = "  PASS  " .. name
  else
    fail = fail + 1
    out[#out + 1] = "  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or "")
  end
end

local function finish()
  out[#out + 1] = string.format("\n%d passed, %d failed", pass, fail)
  local f = io.open(plugin_root .. "/tests/ui/.pty_startup_noise.out", "w")
  f:write("[ui] pty harness startup noise immunity\n"
    .. table.concat(out, "\n") .. "\n")
  f:close()
  vim.cmd(fail > 0 and "cq!" or "qa!")
end

-- Inject startup noise that would trigger hit-enter under default settings
vim.api.nvim_echo({ { "Startup noise line 1: testing prompt immunity", "WarningMsg" } }, true, {})
vim.api.nvim_echo({ { "Startup noise line 2: testing prompt immunity", "WarningMsg" } }, true, {})
vim.cmd("only")

vim.defer_fn(function()
  ok("[ui] a UI is attached", #vim.api.nvim_list_uis() > 0)
  ok("[ui] 'more' option is disabled", vim.o.more == false)
  ok("[ui] 'cmdheight' is at least 2", vim.o.cmdheight >= 2)
  ok("[ui] 'shortmess' contains 'F'", string.find(vim.o.shortmess, "F") ~= nil)
  ok("[ui] event loop proceeded without hit-enter deadlock", true)
  finish()
end, 100)
