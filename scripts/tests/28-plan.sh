#!/usr/bin/env bash
# P81: the wave's scheduling is a pure function of the snapshot
#
# Section 28 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

PLANJQ="$(dirname "$TICK")/plan.jq"
FX="$T/fx"; mkdir -p "$FX"

# One fixture snapshot carrying one case per SKILL.md step, so the whole
# decision table is exercised by a single `plan` run and the ORDER between the
# steps is assertable at the same time:
#   #40 review, gateable, its gate lane dead at rc 7   (step 2 + step 3)
#   #41 in-progress behind a STALE lane                (step 2)
#   #42 stranded, one rejection                        (step 4, rework)
#   #43 stranded, two of the SAME class                (step 4, the stop rule)
#   #52 stranded, two DIFFERENT classes                (step 4, round-3 help)
#   #44 ready but carrying a P63 repair                (step 2 repair)
#   #45 ready and `fix: true`, #46 ready but blocked   (step 4, fix-first)
#   #47/#48/#49 merge-queue: held, free, cap spent     (step 5)
#   #50 in-progress behind a lane past the turn cap    (step 2)
#   two epics awaiting a probe, one with no criteria   (step 6)
cat > "$FX/snap.json" <<'EOF'
{
  "generated_at": "2026-08-10T10:00:00Z",
  "logs_dir": "/home/logs",
  "config": {"max_lanes": 4, "max_aux_lanes": 4, "rejection_cap": 2, "crash_cap": 2,
             "merge_attempt_cap": 2, "lane_turn_cap": 150, "heartbeat_stale_minutes": 30,
             "lane_tier": "medium", "rework_tier": "high", "base": "develop"},
  "build": {"id": 1, "label": "build-2", "title": "Build 2", "url": "https://x/1", "provider":"claude"},
  "epics": [
    {"name": "Ledger core", "milestone": "Ledger core", "acceptance": "- [ ] a ledger balances",
     "needs_probe": true, "complete": true, "open_tickets": 0, "accepted": false},
    {"name": "Reporting surface", "milestone": "Reporting surface", "acceptance": null,
     "needs_probe": true, "complete": true, "open_tickets": 0, "accepted": false}
  ],
  "tickets": [
    {"id": 40, "title": "pregate rejected", "state": "review", "tier": "logic", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null,
     "related_merge_requests": [{"id": 90, "state": "open", "branch": "t40", "sha": "aaaa111"}],
     "gate": {"eligible": true, "reason": null, "head": "aaaa111", "last_verdict": null}},
    {"id": 41, "title": "wedged lane", "state": "in-progress", "tier": "api", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 42, "title": "stranded, one class", "state": "in-progress", "tier": "logic", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "high", "source": "rework_tier"},
     "rejections": {"total": 1, "last_class": "marks-attribution", "same_class_tail": 1},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 43, "title": "stranded, two same class", "state": "in-progress", "tier": "logic", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "high", "source": "rework_tier"},
     "rejections": {"total": 2, "last_class": "marks-attribution", "same_class_tail": 2},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 52, "title": "stranded, two different classes", "state": "in-progress", "tier": "logic", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "high", "source": "rework_tier"},
     "rejections": {"total": 2, "last_class": "api-contract", "same_class_tail": 1},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 44, "title": "ready, but a repair stands against it", "state": "ready-for-agent",
     "tier": "api", "fix": false,
     "unblocked": true, "assignees": [], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 45, "title": "ready, fix", "state": "ready-for-agent", "tier": "logic", "fix": true,
     "unblocked": true, "assignees": [], "tier_selection": {"effective": "high", "source": "label"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 46, "title": "ready, blocked by an open blocker", "state": "ready-for-agent", "tier": "ui",
     "fix": false, "unblocked": false, "assignees": [], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 47, "title": "merge-queue, held", "state": "merge-queue", "tier": "api", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 1, "merge_hold": {"checks": ["pytest::x"], "fixes": [70]},
     "related_merge_requests": [{"id": 97, "state": "open", "branch": "t47", "sha": "cccc333"}],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 48, "title": "merge-queue, free", "state": "merge-queue", "tier": "api", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null,
     "related_merge_requests": [{"id": 98, "state": "open", "branch": "t48", "sha": "dddd444"}],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 49, "title": "merge-queue, cap spent", "state": "merge-queue", "tier": "api", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 2, "merge_hold": null,
     "related_merge_requests": [{"id": 99, "state": "open", "branch": "t49", "sha": "eeee555"}],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 50, "title": "running past the turn cap", "state": "in-progress", "tier": "logic", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 51, "title": "blocked report landed, label did not", "state": "merge-queue", "tier": "api", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "blocked_report": {"at": "2026-08-10T09:59:00Z", "category": "tracker-rate-limit", "body": "Fix creation was rate limited.", "ticket_state": "merge-queue", "released": false},
     "merge_attempts": 0, "merge_hold": null,
     "related_merge_requests": [{"id": 101, "state": "open", "branch": "t51", "sha": "ffff666"}],
     "gate": {"eligible": false, "reason": "not in review", "head": "ffff666", "last_verdict": null}}
  ],
  "other_iids": [],
  "lanes": [
    {"id": "gate-40", "pid": "111", "state": "dead", "type": "gate", "rc": "7", "turns": "3"},
    {"id": "impl-41", "pid": "112", "state": "stale", "type": "impl", "rc": "-", "turns": "9"},
    {"id": "merge-49", "pid": "113", "state": "dead", "type": "merge", "rc": "0", "turns": "12", "outcome": "merge-failed"},
    {"id": "merge-51", "pid": "115", "state": "dead", "type": "merge", "rc": "0", "turns": "8"},
    {"id": "impl-50", "pid": "114", "state": "running", "type": "impl", "rc": "-", "turns": "301"}
  ],
  "lessons_tail": [],
  "summary": {
    "open_tickets": 12, "by_state": {}, "all_blocked": false,
    "epics_awaiting_probe": ["Ledger core", "Reporting surface"],
    "ready_set_empty": false, "lanes_running": 2, "gateable": 1,
    "lanes_running_by_type": {"impl": 2, "gate": 0, "merge": 0, "probe": 0, "unknown": 0},
    "impl_slots_free": 2, "merge_in_flight": false,
    "stranded": [42, 43, 52],
    "repairs": [{"id": 44, "shape": "mr-open-not-in-review", "state": "ready-for-agent", "mr": 91,
                 "fix": "lane.sh transition 44 review"}]
  },
  "warnings": []
}
EOF

