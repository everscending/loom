#!/usr/bin/env bash
# P63 detector: the snapshot names the half-finished
#
# Section 21 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- P63 detector: the snapshot names the half-finished --------------------
# The verb above cannot cover a death mid-verdict, or a lane older than it. So
# both stranded shapes are derived: an open MR that closes a ticket sitting
# short of `review`, and a PASS standing at HEAD on a ticket that never reached
# `merge-queue`. Each item carries the one command that repairs it.
RP="$T/repairfx"; mkdir -p "$RP"
cat > "$RP/open.json" <<'EOF'
[
 {"iid":1,"title":"Build 3","project_id":1,"labels":[],"assignees":[],
  "description":"**Selected epics**\n\n- Ledger core (#31)\n"},
 {"iid":31,"title":"Pushed, then died","project_id":1,"labels":["build-3","in-progress"],
  "assignees":[],"description":"## Risk tier\n\napi\n"},
 {"iid":26,"title":"Verdict posted, label not flipped","project_id":1,
  "labels":["build-3","review"],"assignees":[],"description":"## Risk tier\n\napi\n"},
 {"iid":36,"title":"Healthy, queued","project_id":1,"labels":["build-3","merge-queue"],
  "assignees":[],"description":"## Risk tier\n\napi\n"},
 {"iid":10,"title":"An MR that merely mentions another ticket","project_id":1,
  "labels":["build-3","in-progress"],"assignees":[],"description":"## Risk tier\n\napi\n"}
]
EOF
printf '[{"iid":8,"state":"opened","description":"Closes #31","sha":"aaa1111000000000000000000000000000000000"}]\n' > "$RP/mrs-31.json"
printf '[{"iid":5,"state":"opened","description":"Closes #26","sha":"bbb2222000000000000000000000000000000000"}]\n' > "$RP/mrs-26.json"
printf '[{"iid":6,"state":"opened","description":"Closes #36","sha":"ccc3333000000000000000000000000000000000"}]\n' > "$RP/mrs-36.json"
printf '[{"iid":7,"state":"opened","description":"Related to Closes #31 work","sha":"ddd4444000000000000000000000000000000000"}]\n' > "$RP/mrs-10.json"
printf '[{"system":false,"created_at":"2026-08-07T04:00:00Z","body":"green\\n\\n<!-- orch-verdict PASS bbb2222 -->"}]\n' > "$RP/notes-26.json"
printf '[{"system":false,"created_at":"2026-08-07T04:00:00Z","body":"green\\n\\n<!-- orch-verdict PASS ccc3333 -->"}]\n' > "$RP/notes-36.json"
cat > "$RP/glab-stub.sh" <<'EOF'
#!/usr/bin/env bash
FX="$(cd "$(dirname "$0")" && pwd)"
case "$*" in
  *"state=opened"*) cat "$FX/open.json" ;;
  *"related_merge_requests"*) n=$(echo "$*" | sed -n 's#.*issues/\([0-9]*\)/related.*#\1#p')
                    cat "$FX/mrs-$n.json" 2>/dev/null || echo '[]' ;;
  *"/notes"*)       n=$(echo "$*" | sed -n 's#.*issues/\([0-9]*\)/notes.*#\1#p')
                    cat "$FX/notes-$n.json" 2>/dev/null || echo '[]' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$RP/glab-stub.sh"
GLAB_CMD="$RP/glab-stub.sh" "$TICK" snapshot > "$RP/snap.json" 2>"$RP/err"
qr() { jq -r "$1" "$RP/snap.json"; }
if [ "$(qr '[.summary.repairs[] | select(.iid==31)] | length')" = "1" ] \
   && [ "$(qr '.summary.repairs[] | select(.iid==31) | .shape')" = "mr-open-not-in-review" ] \
   && [ "$(qr '.summary.repairs[] | select(.iid==31) | .mr')" = "8" ] \
   && [ "$(qr '.summary.repairs[] | select(.iid==31) | .fix')" = "lane.sh transition 31 review" ] \
   && qr '.warnings[]' | grep -q 'MR !8 is open and closes it'; then
    ok "repairs: an open MR closing an in-progress ticket is named, with its repair command"
else
    bad "repairs: MR-open shape missed ($(qr '.summary.repairs | tostring'), $(head -2 "$RP/err"))"
fi
if [ "$(qr '.summary.repairs[] | select(.iid==26) | .shape')" = "pass-not-in-merge-queue" ] \
   && [ "$(qr '.summary.repairs[] | select(.iid==26) | .fix')" = "lane.sh transition 26 merge-queue" ] \
   && qr '.warnings[]' | grep -q 'the verdict note landed and the label flip did not'; then
    ok "repairs: a PASS standing at HEAD on a non-queued ticket is named, with its repair command"
else
    bad "repairs: PASS shape missed ($(qr '.summary.repairs | tostring'))"
fi
# The failing side of both guards, in one document: #36 carries the SAME open
# MR and the SAME PASS and is correctly in `merge-queue`, and #10's open MR
# mentions another ticket's `Closes` line rather than its own — repairing off
# that MR would relabel a ticket over someone else's branch.
if [ "$(qr '[.summary.repairs[] | select(.iid==36 or .iid==10)] | length')" = "0" ]; then
    ok "repairs: a queued ticket and a mentions-only MR produce no repair item"
else
    bad "repairs: false positive ($(qr '[.summary.repairs[] | select(.iid==36 or .iid==10)] | tostring'))"
fi
# A ticket whose lane is still ALIVE is never flagged: the second write may
# simply not have happened yet. Same live-lane set `summary.stranded` uses.
"$TICK" spawn-lane impl-31 -- sleep 30 >/dev/null
GLAB_CMD="$RP/glab-stub.sh" "$TICK" snapshot > "$RP/snap2.json" 2>/dev/null
if [ "$(jq -r '[.summary.repairs[] | select(.iid==31)] | length' "$RP/snap2.json")" = "0" ] \
   && [ "$(jq -r '[.summary.repairs[] | select(.iid==26)] | length' "$RP/snap2.json")" = "1" ]; then
    ok "repairs: a ticket holding an alive lane is not flagged mid-write"
else
    bad "repairs: live-lane race guard wrong ($(jq -c '.summary.repairs' "$RP/snap2.json"))"
fi
kill "$(cat "$LOOM_HOME/lanes/impl-31.pid" 2>/dev/null)" 2>/dev/null

test_finish
