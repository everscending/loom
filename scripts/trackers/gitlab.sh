#!/usr/bin/env bash
# The GitLab BOARD driver (P86 stage 2, split from the forge by P87 stage 1).
# Every board call loom makes goes through a driver, and this is one of them.
#
# WHY A DRIVER AT ALL. GitLab was never a configured backend, it was a literal:
# `glab api "projects/:fullpath/issues/$iid"` written out at ~28 call sites
# across tick.sh, lane.sh and bootstrap.sh. A second tracker was therefore not a
# configuration change but a rewrite of every file that touches the board. The
# verbs below are named for what LOOM needs, not for what GitLab offers, so a
# second driver is a new file implementing a written contract.
#
# WHY THE FORGE IS NOT HERE. P86 grouped these verbs and the `mr-*` ones apart
# in a comment, because they are two systems GitLab happens to merge: a board,
# and a place where branches and merge requests live. P87 made the grouping
# real — the merge-request half is `forges/gitlab.sh`, resolved separately — so
# that a board which is not also a code host (Linear has no merge requests) can
# be driven here while its code lives somewhere else. If an `mr-` verb ever
# appears in this file, that split has failed.
#
# CONTRACT — the SHAPE is loom's, not GitLab's (P86 stage 3)
#   * every read verb emits the loom document: `id`, `state` (open | closed),
#     `labels`, `assignees` (usernames), `epic`, `url`, `body`, `updated_at`.
#     Nothing downstream of this file knows the words `iid`, `opened`,
#     `milestone` or `web_url`.
#     This is what makes the verbs a contract rather than a passthrough: a
#     second driver implements what loom asked for, instead of fabricating
#     GitLab fields to satisfy readers that were never told what they need.
#   * `id` is an INTEGER, scoped to the project. Linear's `Issue.number` is the
#     same shape for the same reason (P87 stage 3) — the jq layer does
#     arithmetic on ticket ids, and an opaque string id would be a rewrite of
#     all of it.
#   * stdout is JSON for every read verb, and a JSON array wherever the tracker
#     returns a list — never a bare page, never GitLab's human sentence for an
#     empty list (see `_list` in gitlab-common.sh).
#   * a failed call exits non-zero and prints nothing on stdout, so every
#     caller's existing fail-closed path still fires. This file NEVER
#     substitutes an empty list for an error: `snapshot` degrades deliberately,
#     at its own call site, and a driver that degraded silently would take that
#     decision away from it.
#   * writes are idempotent where the API allows and never delete.
#
# Test seam: GLAB_CMD, as before. The driver itself is seamed by TRACKER_CMD in
# lib.sh, so a test can stub either layer.
set -euo pipefail

LIB_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
[ -f "$LIB_SH" ] \
    || { echo "gitlab.sh: $LIB_SH is missing — it holds the shared derivations" >&2; exit 1; }
. "$LIB_SH"
DIE_RC=1
COMMON_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gitlab-common.sh"
[ -f "$COMMON_SH" ] \
    || die "$COMMON_SH is missing — it holds the GitLab transport both drivers share"
. "$COMMON_SH"

