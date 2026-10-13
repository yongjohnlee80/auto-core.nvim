#!/usr/bin/env bash
# tests/todo-cutover-rehearsal.sh — the cutover rehearsal (design note 2026-10-13
# §7.1) on a COPY of a todo store. It never touches the store it copies.
#
#   REH_STORE=/copy/of/.todo-list            a copy (this script copies it again)
#   REH_OLD=/path/to/auto-core-v0.3.3         the release before the shim
#   AUTOCORE_TEST_AUTODOC(_BIN)               as tests/todo-daemon.sh
#   tests/todo-cutover-rehearsal.sh
#
# Steps: v0.3.3 scans the copy; the candidate's first call claims it (marker, the
# legacy $WORKSPACE refs rewritten, every other file byte- and mtime-identical);
# the counts agree; an assignment is delivered, the Neovim dies before the ack,
# and the same instance resends nothing twice; release refuses writes and the shim
# does not claim again; v0.3.3 writes again and the daemon refuses.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
NEW="$PWD"
: "${REH_STORE:?}" "${REH_OLD:?}" "${AUTOCORE_TEST_AUTODOC:?}" "${AUTOCORE_TEST_AUTODOC_BIN:?}"
export AUTOCORE_TEST_AUTODOC AUTOCORE_TEST_AUTODOC_BIN

R="$(mktemp -d "${TMPDIR:-/tmp}/todo-rehearsal.XXXXXX")"
export REH_ROOT="$R"
stop_daemons() { pkill -f "^$AUTOCORE_TEST_AUTODOC_BIN --serve" 2>/dev/null || true; }
trap 'stop_daemons; rm -rf "$R"' EXIT
mkdir -p "$R/kb" "$R/nvim-plugins" "$R/home" "$R/xdg/config" "$R/xdg/data" "$R/xdg/state" "$R/xdg/cache" "$R/run" "$R/tmp"
chmod 700 "$R/run"
cp -a "$REH_STORE" "$R/kb/.todo-list"
echo "# KB (rehearsal copy)" > "$R/kb/AGENTS.md"
STORE="$R/kb/.todo-list"

# The legacy $WORKSPACE refs in frontmatter lists, recreated under the scratch root.
python3 - "$STORE" "$R/nvim-plugins" > "$R/out-prep.txt" <<'PY'
import os, re, sys
store, root = sys.argv[1], sys.argv[2]
made, files = 0, set()
for d, _, fs in os.walk(store):
    for f in fs:
        if not f.endswith(".md"): continue
        text = open(os.path.join(d, f), encoding="utf-8", errors="replace").read()
        fm = text.split("\n---", 1)[0]
        for m in re.finditer(r'^\s*-\s*"?\$WORKSPACE/([^"\s]+)"?\s*$', fm, re.M):
            p = os.path.join(root, m.group(1))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "a").close(); made += 1
            files.add(os.path.relpath(os.path.join(d, f), store))
print(f"REH legacy_targets={made}")
print(f"REH legacy_files={','.join(sorted(files))}")
PY
sed 's/^/   /' "$R/out-prep.txt"

snapshot() {
  python3 - "$STORE" <<'PY'
import hashlib, os, sys, json
store = sys.argv[1]; out = {}
for d, _, fs in os.walk(store):
    for f in fs:
        p = os.path.join(d, f); st = os.stat(p)
        out[os.path.relpath(p, store)] = [hashlib.sha256(open(p, "rb").read()).hexdigest(), st.st_mtime_ns]
print(json.dumps(out))
PY
}

phase() { # phase <name> <tree>
  echo "── phase $1 ($(basename "$2"))"
  HOME="$R/home" XDG_CONFIG_HOME="$R/xdg/config" XDG_DATA_HOME="$R/xdg/data" XDG_STATE_HOME="$R/xdg/state" \
    XDG_CACHE_HOME="$R/xdg/cache" XDG_RUNTIME_DIR="$R/run" TMPDIR="$R/tmp" REH_AUTOCORE="$2" \
    AUTO_AGENTS_KB_ROOT= AUTO_AGENTS_MAILBOX_ROOT= \
    timeout 300 nvim --headless -u NONE -l "$NEW/tests/todo-cutover-rehearsal.lua" "$1" 2>&1 | tee "$R/out-$1.txt" \
    | grep -E "^(REH|  PASS|  FAIL)|passed, .* failed" | sed 's/^/   /'
}
get() { grep -h "^REH $1=" "$R"/out-*.txt | tail -1 | cut -d= -f2-; }

