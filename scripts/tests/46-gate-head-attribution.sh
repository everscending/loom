#!/usr/bin/env bash
# D-TICK-27: a delayed pregate verdict belongs to the commit the lane tested
#
# Section 46 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

GH="$T/gate-head"; mkdir -p "$GH/repo/scripts"
seed_tracker_decl "$GH/repo"
cat > "$GH/repo/scripts/gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "fixture rejects $1"
exit 1
EOF
chmod +x "$GH/repo/scripts/gate.sh"
printf 'old\n' > "$GH/repo/work.txt"
git -C "$GH/repo" add scripts/gate.sh work.txt docs/agents/issue-tracker.md
git -C "$GH/repo" commit -qm old
old_head=$(git -C "$GH/repo" rev-parse HEAD)

"$TICK" spawn-lane gate-218-r3 --no-tick --pregate api --cwd "$GH/repo" -- true >/dev/null
for _ in $(seq 1 80); do
    [ "$(cat "$LOOM_HOME/lanes/gate-218-r3.rc" 2>/dev/null)" = 7 ] && break
    sleep 0.05
done
printf 'new\n' > "$GH/repo/work.txt"
git -C "$GH/repo" add work.txt
git -C "$GH/repo" commit -qm repaired
new_head=$(git -C "$GH/repo" rev-parse HEAD)

lane_line=$("$TICK" lane-status | awk '$1=="gate-218-r3"')
captured_head=$(printf '%s\n' "$lane_line" | awk '{print $9}')
if [ "$captured_head" = "$old_head" ] && [ "$captured_head" != "$new_head" ]; then
    ok "gate attribution: lane-status retains the immutable pregate HEAD after the branch advances"
else
    bad "gate attribution: lane carried '${captured_head:-nothing}', old=$old_head new=$new_head"
fi

FX="$GH/tracker"; make_glab_fixture "$FX"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$GH/tracker.calls" \
  "$TICK" snapshot > "$GH/live-snapshot.json"
snapshot_head=$(jq -r '.lanes[] | select(.id=="gate-218-r3") | .head // empty' "$GH/live-snapshot.json")
[ "$snapshot_head" = "$old_head" ] \
    && ok "gate attribution: snapshot preserves lane-status launch HEAD" \
    || bad "gate attribution: snapshot dropped launch HEAD '$snapshot_head'"

jq -n \
  --arg old "$captured_head" \
  '{generated_at:"2026-08-17T05:06:30Z", logs_dir:"/tmp/logs",
    config:{max_lanes:1,max_aux_lanes:1,rejection_cap:2,crash_cap:2,
            merge_attempt_cap:2,lane_turn_cap:150,heartbeat_stale_minutes:30,
            lane_tier:"medium",rework_tier:"high",base:"main"},
    build:{id:1,label:"build-1",title:"Build 1",provider:"claude"},
    epics:[], other_iids:[], lessons_tail:[], supervised_leases:[],
    tickets:[{id:218,title:"repaired after pregate",state:"review",tier:"api",fix:false,
      unblocked:true,assignees:["agent"],tier_selection:{effective:"medium",source:"lane_tier"},
      rejections:{total:0,last_class:null,same_class_tail:0},merge_attempts:0,merge_hold:null,
      related_merge_requests:[],gate:{eligible:false,reason:"gate lane exists",head:null,last_verdict:null}}],
    lanes:[{id:"gate-218-r3",pid:"999999",state:"dead",type:"gate",rc:"7",turns:"-",cost:null,
            outcome:"none",head:$old}],
    summary:{open_tickets:1,by_state:{review:1},all_blocked:false,epics_awaiting_probe:[],
             ready_set_empty:false,lanes_running:0,gateable:0,
             lanes_running_by_type:{impl:0,gate:0,merge:0,probe:0,unknown:0},
             impl_slots_free:1,merge_in_flight:false,stranded:[],repairs:[]},warnings:[]}' \
  > "$GH/snapshot.json"
"$TICK" plan "$GH/snapshot.json" > "$GH/plan.json"
planned_sha=$(jq -r '.residue[] | select(.kind=="pregate-rejection") | .sha // empty' "$GH/plan.json")
planned_verb=$(jq -r '.residue[] | select(.kind=="pregate-rejection") | .verb // empty' "$GH/plan.json")
if [ "$planned_sha" = "$old_head" ] \
   && printf '%s' "$planned_verb" | grep -q "verdict 218 fail $old_head" \
   && ! printf '%s' "$planned_verb" | grep -q "$new_head"; then
    ok "gate attribution: delayed plan binds rejection to the tested HEAD"
else
    bad "gate attribution: delayed plan sha='$planned_sha' verb='$planned_verb'"
fi

rm -f "$LOOM_HOME/lanes/gate-218-r3.head"
missing_head=$("$TICK" lane-status | awk '$1=="gate-218-r3" {print $9}')
jq --arg head "$missing_head" '(.lanes[0].head) = $head' "$GH/snapshot.json" > "$GH/no-head.json"
"$TICK" plan "$GH/no-head.json" > "$GH/no-head-plan.json"
missing_verb=$(jq -r '.residue[] | select(.kind=="pregate-rejection") | .verb // empty' "$GH/no-head-plan.json")
missing_why=$(jq -r '.residue[] | select(.kind=="pregate-rejection") | .why // empty' "$GH/no-head-plan.json")
if [ -z "$missing_verb" ] && printf '%s' "$missing_why" | grep -qi 'immutable\|launch.*head\|provenance' \
   && ! grep -q "$new_head" "$GH/no-head-plan.json"; then
    ok "gate attribution violation: missing launch HEAD leaves no classifiable verdict"
else
    bad "gate attribution violation: missing provenance still yielded verb='$missing_verb' why='$missing_why'"
fi

printf '%s\n' "$old_head" > "$LOOM_HOME/lanes/gate-218-r3.head"
"$TICK" clear-lane gate-218-r3 >/dev/null
[ ! -e "$LOOM_HOME/lanes/gate-218-r3.head" ] \
    && ok "gate attribution: clear-lane removes the immutable launch metadata" \
    || bad "gate attribution: cleared lane leaked its launch HEAD metadata"
test_finish
