#!/usr/bin/env bash
# planner transitions compare the live ticket state with the state they observed
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

FX="$T/stale-wave"; mkdir -p "$FX"
STATE_FILE="$FX/state"
TRACKER="$FX/tracker.sh"
CALLS="$FX/tracker.calls"
export STATE_FILE CALLS TRACKER_CMD="$TRACKER"

cat > "$TRACKER" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  issue)
    printf '{"id":%s,"state":"open","labels":["build-1","%s"],"body":""}\n' \
      "$2" "$(cat "$STATE_FILE")"
    ;;
  issue-relabel) exit 0 ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$TRACKER"

# This is the smallest board that produces the incident's immutable action:
# a stranded implementation has exhausted its rejection cap, so the planner
# decides to move it from in-progress to blocked.
cat > "$FX/snapshot.json" <<'EOF'
{
  "generated_at": "2026-08-16T22:00:00Z",
  "logs_dir": "/tmp/logs",
  "config": {"max_lanes": 1, "max_aux_lanes": 1, "rejection_cap": 2,
             "crash_cap": 2, "merge_attempt_cap": 2, "lane_turn_cap": 150,
             "heartbeat_stale_minutes": 30, "lane_tier": "medium",
             "rework_tier": "high", "base": "main"},
  "build": {"id": 1, "label": "build-1", "title": "Build 1",
            "url": "https://x/1", "provider": "codex"},
  "epics": [],
  "tickets": [{
    "id": 283, "title": "reconciled branch", "state": "in-progress",
    "tier": "api", "fix": false, "unblocked": true,
    "assignees": ["agent"],
    "tier_selection": {"effective": "high", "source": "rework_tier"},
    "rejections": {"total": 2, "last_class": "stale-base", "same_class_tail": 1},
    "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
    "gate": {"eligible": false, "reason": "not in review", "head": null,
             "last_verdict": null}
  }],
  "other_iids": [], "lanes": [], "lessons_tail": [],
  "summary": {"open_tickets": 1, "by_state": {}, "all_blocked": false,
    "epics_awaiting_probe": [], "ready_set_empty": false, "lanes_running": 0,
    "gateable": 0,
    "lanes_running_by_type": {"impl": 0, "gate": 0, "merge": 0,
                              "probe": 0, "unknown": 0},
    "impl_slots_free": 1, "merge_in_flight": false, "stranded": [283],
    "repairs": []},
  "warnings": []
}
EOF

"$TICK" plan "$FX/snapshot.json" > "$FX/plan.json"
planned_argv=$(jq -c '.actions[] | select(.ticket == 283 and .kind == "transition") | .argv' "$FX/plan.json")
if [ "$planned_argv" = '["transition","283","blocked","--if-current","in-progress"]' ]; then
    ok "stale wave: a planned transition carries the ticket state it observed"
else
    bad "stale wave: transition has no compare-and-set condition ($planned_argv)"
fi

run_action() { # <plan.json> — execute its one lane.sh argv through the public verb
    set -- $(jq -r '.actions[] | select(.ticket == 283 and .kind == "transition") | .argv[]' "$1")
    "$LANE" "$@"
}

# The supervisor resets the invalid verdict and starts a gate after this plan
# was generated. The old action must now be held at the mutation boundary.
printf 'review\n' > "$STATE_FILE"
: > "$CALLS"
out=$(LOOM_LANE_ID=wave run_action "$FX/plan.json" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'expected.*in-progress.*currently.*review' \
   && ! grep -q '^issue-relabel ' "$CALLS"; then
    ok "stale wave: an in-review ticket cannot be moved back to blocked by an old plan"
else
    bad "stale wave: old transition crossed newer review state (rc=$rc; out=$out)"
fi

# Countercondition: while the observed state still stands, the same planned
# action remains valid. This proves the holding assertion reached the guard.
printf 'in-progress\n' > "$STATE_FILE"
: > "$CALLS"
run_action "$FX/plan.json" > "$FX/current.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^issue-relabel 283 .*--add blocked' "$CALLS"; then
    ok "stale wave: an unchanged ticket still accepts its planned transition"
else
    bad "stale wave: compare-and-set rejected the unchanged state (rc=$rc)"
fi

# Planted violation: remove only the expected-state arguments, recreating the
# pre-fix public plan. The later review state is overwritten again.
jq '(.actions[] | select(.ticket == 283 and .kind == "transition") | .argv) |= .[0:3]' \
  "$FX/plan.json" > "$FX/unguarded-plan.json"
printf 'review\n' > "$STATE_FILE"
: > "$CALLS"
run_action "$FX/unguarded-plan.json" > "$FX/unguarded.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^issue-relabel 283 .*--add blocked' "$CALLS"; then
    ok "stale-wave-violation: deleting the planned precondition recreates the rollback"
else
    bad "stale-wave-violation: planted unguarded plan did not recreate the rollback (rc=$rc)"
fi

test_finish
