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
#   #39/#40 review and gateable; #40 fully unlocks #46, while #39 only
#   contributes to #47, which still has open blocker #48 (step 3 priority)
#   #40's prior gate lane is dead at rc 7               (step 2 + round id)
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
    {"id": 39, "title": "gateable but unlocks nothing", "state": "review", "tier": "logic", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null,
     "related_merge_requests": [{"id": 89, "state": "open", "branch": "t39", "sha": "9999aaa"}],
     "gate": {"eligible": true, "reason": null, "head": "9999aaa", "last_verdict": null}},
    {"id": 40, "title": "pregate rejected", "state": "review", "tier": "logic", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "active_scope_reset": {"at":"2026-08-10T09:59:00Z","body":"Replacement gate scope: prove only the provider availability round-trip; DST and booking belong to other tickets.\n\n<!-- orch-scope-reset 2026-08-10T09:59:00Z -->"},
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
     "contract": "## Acceptance criteria\n\n- [ ] Persist the timing record\n\n## Mandatory adversarial tests\n\n- [ ] A failed write emits no success record\n",
     "active_scope_reset": {"at":"2026-08-10T09:58:00Z","body":"Supervisor scope: own lib/scheduling/booking.ts list and persisted-transition seam.\n\n<!-- orch-scope-reset 2026-08-10T09:58:00Z -->"},
     "rejections": {"total": 1, "last_class": "marks-attribution", "same_class_tail": 1, "generation":"Z2VuNDI=",
                    "latest":{"at":"2026-08-10T09:57:00Z","sha":"aaaa0042","class":"marks-attribution"}},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 43, "title": "stranded, two same class", "state": "in-progress", "tier": "logic", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "high", "source": "rework_tier"},
     "rejections": {"total": 2, "last_class": "marks-attribution", "same_class_tail": 2, "generation":"Z2VuNDM=",
                    "latest":{"at":"2026-08-10T09:58:00Z","sha":"aaaa0043","class":"marks-attribution"}},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 52, "title": "stranded, two different classes", "state": "in-progress", "tier": "logic", "fix": false,
     "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "high", "source": "rework_tier"},
     "rejections": {"total": 2, "last_class": "api-contract", "same_class_tail": 1, "generation":"Z2VuNTI=",
                    "latest":{"at":"2026-08-10T09:59:00Z","sha":"aaaa0052","class":"api-contract"}},
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
     "active_scope_reset": {"at":"2026-08-10T09:57:00Z","body":"Supervisor scope: own lib/scheduling/booking.ts list and persisted-transition seam.\n\n<!-- orch-scope-reset 2026-08-10T09:57:00Z -->"},
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 46, "title": "ready, blocked by an open blocker", "state": "ready-for-agent", "tier": "ui",
     "fix": false, "unblocked": false, "assignees": [], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "blocked_by": [{"id":40,"source":"native","closed":false}],
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 47, "title": "ready, blocked by two open blockers", "state": "ready-for-agent", "tier": "ui",
     "fix": false, "unblocked": false, "assignees": [], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "blocked_by": [{"id":39,"source":"native","closed":false},{"id":48,"source":"native","closed":false}],
     "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
     "merge_attempts": 0, "merge_hold": null, "related_merge_requests": [],
     "gate": {"eligible": false, "reason": "not in review", "head": null, "last_verdict": null}},
    {"id": 48, "title": "the other open blocker", "state": "in-progress", "tier": "logic",
     "fix": false, "unblocked": true, "assignees": ["a"], "tier_selection": {"effective": "medium", "source": "lane_tier"},
     "blocked_by": [], "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
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
    "open_tickets": 15, "by_state": {}, "all_blocked": false,
    "epics_awaiting_probe": ["Ledger core", "Reporting surface"],
    "ready_set_empty": false, "lanes_running": 2, "gateable": 2,
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

# A snapshot-derived supervised repair is the truthful exit from a spent
# rejection cap. The next plan gates the repaired HEAD and freezes the repair
# evidence into that immutable action instead of scheduling another impl round.
jq '.tickets = [{
      "id": 53, "title": "supervised response repair", "state": "review",
      "tier": "api", "fix": false, "unblocked": true, "assignees": ["human"],
      "tier_selection": {"effective": "high", "source": "rework_tier"},
      "rejections": {"total": 0, "last_class": null, "same_class_tail": 0},
      "active_supervised_repair": {
        "at": "2026-08-10T10:05:00Z",
        "body": "Fixed valid response defects at a84fcf3.\n\n<!-- orch-supervised-repair 2026-08-10T09:59:00Z -->\n\nRemoved the shared recipient scope guard at c0ffee2.\n\n<!-- orch-supervised-repair 2026-08-10T10:05:00Z -->"
      },
      "merge_attempts": 1, "merge_hold": null,
      "related_merge_requests": [{"id": 103, "state": "open", "branch": "t53", "sha": "ffff777"}],
      "gate": {"eligible": true, "reason": null, "head": "ffff777", "last_verdict": null}
    }]
    | .lanes = [] | .epics = [] | .supervised_leases = []
    | .config.max_aux_lanes = 1
    | .summary = {"open_tickets":1,"lanes_running":0,"impl_slots_free":0,
                  "merge_in_flight":false,"stranded":[],"repairs":[],
                  "epics_awaiting_probe":[],"ready_set_empty":true}' \
    "$FX/snap.json" > "$FX/snap-supervised-repair.json"
