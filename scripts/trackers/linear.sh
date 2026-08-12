#!/usr/bin/env bash
# The Linear BOARD driver (P87 stage 3).
#
# The second implementation of the contract P86 wrote, and therefore the first
# evidence that it IS a contract rather than a description of GitLab. Everything
# below is the board half only: Linear has no merge requests, so a Linear repo's
# forge is resolved separately from its git remote (see `_require_forge` in
# lib.sh). If an `mr-` verb ever appears in this file, that split has failed.
#
# THREE THINGS LINEAR DOES DIFFERENTLY, and how each is answered:
#
#   1. NO CLI. Linear is GraphQL over HTTPS and nothing else, so this drives
#      `curl` through trackers/http.sh — which exists to keep the API key out of
#      argv, to fail non-zero and silently, and to notice that a GraphQL error
#      arrives with HTTP 200.
#
#   2. TWO IDENTIFIERS, AND LOOM WANTS NEITHER. A Linear issue carries a UUID
#      and a human identifier like `ENG-123`. The contract's `id` is an INTEGER,
#      because the jq layer does arithmetic on ticket ids — `graph.jq` converts
#      them, `snapshot.jq` scans `#([0-9]+)` out of a ticket's `## Blocked by`
#      list, `plan.jq` parses a lane name back to a ticket number — and an
#      opaque string id would be a rewrite of all of it. `Issue.number` is an
#      integer, sequential within a team, which is structurally the same thing
#      GitLab's `iid` is within a project. So the contract needs no change and
#      this file holds the UUID privately, resolving number → UUID for the
#      writes Linear's mutations require.
#
#   3. STATES, NOT OPEN AND CLOSED. A Linear issue is in a workflow state whose
#      TYPE is one of backlog, unstarted, started, completed, canceled,
#      duplicate. The contract's `state` is open or closed, so completed,
#      canceled and duplicate all map to closed — dropping any of them instead
#      would leave a ticket that will never move sitting in the scheduler's
#      universe forever.
#
# LOOM'S OWN STATE MACHINE LIVES HERE TOO (P90). `ready-for-agent`,
# `in-progress`, `review`, `merge-queue` and `blocked` used to be written as
# Linear LABELS, because that is what the GitLab driver this file was written
# against does. Linear's board is its Status field, not its labels — every
# view a human has built (columns, cycle progress, "active issues") reads
# Status, and none of it ever saw the label. So a loom state name in
# `issue-relabel --add` becomes a `stateId` mutation instead, and `_MAP_ISSUE`
# synthesises the matching state name back INTO `labels` on the way out, so
# every reader above this file — `state_of` in snapshot.jq included — keeps
# working unchanged. The five names still map to a fixed default Status
# (`Todo`, `In Progress`, `In Review`, `Merge Queue`, `Blocked`), overridable
# per repo with a `Status <loom-state>: <Linear name>` line beside `Team:` in
# the same declaration file. `fix`, `tier::*` and `model::*` stay real labels:
# they are not states, and Linear has one Status per issue.
#
# THE TEAM. Linear issues belong to a Team and no git remote names it. Read from
# a `Team: <key>` line in the same declaration file the tracker's name comes
# from; failing that, from the API key itself when it can see exactly one team.
# Several teams and no line is a HALT naming them — a board driver that picked
# one would be filing a build's tickets somewhere nobody asked for.
#
# THE PROJECT (P92). SKILL.md's model is "epic = one milestone per epic".
# `epic` used to always read a Linear PROJECT — the natural fit for a board
# with several products, one project each — but a board whose whole product
# is ONE Linear project keeps its epics as ProjectMilestones INSIDE it, and
# closing an epic there must never complete the whole product. A `Project:
# <name or id>` line beside `Team:` opts a repo into that shape: `epic` reads
# a ProjectMilestone, `issue-create --milestone-id` takes one, and
# `milestone-close` records acceptance in the milestone's own description
# rather than trying to complete a project that isn't the epic. No `Project:`
# line keeps every one of those exactly as it was.
#
# RATE LIMITS. A personal API key is capped per hour, which turns P77's snapshot
# fan-out from a wall-clock problem into a hard stop on a board of any size:
# roughly 250 calls per snapshot at 100 tickets, twice a wave. `issues-open`
# below fetches labels, project and body in the SAME query rather than per
# ticket, which is as far as the per-verb contract lets this file go. The rest
# is P77's to fix.
set -euo pipefail

LIB_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
[ -f "$LIB_SH" ] \
    || { echo "linear.sh: $LIB_SH is missing — it holds the shared derivations" >&2; exit 1; }
. "$LIB_SH"
DIE_RC=1
HTTP_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/http.sh"
[ -f "$HTTP_SH" ] || die "$HTTP_SH is missing — it holds the shared HTTP transport"
. "$HTTP_SH"

GRAPHQL_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}"

need_id() { case "${1:-}" in ''|*[!0-9]*) die "$2: needs a numeric id, got '${1:-}'" ;; esac; }

# --- the team -------------------------------------------------------------

