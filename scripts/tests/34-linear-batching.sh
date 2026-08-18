#!/usr/bin/env bash
# P77 / rate limits: the Linear driver spends complexity to save requests
#
# Section 34 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
#
# Linear meters two budgets per hour and they are three orders of magnitude
# apart: 2,500 REQUESTS against 3,000,000 COMPLEXITY points. Every test here
# counts REQUESTS, because that is the one that runs out. Two mechanisms are
# under test:
#
#   1. `_issue_ref` — the identifier is built from the number, so a per-ticket
#      read or mutation costs one request where it used to cost two (the first
#      spent translating the number into a UUID).
#   2. `board` — the whole build's edges and comment threads arrive nested in
#      the list query, so a snapshot costs a handful of requests rather than
#      two per ticket.
#
# The number a test asserts is a REQUEST COUNT, and every one of them is shown
# failing when its mechanism is removed — a saving nobody has watched disappear
# is not a saving.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

SD="$(cd "$(dirname "$TICK")" && pwd)"
LIN="$SD/trackers/linear.sh"
TD="$T/p77lin"; mkdir -p "$TD"

# The canned API again, with one addition the other sections do not need: every
# request appends a line to REQ_LOG, so a test can count them. Counting is the
# whole point of this section — an assertion about output shape would pass just
# as well against the wasteful driver.
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
# One line per REQUEST, tagged by what it asked for.
tag=other
case "$q" in
  *"teams(first: 50)"*)  tag=teams ;;
  *"comments(last: 30)"*) tag=board ;;   # the batched read, matched first
  *"issues(first: 1,"*)  tag=uuid-lookup ;;
  *"issues(first: 250"*) tag=issues ;;
  *"comments(first:"*)   tag=notes ;;
  *"inverseRelations"*)  tag=links ;;
  *"states(first: 50)"*) tag=states ;;
  *"projects(first: 250)"*) tag=projects ;;
  *"labels(first: 250)"*)   tag=labels ;;
  *issueUpdate*|*commentCreate*) tag=mutation ;;
esac
printf '%s\n' "$tag" >> "${REQ_LOG:-/dev/null}"
say()  { printf '%s' "$1" > "$out"; echo 200; }
file() { cat "$1" > "$out"; echo 200; }
case "$q" in
  *"teams(first: 50)"*) file "${TEAMS_JSON:?}" ;;
  # The batched board read. Matched BEFORE the flat issue list, because it is
  # also an `issues(...)` query — the nested comment connection is what tells
  # them apart, exactly as the real API would see two different queries.
  *"comments(last: 30)"*) file "${BOARD_JSON:?}" ;;
  *"issues(first: 250"*)
      case "$q" in
        *'nin: ["completed", "canceled", "duplicate"]'*)
            jq -c '.data.issues.nodes |= map(select(.state.type != "completed" and .state.type != "canceled" and .state.type != "duplicate"))' "${ISSUES_JSON:?}" > "$out" ;;
        *)  cat "${ISSUES_JSON:?}" > "$out" ;;
      esac
      echo 200 ;;
  *"issues(first: 1,"*)
      n=$(jq -r '.variables.n' "$data")
      say "$(jq -c --argjson n "$n" '{data:{issues:{nodes:[ .data.issues.nodes[] | select(.number == $n) ]}}}' "${ISSUES_JSON:?}")" ;;
  # The per-ticket answers are CUT FROM THE SAME FIXTURE the batched read
  # serves, keyed on the identifier the driver now sends (ENG-3 → 3). Two
  # hand-written fixtures would let the two paths differ for a reason that is
  # nobody's bug, which is exactly what the first draft of this section did:
  # a shared relations file answered every ticket with the same edge and gave
  # #2 a blocking edge to itself.
  *"comments(first:"*)
      n=$(jq -r '.variables.id' "$data"); n=${n##*-}
      jq -c --argjson n "$n" '{data:{issue:{comments:
        ([.data.issues.nodes[] | select(.number == $n)][0].comments // {nodes:[]})}}}' \
        "${BOARD_JSON:?}" > "$out"; echo 200 ;;
  *"inverseRelations"*)
      n=$(jq -r '.variables.id' "$data"); n=${n##*-}
      jq -c --argjson n "$n" '{data:{issue:{
        relations:        ([.data.issues.nodes[] | select(.number == $n)][0].relations // {nodes:[]}),
        inverseRelations: ([.data.issues.nodes[] | select(.number == $n)][0].inverseRelations // {nodes:[]})}}}' \
        "${BOARD_JSON:?}" > "$out"; echo 200 ;;
  *"states(first: 50)"*)    file "${STATES_JSON:?}" ;;
  *"projects(first: 250)"*) file "${PROJECTS_JSON:?}" ;;
  *"labels(first: 250)"*)   file "${LABELS_JSON:?}" ;;
  # `issue-relabel` reads the ticket's CURRENT labels before writing the set
  # back, because Linear has no add/remove. Answering from the same fixture
  # keeps that read honest.
  *"labels { nodes { id name } }"*)
      n=$(jq -r '.variables.id' "$data"); n=${n##*-}
      jq -c --argjson n "$n" '{data:{issue:{labels:
        {nodes: [ [.data.issues.nodes[] | select(.number == $n)][0].labels.nodes[]
                  | {id: ("l-" + .name), name: .name} ]}}}}' \
        "${BOARD_JSON:?}" > "$out"; echo 200 ;;
  *viewer*) say '{"data":{"viewer":{"id":"user-uuid","name":"loom","displayName":"Loom Bot"}}}' ;;
  *issueUpdate*|*commentCreate*)
      jq -c '.variables' "$data" >> "${MUT_LOG:-/dev/null}"
      say '{"data":{"issueUpdate":{"success":true},"commentCreate":{"success":true}}}' ;;
  *)  printf '{"errors":[{"message":"unrecognised query"}]}' > "$out"; echo 200 ;;
