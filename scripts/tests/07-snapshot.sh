#!/usr/bin/env bash
# P7: the one-document read set, and P11 gate eligibility
#
# Section 07 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 7. snapshot (P7) -----------------------------------------------------
# Seam: GLAB_CMD points at a stub serving canned API responses and logging
# every invocation, so both the CONTENT of the document and the SHAPE of the
# call pattern are assertable.
FX="$T/fx"; CALLS="$T/calls.log"
make_glab_fixture "$FX"   # the canned tracker, in test-lib.sh
SNAP() { GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$CALLS" "$TICK" snapshot 2>"$T/snap.err"; }

# 7a. Assembly holds: one document carrying the whole read set.
: > "$CALLS"
"$TICK" spawn-lane merge-51 -- sleep 20 >/dev/null
SNAP > "$T/snap.json"; rc=$?
if [ "$rc" = 0 ] && jq -e . "$T/snap.json" >/dev/null 2>&1; then
    q() { jq -r "$1" "$T/snap.json"; }
    if [ "$(q '.build.label')" = "build-2" ] \
       && [ "$(q '[.tickets[].id] | @csv')" = '10,11,12' ] \
       && [ "$(q '.tickets[] | select(.id==10) | .state')" = "ready-for-agent" ] \
       && [ "$(q '.tickets[] | select(.id==10) | .tier')" = "api" ] \
       && [ "$(q '.tickets[] | select(.id==12) | .related_merge_requests[0].id')" = "77" ] \
       && [ "$(q '.lanes[] | select(.id=="merge-51") | .state')" = "running" ] \
       && [ "$(q '[.lessons_tail[].body] | length')" = "1" ] \
       && [ "$(q '.lessons_tail[0].author')" = "wave" ] \
       && [ "$(q '.summary.by_state["ready-for-agent"]')" = "2" ]; then
        ok "snapshot: one document carries tickets, tier, MRs, lanes, lessons, summary"
    else
        bad "snapshot: document assembled wrong ($(head -c 300 "$T/snap.json"))"
    fi
else
    bad "snapshot: did not emit valid JSON (rc=$rc, $(head -2 "$T/snap.err"))"
fi
# P52: the lane's turn count travels into the snapshot too — the wave
# compares it against .config.lane_turn_cap without a second tracker read.
# Its own stub log: appending to $CALLS would corrupt the 7b call-count test.
printf '17\n' > "$LOOM_HOME/lanes/merge-51.progress"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-turns" "$TICK" snapshot \
    > "$T/snap-turns.json" 2>/dev/null
[ "$(jq -r '.lanes[] | select(.id=="merge-51") | .turns' "$T/snap-turns.json")" = "17" ] \
    && ok "snapshot: lane turns travel through to .lanes[].turns" \
    || bad "snapshot: lane turns missing from snapshot ($(jq -c '.lanes[] | select(.id=="merge-51")' "$T/snap-turns.json"))"
# 7a2. Lane accounting (P10). The snapshot is what the wave reads before
#      deciding to fill a lane, so the impl/aux split has to be visible there.
#      Two gates plus a probe alongside one implementer is the exact shape that
#      turned `max_lanes: 4` into a single implementer.
for l in gate-61 gate-62 probe-e61; do "$TICK" spawn-lane "$l" -- sleep 20 >/dev/null; done
# Its own stub log: appending to $CALLS would corrupt the call-count test below.
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-lanes" "$TICK" snapshot \
    > "$T/snap-lanes.json" 2>/dev/null
q2() { jq -r "$1" "$T/snap-lanes.json"; }
if [ "$(q2 '.summary.lanes_running_by_type.impl')" = "0" ] \
   && [ "$(q2 '.summary.lanes_running_by_type.gate')" = "2" ] \
   && [ "$(q2 '.summary.lanes_running_by_type.probe')" = "1" ] \
   && [ "$(q2 '.summary.lanes_running_by_type.merge')" = "1" ] \
   && [ "$(q2 '.summary.lanes_running')" = "4" ]; then
    ok "snapshot: lanes counted by type, not lumped together"
else
    bad "snapshot: lane type counts wrong ($(q2 '.summary.lanes_running_by_type|@json'))"
fi
# Four lanes are running, yet every implementer slot is still free: that
# difference IS the proposal. Compare against the resolved cap, not a literal —
# max_lanes is layered config and this machine's global value may not be 4.
[ "$(q2 '.summary.impl_slots_free')" = "$(q2 '.config.max_lanes')" ] \
    && ok "snapshot: gates/probes/merges leave all impl slots free (P10)" \
    || bad "snapshot: impl_slots_free = $(q2 '.summary.impl_slots_free'), cap = $(q2 '.config.max_lanes')"
[ "$(q2 '.config.max_aux_lanes')" != "null" ] \
    && ok "snapshot: aux cap is published so the wave can bound gates/probes" \
    || bad "snapshot: no max_aux_lanes in config"
# 7a3. Stranded detection: `in-progress` with no ALIVE lane — where a gate
#      rejection parks a ticket (verdict fail → in-progress, assignee kept).
#      No wave step read that state, so gate-rejected #11/#12 sat unworked
#      while fresh backlog tickets took the slots (build-3 2026-08-02). A
#      lane of ANY kind covers its ticket, round suffix included:
#      gate-31-r2 must cover #31 while laneless #30 is flagged.
cat > "$FX/open-stranded.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"**Selected epics**:\n- Ledger core (#30, #31)\n"},
 {"iid":30,"title":"Rejected, awaiting rework","project_id":1,"web_url":"https://x/30",
  "labels":["build-2","in-progress"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":31,"title":"In its second gate round","project_id":1,"web_url":"https://x/31",
  "labels":["build-2","in-progress"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"}
]
EOF
"$TICK" spawn-lane gate-31-r2 -- sleep 20 >/dev/null
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-stranded.json" STUB_LOG="$T/calls-stranded" \
    "$TICK" snapshot > "$T/snap-stranded.json" 2>/dev/null
[ "$(jq -c '.summary.stranded' "$T/snap-stranded.json" 2>/dev/null)" = "[30]" ] \
    && ok "snapshot: laneless in-progress ticket is stranded; a live gate round covers its own" \
    || bad "snapshot: stranded = $(jq -c '.summary.stranded' "$T/snap-stranded.json" 2>/dev/null) (want [30])"
# 7a4. Fix tickets are first-class in the snapshot: the fill step claims
#      `fix: true` before the rest of the ready set (a fix ticket holds an
#      epic's re-probe hostage — asked for by the human, 2026-08-02), so the
#      flag must be derivable without label-parsing in every wave.
[ "$(q '.tickets[] | select(.id==11) | .fix')" = "true" ] \
    && [ "$(q '.tickets[] | select(.id==10) | .fix')" = "false" ] \
    && ok "snapshot: fix label surfaces as a per-ticket flag" \
    || bad "snapshot: fix flag wrong (11=$(q '.tickets[] | select(.id==11) | .fix'), 10=$(q '.tickets[] | select(.id==10) | .fix'))"
# 7a5. P30: the rejection history is a decision input. Two consecutive FAILs
#      naming one class → tail 2 (the wave blocks for a design decision);
#      different classes → tail 1; no verdicts at all → 0. (#39 burned
#      round 3 on a class the round-2 verdict had named, 2026-08-02.)
[ "$(q '.tickets[] | select(.id==12) | .rejections | "\(.total)/\(.last_class)/\(.same_class_tail)"')" = "2/marks-attribution/2" ] \
    && ok "snapshot: two same-class FAILs count as a tail of 2" \
    || bad "snapshot: same-class tail wrong for #12 ($(q '.tickets[] | select(.id==12) | .rejections | @json'))"
cp "$FX/notes-12.json" "$FX/notes-12-orig.json"
cp "$FX/notes-12-changed-class.json" "$FX/notes-12.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-cls" "$TICK" snapshot > "$T/snap-cls.json" 2>/dev/null
cp "$FX/notes-12-orig.json" "$FX/notes-12.json"
[ "$(jq -r '.tickets[] | select(.id==12) | .rejections.same_class_tail' "$T/snap-cls.json")" = "1" ] \
    && ok "snapshot: a class change resets the tail to 1" \
    || bad "snapshot: differing classes did not reset the tail ($(jq -c '.tickets[] | select(.id==12) | .rejections' "$T/snap-cls.json"))"
[ "$(q '.tickets[] | select(.id==10) | .rejections | "\(.total)/\(.same_class_tail)"')" = "0/0" ] \
    && ok "snapshot: no verdicts means zero rejections" \
    || bad "snapshot: phantom rejections on a clean ticket"
# 7a5b. P37: the cap belongs to the SCOPE, not the issue number. A ticket
#      rewritten into different work carries an `orch-scope-reset` marker
#      (lane.sh rescope), and verdicts older than the newest one stop counting.
#      #67 came back to the board with 3 of 3 rejections against code #48 had
#      deleted; its first gate FAIL would have blocked it (build-3, 2026-08-04).
cat > "$FX/notes-12-rescoped.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T10:00:00Z","author":{"username":"human"},"body":"Re-scoped: the pairing race moved to #48, which deleted this code.\n\n<!-- orch-scope-reset 2026-07-28T10:00:00Z -->"},
 {"system":false,"created_at":"2026-07-28T09:30:00Z","author":{"username":"gate"},"body":"r3\n\n<!-- orch-verdict FAIL cccc3333 class=marks-attribution -->"},
 {"system":false,"created_at":"2026-07-28T09:20:00Z","author":{"username":"gate"},"body":"r2\n\n<!-- orch-verdict FAIL bbbb2222 class=marks-attribution -->"},
 {"system":false,"created_at":"2026-07-28T09:10:00Z","author":{"username":"gate"},"body":"r1\n\n<!-- orch-verdict FAIL aaaa1111 class=marks-attribution -->"}]
EOF
cp "$FX/notes-12-rescoped.json" "$FX/notes-12.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-rescope" "$TICK" snapshot > "$T/snap-rescope.json" 2>/dev/null
[ "$(jq -r '.tickets[] | select(.id==12) | .rejections | "\(.total)/\(.same_class_tail)"' "$T/snap-rescope.json")" = "0/0" ] \
    && ok "snapshot: a scope reset retires every rejection older than it" \
    || bad "snapshot: re-scoped ticket still carries its old cap ($(jq -c '.tickets[] | select(.id==12) | .rejections' "$T/snap-rescope.json"))"
# Planted violation: the marker must not eat history NEWER than itself, or a
# single rescope would make the cap permanently unreachable. Same fixture, the
# marker moved back between r2 and r3 — r3 still counts.
sed 's/2026-07-28T10:00:00Z/2026-07-28T09:25:00Z/g' "$FX/notes-12-rescoped.json" > "$FX/notes-12.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-rescope-mid" "$TICK" snapshot > "$T/snap-rescope-mid.json" 2>/dev/null
cp "$FX/notes-12-orig.json" "$FX/notes-12.json"
[ "$(jq -r '.tickets[] | select(.id==12) | .rejections | "\(.total)/\(.last_class)/\(.same_class_tail)"' "$T/snap-rescope-mid.json")" = "1/marks-attribution/1" ] \
    && ok "snapshot: rejections newer than the reset marker still count" \
    || bad "snapshot: the reset swallowed a later rejection ($(jq -c '.tickets[] | select(.id==12) | .rejections' "$T/snap-rescope-mid.json"))"
# 7a5c. P78: the blocked report is located by its `orch-blocked` trailer and
#      carried WHOLE, so the human triaging a blocked ticket reads why without
#      opening the tracker. Every other parser here extracts a field; this one
#      exists to be read, so summarising it in jq would defeat the point.
cat > "$FX/notes-12-blocked.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T11:00:00Z","author":{"username":"wave"},"body":"Cap spent on the pairing race.\n\nAttempt 3 tried the adapter seam and failed the same class.\n\n<!-- orch-blocked category=rejection-cap 2026-07-28T11:00:00Z -->"},
 {"system":false,"created_at":"2026-07-28T09:10:00Z","author":{"username":"gate"},"body":"r1\n\n<!-- orch-verdict FAIL aaaa1111 class=marks-attribution -->"}]