PLAN() { "$TICK" plan "$@"; }
PLAN "$FX/snap.json" > "$T/plan.json" 2>"$T/plan.err"; rc=$?
p() { jq -r "$1" "$T/plan.json"; }
if [ "$rc" = 0 ] && jq -e . "$T/plan.json" >/dev/null 2>&1; then
    ok "plan: emits one JSON document from a snapshot document"
else
    bad "plan: rc=$rc, $(head -2 "$T/plan.err")"
fi

jq '.tickets[0].tier_selection.invalid_labels = ["opus"]' "$FX/snap.json" > "$FX/snap-legacy-model.json"
PLAN "$FX/snap-legacy-model.json" > "$T/plan-legacy-model.json" 2>/dev/null
jq -e '.actions == [] and (.reason | test("legacy model:: label"))' "$T/plan-legacy-model.json" >/dev/null \
  && ok "plan: a provider-native model label blocks scheduling until a human chooses a Loom tier" \
  || bad "plan: legacy model label silently fell back to a configured tier"

# --- 28a. One case per step of SKILL.md's `tick` ---------------------------
# Each of these is a rule the wave used to apply by reading prose. The
# assertion is the rule, not the wording: which action, on which subject.
act() { # act <step> <kind> → the subjects, comma-separated, in plan order
    jq -r --arg s "$1" --arg k "$2" \
       '[.actions[] | select(.step == $s and .kind == $k) | (.lane // (.ticket|tostring))]
        | join(",")' "$T/plan.json"
}
[ "$(act harvest kill-lane)" = "impl-41,impl-50" ] \
    && ok "plan: a stale lane and a lane past lane_turn_cap are both killed through kill-lane" \
    || bad "plan: kill list wrong ($(act harvest kill-lane))"
