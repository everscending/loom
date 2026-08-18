#!/usr/bin/env bash
# Start-owned supervision: blocked work is scheduled into repair lanes by the
# same durable scheduler that owns implementation, gate, and merge lanes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

FX="$T/start-supervision"; mkdir -p "$FX"

cat > "$FX/snapshot.json" <<'EOF'
{
  "generated_at":"2026-08-17T23:55:00Z",
  "logs_dir":"/tmp/loom/logs",
  "config":{"max_lanes":2,"max_aux_lanes":4,"rejection_cap":2,"crash_cap":2,
            "merge_attempt_cap":2,"lane_turn_cap":150,"heartbeat_stale_minutes":30,
            "min_wave_gap_minutes":10,"stall_action":"resume","lane_tier":"medium",
            "rework_tier":"high","base":"main"},
  "build":{"id":267,"label":"build-1","title":"Build 1","provider":"codex",
           "supervision_policy":"autonomous-repair-v1"},
  "epics":[], "other_iids":[], "supervised_leases":[], "lessons_tail":[], "warnings":[],
  "tickets":[
    {"id":31,"title":"root blocker","state":"blocked","tier":"ui","fix":false,
     "unblocked":true,"assignees":["worker"],"blocked_by":[],"supervised_lease":null,
     "supervision_attention":null,
     "blocked_report":{"at":"2026-08-17T23:40:01Z","category":"implementation","body":"valid UI defect","released":false},
     "tier_selection":{"effective":"high","source":"rework_tier"},
     "rejections":{"total":2,"last_class":"ui-contract","same_class_tail":1},
     "merge_attempts":0,"merge_hold":null,"related_merge_requests":[{"id":67,"state":"open","branch":"loom-31","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}],
     "gate":{"eligible":false,"reason":"blocked","head":null,"last_verdict":null}},
    {"id":32,"title":"leaf blocker","state":"blocked","tier":"logic","fix":false,
     "unblocked":true,"assignees":["worker"],"blocked_by":[],"supervised_lease":null,
     "supervision_attention":null,
     "blocked_report":{"at":"2026-08-17T23:40:02Z","category":"test-infrastructure","body":"stale harness","released":false},
     "tier_selection":{"effective":"high","source":"rework_tier"},
     "rejections":{"total":2,"last_class":"test-infrastructure","same_class_tail":1},
     "merge_attempts":0,"merge_hold":null,"related_merge_requests":[{"id":68,"state":"open","branch":"loom-32","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],
     "gate":{"eligible":false,"reason":"blocked","head":null,"last_verdict":null}},
    {"id":33,"title":"decision blocker","state":"blocked","tier":"api","fix":false,
     "unblocked":true,"assignees":["worker"],"blocked_by":[],"supervised_lease":null,
     "supervision_attention":{"category":"human-decision","body":"Choose retention policy"},
     "blocked_report":{"at":"2026-08-17T23:40:03Z","category":"human-decision","body":"Choose retention policy","released":false},
     "tier_selection":{"effective":"high","source":"rework_tier"},
     "rejections":{"total":0,"last_class":null,"same_class_tail":0},
     "merge_attempts":0,"merge_hold":null,"related_merge_requests":[],
     "gate":{"eligible":false,"reason":"blocked","head":null,"last_verdict":null}},
    {"id":40,"title":"direct dependent","state":"ready-for-agent","tier":"logic","fix":false,
     "unblocked":false,"assignees":[],"blocked_by":[{"id":31,"closed":false}],"supervised_lease":null,
     "tier_selection":{"effective":"medium","source":"lane_tier"},"rejections":{"total":0},
     "merge_attempts":0,"merge_hold":null,"related_merge_requests":[],"gate":{"eligible":false}},
    {"id":41,"title":"second dependent","state":"ready-for-agent","tier":"logic","fix":false,
     "unblocked":false,"assignees":[],"blocked_by":[{"id":31,"closed":false}],"supervised_lease":null,
     "tier_selection":{"effective":"medium","source":"lane_tier"},"rejections":{"total":0},
     "merge_attempts":0,"merge_hold":null,"related_merge_requests":[],"gate":{"eligible":false}},
    {"id":42,"title":"transitive dependent","state":"ready-for-agent","tier":"logic","fix":false,
     "unblocked":false,"assignees":[],"blocked_by":[{"id":40,"closed":false}],"supervised_lease":null,
     "tier_selection":{"effective":"medium","source":"lane_tier"},"rejections":{"total":0},
     "merge_attempts":0,"merge_hold":null,"related_merge_requests":[],"gate":{"eligible":false}},
    {"id":43,"title":"leaf dependent","state":"ready-for-agent","tier":"logic","fix":false,
     "unblocked":false,"assignees":[],"blocked_by":[{"id":32,"closed":false}],"supervised_lease":null,
     "tier_selection":{"effective":"medium","source":"lane_tier"},"rejections":{"total":0},
     "merge_attempts":0,"merge_hold":null,"related_merge_requests":[],"gate":{"eligible":false}}
  ],
  "dependency_edges":[
    {"id":40,"blocked_by":[{"id":31,"closed":false}]},
    {"id":41,"blocked_by":[{"id":31,"closed":false}]},
    {"id":42,"blocked_by":[{"id":40,"closed":false}]},
    {"id":43,"blocked_by":[{"id":32,"closed":false}]}
  ],
  "lanes":[],
  "summary":{"open_tickets":7,"by_state":{"blocked":3,"ready-for-agent":4},
             "all_blocked":true,"epics_awaiting_probe":[],"ready_set_empty":true,
             "lanes_running":0,"gateable":0,
             "lanes_running_by_type":{"impl":0,"repair":0,"gate":0,"merge":0,"probe":0,"unknown":0},
             "impl_slots_free":2,"merge_in_flight":false,"ui_pregate_occupied":false,
             "stranded":[],"repairs":[]}
}
EOF

"$TICK" plan "$FX/snapshot.json" > "$FX/plan.json" 2>"$FX/plan.err"
if jq -e '
    [.actions[] | select(.step == "supervise") | .lane] == ["repair-31","repair-32"]
    and ([.actions[] | select(.lane == "repair-31")][0]
         | .spawn.type == "repair" and .spawn.pregate == null
         and .spawn.ui_resource == true
         and .spawn.tier == "high" and .dependency_impact == 3)
    and ([.actions[] | select(.ticket == 33)] | length) == 0
    and ([.deferred[] | select(.ticket == 33 and .kind == "awaiting-human")] | length) == 1' \
    "$FX/plan.json" >/dev/null 2>&1; then
  ok "start supervision: highest-impact repairable blockers fill free worker slots"
else
  bad "start supervision: blocked work was not scheduled into ranked repair lanes ($(jq -c '{actions,deferred,residue}' "$FX/plan.json" 2>/dev/null))"
fi

# Repair lanes consume the implementation worker pool. A normal implementation
# already occupying one of two slots leaves room for exactly one repair; start
# must not create a hidden parallel pool that bypasses the build's cap.
jq '.lanes=[{"id":"impl-90","pid":"900","state":"running","type":"impl","rc":"-","turns":"1","outcome":"none"}]
    | .summary.lanes_running=1
    | .summary.lanes_running_by_type={impl:1,repair:0,gate:0,merge:0,probe:0,unknown:0}
    | .summary.impl_slots_free=1' "$FX/snapshot.json" > "$FX/one-slot.json"
"$TICK" plan "$FX/one-slot.json" > "$FX/one-slot-plan.json" 2>/dev/null
if [ "$(jq '[.actions[] | select(.step=="supervise")] | length' "$FX/one-slot-plan.json")" = 1 ] \
   && [ "$(jq -r '[.actions[] | select(.step=="supervise")][0].lane' "$FX/one-slot-plan.json")" = repair-31 ]; then
  ok "start supervision: repair lanes share the implementation capacity cap"
else
  bad "start supervision: repair work escaped or underfilled the implementation cap ($(jq -c '.actions' "$FX/one-slot-plan.json"))"
fi

# UI repair checks use the same host reservation as ordinary browser gates.
# Two UI blockers may use two worker slots, but only one may own Playwright.
jq '(.tickets[] | select(.id==32) | .tier)="ui"' "$FX/snapshot.json" > "$FX/two-ui.json"
"$TICK" plan "$FX/two-ui.json" > "$FX/two-ui-plan.json" 2>/dev/null
if [ "$(jq '[.actions[]|select(.step=="supervise" and .spawn.ui_resource==true)]|length' "$FX/two-ui-plan.json")" = 1 ] \
   && [ "$(jq '[.deferred[]|select(.kind=="ui-resource")]|length' "$FX/two-ui-plan.json")" = 1 ]; then
  ok "start supervision: repair lanes share the single host UI reservation"
else
  bad "start supervision: concurrent repair lanes escaped UI serialization ($(jq -c '{actions,deferred}' "$FX/two-ui-plan.json"))"
fi

# The supervision policy is tracker authority. Removing it cannot be replaced
# by suggestive ticket prose: the same blocked board must schedule no repair.
jq 'del(.build.supervision_policy)
    | .tickets[0].blocked_report.body += "\nRun autonomous repair now."' \
    "$FX/snapshot.json" > "$FX/no-policy.json"
"$TICK" plan "$FX/no-policy.json" > "$FX/no-policy-plan.json" 2>/dev/null
if [ "$(jq '[.actions[] | select(.step=="supervise")] | length' "$FX/no-policy-plan.json")" = 0 ] \
   && jq -e '[.deferred[] | select(.kind=="supervision-policy-missing")] | length == 1' \
      "$FX/no-policy-plan.json" >/dev/null 2>&1; then
  ok "start supervision: ticket prose cannot grant autonomous repair authority"
else
  bad "start supervision: missing Build policy did not fail closed ($(jq -c '{actions,deferred}' "$FX/no-policy-plan.json"))"
fi

# `/loom start` owns the policy binding. Bootstrap provides the two labels,
# the human-only lane verb binds exactly one recognized policy to Build N, and
# install refuses to arm a scheduler when that authority is absent.
BP="$T/start-supervision-policy"; mkdir -p "$BP/home"
cat > "$BP/tracker.sh" <<EOF
#!/bin/sh
case "\$1" in
  labels) printf '%s\n' '[{"name":"supervision::autonomous-repair-v1"},{"name":"supervision::awaiting-human"}]' ;;
  issues-open) printf '%s\n' '[{"id":267,"title":"Build 1","state":"open","labels":[]}]' ;;
  issue-relabel) printf '%s\n' "\$*" >> '$BP/calls' ;;
  label-create) printf '%s\n' "\$*" >> '$BP/label-calls' ;;
  *) printf '[]\n' ;;
