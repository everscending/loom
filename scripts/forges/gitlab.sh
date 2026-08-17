#!/usr/bin/env bash
# The GitLab FORGE driver (P87 stage 1).
#
# A forge is where branches and merge requests live. GitLab is a board and a
# forge both, so this file and `trackers/gitlab.sh` are two halves of one
# service, sharing one transport (`trackers/gitlab-common.sh`). They are split
# because Linear is a board and nothing else: a Linear-tracked repo keeps its
# code on GitHub or GitLab, and loom then resolves the two roles separately.
#
# CONTRACT — the merge-request document, loom's shape:
#   `id` (integer), `title`, `state` (open | closed | merged), `draft`, `url`,
#   `branch`, `sha`, `body`. Same rules as the board driver: JSON out, an array
#   for every list verb, non-zero and silent on failure so the callers'
#   fail-closed guards fire.
#
# THE TICKET LINK IS THE HARD PART, and it is why `mr-for-ticket` exists.
# GitLab answers "which MR closes issue 41" natively, because it parses
# `Closes #41` out of the MR description and stores the edge — but only when
# the board holding issue 41 is THIS GitLab project (P89). A GitLab repo whose
# board is Linear has no issue 41 of its own: `Closes #41` is either a 404 or,
# worse, a live link to a stranger's issue that the merge then closes. So
# `_board_is_gitlab` asks the same question `forges/github.sh` asks, from the
# same declaration (P86), and the marker + lookup split on it exactly as
# github.sh's do. On a GitLab board nothing changes: the marker stays
# `Closes #<id>` and the lookup stays the native `closed_by` /
# `related_merge_requests` endpoints. On any other board the marker is a
# `Loom-Ticket: <id>` trailer of loom's own, and `mr-for-ticket` finds it by
# walking the merge request list and matching the marker as a literal — the
# same list-and-match github.sh already pays for, and only on this path.
set -euo pipefail

LIB_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
[ -f "$LIB_SH" ] \
    || { echo "gitlab.sh: $LIB_SH is missing — it holds the shared derivations" >&2; exit 1; }
. "$LIB_SH"
DIE_RC=1
COMMON_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../trackers" && pwd)/gitlab-common.sh"
[ -f "$COMMON_SH" ] \
    || die "$COMMON_SH is missing — it holds the GitLab transport both drivers share"
. "$COMMON_SH"

# --- the ticket link ------------------------------------------------------

# Whose issues does the board hold? Read from the repo's own declaration, the
# one place that answers it (P86) — the same question github.sh asks.
# `LOOM_REPO` is exported to every lane; a human running this by hand is
# answered about the repo they stand in.
_board_is_gitlab() { [ "$(_tracker_declared "${LOOM_REPO:-.}")" = gitlab ]; }

v_ticket_marker() { # <id>
    need_id "${1:-}" ticket-marker
    if _board_is_gitlab; then
        # The tracker and the forge are the same service: GitLab's own closing
        # syntax is the best link available and costs nothing.
        printf 'Closes #%s\n' "$1"
    else
        # They are not. A trailer of loom's own, which GitLab attaches no
        # meaning to — that is the point. It links the MR to a ticket on
        # another system without asking GitLab to close anything of its own.
        printf 'Loom-Ticket: %s\n' "$1"
    fi
}

# Every merge request carrying this ticket's marker. Only reached on the
# split path — a GitLab board keeps using the native endpoints below. The
# marker is matched as a literal with a digit boundary after it, so ticket 41
# never matches ticket 410's MR (same test as github.sh's).
_mrs_for_ticket() { # <id> → JSON array of the loom MR document
    local id="$1" marker
    marker=$(v_ticket_marker "$id")
    _list "$(_p 'merge_requests?state=all&per_page=100')" \
        | jq --arg m "$marker" \
             '[ .[] | select((.description // "") | test("\($m)([^0-9]|$)"; "i")) ]' \
        | _shape "$_MAP_MR"
}