esac
STUB
chmod +x "$TD/api"

# One Build issue and two tickets, both members of build-7. Ticket 3 is blocked
# by ticket 2, so there is a real edge to lose.
cat > "$TD/issues.json" <<'JSON'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"id":"u1","number":1,"title":"Build 7","description":"**Selected epics**\n- Ledger (#2)\n",
  "url":"https://linear.app/acme/issue/ENG-1","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"started","name":"In Progress"},"labels":{"nodes":[]},"assignee":null,"project":null},
 {"id":"u2","number":2,"title":"Add the ledger","description":"## Risk tier\n\nlogic\n",
  "url":"https://linear.app/acme/issue/ENG-2","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"unstarted","name":"Todo"},"labels":{"nodes":[{"name":"build-7"}]},
  "assignee":null,"project":{"name":"Ledger"}},
 {"id":"u3","number":3,"title":"Wire the ledger up","description":"## Risk tier\n\napi\n",
  "url":"https://linear.app/acme/issue/ENG-3","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"started","name":"In Progress"},"labels":{"nodes":[{"name":"build-7"}]},
  "assignee":{"name":"jo","displayName":"Jo"},"project":{"name":"Ledger"}}
]}}}
JSON

# The SAME two tickets as the batched read returns them: the issue fields plus
# the two nested connections. Ticket 3 carries the blocking edge and a comment;
# ticket 2 carries neither. If the batched path and the per-ticket path ever
# disagree, these fixtures are where it shows.
cat > "$TD/board.json" <<'JSON'
{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"id":"u2","number":2,"title":"Add the ledger","description":"## Risk tier\n\nlogic\n",
  "url":"https://linear.app/acme/issue/ENG-2","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"unstarted","name":"Todo"},"labels":{"nodes":[{"name":"build-7"}]},
  "assignee":null,"project":{"name":"Ledger"},"projectMilestone":null,
  "relations":{"nodes":[]},"inverseRelations":{"nodes":[]},"comments":{"nodes":[]}},
 {"id":"u3","number":3,"title":"Wire the ledger up","description":"## Risk tier\n\napi\n",
  "url":"https://linear.app/acme/issue/ENG-3","updatedAt":"2026-08-10T00:00:00Z",
  "state":{"type":"started","name":"In Progress"},"labels":{"nodes":[{"name":"build-7"}]},
  "assignee":{"name":"jo","displayName":"Jo"},"project":{"name":"Ledger"},"projectMilestone":null,
  "relations":{"nodes":[]},
  "inverseRelations":{"nodes":[{"type":"blocks","issue":{"number":2,"state":{"type":"unstarted"}}}]},
  "comments":{"nodes":[{"body":"gate FAIL","createdAt":"2026-08-10T01:00:00Z",
                        "user":{"name":"jo","displayName":"Jo"}}]}}
]}}}
JSON

