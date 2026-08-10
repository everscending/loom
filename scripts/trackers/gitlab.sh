#!/usr/bin/env bash
# The GitLab driver (P86 stage 2). Every tracker call loom makes goes through a
# driver, and this is the one implementation of the contract.
#
# WHY A DRIVER AT ALL. GitLab was never a configured backend, it was a literal:
# `glab api "projects/:fullpath/issues/$iid"` written out at ~28 call sites
# across tick.sh, lane.sh and bootstrap.sh. A second tracker was therefore not a
# configuration change but a rewrite of every file that touches the board. The
# verbs below are named for what LOOM needs, not for what GitLab offers, so a
# second driver is a new file implementing a written contract.
#
# THE VERB GROUPS ARE THE SEAM. `board-*` and the issue/label/milestone verbs
# are a tracker; the `mr-*` group and `issue-closed-by` are a FORGE — a place
# where branches and merge requests live. GitLab happens to be both. A tracker
# that is not also a forge (Linear has no merge requests) needs exactly the
# second group pointed somewhere else, and grouping them costs nothing today.
#
# CONTRACT — the SHAPE is loom's, not GitLab's (P86 stage 3)
#   * every read verb emits the loom document: `id`, `state` (open | closed,
#     plus `merged` for a merge request), `labels`, `assignees` (usernames),
#     `epic`, `url`, `body`, `updated_at`. Nothing downstream of this file
#     knows the words `iid`, `opened`, `milestone` or `web_url`.
#     This is what makes the verbs a contract rather than a passthrough: a
#     second driver implements what loom asked for, instead of fabricating
#     GitLab fields to satisfy readers that were never told what they need.
#   * stdout is JSON for every read verb, and a JSON array wherever the tracker
#     returns a list — never a bare page, never GitLab's human sentence for an
#     empty list (see `_list` below).
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
GLAB="${GLAB_CMD:-glab}"

# The one LIST read, moved here from lib.sh where it was `_glab_list` (P49).
# Its two jobs are both GitLab facts and belong to this driver: `--paginate`
# emits one array PER PAGE and a bare `per_page=100` silently returns page one,
# so the fold is part of the read; and a non-array response (including `glab
# issue list`'s human sentence on an empty board) must fail rather than parse as
# emptiness. `--capped` is the deliberate opposite and stays explicit: a
# `sort=desc` notes read wants the newest N, and paginating it pulls the whole
# thread.
_list() { # [--capped] <api-path> → one JSON array
    local capped=false
    case "${1:-}" in --capped) capped=true; shift ;; esac
    if $capped; then "$GLAB" api "$1"; else "$GLAB" api --paginate "$1"; fi \
        | jq -s 'if (length > 0) and all(type == "array") then add
                 else error("not a JSON array") end' 2>/dev/null
}

_one() { "$GLAB" api "$1"; }   # a single object read, passed through as-is

# `:fullpath` and `:id` are both glab shorthands for "the project this cwd's
# git remote points at". They were used interchangeably at the old call sites;
# one form here means the driver resolves the project one way, always.
_p() { printf 'projects/:fullpath/%s' "$1"; }

