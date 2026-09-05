---auto-core.ui.edit — open a file in a window that can actually take it.
---
---# Why this exists in auto-core
---
---`auto-core.ui.panel` DELIBERATELY sets `winfixbuf` on panel windows, to stop
---an external `:edit` hijacking a panel. The plugin that makes windows unusable
---for editing owns the sanctioned way to reach a usable one — otherwise every
---consumer re-derives it, badly, and a fix lives on one machine.
---
---The motivating failure, from a mailbox agent:
---
---    nvim --server $NVIM --remote-silent <file>
---    -> E1513: Cannot switch buffer. 'winfixbuf' is enabled
---
---Three separate reasons, each sufficient on its own:
---
---  1. The window an agent's terminal runs in has `winfixbuf` set, and a remote
---     call targets whichever window is CURRENT.
---  2. Focus does not persist between remote calls, so "switch window" then
---     "open file" as two calls lands the second one back in the terminal. It
---     has to be ONE call — hence everything here runs through `nvim_win_call`
---     rather than by moving the cursor.
---  3. Most windows in a live layout are `nofile` panels. In one measured
---     session there were ~50 windows and exactly ONE could take a file.
---
---# TWO interception mechanisms, not one
---
---`buftype == "" and not winfixbuf` is NECESSARY BUT NOT SUFFICIENT. Measured on
---a real panel four ways — plain window, `winfixbuf`, `buftype=nofile`, and both
---— and every SYNTHETIC window splits normally; only the real panel intercepts.
---The panel's interception is its own AUTOCMDS, and the observed behaviour is:
---
---    topleft split <file>   with the panel focused
---    -> wins 2->2, current still the panel, panel buffer CHANGED to the file,
---       ok=true, err=nil
---
---A window is created, the edit into it is refused, the window is unwound, the
---file lands IN THE PANEL, and every step reports success. `vim.cmd("botright
---new")` from a panel behaves the same way — ok=true, no window — which is why
---window creation here goes through `nvim_open_win` rather than an Ex command.
---So this module
---identifies panels STRUCTURALLY, by the `w:auto_core_panel_name` marker
---`Panel:open` stamps, rather than by inferring from window options. And it
---never uses `:edit`: `bufadd` + `bufload` + `nvim_win_set_buf` cannot be
---intercepted by either mechanism.
---
---# Related implementations — do not add a fourth
---
---`Panel:with_unfixed_buf` is an INSTANCE method for consumers mounting INTO a
---panel; different job. auto-finder's vendored neo-tree fork has
---`get_appropriate_window(state, ignore_winfixbuf)`, coupled to neo-tree
---`state` — left alone deliberately, since auto-core must not depend on a
---sibling. auto-finder's own `probe_editable()` in `tests/smoke.lua` is the
---same idea for its suite. This is the sanctioned general one.
---@module 'auto-core.ui.edit'

local log = require("auto-core.log")

local M = {}

local LOG_COMPONENT = "ui.edit"

---Is this window one of auto-core's panels?
---
---By the MARKER, not by options. `Panel:open` stamps
---`w:auto_core_panel_name` on every panel window.
---
---Honest about what this buys TODAY: auto-core's own panels are also `nofile`
---AND `winfixbuf`, so the option tests below already exclude them — mutating
---this function to `return false` reddens only the skipped-count assertion in
---smoke [88], not the "did not use the panel" one. The marker is defence
---against a panel whose OPTIONS do not give it away, which the measured
---interception (autocmds, not options) says is possible, and it is what makes
---the exclusion structural rather than a side effect of how panels happen to
---be configured. It is not currently the only thing excluding a panel, and
---claiming otherwise would be a claim the suite cannot support.
---@param win integer
---@return boolean
local function is_panel(win)
  local ok, name = pcall(vim.api.nvim_win_get_var, win, "auto_core_panel_name")
  return ok and type(name) == "string" and name ~= ""
end