EOF
cp "$FX/notes-12-blocked.json" "$FX/notes-12.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-blockedrep" "$TICK" snapshot > "$T/snap-blockedrep.json" 2>/dev/null
br() { jq -r ".tickets[] | select(.id==12) | .blocked_report | $1" "$T/snap-blockedrep.json"; }
[ "$(br .category)" = "rejection-cap" ] \
    && ok "snapshot: the blocked report's category is read off its trailer" \
    || bad "snapshot: category missing ($(jq -c '.tickets[] | select(.id==12) | .blocked_report' "$T/snap-blockedrep.json"))"
case "$(br .body)" in *"Attempt 3 tried the adapter seam"*) \
    ok "snapshot: the report body is carried whole, not summarised";; \
    *) bad "snapshot: report body lost ($(br .body))";; esac
case "$(br .body)" in *orch-blocked*) \
    bad "snapshot: the trailer leaked into the human-readable body";; \
    *) ok "snapshot: the trailer is stripped from the body a human reads";; esac
[ "$(br .released)" = "false" ] \
    && ok "snapshot: a block with no release note reads as not yet decided" \
    || bad "snapshot: released was $(br .released) with no orch-unblock in the thread"
# The half-applied batch: the decision note landed and the relabel did not, so
# the ticket is still `blocked` but the decision already exists. `triage` must
# show that as work to finish, never ask the human to decide it twice.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T12:00:00Z","author":{"username":"human"},"body":"Decision: resume on the old seam.\n\n<!-- orch-unblock 2026-07-28T12:00:00Z -->"},
 {"system":false,"created_at":"2026-07-28T11:00:00Z","author":{"username":"wave"},"body":"Cap spent.\n\n<!-- orch-blocked category=rejection-cap 2026-07-28T11:00:00Z -->"}]
EOF
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-blockedrel" "$TICK" snapshot > "$T/snap-blockedrel.json" 2>/dev/null
[ "$(jq -r '.tickets[] | select(.id==12) | .blocked_report.released' "$T/snap-blockedrel.json")" = "true" ] \
    && ok "snapshot: a release note newer than the block reads as already decided" \
    || bad "snapshot: a posted decision was not seen ($(jq -c '.tickets[] | select(.id==12) | .blocked_report' "$T/snap-blockedrel.json"))"
# Planted violation: `released` must be bounded by the NEWEST block. A ticket
# blocked, released, then blocked again would otherwise read as already decided
# forever, and its second decision would never be asked for.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"wave"},"body":"Blocked again, external dependency.\n\n<!-- orch-blocked category=external-dep 2026-07-28T13:00:00Z -->"},
 {"system":false,"created_at":"2026-07-28T12:00:00Z","author":{"username":"human"},"body":"Decision: resume.\n\n<!-- orch-unblock 2026-07-28T12:00:00Z -->"},
 {"system":false,"created_at":"2026-07-28T11:00:00Z","author":{"username":"wave"},"body":"Cap spent.\n\n<!-- orch-blocked category=rejection-cap 2026-07-28T11:00:00Z -->"}]
EOF
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-blockedre" "$TICK" snapshot > "$T/snap-blockedre.json" 2>/dev/null
rb() { jq -r ".tickets[] | select(.id==12) | .blocked_report | $1" "$T/snap-blockedre.json"; }
[ "$(rb .released)" = "false" ] && [ "$(rb .category)" = "external-dep" ] \
    && ok "snapshot: a re-blocked ticket asks for its second decision" \
    || bad "snapshot: stale release note swallowed the new block ($(jq -c '.tickets[] | select(.id==12) | .blocked_report' "$T/snap-blockedre.json"))"
# A thread with no trailer yields null rather than guessing which comment was
# the report — the state every ticket blocked before this verb existed is in.
cp "$FX/notes-12-orig.json" "$FX/notes-12.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-blockednone" "$TICK" snapshot > "$T/snap-blockednone.json" 2>/dev/null
[ "$(jq -r '.tickets[] | select(.id==12) | .blocked_report' "$T/snap-blockednone.json")" = "null" ] \
    && ok "snapshot: an unmarked thread yields no report rather than a guess" \
    || bad "snapshot: invented a blocked report from an unmarked thread"
# The new parser shares one thread with three others. The blocked-report
# fixture above carries an `orch-verdict` FAIL alongside its `orch-blocked`
# trailer, so this reads back the count the SAME thread must still produce —
# a blocked ticket whose rejection history stopped counting is #47 again.
[ "$(jq -r '.tickets[] | select(.id==12) | .rejections | "\(.total)/\(.last_class)"' "$T/snap-blockedrep.json")" \
  = "1/marks-attribution" ] \
    && ok "snapshot: a blocked report does not disturb the rejection parser beside it" \
    || bad "snapshot: blocked_report shifted the rejection read ($(jq -c '.tickets[] | select(.id==12) | .rejections' "$T/snap-blockedrep.json"))"

# 7a6. P31: the model escalation chain is RESOLVED in the snapshot, not
#      reasoned about per wave — ticket `model::` label > rework_model (a
#      round following a rejection) > lane_model > the session default.
#      With neither key set, the chain must resolve to "inherit", never to an
#      invented tier (2026-08-02: a fable interactive default silently ran
#      every worker top-tier — the failure that made lane_model exist).
[ "$(q '.tickets[] | select(.id==10) | .model | "\(.effective)/\(.source)"')" = "null/session-default" ] \
    && ok "snapshot: no model config resolves to inherit-the-default, not an invented tier" \
    || bad "snapshot: unconfigured model chain invented $(q '.tickets[] | select(.id==10) | .model | @json')"