TEAM_KEY=""; TEAM_ID=""
_resolve_team() {
    [ -z "$TEAM_ID" ] || return 0
    local want teams n
    want=$(_tracker_decl_field "${LOOM_REPO:-.}" Team)
    teams=$(_graphql 'query { teams(first: 50) { nodes { id key name } } }') \
        || die "linear.sh: could not list the teams this API key can see"
    if [ -n "$want" ]; then
        TEAM_ID=$(printf '%s' "$teams" | jq -r --arg k "$want" \
            '[.teams.nodes[] | select((.key | ascii_downcase) == ($k | ascii_downcase))][0].id // empty')
        [ -n "$TEAM_ID" ] \
            || die "linear.sh: '$(_tracker_decl_path)' declares 'Team: $want', and this API key
  sees no Linear team with that key. It can see: $(printf '%s' "$teams" | jq -r '[.teams.nodes[].key] | join(", ")')."
        TEAM_KEY="$want"
        return 0
    fi
    n=$(printf '%s' "$teams" | jq '.teams.nodes | length')
    [ "$n" = 1 ] \
        || die "linear.sh: this API key sees $n Linear teams ($(printf '%s' "$teams" | jq -r '[.teams.nodes[].key] | join(", ")')),
  and '$(_tracker_decl_path)' does not say which one holds this repo's tickets.
  Add a line to it:  Team: <KEY>"
    TEAM_ID=$(printf '%s' "$teams" | jq -r '.teams.nodes[0].id')
    TEAM_KEY=$(printf '%s' "$teams" | jq -r '.teams.nodes[0].key')
}

# --- the project, and P92's fork in behaviour ------------------------------
#
# A board whose whole product is one Linear Project keeps loom's epics as
# ProjectMilestones INSIDE it, not as separate Projects on the team — that is
# Linear's actual analogue of "one milestone per epic". A `Project: <name or
# id>` line beside `Team:` in the declaration file opts a repo into that
# shape; PROJECT_MODE stays false with no such line, which is every place
# below keeping its pre-P92 behaviour (a Linear Project IS the epic).
PROJECT_ID=""; PROJECT_NAME=""; _PROJECT_MODE=false; _PROJECT_RESOLVED=false
_resolve_project() {
    $_PROJECT_RESOLVED && return 0
    _PROJECT_RESOLVED=true
    local want projects
    want=$(_tracker_decl_field "${LOOM_REPO:-.}" Project)
    [ -n "$want" ] || return 0
    _resolve_team
    projects=$(_graphql 'query($team: String!) {
  team(id: $team) { projects(first: 250) { nodes { id name } } }
}' "$(jq -nc --arg t "$TEAM_ID" '{team: $t}')") \
        || die "linear.sh: could not list team $TEAM_KEY's projects"
    PROJECT_ID=$(printf '%s' "$projects" | jq -r --arg w "$want" \
        '[.team.projects.nodes[] | select(.id == $w or (.name | ascii_downcase) == ($w | ascii_downcase))][0].id // empty')
    [ -n "$PROJECT_ID" ] \
        || die "linear.sh: '$(_tracker_decl_path)' declares 'Project: $want', and team $TEAM_KEY
  has no project by that name or id. It has: $(printf '%s' "$projects" | jq -r '[.team.projects.nodes[].name] | join(", ")')."
    PROJECT_NAME=$(printf '%s' "$projects" | jq -r --arg id "$PROJECT_ID" \
        '[.team.projects.nodes[] | select(.id == $id)][0].name')
    _PROJECT_MODE=true
}

# --- loom's ticket states, mapped onto Linear's Status field (P90) --------

# The fixed order SKILL.md defines the state machine in. Every place below
# that needs to ask "is this a state name or a real label" walks this list.
_STATE_NAMES="ready-for-agent in-progress review merge-queue blocked"

# The Linear name a repo gets for one of loom's five states when it writes no
# override — the three this driver actually has to CREATE (review,
# merge-queue, blocked) plus the two most Linear teams already carry under
# these names (backlog's `Todo`, started's `In Progress`).
_state_default_name() { # <loom-state> → default Linear Status name
    case "$1" in
        ready-for-agent) printf 'Todo\n' ;;
        in-progress)     printf 'In Progress\n' ;;
        review)          printf 'In Review\n' ;;
        merge-queue)     printf 'Merge Queue\n' ;;
        blocked)         printf 'Blocked\n' ;;
        *) die "linear.sh: '$1' is not one of loom's five ticket states" ;;
    esac
}
# Same palette bootstrap.sh's LABELS constant uses for these five on GitLab,
# so a state reads the same color whichever board it lives on.
_state_default_color() { # <loom-state> → hex color for a state this driver creates
    case "$1" in
        ready-for-agent) printf '#428BCA\n' ;;
        in-progress)     printf '#5CB85C\n' ;;
        review)          printf '#F0AD4E\n' ;;
        merge-queue)     printf '#8E44AD\n' ;;
        blocked)         printf '#D9534F\n' ;;
    esac
}

# The Status name THIS repo actually uses for one of loom's states: an
# override — a `Status <loom-state>: <Linear name>` line beside `Team:` in the
# same declaration file (P87) — else the default above.
_state_name() { # <loom-state> → the Linear Status name this repo resolves it to
    local want
    want=$(_tracker_decl_field "${LOOM_REPO:-.}" "Status $1")
    [ -n "$want" ] && printf '%s\n' "$want" || _state_default_name "$1"
}

