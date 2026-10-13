---ADR-0035 Phase 2 — automation engine for `.todo-list/automated/`
---templates. **Removed by ADR 1791532020 (v0.3.4):** the engine never starts,
---`fire` refuses, and nothing here writes a task. What stays until v0.4.0 is the
---DSL validator, the trust shim and the hook registry. The description below is
---the engine as it was.
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

local function _cron()   return require("auto-core.todo.cron")   end
local function _state()  return require("auto-core.state")       end
local function _log()
  local ok, log = pcall(require, "auto-core.log")
  if ok and log then return log end
  return nil
end

-- ── trust state ───────────────────────────────────────────────────
--
-- ADR-0048 §12: the trust model that originated here is promoted to
-- the generic `auto-core.trust` capability store. This module keeps
-- its public trust surface (`trust_state` / `set_trust` /
-- `acknowledge_first_run` — unchanged signatures + error strings per
-- [[auto-core-maintenance]] #1) as a compat shim delegating to
-- capability `todo.bash`, with a one-time lazy migration of any
-- pre-promotion state persisted under the legacy namespace.

local TRUST_CAP = "todo.bash"
local STATE_NS = "auto-core.todo.automation"  -- legacy trust namespace (read-only since ADR-0048)

local function _trust() return require("auto-core.trust") end

local function _legacy_ns()
  return _state().namespace(STATE_NS, {
    schema = {
      bash_enabled               = { kind = "boolean",  default = false },
      bash_allowlist             = { kind = "any",      default = nil   },
      bash_first_run_acknowledged = { kind = "boolean", default = false },
    },
    persist = "json",
  })
end

-- One-time per session: if the trust store has never seen `todo.bash`
-- but the legacy namespace carries non-default values (a workspace
-- that enabled bash before the promotion), seed the capability from
-- them. Legacy values are left in place (harmless; nothing writes
-- them anymore) so a rollback to an older auto-core keeps working.
local _legacy_checked = false
local function _ensure_legacy_migration()
  if _legacy_checked then return end
  _legacy_checked = true
  local trust = _trust()
  if trust.has_state(TRUST_CAP) then return end
  local ns = _legacy_ns()
  local enabled = ns:get("bash_enabled") == true
  local allow   = ns:get("bash_allowlist")
  local acked   = ns:get("bash_first_run_acknowledged") == true
  local has_allow = type(allow) == "table" and #allow > 0
  if not (enabled or acked or has_allow) then return end
  if acked then trust.acknowledge_first_run(TRUST_CAP) end
  -- force=true: this is a local state migration, not a remote enable;
  -- the legacy ack (or its absence) was already enforced when the
  -- legacy value was written.
  trust.set(TRUST_CAP, {
    enabled   = enabled,
    allowlist = has_allow and allow or nil,
    force     = true,
  })
end

---Test-only: re-arm the legacy-migration probe (paired with
---`trust._reset_for_tests()` in smoke fixtures).
function M._reset_trust_migration_for_tests()
  _legacy_checked = false
end

---@return { bash_enabled: boolean, bash_allowlist: string[]?, bash_first_run_acknowledged: boolean }
function M.trust_state()
  _ensure_legacy_migration()
  local s = _trust().state(TRUST_CAP)
  return {
    bash_enabled                = s.enabled,
    bash_allowlist              = s.allowlist,
    bash_first_run_acknowledged = s.first_run_acknowledged,
  }
end

---Programmatic trust setter. Returns `(ok, err)`. Refuses to flip
---`bash_enabled` to true unless `bash_first_run_acknowledged` is
---already true — interactive enable (`acknowledge_first_run`) must
---land first. Pass `force = true` to skip the gate (used internally
---by the acknowledgement path itself).
---
---ADR §4.5: no mailbox verb reaches this (auto-agents' automation
---verbs went with ADR 1791532020), so a remote agent cannot bootstrap
---bash.
---
---@param opts { bash_enabled: boolean?, bash_allowlist: any?, force: boolean? }
---@return boolean ok, string? err
function M.set_trust(opts)
  opts = opts or {}
  _ensure_legacy_migration()

  -- Validate allowlist here (before delegating) so the error strings
  -- this function has always returned stay byte-identical.
  if opts.bash_allowlist ~= nil
      and opts.bash_allowlist ~= false and opts.bash_allowlist ~= ""
  then
    if type(opts.bash_allowlist) == "table" then
      for _, pat in ipairs(opts.bash_allowlist) do
        if type(pat) ~= "string" then
          return false, "bash_allowlist entries must be strings"
        end
      end
    else
      return false, "bash_allowlist must be a list of strings or nil"
    end
  end

  return _trust().set(TRUST_CAP, {
    enabled   = opts.bash_enabled,
    allowlist = opts.bash_allowlist,
    force     = opts.force,
  })
end

---Acknowledge the first-run trust prompt. Called by the interactive
---auto-finder user command path. ADR §4.5: this is the ONLY way
---`bash_enabled` ever becomes settable; mailbox cannot reach this.
function M.acknowledge_first_run()
  _ensure_legacy_migration()
  _trust().acknowledge_first_run(TRUST_CAP)
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

  -- ADR-0035 post-ship UX amendment (2026-05-31): empty-or-missing
  -- condition / execute on an automated template is malformed. The
  -- template can't ever fire (or has nothing to run); flag it so
  -- the user-facing surfaces (refresh-side errors[] + live
  -- vim.diagnostic + fire pre-flight) catch a freshly-promoted
  -- template that wasn't given a scaffold default.
  if type(task.condition) ~= "table" or #task.condition == 0 then
    out[#out + 1] = {
      field = "condition",
      code  = "automation-condition-malformed",
      message = "condition[] is empty or missing — automated templates need at least one cron or event entry to fire",
      detected = now,
    }
  end
  if type(task.execute) ~= "table" or #task.execute == 0 then
    out[#out + 1] = {
      field = "execute",
      code  = "automation-execute-malformed",
      message = "execute[] is empty or missing — automated templates need at least one step to run",
      detected = now,
    }
  end

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

-- ── removed: firing, the scheduler and the managed-field writer ──────
--
-- ADR 1791532020 removes automation: AutoDoc's daemon owns every todo write, and
-- nothing in auto-core may write a task. From v0.3.4 the engine never starts,
-- `fire` refuses, and its direct file writer is gone. The validator, the trust
-- shim and the hook registry stay (they write no task) until v0.4.0 deletes this
-- module with `cron.lua`.

M.REMOVED = "automation was removed (ADR 1791532020)"

local _warned = false
local function _warn_once()
  if _warned then return end
  _warned = true
  local log = _log()
  if log then pcall(log.info, "auto-core.todo.automation", M.REMOVED .. ": the engine does not start") end
end

---Refused: automation was removed. Returns `(nil, err)`.
---@return nil, string
function M.fire(_id, _opts)
  return nil, M.REMOVED
end

---No-op: the engine does not start any more (one log line).
function M.start()
  _warn_once()
end

---No-op: nothing runs.
function M.stop() end

---Diagnostic snapshot: the engine never runs.
---@return { running: boolean, hooks: string[], executors: string[], events_satisfied: table }
function M.list_pending()
  local hs, es = M.registry_snapshot()
  return { running = false, hooks = hs, executors = es, events_satisfied = {} }
end

return M