mkdir -p "$TD/repo/docs/agents"
git -C "$TD/repo" init -q >/dev/null 2>&1
git -C "$TD/repo" remote add origin https://github.com/acme/app.git >/dev/null 2>&1
printf '# Issue tracker: Linear\n\nTeam: ENG\n' > "$TD/repo/docs/agents/issue-tracker.md"
git -C "$TD/repo" add -A >/dev/null 2>&1

printf '{"data":{"teams":{"nodes":[{"id":"team-uuid","key":"ENG","name":"Engineering"}]}}}' > "$TD/teams.json"
printf '{"data":{"team":{"projects":{"nodes":[]}}}}' > "$TD/projects.json"
printf '{"data":{"team":{"labels":{"nodes":[{"id":"l-b7","name":"build-7"}]}}}}' > "$TD/labels.json"
printf '{"data":{"team":{"states":{"nodes":[
  {"id":"st-todo","name":"Todo","type":"unstarted","position":1},
  {"id":"st-doing","name":"In Progress","type":"started","position":2},
  {"id":"st-review","name":"In Review","type":"started","position":3},
  {"id":"st-merge","name":"Merge Queue","type":"started","position":4},
  {"id":"st-blocked","name":"Blocked","type":"started","position":5},
  {"id":"st-done","name":"Done","type":"completed","position":6}
]}}}}' > "$TD/states.json"

API_ENV() {
    printf '%s\n' "LINEAR_API_KEY=k" "CURL_CMD=$TD/api" "ISSUES_JSON=$TD/issues.json" \
        "BOARD_JSON=$TD/board.json" "TEAMS_JSON=$TD/teams.json" "PROJECTS_JSON=$TD/projects.json" \
        "LABELS_JSON=$TD/labels.json" "STATES_JSON=$TD/states.json" "LOOM_REPO=$TD/repo"
}
# Requests of one kind, in the log a run just wrote.
count() { grep -c "^$1\$" "$TD/req.log" 2>/dev/null | head -1 || true; }
fresh() { : > "$TD/req.log"; }

# --- p77-1. The UUID lookup is gone ---------------------------------------
# Two verbs, each of which used to spend its first request translating a ticket
# NUMBER into the UUID Linear's mutations were assumed to require. Linear
# resolves the human identifier everywhere, so that request should not exist.

fresh
env $(API_ENV | tr '\n' ' ') REQ_LOG="$TD/req.log" "$LIN" issue-links 3 > "$TD/links.json" 2>/dev/null
[ "$(count uuid-lookup)" = 0 ] \
    && ok "issue-links makes no number-to-UUID lookup — the identifier is built, not fetched" \
    || bad "issue-links still spends $(count uuid-lookup) request(s) resolving a UUID"
[ "$(count links)" = 1 ] \
    && ok "issue-links: and exactly one request for the edges themselves" \
    || bad "issue-links made $(count links) edge requests, expected 1"

fresh
env $(API_ENV | tr '\n' ' ') REQ_LOG="$TD/req.log" "$LIN" issue-notes 3 --limit 30 > "$TD/notes.json" 2>/dev/null
[ "$(count uuid-lookup)" = 0 ] && [ "$(count notes)" = 1 ] \
    && ok "issue-notes likewise: one request, not two" \
    || bad "issue-notes spent $(count uuid-lookup) lookups and $(count notes) note requests"

