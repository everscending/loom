#!/usr/bin/env bash
# The GitHub FORGE driver (P87 stage 1).
#
# GitHub is a forge here and nothing else. Loom ships no GitHub *board* driver:
# this file exists so a repo whose tickets live somewhere that has no merge
# requests — a Linear board — still has a place for a lane's branch to land.
# If the board is also GitHub, this drives it too; that costs nothing and the
# marker below is the only thing that notices.
#
# CONTRACT — the merge-request document, loom's shape:
#   `id` (integer), `title`, `state` (open | closed | merged), `draft`, `url`,
#   `branch`, `sha`, `body`. Non-zero and silent on failure.
#
# THE TICKET LINK. GitLab answers "which MR closes issue 41" natively, because
# it parses `Closes #41` and stores the edge. GitHub does the same — for GITHUB
# issues. That is exactly the trap: with a Linear board, `Closes #41` in a pull
# request body means GitHub issue 41, which may well exist and belong to someone
# else, and merging would close it. So the marker this driver writes depends on
# whose issues the board holds, and `mr-for-ticket` looks for the marker it
# actually wrote.
#
# WHY THE LIST ENDPOINT AND NOT SEARCH. `mr-for-ticket` feeds three fail-closed
# guards in lane.sh — submit's "is there already an MR", merge's "which MR do I
# merge", and merge-failed's "did it in fact succeed". A guard built on GitHub's
# search index would be wrong twice over: the index lags behind writes by
# seconds to minutes, and these three calls read state the writes around them
# just changed; and search matches loosely, which is the precise failure that
# made GitLab's `related_merge_requests` unusable (build-1, 2026-08-03: issue #1
# listed #21's MR). The pulls list endpoint is immediately consistent and the
# match is a literal string test done here. It costs a full walk of the repo's
# pull requests, which is the price of an answer a guard may rely on.
set -euo pipefail

LIB_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
[ -f "$LIB_SH" ] \
    || { echo "github.sh: $LIB_SH is missing — it holds the shared derivations" >&2; exit 1; }
. "$LIB_SH"
DIE_RC=1
GH="${GH_CMD:-gh}"

# `{owner}` and `{repo}` are gh's placeholders for the repository this cwd's git
# remote points at — the same job glab's `:fullpath` does, and named here once
# so the driver resolves the repository one way, always.
_r() { printf 'repos/{owner}/{repo}/%s' "$1"; }

_list() { # <api-path> → one JSON array
    "$GH" api --paginate "$1" \
        | jq -s 'if (length > 0) and all(type == "array") then add
                 else error("not a JSON array") end' 2>/dev/null
}
_one() { "$GH" api "$1"; }

need_id() { case "${1:-}" in ''|*[!0-9]*) die "$2: needs a numeric id, got '${1:-}'" ;; esac; }