[ "$(act harvest clear-lane)" = "gate-40,merge-49,merge-51" ] \
    && ok "plan: every dead lane is cleared" \
    || bad "plan: clear list wrong ($(act harvest clear-lane))"
[ "$(jq -r '[.actions[] | select(.step=="harvest" and .kind=="transition") | .ticket] | join(",")' "$T/plan.json")" = "50" ] \
    && ok "plan: the turn-cap lane's ticket is blocked, not respawned" \
    || bad "plan: turn-cap block wrong ($(jq -c '[.actions[]|select(.step=="harvest" and .kind=="transition")]' "$T/plan.json"))"
[ "$(act harvest repair)" = "44,51" ] \
    && [ "$(jq -c '[.actions[] | select(.kind=="repair" and .ticket==44) | .argv] | .[0]' "$T/plan.json")" = '["transition","44","review"]' ] \
    && [ "$(jq -c '[.actions[] | select(.kind=="repair" and .ticket==51) | .argv] | .[0]' "$T/plan.json")" = '["transition","51","blocked"]' ] \
    && [ "$(jq -r '[.actions[] | select(.kind=="repair" and .ticket==51) | .report_already_present] | .[0]' "$T/plan.json")" = true ] \
    && ok "plan: half-finished tracker transitions become repair actions" \
    || bad "plan: repair action wrong ($(jq -c '[.actions[]|select(.kind=="repair")]' "$T/plan.json"))"
# A ticket a repair stands against is left alone by BOTH fill paths: its label
# is one write behind what already happened, so a lane spawned off it would be
# working on a ticket that has already left this step.
[ "$(jq '[.actions[] | select(.lane == "impl-44")] | length' "$T/plan.json")" = "0" ] \
    && ok "plan: a ticket awaiting a repair is not also filled into a lane" \
    || bad "plan: #44 got a lane while its repair was still pending"
# Step 3: gateable only, and the round comes off the ids already spawned, so a
# respawn can never overwrite a live lane's pid file.
[ "$(act gate spawn)" = "gate-40-r2" ] \
    && ok "plan: the gateable ticket is gated, at the next round number" \
    || bad "plan: gate spawn wrong ($(act gate spawn))"
[ "$(p '.actions[] | select(.lane=="gate-40-r2") | .spawn.pregate')" = "logic" ] \
    && ok "plan: the gate spawn carries the ticket's own tier as its pregate" \
    || bad "plan: gate pregate wrong ($(p '.actions[] | select(.lane=="gate-40-r2") | .spawn.pregate'))"
# Step 4: two rejections mean stop, not respawn, even when their classes differ
# (#43/#52); one does not (#42), and the rework respawn takes the ticket's OWN resolved model — a
# rework round is exactly where the escalation chain differs from lane_model.
[ "$(act fill transition)" = "43,52" ] \
    && ok "plan: two total rejections require help before round three, even across different classes" \
    || bad "plan: round-three help stop wrong ($(act fill transition))"
[ "$(p '.actions[] | select(.lane=="impl-42") | .spawn.tier')" = "high" ] \
    && ok "plan: a rework respawn carries .tier_selection.effective, not lane_tier" \
    || bad "plan: rework tier wrong ($(p '.actions[] | select(.lane=="impl-42") | .spawn.tier'))"
# Step 5: the oldest merge-queue ticket whose hold is null. #47 is held, #49
# has spent its attempt cap and is blocked so the queue ADVANCES, #48 merges.
[ "$(act merge spawn)" = "merge-48" ] \
    && ok "plan: the merge lane takes the oldest unheld merge-queue ticket" \
    || bad "plan: merge spawn wrong ($(act merge spawn))"
[ "$(p '.actions[] | select(.lane=="merge-48") | .spawn.merge_lock')" = "true" ] \
    && ok "plan: the merge spawn holds the merge lock" \
    || bad "plan: merge spawn is missing --merge-lock"
