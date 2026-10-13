-- tests/mailbox-wake-ctx.lua — the wake hook learns who actually sent the
-- arriving file (KB todo 2026-10-13, "no false check-your-inbox notices").
--
-- Before: dispatch_wake's ctx carried only the mailbox the hook fired for
-- (the RECIPIENT), so every notice in auto-agents named the recipient as the
-- sender. Now the router passes the arriving file's own facts:
--   inbox     → arrival_from / arrival_from_bare / arrival_subject /
--               arrival_msg_kind
--   responses → arrival_ok / arrival_code / arrival_error / arrival_command
--   either    → arrival_read_error when the file is already gone
-- and response envelopes carry `command`, `code` and `from`, so an error
-- notice can name the command that failed.
--
-- Every case drives the REAL router path (outbox → route → inbox → wake;
-- command → executioner → complete → responses → wake), not dispatch_wake
-- directly.
--
-- Run: nvim --headless -u NONE -l tests/mailbox-wake-ctx.lua
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end

-- Headers go through the same stream as ok(): mixing print() with
-- io.stdout:write() interleaves them out of order.
local function section(title) io.stdout:write("\n", title, "\n"); io.stdout:flush() end

section("mailbox wake ctx — arrival facts reach the wake hook")

local mailbox  = require("auto-core.mailbox")
local mb_path  = mailbox.path
local message  = mailbox.message
local commands = mailbox.commands
local router   = mailbox.router
local events_m = require("auto-core.events")
local log      = require("auto-core.log")

vim.env.AUTO_AGENTS_MAILBOX_ROOT = nil
vim.env.AUTO_AGENTS_CONFIG_DIR   = nil
vim.env.AUTO_AGENTS_KB_ROOT      = nil

local root = vim.fn.tempname() .. "-wake-ctx"
vim.fn.mkdir(root, "p")

mailbox._reset_for_tests()
events_m._reset_for_tests()
commands._reset_for_tests()
router._reset_for_tests()
log.clear()
mb_path.configure(root)
mb_path.set_instance_id("1111111111-22222")
-- Hermetic: no fs watchers, no poll timer — scan_now drives every pass.
router.configure({ mode = "poll", poll_interval_ms = false,
                   stale_recover_on_start = false })