cat > "$FX/open-model.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"**Selected epics**:\n- Ledger core (#10, #11, #12, #13)\n"},
 {"iid":10,"title":"Fresh, unlabeled","project_id":1,"web_url":"https://x/10",
  "labels":["build-2","ready-for-agent"],"assignees":[],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":11,"title":"Two escalation labels","project_id":1,"web_url":"https://x/11",
  "labels":["build-2","in-progress","model::haiku","model::opus"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":12,"title":"Rejected twice AND labeled","project_id":1,"web_url":"https://x/12",
  "labels":["build-2","review","model::fable"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":13,"title":"Rejected twice, unlabeled","project_id":1,"web_url":"https://x/13",
  "labels":["build-2","in-progress"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"}
]
EOF
cp "$FX/notes-12.json" "$FX/notes-13.json"
printf 'lane_model: sonnet\nrework_model: opus\n' >> "$LOOM_REPO/.loom.yml"
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-model.json" STUB_LOG="$T/calls-model" \
    "$TICK" snapshot > "$T/snap-model.json" 2>/dev/null
sed -i.bak '/^lane_model: sonnet$/d;/^rework_model: opus$/d' "$LOOM_REPO/.loom.yml"
rm -f "$FX/notes-13.json"
m() { jq -r ".tickets[] | select(.id==$1) | .model | \"\(.effective)/\(.source)\"" "$T/snap-model.json"; }
[ "$(m 10)" = "sonnet/lane_model" ] \
    && ok "snapshot: an unlabeled first round takes lane_model" \
    || bad "snapshot: first round resolved $(m 10), want sonnet/lane_model"
[ "$(m 13)" = "opus/rework_model" ] \
    && ok "snapshot: a round following a rejection takes rework_model" \
    || bad "snapshot: rework round resolved $(m 13), want opus/rework_model"
[ "$(m 12)" = "fable/label" ] \
    && ok "snapshot: the human's model:: label outranks rework_model" \
    || bad "snapshot: label lost to the config chain ($(m 12))"
[ "$(m 11)" = "opus/label" ] \
    && ok "snapshot: two model:: labels resolve to the highest tier" \
    || bad "snapshot: two labels resolved $(m 11), want opus/label"
jq -e '[.warnings[] | select(test("2 .model::. labels"))] | length == 1' "$T/snap-model.json" >/dev/null \
    && ok "snapshot: the ambiguous ticket is warned about once, not silently picked" \
    || bad "snapshot: two model:: labels produced no warning ($(jq -c .warnings "$T/snap-model.json"))"
# 7a7. Comment threads are read for every MEMBER ticket, not just the active
#      ones, and a ticket left claimed in `ready-for-agent` is warned about.
#      Both are the same failure: #47 went rejected -> blocked -> unblocked,
#      came back `ready-for-agent` still holding its lane's assignee, and read
#      as `rejections.total: 0` with `ready_set_empty: true` — its cap
#      restarted from zero, the same-class stop rule went blind, and the only
#      actionable ticket in the build was invisible to BOTH fill paths
#      (2026-08-03).
cat > "$FX/open-unblocked.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"**Selected epics**:\n- Ledger core (#30, #31)\n"},
 {"iid":30,"title":"Rejected, blocked, then unblocked cleanly","project_id":1,"web_url":"https://x/30",
  "labels":["build-2","ready-for-agent"],"assignees":[],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":31,"title":"Unblocked but never unassigned","project_id":1,"web_url":"https://x/31",
  "labels":["build-2","ready-for-agent"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":32,"title":"Tier carried by the scoped label alone","project_id":1,"web_url":"https://x/32",
  "labels":["build-2","ready-for-agent","tier::api"],"assignees":[],
  "milestone":{"title":"Ledger core"},"description":"No risk-tier section here.\n"},
 {"iid":33,"title":"Poisons every merge lane that picks it","project_id":1,"web_url":"https://x/33",
  "labels":["build-2","merge-queue"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"}
]
EOF
cat > "$FX/notes-33.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T11:20:00Z","author":{"username":"merge"},
  "body":"combined gate deadlocked in pytest\n\n<!-- orch-merge-attempt 33 -->"},
 {"system":false,"created_at":"2026-07-28T11:10:00Z","author":{"username":"merge"},
  "body":"conflict in live-app.ts, aborted\n\n<!-- orch-merge-attempt 33 -->"}]
EOF
cat > "$FX/notes-30.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T09:10:00Z","author":{"username":"gate"},
  "body":"r1: positional pairing\n\n<!-- orch-verdict FAIL aaaa1111 class=positional-correlation -->"}]
EOF
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-unblocked.json" STUB_LOG="$T/calls-unblocked" \
    "$TICK" snapshot > "$T/snap-unblocked.json" 2>/dev/null
rm -f "$FX/notes-30.json" "$FX/notes-33.json"
u() { jq -r "$1" "$T/snap-unblocked.json"; }
[ "$(u '.tickets[] | select(.id==30) | .rejections | "\(.total)/\(.last_class)"')" = "1/positional-correlation" ] \
    && ok "snapshot: a rejection history survives the trip through blocked and back to ready" \
    || bad "snapshot: history lost on a non-active member ($(u '.tickets[] | select(.id==30) | .rejections | @json'))"
jq -e '[.warnings[] | select(test("#31") and test("still assigned")
                             and test("lane.sh transition 31 ready-for-agent"))] | length == 1' \
    "$T/snap-unblocked.json" >/dev/null \
    && ok "snapshot: a claimed ready-for-agent ticket is warned about, with the fixing command" \
    || bad "snapshot: no unassign warning for #31 ($(jq -c .warnings "$T/snap-unblocked.json"))"
# Planted violation: the warning must key on the ASSIGNEE, not on the state.
# #30 is ready-for-agent too — warning on it would make the signal noise.
jq -e '[.warnings[] | select(test("#30") and test("still assigned"))] | length == 0' \
    "$T/snap-unblocked.json" >/dev/null \
    && ok "snapshot: an unassigned ready-for-agent ticket is not warned about" \
    || bad "snapshot: unassign warning fired on a clean ticket"
# P32: the snapshot counts merge attempts from the trailers, so the wave can
# stop feeding lanes into one poisoned ticket. #30 carries a FAIL verdict and
# no merge attempt; #33 carries two attempts — the cap default is 2, so that
# is the ticket the queue must give up on and step past.
[ "$(u '.tickets[] | select(.id==33) | .merge_attempts')" = "2" ] \
    && ok "snapshot: merge attempts counted from the orch-merge-attempt trailers" \
    || bad "snapshot: merge_attempts = $(u '.tickets[] | select(.id==33) | .merge_attempts'), want 2"
# Planted violation: a gate verdict is not a merge attempt. If the count
# matched any trailer, #30's FAIL would inflate it and the queue would give
# up on a ticket that has never once been merged.
[ "$(u '.tickets[] | select(.id==30) | .merge_attempts')" = "0" ] \
    && ok "snapshot: a gate verdict does not count as a merge attempt" \
    || bad "snapshot: verdict trailer leaked into merge_attempts"
# 7a7b. P62: a base-red attempt failed on a defect already on origin/<base>,
#       not in the branch — so it must never count toward merge_attempt_cap
#       (#26 and #15 burned full caps on main-is-red), and the ticket is
#       PARKED while the linked fix issue is open: merge_hold names the check
#       and the fix, the wave skips held tickets, and the hold computes to
#       null the moment the fix closes — release is derivation, not a write,
#       because spent attempts had no reset when #65 merged.
cat > "$FX/open-basered.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"**Selected epics**:\n- Ledger core (#50, #51)\n"},
 {"iid":50,"title":"Held behind an open base fix","project_id":1,"web_url":"https://x/50",
  "labels":["build-2","merge-queue"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":51,"title":"Fix merged, hold released","project_id":1,"web_url":"https://x/51",
  "labels":["build-2","merge-queue"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":60,"title":"Fix: model-literal guard over-matches","project_id":1,"web_url":"https://x/60",
  "labels":["build-2","fix","ready-for-agent"],"assignees":[],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"}
]
EOF
cat > "$FX/notes-50.json" <<'EOF'
[{"system":false,"created_at":"2026-08-07T02:18:00Z","author":{"username":"merge"},
  "body":"model-literal guard red on clean main too\n\n<!-- orch-merge-attempt 50 base-red=model-literal-guard fix=60 -->"},
 {"system":false,"created_at":"2026-08-07T02:04:00Z","author":{"username":"merge"},
  "body":"same guard, same base defect\n\n<!-- orch-merge-attempt 50 base-red=model-literal-guard fix=60 -->"}]
EOF
cat > "$FX/notes-51.json" <<'EOF'
[{"system":false,"created_at":"2026-08-07T04:00:00Z","author":{"username":"merge"},
  "body":"real conflict in schema.ts, aborted\n\n<!-- orch-merge-attempt 51 -->"},
 {"system":false,"created_at":"2026-08-07T03:00:00Z","author":{"username":"merge"},
  "body":"guard red on base; fix filed\n\n<!-- orch-merge-attempt 51 base-red=model-literal-guard fix=61 -->"}]
EOF
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-basered.json" STUB_LOG="$T/calls-basered" \
    "$TICK" snapshot > "$T/snap-basered.json" 2>/dev/null
rm -f "$FX/notes-50.json" "$FX/notes-51.json"
br() { jq -r "$1" "$T/snap-basered.json"; }
# Planted violation: the shipped count took ANY orch-merge-attempt trailer, so
# #50 would read 2 — at the default cap — and the wave would block a ticket
# whose branch was never once the problem.
[ "$(br '.tickets[] | select(.id==50) | .merge_attempts')" = "0" ] \
    && ok "snapshot: base-red attempts never count toward merge_attempt_cap" \
    || bad "snapshot: base-red attempts counted ($(br '.tickets[] | select(.id==50) | .merge_attempts')) — the cap burns on a base defect"
[ "$(br '.tickets[] | select(.id==50) | .merge_hold | "\(.checks[0])/\(.fixes[0])"')" = "model-literal-guard/60" ] \
    && ok "snapshot: an open linked fix parks the ticket — merge_hold names check and fix" \
    || bad "snapshot: merge_hold wrong ($(br '.tickets[] | select(.id==50) | .merge_hold | @json'))"
# Release is derivation: fix #61 is absent from the open set (closed), so the
# hold is gone with no requeue write — and the one REAL attempt still counts.
[ "$(br '.tickets[] | select(.id==51) | .merge_hold')" = "null" ] \
    && ok "snapshot: a closed fix releases the hold with no write" \
    || bad "snapshot: hold survived its fix closing ($(br '.tickets[] | select(.id==51) | .merge_hold | @json'))"
[ "$(br '.tickets[] | select(.id==51) | .merge_attempts')" = "1" ] \
    && ok "snapshot: a real attempt beside a base-red one still counts" \
    || bad "snapshot: mixed history miscounted ($(br '.tickets[] | select(.id==51) | .merge_attempts'), want 1)"
[ "$(jq -r '.config.merge_attempt_cap' "$T/snap-unblocked.json")" != "null" ] \
    && ok "snapshot: merge_attempt_cap is published so the wave can bound retries" \
    || bad "snapshot: no merge_attempt_cap in config"
# P52: lane_turn_cap must be published the same way — a wave cannot bound a
# runaway lane's spend against a cap it never received.
[ "$(jq -r '.config.lane_turn_cap' "$T/snap-unblocked.json")" != "null" ] \
    && ok "snapshot: lane_turn_cap is published so the wave can bound a runaway lane" \
    || bad "snapshot: no lane_turn_cap in config"
# Tier falls back to the SCOPED label when the body has no `## Risk tier`.
# The fallback existed but matched a bare `ui`, while `bootstrap.sh` creates
# `tier::ui` — so it was dead in every repo this skill bootstraps, and a
# probe-filed ticket that set the label and not the section read `tier: null`,
# leaving no suite for `--pregate` to run (#52, 2026-08-03).
[ "$(u '.tickets[] | select(.id==32) | .tier')" = "api" ] \
    && ok "snapshot: tier falls back to the scoped tier:: label, prefix stripped" \
    || bad "snapshot: scoped tier label ignored ($(u '.tickets[] | select(.id==32) | .tier'))"
jq -e '[.warnings[] | select(test("#32") and test("Risk tier"))] | length == 0' \
    "$T/snap-unblocked.json" >/dev/null \
    && ok "snapshot: a label-only tier is not warned about as missing" \
    || bad "snapshot: label-only tier still warned as missing"
# Planted violation: the body section must still WIN over the label, so a
# ticket whose body says logic is not silently regraded by a stray label.
[ "$(u '.tickets[] | select(.id==31) | .tier')" = "logic" ] \
    && ok "snapshot: the body's Risk tier section still outranks the label" \
    || bad "snapshot: body tier lost to the label ($(u '.tickets[] | select(.id==31) | .tier'))"
# The hole itself, documented: #31 is in neither fill path. That is WHY the
# warning exists — the scheduler cannot see it, so a human has to.
[ "$(u '.summary.ready_set_empty')" = "false" ] \
    && [ "$(jq -c '.summary.stranded' "$T/snap-unblocked.json")" = "[]" ] \
    && ok "snapshot: the claimed ticket is in neither the ready set nor stranded" \
    || bad "snapshot: fill-path membership changed ($(u '.summary | "\(.ready_set_empty)/\(.stranded|tostring)"'))"

# The wave must be able to see a merge in flight without holding its lock (P5).
[ "$(q2 '.summary.merge_in_flight')" = "false" ] || bad "snapshot: merge_in_flight true with no merge running"
"$TICK" spawn-lane merge-63 --merge-lock -- sleep 20 >/dev/null
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-lanes" "$TICK" snapshot > "$T/snap-merge.json" 2>/dev/null
[ "$(jq -r '.summary.merge_in_flight' "$T/snap-merge.json")" = "true" ] \
    && ok "snapshot: a merge in flight is visible to the wave" \
    || bad "snapshot: merge_in_flight did not reflect the held lock"
kill "$(cat "$LOOM_HOME/lanes/merge-63.pid" 2>/dev/null)" 2>/dev/null
"$TICK" clear-lane merge-63 >/dev/null; rm -rf "$LOOM_HOME/merge.lock.d"
for l in gate-61 gate-62 probe-e61; do
    kill "$(cat "$LOOM_HOME/lanes/$l.pid" 2>/dev/null)" 2>/dev/null
    "$TICK" clear-lane "$l" >/dev/null
done

# 7a8. P51: `snapshot --brief` keeps a full row only for a ticket the wave can
#      act on THIS turn; the rest collapse to a bare iid in `.other_iids`. One
#      fixture ticket per bullet in the proposal, plus the inverse case.
cat > "$FX/open-brief.json" <<'EOF'
[
 {"iid":1,"title":"Build 9","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"**Selected epics**:\n- Brief epic (#201, #202, #203, #204, #205, #206, #207)\n"},
 {"iid":201,"title":"Ready and unblocked","project_id":1,"web_url":"https://x/201",
  "labels":["build-9","ready-for-agent"],"assignees":[]},
 {"iid":202,"title":"Gateable","project_id":1,"web_url":"https://x/202",
  "labels":["build-9","review"],"assignees":[{"username":"agent-a"}]},
 {"iid":203,"title":"Head of the merge queue","project_id":1,"web_url":"https://x/203",
  "labels":["build-9","merge-queue"],"assignees":[{"username":"agent-a"}]},
 {"iid":204,"title":"Behind it in the merge queue","project_id":1,"web_url":"https://x/204",
  "labels":["build-9","merge-queue"],"assignees":[{"username":"agent-a"}]},
 {"iid":205,"title":"Stranded — in-progress, no lane","project_id":1,"web_url":"https://x/205",
  "labels":["build-9","in-progress"],"assignees":[{"username":"agent-a"}]},
 {"iid":206,"title":"Review, already behind a running gate lane","project_id":1,"web_url":"https://x/206",
  "labels":["build-9","review"],"assignees":[{"username":"agent-a"}]},
 {"iid":207,"title":"Blocked by an open ticket, unclaimed, laneless","project_id":1,"web_url":"https://x/207",
  "labels":["build-9","ready-for-agent"],"assignees":[],
  "description":"## Blocked by\n\n- #205 stranded ticket above\n"}
]
EOF
cat > "$FX/mrs-202.json" <<'EOF'
[{"iid":202,"title":"Gateable","state":"opened","draft":false,"web_url":"https://x/mr/202","source_branch":"t202","sha":"aaaaaaa0000000000000000000000000000000"}]
EOF
cat > "$FX/mrs-206.json" <<'EOF'
[{"iid":206,"title":"Behind a gate","state":"opened","draft":false,"web_url":"https://x/mr/206","source_branch":"t206","sha":"bbbbbbb0000000000000000000000000000000"}]
EOF
"$TICK" spawn-lane gate-206 -- sleep 20 >/dev/null
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-brief.json" STUB_LOG="$T/calls-brief" \
    "$TICK" snapshot --brief > "$T/snap-brief.json" 2>/dev/null
[ "$(jq -c '[.tickets[].id] | sort' "$T/snap-brief.json")" = "[201,202,203,204,205,206]" ] \
    && ok "brief: full rows for ready+unblocked, gateable, both merge-queue tickets, stranded, and a lane-held review ticket" \
    || bad "brief: tickets = $(jq -c '[.tickets[].id] | sort' "$T/snap-brief.json"), want [201,202,203,204,205,206]"
[ "$(jq -c '.other_iids' "$T/snap-brief.json")" = "[207]" ] \
    && ok "brief: the blocked, unclaimed, laneless ticket is a bare iid, not a full row" \
    || bad "brief: other_iids = $(jq -c '.other_iids' "$T/snap-brief.json"), want [207]"
[ "$(jq -r '.tickets[] | select(.id==206) | .gate.eligible' "$T/snap-brief.json")" = "false" ] \
    && ok "brief: #206 earns its row via the lane clause, not the gateable one (already gated)" \
    || bad "brief: #206 unexpectedly gate.eligible — the fixture no longer tests what it claims to"
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-brief.json" STUB_LOG="$T/calls-brief-full" \
    "$TICK" snapshot > "$T/snap-full.json" 2>/dev/null
[ "$(jq -c '[.tickets[].id] | sort' "$T/snap-full.json")" = "[201,202,203,204,205,206,207]" ] \
    && [ "$(jq -c '.other_iids' "$T/snap-full.json")" = "[]" ] \
    && ok "brief: plain snapshot (no flag) still carries every ticket, other_iids empty" \
    || bad "brief: plain snapshot filtered rows or populated other_iids ($(jq -c '{t: [.tickets[].id], o: .other_iids}' "$T/snap-full.json"))"
kill "$(cat "$LOOM_HOME/lanes/gate-206.pid" 2>/dev/null)" 2>/dev/null
"$TICK" clear-lane gate-206 >/dev/null

# The scheduler's universe is "open issues labeled build-N" — #20 is neither.
jq -e '[.tickets[].id] | index(20)' "$T/snap.json" >/dev/null 2>&1 \
    && bad "snapshot: non-member issue leaked into tickets" \
    || ok "snapshot: membership is exactly the build-N label"
# System notes are label-change spam, not lessons.
jq -e '[.lessons_tail[].body] | any(test("added ~"))' "$T/snap.json" >/dev/null 2>&1 \
    && bad "snapshot: system notes leaked into the lessons tail" \
    || ok "snapshot: system notes excluded from the lessons tail"

# 7b. One-shot property: the whole read set costs 1 + members + active +
#     members + 1 calls from ONE invocation (3 members, 1 active, 1 build) —
#     the guard against re-adding a serial question-per-fact read, plus the
#     project-level milestone read that carries epic acceptance. Comment
#     threads and milestones ride the same concurrent fan-out, so they cost a
#     call each but almost no wall clock. P35 adds one more: the closed
#     members, without which an epic whose last ticket closed cannot be seen
#     at all — bought deliberately, and on the same fan-out.
n=$(wc -l < "$CALLS" | tr -d ' ')
[ "$n" = 11 ] && ok "snapshot: whole read set cost 11 calls (1 list + 1 milestones + 3 links + 1 MR + 3 threads + 1 lessons + 1 closed members)" \
             || bad "snapshot: read set cost $n calls, expected 11 ($(cat "$CALLS" | tr '\n' ';'))"
# Planted violation: MRs are fetched only for started tickets. If the active
# filter were dropped, ready-for-agent tickets (which cannot have an MR) would
# each add a call — the count above is what proves the filter is live.
grep -c "related_merge_requests" "$CALLS" | grep -q '^1$' \
    && ok "snapshot: MRs fetched only for started tickets, not the ready set" \
    || bad "snapshot: MR fan-out not bounded to started tickets"
# The mirror of it: comment threads are fetched for every member, active or
# not, because the rejection history has to survive `blocked` and `ready`.
# Narrowing this back to the active set is what lost #47's history.
grep -c "/notes" "$CALLS" | grep -q '^4$' \
    && ok "snapshot: comment threads fetched per member, not per active ticket" \
    || bad "snapshot: thread fan-out is $(grep -c '/notes' "$CALLS"), expected 4 (3 members + lessons)"

# 7c. Concurrency is real: calls must OVERLAP. Asserted by counting how many
#     stub calls are in flight at once, not by timing the run (D-TEST-12): the
#     old `elapsed < 3` was measured with integer `date +%s`, so its window sat
#     inside its own +/-1s truncation, and a loaded machine crossed it — a
#     false alarm on a correct fan-out, which is indistinguishable from a real
#     regression and so gets dismissed as noise. Overlap is load-independent:
#     a serial fan-out peaks at 1 no matter how fast or slow the machine is.
: > "$CALLS"
INFLIGHT="$T/snap-inflight"; PEAKLOG="$T/snap-peak"; rm -rf "$INFLIGHT"; : > "$PEAKLOG"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$CALLS" STUB_SLEEP=0.6 \
    STUB_INFLIGHT_DIR="$INFLIGHT" STUB_PEAK_LOG="$PEAKLOG" "$TICK" snapshot >/dev/null 2>&1
peak=$(sort -n "$PEAKLOG" 2>/dev/null | tail -1); peak="${peak:-0}"
[ "$peak" -gt 1 ] && ok "snapshot: fan-out is concurrent (peak $peak calls in flight at once)" \
                  || bad "snapshot: fan-out ran serially (peak $peak in flight — concurrent work overlaps)"
# Planted violation: SNAP_BATCH=1 forces one call at a time, and the same
# assertion must report a peak of exactly 1. This is what the wall-clock form
# could not do — a slow serial run and a slow concurrent run looked alike.
rm -rf "$INFLIGHT"; : > "$PEAKLOG"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$CALLS" STUB_SLEEP=0.4 SNAP_BATCH=1 \
    STUB_INFLIGHT_DIR="$INFLIGHT" STUB_PEAK_LOG="$PEAKLOG" "$TICK" snapshot >/dev/null 2>&1
speak=$(sort -n "$PEAKLOG" 2>/dev/null | tail -1); speak="${speak:-0}"
# Not "exactly 1": one pair genuinely overlaps even at SNAP_BATCH=1 (the gate
# waits AFTER launching, so the last job of a batch can still be in flight as
# the next starts) — 10 calls of the 11 see a single caller. The claim is that
# forcing the batch COLLAPSES the overlap, which is what fails loudly if the
# gate ever stops bounding: an unbounded fan-out measures ~9 here, not 2.
if [ "$speak" -le 2 ] && [ "$speak" -lt "$peak" ]; then
    ok "snapshot-violation: forcing the batch to 1 collapses the overlap ($peak → $speak) — the measure can fail"
else
    bad "snapshot-violation: a serialised fan-out still measured peak $speak (concurrent was $peak)"
fi

# 7d. Blocking edges come from BOTH sources (SKILL.md: native links where the
#     tier allows, else the body's `## Blocked by` list), deduped and tagged.
b() { jq -r ".tickets[] | select(.id==11) | .blocked_by[] | select(.id==$1) | .$2" "$T/snap.json"; }
if [ "$(b 10 source)" = "both" ] && [ "$(b 14 source)" = "native" ] && [ "$(b 13 source)" = "body" ] \
   && [ "$(jq '.tickets[] | select(.id==11) | .blocked_by | length' "$T/snap.json")" = 3 ]; then
    ok "snapshot: native + body blockers unioned, deduped, source-tagged"
else
    bad "snapshot: blocker union wrong ($(jq -c '.tickets[]|select(.id==11)|.blocked_by' "$T/snap.json"))"
fi
# Planted violation: on a tier without issue links the API 403s. Body-sourced
# edges must survive, with a warning — a degraded field, not a dead document.
GLAB_CMD="$FX/glab-stub.sh" STUB_403_LINKS=1 "$TICK" snapshot > "$T/snap403.json" 2>/dev/null
if jq -e '(.tickets[] | select(.id==11) | .blocked_by | map(.source) | unique == ["body"])
          and (.warnings | any(test("links")))' "$T/snap403.json" >/dev/null 2>&1; then
    ok "snapshot-violation: links 403 degrades to body edges + warning, not failure"
else
    bad "snapshot-violation: links 403 lost the body edges or the warning"
fi

# 7e. Blocker closed-state needs no extra call: the universe is the open set,
#     so a blocker absent from it is closed. #10 is open, #7 and #13 are not.
if [ "$(jq -r '.tickets[]|select(.id==11)|.blocked_by[]|select(.id==10)|.closed' "$T/snap.json")" = "false" ] \
   && [ "$(jq -r '.tickets[]|select(.id==11)|.unblocked' "$T/snap.json")" = "false" ] \
   && [ "$(jq -r '.tickets[]|select(.id==10)|.blocked_by[0].closed' "$T/snap.json")" = "true" ] \
   && [ "$(jq -r '.tickets[]|select(.id==10)|.unblocked' "$T/snap.json")" = "true" ]; then
    ok "snapshot: blocker closed-state derived from the open set, no extra call"
else
    bad "snapshot: closed-state/unblocked derivation wrong"
fi
# A cross-project link cannot use that inference — say so, never guess.
if [ "$(jq -r '.tickets[]|select(.id==12)|.blocked_by[0].closed' "$T/snap.json")" = "null" ] \
   && jq -e '.warnings | any(test("cross-project"))' "$T/snap.json" >/dev/null 2>&1 \
   && [ "$(jq -r '.tickets[]|select(.id==12)|.unblocked' "$T/snap.json")" = "false" ]; then
    ok "snapshot: cross-project blocker is unknown + warned, never assumed closed"
else
    bad "snapshot: cross-project blocker was guessed at"
fi

# 7f. Epic rollup, no calls: an epic with open members is incomplete; one whose
#     last ticket closed is invisible in an open-issue payload, so it comes from
#     the Build issue body — which also carries a dropped-epic list and a config
#     snapshot, and neither is a build epic.
if [ "$(jq -r '.epics[]|select(.name=="Ledger core")|.complete' "$T/snap.json")" = "false" ] \
   && [ "$(jq -r '.epics[]|select(.name=="Ledger core")|.open_tickets' "$T/snap.json")" = "3" ] \
   && [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.complete' "$T/snap.json")" = "true" ] \
   && [ "$(jq '.epics|length' "$T/snap.json")" = "2" ]; then
    ok "snapshot: epic rollup derived from open members + build body, no calls"
else
    bad "snapshot: epic rollup wrong ($(jq -c '.epics' "$T/snap.json"))"
fi

# 7f1. D-SNAP-02: a finished epic whose name is a SUBSTRING of an unrelated
#      open epic's name must not be swallowed by it. The build-issue list
#      names both "E10 Payments" (open, one ticket still on it) and "E1"
#      (finished, zero open tickets — same shape "Reporting surface" has
#      above). A bare mutual `contains` reads "e10 payments" as containing
#      "e1" (it does — "e10" starts with "e1") and silently drops the
#      completed epic out of `$epics_done`, invisible to `epics[]` and
#      `epics_awaiting_probe`, letting `build_complete` close the build over
#      an epic nobody probed (the build-2 failure the entry cites).
cat > "$FX/open-substr.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"**Selected epics**:\n- E10 Payments (#10)\n- E1 (#11)\n"},
 {"iid":10,"title":"Wire E10 payment flow","project_id":1,"web_url":"https://x/10",
  "labels":["build-2","ready-for-agent"],"assignees":[],"updated_at":"2026-07-28T10:00:00Z",
  "milestone":{"title":"E10 Payments"},"description":"## Risk tier\n\napi\n"}
]
EOF
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-substr.json" STUB_LOG="$T/calls-substr" \
    "$TICK" snapshot > "$T/snap-substr.json" 2>/dev/null
if [ "$(jq -r '.epics|length' "$T/snap-substr.json")" = "2" ] \
   && [ "$(jq -r '.epics[]|select(.name=="E10 Payments")|.complete' "$T/snap-substr.json")" = "false" ] \
   && [ "$(jq -r '.epics[]|select(.name=="E10 Payments")|.open_tickets' "$T/snap-substr.json")" = "1" ] \
   && [ "$(jq -r '.epics[]|select(.name=="E1")|.complete' "$T/snap-substr.json")" = "true" ] \
   && [ "$(jq -r '.epics[]|select(.name=="E1")|.source' "$T/snap-substr.json")" = "build-issue" ]; then
    ok "snapshot: a finished epic whose name is a substring of an open epic's name is not swallowed"
else
    bad "snapshot: substring collision dropped the finished epic ($(jq -c '.epics' "$T/snap-substr.json"))"
fi

# 7a2. Epic ACCEPTANCE is read back from the milestone the probe closes.
#      `lane.sh probe-result <epic> pass` closes that milestone and its own
#      source said "completeness stays DERIVED (nothing reads milestone
#      state)" — so `complete` meant only "no open tickets", an epic that was
#      never probed was indistinguishable from one that passed, and the
#      completion path closed the build over both. (Paid for: build-2
#      2026-08-04 — E4 probe FAILED and was never re-run after its fixes
#      merged, E6 and E7 never probed at all, build closed 97s after the last
#      ticket did; the human found it by noticing three open milestones.)
#      "Reporting surface" is the complete epic in this fixture; "Ledger core"
#      still has open tickets and must never be asked for a probe.
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"active"}]' \
    > "$FX/milestones.json"
SNAP > "$T/snap-probe.json" 2>/dev/null
if [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.needs_probe' "$T/snap-probe.json")" = "true" ] \
   && [ "$(jq -r '.epics[]|select(.name=="Ledger core")|.needs_probe' "$T/snap-probe.json")" = "false" ] \
   && [ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-probe.json")" = '["Reporting surface"]' ]; then
    ok "snapshot: a complete epic with an open milestone is listed as awaiting its probe"
else
    bad "snapshot: acceptance rollup wrong ($(jq -c '[.epics[]|{name,complete,accepted,needs_probe}]' "$T/snap-probe.json"))"
fi
# P34: the epic's OWN acceptance criteria travel with it, so a probe brief is
# ASSEMBLED from what must be true rather than invented from what has already
# broken. Without them a brief can only enumerate the last round's defects —
# it cannot catch what nobody has broken yet, and no two runs are comparable.
# (Paid for: E4 failed five straight probes and no run ever checked the
# FR-2/TR-2/PF-1 the epic itself cites. 2026-08-04.)
[ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.acceptance' "$T/snap-probe.json")" = "null" ] \
    && ok "snapshot: an epic with no criteria section reports acceptance null" \
    || bad "snapshot: invented acceptance from a description that has none"
# The warning fires ONLY for the epic actually about to be probed — an epic
# with open tickets still has time to write them, and warning on it is noise.
jq -e '[.warnings[] | select(test("Reporting surface") and test("Acceptance criteria"))] | length == 1' \
    "$T/snap-probe.json" >/dev/null \
    && jq -e '[.warnings[] | select(test("Ledger core") and test("Acceptance criteria"))] | length == 0' \
       "$T/snap-probe.json" >/dev/null \
    && ok "snapshot: warns about missing criteria only on the probe-ready epic" \
    || bad "snapshot: criteria warning fired wrong ($(jq -c '[.warnings[]|select(test("Acceptance"))]' "$T/snap-probe.json"))"
# With criteria present: surfaced verbatim, and the warning goes quiet.
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"active","description":"Scope prose.\n\n## Acceptance criteria\n\n- [ ] A user can file a report and read it back\n\n## Notes\n\nignored\n"}]' \
    > "$FX/milestones.json"
SNAP > "$T/snap-crit.json" 2>/dev/null
acc=$(jq -r '.epics[]|select(.name=="Reporting surface")|.acceptance' "$T/snap-crit.json")
case "$acc" in
    *"file a report and read it back"*)
        case "$acc" in
            *"Scope prose"*|*ignored*) bad "snapshot: acceptance leaked neighbouring sections" ;;
            *) ok "snapshot: acceptance is the criteria section alone, not the whole description" ;;
        esac ;;
    *) bad "snapshot: criteria not surfaced ($acc)" ;;
esac
jq -e '[.warnings[] | select(test("Acceptance criteria"))] | length == 0' "$T/snap-crit.json" >/dev/null \
    && ok "snapshot: the criteria warning goes quiet once they exist" \
    || bad "snapshot: still warning about criteria that are present"
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"active"}]' \
    > "$FX/milestones.json"
