#!/usr/bin/env bash
# Loom one-time setup (P22).
#
# The WRITE half of the skill's plumbing, deliberately split from tick.sh.
# tick.sh is read-only by charter — the wave re-runs it constantly and a
# mutating call there would be unsafe to repeat — and tick-test.sh enforces
# that by scanning captured argv for mutating verbs. Setup genuinely must
# write, so it lives here instead of eroding that guarantee.
#
# Everything is idempotent: run it as many times as you like. Nothing is ever
# deleted, and nothing already present is overwritten without --force.
#
# Subcommands:
#   global-config       seed ~/.loom/config.yml if absent
#   labels              create the five missing ticket-state labels
#   settings            write .claude/settings.json (delegates to tick.sh)
#   all                 all three, in dependency order
#
# Test seams (env): LOOM_REPO, LOOM_GLOBAL_CONFIG, GLAB_CMD.
set -euo pipefail

REPO_ROOT="${LOOM_REPO:-$PWD}"
GLOBAL_CONFIG="${LOOM_GLOBAL_CONFIG:-$HOME/.loom/config.yml}"
GLAB_CMD="${GLAB_CMD:-glab}"
TICK="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/tick.sh"

# P73: `die` was written a third time here. It lives in lib.sh beside this
# script now, with the rest of the derivations both halves share.
LIB_SH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib.sh"
[ -f "$LIB_SH" ] \
    || { echo "bootstrap.sh: $LIB_SH is missing — it holds the shared derivations and ships beside bootstrap.sh" >&2; exit 1; }
. "$LIB_SH"
DIE_RC=1

# REPO_ROOT falls back to $PWD, so every repo-scoped write must first prove it
# is pointed at a repo ROOT, not merely somewhere inside one. Without this,
# running the script from $HOME wrote ~/.claude/settings.json — the human's
# own Claude Code configuration — because the only git check happened AFTER
# the write and merely warned. `rev-parse --git-dir` proves "inside a repo"
# and searches upward, so it also passes from a subdirectory (writing an
# allowlist nothing reads) and from a $HOME that itself has a stray `.git`
# (writing loom's allowlist as everyone's global default) — `--show-toplevel`
# is the check that actually answers "is this the root". Machine-scoped setup
# (global-config) does not need a repo and does not call this.
_require_repo() { # <what>
    local toplevel
    toplevel="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" \
        || die "$1: '$REPO_ROOT' is not a git repository. Run this from the repo,
  or set LOOM_REPO. Refusing to write repo files into a directory that is not
  one (from \$HOME this would target your personal ~/.claude/settings.json)."
    [ "$(cd "$REPO_ROOT" && pwd -P)" = "$toplevel" ] \
        || die "$1: '$REPO_ROOT' is inside a git repository but is not its root
  ($toplevel). Run this from the repo root, or set LOOM_REPO to it. Refusing
  to write repo files somewhere nothing reads them from."
}

# The ticket state machine, as SKILL.md defines it. `closed` is a tracker
# state, not a label, and `build-N` is minted per build by the build verb —
# neither belongs here.
# Fields are `|`-separated, NOT `:`-separated: P31's escalation labels are
# GitLab scoped labels (`model::opus`), whose names contain the colon — read
# with IFS=':' they split as name "model", colour "", and the rest of the line
# as the description, and every one of them would be created wrong.
LABELS="ready-for-agent|#428BCA|queued and unblocked, free for any lane to claim
in-progress|#5CB85C|claimed by a lane, implementation under way
review|#F0AD4E|MR open, waiting on its gate verdict
merge-queue|#8E44AD|gate passed, waiting for the single-writer merge step
blocked|#D9534F|needs a human decision — see the blocked report comment
fix|#E67E22|defect ticket filed mid-build (probe or lane) — outranks the rest of the ready set
model::opus|#6C3483|P31: run this ticket's next implementation lane on opus (outranks rework_model and lane_model)
model::fable|#7D3C98|P31: run this ticket's next implementation lane on fable
model::sonnet|#5499C7|P31: pin this ticket's next implementation lane to sonnet
model::haiku|#48C9B0|P31: pin this ticket's next implementation lane to haiku"