-- The wake hook under test: records every (args, ctx) it is handed.
local wakes = {}
commands.register("test_wake", {
  owner = "tests", description = "record wake ctx",
  handler = function(args, ctx)
    wakes[#wakes + 1] = { args = args, ctx = ctx }
    return { ok = true }
  end,
})
local function wake_for(id)
  for _, w in ipairs(wakes) do
    if w.ctx.arrival_id == id then return w end
  end
end

-- Commands the executioner runs on behalf of agent:x.
commands.register("do_ok", {
  owner = "tests", description = "succeeds",
  handler = function() return { ok = true, value = { done = true } } end,
})
commands.register("do_fail", {
  owner = "tests", description = "fails with a code",
  handler = function() return { ok = false, code = "bad_args", error = "slot is required" } end,
})

local x = mailbox.register("agent:x", { root = root, wake = { command = "test_wake", args = { slot = "x" } } })
local y = mailbox.register("agent:y", { root = root, wake = { command = "test_wake", args = { slot = "y" } } })
local nvim = mailbox.register("nvim", { root = root })
router.start()

local function drop_in_outbox(rec, msg)
  local tmp = rec.subs.outbox .. "/.tmp-" .. msg.id
  vim.fn.writefile({ vim.json.encode(msg) }, tmp)
  vim.uv.fs_rename(tmp, rec.subs.outbox .. "/" .. msg.id .. ".json")
end

-- ── 1. inbox: the wake names the SENDER and the subject ─────────────
section("[1] inbox arrival: arrival_from is the message's from, not the recipient")
local m1 = message.build({ from = x.id, to = "agent:y", subject = "Ready for review",
                            body = "PR #12" })
drop_in_outbox(x, m1)
router.scan_now()
local w1 = wake_for(m1.id)
ok("wake fired for y's arrival", w1 ~= nil and w1.args.slot == "y", vim.inspect(wakes))
ok("ctx.mailbox is still the recipient (unchanged contract)",
  w1 and w1.ctx.mailbox == "agent:y", w1 and w1.ctx.mailbox)
ok("ctx.arrival_from is the sender's full id",
  w1 and w1.ctx.arrival_from == x.id, w1 and tostring(w1.ctx.arrival_from))
ok("ctx.arrival_from_bare is the sender's bare id",
  w1 and w1.ctx.arrival_from_bare == "agent:x", w1 and tostring(w1.ctx.arrival_from_bare))
ok("ctx.arrival_subject is the message subject",
  w1 and w1.ctx.arrival_subject == "Ready for review", w1 and tostring(w1.ctx.arrival_subject))
ok("ctx.arrival_msg_kind is the message kind",
  w1 and w1.ctx.arrival_msg_kind == "message", w1 and tostring(w1.ctx.arrival_msg_kind))
ok("ctx.arrival_path points at the file in y's inbox",
  w1 and w1.ctx.arrival_path == y.subs.inbox .. "/" .. m1.id .. ".json",
  w1 and tostring(w1.ctx.arrival_path))
ok("inbox arrival carries no response outcome",
  w1 and w1.ctx.arrival_ok == nil and w1.ctx.arrival_error == nil)

-- A message with no subject: the field is absent, not "" or vim.NIL.
local m1b = message.build({ from = x.id, to = "agent:y", body = "no subject" })
drop_in_outbox(x, m1b)
router.scan_now()
local w1b = wake_for(m1b.id)
ok("a subject-less message leaves arrival_subject nil (JSON null is not a subject)",
  w1b and w1b.ctx.arrival_subject == nil and w1b.ctx.arrival_from == x.id,
  w1b and vim.inspect(w1b.ctx.arrival_subject))

-- The router's own log carries the sender, so a suppressed notice
-- downstream still leaves a trace naming who sent what.
local logged
for _, e in ipairs(log.recent(500)) do
  if e.event_type == "auto-core.mailbox.router.wake_dispatched"
      and e.fields and e.fields.arrival_id == m1.id then logged = e end
end
ok("wake_dispatched log entry names the sender and subject",
  logged and logged.fields.arrival_from == x.id
    and logged.fields.arrival_subject == "Ready for review",
  logged and vim.inspect(logged.fields))

-- ── 2. responses: outcome + command reach the wake ──────────────────
section("[2] response arrival: arrival_ok / code / error / command")
local function send_command(cmd)
  local c = message.build({ kind = "command", from = x.id, to = nvim.id, command = cmd,
                            correlation_id = "cor-" .. cmd })
  drop_in_outbox(x, c)
  router.scan_now()   -- route to nvim; the executioner runs + completes
  router.scan_now()   -- pick up x's response
  return c
end

send_command("do_ok")
local w_ok = wake_for("cor-do_ok")
ok("wake fired for the ok response", w_ok ~= nil and w_ok.ctx.arrival_kind == "responses",
  vim.inspect(wakes))
ok("ok response: arrival_ok == true", w_ok and w_ok.ctx.arrival_ok == true,
  w_ok and tostring(w_ok.ctx.arrival_ok))
ok("ok response: arrival_command names the command", w_ok and w_ok.ctx.arrival_command == "do_ok",
  w_ok and tostring(w_ok.ctx.arrival_command))
ok("ok response: no error, no code",
  w_ok and w_ok.ctx.arrival_error == nil and w_ok.ctx.arrival_code == nil)

send_command("do_fail")
local w_bad = wake_for("cor-do_fail")
ok("error response: arrival_ok == false", w_bad and w_bad.ctx.arrival_ok == false,
  w_bad and tostring(w_bad.ctx.arrival_ok))
ok("error response: arrival_code carried", w_bad and w_bad.ctx.arrival_code == "bad_args",
  w_bad and tostring(w_bad.ctx.arrival_code))
ok("error response: arrival_error carried", w_bad and w_bad.ctx.arrival_error == "slot is required",
  w_bad and tostring(w_bad.ctx.arrival_error))
ok("error response: arrival_command names the failed command",
  w_bad and w_bad.ctx.arrival_command == "do_fail", w_bad and tostring(w_bad.ctx.arrival_command))

-- The envelope on disk carries the new fields (the bootstrap doc always
-- promised `code`; it was never written).
local env = vim.json.decode(table.concat(vim.fn.readfile(x.subs.responses .. "/cor-do_fail.json"), "\n"))
ok("envelope on disk: code, command, from stamped",
  env.code == "bad_args" and env.command == "do_fail" and env.from == nvim.id,
  vim.inspect(env))

-- An unknown command is refused by the registry; the refusal is a
-- response error the wake can name.
send_command("no_such_command")
local w_unk = wake_for("cor-no_such_command")
ok("refused (unknown) command: arrival_ok false, code unknown_command, command named",
  w_unk and w_unk.ctx.arrival_ok == false and w_unk.ctx.arrival_code == "unknown_command"
    and w_unk.ctx.arrival_command == "no_such_command",
  w_unk and vim.inspect({ ok = w_unk.ctx.arrival_ok, code = w_unk.ctx.arrival_code,
                          cmd = w_unk.ctx.arrival_command }))

-- transport.fail writes the same shape.
local fc = message.build({ kind = "command", from = x.id, to = nvim.id, command = "do_ok",
                           correlation_id = "cor-failed-by-hand" })
vim.fn.writefile({ vim.json.encode(fc) }, nvim.subs.inbox .. "/" .. fc.id .. ".json")
mailbox.claim(nvim.id, fc.id)
mailbox.fail(nvim.id, fc.id, { error = "host gave up", code = "gave_up" }, { response = true })
local fenv = vim.json.decode(table.concat(vim.fn.readfile(x.subs.responses .. "/cor-failed-by-hand.json"), "\n"))
ok("transport.fail envelope: command + code + from",
  fenv.ok == false and fenv.command == "do_ok" and fenv.code == "gave_up" and fenv.from == nvim.id,
  vim.inspect(fenv))

-- ── 3. a response consumed before the router saw it ─────────────────
section("[3] response already archived: the wake says so instead of guessing")
local gone = x.subs.responses .. "/cor-gone.json"
vim.fn.writefile({ vim.json.encode({ ok = true, correlation_id = "cor-gone" }) }, gone)
-- Simulate the agent reading + archiving it between the fs_event and the
-- router's read: the seen-set has not seen it, the file is gone.
local real_read = mailbox.transport.read_from
mailbox.transport.read_from = function(id, sub, mid)
  if sub == "responses" and mid == "cor-gone" then os.remove(gone) end
  return real_read(id, sub, mid)
end
router.scan_now()
mailbox.transport.read_from = real_read
local w_gone = wake_for("cor-gone")
ok("wake still dispatched (the hook decides)", w_gone ~= nil, vim.inspect(wakes))
ok("arrival_read_error set, arrival_ok nil",
  w_gone and type(w_gone.ctx.arrival_read_error) == "string" and w_gone.ctx.arrival_ok == nil,
  w_gone and vim.inspect({ re = w_gone.ctx.arrival_read_error, ok = w_gone.ctx.arrival_ok }))

-- ── 4. undeliverable: the event names the subject and the path ───────
section("[4] outbox_undeliverable carries the subject and path")
local undeliv = {}
events_m.subscribe("core.mailbox:outbox_undeliverable", function(p) undeliv[#undeliv + 1] = p end)
local m4 = message.build({ from = x.id, to = "agent:nobody", subject = "Hello?" })
drop_in_outbox(x, m4)
router.scan_now()
local u4
for _, p in ipairs(undeliv) do if p.id == m4.id then u4 = p end end
ok("recipient_unregistered payload: subject + path",
  u4 and u4.reason == "recipient_unregistered" and u4.subject == "Hello?"
    and u4.path == x.subs.outbox .. "/" .. m4.id .. ".json",
  vim.inspect(u4))
os.remove(x.subs.outbox .. "/" .. m4.id .. ".json")

local bad_id = message.new_id()
vim.fn.writefile({ "{ not json" }, x.subs.outbox .. "/" .. bad_id .. ".json")
router.scan_now()
local u5
for _, p in ipairs(undeliv) do if p.id == bad_id then u5 = p end end
ok("decode_failed payload now carries the path",
  u5 and u5.reason == "decode_failed" and u5.path == x.subs.outbox .. "/" .. bad_id .. ".json",
  vim.inspect(u5))
os.remove(x.subs.outbox .. "/" .. bad_id .. ".json")

router.stop()
vim.fn.delete(root, "rf")

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
io.stdout:flush()
os.exit(fail == 0 and 0 or 1)