[ "$(act merge transition)" = "49" ] \
    && ok "plan: a ticket at merge_attempt_cap is blocked so the queue advances past it" \
    || bad "plan: merge-cap block wrong ($(act merge transition))"
[ "$(jq -r '[.deferred[] | select(.ticket == 47) | .why] | .[0]' "$T/plan.json")" \
    != "null" ] \
    && ok "plan: a held merge-queue ticket is deferred with its reason, never silently dropped" \
    || bad "plan: the held ticket #47 vanished from the plan entirely"
# Step 6: the epic with criteria is probed; the one without is residue, because
# a brief written from the defect history alone cannot catch what nobody has
# broken yet.
[ "$(act probe spawn)" = "probe-ledger-core" ] \
    && ok "plan: an epic awaiting a probe is probed, under its slugified id" \
    || bad "plan: probe spawn wrong ($(act probe spawn))"
[ "$(jq -r '[.residue[] | select(.kind=="probe-criteria") | .epic] | join(",")' "$T/plan.json")" \
    = "Reporting surface" ] \
    && ok "plan: an epic with no acceptance criteria is residue, not a spawned probe" \
    || bad "plan: probe-criteria residue wrong"

# --- 28b. Residue is what a script cannot write ----------------------------
# rc 7 is the pregate's rejection, read off the lane log; a dead merge lane
# needs a LIVE re-check before anything is written; every block needs its
# report. None of those are argv.
res() { jq -r --arg k "$1" '[.residue[] | select(.kind == $k) | ((.ticket // .epic // .build)|tostring)] | join(",")' "$T/plan.json"; }
[ "$(res pregate-rejection)" = "40" ] \
    && ok "plan: an rc-7 lane leaves a pregate rejection to post, not a verifier to spawn" \
    || bad "plan: pregate residue wrong ($(res pregate-rejection))"
[ "$(res merge-failed)" = "" ] \
    && ok "plan: a merge lane that already recorded merge-failed leaves no duplicate residue" \
    || bad "plan: merge-failed residue wrong ($(res merge-failed))"
# Planted violation: remove only the semantic outcome supplied by the lane.
# The same dead merge then becomes genuinely unhandled and must leave residue,
# proving the suppression above depends on the marker rather than the rc.
jq '(.lanes[] | select(.id == "merge-49")) |= del(.outcome)' \
    "$FX/snap.json" > "$FX/snap-no-merge-outcome.json"
PLAN "$FX/snap-no-merge-outcome.json" > "$T/plan-no-merge-outcome.json" 2>/dev/null
[ "$(jq -r '[.residue[] | select(.kind == "merge-failed") | .ticket] | join(",")' "$T/plan-no-merge-outcome.json")" = "49" ] \
    && ok "plan violation: removing the recorded outcome recreates duplicate merge-failed residue" \
    || bad "plan violation: the planted unhandled merge did not recreate residue"
[ "$(jq '[.actions[] | select(.ticket==51 and .kind=="spawn")] | length' "$T/plan.json")" = 0 ] \
    && [ "$(jq '[.residue[] | select(.ticket==51 and .kind=="merge-failed")] | length' "$T/plan.json")" = 0 ] \
    && ok "plan: an unreleased blocked report suppresses retries and duplicate failure accounting" \
    || bad "plan: half-blocked ticket #51 was retried or double-counted"
[ "$(res blocked-report)" = "50,43,52,49" ] \
    && ok "plan: every blocking action carries a blocked report to write" \
    || bad "plan: blocked-report residue wrong ($(res blocked-report))"
# Every `transition … blocked` says so, so an executor cannot apply the label
# without the report the human reads to make the decision.
[ "$(jq '[.actions[] | select(.kind == "transition" and .argv[-1] == "blocked")] | map(.needs_report) | unique | @csv' "$T/plan.json")" \
    = '"true"' ] \
    && ok "plan: no ticket is blocked without a report being demanded with it" \
    || bad "plan: a blocking action carries no needs_report flag"