PLAN "$FX/snap-supervised-repair.json" > "$T/plan-supervised-repair.json" 2>/dev/null
if jq -e '.actions | length == 1
          and .[0].lane == "gate-53"
          and (.[0].spawn.brief.active_supervised_repair.body as $body
               | ($body | index("a84fcf3")) < ($body | index("c0ffee2")))' \
          "$T/plan-supervised-repair.json" >/dev/null 2>&1; then
    ok "plan: completed supervised repair advances to gate with immutable evidence"
else
    bad "plan: supervised repair did not produce the expected gate action ($(jq -c '.actions' "$T/plan-supervised-repair.json"))"
fi
# Renewed diagnosis flows through the existing blocked-ticket supervisor. Its
# repair worker must receive the accumulated prior repair evidence as well as
# the new blocked report.
jq '.build.supervision_policy = "autonomous-repair-v1"
    | .tickets[0].state = "blocked"
    | .tickets[0].blocked_report = {
        "at":"2026-08-10T11:00:00Z", "category":"rejection-cap",
        "body":"The next exact gate failure requires renewed diagnosis.",
        "ticket_state":"blocked", "released":false}
    | .tickets[0].gate = {"eligible":false,"reason":"not in review","head":null,"last_verdict":null}
    | .summary.impl_slots_free = 1' \
    "$FX/snap-supervised-repair.json" > "$FX/snap-renewed-diagnosis.json"
PLAN "$FX/snap-renewed-diagnosis.json" > "$T/plan-renewed-diagnosis.json" 2>/dev/null
if jq -e '.actions[] | select(.lane=="repair-53")
          | (.spawn.brief.active_supervised_repair.body
             | contains("a84fcf3") and contains("c0ffee2"))' \
          "$T/plan-renewed-diagnosis.json" >/dev/null 2>&1; then
    ok "plan: renewed supervised diagnosis retains all prior repair evidence"
else
    bad "plan: renewed diagnosis discarded accumulated repair evidence"
fi
# A supervised repair is an evidence-bearing intervention, not permission to
# restart blind cycles. Its first later FAIL returns to diagnosis immediately.
jq '(.tickets[] | select(.id==42) | .active_supervised_repair) = {
      "at":"2026-08-10T09:59:00Z",
      "body":"Verified repair a84fcf3 adds the deployment runner and its public contract test.\n\n<!-- orch-supervised-repair 2026-08-10T09:59:00Z -->"
    }' "$FX/snap.json" > "$FX/snap-post-supervised-fail.json"
PLAN "$FX/snap-post-supervised-fail.json" > "$T/plan-post-supervised-fail.json" 2>/dev/null
if jq -e '.actions[] | select(.ticket==42 and .kind=="diagnosis-hold")
          | (.why | contains("first gate failure after supervised repair"))
            and (.argv[5] == "Z2VuNDI=")' \
          "$T/plan-post-supervised-fail.json" >/dev/null 2>&1 \
   && ! jq -e '.actions[] | select(.lane=="impl-42")' \
          "$T/plan-post-supervised-fail.json" >/dev/null 2>&1; then
    ok "plan: first post-supervised FAIL returns to diagnosis instead of blind rework"
else
    bad "plan: post-supervised FAIL restarted implementation ($(jq -c '.actions[] | select(.ticket==42 or .lane=="impl-42")' "$T/plan-post-supervised-fail.json"))"