# --- the loom shape -------------------------------------------------------
# One jq program per kind of thing, applied on the way out. Every GitLab field
# name in this skill is now inside these four filters.
#
# `state` collapses GitLab's vocabulary to loom's: an issue is open or closed,
# and a merge request is additionally `merged` — a distinct fact the merge
# queue turns on, not a synonym for closed.
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
_MAP_MR='
  def st: if . == "merged" then "merged" elif . == "closed" then "closed" else "open" end;
  { id: .iid, title: (.title // ""), state: ((.state // "opened") | st),
    draft: (.draft // false), url: (.web_url // null),
    branch: (.source_branch // null), sha: (.sha // null),
    body: (.description // "") }'
_MAP_MILESTONE='
  def st: if . == "closed" then "closed" else "open" end;
  { id: .id, title: (.title // ""), state: ((.state // "active") | st),
    description: (.description // "") }'
_MAP_LABEL='{ name: .name }'

_shape()     { jq "map($1)"; }   # a list
_shape_one() { jq "$1"; }        # a single object

need_id() { case "${1:-}" in ''|*[!0-9]*) die "$2: needs a numeric id, got '${1:-}'" ;; esac; }

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

v_whoami() { _one user; }

# --- board writes ---------------------------------------------------------

v_note_add() { # <issue|mr> <id> <body-file>
    local kind="${1:-}" id="${2:-}" f="${3:-}" path
    case "$kind" in issue) path=issues ;; mr) path=merge_requests ;;
        *) die "note-add: first argument is issue|mr, got '${kind:-}'" ;; esac
    need_id "$id" note-add
    [ -f "$f" ] || die "note-add: no such body file: '$f'"
    # `--field body=@file` and never an inline `-m`: a lane's bodies are long
    # enough to be denied on length alone, and any $VAR in the command defeats
    # allowlist prefix-matching. The path this file passes is one loom produced.
    "$GLAB" api --method POST "$(_p "$path/$id/notes")" --field "body=@$f" >/dev/null
}

v_issue_relabel() { # <id> [--add <csv>] [--remove <csv>] [--assignee <user-id>]
    local id="${1:-}" add="" rm="" assignee=""
    need_id "$id" issue-relabel
    shift
    while [ $# -gt 0 ]; do case "$1" in
        --add)      add="${2:-}"; shift 2 ;;
        --remove)   rm="${2:-}";  shift 2 ;;
        # 0 is GitLab's "unassign", and the caller that needs it (the
        # ready-for-agent transition) means exactly that: a claimed "ready"
        # ticket is invisible to the scheduler.
        --assignee) assignee="${2:-}"; shift 2 ;;
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

# --- forge ----------------------------------------------------------------
# The group a tracker that is not also a code host cannot answer. Kept separate
# for that reason and no other.

# `closed_by`, never `related_merge_requests`: the looser endpoint lists any MR
# that merely MENTIONS the issue, and on build-1 2026-08-03 issue #1 listed
# #21's open MR alongside its own.
# Not through `_list`: `closed_by` is a short, unpaginated list and the callers
# that matter (submit, merge, close, merge-failed) each apply their own jq to
# it. Paginating it would change the request these guards have always made.
v_issue_closed_by() { need_id "${1:-}" issue-closed-by; _one "$(_p "issues/$1/closed_by")" | _shape "$_MAP_MR"; }

# The looser one, wanted deliberately by the snapshot: it is showing a human
# every MR touching a ticket, not choosing one to merge.
v_issue_mrs() { need_id "${1:-}" issue-mrs; _list "$(_p "issues/$1/related_merge_requests?per_page=100")" | _shape "$_MAP_MR"; }

v_mr() { need_id "${1:-}" mr; _one "$(_p "merge_requests/$1")" | _shape_one "$_MAP_MR"; }

v_mr_for_branch() { # <branch> [--state merged]
    local br="${1:-}" state="merged"
    [ -n "$br" ] || die "mr-for-branch: needs a branch"
    case "${2:-}" in --state) state="${3:-merged}" ;; esac
    _list --capped "$(_p "merge_requests?source_branch=$br&state=$state&per_page=1")" | _shape "$_MAP_MR"
}

v_mr_create() { # --source B --target B --title T --body-file F → the new mr id
    local src="" tgt="" title="" f=""
    while [ $# -gt 0 ]; do case "$1" in
        --source)    src="${2:-}";   shift 2 ;;
        --target)    tgt="${2:-}";   shift 2 ;;
        --title)     title="${2:-}"; shift 2 ;;
        --body-file) f="${2:-}";     shift 2 ;;
        *) die "mr-create: unknown option '$1'" ;;
    esac; done
    [ -n "$src" ] && [ -n "$tgt" ] && [ -n "$title" ] || die "mr-create: --source, --target and --title are all required"
    [ -f "$f" ] || die "mr-create: no such body file: '$f'"
    "$GLAB" api --method POST "$(_p merge_requests)" \
        -f "source_branch=$src" -f "target_branch=$tgt" -f "title=$title" \
        --field "description=@$f" | jq -r '.iid // empty'
}

# P84: the source branch is deleted as part of the merge. This is the one
# moment it is provably disposable, and it is one field on a request the verb
# already makes — without it a repo that does not set
# `remove_source_branch_after_merge` accumulates every branch it ever merges.
v_mr_merge() { # <mr-id>
    need_id "${1:-}" mr-merge
    "$GLAB" api --method PUT "$(_p "merge_requests/$1/merge")" \
        -f should_remove_source_branch=true >/dev/null
}

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
    issue-closed-by)  shift; v_issue_closed_by "$@" ;;
    issue-mrs)        shift; v_issue_mrs "$@" ;;
    mr)               shift; v_mr "$@" ;;
    mr-for-branch)    shift; v_mr_for_branch "$@" ;;
    mr-create)        shift; v_mr_create "$@" ;;
    mr-merge)         shift; v_mr_merge "$@" ;;
    # The roster, printed for a human and read by the suite's drift check.
    *) die "usage: gitlab.sh <verb> [args]
  board reads : issues-open | issues-by-label <label> <opened|closed> | issue <id> |
                issue-notes <id> [--limit N] | issue-links <id> |
                milestones [--state <state>] | labels | whoami
  board writes: issue-create --title T --body-file F --labels CSV [--milestone-id N] |
                issue-relabel <id> [--add CSV] [--remove CSV] [--assignee N] |
                issue-close <id> [--remove CSV] | note-add <issue|mr> <id> <body-file> |
                label-create <name> <color> <desc> | milestone-close <id>
  forge       : mr-create --source B --target B --title T --body-file F | mr-merge <id> |
                mr <id> | mr-for-branch <branch> [--state S] | issue-closed-by <id> |
                issue-mrs <id>" ;;
esac