# The warning matters as much as the field: this failure is silent AND
# terminal, since the completion path tears the agent down on its way out.
jq -e '.warnings | any(test("no acceptance probe has passed"))' "$T/snap-probe.json" >/dev/null 2>&1 \
    && ok "snapshot: an unaccepted epic raises a warning, not just a field" \
    || bad "snapshot: unaccepted epic passed silently ($(jq -c '.warnings' "$T/snap-probe.json"))"
# A passed probe closed the milestone → accepted, and nothing left to schedule.
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"closed"}]' \
    > "$FX/milestones.json"
SNAP > "$T/snap-acc.json" 2>/dev/null
if [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.accepted' "$T/snap-acc.json")" = "true" ] \
   && [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.needs_probe' "$T/snap-acc.json")" = "false" ] \
   && [ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-acc.json")" = '[]' ]; then
    ok "snapshot: a closed milestone reads back as an accepted epic"
else
    bad "snapshot: accepted epic still wanted a probe ($(jq -c '[.epics[]|{name,accepted,needs_probe}]' "$T/snap-acc.json"))"
fi
# 7a2b. P57: `--brief` keeps `acceptance` only on an epic actually awaiting
#       its probe — measured at 88% of the epics block and read by nothing
#       but step 6's probe-brief assembly, so every other wave paid full
#       price for text it never used. "Reporting surface" is complete with
#       an open milestone (needs_probe true); "Ledger core" still has open
#       tickets (needs_probe false) despite carrying its own criteria too.
printf '%s\n' '[{"title":"Ledger core","state":"active","description":"## Acceptance criteria\n\n- [ ] Ledger balances\n"},{"title":"Reporting surface","state":"active","description":"## Acceptance criteria\n\n- [ ] A user can file a report and read it back\n"}]' \
    > "$FX/milestones.json"