# --- 28c. Ordering is asserted, not incidental -----------------------------
# The step order is SKILL.md's, and inside the fill, rework outranks the
# backlog and `fix:` outranks the rest of the ready set. Latency is the whole
# point of the proposal, so an executor that runs the list in order must do
# the most urgent thing first.
steps=$(jq -r '[.actions[].step] | join(",")' "$T/plan.json")
case "$steps" in
    harvest*gate*fill*merge*probe*) ok "plan: actions run harvest → gate → fill → merge → probe" ;;
    *) bad "plan: step order is $steps" ;;
esac
[ "$(jq -r '[.actions[] | select(.step=="fill" and .kind=="spawn") | .lane] | join(",")' "$T/plan.json")" \
    = "impl-42,impl-45" ] \
    && ok "plan: rework outranks the backlog, and fix tickets outrank the rest of the ready set" \
    || bad "plan: fill order wrong ($(jq -r '[.actions[]|select(.step=="fill" and .kind=="spawn")|.lane]|join(",")' "$T/plan.json"))"
# `order` is written into every action, so a consumer that reorders them is
# visibly wrong rather than quietly so.
[ "$(jq '[.actions[].order] == [range(1; (.actions|length)+1)]' "$T/plan.json")" = "true" ] \
    && ok "plan: every action carries its position, numbered from 1" \
    || bad "plan: action order numbers are not 1..n"
# Two ready tickets, only two slots and three candidates for them: the ones
# that did not fit are named in `deferred`, never silently dropped. #46 is not
# among them — it is blocked by an open blocker, so it was never a candidate.
[ "$(jq '[.deferred[] | select(.ticket == 46)] | length' "$T/plan.json")" = "0" ] \
    && ok "plan: a ticket with an open blocker is not in the ready set at all" \
    || bad "plan: #46 was treated as ready while its blocker is open"

# --- 28d. Determinism: same document in, same plan out ---------------------
# The proposal's claim is that scheduling is a pure FUNCTION of the snapshot.
# A second run that differed would mean something outside the document leaked
# into the decision.
PLAN "$FX/snap.json" > "$T/plan2.json" 2>/dev/null
cmp -s "$T/plan.json" "$T/plan2.json" \
    && ok "plan: the same snapshot yields a byte-identical plan" \
    || bad "plan: two runs over one snapshot disagreed"

# --- 28e. Every action is a call its script actually dispatches ------------
# The plan is only useful if an executor can run it verbatim. A verb renamed
# in lane.sh or tick.sh with the planner left behind would produce actions
# that die at the boundary, which is exactly what P81 exists to stop paying a
# model to work around.
LANESH="$(dirname "$TICK")/lane.sh"
undispatched=""
while read -r via verb; do
    case "$via" in
        lane.sh) grep -qE "^[[:space:]]+$verb\)[[:space:]]*shift" "$LANESH" || undispatched="$undispatched [$via $verb]" ;;
        tick.sh) grep -qE "^[[:space:]]+$verb\)[[:space:]]*shift" "$TICK" || undispatched="$undispatched [$via $verb]" ;;
        *)       undispatched="$undispatched [unknown script $via]" ;;
    esac
done < <(jq -r '.actions[] | select(.argv != null) | "\(.via) \(.argv[0])"' "$T/plan.json" | sort -u)
[ -z "$undispatched" ] \
    && ok "plan: every action names a verb its script dispatches" \
    || bad "plan: actions name verbs nothing dispatches —$undispatched"

# --- 28f. A lane id spawn-lane would refuse is a PLANNER bug ---------------
# Caught at plan time, not at spawn time: an id with a space parsed as
# {id: "probe-Ledger", pid: "core", state: "<pid>"} and counted as a live lane
# for the rest of the build. An epic whose title slugifies to nothing is the
# reachable case.
jq '.summary.epics_awaiting_probe = ["¡¿!"] | .epics = [{"name":"¡¿!","milestone":"¡¿!","acceptance":"- [ ] x","needs_probe":true,"complete":true,"open_tickets":0}]' \
    "$FX/snap.json" > "$FX/snap-badslug.json"