---Can this window take a file buffer?
---
---All four conditions are load-bearing and none subsumes another:
---  * not a panel      — the autocmd interception (see the module comment)
---  * not floating     — a float is somebody's transient UI, not an editor
---  * `buftype == ""`  — a terminal or quickfix window is not for files
---  * not `winfixbuf`  — the E1513 mechanism, which is the one that started this
---@param win integer
---@return boolean
local function can_take_a_file(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if is_panel(win) then return false end
  local cfg = vim.api.nvim_win_get_config(win)
  if cfg and cfg.relative ~= nil and cfg.relative ~= "" then return false end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" then return false end
  local okf, fixed = pcall(function() return vim.wo[win].winfixbuf end)
  if okf and fixed then return false end
  return true
end

---A window that is safe to SPLIT FROM.
---
---Weaker than `can_take_a_file`: the new window is where the file goes, so the
---source only has to be somewhere a bare `:split` is not intercepted. A panel
---is excluded because splitting from one is the measured failure at the top of
---this file.
---@param win integer
---@return boolean
local function can_split_from(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if is_panel(win) then return false end
  local cfg = vim.api.nvim_win_get_config(win)
  if cfg and cfg.relative ~= nil and cfg.relative ~= "" then return false end
  return true
end

---@return integer? win
local function find_usable()
  -- The current window first, when it qualifies: honouring where the user
  -- already is beats moving their file somewhere else.
  local cur = vim.api.nvim_get_current_win()
  if can_take_a_file(cur) then return cur end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if can_take_a_file(w) then return w end
  end
  return nil
end

---Make a window for the file. Q1 ruling (Johno, 2026-09-05): SPLIT rather than
---refuse or take over a panel.
---
---Created with `nvim_open_win`, NOT with an Ex command, and that is the whole
---of the reason this function is more than one line. Measured with the panel as
---the only window:
---
---    vim.cmd("botright new")                      ok=true  wins 1->1  created=NO
---    nvim_open_win(buf, false, {split="below"})   ok=true  wins 1->2  created=yes
---
---The Ex command is intercepted exactly the way `:split <file>` is, and reports
---success while creating nothing. The API call is not. An earlier draft of this
---module used `botright new` for this case and its own assertion caught it —
---which is why the assertion is here rather than a comment saying it cannot
---happen.
---@return integer? win, string? err
local function make_window()
  -- Anchor the split on a non-panel window when one exists, so the new window
  -- lands somewhere sensible in the layout; the panel is an acceptable anchor
  -- when it is all there is, because the API call is not intercepted.
  local anchor
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if can_split_from(w) then anchor = w break end
  end
  anchor = anchor or vim.api.nvim_get_current_win()

  local before = #vim.api.nvim_tabpage_list_wins(0)
  -- A scratch buffer, so the new window never briefly displays somebody
  -- else's buffer — the real one is set below once the window is known good.
  local scratch = vim.api.nvim_create_buf(false, true)
  -- `wipe`, so replacing it below disposes of it. Without this the window
  -- creation leaked one orphan buffer per call on the primary path (and two on
  -- the fallback). (gold-man r0 nit 2.)
  pcall(function() vim.bo[scratch].bufhidden = "wipe" end)
  local ok, win = pcall(vim.api.nvim_open_win, scratch, false,
    { split = "below", win = anchor })

  if not ok or type(win) ~= "number" then
    -- Older Neovim without `split` support in nvim_open_win. Fall back to the
    -- Ex command AND assert it, because this is the path that lies.
    -- `botright new` ENTERS the new window, so the caller's focus has to be
    -- put back by hand. Q2 says focus is not stolen, and this path was
    -- stealing it — measured by stubbing nvim_open_win to fail so the real
    -- fallback ran: primary kept the caller's focus, fallback did not.
    -- (gold-man r0 nit 1.)
    local caller_win = vim.api.nvim_get_current_win()
    local okc, errc = pcall(vim.cmd, "botright new")
    if not okc then
      pcall(vim.api.nvim_set_current_win, caller_win)
      return nil, "could not create a window: " .. tostring(errc)
    end
    local after = vim.api.nvim_tabpage_list_wins(0)
    if #after <= before then
      pcall(vim.api.nvim_set_current_win, caller_win)
      return nil, ("could not create a window: nvim_open_win split is unavailable "
        .. "and `botright new` reported success while creating nothing "
        .. "(%d windows before and after) — that is the panel interception "
        .. "described at the top of ui/edit.lua"):format(before)
    end
    win = vim.api.nvim_get_current_win()
    -- The buffer `new` created is an orphan once the file goes in; wipe it
    -- with the window's buffer rather than leaving it listed.
    pcall(function() vim.bo[vim.api.nvim_win_get_buf(win)].bufhidden = "wipe" end)
    if caller_win ~= win and vim.api.nvim_win_is_valid(caller_win) then
      pcall(vim.api.nvim_set_current_win, caller_win)
    end
  end

  if not vim.api.nvim_win_is_valid(win) then
    return nil, "created a window that is not valid: " .. tostring(win)
  end

  -- A new window inherits winfixbuf from wherever it was split. Scope-local
  -- per ADR-0028: the bare `vim.wo[win].winfixbuf = false` form has `:set`
  -- semantics and mutates the GLOBAL default, which is how the "winfixbuf
  -- propagation" family bug happened — every window created afterwards
  -- started buffer-locked.
  pcall(vim.api.nvim_set_option_value, "winfixbuf", false,
    { win = win, scope = "local" })
  return win, nil
end

---Open `path` in a window that can take it, at an optional position.
---
---# Coordinates are 1-BASED, both of them
---
---Neovim is inconsistent here — `nvim_win_set_cursor` takes a 1-based line and
---a 0-BASED column — and a public API that inherits that inconsistency arrives
---later as an off-by-one bug report. So `line` and `col` are BOTH 1-based here,
---the way a user reads them off a status line or an error message, and the
---conversion happens inside. (Q3, decided 2026-09-05.)
---
---# Focus is NOT stolen by default
---
---An agent moving the cursor while somebody is typing is precisely the hijack
---`winfixbuf` exists to prevent, so `focus` defaults to false: the file is
---opened and positioned, and the caller's window keeps the cursor. Pass
---`focus = true` to jump. (Q2, decided 2026-09-05.)
---
---@param path string       absolute path; a relative one is refused, because an
---                         agent's cwd is not the user's
---@param opts { line: integer?, col: integer?, focus: boolean? }?
---@return { win: integer, buf: integer, path: string, line: integer, col: integer, created_window: boolean, panel_windows_skipped: integer }? result
---@return string? err
function M.open(path, opts)
  opts = opts or {}
  if type(path) ~= "string" or path == "" then
    return nil, "ui.edit.open: path must be a non-empty string"
  end
  if not vim.startswith(path, "/") then
    return nil, "ui.edit.open: path must be ABSOLUTE (got " .. path .. "); an "
      .. "agent's cwd is not the user's, so a relative path would resolve "
      .. "against whichever the host happens to have"
  end
  local line = opts.line
  local col = opts.col
  -- INTEGERS, matching the mailbox schema's `integer` check. These two gates
  -- guard the same contract and the Lua one was the weaker: it accepted 2.5,
  -- `nvim_win_set_cursor` refused it, the pcall ate the error, and the response
  -- reported a line number that cannot exist in any buffer. (gold-man r0 nit 3.)
  local function bad_int(v)
    return type(v) ~= "number" or v < 1 or v % 1 ~= 0
  end
  if line ~= nil and bad_int(line) then
    return nil, "ui.edit.open: line must be a positive INTEGER (1-based), got "
      .. tostring(line)
  end
  if col ~= nil and bad_int(col) then
    return nil, "ui.edit.open: col must be a positive INTEGER (1-BASED here, "
      .. "unlike nvim_win_set_cursor), got " .. tostring(col)
  end

  local skipped = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_panel(w) then skipped = skipped + 1 end
  end

  local win = find_usable()
  local created = false
  if not win then
    local err
    win, err = make_window()
    if not win then return nil, err end
    created = true
  end

  -- NEVER `:edit`. bufadd + bufload + nvim_win_set_buf cannot be intercepted
  -- by winfixbuf (we have already excluded it) or by the panel's autocmds
  -- (we have already excluded panels), and it does not depend on which window
  -- is current — which is the whole problem a remote call has.
  local buf = vim.fn.bufadd(path)
  if buf == 0 then return nil, "ui.edit.open: bufadd failed for " .. path end
  pcall(vim.fn.bufload, buf)
  local okset, seterr = pcall(vim.api.nvim_win_set_buf, win, buf)
  if not okset then
    return nil, ("ui.edit.open: could not put the buffer in window %s: %s")
      :format(tostring(win), tostring(seterr))
  end
  vim.bo[buf].buflisted = true

  -- Position when either coordinate was asked for. `col` alone used to be
  -- validated and then DISCARDED — it had its own type check, its own error
  -- message, and its only use sat inside `if line then`. That is the one
  -- behaviour a caller cannot discover from outside, so col alone is now
  -- honoured against the line the cursor is already on. (gold-man r0 MF2.)
  if line or col then
    local n = vim.api.nvim_buf_line_count(buf)
    local at = vim.api.nvim_win_get_cursor(win)
    -- Clamp rather than error: a stale line number from a moved file should
    -- still show you the file, at its end, rather than refusing.
    local want_line = math.min(line or at[1], n)
    local want_col = (col or (at[2] + 1)) - 1
    pcall(vim.api.nvim_win_set_cursor, win, { want_line, math.max(want_col, 0) })
    -- Centre it in the TARGET window, without moving the caller's cursor.
    pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zz") end)
  end

  -- REPORT THE CURSOR, NEVER THE REQUEST. The response is the only thing a
  -- mailbox caller ever sees — it cannot look at the screen — and this used to
  -- echo `opts` back: four measured rows where the report disagreed with the
  -- window, including a `line = 2.5` that returned a line number no buffer can
  -- have. `panel_windows_skipped` already carries the argument ("an agent that
  -- cannot tell where the file went cannot report it"); it simply was not
  -- applied to the position, which is the part the caller asked for.
  --
  -- Reading it back is also what makes the clamping HONEST, and answers the
  -- open question about it: `line` clamps here and `col` clamps inside nvim, so
  -- a clamp the caller can see needs no defending, while one it cannot see is
  -- indistinguishable from the request having been honoured. (gold-man r0 MF1.)
  local got = vim.api.nvim_win_get_cursor(win)
  local final_line, final_col = got[1], got[2] + 1

  if opts.focus then pcall(vim.api.nvim_set_current_win, win) end

  log.info(LOG_COMPONENT, string.format(
    "opened %s in window %d (buf %d) at %d:%d%s%s",
    path, win, buf, final_line, final_col,
    created and " [created a window]" or "",
    opts.focus and " [focused]" or ""))

  return {
    win = win,
    buf = buf,
    path = path,
    line = final_line,
    col = final_col,
    created_window = created,
    -- Named so a WRONG choice is diagnosable: an agent that cannot tell where
    -- the file went cannot report it, and "50 windows, one usable" is the
    -- condition this module was written for.
    panel_windows_skipped = skipped,
  }, nil
end

-- ── the mailbox verb ────────────────────────────────────────────
--
-- ONE repo, not two. The task this came from assumed a matching change in
-- auto-agents, on the grounds that "agents do not call Lua". They do not — but
-- auto-core owns the whole surface an agent talks to:
--
--   * the REGISTRY lives in auto-core.mailbox.commands
--   * DISPATCH is auto-core.mailbox.router calling commands.handle_message
--   * DISCOVERY is auto-agents' `commands_list`, whose handler is a relay:
--     it calls core.mailbox.commands.list() and forwards the entries, schema
--     included
--
-- So a verb registered here is discovered and dispatched with no auto-agents
-- change at all. Verified end to end before writing this: registered as owner
-- `auto-core`, it appeared in commands.list() with its schema, dispatched
-- through handle_message, and a bad `path` was rejected as `bad_args` BEFORE
-- the handler ran.
--
-- It also removes the risk the task warned about — "if the verb grows its own
-- window logic, that is the third implementation this task exists to prevent".
-- There is no second place for logic to grow.

---Register `editor.open` on auto-core's command registry.
---
---Idempotent by the registry's own contract: re-registering the same
---owner/name replaces the spec, and a DIFFERENT owner is refused.
---@return boolean ok, string? err
function M.register_command()
  local commands = require("auto-core.mailbox.commands")
  return commands.register("editor.open", {
    owner       = "auto-core",
    description = "Open a file in a window that can take a buffer, at an "
      .. "optional 1-based line/col, without stealing focus. Panels and "
      .. "winfixbuf windows are skipped; a split is created when nothing "
      .. "usable exists.",
    -- Declared so `commands_list` tells an agent exactly what to send —
    -- the existing convention is "discover the live surface, don't hardcode",
    -- and a schema is what makes discovery actionable rather than a name list.
    -- `?` marks a field OPTIONAL. Only `path` is required; the first draft
    -- declared all four bare, which made the schema demand `focus` on every
    -- call — and the acceptance cell caught it as `bad_args: missing required
    -- field 'focus'`. A schema is a contract an agent DISCOVERS, so getting
    -- optionality wrong tells every caller to send fields it should not need.
    schema = {
      path  = "string",
      line  = "integer?",
      col   = "integer?",
      focus = "boolean?",
    },
    handler = function(args)
      args = type(args) == "table" and args or {}
      local res, err = M.open(args.path, {
        line  = args.line,
        col   = args.col,
        focus = args.focus,
      })
      if not res then
        return { ok = false, code = "open_failed", error = err }
      end
      -- The window is NAMED in the response. An agent that cannot tell where
      -- the file went cannot report it to the user, and "50 windows, one
      -- usable" is the condition this exists for.
      return { ok = true, result = res }
    end,
  })
end

return M