# The identifier actually sent is the team key and the number — the thing
# Linear resolves. A driver that sent the bare number would pass the counts
# above and fail against the real API.
env $(API_ENV | tr '\n' ' ') REQ_LOG=/dev/null "$LIN" issue-links 3 >/dev/null 2>&1
fresh
if env $(API_ENV | tr '\n' ' ') MUT_LOG="$TD/mut.log" REQ_LOG="$TD/req.log" \
     "$LIN" issue-relabel 3 --add build-7 >/dev/null 2>&1
   grep -q '"id":"ENG-3"' "$TD/mut.log" 2>/dev/null; then
    ok "a mutation addresses the issue as 'ENG-3' — the identifier, not a UUID and not a bare number"
else
    bad "the mutation did not carry the ENG-3 identifier ($(head -1 "$TD/mut.log" 2>/dev/null))"
fi
[ "$(count uuid-lookup)" = 0 ] \
    && ok "and it spent no lookup request to get there" \
    || bad "issue-relabel still made $(count uuid-lookup) UUID lookup(s)"

# THE VIOLATION. A driver copy that resolves the UUID first — the shape this
# change removed — makes the extra request, and the count above catches it.
#
# The copy needs its own MIRROR of the scripts directory: linear.sh finds
# lib.sh and http.sh relative to its own path, so a copy dropped anywhere else
# dies before it can make a single request — which would have shown up as
# "no extra request" and quietly passed for the wrong reason.
mkdir -p "$TD/drv/trackers"
cp "$SD/lib.sh" "$TD/drv/lib.sh"
cp "$SD/trackers/http.sh" "$TD/drv/trackers/http.sh"
python3 - "$LIN" "$TD/drv/trackers/lin-old.sh" <<'PLANT'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
anchor = '\ncase "${1:-}" in\n'
assert anchor in s, "the verb dispatch anchor moved — this plant needs updating"
override = '\n_issue_ref() { _issue_node "$1" | jq -r \'.id // empty\'; }\n'
open(dst, 'w').write(s.replace(anchor, override + anchor, 1))
PLANT
chmod +x "$TD/drv/trackers/lin-old.sh"
grep -q '_issue_ref() { _issue_node' "$TD/drv/trackers/lin-old.sh" \
    || bad "violation: the override was not injected — the anchor in linear.sh moved"
fresh
env $(API_ENV | tr '\n' ' ') REQ_LOG="$TD/req.log" \
    "$TD/drv/trackers/lin-old.sh" issue-links 3 >/dev/null 2>"$TD/plant.err"
[ "$(count uuid-lookup)" -ge 1 ] \
    && ok "violation: a UUID-resolving driver spends the extra request, so the count is measuring the mechanism" \
    || bad "violation: the planted UUID lookup made no extra request ($(head -1 "$TD/plant.err" 2>/dev/null))"

# --- p77-2. `board` — one read for the whole build -------------------------

fresh
env $(API_ENV | tr '\n' ' ') REQ_LOG="$TD/req.log" "$LIN" board --label build-7 > "$TD/board.out" 2>"$TD/board.err"
rc=$?
[ "$rc" = 0 ] && [ "$(jq 'length' "$TD/board.out" 2>/dev/null)" = 2 ] \
    && ok "board returns the build's two members" \
    || bad "board failed (rc=$rc, $(head -1 "$TD/board.err"))"
[ "$(count board)" = 1 ] && [ "$(count links)" = 0 ] && [ "$(count notes)" = 0 ] \
    && ok "board: one request for the whole build — no per-ticket edge or comment call at all" \
    || bad "board made $(count board) board, $(count links) link and $(count notes) note requests"

# The batched answer must be the SAME answer. Not similar: the same, field for
# field, against the per-ticket verbs it replaces.
a=$(jq -Sc 'sort_by(.id,.type)' "$TD/links.json" 2>/dev/null)
b=$(jq -Sc '[.[] | select(.id == 3)][0].links | sort_by(.id,.type)' "$TD/board.out" 2>/dev/null)
[ -n "$a" ] && [ "$a" = "$b" ] \
    && ok "board's edges for #3 are identical to what issue-links returns" \
    || bad "board's edges differ from issue-links — per-ticket: $a, board: $b"
a=$(jq -Sc '.' "$TD/notes.json" 2>/dev/null)
b=$(jq -Sc '[.[] | select(.id == 3)][0].notes' "$TD/board.out" 2>/dev/null)
[ -n "$a" ] && [ "$a" = "$b" ] \
    && ok "board's comment thread for #3 is identical to what issue-notes returns" \
    || bad "board's notes differ from issue-notes — per-ticket: $a, board: $b"