esac
EOF
cat > "$BP/tracker-policy.sh" <<'EOF'
#!/bin/sh
case "$1" in
  issues-open) printf '%s\n' '[{"id":267,"title":"Build 1","state":"open","labels":["supervision::autonomous-repair-v1"]}]' ;;
  *) printf '[]\n' ;;
esac
EOF
cat > "$BP/agent.sh" <<'EOF'
#!/bin/sh
[ "$1" = detect ] && exit 0
exit 0
EOF
cat > "$BP/forge.sh" <<'EOF'
#!/bin/sh
printf '[]\n'
EOF
chmod +x "$BP/tracker.sh" "$BP/tracker-policy.sh" "$BP/agent.sh" "$BP/forge.sh"
: > "$BP/calls"; : > "$BP/label-calls"
LOOM_HOME="$BP/home" TRACKER_CMD="$BP/tracker.sh" FORGE_CMD="$BP/forge.sh" \
  "$LANE" build-supervision autonomous-repair-v1 >/dev/null 2>"$BP/bind.err"
if grep -q '^issue-relabel 267 --add supervision::autonomous-repair-v1$' "$BP/calls"; then
  ok "start supervision: human start binding records policy on the active Build"
else
  bad "start supervision: Build policy was not bound through its guarded verb"
fi
calls_before=$(wc -l < "$BP/calls" | tr -d ' ')
set +e
LOOM_HOME="$BP/home" LOOM_LANE_ID=impl-31 TRACKER_CMD="$BP/tracker.sh" FORGE_CMD="$BP/forge.sh" \
  "$LANE" build-supervision autonomous-repair-v1 >"$BP/auto.out" 2>"$BP/auto.err"
