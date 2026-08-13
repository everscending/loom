#!/usr/bin/env bash
# P87 stage 3: linear.sh — the contract implemented a second time
#
# Section 32 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
#
# P86 wrote a contract and implemented it once, which makes it a description of
# GitLab until something else implements it too. This is that something else,
# and these tests are about the three places Linear genuinely differs — two
# identifiers where loom wants an integer, workflow states where loom wants open
# and closed, and one assignee where loom wants a list — plus the proof that
# ends the argument: a whole snapshot and plan built from a Linear board.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

SD="$(cd "$(dirname "$TICK")" && pwd)"
LIN="$SD/trackers/linear.sh"
TD="$T/p87lin"; mkdir -p "$TD"

# A Linear API, canned. It answers by looking at the query it was handed, which
# is what makes it a fixture rather than a mock of this driver's own calls: a
# query this file does not recognise gets nothing, and the verb fails.
cat > "$TD/api" <<'STUB'
#!/usr/bin/env bash
out=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output)      out="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    *) shift ;;
  esac
done
q=$(jq -r '.query // ""' "$data" 2>/dev/null)
say()  { printf '%s' "$1" > "$out"; echo 200; }
file() { cat "$1" > "$out"; echo 200; }
case "$q" in
  *"teams(first: 50)"*)      file "${TEAMS_JSON:?}" ;;
  *"issues(first: 250"*)
      # The fixture honours the state filter, because the driver relies on the
      # API to apply it and a stub that ignored it would let this suite pass a
      # driver that never sent one.
      case "$q" in
        *'nin: ["completed", "canceled", "duplicate"]'*)
            filtered=$(jq -c '.data.issues.nodes |= map(select(.state.type != "completed" and .state.type != "canceled" and .state.type != "duplicate"))' "${ISSUES_JSON:?}") ;;
        *'in: ["completed", "canceled", "duplicate"]'*)
            filtered=$(jq -c '.data.issues.nodes |= map(select(.state.type == "completed" or .state.type == "canceled" or .state.type == "duplicate"))' "${ISSUES_JSON:?}") ;;
        *)  filtered=$(cat "${ISSUES_JSON:?}") ;;
      esac
      # D-LIN-01: same honesty about the project filter. The stub only applies
      # it when the query text actually asked for it AND a $project variable
      # rode along — a driver that dropped either half would leak every
      # product on the team straight back through, which is the bug this
      # fixture exists to catch.
      case "$q" in
        *'project: { id: { eq: $project } }'*)
            proj=$(jq -r '.variables.project // ""' "$data" 2>/dev/null)
            [ -n "$proj" ] && filtered=$(printf '%s' "$filtered" \
                | jq -c --arg p "$proj" '.data.issues.nodes |= map(select((.project.id // "") == $p))') ;;
      esac
      printf '%s' "$filtered" > "$out"
      echo 200 ;;
  *"issues(first: 1,"*)
      n=$(jq -r '.variables.n' "$data")
      say "$(jq -c --argjson n "$n" '{data:{issues:{nodes:[ .data.issues.nodes[] | select(.number == $n) ]}}}' "${ISSUES_JSON:?}")" ;;
  *"comments(first:"*)       file "${COMMENTS_JSON:?}" ;;
  *"inverseRelations"*)      file "${RELATIONS_JSON:?}" ;;
  *"labels { nodes { id name } }"*) file "${CURLABELS_JSON:?}" ;;
  # P92: the ONE project's milestones, and one milestone's own description —
  # matched before the plain "projects(first: 250)" team-projects listing,
  # which is a different query (no "Milestones") and stays the back-compat path.
  *"projectMilestones(first: 250)"*) file "${MILESTONES_JSON:?}" ;;
  *'projectMilestone(id: $id) { description }'*) file "${MSDESC_JSON:?}" ;;
  *"projects(first: 250)"*)  file "${PROJECTS_JSON:?}" ;;
  *"labels(first: 250)"*)    file "${LABELS_JSON:?}" ;;
  *"states(first: 50)"*)     file "${STATES_JSON:?}" ;;
  *viewer*)
      say '{"data":{"viewer":{"id":"user-uuid","name":"loom","displayName":"Loom Bot"}}}' ;;
  *issueUpdate*|*issueCreate*|*commentCreate*|*issueLabelCreate*|*projectMilestoneUpdate*|*projectUpdate*|*workflowStateCreate*)
      jq -c '.variables' "$data" >> "${MUT_LOG:-/dev/null}"
      say '{"data":{"issueCreate":{"success":true,"issue":{"number":99}},"issueUpdate":{"success":true},"commentCreate":{"success":true},"issueLabelCreate":{"success":true},"projectUpdate":{"success":true},"projectMilestoneUpdate":{"success":true},"workflowStateCreate":{"success":true}}}' ;;
  *)  printf '{"errors":[{"message":"unrecognised query"}]}' > "$out"; echo 200 ;;
esac
STUB
chmod +x "$TD/api"

# The board. One Build issue and four tickets, chosen to exercise the places
# Linear does not look like GitLab: a canceled ticket and a duplicate one (two
# state types with no GitLab equivalent), an unassigned one, and one with an
# assignee. Loom's state now lives in `state.name` (P90) — a Status, not a
# label — so only `build-7` (a real label) survives on 2 and 3.
cat > "$TD/issues.json" <<'JSON'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"id":"u1","number":1,"title":"Build 7","description":"**Selected epics**\n- Ledger (#2)\n",
  "url":"https://linear.app/acme/issue/ENG-1","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"started","name":"In Progress"},"labels":{"nodes":[]},"assignee":null,"project":null},
 {"id":"u2","number":2,"title":"Add the ledger","description":"## Risk tier\n\nlogic\n\n## Blocked by\n\nNone - can start immediately\n",
  "url":"https://linear.app/acme/issue/ENG-2","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"unstarted","name":"Todo"},"labels":{"nodes":[{"name":"build-7"}]},
  "assignee":null,"project":{"name":"Ledger"}},
 {"id":"u3","number":3,"title":"Wire the ledger up","description":"## Risk tier\n\napi\n",
  "url":"https://linear.app/acme/issue/ENG-3","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"started","name":"In Progress"},"labels":{"nodes":[{"name":"build-7"}]},
  "assignee":{"name":"jo","displayName":"Jo"},"project":{"name":"Ledger"}},
 {"id":"u4","number":4,"title":"Dropped idea","description":"nope\n",
  "url":"https://linear.app/acme/issue/ENG-4","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"canceled","name":"Canceled"},"labels":{"nodes":[{"name":"build-7"}]},
  "assignee":null,"project":{"name":"Ledger"}},
 {"id":"u5","number":5,"title":"Same as #2, filed twice","description":"oops\n",
  "url":"https://linear.app/acme/issue/ENG-5","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"duplicate","name":"Duplicate"},"labels":{"nodes":[{"name":"build-7"}]},
  "assignee":null,"project":{"name":"Ledger"}}
]}}}
JSON

