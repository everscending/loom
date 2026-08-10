#!/usr/bin/env bash
# The GitLab transport, shared by the two drivers GitLab supplies (P87 stage 1).
#
# GitLab is a board AND a forge, so it implements both roles: `trackers/gitlab.sh`
# answers the board verbs and `forges/gitlab.sh` answers the merge-request ones.
# They speak to the same API through the same tool, and this file is that tool —
# sourced by both, executable by neither. `glab` is named here and in nothing
# else, which is the property P86 bought and stage 1 must not spend.
#
# Callers source this AFTER lib.sh (it uses `die`).

GLAB="${GLAB_CMD:-glab}"

# The one LIST read, moved here from lib.sh where it was `_glab_list` (P49).
# Its two jobs are both GitLab facts: `--paginate` emits one array PER PAGE and
# a bare `per_page=100` silently returns page one, so the fold is part of the
# read; and a non-array response (including `glab issue list`'s human sentence
# on an empty board) must fail rather than parse as emptiness. `--capped` is the
# deliberate opposite and stays explicit: a `sort=desc` notes read wants the
# newest N, and paginating it pulls the whole thread.
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

_shape()     { jq "map($1)"; }   # a list
_shape_one() { jq "$1"; }        # a single object

need_id() { case "${1:-}" in ''|*[!0-9]*) die "$2: needs a numeric id, got '${1:-}'" ;; esac; }

# The merge-request shape. Lives here rather than in the forge alone because
# `state` collapses GitLab's vocabulary to loom's in the same way the board's
# does, and the two must not drift: an MR is open, closed, or `merged` — a
# distinct fact the merge queue turns on, never a synonym for closed.
_MAP_MR='
  def st: if . == "merged" then "merged" elif . == "closed" then "closed" else "open" end;
  { id: .iid, title: (.title // ""), state: ((.state // "opened") | st),
    draft: (.draft // false), url: (.web_url // null),
    branch: (.source_branch // null), sha: (.sha // null),
    body: (.description // "") }'