overall=0
check() { if [ "$2" = 1 ]; then echo "   ✓ $1"; else echo "   ✗ $1"; overall=1; fi; }

before="$(snapshot)"
phase old-scan "$REH_OLD"
after_scan="$(snapshot)"
check "v0.3.3's scan wrote nothing" "$([ "$before" = "$after_scan" ] && echo 1 || echo 0)"

phase claim "$NEW"
after="$(snapshot)"
python3 - "$before" "$after" > "$R/diff.txt" <<'PY'
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
changed = sorted(k for k in a if k in b and a[k][0] != b[k][0])
touched = sorted(k for k in a if k in b and a[k][0] == b[k][0] and a[k][1] != b[k][1])
added = sorted(k for k in b if k not in a)
gone = sorted(k for k in a if k not in b)
print(f"REH files_before={len(a)}"); print(f"REH changed={len(changed)}")
print(f"REH changed_files={','.join(changed)}"); print(f"REH mtime_only={len(touched)}")
print(f"REH added={','.join(added)}"); print(f"REH removed={','.join(gone)}")
PY
sed 's/^/   /' "$R/diff.txt"
cp "$R/diff.txt" "$R/out-diff.txt"
check "exactly the files with legacy \$WORKSPACE refs changed ($(get changed) of $(get files_before))" \
  "$([ "$(get changed_files)" = "$(get legacy_files)" ] && echo 1 || echo 0)"
check "no file changed only its mtime" "$([ "$(get mtime_only)" = 0 ] && echo 1 || echo 0)"
check "the only new file is the marker" "$([ "$(get added)" = ".autodoc-owner" ] && echo 1 || echo 0)"
check "nothing removed" "$([ -z "$(get removed)" ] && echo 1 || echo 0)"
check "task counts agree: v0.3.3 $(get lua_tasks), daemon $(get daemon_tasks); malformed $(get lua_malformed) vs $(get daemon_malformed)" \
  "$([ "$(get lua_tasks)" = "$(get daemon_tasks)" ] && echo 1 || echo 0)"
check "the archive's months hold $(get archive_month_files) files; the daemon read $(get daemon_archived) archived tasks" \
  "$([ "$(get archive_month_files)" -ge "$(get daemon_archived)" ] && echo 1 || echo 0)"

phase assign-crash "$NEW"
phase assign-resume "$NEW"
check "one message at the crash: $(get crash_inbox_ids)" "$([ "$(get crash_inbox_files)" = 1 ] && echo 1 || echo 0)"
check "the same id after the resume, written once: $(get resume_inbox_ids)" \
  "$([ "$(get resume_inbox_files)" = 1 ] && [ "$(get resume_inbox_ids)" = "$(get crash_inbox_ids)" ] && echo 1 || echo 0)"
check "nothing left unacked after the resume" "$([ "$(get unacked_assigns_after_resume)" = 0 ] && echo 1 || echo 0)"

phase release "$NEW"
phase old-write "$REH_OLD"
for f in "$R"/out-*.txt; do
  if grep -q "^  FAIL" "$f"; then echo "   ✗ $(basename "$f"): a phase failed"; overall=1; fi
  grep -qE "[0-9]+ passed, [0-9]+ failed" "$f" || { case "$f" in *diff*|*prep*) ;; *) echo "   ✗ $(basename "$f"): no summary"; overall=1;; esac; }
done
echo "──────────────────────────────────────────────"
[ "$overall" -eq 0 ] && echo "rehearsal: OK" || echo "rehearsal: FAILED"
exit "$overall"