mkdir -p "$TD/repo/docs/agents"
git -C "$TD/repo" init -q >/dev/null 2>&1
git -C "$TD/repo" remote add origin https://github.com/acme/app.git >/dev/null 2>&1
printf '# Issue tracker: Linear\n\nTeam: ENG\n' > "$TD/repo/docs/agents/issue-tracker.md"
git -C "$TD/repo" add -A >/dev/null 2>&1

# Every canned answer is a FILE, and each has a default. A query this fixture
# does not recognise still fails, but a query it does recognise never fails for
# want of a shell-quoting trick inside the stub.
printf '{"data":{"teams":{"nodes":[{"id":"team-uuid","key":"ENG","name":"Engineering"}]}}}' > "$TD/teams.json"
printf '{"data":{"issue":{"comments":{"nodes":[]}}}}' > "$TD/comments.json"
printf '{"data":{"issue":{"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}' > "$TD/relations.json"
printf '{"data":{"issue":{"labels":{"nodes":[]}}}}' > "$TD/curlabels.json"
printf '{"data":{"team":{"projects":{"nodes":[]}}}}' > "$TD/projects.json"
printf '{"data":{"team":{"labels":{"nodes":[]}}}}' > "$TD/labels.json"
# P92 defaults — never hit unless a test declares a 'Project:' line.
printf '{"data":{"project":{"projectMilestones":{"nodes":[]}}}}' > "$TD/milestones.json"
printf '{"data":{"projectMilestone":{"description":""}}}' > "$TD/msdesc.json"
# A team that, like the real one P90 was written against, has Todo, In
# Progress and Done already and is missing the three loom has to create.
printf '{"data":{"team":{"states":{"nodes":[
  {"id":"st-todo","name":"Todo","type":"unstarted","position":1},
  {"id":"st-doing","name":"In Progress","type":"started","position":2},
  {"id":"st-done","name":"Done","type":"completed","position":3}
]}}}}' > "$TD/states.json"
# The same team after `bootstrap.sh states` has run: all five plus Done.
printf '{"data":{"team":{"states":{"nodes":[
  {"id":"st-todo","name":"Todo","type":"unstarted","position":1},
  {"id":"st-doing","name":"In Progress","type":"started","position":2},
  {"id":"st-review","name":"In Review","type":"started","position":3},
  {"id":"st-merge","name":"Merge Queue","type":"started","position":4},
  {"id":"st-blocked","name":"Blocked","type":"started","position":5},
  {"id":"st-done","name":"Done","type":"completed","position":6}
]}}}}' > "$TD/states-full.json"

API_ENV() { # the canned API, with every fixture defaulted
    printf '%s\n' "LINEAR_API_KEY=k" "CURL_CMD=$TD/api" "ISSUES_JSON=${ISSUES_JSON:-$TD/issues.json}" \
        "TEAMS_JSON=${TEAMS_JSON:-$TD/teams.json}" "COMMENTS_JSON=${COMMENTS_JSON:-$TD/comments.json}" \
        "RELATIONS_JSON=${RELATIONS_JSON:-$TD/relations.json}" "CURLABELS_JSON=${CURLABELS_JSON:-$TD/curlabels.json}" \
        "PROJECTS_JSON=${PROJECTS_JSON:-$TD/projects.json}" "LABELS_JSON=${LABELS_JSON:-$TD/labels.json}" \
        "STATES_JSON=${STATES_JSON:-$TD/states.json}" \
        "MILESTONES_JSON=${MILESTONES_JSON:-$TD/milestones.json}" "MSDESC_JSON=${MSDESC_JSON:-$TD/msdesc.json}" \
        "LOOM_REPO=$TD/repo" "MUT_LOG=${MUT_LOG:-/dev/null}"
}
L() { # L <verb...> — the driver, against the canned API
    env $(API_ENV | tr '\n' ' ') "$LIN" "$@"
}

# --- p87-l1. `id` is an integer -------------------------------------------
# A Linear issue carries a UUID and a human identifier like `ENG-2`, and loom
# wants neither. The jq layer does arithmetic on ticket ids — graph.jq converts
# them, snapshot.jq scans `#([0-9]+)` out of a `## Blocked by` list, plan.jq
# parses a lane name back to a number — so an opaque string id is a rewrite of
# all of it. `Issue.number` is an integer, sequential within a team, which is
# structurally what GitLab's `iid` is within a project.
open_json=$(L issues-open)
printf '%s' "$open_json" | jq -e 'all(.[]; .id | type == "number")' >/dev/null 2>&1 \
    && ok "document: every id is an integer, not a UUID and not 'ENG-2'" \
    || bad "document: an id came back as something other than a number ($(printf '%s' "$open_json" | jq -c '[.[].id]'))"
[ "$(L issue 2 | jq -r '.id')" = 2 ] \
    && ok "document: a single-issue read agrees with the list read on the id" \
    || bad "document: 'issue 2' did not answer with id 2"
# And no Linear field name escapes the driver.
printf '%s' "$open_json" | grep -qE '"(number|updatedAt|displayName|identifier)"' \
    && bad "document: a Linear field name survived into the driver's output" \
    || ok "document: no Linear field name appears in the output at all"