fi
# The current-head gate deferral is executable input, not prose a new worker
# must rediscover.  It changes the ordinary stranded action into an explicit
# reconciliation action without consuming a gate rejection round.
jq '(.tickets[] | select(.id==42) | .active_base_reconcile) = {
      "at":"2026-08-17T17:56:00Z", "head":"abc1234", "base":"main", "behind":"4",
      "body":"Reconcile origin/main and resubmit.\n\n<!-- orch-base-stale abc1234 base=main behind=4 -->"
    }' "$FX/snap.json" > "$FX/snap-base-reconcile.json"
PLAN "$FX/snap-base-reconcile.json" > "$T/plan-base-reconcile.json" 2>/dev/null
if jq -e '.actions[] | select(.lane=="impl-42")
          | (.why | contains("stale-base reconciliation"))
            and (.spawn.brief.active_base_reconcile.base == "main")
            and (.spawn.brief.inputs | any(contains("merge the named origin base")))' \
          "$T/plan-base-reconcile.json" >/dev/null 2>&1; then
    ok "plan: stale-base stranded ticket becomes an immutable reconciliation action"
else
    bad "plan: stale-base decision did not reach implementation ($(jq -c '.actions[] | select(.lane=="impl-42")' "$T/plan-base-reconcile.json"))"
fi
# Provider selection changes only the adapter named on the shared action; both
# Claude and Codex consume the same tracker-derived repair evidence.
for provider in claude codex; do
    jq --arg p "$provider" '.build.provider = $p' "$FX/snap-supervised-repair.json" \
        > "$FX/snap-supervised-repair-$provider.json"
    PLAN "$FX/snap-supervised-repair-$provider.json" \
        > "$T/plan-supervised-repair-$provider.json" 2>/dev/null
done
if jq -e '.actions[0].spawn.provider == "claude"
          and (.actions[0].spawn.brief.active_supervised_repair.body
               | contains("a84fcf3") and contains("c0ffee2"))' \
          "$T/plan-supervised-repair-claude.json" >/dev/null 2>&1 \
   && jq -e '.actions[0].spawn.provider == "codex"
             and (.actions[0].spawn.brief.active_supervised_repair.body
                  | contains("a84fcf3") and contains("c0ffee2"))' \
          "$T/plan-supervised-repair-codex.json" >/dev/null 2>&1; then
    ok "plan: Claude and Codex share the provider-neutral supervised-repair action"
else
    bad "plan: provider paths derived different supervised-repair evidence"
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
[ "$(act harvest clear-lane)" = "merge-49,merge-51" ] \
    && ok "plan: dead lanes are cleared after any required rejection evidence is posted" \
    || bad "plan: clear list wrong ($(act harvest clear-lane))"
[ "$(jq -r '[.actions[] | select(.step=="harvest" and .kind=="transition") | .ticket] | join(",")' "$T/plan.json")" = "50" ] \
    && ok "plan: the turn-cap lane's ticket is blocked, not respawned" \
    || bad "plan: turn-cap block wrong ($(jq -c '[.actions[]|select(.step=="harvest" and .kind=="transition")]' "$T/plan.json"))"
[ "$(act harvest repair)" = "44,51" ] \
    && [ "$(jq -c '[.actions[] | select(.kind=="repair" and .ticket==44) | .argv] | .[0]' "$T/plan.json")" = '["transition","44","review","--if-current","ready-for-agent"]' ] \
    && [ "$(jq -c '[.actions[] | select(.kind=="repair" and .ticket==51) | .argv] | .[0]' "$T/plan.json")" = '["transition","51","blocked","--if-current","merge-queue"]' ] \
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
[ "$(act gate spawn)" = "gate-40-r2,gate-39" ] \
    && ok "plan: dependency unlock outranks ticket age, and the retry keeps its next round number" \
    || bad "plan: gate spawn wrong ($(act gate spawn))"
[ "$(p '.actions[] | select(.lane=="gate-40-r2") | .spawn.pregate')" = "logic" ] \
    && ok "plan: the gate spawn carries the ticket's own tier as its pregate" \
    || bad "plan: gate pregate wrong ($(p '.actions[] | select(.lane=="gate-40-r2") | .spawn.pregate'))"