# GitHub keeps `state` at open|closed and records the merge separately, so
# `merged` has to be reconstructed — a closed-but-unmerged PR and a merged one
# are the same `state` and mean opposite things to the merge queue.
_MAP_MR='
  { id: .number, title: (.title // ""),
    state: (if (.merged_at // null) != null then "merged"
            elif (.state // "open") == "closed" then "closed" else "open" end),
    draft: (.draft // false), url: (.html_url // null),
    branch: (.head.ref // null), sha: (.head.sha // null),
    body: (.body // "") }'

_shape()     { jq "map($1)"; }
_shape_one() { jq "$1"; }

# --- the ticket link ------------------------------------------------------

# Whose issues does the board hold? Read from the repo's own declaration, the
# one place that answers it (P86). `LOOM_REPO` is exported to every lane;
# a human running this by hand is answered about the repo they stand in.
_board_is_github() { [ "$(_tracker_declared "${LOOM_REPO:-.}")" = github ]; }

v_ticket_marker() { # <id>
    need_id "${1:-}" ticket-marker
    if _board_is_github; then
        # The board and the forge are the same service: use GitHub's own closing
        # syntax so the platform links and closes the issue itself.
        printf 'Closes #%s\n' "$1"
    else
        # They are not. A trailer of loom's own, which GitHub attaches no
        # meaning to — that is the point. It links the PR to a ticket on another
        # system without asking GitHub to close anything of its own.
        printf 'Loom-Ticket: %s\n' "$1"
    fi
}

# Every pull request carrying this ticket's marker. The marker is matched as a
# literal with a digit boundary after it, so ticket 41 never matches ticket 410.
_mrs_for_ticket() { # <id> → JSON array of the loom MR document
    local id="$1" marker
    marker=$(v_ticket_marker "$id")
    # The marker is interpolated straight into the pattern, which is safe only
    # because a marker is regex-inert by contract (`ticket-marker` above emits
    # nothing but letters, digits, `#`, `:`, `-` and a space). The trailing
    # class is the boundary that keeps ticket 41 out of ticket 410's MR.
    _list "$(_r 'pulls?state=all&per_page=100')" \
        | jq --arg m "$marker" \
             '[ .[] | select((.body // "") | test("\($m)([^0-9]|$)"; "i")) ]' \
        | _shape "$_MAP_MR"
}

v_mr_for_ticket() { need_id "${1:-}" mr-for-ticket; _mrs_for_ticket "$1"; }
v_issue_mrs()     { need_id "${1:-}" issue-mrs;     _mrs_for_ticket "$1"; }

# --- merge requests -------------------------------------------------------

v_mr() { need_id "${1:-}" mr; _one "$(_r "pulls/$1")" | _shape_one "$_MAP_MR"; }

v_mr_for_branch() { # <branch> [--state merged|open|closed]
    local br="${1:-}" state="merged" q
    [ -n "$br" ] || die "mr-for-branch: needs a branch"
    case "${2:-}" in --state) state="${3:-merged}" ;; esac
    # GitHub has no `merged` to query for — a merged PR is a closed one with a
    # merge commit — so ask for closed and decide here.
    case "$state" in merged) q=closed ;; *) q="$state" ;; esac
    # The branch filter is applied HERE, not in the query. GitHub's `head=`
    # parameter wants `owner:branch` and silently returns nothing for a bare
    # branch name — a silent empty list is exactly what `_branch_merged` must
    # never be handed, because it reads as "this branch never landed" and that
    # answer deletes a worktree.
    _list "$(_r "pulls?state=$q&per_page=100")" \
        | _shape "$_MAP_MR" \
        | jq --arg want "$state" --arg br "$br" \
             '[ .[] | select(.state == $want and .branch == $br) ]'
}

v_mr_create() { # --source B --target B --title T --body-file F → the new id
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
    # `-F body=@file`, never an inline value: a lane's bodies are long, and a
    # literal path is the only thing an allowlist can match on.
    "$GH" api --method POST "$(_r pulls)" \
        -f "head=$src" -f "base=$tgt" -f "title=$title" -F "body=@$f" \
        | jq -r '.number // empty'
}

# P84: the source branch goes with the merge, the one moment it is provably
# disposable. GitHub takes no field for it on the merge call, so it is a second
# request — and a failure to delete must NOT fail the merge, which already
# landed. Losing a branch is a chore; reporting a landed merge as failed sends
# the whole ticket back through a queue.
v_mr_merge() { # <id>
    local id="${1:-}" br
    need_id "$id" mr-merge
    br=$(_one "$(_r "pulls/$id")" | jq -r '.head.ref // empty' 2>/dev/null || true)
    "$GH" api --method PUT "$(_r "pulls/$id/merge")" >/dev/null
    [ -n "$br" ] && "$GH" api --method DELETE "$(_r "git/refs/heads/$br")" >/dev/null 2>&1 || true
    return 0
}

# A pull request's comments live on the ISSUES endpoint — GitHub models a PR as
# an issue with a branch attached. `pulls/{n}/comments` is the other thing:
# line-level review comments, which is not what a lane is posting.
v_mr_note_add() { # <id> <body-file>
    local id="${1:-}" f="${2:-}"
    need_id "$id" mr-note-add
    [ -f "$f" ] || die "mr-note-add: no such body file: '$f'"
    "$GH" api --method POST "$(_r "issues/$id/comments")" -F "body=@$f" >/dev/null
}

case "${1:-}" in
    ticket-marker)  shift; v_ticket_marker "$@" ;;
    mr-for-ticket)  shift; v_mr_for_ticket "$@" ;;
    issue-mrs)      shift; v_issue_mrs "$@" ;;
    mr)             shift; v_mr "$@" ;;
    mr-for-branch)  shift; v_mr_for_branch "$@" ;;
    mr-create)      shift; v_mr_create "$@" ;;
    mr-merge)       shift; v_mr_merge "$@" ;;
    mr-note-add)    shift; v_mr_note_add "$@" ;;
    *) die "usage: github.sh <verb> [args]   (forge role)
  link  : ticket-marker <id> | mr-for-ticket <id> | issue-mrs <id>
  reads : mr <id> | mr-for-branch <branch> [--state S]
  writes: mr-create --source B --target B --title T --body-file F |
          mr-merge <id> | mr-note-add <id> <body-file>" ;;
esac
