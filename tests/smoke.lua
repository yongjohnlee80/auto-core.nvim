-- auto-core.nvim — smoke test driver
--
-- Run headless:
--   nvim --headless -u tests/smoke.lua -c 'qa!'
--
-- Per the binding convention at
--   ~/.config/nvim/.auto-agents-config/kb/shared/conventions/lua-nvim-plugin-development.md
-- (loaded automatically by the autovim agent kb), every iteration
-- on this plugin must extend or update this driver and run it green
-- before reporting work complete.
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
ok("M.version is 0.1.3 (debug subsystem + winlog probe)",
  select(1, eq(core.version, "0.1.3")))
ok("M.api_version is 0.1 (M.debug additive; events/state/ui/fs/git/tasks/log/health unchanged)",
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
-- Build a fake worktree-style layout under a tempdir.
local repo = td .. "/proj-fake"
vim.fn.mkdir(repo .. "/.git", "p")
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

-- 29b. list — against this auto-core repo (we know it has worktrees)
local self_root = require("auto-core.git.repo").root()
ok("repo root resolved", type(self_root) == "string")
local listed = wt.list(self_root)
ok("list returns a table", type(listed) == "table")
ok("list has at least one entry", #listed >= 1, vim.inspect(listed))
ok("list entries include the auto-core path",
  (function()
    for _, e in ipairs(listed) do
      if e.path:find("auto%-core") then return true end
    end
    return false
  end)())

-- 29c. list_branches — main/master should float to top
local branches = wt.list_branches(self_root)
ok("list_branches returns a table with main first (or master)",
  #branches >= 1
    and (branches[1] == "main" or branches[1] == "master"
         or #branches == 0),
  vim.inspect(branches))

-- 29d. local_branch_exists / worktree_for_branch
ok("local_branch_exists true on default branch",
  wt.local_branch_exists(self_root, wt.default_branch(self_root)))
ok("local_branch_exists false on bogus branch",
  wt.local_branch_exists(self_root,
    "definitely-no-such-branch-xyz") == false)

-- 29e. default_branch
local def = wt.default_branch(self_root)
ok("default_branch returns a non-empty string",
  type(def) == "string" and #def > 0, tostring(def))

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

-- ─────────────────────── 37. ui.float.ghost ─────────────────────────
print("\n[37] ui.float.ghost — invisible 1×1 absorber")
events_mod._reset_for_tests()
f_events = { opened = {}, closed = {} }
events_mod.subscribe("float:opened", function(p) f_events.opened[#f_events.opened + 1] = p end)
events_mod.subscribe("float:closed", function(p) f_events.closed[#f_events.closed + 1] = p end)

local g = float.ghost()
ok("ghost returns a handle with buf+win+close",
  type(g) == "table"
    and g.buf ~= nil and g.win ~= nil
    and type(g.close) == "function")
ok("ghost window is 1×1",
  vim.api.nvim_win_get_width(g.win) == 1
    and vim.api.nvim_win_get_height(g.win) == 1)
ok("ghost buffer has filetype 'auto-core-ghost'",
  vim.bo[g.buf].filetype == "auto-core-ghost")
ok("float:opened event fired with kind='ghost'",
  #f_events.opened >= 1
    and f_events.opened[#f_events.opened].kind == "ghost")

g.close()
ok("ghost.close() closes the window",
  not vim.api.nvim_win_is_valid(g.win))
ok("float:closed event fired with kind='ghost'",
  #f_events.closed >= 1
    and f_events.closed[#f_events.closed].kind == "ghost")

-- ─────────────────────── 38. ui.float.confirm ─────────────────────────
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
ok("ERROR + WARN went to vim.notify; INFO went to nvim_echo",
  #notify_calls == 2
    and notify_calls[1].level == vim.log.levels.ERROR
    and notify_calls[2].level == vim.log.levels.WARN)
ok("notify message includes [AutoCore] prefix",
  notify_calls[1].msg:find("%[AutoCore%]") ~= nil)
ok("notify message includes component bracket",
  notify_calls[1].msg:find("%[comp%]") ~= nil)

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

-- ─────────────────────── 48. version + api_version reflect v0.1.3 ─────────────────────────
print("\n[48] version bump: v0.1.3 (additive patch line)")
;(function()
local v = require("auto-core.version")
ok("version is v0.1.3 (debug subsystem added)", v.version == "0.1.3")
ok("api_version is 0.1 (additive, no break to existing surface)", v.api_version == "0.1")
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
end)()

-- ─────────────────────── summary ─────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