# --- p87-l2. Workflow states collapse to open and closed -------------------
# Linear has five state TYPES. `canceled` is the one worth naming: dropping it
# instead of closing it would leave a ticket that will never move sitting in the
# scheduler's universe forever.
printf '%s' "$open_json" | jq -e 'all(.[]; .state == "open")' >/dev/null 2>&1 \
    && ok "state: backlog, unstarted and started all read as open" \
    || bad "state: an open-set issue came back closed ($(printf '%s' "$open_json" | jq -c '[.[]|{id,state}]'))"
[ "$(printf '%s' "$open_json" | jq '[.[] | select(.id == 4)] | length')" = 0 ] \
    && ok "state: the canceled ticket is not in the open set" \
    || bad "state: a canceled ticket was listed as open"
[ "$(L issue 4 | jq -r '.state')" = closed ] \
    && ok "state: and asked about directly it is CLOSED, not dropped — a ticket that will never move is done" \
    || bad "state: a canceled issue did not map to closed ($(L issue 4 | jq -r '.state'))"

# --- p87-l3. One assignee, and the contract wants a list -------------------
# `null` would be worse than wrong: the scheduler's ready set tests
# `assignees | length == 0`, and jq says `null | length` is 0 — so it would work
# until the day something else asked.
[ "$(L issue 2 | jq -c '.assignees')" = "[]" ] \
    && ok "assignees: an unassigned ticket is an empty ARRAY, never null" \
    || bad "assignees: unassigned came back as $(L issue 2 | jq -c '.assignees')"
[ "$(L issue 3 | jq -c '.assignees')" = '["Jo"]' ] \
    && ok "assignees: an assigned one is a one-element array of the name" \
    || bad "assignees: assigned came back as $(L issue 3 | jq -c '.assignees')"
[ "$(L issue 2 | jq -r '.epic')" = Ledger ] \
    && ok "epic: a Linear Project is the epic — the closest thing it has to a milestone" \
    || bad "epic: the project name did not become the epic"

# --- p87-l4. Blocking edges ------------------------------------------------
# The direction matters. `relations` is what this issue does to others;
# `inverseRelations` is what is done to it, and that is the one the scheduler
# will not start a ticket over.
printf '%s' '{"data":{"issue":{"relations":{"nodes":[{"type":"related","relatedIssue":{"number":9,"state":{"type":"started"}}}]},"inverseRelations":{"nodes":[{"type":"blocks","issue":{"number":2,"state":{"type":"completed"}}}]}}}}' > "$TD/rel.json"
links=$(RELATIONS_JSON="$TD/rel.json" L issue-links 3)
[ "$(printf '%s' "$links" | jq -r '[.[] | select(.type == "is_blocked_by")] | .[0].id')" = 2 ] \
    && ok "links: an incoming 'blocks' relation becomes the is_blocked_by edge the scheduler reads" \
    || bad "links: no is_blocked_by edge was produced ($(printf '%s' "$links" | jq -c .))"
[ "$(printf '%s' "$links" | jq -r '[.[] | select(.type == "is_blocked_by")] | .[0].state')" = closed ] \
    && ok "links: and the blocker's state comes through — a closed blocker is what unblocks a ticket" \
    || bad "links: the blocker's state was wrong ($(printf '%s' "$links" | jq -c .))"
[ "$(printf '%s' "$links" | jq -r '[.[] | select(.type == "relates_to")] | .[0].id')" = 9 ] \
    && ok "links: a 'related' relation becomes relates_to, which is a different edge and stays one" \
    || bad "links: the relates_to edge was lost"
# Never null, unlike GitLab's stateless cross-project link: Linear always knows.
printf '%s' "$links" | jq -e 'all(.[]; .state != null)' >/dev/null 2>&1 \
    && ok "links: no edge carries an unknown state — Linear answers it, so nothing is guessed at" \
    || bad "links: an edge came back with a null state"

# --- p87-l5. The team ------------------------------------------------------
# Linear issues belong to a Team and no git remote names it. One LINE in the
# declaration file the tracker's name already lives in — not a second file, so
# P86's single-source finding holds.
printf '%s' '{"data":{"teams":{"nodes":[{"id":"a","key":"ENG","name":"Eng"},{"id":"b","key":"OPS","name":"Ops"}]}}}' > "$TD/two-teams.json"
TWO="$TD/two-teams.json"
out=$(TEAMS_JSON="$TWO" L issue 2 2>&1)
[ "$(printf '%s' "$out" | jq -r '.project' 2>/dev/null)" = ENG ] \
    && ok "team: the 'Team:' line picks the right team out of several" \
    || bad "team: the declared team was not used ($(printf '%s' "$out" | head -2 | tr '\n' ' '))"
