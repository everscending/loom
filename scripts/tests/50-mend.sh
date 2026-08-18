#!/usr/bin/env bash
# The contract-grounded phase-6 mend supervisor
#
# Section 50 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

FX="$T/mend"; mkdir -p "$FX"

cat > "$FX/healthy.json" <<'EOF'
{
  "generated_at": "2026-08-17T12:00:00Z",
  "logs_dir": "/tmp/loom/logs",
  "config": {"max_lanes":3,"max_aux_lanes":4,"rejection_cap":2,"crash_cap":2,
             "merge_attempt_cap":2,"lane_turn_cap":150,"heartbeat_stale_minutes":30,
             "min_wave_gap_minutes":10,"stall_action":"resume","lane_tier":"medium",
             "rework_tier":"high","base":"main"},
  "build": {"id":267,"label":"build-1","title":"Build 1","provider":"claude"},
  "epics": [],
  "tickets": [{
    "id":10,"title":"healthy implementation","state":"in-progress","tier":"logic",
    "fix":false,"unblocked":true,"assignees":["worker"],"blocked_by":[],
    "tier_selection":{"effective":"medium","source":"lane_tier"},
    "rejections":{"total":0,"last_class":null,"same_class_tail":0},
    "merge_attempts":0,"merge_hold":null,"related_merge_requests":[],
    "gate":{"eligible":false,"reason":"not in review","head":null,"last_verdict":null}
  }],
  "dependency_edges": [],"other_iids":[],"supervised_leases":[],
  "lanes": [{"id":"impl-10","pid":"123","state":"running","type":"impl",
             "rc":"-","turns":"3","outcome":"none","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}],
  "lessons_tail": [],
  "summary": {"open_tickets":1,"by_state":{"in-progress":1},"all_blocked":false,
              "epics_awaiting_probe":[],"ready_set_empty":true,"lanes_running":1,
              "gateable":0,"lanes_running_by_type":{"impl":1,"gate":0,"merge":0,"probe":0,"unknown":0},
              "impl_slots_free":2,"merge_in_flight":false,"ui_pregate_occupied":false,
              "stranded":[],"repairs":[]},
  "warnings": []
}
EOF

out=$("$TICK" mend-status "$FX/healthy.json" 2>"$FX/healthy.err"); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | jq -e '
     .schema == 1
     and .build.id == 267
     and .build.provider == "claude"
     and .loop.stopped == false
     and (.attention | length) == 0
     and (.schedule.actions | length) == 0
     and .configuration.max_lanes == 3
     and .configuration.max_aux_lanes == 4' >/dev/null 2>&1; then
    ok "mend: one compact status document describes a healthy active build"
else
    bad "mend: healthy status was not emitted (rc=$rc, out=$(printf '%s' "$out" | tr '\n' '|'), err=$(head -2 "$FX/healthy.err" | tr '\n' '|'))"
fi

# An armed build with no live lane and a non-empty deterministic plan is not a
# healthy stopping point for the default continuing supervisor. The scheduler
# still owns launch, but mend must keep observing until the action starts or
# diagnose a missed handoff/heartbeat instead of returning "loop armed".
jq '
  .lanes = []
  | .summary.lanes_running = 0
  | .summary.lanes_running_by_type = {"impl":0,"gate":0,"merge":0,"probe":0,"unknown":0}
  | .summary.repairs = [{"id":10,"shape":"mr-open-not-in-review","fix":"lane.sh transition 10 review"}]
  ' "$FX/healthy.json" > "$FX/actionable-idle.json"
idle=$(
  "$TICK" mend-status "$FX/actionable-idle.json" 2>"$FX/actionable-idle.err"
); idle_rc=$?
if [ "$idle_rc" = 0 ] && printf '%s\n' "$idle" | jq -e '
     (.summary.lanes_running == 0)
     and (.schedule.actions | length) > 0
     and ([.attention[]
           | select(.kind == "actionable-idle"
                    and .contract == "MEND-FLOW-01"
                    and .action_count > 0)] | length) == 1' >/dev/null 2>&1; then
    ok "mend: an armed idle board with runnable work stays visible as a progress gap"
else
    bad "mend: runnable idle work was normalized as healthy silence (rc=$idle_rc, $(printf '%s' "$idle" | jq -c '{summary,schedule,attention}' 2>/dev/null))"
fi

# An unrelated live lane must not make a merge queue look healthy. Mend does
# not launch the merge itself, but it must identify the missing owner and keep
# observing through the scheduler boundary.
jq '
  .tickets[0].state = "merge-queue"
  | .tickets[0].merge_attempts = 0
  | .tickets[0].merge_hold = null
  | .lanes[0].id = "impl-99"
  | .summary.by_state = {"merge-queue":1}
  | .summary.lanes_running_by_type = {"impl":1,"gate":0,"merge":0,"probe":0,"unknown":0}
  | .summary.merge_in_flight = false
  ' "$FX/healthy.json" > "$FX/unowned-merge.json"
unowned_merge=$("$TICK" mend-status "$FX/unowned-merge.json" 2>"$FX/unowned-merge.err")
unowned_merge_rc=$?
if [ "$unowned_merge_rc" = 0 ] && printf '%s\n' "$unowned_merge" | jq -e '
     ([.attention[]
       | select(.kind == "unowned-stage"
                and .contract == "MEND-FLOW-01"
                and .ticket == 10
                and .state == "merge-queue"
                and .expected_owner == "merge")] | length) == 1' >/dev/null 2>&1; then
    ok "mend: unrelated activity cannot hide a merge queue with no merge worker"
else
    bad "mend: a merge queue without its owning worker was hidden (rc=$unowned_merge_rc, $(printf '%s' "$unowned_merge" | jq -c '{summary,schedule,attention}' 2>/dev/null))"
fi

# Planted violation: remove the stage detector call from a private mirror. The
# merge queue must become invisible while the unrelated implementation remains
# live, proving the alert comes from the new per-stage invariant.
OWNER_MD=$(mirror_scripts "$T/mend-owner-mirror")
sed '/+ unowned_stages_of($s; $p; $stopped)/d' \
    "$OWNER_MD/mend.jq" > "$OWNER_MD/mend.jq.mutant"
mv "$OWNER_MD/mend.jq.mutant" "$OWNER_MD/mend.jq"
owner_mutant=$(LOOM_REPO="$LOOM_REPO" LOOM_HOME="$LOOM_HOME" \
    "$OWNER_MD/tick.sh" mend-status "$FX/unowned-merge.json" 2>/dev/null)
if ! printf '%s\n' "$owner_mutant" | jq -e '
       [.attention[] | select(.kind == "unowned-stage")] | length > 0' \
       >/dev/null 2>&1; then
    ok "mend-owner-violation: removing the stage detector recreates the invisible merge queue"
else
    bad "mend-owner-violation: unowned merge alert survived without its detector"
fi

# Planted violation: disable only the runnable-action predicate. The same
# public status request must then lose MEND-FLOW-01, proving the GREEN result
# depends on the detector rather than the fixture's partial-transition warning.
FLOW_MD=$(mirror_scripts "$T/mend-flow-mirror")
sed 's/(($p.actions \/\/ \[\]) | length) > 0/(($p.actions \/\/ []) | length) < 0/' \
    "$FLOW_MD/mend.jq" > "$FLOW_MD/mend.jq.mutant"
mv "$FLOW_MD/mend.jq.mutant" "$FLOW_MD/mend.jq"
flow_mutant=$(LOOM_REPO="$LOOM_REPO" LOOM_HOME="$LOOM_HOME" \
    "$FLOW_MD/tick.sh" mend-status "$FX/actionable-idle.json" 2>/dev/null)
if ! printf '%s\n' "$flow_mutant" | jq -e '
       [.attention[] | select(.kind == "actionable-idle")] | length > 0' \
       >/dev/null 2>&1; then
    ok "mend-flow-violation: disabling the idle detector recreates invisible runnable silence"
else
    bad "mend-flow-violation: idle alert survived with its action predicate disabled"
fi

jq 'del(.config.min_wave_gap_minutes, .config.stall_action)' \
    "$FX/healthy.json" > "$FX/snapshot-config-gap.json"
configured=$("$TICK" mend-status "$FX/snapshot-config-gap.json" 2>/dev/null)
if printf '%s\n' "$configured" | jq -e '
     .configuration.min_wave_gap_minutes == 10
     and .configuration.stall_action == "resume"' >/dev/null 2>&1; then
    ok "mend: timing policy comes from canonical layered config when snapshot omits it"
else
    bad "mend: timing policy disappeared at the snapshot boundary ($(printf '%s' "$configured" | jq -c '.configuration' 2>/dev/null))"
fi

# The normal human path supplies no fixture: mend-status must take its own
# fresh tracker snapshot, then feed that exact document to the pure planner.
LIVE_FX="$T/mend-live"; make_glab_fixture "$LIVE_FX"
live=$(GLAB_CMD="$LIVE_FX/glab-stub.sh" STUB_LOG="$T/mend-live.calls" \
    "$TICK" mend-status 2>"$T/mend-live.err"); live_rc=$?
if [ "$live_rc" = 0 ] && printf '%s\n' "$live" | jq -e '
     .schema == 1 and .build.label == "build-2"
     and (.schedule.actions | type) == "array"' >/dev/null 2>&1 \
   && [ -s "$T/mend-live.calls" ]; then
    ok "mend: no-argument status reads one fresh tracker snapshot and derives its plan"
else
    bad "mend: live composition seam failed (rc=$live_rc, err=$(head -2 "$T/mend-live.err" | tr '\n' '|'))"
fi

touch "$LOOM_HOME/loop.stopped"
stopped=$("$TICK" mend-status "$FX/healthy.json" 2>/dev/null)
if printf '%s\n' "$stopped" | jq -e '.loop.stopped == true and (.attention | length) == 0' >/dev/null 2>&1; then
    ok "mend: the human stop switch is visible and never fabricated as a defect"
else
    bad "mend: stopped state was hidden or misclassified ($(printf '%s' "$stopped" | tr '\n' '|'))"
fi
rm -f "$LOOM_HOME/loop.stopped"

jq '
  .tickets = [
    {"id":20,"title":"round three","state":"in-progress","tier":"api","fix":false,
     "unblocked":true,"assignees":["worker"],"blocked_by":[],
     "tier_selection":{"effective":"high","source":"rework_tier"},
     "rejections":{"total":2,"last_class":"gate-contract","same_class_tail":1},
     "merge_attempts":0,"merge_hold":null,"related_merge_requests":[],
     "gate":{"eligible":false,"reason":"not in review","head":null,"last_verdict":null}},
    {"id":21,"title":"external prerequisite","state":"blocked","tier":"logic","fix":false,
     "unblocked":true,"assignees":[],"blocked_by":[],
     "blocked_report":{"category":"prerequisite-unavailable","body":"External stack absent","released":false},
     "tier_selection":{"effective":"medium","source":"lane_tier"},
     "rejections":{"total":0,"last_class":null,"same_class_tail":0},
     "merge_attempts":0,"merge_hold":null,"related_merge_requests":[],
     "gate":{"eligible":false,"reason":"not in review","head":null,"last_verdict":null}}
  ]
  | .lanes = [{"id":"impl-22","pid":"999","state":"stale","type":"impl","rc":"-","turns":"9","outcome":"none"}]
  | .summary.open_tickets = 2
  | .summary.by_state = {"in-progress":1,"blocked":1}
  | .summary.lanes_running = 1
  | .summary.stranded = [20]
  | .summary.repairs = [{"id":23,"shape":"mr-open-not-in-review","fix":"lane.sh transition 23 review"}]
  | .warnings = ["ticket #24: no state label"]' "$FX/healthy.json" > "$FX/attention.json"

attention=$("$TICK" mend-status "$FX/attention.json" 2>"$FX/attention.err"); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$attention" | jq -e '
     ([.attention[].kind] | index("snapshot-warning")) != null
     and ([.attention[] | select(.kind=="round-three" and .ticket==20)] | length) == 1
     and ([.attention[] | select(.kind=="blocked-ticket" and .ticket==21
                                  and .category=="prerequisite-unavailable")] | length) == 1
     and ([.attention[] | select(.kind=="stale-lane" and .lane=="impl-22")] | length) == 1
     and ([.attention[] | select(.kind=="partial-transition" and .ticket==23)] | length) == 1' \
     >/dev/null 2>&1; then
    ok "mend: evidence-backed warnings, round-three help, blocks, stale lanes and repairs are surfaced"
else
    bad "mend: attention classification is incomplete (rc=$rc, $(printf '%s' "$attention" | jq -c '.attention' 2>/dev/null))"
fi

jq '.build.provider = "codex"' "$FX/healthy.json" > "$FX/codex.json"
claude=$("$TICK" mend-status "$FX/healthy.json" 2>/dev/null)
claude_rc=$?
codex=$("$TICK" mend-status "$FX/codex.json" 2>/dev/null)
codex_rc=$?
if [ "$claude_rc" = 0 ] && [ "$codex_rc" = 0 ] \
   && printf '%s\n' "$claude" | jq -e '.schema == 1' >/dev/null 2>&1 \
   && printf '%s\n' "$codex" | jq -e '.schema == 1' >/dev/null 2>&1 \
   && diff -u \
     <(printf '%s\n' "$claude" | jq 'del(.build.provider)') \
     <(printf '%s\n' "$codex" | jq 'del(.build.provider)') >/dev/null 2>&1; then
    ok "mend: Claude and Codex receive the same provider-neutral health document"
else
    bad "mend: provider selection changed monitor semantics"
fi

"$TICK" mend-status "$FX/healthy.json" extra >/dev/null 2>&1 \
    && bad "mend: an unknown argument was accepted" \
    || ok "mend: an unknown argument is refused"

SKILL="$(dirname "$(dirname "$TICK")")/SKILL.md"
MEND_REF="$(dirname "$TICK")/../references/mend.md"
if grep -q '| `mend' "$SKILL" \
   && grep -q 'references/mend.md' "$SKILL" \
   && grep -q 'assert start-owned supervision' "$MEND_REF" 2>/dev/null \
   && grep -q 'Mend is read-only' "$MEND_REF" 2>/dev/null \
   && grep -q 'releases a hold, edits Loom' "$MEND_REF" 2>/dev/null \
   && grep -q 'MEND-FLOW-01' "$MEND_REF" 2>/dev/null \
   && grep -q 'Do not compensate from Mend' "$MEND_REF" 2>/dev/null \
   && grep -q 'Route a confirmed Loom defect to the `fix` verb' "$MEND_REF" 2>/dev/null; then
    ok "mend: the human verb is a read-only assertion of start-owned supervision"
else
    bad "mend: the skill/reference contract is absent or incomplete"
fi

# Planted violation: the public verb must name its shipped document builder
# instead of falling through to an opaque jq error or emitting partial status.
MD=$(mirror_scripts "$T/mend-mirror")
mv "$MD/mend.jq" "$MD/mend.jq.hidden" 2>/dev/null || true
mutant=$(LOOM_REPO="$LOOM_REPO" LOOM_HOME="$LOOM_HOME" "$MD/tick.sh" mend-status "$FX/healthy.json" 2>&1); mutant_rc=$?
if [ "$mutant_rc" -ne 0 ] && printf '%s\n' "$mutant" | grep -q 'mend-status: .*mend.jq is missing'; then
    ok "mend-violation: a missing status builder fails loudly at the public seam"
else
    bad "mend-violation: missing builder was not named (rc=$mutant_rc, $mutant)"
fi

test_finish