bp_auto_rc=$?
set -e
calls_after=$(wc -l < "$BP/calls" | tr -d ' ')
if [ "$bp_auto_rc" -ne 0 ] && [ "$calls_before" = "$calls_after" ] \
   && grep -q 'human-only' "$BP/auto.err"; then
  ok "start supervision: waves and lanes cannot bind or change Build policy"
else
  bad "start supervision: automated caller changed Build supervision policy"
fi

BOOT="$(dirname "$TICK")/bootstrap.sh"
boot_out=$(LOOM_HOME="$BP/home" TRACKER_CMD="$BP/tracker.sh" \
  "$BOOT" supervision-labels --dry-run 2>"$BP/bootstrap.err")
if printf '%s\n' "$boot_out" | grep -q 'supervision::autonomous-repair-v1 already present' \
   && printf '%s\n' "$boot_out" | grep -q 'supervision::awaiting-human already present'; then
  ok "start supervision: bootstrap owns both policy and human-attention labels"
else
  bad "start supervision: bootstrap did not expose the complete supervision vocabulary"
fi

set +e
LOOM_HOME="$BP/install-missing" TRACKER_CMD="$BP/tracker.sh" LOOM_AGENT_CMD="$BP/agent.sh" \
  LOOM_SKIP_SUPERVISION_CHECK= "$TICK" install --dry-run --provider claude \
  >"$BP/install-missing.out" 2>"$BP/install-missing.err"
