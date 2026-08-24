---Shared highlight-group registry for the AutoVim family.
---
---Phase 6 per ADR 0006 + auto-core-todos. Provides:
---
---  M.ensure()                       -- register all defaults (idempotent)
---  M.theme_override(name, attrs)    -- runtime override entrypoint
---  M.list()                         -- inspect registered groups
---
---**Default-link semantics.** Every group is registered with
---`{ link = "<existing-nvim-group>", default = true }`. The
---`default = true` flag means the assignment is a no-op if the user
---(or a colorscheme) has already set the group. Consumers can also
---call `theme_override` to swap a link for explicit attrs (fg/bg/
---bold/italic/etc) at runtime; that bypasses `default = true` so it
---takes precedence over scheme-loaded values.
---
---Group catalog:
---  AutoCoreSectionActive  -- the active tab in a panel winbar tab strip
---  AutoCoreSectionInactive -- inactive tabs
---  AutoCorePanelTitle     -- panel-level winbar title text
---  AutoCoreFloatNormal    -- normal text in a help overlay / confirm
---  AutoCoreFloatBorder    -- border around floats
---  AutoCoreFloatTitle     -- centered title on a float (when set)
---  AutoCoreDimmed         -- de-emphasized inline text
---  AutoCoreHelpKey        -- the "<key>" column in help overlays
---  AutoCoreHelpDesc       -- the description column in help overlays
---  AutoCoreGridHeader     -- the column-title row of a result grid
---  AutoCoreDiff*          -- Add/Delete/Change/Context/Header/Hunk (ADR-0060)
---  AutoCoreGit*           -- Added/Modified/Deleted/Renamed/Untracked/
---                            Conflicted: per-file status in the repos tree
---  AutoCoreReview*        -- Frame/Body/MustFix/ShouldFix/Nit/Question/
---                            Resolved: inline review annotations
---
---Future groups can be added to DEFAULTS without breaking consumers
---— `ensure()` is forward-compatible.
---@module 'auto-core.ui.highlights'

local M = {}

---@type table<string, vim.api.keyset.highlight>
local DEFAULTS = {
  AutoCoreSectionActive   = { link = "Title",       default = true },
  AutoCoreSectionInactive = { link = "Comment",     default = true },
  AutoCorePanelTitle      = { link = "Title",       default = true },
  AutoCoreFloatNormal     = { link = "NormalFloat", default = true },
  AutoCoreFloatBorder     = { link = "FloatBorder", default = true },
  AutoCoreFloatTitle      = { link = "FloatTitle",  default = true },
  AutoCoreDimmed          = { link = "Comment",     default = true },
  AutoCoreHelpKey         = { link = "Special",     default = true },
  AutoCoreHelpDesc        = { link = "Comment",     default = true },
  AutoCoreGridHeader      = { link = "Title",       default = true },
  -- ADR-0060: the diff view. Linked to the built-in Diff* groups so every
  -- colourscheme already themes them; `theme_override` still wins.
  AutoCoreDiffAdd         = { link = "DiffAdd",     default = true },
  AutoCoreDiffDelete      = { link = "DiffDelete",  default = true },
  AutoCoreDiffChange      = { link = "DiffChange",  default = true },
  AutoCoreDiffContext     = { link = "Normal",      default = true },
  AutoCoreDiffHeader      = { link = "Title",       default = true },
  AutoCoreDiffHunk        = { link = "Special",     default = true },
  -- ADR-0060 §2.2: the repos tree's per-file status colours. Johno's scheme is
  -- deleted RED, modified GREEN, added GREEN with a `+` marker -- so added and
  -- modified deliberately SHARE the green and the marker distinguishes them.
  AutoCoreGitAdded        = { link = "DiffAdd",     default = true },
  AutoCoreGitModified     = { link = "DiffAdd",     default = true },
  AutoCoreGitDeleted      = { link = "DiffDelete",  default = true },
  AutoCoreGitRenamed      = { link = "DiffChange",  default = true },
  AutoCoreGitUntracked    = { link = "DiffAdd",     default = true },
  AutoCoreGitConflicted   = { link = "ErrorMsg",    default = true },
  -- ADR-0060 §2.6: inline review annotations rendered as virt_lines.
  AutoCoreReviewFrame     = { link = "Comment",     default = true },
  AutoCoreReviewBody      = { link = "NormalFloat", default = true },
  AutoCoreReviewMustFix   = { link = "DiagnosticError", default = true },
  AutoCoreReviewShouldFix = { link = "DiagnosticWarn",  default = true },
  AutoCoreReviewNit       = { link = "DiagnosticHint",  default = true },
  AutoCoreReviewQuestion  = { link = "DiagnosticInfo",  default = true },
  AutoCoreReviewResolved  = { link = "Comment",     default = true },
}

