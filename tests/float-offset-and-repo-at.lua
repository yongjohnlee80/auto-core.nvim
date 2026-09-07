-- auto-core — two additive primitives the panel work of 2026-09-08 needs:
--
--   [1] `float.multi` outer.row_offset / col_offset — a deliberate shift off
--       centre, so two same-sized floats are TELLABLE APART when one opens
--       over the other. Every multi-float centred itself at the same
--       percentages, which put the agent edits queue and the git diff view on
--       nearly the same rectangle.
--
--   [2] `git.graph.repo_at` — "which repo am I in", answered without walking a
--       workspace, plus the label derivation `fan_out` already used, now
--       public so a second consumer cannot derive a DIFFERENT name for the
--       same repo than the repos panel shows.
--
-- Run headless:  nvim --headless -u NONE -l tests/float-offset-and-repo-at.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

-- ── [1] float.multi offsets ─────────────────────────────────────────────
--
-- Layout is asserted through `_compute_layout`, which is the function that
-- decides where the window goes; opening a real float and reading its config
-- back would measure nvim's clamping as much as ours.

print("[1] float.multi — outer.row_offset / col_offset")
do
  local multi = require("auto-core.ui.float.multi")

  -- A fixed, generous screen so the arithmetic is checkable by hand rather
  -- than relative to whatever the harness happens to boot with.
  vim.o.columns, vim.o.lines, vim.o.cmdheight = 200, 60, 1

  -- `_compute_layout` is the function that decides where the window goes, so
  -- it is what gets asserted. Reached through a real instance rather than a
  -- hand-built stand-in: a stand-in would be a second implementation of the
  -- class and could drift from it silently.
  local function layout(outer)
    local inst = multi.new({
      name = "offset-probe-" .. tostring(math.random(1e9)),
      outer = outer,
      panes = { middle = {} },
    })
    local lay = inst:_compute_layout()
    pcall(function() inst:dispose() end)
    return lay
  end

  local base = layout({ width_pct = 0.9, height_pct = 0.9 })
  -- 200 * 0.9 = 180 wide, (200-180)/2 = 10;  lines = 60-1-1 = 58,
  -- 58 * 0.9 = 52 high, (58-52)/2 = 3.
  ok("[1] centred baseline is where the arithmetic says",
    base.bg.width == 180 and base.bg.height == 52
      and base.bg.col == 10 and base.bg.row == 3,
    vim.inspect(base.bg))

  local shifted = layout({ width_pct = 0.9, height_pct = 0.9, row_offset = 2, col_offset = 6 })
  ok("[1] *** a positive offset moves the float down and right by exactly that much ***",
    shifted.bg.row == base.bg.row + 2 and shifted.bg.col == base.bg.col + 6,
    ("row %d→%d col %d→%d"):format(base.bg.row, shifted.bg.row, base.bg.col, shifted.bg.col))

  local negative = layout({ width_pct = 0.9, height_pct = 0.9, row_offset = -2, col_offset = -6 })
  ok("[1] *** a negative offset moves it up and left ***",
    negative.bg.row == base.bg.row - 2 and negative.bg.col == base.bg.col - 6,
    ("row=%d col=%d"):format(negative.bg.row, negative.bg.col))

  ok("[1] the size is untouched by an offset (it moves, it does not grow)",
    shifted.bg.width == base.bg.width and shifted.bg.height == base.bg.height
      and negative.bg.width == base.bg.width and negative.bg.height == base.bg.height,
    ("%dx%d / %dx%d"):format(shifted.bg.width, shifted.bg.height,
      negative.bg.width, negative.bg.height))

  -- CLAMPING. An offset is a preference about placement, never a licence to
  -- push the float off screen: the slack around a 0.9-sized float is 20 cols
  -- and 6 rows, so an absurd request must land ON the margin, not past it.
  local far = layout({ width_pct = 0.9, height_pct = 0.9, row_offset = 999, col_offset = 999 })
  ok("[1] *** an over-large positive offset clamps to the margin, not off screen ***",
    far.bg.row == 6 and far.bg.col == 20,
    vim.inspect(far.bg))
  local farneg = layout({ width_pct = 0.9, height_pct = 0.9, row_offset = -999, col_offset = -999 })
  ok("[1] *** an over-large negative offset clamps to 0, never negative ***",
    farneg.bg.row == 0 and farneg.bg.col == 0,
    vim.inspect(farneg.bg))

  -- A full-bleed float has NO slack, so every offset is a no-op there. Without
  -- this cell a clamp written against a hard-coded margin would still pass.
  local full = layout({ width_pct = 1.0, height_pct = 1.0, row_offset = 5, col_offset = 5 })
  ok("[1] a float with no margin cannot be offset at all",
    full.bg.row == 0 and full.bg.col == 0, vim.inspect(full.bg))

  -- Absent / malformed offsets must read exactly like the old behaviour: the
  -- option is additive, and every existing caller passes neither.
  local nofield = layout({ width_pct = 0.9, height_pct = 0.9, row_offset = nil, col_offset = nil })
  local junk = layout({ width_pct = 0.9, height_pct = 0.9, row_offset = "x", col_offset = {} })
  ok("[1] *** omitting the offsets is byte-identical to before (additive) ***",
    nofield.bg.row == base.bg.row and nofield.bg.col == base.bg.col,
    vim.inspect(nofield.bg))
  ok("[1] a non-numeric offset degrades to centred rather than erroring",
    junk.bg.row == base.bg.row and junk.bg.col == base.bg.col, vim.inspect(junk.bg))

  -- Fractional offsets floor rather than producing a non-integer row/col,
  -- which nvim_open_win rejects outright.
  local frac = layout({ width_pct = 0.9, height_pct = 0.9, row_offset = 1.7, col_offset = 2.9 })
  ok("[1] a fractional offset floors to an integer position",
    frac.bg.row == base.bg.row + 1 and frac.bg.col == base.bg.col + 2,
    vim.inspect(frac.bg))