install_missing_rc=$?
set -e
LOOM_HOME="$BP/install-policy" TRACKER_CMD="$BP/tracker-policy.sh" LOOM_AGENT_CMD="$BP/agent.sh" \
  LOOM_SKIP_SUPERVISION_CHECK= "$TICK" install --dry-run --provider claude \
  >"$BP/install-policy.out" 2>"$BP/install-policy.err"
install_policy_rc=$?
if [ "$install_missing_rc" -ne 0 ] && [ "$install_policy_rc" -eq 0 ] \
   && grep -q 'must carry exactly one supervision policy' "$BP/install-missing.err" \
   && grep -q 'generated (dry-run)' "$BP/install-policy.out"; then
  ok "start supervision: scheduler install fails closed without the Build policy"
else
  bad "start supervision: install policy gate disagreed (missing=$install_missing_rc bound=$install_policy_rc)"
fi

# Mend is an auditor of start-owned state. It must report the scheduler's
# candidate/owner disposition without manufacturing a second repair queue.
audit=$(LOOM_TEST_SCHEDULER_ARMED=1 "$TICK" mend-status "$FX/snapshot.json" 2>/dev/null)
if printf '%s\n' "$audit" | jq -e '
    .supervision.policy == "autonomous-repair-v1"
    and .supervision.scheduler_armed == true
    and [.supervision.candidates[].ticket] == [31,32]
    and .supervision.awaiting_human == [33]
    and .supervision.ownership_gaps == [31,32]
    and .supervision.assertion == "fail"' >/dev/null 2>&1; then
  ok "mend audit: fails old repair candidates that start left unowned"
else
  bad "mend audit: did not report start-owned supervision state ($(printf '%s' "$audit" | jq -c '.supervision' 2>/dev/null))"
fi
jq '.generated_at="2026-08-17T23:40:30Z"' "$FX/snapshot.json" > "$FX/fresh-block.json"
fresh_audit=$(LOOM_TEST_SCHEDULER_ARMED=1 "$TICK" mend-status "$FX/fresh-block.json" 2>/dev/null)
if printf '%s\n' "$fresh_audit" | jq -e '
    .supervision.ownership_gaps == [] and .supervision.assertion == "pass"' \
    >/dev/null 2>&1; then
  ok "mend audit: allows one heartbeat for a newly blocked repair dispatch"
else
  bad "mend audit: new blocked work had no dispatch grace ($(printf '%s' "$fresh_audit" | jq -c '.supervision' 2>/dev/null))"
fi
ui_audit=$(LOOM_TEST_SCHEDULER_ARMED=1 "$TICK" mend-status "$FX/two-ui.json" 2>/dev/null)
if printf '%s\n' "$ui_audit" | jq -e '
    .supervision.capacity_deferred == [32]
    and .supervision.ownership_gaps == [31]' >/dev/null 2>&1; then
  ok "mend audit: shared UI deferral is valid capacity, not an ownership gap"
else
  bad "mend audit: UI serialization was misclassified ($(printf '%s' "$ui_audit" | jq -c '.supervision' 2>/dev/null))"
fi

# The heartbeat used to stop at the cheap `all blocked` classification before
# it ever derived the plan. Feed the public tick the already-derived plan at
# its deterministic test seam: a policy-owned repair action must promote the
# board to stalled and buy one scheduler wave, while the same board without an
# action remains halted and spends nothing.
HB="$T/start-supervision-heartbeat"; mkdir -p "$HB/home" "$HB/home-no-policy"
cat > "$HB/tracker.sh" <<'EOF'
#!/bin/sh
case "$1" in
  issues-by-label)
    printf '[{"id":31,"state":"open","labels":["build-1","blocked"],"assignees":[],"body":""}]\n' ;;
  issues-open)
    printf '[{"id":267,"title":"Build 1","state":"open","labels":["supervision::autonomous-repair-v1"]}]\n' ;;
  issue)
    printf '{"id":31,"state":"open","labels":["build-1","blocked"]}\n' ;;
  issue-notes)
    printf '[{"body":"report\\n\\n<!-- orch-blocked category=implementation 2026-08-17T23:40:01Z -->","created_at":"2026-08-17T23:40:01Z"}]\n' ;;
  *) printf '[]\n' ;;
