#!/usr/bin/env bash
# Deterministic lane worktree preparation. Consumer: Loom waves before a
# provider session starts. It never reads or writes tracker state.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/lib.sh"
DIE_RC=1

_ensure_local_exclude() { # <main-repo> <pattern>
    local repo="$1" pattern="$2" exclude
    exclude=$(git -C "$repo" rev-parse --git-path info/exclude 2>/dev/null) \
      || die "prepare: could not resolve the repository-local exclude file"
    case "$exclude" in /*) ;; *) exclude="$repo/$exclude";; esac
    mkdir -p "$(dirname "$exclude")"
    touch "$exclude"
    grep -qxF "$pattern" "$exclude" 2>/dev/null || printf '%s\n' "$pattern" >> "$exclude"
}

_prepare_local_metadata() { # <main-repo> <linked-worktree>
    local repo="$1" target="$2" rules="$repo/.codex/rules/loom.rules"
    # These are generated machine-local artifacts. The common exclude file is
    # shared by every linked worktree, so neither path dirties a ticket branch.
    _ensure_local_exclude "$repo" '/.worktrees/'
    _ensure_local_exclude "$repo" '/.codex/rules/loom.rules'
    if [ -f "$rules" ]; then
      mkdir -p "$target/.codex/rules"
      cp "$rules" "$target/.codex/rules/loom.rules"
    fi
}

_prepare_dependencies() { # <linked-worktree>
    local target="$1" stamp resolved install_dir install_cmd
    # Keep the readiness marker in this linked worktree's Git metadata, not in
    # the checkout: it survives retries without dirtying the ticket branch.
    stamp=$(git -C "$target" rev-parse --git-path loom-dependencies-ready 2>/dev/null) \
      || die "prepare: could not resolve dependency state for $target"
    [ -f "$stamp" ] && return 0

    resolved=$(_install_cmd_for "$target")
    if [ -n "$resolved" ]; then
      IFS=$'\t' read -r install_dir install_cmd <<EOF
$resolved
EOF
      install_cmd="${LOOM_WORKTREE_INSTALL_CMD:-$install_cmd}"
      echo "prepare: installing dependencies in $install_dir" >&2
      (cd "$install_dir" && $install_cmd) >&2 \
        || die "prepare: dependency install failed in $install_dir ($install_cmd)"
    fi
    mkdir -p "$(dirname "$stamp")"
    touch "$stamp"
}

_prepare_expected_head() { # <linked-worktree> <immutable commit>
    local target="$1" expected="$2" current stamp
    [ -n "$expected" ] || return 0
    case "$expected" in *[!0-9a-fA-F]*) die "prepare: --head must be a full hexadecimal commit id" ;; esac
    [ "${#expected}" -eq 40 ] || [ "${#expected}" -eq 64 ] \
      || die "prepare: --head must be a full hexadecimal commit id"
    expected=$(git -C "$target" rev-parse --verify "$expected^{commit}" 2>/dev/null) \
      || die "prepare: immutable head is not available after fetch: $expected"
    current=$(git -C "$target" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
      || die "prepare: could not resolve current worktree HEAD"
    [ "$current" != "$expected" ] || return 0
    git -C "$target" diff --quiet && git -C "$target" diff --cached --quiet \
      || die "prepare: worktree has tracked changes and cannot advance safely to immutable head $expected"
    git -C "$target" merge-base --is-ancestor "$current" "$expected" >/dev/null 2>&1 \
      || die "prepare: worktree HEAD $current cannot fast-forward to immutable head $expected"
    git -C "$target" merge --quiet --ff-only "$expected" >&2 \
      || die "prepare: could not fast-forward worktree to immutable head $expected"
    [ "$(git -C "$target" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" = "$expected" ] \
      || die "prepare: worktree did not reach immutable head $expected"
    # The checkout moved outside the implementation lane. Re-run the normal
    # dependency preparation in case the pushed commit changed a manifest or
    # lockfile; this stamp is derived worktree state, never source state.
    stamp=$(git -C "$target" rev-parse --git-path loom-dependencies-ready 2>/dev/null) \
      || die "prepare: could not resolve dependency state for $target"
    rm -f "$stamp"
}

cmd_prepare() {
    local repo="" ticket="" key="" branch="" base="" reuse="" head=""
    while [ $# -gt 0 ]; do case "$1" in
      --repo) repo="${2:-}"; shift 2;; --ticket) ticket="${2:-}"; shift 2;;
      --key) key="${2:-}"; shift 2;;
      --branch) branch="${2:-}"; shift 2;; --base) base="${2:-}"; shift 2;;
      --reuse) reuse="${2:-}"; shift 2;; --head) head="${2:-}"; shift 2;;
      *) die "prepare: unknown argument '$1'";;
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
      [ -z "$head" ] || git -C "$repo" fetch --quiet origin \
        || die "prepare: fetch origin failed"
      _prepare_expected_head "$reuse" "$head"
      _prepare_local_metadata "$repo" "$reuse"
      _prepare_dependencies "$reuse"
      printf '%s\n' "$(cd "$reuse" && pwd -P)"; return 0
    fi

    local target custom
    target="$repo/.worktrees/$key"
    case "$target" in "$repo/.worktrees/"*) ;; *) die "prepare: target escaped the managed .worktrees directory";; esac
    _ensure_local_exclude "$repo" '/.worktrees/'
    mkdir -p "$repo/.worktrees"
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
    _prepare_expected_head "$target" "$head"
    _prepare_local_metadata "$repo" "$target"
    if [ -f "$repo/.env" ] && [ ! -e "$target/.env" ]; then cp "$repo/.env" "$target/.env"; fi
    _prepare_dependencies "$target"
    printf '%s\n' "$(cd "$target" && pwd -P)"
}

case "${1:-}" in
  prepare) shift; cmd_prepare "$@";;
  *) die "usage: worktree.sh prepare --repo <abs> (--ticket <iid>|--key <slug>) [--branch <name>] [--base <name>] [--reuse <abs>] [--head <commit>]";;
esac
