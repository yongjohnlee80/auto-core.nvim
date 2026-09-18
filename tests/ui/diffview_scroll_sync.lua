-- UI-attached test for auto-core.ui.diffview's pane scroll synchronisation.
--
-- This CANNOT live in tests/smoke.lua or the headless adr0191 suite:
-- `WinScrolled` only fires when a UI is attached, because with no UI there is
-- no redraw to trigger it. Headlessly the event is silently never delivered,
-- which produces a false negative that looks exactly like a passing test.
-- (Verified: a headless probe scrolled a window from topline 1 to 90 and
-- WinScrolled fired zero times.)
--
-- The cell that matters most here is §3: the panes must NOT be coupled to
-- windows outside the float. `scrollbind` — the obvious implementation — is
-- not a two-window relation; Neovim synchronises every scroll-bound window in
-- the tab page, and native diff mode sets it automatically. A reader with a
-- `:diffsplit` open would have it dragged by the review and vice versa.
--
-- Run under a pty:
--   script -qec "nvim --clean -u tests/ui/diffview_scroll_sync.lua" /dev/null
-- and read tests/ui/.diffview_scroll_sync.out. tests/ui/run.sh wraps both.

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
vim.opt.rtp:prepend(plugin_root)
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({ LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.rtp:prepend(p) end
end
vim.o.swapfile = false

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
  local f = io.open(plugin_root .. "/tests/ui/.diffview_scroll_sync.out", "w")
  f:write("[ui] auto-core.ui.diffview — pane scroll synchronisation\n"
    .. table.concat(out, "\n") .. "\n")
  f:close()
  vim.cmd(fail > 0 and "cq!" or "qa!")
end

local D = require("auto-core.git.diff")
local DV = require("auto-core.ui.diffview")

-- A file long enough that both panes genuinely scroll.
local N = 400
local function numbered(change)
  local t = {}
  for i = 1, N do t[i] = (change and change[i]) or ("line " .. i) end
  return t
end
local BEFORE = numbered(nil)
local AFTER = numbered({ [2] = "line 2 CHANGED", [380] = "line 380 CHANGED" })

local patch = table.concat({
  "diff --git a/wide.lua b/wide.lua",
  "--- a/wide.lua",
  "+++ b/wide.lua",
  "@@ -1,4 +1,4 @@",
  " line 1",
  "-line 2",
  "+line 2 CHANGED",
  " line 3",
  " line 4",
  "@@ -378,4 +378,4 @@",
  " line 378",
  " line 379",
  "-line 380",
  "+line 380 CHANGED",
  " line 381",
}, "\n") .. "\n"

-- A window that is ALREADY scroll-bound when the float opens — standing in for
-- the reader's own :diffsplit, which sets 'scrollbind' automatically. Nothing
-- the float does may move it.
vim.cmd("silent! only")
local outsider = vim.api.nvim_get_current_win()
local ob = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(ob, 0, -1, false, numbered(nil))
vim.api.nvim_win_set_buf(outsider, ob)
vim.api.nvim_set_option_value("scrollbind", true, { win = outsider, scope = "local" })

local float = DV.open({
  files = D.parse(patch),
  read_file = function(side, path)
    if path ~= "wide.lua" then return nil end
    return side == "before" and BEFORE or AFTER
  end,
  context = "full",
})

local function topline(w)
  if not (w and vim.api.nvim_win_is_valid(w)) then return nil end
  return vim.api.nvim_win_call(w, function() return vim.fn.line("w0") end)
end

vim.defer_fn(function()
  -- POSITIVE CONTROL. Without a UI every scroll assertion below is vacuous,
  -- so the suite states up front that its instrument is live.
  ok("[ui] a UI is attached (else this whole file is a false negative)",
    #vim.api.nvim_list_uis() > 0, #vim.api.nvim_list_uis())
  ok("diffview opened", float ~= nil)

  local mw = float and float:winid("middle")
  local pw = float and float:winid("preview")
  ok("both content panes exist", mw ~= nil and pw ~= nil,
    ("middle=%s preview=%s  term=%dx%d"):format(
      tostring(mw), tostring(pw), vim.o.columns, vim.o.lines))
  -- Bail cleanly rather than throwing inside a deferred callback: a throw in a
  -- vim.defer_fn does not kill nvim, it just stops the timer — so the runner
  -- would hang to its watchdog instead of reporting anything.
  if not (mw and pw) then return finish() end

  local outsider_before = topline(outsider)

  -- Wiring check, and a diagnostic split: if the autocmd is absent the event
  -- can never fire; if it is present but the panes do not move, the fault is
  -- in the mirroring rather than the trigger.
  local acs = vim.api.nvim_get_autocmds({ group = "AutoCoreDiffviewScrollSync" })
  ok("the scroll synchroniser is wired", #acs > 0, ("%d autocmds"):format(#acs))

  -- Does the mirroring mechanism work at all, independent of WinScrolled?
  vim.api.nvim_win_set_cursor(mw, { 150, 0 })
  vim.api.nvim_win_call(mw, function() vim.cmd("normal! zt") end)
  DV._sync_scroll("middle")
  ok("direct _sync_scroll mirrors the topline",
    topline(mw) == topline(pw),
    ("direct: middle=%s preview=%s"):format(tostring(topline(mw)), tostring(topline(pw))))

  -- ── 1. scrolling the a/ pane moves the b/ pane ────────────────────
  vim.api.nvim_set_current_win(mw)
  vim.api.nvim_win_set_cursor(mw, { 200, 0 })
  vim.cmd("normal! zt")
  vim.cmd("redraw")

  vim.defer_fn(function()
    local tm, tp = topline(mw), topline(pw)
    ok("a/ pane actually scrolled (control for the sync assertion)",
      tm and tm > 1, tostring(tm))
    ok("scrolling a/ puts b/ on the same topline", tm == tp,
      ("middle=%s preview=%s"):format(tostring(tm), tostring(tp)))

    -- ── 2. and the reverse direction ───────────────────────────────
    vim.api.nvim_set_current_win(pw)
    vim.api.nvim_win_set_cursor(pw, { 320, 0 })
    vim.cmd("normal! zt")
    vim.cmd("redraw")

    vim.defer_fn(function()
      local tm2, tp2 = topline(mw), topline(pw)
      ok("b/ pane actually scrolled (control)", tp2 and tp2 ~= tp, tostring(tp2))
      ok("scrolling b/ puts a/ on the same topline", tm2 == tp2,
        ("middle=%s preview=%s"):format(tostring(tm2), tostring(tp2)))

      -- ── 3. THE REGRESSION CELL ───────────────────────────────────
      -- A scroll-bound window outside the float must be untouched. With
      -- `scrollbind` on the panes this fails: the outsider is dragged to the
      -- panes' topline, because the option couples the whole tab page.
      local outsider_after = topline(outsider)
      ok("a pre-bound window OUTSIDE the float was not dragged",
        outsider_after == outsider_before,
        ("outsider %s -> %s (panes at %s)"):format(
          tostring(outsider_before), tostring(outsider_after), tostring(tp2)))

      -- ── 4. the reentrancy guard released ─────────────────────────
      -- A guard left set would silently disable syncing from then on, which
      -- looks identical to "the feature never worked" on the next scroll.
      local st = DV._state_for_tests and DV._state_for_tests()
      ok("the reentrancy guard is not left set", st and not st.syncing,
        st and tostring(st.syncing))

      -- And syncing still works AFTER the guard has been through a cycle —
      -- the assertion a stuck guard would fail.
      vim.api.nvim_set_current_win(mw)
      vim.api.nvim_win_set_cursor(mw, { 120, 0 })
      vim.cmd("normal! zt")
      vim.cmd("redraw")

      vim.defer_fn(function()
        local tm3, tp3 = topline(mw), topline(pw)
        ok("sync still works on a later scroll (guard is not stuck)", tm3 == tp3,
          ("middle=%s preview=%s"):format(tostring(tm3), tostring(tp3)))
        finish()
      end, 120)
    end, 120)
  end, 120)
end, 400)