# D-TICK-43: JOR-294 declared `api`, but its mandatory acceptance named a
# Playwright e2e spec. The API host pregate therefore omitted the required
# browser proof, and the sandboxed reviewer tried (and was unable) to launch
# Chromium itself. The contract raises the minimum gate/admission tier to UI
# at the provider-neutral planner seam without rewriting tracker prose.
jq '
  .tickets = [(.tickets[] | select(.id == 39)
    | .tier = "api"
    | .contract = "## Acceptance criteria\n\n- [ ] `npx playwright test e2e/e2-wiring.spec.ts --project=e2-wiring` passes\n\n## Risk tier\n\napi")]
  | .lanes = [] | .epics = [] | .supervised_leases = []
  | .config.max_aux_lanes = 1
  | .summary = {"open_tickets":1,"lanes_running":0,"impl_slots_free":0,
                "merge_in_flight":false,"stranded":[],"repairs":[],
                "epics_awaiting_probe":[],"ready_set_empty":true,
                "ui_pregate_occupied":false}
' "$FX/snap.json" > "$FX/snap-playwright-api-gate.json"
PLAN "$FX/snap-playwright-api-gate.json" > "$T/plan-playwright-api-gate.json" 2>/dev/null
if [ "$(jq -r '.actions[] | select(.lane=="gate-39") | .spawn.pregate' "$T/plan-playwright-api-gate.json")" = ui ]; then
    ok "D-TICK-43: API ticket with mandatory Playwright acceptance is host-gated as UI"
else
    bad "D-TICK-43: mandatory browser proof stayed on an API pregate ($(jq -c '.actions' "$T/plan-playwright-api-gate.json"))"
fi

jq '
  .tickets = [(.tickets[] | select(.id == 48 and .state == "merge-queue")
    | .tier = "api"
    | .contract = "## Mandatory adversarial tests\n\n- [ ] e2e/e2-wiring.spec.ts rejects an expired session\n\n## Risk tier\n\napi")]
  | .lanes = [] | .epics = [] | .supervised_leases = []
  | .config.max_aux_lanes = 1
  | .summary = {"open_tickets":1,"lanes_running":0,"impl_slots_free":0,
                "merge_in_flight":false,"stranded":[],"repairs":[],
                "epics_awaiting_probe":[],"ready_set_empty":true,
                "ui_pregate_occupied":false}
' "$FX/snap.json" > "$FX/snap-playwright-api-merge.json"
PLAN "$FX/snap-playwright-api-merge.json" > "$T/plan-playwright-api-merge.json" 2>/dev/null
if [ "$(jq -r '.actions[] | select(.lane=="merge-48") | .spawn.pregate' "$T/plan-playwright-api-merge.json")" = ui ]; then
    ok "D-TICK-43: merge preflight preserves mandatory host browser proof"
else
    bad "D-TICK-43: merge preflight downgraded mandatory browser proof ($(jq -c '.actions' "$T/plan-playwright-api-merge.json"))"
fi

jq '
  .tickets[0].contract = "## Context\n\nThe API is consumed by e2e/e2-wiring.spec.ts later.\n\n## Acceptance criteria\n\n- [ ] The JSON response is stable"
' "$FX/snap-playwright-api-gate.json" > "$FX/snap-playwright-context-only.json"
PLAN "$FX/snap-playwright-context-only.json" > "$T/plan-playwright-context-only.json" 2>/dev/null
if [ "$(jq -r '.actions[] | select(.lane=="gate-39") | .spawn.pregate' "$T/plan-playwright-context-only.json")" = api ]; then
    ok "D-TICK-43: incidental e2e context does not promote an API acceptance contract"
else
    bad "D-TICK-43: non-mandatory browser prose caused a false UI promotion"
fi

# An active supervisor rescope replaces conflicting original acceptance. The
# browser floor must read that effective contract in both directions: a reset
# can add mandatory browser evidence, or remove obsolete browser acceptance.
jq '
  .tickets[0].active_scope_reset = {
    "at":"2026-08-17T18:00:00Z",
    "body":"## Acceptance criteria\n\n- [ ] `npx playwright test e2e/rescoped.spec.ts` passes\n\n<!-- orch-scope-reset 2026-08-17T18:00:00Z -->"
  }
' "$FX/snap-playwright-context-only.json" > "$FX/snap-playwright-rescope-adds.json"
PLAN "$FX/snap-playwright-rescope-adds.json" > "$T/plan-playwright-rescope-adds.json" 2>/dev/null
if [ "$(jq -r '.actions[] | select(.lane=="gate-39") | .spawn.pregate' "$T/plan-playwright-rescope-adds.json")" = ui ]; then
    ok "D-TICK-44: active rescope adding Playwright raises the host gate to UI"