SNAP > "$T/snap-p57-full.json" 2>/dev/null
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$CALLS" "$TICK" snapshot --brief > "$T/snap-p57-brief.json" 2>/dev/null
full_acc=$(jq -r '.epics[]|select(.name=="Reporting surface")|.acceptance' "$T/snap-p57-full.json")
brief_acc=$(jq -r '.epics[]|select(.name=="Reporting surface")|.acceptance' "$T/snap-p57-brief.json")
[ "$full_acc" = "$brief_acc" ] && [ -n "$full_acc" ] && [ "$full_acc" != "null" ] \
    && ok "brief: an epic awaiting its probe keeps acceptance, byte-identical to plain snapshot" \
    || bad "brief: probe-ready epic's acceptance changed under --brief (full=$full_acc brief=$brief_acc)"
jq -e '.epics[]|select(.name=="Ledger core")|has("acceptance")|not' "$T/snap-p57-brief.json" >/dev/null 2>&1 \
    && ok "brief: an epic not awaiting a probe drops the acceptance key entirely" \
    || bad "brief: Ledger core still carries acceptance under --brief ($(jq -c '.epics[]|select(.name=="Ledger core")' "$T/snap-p57-brief.json"))"
jq -e '.epics[]|select(.name=="Ledger core")|.needs_probe == false and .open_tickets == 3' "$T/snap-p57-brief.json" >/dev/null 2>&1 \
    && ok "brief: an epic dropping acceptance keeps its structural fields" \
    || bad "brief: Ledger core lost structural fields under --brief ($(jq -c '.epics[]|select(.name=="Ledger core")' "$T/snap-p57-brief.json"))"
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"active"}]' \
    > "$FX/milestones.json"
