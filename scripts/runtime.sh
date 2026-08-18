#!/usr/bin/env bash
# Immutable Loom runtime releases and the stable scheduler dispatcher.

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
RUNTIME_HOME="${LOOM_RUNTIME_HOME:-$HOME/.loom/runtime}"
RELEASES="$RUNTIME_HOME/releases"
ACTIVE="${LOOM_RUNTIME_SELECTOR:-$RUNTIME_HOME/active}"
BIN="$RUNTIME_HOME/bin/loom-runtime"
LOCK="$RUNTIME_HOME/publish.lock"
STAGING=""
LOCKED=""

die() { echo "loom-runtime: $*" >&2; exit 1; }

valid_release() {
    [ "${#1}" -eq 40 ] || return 1
    case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

active_value() { # current|previous
    [ -f "$ACTIVE" ] || return 1
    awk -v key="$1" '$1 == key { print $2; exit }' "$ACTIVE"
}

release_path() { # <id>
    valid_release "$1" || return 1
    printf '%s\n' "$RELEASES/$1"
}

release_complete() { # <id>
    local dir
    dir=$(release_path "$1") || return 1
    [ -d "$dir" ] && [ "$(sed -n 's/^tree //p' "$dir/.loom-release" 2>/dev/null)" = "$1" ] \
      && [ "$(cat "$dir/.validated" 2>/dev/null)" = "$1" ] \
      && [ -x "$dir/scripts/tick.sh" ] && [ -x "$dir/scripts/runtime.sh" ]
}

write_active() { # <current> <previous>
    local tmp="$RUNTIME_HOME/.active.$$"
    valid_release "$1" && release_complete "$1" || die "refusing incomplete current release '$1'"
    if [ -n "${2:-}" ]; then
        valid_release "$2" && release_complete "$2" || die "refusing incomplete previous release '$2'"
    fi
    { printf 'schema 1\ncurrent %s\n' "$1"; [ -z "${2:-}" ] || printf 'previous %s\n' "$2"; } > "$tmp"
    mv -f "$tmp" "$ACTIVE"
}

lock_acquire() {
    local owner
    mkdir -p "$RUNTIME_HOME" "$RELEASES" "$RUNTIME_HOME/bin" "${ACTIVE%/*}"
    [ ! -L "$RUNTIME_HOME" ] && [ ! -L "$RELEASES" ] && [ ! -L "${ACTIVE%/*}" ] \
      || die "runtime storage must not traverse symbolic links"
    if ! mkdir "$LOCK" 2>/dev/null; then
        owner=$(cat "$LOCK/pid" 2>/dev/null || true)
        case "$owner" in ''|*[!0-9]*) ;; *) kill -0 "$owner" 2>/dev/null && die "publication is already running as pid $owner" ;; esac
        rm -f "$LOCK/pid" 2>/dev/null || true
        rmdir "$LOCK" 2>/dev/null || die "cannot recover stale publication lock"
        mkdir "$LOCK" || die "cannot acquire publication lock"
    fi
    printf '%s\n' "$$" > "$LOCK/pid"
    LOCKED=1
}

cleanup() {
    if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then chmod -R u+w "$STAGING" 2>/dev/null || true; rm -rf "$STAGING"; fi
    if [ -n "$LOCKED" ]; then rm -f "$LOCK/pid" 2>/dev/null || true; rmdir "$LOCK" 2>/dev/null || true; fi
}

check_tree() { # <staging>
    local dir="$1" f
    for f in SKILL.md scripts/tick.sh scripts/lane.sh scripts/agent.sh scripts/runtime.sh scripts/tick-test.sh; do
        [ -f "$dir/$f" ] || die "release is missing $f"
    done
    [ -z "$(find "$dir" -type l -print -quit)" ] || die "release contains a symbolic link"
    while IFS= read -r f; do bash -n "$f" || die "shell syntax failed: ${f#$dir/}"; done \
      < <(find "$dir" -type f -name '*.sh' | sort)
}