printf '# Issue tracker: Linear\n' > "$TD/repo/docs/agents/issue-tracker.md"
out=$(TEAMS_JSON="$TWO" L issue 2 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "ENG, OPS"; then
    ok "team: several teams and no line is a HALT naming them, never a pick"
else
    bad "team: an ambiguous team was resolved anyway (rc=$rc, out=$(printf '%s' "$out" | head -1))"
fi
out=$(L issue 2 2>&1); rc=$?
[ "$rc" = 0 ] \
    && ok "team: with exactly one team visible the line is unnecessary — no ceremony for the common case" \
    || bad "team: a single-team key still demanded a declaration line"
printf '# Issue tracker: Linear\n\nTeam: NOPE\n' > "$TD/repo/docs/agents/issue-tracker.md"
out=$(TEAMS_JSON="$TWO" L issue 2 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "NOPE" \
    && ok "team: a declared team the key cannot see is refused by name, listing what it can see" \
    || bad "team: an unknown team key was accepted (rc=$rc)"
printf '# Issue tracker: Linear\n\nTeam: ENG\n' > "$TD/repo/docs/agents/issue-tracker.md"

# --- p87-l6. Writes go through Linear's shape ------------------------------
# Linear has no add/remove for labels: the set is written whole. So the current
# set has to be READ first — writing only the additions would silently strip
# every label the ticket has. Real labels (P90 left these alone) still get the
# whole-set rewrite.
printf '%s' '{"data":{"team":{"labels":{"nodes":[{"id":"l1","name":"build-7"},{"id":"l2","name":"fix"},{"id":"l3","name":"tier::logic"}]}}}}' > "$TD/lbl.json"
printf '%s' '{"data":{"issue":{"labels":{"nodes":[{"id":"l1","name":"build-7"}]}}}}' > "$TD/curlbl.json"
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" LABELS_JSON="$TD/lbl.json" CURLABELS_JSON="$TD/curlbl.json" \
  L issue-relabel 2 --add fix,tier::logic --remove build-7 >/dev/null 2>&1 || true
if grep -q '"l2"' "$TD/mut.log" && grep -q '"l3"' "$TD/mut.log" && ! grep -q '"l1"' "$TD/mut.log"; then
    ok "relabel: real labels (fix, tier::logic) still get the whole-set rewrite — build-7 dropped, both new ones added"
else
    bad "relabel: the label set written was wrong ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"
fi
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" L issue-relabel 2 --unassign >/dev/null 2>&1 || true
grep -q '"assigneeId":null' "$TD/mut.log" \
    && ok "relabel: --unassign is null on Linear, where it is 0 on GitLab — the verb is named, not numeric" \
    || bad "relabel: --unassign did not clear the assignee ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"
: > "$TD/mut.log"
printf 'a long note\nwith a newline\n' > "$TD/note.md"
MUT_LOG="$TD/mut.log" L note-add 2 "$TD/note.md" >/dev/null 2>&1 || true
grep -q 'with a newline' "$TD/mut.log" \
    && ok "note-add: the body travels as a JSON variable, newlines and all — never on a command line" \
    || bad "note-add: the note body did not reach the mutation"
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" L issue-close 2 >/dev/null 2>&1 || true
grep -q 'st-done' "$TD/mut.log" \
    && ok "close: closing is a move to the team's own completed-type state, not a name this driver invented" \
    || bad "close: the completed state was not used ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"

# --- p90-1. Linear's Status field is loom's state machine ------------------
# P90: `ready-for-agent`, `in-progress`, `review`, `merge-queue`, `blocked`
# used to be written as labels. They are Statuses now — a loom state name in
# --add becomes stateId in the SAME mutation, never a labelIds entry, and a
# state name in --remove is dropped rather than attempted as a label removal.
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" STATES_JSON="$TD/states.json" \
  L issue-relabel 2 --add in-progress --remove ready-for-agent >/dev/null 2>&1 || true
if grep -q '"stateId":"st-doing"' "$TD/mut.log" && ! grep -q 'labelIds' "$TD/mut.log"; then
    ok "state: --add in-progress writes a stateId mutation, and the --remove of another state name writes no label change at all"
else
    bad "state: the state-add mutation was wrong ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"
fi
out=$(MUT_LOG="$TD/mut.log" STATES_JSON="$TD/states-full.json" \
        L issue-relabel 2 --add in-progress,blocked 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "two ticket states" \
    && ok "state: two ticket states in one --add is refused, never a coin flip" \
    || bad "state: two states in one --add was accepted (rc=$rc, $out)"
# fix-ticket creates with 'ready-for-agent' inline in --labels, the way every
# other driver does — this must set the initial Status, not fail `_label_ids`
# on a name that was never a real Linear label.
printf '%s' '{"data":{"team":{"labels":{"nodes":[{"id":"l1","name":"build-7"},{"id":"l2","name":"fix"},{"id":"l3","name":"tier::logic"}]}}}}' > "$TD/lbl.json"
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" LABELS_JSON="$TD/lbl.json" STATES_JSON="$TD/states.json" \
  L issue-create --title "t" --body-file "$TD/note.md" --labels "build-7,fix,ready-for-agent" >/dev/null 2>&1 || true
if grep -q '"stateId":"st-todo"' "$TD/mut.log" && grep -q '"l1"' "$TD/mut.log" && grep -q '"l2"' "$TD/mut.log"; then
    ok "state: issue-create splits 'ready-for-agent' out of --labels into the initial Status, the reals into labelIds"
else
    bad "state: issue-create did not split the state name out of --labels ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"
fi

# --- p90-2. The mapping is injective, in both directions --------------------
# Loom has five open states; collapsing any pair breaks a specific scheduler
# guard (SKILL.md). Read direction: five issues, one per Status, must each read
# back exactly the ONE matching loom label — never zero, never two.
cat > "$TD/rt-issues.json" <<'JSON'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"id":"r1","number":101,"title":"t","description":"","url":null,"updatedAt":null,"state":{"type":"unstarted","name":"Todo"},"labels":{"nodes":[]},"assignee":null,"project":null},
 {"id":"r2","number":102,"title":"t","description":"","url":null,"updatedAt":null,"state":{"type":"started","name":"In Progress"},"labels":{"nodes":[]},"assignee":null,"project":null},
 {"id":"r3","number":103,"title":"t","description":"","url":null,"updatedAt":null,"state":{"type":"started","name":"In Review"},"labels":{"nodes":[]},"assignee":null,"project":null},
 {"id":"r4","number":104,"title":"t","description":"","url":null,"updatedAt":null,"state":{"type":"started","name":"Merge Queue"},"labels":{"nodes":[]},"assignee":null,"project":null},
 {"id":"r5","number":105,"title":"t","description":"","url":null,"updatedAt":null,"state":{"type":"started","name":"Blocked"},"labels":{"nodes":[]},"assignee":null,"project":null},
 {"id":"r6","number":106,"title":"t","description":"","url":null,"updatedAt":null,"state":{"type":"unstarted","name":"Icebox"},"labels":{"nodes":[]},"assignee":null,"project":null}
]}}}
JSON
rt=$(ISSUES_JSON="$TD/rt-issues.json" L issues-open)
for pair in "101 ready-for-agent" "102 in-progress" "103 review" "104 merge-queue" "105 blocked"; do
    set -- $pair
    got=$(printf '%s' "$rt" | jq -c --argjson n "$1" '[.[] | select(.id == $n)][0].labels')
    if printf '%s' "$got" | jq -e --arg w "$2" 'index($w) != null and length == 1' >/dev/null 2>&1; then
        ok "state round trip: issue $1 (Status '$2's default) reads back exactly that one loom label — a collapsed pair would fail this"
    else
        bad "state round trip: issue $1 expected only '$2', got $got"
    fi