# 7a3. P35: a finished epic is found from the milestones of this builds CLOSED
#      members, not from prose in the Build issue. The body parse reads markdown
#      LIST items; a Build issue that lists its epics in a TABLE matches nothing,
#      so every epic whose last ticket closed went invisible at exactly the
#      moment it became probe-ready. (Paid for: build-3 2026-08-04 — E4 reached
#      zero open tickets six times with `epics_awaiting_probe` empty each time,
#      and the probe only ever ran because a wave spotted the gap and reasoned
#      around it; in build-2 the same blind spot let E6 and E7 close unprobed.)
cat > "$FX/open-table.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"## Selected epics\n\n| Epic | Milestone | Tickets | Status |\n|------|-----------|---------|--------|\n| Ledger core | %4 | #10 | open |\n| Reporting surface | %5 | #13 | open |\n"},
 {"iid":10,"title":"Add ledger table","project_id":1,"web_url":"https://x/10",
  "labels":["build-2","ready-for-agent"],"assignees":[],"updated_at":"2026-07-28T10:00:00Z",
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\napi\n"}
]
EOF
printf '%s\n' '[{"iid":13,"milestone":{"title":"Reporting surface"}}]' > "$FX/closed-members.json"
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"active"}]' \
    > "$FX/milestones.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-table.json" STUB_CLOSED="$FX/closed-members.json" \
    STUB_LOG="$T/calls-p35" "$TICK" snapshot > "$T/snap-p35.json" 2>/dev/null
if [ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-p35.json")" = '["Reporting surface"]' ] \
   && [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.source' "$T/snap-p35.json")" = "closed-members" ] \
   && [ "$(jq -r '.epics[]|select(.name=="Ledger core")|.needs_probe' "$T/snap-p35.json")" = "false" ]; then
    ok "snapshot: an epic whose last ticket closed is found even when the Build issue lists epics in a table"
else
    bad "snapshot: finished epic invisible ($(jq -c '[.epics[]|{name,source,complete,needs_probe}]' "$T/snap-p35.json"))"
fi
# Planted violation: the fix must come from the CLOSED members, not from a
# loosened body parse. Same table body, no closed members — nothing is invented.
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-table.json" STUB_CLOSED="$FX/closed-none.json" \
    "$TICK" snapshot > "$T/snap-p35b.json" 2>/dev/null
[ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-p35b.json")" = '[]' ] \
    && ok "snapshot: with no closed members, a table-listed epic is not conjured into a probe" \
    || bad "snapshot: invented a probe-ready epic from prose ($(jq -c '.summary.epics_awaiting_probe' "$T/snap-p35b.json"))"
# An epic still holding open tickets is never reported complete, however many of
# its OTHER tickets have closed — closed members widen discovery, never verdict.
printf '%s\n' '[{"iid":9,"milestone":{"title":"Ledger core"}},{"iid":13,"milestone":{"title":"Reporting surface"}}]' \
    > "$FX/closed-mixed.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-table.json" STUB_CLOSED="$FX/closed-mixed.json" \
    "$TICK" snapshot > "$T/snap-p35c.json" 2>/dev/null
[ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-p35c.json")" = '["Reporting surface"]' ] \
    && ok "snapshot: an epic with an open ticket stays out of the probe list even with closed members" \
    || bad "snapshot: probed an epic that still has open work ($(jq -c '.summary.epics_awaiting_probe' "$T/snap-p35c.json"))"

# 7f2. P49: the closed-member read is the one P35 added to FIND a finished
#      epic, and it was the one read still truncating at 100. Fixture: 101
#      closed members, the finished epic's only member last. Also pins the
#      call shape both ways — a list read carries `--paginate`, and the
#      `sort=desc` notes read deliberately does NOT, because it wants the
#      newest N and paginating it would pull the whole thread.
cat > "$FX/glab-page-stub.sh" <<'EOF'
#!/usr/bin/env bash
FX="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "${STUB_LOG:-/dev/null}"
paged=no
case "$*" in *--paginate*) paged=yes ;; esac
[ -n "${STUB_NOPAGE:-}" ] && paged=no
case "$*" in
  *"state=closed"*)
      jq -nc '[range(1;101) | {iid: (200 + .), milestone: {title: "Ledger core"}}]'
      [ "$paged" = yes ] && jq -nc '[{iid: 13, milestone: {title: "Reporting surface"}}]' ;;
  *"state=opened"*) cat "$FX/open-table.json" ;;
  *"milestones"*)   cat "$FX/milestones.json" ;;
  *) echo '[]' ;;
esac
exit 0
EOF
chmod +x "$FX/glab-page-stub.sh"
: > "$T/calls-p49"
GLAB_CMD="$FX/glab-page-stub.sh" STUB_LOG="$T/calls-p49" \
    "$TICK" snapshot > "$T/snap-p49.json" 2>/dev/null
if [ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-p49.json")" = '["Reporting surface"]' ] \
   && grep -q -- '--paginate.*state=closed' "$T/calls-p49" \
   && grep -q 'notes?sort=desc' "$T/calls-p49" \
   && ! grep -q -- '--paginate.*notes?sort=desc' "$T/calls-p49"; then
    ok "P49: the snapshot pages through closed members, and leaves the capped notes read capped"
else
    bad "P49: closed-member paging wrong ($(jq -c '.summary.epics_awaiting_probe' "$T/snap-p49.json"), calls: $(grep -c . "$T/calls-p49"))"
fi
# Planted violation: remove the pagination and the finished epic vanishes from
# the probe list — build-2's failure, reached by member count alone.
GLAB_CMD="$FX/glab-page-stub.sh" STUB_NOPAGE=1 \
    "$TICK" snapshot > "$T/snap-p49b.json" 2>/dev/null
[ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-p49b.json")" = '[]' ] \
    && ok "P49-violation: a single-page closed read hides the finished epic entirely" \
    || bad "P49-violation: unpaginated snapshot still saw it ($(jq -c '.summary.epics_awaiting_probe' "$T/snap-p49b.json")) — fixture no longer exceeds one page"

# Planted violation: with NO milestones at all (a tier or project that does not
# use them) acceptance is UNKNOWN — it must never manufacture a probe request.
printf '[]\n' > "$FX/milestones.json"
SNAP > "$T/snap-noms.json" 2>/dev/null
if [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.accepted' "$T/snap-noms.json")" = "null" ] \
   && [ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-noms.json")" = '[]' ]; then
    ok "snapshot: no milestones means acceptance unknown, never a fabricated probe"
else
    bad "snapshot-violation: invented acceptance state with no milestones ($(jq -c '[.epics[]|{name,accepted,needs_probe}]' "$T/snap-noms.json"))"
fi
# Planted violation: an unscoped list scan would read the dropped epics and the
# config snapshot as build epics, and report them complete.
if jq -e '.epics | any(.name | test("Archive sweep|max_lanes"))' "$T/snap.json" >/dev/null 2>&1; then
    bad "snapshot-violation: dropped-epic / config list items read as build epics"
else
    ok "snapshot-violation: dropped epics and config lines are not build epics"
fi

# 7g. Empty universe is VALID, not an error: a heartbeat wave with no active
#     build must get a document it can no-op on.
echo '[{"iid":9,"title":"Some other issue","project_id":1,"labels":[],"assignees":[],"description":""}]' > "$FX/empty.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/empty.json" "$TICK" snapshot > "$T/snapempty.json" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ "$(jq -r '.build' "$T/snapempty.json")" = "null" ] \
   && [ "$(jq '.tickets | length' "$T/snapempty.json")" = "0" ] \
   && [ "$(jq -r '.summary.ready_set_empty' "$T/snapempty.json")" = "true" ]; then
    ok "snapshot: no open Build issue yields a valid null-build document, exit 0"
else
    bad "snapshot: empty universe not handled (rc=$rc)"
fi

# 7h. Planted violation: the FOUNDATIONAL call failing must die, never emit an
#     empty ticket list — a failed query and an empty build must not look alike.
out=$(GLAB_CMD="$FX/glab-stub.sh" STUB_FAIL_STAGE1=1 "$TICK" snapshot 2>"$T/e2"); rc=$?
if [ "$rc" != 0 ] && [ -z "$out" ] && grep -q "open-issue list failed" "$T/e2"; then
    ok "snapshot-violation: failed list call dies loudly with no partial document"
else
    bad "snapshot-violation: failed list call produced rc=$rc, output '$out'"
fi

