#!/usr/bin/env bash
# Immutable Loom runtime releases and the stable scheduler dispatcher.

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
RUNTIME_HOME="${LOOM_RUNTIME_HOME:-$HOME/.loom/runtime}"
RELEASES="$RUNTIME_HOME/releases"
ACTIVE="${LOOM_RUNTIME_SELECTOR:-$RUNTIME_HOME/active}"
BIN="$RUNTIME_HOME/bin/loom-runtime"
BIN_RELEASE="$RUNTIME_HOME/bin/loom-runtime.release"
STORE="$RUNTIME_HOME/store.git"
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
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ ! -L "$dir/.loom-release" ] && [ ! -L "$dir/.validated" ] \
      && [ "$(sed -n 's/^tree //p' "$dir/.loom-release" 2>/dev/null)" = "$1" ] \
      && [ "$(cat "$dir/.validated" 2>/dev/null)" = "$1" ] \
      && [ -x "$dir/scripts/tick.sh" ] && [ -x "$dir/scripts/runtime.sh" ]
}

release_verified() { # <id>
    local dir commit tree
    release_complete "$1" || die "release '$1' is missing or incomplete"
    [ -d "$STORE" ] && [ ! -L "$STORE" ] \
      && [ "$(git -C "$STORE" rev-parse --is-bare-repository 2>/dev/null)" = true ] \
      || die "retained runtime object store is missing or untrusted: $STORE"
    dir=$(release_path "$1")
    commit=$(sed -n 's/^commit //p' "$dir/.loom-release")
    valid_release "$commit" || die "release '$1' has an invalid commit identity"
    tree=$(git -C "$STORE" rev-parse --verify "$commit^{tree}" 2>/dev/null) \
      || die "release '$1' commit is unavailable from retained runtime objects"
    [ "$tree" = "$1" ] || die "release '$1' commit names tree '$tree'"
    verify_exact_tree "$STORE" "$commit" "$dir" published
}

write_active() { # <current> <previous>
    local tmp="${ACTIVE%/*}/.active.$$"
    valid_release "$1" || die "refusing invalid current release '$1'"
    release_verified "$1"
    if [ -n "${2:-}" ]; then
        valid_release "$2" || die "refusing invalid previous release '$2'"
        release_verified "$2"
    fi
    { printf 'current %s\n' "$1"; [ -z "${2:-}" ] || printf 'previous %s\n' "$2"; } > "$tmp"
    mv -f "$tmp" "$ACTIVE"
}

lock_acquire() {
    local owner
    mkdir -p "$RUNTIME_HOME" "$RELEASES" "$RUNTIME_HOME/bin" "${ACTIVE%/*}"
    [ ! -L "$RUNTIME_HOME" ] && [ ! -L "$RELEASES" ] && [ ! -L "$RUNTIME_HOME/bin" ] \
      && [ ! -L "${ACTIVE%/*}" ] \
      || die "runtime storage must not traverse symbolic links"
    if ! mkdir "$LOCK" 2>/dev/null; then
        owner=$(cat "$LOCK/pid" 2>/dev/null || true)
        case "$owner" in
            ''|*[!0-9]*) die "publication lock has no trustworthy owner; retry after the current publisher finishes" ;;
            *) kill -0 "$owner" 2>/dev/null && die "publication is already running as pid $owner" ;;
        esac
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