done
[ "$(printf '%s' "$rt" | jq -c '[.[] | select(.id == 106)][0].labels')" = "[]" ] \
    && ok "state: an unrecognised Status ('Icebox') produces no state label at all — never a guessed one" \
    || bad "state: issue 106 (unrecognised Status) got a state label it should not have ($(printf '%s' "$rt" | jq -c '[.[] | select(.id == 106)][0].labels'))"
# Write direction: each of the five resolves to its OWN distinct state id.
: > "$TD/rt-write.log"
for s in ready-for-agent in-progress review merge-queue blocked; do
    : > "$TD/mut.log"
    MUT_LOG="$TD/mut.log" STATES_JSON="$TD/states-full.json" L issue-relabel 2 --add "$s" >/dev/null 2>&1 || true
    jq -r '.input.stateId' "$TD/mut.log" >> "$TD/rt-write.log" 2>/dev/null
done
[ "$(sort -u "$TD/rt-write.log" | wc -l | tr -d ' ')" = 5 ] \
    && ok "state round trip: all five states resolve to five DISTINCT workflow-state ids on write" \
    || bad "state round trip (write): $(tr '\n' ' ' < "$TD/rt-write.log")"

# --- p90-3. `duplicate` reads closed and is absent from issues-open ---------
# The same failure canceled would have been, dropped instead of closed: a
# ticket that will never move sitting in the scheduler's universe forever.
[ "$(printf '%s' "$open_json" | jq '[.[] | select(.id == 5)] | length')" = 0 ] \
    && ok "duplicate: a duplicate-type ticket is not in the open set" \
    || bad "duplicate: a duplicate ticket was listed as open"
[ "$(L issue 5 | jq -r '.state')" = closed ] \
    && ok "duplicate: and asked about directly it reads CLOSED, like canceled — never dropped" \
    || bad "duplicate: a duplicate issue did not map to closed ($(L issue 5 | jq -r '.state'))"

# --- p90-4. A human hold set through Status still trips _blocked_guard -----
jq '(.data.issues.nodes[] | select(.number == 2) | .state) = {"type":"started","name":"Blocked"}' \
   "$TD/issues.json" > "$TD/blocked-issues.json"
out=$(env $(API_ENV | tr '\n' ' ') TRACKER_CMD="$LIN" ISSUES_JSON="$TD/blocked-issues.json" \
        STATES_JSON="$TD/states-full.json" LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
        "$LANE" transition 2 review 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q "blocked" \
    && ok "blocked: a hold set through Status (not a label) still makes _blocked_guard fire" \
    || bad "blocked: the guard did not fire against a Status-held ticket (rc=$rc, $(printf '%s' "$out" | head -1))"

# --- p90-5. bootstrap.sh states: create only what is missing ---------------
BOOT="$SD/bootstrap.sh"
BOOTENV() { env $(API_ENV | tr '\n' ' ') TRACKER_CMD="$LIN" LOOM_HOME="$TD/boot-home" \
              LOOM_GLOBAL_CONFIG="$TD/g.yml" "$@"; }
: > "$TD/mut.log"
out=$(MUT_LOG="$TD/mut.log" BOOTENV "$BOOT" states --dry-run 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "would create 'In Review'" \
   && printf '%s' "$out" | grep -q "would create 'Merge Queue'" \
   && printf '%s' "$out" | grep -q "would create 'Blocked'" \
   && printf '%s' "$out" | grep -q "would create 3, 2 already present" \
   && [ ! -s "$TD/mut.log" ]; then
    ok "bootstrap states: dry run names the three missing states (Todo and In Progress already exist) and writes nothing"
else
    bad "bootstrap states: dry run was wrong (rc=$rc, mut=$(tr -d '\n' < "$TD/mut.log"), out=$out)"
fi
: > "$TD/mut.log"
out=$(MUT_LOG="$TD/mut.log" BOOTENV "$BOOT" states 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "states: 3 created, 2 already present" \
   && [ "$(wc -l < "$TD/mut.log" | tr -d ' ')" = 3 ] \
   && grep -q '"name":"In Review"' "$TD/mut.log" && grep -q '"type":"started"' "$TD/mut.log"; then
    ok "bootstrap states: creates exactly the three missing states, all of type 'started'"
else
    bad "bootstrap states: real run was wrong (rc=$rc, out=$out, mut=$(tr -d '\n' < "$TD/mut.log"))"
fi
: > "$TD/mut.log"
out=$(MUT_LOG="$TD/mut.log" STATES_JSON="$TD/states-full.json" BOOTENV "$BOOT" states 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "states: 0 created, 5 already present" && [ ! -s "$TD/mut.log" ] \
    && ok "bootstrap states: idempotent — a team that already has all five creates nothing" \
    || bad "bootstrap states: a complete board was not a no-op (rc=$rc, out=$out)"
# Not applicable on a tracker that already carries these five as real labels.
GLTD="$T/p90gl"; mkdir -p "$GLTD/repo/docs/agents"
git -C "$GLTD/repo" init -q >/dev/null 2>&1
printf '# Issue tracker: GitLab\n' > "$GLTD/repo/docs/agents/issue-tracker.md"
git -C "$GLTD/repo" add -A >/dev/null 2>&1
out=$(LOOM_REPO="$GLTD/repo" LOOM_HOME="$GLTD/home" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
        "$BOOT" states 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "not applicable" \
    && ok "bootstrap states: a no-op, plainly, on a GitLab-boarded repo — these five are already real labels there" \
    || bad "bootstrap states: did not recognise GitLab as not applicable (rc=$rc, $out)"

# --- p90-6. Overrides win over defaults, and a name the team lacks halts ---
printf '# Issue tracker: Linear\n\nTeam: ENG\nStatus review: Code Review\nStatus closed: Shipped\n' \
    > "$TD/repo/docs/agents/issue-tracker.md"
printf '%s' '{"data":{"team":{"states":{"nodes":[
  {"id":"st-cr","name":"Code Review","type":"started","position":1},
  {"id":"st-ship","name":"Shipped","type":"completed","position":2}
]}}}}' > "$TD/override-states.json"
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" STATES_JSON="$TD/override-states.json" \
  L issue-relabel 2 --add review >/dev/null 2>&1 || true