esac
EOF
chmod +x "$HB/tracker.sh"
cat > "$HB/dispatch.sh" <<EOF
#!/bin/sh
jq -e 'any(.actions[]?; .step == "supervise" and .kind == "spawn")' "\$1" >/dev/null \
  && printf started > '$HB/dispatch'
EOF
chmod +x "$HB/dispatch.sh"
printf 'build-1\n' > "$HB/home/.build-label"
printf 'build-1\n' > "$HB/home-no-policy/.build-label"
: > "$HB/home/events.jsonl"; : > "$HB/home-no-policy/events.jsonl"
rm -f "$HB/dispatch" "$HB/wave" "$HB/no-policy-wave"
LOOM_HOME="$HB/home" TRACKER_CMD="$HB/tracker.sh" \
  LOOM_TEST_SUPERVISION_PLAN="$FX/plan.json" \
  LOOM_TEST_SUPERVISION_DISPATCH_CMD="$HB/dispatch.sh" \
  LOOM_WAVE_CMD="printf started > '$HB/wave'" \
  "$TICK" tick --auto --provider claude >/dev/null 2>&1
LOOM_HOME="$HB/home-no-policy" TRACKER_CMD="$HB/tracker.sh" \
  LOOM_TEST_SUPERVISION_PLAN="$FX/no-policy-plan.json" \
  LOOM_WAVE_CMD="printf started > '$HB/no-policy-wave'" \
  "$TICK" tick --auto --provider claude >/dev/null 2>&1
if [ -s "$HB/dispatch" ] && [ ! -e "$HB/wave" ] && [ ! -e "$HB/no-policy-wave" ] \
   && grep -q '"ev":"start_supervision_actionable"' "$HB/home/events.jsonl"; then
  ok "start supervision: heartbeat dispatches all-blocked repair without a scheduling agent"
else
  bad "start supervision: heartbeat did not deterministically dispatch repairable work"
fi

# A repair lane has one narrow write path. Exact lane identity, active lease,
# Build policy, and block generation are all required before it can suppress a
# repeated human-only diagnosis. Ordinary implementation lanes cannot borrow
# this authority.
RR="$T/start-supervision-result"; mkdir -p "$RR/home/supervised-leases"
cat > "$RR/tracker.sh" <<EOF
#!/bin/sh
case "\$1" in
  issues-open) printf '%s\n' '[{"id":267,"title":"Build 1","state":"open","labels":["supervision::autonomous-repair-v1"]}]' ;;
  issue) printf '%s\n' '{"id":31,"title":"blocked","state":"open","labels":["build-1","blocked"],"assignees":[]}' ;;
  issue-notes) printf '%s\n' '[{"body":"report\\n\\n<!-- orch-blocked category=implementation 2026-08-17T23:40:01Z -->","created_at":"2026-08-17T23:40:01Z"}]' ;;
  issue-relabel) printf 'relabel %s\n' "\$*" >> '$RR/calls' ;;
  note-add) printf 'note %s\n' "\$*" >> '$RR/calls'; cp "\$3" '$RR/note' ;;
  *) printf '[]\n' ;;
esac
EOF
cat > "$RR/forge.sh" <<'EOF'
#!/bin/sh
printf '[]\n'
EOF
chmod +x "$RR/tracker.sh" "$RR/forge.sh"
printf '{"schema":1,"ticket":31,"owner":"repair-31","acquired_at":1,"expires_at":4102444800}\n' \
  > "$RR/home/supervised-leases/31.json"
printf 'Need the product owner to choose the retention policy.\n' > "$RR/body"
: > "$RR/calls"
LOOM_HOME="$RR/home" LOOM_LANE_ID=repair-31 TRACKER_CMD="$RR/tracker.sh" FORGE_CMD="$RR/forge.sh" \
  "$LANE" repair-result 31 human-attention --block-token 2026-08-17T23:40:01Z \
  --file "$RR/body" >/dev/null 2>"$RR/err"