# loom-state → the name this repo uses, as one JSON object — what `_MAP_ISSUE`
# needs to turn a Status back into a label, and what a Status filter needs to
# turn a label name back into a Status. Reads only the local declaration file,
# so caching it costs nothing and saves five file reads per shaped document.
_STATE_MAP_JSON=""
_state_map_json() {
    [ -n "$_STATE_MAP_JSON" ] && { printf '%s\n' "$_STATE_MAP_JSON"; return 0; }
    local s obj='{}'
    for s in $_STATE_NAMES; do
        obj=$(jq -nc --argjson o "$obj" --arg k "$s" --arg v "$(_state_name "$s")" '$o + {($k): $v}')
    done
    _STATE_MAP_JSON="$obj"
    printf '%s\n' "$obj"
}

# The team's actual workflow states (id, name, type, position), fetched once
# per process and shared by `issue-close`, `states-sync` and the relabel
# intercept below — the same query `issue-close` always made, now paid for
# once rather than per verb.
_TEAM_STATES=""
_team_states() {
    [ -n "$_TEAM_STATES" ] && { printf '%s\n' "$_TEAM_STATES"; return 0; }
    _resolve_team
    local out
    out=$(_graphql 'query($team: String!) {
  team(id: $team) { states(first: 50) { nodes { id name type position } } }
}' "$(jq -nc --arg t "$TEAM_ID" '{team: $t}')") || return 1
    _TEAM_STATES=$(printf '%s' "$out" | jq -c '.team.states.nodes')
    printf '%s\n' "$_TEAM_STATES"
}

# The workflow state id for one of loom's five, by the name this repo
# resolves it to. A name the team does not have is a HALT, never a guess —
# `states-sync` (below) is what creates it.
_state_id_for() { # <loom-state> → Linear state id, or a halt naming it
    local loom="$1" name states id
    name=$(_state_name "$loom")
    states=$(_team_states) || return 1
    id=$(printf '%s' "$states" | jq -r --arg n "$name" '[.[] | select(.name == $n)][0].id // empty')
    [ -n "$id" ] \
        || die "linear.sh: team $TEAM_KEY has no workflow state named '$name' (loom's
  '$loom'). Run 'bootstrap.sh states' to create it, or fix the Status override
  in $(_tracker_decl_path)."
    printf '%s\n' "$id"
}

# The Status this repo's completed tickets close into: an override
# (`Status closed: <name>`) or the team's own lowest-position `completed`
# state — never a name this driver invents, because teams rename `Done`.
_close_state_id() {
    local want states id
    want=$(_tracker_decl_field "${LOOM_REPO:-.}" "Status closed")
    states=$(_team_states) || return 1
    if [ -n "$want" ]; then
        id=$(printf '%s' "$states" | jq -r --arg n "$want" '[.[] | select(.name == $n)][0].id // empty')
        [ -n "$id" ] \
            || die "linear.sh: team $TEAM_KEY has no workflow state named '$want' (the
  'Status closed' override in $(_tracker_decl_path))."
    else
        id=$(printf '%s' "$states" | jq -r \
            '[.[] | select(.type == "completed")] | sort_by(.position) | .[0].id // empty')
        [ -n "$id" ] || die "issue-close: team $TEAM_KEY has no workflow state of type 'completed'"
    fi
    printf '%s\n' "$id"
}