grep -q '"stateId":"st-cr"' "$TD/mut.log" \
    && ok "override: 'Status review: Code Review' in the declaration file wins over the default 'In Review'" \
    || bad "override: the review override was not used ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" STATES_JSON="$TD/override-states.json" L issue-close 2 >/dev/null 2>&1 || true
grep -q '"stateId":"st-ship"' "$TD/mut.log" \
    && ok "override: 'Status closed: Shipped' picks the named completed state, not the lowest-position one" \
    || bad "override: the closed override was not used ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"
out=$(STATES_JSON="$TD/states.json" L issue-relabel 2 --add review 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "Code Review" \
    && ok "override: a name the team does not have is a halt naming it, never a silent fall back to the default" \
    || bad "override: a missing override name was silently accepted (rc=$rc, $out)"
printf '# Issue tracker: Linear\n\nTeam: ENG\n' > "$TD/repo/docs/agents/issue-tracker.md"

# --- p92. A declared Project keeps epics as ProjectMilestones inside it ----
# A board whose whole product is one Linear Project (like the pre-P92 default
# read a board with several products) keeps its epics as ProjectMilestones
# INSIDE that project. A `Project:` line beside `Team:` opts a repo in; no
# such line keeps every case above — read all the way through p90-6 — exactly
# as it was, which is the back-compat half of this proposal.
printf '%s' '{"data":{"team":{"projects":{"nodes":[
 {"id":"proj-tapi","name":"Triggers API"},
 {"id":"proj-other","name":"Demand Letter Generator"}
]}}}}' > "$TD/p92-teamprojects.json"
printf '# Issue tracker: Linear\n\nTeam: ENG\nProject: Triggers API\n' > "$TD/repo/docs/agents/issue-tracker.md"

# p92-1: an issue whose Status and ProjectMilestone are both set reads back
# the MILESTONE's name as epic, never the project's — the opposite of the
# pre-P92 (and still back-compat) mapping proven above.
cat > "$TD/p92-issues.json" <<'JSON'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"id":"u201","number":201,"title":"Bootstrap gate script","description":"","url":null,"updatedAt":null,
  "state":{"type":"unstarted","name":"Todo"},"labels":{"nodes":[]},"assignee":null,
  "project":{"name":"Triggers API"},"projectMilestone":{"id":"ms-e1","name":"E1 Bootstrap"}}
]}}}
JSON
[ "$(PROJECTS_JSON="$TD/p92-teamprojects.json" ISSUES_JSON="$TD/p92-issues.json" L issue 201 | jq -r '.epic')" = "E1 Bootstrap" ] \
    && ok "p92: epic reads the ProjectMilestone's name, not the project's, once a Project: line is declared" \
    || bad "p92: epic did not read the milestone name ($(PROJECTS_JSON="$TD/p92-teamprojects.json" ISSUES_JSON="$TD/p92-issues.json" L issue 201 | jq -c .))"

# p92-2: `milestones` returns the declared project's OWN milestones, never the
# team's other projects — the assertion that failed before this proposal,
# when `milestones` on this same declaration listed "Triggers API" and
# "Demand Letter Generator" as if they were epics.
cat > "$TD/p92-milestones.json" <<'JSON'
{"data":{"project":{"projectMilestones":{"nodes":[
 {"id":"ms-e1","name":"E1 Bootstrap","description":"## Acceptance criteria\n\n- [ ] it gates\n"},
 {"id":"ms-e2","name":"E2 Ledger","description":"## Acceptance criteria\n\n- [ ] it balances\n\n<!-- loom-accepted 2026-08-10T00:00:00Z -->"}
]}}}}
JSON
ms=$(MILESTONES_JSON="$TD/p92-milestones.json" PROJECTS_JSON="$TD/p92-teamprojects.json" L milestones)
[ "$(printf '%s' "$ms" | jq -r '[.[].title] | sort | join(",")')" = "E1 Bootstrap,E2 Ledger" ] \
    && ok "p92: milestones lists the declared project's own ProjectMilestones, not the team's other projects" \
    || bad "p92: milestones returned the wrong set ($(printf '%s' "$ms" | jq -c '[.[].title]'))"
[ "$(printf '%s' "$ms" | jq -r '[.[] | select(.title == "E1 Bootstrap")][0].state')" = open ] \
    && [ "$(printf '%s' "$ms" | jq -r '[.[] | select(.title == "E2 Ledger")][0].state')" = closed ] \
    && ok "p92: a ProjectMilestone's state is derived from the loom-accepted trailer in its description, not a Linear state field it doesn't have" \
    || bad "p92: milestone state was not derived from the trailer ($(printf '%s' "$ms" | jq -c .))"
[ "$(MILESTONES_JSON="$TD/p92-milestones.json" PROJECTS_JSON="$TD/p92-teamprojects.json" L milestones --state active \
      | jq -r '[.[].title] | join(",")')" = "E1 Bootstrap" ] \
    && ok "p92: --state active returns only the un-accepted milestone" \
    || bad "p92: --state active did not filter to the open milestone"

# p92-3: closing a ProjectMilestone appends the trailer and calls
# projectMilestoneUpdate, never projectUpdate (which would complete the whole
# product) — and a second close appends nothing.
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" PROJECTS_JSON="$TD/p92-teamprojects.json" MSDESC_JSON="$TD/msdesc.json" \
  L milestone-close ms-e1 >/dev/null 2>&1 || true
if grep -q '"d":".*loom-accepted' "$TD/mut.log"; then
    ok "p92: milestone-close appends the loom-accepted trailer to the milestone's own description"
else
    bad "p92: milestone-close did not write the accepted trailer ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"
fi
: > "$TD/mut.log"
printf '{"data":{"projectMilestone":{"description":"## Acceptance criteria\n\n- [ ] it gates\n\n<!-- loom-accepted 2026-08-10T00:00:00Z -->"}}}' \
    > "$TD/p92-msdesc-done.json"
MUT_LOG="$TD/mut.log" PROJECTS_JSON="$TD/p92-teamprojects.json" MSDESC_JSON="$TD/p92-msdesc-done.json" \
  L milestone-close ms-e1 >/dev/null 2>&1 || true
[ ! -s "$TD/mut.log" ] \
    && ok "p92: closing an already-accepted milestone appends nothing — idempotent by the trailer's presence" \
    || bad "p92: a second close appended another trailer ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"