# A ticket state is a Status here (P90), never a label, so filtering the board
# by one would quietly return nothing. Refusing is the only safe answer.
out=$(env $(API_ENV | tr '\n' ' ') REQ_LOG=/dev/null "$LIN" board --label review 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -qi "ticket state" \
    && ok "board refuses a ticket state as its label, rather than answering emptily" \
    || bad "board accepted a Status name as a label (rc=$rc)"

# --- p77-3. The snapshot takes the fast path, and survives losing it --------
# The property that matters is not that the fast path exists — it is that the
# OLD path is still there underneath it. A tracker without `board` must produce
# the same snapshot, because that is every GitLab repo.

cat > "$TD/forge" <<'EOF'
#!/usr/bin/env bash
case "$1" in ticket-marker) echo "Loom-Ticket: ${2:-0}" ;; *) echo '[]' ;; esac
EOF
chmod +x "$TD/forge"

fresh
env $(API_ENV | tr '\n' ' ') REQ_LOG="$TD/req.log" FORGE_CMD="$TD/forge" \
    LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
    "$TICK" snapshot > "$TD/snap-fast.json" 2>"$TD/snap-fast.err"; rc=$?
[ "$rc" = 0 ] \
    && ok "snapshot builds on the batched path" \
    || bad "batched snapshot failed (rc=$rc, $(head -1 "$TD/snap-fast.err"))"
# One note request survives and should: the `Build N` issue carries the build's
# lessons thread and is NOT a member of its own build, so no batched member read
# can contain it. Every per-MEMBER call is gone.
[ "$(count links)" = 0 ] && [ "$(count notes)" = 1 ] && [ "$(count board)" -ge 1 ] \
    && ok "snapshot: no per-member edge or comment call at all — one board read replaced the fan-out" \
    || bad "snapshot still fanned out: $(count links) link and $(count notes) note requests"

# A partial foundational page and a complete batched page must never become a
# valid plan. The two reads are independently paginated, so either can lose a
# page while still returning syntactically valid, non-empty JSON.
jq '.data.issues.nodes |= map(select(.number != 3))' "$TD/issues.json" > "$TD/issues-partial.json"
rm -f "$TD/partial-plan.json"
fresh
env $(API_ENV | tr '\n' ' ') ISSUES_JSON="$TD/issues-partial.json" REQ_LOG="$TD/req.log" \
    FORGE_CMD="$TD/forge" LOOM_HOME="$TD/home-partial" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
    "$TICK" snapshot > "$TD/snap-partial.json" 2> "$TD/snap-partial.err"; rc=$?
if [ "$rc" != 0 ] \
   && grep -q "foundational and batched ticket populations disagree" "$TD/snap-partial.err"; then
    ok "snapshot refuses a partial foundational/batched population before planning"
else
    "$TICK" plan "$TD/snap-partial.json" > "$TD/partial-plan.json" 2>/dev/null || true
    bad "partial ticket population reached planning (snapshot rc=$rc, tickets=$(jq -c '[.tickets[].id]' "$TD/snap-partial.json" 2>/dev/null), actions=$(jq -c '.actions' "$TD/partial-plan.json" 2>/dev/null))"
fi

jq '.data.issues.nodes |= map(select(.number == 1))' "$TD/issues.json" > "$TD/issues-build-only.json"
env $(API_ENV | tr '\n' ' ') ISSUES_JSON="$TD/issues-build-only.json" REQ_LOG=/dev/null \
    FORGE_CMD="$TD/forge" LOOM_HOME="$TD/home-foundational-empty" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
    "$TICK" snapshot > "$TD/snap-foundational-empty.json" \
    2> "$TD/snap-foundational-empty.err"; rc=$?
[ "$rc" != 0 ] \
   && grep -q "foundational and batched ticket populations disagree" "$TD/snap-foundational-empty.err" \
    && ok "snapshot compares the batch when the foundational member set is empty" \
    || bad "empty foundational member set skipped population agreement (rc=$rc)"