# `closed_by`, never `related_merge_requests`, on a GitLab board: the looser
# endpoint lists any MR that merely MENTIONS the issue, and on build-1
# 2026-08-03 issue #1 listed #21's open MR alongside its own.
# Not through `_list`: `closed_by` is a short, unpaginated list and the callers
# that matter (submit, merge, close, merge-failed) each apply their own jq to
# it. Paginating it would change the request these guards have always made.
v_mr_for_ticket() {
    need_id "${1:-}" mr-for-ticket
    if _board_is_gitlab; then
        _one "$(_p "issues/$1/closed_by")" | _shape "$_MAP_MR"
    else
        _mrs_for_ticket "$1"
    fi
}

# The looser one on a GitLab board, wanted deliberately by the snapshot: it is
# showing a human every MR touching a ticket, not choosing one to merge. Off a
# GitLab board there is no native edge at all, so it is the same marker walk.
v_issue_mrs() {
    need_id "${1:-}" issue-mrs
    if _board_is_gitlab; then
        _list "$(_p "issues/$1/related_merge_requests?per_page=100")" | _shape "$_MAP_MR"
    else
        _mrs_for_ticket "$1"
    fi
}

# --- merge requests -------------------------------------------------------

v_mr() { need_id "${1:-}" mr; _one "$(_p "merge_requests/$1")" | _shape_one "$_MAP_MR"; }

v_mr_for_branch() { # <branch> [--state merged|open|closed]
    local br="${1:-}" state="merged" query_state
    [ -n "$br" ] || die "mr-for-branch: needs a branch"
    case "${2:-}" in --state) state="${3:-merged}" ;; esac
    case "$state" in open) query_state=opened ;; closed) query_state=closed ;; *) query_state="$state" ;; esac
    _list --capped "$(_p "merge_requests?source_branch=$br&state=$query_state&per_page=1")" | _shape "$_MAP_MR"
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

v_mr_update() { # <id> --body-file F
    local id="${1:-}" f=""
    need_id "$id" mr-update
    shift
    while [ $# -gt 0 ]; do case "$1" in
        --body-file) f="${2:-}"; shift 2 ;;
        *) die "mr-update: unknown option '$1'" ;;
    esac; done
    [ -f "$f" ] || die "mr-update: no such body file: '$f'"
    "$GLAB" api --method PUT "$(_p "merge_requests/$id")" --field "description=@$f" >/dev/null
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

v_mr_note_add() { # <mr-id> <body-file>
    local id="${1:-}" f="${2:-}"
    need_id "$id" mr-note-add
    [ -f "$f" ] || die "mr-note-add: no such body file: '$f'"
    "$GLAB" api --method POST "$(_p "merge_requests/$id/notes")" --field "body=@$f" >/dev/null
}

case "${1:-}" in
    ticket-marker)  shift; v_ticket_marker "$@" ;;
    mr-for-ticket)  shift; v_mr_for_ticket "$@" ;;
    issue-mrs)      shift; v_issue_mrs "$@" ;;
    mr)             shift; v_mr "$@" ;;
    mr-for-branch)  shift; v_mr_for_branch "$@" ;;
    mr-create)      shift; v_mr_create "$@" ;;
    mr-update)      shift; v_mr_update "$@" ;;
    mr-merge)       shift; v_mr_merge "$@" ;;
    mr-note-add)    shift; v_mr_note_add "$@" ;;
    # The roster, printed for a human and read by the suite's drift check.
    *) die "usage: gitlab.sh <verb> [args]   (forge role)
  link  : ticket-marker <id> | mr-for-ticket <id> | issue-mrs <id>
  reads : mr <id> | mr-for-branch <branch> [--state S]
  writes: mr-create --source B --target B --title T --body-file F |
          mr-update <id> --body-file F |
          mr-merge <id> | mr-note-add <id> <body-file>" ;;
esac
