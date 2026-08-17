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
  "labels":["build-3","in-progress"],"assignees":[],"description":"## Risk tier\n\napi\n"},
 {"iid":57,"title":"Rejected by its gate, awaiting round 2","project_id":1,
  "labels":["build-3","in-progress"],"assignees":[],"description":"## Risk tier\n\napi\n"},
 {"iid":58,"title":"Rejected, then requeued by a human","project_id":1,
  "labels":["build-3","ready-for-agent"],"assignees":[],"description":"## Risk tier\n\napi\n"}
]
EOF
printf '[{"iid":8,"state":"opened","description":"Closes #31","sha":"aaa1111000000000000000000000000000000000"}]\n' > "$RP/mrs-31.json"
printf '[{"iid":5,"state":"opened","description":"Closes #26","sha":"bbb2222000000000000000000000000000000000"}]\n' > "$RP/mrs-26.json"
printf '[{"iid":6,"state":"opened","description":"Closes #36","sha":"ccc3333000000000000000000000000000000000"}]\n' > "$RP/mrs-36.json"
printf '[{"iid":7,"state":"opened","description":"Related to Closes #31 work","sha":"ddd4444000000000000000000000000000000000"}]\n' > "$RP/mrs-10.json"
printf '[{"system":false,"created_at":"2026-08-07T04:00:00Z","body":"green\\n\\n<!-- orch-verdict PASS bbb2222 -->"}]\n' > "$RP/notes-26.json"
printf '[{"system":false,"created_at":"2026-08-07T04:00:00Z","body":"green\\n\\n<!-- orch-verdict PASS ccc3333 -->"}]\n' > "$RP/notes-36.json"
printf '[{"iid":9,"state":"opened","description":"Closes #57","sha":"eee5555000000000000000000000000000000000"}]\n' > "$RP/mrs-57.json"
printf '[{"iid":11,"state":"opened","description":"Closes #58","sha":"fff6666000000000000000000000000000000000"}]\n' > "$RP/mrs-58.json"
printf '[{"system":false,"created_at":"2026-08-07T04:00:00Z","body":"rejected\\n\\n<!-- orch-verdict FAIL eee5555 -->"}]\n' > "$RP/notes-57.json"
printf '[{"system":false,"created_at":"2026-08-07T04:00:00Z","body":"rejected\\n\\n<!-- orch-verdict FAIL fff6666 -->"}]\n' > "$RP/notes-58.json"
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
if [ "$(qr '[.summary.repairs[] | select(.id==31)] | length')" = "1" ] \
   && [ "$(qr '.summary.repairs[] | select(.id==31) | .shape')" = "mr-open-not-in-review" ] \
   && [ "$(qr '.summary.repairs[] | select(.id==31) | .mr')" = "8" ] \
   && [ "$(qr '.summary.repairs[] | select(.id==31) | .fix')" = "lane.sh transition 31 review" ] \
   && qr '.warnings[]' | grep -q 'MR !8 is open and closes it'; then
    ok "repairs: an open MR closing an in-progress ticket is named, with its repair command"
else
    bad "repairs: MR-open shape missed ($(qr '.summary.repairs | tostring'), $(head -2 "$RP/err"))"
fi
if [ "$(qr '.summary.repairs[] | select(.id==26) | .shape')" = "pass-not-in-merge-queue" ] \
   && [ "$(qr '.summary.repairs[] | select(.id==26) | .fix')" = "lane.sh transition 26 merge-queue" ] \
   && qr '.warnings[]' | grep -q 'the verdict note landed and the label flip did not'; then
    ok "repairs: a PASS standing at HEAD on a non-queued ticket is named, with its repair command"
else
    bad "repairs: PASS shape missed ($(qr '.summary.repairs | tostring'))"
fi
# The failing side of both guards, in one document: #36 carries the SAME open
# MR and the SAME PASS and is correctly in `merge-queue`, and #10's open MR
# mentions another ticket's `Closes` line rather than its own — repairing off
# that MR would relabel a ticket over someone else's branch.
if [ "$(qr '[.summary.repairs[] | select(.id==36 or .id==10)] | length')" = "0" ]; then
    ok "repairs: a queued ticket and a mentions-only MR produce no repair item"
else
    bad "repairs: false positive ($(qr '[.summary.repairs[] | select(.id==36 or .id==10)] | tostring'))"
fi
# The state a FAIL verdict leaves behind is byte-identical on labels to the
# death shape 1 repairs: `in-progress`, MR still open. Repairing it shoves the
# rejected ticket back to `review`, where the gate calls it already judged and
# nothing else in the wave reads it — parked forever (triggers-api build-2 #57,
# 2026-08-12). #57 is the case the guard actually decides. #58 is the same FAIL
# one state along — `ready-for-agent`, the sanctioned recovery — and it is clean
# for a second, independent reason: MRs are fetched only for active tickets, so
# its MR list is empty here whatever the guard says. It is pinned anyway, so
# that widening the fetch scope cannot quietly re-wedge the recovery state.
if [ "$(qr '[.summary.repairs[] | select(.id==57 or .id==58)] | length')" = "0" ]; then
    ok "repairs: a standing FAIL at HEAD blocks the MR-open repair"