else
    bad "D-TICK-44: browser requirement added by active rescope was ignored"
fi

jq '
  .tickets[0].active_scope_reset = {
    "at":"2026-08-17T18:01:00Z",
    "body":"## Acceptance criteria\n\n- [ ] The JSON response is stable\n\n<!-- orch-scope-reset 2026-08-17T18:01:00Z -->"
  }
' "$FX/snap-playwright-api-gate.json" > "$FX/snap-playwright-rescope-removes.json"
PLAN "$FX/snap-playwright-rescope-removes.json" > "$T/plan-playwright-rescope-removes.json" 2>/dev/null
if [ "$(jq -r '.actions[] | select(.lane=="gate-39") | .spawn.pregate' "$T/plan-playwright-rescope-removes.json")" = api ]; then
    ok "D-TICK-44: active rescope removing Playwright restores the declared API gate"
else
    bad "D-TICK-44: superseded original browser acceptance still forced UI"
fi

# Planted violation: remove only the browser-derived gate floor. Both public
# fixture plans must return to API, proving the assertions above observe the
# owning rule instead of some unrelated UI default.
BROWSER_TIER_MUTANT=$(mirror_scripts "$T/browser-tier-mutant")
sed 's/if \$declared != null and requires_browser_evidence then "ui" else \$declared end;/\$declared; # mutate:browser-tier-floor/' \
  "$BROWSER_TIER_MUTANT/lib.jq" > "$BROWSER_TIER_MUTANT/lib.jq.mut"
mv "$BROWSER_TIER_MUTANT/lib.jq.mut" "$BROWSER_TIER_MUTANT/lib.jq"
"$BROWSER_TIER_MUTANT/tick.sh" plan "$FX/snap-playwright-api-gate.json" \
  > "$T/plan-playwright-api-mutant.json" 2>/dev/null
if [ "$(jq -r '.actions[] | select(.lane=="gate-39") | .spawn.pregate' "$T/plan-playwright-api-mutant.json")" = api ]; then
    ok "D-TICK-43 violation: deleting the browser floor recreates API-only admission"
else
    bad "D-TICK-43 violation: planted browser-floor deletion did not recreate the defect"
fi

RESCOPE_BROWSER_MUTANT=$(mirror_scripts "$T/rescope-browser-mutant")
sed 's#\.active_scope_reset\.body // ##' \
  "$RESCOPE_BROWSER_MUTANT/lib.jq" > "$RESCOPE_BROWSER_MUTANT/lib.jq.mut"
mv "$RESCOPE_BROWSER_MUTANT/lib.jq.mut" "$RESCOPE_BROWSER_MUTANT/lib.jq"
"$RESCOPE_BROWSER_MUTANT/tick.sh" plan "$FX/snap-playwright-rescope-adds.json" \
  > "$T/plan-playwright-rescope-adds-mutant.json" 2>/dev/null
"$RESCOPE_BROWSER_MUTANT/tick.sh" plan "$FX/snap-playwright-rescope-removes.json" \
  > "$T/plan-playwright-rescope-removes-mutant.json" 2>/dev/null
if [ "$(jq -r '.actions[] | select(.lane=="gate-39") | .spawn.pregate' "$T/plan-playwright-rescope-adds-mutant.json")" = api ] \
   && [ "$(jq -r '.actions[] | select(.lane=="gate-39") | .spawn.pregate' "$T/plan-playwright-rescope-removes-mutant.json")" = ui ]; then
    ok "D-TICK-44 violation: ignoring active scope recreates both stale-contract gate tiers"
else
    bad "D-TICK-44 violation: planted active-scope deletion did not recreate both defects"
fi
# Live brief shape: both dependents are filtered out of tickets[] and survive
# only in dependency_edges. With one aux slot, #289 must outrank older #239.
jq '
  .tickets = [
    (.tickets[] | select(.id == 39) | .id = 239 | .title = "older isolated gate"),
    (.tickets[] | select(.id == 40) | .id = 289 | .title = "gate releasing filtered dependent")
  ]
  | .dependency_edges = [{"id":231,"blocked_by":[{"id":289,"closed":false}]}]
  | .other_iids = [231]
  | .lanes = [] | .epics = [] | .supervised_leases = []
  | .config.max_aux_lanes = 1
  | .summary = {"open_tickets":3,"lanes_running":0,"impl_slots_free":0,
                "merge_in_flight":false,"stranded":[],"repairs":[],
                "epics_awaiting_probe":[],"ready_set_empty":true}