export_tree() { # <source> <commit> <empty-destination>
    local source="$1" commit="$2" dir="$3" record meta path mode type object parent
    while IFS= read -r -d '' record; do
        meta="${record%%$'\t'*}"; path="${record#*$'\t'}"
        set -- $meta; mode="$1" type="$2" object="$3"
        case "$path" in
            ''|/*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|.loom-release|.validated)
                die "release tree contains an unsafe path '$path'" ;;
        esac
        [ "$type" = blob ] || die "release tree contains unsupported entry '$path'"
        parent=$(dirname "$dir/$path")
        mkdir -p "$parent" || die "cannot create release directory for '$path'"
        git -C "$source" cat-file blob "$object" > "$dir/$path" \
          || die "cannot materialize committed blob '$path'"
        case "$mode" in
            100755) chmod 755 "$dir/$path" ;;
            100644) chmod 644 "$dir/$path" ;;
            *) die "release tree contains unsupported mode $mode at '$path'" ;;
        esac
    done < <(git -C "$source" ls-tree -r -z "$commit")
}

verify_exact_tree() { # <source> <commit> <export> [published]
    local source="$1" commit="$2" dir="$3" published="${4:-}" record meta path mode type object actual count=0 files dirs expected_dirs links nodes
    links=$(find "$dir" -type l -print) || die "cannot traverse committed export"
    [ -z "$links" ] || die "committed export contains a symbolic link"
    nodes=$(find "$dir" ! -type f ! -type d -print) \
      || die "cannot traverse committed export"
    [ -z "$nodes" ] || die "committed export contains an unexpected special node"
    while IFS= read -r -d '' record; do
        meta="${record%%$'\t'*}"; path="${record#*$'\t'}"
        set -- $meta; mode="$1" type="$2" object="$3"
        [ "$type" = blob ] || die "release tree contains unsupported entry '$path'"
        case "$path" in
            ''|/*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|.loom-release|.validated)
                die "release tree contains an unsafe path '$path'" ;;
        esac
        [ ! -L "$dir/$path" ] && [ -f "$dir/$path" ] || die "committed export omitted '$path'"
        actual=$(git hash-object --no-filters "$dir/$path")
        [ "$actual" = "$object" ] || die "committed export transformed '$path'"
        case "$mode" in
            100755) [ -x "$dir/$path" ] || die "committed export lost executable mode for '$path'" ;;
            100644) [ ! -x "$dir/$path" ] || die "committed export added executable mode for '$path'" ;;
            *) die "release tree contains unsupported mode $mode at '$path'" ;;
        esac
        count=$((count + 1))
    done < <(git -C "$source" ls-tree -r -z "$commit")
    files=$(find "$dir" -type f -print0 | tr -cd '\000' | wc -c | tr -d ' ') \
      || die "cannot count committed export files"
    dirs=$(find "$dir" -type d -print0 | tr -cd '\000' | wc -c | tr -d ' ') \
      || die "cannot count committed export directories"
    expected_dirs=$(git -C "$source" ls-tree -r -d -z "$commit" | tr -cd '\000' | wc -c | tr -d ' ') \
      || die "cannot count committed tree directories"
    expected_dirs=$((expected_dirs + 1))
    [ "$dirs" = "$expected_dirs" ] || die "committed export contains an unexpected directory"
    [ "$published" != published ] || count=$((count + 2))
    [ "$files" = "$count" ] || die "committed export contains an unexpected file"
}

retain_commit() { # <source> <commit>
    local source="$1" commit="$2" tmp
    if [ ! -e "$STORE" ]; then
        tmp="$RUNTIME_HOME/.store.$$"
        git init --bare -q "$tmp" || die "cannot initialize retained runtime objects"
        mv "$tmp" "$STORE"
    fi
    [ -d "$STORE" ] && [ ! -L "$STORE" ] \
      && [ "$(git -C "$STORE" rev-parse --is-bare-repository 2>/dev/null)" = true ] \
      || die "retained runtime object store is missing or untrusted: $STORE"
    git -C "$STORE" fetch -q "$source" \
      "$commit:refs/loom-runtime/$commit" \
      || die "cannot retain committed runtime objects for '$commit'"
}

on_signal() {
    local rc="$1"
    cleanup
    trap - EXIT INT TERM
    exit "$rc"
}

check_tree() { # <staging>
    local dir="$1" f
    for f in SKILL.md runtime-abi scripts/tick.sh scripts/lane.sh scripts/agent.sh scripts/runtime.sh scripts/tick-test.sh; do
        [ -f "$dir/$f" ] || die "release is missing $f"
    done
    [ "$(wc -l < "$dir/runtime-abi" | tr -d ' ')" = 1 ] \
      && grep -Eq '^host_state_api [1-9][0-9]*$' "$dir/runtime-abi" \
      || die "release has an invalid runtime-abi"
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

compatible_with_active() { # <staging-or-release> [allow-migration]
    local target="$1" allow_migration="${2:-0}" current old_api new_api
    current=$(active_value current 2>/dev/null || true)
    [ -n "$current" ] || return 0
    release_verified "$current"
    old_api=$(sed -n 's/^host_state_api //p' "$RELEASES/$current/runtime-abi")
    new_api=$(sed -n 's/^host_state_api //p' "$target/runtime-abi")
    [ "$old_api" = "$new_api" ] && return 0
    [ "$allow_migration" = 1 ] \
      || die "runtime state API differs from the active release; publish --migrate at a stopped/drained boundary"
    require_stopped_drained_boundary "runtime state API migration"
}

require_stopped_drained_boundary() { # <reason>
    local reason="$1" f lanes="$LOOM_HOME/lanes" queue="$LOOM_HOME/lane-launch-queue"
    [ -n "${LOOM_HOME:-}" ] || die "$reason requires LOOM_HOME for the stopped/drained check"
    [ "${LOOM_RUNTIME_CUTOVER_UNARMED:-}" = 1 ] \
      || die "$reason must run through 'tick.sh runtime publish' to verify the scheduler is unloaded"
    [ -f "$LOOM_HOME/loop.stopped" ] && [ ! -L "$LOOM_HOME/loop.stopped" ] \
      || die "$reason requires a stopped build"
    if [ -e "$lanes" ] || [ -L "$lanes" ]; then
        [ -d "$lanes" ] && [ ! -L "$lanes" ] && [ -r "$lanes" ] && [ -x "$lanes" ] \
          || die "$reason cannot prove lane metadata is drained"
        for f in "$lanes"/*.pid; do
            [ ! -e "$f" ] && [ ! -L "$f" ] && continue
            die "$reason requires all lane metadata to be drained"
        done
    fi
    if [ -e "$LOOM_HOME/tick.lock.d" ] || [ -L "$LOOM_HOME/tick.lock.d" ]; then
        die "$reason requires the scheduling wave to be drained"
    fi
    if [ -e "$queue" ] || [ -L "$queue" ]; then
        [ -d "$queue" ] && [ ! -L "$queue" ] && [ -r "$queue" ] && [ -x "$queue" ] \
          || die "$reason cannot prove deferred launches are drained"
        for f in "$queue"/request-* "$queue"/launching-*; do
            [ ! -e "$f" ] && [ ! -L "$f" ] && continue
            die "$reason requires deferred launches to be drained"
        done
    fi
}

cmd_publish() { # [--migrate] [git-ref]
    local source="${LOOM_RUNTIME_SOURCE:-$(cd "${SELF%/*}/.." 2>/dev/null && pwd)}"
    local migrate=0 ref commit tree dir current="" previous="" loader_tmp
    if [ "${1:-}" = --migrate ]; then migrate=1; shift; fi
    [ $# -le 1 ] || die "publish takes [--migrate] [git-ref]"
    ref="${1:-HEAD}"
    [ -d "$source/.git" ] || git -C "$source" rev-parse --git-dir >/dev/null 2>&1 \
      || die "source '$source' is not a Git checkout"
    source=$(cd "$source" && pwd -P)
    [ -z "$(git -C "$source" status --porcelain 2>/dev/null)" ] \
      || die "source checkout is dirty; publish a committed tree"
    commit=$(git -C "$source" rev-parse --verify "$ref^{commit}" 2>/dev/null) \
      || die "cannot resolve committed ref '$ref'"
    tree=$(git -C "$source" rev-parse --verify "$commit^{tree}" 2>/dev/null) \
      || die "cannot resolve tree for '$commit'"
    valid_release "$tree" || die "unexpected Git tree id '$tree'"
    [ -z "$(git -C "$source" ls-tree -r "$commit" | awk '$1 == "120000" || $1 == "160000" { print; exit }')" ] \
      || die "release tree contains a symbolic link or submodule"
    lock_acquire
    trap cleanup EXIT
    trap 'on_signal 130' INT
    trap 'on_signal 143' TERM
    current=$(active_value current 2>/dev/null || true)
    [ -n "$current" ] || require_stopped_drained_boundary "first publication"
    dir="$RELEASES/$tree"
    if ! release_complete "$tree"; then
        [ ! -e "$dir" ] || die "release path exists but is incomplete: $dir"
        STAGING=$(mktemp -d "$RELEASES/.staging.XXXXXX") || die "cannot create release staging directory"
        export_tree "$source" "$commit" "$STAGING"
        verify_exact_tree "$source" "$commit" "$STAGING"
        validate_tree "$STAGING"
        rm -rf "$STAGING"
        STAGING=$(mktemp -d "$RELEASES/.staging.XXXXXX") || die "cannot create final release staging directory"
        export_tree "$source" "$commit" "$STAGING"
        verify_exact_tree "$source" "$commit" "$STAGING"
        check_tree "$STAGING"
        retain_commit "$source" "$commit"
        cat "$STAGING/runtime-abi" > "$STAGING/.loom-release"
        printf 'tree %s\ncommit %s\n' "$tree" "$commit" >> "$STAGING/.loom-release"
        printf '%s\n' "$tree" > "$STAGING/.validated"
        chmod -R a-w "$STAGING"
        mv "$STAGING" "$dir"
        STAGING=""
    fi
    git -C "$STORE" cat-file -e "$commit^{commit}" 2>/dev/null \
      || retain_commit "$source" "$commit"
    release_verified "$tree"
    if [ ! -e "$BIN" ] && [ ! -e "$BIN_RELEASE" ]; then
        printf '%s\n' "$tree" > "$BIN_RELEASE.tmp.$$"
        mv "$BIN_RELEASE.tmp.$$" "$BIN_RELEASE"
    fi
    if [ ! -e "$BIN" ] && [ -f "$BIN_RELEASE" ] && [ ! -L "$BIN_RELEASE" ]; then
        local recorded_loader=""
        recorded_loader=$(cat "$BIN_RELEASE" 2>/dev/null || true)
        valid_release "$recorded_loader" || die "stable launcher identity is invalid: $BIN_RELEASE"
        release_verified "$recorded_loader" \
          || die "stable launcher identity is invalid: $BIN_RELEASE"
        loader_tmp="$RUNTIME_HOME/bin/.loom-runtime.$$"
        cp "$RELEASES/$recorded_loader/scripts/runtime.sh" "$loader_tmp"
        chmod 755 "$loader_tmp"
        mv "$loader_tmp" "$BIN"
    fi
    local loader_release=""
    loader_release=$(cat "$BIN_RELEASE" 2>/dev/null || true)
    [ -f "$BIN_RELEASE" ] && [ ! -L "$BIN_RELEASE" ] \
      && valid_release "$loader_release" \
      && [ -f "$BIN" ] && [ ! -L "$BIN" ] && [ -x "$BIN" ] \
      && cmp -s "$BIN" "$RELEASES/$loader_release/scripts/runtime.sh" \
      || die "stable launcher is missing, untrusted, or modified: $BIN"
    release_verified "$loader_release"
    current=$(active_value current 2>/dev/null || true)
    previous=$(active_value previous 2>/dev/null || true)
    if [ "$current" != "$tree" ]; then previous="$current"; fi
    compatible_with_active "$dir" "$migrate"
    write_active "$tree" "$previous"
    echo "loom-runtime: published ${current:-none} -> $tree"
    echo "loom-runtime: future heartbeats use $tree; running lanes remain pinned"
    cleanup; trap - EXIT INT TERM
}

cmd_rollback() {
    local current previous
    lock_acquire
    trap cleanup EXIT
    trap 'on_signal 130' INT
    trap 'on_signal 143' TERM
    current=$(active_value current 2>/dev/null || true)
    previous=$(active_value previous 2>/dev/null || true)
    [ -n "$current" ] && [ -n "$previous" ] || die "no previous release is available"
    release_verified "$current"
    release_verified "$previous"
    compatible_with_active "$RELEASES/$previous" 0
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
        for f in "$LOOM_HOME"/lane-launch-queue/request-*/runtime-release \
                 "$LOOM_HOME"/lane-launch-queue/launching-*/runtime-release; do
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
    valid_release "$release" || die "selected release '${release:-none}' is invalid"
    release_verified "$release"
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
    *) die "usage: loom-runtime publish [--migrate] [git-ref] | rollback | status | run [--release <id>] -- <entry> [args...]" ;;
esac