if grep -q 'supervision::awaiting-human' "$RR/calls" \
   && grep -q 'orch-blocked category=human-attention' "$RR/note" \
   && [ ! -e "$RR/home/supervised-leases/31.json" ]; then
  ok "start supervision: restricted repair result persists and suppresses human attention"
else
  bad "start supervision: repair human-attention result was not durable ($(tr '\n' ';' < "$RR/calls"))"
fi
calls_before=$(wc -l < "$RR/calls" | tr -d ' ')
printf '{"schema":1,"ticket":31,"owner":"repair-31","acquired_at":1,"expires_at":4102444800}\n' \
  > "$RR/home/supervised-leases/31.json"
set +e
LOOM_HOME="$RR/home" LOOM_LANE_ID=impl-31 TRACKER_CMD="$RR/tracker.sh" FORGE_CMD="$RR/forge.sh" \
  "$LANE" repair-result 31 human-attention --block-token 2026-08-17T23:40:01Z \
  --file "$RR/body" >"$RR/denied.out" 2>"$RR/denied.err"
rr_rc=$?
set -e
calls_after=$(wc -l < "$RR/calls" | tr -d ' ')
if [ "$rr_rc" -ne 0 ] && [ "$calls_before" = "$calls_after" ] \
   && grep -q "only lane 'repair-31'" "$RR/denied.err"; then
  ok "start supervision: ordinary lanes cannot use repair-result authority"
else
  bad "start supervision: repair-result authority escaped its exact lane (rc=$rr_rc calls=$calls_before/$calls_after)"
fi

# A resolved repair is stricter than human-attention: the worktree must be
# clean, pushed, and exactly equal to the ticket's one open MR head before the
# blocked hold can move to review. Build a local bare remote so this proof
# crosses the real git boundary without network access.
RS="$T/start-supervision-resolved"; mkdir -p "$RS/home/supervised-leases"
git init -q --bare "$RS/remote.git"
git init -q "$RS/repo"
git -C "$RS/repo" config user.email loom@test
git -C "$RS/repo" config user.name loom
mkdir -p "$RS/repo/docs/agents"
printf '# Issue tracker: GitLab\n' > "$RS/repo/docs/agents/issue-tracker.md"
printf 'base\n' > "$RS/repo/work.txt"
git -C "$RS/repo" add docs/agents/issue-tracker.md work.txt
git -C "$RS/repo" commit -qm base
git -C "$RS/repo" branch -M main
git -C "$RS/repo" remote add origin "$RS/remote.git"
git -C "$RS/repo" push -q -u origin main
git -C "$RS/repo" switch -qc loom-31
printf 'repaired\n' >> "$RS/repo/work.txt"
git -C "$RS/repo" commit -qam repair
git -C "$RS/repo" push -q -u origin loom-31
RS_HEAD=$(git -C "$RS/repo" rev-parse HEAD)
cat > "$RS/tracker.sh" <<EOF
#!/bin/sh
case "\$1" in
  issues-open) printf '%s\n' '[{"id":267,"title":"Build 1","state":"open","labels":["supervision::autonomous-repair-v1"]}]' ;;
  issue) printf '%s\n' '{"id":31,"title":"blocked","state":"open","labels":["build-1","blocked"],"assignees":[]}' ;;
  issue-notes) printf '%s\n' '[{"body":"report\\n\\n<!-- orch-blocked category=implementation 2026-08-17T23:40:01Z -->","created_at":"2026-08-17T23:40:01Z"}]' ;;
  issue-relabel) printf 'relabel %s\n' "\$*" >> '$RS/calls' ;;
  note-add) printf 'note %s\n' "\$*" >> '$RS/calls'; cp "\$3" '$RS/note' ;;
  *) printf '[]\n' ;;
esac
EOF
cat > "$RS/forge.sh" <<EOF
#!/bin/sh
case "\$1" in
  mr-for-ticket) printf '%s\n' '[{"id":67,"state":"open","sha":"$RS_HEAD"}]' ;;
  *) printf '[]\n' ;;
esac
EOF
chmod +x "$RS/tracker.sh" "$RS/forge.sh"
printf '{"schema":1,"ticket":31,"owner":"repair-31","acquired_at":1,"expires_at":4102444800}\n' \
  > "$RS/home/supervised-leases/31.json"