' "$FX/snap.json" > "$FX/snap-filtered-dependency.json"
PLAN "$FX/snap-filtered-dependency.json" > "$T/plan-filtered-dependency.json" 2>/dev/null
[ "$(jq -r '[.actions[] | select(.step=="gate" and .kind=="spawn") | .lane] | join(",")' "$T/plan-filtered-dependency.json")" = "gate-289" ] \
    && ok "plan: filtered dependent priority survives the live --brief snapshot shape" \
    || bad "plan: filtered dependency collapsed to iid order ($(jq -c '[.actions[]|select(.step=="gate")|.lane]' "$T/plan-filtered-dependency.json"))"

# Backward compatibility: an old producer has no dependency_edges. A malformed
# producer is treated the same way. Both fall back to full ticket rows.
jq '
  del(.dependency_edges) |
  .tickets += [{"id":231,"state":"ready-for-agent","unblocked":false,"assignees":[],
                "blocked_by":[{"id":289,"closed":false}],
                "gate":{"eligible":false},"related_merge_requests":[]}]
' "$FX/snap-filtered-dependency.json" > "$FX/snap-dependency-legacy.json"
PLAN "$FX/snap-dependency-legacy.json" > "$T/plan-dependency-legacy.json" 2>/dev/null
jq '.dependency_edges = "malformed"' "$FX/snap-dependency-legacy.json" > "$FX/snap-dependency-malformed.json"
PLAN "$FX/snap-dependency-malformed.json" > "$T/plan-dependency-malformed.json" 2>/dev/null
if [ "$(jq -r '[.actions[] | select(.step=="gate" and .kind=="spawn") | .lane] | join(",")' "$T/plan-dependency-legacy.json")" = "gate-289" ] \
   && [ "$(jq -r '[.actions[] | select(.step=="gate" and .kind=="spawn") | .lane] | join(",")' "$T/plan-dependency-malformed.json")" = "gate-289" ]; then
    ok "plan: missing and malformed dependency_edges fall back to legacy full ticket rows"
else
    bad "plan: dependency compatibility fallback changed ordering"
fi

# Planted mutant: regress only the priority scorer to actionable tickets[].
# It must pick older #239, proving the live-shaped assertion detects D-TICK.
DPM=$(mirror_scripts "$T/dependency-priority-mutant")
sed 's/\$dependency_edges\[\]/\$tickets[]/g' "$DPM/plan.jq" > "$DPM/plan.jq.mut"
mv "$DPM/plan.jq.mut" "$DPM/plan.jq"
"$DPM/tick.sh" plan "$FX/snap-filtered-dependency.json" > "$T/plan-filtered-dependency-mutant.json" 2>/dev/null
[ "$(jq -r '[.actions[] | select(.step=="gate" and .kind=="spawn") | .lane] | join(",")' "$T/plan-filtered-dependency-mutant.json")" = "gate-239" ] \
    && ok "plan mutant: dropping compact edges recreates iid-order gate starvation" \
    || bad "plan mutant: planted ticket-only scorer did not recreate the priority defect"