end

-- ── [2] git.graph.repo_at / repo_label ──────────────────────────────────

print("\n[2] git.graph.repo_at — repo identity without a workspace walk")
local sb = vim.fn.tempname() .. "-repoat"
vim.fn.mkdir(sb, "p")
local function git(dir, ...)
  return vim.fn.system({ "git", "-C", dir, "-c", "user.email=t@t",
    "-c", "user.name=t", "-c", "init.defaultBranch=main", ... })
end
do
  local graph = require("auto-core.git.graph")

  ok("[2] repo_at is public", type(graph.repo_at) == "function")
  ok("[2] repo_label is public", type(graph.repo_label) == "function")

  -- A) An ordinary clone: `<project>/.git`, so the project is the dir above.
  local plain = sb .. "/my-project"
  vim.fn.mkdir(plain, "p"); git(plain, "init", "-q")
  vim.fn.writefile({ "x" }, plain .. "/f.txt")
  git(plain, "add", "."); git(plain, "commit", "-q", "-m", "one")

  local r = graph.repo_at(plain, sb)
  ok("[2] *** an ordinary repo resolves to its project folder name ***",
    r ~= nil and r.label == "my-project", r and r.label or "nil")
  ok("[2] *** and to the branch actually checked out ***",
    r ~= nil and r.branch == "main", r and tostring(r.branch) or "nil")
  ok("[2] worktree is the work-tree top, not the git dir",
    r ~= nil and r.worktree == plain, r and r.worktree or "nil")
  ok("[2] an ordinary clone is not bare", r ~= nil and r.is_bare == false)

  -- Resolving from a SUBDIRECTORY must give the same answer: the question is
  -- "which repo", not "which directory".
  local sub = plain .. "/deep/deeper"
  vim.fn.mkdir(sub, "p")
  local r_sub = graph.repo_at(sub, sb)
  ok("[2] *** resolving from a nested subdir gives the same repo ***",
    r_sub ~= nil and r_sub.label == r.label and r_sub.worktree == r.worktree,
    r_sub and (r_sub.label .. " @ " .. r_sub.worktree) or "nil")

  -- A non-default branch, because "main" is the value a broken implementation
  -- falls back to — matching it proves nothing on its own.
  git(plain, "checkout", "-q", "-b", "feat/some-work")
  local r_br = graph.repo_at(plain, sb)
  ok("[2] *** the branch is READ, not defaulted ***",
    r_br ~= nil and r_br.branch == "feat/some-work", r_br and tostring(r_br.branch) or "nil")

  -- A detached HEAD has no branch. Reporting one (e.g. the literal "HEAD")
  -- would read like a branch genuinely called that.
  local sha = vim.trim(vim.fn.system({ "git", "-C", plain, "rev-parse", "HEAD" }))
  git(plain, "checkout", "-q", sha)
  local r_det = graph.repo_at(plain, sb)
  ok("[2] *** a detached HEAD reports branch = nil, not \"HEAD\" ***",
    r_det ~= nil and r_det.branch == nil, r_det and tostring(r_det.branch) or "nil")

  -- B) The bare + linked-worktree layout this workspace actually uses: the
  -- common-dir IS the project folder, and the checkout is a child of it.
  local bare = sb .. "/thing.nvim"
  git(sb, "clone", "-q", "--bare", plain, bare)
  -- `main` already exists in the clone, so check it out rather than
  -- `-b`-creating it (which fails and would leave the cells below asserting
  -- against a worktree that was never made).
  local wt_main = bare .. "/main"
  local wt_add = git(bare, "worktree", "add", "-q", wt_main, "main")
  ok("[2] fixture precondition: the bare repo's worktree exists",
    vim.fn.isdirectory(wt_main) == 1, tostring(wt_add))

  local rb = graph.repo_at(wt_main, sb)
  ok("[2] *** a bare-repo worktree names the REPO, not the checkout dir ***",
    rb ~= nil and rb.label == "thing.nvim", rb and rb.label or "nil")
  ok("[2] and its branch is the worktree's own branch",
    rb ~= nil and rb.branch == "main", rb and tostring(rb.branch) or "nil")
  ok("[2] is_bare reflects the UNDERLYING repo, seen from inside a worktree",
    rb ~= nil and rb.is_bare == true, rb and tostring(rb.is_bare) or "nil")

  local wt_feat = bare .. "/sidework"
  git(bare, "worktree", "add", "-q", "-b", "feat/side", wt_feat)
  local rf = graph.repo_at(wt_feat, sb)
  ok("[2] *** two worktrees of one repo share the repo name and differ by branch ***",
    rf ~= nil and rb ~= nil and rf.label == rb.label and rf.branch == "feat/side",
    rf and (rf.label .. " / " .. tostring(rf.branch)) or "nil")

  -- C) Non-repos and nonsense must answer nil rather than guess.
  local plaindir = sb .. "/not-a-repo"
  vim.fn.mkdir(plaindir, "p")
  ok("[2] *** a plain directory is not a repo ***", graph.repo_at(plaindir, sb) == nil)
  ok("[2] a missing path is not a repo", graph.repo_at(sb .. "/nope/nope", sb) == nil)

  -- A directory carrying an EMPTY `.git/` is the case that fools every
  -- existence check — this workspace root has one — and git still refuses it.
  local fake = sb .. "/fake-repo"
  vim.fn.mkdir(fake .. "/.git", "p")
  ok("[2] *** an empty .git/ container is not a repo either ***",
    graph.repo_at(fake, sb) == nil, vim.inspect(graph.repo_at(fake, sb)))

  -- D) `root` relativisation, and the fact that it is OPTIONAL.
  ok("[2] a repo below root is labelled relative to it",
    graph.repo_label(plain .. "/.git", sb, false, plain) == "my-project")
  ok("[2] a repo OUTSIDE root falls back to a ~-shortened path",
    graph.repo_label("/elsewhere/other/.git", sb, false, "/elsewhere/other")
      == vim.fn.fnamemodify("/elsewhere/other", ":~"),
    graph.repo_label("/elsewhere/other/.git", sb, false, "/elsewhere/other"))
  ok("[2] *** root is optional — nil must not crash or empty the label ***",
    (function()
      local okc, res = pcall(graph.repo_at, plain, nil)
      return okc and res ~= nil and res.label ~= nil and res.label ~= ""
    end)())
  ok("[2] a trailing slash on root does not leak into the label",
    graph.repo_label(plain .. "/.git", sb .. "/", false, plain) == "my-project",
    graph.repo_label(plain .. "/.git", sb .. "/", false, plain))

  -- E) The label is the same one `fan_out` publishes. Two consumers deriving
  -- the name separately is exactly the drift this export exists to prevent,
  -- so the equality is asserted rather than assumed.
  local repos = graph.fan_out(sb, { max_depth = 3 })
  local by_label = {}
  for _, e in ipairs(repos) do by_label[e.label] = e end
  ok("[2] *** repo_at's label matches the one fan_out publishes for that repo ***",
    by_label["thing.nvim"] ~= nil and rb ~= nil and rb.label == "thing.nvim",
    vim.inspect(vim.tbl_keys(by_label)))
end

vim.fn.delete(sb, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
