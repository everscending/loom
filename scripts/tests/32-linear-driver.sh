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
        *'nin: ["completed", "canceled"]'*)
            jq -c '.data.issues.nodes |= map(select(.state.type != "completed" and .state.type != "canceled"))' "${ISSUES_JSON:?}" > "$out" ;;
        *'in: ["completed", "canceled"]'*)
            jq -c '.data.issues.nodes |= map(select(.state.type == "completed" or .state.type == "canceled"))' "${ISSUES_JSON:?}" > "$out" ;;
        *)  cat "${ISSUES_JSON:?}" > "$out" ;;
      esac
      echo 200 ;;
  *"issues(first: 1,"*)
      n=$(jq -r '.variables.n' "$data")
      say "$(jq -c --argjson n "$n" '{data:{issues:{nodes:[ .data.issues.nodes[] | select(.number == $n) ]}}}' "${ISSUES_JSON:?}")" ;;
  *"comments(first:"*)       file "${COMMENTS_JSON:?}" ;;
  *"inverseRelations"*)      file "${RELATIONS_JSON:?}" ;;
  *"labels { nodes { id name } }"*) file "${CURLABELS_JSON:?}" ;;
  *"projects(first: 250)"*)  file "${PROJECTS_JSON:?}" ;;
  *"labels(first: 250)"*)    file "${LABELS_JSON:?}" ;;
  *"states(first: 50)"*)
      say '{"data":{"team":{"states":{"nodes":[{"id":"st-done","type":"completed","position":1}]}}}}' ;;
  *viewer*)
      say '{"data":{"viewer":{"id":"user-uuid","name":"loom","displayName":"Loom Bot"}}}' ;;
  *issueUpdate*|*issueCreate*|*commentCreate*|*issueLabelCreate*|*projectUpdate*)
      jq -c '.variables' "$data" >> "${MUT_LOG:-/dev/null}"
      say '{"data":{"issueCreate":{"success":true,"issue":{"number":99}},"issueUpdate":{"success":true},"commentCreate":{"success":true},"issueLabelCreate":{"success":true},"projectUpdate":{"success":true}}}' ;;
  *)  printf '{"errors":[{"message":"unrecognised query"}]}' > "$out"; echo 200 ;;
esac
STUB
chmod +x "$TD/api"

# The board. One Build issue and three tickets, chosen to exercise the three
# places Linear does not look like GitLab: a canceled ticket (a state type with
# no GitLab equivalent), an unassigned one, and one with an assignee.
cat > "$TD/issues.json" <<'JSON'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"id":"u1","number":1,"title":"Build 7","description":"**Selected epics**\n- Ledger (#2)\n",
  "url":"https://linear.app/acme/issue/ENG-1","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"started"},"labels":{"nodes":[]},"assignee":null,"project":null},
 {"id":"u2","number":2,"title":"Add the ledger","description":"## Risk tier\n\nlogic\n\n## Blocked by\n\nNone - can start immediately\n",
  "url":"https://linear.app/acme/issue/ENG-2","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"unstarted"},"labels":{"nodes":[{"name":"build-7"},{"name":"ready-for-agent"}]},
  "assignee":null,"project":{"name":"Ledger"}},
 {"id":"u3","number":3,"title":"Wire the ledger up","description":"## Risk tier\n\napi\n",
  "url":"https://linear.app/acme/issue/ENG-3","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"started"},"labels":{"nodes":[{"name":"build-7"},{"name":"in-progress"}]},
  "assignee":{"name":"jo","displayName":"Jo"},"project":{"name":"Ledger"}},
 {"id":"u4","number":4,"title":"Dropped idea","description":"nope\n",
  "url":"https://linear.app/acme/issue/ENG-4","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"canceled"},"labels":{"nodes":[{"name":"build-7"}]},
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

API_ENV() { # the canned API, with every fixture defaulted
    printf '%s\n' "LINEAR_API_KEY=k" "CURL_CMD=$TD/api" "ISSUES_JSON=$TD/issues.json" \
        "TEAMS_JSON=${TEAMS_JSON:-$TD/teams.json}" "COMMENTS_JSON=${COMMENTS_JSON:-$TD/comments.json}" \
        "RELATIONS_JSON=${RELATIONS_JSON:-$TD/relations.json}" "CURLABELS_JSON=${CURLABELS_JSON:-$TD/curlabels.json}" \
        "PROJECTS_JSON=${PROJECTS_JSON:-$TD/projects.json}" "LABELS_JSON=${LABELS_JSON:-$TD/labels.json}" \
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
# every label the ticket has, which on this board is its entire state machine.
printf '%s' '{"data":{"team":{"labels":{"nodes":[{"id":"l1","name":"build-7"},{"id":"l2","name":"ready-for-agent"},{"id":"l3","name":"in-progress"}]}}}}' > "$TD/lbl.json"
printf '%s' '{"data":{"issue":{"labels":{"nodes":[{"id":"l1","name":"build-7"},{"id":"l2","name":"ready-for-agent"}]}}}}' > "$TD/curlbl.json"
: > "$TD/mut.log"
MUT_LOG="$TD/mut.log" LABELS_JSON="$TD/lbl.json" CURLABELS_JSON="$TD/curlbl.json" \
  L issue-relabel 2 --add in-progress --remove ready-for-agent >/dev/null 2>&1 || true
if grep -q '"l1"' "$TD/mut.log" && grep -q '"l3"' "$TD/mut.log" && ! grep -q '"l2"' "$TD/mut.log"; then
    ok "relabel: the whole label set is rewritten — the ticket keeps build-7, gains in-progress, loses ready-for-agent"
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