PLAN "$FX/snap-badslug.json" > "$T/plan-badslug.json" 2>/dev/null
[ "$(jq '[.actions[] | select(.step=="probe")] | length' "$T/plan-badslug.json")" = "0" ] \
   && [ "$(jq '[.deferred[] | select(.step=="probe")] | length' "$T/plan-badslug.json")" = "1" ] \
    && ok "plan: an unspawnable epic slug is deferred by name instead of becoming a doomed spawn" \
    || bad "plan: a bad epic slug did not reach deferred ($(jq -c '.deferred' "$T/plan-badslug.json"))"
# The charset guard over the whole plan, applied to every id it emits.
badids=$(jq -r '[.actions[] | select(.kind=="spawn") | .lane
                 | select(test("^(impl|gate|merge)-[0-9]+(-r[0-9]+)?$")
                          or test("^probe-[A-Za-z0-9][A-Za-z0-9_-]*$") | not)] | join(",")' \
         "$T/plan.json")
[ -z "$badids" ] \
    && ok "plan: every spawn id is one spawn-lane accepts" \
    || bad "plan: unspawnable ids in the plan — $badids"
# Planted violation: remove the filter and the doomed spawn comes back — the
# guard is the `spawnable` select, not the fixture being tidy.
sed 's/| select(spawnable($lid))/| select(true)/' "$PLANJQ" > "$FX/plan-nofilter.jq"
nf=$(jq -L "$(dirname "$TICK")" -f "$FX/plan-nofilter.jq" "$FX/snap-badslug.json" 2>/dev/null \
     | jq -r '[.actions[] | select(.step=="probe") | .lane] | join(",")')
[ "$nf" = "probe-" ] \
    && ok "plan: with the id filter removed, the refused id reaches the plan — the guard is doing the work" \
    || bad "plan: the planted violation produced [$nf], so the filter proves nothing"

# --- 28g. An unreadable snapshot: empty plan, named reason, never partial --
# Half a document schedules against half a board. Every rule in the planner is
# total only over a whole snapshot, so the refusal is the whole answer.
for case in "not json at all" "[1,2,3]" '{"tickets":[]}'; do
    out=$(printf '%s\n' "$case" | PLAN 2>/dev/null)
    if [ "$(printf '%s' "$out" | jq '(.actions|length) + (.residue|length) + (.deferred|length)')" = "0" ] \
       && [ "$(printf '%s' "$out" | jq -r '.reason | length > 0')" = "true" ]; then
        ok "plan: '$(printf '%s' "$case" | head -c 20)' yields an empty plan with a named reason"
    else
        bad "plan: unreadable input produced $(printf '%s' "$out" | head -c 120)"
    fi
done
# A build that has not started is not an error: an empty universe is a valid
# board, and a heartbeat wave over it must no-op rather than die.
out=$(jq '.build = null' "$FX/snap.json" | PLAN 2>/dev/null)
case "$(printf '%s' "$out" | jq -r .reason)" in
    *"Build N"*) ok "plan: no open Build issue is reported as an empty universe, not a failure" ;;
    *) bad "plan: null build gave reason $(printf '%s' "$out" | jq -r .reason)" ;;
esac
# Nothing to schedule is its own answer, and it is the one that lets a wave be
# skipped: no actions, no residue, and a reason saying so.
jq '.lanes = [] | .summary.stranded = [] | .summary.repairs = []
    | .summary.epics_awaiting_probe = [] | .summary.ready_set_empty = true
    | .summary.lanes_running = 0 | .summary.all_blocked = false
    | .summary.open_tickets = 1
    | .tickets = [.tickets[] | select(.id == 46)]' "$FX/snap.json" > "$FX/snap-quiet.json"
qout=$(PLAN "$FX/snap-quiet.json" 2>/dev/null)
[ "$(printf '%s' "$qout" | jq '(.actions|length) + (.residue|length)')" = "0" ] \
   && [ "$(printf '%s' "$qout" | jq -r '.reason // ""')" != "" ] \
    && ok "plan: a board with nothing to do says so, with no actions and no residue" \
    || bad "plan: quiet board planned $(printf '%s' "$qout" | jq -c '.actions')"