-- Background-only diff groups (ADR-0065 §2.9).
--
-- They are NOT in DEFAULTS, because they are DERIVED from whatever
-- `DiffAdd`/`DiffDelete` the active colorscheme provides rather than linked to
-- it. A link would inherit the theme's FOREGROUND too, and a `line_hl_group`
-- carrying a foreground competes directly with treesitter's — which is the
-- whole reason the diff panes could not be highlighted before.
local DERIVED_BG = {
  AutoCoreDiffAddBg    = "DiffAdd",
  AutoCoreDiffDeleteBg = "DiffDelete",
}

-- Used when the theme's DiffAdd/DiffDelete carries no `bg` at all — some
-- minimal and monochrome schemes define only a foreground. Painting an
-- attribute-less group would be an invisible no-op that reads as "the diff
-- colouring broke", so we supply our own, chosen to be legible on both a dark
-- and a light background.
local FALLBACK_BG = {
  AutoCoreDiffAddBg    = { dark = "#20303b", light = "#d7f0dd" },
  AutoCoreDiffDeleteBg = { dark = "#3b2028", light = "#f7d9de" },
}

---derive_bg_groups recomputes the background-only diff groups from the ACTIVE
---colorscheme. Idempotent, and safe to call on every `ColorScheme`.
---
---`link = false` is load-bearing: `nvim_get_hl` DEFAULTS to returning
---`{ link = "DiffAdd" }` with no attributes at all, and `AutoCoreDiffAdd` is
---itself a link — so the obvious call would silently yield an empty background
---and simply look unstyled. That failure would not have raised anything.
---
---A group claimed by `theme_override` is skipped: that API exists precisely to
---beat colorscheme defaults, so re-deriving over it would undo the one thing it
---promises.
function M.derive_bg_groups()
  for name, source in pairs(DERIVED_BG) do
    if not M._overridden[name] then
      local bg
      local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = source, link = false })
      if ok and type(hl) == "table" then bg = hl.bg end
      if not bg then
        local fb = FALLBACK_BG[name]
        bg = (vim.o.background == "light") and fb.light or fb.dark
      end
      -- No `fg`, deliberately: a line highlight that carries no foreground
      -- cannot compete with treesitter's, whatever the theme does.
      pcall(vim.api.nvim_set_hl, 0, name, { bg = bg })
    end
  end
end

-- Groups an explicit `theme_override` has claimed.
M._overridden = {}

local _ensured = false

---Register every default group. Idempotent — safe to call from
---multiple subsystems on every panel open. The `default = true`
---attribute makes each call a no-op when a colorscheme has
---already defined the group.
function M.ensure()
  if _ensured then return end
  for name, spec in pairs(DEFAULTS) do
    pcall(vim.api.nvim_set_hl, 0, name, vim.deepcopy(spec))
  end
  M.derive_bg_groups()

  -- `ensure()` is once-only, so a background copied out of the theme would go
  -- stale the moment the user runs `:colorscheme`. Re-derive on the event.
  --
  -- Only the DERIVED groups are recomputed. An explicit `theme_override` is a
  -- deliberate user/consumer choice and must survive a theme switch — that API
  -- exists precisely to beat colorscheme defaults, so clobbering it here would
  -- undo the one thing it promises.
  pcall(vim.api.nvim_create_autocmd, "ColorScheme", {
    group = vim.api.nvim_create_augroup("AutoCoreDerivedHighlights", { clear = true }),
    callback = function() M.derive_bg_groups() end,
  })
  _ensured = true
end

---Override a registered (or new) highlight group at runtime.
---`attrs` accepts any nvim_set_hl spec (link, fg, bg, bold,
---italic, underline, etc.). Bypasses `default = true` so this
---wins over colorscheme defaults.
---@param name  string
---@param attrs vim.api.keyset.highlight
function M.theme_override(name, attrs)
  assert(type(name) == "string" and #name > 0,
    "auto-core.ui.highlights.theme_override: name required")
  assert(type(attrs) == "table",
    "auto-core.ui.highlights.theme_override: attrs table required")
  -- Drop `default` — explicit overrides should always take effect.
  local spec = vim.deepcopy(attrs)
  spec.default = nil
  -- Remembered so the ColorScheme re-derivation leaves it alone.
  M._overridden[name] = true
  pcall(vim.api.nvim_set_hl, 0, name, spec)
end

---Snapshot of every group name currently in the canonical
---registry. Order is alphabetical for stable output.
---@return string[]
function M.list()
  local out = {}
  for name in pairs(DEFAULTS) do out[#out + 1] = name end
  table.sort(out)
  return out
end

---Test-only — clears the ensure-once memo so tests can re-exercise
---the registration path.
function M._reset_for_tests()
  M._overridden = {}
  _ensured = false
end

M.DEFAULTS = DEFAULTS

return M
