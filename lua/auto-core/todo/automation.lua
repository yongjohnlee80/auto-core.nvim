---ADR-0035 Phase 2 — automation engine for `.todo-list/automated/`
---templates. Re-armable per [[0026-auto-finder-state-ui-separation]].
---
---Responsibilities:
---  • Walk `.todo-list/automated/` on a 30s scheduler tick + on every
---    `core.todo.{status,assignee}:changed` event. For each template
---    whose `condition[]` is fully satisfied AND-wise since
---    `last_fired_at`, clone it.
---  • Clone-on-fire: synthesize a new task (`origin: <template-id>`,
---    `tags: [automation:fire, …origin tags]`, no condition/execute)
---    with id `<origin-id>--YYYYMMDDTHHMMSSZ`; lands in `open`.
---  • Execute the template's `execute[]` steps in declared order
---    against the new clone. Auto-core directly handles
---    `assign agent:<name>`, `assign user`, `bash <cmd>`,
---    `bash:<seconds> <cmd>`. Plugin-extended forms route through
---    the hook + executor registry (`assign slot:` and `bash -t=`
---    are registered by `auto-agents` at its setup time).
---  • Trust gate for bash: workspace-scoped state under
---    `auto-core.state.namespace("auto-core.todo.automation")` —
---    `bash_enabled`, `bash_allowlist`, `bash_first_run_acknowledged`.
---    Mailbox cannot bootstrap; first enable must come through the
---    auto-finder user command path (`:AutoFinderTodos automation
---    enable`).
---  • Emit `core.todo.automation:fired` so subscribers (notably
---    `auto-agents.kb_audit` when `$AUTO_AGENTS_KB_ROOT` is set)
---    can persist their own audit lines.
---
---Public API surface mirrors `[[0026-auto-finder-state-ui-separation]]`'s
---`ensure_started` / `stop` pattern so smoke tests can re-arm the
---engine between assertions without process restarts.
---@module 'auto-core.todo.automation'

local M = {}

-- ── lazy/local refs (avoid top-level cycles) ──────────────────────

local function _todo()   return require("auto-core.todo")        end
local function _paths()  return require("auto-core.todo.paths")  end
local function _events() return require("auto-core.events")      end
local function _cron()   return require("auto-core.todo.cron")   end
local function _state()  return require("auto-core.state")       end
local function _log()
  local ok, log = pcall(require, "auto-core.log")
  if ok and log then return log end
  return nil
end

-- ── trust state ───────────────────────────────────────────────────

local STATE_NS = "auto-core.todo.automation"

local function _ns()
  return _state().namespace(STATE_NS, {
    schema = {
      bash_enabled               = { kind = "boolean",  default = false },
      bash_allowlist             = { kind = "any",      default = nil   },
      bash_first_run_acknowledged = { kind = "boolean", default = false },
    },
    persist = "json",
  })
end

---@return { bash_enabled: boolean, bash_allowlist: string[]?, bash_first_run_acknowledged: boolean }
function M.trust_state()
  local ns = _ns()
  return {
    bash_enabled                = ns:get("bash_enabled")    == true,
    bash_allowlist              = ns:get("bash_allowlist"),
    bash_first_run_acknowledged = ns:get("bash_first_run_acknowledged") == true,
  }
end

---Programmatic trust setter. Returns `(ok, err)`. Refuses to flip
---`bash_enabled` to true unless `bash_first_run_acknowledged` is
---already true — interactive enable (`acknowledge_first_run`) must
---land first. Pass `force = true` to skip the gate (used internally
---by the acknowledgement path itself).
---
---ADR §4.5: mailbox callers go through `todos.automation_set` in
---auto-agents, which calls this with `force = false` so a remote
---agent cannot bootstrap bash.
---
---@param opts { bash_enabled: boolean?, bash_allowlist: any?, force: boolean? }
---@return boolean ok, string? err
function M.set_trust(opts)
  opts = opts or {}
  local ns = _ns()

  if opts.bash_enabled ~= nil then
    if opts.bash_enabled == true
        and ns:get("bash_first_run_acknowledged") ~= true
        and opts.force ~= true
    then
      return false, "trust_not_acknowledged"
    end
    ns:set("bash_enabled", opts.bash_enabled == true)
  end

  -- `bash_allowlist` accepts a list of strings or nil to clear.
  if opts.bash_allowlist ~= nil then
    if opts.bash_allowlist == false or opts.bash_allowlist == "" then
      ns:set("bash_allowlist", nil)
    elseif type(opts.bash_allowlist) == "table" then
      for _, pat in ipairs(opts.bash_allowlist) do
        if type(pat) ~= "string" then
          return false, "bash_allowlist entries must be strings"
        end
      end
      ns:set("bash_allowlist", opts.bash_allowlist)
    elseif opts.bash_allowlist == nil then
      ns:set("bash_allowlist", nil)
    else
      return false, "bash_allowlist must be a list of strings or nil"
    end
  end

  return true, nil
end