# --- 28h. The two reports that end a build are residue ---------------------
# Both are prose, and both must survive an otherwise empty plan — an empty
# plan is what lets a wave be skipped, so a completion that lived only in the
# actions list would be skipped with it.
jq '.lanes = [] | .tickets = [] | .summary.stranded = [] | .summary.repairs = []
    | .summary.epics_awaiting_probe = [] | .summary.ready_set_empty = true
    | .summary.lanes_running = 0 | .summary.open_tickets = 0' "$FX/snap.json" > "$FX/snap-done.json"
[ "$(PLAN "$FX/snap-done.json" | jq -r '[.residue[] | select(.kind=="completion-report")] | length')" = "1" ] \
    && ok "plan: a finished board leaves the completion report as residue" \
    || bad "plan: no completion residue on a finished board"
jq '.summary.all_blocked = true | .lanes = [] | .summary.stranded = []
    | .summary.repairs = [] | .summary.epics_awaiting_probe = []
    | .summary.ready_set_empty = true | .summary.lanes_running = 0
    | .summary.open_tickets = 1
    | .tickets = [.tickets[] | select(.id == 46)]' "$FX/snap.json" > "$FX/snap-halted.json"
[ "$(PLAN "$FX/snap-halted.json" | jq -r '[.residue[] | select(.kind=="halted-report")] | length')" = "1" ] \
    && ok "plan: an all-blocked board leaves the halted report as residue" \
    || bad "plan: no halted residue on an all-blocked board"

# --- 28i. Caps bound the plan, and what they cut is named ------------------
# `max_aux_lanes` is shared by gates, merges and probes, and `max_lanes` is
# implementers alone. A plan that ignored them would spawn past the caps the
# whole scheduler is built on.
jq '.config.max_aux_lanes = 1 | .summary.impl_slots_free = 0' "$FX/snap.json" > "$FX/snap-caps.json"
capplan=$(PLAN "$FX/snap-caps.json")
[ "$(printf '%s' "$capplan" | jq '[.actions[] | select(.kind=="spawn")] | length')" = "1" ] \
   && [ "$(printf '%s' "$capplan" | jq -r '[.actions[] | select(.kind=="spawn") | .step] | join(",")')" = "gate" ] \
    && ok "plan: one aux slot buys one lane, and the gate step takes it first" \
    || bad "plan: cap plan spawned $(printf '%s' "$capplan" | jq -c '[.actions[]|select(.kind=="spawn")|.lane]')"
[ "$(printf '%s' "$capplan" | jq '[.deferred[] | select(.why | test("no aux slot|no implementation slot"))] | length')" -ge 3 ] \
    && ok "plan: every candidate a cap cut is named in deferred with the cap that cut it" \
    || bad "plan: caps dropped candidates silently ($(printf '%s' "$capplan" | jq -c '[.deferred[].why]'))"
# A merge already in flight: scheduling continues around it, a second merge waits.
[ "$(jq '.summary.merge_in_flight = true' "$FX/snap.json" | PLAN | jq '[.actions[] | select(.step=="merge" and .kind=="spawn")] | length')" = "0" ] \
    && ok "plan: no second merge is planned while one holds the lock" \
    || bad "plan: planned a merge while another was in flight"

# --- 28j. plan is READ-ONLY, and makes no tracker call at all -------------
# tick.sh never mutates the tracker — that is its charter, and section 07
# enforces it by scanning every captured argv. `plan` must not become the
# exception that dissolves the guarantee: it derives, it does not write. It
# reads a document, so the honest assertion is stronger than "no mutating
# call": no call whatsoever.
PFX="$T/pfx"; CALLS="$T/plan-calls.log"
make_glab_fixture "$PFX"
: > "$CALLS"
GLAB_CMD="$PFX/glab-stub.sh" STUB_LOG="$CALLS" "$TICK" plan "$FX/snap.json" >/dev/null 2>&1
[ ! -s "$CALLS" ] \
    && ok "plan: no glab call of any kind — the planner reads the document, not the tracker" \
    || bad "plan: reached the tracker ($(head -1 "$CALLS"))"