# --- the loom shape -------------------------------------------------------
# One jq program per kind of thing, applied on the way out. Every Linear field
# name in this skill is inside these filters.
#
# `assignees` is an ARRAY holding nought or one name, because Linear has a
# single assignee and the contract has a list. Emitting null for "nobody" would
# break every reader — the scheduler's ready set is `assignees | length == 0`,
# and `null | length` is 0 in jq, so it would silently work until the day it
# didn't.
# `. as $i` up front: the labels field below needs both the raw label list AND
# a lookup against `.state.name`, and jq's `to_entries[] | select(...)` inside
# the object constructor changes what `.` means, so the issue has to be a
# named variable rather than the ambient input.
# `epic` (P92): a repo with a declared `Project:` keeps its epics as
# ProjectMilestones INSIDE that one project, so the epic is
# `$i.projectMilestone.name`. A repo with no `Project:` line keeps its
# pre-P92 shape unchanged — the Linear Project itself is the epic. `$pm`
# (project mode) is the switch, resolved once per process by `_resolve_project`
# and threaded through `_shape`/`_shape_one` like `$team` and `$states`.
_MAP_ISSUE='
  def st: if . == "completed" or . == "canceled" or . == "duplicate" then "closed" else "open" end;
  . as $i
  | { id: $i.number, title: ($i.title // ""),
      state: (($i.state.type // "backlog") | st),
      labels: ([ ($i.labels.nodes // [])[] | .name ]
               + [ $states | to_entries[] | select(.value == $i.state.name) | .key ]),
      assignees: (if ($i.assignee // null) == null then []
                  else [ ($i.assignee.displayName // $i.assignee.name) ] end),
      epic: (if $pm then ($i.projectMilestone.name // null) else ($i.project.name // null) end),
      url: ($i.url // null),
      project: $team,
      body: ($i.description // ""), updated_at: ($i.updatedAt // null) }'
_MAP_NOTE='
  { body: (.body // ""), created_at: (.createdAt // null),
    system: false, author: (.user.displayName // .user.name // null) }'
_MAP_PROJECT='
  def st: if . == "completed" or . == "canceled" then "closed" else "open" end;
  { id: .id, title: (.name // ""), state: ((.state // "planned") | st),
    description: (.description // "") }'
# A ProjectMilestone (P92) has no state field of its own — Linear only derives
# a completion PERCENTAGE from its issues, which is completeness, not
# acceptance, and loom needs the two kept apart (a probe may FAIL an epic
# whose tickets all closed). So acceptance lives in a trailer
# `v_milestone_close` appends to the description; its presence is what
# `state: closed` means here.
_MAP_MILESTONE='
  { id: .id, title: (.name // ""),
    state: (if ((.description // "") | test("<!-- loom-accepted ")) then "closed" else "open" end),
    description: (.description // "") }'

_shape() { # <filter> — a list, with the team, state map and project mode in scope
    jq --arg team "$TEAM_KEY" --argjson states "$(_state_map_json)" --argjson pm "$_PROJECT_MODE" "map($1)"
}
_shape_one() { jq --arg team "$TEAM_KEY" --argjson states "$(_state_map_json)" --argjson pm "$_PROJECT_MODE" "$1"; }

# The issue selection every read shares. Written once: a field added to one read
# and forgotten in another is how a ticket looks different depending on which
# call fetched it. `state { name }` joins `type` here for P90: the label
# synthesis above needs the Status's own name, not just its type.
# `projectMilestone { id name }` (P92) is fetched unconditionally — cheap, and
# `_MAP_ISSUE` above only reads it when `$pm` says this repo actually uses it.
_ISSUE_FIELDS='id number title description url updatedAt
               state { type name } labels { nodes { name } }
               assignee { name displayName } project { name }
               projectMilestone { id name }'

# Linear pages at 250 and answers with a cursor. Folded here for the same reason
# GitLab's `--paginate` is folded in its driver: a caller that saw one page
# would read a truncated board as a complete one.
_issues_page_query() { # <extra filter clauses>
    printf 'query($team: String!, $after: String) {
  issues(first: 250, after: $after,
         filter: { team: { key: { eq: $team } }%s }) {
    pageInfo { hasNextPage endCursor }
    nodes { %s }
  }
}' "$1" "$_ISSUE_FIELDS"
}

_issues_all() { # <extra filter clauses> → one JSON array of raw issue nodes
    local q after=null page acc='[]'
    q=$(_issues_page_query "$1")
    while :; do
        page=$(_graphql "$q" "$(jq -nc --arg t "$TEAM_KEY" --argjson a "$after" '{team: $t, after: $a}')") \
            || return 1
        acc=$(jq -nc --argjson acc "$acc" --argjson p "$page" '$acc + $p.issues.nodes')
        printf '%s' "$page" | jq -e '.issues.pageInfo.hasNextPage' >/dev/null 2>&1 || break
        after=$(printf '%s' "$page" | jq -c '.issues.pageInfo.endCursor')
    done
    printf '%s' "$acc"
}

# --- board reads ----------------------------------------------------------

# "Open" is every state type that is not completed, canceled or duplicate —
# backlog, unstarted and started alike. The scheduler's universe is `open
# issues labeled build-N`, and a ticket sitting in backlog is unquestionably
# still to do.
v_issues_open() {
    _resolve_team
    _resolve_project
    _issues_all ', state: { type: { nin: ["completed", "canceled", "duplicate"] } }' | _shape "$_MAP_ISSUE"
}

v_issues_by_label() { # <label> <opened|closed>
    local label="${1:-}" state="${2:-opened}" f
    [ -n "$label" ] || die "issues-by-label: needs a label"
    case "$state" in
        opened) f=', state: { type: { nin: ["completed", "canceled", "duplicate"] } }' ;;
        closed) f=', state: { type: { in: ["completed", "canceled", "duplicate"] } }' ;;
        *) die "issues-by-label: state must be opened|closed" ;;
    esac
    _resolve_team
    _resolve_project
    case " $_STATE_NAMES " in
        *" $label "*)
            # One of loom's five: not a label at all here (P90) — a Status
            # filter on the name this repo resolves it to.
            local want; want=$(_state_name "$label")
            _issues_all "$f" | jq --arg n "$want" '[ .[] | select(.state.name == $n) ]' \
                | _shape "$_MAP_ISSUE" ;;
        *)
            _issues_all "$f" | jq --arg l "$label" '[ .[] | select([.labels.nodes[].name] | index($l)) ]' \
                | _shape "$_MAP_ISSUE" ;;
    esac
}

# CAREFUL: `_resolve_team` sets shell variables, so it has to run in the verb's
# OWN shell. Every call below that reads TEAM_KEY or TEAM_ID through a pipeline
# or a `$(...)` would otherwise resolve the team inside a subshell and leave the
# outer one empty — which showed up as every single-issue read reporting a blank
# project while the list reads reported the right one.
_issue_node() { # <number> → the raw issue node, or fails
    local n="$1" out
    _resolve_team
    out=$(_graphql "query(\$team: String!, \$n: Float!) {
  issues(first: 1, filter: { team: { key: { eq: \$team } }, number: { eq: \$n } }) {
    nodes { $_ISSUE_FIELDS }
  }
}" "$(jq -nc --arg t "$TEAM_KEY" --argjson n "$n" '{team: $t, n: $n}')") || return 1
    printf '%s' "$out" | jq -e '.issues.nodes | length > 0' >/dev/null 2>&1 \
        || { echo "linear.sh: no issue $n in team $TEAM_KEY" >&2; return 1; }
    printf '%s' "$out" | jq '.issues.nodes[0]'
}

v_issue() { _resolve_team; _resolve_project; need_id "${1:-}" issue; _issue_node "$1" | _shape_one "$_MAP_ISSUE"; }

_issue_uuid() { # <number> → the UUID Linear's mutations take
    _issue_node "$1" | jq -r '.id // empty'
}

v_issue_notes() { # <id> [--limit N] — newest first, capped
    local id="${1:-}" limit=30 uuid out
    _resolve_team
    need_id "$id" issue-notes
    case "${2:-}" in --limit) limit="${3:-30}" ;; esac
    uuid=$(_issue_uuid "$id") && [ -n "$uuid" ] || return 1
    out=$(_graphql 'query($id: String!, $n: Int!) {
  issue(id: $id) { comments(first: $n, orderBy: createdAt) {
    nodes { body createdAt user { name displayName } } } }
}' "$(jq -nc --arg i "$uuid" --argjson n "$limit" '{id: $i, n: $n}')") || return 1
    # Newest first, matching every other driver: the readers that matter take
    # `last` of a sorted list, but the cap has to keep the NEWEST comments and
    # Linear's `orderBy` only sorts, it does not reverse.
    printf '%s' "$out" | jq '[.issue.comments.nodes[]] | reverse' | _shape "$_MAP_NOTE"
}

# Blocking edges. `relations` is what this issue does to others; the inverse is
# what is done to it, and that is the direction loom cares about — `is_blocked_by`
# is the edge the scheduler will not start a ticket over.
# The related issue's state is carried through honestly: it is a real state, so
# unlike GitLab's stateless cross-project link it is never null here.
v_issue_links() { # <id>
    local id="${1:-}" uuid out
    _resolve_team
    need_id "$id" issue-links
    uuid=$(_issue_uuid "$id") && [ -n "$uuid" ] || return 1
    out=$(_graphql 'query($id: String!) {
  issue(id: $id) {
    relations(first: 100)        { nodes { type relatedIssue { number state { type } } } }
    inverseRelations(first: 100) { nodes { type issue        { number state { type } } } }
  }
}' "$(jq -nc --arg i "$uuid" '{id: $i}')") || return 1
    printf '%s' "$out" | jq --arg team "$TEAM_KEY" '
      def st: if . == "completed" or . == "canceled" or . == "duplicate" then "closed" else "open" end;
      def row($n; $s; $t): { id: $n, state: ($s | st), project: $team, type: $t };
      [ (.issue.inverseRelations.nodes // [])[]
        | select(.issue != null)
        | if .type == "blocks" then row(.issue.number; .issue.state.type; "is_blocked_by")
          elif .type == "related" then row(.issue.number; .issue.state.type; "relates_to")
          else empty end ]
      + [ (.issue.relations.nodes // [])[]
        | select(.relatedIssue != null)
        | if .type == "related" then row(.relatedIssue.number; .relatedIssue.state.type; "relates_to")
          else empty end ]'
}

# A repo with a declared `Project:` (P92) keeps its epics as ProjectMilestones
# INSIDE that one project — Linear's actual analogue of "one milestone per
# epic" — so this lists THAT project's milestones. Back-compat: no `Project:`
# line lists the team's own Projects, exactly as before this repo's whole
# product was one Linear Project and each epic was one too.
v_milestones() { # [--state active]
    local want="" out
    case "${1:-}" in --state) want="${2:-active}" ;; esac
    _resolve_team
    _resolve_project
    if $_PROJECT_MODE; then
        out=$(_graphql 'query($id: String!) {
  project(id: $id) { projectMilestones(first: 250) { nodes { id name description } } }
}' "$(jq -nc --arg i "$PROJECT_ID" '{id: $i}')") || return 1
        printf '%s' "$out" | jq '[.project.projectMilestones.nodes[]]' | _shape "$_MAP_MILESTONE" \
            | jq --arg w "$want" '
                if $w == "" then . elif $w == "active" then [ .[] | select(.state == "open") ]
                else [ .[] | select(.state == $w) ] end'
    else
        out=$(_graphql 'query($team: String!) {
  team(id: $team) { projects(first: 250) { nodes { id name state description } } }
}' "$(jq -nc --arg t "$TEAM_ID" '{team: $t}')") || return 1
        printf '%s' "$out" | jq '[.team.projects.nodes[]]' | _shape "$_MAP_PROJECT" \
            | jq --arg w "$want" '
                if $w == "" then . elif $w == "active" then [ .[] | select(.state == "open") ]
                else [ .[] | select(.state == $w) ] end'
    fi
}

v_labels() {
    local out real
    _resolve_team
    out=$(_graphql 'query($team: String!) {
  team(id: $team) { labels(first: 250) { nodes { id name } } }
}' "$(jq -nc --arg t "$TEAM_ID" '{team: $t}')") || return 1
    real=$(printf '%s' "$out" | jq '[.team.labels.nodes[] | { name: .name }]')
    # The five ticket-state names are Statuses here, not labels (P90) — but
    # `bootstrap.sh cmd_labels` walks this list to decide what still needs
    # creating, and reports them present unconditionally so it never attempts
    # a label-create against a state that already exists a different way.
    jq -n --argjson real "$real" --arg names "$_STATE_NAMES" \
        '$real + ($names | split(" ") | map({name: .}))'
}

v_whoami() {
    _graphql 'query { viewer { id name displayName } }' \
        | jq '{ id: .viewer.id, name: (.viewer.displayName // .viewer.name) }'
}

# --- board writes ---------------------------------------------------------

_label_ids() { # <csv of names> → JSON array of ids, refusing an unknown name
    local csv="$1" out
    _resolve_team
    out=$(_graphql 'query($team: String!) {
  team(id: $team) { labels(first: 250) { nodes { id name } } }
}' "$(jq -nc --arg t "$TEAM_ID" '{team: $t}')") || return 1
    printf '%s' "$out" | jq -c --arg csv "$csv" '
      (.team.labels.nodes | map({key: .name, value: .id}) | from_entries) as $m
      | ($csv | split(",") | map(select(length > 0)))
      | map(. as $n | $m[$n] // error("no such label: \($n)"))'
}

v_note_add() { # <id> <body-file>
    local id="${1:-}" f="${2:-}" uuid
    _resolve_team
    need_id "$id" note-add
    [ -f "$f" ] || die "note-add: no such body file: '$f'"
    uuid=$(_issue_uuid "$id") && [ -n "$uuid" ] || die "note-add: no issue $id"
    # The body travels as a jq-built JSON variable, never on a command line: a
    # lane's notes run to thousands of characters and carry newlines.
    _graphql 'mutation($id: String!, $body: String!) {
  commentCreate(input: { issueId: $id, body: $body }) { success }
}' "$(jq -n --rawfile b "$f" --arg i "$uuid" '{id: $i, body: $b}')" >/dev/null
}

# Linear has no add/remove: an issue's labels are set whole. So the current set
# is read, the delta applied here, and the result written back. That read is not
# optional — writing only the additions would silently strip every label the
# ticket already had.
#
# P90: one of loom's five ticket states in `--add` is not a label here — Status
# is single-valued, so it becomes a `stateId` in the SAME mutation a claim's
# labelIds/assigneeId already ride in. A state name in `--remove` is dropped
# outright: Status can hold only one value, and whatever `--add` in the same
# call decides (or, with no `--add`, whatever it already is) has already
# answered "what happens to it". Two state names in one `--add` cannot come out
# of `_set_state`, so it is an error here rather than a coin flip.
v_issue_relabel() { # <id> [--add CSV] [--remove CSV] [--assignee ID] [--unassign]
    local id="${1:-}" add="" rm="" assignee="" unassign=false uuid cur want input
    local state_add="" label_add="" label_rm="" tok
    _resolve_team
    need_id "$id" issue-relabel
    shift
    while [ $# -gt 0 ]; do case "$1" in
        --add)      add="${2:-}"; shift 2 ;;
        --remove)   rm="${2:-}";  shift 2 ;;
        --assignee) assignee="${2:-}"; shift 2 ;;
        --unassign) unassign=true; shift ;;
        *) die "issue-relabel: unknown option '$1'" ;;
    esac; done
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        case " $_STATE_NAMES " in
            *" $tok "*)
                [ -z "$state_add" ] \
                    || die "issue-relabel: two ticket states in one --add ('$state_add' and '$tok') — _set_state cannot produce this"
                state_add="$tok" ;;
            *) label_add="${label_add:+$label_add,}$tok" ;;
        esac
    done < <(printf '%s\n' "$add" | tr ',' '\n')
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        case " $_STATE_NAMES " in
            *" $tok "*) : ;;
            *) label_rm="${label_rm:+$label_rm,}$tok" ;;
        esac
    done < <(printf '%s\n' "$rm" | tr ',' '\n')
    uuid=$(_issue_uuid "$id") && [ -n "$uuid" ] || die "issue-relabel: no issue $id"
    input='{}'
    if [ -n "$label_add" ] || [ -n "$label_rm" ]; then
        cur=$(_graphql 'query($id: String!) { issue(id: $id) { labels { nodes { id name } } } }' \
                "$(jq -nc --arg i "$uuid" '{id: $i}')") || return 1
        want=$(printf '%s' "$cur" | jq -c --arg a "$label_add" --arg r "$label_rm" '
            [.issue.labels.nodes[].name]
            + ($a | split(",") | map(select(length > 0)))
            | unique
            | . - ($r | split(",") | map(select(length > 0)))
            | join(",")')
        want=$(_label_ids "$(printf '%s' "$want" | jq -r '.')") || return 1
        input=$(jq -nc --argjson l "$want" '{labelIds: $l}')
    fi
    if [ -n "$state_add" ]; then
        local sid; sid=$(_state_id_for "$state_add") || return 1
        input=$(jq -nc --argjson i "$input" --arg s "$sid" '$i + {stateId: $s}')
    fi
    if $unassign; then input=$(jq -nc --argjson i "$input" '$i + {assigneeId: null}')
    elif [ -n "$assignee" ]; then input=$(jq -nc --argjson i "$input" --arg a "$assignee" '$i + {assigneeId: $a}')
    fi
    _graphql 'mutation($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) { success }
}' "$(jq -nc --arg i "$uuid" --argjson in "$input" '{id: $i, input: $in}')" >/dev/null
}

# Closing means moving to a workflow state of type `completed` — Linear has no
# close verb of its own. `_close_state_id` picks the team's own state (or the
# repo's `Status closed:` override) rather than a name this file invents,
# because teams rename `Done`.
v_issue_close() { # <id> [--remove CSV]
    local id="${1:-}" rm="" uuid sid input
    _resolve_team
    need_id "$id" issue-close
    shift
    case "${1:-}" in --remove) rm="${2:-}" ;; esac
    [ -z "$rm" ] || v_issue_relabel "$id" --remove "$rm"
    uuid=$(_issue_uuid "$id") && [ -n "$uuid" ] || die "issue-close: no issue $id"
    sid=$(_close_state_id) || return 1
    input=$(jq -nc --arg s "$sid" '{stateId: $s}')
    _graphql 'mutation($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) { success }
}' "$(jq -nc --arg i "$uuid" --argjson in "$input" '{id: $i, input: $in}')" >/dev/null
}

v_issue_create() { # --title T --body-file F --labels CSV [--milestone-id ID] → the new id
    local title="" f="" labels="" ms="" input ids
    local state_add="" real_labels="" tok
    while [ $# -gt 0 ]; do case "$1" in
        --title)        title="${2:-}"; shift 2 ;;
        --body-file)    f="${2:-}";     shift 2 ;;
        --labels)       labels="${2:-}"; shift 2 ;;
        --milestone-id) ms="${2:-}";    shift 2 ;;
        *) die "issue-create: unknown option '$1'" ;;
    esac; done
    [ -n "$title" ] || die "issue-create: --title is required"
    [ -f "$f" ] || die "issue-create: no such body file: '$f'"
    _resolve_team
    _resolve_project
    # `fix-ticket` creates with `ready-for-agent` in --labels like every other
    # driver — here it is a Status too (P90), so it splits the same way
    # `issue-relabel`'s --add does rather than failing `_label_ids` on a name
    # that was never a real Linear label.
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        case " $_STATE_NAMES " in
            *" $tok "*)
                [ -z "$state_add" ] \
                    || die "issue-create: two ticket states in --labels ('$state_add' and '$tok')"
                state_add="$tok" ;;
            *) real_labels="${real_labels:+$real_labels,}$tok" ;;
        esac
    done < <(printf '%s\n' "$labels" | tr ',' '\n')
    ids='[]'; [ -z "$real_labels" ] || { ids=$(_label_ids "$real_labels") || return 1; }
    # P92: `--milestone-id` used to be a Linear Project id (the epic itself).
    # A repo with a declared `Project:` puts every ticket in THAT project and
    # `--milestone-id` becomes the ProjectMilestone inside it instead —
    # back-compat unchanged with no `Project:` line.
    if $_PROJECT_MODE; then
        input=$(jq -n --rawfile b "$f" --arg t "$title" --arg team "$TEAM_ID" \
                      --argjson l "$ids" --arg p "$PROJECT_ID" --arg ms "$ms" \
            '{teamId: $team, title: $t, description: $b, labelIds: $l, projectId: $p}
             + (if $ms == "" then {} else {projectMilestoneId: $ms} end)')
    else
        input=$(jq -n --rawfile b "$f" --arg t "$title" --arg team "$TEAM_ID" \
                      --argjson l "$ids" --arg p "$ms" \
            '{teamId: $team, title: $t, description: $b, labelIds: $l}
             + (if $p == "" then {} else {projectId: $p} end)')
    fi
    if [ -n "$state_add" ]; then
        local sid; sid=$(_state_id_for "$state_add") || return 1
        input=$(jq -nc --argjson i "$input" --arg s "$sid" '$i + {stateId: $s}')
    fi
    _graphql 'mutation($input: IssueCreateInput!) {
  issueCreate(input: $input) { success issue { number } }
}' "$(jq -nc --argjson in "$input" '{input: $in}')" \
        | jq -r '.issueCreate.issue.number // empty'
}

v_label_create() { # <name> <color> <description>
    local name="${1:-}" color="${2:-}" desc="${3:-}"
    [ -n "$name" ] || die "label-create: needs a name"
    _resolve_team
    # Idempotent, like the GitLab one: a label that already exists is not an
    # error, because `bootstrap labels` re-runs over a board it set up before.
    _graphql 'mutation($input: IssueLabelCreateInput!) {
  issueLabelCreate(input: $input) { success }
}' "$(jq -nc --arg n "$name" --arg c "$color" --arg d "$desc" --arg t "$TEAM_ID" \
        '{input: {name: $n, teamId: $t, description: $d}
                 + (if $c == "" then {} else {color: $c} end)}')" >/dev/null 2>&1 || true
}

# P92: in project mode `milestones` hands out ProjectMilestone ids, which have
# no state field — Linear only derives a completion PERCENTAGE from their
# issues, which is completeness, not acceptance. So acceptance is recorded the
# only way a ProjectMilestone can hold it: a trailer appended to its
# description, `<!-- loom-accepted <ISO8601> -->`, idempotent by presence.
# Back-compat: no declared `Project:` means the id is still a Linear Project,
# closed the old way.
v_milestone_close() { # <id> — the id `milestones` handed out
    local id="${1:-}" cur desc trailer
    [ -n "$id" ] || die "milestone-close: needs a milestone id"
    _resolve_team
    _resolve_project
    if $_PROJECT_MODE; then
        cur=$(_graphql 'query($id: String!) { projectMilestone(id: $id) { description } }' \
                "$(jq -nc --arg i "$id" '{id: $i}')") || return 1
        desc=$(printf '%s' "$cur" | jq -r '.projectMilestone.description // ""')
        printf '%s' "$desc" | grep -q '<!-- loom-accepted ' && return 0
        trailer="<!-- loom-accepted $(date -u +%Y-%m-%dT%H:%M:%SZ) -->"
        [ -n "$desc" ] && desc="$desc"$'\n\n'"$trailer" || desc="$trailer"
        _graphql 'mutation($id: String!, $d: String!) {
  projectMilestoneUpdate(id: $id, input: { description: $d }) { success }
}' "$(jq -nc --arg i "$id" --arg d "$desc" '{id: $i, d: $d}')" >/dev/null
    else
        _graphql 'mutation($id: String!) {
  projectUpdate(id: $id, input: { state: "completed" }) { success }
}' "$(jq -nc --arg i "$id" '{id: $i}')" >/dev/null
    fi
}

# `bootstrap.sh states` — creates whichever of loom's five ticket states this
# team is missing, under the name this repo resolves it to. Idempotent by
# name, like `label-create`: a name that already exists is left alone. Every
# one loom creates gets type `started` — work exists on all three it usually
# has to add (review, merge-queue, blocked), Linear's UI groups `started` as
# in-flight, and the open/closed mapping above only cares that it is neither
# `completed` nor `canceled` nor `duplicate`.
v_states_sync() { # [--dry-run]
    local dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
    _resolve_team
    local states s name id created=0 skipped=0
    states=$(_team_states) || return 1
    for s in $_STATE_NAMES; do
        name=$(_state_name "$s")
        id=$(printf '%s' "$states" | jq -r --arg n "$name" '[.[] | select(.name == $n)][0].id // empty')
        if [ -n "$id" ]; then
            skipped=$((skipped+1)); continue
        fi
        if [ "$dry" -eq 1 ]; then
            echo "linear.sh: states: would create '$name' (loom's '$s')"
            created=$((created+1)); continue
        fi
        _graphql 'mutation($input: WorkflowStateCreateInput!) {
  workflowStateCreate(input: $input) { success }
}' "$(jq -nc --arg t "$TEAM_ID" --arg n "$name" --arg c "$(_state_default_color "$s")" \
        '{input: {teamId: $t, name: $n, type: "started", color: $c}}')" >/dev/null \
            || die "states: failed creating workflow state '$name'"
        echo "linear.sh: states: created '$name' (loom's '$s')"
        created=$((created+1))
    done
    if [ "$dry" -eq 1 ]; then
        echo "linear.sh: states: would create $created, $skipped already present (dry run — nothing written)"
    else
        echo "linear.sh: states: $created created, $skipped already present"
    fi
}

_usage() {
    die "usage: linear.sh <verb> [args]
  board reads : issues-open | issues-by-label <label> <opened|closed> | issue <id> |
                issue-notes <id> [--limit N] | issue-links <id> |
                milestones [--state <state>] | labels | whoami
  board writes: issue-create --title T --body-file F --labels CSV [--milestone-id ID] |
                issue-relabel <id> [--add CSV] [--remove CSV] [--assignee ID] [--unassign] |
                issue-close <id> [--remove CSV] | note-add <id> <body-file> |
                label-create <name> <color> <desc> | milestone-close <id> |
                states-sync [--dry-run]
  Linear has no merge requests: the forge is resolved from this repo's remote."
}
# The roster comes FIRST and needs no credential. Printing what a driver can do
# is not a tracker call, and refusing it for a missing API key would make the
# one message that explains this driver unreachable to anyone who has not yet
# set the key up.
case "${1:-}" in ''|-h|--help|help) _usage ;; esac

# A Linear personal API key is sent bare, not as a Bearer token.
_http_init LINEAR_API_KEY Authorization linear.sh

case "${1:-}" in
    issues-open)      shift; v_issues_open "$@" ;;
    issues-by-label)  shift; v_issues_by_label "$@" ;;
    issue)            shift; v_issue "$@" ;;
    issue-notes)      shift; v_issue_notes "$@" ;;
    issue-links)      shift; v_issue_links "$@" ;;
    milestones)       shift; v_milestones "$@" ;;
    labels)           shift; v_labels "$@" ;;
    whoami)           shift; v_whoami "$@" ;;
    note-add)         shift; v_note_add "$@" ;;
    issue-relabel)    shift; v_issue_relabel "$@" ;;
    issue-close)      shift; v_issue_close "$@" ;;
    issue-create)     shift; v_issue_create "$@" ;;
    label-create)     shift; v_label_create "$@" ;;
    milestone-close)  shift; v_milestone_close "$@" ;;
    states-sync)      shift; v_states_sync "$@" ;;
    *) _usage ;;
esac
