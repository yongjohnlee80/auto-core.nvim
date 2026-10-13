#!/usr/bin/env bash
# tests/mailbox-wake-ctx-mutants.sh — every arrival fact the wake ctx carries
# must be load-bearing in tests/mailbox-wake-ctx.lua.
#
# Copies the tree, applies ONE mutation, runs the suite, and requires it to
# FAIL. The unmutated copy must pass first (an always-red suite "catches"
# every mutant), and each mutation must match exactly once (a no-op mutant
# would read as killed if the suite were red for another reason).
#
# Run on VM43: bash tests/mailbox-wake-ctx-mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_suite() { (cd "$1" && timeout 120 nvim --headless -u NONE -l tests/mailbox-wake-ctx.lua 2>&1); }

cp -r "$SRC" "$WORK/base"
out="$(run_suite "$WORK/base")"
summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
if [ -z "$summary" ] || [ "${summary##*, }" != "0 failed" ]; then
  echo "BASELINE NOT GREEN: ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
fi
echo "baseline: $summary"

R=lua/auto-core/mailbox/router.lua
T=lua/auto-core/mailbox/transport.lua
# file|name|old|new — literal strings; must occur exactly once in file.
mutants=(
  "$R|sender: ctx names the recipient again (the bug)|    arrival_from       = facts.from,|    arrival_from       = rec.id,"
  "$R|sender: bare id dropped|    arrival_from_bare  = facts.from_bare,|    arrival_from_bare  = nil,"
  "$R|subject dropped|    arrival_subject    = facts.subject,|    arrival_subject    = nil,"
  "$R|subject: JSON null passed through|  f.subject  = nonempty_string(doc.subject)|  f.subject  = doc.subject"
  "$R|inbox: facts not passed|  dispatch_wake(rec, \"inbox\", mid, arrival_facts(\"inbox\", msg, err))|  dispatch_wake(rec, \"inbox\", mid)"
  "$R|responses: facts not passed|  dispatch_wake(rec, \"responses\", cor, facts)|  dispatch_wake(rec, \"responses\", cor)"
  "$R|responses: ok not read|    if type(doc.ok) == \"boolean\" then f.ok = doc.ok end|    f.ok = nil"
  "$R|responses: code not read|    f.code = nonempty_string(doc.code)|    f.code = nil"
  "$R|responses: error not read|      f.error = nonempty_string(e)\n|      f.error = nil\n"
  "$R|read error not reported|  if read_err then f.read_error = tostring(read_err) end|  if false then f.read_error = tostring(read_err) end"
  "$R|log: sender not logged|      arrival_from   = facts.from,\n      arrival_subject = facts.subject,|      arrival_subject = facts.subject,"
  "$R|undeliverable: subject dropped|      reason = \"recipient_unregistered\",\n      path   = src,\n      subject = nonempty_string(msg.subject),|      reason = \"recipient_unregistered\",\n      path   = src,"
  "$R|undeliverable decode_failed: path dropped|        error  = derr,\n        path   = src,|        error  = derr,"
  "$T|envelope: command not stamped (complete)|      command        = envelope_command(original),\n      from           = mailbox_id,\n      completed_at   = original.completed_at,\n    }\n    local rwok, rwerr = atomic_write(response_path, vim.json.encode(envelope))\n    if not rwok then return false, \"complete: response \"|      from           = mailbox_id,\n      completed_at   = original.completed_at,\n    }\n    local rwok, rwerr = atomic_write(response_path, vim.json.encode(envelope))\n    if not rwok then return false, \"complete: response \""
  "$T|envelope: code not stamped (complete)|      code           = response.code,|      code           = nil,"
  "$T|envelope: fail drops command|      code           = type(err_info) == \"table\" and envelope_code(err_info.code) or nil,\n      command        = envelope_command(original),|      code           = type(err_info) == \"table\" and envelope_code(err_info.code) or nil,"
)

killed=0; survived=0; broken=0; i=0
for m in "${mutants[@]}"; do
  file="${m%%|*}"; rest="${m#*|}"
  name="${rest%%|*}"; rest="${rest#*|}"
  old="${rest%%|*}"; new="${rest#*|}"
  i=$((i + 1)); dir="$WORK/m$i"
  cp -r "$SRC" "$dir"
  if ! python3 - "$dir/$file" "$old" "$new" <<'PY'
import sys
p = sys.argv[1]
old = sys.argv[2].replace("\\n", "\n")
new = sys.argv[3].replace("\\n", "\n")
s = open(p).read()
n = s.count(old)
if n != 1:
    print(f"    mutation matched {n} times"); sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  then
    echo "NOT APPLIED  $name"; broken=$((broken + 1)); continue
  fi
  out="$(run_suite "$dir")"
  summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  if [ -n "$summary" ] && [ "${summary##*, }" = "0 failed" ]; then
    echo "SURVIVED     $name"; survived=$((survived + 1))
  else
    echo "KILLED       $name  (${summary:-aborted})"
    printf '%s\n' "$out" | grep -E '^  FAIL' | head -3 | sed 's/^/               /'
    killed=$((killed + 1))
  fi
done
echo "mutants: $killed killed, $survived survived, $broken not applied"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