jq '.data.issues.nodes = []' "$TD/board.json" > "$TD/board-empty.json"
env $(API_ENV | tr '\n' ' ') BOARD_JSON="$TD/board-empty.json" REQ_LOG=/dev/null \
    FORGE_CMD="$TD/forge" LOOM_HOME="$TD/home-batch-empty" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
    "$TICK" snapshot > "$TD/snap-batch-empty.json" 2> "$TD/snap-batch-empty.err"; rc=$?
[ "$rc" != 0 ] \
   && grep -q "foundational and batched ticket populations disagree" "$TD/snap-batch-empty.err" \
    && ok "snapshot compares a successful empty batch with foundational members" \
    || bad "successful empty batch fell back around population agreement (rc=$rc)"

cat > "$TD/lin-board-fail.sh" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = board ] && { echo "linear board query failed" >&2; exit 1; }
exec "$LIN" "\$@"
EOF
chmod +x "$TD/lin-board-fail.sh"
env $(API_ENV | tr '\n' ' ') TRACKER_CMD="$TD/lin-board-fail.sh" REQ_LOG=/dev/null \
    FORGE_CMD="$TD/forge" LOOM_HOME="$TD/home-batch-fail" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
    "$TICK" snapshot > "$TD/snap-batch-fail.json" 2> "$TD/snap-batch-fail.err"; rc=$?
[ "$rc" != 0 ] && grep -q "batched board read failed" "$TD/snap-batch-fail.err" \
    && ok "snapshot refuses a supported driver's failed batch read" \
    || bad "failed supported batch read fell back to the foundational population (rc=$rc)"

cat > "$TD/lin-board-malformed.sh" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = board ] && { echo '{"partial":true}'; exit 0; }
exec "$LIN" "\$@"
EOF
chmod +x "$TD/lin-board-malformed.sh"
env $(API_ENV | tr '\n' ' ') TRACKER_CMD="$TD/lin-board-malformed.sh" REQ_LOG=/dev/null \
    FORGE_CMD="$TD/forge" LOOM_HOME="$TD/home-batch-malformed" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
    "$TICK" snapshot > "$TD/snap-batch-malformed.json" \
    2> "$TD/snap-batch-malformed.err"; rc=$?
[ "$rc" != 0 ] && grep -q "batched board read was not a JSON array" "$TD/snap-batch-malformed.err" \
    && ok "snapshot refuses a supported driver's malformed batch read" \
    || bad "malformed supported batch read fell back to the foundational population (rc=$rc)"

# A driver with no `board` verb — which is GitLab, and any tracker added later.
cat > "$TD/lin-noboard.sh" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = board ] && { echo "no such verb: board" >&2; exit 2; }
exec "$LIN" "\$@"
EOF
chmod +x "$TD/lin-noboard.sh"
fresh
env $(API_ENV | tr '\n' ' ') REQ_LOG="$TD/req.log" TRACKER_CMD="$TD/lin-noboard.sh" \
    FORGE_CMD="$TD/forge" LOOM_HOME="$TD/home2" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
    "$TICK" snapshot > "$TD/snap-slow.json" 2>"$TD/snap-slow.err"; rc=$?
[ "$rc" = 0 ] \
    && ok "fallback: a tracker with no board verb still builds a snapshot" \
    || bad "fallback snapshot failed (rc=$rc, $(head -1 "$TD/snap-slow.err"))"
[ "$(count links)" -ge 1 ] \
    && ok "fallback: and it did fan out — the old path is still there, not merely unused" \
    || bad "fallback made no per-ticket link call, so the fan-out is gone rather than bypassed"

# The two paths must agree. This is the assertion the whole change rests on:
# every ticket, every field, including the edges and the threads.
a=$(jq -S '.tickets' "$TD/snap-fast.json" 2>/dev/null)
b=$(jq -S '.tickets' "$TD/snap-slow.json" 2>/dev/null)
[ -n "$a" ] && [ "$a" = "$b" ] \
    && ok "batched and fanned-out snapshots are identical, ticket for ticket and field for field" \
    || bad "the two snapshot paths disagree: $(diff <(printf '%s' "$a") <(printf '%s' "$b") | head -6)"

test_finish