# --- the loom shape -------------------------------------------------------
# One jq program per kind of thing, applied on the way out. Every GitLab board
# field name in this skill is now inside these filters (the merge-request one
# lives in gitlab-common.sh, shared with the forge).
_MAP_ISSUE='
  def st: if . == "closed" then "closed" else "open" end;
  { id: .iid, title: (.title // ""), state: (.state | st),
    labels: (.labels // []), assignees: [ (.assignees // [])[] | .username ],
    epic: (.milestone.title // null), url: (.web_url // null),
    project: (.project_id // null),
    body: (.description // ""), updated_at: (.updated_at // null) }'
# A link that carries no state at all is UNKNOWN, and stays unknown: the
# open-set inference behind it is only valid inside one project, and inventing
# "open" here is exactly how a cross-project blocker gets guessed at.
_MAP_LINK='
  def st: if . == "closed" then "closed" else "open" end;
  { id: .iid, state: (if (.state // null) == null then null else (.state | st) end),
    project: (.project_id // null), type: (.link_type // "") }'
_MAP_NOTE='
  { body: (.body // ""), created_at: (.created_at // null),
    system: (.system // false), author: (.author.username // null) }'
_MAP_MILESTONE='
  def st: if . == "closed" then "closed" else "open" end;
  { id: .id, title: (.title // ""), state: ((.state // "active") | st),
    description: (.description // "") }'
_MAP_LABEL='{ name: .name }'

# --- board reads ----------------------------------------------------------

v_issues_open() { _list "$(_p 'issues?state=opened&per_page=100')" | _shape "$_MAP_ISSUE"; }

v_issues_by_label() { # <label> <opened|closed>
    local label="${1:-}" state="${2:-opened}"
    [ -n "$label" ] || die "issues-by-label: needs a label"
    case "$state" in opened|closed) ;; *) die "issues-by-label: state must be opened|closed" ;; esac
    # state BEFORE labels, which is the order every existing call site used.
    # Query-parameter order is not semantics to GitLab, but it is to anything
    # matching on the request — including this skill's own test stubs.
    _list "$(_p "issues?state=$state&labels=$label&per_page=100")" | _shape "$_MAP_ISSUE"
}

v_issue() { need_id "${1:-}" issue; _one "$(_p "issues/$1")" | _shape_one "$_MAP_ISSUE"; }

v_issue_notes() { # <id> [--limit N] — newest first, capped (never paginated)
    local id="${1:-}" limit=30
    need_id "$id" issue-notes
    case "${2:-}" in --limit) limit="${3:-30}" ;; esac
    _list --capped "$(_p "issues/$id/notes?sort=desc&order_by=created_at&per_page=$limit")" \
        | _shape "$_MAP_NOTE"
}

# Native blocking links. A 403 here is the EXPECTED path on a tier without
# them — the caller degrades to body-parsed edges — so this reports the failure
# and lets the caller decide, rather than deciding for it.
v_issue_links() { need_id "${1:-}" issue-links; _list "$(_p "issues/$1/links?per_page=100")" | _shape "$_MAP_LINK"; }

v_milestones() { # [--state active]
    local q="milestones?per_page=100"
    case "${1:-}" in --state) q="milestones?state=${2:-active}&per_page=100" ;; esac
    _list "$(_p "$q")" | _shape "$_MAP_MILESTONE"
}

v_labels() { _list "$(_p 'labels?per_page=100')" | _shape "$_MAP_LABEL"; }

# P87: the loom document, not GitLab's user object. `claim` used to sed an
# `"id":<digits>` out of the raw payload at its call site — a GitLab field name
# and a GitLab id SHAPE, both living outside the driver. The id is opaque from
# here on: it goes back in through `issue-relabel --assignee` and nothing else
# ever looks inside it.
v_whoami() { _one user | _shape_one '{ id: .id, name: (.username // .name // null) }'; }

# --- board writes ---------------------------------------------------------

# Issues only. The merge-request note is `mr-note-add` on the forge (P87), for
# the plain reason that a board with no merge requests cannot answer it.
v_note_add() { # <id> <body-file>
    local id="${1:-}" f="${2:-}"
    need_id "$id" note-add
    [ -f "$f" ] || die "note-add: no such body file: '$f'"
    # `--field body=@file` and never an inline `-m`: a lane's bodies are long
    # enough to be denied on length alone, and any $VAR in the command defeats
    # allowlist prefix-matching. The path this file passes is one loom produced.
    "$GLAB" api --method POST "$(_p "issues/$id/notes")" --field "body=@$f" >/dev/null
}

v_issue_relabel() { # <id> [--add <csv>] [--remove <csv>] [--assignee <user-id>] [--unassign]
    local id="${1:-}" add="" rm="" assignee=""
    need_id "$id" issue-relabel
    shift
    while [ $# -gt 0 ]; do case "$1" in
        --add)      add="${2:-}"; shift 2 ;;
        --remove)   rm="${2:-}";  shift 2 ;;
        --assignee) assignee="${2:-}"; shift 2 ;;
        # A named verb, not a magic number. 0 happens to be GitLab's way of
        # saying it, and the caller that needs it (the ready-for-agent
        # transition) means exactly "nobody" — a claimed `ready` ticket is
        # invisible to the scheduler. Another tracker spells it null.
        --unassign) assignee=0; shift ;;
        *) die "issue-relabel: unknown option '$1'" ;;
    esac; done
    "$GLAB" api --method PUT "$(_p "issues/$id")" \
        ${add:+-f "add_labels=$add"} ${rm:+-f "remove_labels=$rm"} \
        ${assignee:+-f "assignee_ids=$assignee"} >/dev/null
}

v_issue_close() { # <id> [--remove <csv>] — strip state labels and close, one call
    local id="${1:-}" rm=""
    need_id "$id" issue-close
    shift
    case "${1:-}" in --remove) rm="${2:-}" ;; esac
    "$GLAB" api --method PUT "$(_p "issues/$id")" \
        ${rm:+-f "remove_labels=$rm"} -f state_event=close >/dev/null
}

v_issue_create() { # --title T --body-file F --labels CSV [--milestone-id N] → the new id
    local title="" f="" labels="" ms=""
    while [ $# -gt 0 ]; do case "$1" in
        --title)        title="${2:-}"; shift 2 ;;
        --body-file)    f="${2:-}";     shift 2 ;;
        --labels)       labels="${2:-}"; shift 2 ;;
        --milestone-id) ms="${2:-}";    shift 2 ;;
        *) die "issue-create: unknown option '$1'" ;;
    esac; done
    [ -n "$title" ] || die "issue-create: --title is required"
    [ -f "$f" ] || die "issue-create: no such body file: '$f'"
    "$GLAB" api --method POST "$(_p issues)" \
        -f "title=$title" --field "description=@$f" \
        ${labels:+-f "labels=$labels"} ${ms:+-f "milestone_id=$ms"} \
        | jq -r '.iid // empty'
}

v_label_create() { # <name> <color> <description>
    [ -n "${1:-}" ] || die "label-create: needs a name"
    "$GLAB" label create --name "$1" --color "${2:-}" --description "${3:-}" >/dev/null
}

v_milestone_close() { # <milestone-id>
    need_id "${1:-}" milestone-close
    "$GLAB" api --method PUT "$(_p "milestones/$1")" --field state_event=close >/dev/null
}

case "${1:-}" in
    issues-open)      shift; v_issues_open "$@" ;;
    issues-by-label)  shift; v_issues_by_label "$@" ;;
    issue)            shift; v_issue "$@" ;;
    issue-notes)      shift; v_issue_notes "$@" ;;
    issue-links)      shift; v_issue_links "$@" ;;
    board)            exit 2 ;;
    milestones)       shift; v_milestones "$@" ;;
    labels)           shift; v_labels "$@" ;;
    whoami)           shift; v_whoami "$@" ;;
    note-add)         shift; v_note_add "$@" ;;
    issue-relabel)    shift; v_issue_relabel "$@" ;;
    issue-close)      shift; v_issue_close "$@" ;;
    issue-create)     shift; v_issue_create "$@" ;;
    label-create)     shift; v_label_create "$@" ;;
    milestone-close)  shift; v_milestone_close "$@" ;;
    # The roster, printed for a human and read by the suite's drift check.
    *) die "usage: gitlab.sh <verb> [args]
  board reads : issues-open | issues-by-label <label> <opened|closed> | issue <id> |
                issue-notes <id> [--limit N] | issue-links <id> |
                milestones [--state <state>] | labels | whoami
  board writes: issue-create --title T --body-file F --labels CSV [--milestone-id N] |
                issue-relabel <id> [--add CSV] [--remove CSV] [--assignee N] |
                issue-close <id> [--remove CSV] | note-add <id> <body-file> |
                label-create <name> <color> <desc> | milestone-close <id>
  the merge-request verbs are the FORGE's, in forges/<name>.sh" ;;
esac