# 7i. A malformed `## Blocked by` section invents nothing.
cat > "$FX/malformed.json" <<'EOF'
[{"iid":1,"title":"Build 3","project_id":1,"labels":[],"assignees":[],"description":"- Solo epic\n"},
 {"iid":30,"title":"Odd ticket","project_id":1,"labels":["build-3","ready-for-agent"],"assignees":[],
  "description":"## Blocked by\n\nsee the thread, probably issue seven-ish\n"}]
EOF
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/malformed.json" "$TICK" snapshot > "$T/snapmal.json" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ "$(jq '.tickets[0].blocked_by | length' "$T/snapmal.json")" = "0" ] \
   && [ "$(jq -r '.tickets[0].unblocked' "$T/snapmal.json")" = "true" ] \
   && jq -e '.warnings | any(test("Risk tier"))' "$T/snapmal.json" >/dev/null 2>&1; then
    ok "snapshot: unparseable Blocked-by invents no blockers; missing tier warns"
else
    bad "snapshot: malformed body mishandled (rc=$rc, $(jq -c '.tickets[0].blocked_by' "$T/snapmal.json"))"
fi

# 7j. jq is a hard dependency (the first one past shell/curl/launchctl, hence
#     its addition to the launchd PATH) — say so, do not emit garbage. macOS
#     ships jq in /usr/bin, so the jq-less PATH is built from symlinks to
#     exactly the tools the script touches before the dependency check.
JQLESS="$T/nojq"; mkdir -p "$JQLESS"
for b in bash basename cksum cut mkdir; do ln -sf "$(command -v "$b")" "$JQLESS/$b"; done
out=$(PATH="$JQLESS" GLAB_CMD="$FX/glab-stub.sh" "$TICK" snapshot 2>&1); rc=$?
case "$rc:$out" in
    0:*) bad "snapshot: missing jq did not fail" ;;
    *"jq required"*) ok "snapshot: missing jq fails loudly" ;;
    *) bad "snapshot: missing jq failed unclearly ($out)" ;;
esac

# 7j2. The document builder is a FILE now (snapshot.jq beside tick.sh), not a
#      370-line string inside a shell quote. Two things follow, and both are
#      cheap to check: it must parse on its own — which is the whole reason it
#      was lifted out, after an apostrophe in a comment ended the shell quote
#      mid-word and broke 250 tests — and a missing one must be named as a
#      missing file, not left to jq to complain about its -f argument.
SNAPJQ="$(dirname "$TICK")/snapshot.jq"
# P72: -L, because it opens with `include "lib";` now. Without it jq answers
# "module not found: lib" and the parse check would pass on a program it never
# managed to compile.
err=$(jq -L "$(dirname "$TICK")" -n -f "$SNAPJQ" </dev/null 2>&1 || true)
case "$err" in
    *"syntax error"*|*"unexpected"*|*"module not found"*) bad "snapshot.jq: does not parse ($(printf '%s' "$err" | head -1))" ;;
    *) ok "snapshot.jq: parses standalone — checkable without running a snapshot" ;;
esac
# D-TEST-15: every planted violation from here to the end of 7j4 takes a file
# AWAY, and the file it takes away is one tick.sh ships. Taken away from the
# shipped directory it is taken away from every section running beside this one
# — scripts/ is the single thing they share — so `snapshot`, `plan`, `report`
# and lane.sh's verdict scan all failed at random in whichever section happened
# to be mid-verb. MSCRIPTS is this section's own copy; MTICK resolves its
# siblings off its own path, so hiding a file there proves the same guard and
# nothing outside this process can see it.
MSCRIPTS="$(mirror_scripts "$T/p71-mirror")"
MTICK="$MSCRIPTS/tick.sh"
# Planted violation: hide the file and the guard must name it.
mv "$MSCRIPTS/snapshot.jq" "$T/snapshot.jq.hidden"
out=$(GLAB_CMD="$FX/glab-stub.sh" "$MTICK" snapshot 2>&1); rc=$?
mv "$T/snapshot.jq.hidden" "$MSCRIPTS/snapshot.jq"
case "$rc:$out" in
    0:*) bad "snapshot: ran with no document builder on disk" ;;
    *snapshot.jq*) ok "snapshot: a missing snapshot.jq is named as the missing file" ;;
    *) bad "snapshot: missing builder failed unclearly ($(printf '%s' "$out" | head -1))" ;;
esac

# 7j3. P71: the other six jq programs tick.sh used to embed as single-quoted
#      shell strings are FILES now too, beside tick.sh — render.jq,
#      render-events.jq, usage.jq, report.jq, report-ticket.jq, retro.jq and
#      graph.jq. Same two checks as snapshot.jq above, once per file: it
#      parses on its own, and a missing one is named by the verb that owns it
#      rather than left to jq to complain about its -f argument.
PJ="$T/p71"; mkdir -p "$PJ/home/logs"
PJENV() { LOOM_HOME="$PJ/home" "$@"; }
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}\n' \
    > "$PJ/home/logs/lane-rj1.jsonl"
printf '{"ev":"wave_start","ts":1,"build":"b"}\n{"ev":"wave_end","ts":2,"rc":0,"secs":1,"build":"b"}\n' \
    > "$PJ/home/events.jsonl"
printf '{"tickets":[],"config":{}}\n' > "$PJ/snap.json"

_p71jq() { # _p71jq <basename.jq> <verb-and-args...> — parse check + hide-and-die check
    local jf="$1" fpath; shift
    fpath="$(dirname "$TICK")/$jf"
    local err; err=$(jq -L "$(dirname "$TICK")" -n -f "$fpath" </dev/null 2>&1 || true)
    case "$err" in
        *"syntax error"*|*"unexpected"*|*"module not found"*) bad "$jf: does not parse ($(printf '%s' "$err" | head -1))" ;;
        *) ok "$jf: parses standalone — checkable without running $1" ;;
    esac
    mv "$MSCRIPTS/$jf" "$T/$jf.hidden"
    local out rc; out=$(PJENV "$MTICK" "$@" 2>&1); rc=$?
    mv "$T/$jf.hidden" "$MSCRIPTS/$jf"
    case "$rc:$out" in
        0:*) bad "$jf: $1 ran with no $jf on disk" ;;
        *"$jf"*) ok "$jf: a missing $jf is named as the missing file" ;;
        *) bad "$jf: $1 with missing $jf failed unclearly ($(printf '%s' "$out" | head -1))" ;;
    esac
}
_p71jq render.jq render-log rj1
_p71jq render-events.jq render-events
_p71jq usage.jq retro
_p71jq report.jq report
_p71jq report-ticket.jq report --ticket 1
_p71jq retro.jq retro
_p71jq graph.jq graph "$PJ/snap.json"

# 7j4. P72: all nine of those programs open with `include "lib";`, and the
#      prelude they include — lib.jq, the jq counterpart of lib.sh — ships
#      beside them. Same two checks again: it compiles on its own, and a verb
#      whose program includes it names the MISSING FILE rather than leaving jq
#      to say "module not found: lib", which names neither the file nor the
#      script it ships beside.
LIBJQ="$(dirname "$TICK")/lib.jq"
err=$(jq -L "$(dirname "$TICK")" -n 'include "lib"; empty' 2>&1 || true)
[ -z "$err" ] \
    && ok "lib.jq: compiles on its own — checkable without running any verb" \
    || bad "lib.jq: does not compile ($(printf '%s' "$err" | head -1))"
# The uniform contract, checked as one: every jq program beside tick.sh
# includes the prelude, so there is no per-file question about which ones need
# `-L` and no second mechanism for sharing a definition.
noinc=""
for jf in snapshot.jq plan.jq render.jq render-events.jq usage.jq report.jq report-ticket.jq retro.jq graph.jq; do
    grep -q '^include "lib";$' "$(dirname "$TICK")/$jf" || noinc="$noinc $jf"
done
[ -z "$noinc" ] \
    && ok "lib.jq: every jq program beside tick.sh includes the prelude" \
    || bad "lib.jq: not included by$noinc — those programs cannot use a shared def"
# Planted violation: hide the prelude. Every verb that runs a jq program must
# refuse by name, and the three checked here are the three separate places the
# `-L` directory is resolved (the wave's read, a report, a lane log).
mv "$MSCRIPTS/lib.jq" "$T/lib.jq.hidden"
libmiss=""
for v in "snapshot" "report" "render-log rj1"; do
    # shellcheck disable=SC2086
    out=$(PJENV env GLAB_CMD="$FX/glab-stub.sh" "$MTICK" $v 2>&1); rc=$?
    case "$rc:$out" in
        0:*)      libmiss="$libmiss [$v ran anyway]" ;;
        *lib.jq*) : ;;
        *)        libmiss="$libmiss [$v: $(printf '%s' "$out" | head -1)]" ;;
    esac
done
mv "$T/lib.jq.hidden" "$MSCRIPTS/lib.jq"
[ -z "$libmiss" ] \
    && ok "lib.jq: a missing prelude is named as the missing file by every verb that includes it" \
    || bad "lib.jq: missing prelude reported unclearly —$libmiss"

# 7k. Read-only guardrail: tick.sh must never mutate tracker state (its whole
#     charter). Every captured argv is checked against a mutating denylist.
if grep -Eq "issue (update|close|create|note)|mr (merge|create|update)|label (create|delete)|-X *(POST|PUT|DELETE|PATCH)" "$CALLS"; then
    bad "snapshot: a mutating glab call was issued ($(grep -E 'update|close|create|merge|-X' "$CALLS" | head -1))"
else
    ok "snapshot: every call was a read — no mutating verb in the captured argv"
fi
kill "$(cat "$LOOM_HOME/lanes/merge-51.pid" 2>/dev/null)" 2>/dev/null