---Acknowledge the first-run trust prompt. Called by the interactive
---auto-finder user command path. ADR §4.5: this is the ONLY way
---`bash_enabled` ever becomes settable; mailbox cannot reach this.
function M.acknowledge_first_run()
  _ns():set("bash_first_run_acknowledged", true)
end

-- ── hook + executor registry ──────────────────────────────────────

-- Storage shape (Lector F4 amendment, 2026-05-30):
--   _hooks[prefix]     = { resolve = fn(step) → (rewritten_step, err),
--                          validate = fn(step) → err? }   -- validate optional
--   _executors[prefix] = { execute = fn(step, clone, ctx) → (result, err),
--                          validate = fn(step) → err? }   -- validate optional
--
-- `register_*` accepts EITHER a bare function (back-compat with the
-- Phase 2 API; no validator) OR a table `{ resolve|execute = fn,
-- validate = fn }`. The table form lets plugin owners express
-- content validation alongside the handler so refresh-side / live
-- diagnostics catch malformed plugin-owned forms (e.g.
-- `assign slot:abc`, `bash -t=99 echo hi`) instead of waiting for
-- fire time. Pure prefix-match validation (existing behavior) is
-- the fallback when no validator is registered.
local _hooks     = {}
local _executors = {}

---Normalize a `(fn | table)` argument into the canonical registry
---record. `kind` is `"resolve"` or `"execute"` and identifies which
---function field to extract from a table form.
local function _normalize_handler_spec(spec, kind, caller)
  if type(spec) == "function" then
    return { [kind] = spec }
  end
  if type(spec) == "table" then
    if type(spec[kind]) ~= "function" then
      error(caller .. ": table form must provide `" .. kind .. " = fn`")
    end
    if spec.validate ~= nil and type(spec.validate) ~= "function" then
      error(caller .. ": optional `validate` must be a function")
    end
    return { [kind] = spec[kind], validate = spec.validate }
  end
  error(caller .. ": handler must be a function or { " .. kind .. " = fn, validate = fn? }")
end

---Register a rewrite hook. The handler receives the raw step string
---and returns `(rewritten_step, err)`. Auto-core then fires the
---rewritten step through its own primitives. Used for
---`assign slot:<N>` (auto-agents registers this).
---
---ADR-0035 Lector F4: optional `validate` function can be provided
---via the table form `{ resolve = fn, validate = fn }` so refresh-
---side / live diagnostics catch malformed forms at validate time
---instead of waiting for fire time.
---@param prefix string
---@param fn_or_spec fun(step: string): string?, string? | { resolve: fun(string): string?, string?, validate: fun(string): string? }
function M.register_hook(prefix, fn_or_spec)
  if type(prefix) ~= "string" or prefix == "" then
    error("automation.register_hook: prefix must be a non-empty string")
  end
  _hooks[prefix] = _normalize_handler_spec(fn_or_spec, "resolve",
    "automation.register_hook")
end

---Register a plugin-owned executor. The handler receives `(step,
---clone, ctx)` and returns `({ok=bool, message=str?,
---completed_clone=bool?}, err)`. Auto-core does NOT execute the step
---itself; the executor's result IS the step outcome. Used for
---`bash -t=<N> <cmd>` (auto-agents registers this).
---
---Lector F3 amendment: `ctx` carries the bypass flags from
---`M.fire`'s `opts` so the documented host Lua bypass path applies
---uniformly to both built-in `bash` AND plugin-extended forms. The
---third arg is optional in the back-compat 2-arg signature, but
---plugin owners SHOULD declare three to honor ctx-driven bypass.
---
---Lector F4 amendment: optional `validate` function via the table
---form (same shape as register_hook).
---@param prefix string
---@param fn_or_spec fun(step: string, clone: table, ctx: table?): table?, string? | { execute: fun(string, table, table?): table?, string?, validate: fun(string): string? }
function M.register_executor(prefix, fn_or_spec)
  if type(prefix) ~= "string" or prefix == "" then
    error("automation.register_executor: prefix must be a non-empty string")
  end
  _executors[prefix] = _normalize_handler_spec(fn_or_spec, "execute",
    "automation.register_executor")
end

function M.unregister_hook(prefix)     _hooks[prefix]     = nil end
function M.unregister_executor(prefix) _executors[prefix] = nil end