# p92-4: issue-create --milestone-id sends projectMilestoneId, with projectId
# from the declaration — not the pre-P92 shape where --milestone-id WAS the
# projectId.
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" LABELS_JSON="$TD/lbl.json" STATES_JSON="$TD/states.json" PROJECTS_JSON="$TD/p92-teamprojects.json" \
  L issue-create --title "t" --body-file "$TD/note.md" --labels "ready-for-agent" --milestone-id ms-e1 >/dev/null 2>&1 || true
if grep -q '"projectMilestoneId":"ms-e1"' "$TD/mut.log" && grep -q '"projectId":"proj-tapi"' "$TD/mut.log"; then
    ok "p92: issue-create sends projectMilestoneId for --milestone-id and projectId from the declared Project"
else
    bad "p92: issue-create did not split project and milestone ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"
fi

# p92-5: back-compat — with NO Project: line, --milestone-id is still the
# pre-P92 projectId, exactly as before this proposal.
printf '# Issue tracker: Linear\n\nTeam: ENG\n' > "$TD/repo/docs/agents/issue-tracker.md"
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" LABELS_JSON="$TD/lbl.json" STATES_JSON="$TD/states.json" \
  L issue-create --title "t" --body-file "$TD/note.md" --labels "ready-for-agent" --milestone-id proj-x >/dev/null 2>&1 || true
if grep -q '"projectId":"proj-x"' "$TD/mut.log" && ! grep -q projectMilestoneId "$TD/mut.log"; then
    ok "p92: back-compat — no Project: line, --milestone-id is still projectId, unchanged"
else
    bad "p92: back-compat issue-create shape changed with no Project: line ($(tr -d '\n' < "$TD/mut.log" | head -c 200))"
fi

# p92-6: `_tracker_decl_field` reads a markdown list item — `- Team: **ENG**
# (key ENG)`, what a human actually writes — the same as the bare `Team: ENG`
# form, for both fields it drives.
printf '# Issue tracker: Linear\n\n- Team: **ENG** (key ENG)\n' > "$TD/repo/docs/agents/issue-tracker.md"
[ "$(TEAMS_JSON="$TWO" L issue 2 2>&1 | jq -r '.project' 2>/dev/null)" = ENG ] \
    && ok "p92: '- Team: **ENG** (key ENG)' reads as 'ENG', a bullet list item with bold and a parenthetical" \
    || bad "p92: the bulleted Team: line was not parsed"
printf '# Issue tracker: Linear\n\nTeam: ENG\nProject: **Triggers API** (the one product)\n' \
    > "$TD/repo/docs/agents/issue-tracker.md"
[ "$(PROJECTS_JSON="$TD/p92-teamprojects.json" ISSUES_JSON="$TD/p92-issues.json" L issue 201 | jq -r '.epic')" = "E1 Bootstrap" ] \
    && ok "p92: the same bold-and-parenthetical parsing applies to 'Project:'" \
    || bad "p92: a bold Project: value was not resolved"
printf '# Issue tracker: Linear\n\nTeam: ENG\n' > "$TD/repo/docs/agents/issue-tracker.md"

# --- D-LIN-01. Two products on one team do not share a build ---------------
# The failure this reproduces: Linear team JOR carries two products, Triggers
# API and Demand Letter Generator, each with its own declared Project. Before
# this fix `_issues_page_query` (`issues-open`'s query) and `v_board` filtered
# on `team: { key: { eq: $team } }` alone — `_resolve_project` ran and set
# `_PROJECT_MODE`/`PROJECT_ID`, but neither read used them — so a repo that
# declared a Project still read the WHOLE team, including the other product's
# `Build N` issue and every one of its tickets. The fixture below puts two
# products' issues, each behind its own `Build N`, on one team, and asserts
# that reading one product's board never surfaces the other's.
printf '%s' '{"data":{"team":{"projects":{"nodes":[
 {"id":"proj-tapi","name":"Triggers API"},
 {"id":"proj-dlg","name":"Demand Letter Generator"}
]}}}}' > "$TD/dlin1-projects.json"
cat > "$TD/dlin1-issues.json" <<'JSON'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"id":"t1","number":301,"title":"Build 2","description":"","url":null,"updatedAt":null,
  "state":{"type":"unstarted","name":"Todo"},"labels":{"nodes":[]},"assignee":null,
  "project":{"id":"proj-tapi","name":"Triggers API"}},
 {"id":"t2","number":302,"title":"Fix the trigger","description":"","url":null,"updatedAt":null,
  "state":{"type":"started","name":"In Progress"},"labels":{"nodes":[{"name":"build-2"}]},
  "assignee":null,"project":{"id":"proj-tapi","name":"Triggers API"}},
 {"id":"t3","number":401,"title":"Build 3","description":"","url":null,"updatedAt":null,
  "state":{"type":"unstarted","name":"Todo"},"labels":{"nodes":[]},"assignee":null,
  "project":{"id":"proj-dlg","name":"Demand Letter Generator"}},
 {"id":"t4","number":402,"title":"Draft the letter template","description":"","url":null,"updatedAt":null,
  "state":{"type":"started","name":"In Progress"},"labels":{"nodes":[{"name":"build-3"}]},
  "assignee":null,"project":{"id":"proj-dlg","name":"Demand Letter Generator"}}
]}}}
JSON

# p-dlin01-1: with `Project: Triggers API` declared, issues-open sees only
# Triggers API's own two issues (301, 302) — never Demand Letter Generator's
# Build 3 or its member ticket. This is the exact leak the Failure section
# describes: reading 401 here would be resolving another product's Build as
# this repo's own.
printf '# Issue tracker: Linear\n\nTeam: ENG\nProject: Triggers API\n' > "$TD/repo/docs/agents/issue-tracker.md"
tapi_open=$(PROJECTS_JSON="$TD/dlin1-projects.json" ISSUES_JSON="$TD/dlin1-issues.json" L issues-open)
if [ "$(printf '%s' "$tapi_open" | jq -r '[.[].id] | sort | join(",")')" = "301,302" ]; then
    ok "D-LIN-01: a declared Project scopes issues-open to that product's own two issues, not the team's four"