# 7f. P11: gate eligibility is DERIVED, not left to the wave to work out.
#     Build 2 spawned a 12m53s verifier on a ticket whose code had merged 95
#     seconds earlier — it produced a FAIL verdict on shipped code — and gated
#     another twice at the identical commit, the duplicate re-running the live
#     suite for ~4 minutes before noticing.
PSNAP() { GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-p11" "$TICK" snapshot 2>"$T/p11.err"; }
rm -f "$FX/notes-12.json"
PSNAP > "$T/p11.json"
if [ "$(jq -r '.tickets[] | select(.id==12) | .gate.eligible' "$T/p11.json")" = "true" ] \
   && [ "$(jq -r '.summary.gateable' "$T/p11.json")" = "1" ] \
   && [ "$(jq -r '.tickets[] | select(.id==12) | .gate.head' "$T/p11.json")" = "e52b7c1000000000000000000000000000000000" ]; then
    ok "gate: a ticket in review with an open MR and no verdict is gateable"
else
    bad "gate: a genuinely gateable ticket was not marked so ($(jq -c '.tickets[]|select(.id==12)|.gate' "$T/p11.json"))"
fi

# 7f2. The merged-underneath case: no open MR left, so no verifier.
cat > "$FX/mrs-12.json" <<'EOF'
[{"iid":77,"title":"Ledger report view","state":"merged","draft":false,"web_url":"https://x/mr/77","source_branch":"t12","sha":"e52b7c1000000000000000000000000000000000"}]
EOF
PSNAP > "$T/p11b.json"
if [ "$(jq -r '.tickets[] | select(.id==12) | .gate.eligible' "$T/p11b.json")" = "false" ] \
   && jq -e '.tickets[] | select(.id==12) | .gate.reason | test("no open merge request")' "$T/p11b.json" >/dev/null 2>&1; then
    ok "gate: a ticket whose MR already merged is not gated again"
else
    bad "gate: merged-underneath ticket still gateable ($(jq -c '.tickets[]|select(.id==12)|.gate' "$T/p11b.json"))"
fi
cat > "$FX/mrs-12.json" <<'EOF'
[{"iid":77,"title":"Ledger report view","state":"opened","draft":false,"web_url":"https://x/mr/77","source_branch":"t12","sha":"e52b7c1000000000000000000000000000000000"}]
EOF

# 7f3. The duplicate-dispatch case. A short sha in the comment must match the
#      long sha on the MR — verdicts are written by humans and models, and both
#      abbreviate.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Review complete. Verdict: PASS.\n\n<!-- orch-verdict PASS e52b7c1 -->"}]
EOF
PSNAP > "$T/p11c.json"
if [ "$(jq -r '.tickets[] | select(.id==12) | .gate.eligible' "$T/p11c.json")" = "false" ] \
   && [ "$(jq -r '.tickets[] | select(.id==12) | .gate.last_verdict.verdict' "$T/p11c.json")" = "PASS" ] \
   && [ "$(jq -r '.summary.gateable' "$T/p11c.json")" = "0" ]; then
    ok "gate: a HEAD already judged is not judged twice (short sha matches long)"
else
    bad "gate: duplicate dispatch not caught ($(jq -c '.tickets[]|select(.id==12)|.gate' "$T/p11c.json" 2>&1) | err: $(head -2 "$T/p11.err"))"
fi

# 7f4. Planted violation: a verdict against a DIFFERENT commit must not suppress
#      the gate — otherwise a rejected ticket that was fixed and re-pushed would
#      never be re-reviewed, which is worse than the duplicate it prevents.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Rejected.\n\n<!-- orch-verdict FAIL 9999999 -->"}]
EOF
PSNAP > "$T/p11d.json"
[ "$(jq -r '.tickets[] | select(.id==12) | .gate.eligible' "$T/p11d.json")" = "true" ] \
    && ok "gate-violation: a verdict on an older commit still leaves the new HEAD gateable" \
    || bad "gate-violation: a stale verdict suppressed the gate — fixes would never be re-reviewed"

# 7f6. The NEWEST verdict at a HEAD wins. Notes arrive newest-first, so taking
#      the last match returned the OLDEST — a ticket rejected and then passed at
#      an unchanged commit read as "already judged FAIL" and would never merge.
#      7f3 planted a single note, so ordering was never exercised at all.
#      (Found by an independent review, 2026-08-01.)
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T15:00:00Z","author":{"username":"gate"},
  "body":"Passed on re-review.\n\n<!-- orch-verdict PASS e52b7c1 -->"},
 {"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Rejected.\n\n<!-- orch-verdict FAIL e52b7c1 -->"}]
EOF
PSNAP > "$T/p11g.json"
[ "$(jq -r '.tickets[] | select(.id==12) | .gate.last_verdict.verdict' "$T/p11g.json")" = "PASS" ] \
    && ok "gate: the newest verdict at a HEAD wins, not the first one fetched" \
    || bad "gate: took the older verdict ($(jq -c '.tickets[]|select(.id==12)|.gate.last_verdict' "$T/p11g.json"))"
# Reversed arrival order must give the same answer. This is a CONSISTENCY check,
# not a guard: with notes already ascending, a plain `last` would also return
# PASS, so it would still pass with the fix reverted. The assertion above is the
# one that actually guards the behaviour.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Rejected.\n\n<!-- orch-verdict FAIL e52b7c1 -->"},
 {"system":false,"created_at":"2026-07-28T15:00:00Z","author":{"username":"gate"},
  "body":"Passed on re-review.\n\n<!-- orch-verdict PASS e52b7c1 -->"}]
EOF
PSNAP > "$T/p11h.json"
[ "$(jq -r '.tickets[] | select(.id==12) | .gate.last_verdict.verdict' "$T/p11h.json")" = "PASS" ] \
    && ok "gate-violation: arrival order does not change which verdict wins" \
    || bad "gate-violation: answer flipped with arrival order — the sort is not doing the work"
rm -f "$FX/notes-12.json"

# 7f7. A `stale` gate lane still holds its ticket. Filtering on `running` alone
#      let a second verifier be dispatched onto a lane that was merely quiet.
#      (Found by an independent review, 2026-08-01.)
"$TICK" spawn-lane gate-12 --no-tick -- sleep 20 >/dev/null
for _ in $(seq 1 40); do [ -f "$LOOM_HOME/logs/lane-gate-12.log" ] && break; sleep 0.1; done
touch -t 202001010000 "$LOOM_HOME/logs/lane-gate-12.log"   # alive, silent since 2020
st=$("$TICK" lane-status | awk '$1=="gate-12"{print $3}')
PSNAP > "$T/p11i.json"
if [ "$st" = "stale" ] \
   && [ "$(jq -r '.tickets[] | select(.id==12) | .gate.eligible' "$T/p11i.json")" = "false" ]; then
    ok "gate: a stale (alive but silent) verifier still blocks a second dispatch"
else
    bad "gate: stale lane state '$st' left the ticket gateable — a duplicate would spawn"
fi
kill "$(cat "$LOOM_HOME/lanes/gate-12.pid" 2>/dev/null)" 2>/dev/null
"$TICK" clear-lane gate-12 >/dev/null

# 7f5. P6 makes this one load-bearing. A lane may now spawn its own gate, and it
#      also fires a completion tick — so the very next wave sees the ticket in
#      `review` with a verifier already on it. Spawning a second under the same
#      id would overwrite the running pid file and rotate its log away, losing
#      the lane that is doing the work.
"$TICK" spawn-lane gate-12 --no-tick -- sleep 20 >/dev/null
PSNAP > "$T/p11e.json"
if [ "$(jq -r '.tickets[] | select(.id==12) | .gate.eligible' "$T/p11e.json")" = "false" ] \
   && jq -e '.tickets[] | select(.id==12) | .gate.reason | test("already running")' "$T/p11e.json" >/dev/null 2>&1; then
    ok "gate: a ticket with a verifier already running is not gated again"
else
    bad "gate: running gate lane did not suppress a second one ($(jq -c '.tickets[]|select(.id==12)|.gate' "$T/p11e.json"))"
fi
kill "$(cat "$LOOM_HOME/lanes/gate-12.pid" 2>/dev/null)" 2>/dev/null
"$TICK" clear-lane gate-12 >/dev/null
# And it must free up again once that lane is gone, or a ticket gated once could
# never be re-gated after a rejection.
PSNAP > "$T/p11f.json"
[ "$(jq -r '.tickets[] | select(.id==12) | .gate.eligible' "$T/p11f.json")" = "true" ] \
    && ok "gate-violation: with the lane cleared the ticket is gateable again" \
    || bad "gate-violation: ticket stayed suppressed after its gate lane ended"

# 7f8. D-TICK-15: `review` + a FAIL standing at HEAD + no gate lane is a
#      permanent, silent stall — ineligible for the gate, invisible to fill
#      (needs `ready-for-agent` + unclaimed), invisible to `summary.stranded`
#      (reads `in-progress`), and no lane for harvest to find. `unblock
#      --to-review` walks a ticket straight into it after a pregate rejection,
#      because a rejection from outside the branch leaves nothing to commit and
#      HEAD never moves (boostlingo build-4 #97, 2026-08-08). Nothing warned.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Pregate rejected: ticket body names the wrong module.\n\n<!-- orch-verdict FAIL e52b7c1 class=wrong-scope -->"}]
EOF
PSNAP > "$T/p11j.json"
jq -e '[.warnings[] | select(test("#12") and test("FAIL verdict standing at")
                             and test("lane.sh transition 12 ready-for-agent"))] | length == 1' \
    "$T/p11j.json" >/dev/null \
    && ok "gate: a review ticket stalled behind a standing FAIL is warned about, with the requeue command" \
    || bad "gate: no stall warning for #12 ($(jq -c .warnings "$T/p11j.json"))"
# Planted violation: the warning must key on a verdict standing at THIS head,
# not on `review` plus any FAIL in the history. #12 was rejected at an older
# commit and re-pushed — it is genuinely gateable, and warning on it would
# push every rework round through a false stall.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Rejected.\n\n<!-- orch-verdict FAIL 9999999 class=wrong-scope -->"}]
EOF
PSNAP > "$T/p11k.json"
if [ "$(jq -r '.tickets[] | select(.id==12) | .gate.eligible' "$T/p11k.json")" = "true" ] \
   && jq -e '[.warnings[] | select(test("#12") and test("FAIL verdict standing at"))] | length == 0' \
        "$T/p11k.json" >/dev/null; then
    ok "gate-violation: a FAIL on an older commit does not read as a stall"
else
    bad "gate-violation: stall warning fired on a gateable ticket ($(jq -c .warnings "$T/p11k.json"))"
fi
# Planted violation: a PASS at HEAD is the same ineligibility and NOT this
# stall — the `pass-not-in-merge-queue` repair already names it, with its own
# command. Two warnings on one ticket is noise the human has to reconcile.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Passed.\n\n<!-- orch-verdict PASS e52b7c1 -->"}]
EOF
PSNAP > "$T/p11l.json"
if jq -e '[.warnings[] | select(test("#12") and test("FAIL verdict standing at"))] | length == 0' \
        "$T/p11l.json" >/dev/null \
   && jq -e '[.warnings[] | select(test("#12") and test("not `merge-queue`"))] | length == 1' \
        "$T/p11l.json" >/dev/null; then
    ok "gate-violation: a PASS at HEAD keeps its own repair warning and does not double up"
else
    bad "gate-violation: PASS-at-HEAD warnings wrong ($(jq -c .warnings "$T/p11l.json"))"
fi
rm -f "$FX/notes-12.json"

test_finish