validate_tree() { # <staging>
    check_tree "$1"
    ( cd "$1" && LOOM_RUNTIME_VALIDATING=1 scripts/tick-test.sh --lint ) \
      || die "release test lint failed"
    ( cd "$1" && LOOM_RUNTIME_VALIDATING=1 scripts/tick-test.sh ) \
      || die "release test suite failed"
}

live_release_state() {
    [ -n "${LOOM_HOME:-}" ] || return 1
    find "$LOOM_HOME/lanes" -maxdepth 1 -type f -name '*.release' -print -quit 2>/dev/null | grep -q . \
      || find "$LOOM_HOME/lane-launch-queue" -mindepth 2 -maxdepth 2 -type f -name runtime-release -print -quit 2>/dev/null | grep -q .
}

compatible_with_active() { # <staging-or-release>
    local target="$1" current old_api new_api
    current=$(active_value current 2>/dev/null || true)
    [ -n "$current" ] && release_complete "$current" || return 0
    old_api=$(sed -n 's/^host_state_api //p' "$RELEASES/$current/.loom-release")
    new_api=$(sed -n 's/^host_state_api //p' "$target/.loom-release")
    [ "$old_api" = "$new_api" ] || ! live_release_state \
      || die "runtime state API changed while lanes or queued launches still reference the old release"
}

require_initial_cutover_boundary() {
    [ -n "${LOOM_HOME:-}" ] || die "first publication requires LOOM_HOME for the stopped/drained check"
    [ -f "$LOOM_HOME/loop.stopped" ] || die "first publication requires a stopped build"
    ! find "$LOOM_HOME/lanes" -maxdepth 1 -type f -name '*.pid' -print -quit 2>/dev/null | grep -q . \
      || die "first publication requires all lane metadata to be drained"
    ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
        \( -name 'request-*' -o -name 'launching-*' \) -print -quit 2>/dev/null | grep -q . \
      || die "first publication requires deferred launches to be drained"
}