# D-TICK-38: an active scope reset is the gate's replacement contract too.
# JOR-240's planner carried the reset only for implementation actions, so its
# reviewer was mechanically briefed with superseded DST and booking criteria.
if [ "$(p '.actions[] | select(.lane=="gate-40-r2") | .spawn.brief.active_scope_reset.body')" = \
     "Replacement gate scope: prove only the provider availability round-trip; DST and booking belong to other tickets.

<!-- orch-scope-reset 2026-08-10T09:59:00Z -->" ]; then
    ok "D-TICK-38: gate action carries the active replacement scope"
else
    bad "D-TICK-38: gate action silently restored the pre-rescope contract"
fi
# Step 4: two rejections mean diagnosis, not respawn, even when their classes
# differ (#43/#52); one does not (#42), and the rework respawn takes the ticket's OWN resolved model — a
# rework round is exactly where the escalation chain differs from lane_model.
[ "$(act fill diagnosis-hold)" = "43,52" ] \
    && ok "plan: two total rejections require supervised diagnosis before round three" \
    || bad "plan: round-three diagnosis stop wrong ($(act fill diagnosis-hold))"
if jq -e '.actions[] | select(.ticket==43 and .kind=="diagnosis-hold")
          | .argv == ["diagnosis-hold","43","--if-current","in-progress",
                      "--expected-generation","Z2VuNDM="]' \
          "$T/plan.json" >/dev/null 2>&1; then
    ok "plan: diagnosis hold freezes the source state and exact latest FAIL identity"
else
    bad "plan: diagnosis hold omitted its stale-plan guards"
fi
[ "$(p '.actions[] | select(.lane=="impl-42") | .spawn.tier')" = "high" ] \
    && ok "plan: a rework respawn carries .tier_selection.effective, not lane_tier" \
    || bad "plan: rework tier wrong ($(p '.actions[] | select(.lane=="impl-42") | .spawn.tier'))"
# D-TICK-28: both fill paths must put the human's replacement scope in the
# immutable action. A rework action is not allowed to regress to its original
# body, and a released/rescoped ticket may re-enter through the ready path.
if [ "$(jq '[.actions[] | select(.lane=="impl-42" or .lane=="impl-45")
              | (.spawn.brief.active_scope_reset.body
                 | contains("lib/scheduling/booking.ts"))] | all' "$T/plan.json")" = true ]; then
    ok "D-TICK-28: new-work and rework actions both carry the active rescope note"
else
    bad "D-TICK-28: a fill action silently fell back to pre-rescope scope"
fi
if [ "$(p '.actions[] | select(.lane=="impl-42") | .spawn.brief.ticket_contract')" = \
     "## Acceptance criteria

- [ ] Persist the timing record

## Mandatory adversarial tests

- [ ] A failed write emits no success record" ]; then
    ok "D-TICK-40: implementation action freezes the full ticket contract"
else
    bad "D-TICK-40: implementation action carries only a pointer to tracker state"
fi
# Step 5: the oldest merge-queue ticket whose hold is null. #47 is held, #49
# has spent its attempt cap and is blocked so the queue ADVANCES, #48 merges.
[ "$(act merge spawn)" = "merge-48" ] \
    && ok "plan: the merge lane takes the oldest unheld merge-queue ticket" \
    || bad "plan: merge spawn wrong ($(act merge spawn))"
[ "$(p '.actions[] | select(.lane=="merge-48") | .spawn.merge_lock')" = "true" ] \
    && ok "plan: the merge spawn holds the merge lock" \
    || bad "plan: merge spawn is missing --merge-lock"
[ "$(p '.actions[] | select(.lane=="merge-48") | .spawn.pregate')" = "api" ] \
    && ok "plan: merge preflight carries the ticket tier to the host boundary" \
    || bad "plan: merge preflight tier missing ($(p '.actions[] | select(.lane=="merge-48") | .spawn.pregate'))"
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
    && [ "$(jq '[.actions[] | select(.kind == "clear-lane" and .lane == "gate-40")] | length' "$T/plan.json")" = 0 ] \
    && ok "plan: an rc-7 lane keeps its evidence until the pregate rejection is posted" \
    || bad "plan: pregate residue wrong ($(res pregate-rejection))"

# Planted violation: restoring eager rc-7 cleanup recreates the live failure
# where the source lane's launchd retirement kills its handoff wave before the
# prose verdict can be written.
PREGATE_CLEAR_MUT="$T/plan-pregate-clear-mutant.jq"
sed '/# mutate:clear-pregate-before-verdict/,+0d' "$PLANJQ" > "$PREGATE_CLEAR_MUT"
if jq -L "$(dirname "$PLANJQ")" -f "$PREGATE_CLEAR_MUT" "$FX/snap.json" \
     | jq -e 'any(.actions[]; .kind == "clear-lane" and .lane == "gate-40")' >/dev/null; then
    ok "plan violation: eager rc-7 cleanup recreates verdict-loss ordering"
else
    bad "plan violation: cleanup mutant did not restore the source-lane hazard"
fi
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
[ "$(res blocked-report)" = "50,49" ] \
    && ok "plan: generic blocking actions carry a blocked report to write" \
    || bad "plan: blocked-report residue wrong ($(res blocked-report))"
[ "$(jq '[.residue[] | select(.ticket==43 or .ticket==52)] | length' "$T/plan.json")" = 0 ] \
    && ok "plan: diagnosis-hold owns its exact report instead of leaving prose residue" \
    || bad "plan: diagnosis hold still depends on hand-composed residue"
# Every `transition … blocked` says so, so an executor cannot apply the label
# without the report the human reads to make the decision.
[ "$(jq '[.actions[] | select(.kind == "transition" and .argv[2] == "blocked")] | map(.needs_report) | unique | @csv' "$T/plan.json")" \
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

# A provider can finish its paid job and write rc/outcome while the host
# epilogue still owns the lane pid. That process needs cleanup, but it is no
# longer doing implementation/gate work and must not consume either cap. The
# same immutable plan clears it before filling the released slots. Keep its
# ticket in-progress to prove the live pid still suppresses a duplicate reuse
# of that lane id until cleanup actually runs.
CAP_REPO="$T/cap-repo"; CAP_HOME="$T/cap-home"
mkdir -p "$CAP_REPO" "$CAP_HOME/lanes"
seed_tracker_decl "$CAP_REPO"
cat > "$CAP_REPO/.loom.yml" <<'EOF'
max_lanes: 1
max_aux_lanes: 1
heartbeat_stale_minutes: 30
EOF
jq '. += [{
      "iid":196,"title":"finished implementation epilogue","project_id":1,"web_url":"https://x/196",
      "labels":["build-2","in-progress"],"assignees":[{"username":"agent-a"}],
      "updated_at":"2026-07-28T13:00:00Z","milestone":{"title":"Ledger core"},
      "description":"## Risk tier\n\nlogic\n\n## Blocked by\n\nNone - can start immediately\n"
    }]' "$PFX/open.json" > "$PFX/open-capacity.json"
sleep 60 & cap_impl_pid=$!
sleep 60 & cap_gate_pid=$!
printf '%s\n' "$cap_impl_pid" > "$CAP_HOME/lanes/impl-196.pid"
printf '%s\n' 0 > "$CAP_HOME/lanes/impl-196.rc"
printf '%s\n' blocked > "$CAP_HOME/lanes/impl-196.outcome"
printf '%s\n' "$cap_gate_pid" > "$CAP_HOME/lanes/gate-99.pid"
printf '%s\n' 0 > "$CAP_HOME/lanes/gate-99.rc"
printf '%s\n' verdict > "$CAP_HOME/lanes/gate-99.outcome"
STUB_OPEN="$PFX/open-capacity.json" GLAB_CMD="$PFX/glab-stub.sh" STUB_LOG="$T/calls-capacity" \
  LOOM_REPO="$CAP_REPO" LOOM_HOME="$CAP_HOME" "$TICK" snapshot --brief > "$T/capacity-snapshot.json" 2>/dev/null
LOOM_REPO="$CAP_REPO" LOOM_HOME="$CAP_HOME" "$TICK" plan "$T/capacity-snapshot.json" \
  > "$T/capacity-plan.json" 2>/dev/null
kill "$cap_impl_pid" "$cap_gate_pid" 2>/dev/null || true
wait "$cap_impl_pid" "$cap_gate_pid" 2>/dev/null || true
if jq -e '
    .summary.impl_slots_free == 1
    and .summary.lanes_running_by_type.impl == 0
    and .summary.lanes_running_by_type.gate == 0
    and (.summary.stranded | index(196) | not)
    and ([.lanes[] | select(.id == "impl-196" and .state == "running" and .rc == "0")] | length) == 1
  ' "$T/capacity-snapshot.json" >/dev/null 2>&1 \
  && jq -e '
    ([.actions[] | select(.kind == "clear-lane") | .lane] | sort) == ["gate-99","impl-196"]
    and ([.actions[] | select(.kind == "spawn") | .lane] | sort) == ["gate-12","impl-10"]
    and ([.actions[] | select(.kind == "clear-lane") | .order] | max)
        < ([.actions[] | select(.kind == "spawn") | .order] | min)
    and ([.actions[] | select(.lane == "impl-196" and .kind == "spawn")] | length) == 0
  ' "$T/capacity-plan.json" >/dev/null 2>&1; then
    ok "plan: completed lane epilogues are cleared then their primary/aux slots fill in the same plan without duplicate reuse"
else
    bad "plan: completed epilogues still consumed capacity or duplicated work (snapshot=$(jq -c '{lanes,summary}' "$T/capacity-snapshot.json" 2>/dev/null); plan=$(jq -c '{actions,deferred}' "$T/capacity-plan.json" 2>/dev/null))"
fi

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