# The control, so an empty log cannot be a broken stub: the same seam, the
# same log, and a verb that DOES read the tracker fills it.
: > "$CALLS"
GLAB_CMD="$PFX/glab-stub.sh" STUB_LOG="$CALLS" "$TICK" snapshot >/dev/null 2>&1
[ -s "$CALLS" ] \
    && ok "plan: the call log records reads when a verb makes them — the empty log above means silence" \
    || bad "plan: the stub log stayed empty even for snapshot, so the check above proves nothing"

# --- 28k. The planner reads the wave's own snapshot, --brief and all -------
# The wave's step-1 read is `snapshot --brief`, which drops rows for tickets it
# cannot act on this turn. If the planner needed the full document the two
# would have to disagree about what is schedulable — so this is the assertion
# that P51 and P81 fit together.
GLAB_CMD="$PFX/glab-stub.sh" STUB_LOG="$T/calls-full" "$TICK" snapshot > "$T/live-full.json" 2>/dev/null
GLAB_CMD="$PFX/glab-stub.sh" STUB_LOG="$T/calls-brief" "$TICK" snapshot --brief > "$T/live-brief.json" 2>/dev/null
"$TICK" plan "$T/live-full.json" | jq -S '.actions' > "$T/acts-full.json" 2>/dev/null
"$TICK" plan "$T/live-brief.json" | jq -S '.actions' > "$T/acts-brief.json" 2>/dev/null
if [ -s "$T/acts-full.json" ] && cmp -s "$T/acts-full.json" "$T/acts-brief.json"; then
    ok "plan: a --brief snapshot plans exactly what the full one plans"
else
    bad "plan: brief and full snapshots disagree ($(jq -c '[.[].lane]' "$T/acts-full.json" 2>/dev/null) vs $(jq -c '[.[].lane]' "$T/acts-brief.json" 2>/dev/null))"
fi
# And it plans real work off that live snapshot, so the fixture above is not
# the only document shape it has ever seen: #12 is in review with an open MR
# and no verdict, and #10 is ready, unblocked (its `## Blocked by` names #7,
# which is not in the open set) and unclaimed.
[ "$("$TICK" plan "$T/live-full.json" | jq -r '[.actions[] | select(.kind=="spawn") | .lane] | join(",")')" = "gate-12,impl-10" ] \
    && ok "plan: over a live snapshot it schedules the gate the board actually calls for" \
    || bad "plan: live snapshot planned $("$TICK" plan "$T/live-full.json" | jq -c '[.actions[]|select(.kind=="spawn")|.lane]')"

# --- 28l. The program is a file, and a missing one is named ---------------
# Same contract as every other jq program beside tick.sh (P71/P72): it parses
# on its own, and a verb whose program is missing says which file is missing
# rather than leaving jq to complain about its -f argument.
err=$(jq -L "$(dirname "$TICK")" -n -f "$PLANJQ" </dev/null 2>&1 || true)
case "$err" in
    *"syntax error"*|*"unexpected"*|*"module not found"*) bad "plan.jq: does not parse ($(printf '%s' "$err" | head -1))" ;;
    *) ok "plan.jq: parses standalone — checkable without running a plan" ;;
esac
# D-TEST-15: hidden in a PRIVATE mirror of the scripts directory, never in the
# shipped one. Sections run at once and scripts/ is the only thing they share,
# so moving the real plan.jq aside for the length of this check took `plan`
# away from every other section too.
MSCRIPTS="$(mirror_scripts "$T/plan-mirror")"
mv "$MSCRIPTS/plan.jq" "$T/plan.jq.hidden"
out=$("$MSCRIPTS/tick.sh" plan "$FX/snap.json" 2>&1); rc=$?
mv "$T/plan.jq.hidden" "$MSCRIPTS/plan.jq"
case "$rc:$out" in
    0:*)      bad "plan: ran with no plan.jq on disk" ;;
    *plan.jq*) ok "plan: a missing plan.jq is named as the missing file" ;;
    *)        bad "plan: missing program failed unclearly ($(printf '%s' "$out" | head -1))" ;;
esac

test_finish