else
    bad "D-LIN-01: issues-open leaked across products ($(printf '%s' "$tapi_open" | jq -c '[.[].id]'))"
fi
printf '%s' "$tapi_open" | jq -e '[.[].id] | index(401) == null and index(402) == null' >/dev/null 2>&1 \
    && ok "D-LIN-01: Demand Letter Generator's Build 3 (401) and its ticket (402) are absent — the cross-product build was not resolved" \
    || bad "D-LIN-01: the other product's Build issue or its ticket leaked into issues-open"
# The second consequence: `project` used to be the constant team key ($team),
# which made every issue's project equal every other's — snapshot.jq's
# cross-project blocker guard (`$proj != $home`) could never fire on Linear.
# It has to be the real, distinguishing project id now.
[ "$(printf '%s' "$tapi_open" | jq -r '[.[] | select(.id == 302)][0].project')" = "proj-tapi" ] \
    && ok "D-LIN-01: a mapped issue's project is the real Linear project id, not the constant team key — the cross-project guard can tell products apart" \
    || bad "D-LIN-01: project field was not the real project id ($(printf '%s' "$tapi_open" | jq -r '[.[] | select(.id == 302)][0].project'))"

# p-dlin01-2: the collision runs both ways — Demand Letter Generator's own
# read must likewise exclude Triggers API's Build 2 and its ticket. Testing
# only one direction would leave the "whichever was created last wins" half of
# the failure unverified.
printf '# Issue tracker: Linear\n\nTeam: ENG\nProject: Demand Letter Generator\n' > "$TD/repo/docs/agents/issue-tracker.md"
dlg_open=$(PROJECTS_JSON="$TD/dlin1-projects.json" ISSUES_JSON="$TD/dlin1-issues.json" L issues-open)
if [ "$(printf '%s' "$dlg_open" | jq -r '[.[].id] | sort | join(",")')" = "401,402" ]; then
    ok "D-LIN-01: Demand Letter Generator's own read is likewise scoped — Triggers API's Build 2 does not leak the other way"
else
    bad "D-LIN-01: the reverse direction leaked too ($(printf '%s' "$dlg_open" | jq -c '[.[].id]'))"
fi

# p-dlin01-3: back-compat — a repo with NO `Project:` line stays exactly
# team-wide, the one shape D-LIN-01's own suite note says the old tests could
# never have caught the bug in. This is that shape, proven directly: all four
# issues, both products, unfiltered.
printf '# Issue tracker: Linear\n\nTeam: ENG\n' > "$TD/repo/docs/agents/issue-tracker.md"
team_open=$(PROJECTS_JSON="$TD/dlin1-projects.json" ISSUES_JSON="$TD/dlin1-issues.json" L issues-open)
[ "$(printf '%s' "$team_open" | jq -r '[.[].id] | sort | join(",")')" = "301,302,401,402" ] \
    && ok "D-LIN-01: back-compat — no Project: line still reads the whole team, all four issues across both products" \
    || bad "D-LIN-01: the undeclared-Project back-compat path is no longer team-wide ($(printf '%s' "$team_open" | jq -c '[.[].id]'))"
# And in that shape `project` is still the team key, exactly as before this
# fix — there is no per-product id to carry when there is no declared product.
[ "$(printf '%s' "$team_open" | jq -r '[.[] | select(.id == 302)][0].project')" = ENG ] \
    && ok "D-LIN-01: back-compat — with project mode off, the project field is still the team key" \
    || bad "D-LIN-01: the back-compat project field changed with no Project: line"
printf '# Issue tracker: Linear\n\nTeam: ENG\n' > "$TD/repo/docs/agents/issue-tracker.md"

# --- p87-l7. The proof: a whole snapshot, then a plan ----------------------
# P86's stage-3 fixture driver emitted the loom document directly, which proved
# the readers. This proves the DRIVER: a real Linear payload, mapped by
# linear.sh, drives the same snapshot and the same planner. GitLab is not
# involved at any point.
cat > "$TD/forge" <<'EOF'
#!/usr/bin/env bash
case "$1" in ticket-marker) echo "Loom-Ticket: ${2:-0}" ;; *) echo '[]' ;; esac
EOF
chmod +x "$TD/forge"
printf '%s' '{"data":{"team":{"projects":{"nodes":[{"id":"p1","name":"Ledger","state":"started","description":"## Acceptance criteria\n\n- [ ] it balances\n"}]}}}}' > "$TD/proj.json"
PROJECTS_JSON="$TD/proj.json" \
  env $(API_ENV | tr '\n' ' ') PROJECTS_JSON="$TD/proj.json" FORGE_CMD="$TD/forge" \
  LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
  "$TICK" snapshot > "$TD/snap.json" 2>"$TD/snap.err"; rc=$?
if [ "$rc" = 0 ] \
   && [ "$(jq -r '.build.label' "$TD/snap.json" 2>/dev/null)" = "build-7" ] \
   && [ "$(jq -r '[.tickets[] | select(.id == 2)] | .[0].tier' "$TD/snap.json" 2>/dev/null)" = "logic" ] \
   && [ "$(jq -r '[.tickets[] | select(.id == 2)] | .[0].epic' "$TD/snap.json" 2>/dev/null)" = "Ledger" ]; then
    ok "end to end: a Linear board builds the whole snapshot — build, tickets, tiers and epics"
else
    bad "end to end: the Linear snapshot failed (rc=$rc, $(head -1 "$TD/snap.err"))"
fi
[ "$(jq -r '.epics[0].accepted' "$TD/snap.json" 2>/dev/null)" = "false" ] \
    && ok "end to end: a Linear Project carries the epic acceptance record a milestone used to" \
    || bad "end to end: the epic rollup did not read the Linear project ($(jq -c '.epics' "$TD/snap.json" 2>/dev/null))"
if jq -e '.actions | type == "array"' \
     <(LOOM_REPO="$TD/repo" LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
       "$TICK" plan "$TD/snap.json" 2>/dev/null) >/dev/null 2>&1; then
    ok "end to end: and the planner reads it — the contract carries a second tracker all the way through"
else
    bad "end to end: plan could not read a snapshot built from Linear"
fi

test_finish