printf 'Repaired the same-scope defect and verified focused checks.\n' > "$RS/body"
: > "$RS/calls"
(cd "$RS/repo" && LOOM_REPO="$RS/repo" LOOM_HOME="$RS/home" LOOM_LANE_ID=repair-31 \
  TRACKER_CMD="$RS/tracker.sh" FORGE_CMD="$RS/forge.sh" \
  "$LANE" repair-result 31 resolved --block-token 2026-08-17T23:40:01Z \
  --file "$RS/body" >"$RS/out" 2>"$RS/err")
if grep -q 'orch-supervised-repair' "$RS/note" \
   && grep -q 'orch-unblock' "$RS/note" \
   && grep -q 'issue-relabel 31 --add review' "$RS/calls" \
   && [ ! -e "$RS/home/supervised-leases/31.json" ] \
   && [ -e "$RS/home/continuation.request" ]; then
  ok "start supervision: exact pushed MR head returns a repaired blocker to independent review"
else
  bad "start supervision: resolved repair did not complete its guarded review handoff ($(tr '\n' ';' < "$RS/calls"))"
fi

# Change only the forge's claimed head. The same clean pushed branch is now a
# stale repair result and must perform no tracker write.
sed "s/$RS_HEAD/0000000000000000000000000000000000000000/" "$RS/forge.sh" > "$RS/forge-stale.sh"
chmod +x "$RS/forge-stale.sh"
printf '{"schema":1,"ticket":31,"owner":"repair-31","acquired_at":1,"expires_at":4102444800}\n' \
  > "$RS/home/supervised-leases/31.json"
: > "$RS/calls"
set +e
(cd "$RS/repo" && LOOM_REPO="$RS/repo" LOOM_HOME="$RS/home" LOOM_LANE_ID=repair-31 \
  TRACKER_CMD="$RS/tracker.sh" FORGE_CMD="$RS/forge-stale.sh" \
  "$LANE" repair-result 31 resolved --block-token 2026-08-17T23:40:01Z \
  --file "$RS/body" >"$RS/stale.out" 2>"$RS/stale.err")
stale_rc=$?
set -e
if [ "$stale_rc" -ne 0 ] && [ ! -s "$RS/calls" ] \
   && grep -q 'open merge request is at' "$RS/stale.err"; then
  ok "start supervision: MR-head drift fails closed before releasing the hold"
else
  bad "start supervision: stale MR head escaped repair-result (rc=$stale_rc calls=$(tr '\n' ';' < "$RS/calls"))"
fi

# Exercise the production deterministic dispatcher, not the marker seam used
# by the cheap heartbeat test above. The host resolves the existing branch,
# renders the bounded brief, acquires the lease and UI reservation, and starts
# only the repair worker—never a scheduling wave agent.
DD="$T/start-supervision-direct-dispatch"; mkdir -p "$DD/home"
jq --arg head "$RS_HEAD" '
  .actions=[.actions[]|select(.lane=="repair-31")]
  | (.actions[0].spawn.expected_head)=$head
  | .summary.impl_slots_free=1' "$FX/plan.json" > "$DD/plan.json"
jq --arg head "$RS_HEAD" '
  .tickets=(.tickets|map(if .id==31
      then .related_merge_requests=[{"id":67,"state":"open","branch":"loom-31","sha":$head}]
      else . end))
  | .summary.impl_slots_free=1' "$FX/snapshot.json" > "$DD/snapshot.json"
cat > "$DD/agent.sh" <<'EOF'
#!/bin/sh
case "$1" in
  detect|preflight) exit 0 ;;
  run) sleep 30; exit 0 ;;
esac
exit 0
EOF
chmod +x "$DD/agent.sh"
printf 'build-1\n' > "$DD/home/.build-label"
: > "$DD/home/events.jsonl"
rm -f "$DD/wave"
LOOM_REPO="$RS/repo" LOOM_HOME="$DD/home" TRACKER_CMD="$HB/tracker.sh" \
  LOOM_AGENT_CMD="$DD/agent.sh" LOOM_TEST_SUPERVISION_PLAN="$DD/plan.json" \
  LOOM_TEST_SUPERVISION_SNAPSHOT="$DD/snapshot.json" \
  LOOM_WAVE_CMD="printf spent > '$DD/wave'" \
  "$TICK" tick --auto --provider claude >"$DD/tick.out" 2>"$DD/tick.err"