cmd_global_config() { # global-config [--force]
    local force=0; [ "${1:-}" = "--force" ] && force=1
    if [ -f "$GLOBAL_CONFIG" ] && [ "$force" -eq 0 ]; then
        echo "global-config: already present — $GLOBAL_CONFIG"; return 0
    fi
    mkdir -p "$(dirname "$GLOBAL_CONFIG")"
    cat > "$GLOBAL_CONFIG" <<'EOF'
# Loom global preferences — machine- and person-level, shared by every
# repo. Read-only input, never build state. A repo's .loom.yml
# overrides anything here; see references/loom-config.md for the full
# repo > derived > global > default chain, and `tick.sh resolve-config` to see
# what any repo actually resolves to.

max_lanes: 4                    # 1-6; each lane is a full worktree
rejection_cap: 3                # gate rejections before a ticket is blocked
crash_cap: 2                    # implementer crashes before blocked (not rejections)
heartbeat_stale_minutes: 30     # PID alive but log silent this long = wedged
usage_limit: pause_and_resume   # pause_and_resume | stop_and_wait | downshift_model

ntfy:
  # Per-repo topic, derived as <topic_prefix><repo-name>. Keep the prefix
  # unguessable: a public topic anyone can post to is a prompt-injection path
  # straight into the wave.
  topic_prefix: ""
  # One line, always: the reader takes the first `push:` line and stops, so a
  # wrapped list silently drops its tail.
  push: [build_complete, build_halted, ticket_blocked, workspace_untrusted, build_unarmed]
EOF
    echo "global-config: wrote $GLOBAL_CONFIG"
    [ -n "$(sed -nE 's/^[[:space:]]*topic_prefix:[[:space:]]*"?([^"#]*)"?.*/\1/p' "$GLOBAL_CONFIG" | xargs)" ] \
        || echo "global-config: set ntfy.topic_prefix to an unguessable value before enabling pushes" >&2
    return 0
}

cmd_labels() { # labels [--dry-run]
    local dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
    command -v "$GLAB_CMD" >/dev/null 2>&1 || die "labels: '$GLAB_CMD' not found"
    command -v jq >/dev/null 2>&1 || die "labels: jq required"
    _require_repo labels
    # P86: the write half's halt, asked at the verb that actually writes to the
    # tracker, so `bootstrap.sh labels` run on its own is refused too — not only
    # the `all` path above it.
    _require_tracker "$REPO_ROOT" labels >/dev/null
    cd "$REPO_ROOT" || die "labels: cannot cd to $REPO_ROOT"
    local raw existing name color desc created=0 skipped=0
    # One read for the whole set; creating a label that exists is an error on
    # some tiers, so check first rather than create-and-ignore-failure.
    #
    # Read NAMES, exactly, from the API rather than grepping `label list` text.
    # That text includes descriptions, so a pre-existing label described as
    # "waiting on review" made the `review` state label look present: it was
    # never created, bootstrap still exited 0, the sentinel was written, and it
    # was never retried.
    #
    # A failed read must NOT look like an empty tracker. Swallowing the error
    # meant an auth failure or outage produced "no labels exist", so every
    # create was attempted, the first one failed against a tracker that already
    # had it, and bootstrap died on every tick thereafter.
    raw=$("$GLAB_CMD" api --paginate "projects/:id/labels?per_page=100" 2>/dev/null) \
        || die "labels: could not read the existing labels (auth, network, or
  project resolution). Not guessing — the next tick retries."
    existing=$(printf '%s' "$raw" | jq -r 'if type == "array" then .[].name else empty end' 2>/dev/null) \
        || die "labels: label list was not JSON"
    while IFS='|' read -r name color desc; do
        [ -n "$name" ] || continue
        if printf '%s\n' "$existing" | grep -qxF "$name"; then
            skipped=$((skipped+1)); continue
        fi
        if [ "$dry" -eq 1 ]; then
            echo "labels: would create $name"; created=$((created+1)); continue
        fi
        "$GLAB_CMD" label create --name "$name" --color "$color" --description "$desc" >/dev/null \
            || die "labels: failed creating '$name'"
        created=$((created+1))
    done <<EOF
$LABELS
EOF
    # Say what actually happened. A dry run reporting "4 created" is a lie that
    # reads identically to a real run.
    if [ "$dry" -eq 1 ]; then
        echo "labels: would create $created, $skipped already present (dry run — nothing written)"
    else
        echo "labels: $created created, $skipped already present"
    fi
    return 0
}

# `.claude/settings.json` is an artifact whose ENTIRE effect depends on the repo
# root being a trusted workspace — untrusted, Claude Code ignores every allow
# entry in it, so bootstrap would be writing an artifact with no consumer
# (constitution 4). The flag can only be set by a human accepting the dialog, so
# this reports rather than fixes, and the report is a deduped push, not a stderr
# line per tick (P3's fifteen warnings into a log nobody read).
#
# Untrusted is INCOMPLETE, never fatal: everything up to the first merge really
# does work untrusted — build-1 got 77 minutes in before it mattered — so the
# wave must still run. Exiting nonzero is the whole mechanism: tick.sh writes no
# `.bootstrapped` sentinel on failure, so the next tick retries for free and
# picks this up the moment the human accepts. (P30)
_check_trust() { # → 0 trusted or unknowable; 1 untrusted
    [ -x "$TICK" ] || return 0
    LOOM_REPO="$REPO_ROOT" "$TICK" trust-check --notify "$REPO_ROOT" >/dev/null || return 1
    return 0
}

cmd_settings() { # settings [--force]
    [ -x "$TICK" ] || die "settings: tick.sh not found beside this script"
    _require_repo settings
    local rc=0
    LOOM_REPO="$REPO_ROOT" "$TICK" install-settings "$@" || rc=$?
    # A lane's worktree is created from origin/<base>, so an UNCOMMITTED
    # allowlist reaches no lane at all — the file exists in the base clone and
    # nowhere the work actually happens. Committing is the human's call (it is
    # a security surface entering history), so say so rather than doing it.
    if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
       && [ -n "$(git -C "$REPO_ROOT" status --porcelain -- .claude/settings.json 2>/dev/null)" ]; then
        echo "settings: .claude/settings.json is uncommitted — commit it, or lane worktrees (created from origin/<base>) will run without the allowlist" >&2
    fi
    # Report what install-settings actually did. Returning 0 unconditionally
    # made `bootstrap.sh settings` claim success on a refusal.
    return "$rc"
}

# `all` used to discard its arguments entirely, so `bootstrap.sh all --dry-run`
# really created labels and really wrote settings — the exact opposite of what
# the flag promises. Only --dry-run is meaningful here (it belongs to labels);
# anything else is refused rather than silently ignored.
cmd_all() {
    local dry=""
    case "${1:-}" in
        "")         ;;
        --dry-run)  dry="--dry-run" ;;
        *)          die "all: unknown flag '$1' (only --dry-run applies to 'all')" ;;
    esac
    # P86: BEFORE any write, including the machine-scoped one. A repo that has
    # not declared its tracker is a repo no lane can work in, so there is
    # nothing worth setting up in it yet — and `--dry-run` refuses too, because
    # a preview of labels for a tracker nobody named is not a preview of
    # anything.
    _require_tracker "$REPO_ROOT" bootstrap >/dev/null
    if [ -n "$dry" ]; then
        echo "bootstrap: dry run — nothing will be written"
        cmd_labels --dry-run
        return 0
    fi
    cmd_global_config
    # A hand-edited allowlist is a refusal, not a failure — install-settings
    # declines rather than clobbering it. Other failures are swallowed here too;
    # run `bootstrap.sh settings` directly to see the real status.
    cmd_settings || true
    cmd_labels
    # Last, and after the writes: the settings file is written either way, so it
    # is ready the moment trust lands, and the labels above are unaffected by it.
    if ! _check_trust; then
        echo "bootstrap: incomplete — '$REPO_ROOT' is not a trusted workspace, so the
  allowlist just written reaches no lane. Accept the trust prompt there once;
  the next tick retries this automatically." >&2
        return 1
    fi
    echo "bootstrap: done — run 'tick.sh resolve-config' to see the effective config"
}

case "${1:-}" in
    global-config) shift; cmd_global_config "$@" ;;
    labels)        shift; cmd_labels "$@" ;;
    settings)      shift; cmd_settings "$@" ;;
    all)           shift; cmd_all "$@" ;;
    "")            cmd_all ;;
    *) die "usage: bootstrap.sh [all [--dry-run]] | global-config [--force] | labels [--dry-run] | settings [--force]" ;;
esac
