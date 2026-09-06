-- tests/review-draft.lua — auto-core.review.draft, the domain layer over
-- auto-core.drafts.
--
-- It was auto-finder.views.repos.authoring, which made auto-finder the plugin
-- no other plugin may depend on — the same trap the draft STORE was moved out
-- of in ADR-0081 §2.2. It bit again when worktree.nvim's graph wanted to open a
-- commit for review and had to reach UP into auto-finder, inverting
-- auto-core <- worktree <- auto-finder.
--
-- These assertions are about BEHAVIOUR, not placement: an extraction that
-- compiles but quietly drops a guard is the failure mode worth catching.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({ LAZY .. "/plenary.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.columns, vim.o.lines = 160, 45

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

print("auto-core.review.draft — domain layer over auto-core.drafts")

local A = require("auto-core.review.draft")
require("auto-core.drafts")._reset_for_tests()

local SLUG = "lab__proj"
local SHA = string.rep("a1b2c3d4", 5)   -- 40 hex
ok("module loads", type(A) == "table")
ok("SEVERITIES ladder carried over",
  type(A.SEVERITIES) == "table" and A.SEVERITIES[1] == "must-fix", vim.inspect(A.SEVERITIES))

-- §1 scope: the full-sha contract is the collision guard, not decoration
local oks, scope = pcall(A.scope, SLUG, SHA)
ok("scope built from a full sha", oks and type(scope) == "string" and scope:find(SHA, 1, true) ~= nil, tostring(scope))
-- It refuses by returning nil, not by throwing — verified against the original
-- auto-finder module before asserting, so this pins the real contract rather
-- than the one the doc comment reads like.
ok("scope REFUSES a 7-char abbreviation", A.scope(SLUG, "a1b2c3d") == nil,
  tostring(A.scope(SLUG, "a1b2c3d")))
ok("scope refuses a slug containing @", A.scope("lab@proj", SHA) == nil,
  tostring(A.scope("lab@proj", SHA)))
ok("is_committed_scope accepts the committed form", A.is_committed_scope(scope) == true)
ok("is_working is false for a committed scope", A.is_working(scope) == false)

local wscope = A.scope_working(SLUG, "wt-id-1")
ok("scope_working builds a working scope", type(wscope) == "string", tostring(wscope))
ok("is_working is true for it", A.is_working(wscope) == true, tostring(wscope))
ok("is_committed_scope rejects it", A.is_committed_scope(wscope) == false)

-- §2 the draft round-trip
local d = A.draft(SLUG, SHA)
ok("draft() returns a draft", type(d) == "table")
ok("a fresh draft is not dirty", A.dirty(d) == false)

A.add_finding(d, { path = "a.lua", line = 3, anchored = true,
                   severity = "must-fix", body = "this leaks" })
A.add_finding(d, { anchored = false, severity = "nit", body = "no tests in this module" })
ok("draft is dirty after a finding", A.dirty(d) == true)
ok("anchored() returns only the anchored one", #A.anchored(d) == 1, #A.anchored(d))
ok("unanchored() returns only the unanchored one", #A.unanchored(d) == 1, #A.unanchored(d))
ok("the anchored finding kept its path", A.anchored(d)[1].path == "a.lua")
ok("the unanchored finding has no line", A.unanchored(d)[1].line == nil)

A.set_summary(SLUG, SHA, "two things")
ok("peek() sees the persisted draft", A.peek(SLUG, SHA) ~= nil)
ok("summary round-trips", (A.peek(SLUG, SHA) or {}).summary == "two things",
  (A.peek(SLUG, SHA) or {}).summary)

-- §3 render is pure formatting and must carry both kinds
local md = A.render_markdown({
  draft = A.peek(SLUG, SHA), sha = SHA, revision = 1,
  reviewer = "tester", repo_label = "proj",
})
ok("render_markdown produced text", type(md) == "string" and #md > 0)
ok("render carries the anchored finding", (md or ""):find("this leaks", 1, true) ~= nil)
ok("render carries the UNANCHORED finding too",
  (md or ""):find("no tests in this module", 1, true) ~= nil,
  "an unanchored finding dropped at render is a finding silently lost")
-- The body text and the COUNT are separate properties: a render can print the
-- finding and still say "0 unanchored" in its abstract. Mutating the count to a
-- literal 0 left the grep above green, so it was proving less than it looked.
ok("render's abstract counts BOTH kinds",
  (md or ""):find("1 anchored finding(s), 1 unanchored", 1, true) ~= nil,
  (md or ""):match("%*%*Abstract:%*%*[^\n]*"))

-- §4 discard actually clears
A.discard(SLUG, SHA)
ok("discard clears the draft", A.peek(SLUG, SHA) == nil)

-- §5 identity + helpers survived the move
ok("slugify normalises a name", A.slugify("Lab Proj/One") ~= nil, A.slugify("Lab Proj/One"))
ok("reviewer() answers", type(A.reviewer(vim.loop.cwd())) == "string", A.reviewer(vim.loop.cwd()))
-- worktree_id is pure DELEGATION to auto-core.git.worktree. Asserting a
-- concrete id would pin an environment, not the contract: the underlying
-- function returns nil for a path with no registered worktree identity, and
-- both the original module and this one return exactly that. So the contract
-- worth pinning is "same answer as the surface it delegates to, and nil rather
-- than a throw when that surface is missing".
local gw = require("auto-core.git.worktree")
local here = vim.loop.cwd()
ok("worktree_id delegates verbatim",
  tostring(A.worktree_id(here)) == tostring(gw.worktree_id(here)),
  ("A=%s core=%s"):format(tostring(A.worktree_id(here)), tostring(gw.worktree_id(here))))
local saved = package.loaded["auto-core.git.worktree"]
package.loaded["auto-core.git.worktree"] = { }        -- surface present, function absent
ok("worktree_id returns nil rather than throwing when the surface is missing",
  A.worktree_id(here) == nil)
package.loaded["auto-core.git.worktree"] = saved

-- §5b kb_root is PUBLIC, and the reason is a boundary defect this suite missed
-- on its first pass. `submit` stayed in auto-finder and called `_kb_root()` —
-- a file-local that moved down here with everything else. Locals do not read
-- through the facade's metatable, so the remainder broke while the moved half
-- was, correctly, "complete and self-contained". Auditing one side of a cut
-- does not establish the other side still resolves.
ok("kb_root is public", type(A.kb_root) == "function")
ok("kb_root actually resolves (not a nil upvalue)",
  type(A.kb_root()) == "string" and A.kb_root() ~= "", tostring(A.kb_root()))
-- The first attempt at this wrapper was defined ABOVE `local function
-- _kb_root`, so it closed over a global lookup and returned nil at call time.
-- Asserting the type alone would have passed that.

-- §6 auto-core must NOT have grown a dependency on its own consumers
local before = { worktree = package.loaded["worktree.review"],
                 finder = package.loaded["auto-finder.views.repos.authoring"] }
ok("loading this module pulls in NO worktree.review",  before.worktree == nil)
ok("loading this module pulls in NO auto-finder",      before.finder == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
vim.cmd(fail > 0 and "cq" or "qa!")
