#!/usr/bin/env bash
# The pure planner reserves the one shared UI host before provider work starts.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

cat > "$T/base.json" <<'EOF'
{
  "generated_at":"2026-08-17T10:00:00Z",
  "logs_dir":"/tmp/logs",
  "config":{"max_lanes":3,"max_aux_lanes":4,"ui_capacity":2,"merge_attempt_cap":2,"lane_tier":"medium","base":"main"},
  "build":{"id":1,"label":"build-1","provider":"codex"},
  "epics":[], "dependency_edges":[], "other_iids":[], "supervised_leases":[], "lanes":[],
  "tickets":[
    {"id":10,"state":"review","tier":"ui","supervised_lease":null,"related_merge_requests":[{"id":110,"state":"open","branch":"ui-10","sha":"aaaa"}],"gate":{"eligible":true,"head":"aaaa"}},
    {"id":11,"state":"review","tier":"ui","supervised_lease":null,"related_merge_requests":[{"id":111,"state":"open","branch":"ui-11","sha":"bbbb"}],"gate":{"eligible":true,"head":"bbbb"}},
    {"id":12,"state":"review","tier":"api","supervised_lease":null,"related_merge_requests":[{"id":112,"state":"open","branch":"api-12","sha":"cccc"}],"gate":{"eligible":true,"head":"cccc"}}
  ],
  "summary":{"impl_slots_free":0,"merge_in_flight":false,"stranded":[],"repairs":[],"epics_awaiting_probe":[],"ui_pregate_usage":2,"ui_pregate_occupied":true},
  "warnings":[]
}
EOF

"$TICK" plan "$T/base.json" > "$T/busy.json"
if jq -e '[.actions[] | select(.step=="gate") | .ticket] == [12]
          and ([.deferred[] | select(.step=="gate" and (.ticket==10 or .ticket==11))
                | .why | select(test("UI host capacity"))] | length) == 2' \
      "$T/busy.json" >/dev/null; then
    ok "plan: a live or queued UI owner suppresses UI gates while API gates continue"
else
    bad "plan: occupied UI resource still scheduled redundant gates ($(jq -c '{actions,deferred}' "$T/busy.json"))"
fi

jq '.summary.ui_pregate_usage=0 | .summary.ui_pregate_occupied=false' "$T/base.json" > "$T/free.json"
"$TICK" plan "$T/free.json" > "$T/free-plan.json"
if jq -e '[.actions[] | select(.step=="gate") | .ticket] == [10,11,12]
          and ([.deferred[] | select(.step=="gate" and (.ticket==10 or .ticket==11))] | length) == 0' \
      "$T/free-plan.json" >/dev/null; then
    ok "plan: two free UI slots admit the two highest-priority UI gates"
else
    bad "plan: configured UI capacity was not fully assigned ($(jq -c '{actions,deferred}' "$T/free-plan.json"))"
fi

jq '.tickets += [{"id":20,"state":"merge-queue","tier":"ui","supervised_lease":null,
                   "merge_attempts":0,"merge_hold":null,
                   "related_merge_requests":[{"id":120,"state":"open","branch":"ui-20","sha":"dddd"}],
                   "gate":{"eligible":false}}]' "$T/free.json" > "$T/ui-merge.json"
"$TICK" plan "$T/ui-merge.json" > "$T/ui-merge-plan.json"
if jq -e 'any(.actions[]; .lane=="gate-10")
          and (any(.actions[]; .lane=="merge-20") | not)
          and any(.deferred[]; .step=="merge" and .ticket==20 and (.why | test("UI host resource")))' \
      "$T/ui-merge-plan.json" >/dev/null; then
    ok "plan: a scheduled UI gate reserves the resource from a UI merge"
else
    bad "plan: one wave scheduled overlapping UI gate and merge ($(jq -c '{actions,deferred}' "$T/ui-merge-plan.json"))"
fi

jq '(.tickets[] | select(.id==20) | .tier)="api"' "$T/ui-merge.json" > "$T/api-merge.json"
"$TICK" plan "$T/api-merge.json" > "$T/api-merge-plan.json"
if jq -e 'any(.actions[]; .lane=="gate-10") and any(.actions[]; .lane=="merge-20")' \
      "$T/api-merge-plan.json" >/dev/null; then
    ok "plan: UI reservation leaves API merge parallelism intact"
else
    bad "plan: UI reservation suppressed an API merge ($(jq -c '{actions,deferred}' "$T/api-merge-plan.json"))"
fi

# A private planted violation proves the configured slot calculation, not
# incidental aux capacity, is what permits the second UI ticket.
MUT=$(mirror_scripts "$T/ui-plan-mutant")
sed -i.bak 's/($ui_capacity - $ui_pregate_usage - $repair_ui_count)/(1 - $ui_pregate_usage - $repair_ui_count)/' \
    "$MUT/plan.jq"
"$MUT/tick.sh" plan "$T/free.json" > "$T/free-mutant.json" 2>/dev/null
if jq -e 'any(.actions[]; .lane=="gate-10")
          and (any(.actions[]; .lane=="gate-11") | not)
          and any(.deferred[]; .ticket==11)' \
      "$T/free-mutant.json" >/dev/null; then
    ok "plan mutant: collapsing configured capacity recreates one-at-a-time UI scheduling"
else
    bad "plan mutant: planted one-slot violation did not recreate serialization"
fi

test_finish
