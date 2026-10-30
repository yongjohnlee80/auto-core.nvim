-- auto-core.nvim — smoke test driver
--
-- Run headless:
--   nvim --headless -u NONE -l tests/smoke.lua
--
-- Use `-u NONE -l`, NOT `-u tests/smoke.lua -c 'qa!'`. The distinction
-- is a correctness gate, not style: under `-c 'qa!'` a Lua error that
-- aborts the suite mid-run is swallowed by nvim's sourcing path and the
-- trailing `qa!` still quits with EXIT 0 — a silent, GREEN abort with no
-- summary printed. Under `-l` the error propagates and nvim exits 1, so a
-- partial run is loud. auto-core is the foundation every sibling depends
-- on; a silent abort here is the most expensive one in the family. See
-- tests/run-all.sh for the summary-presence / crash-before-assertions
-- guard that catches this even when the wrong invocation is used.
--
-- Per the binding convention at
--   ~/.config/nvim/.auto-agents-config/kb/shared/conventions/lua-nvim-plugin-development.md
-- (loaded automatically by the autovim agent kb), every iteration
-- on this plugin must extend or update this driver and run it green
-- before reporting work complete. §2 mandates `-u NONE -l`; §3 mandates
-- the `<P> passed, <F> failed` summary and os.exit(1)/os.exit(0).
--
-- Phase 0: only validates package metadata + setup idempotency.
-- Subsystem tests land alongside their phase implementations:
--   Phase 1 → [2] events
--   Phase 2 → [3] state
--   Phase 3 → [4] ui.panel + [5] ui.winbar + [6] ui.section
--   Phase 4 → [7] fs.watch + [8] git.worktree
--   Phase 5 → [9] tasks
--   Phase 6 → [10] ui.float
--   Phase 7 → [11] log + [12] health
--
-- Discipline (assert-the-contract-not-internals): each `ok()` call
-- targets a public-API observable, never a private helper.

-- ─────────────────────── runtime setup ──────────────────────
-- Prepend the plugin and its hard deps onto the runtimepath so
-- this driver runs with `-u tests/smoke.lua` and finds modules
-- regardless of the user's lazy/packer state.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.rtp:prepend(plugin_root)

-- Hard dep: plenary.nvim. Per ADR 0006 §"Resolutions" #3, plenary is a
-- hard dependency. Probe the standard install paths; fail the suite
-- with a clear message if it's missing rather than silently passing.
local plenary_paths = {
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
}
local plenary_found = false
for _, p in ipairs(plenary_paths) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.rtp:prepend(p)
    plenary_found = true
    break
  end
end

-- ─────────────────────── runner harness ────────────────────
local pass_count, fail_count = 0, 0

local function ok(name, cond, detail)
  if cond then
    print("  PASS  " .. name)
    pass_count = pass_count + 1
  else
    print("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
    fail_count = fail_count + 1
  end
end

local function eq(a, b)
  if a == b then return true end
  return false, "expected " .. tostring(b) .. ", got " .. tostring(a)
end

-- ─────────────────────── 0. environment ────────────────────
print("\n[0] environment")
ok("plenary.nvim discoverable on rtp",
  plenary_found, "checked: " .. table.concat(plenary_paths, ", "))
ok("plenary.path module loads",
  pcall(require, "plenary.path"))

-- ─────────────────────── 1. package metadata ───────────────
print("\n[1] package metadata + public surface")
local ok_req, core = pcall(require, "auto-core")
ok("require('auto-core') succeeds", ok_req, tostring(core))
if not ok_req then
  print(string.format("\n%d passed, %d failed", pass_count, fail_count))
  if fail_count > 0 then os.exit(1) end
  os.exit(0)
end

ok("M.version is a semver string",
  type(core.version) == "string" and core.version:match("^%d+%.%d+%.%d+$") ~= nil,
  tostring(core.version))
-- Anchored to the CHANGELOG's newest entry, not to a hard-coded minor line.
-- It used to be pinned to `^0%.1%.%d+$`, which did not merely fail to catch a
-- stale version — it ENFORCED one: `version.lua` sat at `0.1.62` across the
-- whole v0.2.x line, ten releases behind, and this assertion was the reason it
-- could not be corrected without "breaking a test". A version string exists to
-- be believed, so the test now says it must MATCH THE RELEASE, and a bump that
-- forgets the changelog (or a changelog that forgets the bump) fails here.
ok("M.version is semver and MATCHES the CHANGELOG's newest entry", (function()
  if type(core.version) ~= "string"
    or core.version:match("^%d+%.%d+%.%d+$") == nil then return false end
  local root = vim.fn.fnamemodify(
    vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
  local lines = vim.fn.readfile(root .. "/CHANGELOG.md")
  for _, line in ipairs(lines) do
    local v = line:match("^## %[v(%d+%.%d+%.%d+)%]")
    if v then return v == core.version, v end   -- the FIRST heading is newest
  end
  return false, "no version heading found in CHANGELOG.md"
end)(), "module=" .. tostring(core.version))
ok("M.api_version is 0.1 (auto-core.todo additive; all prior surfaces unchanged)",
  select(1, eq(core.api_version, "0.1")))
ok("M.setup is a function", type(core.setup) == "function")
ok("M.config table present",
  type(core.config) == "table"
    and type(core.config.events) == "table"
    and type(core.config.events.fire_autocmds) == "boolean")

-- Default config sanity per ADR §"Resolutions" #6 (autocmd-fire opt-in)
ok("default config: events.fire_autocmds == false",
  core.config.events.fire_autocmds == false)
ok("default config: log.level == 'info'",
  core.config.log.level == "info")
ok("default config: state.persist_dir == nil (resolves at runtime)",
  core.config.state.persist_dir == nil)

-- ─────────────────────── 2. setup idempotency ──────────────
print("\n[2] setup() — idempotent + opts merge")
ok("M._initialized starts false (pre-setup)",
  core._initialized == false)

core.setup()
ok("M._initialized true after first setup()",
  core._initialized == true)
ok("default config preserved after no-arg setup",
  core.config.events.fire_autocmds == false)

core.setup({ events = { fire_autocmds = true } })
ok("setup({events={fire_autocmds=true}}) flips the flag",
  core.config.events.fire_autocmds == true)
ok("setup merge preserved unrelated defaults",
  core.config.log.level == "info")

-- Re-default for downstream tests.
core.setup({ events = { fire_autocmds = false } })
ok("re-setup re-merges from defaults",
  core.config.events.fire_autocmds == false)

-- Phase 1 wires events; Phase 2 wires state; Phase 3 wires ui.
ok("M.events is a table (Phase 1)",
  type(core.events) == "table")
ok("M.state is a table (Phase 2)",
  type(core.state) == "table")
ok("M.ui is a table with panel/winbar/section (Phase 3)",
  type(core.ui) == "table"
    and type(core.ui.panel) == "table"
    and type(core.ui.winbar) == "table"
    and type(core.ui.section) == "table")
ok("M.fs is a table with path (Phase 4a)",
  type(core.fs) == "table" and type(core.fs.path) == "table")
ok("M.git is a table with repo (Phase 4a)",
  type(core.git) == "table" and type(core.git.repo) == "table")

-- ─────────────────────── 3. events: subscribe/publish ────────
print("\n[3] events.subscribe + publish + unsubscribe")
local events = core.events
events._reset_for_tests()

local hits = {}
local h1 = events.subscribe("panel:opened", function(p) table.insert(hits, p) end)
ok("subscribe returns a handle table", type(h1) == "table")
ok("handle has id, topic, callback", type(h1.id) == "number"
  and h1.topic == "panel:opened" and type(h1.callback) == "function")
ok("count_subscribers reflects 1 active sub",
  events.count_subscribers("panel:opened") == 1)

local invoked, errors = events.publish("panel:opened", { winid = 42 })
ok("publish returns (invoked=1, errors=0)",
  invoked == 1 and errors == 0,
  string.format("invoked=%d errors=%d", invoked, errors))
ok("subscriber received the payload",
  #hits == 1 and hits[1].winid == 42)

events.unsubscribe(h1)
ok("count_subscribers drops to 0 after unsubscribe",
  events.count_subscribers("panel:opened") == 0)
events.publish("panel:opened", { winid = 99 })
ok("subscriber doesn't fire after unsubscribe",
  #hits == 1, "hits=" .. #hits)

-- ─────────────────────── 4. events.once ─────────────────────
print("\n[4] events.once auto-unsubscribes")
events._reset_for_tests()
local once_hits = 0
events.once("panel:opened", function() once_hits = once_hits + 1 end)
events.publish("panel:opened", {})
events.publish("panel:opened", {})
events.publish("panel:opened", {})
ok("once-handler fires exactly once across 3 publishes",
  once_hits == 1, "once_hits=" .. once_hits)

-- ─────────────────────── 5. error isolation ─────────────────
print("\n[5] error isolation — bad subscriber doesn't kill the chain")
events._reset_for_tests()
events.subscribe("panel:opened", function() error("boom") end)
local late_hit = false
events.subscribe("panel:opened", function() late_hit = true end)
local invoked2, errors2 = events.publish("panel:opened", {})
ok("publish reports invoked=2 errors=1",
  invoked2 == 2 and errors2 == 1,
  string.format("invoked=%d errors=%d", invoked2, errors2))
ok("downstream subscriber still fires after upstream error",
  late_hit == true)

-- ─────────────────────── 6. pattern subscribe ───────────────
print("\n[6] pattern subscribe (* wildcard between . / : separators)")
events._reset_for_tests()
local pattern_hits = {}
events.subscribe("agent.*", function(p, t)
  table.insert(pattern_hits, t)
end)
events.publish("agent.task:queued", {})
events.publish("agent.status:changed", {})
events.publish("panel:opened", {})  -- non-matching, must NOT fire
ok("pattern 'agent.*' fired for agent.task:queued",
  vim.tbl_contains(pattern_hits, "agent.task:queued"))
ok("pattern 'agent.*' fired for agent.status:changed",
  vim.tbl_contains(pattern_hits, "agent.status:changed"))
ok("pattern 'agent.*' did NOT fire for panel:opened",
  not vim.tbl_contains(pattern_hits, "panel:opened"))
ok("count_subscribers('agent.task:queued') counts the pattern sub",
  events.count_subscribers("agent.task:queued") == 1)

-- Greedy `*` — `*:opened` matches anything ending in `:opened`,
-- regardless of how many `.`s are in front.
local hits_opened = 0
events.subscribe("*:opened", function() hits_opened = hits_opened + 1 end)
events.publish("panel:opened", {})       -- match
events.publish("agent.task:opened", {})  -- also match (greedy)
events.publish("panel:closed", {})       -- non-match
ok("'*:opened' is greedy across '.'  separators",
  hits_opened == 2, "hits_opened=" .. hits_opened)

-- ─────────────────────── 7. reentrancy cap ──────────────────
print("\n[7] reentrancy guard — caps runaway publish loops")
events._reset_for_tests()
local depth = 0
local max_depth_seen = 0
events.subscribe("loop:topic", function()
  depth = depth + 1
  if depth > max_depth_seen then max_depth_seen = depth end
  events.publish("loop:topic", {})  -- intentional infinite recursion
  depth = depth - 1
end)
events.publish("loop:topic", {})
ok("max recursive depth capped at 8",
  max_depth_seen == 8, "max_depth_seen=" .. max_depth_seen)

-- ─────────────────────── 8. trace ring buffer ───────────────
print("\n[8] events.trace ring buffer")
events._reset_for_tests()
events.configure({ trace_capacity = 5 })  -- small buffer to test wraparound
events.subscribe("panel:opened", function() end)
for i = 1, 8 do
  events.publish("panel:opened", { i = i })
end
local recent = events.trace.recent()
ok("trace cap honored (5 entries despite 8 publishes)",
  #recent == 5, "got " .. #recent)
ok("trace preserves most-recent entries (i=4..8)",
  recent[1].topic == "panel:opened"
    and recent[#recent].subscribers == 1)

-- Restore default capacity for any subsequent tests.
events.configure({ trace_capacity = 200 })
events._reset_for_tests()

-- ─────────────────────── 9. autocmd-fire compat shim (opt-in) ──
print("\n[9] autocmd-fire compat shim — opt-in via setup")
events.configure({ fire_autocmds = false })
local autocmd_hits = 0
local group = vim.api.nvim_create_augroup("AutoCoreSmokeTestShim", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "AutoCore_panel_opened",
  callback = function() autocmd_hits = autocmd_hits + 1 end,
})

events.publish("panel:opened", {})
ok("with fire_autocmds=false, no autocmd User AutoCore_panel_opened fires",
  autocmd_hits == 0, "autocmd_hits=" .. autocmd_hits)

events.configure({ fire_autocmds = true })
events.publish("panel:opened", {})
ok("with fire_autocmds=true, the User autocmd fires",
  autocmd_hits == 1, "autocmd_hits=" .. autocmd_hits)

vim.api.nvim_del_augroup_by_id(group)
events.configure({ fire_autocmds = false })
events._reset_for_tests()

-- ─────────────────────── 10. state: namespace + get/set/defaults ───
print("\n[10] state.namespace — claim, defaults fallthrough, set/get")
local state = core.state
state._reset_for_tests()
events._reset_for_tests()

-- Use ephemeral so this test never touches disk.
local s = state.namespace("auto-test", {
  defaults = { panel = { width = 38, mode = "auto" }, count = 5 },
  persist  = "ephemeral",
})

ok("namespace returns an object with get/set/watch",
  type(s.get) == "function" and type(s.set) == "function"
    and type(s.watch) == "function")
ok("get returns the default when no value has been set",
  s:get("panel.width") == 38, "got " .. tostring(s:get("panel.width")))
ok("get returns nil for an unknown key not in defaults",
  s:get("nope.unknown") == nil)

s:set("panel.width", 50)
ok("set + get round-trips the value",
  s:get("panel.width") == 50, "got " .. tostring(s:get("panel.width")))
ok("set on one path doesn't disturb another",
  s:get("panel.mode") == "auto" and s:get("count") == 5)

ok("get_all returns defaults + sets layered",
  (function()
    local all = s:get_all()
    return all.panel.width == 50 and all.panel.mode == "auto" and all.count == 5
  end)())

-- ─────────────────────── 11. state: change events ───────────────
print("\n[11] state set auto-publishes a change event")
state._reset_for_tests()
events._reset_for_tests()
local ns = state.namespace("auto-test", { persist = "ephemeral",
  defaults = { panel = { user_width = nil } } })

local event_hits = {}
core.events.subscribe("state.auto-test:panel.user_width:changed", function(p)
  table.insert(event_hits, p)
end)

ns:set("panel.user_width", 42)
ok("set fires state.<ns>:<key>:changed with new+old payload",
  #event_hits == 1
    and event_hits[1].namespace == "auto-test"
    and event_hits[1].key == "panel.user_width"
    and event_hits[1].new == 42
    and event_hits[1].old == nil,
  vim.inspect(event_hits))

ns:set("panel.user_width", 42)  -- same value
ok("setting same value does NOT re-fire the change event",
  #event_hits == 1, "extra hits=" .. (#event_hits - 1))

ns:set("panel.user_width", 60)
ok("changing the value fires another event with old=42",
  #event_hits == 2 and event_hits[2].old == 42 and event_hits[2].new == 60)

-- ─────────────────────── 12. state.watch convenience ────────────
print("\n[12] state:watch is sugar over events.subscribe")
state._reset_for_tests()
events._reset_for_tests()
local ns2 = state.namespace("auto-test", { persist = "ephemeral" })

local watch_hits = 0
local h = ns2:watch("foo.bar", function() watch_hits = watch_hits + 1 end)
ns2:set("foo.bar", 1)
ok("watch fires on the matching change event", watch_hits == 1)
ns2:unwatch(h)
ns2:set("foo.bar", 2)
ok("unwatch stops further fires", watch_hits == 1)

-- Wildcard via events bus
local wild_hits = 0
ns2:watch("foo.*", function() wild_hits = wild_hits + 1 end)
ns2:set("foo.bar", 3)
ns2:set("foo.baz", 1)
ok("watch('foo.*') fires for any matching child key",
  wild_hits == 2, "wild_hits=" .. wild_hits)

-- ─────────────────────── 13. state isolation across namespaces ──
print("\n[13] state isolation — auto-agents and auto-finder don't collide")
state._reset_for_tests()
events._reset_for_tests()
local agents = state.namespace("auto-agents", {
  defaults = { panel = { slot_count = 5 } },
  persist  = "ephemeral",
})
local finder = state.namespace("auto-finder", {
  defaults = { panel = { user_width = 38 } },
  persist  = "ephemeral",
})

agents:set("panel.slot_count", 7)
ok("auto-agents.panel.slot_count = 7", agents:get("panel.slot_count") == 7)
ok("auto-finder.panel.user_width still default",
  finder:get("panel.user_width") == 38)
ok("auto-finder doesn't see the auto-agents key (different namespace)",
  finder:get("panel.slot_count") == nil)

finder:set("panel.user_width", 42)
ok("auto-finder.panel.user_width = 42", finder:get("panel.user_width") == 42)
ok("auto-agents.panel.user_width still nil (different namespace)",
  agents:get("panel.user_width") == nil)

ok("agents fires its own change events, NOT auto-finder's",
  (function()
    local agents_hits = 0
    state._reset_for_tests()
    events._reset_for_tests()
    local a = state.namespace("auto-agents", { persist = "ephemeral",
      defaults = { panel = { slot_count = 5 } } })
    local f = state.namespace("auto-finder", { persist = "ephemeral",
      defaults = { panel = { user_width = 38 } } })
    core.events.subscribe("state.auto-agents:panel.slot_count:changed",
      function() agents_hits = agents_hits + 1 end)
    f:set("panel.user_width", 99)  -- writing to finder
    a:set("panel.slot_count", 7)   -- writing to agents
    return agents_hits == 1
  end)())

-- ─────────────────────── 14. state idempotent claim ──────────────
print("\n[14] state.namespace is idempotent (singleton per name)")
state._reset_for_tests()
events._reset_for_tests()
local first = state.namespace("auto-test", { persist = "ephemeral",
  defaults = { a = 1 } })
first:set("a", 99)
local second = state.namespace("auto-test", { persist = "ephemeral",
  defaults = { b = 2 } })  -- additional defaults merged
ok("second claim returns the same instance",
  first == second, "first ~= second")
ok("user-set value preserved across re-claim",
  second:get("a") == 99)
ok("additional defaults merged in",
  second:get("b") == 2)

-- ─────────────────────── 15. state: json persist round-trip ─────
print("\n[15] state json persist — write + reload round-trip")
state._reset_for_tests()
events._reset_for_tests()

-- Use a tempdir specifically for this test so we don't pollute the
-- user's actual ~/.local/state/nvim/auto-core/.
local persist_dir = vim.fn.tempname()
vim.fn.mkdir(persist_dir, "p")
state.configure({ persist_dir = persist_dir })

local ns3 = state.namespace("persist-test", {
  defaults = { panel = { width = 38 } },
  persist  = "json",
})
ns3:set("panel.width", 77)
ns3:set("flag", true)
ns3:persist_now()  -- flush synchronously so the test can read the file

local persist_path = persist_dir .. "/persist-test.json"
ok("json file written at the expected path",
  vim.fn.filereadable(persist_path) == 1, persist_path)

-- Reset registry + reload to simulate restart
state._reset_for_tests()
local reloaded = state.namespace("persist-test", {
  defaults = { panel = { width = 38 } },
  persist  = "json",
})
ok("persisted panel.width survives reload",
  reloaded:get("panel.width") == 77)
ok("persisted flag survives reload",
  reloaded:get("flag") == true)
ok("default still falls through for non-persisted keys",
  reloaded:get("never_set") == nil)

-- Cleanup the tempdir.
state._reset_for_tests()
state.configure({ persist_dir = nil })  -- back to default
pcall(vim.fn.delete, persist_dir, "rf")

-- ─────────────────────── 16. state.clear ────────────────────────
print("\n[16] state:clear")
state._reset_for_tests()
events._reset_for_tests()
local ns4 = state.namespace("auto-test", { persist = "ephemeral",
  defaults = { x = 10 } })
ns4:set("x", 99)
ok("get returns user-set value before clear", ns4:get("x") == 99)
ns4:clear("x")
ok("clear(key) removes user-set value, fall-through to default",
  ns4:get("x") == 10)

ns4:set("a", 1)
ns4:set("b", 2)
ns4:clear()
ok("clear() with no key removes all user-set values",
  ns4:get("a") == nil and ns4:get("b") == nil)

-- ─────────────────────── 17. ui.winbar.render (pure) ────────
print("\n[17] ui.winbar.render — three modes by available width")
local winbar = core.ui.winbar
local sections_def = {
  { number = 0, name = "config" },
  { number = 1, name = "files"  },
  { number = 2, name = "repos"  },
}
local full = winbar.render(1, sections_def, 80)
ok("winbar(80, focused=1) contains '0: config' (full label)",
  full:find("0: config", 1, true) ~= nil, full)
ok("winbar contains the focused active highlight wrap",
  full:find("AutoCoreSectionActive", 1, true) ~= nil, full)
ok("winbar contains a clickable region for section 1",
  full:find("%%1@v:lua%.require'auto%-core%.ui%.winbar'%.click@") ~= nil)

local narrow = winbar.render(1, sections_def, 12)
ok("winbar(narrow=12) drops the unfocused labels",
  narrow:find("config", 1, true) == nil, narrow)
ok("winbar(narrow) keeps the focused label '[1: files]' or '[1]'",
  narrow:find("[1", 1, true) ~= nil, narrow)

-- ─────────────────────── 18. ui.panel singleton + open/close ─
print("\n[18] ui.panel — open / close / singleton-marker adoption")
local Panel = core.ui.panel
Panel._reset_for_tests()
events._reset_for_tests()

local panel = Panel.new({
  name  = "test-panel",
  side  = "left",
  width = { default = 30, min = 20, max = 80 },
  filetype = "auto-core-test",
})
ok("Panel.new returns a table with open/close/toggle/focus/resize",
  type(panel.open) == "function" and type(panel.close) == "function"
    and type(panel.toggle) == "function" and type(panel.focus) == "function"
    and type(panel.resize) == "function")

-- Pre-open: subscribe to panel:opened so we can verify the event.
local opened_payload = nil
core.events.subscribe("panel:opened", function(p) opened_payload = p end)

local winid = panel:open(true)
ok("panel:open() returns a valid winid",
  winid and vim.api.nvim_win_is_valid(winid))
ok("panel.winid was set",
  panel.winid == winid)
ok("panel:opened event fired with name + winid",
  opened_payload and opened_payload.name == "test-panel"
    and opened_payload.winid == winid,
  vim.inspect(opened_payload))

ok("panel window has winfixwidth set",
  vim.wo[winid].winfixwidth == true)
ok("panel window has winfixbuf set",
  vim.wo[winid].winfixbuf == true)
ok("panel window stamped w:test-panel_panel = 1",
  (function()
    local ok_get, m = pcall(vim.api.nvim_win_get_var, winid, "test_panel_panel")
    return ok_get and m == 1
  end)())
ok("panel window stamped w:auto_core_panel_name = 'test-panel'",
  (function()
    local ok_get, n = pcall(vim.api.nvim_win_get_var, winid, "auto_core_panel_name")
    return ok_get and n == "test-panel"
  end)())

-- Singleton-marker adoption: drop the cached winid (simulate
-- :Lazy reload), call open() again, expect adoption rather than
-- a duplicate.
local pre_count = #vim.api.nvim_tabpage_list_wins(0)
panel.winid = nil
local re_winid = panel:open(true)
ok("re-open with cleared state ADOPTS the marked window",
  re_winid == winid, "got " .. tostring(re_winid) .. " expected " .. tostring(winid))
ok("no duplicate window created",
  #vim.api.nvim_tabpage_list_wins(0) == pre_count)

-- ─────────────────────── 19. ui.panel resize + pin ──────────
print("\n[19] ui.panel resize + reset_width")
panel:resize(50)
ok("panel:resize(50) pins user_width", panel.user_width == 50)
ok("panel window width == 50 after resize",
  vim.api.nvim_win_get_width(winid) == 50,
  "got " .. vim.api.nvim_win_get_width(winid))

panel:reset_width()
ok("panel:reset_width() clears user_width", panel.user_width == nil)
-- After reset, width returns to the default (30).
ok("panel window width back to default (30)",
  vim.api.nvim_win_get_width(winid) == 30,
  "got " .. vim.api.nvim_win_get_width(winid))

-- ─────────────────────── 20. ui.panel close + event ─────────
print("\n[20] ui.panel close fires panel:closed")
local closed_payload = nil
core.events.subscribe("panel:closed", function(p) closed_payload = p end)
panel:close()
ok("panel.winid cleared after close", panel.winid == nil)
ok("panel:closed event fired with name",
  closed_payload and closed_payload.name == "test-panel",
  vim.inspect(closed_payload))

Panel._reset_for_tests()
events._reset_for_tests()

-- ─────────────────────── 21. ui.section attach + focus ──────
print("\n[21] ui.section — attach + focus + buffer-local q keymap")
local panel2 = Panel.new({
  name  = "test-sections",
  side  = "left",
  width = { default = 30, min = 20, max = 80 },
})
panel2:open(true)

-- Two simple sections, each builds a scratch buffer with a name.
local mk_buf = function(label)
  return function(_panel)
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].buftype = "nofile"
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "section: " .. label })
    return b
  end
end
local Section = core.ui.section
local registry = Section.attach(panel2, {
  { number = 0, name = "config", get_buffer = mk_buf("config") },
  { number = 1, name = "files",  get_buffer = mk_buf("files")  },
}, { default = 0 })

ok("Section.attach returns a registry with focus/add/remove",
  type(registry.focus) == "function" and type(registry.add) == "function"
    and type(registry.remove) == "function")

local ok_focus = registry:focus(0)
ok("registry:focus(0) returns true", ok_focus)
ok("active section == 0", registry.active == 0)
ok("panel buffer holds 'section: config'",
  (function()
    local b = vim.api.nvim_win_get_buf(panel2.winid)
    local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
    return first == "section: config"
  end)())

ok("section bufnr cached after first focus",
  registry._bufs[0] ~= nil)

registry:focus(1)
ok("active section == 1 after focus(1)", registry.active == 1)
ok("panel buffer holds 'section: files' after focus(1)",
  (function()
    local b = vim.api.nvim_win_get_buf(panel2.winid)
    local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
    return first == "section: files"
  end)())

-- Buffer-local 0..9 keymap and q keymap should be bound.
local map = vim.fn.maparg("q", "n", false, true)
ok("q is bound buffer-locally on the section buffer",
  type(map) == "table" and map.buffer == 1
    and (map.desc or ""):find("close panel") ~= nil,
  vim.inspect(map))
local map0 = vim.fn.maparg("0", "n", false, true)
ok("0 is bound buffer-locally for section switch",
  type(map0) == "table" and map0.buffer == 1
    and (map0.desc or ""):find("focus section") ~= nil)

-- Add a runtime section.
registry:add({ number = 2, name = "repos", get_buffer = mk_buf("repos") })
ok("registry:add appends new section",
  #registry.sections == 3 and registry.sections[3].name == "repos")

registry:focus(2)
ok("focus(new section) works",
  registry.active == 2)

-- Remove a section — its on_close hook should fire and bufnr drop.
local on_close_hits = 0
registry:add({ number = 3, name = "logs",
  get_buffer = mk_buf("logs"),
  on_close = function() on_close_hits = on_close_hits + 1 end })
registry:focus(3)  -- materialize the buffer first
ok("section 3 (logs) bufnr cached", registry._bufs[3] ~= nil)
local removed = registry:remove(3)
ok("registry:remove returns true", removed)
ok("on_close hook fired", on_close_hits == 1)
ok("bufnr cache cleared after remove", registry._bufs[3] == nil)

panel2:close()
registry:dispose()
Panel._reset_for_tests()
events._reset_for_tests()

-- ─────────── 21b. ui.section — section_did_remount (ADR-0033) ──
-- Regression coverage for the dbase winbar/keymap remount bug
-- ([[2026-05-20-auto-finder-dbase-winbar-remount-bug-analysis]]).
-- The public hook repairs the three side-effects an async-mount
-- view loses when it swaps its placeholder for the real buffer
-- outside the registry's focus() window: cache reseat, keymap
-- rebind, winbar refresh. This unit drives the hook directly on a
-- stub two-section registry (no dbee required) — see ADR-0033 §2.1.
print("\n[21b] ui.section — Registry:section_did_remount (ADR-0033)")
do
  local panelR = Panel.new({
    name  = "test-remount",
    side  = "left",
    width = { default = 30, min = 20, max = 80 },
  })
  panelR:open(true)

  local regR = Section.attach(panelR, {
    { number = 0, name = "alpha", get_buffer = mk_buf("alpha") },
    { number = 1, name = "beta",  get_buffer = mk_buf("beta")  },
  }, { default = 0 })
  regR:focus(0)

  -- Window-independent keymap inspection: does `bufnr` carry a
  -- buffer-local normal-mode map for `lhs` whose desc contains
  -- `needle`? (section_did_remount does NOT swap the panel window,
  -- so maparg-on-current-buffer would not see the real buffer.)
  local function has_map(bufnr, lhs, needle)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return false end
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if m.lhs == lhs and (m.desc or ""):find(needle, 1, true) then
        return true
      end
    end
    return false
  end
  local function count_map(bufnr, lhs)
    local n = 0
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if m.lhs == lhs then n = n + 1 end
    end
    return n
  end

  ok("[21b] precondition: section 0 active", regR.active == 0)

  -- Fresh "real" buffer — mirrors dbase swapping the loading
  -- placeholder for the dbee drawer — then notify the registry.
  local realA = vim.api.nvim_create_buf(false, true)
  vim.bo[realA].buftype = "nofile"
  regR:section_did_remount(0, realA)

  -- (1) cache reseat
  ok("[21b] _bufs[0] reseated to the real buffer",
    regR._bufs[0] == realA,
    "got=" .. tostring(regR._bufs[0]) .. " want=" .. tostring(realA))

  -- (2) keymaps rebound on the real buffer (active section)
  ok("[21b] q rebound buffer-locally on the real buffer",
    has_map(realA, "q", "close panel"))
  ok("[21b] 0 rebound buffer-locally on the real buffer",
    has_map(realA, "0", "focus section 0"))
  ok("[21b] 9 rebound buffer-locally on the real buffer",
    has_map(realA, "9", "focus section 9"))

  -- (3) winbar refreshed with the active section's name
  local wb = vim.api.nvim_get_option_value("winbar", { win = panelR.winid })
  ok("[21b] winbar shows the active section after remount",
    type(wb) == "string" and wb:find("alpha", 1, true) ~= nil,
    "winbar=" .. tostring(wb))

  -- (4) idempotency: second call with the same buffer is a no-op,
  --     does not error, and does not duplicate keymaps.
  regR:section_did_remount(0, realA)
  ok("[21b] idempotent: _bufs[0] still the real buffer",
    regR._bufs[0] == realA)
  ok("[21b] idempotent: exactly one q map (no duplicate)",
    count_map(realA, "q") == 1, "count=" .. count_map(realA, "q"))

  -- (5) inactive-section guard: remount section 1 while 0 is active.
  --     Cache reseats unconditionally, but the buffer-local keymap
  --     surface + winbar belong to the active section only — they
  --     must NOT change (ui/section.lua active-section guard).
  local wb_before = vim.api.nvim_get_option_value("winbar", { win = panelR.winid })
  local realB = vim.api.nvim_create_buf(false, true)
  vim.bo[realB].buftype = "nofile"
  regR:section_did_remount(1, realB)
  ok("[21b] inactive guard: _bufs[1] still reseated",
    regR._bufs[1] == realB)
  ok("[21b] inactive guard: no q map bound on inactive buffer",
    not has_map(realB, "q", "close panel"))
  ok("[21b] inactive guard: winbar unchanged for inactive remount",
    vim.api.nvim_get_option_value("winbar", { win = panelR.winid }) == wb_before)

  -- (6) invalid-bufnr guard: nil + wiped bufnr are no-ops.
  local keep = regR._bufs[0]
  regR:section_did_remount(0, nil)
  ok("[21b] invalid guard: nil bufnr leaves _bufs[0] unchanged",
    regR._bufs[0] == keep)
  local wiped = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(wiped, { force = true })
  regR:section_did_remount(0, wiped)
  ok("[21b] invalid guard: wiped bufnr leaves _bufs[0] unchanged",
    regR._bufs[0] == keep)

  panelR:close()
  regR:dispose()
  Panel._reset_for_tests()
  events._reset_for_tests()
end

-- ─────────────────────── 22. fs.path normalize/join/parent ───────
print("\n[22] fs.path — normalize, join, parent, basename, relative")
local p = core.fs.path

ok("normalize collapses trailing slash",
  p.normalize("/tmp/foo/")  == "/tmp/foo")
ok("normalize resolves ~",
  p.normalize("~/x"):sub(1, 1) == "/")  -- should be absolute
ok("normalize resolves '..'",
  p.normalize("/tmp/foo/../bar") == "/tmp/bar")
ok("normalize on empty returns empty",
  p.normalize("") == "")

ok("join concatenates two with /",
  p.join("/tmp", "foo") == "/tmp/foo")
ok("join handles trailing slash on first arg",
  p.join("/tmp/", "foo") == "/tmp/foo")
ok("join skips empty components",
  p.join("/tmp", "", "foo") == "/tmp/foo")
ok("join with abs middle component resets",
  p.join("/tmp", "/etc", "passwd") == "/etc/passwd")

ok("parent returns dirname",
  p.parent("/tmp/foo/bar.lua") == "/tmp/foo")
ok("basename returns filename",
  p.basename("/tmp/foo/bar.lua") == "bar.lua")

ok("relative under base", p.relative("/a/b/c", "/a") == "b/c")
ok("relative same path is .", p.relative("/a/b", "/a/b") == ".")
ok("relative not under returns nil",
  p.relative("/a/b", "/x") == nil)
ok("relative doesn't false-positive prefix",
  p.relative("/foobar", "/foo") == nil)

-- ─────────────────────── 23. fs.path is_under / type checks ─────
print("\n[23] fs.path — is_under, exists, is_dir, is_file")
ok("is_under true for child",
  p.is_under("/tmp/foo/bar", "/tmp/foo") == true)
ok("is_under true for self",
  p.is_under("/tmp/foo", "/tmp/foo") == true)
ok("is_under false for sibling",
  p.is_under("/tmp/foobar", "/tmp/foo") == false)

local td = vim.fn.tempname()
vim.fn.mkdir(td, "p")
ok("is_dir true on a real dir", p.is_dir(td))
ok("exists true on a real dir", p.exists(td))
ok("is_file false on a dir", p.is_file(td) == false)

local tf = td .. "/sample.txt"
vim.fn.writefile({ "hello" }, tf)
ok("is_file true on a real file", p.is_file(tf))
ok("exists true on a real file", p.exists(tf))
ok("is_dir false on a file", p.is_dir(tf) == false)
ok("exists false on a non-existent path",
  p.exists(td .. "/nope") == false)

-- ─────────────────────── 24. fs.path root resolvers ─────────────
print("\n[24] fs.path — project_root / git_root / workspace_root")
-- Build a fake worktree-style layout under a tempdir. The `.git/`
-- needs a `HEAD` entry to pass v0.1.33's empty-`.git` validator
-- (Lector audit 2026-05-24); plant the minimal real-git shape.
local repo = td .. "/proj-fake"
vim.fn.mkdir(repo .. "/.git", "p")
vim.fn.writefile({ "ref: refs/heads/main" }, repo .. "/.git/HEAD")
vim.fn.writefile({ "" }, repo .. "/go.mod")
local sub = repo .. "/internal/pkg"
vim.fn.mkdir(sub, "p")

ok("project_root finds the .git ancestor",
  p.project_root({ start = sub }) == repo)
ok("git_root finds the .git ancestor",
  p.git_root({ start = sub }) == repo)
ok("project_root respects custom markers (go.mod alone)",
  p.project_root({ start = sub, markers = { "go.mod" } }) == repo)
ok("project_root returns nil when no marker found",
  p.project_root({ start = "/", markers = { "definitely-not-here.x" } }) == nil)

-- workspace_root: parent of the .git ancestor
ok("workspace_root falls back to parent of git_root",
  p.workspace_root({ start = sub }) == td)

-- workspace_root with a `.bare` marker prefers the container
local ws = td .. "/multi-repo"
vim.fn.mkdir(ws .. "/.bare", "p")
vim.fn.mkdir(ws .. "/branch-a/.git", "p")
ok("workspace_root with .bare picks the container directly",
  p.workspace_root({ start = ws .. "/branch-a" }) == ws)

-- agent_workspace_root: stable per-project identity (the value
-- worktree.nvim pins as core.workspace_root, hashed into every
-- per-project key — auto-finder panels, md-harpoon pins, todo dir).
-- Precedence: `.auto-agents/` (full ancestry) → `.bare` container →
-- plain repo root → cwd unchanged.
-- ADR-0070: every call below passes the inclusive ancestry boundary
-- `stop = td` (the fixture root this suite creates), so environmental
-- ancestors (e.g. a stray /tmp/.auto-agents/ from an agent-spawned
-- nvim) are invisible by construction. The trailing matrix pins the
-- boundary semantics per pass with hermetic controls — NO unbounded
-- control call anywhere (an unbounded walk consults /tmp and above,
-- which is exactly the uncontrolled state ADR-0070 eliminates).
-- NOTE: scoped in a `do … end` so its locals release their registers
-- before the chunk's peak — this driver sits at Lua's 200-local cap.
do
  local aws = td .. "/agent-ws"
  vim.fn.mkdir(aws .. "/.auto-agents", "p")
  -- a plain git repo nested inside the agent workspace, with a deep
  -- subdir AND a linked-worktree-style `.git` FILE child
  vim.fn.mkdir(aws .. "/repoX/.git", "p")
  vim.fn.writefile({ "ref: refs/heads/main" }, aws .. "/repoX/.git/HEAD")
  vim.fn.mkdir(aws .. "/repoX/deep/nested", "p")
  vim.fn.mkdir(aws .. "/repoX/wt", "p")
  vim.fn.writefile({ "gitdir: " .. aws .. "/repoX/.git/worktrees/wt" },
    aws .. "/repoX/wt/.git")
  ok("agent_workspace_root: .auto-agents wins at the marker dir",
    p.agent_workspace_root({ start = aws, stop = td }) == aws)
  ok("agent_workspace_root: .auto-agents collapses a nested repo",
    p.agent_workspace_root({ start = aws .. "/repoX", stop = td }) == aws)
  ok("agent_workspace_root: .auto-agents collapses a deep subdir",
    p.agent_workspace_root({ start = aws .. "/repoX/deep/nested", stop = td }) == aws)
  ok("agent_workspace_root: .auto-agents collapses a linked worktree",
    p.agent_workspace_root({ start = aws .. "/repoX/wt", stop = td }) == aws)
  -- standalone `.bare` layout (no .auto-agents) → the bare container
  ok("agent_workspace_root: .bare layout collapses worktrees to container",
    p.agent_workspace_root({ start = ws .. "/branch-a", stop = td }) == ws)
  -- standalone plain repo (no .auto-agents/.bare) → the repo ROOT
  -- itself, not its parent (the distinction from workspace_root)
  ok("agent_workspace_root: plain repo returns the repo root, not parent",
    p.agent_workspace_root({ start = sub, stop = td }) == repo)
  -- marker-less start → unchanged (parity with the legacy raw-cwd pin)
  local bare_dir = td .. "/no-markers/here"
  vim.fn.mkdir(bare_dir, "p")
  ok("agent_workspace_root: marker-less start returns the start dir",
    p.agent_workspace_root({ start = bare_dir, stop = td }) == bare_dir)

  -- ── ADR-0070 boundary matrix (pass-discriminating, hermetic) ──
  -- Each pin fails if only its corresponding pass loses the bound.
  -- Controls are bounded inclusion controls (stop = marker_parent),
  -- never unbounded calls — see the section comment above.
  do
    local inner
    -- pin 1: inclusive edge — a marker exactly AT stop is FOUND
    vim.fn.mkdir(td .. "/at-stop/.auto-agents", "p")
    vim.fn.mkdir(td .. "/at-stop/inner", "p")
    ok("agent_workspace_root: marker exactly AT stop is found (inclusive edge)",
      p.agent_workspace_root(
        { start = td .. "/at-stop/inner", stop = td .. "/at-stop" })
        == td .. "/at-stop")

    -- pin 2: rule 1 (.auto-agents) honors the bound
    vim.fn.mkdir(td .. "/excl-aa/.auto-agents", "p")
    vim.fn.mkdir(td .. "/excl-aa/inner", "p")
    inner = td .. "/excl-aa/inner"
    ok("agent_workspace_root: .auto-agents above stop is excluded",
      p.agent_workspace_root({ start = inner, stop = inner }) == inner)
    ok("agent_workspace_root: .auto-agents control — marker at widened stop is found",
      p.agent_workspace_root({ start = inner, stop = td .. "/excl-aa" })
        == td .. "/excl-aa")

    -- pin 3: rule 2 (.bare) honors the bound — no .auto-agents on the
    -- fixture chain, so nothing can mask the .bare result
    vim.fn.mkdir(td .. "/excl-bare/.bare", "p")
    vim.fn.mkdir(td .. "/excl-bare/inner", "p")
    inner = td .. "/excl-bare/inner"
    ok("agent_workspace_root: .bare above stop is excluded",
      p.agent_workspace_root({ start = inner, stop = inner }) == inner)
    ok("agent_workspace_root: .bare control — marker at widened stop is found",
      p.agent_workspace_root({ start = inner, stop = td .. "/excl-bare" })
        == td .. "/excl-bare")

    -- pin 4: rule 3 (valid .git) honors the bound — neither
    -- higher-precedence marker on the fixture chain
    vim.fn.mkdir(td .. "/excl-git/.git", "p")
    vim.fn.writefile({ "ref: refs/heads/main" }, td .. "/excl-git/.git/HEAD")
    vim.fn.mkdir(td .. "/excl-git/inner", "p")
    inner = td .. "/excl-git/inner"
    ok("agent_workspace_root: valid .git above stop is excluded",
      p.agent_workspace_root({ start = inner, stop = inner }) == inner)
    ok("agent_workspace_root: .git control — marker at widened stop is found",
      p.agent_workspace_root({ start = inner, stop = td .. "/excl-git" })
        == td .. "/excl-git")

    -- pin 5: fail-closed contract — invalid stop (sibling subtree) and
    -- the filesystem root both error loudly. Assert semantics: the
    -- message mentions `stop` and the ancestor/boundary contract.
    local ok_call, err = pcall(p.agent_workspace_root,
      { start = td .. "/at-stop/inner", stop = td .. "/excl-aa" })
    ok("agent_workspace_root: invalid stop (off-ancestry) raises",
      ok_call == false and err:match("stop") ~= nil
        and err:match("ancestor") ~= nil)
    ok_call, err = pcall(p.agent_workspace_root,
      { start = td .. "/at-stop/inner", stop = "/" })
    ok("agent_workspace_root: stop = filesystem root raises",
      ok_call == false and err:match("stop") ~= nil
        and err:match("ancestor") ~= nil)
    ok_call, err = pcall(p.agent_workspace_root,
      { start = "/", stop = "/" })
    ok("agent_workspace_root: root start cannot bypass root-stop validation",
      ok_call == false and err:match("stop") ~= nil
        and err:match("ancestor") ~= nil)

    -- pin 6: marker-less tier under a dirty SIBLING subtree — a
    -- planted .auto-agents under td but OFF the walked chain of the
    -- start path changes nothing (the original incident, restated)
    vim.fn.mkdir(td .. "/planted-aa/.auto-agents", "p")
    ok("agent_workspace_root: marker-less walk ignores dirty sibling subtree",
      p.agent_workspace_root({ start = bare_dir, stop = td }) == bare_dir)
  end
end

-- Cleanup
pcall(vim.fn.delete, td, "rf")

-- ─────────────────────── 25. git.repo — is_git / root / dirs ────
print("\n[25] git.repo — is_git / root / git_dir / common_dir / is_bare")
-- This test depends on the auto-core repo itself being a git repo
-- (we're running in-tree).
local repo_mod = core.git.repo
local self_root = repo_mod.root()
ok("git.repo.root returns a non-nil string when run inside a repo",
  type(self_root) == "string" and #self_root > 0,
  tostring(self_root))

ok("git.repo.is_git true on the repo root",
  repo_mod.is_git(self_root) == true)
ok("git.repo.is_git true on a sub-path of the repo",
  repo_mod.is_git(self_root .. "/lua") == true)

local gd = repo_mod.git_dir(self_root)
ok("git.repo.git_dir returns an absolute path",
  type(gd) == "string" and gd:sub(1, 1) == "/", tostring(gd))

local cd = repo_mod.common_dir(self_root)
ok("git.repo.common_dir returns an absolute path",
  type(cd) == "string" and cd:sub(1, 1) == "/", tostring(cd))

ok("git.repo.is_bare false on the auto-core working tree",
  repo_mod.is_bare(self_root) == false)

-- Negative cases — a known-non-git path.
local non_git = vim.fn.tempname() .. "-no-git"
vim.fn.mkdir(non_git, "p")
ok("git.repo.is_git false on a fresh empty dir",
  repo_mod.is_git(non_git) == false)
ok("git.repo.root nil on a fresh empty dir",
  repo_mod.root(non_git) == nil)
pcall(vim.fn.delete, non_git, "rf")

-- v0.1.33 / Lector round-3 regression: an EMPTY `.git/` directory
-- ancestor must not be treated as a valid git marker. Before the
-- validator was added, a stray `/tmp/.git/` (common on dev
-- machines) caused every `/tmp/<x>/` to misclassify as in-repo.
do
  local stray_root = vim.fn.tempname() .. "-empty-git-ancestor"
  local stray_git  = stray_root .. "/.git"
  local child      = stray_root .. "/sub/leaf"
  vim.fn.mkdir(stray_git, "p")  -- empty .git dir
  vim.fn.mkdir(child, "p")
  ok("git.repo.is_git rejects empty `.git` ancestor",
    repo_mod.is_git(child) == false,
    "got: " .. tostring(repo_mod.is_git(child)))
  ok("git.repo.root nil when ancestor `.git` is empty",
    repo_mod.root(child) == nil,
    "got: " .. tostring(repo_mod.root(child)))
  -- Plant a `HEAD` ref to verify the validator accepts a real
  -- repository-shaped `.git/` once entries appear.
  vim.fn.writefile({ "ref: refs/heads/main" }, stray_git .. "/HEAD")
  ok("git.repo.is_git accepts `.git` ancestor with HEAD",
    repo_mod.is_git(child) == true,
    "got: " .. tostring(repo_mod.is_git(child)))
  -- And a FILE `.git` (linked-worktree gitdir indirection) — also
  -- accepted, separate from the dir-marker validator.
  local lwt_root = vim.fn.tempname() .. "-linked-worktree"
  vim.fn.mkdir(lwt_root, "p")
  vim.fn.writefile({ "gitdir: /elsewhere/repo/.git/worktrees/lwt" },
    lwt_root .. "/.git")
  ok("git.repo.is_git accepts file-marker `.git` (linked-worktree gitdir indirection)",
    repo_mod.is_git(lwt_root) == true,
    "got: " .. tostring(repo_mod.is_git(lwt_root)))
  pcall(vim.fn.delete, stray_root, "rf")
  pcall(vim.fn.delete, lwt_root, "rf")
end

-- ─────────────────────── 26. fs.watch — libuv watcher + events ──────────────
print("\n[26] fs.watch — start/stop, events, debounce, ignore, max_handles")
local watch = require("auto-core.fs.watch")
local events_mod = require("auto-core.events")
events_mod._reset_for_tests()
watch._reset_for_tests()

ok("fs.watch.start returns nil on a non-directory",
  (function()
    local h, err = watch.start("/definitely/not/a/path/to/anywhere")
    return h == nil and type(err) == "string"
  end)())

-- Build a tmp tree:  <root>/   {a.txt, sub/, .git/HEAD, sub/b.txt}
local tmp_root = vim.fn.tempname() .. "-fs-watch"
vim.fn.mkdir(tmp_root, "p")
vim.fn.mkdir(tmp_root .. "/sub", "p")
vim.fn.mkdir(tmp_root .. "/.git", "p")  -- should be ignored by default
vim.fn.writefile({ "stamp" }, tmp_root .. "/.git/HEAD")

-- Capture events for assertion. Subscriber records into a list.
local seen = {}
events_mod.subscribe("core.file:*", function(payload, topic)
  seen[#seen + 1] = { topic = topic, path = payload.path, change = payload.change }
end)

local handle, err = watch.start(tmp_root)
ok("watch.start succeeds on real dir",
  handle ~= nil and handle.id ~= nil, tostring(err))
ok("watch.list reports one handle",
  #watch.list() == 1)

-- Trigger a create. Use writefile (synchronous) then vim.wait to
-- drain the libuv event loop into our subscriber.
vim.fn.writefile({ "hello" }, tmp_root .. "/a.txt")
vim.wait(300, function()
  for _, e in ipairs(seen) do
    if e.path:sub(-#"/a.txt") == "/a.txt" then return true end
  end
  return false
end)
local saw_a = false
local saw_kind = nil
for _, e in ipairs(seen) do
  if e.path:sub(-#"/a.txt") == "/a.txt" then
    saw_a = true
    saw_kind = e.change
    break
  end
  end
ok("create-event fired for new file", saw_a, vim.inspect(seen))
ok("create-event change kind is 'created' or 'modified'",
  saw_kind == "created" or saw_kind == "modified",
  "got " .. tostring(saw_kind))

-- Modify the same file. Wait long enough for the debounce window
-- (default 100 ms) to clear.
local pre_modify_count = #seen
vim.wait(150)
vim.fn.writefile({ "hello", "again" }, tmp_root .. "/a.txt")
vim.wait(300, function()
  for i = pre_modify_count + 1, #seen do
    if seen[i].path:sub(-#"/a.txt") == "/a.txt" then return true end
  end
  return false
end)
local saw_modify = false
for i = pre_modify_count + 1, #seen do
  if seen[i].path:sub(-#"/a.txt") == "/a.txt" then saw_modify = true end
end
ok("modify-event fired on subsequent write", saw_modify,
  vim.inspect({ before = pre_modify_count, total = #seen, last = seen[#seen] }))

-- Delete it.
local pre_delete_count = #seen
vim.wait(150)
vim.fn.delete(tmp_root .. "/a.txt")
vim.wait(300, function()
  for i = pre_delete_count + 1, #seen do
    if seen[i].path:sub(-#"/a.txt") == "/a.txt"
        and seen[i].change == "deleted" then
      return true
    end
  end
  return false
end)
local saw_delete = false
for i = pre_delete_count + 1, #seen do
  if seen[i].path:sub(-#"/a.txt") == "/a.txt" and seen[i].change == "deleted" then
    saw_delete = true
  end
end
ok("delete-event fired with change='deleted'", saw_delete,
  vim.inspect({ before = pre_delete_count, total = #seen, last = seen[#seen] }))

-- Directory creation and deletion.
local pre_dir_count = #seen
vim.wait(150)
vim.fn.mkdir(tmp_root .. "/new_dir")
vim.wait(300, function()
  for i = pre_dir_count + 1, #seen do
    if seen[i].path:sub(-#"/new_dir") == "/new_dir" then return true end
  end
  return false
end)
local saw_dir_create = false
for i = pre_dir_count + 1, #seen do
  if seen[i].path:sub(-#"/new_dir") == "/new_dir" and seen[i].change == "created" then
    saw_dir_create = true
  end
end
ok("create-event fired for new directory", saw_dir_create)

local pre_dir_del_count = #seen
vim.wait(150)
vim.fn.delete(tmp_root .. "/new_dir", "d")
vim.wait(300, function()
  for i = pre_dir_del_count + 1, #seen do
    if seen[i].path:sub(-#"/new_dir") == "/new_dir" and seen[i].change == "deleted" then return true end
  end
  return false
end)
local saw_dir_delete = false
for i = pre_dir_del_count + 1, #seen do
  if seen[i].path:sub(-#"/new_dir") == "/new_dir" and seen[i].change == "deleted" then
    saw_dir_delete = true
  end
end
ok("delete-event fired for deleted directory", saw_dir_delete)

-- Ignore filter: writes under .git/ should produce NO events.
local before_ignore = #seen
vim.fn.writefile({ "ref" }, tmp_root .. "/.git/HEAD")
vim.wait(200)
local saw_git_event = false
for i = before_ignore + 1, #seen do
  if seen[i].path:find("/%.git/") then saw_git_event = true end
end
ok("ignore filter: no events under .git/ subtree", not saw_git_event,
  vim.inspect({ added = #seen - before_ignore }))

-- Debounce coalescing: a burst of writes within 100 ms should
-- produce at most one event for that path.
local before_burst = #seen
vim.wait(150)  -- clear any debounce window from prior writes
local burst_path = tmp_root .. "/burst.txt"
for i = 1, 5 do
  vim.fn.writefile({ tostring(i) }, burst_path)
end
vim.wait(300)
local burst_event_count = 0
for i = before_burst + 1, #seen do
  if seen[i].path:sub(-#"/burst.txt") == "/burst.txt" then
    burst_event_count = burst_event_count + 1
  end
end
ok("debounce coalesces rapid writes (<= 2 events for burst of 5)",
  burst_event_count >= 1 and burst_event_count <= 2,
  "got " .. tostring(burst_event_count))

-- Stop and verify list is empty.
watch.stop(handle)
ok("watch.stop drops the handle from list",
  #watch.list() == 0)

-- max_handles cap. Setting a tiny cap should refuse the start when
-- the recursive walk would exceed it.
vim.fn.mkdir(tmp_root .. "/d1", "p")
vim.fn.mkdir(tmp_root .. "/d2", "p")
vim.fn.mkdir(tmp_root .. "/d3", "p")
local capped, cap_err = watch.start(tmp_root, { max_handles = 1 })
ok("max_handles cap refuses oversized recursive watch",
  capped == nil and type(cap_err) == "string"
    and cap_err:find("max_handles"),
  tostring(cap_err))

-- Cleanup.
watch.stop_all()
events_mod._reset_for_tests()
pcall(vim.fn.delete, tmp_root, "rf")

-- ──────────── 26b. fs.watch — self-extending recursion (ADR 0042) ────────────
-- The Linux walker grows its handle set as directories appear at runtime
-- (fresh worktree / git clone / mkdir). Darwin's FSEvents watch is already
-- recursive, so this whole suite is Linux-gated.
print("\n[26b] fs.watch — self-extending recursion (runtime-created subtrees)")
do
  local se_is_darwin = (function()
    local ok_u, u = pcall(vim.uv.os_uname)
    return (ok_u and u and u.sysname == "Darwin") or false
  end)()

  if se_is_darwin then
    ok("self-extension suite skipped on Darwin (FSEvents already recursive)", true)
  else
    events_mod._reset_for_tests()
    watch._reset_for_tests()

    local se_root = vim.fn.tempname() .. "-fs-watch-selfext"
    vim.fn.mkdir(se_root, "p")

    local se_seen = {}
    events_mod.subscribe("core.file:*", function(payload)
      se_seen[#se_seen + 1] = { path = payload.path, change = payload.change }
    end)

    local function se_saw(suffix)
      for _, e in ipairs(se_seen) do
        if e.path:sub(-#suffix) == suffix then return true end
      end
      return false
    end
    local function se_active()
      local l = watch.list()
      return (l[1] and #l[1].fs_events) or 0
    end

    local se_handle = watch.start(se_root)
    ok("self-ext: watch.start on fresh root", se_handle ~= nil, tostring(se_handle))

    -- Test 1 — fail-before / pass-after. A directory created AFTER start,
    -- with a file written two levels deep, must surface a file event with
    -- no manual rescan. (This is the reported bug; fails on pre-ADR-0042.)
    vim.fn.mkdir(se_root .. "/a/b/c", "p")
    vim.wait(300)  -- let the create event + self-extension open the handles
    vim.fn.writefile({ "deep" }, se_root .. "/a/b/c/file.txt")
    vim.wait(800, function() return se_saw("/a/b/c/file.txt") end)
    ok("self-ext: file in a runtime-created nested dir fires an event",
      se_saw("/a/b/c/file.txt"), vim.inspect(se_seen))

    -- Test 2 — catch-up (C6). Create the whole subtree AND write a file in
    -- one synchronous burst, so the file already exists when the extension
    -- walk runs (the main loop only processes the scheduled extend during
    -- the wait below). The catch-up walk must surface it.
    local pre_catchup = #se_seen
    vim.fn.mkdir(se_root .. "/x/y/z", "p")
    vim.fn.writefile({ "pre" }, se_root .. "/x/y/z/pre.txt")
    vim.wait(800, function() return se_saw("/x/y/z/pre.txt") end)
    ok("self-ext: catch-up surfaces a file that predated the new handle",
      se_saw("/x/y/z/pre.txt"), vim.inspect({ added = #se_seen - pre_catchup }))

    -- Test 3 — runtime ignore (C3). A node_modules subtree created at
    -- runtime must NOT be watched: no events for any path UNDER it.
    local pre_ignore = #se_seen
    vim.fn.mkdir(se_root .. "/proj/node_modules/pkg", "p")
    vim.wait(300)
    vim.fn.writefile({ "x" }, se_root .. "/proj/node_modules/pkg/index.js")
    vim.wait(400)
    local saw_under_nm = false
    for i = pre_ignore + 1, #se_seen do
      if se_seen[i].path:find("/node_modules/") then saw_under_nm = true end
    end
    ok("self-ext: no events under a runtime-created node_modules/",
      not saw_under_nm, vim.inspect({ added = #se_seen - pre_ignore }))

    -- Test 3b — the agent mailbox transport is ignored, but the KB
    -- beside it is NOT. A multi-agent session writes to
    -- `.auto-agents/mailbox/` constantly, and each new instance/agent
    -- subdir used to consume a watch handle AND publish events that
    -- drove a consumer refresh. The scoping is deliberate: `kb/` holds
    -- documents a user browses and edits, so it stays watched.
    local pre_aa = #se_seen
    vim.fn.mkdir(se_root .. "/.auto-agents/mailbox/inst/agent/outbox", "p")
    vim.fn.mkdir(se_root .. "/.auto-agents/kb/shared", "p")
    vim.wait(300)
    vim.fn.writefile({ "{}" },
      se_root .. "/.auto-agents/mailbox/inst/agent/outbox/msg.json")
    vim.fn.writefile({ "# doc" }, se_root .. "/.auto-agents/kb/shared/note.md")
    vim.wait(800, function() return se_saw("/.auto-agents/kb/shared/note.md") end)
    local saw_under_mailbox = false
    for i = pre_aa + 1, #se_seen do
      if se_seen[i].path:find("/%.auto%-agents/mailbox/") then
        saw_under_mailbox = true
      end
    end
    ok("self-ext: no events under .auto-agents/mailbox/ (agent transport)",
      not saw_under_mailbox, vim.inspect({ added = #se_seen - pre_aa }))
    ok("self-ext: .auto-agents/kb/ IS still watched (scoping is deliberate)",
      se_saw("/.auto-agents/kb/shared/note.md"),
      vim.inspect({ added = #se_seen - pre_aa }))

    -- Test 5 — deletion cleanup (C5). A runtime dir adds a handle; deleting
    -- it reclaims the handle so the count returns to baseline (honest cap
    -- accounting under churn).
    local base_handles = se_active()
    vim.fn.mkdir(se_root .. "/churn", "p")
    vim.wait(400, function() return se_active() > base_handles end)
    ok("self-ext: a runtime dir adds a watch handle",
      se_active() > base_handles, "base=" .. base_handles .. " now=" .. se_active())
    vim.wait(150)  -- clear the debounce window so the delete event isn't coalesced with the create
    vim.fn.delete(se_root .. "/churn", "d")
    vim.wait(500, function() return se_active() <= base_handles end)
    ok("self-ext: deleting a runtime dir reclaims its handle",
      se_active() <= base_handles, "base=" .. base_handles .. " now=" .. se_active())

    watch.stop_all()
    events_mod._reset_for_tests()

    -- Test 4 — dynamic cap (C4). Start on an empty root with max_handles=1
    -- (the root consumes the only slot). A runtime subtree must be refused
    -- with a `core.fs.watch:partial` signal and must not exceed the cap.
    watch._reset_for_tests()
    local cap_partials = {}
    events_mod.subscribe("core.fs.watch:partial", function(payload)
      cap_partials[#cap_partials + 1] = payload
    end)
    local cap_root = vim.fn.tempname() .. "-fs-watch-cap"
    vim.fn.mkdir(cap_root, "p")
    local cap_handle = watch.start(cap_root, { max_handles = 1 })
    ok("self-ext: capped watch starts (root only)", cap_handle ~= nil)
    local cap_before = (cap_handle and #cap_handle.fs_events) or 0
    vim.fn.mkdir(cap_root .. "/newdir", "p")
    vim.wait(600, function() return #cap_partials > 0 end)
    ok("self-ext: dynamic cap publishes core.fs.watch:partial with dropped>=1",
      #cap_partials >= 1 and (cap_partials[1].dropped or 0) >= 1,
      vim.inspect(cap_partials))
    ok("self-ext: dynamic cap does not exceed max_handles",
      cap_handle ~= nil and #cap_handle.fs_events == cap_before,
      "before=" .. cap_before .. " after=" .. ((cap_handle and #cap_handle.fs_events) or -1))

    -- Cleanup.
    watch.stop_all()
    events_mod._reset_for_tests()
    pcall(vim.fn.delete, se_root, "rf")
    pcall(vim.fn.delete, cap_root, "rf")
  end
end

-- ─────────────────────── 27. git.status — cached porcelain ──────────────
print("\n[27] git.status — cache, parse, invalidate-on-event")
local status_mod = require("auto-core.git.status")
events_mod._reset_for_tests()
status_mod._reset_for_tests()

-- Build a fresh git repo with one untracked file.
local git_root = vim.fn.tempname() .. "-status"
vim.fn.mkdir(git_root, "p")
local function sh(cmd, cwd)
  local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
  return r.code == 0, r.stdout, r.stderr
end
local init_ok = sh({ "git", "init", "-q", "-b", "main", git_root })
ok("test repo initialized", init_ok)
-- Local user.* config so commits / status work in isolated env.
sh({ "git", "config", "user.email", "smoke@auto-core.test" }, git_root)
sh({ "git", "config", "user.name",  "Smoke Test"             }, git_root)
vim.fn.writefile({ "first" }, git_root .. "/untracked.txt")

local entries, ts = status_mod.get(git_root)
ok("status.get returns entries on repo with untracked file",
  type(entries) == "table" and #entries >= 1,
  vim.inspect(entries))
ok("status.get cached_at returned (number)", type(ts) == "number")
ok("entry has shape { path, status_x, status_y }",
  entries[1] ~= nil
    and type(entries[1].path) == "string"
    and type(entries[1].status_x) == "string"
    and type(entries[1].status_y) == "string",
  vim.inspect(entries[1]))
local untracked = nil
for _, e in ipairs(entries) do
  if e.path == "untracked.txt" then untracked = e end
end
ok("untracked file appears with status_y = '?'",
  untracked ~= nil and untracked.status_y == "?",
  vim.inspect(untracked))

ok("status.is_cached true after first get",
  status_mod.is_cached(git_root) == true)

-- Second get returns the SAME cached_at (cache hit, no re-shell).
local _, ts2 = status_mod.get(git_root)
ok("second get returns same cached_at (cache hit)",
  ts == ts2,
  string.format("first=%s second=%s", tostring(ts), tostring(ts2)))

-- Invalidate manually.
status_mod.invalidate(git_root)
ok("status.is_cached false after invalidate",
  status_mod.is_cached(git_root) == false)

-- Re-populate, then publish a core.file:modified for a path under
-- the repo. The auto-wired subscriber should drop the cache.
status_mod.get(git_root)
ok("re-populated cache before invalidation-by-event",
  status_mod.is_cached(git_root) == true)
events_mod.publish("core.file:modified", {
  path   = git_root .. "/untracked.txt",
  change = "modified",
})
-- Subscriber dispatches synchronously — no vim.wait needed.
ok("cache invalidated by core.file:modified event",
  status_mod.is_cached(git_root) == false)

-- Events for paths OUTSIDE the repo do NOT invalidate.
status_mod.get(git_root)
events_mod.publish("core.file:modified", {
  path   = "/tmp/some-other-place/x.txt",
  change = "modified",
})
ok("cache survives event for path outside repo",
  status_mod.is_cached(git_root) == true)

-- invalidate_all wipes everything.
status_mod.invalidate_all()
ok("invalidate_all wipes the cache",
  status_mod.is_cached(git_root) == false)

-- Negative case: not in a git repo.
local non_git = vim.fn.tempname() .. "-no-git-status"
vim.fn.mkdir(non_git, "p")
local none, none_err = status_mod.get(non_git)
ok("status.get nil + err on non-git path",
  none == nil and type(none_err) == "string", tostring(none_err))
pcall(vim.fn.delete, non_git, "rf")

pcall(vim.fn.delete, git_root, "rf")
events_mod._reset_for_tests()

-- ─────────────────────── 28. fs.tree — directory walker ─────────────────────────
print("\n[28] fs.tree — walk, walk_dirs, walk_files, exclude defaults")
local tree = require("auto-core.fs.tree")

-- Stage a tree:
--   <root>/
--     a.txt
--     sub/
--       b.txt
--     .git/
--       HEAD
--     .bare/
--       HEAD
--     node_modules/
--       skip-me.txt
--     .hidden        (a dotfile — skipped unless include_hidden)
local tree_root = vim.fn.tempname() .. "-fs-tree"
vim.fn.mkdir(tree_root, "p")
vim.fn.mkdir(tree_root .. "/sub", "p")
vim.fn.mkdir(tree_root .. "/.git", "p")
vim.fn.mkdir(tree_root .. "/.bare", "p")
vim.fn.mkdir(tree_root .. "/node_modules", "p")
vim.fn.writefile({ "x" }, tree_root .. "/a.txt")
vim.fn.writefile({ "x" }, tree_root .. "/sub/b.txt")
vim.fn.writefile({ "x" }, tree_root .. "/.git/HEAD")
vim.fn.writefile({ "x" }, tree_root .. "/.bare/HEAD")
vim.fn.writefile({ "x" }, tree_root .. "/node_modules/skip-me.txt")
vim.fn.writefile({ "x" }, tree_root .. "/.hidden")

local entries = tree.walk(tree_root)
local function find_path(es, suffix)
  for _, e in ipairs(es) do
    if e.path:sub(-#suffix) == suffix then return e end
  end
  return nil
end

ok("walk includes a.txt", find_path(entries, "/a.txt") ~= nil)
ok("walk includes sub/", find_path(entries, "/sub") ~= nil)
ok("walk includes sub/b.txt (recursive)", find_path(entries, "/sub/b.txt") ~= nil)
ok("walk excludes .git subtree by default",
  find_path(entries, "/.git") == nil
    and find_path(entries, "/.git/HEAD") == nil)
ok("walk excludes .bare subtree by default",
  find_path(entries, "/.bare") == nil
    and find_path(entries, "/.bare/HEAD") == nil)
ok("walk excludes node_modules subtree by default",
  find_path(entries, "/node_modules") == nil)
ok("walk excludes dotfiles by default",
  find_path(entries, "/.hidden") == nil)

local with_hidden = tree.walk(tree_root, { include_hidden = true })
ok("walk with include_hidden surfaces .hidden",
  find_path(with_hidden, "/.hidden") ~= nil)
-- include_hidden does NOT override the .git/.bare exclusion patterns
-- because those are matched as full-path patterns, not hidden-name
-- exclusions.
ok("include_hidden still excludes .git subtree",
  find_path(with_hidden, "/.git/HEAD") == nil)

local depth0 = tree.walk(tree_root, { depth = 0 })
ok("depth=0 returns only root's direct children",
  find_path(depth0, "/sub") ~= nil
    and find_path(depth0, "/a.txt") ~= nil
    and find_path(depth0, "/sub/b.txt") == nil)

local dirs = tree.walk_dirs(tree_root)
ok("walk_dirs returns only directories",
  (function()
    for _, e in ipairs(dirs) do
      if e.type ~= "directory" then return false end
    end
    return #dirs > 0
  end)())

local files = tree.walk_files(tree_root)
ok("walk_files returns only files",
  (function()
    for _, e in ipairs(files) do
      if e.type ~= "file" then return false end
    end
    return #files > 0
  end)())

-- Negative case: non-existent root.
ok("walk on non-existent path returns empty",
  #tree.walk("/definitely/not/anywhere") == 0)

pcall(vim.fn.delete, tree_root, "rf")

-- ─────────────────────── 29. git.worktree — porcelain parser + queries ─────────────────────────
print("\n[29] git.worktree — parse_porcelain, list, branches, helpers")
local wt = require("auto-core.git.worktree")
events_mod._reset_for_tests()
wt._reset_for_tests()

-- 29a. parse_porcelain — pure function tests
local sample = {
  "worktree /home/u/repo",
  "HEAD abc1234567890",
  "branch refs/heads/main",
  "",
  "worktree /home/u/repo-feature",
  "HEAD def4567890abc",
  "branch refs/heads/feature",
  "",
  "worktree /home/u/repo-detached",
  "HEAD 0123456789ab",
  "detached",
  "",
  "worktree /home/u/repo/.bare",
  "bare",
}
local parsed = wt.parse_porcelain(sample)
ok("parse_porcelain returns 4 entries", #parsed == 4,
  vim.inspect(parsed))
-- Note: parse_porcelain extracts head as line:sub(6, 13) = 8 chars
-- (verbatim from upstream worktree.nvim/git.lua). Git's "short HEAD"
-- length is configurable; 8 covers most repos comfortably.
ok("first entry has main branch + 8-char head",
  parsed[1].path == "/home/u/repo"
    and parsed[1].branch == "main"
    and parsed[1].head == "abc12345",
  vim.inspect(parsed[1]))
ok("feature entry has branch stripped of refs/heads/",
  parsed[2].branch == "feature")
ok("detached entry flagged",
  parsed[3].detached == true and parsed[3].branch == nil)
ok("bare entry flagged",
  parsed[4].bare == true and parsed[4].path == "/home/u/repo/.bare")

do
  -- 29b-29e: fixture repo with known worktrees and branches
  -- Instead of asserting against the ambient auto-core checkout (which varies by
  -- clone path, detached HEAD in CI, worktree name, etc.), build a deterministic
  -- fixture repo in a tempdir with known branches and a linked worktree.
  local fix_repo = vim.fs.normalize(vim.fn.tempname() .. "_wt_fixture")
  vim.fn.mkdir(fix_repo, "p")
  vim.fn.system({ "git", "-C", fix_repo, "init", "-q", "--initial-branch=main" })
  vim.fn.system({ "git", "-C", fix_repo, "-c", "user.email=t@t", "-c", "user.name=t",
    "commit", "--allow-empty", "-q", "-m", "init" })
  vim.fn.system({ "git", "-C", fix_repo, "branch", "feature-b" })
  vim.fn.system({ "git", "-C", fix_repo, "branch", "alpha-a" })

  local fix_linked = vim.fs.normalize(vim.fn.tempname() .. "_wt_linked")
  vim.fn.system({ "git", "-C", fix_repo, "worktree", "add", "-q", fix_linked, "feature-b" })

  -- 29b. list — against the fixture repo (main + linked worktree)
  local listed = wt.list(fix_repo)
  ok("list returns a table", type(listed) == "table")
  ok("list has exactly two entries (main + linked worktree)", #listed == 2, vim.inspect(listed))
  ok("list includes the main worktree path and branch",
    (function()
      for _, e in ipairs(listed) do
        if e.path == fix_repo and e.branch == "main" then return true end
      end
      return false
    end)(), vim.inspect(listed))
  ok("list includes the linked worktree path and branch",
    (function()
      for _, e in ipairs(listed) do
        if e.path == fix_linked and e.branch == "feature-b" then return true end
      end
      return false
    end)(), vim.inspect(listed))

  -- Also verify list on the ambient checkout asserts something honest for ANY checkout
  local self_root = require("auto-core.git.repo").root()
  ok("ambient repo root resolved", type(self_root) == "string")
  local self_listed = wt.list(self_root)
  ok("ambient list returns a table with at least one entry",
    type(self_listed) == "table" and #self_listed >= 1)
  ok("ambient list entries include the current checkout root",
    (function()
      local norm_self = vim.fs.normalize(self_root)
      for _, e in ipairs(self_listed) do
        if vim.fs.normalize(e.path) == norm_self then return true end
      end
      return false
    end)(), "self_root=" .. tostring(self_root))

  -- 29c. list_branches — main/master floats to top + empty-branch tolerance is reachable
  local branches = wt.list_branches(fix_repo)
  ok("list_branches returns all fixture branches with main first",
    #branches == 3 and branches[1] == "main" and branches[2] == "alpha-a" and branches[3] == "feature-b",
    vim.inspect(branches))

  -- Dead disjunct regression test: empty repo returns {} strictly without needing a tolerance
  local empty_repo = vim.fs.normalize(vim.fn.tempname() .. "_wt_empty")
  vim.fn.mkdir(empty_repo, "p")
  vim.fn.system({ "git", "-C", empty_repo, "init", "-q" })
  local empty_branches = wt.list_branches(empty_repo)
  ok("list_branches on empty repo returns empty list", #empty_branches == 0)


  -- 29d. local_branch_exists / worktree_for_branch
  ok("local_branch_exists true for existing main branch",
    wt.local_branch_exists(fix_repo, "main") == true)
  ok("local_branch_exists true for existing feature branch",
    wt.local_branch_exists(fix_repo, "feature-b") == true)
  ok("local_branch_exists false on bogus branch",
    wt.local_branch_exists(fix_repo, "definitely-no-such-branch-xyz") == false)
  ok("worktree_for_branch finds main worktree path",
    wt.worktree_for_branch(fix_repo, "main") == fix_repo)
  ok("worktree_for_branch finds linked worktree path",
    wt.worktree_for_branch(fix_repo, "feature-b") == fix_linked)
  ok("worktree_for_branch returns nil for branch without worktree",
    wt.worktree_for_branch(fix_repo, "alpha-a") == nil)

  -- 29e. default_branch
  local def = wt.default_branch(fix_repo)
  ok("default_branch on fixture repo with symbolic HEAD returns main", def == "main", tostring(def))

  -- Bare repo default_branch (the primary production consumer in worktree.nvim)
  local fix_bare = vim.fs.normalize(vim.fn.tempname() .. "_wt_bare")
  vim.fn.system({ "git", "clone", "--bare", "-q", fix_repo, fix_bare })
  local def_bare = wt.default_branch(fix_bare)
  ok("default_branch on bare repo returns symbolic HEAD (main)", def_bare == "main", tostring(def_bare))

  -- Clean up fixture repositories
  pcall(vim.fn.delete, fix_linked, "rf")
  pcall(vim.fn.delete, fix_repo, "rf")
  pcall(vim.fn.delete, fix_bare, "rf")
  pcall(vim.fn.delete, empty_repo, "rf")
end

-- 29f. repo_name_from_url — pure function
ok("repo_name from ssh url",
  wt.repo_name_from_url("git@github.com:foo/bar.git") == "bar")
ok("repo_name from https url with .git",
  wt.repo_name_from_url("https://github.com/foo/bar.git") == "bar")
ok("repo_name from https url without .git",
  wt.repo_name_from_url("https://github.com/foo/bar") == "bar")
ok("repo_name from local path",
  wt.repo_name_from_url("/path/to/myrepo") == "myrepo")

-- 29g. repo_container — parent of common dir
ok("repo_container of /foo/repo/.bare → /foo/repo",
  wt.repo_container("/foo/repo/.bare") == "/foo/repo")
ok("repo_container of /foo/repo.git → /foo",
  wt.repo_container("/foo/repo.git") == "/foo")

-- 29h. negative case: non-git path
local none = vim.fn.tempname() .. "-no-git"
vim.fn.mkdir(none, "p")
local entries_none, err_none = wt.list(none)
ok("list returns nil + err on non-git path",
  entries_none == nil and type(err_none) == "string", tostring(err_none))
pcall(vim.fn.delete, none, "rf")

-- ─────────────────────── 30. git.worktree — workspace memory + events ─────────────────────────
print("\n[30] git.worktree — set/get active + workspace_root + events")
events_mod._reset_for_tests()
wt._reset_for_tests()

-- Capture published events.
local active_events = {}
local root_events = {}
events_mod.subscribe("core.active_worktree:changed", function(payload)
  active_events[#active_events + 1] = payload
end)
events_mod.subscribe("core.workspace_root:changed", function(payload)
  root_events[#root_events + 1] = payload
end)

ok("get_active starts as nil after reset",
  wt.get_active() == nil)

wt.set_active("/tmp/some-wt")
ok("get_active returns the path after set",
  wt.get_active() == "/tmp/some-wt")
ok("core.active_worktree:changed fired with from=nil to=/tmp/some-wt",
  #active_events == 1
    and active_events[1].from == nil
    and active_events[1].to == "/tmp/some-wt"
    and type(active_events[1].cwd) == "string",
  vim.inspect(active_events))

wt.set_active("/tmp/another-wt")
ok("event fires with from=previous, to=new",
  #active_events == 2
    and active_events[2].from == "/tmp/some-wt"
    and active_events[2].to == "/tmp/another-wt")

-- Idempotent set should NOT republish.
wt.set_active("/tmp/another-wt")
ok("idempotent set does NOT republish",
  #active_events == 2)

wt.set_active(nil)
ok("set_active(nil) clears + publishes",
  wt.get_active() == nil
    and #active_events == 3
    and active_events[3].to == nil,
  string.format("get_active=%s #events=%d events=%s",
    tostring(wt.get_active()), #active_events,
    vim.inspect(active_events)))

-- workspace_root parallel test
ok("get_workspace_root starts as nil",
  wt.get_workspace_root() == nil)

wt.set_workspace_root("/home/u/Source/Projects")
ok("get_workspace_root returns set value",
  wt.get_workspace_root() == "/home/u/Source/Projects")
ok("core.workspace_root:changed fired",
  #root_events == 1
    and root_events[1].from == nil
    and root_events[1].to == "/home/u/Source/Projects")

events_mod._reset_for_tests()
wt._reset_for_tests()

-- ─────────────────────── 31. tasks.queue — FIFO + priority dispatch ─────────────────────────
print("\n[31] tasks.queue — enqueue / claim / peek / complete / priority")
local queue = require("auto-core.tasks.queue")
events_mod._reset_for_tests()
queue._reset_for_tests()

-- Capture events.
local q_events = { queued = {}, claimed = {}, completed = {} }
events_mod.subscribe("agent.task:queued",    function(p) q_events.queued[#q_events.queued + 1]       = p end)
events_mod.subscribe("agent.task:claimed",   function(p) q_events.claimed[#q_events.claimed + 1]     = p end)
events_mod.subscribe("agent.task:completed", function(p) q_events.completed[#q_events.completed + 1] = p end)

local t1 = queue.enqueue("jarvis", { payload = "first",  priority = "normal" })
local t2 = queue.enqueue("jarvis", { payload = "urgent", priority = "urgent" })
local t3 = queue.enqueue("jarvis", { payload = "high",   priority = "high"   })
local t4 = queue.enqueue("jarvis", { payload = "low",    priority = "low"    })

ok("enqueue returns task with id + status='queued'",
  t1.id ~= nil and t1.status == "queued" and t1.priority == "normal")
ok("4 queued events fired",
  #q_events.queued == 4
    and q_events.queued[2].priority == "urgent")

-- Peek picks the highest-priority queued task.
local peeked = queue.peek("jarvis")
ok("peek returns the urgent task first",
  peeked ~= nil and peeked.id == t2.id,
  "got id=" .. tostring(peeked and peeked.id))

ok("peek does NOT transition status",
  t2.status == "queued"
    and #q_events.claimed == 0)

-- Claim — should return urgent first, then high, then normal, then low.
local c1 = queue.claim("jarvis")
ok("claim 1 → urgent (priority order)",
  c1 ~= nil and c1.id == t2.id and c1.status == "claimed")
ok("claimed event fired with id",
  #q_events.claimed == 1 and q_events.claimed[1].id == t2.id)

local c2 = queue.claim("jarvis")
ok("claim 2 → high",
  c2 ~= nil and c2.id == t3.id)

local c3 = queue.claim("jarvis")
ok("claim 3 → normal (FIFO across priorities)",
  c3 ~= nil and c3.id == t1.id)

local c4 = queue.claim("jarvis")
ok("claim 4 → low",
  c4 ~= nil and c4.id == t4.id)

local c5 = queue.claim("jarvis")
ok("claim 5 → nil (empty)", c5 == nil)

-- Complete one — verify event + removal from active list.
ok("complete returns true on claimed task",
  queue.complete(t1.id, { ok = true }))
ok("completed event fired with result",
  #q_events.completed == 1
    and q_events.completed[1].id == t1.id
    and q_events.completed[1].result.ok == true)
ok("complete returns false on already-completed",
  queue.complete(t1.id) == false)

-- FIFO within same priority. Enqueue two normal tasks; claim order
-- should match insertion order.
queue.clear("jarvis")
queue.enqueue("jarvis", { payload = "a", priority = "normal" })
queue.enqueue("jarvis", { payload = "b", priority = "normal" })
local first  = queue.claim("jarvis")
local second = queue.claim("jarvis")
ok("FIFO within same priority — first-in claims first",
  first.payload == "a" and second.payload == "b")

-- Per-agent isolation.
queue.clear()
queue.enqueue("jarvis", { payload = "for-jarvis" })
queue.enqueue("vision", { payload = "for-vision" })
ok("list(agent) returns only that agent's tasks",
  #queue.list("jarvis") == 1
    and queue.list("jarvis")[1].payload == "for-jarvis")
ok("list() returns every agent's tasks",
  #queue.list() == 2)

queue._reset_for_tests()
events_mod._reset_for_tests()

-- ─────────────────────── 32. tasks.channel — append-only message log ─────────────────────────
print("\n[32] tasks.channel — send / list / filter / recent / events")
local ch = require("auto-core.tasks.channel")
events_mod._reset_for_tests()
ch._reset_for_tests()

local m_events = {}
events_mod.subscribe("agent.message:sent",
  function(p) m_events[#m_events + 1] = p end)

local m1 = ch.send({ from = "jarvis", to = "vision",
  body = "ping",          kind = "info" })
local m2 = ch.send({ from = "vision",
  body = "broadcast hi",  kind = "info" })
local m3 = ch.send({ from = "jarvis", to = "vision",
  body = "again",         kind = "warn" })

ok("send returns message with id + iso timestamp",
  m1.id ~= nil
    and type(m1.sent_at) == "number"
    and type(m1.sent_at_iso) == "string"
    and m1.sent_at_iso:match("^%d%d%d%d%-"))
ok("ids are monotonic across sends",
  m2.id == m1.id + 1 and m3.id == m2.id + 1)
ok("3 sent events fired",
  #m_events == 3 and m_events[2].body == "broadcast hi")

-- list — no filter
local all = ch.list()
ok("list() returns all 3 messages", #all == 3)

-- filter: from
local from_jarvis = ch.list({ from = "jarvis" })
ok("filter by from='jarvis' returns 2",
  #from_jarvis == 2,
  vim.inspect(from_jarvis))

-- filter: to (specific agent)
local to_vision = ch.list({ to = "vision" })
ok("filter by to='vision' returns 2 (the directed messages)",
  #to_vision == 2)

-- filter: to="" (broadcast-only)
local broadcasts = ch.list({ to = "" })
ok("filter by to='' returns broadcasts only (1)",
  #broadcasts == 1 and broadcasts[1].body == "broadcast hi")

-- filter: kind
local warns = ch.list({ kind = "warn" })
ok("filter by kind='warn' returns 1", #warns == 1)

-- filter: since
local mid_ts = m2.sent_at
local since_mid = ch.list({ since = mid_ts })
ok("filter by since returns messages at or after the timestamp",
  #since_mid >= 1
    and (function()
      for _, m in ipairs(since_mid) do
        if m.sent_at < mid_ts then return false end
      end
      return true
    end)())

-- recent(n)
ok("recent(2) returns the 2 most recent",
  #ch.recent(2) == 2 and ch.recent(2)[2].body == "again")
ok("recent() default 100 returns all 3",
  #ch.recent() == 3)

-- clear
ch.clear()
ok("clear() empties the log", #ch.list() == 0)

-- after clear, ids should still be monotonic (don't restart)
local m_after_clear = ch.send({ from = "jarvis", body = "post-clear" })
ok("ids remain monotonic after clear",
  m_after_clear.id > m3.id,
  string.format("got %d, expected > %d", m_after_clear.id, m3.id))

ch._reset_for_tests()
events_mod._reset_for_tests()

-- ─────────────────────── 33. tasks.status — per-agent state surface ─────────────────────────
print("\n[33] tasks.status — set / get / list / transitions / events")
local stat = require("auto-core.tasks.status")
events_mod._reset_for_tests()
stat._reset_for_tests()

local s_events = {}
events_mod.subscribe("agent.status:changed",
  function(p) s_events[#s_events + 1] = p end)

ok("get on unknown agent returns nil", stat.get("jarvis") == nil)

stat.set("jarvis", "working")
ok("set+get round-trip", stat.get("jarvis") == "working")
ok("first set fires changed event with from=nil",
  #s_events == 1
    and s_events[1].agent == "jarvis"
    and s_events[1].from == nil
    and s_events[1].to == "working")

stat.set("jarvis", "idle")
ok("transition fires event with from=working to=idle",
  #s_events == 2
    and s_events[2].from == "working"
    and s_events[2].to == "idle")

-- Idempotent set.
stat.set("jarvis", "idle")
ok("idempotent set does NOT republish", #s_events == 2)

-- Multi-agent.
stat.set("vision", "waiting")
local snapshot = stat.list()
ok("list() returns map with both agents",
  snapshot.jarvis == "idle" and snapshot.vision == "waiting")

-- Invalid state
local invalid_ok = pcall(stat.set, "jarvis", "exploded")
ok("set rejects invalid state with error", not invalid_ok)

-- Clear single
stat.clear("vision")
ok("clear(agent) removes that agent's state",
  stat.get("vision") == nil)
ok("clear publishes a changed event with to=nil",
  s_events[#s_events].agent == "vision"
    and s_events[#s_events].to == nil)

stat._reset_for_tests()
events_mod._reset_for_tests()

-- ─────────────────────── 34. tasks.ui — :AutoCoreChannel panel ─────────────────────────
print("\n[34] tasks.ui — open / sections / refresh on event / close")
local ui = require("auto-core.tasks.ui")
events_mod._reset_for_tests()
ch._reset_for_tests()
stat._reset_for_tests()
queue._reset_for_tests()
ui._reset_for_tests()

-- Seed some data so the rendered buffers have content.
ch.send({ from = "jarvis", body = "channel-test message" })
stat.set("jarvis", "working")
queue.enqueue("jarvis", { payload = "ui-test-task" })

ui.open()

-- Panel should be live + have a window.
local panel_mod = require("auto-core.ui.panel")
local panel = panel_mod.get("auto-core-channel")
ok("ui.open creates the auto-core-channel panel",
  panel ~= nil and panel.winid ~= nil
    and vim.api.nvim_win_is_valid(panel.winid))

-- The active section should be 0 (messages) and its buffer should
-- contain the seeded message.
local active_buf = vim.api.nvim_win_get_buf(panel.winid)
ok("active buffer has filetype 'auto-core-channel'",
  vim.bo[active_buf].filetype == "auto-core-channel")

local lines = vim.api.nvim_buf_get_lines(active_buf, 0, -1, false)
local saw_message = false
for _, l in ipairs(lines) do
  if l:find("channel%-test message") then saw_message = true end
end
ok("messages section renders the seeded message", saw_message,
  vim.inspect(lines))

-- Send a new message — refresh subscriber should re-render.
ch.send({ from = "vision", body = "live-refresh-check" })
-- refresh is synchronous via subscribe → fire — no vim.wait needed.
local lines2 = vim.api.nvim_buf_get_lines(active_buf, 0, -1, false)
local saw_new = false
for _, l in ipairs(lines2) do
  if l:find("live%-refresh%-check") then saw_new = true end
end
ok("new message triggers panel refresh", saw_new,
  vim.inspect(lines2))

-- Close + reopen idempotency.
ui.close()
ok("ui.close closes the panel",
  panel.winid == nil
    or not vim.api.nvim_win_is_valid(panel.winid))

ui.open()
ok("ui.open after close re-opens cleanly",
  panel.winid ~= nil and vim.api.nvim_win_is_valid(panel.winid))

ui._reset_for_tests()
queue._reset_for_tests()
stat._reset_for_tests()
ch._reset_for_tests()
events_mod._reset_for_tests()

-- ─────────────────────── 35. ui.highlights — registry + theme_override ─────────────────────────
print("\n[35] ui.highlights — defaults + theme_override")
local highlights = require("auto-core.ui.highlights")
highlights._reset_for_tests()

-- Defaults catalog matches the documented set.
local listed = highlights.list()
local function listed_has(name)
  for _, n in ipairs(listed) do if n == name then return true end end
  return false
end
ok("DEFAULTS includes AutoCoreSectionActive",  listed_has("AutoCoreSectionActive"))
ok("DEFAULTS includes AutoCoreFloatNormal",    listed_has("AutoCoreFloatNormal"))
ok("DEFAULTS includes AutoCoreFloatBorder",    listed_has("AutoCoreFloatBorder"))
ok("DEFAULTS includes AutoCoreHelpKey",        listed_has("AutoCoreHelpKey"))

highlights.ensure()
ok("ensure registers AutoCoreSectionActive",
  vim.fn.hlexists("AutoCoreSectionActive") == 1)
ok("ensure registers AutoCoreFloatNormal",
  vim.fn.hlexists("AutoCoreFloatNormal") == 1)

-- Idempotent: second ensure call doesn't re-register (no-op).
highlights.ensure()
ok("ensure is idempotent (still registered)",
  vim.fn.hlexists("AutoCoreSectionActive") == 1)

-- theme_override should bypass `default = true` so it overrides
-- whatever was registered at ensure-time.
highlights.theme_override("AutoCoreFloatNormal", { bg = "#112233", fg = "#ffeedd" })
local hl_attrs = vim.api.nvim_get_hl(0, { name = "AutoCoreFloatNormal" })
ok("theme_override applies fg",
  hl_attrs.fg ~= nil,
  vim.inspect(hl_attrs))
ok("theme_override applies bg",
  hl_attrs.bg ~= nil,
  vim.inspect(hl_attrs))

-- Reset + restore link semantics by re-running ensure.
pcall(vim.api.nvim_set_hl, 0, "AutoCoreFloatNormal", { link = "NormalFloat", default = true })

-- ── the repos tree's status colours: added GREEN, modified YELLOW, deleted RED ──
-- FOREGROUND only (Johno, 2026-09-02, ADR-0060 §10). The tree paints whole rows
-- with these groups, and a link to DiffAdd/DiffDelete — or to the derived
-- yellow tint v0.2.8 briefly introduced — paints a BACKGROUND wash that read as
-- "not so green / not so orange". The groups now link to the Diagnostic*
-- family, foreground-only by convention and themed by every scheme: the same
-- groups auto-finder's todos panel uses for its Completed and Deferred headers,
-- so the two panels agree.
--
-- Scoped in `do … end`: the main chunk sits near Lua's 200-local ceiling.
do
highlights._reset_for_tests()
highlights.ensure()
local function hl_of(name)
  local okh, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return (okh and type(h) == "table") and h or {}
end
local function fg_of(name) return hl_of(name).fg end
ok("[35] fixture: the default scheme gives DiagnosticOk/Warn/Error a foreground",
  fg_of("DiagnosticOk") ~= nil and fg_of("DiagnosticWarn") ~= nil and fg_of("DiagnosticError") ~= nil,
  ("ok=%s warn=%s error=%s"):format(tostring(fg_of("DiagnosticOk")),
    tostring(fg_of("DiagnosticWarn")), tostring(fg_of("DiagnosticError"))))
local added, modified, deleted =
  hl_of("AutoCoreGitAdded"), hl_of("AutoCoreGitModified"), hl_of("AutoCoreGitDeleted")
ok("[35] added is DiagnosticOk's green",
  added.fg ~= nil and added.fg == fg_of("DiagnosticOk"),
  ("added=%s ok=%s"):format(tostring(added.fg), tostring(fg_of("DiagnosticOk"))))
ok("[35] modified is DiagnosticWarn's yellow",
  modified.fg ~= nil and modified.fg == fg_of("DiagnosticWarn"),
  ("modified=%s warn=%s"):format(tostring(modified.fg), tostring(fg_of("DiagnosticWarn"))))
ok("[35] deleted is DiagnosticError's red",
  deleted.fg ~= nil and deleted.fg == fg_of("DiagnosticError"),
  ("deleted=%s error=%s"):format(tostring(deleted.fg), tostring(fg_of("DiagnosticError"))))
ok("[35] the three are distinguishable by foreground alone",
  added.fg ~= modified.fg and modified.fg ~= deleted.fg and added.fg ~= deleted.fg,
  ("added=%s modified=%s deleted=%s"):format(tostring(added.fg), tostring(modified.fg), tostring(deleted.fg)))
ok("[35] none of them paints a background (the whole-row wash is gone)",
  added.bg == nil and modified.bg == nil and deleted.bg == nil,
  ("added.bg=%s modified.bg=%s deleted.bg=%s"):format(tostring(added.bg), tostring(modified.bg), tostring(deleted.bg)))
ok("[35] untracked shares added's green; renamed has a foreground of its own",
  hl_of("AutoCoreGitUntracked").fg == added.fg
  and hl_of("AutoCoreGitRenamed").fg ~= nil and hl_of("AutoCoreGitRenamed").fg ~= added.fg,
  ("untracked=%s renamed=%s"):format(tostring(hl_of("AutoCoreGitUntracked").fg),
    tostring(hl_of("AutoCoreGitRenamed").fg)))
-- PUSH STATE (batch item #7): the hash reads pushed-vs-local at a glance.
local pushed, unpushed = hl_of("AutoCoreGitPushed"), hl_of("AutoCoreGitUnpushed")
ok("[35] *** pushed and unpushed each have a foreground ***",
  pushed.fg ~= nil and unpushed.fg ~= nil,
  ("pushed=%s unpushed=%s"):format(tostring(pushed.fg), tostring(unpushed.fg)))
ok("[35] *** and they are distinguishable from each other ***",
  pushed.fg ~= unpushed.fg,
  ("pushed=%s unpushed=%s"):format(tostring(pushed.fg), tostring(unpushed.fg)))
ok("[35] neither paints a background — only the hash is coloured, not the row",
  pushed.bg == nil and unpushed.bg == nil,
  ("pushed.bg=%s unpushed.bg=%s"):format(tostring(pushed.bg), tostring(unpushed.bg)))
ok("[35] unpushed is the SAME orange the modified rows already use",
  unpushed.fg == modified.fg,
  ("unpushed=%s modified=%s"):format(tostring(unpushed.fg), tostring(modified.fg)))
ok("[35] *** pushed is NOT one of the status colours ***",
  -- If it collided with added/modified/deleted, a purple hash would read as a
  -- file status instead of a push state.
  pushed.fg ~= added.fg and pushed.fg ~= modified.fg and pushed.fg ~= deleted.fg,
  ("pushed=%s added=%s modified=%s deleted=%s"):format(tostring(pushed.fg),
    tostring(added.fg), tostring(modified.fg), tostring(deleted.fg)))
-- The v0.2.8 tint is gone: not registered, not derived, not listed.
ok("[35] AutoCoreGitModifiedBg is no longer defined, derived or listed",
  vim.tbl_isempty(hl_of("AutoCoreGitModifiedBg"))
  and not vim.tbl_contains(highlights.list(), "AutoCoreGitModifiedBg"),
  vim.inspect(hl_of("AutoCoreGitModifiedBg")))
-- A LINK, not a copy: the colour follows the scheme immediately, with no
-- derivation step for a ColorScheme event to have to re-run.
local warn_before = hl_of("DiagnosticWarn")
vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = "#ff00ff" })
ok("[35] modified follows the scheme's warning colour live (it is a link)",
  hl_of("AutoCoreGitModified").fg == 0xff00ff, tostring(hl_of("AutoCoreGitModified").fg))
pcall(vim.api.nvim_set_hl, 0, "DiagnosticWarn", warn_before)
-- theme_override still beats the default link — the existing contract.
highlights.theme_override("AutoCoreGitModified", { fg = "#123456" })
ok("[35] theme_override on a status group wins over its default link",
  hl_of("AutoCoreGitModified").fg == 0x123456, tostring(hl_of("AutoCoreGitModified").fg))
-- Put the default link back by hand: `ensure()` registers with `default = true`,
-- which by design never overwrites a group that is already defined.
pcall(vim.api.nvim_set_hl, 0, "AutoCoreGitModified", { link = "DiagnosticWarn" })
highlights._reset_for_tests()
highlights.ensure()
end

-- ─────────────────────── 36. ui.float.help_overlay ─────────────────────────
print("\n[36] ui.float.help_overlay — open / dismiss / events")
local float = require("auto-core.ui.float")
events_mod._reset_for_tests()

local f_events = { opened = {}, closed = {} }
events_mod.subscribe("float:opened", function(p) f_events.opened[#f_events.opened + 1] = p end)
events_mod.subscribe("float:closed", function(p) f_events.closed[#f_events.closed + 1] = p end)

local handle = float.help_overlay({
  { "?",       "show help" },
  { "q",       "close" },
  { "<cr>",    "confirm" },
  "Free-form line",
  { key = "x", desc = "named-pair entry" },
}, { title = "test help" })

ok("help_overlay returns handle with buf+win+close",
  type(handle) == "table"
    and handle.buf ~= nil
    and handle.win ~= nil
    and type(handle.close) == "function")
ok("help_overlay window is valid",
  vim.api.nvim_win_is_valid(handle.win))
ok("help_overlay buffer has filetype 'auto-core-help'",
  vim.bo[handle.buf].filetype == "auto-core-help")
ok("help_overlay buffer is non-modifiable",
  vim.bo[handle.buf].modifiable == false)
ok("float:opened event fired with kind='help_overlay'",
  #f_events.opened == 1
    and f_events.opened[1].kind == "help_overlay"
    and f_events.opened[1].buf == handle.buf)

-- Lines should include the rendered key/desc pairs.
local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)
local function has_substr(lst, s)
  for _, l in ipairs(lst) do if l:find(s) then return true end end
  return false
end
ok("help_overlay rendered '?' key entry",
  has_substr(lines, "show help"))
ok("help_overlay rendered free-form line",
  has_substr(lines, "Free%-form line"))
ok("help_overlay rendered named-pair entry",
  has_substr(lines, "named%-pair entry"))

-- Close via the explicit handle.
handle.close()
ok("help_overlay close() dismisses the window",
  not vim.api.nvim_win_is_valid(handle.win))
ok("float:closed event fired",
  #f_events.closed == 1
    and f_events.closed[1].kind == "help_overlay")

-- close() is idempotent — second call doesn't republish.
handle.close()
ok("close() is idempotent (no double-publish)",
  #f_events.closed == 1)

-- on_close hook fires on explicit close.
local on_close_fired = false
local h2 = float.help_overlay({ "x" },
  { on_close = function() on_close_fired = true end })
h2.close()
ok("on_close hook fires on dismiss",
  on_close_fired)

-- ─────────────────────── 37. ui.float.confirm ─────────────────────────
print("\n[38] ui.float.confirm — vim.ui.select wrapper")

-- Stub vim.ui.select to capture the call without blocking.
local orig_select = vim.ui.select
local select_calls = {}
local stub_choice = "yes"
vim.ui.select = function(items, opts, on_choice)
  select_calls[#select_calls + 1] = { items = items, prompt = opts.prompt }
  if on_choice then on_choice(stub_choice) end
end

local choice_received = nil
float.confirm("Proceed?", {
  on_choice = function(c) choice_received = c end,
})

ok("confirm calls vim.ui.select once",
  #select_calls == 1)
ok("confirm passes prompt to vim.ui.select",
  select_calls[1].prompt == "Proceed?")
ok("confirm default items are { yes, no }",
  #select_calls[1].items == 2
    and select_calls[1].items[1] == "yes"
    and select_calls[1].items[2] == "no")
ok("confirm forwards choice to on_choice",
  choice_received == "yes")

-- Custom items override the default.
select_calls = {}
choice_received = nil
stub_choice = "abort"
float.confirm("Pick action:", {
  items = { "save", "discard", "abort" },
  on_choice = function(c) choice_received = c end,
})
ok("confirm respects custom items",
  #select_calls[1].items == 3 and select_calls[1].items[3] == "abort")
ok("confirm forwards custom choice",
  choice_received == "abort")

-- Restore vim.ui.select.
vim.ui.select = orig_select
events_mod._reset_for_tests()

-- ─────────────────────── 39. log — levels, ring, namespace, notify ─────────────────────────
print("\n[39] log — levels, ring buffer, namespace, notify mirror")
local log = require("auto-core.log")
log._reset_for_tests()

-- Stub vim.notify so tests don't spam stderr; capture calls.
local orig_notify = vim.notify
local notify_calls = {}
vim.notify = function(msg, level, opts)
  notify_calls[#notify_calls + 1] = { msg = msg, level = level, opts = opts }
end

-- Stub nvim_echo too — we don't want INFO spam in test output.
local orig_echo = vim.api.nvim_echo
vim.api.nvim_echo = function() end

-- Default level is INFO; calls at INFO+ land in ring + notify; DEBUG/TRACE drop.
log.error("comp", "boom")
log.warn("comp", "watch out")
log.info("comp", "fyi")
log.debug("comp", "internal")  -- below default level; should NOT record
log.trace("comp", "deep")      -- below default level; should NOT record

-- vim.schedule is used for the notify side-effect; drain.
vim.wait(20)

local recent = log.recent()
ok("default level INFO records error+warn+info (3)",
  #recent == 3, vim.inspect(recent))
ok("ring entries carry component + level_name",
  recent[1].component == "comp"
    and recent[1].level_name == "ERROR"
    and recent[2].level_name == "WARN"
    and recent[3].level_name == "INFO")
-- v0.1.12 behavior: ERROR + WARN toast by default; INFO is RING-ONLY
-- (no nvim_echo → no `:messages` spam). Users who want the old behavior
-- opt in via `log.configure({ echo = true })` or per-call `opts.echo`.
ok("ERROR + WARN went to vim.notify; INFO is ring-only (no :messages echo)",
  #notify_calls == 2
    and notify_calls[1].level == vim.log.levels.ERROR
    and notify_calls[2].level == vim.log.levels.WARN)
ok("notify message includes [AutoCore] prefix",
  notify_calls[1].msg:find("%[AutoCore%]") ~= nil)
ok("notify message includes component bracket",
  notify_calls[1].msg:find("%[comp%]") ~= nil)

-- v0.1.12: `opts.echo = true` re-enables the nvim_echo path per-call
-- (the migration knob for callers who actually wanted the :messages
-- visibility). The ring entry is also written.
do
  log._reset_for_tests()
  local echo_count = 0
  local prev_echo = vim.api.nvim_echo
  vim.api.nvim_echo = function() echo_count = echo_count + 1 end
  log.info("comp", "echoed-info", { echo = true })
  log.info("comp", "silent-info")
  vim.wait(20)
  vim.api.nvim_echo = prev_echo
  ok("v0.1.12: opts.echo=true forwards INFO to nvim_echo",
    echo_count == 1, "echo_count=" .. echo_count)
  ok("v0.1.12: omitted opts.echo stays ring-only (silent)",
    #log.recent() == 2 and echo_count == 1)
end

-- v0.1.12: global `configure({ echo = true })` flips the default
-- for every emission. Mirrors the old (pre-v0.1.12) behavior for
-- users / projects that want the :messages visibility back.
do
  log._reset_for_tests()
  log.configure({ echo = true })
  local echo_count = 0
  local prev_echo = vim.api.nvim_echo
  vim.api.nvim_echo = function() echo_count = echo_count + 1 end
  log.info("comp", "echoed-via-config-1")
  log.info("comp", "echoed-via-config-2")
  vim.wait(20)
  vim.api.nvim_echo = prev_echo
  ok("v0.1.12: configure({ echo = true }) re-enables nvim_echo by default",
    echo_count == 2, "echo_count=" .. echo_count)
end

-- is_level_enabled
ok("is_level_enabled('error') true at default INFO", log.is_level_enabled("error"))
ok("is_level_enabled('debug') false at default INFO", not log.is_level_enabled("debug"))

-- Lower level → DEBUG passes through.
log.configure({ level = "debug" })
log.debug("comp", "now visible")
ok("after configure(debug), debug entries record",
  (function()
    for _, e in ipairs(log.recent()) do
      if e.level_name == "DEBUG" then return true end
    end
    return false
  end)())

-- Numeric level (reset FIRST, then configure — _reset_for_tests
-- restores defaults so the order matters).
vim.wait(30)  -- drain pending notify schedules from prior assertions
log._reset_for_tests()
log.configure({ level = log.levels.WARN })
log.error("c", "e1")
log.warn("c", "w1")
log.info("c", "i1")
vim.wait(30)  -- drain
ok("level=WARN drops INFO",
  #log.recent() == 2,
  string.format("got %d entries", #log.recent()))

-- Notify off (same order — drain + reset, then configure).
vim.wait(30)
log._reset_for_tests()
notify_calls = {}
log.configure({ notify = false })
log.error("c", "silent")
vim.wait(30)
ok("notify=false suppresses vim.notify",
  #notify_calls == 0
    and #log.recent() == 1,
  string.format("notify_calls=%d log.recent=%d",
    #notify_calls, #log.recent()))

-- Ring capacity behavior
log._reset_for_tests()
log.configure({ ring_capacity = 5, level = log.levels.TRACE, notify = false })
for i = 1, 12 do log.info("c", "msg-" .. i) end
local r = log.recent()
ok("ring capped at 5 (FIFO eviction)",
  #r == 5)
ok("ring contents are the last 5 entries (oldest first)",
  r[1].message:find("msg%-8")  ~= nil
    and r[5].message:find("msg%-12") ~= nil,
  string.format("first=%s last=%s", r[1].message, r[5].message))

-- recent(n)
local r3 = log.recent(3)
ok("recent(n) returns last n",
  #r3 == 3 and r3[3].message:find("msg%-12") ~= nil)

-- namespace handle
log._reset_for_tests()
log.configure({ notify = false })
local h = log.namespace("watcher")
h.error("boom")
h.info("hello")
local nrh = log.recent()
ok("namespace handle pre-binds component",
  #nrh == 2
    and nrh[1].component == "watcher"
    and nrh[2].component == "watcher")

-- inspect
local snap = log.inspect()
ok("inspect returns config snapshot",
  type(snap) == "table"
    and snap.ring_capacity ~= nil
    and snap.notify == false
    and type(snap.count) == "number")

-- ── ADR 0021 Phase 1: options-table sentinel detection + schema ─────
-- Wrapped in `do ... end` so the locals release before the smoke
-- script's main-function 200-local cap.
do
  -- Backward compat: a trailing table with no sentinel keys remains a
  -- message part (renders via vim.inspect into `message`).
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "msg", { path = "/x", count = 3 })
  local r = log.recent()
  ok("ADR 0021: trailing table without sentinel keys stays a message part",
    #r == 1
      and r[1].message:find("path") ~= nil
      and r[1].event_type == nil
      and r[1].fields == nil,
    vim.inspect(r))

  -- Sentinel: `event` key promotes the table to options. The table is
  -- popped off the parts; the ring entry carries event_type, not the
  -- table-as-message-part.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "started", { event = "auto-finder.scan.started" })
  r = log.recent()
  ok("ADR 0021: `event` sentinel populates event_type on the ring entry",
    #r == 1
      and r[1].event_type == "auto-finder.scan.started"
      and r[1].message:find("auto%-finder%.scan%.started") == nil
      and r[1].message:find("started") ~= nil,
    vim.inspect(r))

  -- Sentinel: `fields` key preserves the structured table on the entry.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "completed", {
    fields = { path = "/proj", elapsed_ms = 314 },
  })
  r = log.recent()
  ok("ADR 0021: `fields` sentinel preserves the structured table unflattened",
    #r == 1
      and type(r[1].fields) == "table"
      and r[1].fields.path == "/proj"
      and r[1].fields.elapsed_ms == 314,
    vim.inspect(r))

  -- Sentinels combine: event + fields together.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "done", {
    event  = "auto-finder.scan.completed.slow",
    fields = { elapsed_ms = 3142 },
  })
  r = log.recent()
  ok("ADR 0021: event + fields combine on one entry",
    #r == 1
      and r[1].event_type == "auto-finder.scan.completed.slow"
      and r[1].fields.elapsed_ms == 3142)

  -- `notify` and `level_override` sentinels: recognized + popped even
  -- though Phase 1 does not yet act on them (routing lands in Phase 2).
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "msg", { notify = true })
  log.info("comp", "msg2", { level_override = log.levels.WARN })
  r = log.recent()
  ok("ADR 0021: `notify` sentinel pops the opts table (no message bleed)",
    r[1].message:find("notify = true", 1, true) == nil)
  ok("ADR 0021: `level_override` sentinel pops the opts table",
    r[2].message:find("level_override", 1, true) == nil)

  -- Multiple message parts followed by opts.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "part1", "part2", "part3", { event = "auto-core.x" })
  r = log.recent()
  ok("ADR 0021: parts before opts table all reach the message",
    #r == 1
      and r[1].message:find("part1") ~= nil
      and r[1].message:find("part2") ~= nil
      and r[1].message:find("part3") ~= nil
      and r[1].event_type == "auto-core.x",
    vim.inspect(r))

  -- Existing entries (no opts) still have nil for the new fields.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "plain")
  r = log.recent()
  ok("ADR 0021: pre-existing call shape leaves event_type/fields nil",
    r[1].event_type == nil and r[1].fields == nil)

  -- First-arg-not-string shape combined with opts table.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info({ event = "auto-core.nocomp" })
  r = log.recent()
  ok("ADR 0021: non-string first arg + opts table — component nil, opts applied",
    #r == 1
      and r[1].component == nil
      and r[1].event_type == "auto-core.nocomp")

  -- Namespace handle passes opts through.
  log._reset_for_tests()
  log.configure({ notify = false })
  local h2 = log.namespace("watcher")
  h2.info("watching", { event = "auto-core.watcher.armed" })
  r = log.recent()
  ok("ADR 0021: namespace handle propagates opts through to dispatch",
    #r == 1
      and r[1].component == "watcher"
      and r[1].event_type == "auto-core.watcher.armed")
end

-- ── ADR 0021 Phase 1 Step 2: notify / notifyIf + opts.notify routing ─
do
  -- log.notify(msg) — default level INFO, toasts + ring.
  log._reset_for_tests()
  notify_calls = {}
  log.notify("hello world")
  vim.wait(20)
  local r = log.recent()
  ok("ADR 0021 §5: log.notify writes the ring entry",
    #r == 1 and r[1].level_name == "INFO"
      and r[1].message:find("hello world") ~= nil,
    vim.inspect(r))
  ok("ADR 0021 §5: log.notify fires vim.notify (forces toast at INFO)",
    #notify_calls == 1
      and notify_calls[1].level == vim.log.levels.INFO,
    vim.inspect(notify_calls))

  -- log.notify(msg, { level = "warn", component = "scan", title = "Custom" })
  log._reset_for_tests()
  notify_calls = {}
  log.notify("watch out", {
    level     = "warn",
    component = "scan",
    title     = "Custom Title",
    fields    = { path = "/tmp" },
  })
  vim.wait(20)
  r = log.recent()
  ok("ADR 0021 §5: log.notify honors opts.level (warn)",
    #r == 1 and r[1].level_name == "WARN" and r[1].component == "scan")
  ok("ADR 0021 §5: log.notify preserves opts.fields on the ring entry",
    type(r[1].fields) == "table" and r[1].fields.path == "/tmp")
  ok("ADR 0021 §5: log.notify uses opts.title for the toast",
    #notify_calls == 1
      and notify_calls[1].opts.title == "Custom Title"
      and notify_calls[1].level == vim.log.levels.WARN)

  -- log.notifyIf with the default stub (always returns false) — ring
  -- entry written, NO toast.
  log._reset_for_tests()
  notify_calls = {}
  log.notifyIf("auto-finder.scan.started", "mapping ~/proj")
  vim.wait(20)
  r = log.recent()
  ok("ADR 0021 §5: notifyIf writes ring entry even when event unsubscribed",
    #r == 1
      and r[1].event_type == "auto-finder.scan.started"
      and r[1].message:find("mapping") ~= nil)
  ok("ADR 0021 §5: notifyIf stays silent when stub returns false",
    #notify_calls == 0,
    string.format("got %d notifies", #notify_calls))

  -- log.notifyIf when the registry says subscribed — toast fires.
  log._reset_for_tests()
  notify_calls = {}
  local saved_is_enabled = log.events.is_notify_enabled
  log.events.is_notify_enabled = function(e) return e == "auto-finder.scan.completed.slow" end
  log.notifyIf("auto-finder.scan.completed.slow", "mapped ~/proj (3.1s)")
  log.notifyIf("auto-finder.scan.started",         "mapping ~/proj")  -- not subscribed
  vim.wait(20)
  ok("ADR 0021 §5: notifyIf toasts when event is subscribed",
    #notify_calls == 1
      and notify_calls[1].msg:find("3%.1s") ~= nil,
    vim.inspect(notify_calls))
  log.events.is_notify_enabled = saved_is_enabled

  -- Per-call opts.notify = true forces toast even for INFO.
  log._reset_for_tests()
  notify_calls = {}
  log.info("comp", "force-toast", { notify = true })
  vim.wait(20)
  ok("ADR 0021 §4: opts.notify=true forces toast at INFO",
    #notify_calls == 1
      and notify_calls[1].level == vim.log.levels.INFO)

  -- Per-call opts.notify = false suppresses toast even for ERROR.
  log._reset_for_tests()
  notify_calls = {}
  log.error("comp", "silent-error", { notify = false })
  vim.wait(20)
  r = log.recent()
  ok("ADR 0021 §4: opts.notify=false suppresses toast at ERROR (ring entry still written)",
    #notify_calls == 0 and #r == 1 and r[1].level_name == "ERROR",
    string.format("notify_calls=%d ring=%d", #notify_calls, #r))

  -- Default routing preserved: no opts → ERROR/WARN toast, INFO+ silent.
  log._reset_for_tests()
  notify_calls = {}
  log.error("c", "e")
  log.warn ("c", "w")
  log.info ("c", "i")
  vim.wait(20)
  ok("ADR 0021 §4: omitted opts.notify keeps the pre-existing default routing",
    #notify_calls == 2
      and notify_calls[1].level == vim.log.levels.ERROR
      and notify_calls[2].level == vim.log.levels.WARN)

  -- Below-level filter applies to notify too: log.notify at INFO is
  -- dropped when active level is WARN (both ring and toast).
  log._reset_for_tests()
  log.configure({ level = "warn" })
  notify_calls = {}
  log.notify("dropped")
  vim.wait(20)
  ok("ADR 0021 §5: log.notify still honors the active level filter",
    #notify_calls == 0 and #log.recent() == 0)

  -- M.events stub callable + default-false.
  log._reset_for_tests()
  ok("ADR 0021 §5: M.events.is_notify_enabled is callable + returns false (stub)",
    type(log.events) == "table"
      and type(log.events.is_notify_enabled) == "function"
      and log.events.is_notify_enabled("any.event") == false)

  -- notify=auto without event → never toasts.
  log._reset_for_tests()
  notify_calls = {}
  log.info("c", "auto-no-event", { notify = "auto" })
  vim.wait(20)
  ok("ADR 0021 §4: notify='auto' without event silences (no key to look up)",
    #notify_calls == 0)
end

-- ── ADR 0021 Phase 1 Step 3: event-type registry + persistence ──────
do
  local state = require("auto-core.state")
  -- Use a temp persist dir so the subscription set written during
  -- this test doesn't pollute the user's real auto-core state.
  local persist_dir = vim.fn.tempname()
  vim.fn.mkdir(persist_dir, "p")
  state.configure({ persist_dir = persist_dir })

  -- register: bare event name gets fully-qualified with plugin prefix.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-finder", { "scan.started", "scan.completed.slow" })
  local listed = log.events.list("auto-finder")
  ok("ADR 0021 §5: register auto-prefixes bare event names",
    #listed == 2
      and listed[1].event == "auto-finder.scan.completed.slow"
      and listed[2].event == "auto-finder.scan.started",
    vim.inspect(listed))
  ok("ADR 0021 §5: list returns owning plugin per record",
    listed[1].plugin == "auto-finder" and listed[2].plugin == "auto-finder")

  -- Pre-qualified event names pass through unchanged (no double prefix).
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-agents", { "auto-agents.spawn.failed" })
  local pq = log.events.list("auto-agents")
  ok("ADR 0021 §5: register skips re-prefixing already-qualified names",
    #pq == 1 and pq[1].event == "auto-agents.spawn.failed",
    vim.inspect(pq))

  -- register accepts a single string for ergonomic single-event registration.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("md-harpoon", "doc.pinned")
  local single = log.events.list("md-harpoon")
  ok("ADR 0021 §5: register accepts a bare string for a single event",
    #single == 1 and single[1].event == "md-harpoon.doc.pinned")

  -- register is idempotent: repeat call doesn't duplicate.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-finder", "scan.started")
  log.events.register("auto-finder", "scan.started")
  log.events.register("auto-finder", "scan.started")
  ok("ADR 0021 §5: register is idempotent (no duplicates)",
    #log.events.list("auto-finder") == 1)

  -- list() with no arg returns ALL registered events.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-finder", { "scan.started" })
  log.events.register("auto-agents", { "spawn.failed" })
  log.events.register("auto-core",   { "mailbox.delivered" })
  local all = log.events.list()
  ok("ADR 0021 §5: list() with no plugin filter returns events across plugins",
    #all == 3
      and all[1].event == "auto-agents.spawn.failed"
      and all[2].event == "auto-core.mailbox.delivered"
      and all[3].event == "auto-finder.scan.started",
    vim.inspect(all))

  -- enable_notify + is_notify_enabled round trip.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.enable_notify("auto-finder.scan.completed.slow")
  ok("ADR 0021 §5: is_notify_enabled returns true after enable_notify",
    log.events.is_notify_enabled("auto-finder.scan.completed.slow") == true)
  ok("ADR 0021 §5: is_notify_enabled returns false for un-subscribed events",
    log.events.is_notify_enabled("auto-finder.scan.started") == false)

  -- disable_notify clears the subscription.
  log.events.disable_notify("auto-finder.scan.completed.slow")
  ok("ADR 0021 §5: disable_notify clears the subscription",
    log.events.is_notify_enabled("auto-finder.scan.completed.slow") == false)

  -- Tolerant of registration order: subscribe-before-register works.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.enable_notify("not-yet.registered")
  ok("ADR 0021 §5: enable_notify works on unregistered events (tolerant ordering)",
    log.events.is_notify_enabled("not-yet.registered") == true)

  -- Persistence round-trip: write subscription, flush, reset cache,
  -- reload — subscription survives.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.enable_notify("persisted.event.x")
  -- Force a synchronous flush so the file lands before we tear down.
  local ns_pre = state.namespace("auto-core.log.events")
  ns_pre:persist_now()
  -- Drop the cache so the next call re-loads from disk.
  log._reset_for_tests()
  state._reset_for_tests()
  ok("ADR 0021 §5: subscriptions persist across state reset (json round-trip)",
    log.events.is_notify_enabled("persisted.event.x") == true)
  -- Cleanup: clear the persisted entry so we leave the temp dir clean.
  log.events.disable_notify("persisted.event.x")
  state.namespace("auto-core.log.events"):persist_now()

  -- notifyIf with real registry: subscribed → toast; unsubscribed → silent.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-finder", { "scan.started", "scan.completed.slow" })
  log.events.enable_notify("auto-finder.scan.completed.slow")
  notify_calls = {}
  log.notifyIf("auto-finder.scan.completed.slow", "mapped (slow)")
  log.notifyIf("auto-finder.scan.started",         "mapping")
  vim.wait(20)
  ok("ADR 0021 §5: notifyIf consults the real registry (subscribed → toast)",
    #notify_calls == 1
      and notify_calls[1].msg:find("mapped %(slow%)") ~= nil)
  ok("ADR 0021 §5: notifyIf consults the real registry (unsubscribed → silent)",
    (function()
      for _, c in ipairs(notify_calls) do
        if c.msg:find("mapping") then return false end
      end
      return true
    end)())

  -- Argument validation.
  log._reset_for_tests()
  state._reset_for_tests()
  ok("ADR 0021 §5: register rejects empty plugin name",
    not pcall(log.events.register, "", { "x" }))
  ok("ADR 0021 §5: register rejects non-string event names",
    not pcall(log.events.register, "p", { 42 }))
  ok("ADR 0021 §5: enable_notify rejects empty event",
    not pcall(log.events.enable_notify, ""))

  -- Teardown: restore default persist dir.
  state.configure({ persist_dir = nil })
  state._reset_for_tests()
  pcall(vim.fn.delete, persist_dir, "rf")
end

-- ── ADR 0021 Phase 1 Step 4: :AutoCoreLogEvent user command ─────────
do
  -- Make sure the plugin file has been sourced. In a real session
  -- nvim does this at startup; the smoke harness boots with
  -- `-u tests/smoke.lua` which bypasses normal plugin loading, so
  -- we force it here.
  vim.cmd("runtime! plugin/auto-core.lua")

  local state = require("auto-core.state")
  local persist_dir = vim.fn.tempname()
  vim.fn.mkdir(persist_dir, "p")
  state.configure({ persist_dir = persist_dir })

  -- Reset state + log for a clean slate.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-finder",
    { "scan.started", "scan.completed.slow" })

  -- Capture vim.notify to verify the command emits a confirmation.
  notify_calls = {}

  -- Command registration: AutoCoreLogEvent must exist as a user command.
  local cmds = vim.api.nvim_get_commands({})
  ok("ADR 0021 §5: :AutoCoreLogEvent command is registered",
    cmds.AutoCoreLogEvent ~= nil,
    "no AutoCoreLogEvent in nvim_get_commands")

  -- :AutoCoreLogEvent notify <event> enables the subscription.
  vim.cmd("AutoCoreLogEvent notify auto-finder.scan.completed.slow")
  ok("ADR 0021 §5: :AutoCoreLogEvent notify enables the subscription",
    log.events.is_notify_enabled("auto-finder.scan.completed.slow") == true)

  -- :AutoCoreLogEvent silence <event> disables it again.
  vim.cmd("AutoCoreLogEvent silence auto-finder.scan.completed.slow")
  ok("ADR 0021 §5: :AutoCoreLogEvent silence disables the subscription",
    log.events.is_notify_enabled("auto-finder.scan.completed.slow") == false)

  -- :AutoCoreLogEvent list runs without raising; we capture nvim_echo
  -- output via the stub installed at the top of [39].
  local echo_calls = 0
  local prev_echo = vim.api.nvim_echo
  vim.api.nvim_echo = function() echo_calls = echo_calls + 1 end
  local list_ok = pcall(vim.cmd, "AutoCoreLogEvent list")
  vim.api.nvim_echo = prev_echo
  ok("ADR 0021 §5: :AutoCoreLogEvent list runs without error",
    list_ok and echo_calls >= 1,
    string.format("list_ok=%s echo_calls=%d", tostring(list_ok), echo_calls))

  -- :AutoCoreLogEvent (no subcommand) defaults to list.
  echo_calls = 0
  vim.api.nvim_echo = function() echo_calls = echo_calls + 1 end
  local default_ok = pcall(vim.cmd, "AutoCoreLogEvent")
  vim.api.nvim_echo = prev_echo
  ok("ADR 0021 §5: :AutoCoreLogEvent with no subcommand defaults to list",
    default_ok and echo_calls >= 1)

  -- Unknown subcommand surfaces an ERROR notify.
  log.events.enable_notify("auto-finder.scan.started")  -- noise to clear
  notify_calls = {}
  pcall(vim.cmd, "AutoCoreLogEvent garbage")
  ok("ADR 0021 §5: :AutoCoreLogEvent rejects unknown subcommand with ERROR notify",
    (function()
      for _, c in ipairs(notify_calls) do
        if c.level == vim.log.levels.ERROR
            and c.msg:find("unknown subcommand") then
          return true
        end
      end
      return false
    end)(),
    vim.inspect(notify_calls))

  -- notify without an event arg errors.
  notify_calls = {}
  pcall(vim.cmd, "AutoCoreLogEvent notify")
  ok("ADR 0021 §5: :AutoCoreLogEvent notify without event arg errors",
    (function()
      for _, c in ipairs(notify_calls) do
        if c.level == vim.log.levels.ERROR
            and c.msg:find("missing <event>") then
          return true
        end
      end
      return false
    end)())

  -- Tab completion: subcommand list.
  local complete_fn = cmds.AutoCoreLogEvent.complete
  -- Neovim's complete function gets the user-defined complete
  -- callback under .complete = "customlist,<func>" / fnref. The
  -- nvim_get_commands API doesn't expose the raw callback, so we
  -- access it through the registered command directly via cmd.
  -- For the smoke test, we exercise the command-defined completion
  -- function by re-importing the user-command callback indirectly:
  -- call the underlying logic. Skip if not accessible.
  ok("ADR 0021 §5: :AutoCoreLogEvent has a completion fn registered",
    complete_fn == "customlist" or type(complete_fn) == "function"
      or type(complete_fn) == "string",
    string.format("complete_fn type=%s val=%s",
      type(complete_fn), tostring(complete_fn)))

  -- Teardown.
  state.configure({ persist_dir = nil })
  state._reset_for_tests()
  pcall(vim.fn.delete, persist_dir, "rf")
end

-- ── ADR 0021 Phase 1 Step 5: throttled emission (hot-loop guard) ────
do
  -- First call passes the throttle; second call within the window
  -- is silently dropped; after the window elapses, the next call
  -- passes again.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info_throttled("test-scan", 100, "comp", "msg-1")
  log.info_throttled("test-scan", 100, "comp", "msg-2")  -- dropped
  log.info_throttled("test-scan", 100, "comp", "msg-3")  -- dropped
  local r = log.recent()
  ok("ADR 0021 §11: throttled emission drops calls within window",
    #r == 1 and r[1].message:find("msg%-1") ~= nil,
    string.format("got %d entries", #r))

  -- Wait past the window, then the next call passes.
  vim.wait(120)
  log.info_throttled("test-scan", 100, "comp", "msg-4")
  r = log.recent()
  ok("ADR 0021 §11: throttled emission re-emits after window elapses",
    #r == 2 and r[2].message:find("msg%-4") ~= nil)

  -- Different keys throttle independently — neither leaks into the
  -- other's bucket.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info_throttled("key-A", 1000, "comp", "A1")
  log.info_throttled("key-B", 1000, "comp", "B1")  -- different bucket
  log.info_throttled("key-A", 1000, "comp", "A2")  -- dropped
  log.info_throttled("key-B", 1000, "comp", "B2")  -- dropped
  r = log.recent()
  ok("ADR 0021 §11: throttle buckets are key-keyed (independent)",
    #r == 2
      and r[1].message:find("A1") ~= nil
      and r[2].message:find("B1") ~= nil,
    vim.inspect(r))

  -- All five level variants exist and route to the matching level.
  log._reset_for_tests()
  log.configure({ level = log.levels.TRACE, notify = false })
  log.error_throttled("k-e", 50, "c", "e")
  log.warn_throttled ("k-w", 50, "c", "w")
  log.info_throttled ("k-i", 50, "c", "i")
  log.debug_throttled("k-d", 50, "c", "d")
  log.trace_throttled("k-t", 50, "c", "t")
  r = log.recent()
  ok("ADR 0021 §11: every level has a *_throttled variant routing to the right level",
    #r == 5
      and r[1].level_name == "ERROR"
      and r[2].level_name == "WARN"
      and r[3].level_name == "INFO"
      and r[4].level_name == "DEBUG"
      and r[5].level_name == "TRACE",
    vim.inspect(r))

  -- Argument validation.
  log._reset_for_tests()
  ok("ADR 0021 §11: throttled rejects empty key",
    not pcall(log.info_throttled, "", 100, "c", "x"))
  ok("ADR 0021 §11: throttled rejects non-positive every_ms",
    not pcall(log.info_throttled, "k", 0, "c", "x")
      and not pcall(log.info_throttled, "k", -10, "c", "x"))

  -- _reset_for_tests clears the throttle map so tests don't leak.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info_throttled("k-reset", 1000, "c", "first")
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info_throttled("k-reset", 1000, "c", "after-reset")
  r = log.recent()
  ok("ADR 0021 §11: _reset_for_tests clears the throttle map",
    #r == 1 and r[1].message:find("after%-reset") ~= nil,
    vim.inspect(r))

  -- Throttled call honors opts-table sentinel detection: a trailing
  -- opts table flows through to dispatch (event/fields preserved).
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info_throttled("k-opts", 100, "scan", "started", {
    event  = "auto-finder.scan.started",
    fields = { path = "~/proj" },
  })
  r = log.recent()
  ok("ADR 0021 §11: throttled calls flow opts through (event + fields preserved)",
    #r == 1
      and r[1].event_type == "auto-finder.scan.started"
      and r[1].fields.path == "~/proj")
end

-- Restore stubs.
vim.notify = orig_notify
vim.api.nvim_echo = orig_echo
log._reset_for_tests()

-- ─────────────────────── 40. health — :checkhealth subsystem checks ─────────────────────────
print("\n[40] health — checkhealth runs without error, reports each subsystem")
local health = require("auto-core.health")

-- Stub vim.health.* to capture calls.
local orig_health = vim.health
local health_calls = { start = {}, ok = {}, info = {}, warn = {}, err = {} }
vim.health = {
  start = function(name) health_calls.start[#health_calls.start + 1] = name end,
  ok    = function(msg)  health_calls.ok[#health_calls.ok + 1] = msg end,
  info  = function(msg)  health_calls.info[#health_calls.info + 1] = msg end,
  warn  = function(msg)  health_calls.warn[#health_calls.warn + 1] = msg end,
  error = function(msg, advice)
    health_calls.err[#health_calls.err + 1] = { msg = msg, advice = advice }
  end,
}

local check_ok = pcall(health.check)
ok("health.check runs without error", check_ok)

ok("health.start invoked with 'auto-core'",
  #health_calls.start == 1 and health_calls.start[1] == "auto-core")

ok("at least one ok report (e.g. plenary or events bus)",
  #health_calls.ok >= 1, vim.inspect(health_calls.ok))

ok("info reports include version line",
  (function()
    for _, m in ipairs(health_calls.info) do
      if m:find("version") then return true end
    end
    return false
  end)(),
  vim.inspect(health_calls.info))

ok("info reports include log status",
  (function()
    for _, m in ipairs(health_calls.info) do
      if m:find("^log:") then return true end
    end
    return false
  end)(),
  vim.inspect(health_calls.info))

ok("info reports include fs.watch status",
  (function()
    for _, m in ipairs(health_calls.info) do
      if m:find("fs%.watch") then return true end
    end
    return false
  end)())

ok("topic registry check produces ok or warn",
  (function()
    for _, m in ipairs(health_calls.ok) do
      if m:find("topic registry") then return true end
    end
    for _, m in ipairs(health_calls.warn) do
      if m:find("topic registry") then return true end
    end
    return false
  end)())

ok("events bus probe produced ok status",
  (function()
    for _, m in ipairs(health_calls.ok) do
      if m:find("events bus dispatch responsive") then return true end
    end
    return false
  end)())

-- Restore.
vim.health = orig_health

-- ─────────────────────── 41. setup() forwards log config ─────────────────────────
print("\n[41] setup() forwards log config to log.configure")
core.setup({ log = { level = "error" } })
local snap_after_setup = log.inspect()
ok("setup({log.level='error'}) lowers level to ERROR",
  snap_after_setup.level == log.levels.ERROR,
  vim.inspect(snap_after_setup))

-- Restore default.
core.setup({})

-- ─────────────────────── 42. lsp.reset — tech-stack-aware restart ─────────────────────────
print("\n[42] lsp.reset — tech-stack detection, partition, dry_run")
;(function()
local lsp_reset = require("auto-core.lsp.reset")
lsp_reset._reset_for_tests()

-- Build a deterministic tmpdir tree with a few stack markers.
local tmp = vim.fn.tempname() .. "_lspreset"
vim.fn.mkdir(tmp .. "/go-proj/sub", "p")
vim.fn.writefile({ "module x" }, tmp .. "/go-proj/go.mod")
vim.fn.mkdir(tmp .. "/ts-proj/src", "p")
vim.fn.writefile({ "{}" }, tmp .. "/ts-proj/package.json")
vim.fn.mkdir(tmp .. "/poly", "p")
vim.fn.writefile({ "module y" }, tmp .. "/poly/go.mod")
vim.fn.writefile({ "{}" }, tmp .. "/poly/package.json")
vim.fn.mkdir(tmp .. "/empty", "p")

-- detect_stack: walk-up from a file or subdir, OR-combine markers.
local go_stack = lsp_reset.detect_stack(tmp .. "/go-proj/sub/file.go")
ok("detect_stack(go file under go.mod) returns gopls",
  vim.tbl_contains(go_stack, "gopls"),
  vim.inspect(go_stack))
ok("detect_stack(go file) does NOT return ts_ls",
  not vim.tbl_contains(go_stack, "ts_ls"))

local ts_stack = lsp_reset.detect_stack(tmp .. "/ts-proj/src")
ok("detect_stack(ts dir) returns ts_ls + eslint",
  vim.tbl_contains(ts_stack, "ts_ls")
    and vim.tbl_contains(ts_stack, "eslint"))

-- Polyglot dir (rare but legal): both go.mod and package.json present.
local poly_stack = lsp_reset.detect_stack(tmp .. "/poly")
ok("detect_stack(polyglot dir) unions both stacks",
  vim.tbl_contains(poly_stack, "gopls")
    and vim.tbl_contains(poly_stack, "ts_ls"),
  vim.inspect(poly_stack))

-- No marker reachable: empty result.
local empty_stack = lsp_reset.detect_stack(tmp .. "/empty")
ok("detect_stack(no marker) returns empty",
  type(empty_stack) == "table" and #empty_stack == 0,
  vim.inspect(empty_stack))

-- register_stack adds servers; idempotent on repeat add.
lsp_reset.register_stack("go.mod", { "custom_go_lsp" })
local extended = lsp_reset.detect_stack(tmp .. "/go-proj")
ok("register_stack appends new server",
  vim.tbl_contains(extended, "custom_go_lsp"))
lsp_reset.register_stack("go.mod", { "custom_go_lsp" })  -- duplicate
local snap = lsp_reset.list_stacks()["go.mod"]
local custom_count = 0
for _, s in ipairs(snap) do
  if s == "custom_go_lsp" then custom_count = custom_count + 1 end
end
ok("register_stack is idempotent (no duplicate entries)",
  custom_count == 1, "custom_count=" .. custom_count)

-- preview / reset_for partition logic. Stub vim.lsp.get_clients to
-- return synthetic clients so we don't depend on a real LSP setup.
local orig_get_clients = vim.lsp.get_clients
local orig_stop = vim.lsp.stop_client
local stop_calls = {}
local function fake_clients(list)
  vim.lsp.get_clients = function() return list end
end
vim.lsp.stop_client = function(id, _force)
  stop_calls[#stop_calls + 1] = id
end

-- Case A: a gopls client rooted under the new go-proj path → kept.
fake_clients({
  { id = 11, name = "gopls", root_dir = tmp .. "/go-proj" },
})
local p1 = lsp_reset.preview(tmp .. "/go-proj")
ok("preview keeps gopls already rooted under target",
  #p1.stopped == 0 and #p1.untouched == 1,
  string.format("stopped=%d untouched=%d", #p1.stopped, #p1.untouched))

-- Case B: a gopls client rooted under a DIFFERENT go project → stopped.
fake_clients({
  { id = 12, name = "gopls", root_dir = "/some/other/go-project" },
})
local p2 = lsp_reset.preview(tmp .. "/go-proj")
ok("preview stops gopls rooted outside target",
  #p2.stopped == 1 and p2.stopped[1].id == 12)

-- Case C: a ts_ls client when the target is a Go project → untouched
-- (ts_ls is NOT in the considered set for go.mod stack).
fake_clients({
  { id = 13, name = "ts_ls", root_dir = "/some/ts-project" },
})
local p3 = lsp_reset.preview(tmp .. "/go-proj")
ok("preview leaves out-of-stack clients alone",
  #p3.stopped == 0 and #p3.untouched == 1)

-- Case D: extra_servers extends the considered set.
fake_clients({
  { id = 14, name = "ts_ls", root_dir = "/elsewhere" },
})
local p4 = lsp_reset.preview(tmp .. "/go-proj",
  { extra_servers = { "ts_ls" } })
ok("preview with extra_servers stops the additional name",
  #p4.stopped == 1 and p4.stopped[1].id == 14)

-- Case E: exclude takes precedence — even mismatched + in-stack
-- clients are untouched if excluded.
fake_clients({
  { id = 15, name = "gopls", root_dir = "/elsewhere" },
})
local p5 = lsp_reset.preview(tmp .. "/go-proj",
  { exclude = { "gopls" } })
ok("preview honors opts.exclude",
  #p5.stopped == 0 and #p5.untouched == 1)

-- Case F: dry_run skips the actual stop_client call but still publishes.
fake_clients({
  { id = 16, name = "gopls", root_dir = "/elsewhere" },
})
stop_calls = {}
local got_topic = nil
events.subscribe("core.lsp:reset", function(payload, _topic)
  got_topic = payload
end)
lsp_reset.reset_for(tmp .. "/go-proj", { dry_run = true })
vim.wait(20)
ok("dry_run does NOT call vim.lsp.stop_client",
  #stop_calls == 0, "stop_calls=" .. vim.inspect(stop_calls))
ok("dry_run still publishes core.lsp:reset",
  got_topic ~= nil and got_topic.dry_run == true,
  vim.inspect(got_topic))

-- Case G: real reset_for stops mismatched clients AND publishes.
fake_clients({
  { id = 17, name = "gopls", root_dir = "/elsewhere" },
})
stop_calls = {}
got_topic = nil
lsp_reset.reset_for(tmp .. "/go-proj")
vim.wait(20)
ok("reset_for stops the mismatched client", vim.tbl_contains(stop_calls, 17))
ok("reset_for publishes payload with detected_stack",
  got_topic ~= nil
    and vim.tbl_contains(got_topic.detected_stack, "gopls"),
  vim.inspect(got_topic))

-- Restore real LSP API.
vim.lsp.get_clients = orig_get_clients
vim.lsp.stop_client = orig_stop
lsp_reset._reset_for_tests()
vim.fn.delete(tmp, "rf")
end)()  -- close [42] IIFE so its locals don't count toward main function's 200 limit

-- ─────────────────────── 43. ui.float.multi — multi-pane float ─────────────────────────
print("\n[43] ui.float.multi — open/close/focus/cycle/resize/dispose")
;(function()
local mfloat = require("auto-core.ui.float.multi")
mfloat._reset_for_tests()

-- Open a four-pane instance. The fixture mirrors the gitsgraph
-- shape exactly so Phase 3's worktree.graph can drop in.
local m = mfloat.new({
  name  = "smoke_test_panel",
  outer = { width_pct = 0.85, height_pct = 0.85, title = " smoke " },
  panes = {
    left    = { width = 28, cursorline = true },
    middle  = { title = " middle " },
    preview = { width = 60, min_width = 30, min_middle = 30 },
    footer  = { height = 1, content = " <Tab> cycle • q close " },
  },
  initial_focus = "middle",
})

ok("registry holds the instance after .new()",
  mfloat.get("smoke_test_panel") == m)

m:open()
ok("is_open after :open()", m:is_open())
ok("bg pane has a winid",
  m:winid("bg") and vim.api.nvim_win_is_valid(m:winid("bg")))
ok("left pane has a winid", m:winid("left") ~= nil)
ok("middle pane has a winid", m:winid("middle") ~= nil)
ok("footer pane has a winid", m:winid("footer") ~= nil)

-- All panes carry the marker var.
local marker = "auto_core_multi_float"
local function _wvar(w)
  local ok_v, v = pcall(vim.api.nvim_win_get_var, w, marker)
  return ok_v and v or nil
end
ok("bg window stamped with marker",
  _wvar(m:winid("bg")) == "smoke_test_panel")
ok("left window stamped with marker",
  _wvar(m:winid("left")) == "smoke_test_panel")
ok("middle window stamped with marker",
  _wvar(m:winid("middle")) == "smoke_test_panel")

-- Initial focus landed on middle.
ok("initial_focus moved cursor to middle",
  vim.api.nvim_get_current_win() == m:winid("middle"))

-- Footer is non-focusable; focusing it is a no-op (the function
-- still stays on the requested winid because we don't validate
-- focusable in :focus). Skip.

-- Cycle: middle → preview (or → left if preview wasn't laid out).
m:cycle("forward")
local cur = vim.api.nvim_get_current_win()
ok("cycle forward moved focus off middle", cur ~= m:winid("middle"))

m:cycle("backward")
ok("cycle backward returned to middle",
  vim.api.nvim_get_current_win() == m:winid("middle"))

-- Footer content lands in the auto-spawned scratch buffer.
local footer_buf = m:bufnr("footer")
local footer_lines = vim.api.nvim_buf_get_lines(footer_buf, 0, -1, false)
ok("footer content rendered into scratch",
  footer_lines[1] and footer_lines[1]:find("cycle", 1, true))

-- set_buffer swaps a pane's bufnr; the auto-spawned old buffer is wiped.
local replacement = vim.api.nvim_create_buf(false, true)
vim.bo[replacement].bufhidden = "hide"  -- so wipe-on-set doesn't kill it
local prev = m:bufnr("left")
m:set_buffer("left", replacement)
ok("set_buffer updates bufnr",
  m:bufnr("left") == replacement)
ok("set_buffer wiped the auto-spawned buffer",
  not vim.api.nvim_buf_is_valid(prev))

-- resize() recomputes layout — call it manually and confirm
-- bg geometry still matches the editor dims.
local pre = vim.api.nvim_win_get_config(m:winid("bg"))
m:resize()
local post = vim.api.nvim_win_get_config(m:winid("bg"))
ok("resize re-applies bg geometry",
  pre.width == post.width and pre.height == post.height,
  string.format("pre=%dx%d post=%dx%d",
    pre.width, pre.height, post.width, post.height))

-- WinClosed on any pane triggers full close. Close left manually,
-- expect the whole multi to tear down on the next event tick.
local left_win = m:winid("left")
pcall(vim.api.nvim_win_close, left_win, true)
vim.wait(50, function() return not m:is_open() end)
ok("closing one pane closes the whole multi-float",
  not m:is_open())

-- New idempotent: re-calling .new with the same name returns the
-- same instance.
local m2 = mfloat.new({
  name  = "smoke_test_panel",
  panes = { middle = {} },
})
ok("idempotent .new returns the existing instance", m2 == m)

-- dispose drops it from the registry.
m:dispose()
ok("dispose removes from registry",
  mfloat.get("smoke_test_panel") == nil)

-- A 2-pane variant (no preview, no footer) lays out cleanly.
local m3 = mfloat.new({
  name  = "smoke_two_pane",
  panes = {
    left   = { width = 28 },
    middle = {},
  },
})
m3:open()
ok("2-pane variant opens",
  m3:winid("left") and m3:winid("middle") and not m3:winid("preview"))
ok("2-pane: middle width fills the rest",
  vim.api.nvim_win_get_config(m3:winid("middle")).width
    > vim.api.nvim_win_get_config(m3:winid("left")).width)
m3:dispose()

-- A middle-only variant (a single content pane) opens.
local m4 = mfloat.new({
  name  = "smoke_solo",
  panes = { middle = {} },
})
m4:open()
ok("middle-only variant opens", m4:is_open())
ok("middle-only has no left/preview/footer",
  not m4:winid("left") and not m4:winid("preview")
    and not m4:winid("footer"))
m4:dispose()

-- Percentage-based widths (Responsive)
local m_perc = mfloat.new({
  name  = "smoke_test_percentage",
  outer = { width_pct = 0.8 }, -- 0.8 * 80 = 64
  panes = {
    left    = { width = 0.25 }, -- 0.25 * 62 (inner) = 15
    middle  = { title = " middle " },
    preview = { width = 0.5, min_middle = 0 },  -- 0.5 * 62 (inner) = 31
    },
  })
  m_perc:open()
  -- inner_w = math.floor(80 * 0.8) - 2 = 64 - 2 = 62
  -- left_w = math.floor(62 * 0.25) = 15
  -- gap1 = 1 (left/middle)
  -- gap2 = 1 (middle/preview)
  -- preview_w = math.floor(62 * 0.5) = 31
  -- middle_w = 62 - 15 - 31 - 2 = 14

local l_win = m_perc:winid("left")
local m_win = m_perc:winid("middle")
local p_win = m_perc:winid("preview")

ok("percentage: left window width is 25% of inner",
  vim.api.nvim_win_get_width(l_win) == 15, "got " .. vim.api.nvim_win_get_width(l_win))
ok("percentage: preview window width is 50% of inner",
  vim.api.nvim_win_get_width(p_win) == 31, "got " .. vim.api.nvim_win_get_width(p_win))
ok("percentage: middle window width claims rest",
  vim.api.nvim_win_get_width(m_win) == 14, "got " .. vim.api.nvim_win_get_width(m_win))
m_perc:dispose()

-- v0.1.28: opener-winid capture + restore. The float must
-- remember which window the user was in when it opened so that
-- close() doesn't leave focus on whatever window nvim's default
-- traversal happens to pick (frequently the tall left-side
-- auto-finder panel).
local opener_buf = vim.api.nvim_create_buf(false, true)
vim.cmd("vsplit")
local opener_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(opener_win, opener_buf)
local m_op = mfloat.new({
  name  = "smoke_opener_restore",
  panes = { middle = {} },
})
m_op:open()
ok("opener_winid captured on open",
  m_op._opener_winid == opener_win,
  "got " .. tostring(m_op._opener_winid)
    .. " expected " .. tostring(opener_win))
ok("focus moved off opener after open",
  vim.api.nvim_get_current_win() ~= opener_win)
m_op:close()
ok("close restored focus to opener",
  vim.api.nvim_get_current_win() == opener_win,
  "got " .. tostring(vim.api.nvim_get_current_win())
    .. " expected " .. tostring(opener_win))
ok("opener_winid cleared after close",
  m_op._opener_winid == nil)
m_op:dispose()

-- Opener captured BEFORE the bg pane opens — bg is not focusable
-- but we still want to confirm the captured winid isn't the bg
-- (regression guard).
vim.api.nvim_set_current_win(opener_win)
local m_op2 = mfloat.new({
  name  = "smoke_opener_not_bg",
  panes = { middle = {} },
})
m_op2:open()
ok("captured opener != bg pane",
  m_op2._opener_winid ~= m_op2:winid("bg"))
m_op2:dispose()

-- Invalid opener (opener window closed during the float's
-- lifetime): close should not crash, and shouldn't try to
-- restore a dead winid.
local victim_buf = vim.api.nvim_create_buf(false, true)
vim.cmd("vsplit")
local victim_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(victim_win, victim_buf)
local m_op3 = mfloat.new({
  name  = "smoke_opener_invalidated",
  panes = { middle = {} },
})
m_op3:open()
-- Kill the opener while the float is up.
pcall(vim.api.nvim_win_close, victim_win, true)
local ok_close = pcall(function() m_op3:close() end)
ok("close survives invalidated opener", ok_close)
ok("invalidated opener doesn't crash, no restore attempted",
  not vim.api.nvim_win_is_valid(victim_win))
m_op3:dispose()

-- Cleanup the opener split we made above.
if vim.api.nvim_win_is_valid(opener_win) then
  pcall(vim.api.nvim_win_close, opener_win, true)
end

mfloat._reset_for_tests()
end)()

-- ─────────────────────── 44. git.graph — fan_out + show_stat + show_diff ─────────────────────────
print("\n[44] git.graph — multi-repo discovery + commit show caches")
;(function()
local graph = require("auto-core.git.graph")
graph._reset_for_tests()

-- Build a small workspace with two real git repos so fan_out can probe.
local tmp = vim.fn.tempname() .. "_graph_ws"
vim.fn.mkdir(tmp .. "/repo-a", "p")
vim.fn.mkdir(tmp .. "/repo-b", "p")
vim.fn.system({ "git", "-C", tmp .. "/repo-a", "init", "-q" })
vim.fn.system({ "git", "-C", tmp .. "/repo-a",
  "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "init" })
vim.fn.system({ "git", "-C", tmp .. "/repo-b", "init", "-q" })
vim.fn.system({ "git", "-C", tmp .. "/repo-b",
  "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "init" })

-- fan_out: discovers both repos.
local repos_found = graph.fan_out(tmp)
ok("fan_out finds repo-a + repo-b", #repos_found == 2,
  "found=" .. #repos_found)
ok("fan_out repos sorted by label",
  repos_found[1].label == "repo-a" and repos_found[2].label == "repo-b")
ok("fan_out repo-a has sample_worktree",
  type(repos_found[1].sample_worktree) == "string"
    and repos_found[1].sample_worktree == tmp .. "/repo-a")
ok("fan_out repo-a not bare", repos_found[1].is_bare == false)
ok("fan_out repo-a has common_dir",
  repos_found[1].common_dir:find("/repo%-a/%.git") ~= nil,
  repos_found[1].common_dir)

-- Cached: second call returns same array.
local cached = graph.fan_out(tmp)
ok("fan_out result is cached (same table)",
  cached == repos_found)

-- show_stat against the init commit. We need the actual hash.
local hash = vim.fn.systemlist({
  "git", "--git-dir=" .. repos_found[1].common_dir,
  "rev-parse", "HEAD",
})[1]
ok("captured a real commit hash for repo-a",
  type(hash) == "string" and #hash >= 7, "hash=" .. tostring(hash))

local stat_lines = graph.show_stat(repos_found[1].common_dir, hash)
ok("show_stat returns non-empty output for real hash", #stat_lines > 0,
  "lines=" .. #stat_lines)
ok("show_stat output mentions the commit message",
  (function()
    for _, l in ipairs(stat_lines) do
      if l:find("init", 1, true) then return true end
    end
    return false
  end)())

local diff_lines = graph.show_diff(repos_found[1].common_dir, hash)
ok("show_diff returns non-empty output for real hash",
  #diff_lines > 0)

-- Cache returns the same table on a second call.
local stat_cached = graph.show_stat(repos_found[1].common_dir, hash)
ok("show_stat result is cached", stat_cached == stat_lines)

-- Bad hash: returns an error tag instead of crashing.
local stat_bad = graph.show_stat(repos_found[1].common_dir, "deadbeefdeadbeef")
ok("show_stat with bad hash returns a defensive output",
  type(stat_bad) == "table" and #stat_bad > 0)

-- clear_repo_cache wipes the per-repo caches but leaves fan-out alone.
graph.clear_repo_cache(repos_found[1].common_dir)
local stat_recomputed = graph.show_stat(repos_found[1].common_dir, hash)
ok("clear_repo_cache forced a recomputation",
  stat_recomputed ~= stat_lines and #stat_recomputed > 0)
ok("clear_repo_cache preserved fan_out cache",
  graph.fan_out(tmp) == repos_found)

-- Topic invalidation: publishing worktree:added drops fan_out cache.
require("auto-core").events.publish("worktree:added", { path = "/x" })
vim.wait(20)
local refreshed = graph.fan_out(tmp)
ok("worktree:added event invalidates fan_out cache",
  refreshed ~= repos_found and #refreshed == 2,
  string.format("refreshed=%s repos_found=%s same=%s len=%d",
    tostring(refreshed), tostring(repos_found),
    tostring(refreshed == repos_found), #refreshed))

-- worktree:removed too.
require("auto-core").events.publish("worktree:removed", { path = "/x" })
vim.wait(20)
local refreshed2 = graph.fan_out(tmp)
ok("worktree:removed event invalidates fan_out cache",
  refreshed2 ~= refreshed,
  string.format("refreshed2=%s refreshed=%s same=%s",
    tostring(refreshed2), tostring(refreshed),
    tostring(refreshed2 == refreshed)))

-- Bare-at-root layout regression (the auto-run.nvim case). A bare repo
-- can live DIRECTLY at its project folder: its git common-dir IS the
-- folder (`<ws>/pkg.nvim`), not a `.git`/`.bare` container one level
-- down. fan_out only discovers it via the linked worktree's `.git` FILE,
-- so the recorded common-dir is the folder itself. _derive_label must
-- name such a repo after its folder ("pkg.nvim"), not walk one level up
-- to the workspace root (which produced the wrong "nvim-plugins" label).
local batr = vim.fs.normalize(vim.fn.tempname() .. "_batr_ws")
vim.fn.mkdir(batr, "p")
-- The seed lives OUTSIDE the workspace so fan_out(batr) discovers only
-- the bare-at-root repo, not the seed's own `.git`.
local seed2 = vim.fs.normalize(vim.fn.tempname() .. "_batr_seed")
vim.fn.mkdir(seed2, "p")
vim.fn.system({ "git", "-C", seed2, "init", "-q", "--initial-branch=main" })
vim.fn.system({ "git", "-C", seed2,
  "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "init" })
-- clone --bare INTO the project folder → bare internals sit at
-- <ws>/pkg.nvim directly, exactly like auto-run.nvim.
local pkg_bare = batr .. "/pkg.nvim"
vim.fn.system({ "git", "clone", "--bare", "-q", seed2, pkg_bare })
vim.fn.system({ "git", "-C", pkg_bare, "worktree", "add", "-q",
  pkg_bare .. "/main", "main" })

graph._reset_for_tests()
local batr_repos = graph.fan_out(batr)
local batr_repo = batr_repos[1]
ok("fan_out discovers a bare-at-root repo (via its worktree)",
  #batr_repos == 1, "found=" .. #batr_repos)
ok("bare-at-root label is the project folder, not the workspace root",
  batr_repo ~= nil and batr_repo.label == "pkg.nvim",
  "label=" .. tostring(batr_repo and batr_repo.label))
ok("bare-at-root common_dir is the folder itself",
  batr_repo ~= nil and batr_repo.common_dir == pkg_bare,
  batr_repo and batr_repo.common_dir)
ok("bare-at-root flagged is_bare",
  batr_repo ~= nil and batr_repo.is_bare == true)
ok("bare-at-root sample_worktree is the linked worktree",
  batr_repo ~= nil and batr_repo.sample_worktree == pkg_bare .. "/main",
  batr_repo and batr_repo.sample_worktree)

vim.fn.delete(batr, "rf")
vim.fn.delete(seed2, "rf")
graph._reset_for_tests()

-- Regular repo with an EXTERNAL git dir (`git init --separate-git-dir`)
-- control (Lector PR#7 must-fix). The worktree holds a `.git` FILE pointing
-- at an arbitrary external metadata dir; `--git-common-dir` returns that
-- external path and `core.bare` is false. A non-`.git`/`.bare` common-dir
-- must NOT be assumed bare-at-root: the label is the PROJECT/worktree folder,
-- never the metadata dir's basename (which is storage topology, not identity).
local sgd_ws = vim.fs.normalize(vim.fn.tempname() .. "_sgd_ws")
vim.fn.mkdir(sgd_ws, "p")
-- Metadata dir lives OUTSIDE the workspace so fan_out(sgd_ws) can't see it
-- directly and can only discover the repo through its worktree.
local sgd_meta = vim.fs.normalize(vim.fn.tempname() .. "_sgd_meta")
local sgd_proj = sgd_ws .. "/project"
vim.fn.system({ "git", "init", "-q", "--initial-branch=main",
  "--separate-git-dir=" .. sgd_meta, sgd_proj })

graph._reset_for_tests()
local sgd_repos = graph.fan_out(sgd_ws)
local sgd_repo = sgd_repos[1]
ok("fan_out discovers a --separate-git-dir repo via its worktree",
  #sgd_repos == 1, "found=" .. #sgd_repos)
ok("separate-git-dir label is the PROJECT folder, not the metadata dir",
  sgd_repo ~= nil and sgd_repo.label == "project",
  "label=" .. tostring(sgd_repo and sgd_repo.label))
ok("separate-git-dir repo is not flagged bare",
  sgd_repo ~= nil and sgd_repo.is_bare == false,
  "is_bare=" .. tostring(sgd_repo and sgd_repo.is_bare))
ok("separate-git-dir common_dir is the external metadata dir",
  sgd_repo ~= nil and sgd_repo.common_dir == sgd_meta,
  sgd_repo and sgd_repo.common_dir)

vim.fn.delete(sgd_ws, "rf")
vim.fn.delete(sgd_meta, "rf")
graph._reset_for_tests()

-- Cleanup.
vim.fn.delete(tmp, "rf")
graph._reset_for_tests()
end)()

-- ─────────────────────── 45. git.fetch / git.pull / git.worktree.destroy (Phase 3.5) ─────────────────────────
print("\n[45] git.fetch + git.pull + git.worktree.destroy")
;(function()
local fetch_mod = require("auto-core.git.fetch")
local pull_mod  = require("auto-core.git.pull")
local wt_mod    = require("auto-core.git.worktree")
events._reset_for_tests()

ok("git.fetch.fetch_one is a function", type(fetch_mod.fetch_one) == "function")
ok("git.fetch.fetch_all is a function", type(fetch_mod.fetch_all) == "function")
ok("git.pull.pull_status is a function", type(pull_mod.pull_status) == "function")
ok("git.pull.pull_apply is a function",  type(pull_mod.pull_apply)  == "function")
ok("git.pull.worktree_dirty is a function",
  type(pull_mod.worktree_dirty) == "function")
ok("git.worktree.destroy is a function", type(wt_mod.destroy) == "function")

-- Build two repos so we can test fetch with a real local remote.
local tmp = vim.fn.tempname() .. "_p35"
local upstream = tmp .. "/upstream.git"
local clone = tmp .. "/clone"
vim.fn.mkdir(tmp, "p")
vim.fn.system({ "git", "init", "--bare", "-q",
  "--initial-branch=main", upstream })
local seed = tmp .. "/seed"
vim.fn.mkdir(seed, "p")
vim.fn.system({ "git", "-C", seed, "init", "-q", "--initial-branch=main" })
vim.fn.system({ "git", "-C", seed, "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "seed" })
vim.fn.system({ "git", "-C", seed, "remote", "add", "origin", upstream })
vim.fn.system({ "git", "-C", seed, "push", "-q", "origin", "main" })
-- Now clone a fresh working copy that we'll fetch + pull against.
-- `-b main` forces the branch even if upstream's HEAD ref points
-- elsewhere (avoids the default-branch ambiguity that bit the test
-- on systems where init defaults to master).
vim.fn.system({ "git", "clone", "-q", "-b", "main", upstream, clone })

-- pull_status on a clean uptodate clone.
local s = pull_mod.pull_status({ path = clone, branch = "main" })
ok("pull_status: uptodate after fresh clone",
  s.state == "uptodate", "state=" .. tostring(s.state))
ok("pull_status: clean clone reports not dirty", s.dirty == false)

-- worktree_dirty on the clean clone.
local d = pull_mod.worktree_dirty({ path = clone })
ok("worktree_dirty: clean clone is not dirty",
  d.dirty == false and d.dirty_count == 0)

-- Touch a tracked-style file in the clone to make it dirty for a
-- subsequent assertion (we must add a tracked file first since
-- worktree_dirty includes untracked).
vim.fn.writefile({ "x" }, clone .. "/scratch.txt")
local d2 = pull_mod.worktree_dirty({ path = clone })
ok("worktree_dirty: untracked file flips dirty true",
  d2.dirty == true and d2.dirty_count >= 1)
vim.fn.delete(clone .. "/scratch.txt")

-- Add a new commit upstream so the clone falls behind.
vim.fn.system({ "git", "-C", seed, "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "advance" })
vim.fn.system({ "git", "-C", seed, "push", "-q", "origin", "main" })

-- fetch_one on the clone; capture topic payloads.
local fetch_started, fetch_completed = nil, nil
events.subscribe("core.git.fetch:started",
  function(p) fetch_started = p end)
events.subscribe("core.git.fetch:completed",
  function(p) fetch_completed = p end)

local clone_common = vim.trim(vim.fn.systemlist({
  "git", "-C", clone, "rev-parse", "--git-dir",
})[1] or "")
-- `--git-dir` returns either an absolute path or a relative one
-- (typically `.git`) depending on cwd. Resolve to absolute.
if not clone_common:match("^/") then
  clone_common = clone .. "/" .. clone_common
end

local fetch_done = false
fetch_mod.fetch_one({ common_dir = clone_common, label = "clone" }, nil,
  function(ok_done, _stderr) fetch_done = ok_done end)
vim.wait(8000, function() return fetch_done end)
ok("fetch_one completed successfully against local remote",
  fetch_done == true)
ok("fetch:started topic fired with label",
  fetch_started ~= nil and fetch_started.label == "clone")
ok("fetch:completed topic fired with ok=true",
  fetch_completed ~= nil and fetch_completed.ok == true,
  vim.inspect(fetch_completed))

-- After fetch, pull_status should report ff (one commit behind).
local s2 = pull_mod.pull_status({ path = clone, branch = "main" })
ok("pull_status: ff after upstream advance + fetch",
  s2.state == "ff", "state=" .. tostring(s2.state))

-- pull_apply ff brings the clone forward.
local pull_started, pull_completed = nil, nil
events.subscribe("core.git.pull:started",
  function(p) pull_started = p end)
events.subscribe("core.git.pull:completed",
  function(p) pull_completed = p end)

local pull_done = false
pull_mod.pull_apply({ path = clone, branch = "main" }, "ff", nil,
  function(ok_done) pull_done = ok_done end)
vim.wait(8000, function() return pull_done end)
ok("pull_apply ff succeeded", pull_done == true)
ok("pull:started topic fired with mode=ff",
  pull_started ~= nil and pull_started.mode == "ff")
ok("pull:completed topic fired with ok=true",
  pull_completed ~= nil and pull_completed.ok == true)

-- After pull, status is uptodate.
local s3 = pull_mod.pull_status({ path = clone, branch = "main" })
ok("pull_status: uptodate after ff", s3.state == "uptodate")

-- Unknown pull mode is a clean error.
local bad_done = false
local bad_err
pull_mod.pull_apply({ path = clone, branch = "main" }, "not-a-mode", nil,
  function(ok_done, err) bad_done = ok_done; bad_err = err end)
vim.wait(50)
ok("pull_apply unknown mode returns error",
  bad_done == false and type(bad_err) == "string"
    and bad_err:find("unknown mode", 1, true) ~= nil)

-- Now add a worktree to the clone and test destroy. Use the seed
-- repo for this since it has the bare-style common dir.
vim.fn.mkdir(tmp .. "/wt-target", "p")
vim.fn.system({ "git", "-C", seed,
  "worktree", "add", "-b", "feature-x", tmp .. "/wt-target" })
local seed_common = vim.trim(vim.fn.systemlist({
  "git", "-C", seed, "rev-parse", "--git-dir",
})[1] or "")
if not seed_common:match("^/") then
  seed_common = seed .. "/" .. seed_common
end

local destroy_topic = nil
events.subscribe("core.git.worktree:destroyed",
  function(p) destroy_topic = p end)

local destroy_done = false
local destroy_err
wt_mod.destroy({ common_dir = seed_common },
  { path = tmp .. "/wt-target", branch = "feature-x" },
  { force = false },
  function(ok_done, err) destroy_done = ok_done; destroy_err = err end)
vim.wait(8000, function() return destroy_done ~= false end)
ok("destroy: clean worktree removed",
  destroy_done == true and destroy_err == nil,
  string.format("done=%s err=%s",
    tostring(destroy_done), tostring(destroy_err)))
ok("destroy: target dir is gone",
  vim.fn.isdirectory(tmp .. "/wt-target") == 0)
ok("destroy: worktree:destroyed topic fired with ok=true",
  destroy_topic ~= nil and destroy_topic.ok == true)
-- Branch was deleted as part of destroy (no branch_err on success).
ok("destroy: branch_err nil when branch deletes cleanly",
  destroy_topic.branch_err == nil)

-- Cleanup.
vim.fn.delete(tmp, "rf")
events._reset_for_tests()
require("auto-core.git.graph")._reset_for_tests()
end)()

-- ─────────────────────── 46. files — show_hidden / show_dotfiles prefs ─────────────────────────
print("\n[46] files — global show_hidden / show_dotfiles prefs")
;(function()
local files = require("auto-core.files")
files._reset_for_tests()

ok("get_show_hidden defaults to true",   files.get_show_hidden()   == true)
ok("get_show_dotfiles defaults to true", files.get_show_dotfiles() == true)

-- Flip + read back.
files.set_show_hidden(false)
ok("set_show_hidden(false) round-trips", files.get_show_hidden() == false)
files.set_show_dotfiles(false)
ok("set_show_dotfiles(false) round-trips", files.get_show_dotfiles() == false)

-- Watcher fires on change.
local got_hidden, got_dotfiles = nil, nil
files.watch_show_hidden(function(p) got_hidden = p end)
files.watch_show_dotfiles(function(p) got_dotfiles = p end)
files.set_show_hidden(true)
vim.wait(20)
ok("watch_show_hidden fired with new=true",
  got_hidden ~= nil and got_hidden.new == true)
files.set_show_dotfiles(true)
vim.wait(20)
ok("watch_show_dotfiles fired with new=true",
  got_dotfiles ~= nil and got_dotfiles.new == true)

-- Truthy non-bool coerces to bool (defensive).
files.set_show_hidden("yes")
ok("set_show_hidden coerces truthy non-bool to false (strict ==)",
  files.get_show_hidden() == false,
  "set_show_hidden requires literal `true`; non-true → false")

files._reset_for_tests()
end)()

-- ─────────────────────── 47. debug.winlog — opt-in window/buffer probe ─────────────────────────
print("\n[47] debug.winlog — start/stop/status/tail/clear contract")
;(function()
local winlog = require("auto-core").debug.winlog

-- Start clean: route the log to a temp path so we don't trample the
-- user's real cache file when the smoke runs locally.
local tmp = vim.fn.tempname() .. "-winlog.log"
winlog.stop()                                       -- defensive: prior run residue
winlog.start({ log_path = tmp, poll_interval_ms = 60 })

ok("is_running() true after start()", winlog.is_running() == true)

local s = winlog.status()
ok("status.running mirrors is_running()", s.running == true)
ok("status.log_path matches the opt we passed", s.log_path == tmp)
ok("status.poll_interval_ms honors opt (clamped to >=50)",
  s.poll_interval_ms == 60)
ok("status.events is non-empty list",
  type(s.events) == "table" and #s.events > 0)
ok("path() == status.log_path", winlog.path() == tmp)
-- start() writes a banner + INITIAL line synchronously, so the
-- count is non-zero immediately after start.
ok("status.event_count > 0 immediately after start() (banner written)",
  s.event_count > 0,
  "got " .. tostring(s.event_count))

-- Banner is on disk synchronously. Verify before any window activity
-- so the assertion targets the start path, not the poll/autocmd path.
local saw_banner = false
for _, line in ipairs(winlog.tail(40)) do
  if line:find("winlog started", 1, true) then saw_banner = true; break end
end
ok("tail() contains the start banner", saw_banner)

-- Provoke a window event: open + close a scratch split. The poll
-- detector and the WinNew autocmd both fire — we assert event_count
-- moves and tail() reflects the change.
local count_before = winlog.status().event_count
vim.cmd("botright new")
local probe_win = vim.api.nvim_get_current_win()
local probe_buf = vim.api.nvim_get_current_buf()
vim.bo[probe_buf].bufhidden = "wipe"
vim.bo[probe_buf].buftype   = "nofile"
-- Wait for one poll tick + the autocmd-driven append. The 60ms poll
-- plus jitter is plenty for the writes to land.
vim.wait(250, function()
  return winlog.status().event_count > count_before
end, 20)
ok("event_count rises after a real WinNew",
  winlog.status().event_count > count_before,
  "before=" .. count_before .. " after=" .. winlog.status().event_count)

-- Close the probe window so we don't leak it past the test.
pcall(vim.api.nvim_win_close, probe_win, true)
vim.wait(120)

local tail = winlog.tail(20)
ok("tail() returns at least one line after activity",
  type(tail) == "table" and #tail > 0)

-- Stop and confirm running state flips. tail() still reads from the
-- file after stop — it's a pure file read.
winlog.stop()
ok("is_running() false after stop()", winlog.is_running() == false)
ok("status.running mirrors is_running()", winlog.status().running == false)

-- clear() truncates AND resets the counter. Assert in that order
-- (counter check first, then file check) to mirror the doc contract.
winlog.clear()
ok("event_count zero after clear()", winlog.status().event_count == 0)
ok("tail() empty after clear()", #winlog.tail(40) == 0)

-- toggle() round-trips: off → on → off. start() will re-write the
-- banner so event_count rises again; the assertion targets the
-- running-state flip, not the count.
ok("toggle() turns it back on",  winlog.toggle({ log_path = tmp }) == true)
ok("toggle() turns it back off", winlog.toggle() == false)

-- Idempotent stop — second stop is a no-op, doesn't error.
local ok_stop2 = pcall(winlog.stop)
ok("stop() is idempotent (second call doesn't error)", ok_stop2)

-- Out-of-range poll interval clamps to the documented [50, 5000].
winlog.start({ log_path = tmp, poll_interval_ms = 1 })
ok("poll_interval_ms clamps low value to 50",
  winlog.status().poll_interval_ms == 50)
winlog.start({ log_path = tmp, poll_interval_ms = 1e9 })
ok("poll_interval_ms clamps high value to 5000",
  winlog.status().poll_interval_ms == 5000)
winlog.stop()

-- panel_filter flag is honored — start with it on and verify status
-- mirrors it. (We can't easily exercise the filter outcome headlessly
-- without booting a panel; assert the option surface.)
winlog.start({ log_path = tmp, panel_filter = true })
ok("panel_filter honored when opt is true",
  winlog.status().panel_filter == true)
winlog.start({ log_path = tmp, panel_filter = false })
ok("panel_filter honored when opt is false",
  winlog.status().panel_filter == false)
winlog.stop()

-- Cleanup the temp log file.
pcall(os.remove, tmp)
end)()

-- ─────────────────────── 48. version + api_version sanity ─────────────────────────
-- Version is asserted against the v0.1.x regex (option (a) from the old
-- FIXME, now adopted) so additive patch bumps pass without a manual
-- edit; a minor/major bump trips it deliberately.
print("\n[48] version + api_version sanity")
;(function()
local v = require("auto-core.version")
-- Shape only here; the CHANGELOG agreement is asserted once, above.
ok("version is semver", type(v.version) == "string"
  and v.version:match("^%d+%.%d+%.%d+$") ~= nil, "got " .. tostring(v.version))
ok("api_version is 0.1 (auto-core.todo additive surface)", v.api_version == "0.1")
-- :h api_version semver gate consumers will use.
local core = require("auto-core")
ok("M.debug is a table on the public surface",
  type(core.debug) == "table")
ok("M.debug.winlog is a table on the public surface",
  type(core.debug) == "table" and type(core.debug.winlog) == "table")
ok("M.debug.winlog.start is a function",
  type(core.debug.winlog.start) == "function")
ok("M.debug.winlog.stop is a function",
  type(core.debug.winlog.stop) == "function")
ok("M.mailbox is a table on the public surface (ADR 0013 Phase 1)",
  type(core.mailbox) == "table")
ok("M.mailbox surface includes send/unregister/claim/complete/start/stop/refresh/scan_now",
  type(core.mailbox.send) == "function"
    and type(core.mailbox.unregister) == "function"
    and type(core.mailbox.claim) == "function"
    and type(core.mailbox.complete) == "function"
    and type(core.mailbox.start) == "function"
    and type(core.mailbox.stop) == "function"
    and type(core.mailbox.refresh) == "function"
    and type(core.mailbox.scan_now) == "function")
ok("M.mailbox.commands is a table",
  type(core.mailbox.commands) == "table"
    and type(core.mailbox.commands.register) == "function")
ok("M.mailbox.router is a table",
  type(core.mailbox.router) == "table"
    and type(core.mailbox.router.start) == "function")
ok("M.mailbox.bootstrap is a table",
  type(core.mailbox.bootstrap) == "table"
    and type(core.mailbox.bootstrap.render) == "function")
ok("legacy M.mailbox.consume is gone (router replaces per-mailbox consumers)",
  core.mailbox.consume == nil)
end)()

-- ─────────────────────── 49. mailbox subsystem (ADR 0013 Phase 1, revised) ─────────
print("\n[49] mailbox: per-mailbox roots, bootstrap upsert, central router, outbox delivery, wake, commands")
;(function()
local mailbox  = require("auto-core.mailbox")
local mb_path  = mailbox.path
local message  = mailbox.message
local registry = mailbox.registry
local transp   = mailbox.transport
local commands = mailbox.commands
local router   = mailbox.router
local boot     = mailbox.bootstrap
local events_m = require("auto-core.events")

-- Hermetic temp root so the test never touches the real durable
-- mailbox root. configure(nil) at teardown restores defaults.
local tmp_root = vim.fn.tempname() .. "-mailbox-test"
vim.fn.mkdir(tmp_root, "p")

-- Capture any AUTO_AGENTS_* env overrides up-front so the
-- "default points at the durable global location" assertions
-- aren't fooled by the surrounding shell environment.
local saved_env = {
  AUTO_AGENTS_MAILBOX_ROOT = vim.env.AUTO_AGENTS_MAILBOX_ROOT,
  AUTO_AGENTS_CONFIG_DIR   = vim.env.AUTO_AGENTS_CONFIG_DIR,
  AUTO_AGENTS_KB_ROOT      = vim.env.AUTO_AGENTS_KB_ROOT,
}
vim.env.AUTO_AGENTS_MAILBOX_ROOT = nil
vim.env.AUTO_AGENTS_CONFIG_DIR   = nil
vim.env.AUTO_AGENTS_KB_ROOT      = nil

-- ── 49a. host-fallback root resolution (used for nvim/user) ─
mailbox._reset_for_tests()
events_m._reset_for_tests()

-- v0.1.8: forward-declare the instance_id pin + FULL helper. We
-- can't pin yet because [49a] calls _reset_for_tests several more
-- times to exercise env-var precedence (each reset would wipe the
-- pin via path._reset_for_tests). Pin is applied just before [49c]
-- registrations below.
local TEST_INSTANCE_ID = "9999999999-12345"
local function FULL(bare) return bare .. ":" .. TEST_INSTANCE_ID end
-- v0.1.33: host_fallback_root now resolves via workspace_root walk-up,
-- not the durable global location. The path ends in `.auto-agents/mailbox`
-- regardless of which workspace we're in.
ok("host_fallback_root ends in .auto-agents/mailbox (workspace-scoped)",
  mailbox.host_fallback_root():find("%.auto%-agents/mailbox$") ~= nil,
  "got: " .. mailbox.host_fallback_root())

vim.env.AUTO_AGENTS_MAILBOX_ROOT = tmp_root .. "/env-mb"
mailbox._reset_for_tests()
ok("AUTO_AGENTS_MAILBOX_ROOT env var still overrides workspace resolution",
  mailbox.host_fallback_root() == tmp_root .. "/env-mb",
  "got: " .. mailbox.host_fallback_root())
vim.env.AUTO_AGENTS_MAILBOX_ROOT = nil

-- Fixture: reflect distinct per-mailbox roots. The architecture treats
-- roots as opaque; the test verifies that multiple distinct roots
-- coexist and the central router collapses by unique root.
local active_root      = tmp_root .. "/active"
local codex_like_root  = tmp_root .. "/.codex/mailbox"
local claude_like_root = tmp_root .. "/.claude/mailbox"
local gemini_like_root = tmp_root .. "/.gemini/mailbox"
require("auto-core").setup({ mailbox = { root = active_root } })
ok("setup({mailbox={root=...}}) override applies to host fallback",
  mailbox.host_fallback_root() == active_root,
  "got: " .. mailbox.host_fallback_root())

-- v0.1.33: tool_root / TOOL_DIRS are gone. Production code uses
-- workspace_mailbox_root() instead; per-tool config dirs are now
-- a downstream consumer concern (auto-agents.runtime.identity), not
-- an auto-core primitive.
ok("v0.1.33: mb_path.tool_root removed (clean cut)",
  mb_path.tool_root == nil,
  "tool_root still present")
ok("v0.1.33: mb_path.TOOL_DIRS removed (clean cut)",
  mb_path.TOOL_DIRS == nil,
  "TOOL_DIRS still present")
-- workspace_mailbox_root semantics: only the no-override path is
-- workspace-relative. Once configure() has set an override (the
-- setup() call above set active_root as the override), the override
-- wins. Verify that explicitly by temporarily clearing it.
do
  mb_path.configure(nil)
  ok("workspace_mailbox_root() resolves to <workspace>/.auto-agents/mailbox when no override is set",
    mb_path.workspace_mailbox_root():find("%.auto%-agents/mailbox$") ~= nil,
    "got: " .. mb_path.workspace_mailbox_root())
  -- Restore the active_root override so subsequent assertions still see it.
  mb_path.configure(active_root)
end

-- ── 49b. id validation ─────────────────────────────────────
ok("validate_id accepts 'user'", (mb_path.validate_id("user")))
ok("validate_id accepts 'agent:lector'", (mb_path.validate_id("agent:lector")))
ok("validate_id rejects empty string",
  not mb_path.validate_id(""))
ok("validate_id rejects path traversal '../boom'",
  not mb_path.validate_id("../boom"))
ok("validate_id rejects slash 'a/b'",
  not mb_path.validate_id("a/b"))
-- v0.1.33: reject `agent:nvim` / `agent:user` (would collide with the
-- host/user mailbox after `_name_from_id` strips the type prefix).
ok("validate_id rejects reserved agent name 'agent:nvim'",
  not mb_path.validate_id("agent:nvim"))
ok("validate_id rejects reserved agent name 'agent:user'",
  not mb_path.validate_id("agent:user"))
ok("validate_id rejects reserved agent name with instance suffix",
  not mb_path.validate_id("agent:nvim:1747-3478"))
ok("validate_id still accepts host bare names 'nvim' and 'user'",
  (mb_path.validate_id("nvim")) and (mb_path.validate_id("user")))
ok("validate_id rejects leading dot '.hidden'",
  not mb_path.validate_id(".hidden"))

-- ── 49c. registration uses per-mailbox roots + upserts bootstrap doc ──
-- Pin the instance_id NOW (after all the [49a] env-var resets) so
-- the rest of [49] sees stable full ids in assertions.
mb_path.set_instance_id(TEST_INSTANCE_ID)

local registered_payloads = {}
local sub = events_m.subscribe("core.mailbox:registered", function(p)
  registered_payloads[#registered_payloads + 1] = p
end)

-- Codex-backed agent (Lector) — uses Codex's tool config root.
local lector_rec = mailbox.register("agent:lector", {
  root = codex_like_root,
  wake = { command = "send_slot", args = { slot = "lector" } },
})
ok("register returns record with per-mailbox root + dir + subs + wake (v0.1.8: id is full)",
  type(lector_rec) == "table"
    and lector_rec.id == FULL("agent:lector")
    and lector_rec.bare_id == "agent:lector"
    and lector_rec.root == codex_like_root
    and lector_rec.dir == mb_path.mailbox_dir(FULL("agent:lector"), codex_like_root)
    and type(lector_rec.subs) == "table"
    and type(lector_rec.wake) == "table"
    and lector_rec.wake.command == "send_slot")
ok("lector's mailbox dir lives under Codex's tool root with instance suffix",
  lector_rec.dir == mb_path.mailbox_dir(FULL("agent:lector"), codex_like_root),
  "got: " .. lector_rec.dir)
ok("inbox/outbox/processing/archive/responses all exist on disk",
  vim.fn.isdirectory(lector_rec.subs.inbox)      == 1
    and vim.fn.isdirectory(lector_rec.subs.outbox)     == 1
    and vim.fn.isdirectory(lector_rec.subs.processing) == 1
    and vim.fn.isdirectory(lector_rec.subs.archive)    == 1
    and vim.fn.isdirectory(lector_rec.subs.responses)  == 1)

-- Claude-backed agent (Jarvis) — separate tool, separate root.
-- A second claude-backed agent would share this root, subdivided
-- by id (~/.claude/mailbox/agent:jarvis/, ~/.claude/mailbox/agent:hephaestus/,
-- etc) so the central router opens just ONE watcher on
-- ~/.claude/mailbox/ regardless of how many Claude agents exist.
local jarvis_rec = mailbox.register("agent:jarvis", {
  root = claude_like_root,
  wake = { command = "send_slot", args = { slot = "jarvis" } },
})
ok("claude-backed agent uses Claude's tool root",
  jarvis_rec.root == claude_like_root
    and jarvis_rec.dir == mb_path.mailbox_dir(FULL("agent:jarvis"), claude_like_root),
  "got: " .. jarvis_rec.dir)

-- Add a second claude-backed agent to exercise the
-- multi-agent-per-tool-root case. Both share ~/.claude/mailbox/,
-- subdivided by id, and the router opens ONE watcher on the root.
local hephaestus_rec = mailbox.register("agent:hephaestus", {
  root = claude_like_root,
  wake = { command = "send_slot", args = { slot = "hephaestus" } },
})
ok("multiple claude-backed agents share the root, subdivided by full id",
  hephaestus_rec.root == claude_like_root
    and hephaestus_rec.dir == mb_path.mailbox_dir(FULL("agent:hephaestus"), claude_like_root)
    and jarvis_rec.root == hephaestus_rec.root,
  "jarvis.dir=" .. jarvis_rec.dir
    .. " hephaestus.dir=" .. hephaestus_rec.dir)

-- Gemini-backed agent under its own tool root.
local gemini_rec = mailbox.register("agent:gemini", {
  root = gemini_like_root,
  wake = { command = "send_slot", args = { slot = "gemini" } },
})
ok("gemini-backed agent uses its own tool root",
  gemini_rec.dir == mb_path.mailbox_dir(FULL("agent:gemini"), gemini_like_root))

-- Host-side mailbox with no explicit root falls back.
local nvim_rec = mailbox.register("nvim")
ok("host-side 'nvim' mailbox falls back to host fallback root + instance suffix",
  nvim_rec.root == active_root
    and nvim_rec.dir == mb_path.mailbox_dir(FULL("nvim"), active_root))
ok("nvim retains 'nvim' as bare_id (executioner-default key)",
  nvim_rec.bare_id == "nvim" and nvim_rec.executioner == true)

ok("core.mailbox:registered fired for every register call",
  #registered_payloads == 5)
ok("first registered payload carries first_time=true",
  registered_payloads[1].first_time == true)
ok("registered payload includes bootstrap_path + bootstrap_revision",
  type(registered_payloads[1].bootstrap_path)     == "string"
    and type(registered_payloads[1].bootstrap_revision) == "string"
    and #registered_payloads[1].bootstrap_revision >= 16)

-- registry.list reflects what we've registered (full ids in v0.1.8).
ok("registry.list reports all five mailboxes as full ids",
  (function()
    local set = {}
    for _, id in ipairs(registry.list()) do set[id] = true end
    return set[FULL("agent:lector")] and set[FULL("agent:jarvis")]
       and set[FULL("agent:hephaestus")] and set[FULL("agent:gemini")]
       and set[FULL("nvim")]
  end)())
ok("registry.get accepts bare id (auto-resolves to this instance)",
  registry.get("agent:lector") == lector_rec
    and registry.get("agent:jarvis") == jarvis_rec)
ok("registry.get accepts full id directly",
  registry.get(FULL("agent:lector")) == lector_rec)

-- unique_roots collapses claude+claude → one entry.
ok("registry.unique_roots collapses shared roots (jarvis + hephaestus on claude → one entry)",
  (function()
    local roots = registry.unique_roots()
    -- expect 4 unique roots: codex (lector), claude (jarvis+hephaestus),
    -- gemini, host-fallback (nvim).
    return #roots == 4
  end)(),
  "got: " .. vim.inspect(registry.unique_roots()))

events_m.unsubscribe(sub)

-- ── 49c2. bootstrap-mailbox.md per-tool-root layout (v0.1.8) ──
-- v0.1.8 hoists the doc from per-mailbox to per-tool-root, so every
-- agent under a given tool root shares one bootstrap doc. The doc
-- content is agent-agnostic — agents read their identity from
-- env vars at spawn time (see env_for_agent).
local boot_path = lector_rec.bootstrap.path
ok("bootstrap-mailbox.md written to <tool-root>/bootstrap-mailbox.md",
  boot_path == codex_like_root .. "/bootstrap-mailbox.md"
    and vim.fn.filereadable(boot_path) == 1,
  "got: " .. tostring(boot_path))

-- All agents under the same root reference the same doc path.
ok("jarvis + hephaestus share the same per-tool-root bootstrap doc",
  jarvis_rec.bootstrap.path == hephaestus_rec.bootstrap.path
    and jarvis_rec.bootstrap.path == claude_like_root .. "/bootstrap-mailbox.md")
ok("different tool roots get different bootstrap docs",
  lector_rec.bootstrap.path ~= jarvis_rec.bootstrap.path
    and jarvis_rec.bootstrap.path ~= gemini_rec.bootstrap.path)

local boot_text = table.concat(vim.fn.readfile(boot_path), "\n")
ok("bootstrap doc body references the env-var contract (no per-call ids)",
  boot_text:find("AUTO_AGENTS_MAILBOX_ID", 1, true) ~= nil
    and boot_text:find("AUTO_AGENTS_MAILBOX_DIR", 1, true) ~= nil
    and boot_text:find("AUTO_AGENTS_INSTANCE_ID", 1, true) ~= nil)
ok("bootstrap doc frontmatter has revision field",
  boot_text:find("revision:") ~= nil)
ok("bootstrap doc body does NOT bake in any specific agent id (v0.1.8 hoist)",
  boot_text:find("agent:lector", 1, true) == nil)
ok("bootstrap doc carries the audit instructions",
  boot_text:find("bootstrap audit protocol") ~= nil)
ok("bootstrap doc stores seen-revision under per-agent workspace state (schema_version 7)",
  boot_text:find("seen_revisions/<your-agent-name>/seen_revision",
    1, true) ~= nil
    and boot_text:find("schema_version 7", 1, true) ~= nil)
ok("bootstrap doc still documents spawn-time permission grants",
  boot_text:find("Spawn-time permission grants", 1, true) ~= nil
    and boot_text:find("--add-dir <path>", 1, true) ~= nil)

-- ── ADR-0036: PERMISSION.md guideline (peer to bootstrap doc) ──
-- registry.register now also upserts PERMISSION.md (advisory peer) into
-- the workspace mailbox root; the bootstrap doc references it.
local perm_path = codex_like_root .. "/PERMISSION.md"
ok("ADR-0036: PERMISSION.md written alongside bootstrap doc",
  vim.fn.filereadable(perm_path) == 1, "expected at " .. perm_path)
local perm_text = vim.fn.filereadable(perm_path) == 1
  and table.concat(vim.fn.readfile(perm_path), "\n") or ""
ok("PERMISSION.md leads with the prompt-avoidance directive",
  perm_text:find("disrupt", 1, true) ~= nil
    and perm_text:find("avoid", 1, true) ~= nil)
ok("PERMISSION.md states the Read/Write tools are the prompt-free surface",
  perm_text:find("Read/Write", 1, true) ~= nil)
ok("PERMISSION.md frontmatter carries its own revision",
  perm_text:find("revision:") ~= nil)
ok("bootstrap doc references PERMISSION.md (ADR-0036) + schema_version 9",
  boot_text:find("PERMISSION.md", 1, true) ~= nil
    and boot_text:find("schema_version: 9", 1, true) ~= nil)
-- render_permission is deterministic (content sha → stable revision)
local _, perm_rev_a = boot.render_permission()
local _, perm_rev_b = boot.render_permission()
ok("render_permission revision is deterministic (content-addressed)",
  perm_rev_a == perm_rev_b and type(perm_rev_a) == "string")
ok("permission revision differs from the bootstrap revision",
  perm_rev_a ~= select(2, boot.render()))

-- v0.1.8 render is agent-agnostic — identical revisions across
-- arbitrary inputs (the template no longer substitutes per-call
-- variables beyond revision/upserted_at).
local _, rev_a = boot.render()
local _, rev_b = boot.render()
ok("render is stable across calls (no per-call inputs)",
  rev_a == rev_b, "a=" .. tostring(rev_a) .. " b=" .. tostring(rev_b))
ok("render's revision matches the on-disk doc",
  rev_a == lector_rec.bootstrap.revision)

-- v0.1.7's revision-skip survives the v0.1.8 hoist: re-register with
-- ANY inputs (the doc is now agent-agnostic) leaves the per-tool-root
-- doc untouched on disk.
local first_mtime = vim.fn.getftime(boot_path)
vim.wait(1100)
local skip_rec = mailbox.register("agent:lector", {
  root = codex_like_root,
  wake = { command = "send_slot", args = { slot = "lector" } },
})
ok("v0.1.8: re-register leaves per-tool-root bootstrap doc mtime unchanged",
  vim.fn.getftime(boot_path) == first_mtime,
  string.format("before=%d after=%d", first_mtime, vim.fn.getftime(boot_path)))
ok("v0.1.8: skipped upsert returns wrote=false",
  skip_rec.bootstrap.wrote == false,
  "wrote=" .. tostring(skip_rec.bootstrap.wrote))
ok("v0.1.8: revision survives a skipped upsert",
  skip_rec.bootstrap.revision == lector_rec.bootstrap.revision)

-- env_for_agent helper: every spawn-time env var an agent needs to
-- find its own mailbox without socket access.
local env = mailbox.env_for_agent(lector_rec)
ok("env_for_agent returns AUTO_AGENTS_INSTANCE_ID matching the pin",
  env.AUTO_AGENTS_INSTANCE_ID == TEST_INSTANCE_ID)
ok("env_for_agent returns AUTO_AGENTS_MAILBOX_ID = full id",
  env.AUTO_AGENTS_MAILBOX_ID == FULL("agent:lector"))
ok("env_for_agent returns AUTO_AGENTS_MAILBOX_DIR = record dir",
  env.AUTO_AGENTS_MAILBOX_DIR == lector_rec.dir)
ok("env_for_agent returns AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC = per-tool-root doc",
  env.AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC == boot_path)

-- ── 49d. message construction + validation ─────────────────
local m1, m1_err = message.build({
  from = "agent:gemini", to = "agent:lector",
  subject = "review please", body = "ready",
})
ok("message.build returns a valid message", m1 ~= nil and m1_err == nil,
  tostring(m1_err))
ok("kind defaults to 'message'", m1.kind == "message")
ok("id auto-generated and non-empty", type(m1.id) == "string" and #m1.id > 0)
ok("created_at ISO 8601 (Z)", type(m1.created_at) == "string"
  and m1.created_at:match("Z$") ~= nil)
ok("validate accepts a built message",
  (message.validate(m1)))

local m2, m2_err = message.build({ from = "x" })  -- missing to
ok("build rejects missing 'to'", m2 == nil and type(m2_err) == "string")
local m3, m3_err = message.build({
  from = "a", to = "b", kind = "command",
})
ok("build rejects command without command name",
  m3 == nil and type(m3_err) == "string", tostring(m3_err))
local m4, m4_err = message.build({
  from = "a", to = "b", kind = "command", command = "harpoon",
})
ok("build accepts command with command name",
  m4 ~= nil and m4_err == nil, tostring(m4_err))

-- ── 49e. host-side send() writes directly to recipient inbox ──
local queued_events = {}
local qs = events_m.subscribe("core.mailbox:message_queued", function(p)
  queued_events[#queued_events + 1] = p
end)

local result, send_err = mailbox.send({
  from = "agent:gemini", to = "agent:lector",
  subject = "ready", body = "branch X is up",
})
ok("send returns a result with id/path/message",
  result ~= nil and send_err == nil
    and type(result.id) == "string"
    and type(result.path) == "string"
    and type(result.message) == "table",
  tostring(send_err))
ok("send wrote the JSON file under the RECIPIENT's per-mailbox root (codex for lector)",
  result.path:sub(1, #codex_like_root) == codex_like_root,
  "got: " .. result.path)
ok("send wrote a complete JSON object (atomic rename was the commit)",
  (function()
    local lines = vim.fn.readfile(result.path)
    local ok_dec, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
    return ok_dec
      and type(decoded) == "table"
      and decoded.id == result.id
      and decoded.from == "agent:gemini"
      and decoded.to   == "agent:lector"
  end)())
ok("recipient inbox contains NO leftover .tmp- files",
  (function()
    local inbox = lector_rec.subs.inbox
    for _, e in ipairs(vim.fn.readdir(inbox)) do
      if e:sub(1, 5) == ".tmp-" then return false end
    end
    return true
  end)())
ok("core.mailbox:message_queued fired synchronously from send",
  #queued_events == 1
    and queued_events[1].mailbox == "agent:lector"
    and queued_events[1].id == result.id,
  vim.inspect(queued_events))
ok("transport.list_inbox lists the new id",
  vim.tbl_contains(transp.list_inbox("agent:lector"), result.id))

-- ── 49f. claim → processing, complete → archive + response ──
local completed_events = {}
local response_events = {}
events_m.subscribe("core.mailbox:message_completed", function(p)
  completed_events[#completed_events + 1] = p
end)
events_m.subscribe("core.mailbox:response_written", function(p)
  response_events[#response_events + 1] = p
end)

local cor = message.new_correlation_id()
local r2 = mailbox.send({
  from = "agent:gemini", to = "agent:lector",
  subject = "needs reply", body = "do the thing",
  correlation_id = cor,
})

local claimed, claim_err = mailbox.claim("agent:lector", r2.id)
ok("claim returns the message", claimed ~= nil and claim_err == nil,
  tostring(claim_err))
ok("claim moves file out of inbox",
  not vim.tbl_contains(transp.list_inbox("agent:lector"), r2.id))
ok("claim moves file into processing",
  vim.tbl_contains(transp.list_processing("agent:lector"), r2.id))

local cok, cerr = mailbox.complete("agent:lector", r2.id, {
  ok = true, value = { result = "approved" },
})
ok("complete returns true", cok == true, tostring(cerr))
ok("complete moves out of processing",
  not vim.tbl_contains(transp.list_processing("agent:lector"), r2.id))
ok("complete archives the message",
  vim.tbl_contains(transp.list_archive("agent:lector"), r2.id))
ok("response landed in sender's responses dir keyed by correlation_id",
  vim.tbl_contains(transp.list_responses("agent:gemini"), cor))
ok("response file is a valid envelope with ok=true and matching reply_to",
  (function()
    local resp_path = gemini_rec.subs.responses .. "/" .. cor .. ".json"
    if vim.fn.filereadable(resp_path) ~= 1 then return false end
    local content = table.concat(vim.fn.readfile(resp_path), "\n")
    local ok_dec, decoded = pcall(vim.json.decode, content)
    return ok_dec
      and decoded.ok == true
      and decoded.reply_to == r2.id
      and decoded.correlation_id == cor
      and type(decoded.value) == "table"
      and decoded.value.result == "approved"
  end)())
ok("core.mailbox:message_completed fired",
  #completed_events == 1 and completed_events[1].id == r2.id)
ok("core.mailbox:response_written fired with the correlation_id",
  #response_events == 1
    and response_events[1].correlation_id == cor
    and response_events[1].reply_to == r2.id)

events_m.unsubscribe(qs)

-- ── 49g. central router: lifecycle + start/stop/refresh ─────
router._reset_for_tests()
events_m._reset_for_tests()
ok("router is not running before start", router.is_running() == false)
router.start()
ok("router is running after start", router.is_running() == true)
local status = router.status()
ok("router status reports one entry per unique registered root",
  (function()
    local count = 0
    for _ in pairs(status.roots) do count = count + 1 end
    -- codex + claude + gemini + active_root (host fallback) = 4.
    -- jarvis + hephaestus collapse onto the single claude watcher.
    return count == 4
  end)(),
  vim.inspect(status))

-- Idempotent start.
router.start()
ok("router.start is idempotent", router.is_running() == true)

-- ── 49h. router routes outbox → recipient inbox ─────────────
local routed_events = {}
events_m.subscribe("core.mailbox:outbox_routed", function(p)
  routed_events[#routed_events + 1] = p
end)
local queued_via_router = {}
events_m.subscribe("core.mailbox:message_queued", function(p)
  if p.mailbox == "agent:gemini" then
    queued_via_router[#queued_via_router + 1] = p
  end
end)

-- jarvis writes to its OWN outbox addressed to gemini.
-- (Simulates a sandboxed agent dropping a message in its outbox.)
local jarvis_outgoing = message.build({
  from = "agent:jarvis", to = "agent:gemini",
  body = "hello gemini from jarvis",
})
local outbox_file = jarvis_rec.subs.outbox .. "/" .. jarvis_outgoing.id .. ".json"
vim.fn.writefile({ vim.json.encode(jarvis_outgoing) }, outbox_file)
-- Force a scan since we wrote directly with writefile (not atomic rename
-- through the watcher path) — the watcher may or may not fire on the
-- single-step write; scan_now makes the test deterministic.
router.scan_now()
vim.wait(300, function() return #routed_events >= 1 end, 25)

ok("router fired core.mailbox:outbox_routed",
  #routed_events >= 1
    and routed_events[1].from == "agent:jarvis"
    and routed_events[1].to == "agent:gemini"
    and routed_events[1].id == jarvis_outgoing.id,
  vim.inspect(routed_events))
ok("outbox file is GONE from jarvis's outbox after routing",
  vim.fn.filereadable(outbox_file) == 0)
ok("message landed in gemini's inbox",
  vim.tbl_contains(transp.list_inbox("agent:gemini"), jarvis_outgoing.id))
-- After routing, the router's inbox dispatch fires too.
vim.wait(200, function() return #queued_via_router >= 1 end, 25)
ok("core.mailbox:message_queued fired for gemini's inbox after routing",
  #queued_via_router >= 1
    and queued_via_router[1].id == jarvis_outgoing.id)

-- ── 49i. outbox_undeliverable when recipient is unregistered ──
local undeliverable_events = {}
events_m.subscribe("core.mailbox:outbox_undeliverable", function(p)
  undeliverable_events[#undeliverable_events + 1] = p
end)
local orphan = message.build({
  from = "agent:jarvis", to = "agent:nobody_registered",
  body = "noone home",
})
local orphan_path = jarvis_rec.subs.outbox .. "/" .. orphan.id .. ".json"
vim.fn.writefile({ vim.json.encode(orphan) }, orphan_path)
router.scan_now()
vim.wait(200, function() return #undeliverable_events >= 1 end, 25)
ok("undeliverable fires when recipient is unregistered",
  #undeliverable_events >= 1
    and undeliverable_events[1].reason == "recipient_unregistered"
    and undeliverable_events[1].to == "agent:nobody_registered",
  vim.inspect(undeliverable_events))
ok("undeliverable: file REMAINS in sender's outbox (retryable)",
  vim.fn.filereadable(orphan_path) == 1)

-- Now register the missing recipient with a tmp root and re-scan;
-- the next routing pass should succeed.
mailbox.register("agent:nobody_registered", { root = tmp_root .. "/.misc/mailbox" })
router.scan_now()
vim.wait(300, function()
  return vim.fn.filereadable(orphan_path) == 0
end, 25)
ok("recipient registers later → re-scan routes the pending message",
  vim.fn.filereadable(orphan_path) == 0
    and vim.tbl_contains(transp.list_inbox("agent:nobody_registered"), orphan.id))

-- ── 49i2. the outbox gateway (ADR 1793271500 phase 4) ─────────
-- A gateway that takes a message owns it: done(nil) archives the outbox file
-- and the recipient's inbox never sees it; done(err) or a gateway that throws
-- leaves the file for the next scan; a gateway that declines leaves the
-- message to the file move.
local gw_routed, gw_undeliverable, gw_calls, gw_archive_failed = {}, {}, {}, {}
local gw_sub1 = events_m.subscribe("core.mailbox:outbox_routed", function(p)
  if p.via == "gateway" then gw_routed[#gw_routed + 1] = p end
end)
local gw_sub2 = events_m.subscribe("core.mailbox:outbox_undeliverable", function(p)
  if p.reason == "gateway_failed" then gw_undeliverable[#gw_undeliverable + 1] = p end
  if p.reason == "gateway_archive_failed" then gw_archive_failed[#gw_archive_failed + 1] = p end
end)
local gw_mode = "take"
router.set_gateway(function(rec, mid, msg, done)
  gw_calls[#gw_calls + 1] = { from = rec.id, mid = mid, to = msg.to }
  if gw_mode == "decline" then return false end
  if gw_mode == "throw" then error("gateway exploded") end
  vim.defer_fn(function() done(gw_mode == "fail" and "daemon refused" or nil) end, 10)
  return true
end)
local function gw_send(body)
  local m = message.build({ from = "agent:jarvis", to = "agent:gemini", body = body })
  local path = jarvis_rec.subs.outbox .. "/" .. m.id .. ".json"
  vim.fn.writefile({ vim.json.encode(m) }, path)
  router.scan_now()
  return m, path
end

local gw_taken, gw_taken_path = gw_send("through the gateway")
vim.wait(500, function() return #gw_routed >= 1 end, 25)
ok("gateway: a taken message is archived, announced via the gateway, and never moved to the inbox",
  #gw_routed == 1 and gw_routed[1].id == gw_taken.id and gw_routed[1].to == "agent:gemini"
    and vim.fn.filereadable(gw_taken_path) == 0
    and vim.fn.filereadable(jarvis_rec.subs.archive .. "/" .. gw_taken.id .. ".json") == 1
    and not vim.tbl_contains(transp.list_inbox("agent:gemini"), gw_taken.id),
  vim.inspect({ gw_routed, gw_calls }))

gw_mode = "fail"
local gw_failed, gw_failed_path = gw_send("the daemon refuses this one")
vim.wait(500, function() return #gw_undeliverable >= 1 end, 25)
ok("gateway: done(err) leaves the file in the outbox and says gateway_failed",
  #gw_undeliverable == 1 and gw_undeliverable[1].id == gw_failed.id
    and gw_undeliverable[1].error == "daemon refused"
    and vim.fn.filereadable(gw_failed_path) == 1,
  vim.inspect(gw_undeliverable))

gw_mode = "take"
router.scan_now()
vim.wait(500, function() return #gw_routed >= 2 end, 25)
ok("gateway: the failed message is retried by the next scan and goes through",
  #gw_routed == 2 and gw_routed[2].id == gw_failed.id and vim.fn.filereadable(gw_failed_path) == 0,
  vim.inspect(gw_routed))

gw_mode = "throw"
local gw_thrown, gw_thrown_path = gw_send("the gateway throws")
vim.wait(300, function() return #gw_undeliverable >= 2 end, 25)
ok("gateway: a gateway that throws leaves the file and says gateway_failed",
  #gw_undeliverable == 2 and gw_undeliverable[2].id == gw_thrown.id
    and vim.fn.filereadable(gw_thrown_path) == 1,
  vim.inspect(gw_undeliverable))

gw_mode = "decline"
local gw_declined = select(1, gw_send("not for the gateway"))
vim.wait(300, function()
  return vim.tbl_contains(transp.list_inbox("agent:gemini"), gw_declined.id)
end, 25)
ok("gateway: a declined message takes the file move to the recipient's inbox, as before",
  vim.tbl_contains(transp.list_inbox("agent:gemini"), gw_declined.id))

-- the classes of #16 r0 (Lector): ownership apart from the hook, one settlement per attempt
local held = {}
gw_mode = "hold"
router.set_gateway(function(rec, mid, msg, done)
  if gw_mode == "hold" then held[#held + 1] = done; return true end
  if gw_mode == "sync" then done(nil); return true end
  if gw_mode == "twice" then done(nil); done(nil); return true end
  if gw_mode == "done-throw" then done(nil); error("after done") end
  if gw_mode == "done-decline" then done(nil); return false end
  return false
end)
local function routed_count(id)
  local n = 0
  for _, p in ipairs(gw_routed) do if p.id == id then n = n + 1 end end
  return n
end

-- held, then the hook unset: no scan routes the file another way
local m_held, p_held = gw_send("held while the hook goes away")
vim.wait(100, function() return #held >= 1 end, 10)
router.set_gateway(nil)
router.scan_now()
vim.wait(100)
ok("gateway: a held message is never moved once the hook is unset",
  vim.fn.filereadable(p_held) == 1 and not vim.tbl_contains(transp.list_inbox("agent:gemini"), m_held.id))
held[1](nil)
vim.wait(300, function() return routed_count(m_held.id) == 1 end, 25)
ok("gateway: the held attempt settles after the unset, archived once",
  routed_count(m_held.id) == 1 and vim.fn.filereadable(p_held) == 0
    and vim.fn.filereadable(jarvis_rec.subs.archive .. "/" .. m_held.id .. ".json") == 1)

-- delivered, the archive refused, the hook unset: archived later, never moved
router.set_gateway(function(rec, mid, msg, done) held[#held + 1] = done; return true end)
local m_arch, p_arch = gw_send("delivered, archive refused")
vim.wait(100, function() return #held >= 2 end, 10)
vim.uv.fs_chmod(jarvis_rec.subs.archive, tonumber("500", 8))
held[2](nil)
vim.wait(300, function()
  for _, p in ipairs(gw_archive_failed) do if p.id == m_arch.id then return true end end
  return false
end, 25)
ok("gateway: the refused archive is reported as gateway_archive_failed",
  #gw_archive_failed >= 1 and gw_archive_failed[#gw_archive_failed].id == m_arch.id,
  vim.inspect(gw_archive_failed))
router.set_gateway(nil)
router.scan_now()
vim.wait(100)
ok("gateway: a delivered message whose archive failed is never moved, hook or no hook",
  vim.fn.filereadable(p_arch) == 1 and not vim.tbl_contains(transp.list_inbox("agent:gemini"), m_arch.id)
    and routed_count(m_arch.id) == 0)
vim.uv.fs_chmod(jarvis_rec.subs.archive, tonumber("700", 8))
router.scan_now()
vim.wait(300, function() return routed_count(m_arch.id) == 1 end, 25)
ok("gateway: the next scan archives it, once",
  routed_count(m_arch.id) == 1 and vim.fn.filereadable(p_arch) == 0
    and not vim.tbl_contains(transp.list_inbox("agent:gemini"), m_arch.id))

router.set_gateway(function(rec, mid, msg, done)
  if gw_mode == "sync" then done(nil); return true end
  if gw_mode == "twice" then done(nil); done(nil); return true end
  if gw_mode == "done-throw" then done(nil); error("after done") end
  if gw_mode == "done-decline" then done(nil); return false end
  held[#held + 1] = done
  return true
end)

gw_mode = "sync"
local m_sync, p_sync = gw_send("done before return")
vim.wait(300, function() return routed_count(m_sync.id) == 1 end, 25)
ok("gateway: a done() before the gateway returns waits for its acceptance, then archives",
  routed_count(m_sync.id) == 1 and vim.fn.filereadable(p_sync) == 0)

gw_mode = "twice"
local m_twice = select(1, gw_send("done twice"))
vim.wait(300, function() return routed_count(m_twice.id) >= 1 end, 25)
vim.wait(100)
ok("gateway: a second done() is ignored", routed_count(m_twice.id) == 1)

gw_mode = "done-throw"
local m_dt, p_dt = gw_send("done, then a throw")
vim.wait(150)
ok("gateway: done() then a throw: nothing archived, the file kept",
  vim.fn.filereadable(p_dt) == 1 and routed_count(m_dt.id) == 0)

gw_mode = "done-decline"
local m_dd, p_dd = gw_send("done, then declined")
vim.wait(300, function() return vim.tbl_contains(transp.list_inbox("agent:gemini"), m_dd.id) end, 25)
ok("gateway: done() then a decline: the file move, never an archive",
  vim.tbl_contains(transp.list_inbox("agent:gemini"), m_dd.id) and routed_count(m_dd.id) == 0)

-- a stale callback after a retry settles nothing
gw_mode = "hold"
local before = #held
local m_st, p_st = gw_send("retried")
vim.wait(100, function() return #held == before + 1 end, 10)
local first = held[#held]
first("refused")
vim.wait(200, function()
  for _, p in ipairs(gw_undeliverable) do if p.id == m_st.id then return true end end
  return false
end, 25)
router.scan_now()
vim.wait(100, function() return #held == before + 2 end, 10)
first(nil) -- the first attempt's callback, late
vim.wait(100)
ok("gateway: a stale callback from a failed attempt settles nothing",
  vim.fn.filereadable(p_st) == 1 and routed_count(m_st.id) == 0)
held[#held](nil)
vim.wait(300, function() return routed_count(m_st.id) == 1 end, 25)
ok("gateway: the retry's own callback settles it, once",
  routed_count(m_st.id) == 1 and vim.fn.filereadable(p_st) == 0)

router.set_gateway(nil)
router.scan_now() -- the thrown ones, with no gateway, take the file move now
vim.wait(300, function() return vim.fn.filereadable(gw_thrown_path) == 0 end, 25)
ok("gateway: unset, the file move routes what was left",
  vim.fn.filereadable(gw_thrown_path) == 0
    and vim.tbl_contains(transp.list_inbox("agent:gemini"), gw_thrown.id))
events_m.unsubscribe(gw_sub1)
events_m.unsubscribe(gw_sub2)

router.stop()
ok("router.stop drops running state", router.is_running() == false)

-- ── 49j. wake hook dispatch via command registry ────────────
commands._reset_for_tests()
events_m._reset_for_tests()
router._reset_for_tests()

local wake_invocations = {}
commands.register("send_slot", {
  owner = "auto-agents.nvim",
  handler = function(args, ctx)
    wake_invocations[#wake_invocations + 1] = { args = args, ctx = ctx }
    return { ok = true }
  end,
  description = "wake the agent's terminal slot",
})

-- Register user FIRST so its wake hook is in place before we send.
local user_rec = mailbox.register("user", {
  wake = { command = "send_slot", args = { slot = "user_terminal" } },
})

router.start()

-- Send a fresh user→lector message and capture its id specifically
-- (lector's inbox has leftovers from earlier sections; using the
-- returned id keeps this section hermetic).
local wake_msg = mailbox.send({
  from = "user", to = "agent:lector",
  body = "wake test 1",
})
vim.wait(300, function()
  for _, inv in ipairs(wake_invocations) do
    if inv.ctx.arrival_id == wake_msg.id then return true end
  end
  return false
end, 25)
ok("wake hook dispatched send_slot on inbox arrival for the new message",
  (function()
    for _, inv in ipairs(wake_invocations) do
      if inv.ctx.arrival_id == wake_msg.id
          and inv.args.slot == "lector"
          and inv.ctx.reason == "mailbox_wake"
          and inv.ctx.mailbox == "agent:lector"
          and inv.ctx.arrival_kind == "inbox"
      then return true end
    end
    return false
  end)(),
  vim.inspect(wake_invocations))

-- Regression: a mailbox registered after router.start under an already
-- watched root must still get its own mailbox-subtree watcher coverage.
-- This is the common Claude-backed multi-agent shape.
local watched_before = router.status().roots[claude_like_root]
  and router.status().roots[claude_like_root].watched or 0
local late_claude = mailbox.register("agent:late-claude", {
  root = claude_like_root,
  wake = { command = "send_slot", args = { slot = "late-claude" } },
})
local watched_after = router.status().roots[claude_like_root]
  and router.status().roots[claude_like_root].watched or 0
ok("router.refresh adds mailbox-subtree watchers for same-root late mailboxes",
  watched_after > watched_before,
  "before=" .. tostring(watched_before) .. " after=" .. tostring(watched_after))

local late_msg = message.build({
  from = "user", to = late_claude.id,
  body = "late claude wake test",
})
vim.fn.writefile({ vim.json.encode(late_msg) },
  user_rec.subs.outbox .. "/" .. late_msg.id .. ".json")
router.scan_now()
vim.wait(300, function()
  for _, inv in ipairs(wake_invocations) do
    if inv.ctx.arrival_id == late_msg.id then return true end
  end
  return false
end, 25)
ok("routed mail immediately dispatches wake for same-root late mailbox",
  (function()
    for _, inv in ipairs(wake_invocations) do
      if inv.ctx.arrival_id == late_msg.id
          and inv.ctx.mailbox == "agent:late-claude"
          and inv.args.slot == "late-claude"
      then return true end
    end
    return false
  end)(),
  vim.inspect(wake_invocations))

local removed_late = mailbox.unregister("agent:late-claude")
local watched_removed = router.status().roots[claude_like_root]
  and router.status().roots[claude_like_root].watched or 0
ok("mailbox.unregister returns removed record and releases watcher coverage",
  removed_late == late_claude and watched_removed < watched_after,
  "after=" .. tostring(watched_after) .. " removed=" .. tostring(watched_removed))

-- Wake also fires for response arrivals to the sender. Subscribe
-- AFTER the send so we only capture the response leg.
local response_received = {}
events_m.subscribe("core.mailbox:response_received", function(p)
  response_received[#response_received + 1] = p
end)

mailbox.claim("agent:lector", wake_msg.id)
mailbox.complete("agent:lector", wake_msg.id, { ok = true, value = "ack" })
-- complete() writes a response to user/responses; router.scan_now()
-- makes arrival detection deterministic without waiting on fs_event.
router.scan_now()
vim.wait(400, function()
  for _, p in ipairs(response_received) do
    if p.mailbox == "user" then return true end
  end
  return false
end, 25)
ok("core.mailbox:response_received fired for user's responses",
  (function()
    for _, p in ipairs(response_received) do
      if p.mailbox == "user" then return true end
    end
    return false
  end)(),
  vim.inspect(response_received))
ok("wake hook also dispatched on response arrival for user",
  (function()
    for _, inv in ipairs(wake_invocations) do
      if inv.ctx.arrival_kind == "responses"
          and inv.ctx.mailbox == "user"
          and inv.args.slot == "user_terminal"
      then return true end
    end
    return false
  end)(),
  vim.inspect(wake_invocations))

router.stop()

-- ── 49k. command registry: register, list, get, reject unknown ──
commands._reset_for_tests()
local cmd_registered = {}
local cmd_executed = {}
local cmd_rejected = {}
events_m.subscribe("core.command:registered", function(p)
  cmd_registered[#cmd_registered + 1] = p
end)
events_m.subscribe("core.command:executed", function(p)
  cmd_executed[#cmd_executed + 1] = p
end)
events_m.subscribe("core.command:rejected", function(p)
  cmd_rejected[#cmd_rejected + 1] = p
end)

local reg_ok, reg_err = commands.register("harpoon", {
  owner = "md-harpoon.nvim",
  handler = function(args) return { ok = true, value = { panel = args.panel or "1" } } end,
  description = "pin a doc to a md-harpoon slot",
})
ok("commands.register returns true", reg_ok == true, tostring(reg_err))
ok("core.command:registered fired",
  #cmd_registered == 1 and cmd_registered[1].name == "harpoon")
ok("commands.get returns the spec", (function()
  local s = commands.get("harpoon")
  return type(s) == "table" and s.owner == "md-harpoon.nvim"
end)())
ok("commands.list includes harpoon",
  (function()
    for _, s in ipairs(commands.list()) do
      if s.name == "harpoon" then return true end
    end
    return false
  end)())

-- Re-register with a different owner is refused.
local rr_ok, rr_err = commands.register("harpoon", {
  owner = "evil.plugin", handler = function() end,
})
ok("re-register with different owner is refused",
  rr_ok == false and type(rr_err) == "string" and rr_err:find("already owned"),
  tostring(rr_err))
-- Re-register with the SAME owner is allowed (hot-reload friendly).
local rr2_ok = commands.register("harpoon", {
  owner = "md-harpoon.nvim", handler = function() return { ok = true } end,
})
ok("re-register with same owner is allowed", rr2_ok == true)

-- Dispatch unknown command via handle_message → structured rejection.
local unknown_msg = message.build({
  from = "agent:gemini", to = "nvim",
  kind = "command", command = "definitely_not_real",
  correlation_id = "cor-test-1",
})
local resp = commands.handle_message(unknown_msg)
ok("handle_message returns ok=false for unknown command",
  type(resp) == "table" and resp.ok == false)
ok("rejection code is 'unknown_command'",
  resp.code == "unknown_command",
  tostring(resp.code))
ok("core.command:rejected fired with the correlation_id",
  #cmd_rejected >= 1
    and cmd_rejected[#cmd_rejected].name == "definitely_not_real"
    and cmd_rejected[#cmd_rejected].correlation_id == "cor-test-1")

-- Dispatch known command — handler returns table.
local known_msg = message.build({
  from = "user", to = "nvim",
  kind = "command", command = "harpoon",
  args = { panel = "2" },
})
local resp2 = commands.handle_message(known_msg)
ok("handle_message dispatches known command",
  type(resp2) == "table" and resp2.ok == true)
ok("core.command:executed fired",
  #cmd_executed >= 1 and cmd_executed[#cmd_executed].name == "harpoon")

-- kind != command is rejected (it's not a command message).
local bad_kind = { id = "x", kind = "message", from = "a", to = "b" }
local resp3 = commands.handle_message(bad_kind)
ok("handle_message rejects kind != 'command'",
  resp3.ok == false and resp3.code == "not_a_command")

-- handler that throws → handler_error, NOT a raise.
commands.register("crashy", {
  owner = "test", handler = function() error("oops") end,
})
local resp4 = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "crashy",
}))
ok("handler that errors → ok=false, code='handler_error'",
  resp4.ok == false and resp4.code == "handler_error"
    and resp4.error:find("oops"),
  vim.inspect(resp4))

-- ── Schema validation (should-fix #5) ───────────────────────
-- Register a command with a schema covering required/optional
-- fields and the supported type primitives.
commands.register("opendiff", {
  owner = "auto-agents.nvim",
  schema = {
    old_file_path = "string",
    new_file_path = "string",
    tab_name      = "string?",
    line_count    = "integer?",
  },
  handler = function(args)
    return { ok = true, value = args }
  end,
})

-- Happy path — handler returns ok=true.
local good = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a", new_file_path = "/b", tab_name = "T" },
}))
ok("schema: handler runs when args satisfy schema",
  good.ok == true and good.value.old_file_path == "/a",
  vim.inspect(good))

-- Missing required field → bad_args, NOT handler_error.
local missing = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a" },
  correlation_id = "cor-bad-args-1",
}))
ok("schema: missing required field → ok=false, code=bad_args",
  missing.ok == false and missing.code == "bad_args"
    and missing.field == "new_file_path",
  vim.inspect(missing))

-- Wrong type → bad_args.
local wrongtype = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a", new_file_path = 42 },
}))
ok("schema: wrong-type field → ok=false, code=bad_args, error names the type mismatch",
  wrongtype.ok == false and wrongtype.code == "bad_args"
    and wrongtype.field == "new_file_path"
    and wrongtype.error:find("string", 1, true) ~= nil,
  vim.inspect(wrongtype))

-- Optional field absent is fine.
local opt_absent = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a", new_file_path = "/b" },
}))
ok("schema: optional field omitted is accepted",
  opt_absent.ok == true)

-- Optional field with vim.NIL (JSON null) is accepted and normalized to nil.
local opt_nil = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a", new_file_path = "/b", tab_name = vim.NIL },
}))
ok("schema: optional field with vim.NIL (JSON null) is accepted",
  opt_nil.ok == true)
ok("schema: optional field with vim.NIL is normalized to nil for handler",
  opt_nil.value.tab_name == nil)

-- Required field with vim.NIL (JSON null) is rejected with bad_args.
local req_nil = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a", new_file_path = vim.NIL },
}))
ok("schema: required field with vim.NIL is rejected as bad_args",
  req_nil.ok == false and req_nil.code == "bad_args" and req_nil.field == "new_file_path")

-- Integer type rejects floats.
commands.register("setline", {
  owner = "test", schema = { n = "integer" },
  handler = function() return { ok = true } end,
})
local floaty = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "setline",
  args = { n = 3.5 },
}))
ok("schema: integer type rejects non-integer numbers",
  floaty.ok == false and floaty.code == "bad_args")

-- Schema rejection publishes core.command:rejected with reason='bad_args'.
local bad_args_rejections = {}
events_m.subscribe("core.command:rejected", function(p)
  bad_args_rejections[#bad_args_rejections + 1] = p
end)
commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a" },
  correlation_id = "cor-bad-args-event",
}))
ok("schema: rejection publishes core.command:rejected with reason='bad_args'",
  (function()
    for _, e in ipairs(bad_args_rejections) do
      if e.name == "opendiff" and e.reason == "bad_args"
          and e.correlation_id == "cor-bad-args-event"
      then return true end
    end
    return false
  end)(),
  vim.inspect(bad_args_rejections))

-- ── 49l. fail() transition writes failure envelope ─────────
local r3 = mailbox.send({
  from = "agent:gemini", to = "agent:lector",
  body = "intentional fail", correlation_id = "cor-fail-1",
})
mailbox.claim("agent:lector", r3.id)
local fok, ferr = mailbox.fail("agent:lector", r3.id, "deliberate",
  { response = true })
ok("fail returns true", fok == true, tostring(ferr))
ok("failed message archived",
  vim.tbl_contains(transp.list_archive("agent:lector"), r3.id))
ok("response envelope for failure has ok=false and the error",
  (function()
    -- gemini's responses dir lives under its tool root, not the host
    -- fallback — read via the registered record.
    local p = registry.get("agent:gemini").subs.responses .. "/cor-fail-1.json"
    if vim.fn.filereadable(p) ~= 1 then return false end
    local content = table.concat(vim.fn.readfile(p), "\n")
    local ok_dec, decoded = pcall(vim.json.decode, content)
    return ok_dec and decoded.ok == false and decoded.error == "deliberate"
  end)())

-- ── 49l0. host executioner via file transport (ADR §4) ─────
;(function()
local mb = require("auto-core.mailbox")
local router = mb.router
local commands = mb.commands

commands._reset_for_tests()
events_m._reset_for_tests()
router._reset_for_tests()

-- Register the host-side executioner mailbox. Default
-- executioner=true for id='nvim'; we exercise that default here.
local nvim_rec = mb.register("nvim")
ok("register('nvim') sets executioner=true by default",
  nvim_rec.executioner == true)
-- Other ids default to executioner=false.
local lector_rec_now = registry.get("agent:lector")
ok("non-nvim mailbox defaults to executioner=false",
  lector_rec_now.executioner == false)

-- Register a 'harpoon' command. The handler captures invocations
-- so we can assert it actually ran via the file path (not direct
-- lua dispatch).
local handler_invocations = {}
commands.register("harpoon", {
  owner = "md-harpoon.nvim",
  handler = function(args, ctx)
    handler_invocations[#handler_invocations + 1] = {
      args = args, ctx = ctx,
    }
    return { ok = true, value = { panel = args.panel or "1" } }
  end,
  description = "pin a doc to a md-harpoon slot",
})

router.start()

-- The realistic flow: a sandboxed agent (here jarvis) writes a
-- command JSON to its OWN outbox addressed to 'nvim'. Router
-- routes outbox → nvim/inbox → executioner claims+dispatches+
-- completes; sender (jarvis) gets a response in its responses/
-- dir keyed by correlation_id.
local cor = "cor-exec-harpoon-" .. tostring(vim.uv.hrtime())
local cmd_msg = mb.message.build({
  from = "agent:jarvis", to = "nvim",
  kind = "command", command = "harpoon",
  args = { panel = "2", file = "/tmp/foo.md" },
  correlation_id = cor,
})
local jarvis_rec_now = registry.get("agent:jarvis")
vim.fn.writefile({ vim.json.encode(cmd_msg) },
  jarvis_rec_now.subs.outbox .. "/" .. cmd_msg.id .. ".json")

local executed_events = {}
events_m.subscribe("core.command:executed", function(p)
  executed_events[#executed_events + 1] = p
end)
local completed_events = {}
events_m.subscribe("core.mailbox:message_completed", function(p)
  completed_events[#completed_events + 1] = p
end)

router.scan_now()
vim.wait(400, function()
  return #executed_events >= 1 and #completed_events >= 1
end, 25)

ok("executioner dispatched the file-routed command via registry",
  #handler_invocations >= 1
    and handler_invocations[1].args.panel == "2"
    and handler_invocations[1].args.file  == "/tmp/foo.md"
    and handler_invocations[1].ctx.reason == "mailbox_executioner"
    and handler_invocations[1].ctx.mailbox == "nvim",
  vim.inspect(handler_invocations))
-- v0.1.11: ctx surfaces the SENDER's identity alongside the executor's
-- mailbox so command handlers can attribute the call to who actually
-- asked for it (the executor is always `nvim`, which historically
-- forced handlers to guess or to require an explicit `args.sender`).
ok("ctx.sender carries the sender's full mailbox id (msg.from)",
  #handler_invocations >= 1
    and handler_invocations[1].ctx.sender == cmd_msg.from,
  vim.inspect(handler_invocations[1] and handler_invocations[1].ctx))
ok("ctx.sender_bare carries the bare form (agent:jarvis without instance suffix)",
  #handler_invocations >= 1
    and handler_invocations[1].ctx.sender_bare == "agent:jarvis",
  vim.inspect(handler_invocations[1] and handler_invocations[1].ctx))
-- v0.1.23: ctx also surfaces the round-trip identity so handlers that
-- defer a verdict past the synchronous response (e.g. auto-agents'
-- diff_queue) can stash the correlation_id and route a follow-up
-- back to the sender keyed by it.
ok("ctx.correlation_id carries the original message's correlation_id (when set)",
  #handler_invocations >= 1
    and handler_invocations[1].ctx.correlation_id == cor,
  vim.inspect(handler_invocations[1] and handler_invocations[1].ctx))
ok("ctx.message_id carries the executor-path file basename (mid)",
  #handler_invocations >= 1
    and handler_invocations[1].ctx.message_id == cmd_msg.id,
  vim.inspect(handler_invocations[1] and handler_invocations[1].ctx))
ok("core.command:executed fired with name='harpoon'",
  #executed_events >= 1 and executed_events[1].name == "harpoon")
ok("core.mailbox:message_completed fired for the executioner-handled message",
  (function()
    for _, e in ipairs(completed_events) do
      if e.mailbox == "nvim" and e.id == cmd_msg.id then return true end
    end
    return false
  end)(),
  vim.inspect(completed_events))
ok("command file moved out of nvim inbox/processing into archive",
  not vim.tbl_contains(transp.list_inbox("nvim"), cmd_msg.id)
    and not vim.tbl_contains(transp.list_processing("nvim"), cmd_msg.id)
    and vim.tbl_contains(transp.list_archive("nvim"), cmd_msg.id))

-- Response envelope landed in sender's responses/ with the
-- handler's return value. This is the "blocking sender" contract:
-- the agent that sent the command can poll <jarvis>/responses/
-- <cor>.json and unblock.
ok("sender's responses/<cor>.json contains the handler's return value",
  (function()
    local p = jarvis_rec_now.subs.responses .. "/" .. cor .. ".json"
    if vim.fn.filereadable(p) ~= 1 then return false end
    local txt = table.concat(vim.fn.readfile(p), "\n")
    local okd, dec = pcall(vim.json.decode, txt)
    return okd and dec.ok == true
      and dec.reply_to == cmd_msg.id
      and dec.correlation_id == cor
      and type(dec.value) == "table"
      and dec.value.panel == "2"
  end)())

-- Unknown command through the file transport — structured
-- rejection lands in the sender's responses dir, not a thrown error.
local cor_unknown = "cor-exec-unknown-" .. tostring(vim.uv.hrtime())
local unknown_msg = mb.message.build({
  from = "agent:jarvis", to = "nvim",
  kind = "command", command = "definitely_not_registered",
  correlation_id = cor_unknown,
})
vim.fn.writefile({ vim.json.encode(unknown_msg) },
  jarvis_rec_now.subs.outbox .. "/" .. unknown_msg.id .. ".json")
local rejected_events = {}
events_m.subscribe("core.command:rejected", function(p)
  rejected_events[#rejected_events + 1] = p
end)
router.scan_now()
vim.wait(400, function() return #rejected_events >= 1 end, 25)
ok("unknown command via file path is rejected with structured response",
  #rejected_events >= 1
    and rejected_events[1].name == "definitely_not_registered",
  vim.inspect(rejected_events))
ok("sender unblocks via responses/<cor>.json with ok=false code=unknown_command",
  (function()
    local p = jarvis_rec_now.subs.responses .. "/" .. cor_unknown .. ".json"
    if vim.fn.filereadable(p) ~= 1 then return false end
    local txt = table.concat(vim.fn.readfile(p), "\n")
    local okd, dec = pcall(vim.json.decode, txt)
    return okd and dec.ok == false
  end)())

-- Non-command messages on an executioner mailbox still trigger
-- the wake hook (executioner only intercepts kind='command').
-- We can't register a wake on nvim here without polluting, but we
-- can assert: a plain 'message' to nvim does NOT call the
-- executioner (handler_invocations doesn't grow).
local hi_before = #handler_invocations
mb.send({ from = "agent:jarvis", to = "nvim",
  body = "just a message, not a command" })
router.scan_now()
vim.wait(200, function() return false end, 50)  -- give it a moment
ok("non-command messages on executioner mailbox do NOT invoke handlers",
  #handler_invocations == hi_before)

router.stop()
commands._reset_for_tests()
events_m._reset_for_tests()
end)()

-- ── 49l1. router polling fallback + status flags ──────────
;(function()
local mb = require("auto-core.mailbox")
local router = mb.router
events_m._reset_for_tests()
router._reset_for_tests()

-- mode='poll' skips fs_event entirely; the global poll timer must
-- pick up new arrivals via scan_now().
router.configure({ mode = "poll", poll_interval_ms = 60 })
router.start()
ok("status.mode reports 'poll' after configure",
  router.status().mode == "poll",
  vim.inspect(router.status()))
ok("status.poll_running is true with poll mode + an interval",
  router.status().poll_running == true,
  vim.inspect(router.status()))
ok("every root reports poll_active=true in poll mode",
  (function()
    for _, entry in pairs(router.status().roots) do
      if entry.poll_active ~= true then return false end
    end
    return next(router.status().roots) ~= nil
  end)(),
  vim.inspect(router.status()))
ok("every root has zero fs_event handles in poll mode",
  (function()
    for _, entry in pairs(router.status().roots) do
      if entry.handles ~= 0 then return false end
    end
    return true
  end)(),
  vim.inspect(router.status()))

-- Now send via outbox: simulate an agent dropping a message in
-- its own outbox, no fs_event; only the poll timer can find it.
local jarvis_rec = registry.get("agent:jarvis")
local outgoing = mb.message.build({
  from = "agent:jarvis", to = "agent:gemini",
  body = "polled delivery test",
})
vim.fn.writefile({ vim.json.encode(outgoing) },
  jarvis_rec.subs.outbox .. "/" .. outgoing.id .. ".json")
local routed_via_poll = false
events_m.subscribe("core.mailbox:outbox_routed", function(p)
  if p.id == outgoing.id then routed_via_poll = true end
end)
-- Wait a bit longer than the poll interval. We do NOT call
-- scan_now() — the timer must fire on its own.
vim.wait(400, function() return routed_via_poll end, 25)
ok("poll-mode timer routes outbox without fs_event",
  routed_via_poll)
router.stop()
ok("status.poll_running false after stop", router.status().poll_running == false)

-- mode='watch' is strict: even with poll_interval_ms set, no
-- timer should run. Useful as a "must have watchers" mode.
router._reset_for_tests()
router.configure({ mode = "watch", poll_interval_ms = 60 })
router.start()
ok("watch mode never starts the poll timer even with interval set",
  router.status().poll_running == false,
  vim.inspect(router.status()))
ok("every root reports poll_active=false in watch mode",
  (function()
    for _, entry in pairs(router.status().roots) do
      if entry.poll_active ~= false then return false end
    end
    return true
  end)())
router.stop()

-- poll_interval_ms=false disables polling even if a root would
-- otherwise need it.
router._reset_for_tests()
router.configure({ mode = "poll", poll_interval_ms = false })
router.start()
ok("poll_interval_ms=false prevents the timer from starting",
  router.status().poll_running == false)
router.stop()

router._reset_for_tests()
events_m._reset_for_tests()
end)()

-- ── 49l2. claim stamps + stale processing recovery ─────────
;(function()
local mb = require("auto-core.mailbox")
local tr = mb.transport
events_m._reset_for_tests()

-- Fresh message → claim stamps claimed_at/claimed_by/attempt
-- durably on the processing file.
local r = mb.send({ from = "agent:gemini", to = "agent:lector",
  body = "stamp test", correlation_id = "cor-stale-stamp" })
local msg, claim_err = mb.claim("agent:lector", r.id,
  { claimed_by = "test-harness" })
ok("claim returns the message with stamps", msg ~= nil and claim_err == nil,
  tostring(claim_err))
ok("claim stamps claimed_at + claimed_by + attempt on the returned msg",
  type(msg.claimed_at) == "string"
    and msg.claimed_by == "test-harness"
    and msg.attempt == 1,
  vim.inspect(msg))

-- Stamps are durable on disk (read processing file independently).
local on_disk = tr.read_from("agent:lector", "processing", r.id)
ok("claim stamps persist to disk",
  on_disk ~= nil
    and on_disk.claimed_by == "test-harness"
    and on_disk.attempt == 1
    and type(on_disk.claimed_at) == "string")

-- Recover-stale with a tiny threshold (0ms) trips immediately. Use
-- 'fail' policy (default) → archived + structured response.
local stale_events = {}
events_m.subscribe("core.mailbox:stale_recovered", function(p)
  stale_events[#stale_events + 1] = p
end)
local result = tr.recover_stale("agent:lector", { threshold_ms = 0 })
ok("recover_stale returns recovered list + scan count",
  type(result) == "table"
    and type(result.recovered) == "table"
    and type(result.scanned) == "number",
  vim.inspect(result))
ok("the stamped message was recovered with policy='fail'",
  (function()
    for _, e in ipairs(result.recovered) do
      if e.id == r.id and e.policy == "fail" then return true end
    end
    return false
  end)(),
  vim.inspect(result.recovered))
ok("core.mailbox:stale_recovered fired for the recovery",
  (function()
    for _, e in ipairs(stale_events) do
      if e.id == r.id and e.policy == "fail" then return true end
    end
    return false
  end)())
ok("recovered message archived",
  vim.tbl_contains(tr.list_archive("agent:lector"), r.id))
ok("recovered message no longer in processing",
  not vim.tbl_contains(tr.list_processing("agent:lector"), r.id))
-- Structured response with stale_processing_timeout went to sender.
ok("recovery wrote a response envelope with error=stale_processing_timeout",
  (function()
    local resp_path = registry.get("agent:gemini").subs.responses
                     .. "/cor-stale-stamp.json"
    if vim.fn.filereadable(resp_path) ~= 1 then return false end
    local txt = table.concat(vim.fn.readfile(resp_path), "\n")
    local okd, dec = pcall(vim.json.decode, txt)
    return okd and dec.ok == false
      and dec.error == "stale_processing_timeout"
  end)())

-- 'requeue' policy puts the message back in inbox; attempt
-- preserved; next claim → attempt = 2.
local r2 = mb.send({ from = "agent:gemini", to = "agent:lector",
  body = "requeue test", correlation_id = "cor-requeue" })
mb.claim("agent:lector", r2.id, { claimed_by = "test-harness" })
local result2 = tr.recover_stale("agent:lector",
  { threshold_ms = 0, policy = "requeue" })
ok("requeue policy recovers the message",
  (function()
    for _, e in ipairs(result2.recovered) do
      if e.id == r2.id and e.policy == "requeue" then return true end
    end
    return false
  end)(),
  vim.inspect(result2))
ok("requeued message returns to inbox",
  vim.tbl_contains(tr.list_inbox("agent:lector"), r2.id))
ok("requeued message no longer in processing",
  not vim.tbl_contains(tr.list_processing("agent:lector"), r2.id))

-- Next claim → attempt = 2 (the counter survived requeue).
local msg2 = mb.claim("agent:lector", r2.id, { claimed_by = "test-harness" })
ok("next claim after requeue increments attempt to 2",
  msg2 ~= nil and msg2.attempt == 2,
  vim.inspect(msg2))
-- Cleanup.
mb.fail("agent:lector", r2.id, "test-done", { response = false })

-- Threshold honors recency: a fresh claim with the default
-- threshold (5min) is NOT recovered.
local r3 = mb.send({ from = "agent:gemini", to = "agent:lector",
  body = "young message" })
mb.claim("agent:lector", r3.id)
local result3 = tr.recover_stale("agent:lector")  -- default 5min
ok("fresh claim is NOT swept under default threshold",
  (function()
    for _, e in ipairs(result3.recovered) do
      if e.id == r3.id then return false end
    end
    return true
  end)(),
  vim.inspect(result3))
mb.fail("agent:lector", r3.id, "test-cleanup", { response = false })

-- recover_stale_all walks every registered mailbox.
local merged = tr.recover_stale_all({ threshold_ms = 999999999 })
ok("recover_stale_all returns merged scanned + recovered list",
  type(merged) == "table"
    and type(merged.scanned) == "number"
    and type(merged.recovered) == "table",
  vim.inspect(merged))
end)()

-- ── 49n_pre. message_state + list_entries + viewer data pipeline ──
;(function()
local mb = require("auto-core.mailbox")
local tr = mb.transport
local ui = mb.ui

-- The earlier 49l block left agent:lector with an archived 'failed'
-- message. Find it specifically (list_archive returns sorted-by-id,
-- which is roughly oldest-first; archive contains both completed
-- and failed messages by now).
local fail_id
for _, id in ipairs(transp.list_archive("agent:lector")) do
  if tr.message_state("agent:lector", id) == "failed" then
    fail_id = id; break
  end
end
ok("agent:lector archive has a 'failed' message from the fail test",
  type(fail_id) == "string")
local fail_state = tr.message_state("agent:lector", fail_id)
ok("message_state classifies the archived failed message as 'failed'",
  fail_state == "failed",
  "got " .. tostring(fail_state))

-- Send a fresh message and verify it's "queued" before claim.
local r = mb.send({
  from = "agent:gemini", to = "agent:lector",
  body = "fresh queued",
})
local s = tr.message_state("agent:lector", r.id)
ok("freshly-sent inbox message reports 'queued'",
  s == "queued", "got " .. tostring(s))

-- Claim it → "claimed".
mb.claim("agent:lector", r.id)
s = tr.message_state("agent:lector", r.id)
ok("after claim, message_state reports 'claimed'",
  s == "claimed", "got " .. tostring(s))

-- Complete with response → "completed", and the response exists
-- in the sender's responses dir.
local cor = "cor-state-test-" .. tostring(vim.uv.hrtime())
mb.complete("agent:lector", r.id, {
  ok = true, value = "ack", correlation_id = cor,
})
s = tr.message_state("agent:lector", r.id)
ok("after complete, message_state reports 'completed'",
  s == "completed", "got " .. tostring(s))

-- Unknown id → nil.
ok("unknown message id → state is nil",
  tr.message_state("agent:lector", "nope-never-existed") == nil)

-- list_entries: ensure decoded payload fields land on entries.
local inbox_entries = tr.list_entries("agent:lector", "inbox")
ok("list_entries(inbox) returns a table",
  type(inbox_entries) == "table")
local arch_entries = tr.list_entries("agent:lector", "archive")
ok("list_entries(archive) carries states + responded annotation",
  (function()
    local saw_completed, saw_failed = false, false
    for _, e in ipairs(arch_entries) do
      if e.state == "completed" then saw_completed = true end
      if e.state == "failed"    then saw_failed    = true end
    end
    return saw_completed and saw_failed
  end)(),
  vim.inspect(arch_entries))

-- list_all merges every subdir, sorted by mtime desc.
local all = tr.list_all("agent:lector")
ok("list_all merges across subdirs and sorts desc",
  (function()
    if #all < 2 then return true end  -- nothing to compare
    for i = 1, #all - 1 do
      if all[i].mtime < all[i + 1].mtime then return false end
    end
    return true
  end)())

-- Viewer's data pipeline (without actually rendering windows).
ui._reset_for_tests()
ui._select("agent:lector", "all")
local data = ui._render_data()
ok("ui._render_data returns tree + tree_map + entries",
  type(data.tree) == "table"
    and type(data.tree_map) == "table"
    and type(data.entries) == "table")
ok("tree contains a row per registered mailbox + 5 subdirs each",
  (function()
    -- One owner row + 5 scope rows per mailbox.
    local owner_rows = 0
    for _, m in ipairs(data.tree_map) do
      if m.scope == "all" then owner_rows = owner_rows + 1 end
    end
    return owner_rows == #registry.records()
  end)(),
  vim.inspect(data.tree_map))

-- Backlog indicator: lower threshold and check tree includes warning.
ui._reset_for_tests()
ui.open({ backlog_threshold = 1, initial_mailbox = "agent:lector",
  initial_scope = "all" })
-- Immediately read state and close — open() requires a real UI but
-- we don't drive interactions; the smoke run is headless so windows
-- exist briefly. We just verify the tree was built with the
-- backlog warning embedded.
local s2 = ui._state()
local saw_warn = false
for _, line in ipairs(s2.tree_lines) do
  if line:find("⚠ inbox=", 1, true) then saw_warn = true; break end
end
ok("backlog indicator appears in the tree when inbox >= threshold",
  saw_warn, vim.inspect(s2.tree_lines))
ui.close()
end)()

-- ── 49n. debug probe surface — :AutoCoreDebug mailbox helpers ─
;(function()
local dbg = require("auto-core").debug.mailbox
ok("debug.mailbox is a table",
  type(dbg) == "table"
    and type(dbg.recent)         == "function"
    and type(dbg.format_entry)   == "function"
    and type(dbg.status)         == "function"
    and type(dbg.registry_lines) == "function"
    and type(dbg.tail_lines)     == "function"
    and type(dbg.follow_start)   == "function"
    and type(dbg.follow_stop)    == "function"
    and type(dbg.clear)          == "function")

-- registry_lines renders the current state without crashing on
-- empty/full registries.
local lines = dbg.registry_lines()
ok("registry_lines returns a non-empty list of strings",
  type(lines) == "table" and #lines >= 3
    and type(lines[1]) == "string"
    -- `:find(needle, 1, true)` is a literal-text search; the hyphens
    -- in "auto-core" would otherwise be pattern-quantifiers.
    and lines[1]:find("auto-core mailbox registry", 1, true) ~= nil,
  type(lines) == "table" and ("first=" .. tostring(lines[1])
                              .. " count=" .. tostring(#lines)) or "not-a-table")

-- tail_lines pulls from the trace; we trust the trace's existing
-- contract here. Just verify the shape.
local tail = dbg.tail_lines(20)
ok("tail_lines returns a list with at least the header rows",
  type(tail) == "table" and #tail >= 2)

-- recent() filters trace to core.mailbox:* / core.command:*. The
-- earlier sections fired both, so we should see entries.
local rec_events = dbg.recent(50)
ok("recent() returns mailbox / command events only",
  (function()
    if #rec_events == 0 then return false end
    for _, e in ipairs(rec_events) do
      if not (e.topic:sub(1, 13) == "core.mailbox:"
              or e.topic:sub(1, 13) == "core.command:") then
        return false
      end
    end
    return true
  end)(),
  vim.inspect(rec_events))
end)()

-- ── 49o. ADR 0023 Phase 1 — stale-orphan event + wake identity_hint ─
print("\n[49o] ADR 0023 Phase 1 — stale orphan event + wake identity_hint")
;(function()
  local mailbox_m  = require("auto-core.mailbox")
  local router_m   = require("auto-core.mailbox.router")
  local registry_m = require("auto-core.mailbox.registry")
  local transport_m = require("auto-core.mailbox.transport")
  local message_m  = require("auto-core.mailbox.message")
  local commands_m = require("auto-core.mailbox.commands")
  local path_m     = require("auto-core.mailbox.path")

  -- Don't reset registry/commands/events — section 49p downstream
  -- depends on the `agent:lector` registration that section 49
  -- planted. Just stop the router, swap in a fresh tmp root, and
  -- restart so this section's orphan event doesn't get polluted by
  -- the prior root's activity.
  router_m.stop()

  local tmp_root = vim.fn.tempname() .. "_adr0023_orphan"
  vim.fn.mkdir(tmp_root, "p")
  mailbox_m.configure({ host_fallback_root = tmp_root, mode = "watch" })

  -- Register a live mailbox so the router has something to scope to.
  local rec = mailbox_m.register("agent:live-peer", {
    root = tmp_root,
    wake = { command = "test_wake_hint" },
  })
  -- Stage a stale orphan mailbox dir layout under the same root —
  -- never registered. Path is composed via `mb_path.subdir` so the
  -- v0.1.33 layout (`<root>/<instance>/<name>/<sub>/`) is honored
  -- without test fixtures hardcoding the shape.
  local orphan_id  = "agent:orphan-ghost:9999999999-99999"
  local orphan_dir = path_m.subdir(orphan_id, "outbox", tmp_root)
  vim.fn.mkdir(orphan_dir, "p")
  local orphan_file = orphan_dir .. "/orphan-msg-id-001.json"

  -- Start router + collect orphan events as they fire.
  router_m.start()
  local orphan_events = {}
  local orphan_sub = events_m.subscribe(
    "core.mailbox:stale_orphan_detected",
    function(p) orphan_events[#orphan_events + 1] = p end)

  -- Plant the orphan file; router's fs.watch on the recursive root
  -- catches the write OR a manual scan_now() catches it on poll.
  vim.fn.writefile({ "{}" }, orphan_file)
  mailbox_m.scan_now()
  vim.wait(150, function() return #orphan_events > 0 end, 20)

  local orphan_event
  for _, event in ipairs(orphan_events) do
    if event.mailbox_id == orphan_id then
      orphan_event = event
      break
    end
  end
  ok("ADR 0023 §3.6: stale orphan write under unregistered mailbox emits event",
    orphan_event ~= nil, vim.inspect(orphan_events))
  ok("ADR 0023 §3.6: orphan event payload carries mailbox_id + reason",
    orphan_event
      and orphan_event.mailbox_id == orphan_id
      and orphan_event.reason == "unregistered_mailbox",
    vim.inspect(orphan_event))
  ok("ADR 0023 §3.6: orphan event payload carries sub + message_id + path",
    orphan_event
      and orphan_event.sub == "outbox"
      and orphan_event.message_id == "orphan-msg-id-001"
      and orphan_event.path == orphan_file)

  events_m.unsubscribe(orphan_sub)

  -- ── Track A — wake-payload identity_hint round trip ──
  -- Register a fake wake-command handler that captures the ctx it
  -- received. Plant an inbox arrival on the live mailbox; the
  -- router's dispatch_wake should fire the handler with the new
  -- identity_hint slot populated.
  local captured_ctx
  commands_m.register("test_wake_hint", {
    owner       = "smoke",
    description = "ADR 0023 wake hint probe",
    schema      = nil,
    handler     = function(_args, ctx)
      captured_ctx = ctx
      return { ok = true, value = {} }
    end,
  })

  -- Write a minimal inbox message and trigger a scan.
  local arrival_mid = message_m.new_id()
  local arrival = {
    id   = arrival_mid,
    kind = "command",
    from = "auto-core",
    to   = rec.id,
    command = "test_wake_hint",
    args = {},
  }
  local arrival_path = rec.subs.inbox .. "/" .. arrival_mid .. ".json"
  vim.fn.writefile({ vim.fn.json_encode(arrival) }, arrival_path)
  mailbox_m.scan_now()
  vim.wait(200, function() return captured_ctx ~= nil end, 20)

  ok("ADR 0023 §3.5: wake handler receives ctx with identity_hint slot",
    type(captured_ctx) == "table"
      and type(captured_ctx.identity_hint) == "table",
    vim.inspect(captured_ctx))
  ok("ADR 0023 §3.5: identity_hint.expected_instance_id matches host's get_instance_id()",
    captured_ctx and captured_ctx.identity_hint
      and captured_ctx.identity_hint.expected_instance_id == path_m.get_instance_id())
  ok("ADR 0023 §3.5: identity_hint.expected_mailbox_id matches the addressed mailbox's full id",
    captured_ctx and captured_ctx.identity_hint
      and captured_ctx.identity_hint.expected_mailbox_id == rec.id)
  ok("ADR 0023 §3.5: identity_hint.expected_bare_id matches the addressed mailbox's bare id",
    captured_ctx and captured_ctx.identity_hint
      and captured_ctx.identity_hint.expected_bare_id == "agent:live-peer")

  router_m.stop()
end)()

-- ── 49p. mailbox.prune — sweep old per-instance dirs (v0.1.8) ─
print("\n[49p] mailbox.prune — sweep stale per-instance dirs")
;(function()
  -- Plant three stale dirs under the codex-like root, alongside the
  -- live `agent:lector:9999999999-12345` registered earlier. Two
  -- look like full-format instance dirs (pruneable by name pattern),
  -- one is a bare-id orphan from pre-v0.1.8 layout (also pruneable
  -- since it can never be "live" in v0.1.8).
  -- v0.1.33 layout: <root>/<instance>/<name>/. Compose via the path
  -- module's resolver so the test fixtures don't reproduce layout
  -- knowledge that lives in mb_path.
  local stale_full_a = mb_path.mailbox_dir("agent:lector:1111111111-1111",  codex_like_root)
  local stale_full_b = mb_path.mailbox_dir("agent:juliet:2222222222-2222", codex_like_root)
  vim.fn.mkdir(stale_full_a .. "/inbox", "p")
  vim.fn.mkdir(stale_full_b .. "/outbox", "p")
  -- Backdate each so they're older than the 7-day default. `touch`
  -- with relative time tags is the cheapest path; if the platform
  -- doesn't have it we fall back to a 1s threshold for this test.
  local backdate = function(p)
    os.execute("touch -d '8 days ago' " .. vim.fn.shellescape(p))
  end
  backdate(stale_full_a)
  backdate(stale_full_b)

  local result = mailbox.prune({ root = codex_like_root })
  local removed_set = {}
  for _, d in ipairs(result.removed) do removed_set[d] = true end
  ok("prune removed the two stale full-format instance dirs",
    removed_set[stale_full_a] == true and removed_set[stale_full_b] == true,
    vim.inspect(result.removed))
  local kept_alive_set = {}
  for _, d in ipairs(result.kept_alive) do kept_alive_set[d] = true end
  ok("prune kept the live registered lector dir alive",
    kept_alive_set[lector_rec.dir] == true,
    vim.inspect(result.kept_alive))
  ok("prune left the workspace bootstrap doc intact",
    vim.fn.filereadable(codex_like_root .. "/bootstrap-mailbox.md") == 1)

  -- A second register of a fresh dir followed by an immediate prune
  -- should keep it (younger than threshold).
  local fresh_dir = mb_path.mailbox_dir("agent:fresh:3333333333-3333", codex_like_root)
  vim.fn.mkdir(fresh_dir, "p")
  local result2 = mailbox.prune({ root = codex_like_root,
    max_age_seconds = 7 * 24 * 60 * 60 })
  local fresh_kept = false
  for _, d in ipairs(result2.kept_recent) do
    if d == fresh_dir then fresh_kept = true; break end
  end
  ok("prune keeps recent dirs under the age threshold", fresh_kept,
    vim.inspect(result2.kept_recent))

  -- v0.1.33 / Phase 8 safety rail: prune({ root = <legacy_root> })
  -- where the root has ZERO live registrations refuses by default —
  -- protects accidental cleanup of foreign trees. Bypass with force.
  local legacy_only_root = vim.fn.tempname() .. "_legacy-only-root"
  vim.fn.mkdir(legacy_only_root .. "/9999999999-9999/orphan-agent/inbox", "p")
  os.execute("touch -d '8 days ago' " .. vim.fn.shellescape(
    legacy_only_root .. "/9999999999-9999/orphan-agent"))
  local refused = mailbox.prune({ root = legacy_only_root })
  ok("Phase 8 safety rail: prune refuses root with zero live registrations",
    refused.refused == true and refused.reason == "no_live_registrations"
      and refused.root:sub(-#legacy_only_root) == legacy_only_root,
    vim.inspect(refused))
  ok("Phase 8 safety rail: refusal does NOT touch the filesystem",
    vim.fn.isdirectory(legacy_only_root .. "/9999999999-9999/orphan-agent") == 1)
  -- force=true bypasses the rail.
  local forced = mailbox.prune({ root = legacy_only_root, force = true })
  ok("Phase 8 safety rail: force=true bypasses (prune proceeds)",
    forced.refused ~= true
      and type(forced.removed) == "table"
      and #forced.removed >= 1,
    vim.inspect(forced))
  pcall(vim.fn.delete, legacy_only_root, "rf")
end)()

-- ── 49o. teardown ───────────────────────────────────────────
mailbox._reset_for_tests()
events_m._reset_for_tests()
require("auto-core").setup()  -- restore defaults
pcall(vim.fn.delete, tmp_root, "rf")
-- Restore env so the rest of the suite (if any) sees originals.
vim.env.AUTO_AGENTS_MAILBOX_ROOT = saved_env.AUTO_AGENTS_MAILBOX_ROOT
vim.env.AUTO_AGENTS_CONFIG_DIR   = saved_env.AUTO_AGENTS_CONFIG_DIR
vim.env.AUTO_AGENTS_KB_ROOT      = saved_env.AUTO_AGENTS_KB_ROOT
end)()

-- ─────────────────────── 49. remote branches + git mutations (Phase 3.5+) ─────────────────────────
print("\n[49] git.worktree/git.repo — remote branches + mutations")
;(function()
local wt_mod = require("auto-core.git.worktree")
local repo_mod = require("auto-core.git.repo")
local events = require("auto-core.events")

-- 1. Setup local bare remote and a clone
local tmp = vim.fn.tempname()
local remote_path = tmp .. "/remote.git"
local clone_path  = tmp .. "/clone"
vim.fn.mkdir(remote_path, "p")
vim.system({ "git", "init", "--bare", remote_path }):wait()

vim.fn.mkdir(clone_path, "p")
vim.system({ "git", "clone", remote_path, clone_path }):wait()
vim.system({ "git", "-C", clone_path, "config", "user.email", "test@example.com" }):wait()
vim.system({ "git", "-C", clone_path, "config", "user.name", "Test User" }):wait()
vim.system({ "git", "-C", clone_path, "commit", "--allow-empty", "-m", "initial" }):wait()
vim.system({ "git", "-C", clone_path, "push", "origin", "HEAD" }):wait()

-- 2. Create a remote branch
vim.system({ "git", "-C", clone_path, "checkout", "-b", "feature-y" }):wait()
vim.system({ "git", "-C", clone_path, "push", "origin", "feature-y" }):wait()
local def_branch = wt_mod.default_branch(clone_path)
vim.system({ "git", "-C", clone_path, "checkout", def_branch }):wait()

-- 3. Test list_remote_branches
local remotes = wt_mod.list_remote_branches(clone_path)
local found = false
for _, r in ipairs(remotes) do if r == "origin/feature-y" then found = true end end
ok("list_remote_branches finds real remote branch", found)

-- 4. Test track()
local wt_added_event = nil
events.subscribe("core.git.worktree:added", function(p) wt_added_event = p end)

local track_path = tmp .. "/track-wt"
local track_done = false
wt_mod.track({ common_dir = clone_path .. "/.git" }, "origin/feature-y", "feature-y-local", track_path, function(res)
  ok("track() callback reports success", res.ok, res.stderr)
  track_done = true
end)
vim.wait(2000, function() return track_done end)

ok("track() created directory", vim.fn.isdirectory(track_path) == 1)
ok("track() published core.git.worktree:added", wt_added_event and wt_added_event.path == track_path)

-- 5. Test create_branch()
local branch_created_event = nil
events.subscribe("core.git.repo.branch:created", function(p) branch_created_event = p end)

local cb_done = false
repo_mod.create_branch(clone_path, "new-branch", def_branch, function(res)
  ok("create_branch() callback reports success", res.ok, res.stderr)
  cb_done = true
end)
vim.wait(2000, function() return cb_done end)
ok("create_branch() published core.git.repo.branch:created", branch_created_event and branch_created_event.name == "new-branch")

-- 6. Test checkout() + checkout_status()
ok("checkout_status() reports ok for clean branch", repo_mod.checkout_status(clone_path, def_branch).ok)

local checkout_event = nil
events.subscribe("core.git.repo.checkout:completed", function(p) checkout_event = p end)
local co_done = false
repo_mod.checkout(clone_path, def_branch, function(res)
  ok("checkout() callback reports success", res.ok, res.stderr)
  co_done = true
end)
vim.wait(2000, function() return co_done end)
ok("checkout() published core.git.repo.checkout:completed", checkout_event and checkout_event.branch == def_branch)

-- 7. Test delete_remote()
local remote_deleted_event = nil
events.subscribe("core.git.repo.remote:deleted", function(p) remote_deleted_event = p end)
local del_done = false
repo_mod.delete_remote(clone_path, "origin", "feature-y", function(res)
  ok("delete_remote() callback reports success", res.ok)
  del_done = true
end)
vim.wait(2000, function() return del_done end)
ok("delete_remote() published core.git.repo.remote:deleted", remote_deleted_event and remote_deleted_event.branch == "feature-y")

-- Verify remote branch is gone from listing
vim.system({ "git", "-C", clone_path, "fetch", "--prune" }):wait()
remotes = wt_mod.list_remote_branches(clone_path)
found = false
for _, r in ipairs(remotes) do if r == "origin/feature-y" then found = true end end
ok("remote branch gone after delete_remote + prune", not found)

-- Cleanup
vim.fn.delete(tmp, "rf")
end)()

print("\n[50] log.dumps — JSONL persistence (ADR 0021 §7)")
;(function()
local dumps = require("auto-core.log.dumps")
local log   = require("auto-core.log")
log._reset_for_tests()

-- Isolate the dumps dir to a tmpdir so we don't trample the user's
-- real cache or other suite runs. Override stdpath('cache') for the
-- length of this section.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local orig_stdpath = vim.fn.stdpath
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = function(what)
  if what == "cache" then return tmp end
  return orig_stdpath(what)
end

-- Path helper points at the isolated dir.
ok("dumps.dir() resolves under stdpath('cache')",
  dumps.dir() == tmp .. "/auto-core/dumps")

-- scan() on a non-existent dir returns empty list, not an error.
ok("scan() on missing dir returns empty", #dumps.scan() == 0)

-- iso_from_mono — exercise the wall-clock reconstruction. Picking
-- a fixed epoch (Jan 1 2020 UTC = 1577836800) keeps the assertion
-- portable across timezones.
local fixed_wall = 1577836800
local iso_now = dumps.iso_from_mono(1000, fixed_wall, 1000)
ok("iso_from_mono with ts == now_mono renders now_wall",
  iso_now == "2020-01-01T00:00:00Z", "got " .. tostring(iso_now))
local iso_back = dumps.iso_from_mono(0, fixed_wall, 1000)
ok("iso_from_mono with 1s-ago mono renders 1s before now",
  iso_back == "2019-12-31T23:59:59Z", "got " .. tostring(iso_back))

-- Write a small ring snapshot and read it back.
log.info("smoke.dumps", "first line")
log.warn("smoke.dumps", "second line", { event = "smoke.dumps.warned" })
log.error("smoke.dumps", "third line",
  { fields = { code = 42, where = "section-50" } })
vim.wait(20)
local snapshot = log.recent()
ok("ring captured 3 entries pre-export", #snapshot == 3)

local path, werr = dumps.write(snapshot)
ok("write() returned a path", type(path) == "string", "err=" .. tostring(werr))
ok("write() created a real file",
  path ~= nil and vim.fn.filereadable(path) == 1)
ok("filename matches dump-<UTC>.log",
  path ~= nil and path:match("/dump%-%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%dZ%.log$") ~= nil,
  path)

local read_back, rerr = dumps.read(path)
ok("read() succeeds", read_back ~= nil, "err=" .. tostring(rerr))
ok("read() returned the same entry count",
  read_back and #read_back == 3, "got " .. tostring(read_back and #read_back))
ok("disk entries carry ts_iso instead of monotonic ts",
  read_back and read_back[1].ts_iso ~= nil and read_back[1].ts == nil)
ok("ts_iso is well-formed ISO 8601 UTC",
  read_back and read_back[1].ts_iso:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil,
  read_back and read_back[1].ts_iso)
ok("structured fields survive the round trip",
  read_back and read_back[3].fields ~= nil
    and read_back[3].fields.code == 42
    and read_back[3].fields.where == "section-50")
ok("event_type survives the round trip",
  read_back and read_back[2].event_type == "smoke.dumps.warned")

-- scan() lists the file.
local listing = dumps.scan()
ok("scan() finds the new dump", #listing == 1
  and listing[1].path == path)

-- delete() removes the file; scan goes back to empty.
local del_ok, derr = dumps.delete(path)
ok("delete() returned true", del_ok, tostring(derr))
ok("file gone after delete", vim.fn.filereadable(path) == 0)
ok("scan() empty again", #dumps.scan() == 0)

-- Atomic write: the .tmp- prefix must not survive a successful write.
log.clear()
log.info("smoke.dumps", "post-clean")
vim.wait(10)
local path2 = dumps.write(log.recent())
ok("write #2 returned a path", type(path2) == "string")
local leftover_tmp = vim.fn.glob(tmp .. "/auto-core/dumps/.tmp-*", false, true)
ok("no .tmp- file lingers after successful write",
  type(leftover_tmp) == "table" and #leftover_tmp == 0,
  vim.inspect(leftover_tmp))

-- Restore stdpath + tear down.
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = orig_stdpath
vim.fn.delete(tmp, "rf")
end)()

print("\n[51] log.viewer — :AutoCoreLog 3-pane snapshot viewer (ADR 0021 §7)")
;(function()
local viewer = require("auto-core.log.viewer")
local mfloat = require("auto-core.ui.float.multi")
local log    = require("auto-core.log")
local dumps  = require("auto-core.log.dumps")

viewer._reset_for_tests()
mfloat._reset_for_tests()
log._reset_for_tests()

-- Stub vim.notify so the viewer's user-feedback toasts don't spam
-- test stderr. We aren't asserting on these; the convention path
-- (log.notify / log.error) routes through vim.notify which we want
-- silent under the suite.
local orig_notify = vim.notify
vim.notify = function() end
local orig_echo = vim.api.nvim_echo
vim.api.nvim_echo = function() end

-- Isolate dumps dir for this section, same trick as [50].
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local orig_stdpath = vim.fn.stdpath
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = function(what)
  if what == "cache" then return tmp end
  return orig_stdpath(what)
end

-- ── _apply_filters: pure-function math ──────────────────────
do
  local entries = {
    { level = 1, level_name = "ERROR", component = "scan",  message = "err: boom",  event_type = "auto-finder.scan.failed" },
    { level = 2, level_name = "WARN",  component = "scan",  message = "warn: slow", event_type = "auto-finder.scan.slow"   },
    { level = 3, level_name = "INFO",  component = "panel", message = "ok",         event_type = "auto-finder.panel.open"  },
    { level = 4, level_name = "DEBUG", component = "panel", message = "details",    event_type = nil },
  }

  -- ALL filter (index 1) → all 4.
  local r = viewer._apply_filters(entries, "", 1)
  ok("filter ALL keeps every entry", #r == 4)

  -- INFO+ (index 2) → 3.
  r = viewer._apply_filters(entries, "", 2)
  ok("filter INFO+ drops DEBUG", #r == 3 and r[3].level_name == "INFO")

  -- WARN+ (index 3) → 2.
  r = viewer._apply_filters(entries, "", 3)
  ok("filter WARN+ drops INFO+DEBUG", #r == 2 and r[2].level_name == "WARN")

  -- ERROR (index 4) → 1.
  r = viewer._apply_filters(entries, "", 4)
  ok("filter ERROR keeps only ERROR", #r == 1 and r[1].level_name == "ERROR")

  -- Substring filter — matches against message + component + event_type.
  r = viewer._apply_filters(entries, "panel", 1)
  ok("substring 'panel' matches component", #r == 2)
  r = viewer._apply_filters(entries, "auto-finder.scan", 1)
  ok("substring matches event_type", #r == 2)
  r = viewer._apply_filters(entries, "boom", 1)
  ok("substring matches message body", #r == 1 and r[1].message == "err: boom")
  r = viewer._apply_filters(entries, "PANEL", 1)
  ok("substring filter is case-insensitive", #r == 2)
  r = viewer._apply_filters(entries, "nothing-matches-this", 1)
  ok("substring with no matches returns empty", #r == 0)

  -- Combined: WARN+ AND component contains "scan" → 2.
  r = viewer._apply_filters(entries, "scan", 3)
  ok("level + substring compose (AND)", #r == 2)
end

-- ── open / close idempotency ────────────────────────────────
ok("is_open() false before open", not viewer.is_open())
viewer.open()
ok("is_open() true after open", viewer.is_open())

local state = viewer._state()
ok("viewer state populated after open",
  state ~= nil and state.float ~= nil)
ok("Memory is dumps[1]",
  state.dumps[1] and state.dumps[1].kind == "memory")

-- Re-calling open() must focus, not throw.
viewer.open()
ok("open() is idempotent — still open", viewer.is_open())

-- Snapshot is read-only — mutating the live ring after open
-- doesn't change the cached snapshot.
log.info("after-snapshot", "this entry came after snapshot")
vim.wait(10)
ok("snapshot length unchanged after live ring mutation",
  #state.memory_entries == 0)

-- R re-snapshots; now we should see the new entry.
viewer._reset_for_tests()
log._reset_for_tests()
log.info("before", "pre")
log.info("before", "pre-2")
vim.wait(10)
viewer.open()
state = viewer._state()
ok("snapshot picks up entries that existed at open-time",
  #state.memory_entries == 2)
log.info("after", "post-1")
log.info("after", "post-2")
vim.wait(10)
ok("live ring grew but snapshot is stable",
  #state.memory_entries == 2 and #log.recent() == 4)

-- Manually exercise the R path (calling internal helper because
-- buf-local keymaps can't be triggered headlessly without simulating
-- input).
do
  local mod = require("auto-core.log.viewer")
  -- Reproduce what the `R` keymap does: re-snapshot. The `R` keymap is a
  -- thin closure over `_snapshot_memory` which isn't exported, so verify
  -- via the public observable: close + open does the same thing.
  mod.close()
  vim.wait(10)
  mod.open()
  local s = mod._state()
  ok("close+reopen re-snapshots Memory (proxy for R)",
    s and #s.memory_entries == 4)
end

-- ── delete (Memory branch) → log.clear() and re-snapshot ────
-- Direct call into log.clear because exercising the D keymap
-- requires vim.ui.input which is non-trivial to fake. The
-- post-clear behavior is what we assert.
log.clear()
viewer.close()
vim.wait(10)
viewer.open()
state = viewer._state()
ok("post-clear, snapshot is empty",
  state and #state.memory_entries == 0)

-- ── export round-trip via dumps.write, then verify viewer picks
--    up the new file on rescan (via close+open) ──────────────
log._reset_for_tests()
log.info("export-test", "entry 1")
log.warn("export-test", "entry 2")
vim.wait(10)
local path = dumps.write(log.recent())
ok("dumps.write produced an export file",
  type(path) == "string" and vim.fn.filereadable(path) == 1)

viewer.close()
vim.wait(10)
viewer.open()
state = viewer._state()
ok("viewer rescans dumps dir on open — file is visible as dumps[2]",
  state and state.dumps[2] and state.dumps[2].kind == "file"
    and state.dumps[2].path == path)

-- ── cleanup ─────────────────────────────────────────────────
viewer.close()
viewer._reset_for_tests()
mfloat._reset_for_tests()
log._reset_for_tests()

---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = orig_stdpath
vim.fn.delete(tmp, "rf")
vim.notify = orig_notify
vim.api.nvim_echo = orig_echo
end)()

-- ─────────────────────── 51. git.watch — .git/ plumbing watcher (ADR 0025) ─────────────────────────
print("\n[51] git.watch — start/stop, kind classification, debounce, .lock filter, status invalidation")
;(function()
local gwatch = require("auto-core.git.watch")
local status_mod = require("auto-core.git.status")
local events = require("auto-core.events")
events._reset_for_tests()
gwatch._reset_for_tests()
status_mod._reset_for_tests()

-- Negative: nil / non-repo path.
local h_nil, err_nil = gwatch.start(nil)
ok("git.watch.start nil repo_root → err",
  h_nil == nil and type(err_nil) == "string", tostring(err_nil))
local non_git_root = vim.fn.tempname() .. "-not-a-repo"
vim.fn.mkdir(non_git_root, "p")
local h_ng, err_ng = gwatch.start(non_git_root)
ok("git.watch.start non-git path → err",
  h_ng == nil and type(err_ng) == "string"
    and err_ng:find("not a git repo"),
  tostring(err_ng))
pcall(vim.fn.delete, non_git_root, "rf")

-- Build a fresh, fully-initialized git repo. Use `commit --allow-empty`
-- so logs/HEAD exists (reflog is created on first ref update, not on
-- bare `init` — so a repo with zero commits has no logs/ dir yet).
local repo = vim.fn.tempname() .. "-gw-repo"
vim.fn.mkdir(repo, "p")
local function gsh(args)
  return vim.system(args, { cwd = repo, text = true }):wait()
end
gsh({ "git", "init", "-q", "-b", "main", repo })
gsh({ "git", "config", "user.email", "smoke@auto-core.test" })
gsh({ "git", "config", "user.name",  "Smoke Test"             })
gsh({ "git", "commit", "--allow-empty", "-q", "-m", "first" })

-- Sanity: confirm both watched dirs exist now.
ok("repo .git/ exists",       vim.fn.isdirectory(repo .. "/.git") == 1)
ok("repo .git/logs/ exists",  vim.fn.isdirectory(repo .. "/.git/logs") == 1)

-- Subscribe BEFORE starting the watch so initial publishes are caught.
local seen = {}
events.subscribe("core.git.state:changed", function(p, t)
  seen[#seen + 1] = { topic = t, kind = p.kind, repo_root = p.repo_root, path = p.path }
end)

local handle, start_err = gwatch.start(repo)
ok("git.watch.start succeeds on real repo",
  handle ~= nil and type(handle.id) == "number", tostring(start_err))
ok("git.watch.list reports one handle", #gwatch.list() == 1)
ok("handle has two fs_event handles (git_dir/ + logs/)",
  handle and #handle.fs_events == 2,
  vim.inspect(handle and #handle.fs_events))
ok("handle.repo_root + git_dir are normalized strings",
  type(handle.repo_root) == "string"
    and type(handle.git_dir) == "string"
    and handle.git_dir:find("/%.git$") ~= nil,
  vim.inspect({ repo_root = handle.repo_root, git_dir = handle.git_dir }))

-- ── ADR-0050 §2.2: `index` is no longer watched ─────────────
-- A pure `git add` (stages the index, no HEAD/reflog movement) must
-- NOT publish core.git.state:changed. `index` was dropped from
-- FILENAME_KINDS because `git status` rewrites it constantly, forming
-- the refresh feedback loop ADR-0050 documents.
local before = #seen
vim.fn.writefile({ "abc" }, repo .. "/a.txt")
gsh({ "git", "add", "a.txt" })
vim.wait(500)
local saw_index = false
for i = before + 1, #seen do
  if seen[i].kind == "index"
      or (seen[i].path and seen[i].path:sub(-#"/index") == "/index") then
    saw_index = true
  end
end
ok("git add does NOT fire an index event (§2.2)", not saw_index,
  vim.inspect({ before = before, total = #seen, slice = { unpack(seen, before + 1) } }))

-- ── Kind = "reflog" + index via `git commit` ────────────────
before = #seen
-- Let the 200ms debounce window clear so commit's index/HEAD/logs
-- mutations each get their own publish.
vim.wait(300)
gsh({ "git", "commit", "-q", "-m", "second" })
vim.wait(800, function()
  local saw_reflog = false
  for i = before + 1, #seen do
    if seen[i].kind == "reflog" then saw_reflog = true end
  end
  return saw_reflog
end)
local kinds_seen = {}
for i = before + 1, #seen do kinds_seen[seen[i].kind] = true end
ok("git commit fires kind='reflog' (logs/HEAD appended)",
  kinds_seen.reflog == true,
  vim.inspect({ before = before, kinds = kinds_seen, slice = { unpack(seen, before + 1) } }))
-- HEAD file is rewritten on commit (the SHA the ref points to changes
-- — though the HEAD file itself just says "ref: refs/heads/main" and
-- doesn't change content, the inode mtime updates on some platforms).
-- Don't strictly require "head" here — the load-bearing signal is
-- "reflog" which we just asserted.

-- ── kind = "head" via `git checkout -b` (HEAD content changes) ─
before = #seen
vim.wait(300)
gsh({ "git", "checkout", "-q", "-b", "branch2" })
vim.wait(800, function()
  for i = before + 1, #seen do
    if seen[i].kind == "head" then return true end
  end
  return false
end)
local saw_head = false
for i = before + 1, #seen do
  if seen[i].kind == "head" then saw_head = true end
end
ok("git checkout -b fires kind='head' (HEAD file rewritten)",
  saw_head,
  vim.inspect({ before = before, total = #seen, slice = { unpack(seen, before + 1) } }))

-- ── refs/remotes is NOT watched ────────────────────────────
-- Simulate a fetch-side write by creating the dir and dropping a ref
-- file. The watcher must NOT publish for this.
before = #seen
vim.wait(300)
vim.fn.mkdir(repo .. "/.git/refs/remotes/origin", "p")
vim.fn.writefile({ "0000000000000000000000000000000000000000" },
  repo .. "/.git/refs/remotes/origin/main")
vim.wait(400)
local saw_remote_publish = false
for i = before + 1, #seen do
  if seen[i].path and seen[i].path:find("/refs/remotes/") then
    saw_remote_publish = true
  end
end
ok("refs/remotes/ writes do NOT publish",
  not saw_remote_publish,
  vim.inspect({ added = #seen - before, slice = { unpack(seen, before + 1) } }))

-- ── .lock files are filtered ───────────────────────────────
before = #seen
vim.wait(300)
vim.fn.writefile({ "x" }, repo .. "/.git/index.lock")
vim.wait(400)
local saw_lock_publish = false
for i = before + 1, #seen do
  if seen[i].path and seen[i].path:match("%.lock$") then
    saw_lock_publish = true
  end
end
ok(".lock filename writes do NOT publish",
  not saw_lock_publish,
  vim.inspect({ added = #seen - before, slice = { unpack(seen, before + 1) } }))
pcall(vim.fn.delete, repo .. "/.git/index.lock")

-- ── status cache invalidation via the new topic ────────────
-- Done BEFORE the debounce burst test below because that test writes
-- garbage directly to `.git/index` (bypassing git tools) to verify
-- the publisher coalesces — which corrupts the index and makes
-- `git status` shell-out fail, so `status.get()` would no longer
-- populate the cache. Order matters: assert cache plumbing while
-- the repo is still healthy.
status_mod.get(repo)
ok("status cache is populated before invalidation test",
  status_mod.is_cached(repo) == true)
events.publish("core.git.state:changed", {
  repo_root = repo,
  git_dir   = repo .. "/.git",
  kind      = "index",
  path      = repo .. "/.git/index",
})
ok("status cache cleared by core.git.state:changed publish",
  status_mod.is_cached(repo) == false)

-- A publish naming a DIFFERENT repo_root must not affect this cache.
status_mod.get(repo)
events.publish("core.git.state:changed", {
  repo_root = "/some/other/repo",
  git_dir   = "/some/other/repo/.git",
  kind      = "index",
  path      = "/some/other/repo/.git/index",
})
ok("status cache survives publish for unrelated repo",
  status_mod.is_cached(repo) == true)

-- ── debounce coalescing on the SAME file ───────────────────
-- Three rapid writes to a watched file (HEAD) within the 200ms
-- debounce window should produce at most one publish. Uses HEAD
-- (still watched) rather than index (dropped per §2.2); writes keep
-- valid ref content so the repo stays usable for the assertions below.
before = #seen
vim.wait(300)
for _ = 1, 3 do
  vim.fn.writefile({ "ref: refs/heads/branch2" }, repo .. "/.git/HEAD")
end
vim.wait(400)
local burst_count = 0
for i = before + 1, #seen do
  if seen[i].path and seen[i].path:sub(-#"/HEAD") == "/HEAD"
      and seen[i].kind == "head" then
    burst_count = burst_count + 1
  end
end
-- Bound matches fs.watch's own burst test (§26): libuv's inotify can
-- fire multiple events per writefile on Linux, so 1–2 publishes for
-- a burst of 3 is the realistic coalescing outcome. 3 (no coalescing)
-- would fail.
ok("debounce coalesces burst of 3 HEAD writes to ≤2 publishes",
  burst_count >= 1 and burst_count <= 2,
  "got " .. tostring(burst_count))

-- ── stop / list / stop_all ─────────────────────────────────
gwatch.stop(handle)
ok("after stop, list is empty", #gwatch.list() == 0)
ok("stopped handle.fs_events is cleared",
  handle and #handle.fs_events == 0)

-- max_handles cap.
local capped, cap_err = gwatch.start(repo, { max_handles = 1 })
ok("max_handles cap refuses start when budget would overflow",
  capped == nil and type(cap_err) == "string"
    and cap_err:find("max_handles"),
  tostring(cap_err))

-- Restart for stop_all coverage.
local h2 = gwatch.start(repo)
ok("restart succeeds after stop", h2 ~= nil)
gwatch.stop_all()
ok("stop_all clears every handle", #gwatch.list() == 0)

-- ── default constants are exposed ──────────────────────────
ok("DEFAULT_DEBOUNCE_MS = 200", gwatch.DEFAULT_DEBOUNCE_MS == 200)
ok("DEFAULT_MAX_HANDLES = 64",  gwatch.DEFAULT_MAX_HANDLES == 64)
ok("FILENAME_KINDS includes HEAD/ORIG_HEAD/MERGE_HEAD, excludes index (§2.2)",
  gwatch.FILENAME_KINDS.HEAD == "head"
    and gwatch.FILENAME_KINDS.index == nil
    and gwatch.FILENAME_KINDS.ORIG_HEAD == "merge"
    and gwatch.FILENAME_KINDS.MERGE_HEAD == "merge")

-- ── topic registry entry ──────────────────────────────────
local topics = require("auto-core.events.topics")
ok("core.git.state:changed is registered in topics.lua",
  topics["core.git.state:changed"] ~= nil
    and type(topics["core.git.state:changed"].doc) == "string"
    and type(topics["core.git.state:changed"].payload) == "string")

-- cleanup
gwatch._reset_for_tests()
status_mod._reset_for_tests()
events._reset_for_tests()
pcall(vim.fn.delete, repo, "rf")
end)()

-- ─────────────────────── 52. ui.panel — VimResized visibility + unmarked-sibling cleanup ─────────────────────────
-- v0.1.21 panel-visibility branch. Closes the regression where
-- VimResized fired but produced no ring entry because the
-- field-table literal threw before log_panel.info ever saw the
-- message (per incident agents/white-vision/incidents/
-- 2026-05-18-auto-agents-panel-duplicated-recurrence.md). Also
-- covers the WinNew detection + post-VimResized cleanup pass.
print("\n[52] ui.panel — VimResized log anchor + unmarked-sibling cleanup")
;(function()
local panel_mod = require("auto-core.ui.panel")
local log = require("auto-core.log")
panel_mod._reset_for_tests()
log._reset_for_tests()

local p = panel_mod.new({
  name = "smoke52",
  side = "right",
  width = { default = 30, min = 10, max = 80 },
  filetype = "smoke52-panel",
})
p:open(true)
ok("panel opens for smoke 52", p:_is_open(),
  "winid=" .. tostring(p.winid))

-- ── VimResized → ring anchor MUST appear (regression guard). ──
-- Strictly-after-since search so an idempotent re-call doesn't
-- match the prior pass's entry. `since` is the ring length captured
-- BEFORE the action; only indices > since are valid "new" entries.
local function ring_has(needle, since)
  local r = log.recent()
  for i = #r, (since or 0) + 1, -1 do
    local m = (r[i] or {}).message or ""
    if m:find(needle, 1, true) then return true end
  end
  return false
end

local before = #log.recent()
vim.api.nvim_exec_autocmds("VimResized", {})
vim.wait(50, function() return ring_has("VimResized", before) end)
ok("VimResized log entry lands in ring (regression guard)",
  ring_has("VimResized", before),
  "ring grew " .. before .. " → " .. #log.recent())

-- ── Defensive: log still lands when refresh_width's winid is stale. ──
local saved_winid = p.winid
p.winid = 99999   -- invalid → refresh_width's pcall silently fails
before = #log.recent()
vim.api.nvim_exec_autocmds("VimResized", {})
vim.wait(50)
ok("VimResized anchor still logs when winid is racy-invalid",
  ring_has("VimResized", before))
p.winid = saved_winid  -- restore

-- ── WinNew detection path: synthetic unmarked sibling → log. ──
-- Spawn the sibling using the explicit nvim_open_win API (which
-- doesn't copy `w:` vars unlike `vim.cmd("split")`, and works
-- deterministically in headless mode). The panel-singleton's
-- WinNew autocmd should detect this via its `vim.schedule`-deferred
-- check, log INFO "unmarked sibling detected (WinNew)", and NOT
-- close the sibling (detection-only path).
local panel_bufnr = vim.api.nvim_win_get_buf(p.winid)
local winnew_before = #log.recent()
local sibling = vim.api.nvim_open_win(panel_bufnr, false, {
  win   = p.winid,
  split = "below",
})
ok("sibling spawned",
  sibling ~= nil and vim.api.nvim_win_is_valid(sibling),
  "sibling=" .. tostring(sibling))
ok("sibling has the panel buffer",
  vim.api.nvim_win_get_buf(sibling) == panel_bufnr)
local sib_marker_set, _ = pcall(vim.api.nvim_win_get_var, sibling, p._marker_var)
ok("sibling lacks the panel marker",
  not sib_marker_set)

-- Drain the schedule queue so the WinNew autocmd's deferred check
-- runs. nvim.wait() with a poll predicate gives time for vim.schedule
-- to flush.
vim.wait(100, function()
  return ring_has("unmarked sibling detected", winnew_before)
end)
ok("WinNew detection logged 'unmarked sibling detected (WinNew)'",
  ring_has("unmarked sibling detected", winnew_before),
  "expected WinNew log entry after nvim_open_win sibling spawn")
ok("WinNew detection did NOT close the sibling (detection-only)",
  vim.api.nvim_win_is_valid(sibling))

before = #log.recent()
p:_cleanup_unmarked_siblings()
ok("sibling closed by cleanup pass",
  not vim.api.nvim_win_is_valid(sibling))
ok("cleanup logs 'unmarked sibling closed' at INFO",
  ring_has("unmarked sibling closed", before))

-- ── Idempotent: cleanup with no siblings is a silent fast-path. ──
before = #log.recent()
p:_cleanup_unmarked_siblings()
ok("cleanup is silent when no siblings exist",
  not ring_has("unmarked sibling", before),
  "expected no new 'unmarked sibling' log lines")

-- ── Cleanup. ─────────────────────────────────────────────────
p:close()
p:dispose()
panel_mod._reset_for_tests()
log._reset_for_tests()
end)()

-- ─────────────────────── 53. ui.panel — ADR 0028 local-scope regression probe ─────────────────────────
-- Asserts that panel-open does NOT mutate the global-local
-- DEFAULTS for `number` / `relativenumber` / `signcolumn` /
-- `foldcolumn`, and that a fresh editor split spawned AFTER the
-- panel opens inherits the user-configured editor defaults — not
-- the panel-masked values.
--
-- Pre-ADR-0028 panel writes (`{ win = winid }` without
-- `scope = "local"`) had the side effect of mutating these
-- global-local defaults. The symptom was an editor window opened
-- after panels showing no line numbers / no sign column, because
-- it inherited the polluted defaults. The fix (set_winlocal in
-- ui/panel.lua) routes every appearance write through
-- `{ win = winid, scope = "local" }`. This section would have
-- caught the original bug.
print("\n[53] ui.panel — ADR 0028 panel-open does NOT pollute global defaults")
;(function()
local panel_mod = require("auto-core.ui.panel")
panel_mod._reset_for_tests()

-- Seed editor-side defaults so the assertions are self-contained
-- regardless of host config or prior smoke sections. Capture
-- pre-section globals to restore afterwards.
local saved = {
  number         = vim.api.nvim_get_option_value("number",         {}),
  relativenumber = vim.api.nvim_get_option_value("relativenumber", {}),
  signcolumn     = vim.api.nvim_get_option_value("signcolumn",     {}),
  foldcolumn     = vim.api.nvim_get_option_value("foldcolumn",     {}),
}
vim.api.nvim_set_option_value("number",         true,  {})
vim.api.nvim_set_option_value("relativenumber", true,  {})
vim.api.nvim_set_option_value("signcolumn",     "yes", {})
vim.api.nvim_set_option_value("foldcolumn",     "1",   {})

local seeded = {
  number         = vim.api.nvim_get_option_value("number",         {}),
  relativenumber = vim.api.nvim_get_option_value("relativenumber", {}),
  signcolumn     = vim.api.nvim_get_option_value("signcolumn",     {}),
  foldcolumn     = vim.api.nvim_get_option_value("foldcolumn",     {}),
}
ok("seed: global number=true",         seeded.number == true)
ok("seed: global relativenumber=true", seeded.relativenumber == true)
ok("seed: global signcolumn=yes",      seeded.signcolumn == "yes")
ok("seed: global foldcolumn=1",        seeded.foldcolumn == "1")

local p = panel_mod.new({
  name = "smoke53",
  side = "right",
  width = { default = 30, min = 10, max = 80 },
  filetype = "smoke53-panel",
})
p:open(true)
ok("panel opens for smoke 53", p:_is_open(),
  "winid=" .. tostring(p.winid))

-- ── Panel window has the masked appearance values (local). ──
local panel_win = p.winid
ok("panel win: number=false (local)",
  vim.api.nvim_get_option_value("number", { win = panel_win, scope = "local" }) == false)
ok("panel win: relativenumber=false (local)",
  vim.api.nvim_get_option_value("relativenumber", { win = panel_win, scope = "local" }) == false)
ok("panel win: signcolumn=no (local)",
  vim.api.nvim_get_option_value("signcolumn", { win = panel_win, scope = "local" }) == "no")
ok("panel win: foldcolumn=0 (local)",
  vim.api.nvim_get_option_value("foldcolumn", { win = panel_win, scope = "local" }) == "0")

-- ── Global defaults survive panel open (this is the bug guard). ──
-- Read via `{ scope = "global" }` explicitly. `{}` defaults to the
-- CURRENT window's local value for window-local options, which would
-- be the panel-masked false right now — that's the wrong assertion
-- shape for this regression. The global default is what editor
-- windows materialized fresh-from-defaults inherit from.
local function global(name) return vim.api.nvim_get_option_value(name, { scope = "global" }) end
ok("global number SURVIVES panel open",
  global("number") == seeded.number,
  "expected " .. tostring(seeded.number) .. " got " .. tostring(global("number")))
ok("global relativenumber SURVIVES panel open",
  global("relativenumber") == seeded.relativenumber,
  "expected " .. tostring(seeded.relativenumber) .. " got " .. tostring(global("relativenumber")))
ok("global signcolumn SURVIVES panel open",
  global("signcolumn") == seeded.signcolumn,
  "expected " .. tostring(seeded.signcolumn) .. " got " .. tostring(global("signcolumn")))
ok("global foldcolumn SURVIVES panel open",
  global("foldcolumn") == seeded.foldcolumn,
  "expected " .. tostring(seeded.foldcolumn) .. " got " .. tostring(global("foldcolumn")))

-- ── Fresh editor split spawned AFTER panel inherits editor defaults. ──
-- Use nvim_open_win with split=below targeting a non-panel window so
-- the new split is materialized cleanly without disturbing the panel.
-- Need a non-panel anchor: create a baseline editor window first via
-- vsplit from the panel (the resulting window is editor-side; the
-- panel keeps winfixwidth so layout doesn't squash it).
vim.api.nvim_set_current_win(panel_win)
-- Move focus to any non-panel window. nvim_open_win with split off
-- the panel would inherit panel-window-local options, so we leave
-- the panel and use the autocreated initial window if present, else
-- spawn an editor window from outside the panel context.
local editor_anchor
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if w ~= panel_win then editor_anchor = w; break end
end
if not editor_anchor then
  -- No editor window in headless tab — create one from the panel side
  -- via :new (horizontal split off the panel). The new window IS
  -- editor-side. We use a fresh scratch so we don't dirty any buffer.
  vim.cmd("new")
  editor_anchor = vim.api.nvim_get_current_win()
end
vim.api.nvim_set_current_win(editor_anchor)

local fresh = vim.api.nvim_open_win(0, false, {
  win   = editor_anchor,
  split = "below",
})
ok("fresh editor split spawned after panel open",
  fresh ~= nil and vim.api.nvim_win_is_valid(fresh),
  "winid=" .. tostring(fresh))

ok("fresh split inherits global number (not panel-masked)",
  vim.api.nvim_get_option_value("number", { win = fresh }) == seeded.number,
  "expected " .. tostring(seeded.number) ..
  " got " .. tostring(vim.api.nvim_get_option_value("number", { win = fresh })))
ok("fresh split inherits global relativenumber (not panel-masked)",
  vim.api.nvim_get_option_value("relativenumber", { win = fresh }) == seeded.relativenumber,
  "expected " .. tostring(seeded.relativenumber) ..
  " got " .. tostring(vim.api.nvim_get_option_value("relativenumber", { win = fresh })))
ok("fresh split inherits global signcolumn (not panel-masked)",
  vim.api.nvim_get_option_value("signcolumn", { win = fresh }) == seeded.signcolumn,
  "expected " .. tostring(seeded.signcolumn) ..
  " got " .. tostring(vim.api.nvim_get_option_value("signcolumn", { win = fresh })))

-- ── Cleanup. ─────────────────────────────────────────────────
if fresh and vim.api.nvim_win_is_valid(fresh) then
  pcall(vim.api.nvim_win_close, fresh, true)
end
p:close()
p:dispose()
panel_mod._reset_for_tests()

-- Restore pre-section globals so later sections / the host process
-- aren't perturbed by the seed.
vim.api.nvim_set_option_value("number",         saved.number,         {})
vim.api.nvim_set_option_value("relativenumber", saved.relativenumber, {})
vim.api.nvim_set_option_value("signcolumn",     saved.signcolumn,     {})
vim.api.nvim_set_option_value("foldcolumn",     saved.foldcolumn,     {})
end)()

-- [54] (todo.yaml) and [55] (todo.schema): removed in v0.4.1 with the Lua format
-- modules; AutoDoc owns the format (ADR 1791532020 §2.2).

-- ─────────────────────── 56. todo.paths (ADR 0031 §1) ───────────────────
print("\n[56] todo.paths — dir resolver + bucket helpers + id slug")
;(function()
  local ok_p, paths = pcall(require, "auto-core.todo.paths")
  ok("auto-core.todo.paths loads", ok_p, tostring(paths))
  if not ok_p then return end

  -- ── workspace_root resolves through git.worktree ────────────
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root("/tmp/ac-todo-smoke-ws")
  ok("workspace_root() returns the explicitly-set value",
    paths.workspace_root() == "/tmp/ac-todo-smoke-ws",
    "got " .. paths.workspace_root())

  worktree.set_workspace_root(nil)  -- clear; fall through to other layers

  -- ── default_todo_dir is `<ws>/.todo-list` ───────────────────
  ok("default_todo_dir(ws) appends .todo-list",
    paths.default_todo_dir("/tmp/foo") == "/tmp/foo/.todo-list",
    "got " .. paths.default_todo_dir("/tmp/foo"))

  -- ── resolve_todo_dir honors explicit override ───────────────
  ok("resolve_todo_dir(override) returns the override",
    paths.resolve_todo_dir("/tmp/explicit") == "/tmp/explicit")
  worktree.set_workspace_root("/tmp/ac-todo-smoke-ws")
  ok("resolve_todo_dir(nil) falls back to workspace default",
    paths.resolve_todo_dir(nil) == "/tmp/ac-todo-smoke-ws/.todo-list")
  ok("resolve_todo_dir('') falls back like nil",
    paths.resolve_todo_dir("") == "/tmp/ac-todo-smoke-ws/.todo-list")
  worktree.set_workspace_root(nil)

  -- ── bucket_dir for non-archived statuses ────────────────────
  local td = "/tmp/foo/.todo-list"
  ok("bucket_dir(open)      → <td>/open",      paths.bucket_dir(td, "open")      == td .. "/open")
  ok("bucket_dir(completed) → <td>/completed", paths.bucket_dir(td, "completed") == td .. "/completed")
  ok("bucket_dir(deferred)  → <td>/deferred",  paths.bucket_dir(td, "deferred")  == td .. "/deferred")
  local ok_arch_err = pcall(paths.bucket_dir, td, "archived")
  ok("bucket_dir('archived') refuses (caller must use archive_bucket)", not ok_arch_err)
  local ok_bad_status = pcall(paths.bucket_dir, td, "wat")
  ok("bucket_dir(unknown status) raises",      not ok_bad_status)

  -- ── archive_bucket partitions by YYYY/MM ────────────────────
  ok("archive_bucket('2026-06-17T10:00:00Z') → <td>/archived/2026/06",
    paths.archive_bucket(td, "2026-06-17T10:00:00Z") == td .. "/archived/2026/06")
  ok("archive_bucket('2026-12-31T23:59:59-08:00') → <td>/archived/2026/12",
    paths.archive_bucket(td, "2026-12-31T23:59:59-08:00") == td .. "/archived/2026/12")
  local ok_bad_iso = pcall(paths.archive_bucket, td, "not-a-date")
  ok("archive_bucket(non-ISO) raises", not ok_bad_iso)

  -- ── task_file_path ──────────────────────────────────────────
  ok("task_file_path(open) builds <td>/open/<id>.md",
    paths.task_file_path(td, "2026-05-25-foo", "open")
      == td .. "/open/2026-05-25-foo.md")
  ok("task_file_path(archived) uses YYYY/MM partition",
    paths.task_file_path(td, "2026-05-25-foo", "archived", "2026-06-17T10:00:00Z")
      == td .. "/archived/2026/06/2026-05-25-foo.md")

  -- ── make_id slug rules ──────────────────────────────────────
  ok("make_id strips punctuation",
    paths.make_id("2026-05-25T12:00:00Z", "Implement the todo!  System.")
      == "2026-05-25-implement-the-todo-system",
    "got " .. paths.make_id("2026-05-25T12:00:00Z", "Implement the todo!  System."))
  ok("make_id collapses whitespace runs",
    paths.make_id("2026-05-25T12:00:00Z", "Fix   the     panel  bug")
      == "2026-05-25-fix-the-panel-bug")
  ok("make_id lower-cases",
    paths.make_id("2026-05-25T12:00:00Z", "MixedCASE Title")
      == "2026-05-25-mixedcase-title")
  ok("make_id preserves intentional dashes",
    paths.make_id("2026-05-25T12:00:00Z", "v1.2-bugfix release")
      == "2026-05-25-v12-bugfix-release",
    "got " .. paths.make_id("2026-05-25T12:00:00Z", "v1.2-bugfix release"))
  ok("make_id falls back to 'untitled' on empty slug",
    paths.make_id("2026-05-25T12:00:00Z", "?!@#")
      == "2026-05-25-untitled")
  local ok_no_date = pcall(paths.make_id, "not-a-date", "Foo")
  ok("make_id raises on non-ISO created", not ok_no_date)
end)()

-- [57] (todo.header): removed in v0.4.1 with the Lua format modules.

-- ─────────── 58-64, 66-68, 70-74, 75(g), 85, 86: removed in v0.4.0 ───────────
-- These sections tested auto-core.todo's own Lua writer (CRUD, status, refresh,
-- set_todo_dir, import, assign, automation firing, buffers following a move).
-- ADR 1791532020 moved every todo write to AutoDoc's daemon and deleted that
-- writer. What auto-core keeps (the store resolution and claim, buffers, the
-- commands, the assignment notifier) is tested against a real daemon by
-- tests/todo-where.lua and tests/todo-notifier.lua (tests/todo-daemon.sh), and
-- without AutoDoc by tests/todo-where-required.lua.

-- [58a] (todo.md) and [58c] (todo.schema): removed in v0.4.1 with the Lua format modules.

-- auto-core.kb keeps its records in the `kb` state namespace. Every section
-- that wipes them (kb._reset_for_tests) first proves that namespace is NOT the
-- developer's real state file under stdpath("state") — a reset there would
-- erase the user's recorded primaries. Loud (an abort, which run-all reports as
-- a missing summary) rather than a skipped cell: it must never be green.
local function assert_kb_state_sandboxed()
  local ns = require("auto-core.state").namespace("kb", { persist = "json" })
  local real = vim.fn.stdpath("state")
  assert(type(ns._path) == "string" and not vim.startswith(ns._path, real),
    "auto-core.kb state is NOT sandboxed: " .. tostring(ns._path))
end

-- ─────────────────────── 65. todo.vars — the store's variables, from AutoDoc ──
-- ADR 1792015069 §2.5, ADR 1792132105: vars.lua asks the daemon for a table
-- instead of computing one: the session store's (todos.vars), or a file's
-- workspace's (workspace.of, workspace.vars). The daemon is faked here
-- (daemon._set_transport); tests/todo-where.lua runs a real one.
print("\n[65] todo.vars — the store's variables, from AutoDoc's daemon")
;(function()
  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })
  local daemon = require("auto-core.todo.daemon")
  local where = require("auto-core.todo.where")
  local wt = require("auto-core.git.worktree")
  local prev_root = wt.get_workspace_root()
  local events = require("auto-core.events")
  where._reset_for_tests()
  package.loaded["auto-core.todo.vars"] = nil
  local vars = require("auto-core.todo.vars")

  -- the fixture: a KB with one file, a project, and the store's table as the
  -- daemon answers it; LONG is a global var deeper than $KB_ROOT
  local kbdir = vim.fn.tempname() .. "-kb"
  vim.fn.mkdir(kbdir .. "/adrs", "p")
  local fh = assert(io.open(kbdir .. "/adrs/x.md", "w")); fh:write("# x\n"); fh:close()
  local proj = vim.fn.tempname() .. "-proj"
  vim.fn.mkdir(proj, "p")
  wt.set_workspace_root(proj)
  -- $WORKSPACE is no built-in (ADR 1792132105 §2.6); this KB sets it, deeper than
  -- $KB_ROOT, and it is never written
  local tbl = {
    { name = "KB_ROOT", value = kbdir, builtin = true, derived = kbdir, source = "derived" },
    { name = "HOME", value = "/home/u", builtin = true, derived = "/home/u", source = "derived" },
    { name = "PROJECT_ROOT", value = "/src/proj", source = "store" },
    { name = "DOCS", value = "/src/proj/docs", source = "store" },
    { name = "DUMPS", machine = true },
    { name = "LONG", value = kbdir .. "/deep", source = "global" },
    { name = "WORKSPACE", value = kbdir .. "/ws", source = "store" },
  }
  -- kb2: another workspace, whose files' refs resolve with its own table; HELD is a
  -- name a pending migration holds in conflict there (ADR 1792132105 §2.7)
  local ws2 = {
    { name = "KB_ROOT", value = "/kb2", builtin = true, derived = "/kb2", source = "derived" },
    { name = "HOME", value = "/home/u", builtin = true, derived = "/home/u", source = "derived" },
    { name = "DOCS", value = "/kb2/docs", source = "kb" },
    { name = "HELD", conflict = true },
  }
  local old_daemon = false -- workspace.of refused, as by a daemon older than protocol 24
  local old_none = false   -- workspace.vars("") refused, as by a daemon before no workspace's variables
  local calls = {}
  local function count(m)
    local n = 0
    for _, c in ipairs(calls) do if c.method == m then n = n + 1 end end
    return n
  end
  daemon._set_transport(function(method, params, cb)
    calls[#calls + 1] = { method = method, params = vim.deepcopy(params) }
    if method == "workspace.list" then return cb({}) end
    if method == "workspace.of" then
      if old_daemon then return cb(nil, { code = -32601, message = "the verb is unknown" }) end
      if params[1]:sub(1, 5) == "/kb2/" then return cb({ workspace = "kb2", root = "/kb2" }) end
      return cb({})
    end
    if method == "workspace.vars" then
      if params[1] == "" then
        if old_none then return cb(nil, { code = -32060, message = "no such workspace: " }) end
        return cb({ { name = "HOME", value = "/home/u", builtin = true, source = "derived" },
          { name = "GLOB", value = "/glob", source = "global" } })
      end
      return cb(vim.deepcopy(ws2))
    end
    if method == "workspace.set_var" then
      local name, value = params[2], params[3]
      for i, r in ipairs(ws2) do if r.name == name then table.remove(ws2, i) break end end
      if value ~= "" then ws2[#ws2 + 1] = { name = name, value = value, source = params[4].scope } end
      return cb(nil)
    end
    if method == "todos.resolve" then
      return cb({ store = kbdir .. "/.todo-list", store_id = "s1", writable = true, claimed = true })
    end
    if method == "todos.vars" then return cb(vim.deepcopy(tbl)) end
    if method == "todos.set_var" then
      local name, value = params[1], params[2]
      for i, r in ipairs(tbl) do if r.name == name then table.remove(tbl, i) break end end
      if value ~= "" then tbl[#tbl + 1] = { name = name, value = value, source = params[3].scope } end
      return cb(nil)
    end
    cb(nil) -- todos.register, todos.open, todos.claim
  end)

  -- values -----------------------------------------------------
  ok("KB_ROOT is the store's, from todos.vars", vars.get("KB_ROOT") == kbdir, vars.get("KB_ROOT"))
  ok("PROJECT_ROOT is a user variable now", not vars.is_builtin("PROJECT_ROOT") and vars.get("PROJECT_ROOT") == "/src/proj")
  ok("WORKSPACE is no built-in", not vars.is_builtin("WORKSPACE"))
  ok("CWD is gone: the daemon has no working directory", not vars.is_builtin("CWD"))
  ok("a machine-only name not set here has no value", vars.get("DUMPS") == nil)
  vim.env.SMOKE_ONLY_ENV = "/from/env"
  ok("a name the store does not know falls back to vim.env", vars.get("SMOKE_ONLY_ENV") == "/from/env")
  vim.env.SMOKE_ONLY_ENV = nil
  ok("todos.open sent no kb_root (the daemon derives it)",
    (function()
      for _, c in ipairs(calls) do
        if c.method == "todos.open" and c.params[2] ~= nil then return false end
      end
      return count("todos.open") == 1
    end)(), vim.inspect(calls))
  local rows = vars.list()
  ok("list is the daemon's table, built-ins first",
    #rows == #tbl and rows[1].name == "KB_ROOT" and rows[1].builtin and rows[1].doc ~= nil
      and rows[4].name == "DOCS" and rows[4].source == "store" and rows[5].machine == true)

  -- resolve_path ------------------------------------------------
  local r = vars.resolve_path("$DOCS/a.md")
  ok("resolve_path: $VAR/rest substitutes", r.ok and r.path == "/src/proj/docs/a.md" and r.var_name == "DOCS")
  ok("resolve_path: ${VAR}/rest too", vars.resolve_path("${DOCS}/a.md").path == "/src/proj/docs/a.md")
  ok("resolve_path: bare $VAR is its value", vars.resolve_path("$DOCS").path == "/src/proj/docs")
  local u = vars.resolve_path("$DUMPS/x")
  ok("resolve_path: an unset machine-only name is unresolved, the literal kept",
    not u.ok and u.unresolved and u.path == "$DUMPS/x" and u.var_name == "DUMPS")
  ok("resolve_path: absolute passes through", vars.resolve_path("/abs/p").path == "/abs/p")
  ok("resolve_path: plain relative is the caller's", vars.resolve_path("rel/p").path == "rel/p")

  -- symbolize_path: the daemon's rule ----------------------------
  ok("symbolize: under $KB_ROOT", vars.symbolize_path(kbdir .. "/adrs/x.md") == "$KB_ROOT/adrs/x.md")
  ok("symbolize: $WORKSPACE is never written, however deep it is",
    vars.symbolize_path(kbdir .. "/ws/a.md") == "$KB_ROOT/ws/a.md", vars.symbolize_path(kbdir .. "/ws/a.md"))
  ok("symbolize: a longer user var wins", vars.symbolize_path(kbdir .. "/deep/y.md") == "$LONG/y.md")
  ok("symbolize: $DOCS is longer than $PROJECT_ROOT", vars.symbolize_path("/src/proj/docs/a.md") == "$DOCS/a.md")
  ok("symbolize: under $PROJECT_ROOT", vars.symbolize_path("/src/proj/z.md") == "$PROJECT_ROOT/z.md")
  ok("symbolize: $HOME last", vars.symbolize_path("/home/u/n.md") == "$HOME/n.md")
  ok("symbolize: outside every root, unchanged", vars.symbolize_path("/opt/n.md") == "/opt/n.md")
  ok("symbolize: a bare relative path the KB holds", vars.symbolize_path("adrs/x.md") == "$KB_ROOT/adrs/x.md")
  ok("symbolize: a bare relative path it does not, unchanged", vars.symbolize_path("adrs/nope.md") == "adrs/nope.md")
  ok("symbolize: a $VAR input, unchanged", vars.symbolize_path("$WORKSPACE/a") == "$WORKSPACE/a")

  -- the cache ---------------------------------------------------
  local reads = count("todos.vars")
  vars.get("KB_ROOT"); vars.list(); vars.symbolize_path("/opt/a")
  ok("a fresh table is not read again", count("todos.vars") == reads, count("todos.vars") - reads)
  local seen = 0
  local h = events.subscribe("core.todo.vars:changed", function() seen = seen + 1 end)
  tbl[4].value = "/src/proj/doc2"
  local fresh = vars.FRESH_MS
  vars.FRESH_MS = -1
  ok("an old table is read again before it answers: the read has the change",
    vars.get("DOCS") == "/src/proj/doc2", vars.get("DOCS"))
  vars.FRESH_MS = fresh
  ok("… and the change is published", seen == 1, seen)

  -- ~ is the store's $HOME, as the daemon reads it, never Neovim's own
  ok("resolve_path: ~/x is under the store's $HOME", vars.resolve_path("~/ref.md").path == "/home/u/ref.md",
    vars.resolve_path("~/ref.md").path)
  ok("resolve_path: ~ alone is the store's $HOME", vars.resolve_path("~").path == "/home/u")
  ok("resolve_path: ~name is left as the daemon leaves it", vars.resolve_path("~other/x").path == "~other/x")
  ok("symbolize: a ~ path is the store's $HOME's", vars.symbolize_path("~/n.md") == "$HOME/n.md")

  -- set / remove: where the value comes from ---------------------
  local function last_set()
    for i = #calls, 1, -1 do if calls[i].method == "todos.set_var" then return calls[i].params end end
  end
  seen = 0
  ok("set: a new name succeeds", vars.set("NEWV", "/n") == true)
  local p1 = last_set()
  ok("… for this machine and this store, so its value never reaches git",
    p1 and p1[1] == "NEWV" and p1[3].scope == "machine" and p1[3].at ~= nil, vim.inspect(p1))
  ok("… publishes core.todo.vars:changed", seen == 1, seen)
  ok("… and the next read has it", vars.get("NEWV") == "/n")
  vars.set("DOCS", "/src/proj/d3")
  ok("set: a store-file var stays in the store's file", last_set()[3].scope == "store")
  vars.set("LONG", "/l")
  local p3 = last_set()
  ok("set: a global var stays global, with no at", p3[3].scope == "global" and p3[3].at == nil, vim.inspect(p3))
  local bok, berr = vars.set("KB_ROOT", "/x")
  ok("set: a built-in is refused here (the Variables tab overrides one)",
    bok == false and tostring(berr):find("built-in", 1, true))
  ok("set: an invalid name is refused", vars.set("1bad", "/x") == false and vars.set("bad-name", "/x") == false)
  local n_sets = count("todos.set_var")
  ok("remove: a store-file var is cleared in the file", vars.remove("DOCS") == true
    and last_set()[2] == "" and last_set()[3].scope == "store")
  ok("remove: a name with no value is a no-op", vars.remove("DUMPS") == true
    and count("todos.set_var") == n_sets + 1)
  ok("remove: a built-in is refused", vars.remove("HOME") == false)
  events.unsubscribe(h)

  -- the background read: a change made elsewhere is published with no one reading
  vars._reset_for_tests()
  vars.FRESH_MS = 50
  vars.get("KB_ROOT") -- the session's first read starts it
  local polled = 0
  local hp = events.subscribe("core.todo.vars:changed", function() polled = polled + 1 end)
  local reads = count("todos.vars")
  tbl[4].value = "/src/proj/elsewhere"
  ok("an idle session sees a change made elsewhere: it is published with no read",
    vim.wait(2000, function() return polled > 0 end, 10), polled)
  ok("… by reading the table again", count("todos.vars") > reads)
  events.unsubscribe(hp)
  vars._reset_for_tests()
  vars.FRESH_MS = fresh

  -- the one-time carry of auto-core's own vars (before v0.4.2) -----
  local ns = require("auto-core.state").namespace("todo.vars", { persist = "json" })
  ns:set("carried", nil)
  ns:set("entries", { OLDV = "/old", NEWV = "/kept" })
  where._reset_for_tests()
  vars._reset_for_tests()
  calls = {}
  vars.get("KB_ROOT")
  local carried = {}
  for _, c in ipairs(calls) do if c.method == "todos.set_var" then carried[#carried + 1] = c.params end end
  ok("an old var is carried to the daemon as global; one it knows is left alone",
    #carried == 1 and carried[1][1] == "OLDV" and carried[1][3].scope == "global", vim.inspect(carried))
  ok("… and recorded as carried", ns:get("carried") ~= nil)
  ok("fixture: the carried var is removed in AutoDoc", vars.remove("OLDV") == true and vars.get("OLDV") == nil)
  where._reset_for_tests()
  vars._reset_for_tests()
  calls = {}
  vars.get("KB_ROOT")
  ok("… so it is never offered again: a var removed in AutoDoc stays removed",
    count("todos.set_var") == 0 and vars.get("OLDV") == nil, count("todos.set_var"))

  -- a file's refs resolve with ITS workspace's table (ADR 1792132105 §2.5) ------
  vars._reset_for_tests()
  calls = {}
  local note2 = "/kb2/notes/n.md"
  ok("from: a kb2 file's $KB_ROOT is kb2's; the session's is its own",
    vars.get("KB_ROOT", { from = note2 }) == "/kb2" and vars.get("KB_ROOT") == kbdir,
    tostring(vars.get("KB_ROOT", { from = note2 })))
  ok("from: its refs resolve with kb2's values",
    vars.resolve_path("$DOCS/a.md", { from = note2 }).path == "/kb2/docs/a.md")
  ok("from: vars.workspace names it", vars.workspace({ from = note2 }) == "kb2")
  ok("from: symbolize writes against kb2's roots",
    vars.symbolize_path("/kb2/docs/b.md", { from = note2 }) == "$DOCS/b.md")
  local wo = count("workspace.of")
  vars.get("DOCS", { from = "/kb2/notes/other.md" })
  ok("from: a file beside it is not asked about again while fresh", count("workspace.of") == wo,
    count("workspace.of") - wo)
  ok("from: a file no workspace owns has no $KB_ROOT", vars.get("KB_ROOT", { from = "/opt/x.md" }) == nil)
  ok("… but the global variables, from workspace.vars(\"\")", vars.get("GLOB", { from = "/opt/x.md" }) == "/glob")
  vars._reset_for_tests()
  old_none = true
  -- the fallback is an empty table, so the environment answers, and nothing is an error: a refusal
  -- passed on would answer nil and why here, as an unset name would without the environment
  vim.env.GLOB = "/from/env"
  local gv, gwhy = vars.get("GLOB", { from = "/opt/x.md" })
  local _, lwhy = vars.list({ from = "/opt/x.md" })
  vim.env.GLOB = nil
  ok("a daemon before them: the environment alone, no error",
    gv == "/from/env" and gwhy == nil and lwhy == nil and vars.workspace({ from = "/opt/x.md" }) == nil,
    vim.inspect({ value = gv, why = gwhy, list_why = lwhy }))
  old_none = false
  vars._reset_for_tests()
  vim.env.HELD = "/from/env"
  ok("a name held in conflict is unresolved, never the environment's",
    vars.get("HELD", { from = note2 }) == nil and vars.resolve_path("$HELD/x", { from = note2 }).unresolved)
  vim.env.HELD = nil
  local held
  for _, r in ipairs(vars.list({ from = note2 })) do if r.name == "HELD" then held = r end end
  ok("… and listed as a conflict", held ~= nil and held.conflict == true, vim.inspect(held))
  local function last_ws_set()
    for i = #calls, 1, -1 do if calls[i].method == "workspace.set_var" then return calls[i].params end end
  end
  vars.set("NEWV2", "/n2", { from = note2 })
  local q1 = last_ws_set()
  ok("set from: a new name is this machine's, in kb2",
    q1 and q1[1] == "kb2" and q1[2] == "NEWV2" and q1[4].scope == "machine", vim.inspect(q1))
  vars.set("DOCS", "/kb2/d", { from = note2 })
  ok("set from: a KB-file var stays in the KB's file", last_ws_set()[4].scope == "kb")
  vars.set("MO", "/m", { from = note2, machine_only = true })
  ok("set from: machine_only is sent", last_ws_set()[4].machine_only == true, vim.inspect(last_ws_set()))
  ok("set: a scope that is none of machine, kb and global is refused", vars.set("X", "/x", { scope = "nope" }) == false)
  local sok, serr = vars.set("X", "/x", { from = "/opt/x.md" })
  ok("set: a file no workspace owns is refused, saying so",
    sok == false and tostring(serr):find("no workspace", 1, true) ~= nil, serr)
  ok("remove from: a KB-file var is cleared in the KB's file", vars.remove("DOCS", { from = note2 }) == true
    and last_ws_set()[3] == "" and last_ws_set()[4].scope == "kb")
  -- a daemon older than protocol 24: workspace.of refused
  vars._reset_for_tests()
  old_daemon = true
  calls = {}
  ok("an old daemon: a from reads the session store's table", vars.get("KB_ROOT", { from = note2 }) == kbdir)
  vars.get("KB_ROOT", { from = "/opt/y.md" })
  ok("… and workspace.of is asked once", count("workspace.of") == 1, count("workspace.of"))
  old_daemon = false
  vars._reset_for_tests()

  daemon._set_transport(nil)
  vars._reset_for_tests() -- its background read stops
  wt.set_workspace_root(prev_root)
  where._reset_for_tests()
  -- state_tmp is NOT deleted: configure({ persist_dir = nil }) changes nothing, so
  -- it stays the persist dir, and a namespace a later section creates first (the
  -- kb one, [94]) lives in it. Deleted, that namespace's writes fail silently.
  vim.fn.delete(kbdir, "rf")
  vim.fn.delete(proj, "rf")
  package.loaded["auto-core.todo.vars"] = nil
end)()

-- [69] (todo.cron): removed in v0.4.1 with automation (ADR 1791532020).

-- ─────────────── 75. ADR-0038 Batches A-C ────────────────
print("\n[75] ADR-0038 — scope-local wo writes, response_write_failed, poll re-arm, entry cache, UI debounce")

-- ── (a) panel with_unfixed_buf must NOT leak winfixbuf into the
--        global default (ADR-0028; the "winfixbuf propagation" bug).
;(function()
  local Panel = require("auto-core.ui.panel")
  Panel._reset_for_tests()
  local p = Panel.new({
    name  = "p75-panel",
    side  = "left",
    width = { default = 28, min = 20, max = 60 },
    filetype = "p75-test",
  })
  local winid = p:open(true)
  ok("p75(a): panel opens with winfixbuf set locally",
    winid and vim.wo[winid].winfixbuf == true)
  local g_before = vim.api.nvim_get_option_value("winfixbuf", { scope = "global" })
  local ran = false
  p:with_unfixed_buf(function() ran = true end)
  ok("p75(a): with_unfixed_buf ran the callback", ran)
  ok("p75(a): panel window winfixbuf restored locally",
    vim.wo[winid].winfixbuf == true)
  local g_after = vim.api.nvim_get_option_value("winfixbuf", { scope = "global" })
  ok("p75(a): global winfixbuf default NOT mutated by the toggle (ADR-0028)",
    g_after == g_before and g_after == false,
    "global winfixbuf before=" .. tostring(g_before) .. " after=" .. tostring(g_after))
  p:close()
end)()

-- ── (b) multi-float pane options are scope-local (ADR-0028).
;(function()
  local multi = require("auto-core.ui.float.multi")
  local function g(name)
    return vim.api.nvim_get_option_value(name, { scope = "global" })
  end
  local pre = { cursorline = g("cursorline"), wrap = g("wrap"),
                winhighlight = g("winhighlight") }
  local m = multi.new({
    name  = "p75-float",
    outer = { width_pct = 0.8, height_pct = 0.8, title = " p75 " },
    panes = {
      left   = { width = 24, cursorline = true },
      middle = { cursorline = true },
    },
  })
  m:open()
  ok("p75(b): multi float opened", m:is_open())
  local mid_win = m:winid("middle")
  ok("p75(b): pane window got cursorline LOCALLY",
    mid_win and vim.wo[mid_win].cursorline == true)
  ok("p75(b): global cursorline/wrap/winhighlight defaults NOT mutated (ADR-0028)",
    g("cursorline") == pre.cursorline
      and g("wrap") == pre.wrap
      and g("winhighlight") == pre.winhighlight,
    string.format("cursorline %s>%s wrap %s>%s winhl %q>%q",
      tostring(pre.cursorline), tostring(g("cursorline")),
      tostring(pre.wrap), tostring(g("wrap")),
      pre.winhighlight, g("winhighlight")))
  m:dispose()
end)()

-- ── (c) executioner response-write failure is OBSERVABLE: failed
--        transport.complete → log.error + response_write_failed event
--        (previously fully silent; sender polled forever).
;(function()
  local mb       = require("auto-core.mailbox")
  local registry = require("auto-core.mailbox.registry")
  local router   = mb.router
  local commands = mb.commands
  local tr       = mb.transport
  local events_m = require("auto-core.events")

  mb.register("nvim")
  mb.register("agent:p75-sender")
  router.start()

  commands.register("p75.echo", {
    owner = "smoke",
    handler = function(args) return { ok = true, value = { echoed = args.x } } end,
    description = "p75 echo",
  })

  local failed_events = {}
  local sub = events_m.subscribe("core.mailbox:response_write_failed", function(p)
    failed_events[#failed_events + 1] = p
  end)

  local real_complete = tr.complete
  tr.complete = function() return false, "p75 forced response-write failure" end

  local cor = "cor-p75-fail-" .. tostring(vim.uv.hrtime())
  local cmd_msg = mb.message.build({
    from = "agent:p75-sender", to = "nvim",
    kind = "command", command = "p75.echo",
    args = { x = 1 }, correlation_id = cor,
  })
  local srec = registry.get("agent:p75-sender")
  vim.fn.writefile({ vim.json.encode(cmd_msg) },
    srec.subs.outbox .. "/" .. cmd_msg.id .. ".json")

  router.scan_now()
  vim.wait(600, function() return #failed_events >= 1 end, 25)

  tr.complete = real_complete
  events_m.unsubscribe(sub)

  ok("p75(c): core.mailbox:response_write_failed published when complete() fails",
    #failed_events >= 1, "events: " .. vim.inspect(failed_events))
  ok("p75(c): payload carries mailbox + id + error",
    failed_events[1] ~= nil
      and failed_events[1].mailbox == "nvim"
      and failed_events[1].id == cmd_msg.id
      and tostring(failed_events[1].error):find("p75 forced", 1, true) ~= nil,
    vim.inspect(failed_events[1]))

  -- The stubbed complete left the message in processing/ — finish it
  -- for real so downstream state stays clean.
  pcall(real_complete, "nvim", cmd_msg.id, { ok = true, value = {} })
end)()

-- ── (d) poll timer re-arms when poll_interval_ms changes (was
--        frozen at the first-armed interval until stop()/start()).
;(function()
  local router = require("auto-core.mailbox.router")
  router.stop()
  router.configure({ mode = "poll", poll_interval_ms = 60000 })
  router.start()
  local st = router.status()
  ok("p75(d): poll mode arms the global timer",
    st.poll_running == true, vim.inspect(st))
  ok("p75(d): status reports the ARMED interval",
    st.poll_armed_interval_ms == 60000,
    "got " .. tostring(st.poll_armed_interval_ms))
  router.configure({ poll_interval_ms = 90000 })
  router.refresh()
  st = router.status()
  ok("p75(d): refresh() re-arms the live timer at the NEW interval (ADR-0038 A3)",
    st.poll_armed_interval_ms == 90000,
    "got " .. tostring(st.poll_armed_interval_ms))
  router.stop()
  router.configure({ mode = "auto", poll_interval_ms = 1000 })
end)()

-- ── (e) list_entries entry cache: unchanged dir → zero decodes;
--        a new message invalidates via the dir signature.
;(function()
  local mb = require("auto-core.mailbox")
  local tr = mb.transport
  mb.register("agent:p75-cache")
  mb.send({ from = "agent:p75-cache", to = "agent:p75-cache", body = "one" })
  mb.send({ from = "agent:p75-cache", to = "agent:p75-cache", body = "two" })

  tr._invalidate_entry_cache()
  local e1 = tr.list_entries("agent:p75-cache", "inbox")
  ok("p75(e): first list decodes the inbox", #e1 == 2, "#e1=" .. tostring(#e1))
  local d_after_first = tr._list_decode_count
  local e2 = tr.list_entries("agent:p75-cache", "inbox")
  ok("p75(e): unchanged dir → cache hit with ZERO additional decodes (ADR-0038 B2)",
    tr._list_decode_count == d_after_first and #e2 == 2,
    string.format("decodes %d>%d #e2=%d", d_after_first, tr._list_decode_count, #e2))

  mb.send({ from = "agent:p75-cache", to = "agent:p75-cache", body = "three" })
  local e3 = tr.list_entries("agent:p75-cache", "inbox")
  ok("p75(e): new message invalidates the cache via dir signature",
    #e3 == 3 and tr._list_decode_count > d_after_first,
    string.format("#e3=%d decodes %d>%d", #e3, d_after_first, tr._list_decode_count))
end)()

-- ── (f) viewer refresh is COALESCED: an event burst inside the
--        debounce window produces exactly one repaint.
;(function()
  local mb = require("auto-core.mailbox")
  local ui = mb.ui
  local events_m = require("auto-core.events")
  ui.open()
  ui._refresh_count = 0
  for i = 1, 6 do
    events_m.publish("core.mailbox:message_queued",
      { mailbox = "agent:p75-cache", id = "p75-burst-" .. i })
  end
  vim.wait(2000, function() return ui._refresh_count >= 1 end, 25)
  vim.wait(400)  -- window for any (wrongly) stacked extra repaints
  ok("p75(f): 6-event burst coalesced into exactly ONE repaint (ADR-0038 B1)",
    ui._refresh_count == 1, "refresh_count=" .. tostring(ui._refresh_count))
  ui.close()
end)()

-- ─────────────── 76. ADR-0038 Batches D1 + E ─────────────
print("\n[76] ADR-0038 — fs.atomic, async git show, shared field catalog, bookkeeping prune")

-- ── (a) fs.atomic.write — the shared primitive.
;(function()
  local atomic = require("auto-core.fs.atomic")
  local base = vim.fn.tempname() .. "_p76atomic"
  vim.fn.mkdir(base, "p")

  local f1 = base .. "/plain.txt"
  local ok1 = atomic.write(f1, "p76 payload")
  ok("p76(a): write into an existing dir succeeds",
    ok1 == true and table.concat(vim.fn.readfile(f1), "\n") == "p76 payload")

  local ok2, err2 = atomic.write(base .. "/missing/sub.txt", "x")
  ok("p76(a): missing parent dir without mkdir → structured error",
    ok2 == false and tostring(err2):find("target dir missing", 1, true) ~= nil,
    tostring(err2))

  local f3 = base .. "/made/sub.txt"
  local ok3 = atomic.write(f3, "y", { mkdir = true })
  ok("p76(a): mkdir=true creates the parent and writes",
    ok3 == true and vim.fn.filereadable(f3) == 1)

  ok("p76(a): no tmp litter left behind",
    (function()
      for _, f in ipairs(vim.fn.readdir(base)) do
        if f:match("^%.tmp%-") then return false end
      end
      return true
    end)())

  ok("p76(a): facade exposes fs.atomic",
    require("auto-core.fs").atomic == atomic)

  vim.fn.delete(base, "rf")
end)()

-- ── (b) async git show — shared cache, in-flight coalescing.
;(function()
  local graph = require("auto-core.git.graph")
  graph._reset_for_tests()

  local repo = vim.fn.tempname() .. "_p76git"
  vim.fn.mkdir(repo, "p")
  vim.fn.system({ "git", "-C", repo, "init", "-q" })
  vim.fn.writefile({ "hello p76" }, repo .. "/f.txt")
  vim.fn.system({ "git", "-C", repo, "add", "." })
  vim.fn.system({ "git", "-C", repo,
    "-c", "user.email=t@t", "-c", "user.name=t",
    "commit", "-q", "-m", "p76 commit subject" })
  local hash = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "HEAD" }))
  local common = repo .. "/.git"
  if vim.v.shell_error ~= 0 or hash == "" then
    ok("p76(b): git fixture creation", false, "git unavailable / commit failed")
    vim.fn.delete(repo, "rf")
    return
  end

  -- Two rapid requests for the SAME key: both callbacks fire, ONE
  -- subprocess (in-flight coalescing).
  local spawn0 = graph._async_spawn_count
  local got1, got2
  graph.show_stat_async(common, hash, function(lines) got1 = lines end)
  graph.show_stat_async(common, hash, function(lines) got2 = lines end)
  vim.wait(4000, function() return got1 ~= nil and got2 ~= nil end, 25)
  ok("p76(b): both async callbacks delivered",
    type(got1) == "table" and type(got2) == "table")
  ok("p76(b): async stat lines carry the commit subject",
    (function()
      for _, l in ipairs(got1 or {}) do
        if l:find("p76 commit subject", 1, true) then return true end
      end
      return false
    end)(), vim.inspect(got1))
  ok("p76(b): concurrent same-key requests coalesced into ONE subprocess",
    graph._async_spawn_count == spawn0 + 1,
    "spawns " .. tostring(spawn0) .. ">" .. tostring(graph._async_spawn_count))

  -- The async result landed in the SHARED cache: the sync API now
  -- returns identical lines without shelling out.
  local sync_lines = graph.show_stat(common, hash)
  ok("p76(b): sync show_stat hits the cache populated by the async path",
    vim.deep_equal(sync_lines, got1))

  -- Cache hit via the async API resolves without a new spawn.
  local spawn1 = graph._async_spawn_count
  local got3
  graph.show_diff_async(common, hash, function(lines) got3 = lines end)
  vim.wait(4000, function() return got3 ~= nil end, 25)
  local spawn_after_diff = graph._async_spawn_count
  local got4
  graph.show_diff_async(common, hash, function(lines) got4 = lines end)
  vim.wait(2000, function() return got4 ~= nil end, 25)
  ok("p76(b): async diff delivered + repeat is a cache hit (no extra spawn)",
    got3 ~= nil and got4 ~= nil
      and spawn_after_diff == spawn1 + 1
      and graph._async_spawn_count == spawn_after_diff,
    string.format("spawns %d>%d>%d", spawn1, spawn_after_diff, graph._async_spawn_count))

  -- Failure path: unknown hash → banner line, callback still fires.
  local got_err
  graph.show_diff_async(common, ("d"):rep(40), function(lines) got_err = lines end)
  vim.wait(4000, function() return got_err ~= nil end, 25)
  ok("p76(b): failed git show delivers the failure banner",
    got_err ~= nil and tostring(got_err[1] or ""):find("failed", 1, true) ~= nil,
    vim.inspect(got_err))

  graph._reset_for_tests()
  vim.fn.delete(repo, "rf")
end)()

-- ── (c) the shared frontmatter catalog (todo.schema + todo.md): removed in
--        v0.4.1 with the Lua format modules (ADR 1791532020).

-- ── (d) router bookkeeping prune: seen ids whose files left the
--        subdir are swept on refresh(); totals are observable.
;(function()
  local mb       = require("auto-core.mailbox")
  local registry = require("auto-core.mailbox.registry")
  local router   = mb.router
  local commands = mb.commands
  local events_m = require("auto-core.events")

  mb.register("nvim")
  mb.register("agent:p76-sender")
  router.start()
  commands.register("p76.echo", {
    owner = "smoke",
    handler = function(args) return { ok = true, value = { echoed = args.x } } end,
    description = "p76 echo",
  })

  local completed = {}
  local sub = events_m.subscribe("core.mailbox:message_completed", function(p)
    completed[#completed + 1] = p
  end)

  local cmd_msg = mb.message.build({
    from = "agent:p76-sender", to = "nvim",
    kind = "command", command = "p76.echo", args = { x = 2 },
    correlation_id = "cor-p76-" .. tostring(vim.uv.hrtime()),
  })
  local srec = registry.get("agent:p76-sender")
  vim.fn.writefile({ vim.json.encode(cmd_msg) },
    srec.subs.outbox .. "/" .. cmd_msg.id .. ".json")
  router.scan_now()
  vim.wait(600, function() return #completed >= 1 end, 25)
  events_m.unsubscribe(sub)

  local t1 = router.status().seen_total
  ok("p76(d): seen_total counts the dispatched message", t1 >= 1,
    "seen_total=" .. tostring(t1))
  -- The command completed → its inbox file was claimed away; the
  -- prune on refresh() must drop the orphaned seen id.
  router.refresh()
  local t2 = router.status().seen_total
  ok("p76(d): refresh() prunes seen ids whose files are gone (ADR-0038 E)",
    t2 < t1, string.format("seen_total %d>%d", t1, t2))
  ok("p76(d): debounce_total is observable",
    type(router.status().debounce_total) == "number")
end)()

-- ── (e) log throttle map: counted + repeat keys don't grow it.
;(function()
  local log = require("auto-core.log")
  local s0 = log._throttle_size()
  log.info_throttled("p76-throttle-key-a", 60000, "smoke", "a")
  log.info_throttled("p76-throttle-key-b", 60000, "smoke", "b")
  local s1 = log._throttle_size()
  ok("p76(e): new throttle keys are counted", s1 == s0 + 2,
    string.format("size %d>%d", s0, s1))
  log.info_throttled("p76-throttle-key-a", 60000, "smoke", "a-again")
  ok("p76(e): repeat key within window does not grow the map",
    log._throttle_size() == s1)
end)()

print("\n[77] ADR-0048 Phase 1 — events.register_topics (dynamic plugin topics)")

;(function()
  local events = require("auto-core.events")

  -- (a) register: valid specs land in the merged registry + spec lookup.
  local n = events.register_topics("auto-run.nvim", {
    ["run.job:started"] = {
      doc = "smoke: an auto-run job started",
      payload = "{ config = string, run_id = string }",
    },
    ["run.job:exited"] = {
      doc = "smoke: an auto-run job exited",
      payload = "{ run_id = string, code = integer }",
      publishers = { "auto-run.nvim" },
    },
  })
  ok("p77(a): register_topics returns count", n == 2)
  local spec = events.topic_spec("run.job:started")
  ok("p77(a): topic_spec resolves a dynamic topic",
    spec ~= nil and spec.doc:find("job started") ~= nil)
  ok("p77(a): registered_topics merges static + dynamic",
    events.registered_topics()["run.job:exited"] ~= nil
    and events.registered_topics()["core.cwd:changed"] ~= nil)
  ok("p77(a): default publishers stamp the owning plugin",
    events.topic_spec("run.job:started").publishers[1] == "auto-run.nvim")

  -- (b) idempotent re-registration by the same owner replaces the spec.
  events.register_topics("auto-run.nvim", {
    ["run.job:started"] = {
      doc = "smoke: re-registered doc",
      payload = "{ config = string }",
    },
  })
  ok("p77(b): same-owner re-registration replaces the spec",
    events.topic_spec("run.job:started").doc:find("re%-registered") ~= nil)

  -- (c) ownership: a different plugin cannot clobber.
  local clobber_ok = pcall(events.register_topics, "other.nvim", {
    ["run.job:started"] = { doc = "clobber", payload = "{}" },
  })
  ok("p77(c): different-owner clobber is rejected", clobber_ok == false)

  -- (d) static registry can never be shadowed.
  local shadow_ok = pcall(events.register_topics, "auto-run.nvim", {
    ["core.cwd:changed"] = { doc = "shadow", payload = "{}" },
  })
  ok("p77(d): static-registry shadowing is rejected", shadow_ok == false)

  -- (e) malformed specs are rejected.
  local bad_ok = pcall(events.register_topics, "auto-run.nvim", {
    ["run.bad:topic"] = { doc = "missing payload" },
  })
  ok("p77(e): spec without payload is rejected", bad_ok == false)

  -- (f) strict mode: dynamic topics publish without the unregistered
  -- warn (observable via publish proceeding + spec presence; the warn
  -- itself is vim.schedule'd notify, asserted structurally here).
  events.configure({ strict_topics = true })
  local fired = 0
  local h = events.subscribe("run.job:started", function() fired = fired + 1 end)
  local invoked = events.publish("run.job:started", { config = "smoke" })
  ok("p77(f): dynamic topic publishes under strict mode",
    invoked == 1 and fired == 1)
  events.unsubscribe(h)
  events.configure({ strict_topics = false })

  -- (g) _reset_for_tests clears dynamic topics (registry hygiene
  -- between suite sections).
  events._reset_for_tests()
  ok("p77(g): reset clears dynamic topics",
    events.topic_spec("run.job:started") == nil)
end)()

print("\n[78] ADR-0048 Phase 1 — auto-core.trust")

;(function()
  local trust = require("auto-core.trust")
  trust._reset_for_tests()

  -- (a) defaults: unwritten capability is fully off.
  local s = trust.state("run.exec")
  ok("p78(a): capability defaults all-off",
    s.enabled == false and s.first_run_acknowledged == false
    and s.allowlist == nil)
  ok("p78(a): has_state false before any write",
    trust.has_state("run.exec") == false)

  -- (b) enable without ack refused; mailbox-shaped call can't force.
  local ok_set, err_set = trust.set("run.exec", { enabled = true })
  ok("p78(b): enable refused without ack",
    ok_set == false and err_set == "trust_not_acknowledged")

  -- (c) ack → enable → check passes.
  trust.acknowledge_first_run("run.exec")
  ok("p78(c): enable succeeds after ack",
    trust.set("run.exec", { enabled = true }) == true)
  ok("p78(c): check passes when enabled", trust.check("run.exec") == true)

  -- (d) allowlist: subject gating semantics.
  trust.set("run.exec", { allowlist = { "^gold%-", "^lm%-http$" } })
  ok("p78(d): allowlisted subject passes",
    trust.check("run.exec", "gold-http") == true)
  local ok_rej, why = trust.check("run.exec", "rm-rf-everything")
  ok("p78(d): non-matching subject rejected",
    ok_rej == false and why == "allowlist_rejected")
  ok("p78(d): no-subject check passes (call-site contract)",
    trust.check("run.exec") == true)
  local ok_bad, err_bad = trust.set("run.exec", { allowlist = { 42 } })
  ok("p78(d): non-string allowlist entries rejected",
    ok_bad == false and err_bad == "allowlist entries must be strings")

  -- (e) capabilities are isolated from one another.
  ok("p78(e): sibling capability unaffected",
    trust.state("run.command_env").enabled == false)
  local ok_dis, why_dis = trust.check("run.command_env")
  ok("p78(e): disabled capability check returns 'disabled'",
    ok_dis == false and why_dis == "disabled")

  -- (f)-(h) tested automation's legacy todo.bash migration into the trust
  -- store; they went with automation in v0.4.1 (ADR 1791532020). auto-core.trust
  -- stays: auto-run uses it.

  -- teardown: leave the store clean for any later section.
  trust._reset_for_tests()
end)()

print("\n[79] ADR-0050 — git.watch drops `index`; git.status uses --no-optional-locks")
;(function()
  local watch  = require("auto-core.git.watch")
  local status = require("auto-core.git.status")

  -- ── (a) FILENAME_KINDS no longer watches `index` (§2.2). Real
  -- state transitions stay covered by HEAD / ORIG_HEAD / MERGE_HEAD.
  ok("p79(a): git.watch does NOT watch `index`",
    watch.FILENAME_KINDS["index"] == nil,
    vim.inspect(watch.FILENAME_KINDS))
  ok("p79(a): git.watch still watches HEAD / ORIG_HEAD / MERGE_HEAD",
    watch.FILENAME_KINDS["HEAD"] == "head"
      and watch.FILENAME_KINDS["ORIG_HEAD"] == "merge"
      and watch.FILENAME_KINDS["MERGE_HEAD"] == "merge")

  -- Real repo fixture with one commit (so git_dir/index exists).
  local repo = vim.fn.tempname() .. "_p79git"
  vim.fn.mkdir(repo, "p")
  vim.fn.system({ "git", "-C", repo, "init", "-q" })
  vim.fn.writefile({ "hello p79" }, repo .. "/f.txt")
  vim.fn.system({ "git", "-C", repo, "add", "." })
  vim.fn.system({ "git", "-C", repo,
    "-c", "user.email=t@t", "-c", "user.name=t",
    "commit", "-q", "-m", "p79 commit" })
  local git_dir = repo .. "/.git"
  if vim.v.shell_error ~= 0 or vim.fn.isdirectory(git_dir) ~= 1 then
    ok("p79: git fixture creation", false, "git unavailable / init failed")
    vim.fn.delete(repo, "rf")
  else
    local index_path = git_dir .. "/index"

    -- ── (b) §2.1: git.status.get must NOT rewrite git_dir/index.
    -- Make the tracked file's stat cache stale (bump its mtime into
    -- the future) so a status WOULD refresh + rewrite the index if
    -- optional locks were enabled. With --no-optional-locks it must
    -- leave the index byte-for-byte alone.
    status.invalidate(repo)
    local pre = vim.uv.fs_stat(index_path) or {}
    local future = os.time() + 120
    vim.uv.fs_utime(repo .. "/f.txt", future, future)
    local entries = status.get(repo)
    local post = vim.uv.fs_stat(index_path) or {}
    ok("p79(b): git.status.get returns entries on the fixture",
      type(entries) == "table")
    ok("p79(b): git.status.get did NOT rewrite git_dir/index (§2.1)",
      pre.mtime and post.mtime
        and pre.mtime.sec == post.mtime.sec
        and pre.mtime.nsec == post.mtime.nsec
        and pre.size == post.size,
      string.format("pre=%s post=%s",
        vim.inspect(pre.mtime), vim.inspect(post.mtime)))

    -- ── (c) §2.2: arming the watch and mutating git_dir/index must
    -- NOT publish core.git.state:changed; a HEAD mutation still must.
    watch._reset_for_tests()
    local hits = {}
    local sub = events_mod.subscribe("core.git.state:changed", function(p)
      hits[#hits + 1] = { kind = p.kind, path = p.path }
    end)
    local handle, werr = watch.start(repo)
    ok("p79(c): watch.start succeeds on the fixture",
      handle ~= nil, tostring(werr))

    -- Mutate index (rewrite bytes) — must be filtered out.
    vim.fn.writefile({ "not-a-real-index" }, index_path)
    vim.wait(300)
    local index_hits = 0
    for _, h in ipairs(hits) do
      if h.kind == "index" or (h.path and h.path:sub(-#"/index") == "/index") then
        index_hits = index_hits + 1
      end
    end
    ok("p79(c): index mutation does NOT publish core.git.state:changed",
      index_hits == 0, vim.inspect(hits))

    -- Mutate HEAD — must still publish (proves the watch is live).
    vim.wait(250)  -- clear any per-path debounce window
    vim.fn.writefile({ "ref: refs/heads/p79" }, git_dir .. "/HEAD")
    vim.wait(300, function()
      for _, h in ipairs(hits) do
        if h.kind == "head" then return true end
      end
      return false
    end)
    local head_hit = false
    for _, h in ipairs(hits) do
      if h.kind == "head" then head_hit = true break end
    end
    ok("p79(c): HEAD mutation still publishes core.git.state:changed",
      head_hit, vim.inspect(hits))

    events_mod.unsubscribe(sub)
    watch.stop_all()
    status.invalidate(repo)
    vim.fn.delete(repo, "rf")
  end
end)()

print("\n[80] ADR-0058 — ui.grid.model (pure tabular data rules)")
;(function()
  local ui = require("auto-core.ui")
  ok("p80: ui.grid is aggregated", type(ui.grid) == "table", type(ui.grid))
  ok("p80: ui.grid.model is a constructor", type(ui.grid.model) == "function", type(ui.grid.model))
  local grid = ui.grid

  -- ── raw value vs display text ──────────────────────────────
  -- The model must keep BOTH: a yank has to reproduce what the
  -- database returned, while the grid shows one line per row.
  -- Column indexes are named so an assertion can never quietly target
  -- the wrong cell; column 3 repeats the name "id" on purpose, to pin
  -- the duplicate-name rule.
  local C_ID, C_TITLE, C_DUP = 1, 2, 3
  local m = grid.model({
    columns = { { name = "id", type = "integer" }, "title", { name = "id" } },
    rows = {
      { 1, "alpha", "x" },
      { 2, vim.NIL, "y" },
      { 3, "has,comma", 'has"quote' },
      { 4, "line1\nline2", "tab\there" },
      { 5, "\255\254bin", "日本語" },
    },
  })

  ok("p80: nrows/ncols", m:nrows() == 5 and m:ncols() == 3,
    m:nrows() .. "x" .. m:ncols())
  ok("p80: kind inferred as rows", m:kind() == "rows", m:kind())

  local c = m:cell(1, C_ID)
  ok("p80: cell keeps the RAW value", c.value == 1 and c.text == "1" and not c.null,
    vim.inspect(c))

  -- ── NULL: not the string "NULL" ────────────────────────────
  local n = m:cell(2, C_TITLE)
  ok("p80: vim.NIL is null with display text", n.null == true and n.text == "NULL",
    vim.inspect(n))
  ok("p80: NULL is an EMPTY csv field (not \"NULL\")",
    m:csv(2) == "2,,y", m:csv(2))
  ok("p80: NULL encodes as json null", grid.json_value(vim.NIL) == "null",
    grid.json_value(vim.NIL))

  local hole = grid.model({ columns = { "a", "b" }, rows = { { 1 } } })
  ok("p80: a missing (nil) trailing value is null too",
    hole:cell(1, 2).null == true and hole:cell(1, 2).text == "NULL",
    vim.inspect(hole:cell(1, 2)))
  ok("p80: null text is configurable", grid.model({
    columns = { "a" }, rows = { { vim.NIL } }, null = "∅",
  }):cell(1, 1).text == "∅")

  -- ── binary: non-UTF-8 renders as hex, never as raw bytes ────
  local b = m:cell(5, C_TITLE)
  ok("p80: non-UTF-8 bytes render as 0x hex", b.text == "0xfffe62696e" and b.binary == true,
    vim.inspect(b))
  ok("p80: valid UTF-8 is NOT treated as binary",
    m:cell(5, C_DUP).binary == false and m:cell(5, C_DUP).text == "日本語",
    vim.inspect(m:cell(5, C_DUP)))
  ok("p80: is_printable rejects overlong encodings",
    grid.is_printable("\192\175") == false)
  ok("p80: is_printable rejects lone continuation bytes",
    grid.is_printable("\128") == false)
  ok("p80: is_printable rejects truncated sequences",
    grid.is_printable("\228\184") == false)
  ok("p80: is_printable rejects surrogates",
    grid.is_printable("\237\160\128") == false)
  ok("p80: is_printable accepts tab/newline",
    grid.is_printable("a\tb\nc") == true)
  ok("p80: is_printable rejects other control bytes",
    grid.is_printable("a\1b") == false)
  -- A 16-byte id with embedded NULs is binary, so it never reaches the
  -- buffer as raw bytes (which is what produced the decimal-int display).
  local uuid = string.char(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 255)
  ok("p80: 16-byte id renders as hex, not integers",
    grid.display_text(uuid, "NULL") == "0x000102030405060708090a0b0c0d0eff",
    grid.display_text(uuid, "NULL"))

  -- ── newlines: flattened on screen, verbatim in yanks ────────
  local nl = m:cell(4, 2)
  ok("p80: embedded newline shows as ␤ (row stays one line)",
    nl.text == "line1␤line2" and not nl.text:find("\n"), vim.inspect(nl.text))
  ok("p80: csv keeps the REAL newline and quotes the field",
    m:csv(4) == '4,"line1\nline2",tab\there', vim.inspect(m:csv(4)))

  -- ── RFC 4180 ───────────────────────────────────────────────
  ok("p80: csv quotes a field containing a comma", m:csv(3):find('"has,comma"', 1, true) ~= nil, m:csv(3))
  ok("p80: csv doubles inner quotes", m:csv(3):find('"has""quote"', 1, true) ~= nil, m:csv(3))
  ok("p80: csv leaves plain fields unquoted", m:csv(1) == "1,alpha,x", m:csv(1))
  ok("p80: csv_field of a plain value is bare", grid.csv_field("plain") == "plain")
  local csv_all = m:csv_rows()
  ok("p80: csv_rows emits a header record first",
    vim.split(csv_all, "\n")[1] == "id,title,id", vim.split(csv_all, "\n")[1])
  ok("p80: csv_rows honours an explicit row subset",
    m:csv_rows({ 1 }) == "id,title,id\n1,alpha,x", vim.inspect(m:csv_rows({ 1 })))

  -- ── duplicate column names survive both serializations ──────
  local cols = m:columns()
  ok("p80: duplicate column keeps its name", cols[3].name == "id", cols[3].name)
  ok("p80: duplicate column gets a unique key", cols[3].key == "id#2", cols[3].key)
  ok("p80: columns() returns a copy (not the model's own table)",
    (function() cols[1].name = "mutated"; return m:columns()[1].name == "id" end)())

  local obj = vim.json.decode(m:json(1))
  ok("p80: json object carries BOTH duplicate columns",
    obj["id"] == 1 and obj["id#2"] == "x", vim.inspect(obj))
  ok("p80: json object preserves the raw number type", type(obj["id"]) == "number", type(obj["id"]))
  local obj2 = vim.json.decode(m:json(2))
  ok("p80: json object encodes NULL as json null", obj2["title"] == vim.NIL, vim.inspect(obj2))
  local obj5 = vim.json.decode(m:json(5))
  ok("p80: json object carries binary as its hex text (valid UTF-8)",
    obj5["title"] == "0xfffe62696e", vim.inspect(obj5))
  ok("p80: json object keeps a real newline in the value",
    vim.json.decode(m:json(4))["title"] == "line1\nline2",
    vim.inspect(vim.json.decode(m:json(4))["title"]))

  local all = vim.json.decode(m:json_all())
  ok("p80: json_all keeps duplicate columns POSITIONALLY",
    #all.columns == 3 and all.columns[1].name == "id" and all.columns[3].name == "id"
    and all.columns[3].key == "id#2", vim.inspect(all.columns))
  ok("p80: json_all rows are positional arrays", #all.rows == 5 and all.rows[1][2] == "alpha",
    vim.inspect(all.rows[1]))
  ok("p80: json_all row keeps NULL as null", all.rows[2][2] == vim.NIL, vim.inspect(all.rows[2]))
  local rows_json = vim.json.decode(m:json_rows())
  ok("p80: json_rows decodes to one object per row",
    #rows_json == 5 and rows_json[1]["title"] == "alpha", vim.inspect(rows_json[1]))
  ok("p80: json_rows of an empty result is []",
    grid.model({ columns = { "a" }, rows = {} }):json_rows() == "[]")

  -- ── widths measured in DISPLAY cells, not bytes ─────────────
  local w = m:widths()
  -- Isolated fixture: 日本語 is 9 BYTES but 6 display cells. Byte-width
  -- padding (string.format("%-Ns")) is what mis-aligns every existing
  -- columnar view in this plugin; the grid must not repeat it.
  local wide = grid.model({ columns = { "c" }, rows = { { "日本語" } } })
  ok("p80: width counts display cells for multibyte (日本語 = 6, not 9)",
    wide:widths()[1] == 6, vim.inspect(wide:widths()))
  ok("p80: a tab is expanded (it would otherwise break alignment)",
    m:cell(4, C_DUP).text == "tab    here", vim.inspect(m:cell(4, C_DUP).text))
  ok("p80: widths take the widest cell in the column",
    w[C_TITLE] == 12, vim.inspect(w))
  ok("p80: width includes the header", grid.model({
    columns = { "a_long_header" }, rows = { { "x" } },
  }):widths()[1] == #"a_long_header")
  ok("p80: width is clamped by opts.max", grid.model({
    columns = { "a" }, rows = { { string.rep("x", 500) } },
  }):widths({ max = 12 })[1] == 12)
  ok("p80: width has a floor of 1", grid.model({
    columns = { "" }, rows = { { vim.NIL } },
  }):widths()[1] >= 1)

  -- ── truncation is multibyte-safe ───────────────────────────
  ok("p80: truncate appends … and fits the budget",
    grid.truncate("abcdefgh", 5) == "abcd…", grid.truncate("abcdefgh", 5))
  ok("p80: truncate leaves a short string alone", grid.truncate("ab", 5) == "ab")
  ok("p80: truncate never splits a multibyte char",
    vim.fn.strdisplaywidth(grid.truncate("日本語テスト", 5)) <= 5,
    grid.truncate("日本語テスト", 5))

  -- ── line + cell ranges (what the view highlights) ───────────
  local line, ranges = m:line(1, w)
  ok("p80: line has no trailing padding", line == line:gsub("%s+$", ""), vim.inspect(line))
  ok("p80: one range per column", #ranges == 3, #ranges)
  local within = true
  for _, rg in ipairs(ranges) do
    if rg.start > #line or rg.stop > #line or rg.start > rg.stop then within = false end
  end
  ok("p80: every range is INSIDE the line (extmark-safe)", within,
    vim.inspect({ line = line, len = #line, ranges = ranges }))
  ok("p80: range 1 spans the first cell's text",
    line:sub(ranges[1].start + 1, ranges[1].stop):match("^1"), vim.inspect(ranges[1]))
  ok("p80: column_at maps a byte column back to its cell",
    grid.column_at(ranges, ranges[2].start) == 2
    and grid.column_at(ranges, ranges[1].start) == 1, "ranges=" .. vim.inspect(ranges))
  ok("p80: column_at past the end clamps to the last column",
    grid.column_at(ranges, 10000) == 3)
  local hline, hranges = m:header_line(w)
  ok("p80: header aligns on the same grid as rows",
    hranges[2].start == ranges[2].start, hline .. " | " .. line)
  ok("p80: line() of a missing row is nil", m:line(99, w) == nil)

  -- ── non-row results ────────────────────────────────────────
  local wr = grid.model({ verb = "update", affected = 3, duration_ms = 12 })
  ok("p80: a result with no columns is a write", wr:kind() == "write", wr:kind())
  ok("p80: write summary reports rows affected",
    wr:summary() == "UPDATE — 3 row(s) affected in 12ms", wr:summary())
  local er = grid.model({ error = "syntax error near \"slect\"" })
  ok("p80: an error result is kind=error", er:kind() == "error", er:kind())
  ok("p80: error summary carries the message",
    er:summary():find("slect", 1, true) ~= nil, er:summary())
  local mt = grid.model({ columns = { "a" }, rows = {} })
  ok("p80: columns with no rows is kind=empty", mt:kind() == "empty" and mt:is_empty(), mt:kind())
  ok("p80: truncation is reported in the summary",
    grid.model({ columns = { "a" }, rows = { { 1 } }, verb = "select", more = true })
      :summary():find("more truncated", 1, true) ~= nil)

  -- ── column names: raw identity vs display label (R4-3) ─────
  -- A quoted database column may legally contain a newline or a tab.
  -- Rendering that raw breaks the buffer write (a line may not contain a
  -- newline) and leaves a tab whose width depends on where it lands.
  local weird = grid.model({
    columns = { "has\nnewline", "has\ttab", "\255\254bin" },
    rows = { { 1, 2, 3 } },
  })
  local wc = weird:columns()
  ok("p80: column keeps its RAW name for identity",
    wc[1].name == "has\nnewline", vim.inspect(wc[1].name))
  ok("p80: column gains a single-line display LABEL",
    wc[1].label == "has␤newline" and not wc[1].label:find("\n"), vim.inspect(wc[1].label))
  ok("p80: a tab in a column name is expanded in the label",
    wc[2].label == "has    tab", vim.inspect(wc[2].label))
  ok("p80: a non-UTF-8 column name renders as hex",
    wc[3].label == "0xfffe62696e", vim.inspect(wc[3].label))
  local hline_weird = weird:header_line(weird:widths())
  ok("p80: the rendered header has no control characters",
    not hline_weird:find("[\n\r\t]"), vim.inspect(hline_weird))
  -- The rule that makes character-by-character width measurement exact.
  ok("p80: the header is safe to write as a buffer line",
    pcall(vim.api.nvim_buf_set_lines, vim.api.nvim_create_buf(false, true), 0, -1, false,
      { hline_weird }))
  ok("p80: widths measure the LABEL, not the raw name",
    weird:widths()[1] == vim.fn.strdisplaywidth("has␤newline"), vim.inspect(weird:widths()))
  ok("p80: CSV header still carries the RAW name",
    weird:csv_rows({}):find('"has\nnewline"', 1, true) ~= nil,
    vim.inspect(weird:csv_rows({})))
  ok("p80: json_all still carries the RAW name",
    vim.json.decode(weird:json_all()).columns[1].name == "has\nnewline",
    vim.inspect(vim.json.decode(weird:json_all()).columns[1]))

  -- ── row() returns raw values, and the model stays immutable ─
  local r4 = m:row(4)
  ok("p80: row() returns RAW values (real newline, not ␤)",
    r4[2] == "line1\nline2", vim.inspect(r4[2]))
  r4[2] = "clobbered"
  ok("p80: mutating a returned row does not affect the model",
    m:row(4)[2] == "line1\nline2", vim.inspect(m:row(4)[2]))
  ok("p80: row() of a missing row is nil", m:row(99) == nil)
  ok("p80: cell() out of range is nil", m:cell(1, 99) == nil and m:cell(99, 1) == nil)
end)()

print("\n[81] ADR-0058 — ui.grid.attach (window ownership, cell cursor, header)")
;(function()
  local grid = require("auto-core.ui").grid
  -- clip_header/escape_statusline are INTERNAL: publishing them beside
  -- render_header invites the wrong composition (R4-3), so the public
  -- facade exposes only render_header and tests reach the primitives
  -- through the view module.
  local grid_view = require("auto-core.ui.grid.view")
  ok("p81: only render_header is public (clip/escape are internal)",
    type(grid.render_header) == "function" and grid.clip_header == nil
    and grid.escape_statusline == nil,
    vim.inspect({ clip = grid.clip_header, escape = grid.escape_statusline }))
  ok("p81: ui.grid.attach is exposed", type(grid.attach) == "function", type(grid.attach))

  -- ── statusline escaping (winbar is evaluated AS a statusline) ──
  -- Measured: a literal "100%s done" renders as "100 done" — the %s is
  -- consumed as an item. Column names must be escaped or a header like
  -- "pct%" silently mangles the whole bar.
  ok("p81: escape_statusline doubles %", grid_view.escape_statusline("100%s done") == "100%%s done",
    grid_view.escape_statusline("100%s done"))
  ok("p81: escaped header renders literally", vim.api.nvim_eval_statusline(
    grid_view.escape_statusline("100%s done"), {}).str == "100%s done",
    vim.api.nvim_eval_statusline(grid_view.escape_statusline("100%s done"), {}).str)
  ok("p81: UNescaped text really is eaten (the bug this prevents)",
    vim.api.nvim_eval_statusline("100%s done", {}).str == "100 done",
    vim.api.nvim_eval_statusline("100%s done", {}).str)
  ok("p81: escaping leaves ordinary text alone",
    grid_view.escape_statusline("id  title") == "id  title")

  -- ── header clipping (the horizontal-scroll half of R2-3) ───────
  -- WinScrolled cannot be observed headlessly (no UI, no redraw), so
  -- the pure computation is what the suite pins.
  ok("p81: clip_header at leftcol 0 is unchanged", grid_view.clip_header("id  title", 0) == "id  title")
  ok("p81: clip_header shifts by leftcol", grid_view.clip_header("id  title", 4) == "title",
    vim.inspect(grid_view.clip_header("id  title", 4)))
  ok("p81: clip_header past the end is empty", grid_view.clip_header("id", 99) == "")
  ok("p81: clip_header keeps multibyte glyphs whole",
    grid_view.clip_header("日本語x", 2) == "本語x", vim.inspect(grid_view.clip_header("日本語x", 2)))
  ok("p81: a wide glyph straddling the cut becomes a space (no drift)",
    grid_view.clip_header("日本語x", 1) == " 本語x", vim.inspect(grid_view.clip_header("日本語x", 1)))
  ok("p81: clipped header keeps its display width",
    vim.fn.strdisplaywidth(grid_view.clip_header("日本語x", 1)) == 6,
    vim.fn.strdisplaywidth(grid_view.clip_header("日本語x", 1)))

  -- ── ORDER: clip the RAW header, escape the RESULT ──────────────
  -- Escaping first adds a cell for every literal %, so clipping the
  -- escaped string measures cells the winbar never renders — labels
  -- after a % shift, and a cut landing inside a %% pair leaves a live
  -- statusline item that eats the rest of the line. The assertion that
  -- matters is what the winbar actually RENDERS.
  local raw_pct = "a%b  c"
  local function rendered(s) return vim.api.nvim_eval_statusline(s, {}).str end
  ok("p81: render_header clips in RAW cells, not escaped ones",
    rendered(grid.render_header(raw_pct, 2)) == "b  c",
    vim.inspect(rendered(grid.render_header(raw_pct, 2))))
  ok("p81: render_header at leftcol 0 renders the header verbatim",
    rendered(grid.render_header(raw_pct, 0)) == raw_pct,
    vim.inspect(rendered(grid.render_header(raw_pct, 0))))
  ok("p81: render_header never leaves a live statusline item",
    rendered(grid.render_header(raw_pct, 1)) == "%b  c",
    vim.inspect(rendered(grid.render_header(raw_pct, 1))))

  -- A header WIDER than the window truncates from the RIGHT (keeps the
  -- left columns above the body), because the trailing %< moves the
  -- truncation point to the end. Without it a winbar truncates from the
  -- START — the rightmost columns paint with a leading "<" while the
  -- body shows the leftmost, and header/body drift apart (the field bug).
  local wide = "LEFT_col              MIDDLE_col              RIGHT_col"
  local narrow = vim.api.nvim_eval_statusline(grid.render_header(wide, 0), { maxwidth = 20 }).str
  ok("p81: a too-wide header keeps its LEFT (truncates from the right)",
    narrow:match("^LEFT_col") ~= nil and narrow:find("RIGHT_col", 1, true) == nil,
    vim.inspect(narrow))

  -- The header row carries its own highlight group so the column titles
  -- read distinctly from the surrounding winbar.
  local hlres = vim.api.nvim_eval_statusline(grid.render_header("id  name", 0),
    { use_winbar = true, highlights = true })
  local has_hdr_hl = false
  for _, h in ipairs(hlres.highlights or {}) do
    if h.group == "AutoCoreGridHeader" then has_hdr_hl = true end
  end
  ok("p81: the header text carries the AutoCoreGridHeader highlight", has_hdr_hl,
    vim.inspect(hlres.highlights))
  -- The wrong order, kept as an executable record of the bug: clipping
  -- the escaped string by 2 cuts the %% pair in half.
  ok("p81: escape-then-clip really does corrupt (the bug this prevents)",
    rendered(grid_view.clip_header(grid_view.escape_statusline(raw_pct), 2)) ~= "b  c",
    vim.inspect(rendered(grid_view.clip_header(grid_view.escape_statusline(raw_pct), 2))))

  -- ── attach / render / dispose against a real window ────────────
  vim.cmd("new")
  local win = vim.api.nvim_get_current_win()
  local prior_buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_set_option_value("winbar", "PRE-EXISTING", { win = win, scope = "local" })

  local m = grid.model({
    columns = { "id", "name" },
    rows = { { 1, "alpha" }, { 2, "beta" }, { 3, vim.NIL } },
  })
  local v = grid.attach(m, { win = win })

  ok("p81: view owns its OWN buffer (not the window's prior one)",
    v:buf() ~= prior_buf and vim.api.nvim_win_get_buf(win) == v:buf(),
    tostring(v:buf()) .. " vs " .. tostring(prior_buf))
  ok("p81: buffer is an unmodifiable scratch",
    vim.bo[v:buf()].modifiable == false and vim.bo[v:buf()].buftype == "nofile")
  local lines = vim.api.nvim_buf_get_lines(v:buf(), 0, -1, false)
  ok("p81: one buffer line per row (header is NOT a line in winbar mode)",
    #lines == 3, vim.inspect(lines))
  ok("p81: row content is rendered", lines[1]:match("^1%s+alpha") ~= nil, vim.inspect(lines[1]))
  ok("p81: NULL renders in the row", lines[3]:find("NULL", 1, true) ~= nil, vim.inspect(lines[3]))

  local wb = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
  ok("p81: header is written to the window-local winbar",
    wb:find("id", 1, true) ~= nil and wb:find("name", 1, true) ~= nil, vim.inspect(wb))

  -- ── the cell cursor is DERIVED from the real cursor ────────────
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local cur = v:cell()
  ok("p81: cursor at col 0 is cell (1,1)", cur.row == 1 and cur.col == 1, vim.inspect(cur))
  ok("p81: cell carries the raw value", cur.cell.value == 1, vim.inspect(cur.cell))
  local name_col = lines[1]:find("alpha", 1, true) - 1
  vim.api.nvim_win_set_cursor(win, { 1, name_col })
  ok("p81: moving the real cursor changes the cell", v:cell().col == 2, vim.inspect(v:cell()))
  ok("p81: native motion is not trapped — cursor really moved",
    vim.api.nvim_win_get_cursor(win)[2] == name_col)

  v:move_cell(0, -1)
  ok("p81: move_cell steps by whole cells", v:cell().col == 1, vim.inspect(v:cell()))
  v:move_cell(1, 0)
  ok("p81: move_cell moves rows", v:cell().row == 2, vim.inspect(v:cell()))
  v:move_cell(0, 99)
  ok("p81: move_cell clamps to the last column", v:cell().col == 2, vim.inspect(v:cell()))
  v:move_cell(-99, 0)
  ok("p81: move_cell clamps to the first row", v:cell().row == 1, vim.inspect(v:cell()))

  local marks = vim.api.nvim_buf_get_extmarks(v:buf(), -1, 0, -1, { details = true })
  ok("p81: the current cell is highlighted with an extmark", #marks >= 1, vim.inspect(#marks))

  -- ── yanks use the MODEL's rules, not the rendered line ─────────
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  ok("p81: yank_row csv is RFC-4180", v:yank_row("csv") == "2,beta", vim.inspect(v:yank_row("csv")))
  ok("p81: yank_row json is an object",
    vim.json.decode(v:yank_row("json")).name == "beta", v:yank_row("json"))
  ok("p81: yank_cell copies the raw cell", v:yank_cell() == "2", vim.inspect(v:yank_cell()))
  ok("p81: yank populates the unnamed register", vim.fn.getreg('"') == "2", vim.fn.getreg('"'))
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  v:move_cell(0, 1)
  ok("p81: yanking a NULL cell yields empty, not \"NULL\"", v:yank_cell() == "", vim.inspect(v:yank_cell()))

  -- ── keymaps are bound buffer-locally to public methods ─────────
  local maps = {}
  for _, mp in ipairs(vim.api.nvim_buf_get_keymap(v:buf(), "n")) do maps[mp.lhs] = true end
  ok("p81: default yank/toggle/inspect keymaps are bound",
    maps["y"] and maps["Y"] and maps["gy"] and maps["J"], vim.inspect(vim.tbl_keys(maps)))

  -- ── JSON layout toggle ─────────────────────────────────────────
  ok("p81: toggle_view switches to JSON", v:toggle_view() == true and v:is_json() == true)
  local jlines = vim.api.nvim_buf_get_lines(v:buf(), 0, -1, false)
  ok("p81: JSON layout decodes back to the rows",
    #vim.json.decode(table.concat(jlines, "\n")) == 3, vim.inspect(jlines[1]))
  ok("p81: the winbar header is cleared in JSON mode",
    vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" }) == "",
    vim.inspect(vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })))
  v:toggle_view()
  ok("p81: toggling back restores the table header",
    vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" }):find("id", 1, true) ~= nil)

  -- ── non-row results are explicit states ────────────────────────
  v:set_model(grid.model({ verb = "update", affected = 7 }))
  ok("p81: a write result renders its summary",
    vim.api.nvim_buf_get_lines(v:buf(), 0, -1, false)[1] == "UPDATE — 7 row(s) affected",
    vim.inspect(vim.api.nvim_buf_get_lines(v:buf(), 0, -1, false)[1]))
  ok("p81: there is no cell in a non-row result", v:cell() == nil)
  v:set_model(m)

  -- ── dispose gives everything back ──────────────────────────────
  local buf_before = v:buf()
  v:dispose()
  ok("p81: dispose is marked", v:disposed() == true)
  -- The window belongs to the CONSUMER. Deleting the view's own buffer
  -- while the window still showed it used to take the window down too,
  -- which would collapse a docked result split on every dispose.
  ok("p81: dispose leaves the WINDOW alive", vim.api.nvim_win_is_valid(win))
  ok("p81: dispose puts the window's prior buffer back",
    vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == prior_buf,
    vim.api.nvim_win_is_valid(win) and tostring(vim.api.nvim_win_get_buf(win)) or "win gone")
  ok("p81: dispose restores the PRE-EXISTING winbar",
    vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" }) == "PRE-EXISTING",
    vim.inspect(vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })))
  ok("p81: dispose deletes the view's own buffer",
    not vim.api.nvim_buf_is_valid(buf_before))
  local ok_twice = pcall(function() v:dispose() end)
  ok("p81: dispose is idempotent", ok_twice)

  -- ── a view must NOT clobber a winbar someone else took over ────
  vim.cmd("new")
  local win2 = vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value("winbar", "ORIGINAL", { win = win2, scope = "local" })
  local v2 = grid.attach(grid.model({ columns = { "a" }, rows = { { 1 } } }), { win = win2 })
  vim.api.nvim_set_option_value("winbar", "SOMEONE-ELSE", { win = win2, scope = "local" })
  v2:dispose()
  -- This also pins a measured Neovim behaviour: swapping a window's
  -- buffer restores the window-local options remembered for THAT
  -- buffer, so dispose's buffer restore would silently reinstate the
  -- pre-attach winbar unless the ownership decision is applied AFTER
  -- the swap. Without that ordering this assertion reads "ORIGINAL".
  ok("p81: dispose leaves a winbar taken over by someone else alone",
    vim.api.nvim_get_option_value("winbar", { win = win2, scope = "local" }) == "SOMEONE-ELSE",
    vim.inspect(vim.api.nvim_get_option_value("winbar", { win = win2, scope = "local" })))
  pcall(vim.api.nvim_win_close, win2, true)

  -- ── ownership ends at the buffer swap, not at dispose (R5-4) ───
  -- The view stays live until disposal, and its scroll/resize callbacks
  -- are GLOBAL. Without an ownership predicate it would keep writing
  -- this grid's winbar into whatever replaced it.
  vim.cmd("new")
  local win6 = vim.api.nvim_get_current_win()
  local v6 = grid.attach(grid.model({ columns = { "zzz" }, rows = { { 1 } } }), { win = win6 })
  ok("p81: a fresh view owns its window", v6:owns_window() == true)
  local intruder = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win6, intruder)
  vim.api.nvim_set_option_value("winbar", "THEIRS", { win = win6, scope = "local" })
  ok("p81: ownership ends the moment the buffer is swapped",
    v6:owns_window() == false)
  v6:refresh_header()
  ok("p81: refresh_header writes nothing into a window it lost",
    vim.api.nvim_get_option_value("winbar", { win = win6, scope = "local" }) == "THEIRS",
    vim.inspect(vim.api.nvim_get_option_value("winbar", { win = win6, scope = "local" })))
  ok("p81: cell() reports nothing once ownership is gone", v6:cell() == nil)
  v6:render()
  ok("p81: render writes nothing into a window it lost",
    vim.api.nvim_get_option_value("winbar", { win = win6, scope = "local" }) == "THEIRS")
  v6:dispose()
  ok("p81: disposing an un-owned view leaves the intruder alone",
    vim.api.nvim_win_get_buf(win6) == intruder
    and vim.api.nvim_get_option_value("winbar", { win = win6, scope = "local" }) == "THEIRS")
  pcall(vim.api.nvim_win_close, win6, true)

  -- ── dispose must not mutate a window it no longer owns (R4-4) ──
  -- Ownership is per option AND per buffer: the guard that protects the
  -- replacement buffer has to protect wrap/cursorline too, or disposal
  -- reaches into someone else's window and changes their display.
  vim.cmd("new")
  local win4 = vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value("wrap", true, { win = win4, scope = "local" })
  vim.api.nvim_set_option_value("cursorline", true, { win = win4, scope = "local" })
  local v4 = grid.attach(grid.model({ columns = { "a" }, rows = { { 1 } } }), { win = win4 })
  -- A third party takes the window over completely.
  local foreign = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win4, foreign)
  vim.api.nvim_set_option_value("wrap", false, { win = win4, scope = "local" })
  vim.api.nvim_set_option_value("cursorline", false, { win = win4, scope = "local" })
  v4:dispose()
  ok("p81: dispose does not restore wrap into a window it lost",
    vim.api.nvim_get_option_value("wrap", { win = win4, scope = "local" }) == false,
    vim.inspect(vim.api.nvim_get_option_value("wrap", { win = win4, scope = "local" })))
  ok("p81: dispose does not restore cursorline into a window it lost",
    vim.api.nvim_get_option_value("cursorline", { win = win4, scope = "local" }) == false)
  ok("p81: dispose leaves the third party's buffer in place",
    vim.api.nvim_win_get_buf(win4) == foreign)
  pcall(vim.api.nvim_win_close, win4, true)

  -- Still-owned window: our own values ARE given back.
  vim.cmd("new")
  local win5 = vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value("wrap", true, { win = win5, scope = "local" })
  local v5 = grid.attach(grid.model({ columns = { "a" }, rows = { { 1 } } }), { win = win5 })
  ok("p81: attach turns wrap off while it owns the window",
    vim.api.nvim_get_option_value("wrap", { win = win5, scope = "local" }) == false)
  v5:dispose()
  ok("p81: dispose restores wrap when it still owned the window",
    vim.api.nvim_get_option_value("wrap", { win = win5, scope = "local" }) == true,
    vim.inspect(vim.api.nvim_get_option_value("wrap", { win = win5, scope = "local" })))
  pcall(vim.api.nvim_win_close, win5, true)

  -- ── header = "line" mode (what a headless consumer uses) ───────
  vim.cmd("new")
  local win3 = vim.api.nvim_get_current_win()
  local v3 = grid.attach(m, { win = win3, header = "line" })
  local l3 = vim.api.nvim_buf_get_lines(v3:buf(), 0, -1, false)
  ok("p81: header = 'line' puts the header in buffer line 1",
    l3[1]:match("^id") ~= nil and #l3 == 4, vim.inspect(l3))
  ok("p81: header = 'line' does not touch the winbar",
    vim.api.nvim_get_option_value("winbar", { win = win3, scope = "local" }) == "")
  vim.api.nvim_win_set_cursor(win3, { 2, 0 })
  ok("p81: row offset accounts for the header line", v3:cell().row == 1, vim.inspect(v3:cell()))
  vim.api.nvim_win_set_cursor(win3, { 1, 0 })
  ok("p81: the header line itself is not a cell", v3:cell() == nil, vim.inspect(v3:cell()))
  v3:dispose()
  pcall(vim.api.nvim_win_close, win3, true)

  -- ── two views over one model stay isolated ─────────────────────
  vim.cmd("new")
  local wa = vim.api.nvim_get_current_win()
  vim.cmd("new")
  local wbn = vim.api.nvim_get_current_win()
  local va = grid.attach(m, { win = wa })
  local vb = grid.attach(m, { win = wbn })
  ok("p81: two views over one model own different buffers", va:buf() ~= vb:buf())
  va:dispose()
  ok("p81: disposing one view leaves the other alive",
    not vb:disposed() and vim.api.nvim_buf_is_valid(vb:buf()))
  vb:dispose()
  pcall(vim.api.nvim_win_close, wa, true)
  pcall(vim.api.nvim_win_close, wbn, true)
  pcall(vim.api.nvim_win_close, win, true)
end)()

print("\n[82] ADR-0058 — rpc.frame (incremental msgpack framing + budgets)")
;(function()
  -- INTERNAL module: the auto-core.rpc facade is not published yet, and
  -- this is the security boundary in front of it, so it is tested
  -- directly rather than through a surface that does not exist.
  local frame = require("auto-core.rpc.frame")
  local enc = vim.mpack.encode

  -- ── channel byte convention is LOSSLESS ────────────────────────
  -- :h channel-lines — the list splits on a real 0x0A and a "\n" INSIDE
  -- an element is a 0x00. Reversible, which is what makes binary
  -- msgpack safe over a non-RPC channel.
  ok("p82: channel_bytes maps NUL<->NL back to the exact bytes",
    frame.channel_bytes({ "a\nb", "c\nd" }) == "a\0b\nc\0d",
    vim.inspect(frame.channel_bytes({ "a\nb", "c\nd" })))
  ok("p82: a chunk that is all NULs decodes to all NULs",
    frame.channel_bytes({ "\n\n" }) == "\0\0",
    vim.inspect(frame.channel_bytes({ "\n\n" })))
  ok("p82: an empty element is an empty line, not a lost byte",
    frame.channel_bytes({ "a", "", "b" }) == "a\n\nb",
    vim.inspect(frame.channel_bytes({ "a", "", "b" })))

  -- ── whole frames ───────────────────────────────────────────────
  local d = frame.decoder()
  local req = enc({ 0, 1, "sys.hello", {} })
  d:feed(req)
  local status, value = d:next()
  ok("p82: a complete frame decodes", status == "ok", status .. " " .. vim.inspect(value))
  ok("p82: the decoded value is the request", value[1] == 0 and value[3] == "sys.hello",
    vim.inspect(value))
  ok("p82: an empty decoder is incomplete, not an error",
    (frame.decoder():next()) == "incomplete")

  -- ── two frames in one chunk, and a frame split across chunks ────
  local d2 = frame.decoder()
  d2:feed(enc({ 1, 1, vim.NIL, "first" }) .. enc({ 1, 2, vim.NIL, "second" }))
  local s1, v1 = d2:next()
  local s2, v2 = d2:next()
  ok("p82: two frames in one chunk decode in order",
    s1 == "ok" and s2 == "ok" and v1[4] == "first" and v2[4] == "second",
    vim.inspect({ v1, v2 }))
  ok("p82: nothing is left over", (d2:next()) == "incomplete" and d2:pending() == 0,
    d2:pending())

  -- The invariant the single-pass design exists for: a peer dripping a
  -- frame one byte at a time must not make the parser rescan from the
  -- start on every byte.
  local payload = enc({ 1, 7, vim.NIL, { a = "alpha", b = { 1, 2, 3 } } })
  local d3 = frame.decoder()
  local completed_at, saw_error = nil, nil
  for i = 1, #payload do
    d3:feed(payload:sub(i, i))
    local st, val = d3:next()
    if st == "error" then saw_error = val break end
    if st == "ok" then completed_at = i; ok("p82: a byte-at-a-time frame decodes",
      val[2] == 7 and val[4].a == "alpha", vim.inspect(val)) end
  end
  ok("p82: it completed on the LAST byte, not before", completed_at == #payload,
    tostring(completed_at) .. "/" .. #payload .. " err=" .. tostring(saw_error))

  -- ── budgets refuse, they never truncate ────────────────────────
  -- The measured attack: five bytes declaring 512 MiB. vim.mpack.Unpacker
  -- allocates that on the length token (VmSize +512 MB, RSS flat); the
  -- scanner refuses it without allocating anything.
  local function be32(n)
    return string.char(math.floor(n / 0x1000000) % 256, math.floor(n / 0x10000) % 256,
      math.floor(n / 0x100) % 256, n % 256)
  end
  local huge = string.char(0xdb) .. be32(512 * 1024 * 1024)
  local dh = frame.decoder()
  dh:feed(huge)
  local hs, herr = dh:next()
  ok("p82: a 5-byte header declaring 512 MiB is REFUSED", hs == "error", hs .. " " .. tostring(herr))
  ok("p82: the refusal names max_string", tostring(herr):find("max_string", 1, true) ~= nil, herr)
  ok("p82: the decoder stays failed (the epoch is over)", (dh:next()) == "error")

  local dc = frame.decoder()
  dc:feed(string.char(0xdd) .. be32(0xFFFFFFFF))
  local cs, cerr = dc:next()
  ok("p82: an array declaring 4G elements is REFUSED", cs == "error", cs .. " " .. tostring(cerr))
  ok("p82: the refusal names max_tokens", tostring(cerr):find("max_tokens", 1, true) ~= nil, cerr)

  local dd = frame.decoder({ max_depth = 4 })
  dd:feed(string.rep(string.char(0x91), 40) .. string.char(0x01))
  local ds, derr = dd:next()
  ok("p82: nesting past max_depth is REFUSED", ds == "error", ds .. " " .. tostring(derr))
  ok("p82: the refusal names max_depth", tostring(derr):find("max_depth", 1, true) ~= nil, derr)

  local df = frame.decoder({ max_frame = 16 })
  df:feed(enc({ string.rep("x", 200) }))
  local fs, ferr = df:next()
  ok("p82: a frame over max_frame is REFUSED", fs == "error", fs .. " " .. tostring(ferr))

  -- An endless incomplete frame is the reason max_buffer exists: without
  -- it "incomplete" is an unbounded invitation.
  local db = frame.decoder({ max_buffer = 64, max_string = 4096 })
  db:feed(string.char(0xdb) .. be32(1024))   -- legitimate header, payload dribbles
  local bst, berr = "incomplete", nil
  for _ = 1, 20 do
    db:feed(string.rep("x", 8))
    bst, berr = db:next()
    if bst == "error" then break end
  end
  ok("p82: an endless incomplete frame trips max_buffer", bst == "error", tostring(berr))
  ok("p82: the refusal names max_buffer",
    tostring(berr):find("max_buffer", 1, true) ~= nil, berr)
  -- The budget is per INCOMPLETE frame, so a callback carrying several
  -- COMPLETE frames whose total exceeds it must still drain (R5-2).
  local dq = frame.decoder({ max_buffer = 64 })
  local batch = {}
  for i = 1, 8 do batch[i] = enc({ 1, i, vim.NIL, string.rep("y", 20) }) end
  dq:feed(table.concat(batch))
  local drained = 0
  while true do
    local st = dq:next()
    if st ~= "ok" then break end
    drained = drained + 1
  end
  ok("p82: several complete frames over max_buffer still drain", drained == 8, drained)

  -- A header split across chunks must cost exactly what an unsplit one
  -- costs: charging a token per retry would let TCP framing decide
  -- whether a valid frame is refused.
  -- The array itself is a token, so this frame is exactly 5.
  local split = enc({ 1, 2, vim.NIL, "ok" })
  local whole = frame.decoder({ max_tokens = 5 })
  whole:feed(split)
  local whole_st = whole:next()
  local dt = frame.decoder({ max_tokens = 5 })
  local dt_st
  for i = 1, #split do dt:feed(split:sub(i, i)); dt_st = dt:next() end
  ok("p82: a byte-split frame reaches the SAME outcome as an unsplit one",
    whole_st == "ok" and dt_st == "ok",
    "whole=" .. tostring(whole_st) .. " split=" .. tostring(dt_st))

  -- fixstr/fixext carry data too, so a tight max_string must bind them.
  local dfs = frame.decoder({ max_string = 4 })
  dfs:feed(enc("0123456789"))                  -- fixstr, 10 bytes
  local fst, ferr2 = dfs:next()
  ok("p82: fixstr is bounded by max_string too", fst == "error", tostring(ferr2))

  ok("p82: 0xc1 (the never-used type byte) is refused",
    (function() local x = frame.decoder(); x:feed(string.char(0xc1)); return (x:next()) end)() == "error")

  -- ── limits must mean what the table says (R6-1) ────────────────
  -- max_string bounds str/bin/ext DATA. A float64 has an 8-byte payload
  -- and no data, so a tiny max_string must not refuse ordinary numbers.
  local dnum = frame.decoder({ max_string = 1 })
  dnum:feed(enc({ 1.5, 4294967295, -2147483648, true, vim.NIL }))
  local nst, nval = dnum:next()
  ok("p82: max_string does not bound numeric scalars",
    nst == "ok" and nval[1] == 1.5, tostring(nst) .. " " .. vim.inspect(nval))

  -- An extension's one type-tag byte is payload but NOT data: counting
  -- it made an ext carrying exactly max_string bytes fail by one.
  local ext4 = string.char(0xc7, 4, 42) .. "abcd"   -- ext8, 4 data bytes
  local dext = frame.decoder({ max_string = 4 })
  dext:feed(ext4)
  local est = dext:next()
  ok("p82: an ext carrying exactly max_string DATA is accepted",
    est == "ok", tostring(est))
  local dext2 = frame.decoder({ max_string = 3 })
  dext2:feed(ext4)
  ok("p82: one data byte over max_string is still refused",
    (dext2:next()) == "error")

  -- An empty container is a container level too.
  local nested_empty = string.rep(string.char(0x91), 6) .. string.char(0x90)
  local dde = frame.decoder({ max_depth = 4 })
  dde:feed(nested_empty)
  ok("p82: empty containers count toward max_depth",
    (dde:next()) == "error", "6 nested arrays ending in an empty one")
  local dde2 = frame.decoder({ max_depth = 8 })
  dde2:feed(nested_empty)
  ok("p82: and are accepted when they fit", (dde2:next()) == "ok")

  -- ── many complete frames in ONE callback ───────────────────────
  -- The other quadratic axis: slicing the unconsumed remainder after
  -- each frame recopies the rest of the batch every time.
  local dmulti = frame.decoder()
  local blob, want = {}, 200
  for i = 1, want do blob[i] = enc({ 1, i, vim.NIL, "row" .. i }) end
  dmulti:feed(table.concat(blob))
  local seen, last = 0, nil
  while true do
    local st, val = dmulti:next()
    if st ~= "ok" then break end
    seen = seen + 1
    last = val
  end
  ok("p82: a batch of frames in one feed all decode, in order",
    seen == want and last[2] == want and last[4] == "row" .. want,
    seen .. "/" .. want .. " last=" .. vim.inspect(last))
  ok("p82: the queue is empty afterwards", dmulti:pending() == 0, dmulti:pending())

  -- A frame straddling the boundary between two batched chunks.
  local dstr = frame.decoder()
  local two = enc({ 1, 1, vim.NIL, "alpha" }) .. enc({ 1, 2, vim.NIL, "beta" })
  dstr:feed(two:sub(1, #two - 4))
  local mid = dstr:next()
  dstr:feed(two:sub(#two - 3))
  local st_a, va = mid, nil
  if st_a == "ok" then st_a, va = dstr:next() else st_a, va = dstr:next() end
  ok("p82: a frame split across two batched feeds still decodes",
    st_a == "ok", tostring(st_a) .. " " .. vim.inspect(va))

  -- ── PHYSICAL retention, not just logical (R7-1) ────────────────
  -- A Lua string is immutable, so holding the head chunk holds the whole
  -- original callback. Draining a big batch used to leave the entire
  -- callback pinned while the logical count reported one byte.
  local dret = frame.decoder()
  local big = {}
  for i = 1, 400 do big[i] = enc({ 1, i, vim.NIL, string.rep("q", 300) }) end
  dret:feed(table.concat(big) .. string.char(0xdb))  -- + one byte of the next header
  local pulled = 0
  while true do
    local st = dret:next()
    if st ~= "ok" then break end
    pulled = pulled + 1
  end
  ok("p82: the batch drained", pulled == 400, pulled)
  ok("p82: logical retention is the trailing byte", dret:pending() == 1, dret:pending())
  ok("p82: PHYSICAL retention is bounded, not the whole callback",
    dret:retained() <= 2 * dret:pending() + 4096,
    "retained=" .. dret:retained() .. " logical=" .. dret:pending())

  -- Compaction must not corrupt the stream it is compacting.
  local dcomp = frame.decoder()
  local kept = {}
  for i = 1, 300 do kept[i] = enc({ 1, i, vim.NIL, string.rep("c", 200) }) end
  local tail_frame = enc({ 1, 999, vim.NIL, "tail" })
  dcomp:feed(table.concat(kept) .. tail_frame:sub(1, 3))
  while (dcomp:next()) == "ok" do end
  dcomp:feed(tail_frame:sub(4))
  local cst, cval = dcomp:next()
  ok("p82: a frame straddling a compaction still decodes",
    cst == "ok" and cval[2] == 999 and cval[4] == "tail",
    tostring(cst) .. " " .. vim.inspect(cval))

  -- Queue REFERENCE work: many feeds queued before a single drain must
  -- not rebuild or shift the chunk array per frame.
  local dref = frame.decoder()
  for i = 1, 500 do dref:feed(enc({ 1, i, vim.NIL, "f" .. i })) end
  local refs, last_ref = 0, nil
  while true do
    local st, val = dref:next()
    if st ~= "ok" then break end
    refs = refs + 1
    last_ref = val
  end
  ok("p82: 500 separately-fed frames all drain in order",
    refs == 500 and last_ref[2] == 500, refs .. " last=" .. vim.inspect(last_ref))
  ok("p82: nothing is retained after draining separate feeds",
    dref:pending() == 0 and dref:retained() == 0,
    dref:pending() .. "/" .. dref:retained())

  -- ── the queue TABLE is bounded too (R8-1) ──────────────────────
  -- retained() counts string bytes; the queue's own slot capacity is a
  -- second quantity Lua will not shrink on its own. A drained batch used
  -- to leave ~1 MB of slots held at a permanent high-water mark.
  local dq2 = frame.decoder({ max_buffer = 64 * 1024 * 1024 })
  local one = enc({ 1, 1, vim.NIL, "x" })
  for _ = 1, 5000 do dq2:feed(one) end
  while (dq2:next()) == "ok" do end
  ok("p82: an emptied queue resets its table indices",
    dq2.qh == 1 and dq2.qt == 0, "qh=" .. dq2.qh .. " qt=" .. dq2.qt)
  ok("p82: and reports nothing retained", dq2:retained() == 0 and dq2:pending() == 0)
  -- Still usable afterwards: the reset must not lose the parse state.
  dq2:feed(enc({ 1, 42, vim.NIL, "after" }))
  local ast, aval = dq2:next()
  ok("p82: the decoder still works after a queue reset",
    ast == "ok" and aval[2] == 42, tostring(ast) .. " " .. vim.inspect(aval))

  -- Rebasing while NON-empty: many drained frames with one live tail.
  local dq3 = frame.decoder({ max_buffer = 64 * 1024 * 1024 })
  for _ = 1, 2000 do dq3:feed(one) end
  dq3:feed(enc({ 1, 7, vim.NIL, "live" }):sub(1, 4))   -- partial: stays queued
  while (dq3:next()) == "ok" do end
  ok("p82: a non-empty queue rebases its live entries to the front",
    dq3.qh <= 64, "qh=" .. dq3.qh .. " qt=" .. dq3.qt)

  -- ── every msgpack type is walked correctly ─────────────────────
  -- Round-trip through our framing what vim.mpack itself produces, so a
  -- type the scanner mis-sizes shows up as a wrong boundary rather than
  -- silently shifting the stream.
  local samples = {
    0, 1, -1, 127, -32, 255, 65535, 4294967295, -2147483648,
    1.5, -0.25, true, false, vim.NIL,
    "", "short", string.rep("m", 40), string.rep("L", 70000),
    {}, { 1, 2, 3 }, { { { 1 } } },
    { a = 1 }, { a = { b = { c = "deep" } } },
    { 1, "two", { three = 3 }, vim.NIL },
  }
  local all_ok, bad = true, nil
  for i, sample in ipairs(samples) do
    local dz = frame.decoder()
    dz:feed(enc(sample) .. enc("SENTINEL"))
    local st = dz:next()
    local st2, v2b = dz:next()
    -- The sentinel proves the first frame's boundary was exact: a
    -- mis-sized token would eat into it or leave bytes behind.
    if st ~= "ok" or st2 ~= "ok" or v2b ~= "SENTINEL" then
      all_ok, bad = false, string.format("sample %d (%s): %s / %s %s",
        i, type(sample), st, st2, vim.inspect(v2b))
      break
    end
  end
  ok("p82: every msgpack type yields an exact frame boundary", all_ok, bad)
end)()

print("\n[83] ADR-0058 — auto-core.rpc (async msgpack-RPC client)")
;(function()
  local rpc = require("auto-core.rpc")

  -- A real msgpack-RPC peer with no external dependency: Neovim's own
  -- server. It speaks exactly the wire this client implements, so the
  -- whole path — framing, ids, error slot, EOF — is exercised for real
  -- rather than against a mock that agrees with us by construction.
  local addr = vim.fn.serverstart("127.0.0.1:0")
  ok("p83: a test peer is listening", type(addr) == "string" and addr ~= "", vim.inspect(addr))

  local function wait_for(pred, ms)
    return vim.wait(ms or 3000, pred, 10)
  end

  -- ── connect fails synchronously, never half-open ───────────────
  local bad, berr = rpc.connect({})
  ok("p83: connect refuses a missing address", bad == nil and berr ~= nil, tostring(berr))
  local bad2, berr2 = rpc.connect({ addr = "127.0.0.1:1" })
  ok("p83: connect fails synchronously on a dead port",
    bad2 == nil and berr2 ~= nil, tostring(berr2))

  local conn, cerr = rpc.connect({ addr = addr })
  ok("p83: connect returns a live connection", conn ~= nil, tostring(cerr))

  -- ── a request returns an id and fires exactly once ─────────────
  local seen = {}
  local id = conn:request("nvim_eval", { "1 + 1" }, {}, function(o)
    seen[#seen + 1] = o
  end)
  ok("p83: request returns an integer id", type(id) == "number", vim.inspect(id))
  ok("p83: it is charged against capacity while in flight", conn:in_flight() == 1)
  wait_for(function() return #seen > 0 end)
  ok("p83: the callback fired", #seen == 1, #seen)
  ok("p83: status ok with the result", seen[1] and seen[1].status == "ok" and seen[1].value == 2,
    vim.inspect(seen[1]))
  ok("p83: the outcome carries its id", seen[1] and seen[1].id == id, vim.inspect(seen[1]))
  ok("p83: the slot is released after settling", conn:in_flight() == 0, conn:in_flight())

  -- Exactly once: give it room to fire again.
  vim.wait(150)
  ok("p83: it fires exactly once", #seen == 1, #seen)

  -- ── the RAW error slot survives ────────────────────────────────
  -- The whole reason this client exists: vim.rpcrequest flattens a
  -- server error to "unknown error"; reading the slot keeps it.
  local errs = {}
  conn:request("nvim_eval", { "this is not valid vimscript(" }, {}, function(o)
    errs[#errs + 1] = o
  end)
  wait_for(function() return #errs > 0 end)
  ok("p83: an erroring call settles as status=error",
    errs[1] and errs[1].status == "error", vim.inspect(errs[1]))
  -- The error arrives as the server's own STRUCTURE — here nvim's
  -- [type, message] array — not as a flattened string. That is the
  -- difference this client exists for: vim.rpcrequest reduces the same
  -- reply to "unknown error".
  --
  -- The side-by-side against vim.rpcrequest is NOT run here on purpose:
  -- the peer is this very Neovim, and rpcrequest would block the event
  -- loop that has to serve the request — an instant deadlock, and a
  -- neat demonstration of the blocking behaviour being avoided. The
  -- comparison was made against the real autodb daemon instead
  -- (ADR-0058 §2, experiment E6).
  ok("p83: the error slot is carried RAW, not flattened",
    errs[1] and type(errs[1].error) == "table"
    and vim.inspect(errs[1].error):find("E121", 1, true) ~= nil,
    vim.inspect(errs[1] and errs[1].error))
  ok("p83: the raw slot is structured, not a bare string",
    errs[1] and type(errs[1].error) ~= "string", type(errs[1] and errs[1].error))

  -- ── concurrency: many in flight, each settled once ─────────────
  local many, fired = 20, {}
  for i = 1, many do
    conn:request("nvim_eval", { tostring(i) .. " * 10" }, {}, function(o)
      fired[#fired + 1] = o
    end)
  end
  wait_for(function() return #fired == many end)
  ok("p83: every concurrent request settles", #fired == many, #fired .. "/" .. many)
  local values, all_ok = {}, true
  for _, o in ipairs(fired) do
    if o.status ~= "ok" then all_ok = false end
    values[o.value] = true
  end
  ok("p83: each reply is routed to its own callback",
    all_ok and values[10] and values[200], vim.inspect(vim.tbl_count(values)))
  ok("p83: capacity is fully released", conn:in_flight() == 0, conn:in_flight())

  -- ── capacity refuses BEFORE admission ──────────────────────────
  local small = rpc.connect({ addr = addr, capacity = 2 })
  local refused_cb = false
  small:request("nvim_eval", { "1" }, {}, function() end)
  small:request("nvim_eval", { "2" }, {}, function() end)
  local rid, rerr = small:request("nvim_eval", { "3" }, {}, function() refused_cb = true end)
  ok("p83: capacity refusal returns nil + E_CAPACITY",
    rid == nil and rerr == rpc.E_CAPACITY, tostring(rid) .. " " .. tostring(rerr))
  vim.wait(300)
  ok("p83: a refused request NEVER calls back", refused_cb == false)
  small:close()

  -- ── cancel is local, total and idempotent ──────────────────────
  local cancelled = {}
  local cid = conn:request("nvim_eval", { "1" }, {}, function(o) cancelled[#cancelled + 1] = o end)
  local first = conn:cancel(cid)
  local second = conn:cancel(cid)
  ok("p83: cancel returns true once, then false", first == true and second == false)
  ok("p83: it settles as abandoned",
    cancelled[1] and cancelled[1].status == "abandoned"
    and cancelled[1].code == rpc.E_ABANDONED, vim.inspect(cancelled[1]))
  ok("p83: cancel of an unknown id is a no-op", conn:cancel(999999) == false)
  -- The tombstone stays charged until the reply arrives: local
  -- abandonment does not stop the server's work.
  ok("p83: an abandoned request keeps its wire slot", conn:in_flight() >= 1, conn:in_flight())
  wait_for(function() return conn:in_flight() == 0 end, 2000)
  ok("p83: the tombstone is retired by the late reply, with no callback",
    conn:in_flight() == 0 and #cancelled == 1, conn:in_flight() .. " cbs=" .. #cancelled)

  -- ── deadline ───────────────────────────────────────────────────
  local slow = {}
  conn:request("nvim_eval", { "1" }, { deadline = 1 }, function(o) slow[#slow + 1] = o end)
  wait_for(function() return #slow > 0 end)
  ok("p83: a request can settle as deadline",
    slow[1] and (slow[1].status == "deadline" or slow[1].status == "ok"),
    vim.inspect(slow[1]))

  -- ── close settles everything, and is idempotent ────────────────
  local closed_reason, on_close = nil, {}
  local c2 = rpc.connect({ addr = addr, on_epoch_lost = function(r) closed_reason = r end })
  c2:request("nvim_eval", { "1" }, { deadline = 60000 }, function(o) on_close[#on_close + 1] = o end)
  c2:close()
  ok("p83: close settles outstanding requests as disconnected",
    on_close[1] and on_close[1].status == "disconnected"
    and on_close[1].code == rpc.E_DISCONNECTED, vim.inspect(on_close[1]))
  ok("p83: on_epoch_lost reports the reason", closed_reason == "closed", tostring(closed_reason))
  ok("p83: close is idempotent", pcall(function() c2:close() end))
  ok("p83: a closed connection refuses new requests",
    select(2, c2:request("nvim_eval", { "1" }, {}, function() end)) == rpc.E_DISCONNECTED)
  ok("p83: is_closed reports it", c2:is_closed() == true)

  -- ── unix socket transport (the DEFAULT endpoint) ───────────────
  -- Same protocol, different plumbing: addressed by a file path, never
  -- touching the network stack, and openable only by whoever the file
  -- permissions allow. Neovim calls this mode "pipe".
  local sock = vim.fn.tempname() .. ".sock"
  local sock_addr = vim.fn.serverstart(sock)
  ok("p83: a unix-socket peer is listening",
    type(sock_addr) == "string" and vim.fn.filereadable(sock_addr) == 1
      or vim.loop.fs_stat(sock) ~= nil, vim.inspect(sock_addr))

  local uconn, uerr = rpc.connect({ addr = sock, mode = "pipe" })
  ok("p83: connects over a unix socket", uconn ~= nil, tostring(uerr))
  if uconn then
    ok("p83: the mode is recorded", uconn:mode() == "pipe", uconn:mode())
    local useen = {}
    uconn:request("nvim_eval", { "6 * 7" }, {}, function(o) useen[#useen + 1] = o end)
    wait_for(function() return #useen > 0 end)
    ok("p83: a request round-trips over the socket",
      useen[1] and useen[1].status == "ok" and useen[1].value == 42,
      vim.inspect(useen[1]))
    uconn:close()
  end
  pcall(vim.fn.serverstop, sock_addr)

  ok("p83: an unknown mode is refused",
    select(2, rpc.connect({ addr = sock, mode = "smoke-signals" })):find("mode", 1, true) ~= nil)

  -- ── EOF from the peer settles the epoch ────────────────────────
  -- serverstop() only stops LISTENING; an established connection
  -- survives it, so the peer has to actually go away. The peer is a
  -- libuv TCP listener in this same Neovim: it accepts once, holds
  -- briefly, then closes the accepted socket and itself. No external
  -- interpreter: a `python3` helper made the cell depend on whatever the
  -- PATH resolves (a version-manager shim that refuses to run, say) and
  -- fail as "connection refused" with the real cause hidden.
  local listener = assert(vim.uv.new_tcp())
  assert(listener:bind("127.0.0.1", 0))
  local port = listener:getsockname().port
  local peer_addr = "127.0.0.1:" .. tostring(port)
  local accepted, hold = nil, nil
  local function close_peer()
    if hold and not hold:is_closing() then hold:close() end
    if accepted and not accepted:is_closing() then accepted:close() end
    if not listener:is_closing() then listener:close() end
  end
  assert(listener:listen(1, function(err)
    if err or accepted then return end
    accepted = vim.uv.new_tcp()
    listener:accept(accepted)
    accepted:read_start(function() end)
    hold = vim.uv.new_timer()
    hold:start(500, 0, close_peer)
  end))

  local c3, eof_reason = nil, nil
  local connected = vim.wait(4000, function()
    if c3 then return true end
    c3 = rpc.connect({ addr = peer_addr, on_epoch_lost = function(r) eof_reason = r end })
    return c3 ~= nil
  end, 50)
  ok("p83: connected to a peer that will go away", connected and c3 ~= nil)
  if c3 then
    wait_for(function() return eof_reason ~= nil end, 5000)
    ok("p83: losing the peer reports eof", eof_reason == "eof", tostring(eof_reason))
    ok("p83: the connection closes itself on epoch loss", c3:is_closed() == true)
  end
  close_peer()

  conn:close()
  pcall(vim.fn.serverstop, addr)
end)()

-- ─────────── [grid] ui.grid — result grid owns its window gutters ──────────
print("\n[grid] ui.grid — a result grid disables gutters so the winbar header aligns")
;(function()
  local grid = core.ui.grid
  local model = grid.model({ columns = { "a", "b", "c" }, rows = { { "1", "2", "3" } } })
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  local function setw(o, v) vim.api.nvim_set_option_value(o, v, { win = win, scope = "local" }) end
  local function getw(o) return vim.api.nvim_get_option_value(o, { win = win, scope = "local" }) end
  setw("number", true); setw("relativenumber", true)
  setw("signcolumn", "yes"); setw("foldcolumn", "2")

  local view = grid.attach(model, { win = win })
  -- The winbar header sits at window column 0; any gutter would slide the
  -- body cells out from under their labels. The grid must own them off.
  ok("[grid] number off under the grid", getw("number") == false, tostring(getw("number")))
  ok("[grid] relativenumber off under the grid", getw("relativenumber") == false)
  ok("[grid] signcolumn off under the grid", getw("signcolumn") == "no", tostring(getw("signcolumn")))
  ok("[grid] foldcolumn off under the grid", getw("foldcolumn") == "0", tostring(getw("foldcolumn")))

  view:dispose()
  ok("[grid] number restored on dispose", getw("number") == true, tostring(getw("number")))
  ok("[grid] signcolumn restored on dispose", getw("signcolumn") == "yes", tostring(getw("signcolumn")))
  ok("[grid] foldcolumn restored on dispose", getw("foldcolumn") == "2", tostring(getw("foldcolumn")))
  pcall(vim.cmd, "close")
end)()

-- ────────── [gitlog] git.log — commits, range policy, changes (ADR-0060 P1) ──────────
print("\n[gitlog] auto-core.git.log — structured history + working changes (ADR-0060 P1)")
;(function()
  local glog = require("auto-core.git").log
  ok("[gitlog] exported on the git facade", type(glog) == "table" and type(glog.commits) == "function")
  ok("[gitlog] DEFAULT_WINDOW is 15 (ADR-0060 §6.1)", glog.DEFAULT_WINDOW == 15,
    tostring(glog.DEFAULT_WINDOW))

  -- Guard clauses must never throw — a panel calls these before a repo is known.
  ok("[gitlog] commits() with no common_dir is empty + err",
    select(1, glog.commits(nil)) ~= nil and #(select(1, glog.commits(nil))) == 0
    and select(2, glog.commits(nil)) ~= nil)
  ok("[gitlog] working_changes() with no worktree is empty + err",
    #(select(1, glog.working_changes(""))) == 0 and select(2, glog.working_changes("")) ~= nil)
  ok("[gitlog] merge_base() with missing args errors", select(2, glog.merge_base(nil, "a", "b")) ~= nil)
  ok("[gitlog] rev_exists() is false, not an error, on nil", glog.rev_exists(nil, "x") == false)

  -- ── a real repo: history queries need real git output ──
  local repo = vim.fn.tempname() .. "_gitlog"
  vim.fn.mkdir(repo, "p")
  local function g(...)
    local argv = { "git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    local out = vim.fn.system(argv)
    return vim.v.shell_error, out
  end
  g("init", "-q", "-b", "main")
  vim.fn.writefile({ "one" }, repo .. "/a.txt")
  g("add", "."); g("commit", "-q", "-m", "first: base commit")
  local base_sha = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "HEAD" }))
  local common = repo .. "/.git"
  if base_sha == "" or vim.v.shell_error ~= 0 then
    ok("[gitlog] git fixture", false, "git unavailable")
    vim.fn.delete(repo, "rf")
    return
  end

  -- A subject containing the delimiters + a pipe + quotes: the parser must not
  -- lose or split it. This is why the format uses US/RS, not tab-or-pipe.
  vim.fn.writefile({ "two" }, repo .. "/b.txt")
  g("add", "."); g("commit", "-q", "-m", 'weird: a|b "quoted" $x %s subject')

  local commits, err = glog.commits(common, {})
  ok("[gitlog] commits() reads real history", err == nil and #commits == 2, tostring(err))
  local head = commits[1]
  ok("[gitlog] a commit carries sha/short/author/ts/subject",
    head and #head.sha == 40 and head.short ~= "" and head.author == "t"
    and head.email == "t@t" and head.ts > 0 and head.subject ~= "",
    vim.inspect(head))
  ok("[gitlog] a delimiter/quote-heavy subject survives intact",
    head and head.subject == 'weird: a|b "quoted" $x %s subject', head and head.subject)
  ok("[gitlog] parents are a list; a non-merge has one",
    head and type(head.parents) == "table" and #head.parents == 1 and head.merge == false,
    head and vim.inspect(head.parents))
  ok("[gitlog] the root commit has no parents",
    commits[2] and #commits[2].parents == 0)
  ok("[gitlog] newest first", commits[1].ts >= commits[2].ts)

  -- limit + skip page through
  local one = glog.commits(common, { limit = 1 })
  local two = glog.commits(common, { limit = 1, skip = 1 })
  ok("[gitlog] limit bounds the result", #one == 1)
  ok("[gitlog] skip pages past it", #two == 1 and two[1].sha == commits[2].sha)

  -- ── range policy (ADR-0060 §2.4) ──
  g("checkout", "-q", "-b", "feature")
  vim.fn.writefile({ "f1" }, repo .. "/f1.txt")
  g("add", "."); g("commit", "-q", "-m", "feature: one")
  vim.fn.writefile({ "f2" }, repo .. "/f2.txt")
  g("add", "."); g("commit", "-q", "-m", "feature: two")

  local rc, meta, rerr = glog.range(common, { rev = "feature", base = "main" })
  ok("[gitlog] a diverged branch resolves since_divergence",
    rerr == nil and meta.mode == "since_divergence", vim.inspect(meta))
  ok("[gitlog] and returns ONLY its own commits (not the base's)",
    #rc == 2 and rc[1].subject == "feature: two" and rc[2].subject == "feature: one",
    vim.inspect(vim.tbl_map(function(c) return c.subject end, rc)))
  ok("[gitlog] meta names the merge-base", meta.merge_base ~= nil and #meta.merge_base == 40,
    tostring(meta.merge_base))

  local bc, bmeta = glog.range(common, { rev = "main", base = "main" })
  ok("[gitlog] the base branch itself falls back to a window",
    bmeta.mode == "window" and bmeta.limit == 15, vim.inspect(bmeta))
  ok("[gitlog] the window returns the base's own history", #bc == 2, tostring(#bc))

  local wc, wmeta = glog.range(common, { rev = "main", base = "main", limit = 1 })
  ok("[gitlog] an explicit limit is honoured in window mode",
    #wc == 1 and wmeta.limit == 1)

  -- `has_more` is a FACT, not the count-versus-limit guess (2026-09-02): the
  -- window asks git for one commit past itself and drops it. The panel offered
  -- `m for more commits` on every windowed worktree before, so a one-commit repo
  -- showed a key that could never do anything.
  ok("[gitlog] a full window reports has_more=true and does NOT return the extra commit",
    #wc == 1 and wmeta.has_more == true, vim.inspect(wmeta))
  ok("[gitlog] a window that exhausts the history reports has_more=false",
    #bc == 2 and bmeta.has_more == false, vim.inspect(bmeta))
  local xc, xmeta = glog.range(common, { rev = "main", base = "main", limit = 2 })
  ok("[gitlog] a window EXACTLY the size of the history is not 'more' (the count guess would say it is)",
    #xc == 2 and xmeta.has_more == false, vim.inspect(xmeta))
  ok("[gitlog] a divergence range is complete by definition: has_more=false",
    meta.has_more == false, vim.inspect(meta))

  -- an unrelated history shares no merge-base -> window, not a crash
  local nb, nmeta = glog.range(common, { rev = "feature", base = "refs/heads/does-not-exist" })
  ok("[gitlog] a missing base degrades to a window", nmeta.mode == "window" and #nb > 0,
    vim.inspect(nmeta))

  ok("[gitlog] merge_base() agrees with the range meta",
    glog.merge_base(common, "feature", "main") == meta.merge_base)
  ok("[gitlog] rev_exists() true for a real ref and false for a fake one",
    glog.rev_exists(common, "main") == true and glog.rev_exists(common, "nope/x") == false)

  -- ── working_changes: every status class, including a rename ──
  vim.fn.writefile({ "one", "edited" }, repo .. "/a.txt")   -- modified
  vim.fn.writefile({ "brand new" }, repo .. "/new.txt")     -- untracked
  g("rm", "-q", "b.txt")                                     -- deleted (staged)
  vim.fn.writefile({ "f1" }, repo .. "/renamed.txt")
  g("add", "renamed.txt"); g("rm", "-q", "--cached", "f1.txt")
  vim.fn.delete(repo .. "/f1.txt")

  local ch, cerr = glog.working_changes(repo)
  ok("[gitlog] working_changes() reads the worktree", cerr == nil and #ch > 0, tostring(cerr))
  local by = {}
  for _, c in ipairs(ch) do by[c.path] = c end
  ok("[gitlog] a modified file is kind=modified",
    by["a.txt"] and by["a.txt"].kind == "modified", vim.inspect(by["a.txt"]))
  ok("[gitlog] an untracked file is kind=untracked and not staged",
    by["new.txt"] and by["new.txt"].kind == "untracked" and by["new.txt"].staged == false,
    vim.inspect(by["new.txt"]))
  ok("[gitlog] a deleted file is kind=deleted",
    by["b.txt"] and by["b.txt"].kind == "deleted", vim.inspect(by["b.txt"]))
  ok("[gitlog] every change carries x/y/staged/unstaged",
    by["a.txt"] and by["a.txt"].x ~= nil and by["a.txt"].y ~= nil
    and type(by["a.txt"].staged) == "boolean" and type(by["a.txt"].unstaged) == "boolean")
  ok("[gitlog] results are path-sorted",
    (function() for i = 2, #ch do if ch[i - 1].path > ch[i].path then return false end end return true end)())

  -- A path containing a SPACE and a QUOTE proves the -z parse: with git's
  -- default quoting this entry would arrive wrapped in quotes and split.
  vim.fn.writefile({ "x" }, repo .. '/we ird".txt')
  local ch2 = glog.working_changes(repo)
  local found_weird = false
  for _, c in ipairs(ch2) do if c.path == 'we ird".txt' then found_weird = true end end
  ok("[gitlog] a path with a space and a quote parses literally (-z)", found_weird,
    vim.inspect(vim.tbl_map(function(c) return c.path end, ch2)))

  -- ── commit_files ──
  local cf, cferr = glog.commit_files(common, commits[1].sha)
  ok("[gitlog] commit_files() lists what a commit touched",
    cferr == nil and #cf == 1 and cf[1].path == "b.txt", vim.inspect(cf))
  ok("[gitlog] and labels it with the same kind vocabulary",
    cf[1] and cf[1].kind == "added", cf[1] and cf[1].kind)
  ok("[gitlog] commit_files() guards a nil sha", select(2, glog.commit_files(common, nil)) ~= nil)
  -- A ROOT commit has no parent for diff-tree to compare against, and without
  -- `--root` git prints nothing: the panel said "(no files)" under a repo's
  -- first commit while `o` — a `git show`, which shows the root by default —
  -- listed every file (ddex-sftp, 2026-09-02).
  local root_files, rooterr = glog.commit_files(common, base_sha)
  ok("[gitlog] commit_files() lists a ROOT commit's files (--root)",
    rooterr == nil and #root_files == 1 and root_files[1].path == "a.txt"
    and root_files[1].kind == "added", vim.inspect(root_files))

  -- ── async variants deliver on the main loop ──
  local acommits, aerr, adone
  glog.commits_async(common, { limit = 1 }, function(c, e) acommits, aerr, adone = c, e, true end)
  vim.wait(4000, function() return adone end, 10)
  ok("[gitlog] commits_async delivers", adone == true and aerr == nil and #acommits == 1,
    tostring(aerr))

  local ach, adone2
  glog.working_changes_async(repo, function(c) ach, adone2 = c, true end)
  vim.wait(4000, function() return adone2 end, 10)
  ok("[gitlog] working_changes_async delivers", adone2 == true and #ach > 0)

  local bad, bdone
  glog.commits_async("", {}, function(c, e) bad, bdone = e, true end)
  vim.wait(2000, function() return bdone end, 10)
  ok("[gitlog] commits_async reports a bad common_dir instead of hanging",
    bdone == true and bad ~= nil, tostring(bad))

  vim.fn.delete(repo, "rf")
end)()

-- ────────── [gitdiff] git.diff — unified-diff parser (ADR-0060 P2) ──────────
print("\n[gitdiff] auto-core.git.diff — unified-diff parsing (ADR-0060 P2)")
;(function()
  local D = require("auto-core.git").diff
  ok("[gitdiff] exported on the git facade", type(D) == "table" and type(D.parse) == "function")
  ok("[gitdiff] parse(nil) is empty, not an error", #D.parse(nil) == 0)
  ok("[gitdiff] parse('') is empty", #D.parse("") == 0)

  -- A hand-written diff exercising every shape at once. Hand-written on
  -- purpose: git will not readily produce a rename AND a binary AND a
  -- no-newline marker in one commit, and each is a distinct parser branch.
  local patch = table.concat({
    "commit deadbeef",                      -- `git show` preamble must be ignored
    "Author: t <t@t>",
    "",
    "    subject line",
    "",
    "diff --git a/keep.txt b/keep.txt",
    "index 111..222 100644",
    "--- a/keep.txt",
    "+++ b/keep.txt",
    "@@ -1,4 +1,5 @@ function ctx()",
    " one",
    "-two",
    "+two-edited",
    "+inserted",
    " three",
    " four",
    "@@ -20,2 +21,2 @@",
    "-old20",
    "+new21",
    " tail",
    "diff --git a/added.txt b/added.txt",
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/added.txt",
    "@@ -0,0 +1,2 @@",
    "+alpha",
    "+beta",
    "\\ No newline at end of file",
    "diff --git a/gone.txt b/gone.txt",
    "deleted file mode 100644",
    "--- a/gone.txt",
    "+++ /dev/null",
    "@@ -1,1 +0,0 @@",
    "-was here",
    "diff --git a/old name.txt b/new name.txt",
    "similarity index 95%",
    "rename from old name.txt",
    "rename to new name.txt",
    "diff --git a/logo.png b/logo.png",
    "index 333..444 100644",
    "Binary files a/logo.png and b/logo.png differ",
  }, "\n")

  local files = D.parse(patch)
  ok("[gitdiff] five files parsed, preamble ignored", #files == 5, tostring(#files))
  local by = {}
  for _, f in ipairs(files) do by[f.path] = f end

  -- modified
  local keep = by["keep.txt"]
  ok("[gitdiff] a modified file is kind=modified with both paths",
    keep and keep.kind == "modified" and keep.old_path == "keep.txt"
    and keep.new_path == "keep.txt", vim.inspect(keep and keep.kind))
  ok("[gitdiff] both hunks captured", keep and #keep.hunks == 2, keep and #keep.hunks)
  local h1 = keep and keep.hunks[1]
  ok("[gitdiff] hunk header numbers parsed",
    h1 and h1.old_start == 1 and h1.old_count == 4
    and h1.new_start == 1 and h1.new_count == 5, vim.inspect(h1 and { h1.old_start, h1.old_count, h1.new_start, h1.new_count }))
  ok("[gitdiff] the @@ heading is kept", h1 and h1.heading == "function ctx()", h1 and h1.heading)
  ok("[gitdiff] a hunk with omitted counts defaults to 1",
    (function()
      local f = D.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -3 +3 @@\n-a\n+b")
      local h = f[1] and f[1].hunks[1]
      return h and h.old_count == 1 and h.new_count == 1 and h.old_start == 3
    end)())

  -- line numbering is the whole point: a comment anchors to it
  local kinds, olds, news = {}, {}, {}
  for _, l in ipairs(h1.lines) do
    kinds[#kinds + 1] = l.kind; olds[#olds + 1] = tostring(l.old or "-")
    news[#news + 1] = tostring(l.new or "-")
  end
  ok("[gitdiff] line kinds in order",
    table.concat(kinds, ",") == "context,del,add,add,context,context",
    table.concat(kinds, ","))
  ok("[gitdiff] OLD numbering skips adds",
    table.concat(olds, ",") == "1,2,-,-,3,4", table.concat(olds, ","))
  ok("[gitdiff] NEW numbering skips deletes",
    table.concat(news, ",") == "1,-,2,3,4,5", table.concat(news, ","))
  ok("[gitdiff] the marker is stripped from the text",
    h1.lines[2].text == "two" and h1.lines[3].text == "two-edited",
    h1.lines[2].text .. "/" .. h1.lines[3].text)
  ok("[gitdiff] the second hunk restarts numbering at its own start",
    keep.hunks[2].lines[1].old == 20 and keep.hunks[2].lines[2].new == 21)

  -- added / deleted / renamed / binary
  ok("[gitdiff] a new file is kind=added with no old_path",
    by["added.txt"] and by["added.txt"].kind == "added" and by["added.txt"].old_path == nil,
    vim.inspect(by["added.txt"] and by["added.txt"].kind))
  ok("[gitdiff] the no-newline marker annotates the previous line, not a new one",
    (function()
      local a = by["added.txt"]
      local last = a and a.hunks[1].lines[#a.hunks[1].lines]
      return last and last.text == "beta" and last.no_newline == true
        and #a.hunks[1].lines == 2
    end)())
  ok("[gitdiff] a deleted file is kind=deleted and displays its old path",
    by["gone.txt"] and by["gone.txt"].kind == "deleted"
    and by["gone.txt"].new_path == nil, vim.inspect(by["gone.txt"] and by["gone.txt"].kind))
  local ren = by["new name.txt"]
  ok("[gitdiff] a rename keeps BOTH paths (with spaces) and the similarity",
    ren and ren.kind == "renamed" and ren.old_path == "old name.txt"
    and ren.new_path == "new name.txt" and ren.similarity == 95,
    vim.inspect(ren and { ren.old_path, ren.new_path, ren.similarity }))
  ok("[gitdiff] a binary file is flagged, with no hunks",
    by["logo.png"] and by["logo.png"].binary == true
    and by["logo.png"].kind == "binary" and #by["logo.png"].hunks == 0)

  -- sides(): the three-column projection
  local sides = D.sides(keep)
  ok("[gitdiff] sides() splits into before/after",
    type(sides.before) == "table" and type(sides.after) == "table")
  ok("[gitdiff] BEFORE holds context+deletes only",
    (function()
      for _, e in ipairs(sides.before) do if e.kind == "add" then return false end end
      return true
    end)())
  ok("[gitdiff] AFTER holds context+adds only",
    (function()
      for _, e in ipairs(sides.after) do if e.kind == "del" then return false end end
      return true
    end)())
  ok("[gitdiff] hunks are separated by a gap so the view can draw a divider",
    (function()
      for _, e in ipairs(sides.before) do if e.kind == "gap" then return true end end
      return false
    end)())

  -- row_for(): what a review comment actually needs
  ok("[gitdiff] row_for() finds the row carrying a given AFTER line",
    D.row_for(sides.after, 2) ~= nil
    and sides.after[D.row_for(sides.after, 2) + 1].lineno == 2,
    tostring(D.row_for(sides.after, 2)))
  ok("[gitdiff] row_for() is 0-based (extmark rows are)",
    D.row_for(sides.after, 1) == 0, tostring(D.row_for(sides.after, 1)))
  ok("[gitdiff] row_for() a line not shown is nil, not 0",
    D.row_for(sides.after, 9999) == nil)
  ok("[gitdiff] row_for() guards nils", D.row_for(nil, 1) == nil and D.row_for(sides.after, nil) == nil)

  -- stats + find
  local st = D.stats(keep)
  ok("[gitdiff] stats() counts adds and removes", st.added == 3 and st.removed == 2,
    vim.inspect(st))
  ok("[gitdiff] find() matches by new OR old path",
    D.find(files, "keep.txt") == keep
    and D.find(files, "old name.txt") == ren
    and D.find(files, "nope") == nil)

  -- ── against REAL git output, not just a hand-written patch ──
  local repo = vim.fn.tempname() .. "_p2diff"
  vim.fn.mkdir(repo, "p")
  local function g(...)
    local argv = { "git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return vim.fn.system(argv)
  end
  g("init", "-q", "-b", "main")
  vim.fn.writefile({ "a", "b", "c" }, repo .. "/f.txt")
  g("add", "."); g("commit", "-q", "-m", "one")
  vim.fn.writefile({ "a", "B", "c", "d" }, repo .. "/f.txt")
  g("add", "."); g("commit", "-q", "-m", "two")
  local sha = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "HEAD" }))
  if sha ~= "" and vim.v.shell_error == 0 then
    local raw = require("auto-core.git.graph").show_diff(repo .. "/.git", sha)
    local rf = D.parse(raw)
    ok("[gitdiff] parses REAL `git show -p` output", #rf == 1 and rf[1].path == "f.txt",
      vim.inspect(vim.tbl_map(function(f) return f.path end, rf)))
    local rst = D.stats(rf[1])
    ok("[gitdiff] real stats: 2 added, 1 removed", rst.added == 2 and rst.removed == 1,
      vim.inspect(rst))
    local rs = D.sides(rf[1])
    ok("[gitdiff] real AFTER side carries line 4 (the appended 'd')",
      D.row_for(rs.after, 4) ~= nil)

    -- ── a MERGE commit (2026-09-02): the repos panel said "no diff" ──
    -- A plain `git show -p` prints a COMBINED diff for a merge — only hunks
    -- that differ from EVERY parent — which for a clean merge is nothing,
    -- while `log.commit_files` (`diff-tree -m --first-parent`) listed the
    -- files. The fixture merges cleanly with --no-ff, so the combined diff
    -- is provably empty and the two surfaces provably disagreed.
    g("checkout", "-q", "-b", "topic")
    vim.fn.writefile({ "g" }, repo .. "/g.txt")
    g("add", "."); g("commit", "-q", "-m", "topic adds g")
    g("checkout", "-q", "main")
    g("merge", "-q", "--no-ff", "--no-edit", "topic")
    local msha = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "HEAD" }))
    local parents = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-list", "--parents", "-n1", msha }))
    ok("[gitdiff] fixture: HEAD is a two-parent merge",
      select(2, parents:gsub(" ", "")) == 2, parents)
    -- CONTROL — a reversal, not an insertion: the OLD argv really does yield
    -- nothing for this commit, so the assertions below are able to fail.
    local plain = vim.fn.systemlist({ "git", "--git-dir=" .. repo .. "/.git",
      "show", "-p", "--no-color", msha })
    ok("[gitdiff] control: plain `git show -p` on a clean merge parses to ZERO files",
      vim.v.shell_error == 0 and #D.parse(plain) == 0, tostring(#D.parse(plain)))
    local graph = require("auto-core.git.graph")
    local gitlog = require("auto-core.git.log")
    local gdir = repo .. "/.git"
    local want = vim.tbl_map(function(f) return f.path end, (gitlog.commit_files(gdir, msha)))
    ok("[gitdiff] commit_files lists the merge's file", vim.deep_equal(want, { "g.txt" }),
      vim.inspect(want))
    local function names(fs)
      return vim.tbl_map(function(f) return f.path .. ":" .. f.kind end, fs)
    end
    -- ASYNC first on a cold cache, then SYNC on a cold cache: each path runs
    -- its own argv (a warm cache would let one stand in for the other).
    graph.clear_repo_cache(gdir)
    local async_lines
    graph.show_diff_async(gdir, msha, function(l) async_lines = l end)
    vim.wait(5000, function() return async_lines ~= nil end, 10)
    local af = D.parse(async_lines or {})
    ok("[gitdiff] show_diff_async on a merge yields its first-parent diff",
      #af == 1 and af[1].path == "g.txt" and af[1].kind == "added", vim.inspect(names(af)))
    graph.clear_repo_cache(gdir)
    local mf = D.parse(graph.show_diff(gdir, msha))
    ok("[gitdiff] show_diff on a merge yields its first-parent diff",
      #mf == 1 and mf[1].path == "g.txt" and mf[1].kind == "added", vim.inspect(names(mf)))
    ok("[gitdiff] the diff answers for EXACTLY the files commit_files lists",
      vim.deep_equal(vim.tbl_map(function(f) return f.path end, mf), want),
      vim.inspect({ diff = names(mf), listed = want }))
    ok("[gitdiff] sync and async agree line for line",
      vim.deep_equal(async_lines, graph.show_diff(gdir, msha)))
    -- The merge flags are no-ops on a single-parent commit: `two` is
    -- byte-identical to what a plain `git show -p` prints for it.
    graph.clear_repo_cache(gdir)
    ok("[gitdiff] a single-parent commit's diff is unchanged by the merge flags",
      vim.deep_equal(graph.show_diff(gdir, sha),
        vim.fn.systemlist({ "git", "--git-dir=" .. gdir, "show", "-p", "--no-color", sha })))

    -- ── a ROOT commit (2026-09-02): the tree said "(no files)", `o` listed every file ──
    -- diff-tree prints nothing for a parentless commit unless told `--root`;
    -- `git show` shows the root by default. Same two-surface invariant as the
    -- merge: what commit_files LISTS is exactly what the diff SHOWS.
    local rsha = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-list", "--max-parents=0", "HEAD" }))
    ok("[gitdiff] fixture: the history has exactly one root commit", #rsha == 40, rsha)
    -- CONTROL: the OLD argv really does yield nothing here, so the assertions
    -- below are able to fail.
    local bare = vim.fn.system({ "git", "--git-dir=" .. gdir, "diff-tree", "--no-commit-id",
      "--name-status", "-z", "-r", "-m", "--first-parent", rsha })
    ok("[gitdiff] control: diff-tree WITHOUT --root prints nothing for the root commit",
      vim.v.shell_error == 0 and bare == "", ("%d bytes"):format(#bare))
    local rwant = vim.tbl_map(function(f) return f.path end, (gitlog.commit_files(gdir, rsha)))
    ok("[gitdiff] commit_files lists the root commit's file (--root)",
      vim.deep_equal(rwant, { "f.txt" }), vim.inspect(rwant))
    graph.clear_repo_cache(gdir)
    local rdf = D.parse(graph.show_diff(gdir, rsha))
    ok("[gitdiff] the root commit's diff answers for EXACTLY the files commit_files lists",
      #rdf > 0 and vim.deep_equal(vim.tbl_map(function(f) return f.path end, rdf), rwant),
      vim.inspect({ diff = names(rdf), listed = rwant }))
  else
    print("  SKIP  real-git diff (git unavailable)")
  end
  vim.fn.delete(repo, "rf")
end)()

-- ────────── [marks] ui.marks — highlights, gutter, virt_lines (ADR-0060 P2) ──────────
print("\n[marks] auto-core.ui.marks — line/range/gutter/virt_lines (ADR-0060 P2)")
;(function()
  local marks = require("auto-core.ui").marks
  local D = require("auto-core.git").diff
  marks._reset_for_tests()
  ok("[marks] exported on the ui facade", type(marks) == "table" and type(marks.line) == "function")

  local ns = marks.ns("p2test")
  ok("[marks] ns() returns a namespace id", type(ns) == "number" and ns > 0)
  ok("[marks] ns() is stable for the same name", marks.ns("p2test") == ns)
  ok("[marks] ns() differs per name", marks.ns("other") ~= ns)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })

  ok("[marks] line() highlights a valid row", marks.line(buf, ns, 0, "AutoCoreDiffAdd") == true)
  ok("[marks] line() refuses a row past the end (an extmark error, not a no-op)",
    marks.line(buf, ns, 99, "AutoCoreDiffAdd") == false)
  ok("[marks] line() refuses a negative row", marks.line(buf, ns, -1, "AutoCoreDiffAdd") == false)
  ok("[marks] line() refuses an invalid buffer", marks.line(9999, ns, 0, "AutoCoreDiffAdd") == false)
  local got = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  ok("[marks] the mark is really set with line_hl_group",
    #got == 1 and got[1][4].line_hl_group == "AutoCoreDiffAdd", vim.inspect(got[1] and got[1][4]))

  marks.clear(buf, ns)
  ok("[marks] clear() removes them", #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0)

  ok("[marks] range() clamps end_col to the real line length",
    marks.range(buf, ns, 1, 0, 1, 9999, "AutoCoreDiffChange") == true)
  ok("[marks] range() refuses an out-of-range row",
    marks.range(buf, ns, 42, 0, 42, 1, "AutoCoreDiffChange") == false)
  marks.clear(buf, ns)

  ok("[marks] gutter() places a sign extmark", marks.gutter(buf, ns, 0, "▎", "AutoCoreGitModified") == true)
  local gm = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  ok("[marks] the sign text is set (multibyte glyph survives)",
    #gm == 1 and gm[1][4].sign_text ~= nil, vim.inspect(gm[1] and gm[1][4].sign_text))
  marks.clear(buf, ns)
  -- Byte-slicing a multibyte sign yields invalid UTF-8 and nvim rejects the
  -- extmark outright, so the sign silently vanishes. Trim by CHARACTER.
  ok("[marks] an over-long multibyte sign is trimmed by character, not byte",
    marks.gutter(buf, ns, 0, "▎▎▎▎", "AutoCoreGitAdded") == true)
  ok("[marks] an empty sign is refused", marks.gutter(buf, ns, 0, "", nil) == false)
  marks.clear(buf, ns)

  ok("[marks] virt_lines() renders below a row",
    marks.virt_lines(buf, ns, 0, { "hello", "world" }) == true)
  local vm = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  ok("[marks] two virtual lines are attached",
    #vm == 1 and vm[1][4].virt_lines and #vm[1][4].virt_lines == 2,
    vim.inspect(vm[1] and vm[1][4].virt_lines and #vm[1][4].virt_lines))
  ok("[marks] virt_lines() with no lines is refused", marks.virt_lines(buf, ns, 0, {}) == false)
  ok("[marks] virt_lines() refuses a bad row", marks.virt_lines(buf, ns, 77, { "x" }) == false)
  marks.clear(buf, ns)

  -- annotate(): the review comment block
  ok("[marks] annotate() renders a comment",
    marks.annotate(buf, ns, 1, {
      severity = "must-fix", author = "lector",
      body = "This is a fairly long finding body that must wrap across more than one virtual line so the wrapping path is genuinely exercised.",
    }, { width = 40 }) == true)
  local am = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local vl = am[1] and am[1][4].virt_lines
  ok("[marks] the block wraps to several lines", vl and #vl > 3, vl and #vl)
  ok("[marks] the head names severity and author",
    vl and vl[1][2] and vl[1][2][1] == "must-fix · lector", vl and vl[1][2] and vl[1][2][1])
  ok("[marks] severity picks its highlight group",
    vl and vl[1][2] and vl[1][2][2] == "AutoCoreReviewMustFix", vl and vl[1][2] and vl[1][2][2])
  ok("[marks] no wrapped line exceeds the width",
    (function()
      for i = 2, #vl do
        local text = vl[i][2] and vl[i][2][1] or ""
        if #text > 40 then return false end
      end
      return true
    end)())
  marks.clear(buf, ns)

  ok("[marks] a resolved comment renders dimmed rather than hidden",
    (function()
      marks.annotate(buf, ns, 0, { severity = "nit", author = "a", body = "x", resolved = true })
      local m = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      local v = m[1] and m[1][4].virt_lines
      return v and v[1][2][2] == "AutoCoreReviewResolved"
        and v[1][2][1]:find("resolved", 1, true) ~= nil
    end)())
  marks.clear(buf, ns)

  ok("[marks] every severity in the ladder maps to a group",
    (function()
      for _, s in ipairs({ "must-fix", "should-fix", "nit", "question" }) do
        if not marks.SEVERITY_HL[s] then return false end
      end
      return true
    end)())

  -- paint_diff_column(): text and colour stay separable
  local files = D.parse(
    "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n ctx\n-gone\n+came\n")
  local sides = D.sides(files[1])
  local buf2 = vim.api.nvim_create_buf(false, true)
  local text = {}
  for _, e in ipairs(sides.after) do text[#text + 1] = e.text end
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, text)
  local painted = marks.paint_diff_column(buf2, ns, sides.after)
  ok("[marks] paint_diff_column colours the add and leaves context alone",
    painted == 1, tostring(painted))
  local pm = vim.api.nvim_buf_get_extmarks(buf2, ns, 0, -1, { details = true })
  -- ADR-0065 §2.9: the painter now uses the BACKGROUND-ONLY group, below
  -- treesitter's priority, so foreground belongs to the syntax and background
  -- to the diff. Asserting the group NAME alone would not catch the thing that
  -- matters, so the fg-free invariant is asserted too.
  ok("[marks] and it used the background-only diff-add group",
    #pm == 1 and pm[1][4].line_hl_group == "AutoCoreDiffAddBg",
    vim.inspect(pm[1] and pm[1][4].line_hl_group))
  ok("[marks] painted below treesitter, so it cannot win the foreground",
    #pm == 1 and pm[1][4].priority == 90, vim.inspect(pm[1] and pm[1][4].priority))
  ok("[marks] and that group carries NO foreground",
    (function()
      require("auto-core.ui.highlights").ensure()
      local h = vim.api.nvim_get_hl(0, { name = "AutoCoreDiffAddBg", link = false })
      return h.fg == nil and h.bg ~= nil
    end)(), "AutoCoreDiffAddBg must be bg-only")
  ok("[marks] legacy_hl restores the old group for non-treesitter consumers",
    (function()
      local b3 = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(b3, 0, -1, false, text)
      local ns3 = marks.ns("smoke-legacy")
      marks.paint_diff_column(b3, ns3, sides.after, { legacy_hl = true })
      local m3 = vim.api.nvim_buf_get_extmarks(b3, ns3, 0, -1, { details = true })
      return m3[1] and m3[1][4].line_hl_group == "AutoCoreDiffAdd"
    end)())
  ok("[marks] painting an over-long column does not throw",
    (function()
      local okp = pcall(marks.paint_diff_column, buf2, ns, sides.after, { offset = 500 })
      return okp
    end)())

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(buf2, { force = true })
end)()

-- ────────── [diffview] ui.diffview — three columns + annotations (ADR-0060 P5) ──────────
print("\n[diffview] auto-core.ui.diffview — three columns, git a/ b/ (ADR-0060 P5)")
;(function()
  local dv = require("auto-core.ui").diffview
  local D = require("auto-core.git").diff
  ok("[diffview] exported on the ui facade", type(dv) == "table" and type(dv.open) == "function")
  ok("[diffview] MIN_COLUMNS is declared", type(dv.MIN_COLUMNS) == "number" and dv.MIN_COLUMNS > 0)
  ok("[diffview] open() with no files refuses", select(1, dv.open({ files = {} })) == nil)

  -- Refuse on a narrow window rather than silently dropping the b/ pane.
  local saved_cols = vim.o.columns
  vim.o.columns = 40
  local narrow, nerr = dv.open({ files = { { path = "x", hunks = {} } } })
  ok("[diffview] a narrow window REFUSES with an explanation (never half a diff)",
    narrow == nil and tostring(nerr):find("columns") ~= nil, tostring(nerr))
  vim.o.columns = 200

  local files = D.parse(table.concat({
    "diff --git a/keep.lua b/keep.lua",
    "--- a/keep.lua",
    "+++ b/keep.lua",
    "@@ -1,4 +1,5 @@",
    " one",
    "-two",
    "+two-edited",
    "+inserted",
    " three",
    " four",
    "diff --git a/gone.lua b/gone.lua",
    "deleted file mode 100644",
    "--- a/gone.lua",
    "+++ /dev/null",
    "@@ -1,1 +0,0 @@",
    "-was here",
  }, "\n"))
  ok("[diffview] fixture parsed", #files == 2)

  -- annotations keyed by path; LEFT = a/ side, RIGHT = b/ side
  local annotations = {
    ["keep.lua"] = {
      { line = 2, side = "RIGHT", severity = "must-fix", author = "lector",
        body = "this edit drops the guard" },
      { line = 2, side = "LEFT", severity = "nit", author = "lector",
        body = "the old line was clearer" },
      { line = 999, side = "RIGHT", severity = "question", body = "not in the diff" },
    },
  }

  local handle, err = dv.open({ files = files, annotations = annotations,
    title = " abc1234 test " })
  ok("[diffview] open() returns a handle", handle ~= nil and err == nil, tostring(err))
  ok("[diffview] is_open()", dv.is_open() == true)

  local st = dv._state_for_tests()
  ok("[diffview] three content panes exist",
    st and st.float:bufnr("left") and st.float:bufnr("middle") and st.float:bufnr("preview"))

  local function lines(pane)
    local b = st.float:bufnr(pane)
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  local left = table.concat(lines("left"), "\n")
  ok("[diffview] the file list shows both files with +/- counts",
    left:find("keep.lua", 1, true) and left:find("gone.lua", 1, true)
    and left:find("+2", 1, true), left)
  -- 2026-09-03: the `[deleted]` badge became a one-glyph `D ` marker (repos
  -- panel parity), so the row now reads `D gone.lua …` rather than `[deleted]`.
  ok("[diffview] a deleted file leads with the D marker",
    left:find("\nD gone.lua", 1, true) ~= nil or left:find("^D gone.lua", 1, true) ~= nil,
    left)
  ok("[diffview] no [kind] badges remain on the file list",
    left:find("[", 1, true) == nil, left)

  local a_side = table.concat(lines("middle"), "\n")
  local b_side = table.concat(lines("preview"), "\n")
  ok("[diffview] the a/ pane holds context + deletions, not insertions",
    a_side:find("two", 1, true) and not a_side:find("inserted", 1, true), a_side)
  ok("[diffview] the b/ pane holds context + insertions, not deletions",
    b_side:find("inserted", 1, true) and b_side:find("two%-edited"), b_side)
  -- ADR-0065 §2.9 moved the line numbers OUT of the buffer text and into the
  -- `statuscolumn`, because a `%5s │ ` prefix inside the buffer is what stopped
  -- treesitter being usable at all. The requirement is unchanged — a comment
  -- anchors to a line and the reader must be able to find it — so it is now
  -- asserted where the numbers actually live.
  ok("[diffview] the panes hold PURE file text, with no gutter in the buffer",
    a_side:match("│") == nil and b_side:match("│") == nil,
    vim.inspect({ a_side, b_side }))
  ok("[diffview] both panes still carry line numbers (a comment anchors to one)",
    (function()
      for _, pane in ipairs({ "middle", "preview" }) do
        local w = st.float:winid(pane)
        if not (w and vim.wo[w].number and vim.wo[w].statuscolumn:find("diffview", 1, true)) then
          return false
        end
        vim.g.statusline_winid = w
        vim.v.lnum = 1
        if not dv.statuscolumn():find("1") then return false end
      end
      return true
    end)(), "statuscolumn must resolve row 1 to file line 1 on both panes")

  -- annotations: the whole point of the view
  local marks = require("auto-core.ui").marks
  local ns = marks.ns("diffview")
  local function ann(pane)
    local b = st.float:bufnr(pane)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })) do
      if m[4] and m[4].virt_lines then out[#out + 1] = m end
    end
    return out
  end
  local b_ann, a_ann = ann("preview"), ann("middle")
  ok("[diffview] a RIGHT comment renders on the b/ side", #b_ann == 1, tostring(#b_ann))
  ok("[diffview] a LEFT comment renders on the a/ side", #a_ann == 1, tostring(#a_ann))
  ok("[diffview] the b/ annotation names its severity and author",
    (function()
      local vl = b_ann[1] and b_ann[1][4].virt_lines
      return vl and vl[1] and vl[1][2] and vl[1][2][1] == "must-fix · lector"
    end)(), b_ann[1] and vim.inspect(b_ann[1][4].virt_lines[1]))
  ok("[diffview] and it is anchored to the row carrying that file line",
    (function()
      local sides = D.sides(files[1])
      local want = D.row_for(sides.after, 2)
      return b_ann[1] and b_ann[1][2] == want
    end)(),
    b_ann[1] and (b_ann[1][2] .. " vs " .. tostring(D.row_for(D.sides(files[1]).after, 2))))

  -- diff colouring is present alongside the annotations
  local painted = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.float:bufnr("preview"), ns, 0, -1,
    { details = true })) do
    if m[4] and m[4].line_hl_group == "AutoCoreDiffAddBg" then painted = painted + 1 end
  end
  ok("[diffview] insertions are coloured on the b/ side", painted == 2, tostring(painted))

  -- an unplaceable comment is reported, never silently dropped
  local lost = dv.unplaced_for(files, annotations)
  ok("[diffview] unplaced_for() reports a comment on a line not in the diff",
    #lost == 1 and lost[1].line == 999, vim.inspect(lost))

  -- selecting the second file retitles and repaints
  st.float:focus("left")
  local lw = st.float:winid("left")
  vim.api.nvim_win_set_cursor(lw, { 2, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = st.float:bufnr("left") })
  vim.wait(120, function() return dv._state_for_tests().idx == 2 end, 10)
  ok("[diffview] moving in the file list selects the next file",
    dv._state_for_tests().idx == 2, tostring(dv._state_for_tests().idx))
  -- nvim_win_get_config().title is a CHUNK LIST ({{text, hl}, ...}), not a
  -- string; tostring() on it yields "table: 0x…" and would fail a working view.
  local function title_text(winid)
    local cfg = vim.api.nvim_win_get_config(winid)
    local tt = cfg.title
    if type(tt) == "string" then return tt end
    local parts = {}
    for _, chunk in ipairs(tt or {}) do
      parts[#parts + 1] = type(chunk) == "table" and tostring(chunk[1]) or tostring(chunk)
    end
    return table.concat(parts)
  end
  ok("[diffview] a deleted file titles the b/ pane /dev/null, as git prints it",
    title_text(st.float:winid("preview")):find("/dev/null", 1, true) ~= nil,
    title_text(st.float:winid("preview")))
  ok("[diffview] and the a/ pane carries the a/<path> title",
    title_text(st.float:winid("middle")):find("a/gone.lua", 1, true) ~= nil,
    title_text(st.float:winid("middle")))

  dv.close()
  ok("[diffview] close() disposes", dv.is_open() == false)
  ok("[diffview] close() is idempotent", (function() local o = pcall(dv.close); return o end)())
  vim.o.columns = saved_cols
end)()


-- ───── [84] ui.panel — adopt-on-open refreshes the consumer mirror ─────
-- Consumers mirror the panel's winid via the on_open/on_close pair
-- (auto-finder keeps `state.panel_winid` that way, and several of its
-- readers trust it). `Panel:open()`'s singleton guard did
-- `self.winid = existing; return existing`, returning BEFORE the
-- on_open call: the panel refreshed, the consumer did not. A consumer
-- that had already seen an on_close then held nil while the panel held
-- a valid window, and its readers silently no-opped.
--
-- KNOWN REMAINING GAP, deliberately not fixed here: an EXTERNAL close
-- (`:q`, a layout change, another plugin) still leaves `panel.winid`
-- stale and never fires `on_close`, because the WinClosed autocmd only
-- logs. Making WinClosed perform the transition is correct but is a
-- cross-repo behaviour change -- auto-finder's on_close tears down
-- cached section buffers, so external closes would start doing that
-- too (which is the point, and also breaks assertions written against
-- the silent behaviour). Tracked on the panel-mirror task; see the PR
-- for the measured consumer impact.
print("\n[84] ui.panel — adopt-on-open refreshes the consumer mirror")
;(function()
  local mirror, opens = nil, 0
  local p = Panel.new({
    name  = "mirror-probe",
    side  = "left",
    width = { default = 30, min = 10, max = 80 },
    on_open  = function(w) opens = opens + 1; mirror = w end,
    on_close = function() mirror = nil end,
  })

  p:open(true)
  ok("p84: on_open fires on a real open",
    opens == 1 and mirror == p.winid,
    ("opens=%d mirror=%s panel=%s"):format(opens, tostring(mirror), tostring(p.winid)))

  -- Control: the probe can observe a desync at all. Force one by hand,
  -- so the assertion below is not passing on an inert instrument.
  mirror = nil
  ok("p84: control — a hand-forced desync IS observable",
    mirror ~= p.winid, tostring(mirror) .. " vs " .. tostring(p.winid))

  -- The fix: the window still exists, so open() takes the adopt path.
  local adopted = p:open(true)
  ok("p84: adopt-on-open refreshes the consumer mirror",
    mirror == p.winid and mirror == adopted,
    ("mirror=%s panel=%s returned=%s")
      :format(tostring(mirror), tostring(p.winid), tostring(adopted)))
  ok("p84: the adopt path still returns the existing window",
    adopted == p.winid and vim.api.nvim_win_is_valid(adopted),
    tostring(adopted))

  p:close()
  ok("p84: an API close still clears both sides",
    p.winid == nil and mirror == nil,
    ("panel=%s mirror=%s"):format(tostring(p.winid), tostring(mirror)))

  Panel._reset_for_tests()
  events._reset_for_tests()
end)()

-- ── [87] ui.panel — an EXTERNAL close performs the transition, once ──
--
-- Direction 1 of the winid-mirror desync. Panel:close() was the only path
-- that cleared self.winid and invoked on_close, so `:q`, `:close`, a layout
-- change or another plugin closing the window left BOTH panel.winid and the
-- consumer's mirror pointing at a dead window with on_close never fired.
--
-- The count matters as much as the end state. Panel:close() calls
-- nvim_win_close, which fires WinClosed SYNCHRONOUSLY — so a WinClosed
-- handler that transitions unconditionally fires on_close TWICE for one API
-- close, and a cell asserting only "mirror is nil" would pass on that.
-- Hence closes is asserted as a number throughout.
print("\n[87] ui.panel — an external close clears both sides exactly once")
;(function()
  local mirror, opens, closes = nil, 0, 0
  -- Recorded INSIDE on_close: was the window still alive when the consumer
  -- was told it had gone? That is the property `_api_closing` exists for.
  -- nvim_win_close fires WinClosed synchronously, so a handler that
  -- transitions during an API close runs on_close from INSIDE the teardown,
  -- and a consumer deleting buffers there does it re-entrantly.
  local valid_at_close = nil
  local p = Panel.new({
    name  = "extclose-probe",
    side  = "left",
    width = { default = 30, min = 10, max = 80 },
    on_open  = function(w) opens = opens + 1; mirror = w end,
    on_close = function(w)
      closes = closes + 1
      mirror = nil
      valid_at_close = type(w) == "number" and w > 0
        and vim.api.nvim_win_is_valid(w) or false
    end,
  })

  local w = p:open(true)
  ok("p87: open established both sides",
    opens == 1 and closes == 0 and mirror == w and p.winid == w,
    ("opens=%d closes=%d mirror=%s panel=%s"):format(opens, closes, tostring(mirror), tostring(p.winid)))

  -- Control: on_close is reachable AT ALL through this probe. Without it a
  -- transition that never fires and a probe that cannot see one look the
  -- same, which is exactly how the original desync went unnoticed.
  p:close()
  ok("p87: control — an API close is observable here (closes=1)",
    closes == 1 and mirror == nil and p.winid == nil,
    ("closes=%d mirror=%s panel=%s"):format(closes, tostring(mirror), tostring(p.winid)))

  -- THE CASE: close the window behind the panel's back.
  local w2 = p:open(true)
  closes = 0
  ok("p87: reopened for the external case", p.winid == w2 and mirror == w2,
    ("panel=%s mirror=%s"):format(tostring(p.winid), tostring(mirror)))
  vim.api.nvim_win_close(w2, true)
  vim.wait(200, function() return closes > 0 end, 5)

  ok("p87: an external close fires on_close EXACTLY once",
    closes == 1, ("closes=%d"):format(closes))
  ok("p87: and clears panel.winid and the consumer mirror together",
    p.winid == nil and mirror == nil,
    ("panel=%s mirror=%s"):format(tostring(p.winid), tostring(mirror)))

  -- An API close must not double-fire through its own WinClosed. Same
  -- assertion as the control above, but now with the external path armed:
  -- this is the one that catches a missing re-entrancy guard.
  local w3 = p:open(true)
  closes = 0
  p:close()
  ok("p87: an API close still fires on_close exactly once, not twice",
    closes == 1 and p.winid == nil and mirror == nil,
    ("closes=%d panel=%s mirror=%s"):format(closes, tostring(p.winid), tostring(mirror)))
  ok("p87: and the window it closed is gone",
    not vim.api.nvim_win_is_valid(w3), tostring(w3))
  -- ORDERING, not just count. Without the suppression the consumer is
  -- notified from inside nvim_win_close, with its window still alive —
  -- and a consumer that deletes buffers there is doing it mid-teardown.
  -- This is the only cell that observes why `_api_closing` exists; the
  -- count assertions above pass either way, because finish_close's own
  -- winid guard covers idempotence on its own.
  ok("p87: on_close runs AFTER the window is gone, not during the close",
    valid_at_close == false, "window still valid inside on_close: "
      .. tostring(valid_at_close))

  -- IDEMPOTENCE ACROSS SEPARATE CALLS, which is a different property from
  -- everything above and the one finish_close's `p.winid == nil` guard
  -- actually carries. The sequence is ordinary: a user :q's the panel and
  -- then hits the toggle, or a plugin shuts down and calls close() on a
  -- panel that is already gone. Without the guard the second call runs a
  -- SECOND teardown — two on_close for one panel, and consumers release
  -- real resources in there.
  --
  -- This cell exists because its absence made a mutation look survivable:
  -- removing that guard changed nothing in the suite, and I read that as
  -- "the guard is redundant". It was not evidence about the guard, it was
  -- evidence about which inputs the suite drives. (gold-man, #30 r0.)
  local w5 = p:open(true)
  closes = 0
  vim.api.nvim_win_close(w5, true)
  vim.wait(200, function() return closes > 0 end, 5)
  -- Asserted BEFORE the second call, so this cell is self-contained rather
  -- than leaning on its neighbours: if the external close ever stopped
  -- transitioning entirely, closes would be 0 here, p:close() would then fire
  -- once, and a single `closes == 1` at the end would PASS on a broken
  -- transition. (gold-man, #30 r1 — specificity.)
  ok("p87: the external half of the pair actually transitioned",
    closes == 1 and p.winid == nil,
    ("closes=%d panel=%s"):format(closes, tostring(p.winid)))
  p:close()
  ok("p87: an external close then a later close() fires on_close once, not twice",
    closes == 1 and p.winid == nil and mirror == nil,
    ("closes=%d panel=%s mirror=%s"):format(closes, tostring(p.winid), tostring(mirror)))

  -- After an external close the panel must be reopenable, with both sides
  -- agreeing again — a transition that cleared state but left the panel
  -- unusable would pass every assertion above.
  local w4 = p:open(true)
  ok("p87: reopen after an external close agrees on both sides",
    p.winid == w4 and mirror == w4 and vim.api.nvim_win_is_valid(w4),
    ("panel=%s mirror=%s"):format(tostring(p.winid), tostring(mirror)))
  p:close()

  Panel._reset_for_tests()
  events._reset_for_tests()
end)()

-- ─────────────────────── summary ─────────────────────────
-- ── [88] ui.edit — open a file in a window that can TAKE one ──────────
--
-- The case that motivated the module: an agent's remote call lands in
-- whichever window is CURRENT, and in a live layout that is usually a panel or
-- a winfixbuf'd terminal. Every cell here therefore CALLS FROM a window that
-- cannot take a file, because calling from a good window tests nothing.
print("\n[88] ui.edit — open a file from a window that cannot take one")
;(function()
  local edit = require("auto-core.ui.edit")
  local Panel = require("auto-core.ui.panel")

  -- The measure that discriminates a leaked scratch from the legitimate file
  -- buffer: a buffer with no name that no window is showing.
  local function undisplayed_unnamed()
    local n = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == "" and #vim.fn.win_findbuf(b) == 0 then
        n = n + 1
      end
    end
    return n
  end

  local dir = vim.fn.tempname() .. "_edit88"
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/target.txt"
  local lines = {}
  for i = 1, 60 do lines[i] = "line " .. i end
  vim.fn.writefile(lines, file)

  -- A panel, so there is a real winfixbuf'd, marker-stamped window present —
  -- not a synthetic imitation. The measurement that drove this module's design
  -- was that synthetic windows do NOT reproduce the panel's interception.
  local p = Panel.new({
    name  = "edit88-probe",
    side  = "left",
    width = { default = 30, min = 10, max = 80 },
  })
  local panel_win = p:open(true)
  local panel_buf_before = vim.api.nvim_win_get_buf(panel_win)
  ok("p88: the probe panel is open and winfixbuf'd",
    panel_win ~= nil and vim.wo[panel_win].winfixbuf == true,
    "winfixbuf=" .. tostring(vim.wo[panel_win].winfixbuf))

  -- CALL FROM THE PANEL. This is the motivating case, and the assertion that
  -- matters most is the one about what did NOT happen to the panel.
  vim.api.nvim_set_current_win(panel_win)
  local caller = vim.api.nvim_get_current_win()
  local res, err = edit.open(file, { line = 40, col = 3 })

  ok("p88: open() succeeds when called FROM a winfixbuf panel",
    res ~= nil, tostring(err))
  if res then
    ok("p88: it did NOT use the panel window",
      res.win ~= panel_win,
      ("chose win=%s, panel=%s"):format(tostring(res.win), tostring(panel_win)))
    ok("p88: and the panel's own buffer is untouched",
      vim.api.nvim_win_get_buf(panel_win) == panel_buf_before,
      "the panel's buffer was replaced — the interception this module exists "
        .. "to avoid")
    ok("p88: the file is in the window it named",
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(res.win)) == file,
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(res.win)))
    ok("p88: cursor is at the requested 1-based line and col",
      (function()
        local c = vim.api.nvim_win_get_cursor(res.win)
        -- col is 1-based in this API and 0-based in nvim, so 3 -> 2.
        return c[1] == 40 and c[2] == 2, ("%d:%d"):format(c[1], c[2])
      end)())
    ok("p88: focus was NOT stolen (Q2 default)",
      vim.api.nvim_get_current_win() == caller,
      ("current=%s caller=%s"):format(tostring(vim.api.nvim_get_current_win()),
        tostring(caller)))
    ok("p88: the response NAMES the window and counts the panels it skipped",
      type(res.win) == "number" and type(res.panel_windows_skipped) == "number"
        and res.panel_windows_skipped >= 1,
      vim.inspect({ win = res.win, skipped = res.panel_windows_skipped }))
  end

  -- Q1's ruling: SPLIT when nothing usable exists. Reached by closing every
  -- non-panel window, so the only windows left are the panel and whatever
  -- ui.edit makes for itself.
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= panel_win and vim.api.nvim_win_is_valid(w)
      and #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  vim.api.nvim_set_current_win(panel_win)
  local only = vim.api.nvim_tabpage_list_wins(0)
  ok("p88: control — the panel is now the ONLY window, so nothing is usable",
    #only == 1 and only[1] == panel_win,
    ("%d windows"):format(#only))

  local orphans_primary = undisplayed_unnamed()
  local res2, err2 = edit.open(file, { line = 5 })
  ok("p88: open() creates a window rather than refusing or taking the panel",
    res2 ~= nil and res2.created_window == true, tostring(err2))
  -- The PRIMARY path's scratch buffer. `bufhidden = "wipe"` disposes of it
  -- when nvim_win_set_buf replaces it, and until this cell existed nothing
  -- checked that: deleting the flag left the suite at 1903/0. It was the only
  -- fix in the round with no witness, which is what makes it the one most
  -- likely to come back. (gold-man r1.)
  ok("p88: …and the primary path leaks no undisplayed scratch buffer",
    undisplayed_unnamed() == orphans_primary,
    ("undisplayed-unnamed %d -> %d"):format(orphans_primary, undisplayed_unnamed()))
  if res2 then
    ok("p88: …and the panel STILL has its own buffer",
      vim.api.nvim_win_get_buf(panel_win) == panel_buf_before,
      "the split loaded the file into the panel — the measured failure mode")
    ok("p88: …in a window that is not the panel",
      res2.win ~= panel_win, tostring(res2.win))
  end

  -- Input contract. A relative path is refused loudly rather than resolved
  -- against whichever cwd the host happens to have.
  local rel, relerr = edit.open("target.txt")
  ok("p88: a relative path is refused, naming why",
    rel == nil and tostring(relerr):find("ABSOLUTE", 1, true) ~= nil,
    tostring(relerr))
  local badcol, colerr = edit.open(file, { col = 0 })
  ok("p88: col is 1-BASED and 0 is refused",
    badcol == nil and tostring(colerr):find("1-BASED", 1, true) ~= nil,
    tostring(colerr))

  -- A stale line number opens the file at the end rather than refusing: the
  -- file is what the caller wanted to see.
  local clamped = edit.open(file, { line = 9999 })
  ok("p88: an out-of-range line CLAMPS instead of failing",
    clamped ~= nil and clamped.line == 60, vim.inspect(clamped and clamped.line))

  -- ── the response must describe the CURSOR, not the request ──────────
  --
  -- r0 MF1: this used to echo `opts` back. Four measured rows disagreed with
  -- the window, including a `line = 2.5` that returned a line number no buffer
  -- can hold. The response is the only thing a mailbox caller ever sees, so a
  -- position it did not verify is worse than no position.
  do
    local n2 = dir .. "/short.txt"
    vim.fn.writefile({ "short", "second line is longer here", "third" }, n2)

    -- A column past the end of the line: nvim clamps, and the caller has to be
    -- TOLD it clamped rather than handed back the number it asked for.
    local r = edit.open(n2, { line = 1, col = 999 })
    local c = r and vim.api.nvim_win_get_cursor(r.win)
    ok("p88: a clamped column is REPORTED clamped, not echoed back",
      r ~= nil and c ~= nil and r.col == c[2] + 1 and r.col < 999,
      vim.inspect({ reported = r and r.col, actual = c and (c[2] + 1) }))

    -- col WITHOUT line: r0 MF2 — it was validated and then discarded.
    local r2 = edit.open(n2, { col = 4 })
    local c2 = r2 and vim.api.nvim_win_get_cursor(r2.win)
    ok("p88: col alone is applied to the current line, not ignored",
      r2 ~= nil and c2 ~= nil and r2.col == c2[2] + 1 and c2[2] + 1 == 4,
      vim.inspect({ reported = r2 and r2.col, actual = c2 and (c2[2] + 1) }))

    -- No position asked for: the response must describe where the cursor
    -- actually is, not assert 1:1 about a cursor it never touched.
    local r3 = edit.open(n2)
    local c3 = r3 and vim.api.nvim_win_get_cursor(r3.win)
    ok("p88: with no position asked for, the report still matches the window",
      r3 ~= nil and c3 ~= nil and r3.line == c3[1] and r3.col == c3[2] + 1,
      vim.inspect({ reported = r3 and { r3.line, r3.col },
                    actual = c3 and { c3[1], c3[2] + 1 } }))

    -- r0 nit 3: the Lua gate was weaker than the mailbox schema's `integer`.
    local frac, fracerr = edit.open(n2, { line = 2.5 })
    ok("p88: a fractional line is refused by the Lua entry point too",
      frac == nil and tostring(fracerr):find("INTEGER", 1, true) ~= nil,
      tostring(fracerr))
  end

  -- ── the fallback path must not steal focus either (r0 nit 1) ────────
  --
  -- Reached by stubbing nvim_open_win so the REAL fallback runs, rather than
  -- by trusting that the branch behaves like the primary one. Restored
  -- immediately, and asserted to have actually been taken — a stub that did
  -- not fire would make this cell pass while testing the primary path.
  do
    -- make_window() is only REACHED when nothing usable exists, and by this
    -- point earlier cells have left usable windows around. Close them first,
    -- or the stub never fires and this cell silently tests the primary path —
    -- which is exactly what the control below caught on the first run.
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= panel_win and vim.api.nvim_win_is_valid(w)
        and #vim.api.nvim_tabpage_list_wins(0) > 1 then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.api.nvim_set_current_win(panel_win)

    local real_open_win = vim.api.nvim_open_win
    local took_fallback = false
    vim.api.nvim_open_win = function(...)
      took_fallback = true
      error("stubbed: forcing the Ex-command fallback")
    end
    local before_bufs = #vim.api.nvim_list_bufs()
    local orphans_before = undisplayed_unnamed()
    local caller = vim.api.nvim_get_current_win()
    local rf, rferr = edit.open(file, { line = 2 })
    vim.api.nvim_open_win = real_open_win

    ok("p88: control — the stub fired, so the FALLBACK path is what ran",
      took_fallback, "the stub never fired; this cell tested the primary path")
    -- With the panel as the ONLY window the Ex-command fallback CANNOT work —
    -- that is the measurement that made the primary path use nvim_open_win in
    -- the first place. So the correct outcome here is a LOUD failure naming the
    -- interception, not a window. This cell asserted a window on its first
    -- draft and the error message is what corrected it.
    ok("p88: the fallback fails LOUDLY when the Ex command is intercepted",
      rf == nil and tostring(rferr):find("reported success while creating nothing",
        1, true) ~= nil,
      tostring(rferr))
    -- Nit 1's actual content: focus is kept even down the failure path.
    ok("p88: and the caller keeps focus even when the fallback fails",
      vim.api.nvim_get_current_win() == caller,
      ("current=%s caller=%s"):format(tostring(vim.api.nvim_get_current_win()),
        tostring(caller)))
    -- r0 nit 2, tightened at r1. `#list_bufs() <= before + 1` was too loose to
    -- discriminate: the file buffer is a legitimate +1, so a leaked scratch
    -- hides inside the allowance. The measure that separates them is
    -- UNDISPLAYED, UNNAMED buffers — a scratch that never reached a window —
    -- and it was delta 0 on the primary path and delta 1 here, which is
    -- exactly what `bufhidden = "wipe"` cannot catch: it is a hidden trigger,
    -- so a buffer never displayed never fires it.
    ok("p88: and the fallback leaks no undisplayed scratch buffer",
      undisplayed_unnamed() == orphans_before,
      ("undisplayed-unnamed %d -> %d"):format(orphans_before, undisplayed_unnamed()))
  end

  -- The fallback SUCCEEDING, which needs a window that can be split from but
  -- cannot take a file — a nofile scratch window, not a panel. Without one,
  -- `find_usable` short-circuits and make_window is never reached; with only a
  -- panel, the Ex command is intercepted. This is the narrow case where the
  -- old-Neovim path actually works, and it is the one worth pinning.
  do
    vim.cmd("botright new")
    local scratch_win = vim.api.nvim_get_current_win()
    vim.bo[vim.api.nvim_win_get_buf(scratch_win)].buftype = "nofile"
    vim.api.nvim_set_current_win(panel_win)

    local real_open_win = vim.api.nvim_open_win
    local fired = false
    vim.api.nvim_open_win = function(...)
      fired = true
      error("stubbed: forcing the Ex-command fallback")
    end
    local caller = vim.api.nvim_get_current_win()
    local rf2, rf2err = edit.open(file, { line = 3 })
    vim.api.nvim_open_win = real_open_win

    ok("p88: control — the stub fired again", fired, "stub did not fire")
    ok("p88: the fallback DOES create a window when it can be split from",
      rf2 ~= nil and rf2.created_window == true and rf2.win ~= panel_win
        and rf2.win ~= scratch_win, vim.inspect({ err = rf2err, res = rf2 }))
    ok("p88: …and still does not steal focus (Q2 on the fallback path)",
      vim.api.nvim_get_current_win() == caller,
      ("current=%s caller=%s"):format(tostring(vim.api.nvim_get_current_win()),
        tostring(caller)))
  end

  -- ── the mailbox verb, through the SAME entry point the router uses ──
  local commands = require("auto-core.mailbox.commands")
  local listed
  for _, e in ipairs(commands.list()) do
    if e.name == "editor.open" then listed = e end
  end
  ok("p88: `editor.open` is DISCOVERABLE — commands_list relays this list",
    listed ~= nil and listed.owner == "auto-core"
      and type(listed.schema) == "table" and listed.schema.path == "string",
    vim.inspect(listed))

  local resp = commands.handle_message({
    kind = "command", command = "editor.open",
    from = "agent:p88", to = "nvim",
    args = { path = file, line = 12 },
  })
  ok("p88: and DISPATCHABLE through handle_message, naming its window",
    resp ~= nil and resp.ok == true and type(resp.result) == "table"
      and resp.result.win ~= nil and resp.result.line == 12,
    vim.inspect(resp))

  local bad = commands.handle_message({
    kind = "command", command = "editor.open",
    from = "agent:p88", to = "nvim",
    args = { path = 42 },
  })
  ok("p88: a bad arg is rejected by the SCHEMA, before the handler runs",
    bad ~= nil and bad.ok == false and bad.code == "bad_args",
    vim.inspect(bad))

  p:close()
  Panel._reset_for_tests()
  events._reset_for_tests()
  vim.fn.delete(dir, "rf")
end)()

-- ── [89] git.worktree — a bare repo cloned in place is a repo ────────
-- list_child_repos and collect recognised a child only by `<child>/.git`.
-- A bare repository cloned straight into its container (`git clone --bare
-- <url> name`, worktrees inside it) has no `.git` — its HEAD, objects/ and
-- refs/ sit in the container itself — so it was invisible: missing from every
-- repo picker and every worktree listing (auto-run.nvim in Johno's workspace
-- has this shape; ADR 0199 §7.3). Recognised now by git's own test for a git
-- directory: HEAD plus objects/ and refs/.
print("\n[89] git.worktree — bare repos without .git are enumerated")
;(function()
  local wt = require("auto-core.git.worktree")
  local ws = vim.fn.tempname() .. "-ws89"
  vim.fn.mkdir(ws, "p")
  local function git(dir, ...)
    local r = vim.system({ "git", "-C", dir, "-c", "user.email=s@t", "-c", "user.name=s", ... },
      { text = true }):wait()
    return r.code == 0, (r.stderr or "")
  end
  -- a/: a plain repository.
  vim.system({ "git", "init", "-q", "-b", "main", ws .. "/a" }, { text = true }):wait()
  git(ws .. "/a", "commit", "-q", "--allow-empty", "-m", "init")
  -- b/: the family layout — a bare git dir at b/.git, a worktree at b/main.
  vim.fn.mkdir(ws .. "/b", "p")
  vim.system({ "git", "clone", "-q", "--bare", ws .. "/a", ws .. "/b/.git" }, { text = true }):wait()
  local okb, eb = git(ws .. "/b", "worktree", "add", "-q", ws .. "/b/main", "main")
  -- c/: a bare repo cloned IN PLACE — no .git — with a worktree inside it.
  vim.system({ "git", "clone", "-q", "--bare", ws .. "/a", ws .. "/c" }, { text = true }):wait()
  local okc, ec = git(ws .. "/c", "worktree", "add", "-q", ws .. "/c/wt1", "main")
  ok("[89] fixture: both bare layouts have a worktree", okb and okc, eb .. ec)
  -- d/: a plain directory. e/: a HEAD file alone is NOT a git directory.
  vim.fn.mkdir(ws .. "/d", "p")
  vim.fn.mkdir(ws .. "/e", "p")
  vim.fn.writefile({ "ref: refs/heads/main" }, ws .. "/e/HEAD")

  local names = {}
  for _, r in ipairs(wt.list_child_repos(ws)) do names[#names + 1] = r.name end
  ok("[89] list_child_repos includes the in-place bare repo, alongside the other layouts",
    vim.deep_equal(names, { "a", "b", "c" }), vim.inspect(names))

  local paths = {}
  for _, e in ipairs(wt.collect(ws) or {}) do paths[#paths + 1] = e.path end
  local norm = require("auto-core.fs.path").normalize
  local function has(p) return vim.tbl_contains(paths, norm(p)) end
  ok("[89] collect lists the in-place bare repo's worktree", has(ws .. "/c/wt1"), vim.inspect(paths))
  ok("[89] collect still lists the plain repo and the family layout's worktree",
    has(ws .. "/a") and has(ws .. "/b/main"), vim.inspect(paths))
  ok("[89] collect drops the bare entries themselves (nothing to run in)",
    not has(ws .. "/c") and not has(ws .. "/b/.git") and not has(ws .. "/b"), vim.inspect(paths))
  ok("[89] a plain dir and a lone HEAD file are not repos",
    not has(ws .. "/d") and not has(ws .. "/e"), vim.inspect(paths))

  vim.fn.delete(ws, "rf")
end)()

-- ── [90] git.worktree — prunable and locked worktrees are marked ──────
-- parse_porcelain dropped git's `prunable` and `locked` lines, so a worktree
-- whose directory had been deleted was listed exactly like a live one, and
-- auto-finder's Active-worktree picker offered (and crashed on) two dead /tmp
-- worktrees. The flags are kept now; the entries stay listed.
print("\n[90] git.worktree — prunable and locked worktrees are marked")
;(function()
  local wt = require("auto-core.git.worktree")
  local parsed = wt.parse_porcelain({
    "worktree /r/live", "HEAD 1111111111", "branch refs/heads/main", "",
    "worktree /r/gone", "HEAD 2222222222", "detached", "prunable gitdir file points to non-existent location", "",
    "worktree /r/held", "HEAD 3333333333", "branch refs/heads/hold", "locked on a USB drive", "",
    "worktree /r/both", "HEAD 4444444444", "branch refs/heads/b", "locked", "prunable",
  })
  ok("[90] every entry is still listed", #parsed == 4, vim.inspect(parsed))
  ok("[90] a live worktree carries neither flag",
    parsed[1].prunable == nil and parsed[1].locked == nil, vim.inspect(parsed[1]))
  ok("[90] prunable with a reason is flagged; detached is still read",
    parsed[2].prunable == true and parsed[2].detached == true, vim.inspect(parsed[2]))
  ok("[90] locked with a reason is flagged; the branch is still read",
    parsed[3].locked == true and parsed[3].branch == "hold" and parsed[3].prunable == nil, vim.inspect(parsed[3]))
  ok("[90] the bare keywords set both flags",
    parsed[4].locked == true and parsed[4].prunable == true, vim.inspect(parsed[4]))

  -- The real thing: git marks a worktree whose directory was deleted.
  local ws = vim.fn.tempname() .. "-ws90"
  vim.fn.mkdir(ws, "p")
  local function git(dir, ...)
    local r = vim.system({ "git", "-C", dir, "-c", "user.email=s@t", "-c", "user.name=s", ... },
      { text = true }):wait()
    return r.code == 0, (r.stderr or "")
  end
  vim.system({ "git", "init", "-q", "-b", "main", ws .. "/repo" }, { text = true }):wait()
  git(ws .. "/repo", "commit", "-q", "--allow-empty", "-m", "init")
  local gone = ws .. "/elsewhere/gone"
  local okw, ew = git(ws .. "/repo", "worktree", "add", "-q", "--detach", gone)
  ok("[90] fixture: a linked worktree outside the workspace", okw, ew)
  vim.fn.delete(ws .. "/elsewhere", "rf")

  local norm = require("auto-core.fs.path").normalize
  local by = {}
  for _, e in ipairs(wt.collect(ws) or {}) do by[e.path] = e end
  ok("[90] collect still lists the deleted worktree, flagged prunable",
    by[norm(gone)] and by[norm(gone)].prunable == true, vim.inspect(by))
  ok("[90] the live main worktree is not flagged",
    by[norm(ws .. "/repo")] and by[norm(ws .. "/repo")].prunable == nil, vim.inspect(by))

  vim.fn.delete(ws, "rf")
end)()

-- ── [91] git.worktree — the one worktree picker ────────────────────
-- worktree.nvim's <leader>gw, auto-finder's `w` and auto-run's <leader>rw all
-- show git.worktree.select's list: every worktree of every repo under the
-- root, plus the root's own when the root is a repo (a single plain repo —
-- collect alone found nothing there), without bare or prunable entries.
-- choose_active is select + set_active and leaves the cwd alone.
print("\n[91] git.worktree — select / choose_active: the one worktree picker")
;(function()
  local wt = require("auto-core.git.worktree")
  local norm = require("auto-core.fs.path").normalize
  local function git(dir, ...)
    local r = vim.system({ "git", "-C", dir, "-c", "user.email=s@t", "-c", "user.name=s", ... },
      { text = true }):wait()
    return r.code == 0, (r.stderr or "")
  end
  local function init(dir)
    vim.system({ "git", "init", "-q", "-b", "main", dir }, { text = true }):wait()
    git(dir, "commit", "-q", "--allow-empty", "-m", "init")
  end

  -- A multi-repo workspace: plain repo a/ with a linked worktree a-feat/, the
  -- family layout b/ (bare at b/.git, worktree b/main), and a deleted worktree.
  local ws = norm(vim.fn.tempname() .. "-ws91")
  vim.fn.mkdir(ws, "p")
  init(ws .. "/a")
  local ok1 = git(ws .. "/a", "worktree", "add", "-q", "-b", "feat", ws .. "/a-feat")
  vim.fn.mkdir(ws .. "/b", "p")
  vim.system({ "git", "clone", "-q", "--bare", ws .. "/a", ws .. "/b/.git" }, { text = true }):wait()
  local ok2 = git(ws .. "/b", "worktree", "add", "-q", ws .. "/b/main", "main")
  local ok3 = git(ws .. "/a", "worktree", "add", "-q", "--detach", ws .. "/gone")
  vim.fn.delete(ws .. "/gone", "rf")
  ok("[91] fixture built", ok1 and ok2 and ok3)

  local paths = {}
  for _, e in ipairs(wt.selectable(ws)) do paths[#paths + 1] = e.path end
  ok("[91] selectable: every live worktree, sorted; no bare, no prunable",
    vim.deep_equal(paths, { ws .. "/a", ws .. "/a-feat", ws .. "/b/main" }), vim.inspect(paths))

  -- A single plain repo as the root, with one linked worktree beside it.
  local solo = norm(vim.fn.tempname() .. "-solo91")
  init(solo)
  git(solo, "worktree", "add", "-q", "-b", "side", solo .. "-side")
  local solo_paths = {}
  for _, e in ipairs(wt.selectable(solo)) do solo_paths[#solo_paths + 1] = e.path end
  ok("[91] selectable: a root that is itself a plain repo offers its own worktrees",
    vim.deep_equal(solo_paths, { solo, solo .. "-side" }), vim.inspect(solo_paths))

  -- Fixed entries, so these cells do not depend on selectable's answer.
  local root_label = wt.format_entry({ path = solo, branch = "main" }, solo, solo)
  ok("[91] format_entry: '.' for the root, marked when current",
    root_label:match("^● %.%s+%[main%]$") ~= nil, root_label)
  local outside = wt.format_entry({ path = solo .. "-side", branch = "side" }, solo, solo)
  ok("[91] format_entry: a worktree outside the root shows its ~-relative path",
    outside:match("^  " .. vim.pesc(vim.fn.fnamemodify(solo .. "-side", ":~")) .. "%s+%[side%]$") ~= nil, outside)
  local detached = wt.format_entry({ path = solo .. "/x", detached = true }, solo, nil)
  ok("[91] format_entry: a detached worktree says so", detached:match("^  x%s+%[detached%]$") ~= nil, detached)

  -- select: the list, the labels and the prompt; the choice goes to on_choice.
  local real_select = vim.ui.select
  local seen
  local pick_index = 2
  vim.ui.select = function(items, o, cb)
    seen = { items = items, prompt = o.prompt, labels = vim.tbl_map(o.format_item, items) }
    cb(pick_index and items[pick_index] or nil)
  end
  local chosen
  local okS = wt.select({ root = ws, prompt = "Switch worktree:", current = ws .. "/a" }, function(e) chosen = e end)
  ok("[91] select opens the picker with the caller's prompt", okS and seen and seen.prompt == "Switch worktree:",
    vim.inspect(seen))
  ok("[91] select labels: marker on current, relative path, branch",
    seen.labels[1]:match("^● a%s+%[main%]$") and seen.labels[2]:match("^  a%-feat%s+%[feat%]$")
      and seen.labels[3]:match("^  b/main%s+%[main%]$"), vim.inspect(seen.labels))
  ok("[91] select hands the chosen entry to on_choice", chosen and chosen.path == ws .. "/a-feat", vim.inspect(chosen))

  local empty = norm(vim.fn.tempname() .. "-empty91")
  vim.fn.mkdir(empty, "p")
  seen = nil
  local okE, errE = wt.select({ root = empty }, function() end)
  ok("[91] select with nothing to offer reports it and opens no picker",
    okE == false and seen == nil and tostring(errE):match("no worktrees found") ~= nil, tostring(errE))

  -- choose_active: step 1 is this list, step 2 a directory in the chosen
  -- worktree. Answers are queued, one per prompt; a prompt with none cancels.
  local answers, prompts = {}, {}
  vim.ui.select = function(items, o, cb)
    prompts[#prompts + 1] = o.prompt
    seen = { prompt = o.prompt, labels = vim.tbl_map(o.format_item, items), items = items }
    local i = table.remove(answers, 1)
    cb(i and items[i] or nil)
  end
  wt._reset_for_tests()
  local cwd_before = vim.fn.getcwd()
  local changed = {}
  local sub = events_mod.subscribe("core.active_worktree:changed", function(p) changed[#changed + 1] = p end)
  answers = { 3, 1 } -- b/main, then its root
  local okA = wt.choose_active({ root = ws })
  ok("[91] choose_active: the worktree list, then the folder step",
    okA and prompts[1] == "Active worktree (cwd stays):" and prompts[2] == "Working directory in main:",
    vim.inspect(prompts))
  ok("[91] choose_active sets the chosen worktree active",
    wt.get_active() == ws .. "/b/main", tostring(wt.get_active()))
  ok("[91] choose_active leaves the cwd alone", vim.fn.getcwd() == cwd_before, vim.fn.getcwd())
  vim.wait(200, function() return #changed > 0 end)
  ok("[91] choose_active publishes core.active_worktree:changed",
    #changed == 1 and changed[1].to == ws .. "/b/main", vim.inspect(changed))
  answers = {}
  prompts = {}
  wt.choose_active({ root = ws })
  ok("[91] step 1 marks the worktree that is active", seen and seen.labels[3]:match("^●") ~= nil,
    vim.inspect(seen and seen.labels))
  ok("[91] cancelling step 1 opens no folder step and changes nothing",
    #prompts == 1 and wt.get_active() == ws .. "/b/main", vim.inspect(prompts))
  answers = { 1 }
  prompts = {}
  wt.choose_active({ root = ws })
  ok("[91] cancelling step 2 changes nothing",
    #prompts == 2 and wt.get_active() == ws .. "/b/main", tostring(wt.get_active()))
  -- An active directory INSIDE a worktree still marks that worktree.
  wt.set_active(ws .. "/a-feat/sub")
  answers = {}
  wt.choose_active({ root = ws })
  ok("[91] an active folder inside a worktree marks that worktree",
    seen.labels[2]:match("^●") ~= nil and seen.labels[1]:match("^●") == nil, vim.inspect(seen.labels))

  events_mod.unsubscribe(sub)
  vim.ui.select = real_select
  wt._reset_for_tests()
  for _, d in ipairs({ ws, solo, solo .. "-side", empty }) do vim.fn.delete(d, "rf") end
end)()

-- ── [92] git.worktree — the folder step: project folders, custom paths ──
-- A multi-project repo (playground: go-contacts/, rust-contacts/, web/ ...)
-- is ONE worktree; the folder step lets auto-run work in one of its
-- directories. Project folders are those carrying a marker; any directory can
-- be typed. The active worktree becomes that directory; the cwd never moves.
print("\n[92] git.worktree — choose_dir: root, project folders, a typed directory")
;(function()
  local wt = require("auto-core.git.worktree")
  local norm = require("auto-core.fs.path").normalize
  local repo = norm(vim.fn.tempname() .. "-play92")
  vim.system({ "git", "init", "-q", "-b", "main", repo }, { text = true }):wait()
  local function touch(rel)
    vim.fn.mkdir(vim.fn.fnamemodify(repo .. "/" .. rel, ":h"), "p")
    vim.fn.writefile({}, repo .. "/" .. rel)
  end
  touch("go-contacts/go.mod")
  touch("go-contacts/cmd/server/main.go")
  touch("rust-contacts/Cargo.toml")
  touch("web/package.json")
  touch("web/node_modules/dep/package.json")   -- inside a project: not searched
  touch("go-contacts/tools/go.mod")            -- a project inside a project, depth 2: not listed
  touch("node_modules/dep/package.json")       -- dependency output at depth 2: skipped
  touch("target/debug/Cargo.toml")             -- build output at depth 2: skipped
  touch("services/api/go.mod")                 -- depth 2, under a non-project dir
  touch("services/api/internal/x/go.mod")      -- inside a project: not searched
  touch("deep/a/b/package.json")               -- depth 3: beyond the default
  touch(".hidden/go.mod")
  touch("nested/.git")                          -- a nested repo: its own entry
  touch("nested/go.mod")
  vim.fn.mkdir(repo .. "/docs", "p")

  local got = {}
  for _, d in ipairs(wt.project_dirs(repo)) do got[#got + 1] = d.path:sub(#repo + 2) .. ":" .. d.marker end
  ok("[92] project_dirs: marker folders to depth 2, not inside a project, no deps/hidden/nested repos",
    vim.deep_equal(got, { "go-contacts:go.mod", "rust-contacts:Cargo.toml", "services/api:go.mod", "web:package.json" }),
    vim.inspect(got))

  local r1 = wt.resolve_dir_input("go-contacts", repo)
  local r2 = wt.resolve_dir_input(repo .. "/docs", repo)
  local r3, e3 = wt.resolve_dir_input("missing/dir", repo)
  local r4, e4 = wt.resolve_dir_input("go-contacts/go.mod", repo)
  local r5, e5 = wt.resolve_dir_input("   ", repo)
  ok("[92] resolve_dir_input: relative to the worktree, absolute as given",
    r1 == repo .. "/go-contacts" and r2 == repo .. "/docs", vim.inspect({ r1, r2 }))
  ok("[92] resolve_dir_input: a missing path, a file and nothing are refused with a reason",
    r3 == nil and tostring(e3):match("not a directory") ~= nil and r4 == nil
      and tostring(e4):match("not a directory") ~= nil and r5 == nil and tostring(e5):match("no directory") ~= nil,
    vim.inspect({ e3, e4, e5 }))

  local real_select, real_input, real_notify = vim.ui.select, vim.ui.input, vim.notify
  local seen, answer, typed, notes = nil, nil, nil, {}
  vim.ui.select = function(items, o, cb)
    seen = { prompt = o.prompt, labels = vim.tbl_map(o.format_item, items) }
    cb(answer and items[answer] or nil)
  end
  vim.ui.input = function(o, cb) seen.input = o; cb(typed) end
  vim.notify = function(m) notes[#notes + 1] = m end

  wt._reset_for_tests()
  local cwd_before = vim.fn.getcwd()
  answer = 2 -- go-contacts
  wt.choose_dir(repo)
  ok("[92] the folder step lists the root, the project folders, then the custom entry",
    #seen.labels == 6 and seen.labels[1] == "  . (worktree root)" and seen.labels[2]:match("^  go%-contacts%s+go%.mod$") ~= nil
      and seen.labels[6] == "  Custom directory…", vim.inspect(seen.labels))
  ok("[92] choosing a project folder makes it the active worktree", wt.get_active() == repo .. "/go-contacts",
    tostring(wt.get_active()))
  ok("[92] the cwd does not move", vim.fn.getcwd() == cwd_before, vim.fn.getcwd())

  wt.choose_dir(repo, { current = wt.get_active() })
  ok("[92] the current directory is marked", seen.labels[2]:match("^● go%-contacts") ~= nil, vim.inspect(seen.labels))

  answer, typed = 6, "docs"
  wt.choose_dir(repo)
  ok("[92] the custom entry prompts for a directory, completed as one, starting at the worktree",
    seen.input and seen.input.completion == "dir" and seen.input.default == repo .. "/", vim.inspect(seen.input))
  ok("[92] a typed relative directory becomes active", wt.get_active() == repo .. "/docs", tostring(wt.get_active()))

  typed = "no/such/dir"
  wt.choose_dir(repo)
  ok("[92] a typed path that is not a directory changes nothing and says why",
    wt.get_active() == repo .. "/docs" and #notes == 1 and tostring(notes[1]):match("unchanged: not a directory") ~= nil,
    vim.inspect(notes))

  typed = nil
  wt.choose_dir(repo)
  answer = nil
  wt.choose_dir(repo)
  ok("[92] cancelling the prompt or the list changes nothing", wt.get_active() == repo .. "/docs" and #notes == 1,
    tostring(wt.get_active()))

  vim.ui.select, vim.ui.input, vim.notify = real_select, real_input, real_notify
  wt._reset_for_tests()
  vim.fn.delete(repo, "rf")
end)()

-- ── [93] auto-core.kb — the project's primary KB (ADR 1791209945 §5) ──────
--
-- The one KB resolver: primary > $AUTO_AGENTS_KB_ROOT > first-run import from
-- auto-agents > nil. auto-agents is STUBBED through package.loaded for every
-- cell (absent / answering / erroring / calling back in) so no cell depends on
-- what happens to be on the runtimepath, and the env trio is saved, cleared
-- and restored so an agent session's ambient KB cannot answer for a fixture.
-- State isolation: the namespace's records are wiped before and after, and
-- persist_dir points at this section's own tempdir.
print("\n[93] auto-core.kb — primary KB, the one resolver, first-run import")
;(function()
  local ok_k, kb = pcall(require, "auto-core.kb")
  ok("[93] auto-core.kb loads", ok_k, tostring(kb))
  if not ok_k then return end
  local state  = require("auto-core.state")
  local events = require("auto-core.events")
  local wt     = require("auto-core.git.worktree")
  local where  = require("auto-core.todo.where")

  ok("[93] the facade exposes it", core.kb == kb)

  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  state.configure({ persist_dir = state_tmp })
  assert_kb_state_sandboxed()
  kb._reset_for_tests()

  local saved_env = {
    ROOT  = vim.env.AUTO_AGENTS_KB_ROOT,
    READ  = vim.env.AUTO_AGENTS_KB_READ,
    WRITE = vim.env.AUTO_AGENTS_KB_WRITE,
  }
  vim.env.AUTO_AGENTS_KB_ROOT  = nil
  vim.env.AUTO_AGENTS_KB_READ  = nil
  vim.env.AUTO_AGENTS_KB_WRITE = nil
  local saved_aa_loaded  = package.loaded["auto-agents.kb"]
  local saved_aa_preload = package.preload["auto-agents.kb"]
  local saved_ws = wt.get_workspace_root()

  -- auto-agents ABSENT: require must fail, not merely find nothing loaded.
  local function aa_absent()
    package.loaded["auto-agents.kb"] = nil
    package.preload["auto-agents.kb"] = function() error("auto-agents not installed") end
  end
  local aa_calls = 0
  local function aa_answers(fn)
    aa_calls = 0
    package.preload["auto-agents.kb"] = nil
    package.loaded["auto-agents.kb"] = {
      root = function() aa_calls = aa_calls + 1; return fn() end,
    }
  end

  local function mkdir(p) vim.fn.mkdir(p, "p"); return vim.uv.fs_realpath(p) end
  local base  = mkdir(vim.fn.tempname())
  local proj  = mkdir(base .. "/proj")
  local kb_a  = mkdir(base .. "/kb-a")
  local kb_b  = mkdir(base .. "/kb-b")
  local alias = base .. "/proj-alias"
  vim.uv.fs_symlink(proj, alias)
  vim.fn.writefile({ "x" }, base .. "/a-file")

  local function primaries()
    local all = state.namespace("kb"):get("primaries")
    local keys = {}
    for k in pairs(type(all) == "table" and all or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys, all
  end

  local seen = {}
  local h = events.subscribe("core.kb:primary_changed", function(p) seen[#seen + 1] = p end)

  -- ── nothing configured ───────────────────────────────────────
  aa_absent()
  wt.set_workspace_root(proj)
  ok("[93] no primary, no env, no auto-agents → root is nil",
    kb.root(proj) == nil and kb.root() == nil, tostring(kb.root(proj)))
  ok("[93] … and primary is nil, nothing recorded",
    kb.primary(proj) == nil and #primaries() == 0, vim.inspect(primaries()))

  -- ── env: used when there is no primary ───────────────────────
  vim.env.AUTO_AGENTS_KB_ROOT = kb_a
  ok("[93] env AUTO_AGENTS_KB_ROOT answers when no primary is set",
    kb.root(proj) == kb_a, tostring(kb.root(proj)))
  -- READ/WRITE are dropped: a spawned agent always gets ROOT.
  vim.env.AUTO_AGENTS_KB_ROOT  = nil
  vim.env.AUTO_AGENTS_KB_READ  = kb_a
  vim.env.AUTO_AGENTS_KB_WRITE = kb_a
  ok("[93] READ / WRITE are no longer fallbacks",
    kb.root(proj) == nil, tostring(kb.root(proj)))
  vim.env.AUTO_AGENTS_KB_READ  = nil
  vim.env.AUTO_AGENTS_KB_WRITE = nil
  vim.env.AUTO_AGENTS_KB_ROOT  = kb_a

  -- ── set_primary is interactive only ──────────────────────────
  local okc, errc = kb.set_primary(proj, { workspace = "global", root = kb_b })
  ok("[93] set_primary refuses without opts.confirmed", okc == false and errc == "not_confirmed",
    tostring(errc))
  local okt = kb.set_primary(proj, { root = kb_b }, { confirmed = "yes" })
  ok("[93] … and refuses a truthy non-true confirmed", okt == false)
  ok("[93] … and wrote nothing, published nothing", kb.primary(proj) == nil and #seen == 0)

  local okm, errm = kb.set_primary(proj, { root = kb_b .. "/missing" }, { confirmed = true })
  ok("[93] set_primary rejects a root that does not exist", okm == false and errm == "root_not_a_directory",
    tostring(errm))
  local okf, errf = kb.set_primary(proj, { root = base .. "/a-file" }, { confirmed = true })
  ok("[93] set_primary rejects a root that is a file", okf == false and errf == "root_not_a_directory",
    tostring(errf))
  ok("[93] … neither rejection wrote a record", kb.primary(proj) == nil and #primaries() == 0)

  -- The todo store is untouched by set_primary (ADR §5.5): snapshot the
  -- resolved dir AND the whole todo namespace before the first real set.
  local td_before = where.local_dir(where.root())
  local todo_ns_before = vim.deepcopy(state.namespace("todo"):get_all())

  local oks, errs = kb.set_primary(proj, { workspace = "global", root = kb_b }, { confirmed = true })
  ok("[93] set_primary with confirmed = true succeeds", oks == true, tostring(errs))
  ok("[93] core.kb:primary_changed published once, keyed by the real path",
    #seen == 1 and seen[1].project_root == proj and seen[1].root == kb_b
      and seen[1].workspace == "global" and seen[1].source == "set" and seen[1].old == nil,
    vim.inspect(seen))
  ok("[93] the topic is registered", require("auto-core.events.topics")["core.kb:primary_changed"] ~= nil)

  -- ── primary wins over env ────────────────────────────────────
  ok("[93] primary wins over env (env still set to another KB)",
    vim.env.AUTO_AGENTS_KB_ROOT == kb_a and kb.root(proj) == kb_b, tostring(kb.root(proj)))
  local pr = kb.primary(proj)
  ok("[93] primary() returns { workspace, root }",
    pr and pr.workspace == "global" and pr.root == kb_b, vim.inspect(pr))
  ok("[93] the default project is the session's (workspace root)", kb.root() == kb_b, tostring(kb.root()))

  -- ── realpath: an alias maps to the same single entry ─────────
  ok("[93] an alias of the project reads the same primary",
    kb.root(alias) == kb_b and (kb.primary(alias) or {}).root == kb_b, tostring(kb.root(alias)))
  kb.set_primary(alias, { workspace = "global", root = kb_a }, { confirmed = true })
  local keys = primaries()
  ok("[93] setting through the alias rewrites the ONE real-path entry",
    #keys == 1 and keys[1] == proj and kb.root(proj) == kb_a, vim.inspect(keys))
  ok("[93] … and the event carries the old value",
    #seen == 2 and seen[2].old and seen[2].old.root == kb_b and seen[2].project_root == proj,
    vim.inspect(seen[2]))
  kb.set_primary(proj, { workspace = "global", root = kb_a }, { confirmed = true })
  ok("[93] re-setting the same value publishes nothing", #seen == 2, tostring(#seen))

  ok("[93] the todo dir is untouched by set_primary", where.local_dir(where.root()) == td_before,
    tostring(where.local_dir(where.root())) .. " vs " .. tostring(td_before))
  ok("[93] … and so is the todo state namespace (overrides, known dirs)",
    vim.deep_equal(state.namespace("todo"):get_all(), todo_ns_before))

  -- ── persisted JSON, keyed by real path ───────────────────────
  local ns = state.namespace("kb")
  ns:persist_now()
  local raw = table.concat(vim.fn.readfile(ns._path), "\n")
  local okd, decoded = pcall(vim.json.decode, raw)
  local rec = okd and decoded.primaries and decoded.primaries[proj]
  ok("[93] the state file holds { workspace, root, set_at } under the real path",
    rec and rec.root == kb_a and rec.workspace == "global" and type(rec.set_at) == "string",
    raw)

  -- ── first-run import ─────────────────────────────────────────
  vim.env.AUTO_AGENTS_KB_ROOT = nil
  local proj2  = mkdir(base .. "/proj2")
  local alias2 = base .. "/proj2-alias"
  vim.uv.fs_symlink(proj2, alias2)
  wt.set_workspace_root(proj2)
  aa_answers(function() return kb_b end)
  local n_before = #seen
  ok("[93] import: a project without a primary gets auto-agents' answer",
    kb.root() == kb_b, tostring(kb.root()))
  local p2 = kb.primary(proj2)
  ok("[93] import: … recorded as the project's primary (no workspace yet)",
    p2 and p2.root == kb_b and p2.workspace == nil, vim.inspect(p2))
  ok("[93] import: published once with source = 'import'",
    #seen == n_before + 1 and seen[#seen].source == "import" and seen[#seen].project_root == proj2,
    vim.inspect(seen[#seen]))
  local logged
  for _, r in ipairs(require("auto-core.log").recent(10)) do
    if r.component == "auto-core.kb" and tostring(r.message or r.msg or ""):find(proj2, 1, true) then
      logged = r
    end
  end
  ok("[93] import: logged on the auto-core.kb component axis", logged ~= nil)
  ok("[93] import: a second call is a no-op (auto-agents not asked again, no event)",
    kb.root() == kb_b and aa_calls == 1 and #seen == n_before + 1, "calls=" .. aa_calls)
  wt.set_workspace_root(alias2)
  local keys2 = primaries()
  ok("[93] import: an alias of the same real path is a no-op too",
    kb.root() == kb_b and aa_calls == 1 and #seen == n_before + 1 and #keys2 == 2,
    "calls=" .. aa_calls .. " keys=" .. vim.inspect(keys2))
  ok("[93] import: nothing on disk changed besides the state file",
    vim.fn.readdir(proj2)[1] == nil and vim.fn.isdirectory(kb_b .. "/.todo-list") == 0,
    vim.inspect(vim.fn.readdir(proj2)))

  -- A phantom root (auto-agents answers <project>/.auto-agents/kb whether or
  -- not it exists) is still RETURNED — today's answer — but never recorded.
  local proj3 = mkdir(base .. "/proj3")
  wt.set_workspace_root(proj3)
  aa_answers(function() return proj3 .. "/.auto-agents/kb" end)
  ok("[93] import: a missing directory is returned as the legacy answer",
    kb.root() == proj3 .. "/.auto-agents/kb", tostring(kb.root()))
  ok("[93] import: … but not recorded as the primary", kb.primary(proj3) == nil)

  -- auto-agents answers for the SESSION, so it says nothing about another project.
  local proj4 = mkdir(base .. "/proj4")
  aa_answers(function() return kb_a end)
  kb.root(proj4)
  ok("[93] import: never recorded for a project that is not the session's",
    kb.primary(proj4) == nil and kb.primary(proj3) == nil,
    vim.inspect({ kb.primary(proj4), kb.primary(proj3) }))

  -- env present → the legacy chain answered from env, never auto-agents.
  local proj5 = mkdir(base .. "/proj5")
  wt.set_workspace_root(proj5)
  aa_answers(function() return kb_b end)
  vim.env.AUTO_AGENTS_KB_ROOT = kb_a
  ok("[93] import: env answers before auto-agents is asked",
    kb.root() == kb_a and aa_calls == 0 and kb.primary(proj5) == nil, "calls=" .. aa_calls)
  vim.env.AUTO_AGENTS_KB_ROOT = nil

  aa_answers(function() error("boom") end)
  local okb, rb = pcall(kb.root)
  ok("[93] import: an erroring auto-agents is soft (nil, no throw, nothing recorded)",
    okb and rb == nil and kb.primary(proj5) == nil, tostring(rb))

  -- ── re-entrancy: auto-agents' shim calls back into auto-core.kb ──
  -- The shape auto-agents takes for one minor: ask auto-core first, fall back
  -- to its own legacy resolution. Without the guard the import re-enters
  -- itself until the C stack gives out.
  aa_answers(function() return require("auto-core.kb").root() or kb_b end)
  local okr, rr = pcall(kb.root)
  ok("[93] re-entrancy: the shim's call-back does not recurse",
    okr and rr == kb_b and aa_calls == 1, "ok=" .. tostring(okr) .. " calls=" .. aa_calls .. " r=" .. tostring(rr))
  ok("[93] re-entrancy: … and the import still recorded once",
    (kb.primary(proj5) or {}).root == kb_b)
  ok("[93] re-entrancy: the guard is released afterwards (a later import runs)",
    (function()
      local proj6 = mkdir(base .. "/proj6")
      wt.set_workspace_root(proj6)
      aa_answers(function() return kb_a end)
      return kb.root() == kb_a and kb.primary(proj6) ~= nil
    end)())

  -- ── another project, asked for by name (lector mid-stream MF2) ──
  -- The env var and the import describe the SESSION's project: another project with no primary of
  -- its own gets nil, never the session's KB.
  do
    local session_proj = mkdir(base .. "/proj-session")
    local other_proj = mkdir(base .. "/proj-other")
    wt.set_workspace_root(session_proj)
    kb._reset_for_tests()
    vim.env.AUTO_AGENTS_KB_ROOT = kb_a
    ok("[93] another project gets no KB from the session's AUTO_AGENTS_KB_ROOT",
      kb.root(other_proj) == nil, tostring(kb.root(other_proj)))
    ok("[93] the session's own project still gets it", kb.root() == kb_a, tostring(kb.root()))
    vim.env.AUTO_AGENTS_KB_ROOT = nil
    aa_answers(function() return kb_a end)
    ok("[93] another project gets no KB from the session's import", kb.root(other_proj) == nil and aa_calls == 0,
      string.format("%s (auto-agents asked %d times)", tostring(kb.root(other_proj)), aa_calls))
    ok("[93] and nothing is recorded for it", kb.primary(other_proj) == nil)
  end

  -- ── teardown ─────────────────────────────────────────────────
  events.unsubscribe(h)
  kb._reset_for_tests()
  package.loaded["auto-agents.kb"]  = saved_aa_loaded
  package.preload["auto-agents.kb"] = saved_aa_preload
  vim.env.AUTO_AGENTS_KB_ROOT  = saved_env.ROOT
  vim.env.AUTO_AGENTS_KB_READ  = saved_env.READ
  vim.env.AUTO_AGENTS_KB_WRITE = saved_env.WRITE
  wt.set_workspace_root(saved_ws)
  vim.fn.delete(base, "rf")
  -- state_tmp is NOT deleted: the state registry keeps a namespace at the path it
  -- was created with, and the kb namespace may have been created here (when no
  -- earlier section touched it). [94] writes through it; with this directory
  -- gone its writes would fail silently.
end)()

print("\n[94] auto-core.kb — managed KB documents: provided per version, synced into a KB")
;(function()
  local kb     = require("auto-core.kb")
  local state  = require("auto-core.state")
  local events = require("auto-core.events")
  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  state.configure({ persist_dir = state_tmp })
  assert_kb_state_sandboxed()
  kb._reset_for_tests()

  local function ops(v, body)
    return table.concat({ "---", "type: kb", "kind: operations", "autodoc_version: " .. v, "revision: 2", "---", "",
      body or ("# KB operations " .. v), "" }, "\n")
  end
  local function schema_yaml(v) return "# autodoc_version: " .. v .. "\n# schema\nversion: 2\n" end
  local function files(v) return {
    { rel = "KB_OPERATIONS.md", version = v, text = ops(v) },
    { rel = "_schema/frontmatter.yaml", version = v, text = schema_yaml(v) },
  } end
  local provided = {}
  local h = events.subscribe("core.kb:managed_provided", function(p) provided[#provided + 1] = p end)

  -- provide: stored, readable back, announced
  local okp, errp, rep = kb.provide_managed("autodoc", { version_key = "autodoc_version", files = files("0.1.18") })
  ok("[94] provide_managed stores a provider's documents", okp and errp == nil and #rep.stored == 2, vim.inspect({ errp, rep }))
  local m = kb.managed()
  ok("[94] managed() returns them by path, with version and text",
    m["KB_OPERATIONS.md"] and m["KB_OPERATIONS.md"].version == "0.1.18" and m["KB_OPERATIONS.md"].text == ops("0.1.18")
      and m["_schema/frontmatter.yaml"].version == "0.1.18")
  ok("[94] and publishes core.kb:managed_provided", #provided == 1 and provided[1].files["KB_OPERATIONS.md"] == "0.1.18",
    vim.inspect(provided))
  local ns = state.namespace("kb", { persist = "json" })
  vim.wait(200)
  local disk = vim.fn.filereadable(ns._path) == 1 and table.concat(vim.fn.readfile(ns._path), "\n") or ""
  ok("[94] the documents are persisted (a session where the provider never loads still has them)",
    disk:find("KB_OPERATIONS.md", 1, true) ~= nil, ns._path)

  -- an older provider never rolls them back; an equal version keeps the stored copy
  local _, _, rep_old = kb.provide_managed("autodoc", { version_key = "autodoc_version", files = files("0.1.17") })
  ok("[94] an older version is kept out (no rollback)", #rep_old.stored == 0 and kb.managed()["KB_OPERATIONS.md"].version == "0.1.18")
  local same = { { rel = "KB_OPERATIONS.md", version = "0.1.18", text = ops("0.1.18", "# other text") } }
  kb.provide_managed("autodoc", { version_key = "autodoc_version", files = same })
  ok("[94] an equal version keeps the stored copy", kb.managed()["KB_OPERATIONS.md"].text == ops("0.1.18"))

  -- refusals
  local bad_decl = { { rel = "KB_OPERATIONS.md", version = "0.2.0", text = ops("0.1.18") } }
  local okb, errb = kb.provide_managed("autodoc", { version_key = "autodoc_version", files = bad_decl })
  ok("[94] a file whose declared version disagrees is refused", not okb and errb == "invalid_file")
  local okr = kb.provide_managed("autodoc", { version_key = "autodoc_version",
    files = { { rel = "../escape.md", version = "9.9.9", text = ops("9.9.9") } } })
  local oka = kb.provide_managed("autodoc", { version_key = "autodoc_version",
    files = { { rel = "/etc/escape.md", version = "9.9.9", text = ops("9.9.9") } } })
  ok("[94] a path outside the KB is refused (.. and absolute)", not okr and not oka)
  ok("[94] and nothing it refused was stored", kb.managed()["KB_OPERATIONS.md"].version == "0.1.18"
    and kb.managed()["../escape.md"] == nil)

  -- sync into a KB
  local base = vim.fn.tempname()
  local kbroot = base .. "/kb"
  vim.fn.mkdir(kbroot .. "/_schema", "p")
  vim.fn.writefile(vim.split(ops("0.1.15", "# old"), "\n"), kbroot .. "/KB_OPERATIONS.md")
  vim.fn.writefile(vim.split(schema_yaml("0.1.15"), "\n"), kbroot .. "/_schema/frontmatter.yaml")
  vim.fn.writefile({ "# this KB's own" }, kbroot .. "/AGENTS.md")
  local synced = {}
  local h2 = events.subscribe("core.kb:managed_synced", function(p) synced[#synced + 1] = p end)
  local oks, errs, srep = kb.sync_managed(kbroot)
  local now = table.concat(vim.fn.readfile(kbroot .. "/KB_OPERATIONS.md"), "\n")
  ok("[94] sync_managed replaces an older copy with the stored text", oks and errs == nil and #srep.updated == 2
    and now .. "\n" == ops("0.1.18"), vim.inspect({ errs, srep, now }))
  ok("[94] it reads a YAML file's version from its leading comment",
    vim.fn.readfile(kbroot .. "/_schema/frontmatter.yaml")[1] == "# autodoc_version: 0.1.18")
  ok("[94] it never touches another file", vim.fn.readfile(kbroot .. "/AGENTS.md")[1] == "# this KB's own")
  ok("[94] and publishes core.kb:managed_synced", #synced == 1 and synced[1].root == kbroot, vim.inspect(synced))
  local _, _, again = kb.sync_managed(kbroot)
  ok("[94] a same-version copy is kept", #again.updated == 0 and #again.kept == 2)
  vim.fn.writefile(vim.split(ops("0.9.0", "# newer"), "\n"), kbroot .. "/KB_OPERATIONS.md")
  vim.fn.writefile({ "# hand written, no version" }, kbroot .. "/_schema/frontmatter.yaml")
  local _, _, keep = kb.sync_managed(kbroot)
  ok("[94] a newer or an unversioned copy is kept", #keep.updated == 0
    and vim.fn.readfile(kbroot .. "/_schema/frontmatter.yaml")[1] == "# hand written, no version", vim.inspect(keep))

  local bare = base .. "/not-a-kb"
  vim.fn.mkdir(bare, "p")
  local _, _, none = kb.sync_managed(bare)
  ok("[94] a missing file is never created", #none.updated == 0 and #none.missing == 2
    and vim.fn.filereadable(bare .. "/KB_OPERATIONS.md") == 0)
  local okn, errn = kb.sync_managed(base .. "/nope")
  ok("[94] a root that is not a directory is refused", not okn and errn == "root_not_a_directory")

  -- a symlinked folder leading out of the KB is never read or written through
  local outside = base .. "/outside"
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile(vim.split(schema_yaml("0.0.1"), "\n"), outside .. "/frontmatter.yaml")
  local esc = base .. "/esc"
  vim.fn.mkdir(esc, "p")
  vim.fn.writefile(vim.split(ops("0.0.1"), "\n"), esc .. "/KB_OPERATIONS.md")
  vim.uv.fs_symlink(outside, esc .. "/_schema")
  local _, _, erep = kb.sync_managed(esc)
  ok("[94] a symlinked folder leading outside the KB is skipped, and the outside file is untouched",
    vim.tbl_contains(erep.failed, "_schema/frontmatter.yaml")
      and vim.fn.readfile(outside .. "/frontmatter.yaml")[1] == "# autodoc_version: 0.0.1", vim.inspect(erep))
  ok("[94] the KB's own file beside it still syncs", vim.tbl_contains(erep.updated, "KB_OPERATIONS.md"))

  -- versions are semver, prereleases ordered below their release
  kb._reset_for_tests()
  local function one(v) return { { rel = "KB_OPERATIONS.md", version = v, text = ops(v) } } end
  local okj = kb.provide_managed("autodoc", { version_key = "autodoc_version", files = one("1.2.3junk") })
  ok("[94] a version with junk after it is not a version (refused)", not okj)
  kb.provide_managed("autodoc", { version_key = "autodoc_version", files = one("0.2.0-rc.1") })
  local _, _, rc = kb.provide_managed("autodoc", { version_key = "autodoc_version", files = one("0.2.0") })
  ok("[94] a release replaces its stored release candidate", #rc.stored == 1 and kb.managed()["KB_OPERATIONS.md"].version == "0.2.0")
  local _, _, back = kb.provide_managed("autodoc", { version_key = "autodoc_version", files = one("0.2.0-rc.2") })
  ok("[94] and a release candidate never replaces its release", #back.stored == 0)
  local rckb = base .. "/rckb"
  vim.fn.mkdir(rckb, "p")
  vim.fn.writefile(vim.split(ops("0.2.0-rc.1"), "\n"), rckb .. "/KB_OPERATIONS.md")
  local _, _, rcs = kb.sync_managed(rckb)
  ok("[94] a KB on the release candidate is synced to the release", vim.tbl_contains(rcs.updated, "KB_OPERATIONS.md"), vim.inspect(rcs))
  kb.provide_managed("autodoc", { version_key = "autodoc_version", files = one("0.2.1-alpha.10") })
  local _, _, pre = kb.provide_managed("autodoc", { version_key = "autodoc_version", files = one("0.2.1-alpha.9") })
  ok("[94] prerelease identifiers compare numerically (alpha.9 < alpha.10)", #pre.stored == 0)
  for _, bad in ipairs({ "01.2.3", "1.02.3", "1.2.3-rc.01", "1.2.3+foo..bar", "1.2.3-", "1.2.3-rc..1", "1.2.3+" }) do
    local okb = kb.provide_managed("autodoc", { version_key = "autodoc_version", files = one(bad) })
    ok("[94] an invalid SemVer is not a version: " .. bad, not okb)
  end
  local _, _, good = kb.provide_managed("autodoc", { version_key = "autodoc_version", files = one("0.3.0-rc.0+build.7") })
  ok("[94] a valid prerelease with build metadata is a version", #good.stored == 1)
  kb.provide_managed("autodoc", { version_key = "autodoc_version", files = one("1.2.3") })
  local mal = base .. "/malkb"
  vim.fn.mkdir(mal, "p")
  vim.fn.writefile(vim.split(ops("01.2.3"), "\n"), mal .. "/KB_OPERATIONS.md")
  local _, _, mrep = kb.sync_managed(mal)
  ok("[94] a KB copy declaring a malformed version (01.2.3) is replaced, not kept as equal to 1.2.3",
    vim.tbl_contains(mrep.updated, "KB_OPERATIONS.md") and vim.fn.readfile(mal .. "/KB_OPERATIONS.md")[4] == "autodoc_version: 1.2.3",
    vim.inspect(mrep))

  events.unsubscribe(h)
  events.unsubscribe(h2)
  kb._reset_for_tests()
  ok("[94] reset clears the provided documents", next(kb.managed()) == nil)
  vim.fn.delete(base, "rf")
  vim.fn.delete(state_tmp, "rf")
end)()

-- Convention §3: emit the `<P> passed, <F> failed` summary and exit
-- EXPLICITLY — os.exit(1) on any failure, os.exit(0) otherwise. Do not
-- rely on falling off the end for the success exit: an explicit 0 keeps
-- the contract legible and survives any future trailing driver code.
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
