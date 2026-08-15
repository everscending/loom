#!/usr/bin/env bash
# Deterministic lane worktree preparation. Consumer: Loom waves before a
# provider session starts. It never reads or writes tracker state.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
DIE_RC=1

cmd_prepare() {
    local repo="" ticket="" key="" branch="" base="" reuse=""
    while [ $# -gt 0 ]; do case "$1" in
      --repo) repo="${2:-}"; shift 2;; --ticket) ticket="${2:-}"; shift 2;;
      --key) key="${2:-}"; shift 2;;
      --branch) branch="${2:-}"; shift 2;; --base) base="${2:-}"; shift 2;;
      --reuse) reuse="${2:-}"; shift 2;; *) die "prepare: unknown argument '$1'";;
    esac; done
    case "$repo" in /*) ;; *) die "prepare: --repo must be absolute";; esac
    if [ -n "$ticket" ]; then case "$ticket" in *[!0-9]*) die "prepare: --ticket must be numeric";; esac; key="$ticket"; fi
    case "$key" in ''|*[!A-Za-z0-9_-]*) die "prepare: --ticket or slug-safe --key is required";; esac
    [ -d "$repo" ] || die "prepare: repo does not exist: $repo"
    local top; top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || die "prepare: not a git repo: $repo"
    [ "$(cd "$repo" && pwd -P)" = "$top" ] || die "prepare: --repo must be the main repository root"
    base="${base:-$(_detect_base "$repo")}"; branch="${branch:-loom-$key}"
    case "$branch" in ''|*[!A-Za-z0-9._/-]*) die "prepare: unsafe branch '$branch'";; esac

    if [ -n "$reuse" ]; then
      case "$reuse" in /*) ;; *) die "prepare: --reuse must be absolute";; esac
      [ -d "$reuse" ] || die "prepare: reuse path does not exist: $reuse"
      local common want
      common=$(git -C "$reuse" rev-parse --git-common-dir 2>/dev/null) || die "prepare: reuse path is not a git worktree"
      want=$(git -C "$repo" rev-parse --git-common-dir)
      [ "$(cd "$reuse" && cd "$common" 2>/dev/null && pwd -P)" = "$(cd "$repo" && cd "$want" && pwd -P)" ] \
        || die "prepare: reuse path belongs to another repository"
      printf '%s\n' "$(cd "$reuse" && pwd -P)"; return 0
    fi

    local parent name target custom
    parent=$(dirname "$repo"); name=$(basename "$repo"); target="$parent/$name-wt-$key"
    case "$target" in "$repo"|"$repo"/*) die "prepare: target must be a sibling, never nested in the repo";; esac
    custom=$(_yaml_scalar "$repo/.loom.yml" worktree_cmd)
    git -C "$repo" fetch --quiet origin || die "prepare: fetch origin failed"
    git -C "$repo" rev-parse --verify "origin/$base" >/dev/null 2>&1 || die "prepare: origin/$base does not exist"

    if [ -n "$custom" ]; then
      (cd "$repo" && $custom worktree add "$branch" -b --base "$base" --env copilot --start) >&2 \
        || die "prepare: custom worktree command failed: $custom"
      local found
      found=$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
        /^worktree / {w=substr($0,10)} /^branch / {if(substr($0,8)==b){print w;exit}}')
      [ -n "$found" ] || die "prepare: custom command succeeded but no worktree for '$branch' was registered"
      target="$found"
    elif [ -d "$target" ]; then
      git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || die "prepare: target exists but is not a worktree: $target"
      [ "$(git -C "$target" branch --show-current)" = "$branch" ] || die "prepare: target exists on another branch"
    elif git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$repo" worktree add --quiet "$target" "$branch" >&2 || die "prepare: could not reuse branch '$branch'"
    else
      git -C "$repo" worktree add --quiet "$target" -b "$branch" "origin/$base" >&2 || die "prepare: could not create worktree"
    fi
    if [ -f "$repo/.env" ] && [ ! -e "$target/.env" ]; then cp "$repo/.env" "$target/.env"; fi
    printf '%s\n' "$(cd "$target" && pwd -P)"
}

case "${1:-}" in
  prepare) shift; cmd_prepare "$@";;
  *) die "usage: worktree.sh prepare --repo <abs> (--ticket <iid>|--key <slug>) [--branch <name>] [--base <name>] [--reuse <abs>]";;
esac