cmd_publish() { # [git-ref]
    local source="${LOOM_RUNTIME_SOURCE:-$(cd "${SELF%/*}/.." 2>/dev/null && pwd)}"
    local ref="${1:-HEAD}" commit tree dir current="" previous="" loader_tmp
    [ -d "$source/.git" ] || git -C "$source" rev-parse --git-dir >/dev/null 2>&1 \
      || die "source '$source' is not a Git checkout"
    [ -z "$(git -C "$source" status --porcelain 2>/dev/null)" ] \
      || die "source checkout is dirty; publish a committed tree"
    commit=$(git -C "$source" rev-parse --verify "$ref^{commit}" 2>/dev/null) \
      || die "cannot resolve committed ref '$ref'"
    tree=$(git -C "$source" rev-parse --verify "$commit^{tree}" 2>/dev/null) \
      || die "cannot resolve tree for '$commit'"
    valid_release "$tree" || die "unexpected Git tree id '$tree'"
    [ -z "$(git -C "$source" ls-tree -r "$commit" | awk '$1 == "120000" || $1 == "160000" { print; exit }')" ] \
      || die "release tree contains a symbolic link or submodule"
    current=$(active_value current 2>/dev/null || true)
    [ -n "$current" ] || require_initial_cutover_boundary
    lock_acquire
    trap cleanup EXIT INT TERM
    dir="$RELEASES/$tree"
    if ! release_complete "$tree"; then
        [ ! -e "$dir" ] || die "release path exists but is incomplete: $dir"
        STAGING=$(mktemp -d "$RELEASES/.staging.XXXXXX") || die "cannot create release staging directory"
        git -C "$source" archive "$commit" | tar -x -C "$STAGING" \
          || die "cannot export committed Loom tree"
        validate_tree "$STAGING"
        rm -rf "$STAGING"
        STAGING=$(mktemp -d "$RELEASES/.staging.XXXXXX") || die "cannot create final release staging directory"
        git -C "$source" archive "$commit" | tar -x -C "$STAGING" \
          || die "cannot re-export validated Loom tree"
        check_tree "$STAGING"
        printf 'schema 1\nloader_schema 1\nhost_state_api 1\nbroker_api 1\ntree %s\ncommit %s\n' \
          "$tree" "$commit" > "$STAGING/.loom-release"
        printf '%s\n' "$tree" > "$STAGING/.validated"
        compatible_with_active "$STAGING"
        chmod -R a-w "$STAGING"
        mv "$STAGING" "$dir"
        STAGING=""
    fi
    loader_tmp="$RUNTIME_HOME/bin/.loom-runtime.$$"
    cp "$dir/scripts/runtime.sh" "$loader_tmp"
    chmod 755 "$loader_tmp"
    mv -f "$loader_tmp" "$BIN"
    current=$(active_value current 2>/dev/null || true)
    previous=$(active_value previous 2>/dev/null || true)
    if [ "$current" != "$tree" ]; then previous="$current"; fi
    write_active "$tree" "$previous"
    echo "loom-runtime: published ${current:-none} -> $tree"
    echo "loom-runtime: future heartbeats use $tree; running lanes remain pinned"
    cleanup; trap - EXIT INT TERM
}

cmd_rollback() {
    local current previous
    lock_acquire
    trap cleanup EXIT INT TERM
    current=$(active_value current 2>/dev/null || true)
    previous=$(active_value previous 2>/dev/null || true)
    [ -n "$current" ] && [ -n "$previous" ] || die "no previous release is available"
    write_active "$previous" "$current"
    echo "loom-runtime: rolled back $current -> $previous"
    cleanup; trap - EXIT INT TERM
}

cmd_status() {
    local current previous f id
    current=$(active_value current 2>/dev/null || true)
    previous=$(active_value previous 2>/dev/null || true)
    echo "active: ${current:-none}"
    echo "previous: ${previous:-none}"
    echo "launcher: $BIN"
    echo "selector: $ACTIVE"
    if [ -n "${LOOM_HOME:-}" ]; then
        for f in "$LOOM_HOME"/lanes/*.release; do
            [ -f "$f" ] || continue
            id="${f##*/}"; id="${id%.release}"
            echo "lane $id: $(cat "$f" 2>/dev/null || echo unreadable)"
        done
        for f in "$LOOM_HOME"/lane-launch-queue/request-*/runtime-release; do
            [ -f "$f" ] || continue
            echo "queued ${f%/runtime-release}: $(cat "$f" 2>/dev/null || echo unreadable)"
        done
    fi
}

cmd_run() {
    local release="" entry dir script
    if [ "${1:-}" = --release ]; then release="${2:-}"; shift 2; fi
    [ "${1:-}" = -- ] || die "run requires -- before the entry name"
    shift
    entry="${1:-}"; [ $# -gt 0 ] && shift
    [ -n "$release" ] || release=$(active_value current 2>/dev/null || true)
    valid_release "$release" && release_complete "$release" \
      || die "selected release '${release:-none}' is missing or incomplete"
    case "$entry" in
        tick) script=tick.sh ;; lane) script=lane.sh ;; agent) script=agent.sh ;;
        watch) script=watch-panes.sh ;; bootstrap) script=bootstrap.sh ;; worktree) script=worktree.sh ;;
        *) die "run entry must be tick|lane|agent|watch|bootstrap|worktree" ;;
    esac
    dir="$RELEASES/$release"
    [ -x "$dir/scripts/$script" ] || die "release $release has no executable $script"
    export LOOM_RUNTIME_HOME="$RUNTIME_HOME"
    export LOOM_RUNTIME_RELEASE="$release"
    export LOOM_RUNTIME_ROOT="$dir"
    export LOOM_RUNTIME_LAUNCHER="$BIN"
    exec "$dir/scripts/$script" "$@"
}

case "${1:-}" in
    publish) shift; cmd_publish "$@" ;;
    rollback) shift; [ $# -eq 0 ] || die "rollback takes no arguments"; cmd_rollback ;;
    status) shift; [ $# -eq 0 ] || die "status takes no arguments"; cmd_status ;;
    run) shift; cmd_run "$@" ;;
    *) die "usage: loom-runtime publish [git-ref] | rollback | status | run [--release <id>] -- <entry> [args...]" ;;
esac