---@return string[] hook_prefixes, string[] executor_prefixes
function M.registry_snapshot()
  local hs, es = {}, {}
  for k, _ in pairs(_hooks)     do hs[#hs + 1] = k end
  for k, _ in pairs(_executors) do es[#es + 1] = k end
  table.sort(hs); table.sort(es)
  return hs, es
end

---Call the resolve function for a registered hook prefix. Lookup
---encapsulated here so the registry's storage shape can evolve
---without scattering knowledge of it across the file.
local function _call_hook_resolve(prefix, step)
  return _hooks[prefix].resolve(step)
end

---Call the execute function for a registered executor prefix.
local function _call_executor_execute(prefix, step, clone, ctx)
  return _executors[prefix].execute(step, clone, ctx)
end

-- ── DSL validation (Phase 2 + Phase 3 share this) ─────────────────

-- Built-in execute prefixes auto-core recognizes directly. The order
-- is "longest prefix first" so `bash:` doesn't shadow `bash ` matching.
local BUILTIN_PREFIXES = {
  "assign agent:",
  "assign user",
  "bash:",
  "bash ",
}

---True iff `step` starts with one of the prefixes recognized by
---auto-core directly. Plugin-extended prefixes (e.g. `assign slot:`,
---`bash -t=`) come from the registry.
---
---**Important**: the `bash ` prefix MUST NOT swallow `bash -t=…` —
---that's a plugin-owned executor form and auto-core has no business
---running `bash -c "-t=N <cmd>"` itself. We gate the prefix match
---explicitly. Mirrors the boundary invariant from ADR-0035 §"Plugin
---boundaries (recap)".
---@param step string
---@return string? prefix
local function _builtin_prefix(step)
  if step:sub(1, 8) == "bash -t=" then return nil end
  for _, p in ipairs(BUILTIN_PREFIXES) do
    if step:sub(1, #p) == p then return p end
  end
  return nil
end

---Longest registered hook prefix matching the step, or nil.
local function _hook_prefix(step)
  local best
  for p, _ in pairs(_hooks) do
    if step:sub(1, #p) == p and (not best or #p > #best) then best = p end
  end
  return best
end

local function _executor_prefix(step)
  local best
  for p, _ in pairs(_executors) do
    if step:sub(1, #p) == p and (not best or #p > #best) then best = p end
  end
  return best
end

---Validate the automation surface of a task. Schema-shape validation
---(every field type-correct, status==automated invariants) is the job
---of `auto-core.todo.schema.validate`; THIS function adds the deeper
---content checks for `condition[]` and `execute[]` that ADR-0035 §8
---wants surfaced as `errors[]` entries on refresh AND as
---`vim.diagnostic` entries in auto-finder (Phase 3).
---
---Returns a list of `errors[]`-shaped entries (possibly empty). Each
---entry: `{ field=<string>, code=<error-code>, message=<string>,
---detected=<UTC ISO>, line=<integer?> }`. `line` is 1-based and points
---into the file when known (Phase 3 buffer-attach populates it; the
---refresh-side call leaves it nil because refresh doesn't have the
---file line offsets at that stage).
---
---Only meaningful for `task.status == "automated"`. Returns an empty
---list for any other status (the schema validator already rejects
---template-only fields on non-automated rows).
---
---@param task table
---@return table[] errors
function M.validate(task)
  local out = {}
  if type(task) ~= "table" or task.status ~= "automated" then return out end

  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")

  -- condition[] — each entry must parse as cron OR `event:<topic>`.
  if type(task.condition) == "table" then
    for i, entry in ipairs(task.condition) do
      if type(entry) ~= "string" or entry == "" then
        out[#out + 1] = {
          field = "condition[" .. i .. "]",
          code  = "automation-condition-malformed",
          message = "condition entries must be non-empty strings; got " .. type(entry),
          detected = now,
        }
      elseif entry:sub(1, 6) == "event:" then
        local topic = entry:sub(7)
        if topic == "" then
          out[#out + 1] = {
            field = "condition[" .. i .. "]",
            code  = "automation-condition-malformed",
            message = "event topic empty: '" .. entry .. "'",
            detected = now,
          }
        end
      else
        local _, perr = _cron().parse(entry)
        if perr then
          out[#out + 1] = {
            field = "condition[" .. i .. "]",
            code  = "automation-condition-malformed",
            message = "not a valid cron or event: " .. perr,
            detected = now,
          }
        end
      end
    end
  end

  -- execute[] — each entry must match a built-in primitive OR a
  -- registered hook prefix OR a registered executor prefix. Lector
  -- F4: when a plugin prefix matches AND that plugin registered a
  -- validator, call it so malformed forms (`assign slot:abc`,
  -- `bash -t=99 echo hi`) fail at validate time instead of fire
  -- time. Plugins without a validator fall back to the prior
  -- "prefix match = trust" behavior.
  if type(task.execute) == "table" then
    for i, step in ipairs(task.execute) do
      if type(step) ~= "string" or step == "" then
        out[#out + 1] = {
          field = "execute[" .. i .. "]",
          code  = "automation-execute-malformed",
          message = "execute entries must be non-empty strings; got " .. type(step),
          detected = now,
        }
      else
        local bp = _builtin_prefix(step)
        local hp = _hook_prefix(step)
        local ep = _executor_prefix(step)
        if hp then
          -- Plugin-owned rewrite prefix matched. Call the
          -- validator if the plugin registered one.
          local vfn = _hooks[hp].validate
          if vfn then
            local verr = vfn(step)
            if verr then
              -- Use a code that points at the plugin family. Auto-
              -- agents' hook for `assign slot:` maps cleanly to
              -- `automation-slot-no-resolver` semantically — the
              -- form is recognized but unusable — but we keep
              -- `automation-execute-malformed` here so the code
              -- specifically signals "the syntax is wrong" vs
              -- "the resolver is missing".
              out[#out + 1] = {
                field = "execute[" .. i .. "]",
                code  = "automation-execute-malformed",
                message = "step '" .. step .. "': " .. tostring(verr),
                detected = now,
              }
            end
          end
        elseif ep then
          local vfn = _executors[ep].validate
          if vfn then
            local verr = vfn(step)
            if verr then
              out[#out + 1] = {
                field = "execute[" .. i .. "]",
                code  = "automation-execute-malformed",
                message = "step '" .. step .. "': " .. tostring(verr),
                detected = now,
              }
            end
          end
        elseif not bp then
          -- Nothing matched. Probe for known plugin prefixes that
          -- aren't currently registered (e.g. `assign slot:` without
          -- auto-agents loaded) so the error message points the
          -- user at the right fix.
          local err_code = "automation-execute-malformed"
          local hint = "no built-in primitive, hook, or executor matches"
          if step:sub(1, 12) == "assign slot:" then
            err_code = "automation-slot-no-resolver"
            hint = "`assign slot:<N>` requires the auto-agents hook (loaded only when auto-agents is active)"
          elseif step:sub(1, 7) == "bash -t" then
            err_code = "automation-bash-t-no-resolver"
            hint = "`bash -t=<N>` requires the auto-agents executor (loaded only when auto-agents is active)"
          end
          out[#out + 1] = {
            field = "execute[" .. i .. "]",
            code  = err_code,
            message = hint .. ": '" .. step .. "'",
            detected = now,
          }
        end
      end
    end
  end

  return out
end

-- ── step execution ────────────────────────────────────────────────

---Parse `assign <target>` step. Returns `(target_string, err)`.
---Target string is the assignee value to pass to `todo.assign()` —
---either `agent:<name>`, the full `agent:<name>:<instance>`, or the
---string `"user"`.
local function _parse_assign(step)
  -- `assign user` — exact match.
  if step == "assign user" then return "user", nil end
  -- `assign agent:<name>` (optionally `:<instance>`).
  local rest = step:match("^assign agent:(.+)$")
  if rest and rest ~= "" then return "agent:" .. rest, nil end
  return nil, "malformed assign step: '" .. step .. "'"
end

---Parse `bash:<sec>` prefix to extract the timeout. Returns
---`(timeout_ms, remainder_string)` or `(nil, nil)` if not a bash:
---form (caller falls back to plain bash).
local function _parse_bash_timeout(step)
  local sec, rest = step:match("^bash:(%d+)%s+(.+)$")
  if not sec then return nil, nil end
  return tonumber(sec) * 1000, rest
end

---Default bash timeout per ADR-0035 OQ2: 1 hour for unattended
---background scripts. Per-step `bash:<sec> <cmd>` overrides.
local DEFAULT_BASH_TIMEOUT_MS = 60 * 60 * 1000

---Check the bash trust gate. Returns `(ok, err_code)`. ADR §4.5.
local function _check_bash_trust(cmd, opts)
  opts = opts or {}
  local ts = M.trust_state()
  if not ts.bash_enabled and not opts.bypass_bash_disabled then
    return false, "automation-bash-disabled"
  end
  if type(ts.bash_allowlist) == "table" and #ts.bash_allowlist > 0
      and not opts.bypass_allowlist
  then
    for _, pat in ipairs(ts.bash_allowlist) do
      if cmd:match(pat) then return true, nil end
    end
    return false, "automation-bash-not-allowlisted"
  end
  return true, nil
end

---Execute a single step. Continuation-passing: the caller MUST
---supply `on_complete(result, err)` — for sync steps the callback
---fires inline before this function returns; for async steps
---(plain `bash` / `bash:<sec>`) the function kicks off the work
---and returns immediately, with the callback invoked later when
---the process exits.
---
---Lector F1 amendment: bash steps no longer call `sys:wait()` — that
---blocked Neovim for up to 1 hour. The async-callback path is
---mandatory now; sync semantics are reserved for assigns, executors
---(which already report delivery success synchronously), and
---hook-rewrites.
---
---Lector F3 amendment: `ctx` (the third arg) is passed through to
---registered executors so plugin-owned forms can honor the host's
---`bypass_bash_disabled` / `bypass_allowlist` flags. Without this,
---only the built-in `bash` primitive saw the bypass, leaving
---`bash -t=` blocked even from the documented host Lua escape
---hatch.
---
---@param step string
---@param clone table
---@param ctx { bypass_bash_disabled: boolean?, bypass_allowlist: boolean?, clone_id: string? }?
---@param on_complete fun(result: table?, err: string?)
local function _execute_step(step, clone, ctx, on_complete)
  ctx = ctx or {}

  -- 1. Rewrite hook first (longest matching prefix).
  local hp = _hook_prefix(step)
  if hp then
    local rewritten, herr = _call_hook_resolve(hp, step)
    if herr then return on_complete(nil, herr) end
    if type(rewritten) ~= "string" or rewritten == "" then
      return on_complete(nil,
        "hook for prefix '" .. hp .. "' returned empty step")
    end
    -- Recurse with the rewritten step. The rewritten step is expected
    -- to match a built-in primitive (e.g. `assign slot:N` rewrites to
    -- `assign agent:<name>`); a hook-resolving-to-another-hook is a
    -- footgun we don't enable.
    step = rewritten
  end

  -- 2. Executor next (longest matching prefix).
  local ep = _executor_prefix(step)
  if ep then
    local res, eerr = _call_executor_execute(ep, step, clone, ctx)
    if eerr then return on_complete(nil, eerr) end
    if type(res) ~= "table" or res.ok ~= true then
      return on_complete(nil,
        "executor for prefix '" .. ep .. "' returned non-ok result")
    end
    return on_complete(res, nil)
  end

  -- 3. Built-in: `assign agent:` / `assign user`. Synchronous.
  if _builtin_prefix(step) == "assign agent:" or step == "assign user" then
    local target, perr = _parse_assign(step)
    if perr then return on_complete(nil, perr) end
    local _, asn_err = _todo().assign(clone.id, target, "ADR-0035 automation")
    if asn_err then return on_complete(nil, asn_err) end
    return on_complete({ ok = true, message = "assigned to " .. target }, nil)
  end

  -- 4 / 5. Built-in bash (`bash:<sec> <cmd>` with explicit timeout
  -- OR plain `bash <cmd>` with the 1h default). Async via
  -- vim.system's callback form — does NOT block Neovim.
  local cmd, timeout_ms
  do
    local sec_ms, rest = _parse_bash_timeout(step)
    if sec_ms then
      cmd, timeout_ms = rest, sec_ms
    elseif _builtin_prefix(step) == "bash " then
      cmd, timeout_ms = step:sub(6), DEFAULT_BASH_TIMEOUT_MS
    end
  end
  if cmd then
    local ok_t, terr = _check_bash_trust(cmd, ctx)
    if not ok_t then return on_complete(nil, terr) end

    -- ADR §5: bash-owned clones bump to `in-progress` BEFORE
    -- launching so the panel reflects "actively running" while the
    -- command is in flight. Only fires when the clone is currently
    -- `open` (assigns earlier in the chain may have already moved
    -- it through M.assign's atomic transition).
    if clone and clone.status == "open" then
      pcall(_todo().status, clone.id, "in-progress")
    end

    -- Async vim.system. The callback runs on libuv's thread; wrap
    -- with vim.schedule so any nvim API calls inside on_complete
    -- run on the main loop.
    vim.system({ "bash", "-c", cmd }, {
      text    = true,
      timeout = timeout_ms,
    }, function(result)
      vim.schedule(function()
        if result.code == 0 then
          on_complete({
            ok               = true,
            message          = "bash exit 0",
            completed_clone  = true,
          }, nil)
        else
          local stderr = result.stderr or ""
          local suffix = stderr ~= "" and (": " .. stderr) or ""
          -- vim.system signals a timeout via `signal == "SIGKILL"`
          -- after the timeout window elapses. Surface as a
          -- recognizable error so the clone's `errors[]` entry is
          -- specific.
          if result.signal and result.signal ~= 0 then
            on_complete(nil, "bash killed by signal "
              .. tostring(result.signal) .. " (timeout?)" .. suffix)
          else
            on_complete(nil, "bash exit " .. tostring(result.code) .. suffix)
          end
        end
      end)
    end)
    return  -- async; on_complete fires later
  end

  on_complete(nil, "no handler matched step: '" .. step .. "'")
end

-- ── managed-field write helper (Lector F2) ────────────────────────

---Internal helper: rewrite ONE managed field on disk. The schema
---validator rejects bypass paths via `todo.update()`, so managed
---fields (`origin`, `last_fired_at`, `errors`) need a direct file
---mutation. Atomic via `<file>.tmp` + os.rename, matching the same
---contract `atomic_write` uses elsewhere.
---
---`task_id` is looked up across the four flat buckets (open,
---in-progress, automated, deferred, completed) — the clone may
---have moved between bucket dirs since fire started. `archived`
---tasks are not supported here (callers don't need this for the
---automation surface).
---@param task_id string
---@param mutate fun(task: table)  -- mutates `task` in place
---@return boolean ok, string? err
local function _write_managed_field(task_id, mutate)
  local paths = _paths()
  local td    = paths.resolve_todo_dir()
  local md    = require("auto-core.todo.md")

  -- Find the live file location. Mirror find_task_path's flat-
  -- bucket scan without importing a private from init.lua.
  local fs_path = require("auto-core.fs.path")
  local file
  for _, bucket in ipairs(paths.FLAT_BUCKETS) do
    local candidate = fs_path.join(td, bucket, task_id .. ".md")
    if fs_path.is_file(candidate) then file = candidate; break end
  end
  if not file then return false, "task '" .. task_id .. "' not found" end

  local f = io.open(file, "r")
  if not f then return false, "open failed: " .. file end
  local txt = f:read("*a"); f:close()
  local dec = md.decode(txt)
  if not (dec and dec.ok and type(dec.value) == "table") then
    return false, "decode failed: " .. tostring(dec and dec.err or "?")
  end
  mutate(dec.value)
  local enc_ok, enc = pcall(md.encode, dec.value)
  if not enc_ok then return false, "encode failed: " .. tostring(enc) end
  local tmp = file .. ".tmp"
  local g = io.open(tmp, "w")
  if not g then return false, "open write failed: " .. tmp end
  g:write(enc); g:close()
  local ok_ren, ren_err = os.rename(tmp, file)
  if not ok_ren then return false, "rename failed: " .. tostring(ren_err) end
  return true, nil
end

-- ── clone-on-fire ─────────────────────────────────────────────────

---Format `<origin>--YYYYMMDDTHHMMSSZ` per ADR-0035 §5 / OQ3.
local function _clone_id(origin_id, ts)
  local t = type(ts) == "table" and ts or os.date("!*t", ts)
  return string.format("%s--%04d%02d%02dT%02d%02d%02dZ",
    origin_id, t.year, t.month, t.day, t.hour, t.min, t.sec)
end

---Build the clone task body — origin body + an "## Automation trace"
---section listing the fired conditions + planned steps. The trace is
---written before any step runs so a mid-step crash still leaves the
---audit trail visible.
local function _compose_clone_body(template, conditions_snapshot)
  local body = tostring(template.description or "")
  if body ~= "" and not body:match("\n$") then body = body .. "\n" end
  body = body .. "\n## Automation trace\n"
  body = body .. "- Fired by: " .. tostring(template.id) .. "\n"
  body = body .. "- Conditions matched:\n"
  for _, c in ipairs(conditions_snapshot or {}) do
    body = body .. "  - `" .. tostring(c) .. "`\n"
  end
  body = body .. "- Execute plan:\n"
  for i, s in ipairs(template.execute or {}) do
    body = body .. "  " .. i .. ". `" .. tostring(s) .. "`\n"
  end
  return body
end

---Manually trigger an automated template, bypassing the scheduler /
---event router. Used for testing, admin debugging, and one-off fires.
---Mailbox surface (`todos.fire`) routes through here from auto-agents.
---
---@param id string  the automated template id
---@param opts { bypass_bash_disabled: boolean?, bypass_allowlist: boolean?, reason: string? }?
---@return { clone_id: string, outcome: string, errors: table[] }? result, string? err
function M.fire(id, opts)
  opts = opts or {}
  local todo = _todo()

  local template, gerr = todo.get(id)
  if not template then return nil, gerr or ("not found: " .. id) end
  if template.status ~= "automated" then
    return nil, "task '" .. id .. "' is status=" .. tostring(template.status)
      .. ", expected 'automated'"
  end

  -- Pre-flight validate. If the template is malformed, refuse to fire.
  local vlist = M.validate(template)
  if #vlist > 0 then
    return nil, "automation-execute-malformed (or condition): "
      .. tostring(vlist[1].message)
  end

  local now_t = os.date("!*t")
  local now_iso = string.format(
    "%04d-%02d-%02dT%02d:%02d:%02dZ",
    now_t.year, now_t.month, now_t.day, now_t.hour, now_t.min, now_t.sec)
  local cid = _clone_id(id, now_t)

  -- Build clone tags: existing template tags + automation:fire marker.
  local clone_tags = { "automation:fire" }
  if type(template.tags) == "table" then
    for _, t in ipairs(template.tags) do clone_tags[#clone_tags + 1] = t end
  end

  -- Snapshot which conditions were active at fire time (used in the
  -- body trace; event-router clears `_events_satisfied` on fire so
  -- we capture before the auto-fire path; M.fire passes nil snapshot
  -- which falls back to the literal condition[] list).
  local snapshot = opts._conditions_snapshot or template.condition or {}

  local description = _compose_clone_body(template, snapshot)

  local clone_id, aerr = todo.add({
    id          = cid,
    title       = string.format("%s (fired %s)",
                    tostring(template.title or "automation"),
                    now_iso),
    description = description,
    tags        = clone_tags,
    -- `origin:` set via direct frontmatter — todo.add doesn't
    -- expose it (it's a managed field). We patch via the
    -- _write_managed_field helper below.
  })
  if aerr or not clone_id then return nil, aerr or "todo.add failed" end

  -- Patch the origin field on the clone (managed). Lector F2: use
  -- the shared managed-field helper.
  _write_managed_field(clone_id, function(task)
    task.origin = id
  end)

  -- ── async step continuation chain ─────────────────────────────
  --
  -- Lector F1: bash steps are async (vim.system callback form).
  -- We can't run the step loop as a flat `for` — once a bash step
  -- kicks off, the remaining steps need to run inside its
  -- callback. Pass a `run_next(idx)` continuation that walks the
  -- step list; bash steps return into the callback, which then
  -- calls run_next(idx + 1).
  --
  -- M.fire returns synchronously after kicking off the chain. For
  -- pure sync templates (only assigns/executors), the entire chain
  -- runs inline before return — outcome reflects the final state.
  -- For templates with bash, M.fire returns with `outcome =
  -- "in_flight"`; the final outcome lands in the
  -- `core.todo.automation:fired` event when the chain completes.

  local execute_steps = template.execute or {}
  local errors        = {}
  local last_completed = false
  local outcome       = "ok"
  -- `finalized` flips inside _finalize. The OUTER M.fire-return
  -- logic uses it to distinguish "chain completed inline" from
  -- "chain is async; on_complete will fire later" — replaces the
  -- pre-detection `async_seen` heuristic from the prior revision,
  -- which got Lector A1 wrong (a step that failed at the trust
  -- gate BEFORE vim.system kicked off would set async_seen via
  -- bash-prefix detection AND finalize sync, then incorrectly
  -- return outcome=in_flight).
  local finalized     = false
  local ctx = {
    bypass_bash_disabled = opts.bypass_bash_disabled == true,
    bypass_allowlist     = opts.bypass_allowlist == true,
    clone_id             = clone_id,
  }

  -- Lector F5: stamp the template's `last_fired_at` BEFORE the
  -- step chain runs, not in _finalize. The scheduler's debounce
  -- gate (`_conditions_satisfied`) checks last_fired_at to suppress
  -- same-minute re-fires; without an early stamp, a long-running
  -- bash template can be re-fired on the 30s tick that lands while
  -- the first command is still executing. Stamp at fire-start
  -- (now_iso, computed above as the canonical "this fire happened
  -- at" timestamp) so the debounce gate is durable from the moment
  -- this fire begins, not from when it finishes.
  _write_managed_field(id, function(task)
    task.last_fired_at = now_iso
    task.updated       = now_iso
  end)

  local function _finalize()
    if finalized then return end
    finalized = true

    -- Lector F2: errors[] are managed; todo.update rejects them.
    -- Persist via the direct managed-field write so the clone
    -- file carries the durable audit trail the panel renders.
    if #errors > 0 then
      _write_managed_field(clone_id, function(task)
        task.errors = errors
      end)
    end

    -- ADR §5 clone-completion lifecycle: only transition to
    -- `completed` when outcome=ok AND the last successful step's
    -- result claimed completed_clone (true only for plain `bash`
    -- exit-0; never for `bash -t=` per A3; never for assigns).
    if outcome == "ok" and last_completed then
      pcall(_todo().status, clone_id, "completed")
    end

    -- Note: template `last_fired_at` was stamped at fire-start
    -- above (Lector F5). No additional write needed here.

    -- Fire event AFTER persistence so subscribers see consistent
    -- on-disk state.
    local ok_ev, events = pcall(_events)
    if ok_ev and events and type(events.publish) == "function" then
      pcall(events.publish, "core.todo.automation:fired", {
        origin_id          = id,
        clone_id           = clone_id,
        fired_at           = now_iso,
        conditions_matched = snapshot,
        execute_steps      = execute_steps,
        outcome            = outcome,
        errors             = errors,
      })
    end

    local log = _log()
    if log and log.info then
      pcall(log.info, "todo.automation",
        string.format("fired %s → %s [%s]", id, clone_id, outcome))
    end
  end

  local function run_next(idx)
    if idx > #execute_steps then
      return _finalize()
    end
    local step = execute_steps[idx]
    -- Re-read clone since the previous step may have mutated state
    -- (assign triggers the auto-transition + bucket move).
    local clone = todo.get(clone_id) or { id = clone_id, status = "open" }

    _execute_step(step, clone, ctx, function(res, sterr)
      if sterr then
        errors[#errors + 1] = {
          field    = "execute[" .. idx .. "]",
          code     = "automation-step-failed",
          message  = "step " .. idx .. " (`" .. step .. "`): " .. sterr,
          detected = now_iso,
        }
        outcome = (idx == 1) and "failed" or "partial"
        return _finalize()
      end
      last_completed = res.completed_clone == true
      run_next(idx + 1)
    end)
  end

  run_next(1)

  -- Lector A1: rather than pre-detecting which step LOOKS async,
  -- observe whether _finalize ran synchronously. If yes, the chain
  -- finalized inline — return the actual outcome. If no, the
  -- chain is mid-flight (some step kicked off vim.system and
  -- registered its callback) — return `in_flight` and let the
  -- async path finalize via the event. This correctly handles
  -- bash-trust-gate failures that abort before vim.system fires.
  if finalized then
    return {
      clone_id = clone_id,
      outcome  = outcome,
      errors   = errors,
    }, nil
  end
  return {
    clone_id = clone_id,
    outcome  = "in_flight",
    errors   = {},  -- not yet finalized
  }, nil
end

-- ── scheduler + event router ──────────────────────────────────────

local _started = false
local _timer   = nil
local _subs    = nil  -- list of subscription handles for clean stop()

-- `_events_satisfied[template_id][topic] = true` — set by the event
-- router; cleared after a successful fire of that template.
local _events_satisfied = {}

-- Mapping from auto-core event payloads to our short topic names.
local STATUS_TO_TOPIC = {
  open      = "new-task",
  completed = "task-completed",
  archived  = "task-archived",
  deferred  = "task-deferred",
}

---List every automated template currently on disk. Read-only.
---@return table[] templates
local function _list_automated()
  local todo = _todo()
  local ok, result = pcall(todo.list, { status = "automated" })
  if not ok or type(result) ~= "table" then return {} end
  return result
end

---Evaluate whether template `t`'s conditions are satisfied right
---now. Returns `(satisfied: bool, matched_snapshot: string[])`.
local function _conditions_satisfied(t, now)
  if type(t.condition) ~= "table" or #t.condition == 0 then
    return false, {}
  end

  local matched = {}
  for _, cond in ipairs(t.condition) do
    if type(cond) ~= "string" or cond == "" then
      return false, {}
    end
    if cond:sub(1, 6) == "event:" then
      local topic = cond:sub(7)
      -- Strip wildcards / parameters for the satisfied check; the
      -- event router stamps the literal topic when it observes.
      -- For v1 we accept exact-match topics only.
      local seen = _events_satisfied[t.id] and _events_satisfied[t.id][topic]
      if not seen then return false, {} end
      matched[#matched + 1] = cond
    else
      -- Cron: must match the current minute AND last_fired_at must
      -- predate the current minute boundary (debounce).
      local ok_match = _cron().matches(_cron().parse(cond) or {}, now)
      if not ok_match then return false, {} end
      -- Debounce: if last_fired_at exists and falls inside the
      -- current minute, the template has already fired this minute.
      if type(t.last_fired_at) == "string" then
        local lf_y, lf_mo, lf_d, lf_h, lf_mn = t.last_fired_at:match(
          "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):")
        if lf_y then
          local now_t = type(now) == "table" and now or os.date("!*t", now)
          if tonumber(lf_y)  == now_t.year
            and tonumber(lf_mo) == now_t.month
            and tonumber(lf_d)  == now_t.day
            and tonumber(lf_h)  == now_t.hour
            and tonumber(lf_mn) == now_t.min
          then
            return false, {}
          end
        end
      end
      matched[#matched + 1] = cond
    end
  end
  return true, matched
end

---Walk every automated template and fire those whose conditions are
---fully satisfied right now. Called by the scheduler tick AND by the
---event router (so event-driven templates fire as soon as the last
---condition lands).
local function _try_fire_all()
  local now_t = os.date("!*t")
  for _, t in ipairs(_list_automated()) do
    local sat, snapshot = _conditions_satisfied(t, now_t)
    if sat then
      local ok, fire_err = pcall(M.fire, t.id, { _conditions_snapshot = snapshot })
      if not ok then
        local log = _log()
        if log and log.warn then
          pcall(log.warn, "todo.automation",
            "fire failed for " .. tostring(t.id) .. ": " .. tostring(fire_err))
        end
      end
      _events_satisfied[t.id] = nil  -- consume the events on fire
    end
  end
end

---Stamp an event topic against every automated template's
---"satisfied since last fire" map. We don't pre-filter to templates
---that listed the topic — that's cheap and lets templates added
---mid-session pick up events the router already observed (rare but
---harmless).
local function _stamp_event(topic)
  for _, t in ipairs(_list_automated()) do
    _events_satisfied[t.id] = _events_satisfied[t.id] or {}
    _events_satisfied[t.id][topic] = true
  end
  _try_fire_all()
end

---Idempotent start. Mounts the scheduler timer (30s) + event-router
---subscriptions. Subsequent calls are no-ops.
function M.start()
  if _started then return end

  _subs = {}
  local events = _events()

  -- status:changed → map to-event topics.
  _subs[#_subs + 1] = events.subscribe("core.todo.status:changed", function(payload)
    local topic = STATUS_TO_TOPIC[payload and payload.to]
    if topic then _stamp_event(topic) end
  end)

  -- assignee:changed → `assign:<bare-agent>` AND wildcard `assign:*`.
  _subs[#_subs + 1] = events.subscribe("core.todo.assignee:changed", function(payload)
    local to = payload and payload.to
    if type(to) == "string" and to ~= "" then
      _stamp_event("assign:*")
      -- Strip the `agent:` prefix for the topic suffix.
      local bare = to:match("^agent:([^:]+)") or to
      if bare and bare ~= "" then
        _stamp_event("assign:" .. bare)
      end
    end
  end)

  -- Scheduler tick — 30s resolution per ADR §6.
  _timer = vim.uv.new_timer()
  _timer:start(30 * 1000, 30 * 1000, vim.schedule_wrap(function()
    pcall(_try_fire_all)
  end))

  _started = true
end

---Idempotent stop. Tears down subscriptions + timer. Used by smoke
---to re-arm between assertions.
function M.stop()
  if not _started then return end
  local events = _events()
  if _subs then
    for _, h in ipairs(_subs) do
      pcall(events.unsubscribe, h)
    end
  end
  _subs = nil
  if _timer then
    pcall(function() _timer:stop(); _timer:close() end)
  end
  _timer = nil
  _events_satisfied = {}
  _started = false
end

---Diagnostic snapshot — what does the engine see right now?
---@return { running: boolean, hooks: string[], executors: string[], events_satisfied: table }
function M.list_pending()
  local hs, es = M.registry_snapshot()
  return {
    running          = _started,
    hooks            = hs,
    executors        = es,
    events_satisfied = vim.deepcopy(_events_satisfied),
  }
end

return M