else
    bad "repairs: FAIL verdict repaired into review ($(qr '[.summary.repairs[] | select(.id==57 or .id==58)] | tostring'))"
fi
# A gate-base deferral is an intentional transition, not a lane dying between
# MR creation and relabel.  Its tracker marker is active only at the inspected
# HEAD, suppresses the false repair to review, and leaves the ticket stranded
# for implementation reconciliation.  Advancing the MR head retires it.
cat > "$RP/notes-31.json" <<'EOF'
[{"system":false,"created_at":"2026-08-07T04:05:00Z","body":"Reconcile origin/main, push, and resubmit.\n\n<!-- orch-base-stale aaa1111000000000000000000000000000000000 base=main behind=4 -->"}]
EOF
GLAB_CMD="$RP/glab-stub.sh" "$TICK" snapshot > "$RP/snap-base-stale.json" 2>/dev/null
if jq -e '([.summary.repairs[] | select(.id==31)] | length) == 0
          and (.summary.stranded | index(31)) != null
          and (.tickets[] | select(.id==31) | .active_base_reconcile.base) == "main"' \
          "$RP/snap-base-stale.json" >/dev/null 2>&1; then
    ok "base reconcile: current-head marker suppresses the false review repair and exposes rework"
else
    bad "base reconcile: stale-base transition still loops through review ($(jq -c '{repairs:.summary.repairs,stranded:.summary.stranded,ticket:(.tickets[]|select(.id==31)|{active_base_reconcile,related_merge_requests})}' "$RP/snap-base-stale.json"))"
fi
# Planted violation: remove only the intentional-transition exclusion.  The
# current-head marker remains visible, but the generic half-transition repair
# sends the ticket straight back to the stale gate.
BASE_REPAIR_MUT=$(mirror_scripts "$T/base-repair-mutant")
sed 's/ and \$base_reconcile == null//' "$BASE_REPAIR_MUT/snapshot.jq" \
    > "$BASE_REPAIR_MUT/snapshot-mutant.jq"
mv "$BASE_REPAIR_MUT/snapshot-mutant.jq" "$BASE_REPAIR_MUT/snapshot.jq"
GLAB_CMD="$RP/glab-stub.sh" "$BASE_REPAIR_MUT/tick.sh" snapshot \
    > "$RP/snap-base-stale-mutant.json" 2>/dev/null
if jq -e '([.summary.repairs[] | select(.id==31 and .shape=="mr-open-not-in-review")] | length) == 1' \
          "$RP/snap-base-stale-mutant.json" >/dev/null 2>&1; then
    ok "base-reconcile-violation: deleting the exclusion recreates the stale review loop"
else
    bad "base-reconcile-violation: planted exclusion deletion did not restore the false repair"
fi
sed 's/aaa1111000000000000000000000000000000000/9999999000000000000000000000000000000000/' \
    "$RP/mrs-31.json" > "$RP/mrs-31-new.json"
mv "$RP/mrs-31-new.json" "$RP/mrs-31.json"
GLAB_CMD="$RP/glab-stub.sh" "$TICK" snapshot > "$RP/snap-base-advanced.json" 2>/dev/null
if jq -e '([.summary.repairs[] | select(.id==31 and .shape=="mr-open-not-in-review")] | length) == 1
          and (.tickets[] | select(.id==31) | .active_base_reconcile) == null' \
          "$RP/snap-base-advanced.json" >/dev/null 2>&1; then
    ok "base reconcile: advancing HEAD automatically retires the stale-base decision"
else
    bad "base reconcile: old marker remained active against a new HEAD ($(jq -c '{repairs:.summary.repairs,ticket:(.tickets[]|select(.id==31)|{active_base_reconcile,related_merge_requests})}' "$RP/snap-base-advanced.json"))"
fi
# A ticket whose lane is still ALIVE is never flagged: the second write may
# simply not have happened yet. Same live-lane set `summary.stranded` uses.
"$TICK" spawn-lane impl-31 -- sleep 30 >/dev/null
GLAB_CMD="$RP/glab-stub.sh" "$TICK" snapshot > "$RP/snap2.json" 2>/dev/null
if [ "$(jq -r '[.summary.repairs[] | select(.id==31)] | length' "$RP/snap2.json")" = "0" ] \
   && [ "$(jq -r '[.summary.repairs[] | select(.id==26)] | length' "$RP/snap2.json")" = "1" ]; then
    ok "repairs: a ticket holding an alive lane is not flagged mid-write"
else
    bad "repairs: live-lane race guard wrong ($(jq -c '.summary.repairs' "$RP/snap2.json"))"
fi
kill "$(cat "$LOOM_HOME/lanes/impl-31.pid" 2>/dev/null)" 2>/dev/null

test_finish