if [ ! -e "$DD/wave" ] \
   && jq -e '.owner=="repair-31" and .ticket==31' "$DD/home/supervised-leases/31.json" >/dev/null 2>&1 \
   && [ -e "$DD/home/lanes/repair-31.ui-resource" ] \
   && grep -q 'repair-result 31 resolved --block-token 2026-08-17T23:40:01Z' "$DD/home/briefs/repair-31.md" \
   && grep -q 'no scheduling agent spent' "$DD/tick.out"; then
  ok "start supervision: host directly dispatches the frozen repair worker and UI reservation"
else
  bad "start supervision: production dispatcher lost its brief, lease, UI reservation, or no-wave guarantee"
fi
LOOM_REPO="$RS/repo" LOOM_HOME="$DD/home" LOOM_AGENT_CMD="$DD/agent.sh" \
  "$TICK" kill-lane repair-31 >/dev/null 2>&1 || true

# The final host admission rechecks the frozen block generation. A newer
# report invalidates the old plan before lease publication or agent launch.
set +e
LOOM_REPO="$RS/repo" LOOM_HOME="$DD/home-stale" TRACKER_CMD="$HB/tracker.sh" \
  LOOM_AGENT_CMD="$DD/agent.sh" "$TICK" spawn-lane repair-31 --provider claude \
  --job repair --tier high --repair-block-token 2026-08-17T22:00:00Z \
  --brief "$DD/home/briefs/repair-31.md" --cwd "$RS/repo" \
  >"$DD/stale.out" 2>"$DD/stale.err"
stale_spawn_rc=$?
set -e
if [ "$stale_spawn_rc" -ne 0 ] \
   && grep -q 'block generation changed' "$DD/stale.err" \
   && [ ! -e "$DD/home-stale/supervised-leases/31.json" ] \
   && [ ! -e "$DD/home-stale/lanes/repair-31.pid" ]; then
  ok "start supervision: stale block generation is rejected before lease or agent launch"
else
  bad "start supervision: stale blocked authority reached repair admission"
fi

# Hard cleanup must release the exact repair-owned lease even when the worker
# never reaches its epilogue. Otherwise a killed repair lane strands the
# ticket for the lease TTL.
CL="$T/start-supervision-clear"; mkdir -p "$CL/home/lanes" "$CL/home/supervised-leases"
printf '{"schema":1,"ticket":31,"owner":"repair-31","acquired_at":1,"expires_at":4102444800}\n' \
  > "$CL/home/supervised-leases/31.json"
LOOM_HOME="$CL/home" "$TICK" clear-lane repair-31 >/dev/null 2>"$CL/err"
if [ ! -e "$CL/home/supervised-leases/31.json" ]; then
  ok "start supervision: hard lane cleanup releases the exact repair lease"
else
  bad "start supervision: clear-lane left repair ownership stranded"
fi

# The policy is intentionally attached by start, not inferred by install or a
# ticket. Keep the reference contract load-bearing enough that a future Mend
# rewrite cannot quietly take queue ownership back.
SKILL_ROOT="$(cd "$(dirname "$TICK")/.." && pwd)"
if grep -q 'Derive every decision that can be computed' "$SKILL_ROOT/references/supervision.md" \
   && grep -q 'Mend does not create a competing queue' "$SKILL_ROOT/references/supervision.md" \
   && grep -q 'repairs confirmed defects in' "$SKILL_ROOT/references/supervision.md" \
   && grep -q '\[supervision.md\](supervision.md)' "$SKILL_ROOT/references/phases-1-5.md"; then
  ok "start supervision: deterministic-first ownership is codified at the start boundary"
else
  bad "start supervision: deterministic/start/mend ownership contract is missing"
fi

# Planted violation: remove the planner's repair action assembly. The public
# plan must return to the observed failure shape—blocked tickets, free slots,
# and no worker—while the Mend audit can only report the resulting gap.
MUT=$(mirror_scripts "$T/start-supervision-mutant")
sed 's/+ $repair_actions /+ [] /' "$MUT/plan.jq" > "$MUT/plan.jq.mutant"
mv "$MUT/plan.jq.mutant" "$MUT/plan.jq"
"$MUT/tick.sh" plan "$FX/snapshot.json" > "$FX/mutant-plan.json" 2>/dev/null
if [ "$(jq '[.actions[] | select(.step=="supervise")] | length' "$FX/mutant-plan.json")" = 0 ]; then
  ok "start-supervision violation: removing repair dispatch recreates the unattended blocked queue"
else
  bad "start-supervision violation: repair work survived without planner dispatch"
fi

test_finish
