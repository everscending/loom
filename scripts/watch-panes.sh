#!/usr/bin/env bash
# watch-panes.sh — one herdr pane per TICKET, following each of its lanes in
# turn. Human-run convenience, never called by the machinery (P24).
#
# Nothing about a build changes if this is never run, or if herdr is not
# installed: it only reads `tick.sh lanes-alive` and follows files the lanes
# already write. Delete herdr from the machine and the build is unaffected —
# `tick.sh render-log <id> --follow` still works in any terminal.
#
# Pane ownership is durable Herdr metadata. A replacement polling worker
# reconstructs the active lane↔pane map from those tokens, adopts surviving
# followers, and closes only inactive panes bearing this repo's exact token.
# Ticket affinity survives an immediate stage handoff, but an inactive worker
# pane is never kept merely as presentation state: lane logs are the record.
#
# Usage: watch-panes.sh            (foreground polling worker; Ctrl-C to stop)
#        watch-panes.sh off        close every pane and stop the viewer
#        watch-panes.sh on         allow it again, and ensure its controller
#        watch-panes.sh raise      clear switches and ensure its controller
#        watch-panes.sh ticker off|on   just the build-ticker strip
#        WATCH_MAX_PANES=6 watch-panes.sh

set -euo pipefail

TICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tick.sh"
POLL="${WATCH_POLL_SECONDS:-10}"
# Pane cap: sized to the build's real width, not a flat number. `max_lanes`
# caps implementers only — gates/merges/probes run from a separate aux pool —
# so a full frontier is max_lanes impl panes plus an aux lane or two on OTHER
# tickets (a ticket's own gate/merge folds into its impl pane via affinity).
# A flat 4 hid a fifth lane entirely: build-3 wave 2 2026-08-02, 4 impl + 1
# gate live, impl-16 waited at the cap with no trace and the human had to ask.
if [ -n "${WATCH_MAX_PANES:-}" ]; then
    MAX_PANES="$WATCH_MAX_PANES"
else
    _ml=$("$TICK" resolve-config 2>/dev/null | jq -r '.scalars.max_lanes.value // empty' 2>/dev/null || :)
    MAX_PANES=$(( ${_ml:-4} + 2 ))
fi
# Same seam pattern as GLAB_CMD/LAUNCHCTL_CMD: the test suite exercises pane
# lifecycle against a capture stub, never a real herdr.
HERDR="${HERDR_CMD:-herdr}"
ORCH_HOME=$("$TICK" orch-home 2>/dev/null)
WP_PID="$ORCH_HOME/watch-panes.pid"
WP_PID_START="$ORCH_HOME/watch-panes.pid.start"
OWNER_FILE="$ORCH_HOME/watch-panes.owner"
TICKER_OFF="$ORCH_HOME/ticker-off"
VIEWER_OFF="$ORCH_HOME/viewer-off"

# One stable owner per repo state directory. `noclobber` is the portable
# O_EXCL seam available in Bash 3.2: concurrent first launches may generate
# different candidates, but only the process that creates the file wins.
owner_token() {
    if [ -n "${WATCH_OWNER_TOKEN:-}" ]; then
        printf '%s\n' "$WATCH_OWNER_TOKEN"
        return 0
    fi
    if [ ! -s "$OWNER_FILE" ]; then
        mkdir -p "$ORCH_HOME"
        [ ! -e "$OWNER_FILE" ] || rm -f "$OWNER_FILE"
        local token
        token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
        [ -n "$token" ] || token="$(date +%s)-$$-${RANDOM:-0}"
        ( umask 077; set -C; printf '%s\n' "$token" > "$OWNER_FILE" ) 2>/dev/null || :
    fi
    [ -s "$OWNER_FILE" ] || return 1
    sed -n '1p' "$OWNER_FILE"
}

OWNER_TOKEN=$(owner_token) || {
    echo "watch-panes: could not create the repo viewer owner token" >&2
    exit 1
}
WORKSPACE_ID="${HERDR_WORKSPACE_ID:-}"
if [ -z "$WORKSPACE_ID" ]; then
    WORKSPACE_ID="${HERDR_PANE_ID:-}"
    WORKSPACE_ID="${WORKSPACE_ID%%:*}"
fi

viewer_note() { # <message>
    "$TICK" event viewer_note note "$1" >/dev/null 2>&1 || :
    echo "watch-panes: $1" >&2
}

pane_list() {
    [ -n "$WORKSPACE_ID" ] || return 1
    "$HERDR" pane list --workspace "$WORKSPACE_ID" 2>/dev/null
}

pane_list_valid() { # <json>
    printf '%s\n' "$1" | jq -e '.result.panes | type == "array"' >/dev/null 2>&1
}

tag_pane() { # <pane> <role> [lane] [ticket]
    local pane="$1" role="$2" lane="${3:-}" ticket="${4:-}" args=()
    args+=(pane report-metadata "$pane" --source loom-viewer)
    args+=(--token "loom_viewer=$OWNER_TOKEN" --token "loom_role=$role")
    if [ -n "$lane" ]; then args+=(--token "loom_lane=$lane"); else args+=(--clear-token loom_lane); fi
    if [ -n "$ticket" ]; then args+=(--token "loom_ticket=$ticket"); else args+=(--clear-token loom_ticket); fi
    "$HERDR" "${args[@]}" >/dev/null 2>&1
}

owned_role_ids() { # <pane-list-json> <role>; incomplete worker metadata is inert
    printf '%s\n' "$1" | jq -r --arg owner "$OWNER_TOKEN" --arg role "$2" '
        .result.panes[]?
        | select((.pane_id | type) == "string" and (.pane_id | length) > 0)
        | select((.tokens | type) == "object")
        | select(.tokens.loom_viewer == $owner and .tokens.loom_role == $role)
        | select($role != "worker" or
                 ((.tokens.loom_lane | type) == "string" and (.tokens.loom_lane | length) > 0 and
                  (.tokens.loom_ticket | type) == "string" and (.tokens.loom_ticket | length) > 0))
        | .pane_id // empty' 2>/dev/null
}

owned_metadata_valid() { # <pane-list-json>
    printf '%s\n' "$1" | jq -e --arg owner "$OWNER_TOKEN" '
        [.result.panes[]?
         | select((.tokens | type) == "object" and .tokens.loom_viewer == $owner)
         | ((.pane_id | type) == "string" and (.pane_id | length) > 0)
           and ((.tokens.loom_role == "controller" or .tokens.loom_role == "ticker")
                or (.tokens.loom_role == "worker"
                    and (.tokens.loom_lane | type) == "string" and (.tokens.loom_lane | length) > 0
                    and (.tokens.loom_ticket | type) == "string" and (.tokens.loom_ticket | length) > 0))]
        | all' >/dev/null 2>&1
}

pane_expected_live() { # <pane> <controller|worker|ticker> [lane] -> 0 live, 1 dead, 2 unknown
    local pane="$1" role="$2" lane="${3:-}" info base
    info=$("$HERDR" pane process-info --pane "$pane" 2>/dev/null) || return 2
    printf '%s\n' "$info" | jq -e \
        '.result.process_info.foreground_processes | type == "array"' >/dev/null 2>&1 || return 2
    base="${0##*/}"
    case "$role" in
        controller)
            printf '%s\n' "$info" | jq -e --arg script "$0" --arg base "$base" '
                any(.result.process_info.foreground_processes[]?.argv? // [];
                    (. as $a
                     | ($a | index("supervise")) != null
                     and any($a[]?; . == $script or endswith("/" + $base))))' >/dev/null 2>&1 ;;
        worker)
            printf '%s\n' "$info" | jq -e --arg tick "$TICK" --arg lane "$lane" '
                any(.result.process_info.foreground_processes[]?.argv? // [];
                    (. as $a
                     | ($a | index($tick)) != null
                     and ($a | index("render-log")) != null
                     and ($a | index($lane)) != null
                     and ($a | index("--follow")) != null))' >/dev/null 2>&1 ;;
        ticker)
            printf '%s\n' "$info" | jq -e --arg tick "$TICK" '
                any(.result.process_info.foreground_processes[]?.argv? // [];
                    (. as $a
                     | ($a | index($tick)) != null
                     and ($a | index("render-events")) != null
                     and ($a | index("--follow")) != null))' >/dev/null 2>&1 ;;
        *) return 2 ;;
    esac
}

_ensure_controller_locked() {
    [ "${HERDR_ENV:-}" = 1 ] || {
        echo "watch-panes: viewer controller requires a Herdr pane" >&2
        return 1
    }
    command -v "$HERDR" >/dev/null 2>&1 || {
        echo "watch-panes: herdr is not on PATH" >&2
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        echo "watch-panes: jq is required" >&2
        return 1
    }
    local panes controllers live="" dead="" keep pane out cmd q live_rc
    panes=$(pane_list) || {
        viewer_note "viewer degraded: cannot discover Herdr panes; controller creation deferred"
        return 1
    }
    pane_list_valid "$panes" || {
        viewer_note "viewer degraded: malformed Herdr pane list; controller creation deferred"
        return 1
    }
    controllers=$(owned_role_ids "$panes" controller)
    for pane in $controllers; do
        if pane_expected_live "$pane" controller; then
            live="$live $pane"
        else
            live_rc=$?
            if [ "$live_rc" -eq 1 ]; then
                dead="$dead $pane"
            else
                viewer_note "viewer degraded: cannot verify controller pane $pane; no controller changes made"
                return 1
            fi
        fi
    done
    keep=$(printf '%s\n' $live | sed -n '1p')
    if [ -n "$keep" ]; then
        # Exact metadata plus verified command liveness is authority. Retire
        # stale and duplicate controllers only after every read succeeded.
        for pane in $dead $(printf '%s\n' $live | sed '1d'); do
            [ -n "$pane" ] && "$HERDR" pane close "$pane" >/dev/null 2>&1 || :
        done
        echo "watch-panes: already running in controller pane $keep — nothing to do."
        return 0
    fi
    for pane in $dead; do
        "$HERDR" pane close "$pane" >/dev/null 2>&1 || :
    done
    [ -n "${HERDR_PANE_ID:-}" ] || {
        echo "watch-panes: no caller pane is available for the viewer controller" >&2
        return 1
    }
    out=$("$HERDR" pane split --pane "$HERDR_PANE_ID" --direction right \
        --cwd "$PWD" --no-focus 2>/dev/null) || out=""
    pane=$(printf '%s\n' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
    [ -n "$pane" ] || {
        echo "watch-panes: could not create the Herdr-hosted viewer controller" >&2
        return 1
    }
    if ! tag_pane "$pane" controller; then
        "$HERDR" pane close "$pane" >/dev/null 2>&1 || :
        echo "watch-panes: could not tag the viewer controller; closed the unowned pane" >&2
        return 1
    fi
    "$HERDR" pane rename "$pane" "loom viewer" >/dev/null 2>&1 || :

    # Pane shells do not inherit later parent exports. Freeze the few inputs
    # the controller needs into its command, shell-quoted by Bash itself.
    cmd="env"
    for q in \
        "WATCH_OWNER_TOKEN=$OWNER_TOKEN" \
        "WATCH_ANCHOR_PANE=$HERDR_PANE_ID" \
        "LOOM_HOME=$ORCH_HOME" \
        "LOOM_REPO=${LOOM_REPO:-.}" \
        "LOOM_GLOBAL_CONFIG=${LOOM_GLOBAL_CONFIG:-$HOME/.loom/config.yml}" \
        "HERDR_CMD=$HERDR" \
        "WATCH_TICKER=${WATCH_TICKER:-1}" \
        "WATCH_POLL_SECONDS=$POLL" \
        "WATCH_MAX_PANES=$MAX_PANES"; do
        printf -v q '%q' "$q"
        cmd="$cmd $q"
    done
    printf -v q '%q' "$0"
    cmd="$cmd $q supervise"
    if ! "$HERDR" pane run "$pane" "$cmd" >/dev/null 2>&1; then
        "$HERDR" pane close "$pane" >/dev/null 2>&1 || :
        echo "watch-panes: controller command did not start; closed its pane" >&2
        return 1
    fi
    echo "watch-panes: controller → $pane"
}

process_start_identity() { # <pid>
    local started
    started=$( { ps -o lstart= -p "$1" 2>/dev/null || :; } \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' )
    printf '%s\n' "${started:-unavailable}"
}

CONTROLLER_LOCK="$ORCH_HOME/watch-controller.lock"

controller_lock_acquire() {
    local tries=0 incomplete=0 reap_wait=0 pid start live_start
    while [ "$tries" -lt 200 ]; do
        if mkdir "$CONTROLLER_LOCK" 2>/dev/null; then
            printf '%s\n' "$$" > "$CONTROLLER_LOCK/pid"
            process_start_identity $$ > "$CONTROLLER_LOCK/start"
            return 0
        fi
        pid=$(cat "$CONTROLLER_LOCK/pid" 2>/dev/null || :)
        start=$(cat "$CONTROLLER_LOCK/start" 2>/dev/null || :)
        live_start=""
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            live_start=$(process_start_identity "$pid")
            # A transient ps failure is unknown, not proof that a live PID was
            # reused. Keep waiting rather than risk a duplicate controller.
            if [ "$live_start" = unavailable ] || [ "$start" = unavailable ]; then
                live_start="$start"
            fi
        fi
        if [ -z "$pid" ] || [ -z "$start" ]; then
            incomplete=$((incomplete + 1))
        else
            incomplete=0
        fi
        if [ -d "$CONTROLLER_LOCK/reap" ]; then
            reap_wait=$((reap_wait + 1))
            if [ "$reap_wait" -ge 20 ]; then
                rmdir "$CONTROLLER_LOCK/reap" 2>/dev/null || :
                reap_wait=0
            fi
        else
            reap_wait=0
        fi
        # Reclamation is itself an atomic transaction. Only one waiter may
        # inspect and retire a stale lock, and it re-reads identity after
        # winning the claim. Missing metadata gets a one-second grace period:
        # it can be the mkdir winner between its two tiny writes.
        if { [ -n "$pid" ] && [ -n "$start" ] && [ "$live_start" != "$start" ]; } \
           || [ "$incomplete" -ge 20 ]; then
            if mkdir "$CONTROLLER_LOCK/reap" 2>/dev/null; then
                pid=$(cat "$CONTROLLER_LOCK/pid" 2>/dev/null || :)
                start=$(cat "$CONTROLLER_LOCK/start" 2>/dev/null || :)
                live_start=""
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    live_start=$(process_start_identity "$pid")
                    if [ "$live_start" = unavailable ] || [ "$start" = unavailable ]; then
                        live_start="$start"
                    fi
                fi
                if { [ -n "$pid" ] && [ -n "$start" ] && [ "$live_start" != "$start" ]; } \
                   || { { [ -z "$pid" ] || [ -z "$start" ]; } && [ "$incomplete" -ge 20 ]; }; then
                    rm -f "$CONTROLLER_LOCK/pid" "$CONTROLLER_LOCK/start"
                    rmdir "$CONTROLLER_LOCK/reap" 2>/dev/null || :
                    rmdir "$CONTROLLER_LOCK" 2>/dev/null || :
                else
                    rmdir "$CONTROLLER_LOCK/reap" 2>/dev/null || :
                fi
            fi
        fi
        sleep 0.05
        tries=$((tries + 1))
    done
    echo "watch-panes: timed out acquiring the repo controller lock" >&2
    return 1
}

controller_lock_release() {
    local start tries=0
    start=$(process_start_identity $$)
    if [ "$(cat "$CONTROLLER_LOCK/pid" 2>/dev/null || :)" = "$$" ] \
       && [ "$(cat "$CONTROLLER_LOCK/start" 2>/dev/null || :)" = "$start" ]; then
        while [ -d "$CONTROLLER_LOCK/reap" ] && [ "$tries" -lt 20 ]; do
            sleep 0.01
            tries=$((tries + 1))
        done
        rm -f "$CONTROLLER_LOCK/pid" "$CONTROLLER_LOCK/start"
        rmdir "$CONTROLLER_LOCK" 2>/dev/null || :
    fi
}

ensure_controller() {
    local rc
    controller_lock_acquire || return 1
    if _ensure_controller_locked; then rc=0; else rc=$?; fi
    controller_lock_release
    return "$rc"
}

owns_pid_record() { # <pid> <start>
    [ "$(cat "$WP_PID" 2>/dev/null)" = "$1" ] \
        && [ "$(cat "$WP_PID_START" 2>/dev/null)" = "$2" ]
}

supervise() {
    [ "${HERDR_ENV:-}" = 1 ] || {
        echo "watch-panes: controller is not inside a Herdr pane" >&2
        return 1
    }
    local self_start child="" rc=0
    self_start=$(process_start_identity $$)
    printf '%s\n' "$$" > "$WP_PID" 2>/dev/null || :
    printf '%s\n' "$self_start" > "$WP_PID_START" 2>/dev/null || :
    _supervise_term() {
        [ -n "$child" ] && kill "$child" 2>/dev/null || :
        exit 0
    }
    _supervise_cleanup() {
        local x="${1:-$?}"
        if owns_pid_record "$$" "$self_start"; then
            rm -f "$WP_PID" "$WP_PID_START"
        fi
        return $x
    }
    trap _supervise_term INT TERM
    trap _supervise_cleanup EXIT

    while [ ! -f "$VIEWER_OFF" ]; do
        set +e
        if [ -n "${WATCH_WORKER_CMD:-}" ]; then
            WORKER_CALLS="${WORKER_CALLS:-}" LOOM_HOME="$ORCH_HOME" \
                /bin/bash -c "$WATCH_WORKER_CMD" &
        else
            WATCH_CONTROLLER_PANE="${HERDR_PANE_ID:-}" "$0" worker &
        fi
        child=$!
        wait "$child"; rc=$?
        child=""
        set -e
        [ -f "$VIEWER_OFF" ] && break
        viewer_note "viewer polling worker exited rc $rc; controller restarting it"
        sleep "${WATCH_RESTART_SECONDS:-1}"
    done

    # The marker can arrive during the bounded restart backoff, when no
    # polling worker exists to perform owned-pane cleanup. One final ordinary
    # worker pass is idempotent and applies the same token boundary.
    if [ -f "$VIEWER_OFF" ]; then
        WATCH_CONTROLLER_PANE="${HERDR_PANE_ID:-}" "$0" worker >/dev/null 2>&1 || :
    fi

    # `off` asks the worker to close worker/ticker panes. The controller owns
    # only itself, and verifies its token before closing that final pane.
    local close_controller=""
    if [ -f "$VIEWER_OFF" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
        local meta
        meta=$("$HERDR" pane get "$HERDR_PANE_ID" 2>/dev/null) || meta=""
        if printf '%s\n' "$meta" | jq -e --arg owner "$OWNER_TOKEN" '
            .result.pane.tokens.loom_viewer == $owner
            and .result.pane.tokens.loom_role == "controller"' >/dev/null 2>&1; then
            close_controller=1
        fi
    fi
    trap - INT TERM EXIT
    _supervise_cleanup "$rc"
    [ -n "$close_controller" ] \
        && "$HERDR" pane close "$HERDR_PANE_ID" >/dev/null 2>&1 || :
    return "$rc"
}

# The deliberate off-switch for the ticker strip, honored mid-run. The viewer
# reopens a dead ticker every poll (see ensure_ticker), which makes the
# natural gesture — Ctrl-C the follow, close the pane — futile by design; the
# human's intent needs a channel the poll loop can read. A state-dir marker is
# that channel (same plumbing class as locks and pause markers, per the
# constitution's run-dir carve-out). Works from any terminal, viewer running
# or not. (Asked for by the human, 2026-08-02, after the reopen-every-poll
# fix ate the close-the-pane gesture.)
#   watch-panes.sh ticker off   close the ticker and keep it closed
#   watch-panes.sh ticker on    bring it back (within one poll)
if [ "${1:-}" = "ticker" ]; then
    case "${2:-}" in
        off) touch "$TICKER_OFF"; echo "watch-panes: ticker off — a running viewer closes it within one poll." ;;
        on)  rm -f "$TICKER_OFF"; echo "watch-panes: ticker on — a running viewer opens it within one poll." ;;
        *)   echo "usage: watch-panes.sh ticker off|on" >&2; exit 2 ;;
    esac
    exit 0
fi

# `/loom watch` raises the viewer, and a human typing `watch` is asking to SEE
# the build — an intent newer than whatever earlier `q` or `off` closed it, on
# the same reasoning that lets `start` clear both switches. So `raise` clears
# BOTH and brings the viewer up, where `on` clears the viewer switch alone and
# leaves a deliberate `ticker off` standing. Only human-typed verbs (`start`,
# `watch`) may use it: an automatic tick undoing a human's close is the thing
# the switches exist to prevent.
# (Asked for by the human, 2026-08-05: a `ticker-off` marker left an armed
# build with no ticker for 40 minutes, and `watch` reporting healthy the whole
# time read as the viewer being broken rather than as a setting.)
if [ "${1:-}" = "raise" ]; then
    rm -f "$TICKER_OFF" "$VIEWER_OFF"
    ensure_controller
    exit $?
fi

# The whole viewer, same shape as the ticker switch above. Until now only the
# ticker had an off-switch: closing everything meant killing the process by
# its pidfile, by hand, from a command someone had to be told. The script's
# own header said "Ctrl-C to stop", which is true only of a foreground run —
# and the skill deliberately launches this detached so the panes outlive the
# session that opened them. So in normal use there was no way to stop it.
# (Asked for by the human, 2026-08-04.)
if [ "${1:-}" = "off" ] || [ "${1:-}" = "on" ]; then
    if [ "$1" = off ]; then
        touch "$VIEWER_OFF"
        echo "watch-panes: off — the controller closes its owned panes and exits within one poll."
    else
        rm -f "$VIEWER_OFF"
        if ensure_controller; then
            echo "watch-panes: on."
            exit 0
        fi
        echo "watch-panes: on FAILED — viewer availability is unconfirmed." >&2
        exit 1
    fi
    exit 0
fi

if [ "${1:-}" = supervise ]; then
    supervise
    exit $?
fi
WORKER_MODE=""
if [ "${1:-}" = worker ]; then
    WORKER_MODE=1
    shift
elif [ -n "${1:-}" ]; then
    echo "usage: watch-panes.sh [raise|on|off|supervise|worker|ticker off|on]" >&2
    exit 2
fi

# A deliberate `off` outranks every launch path, including the opportunistic
# one on each manual tick — otherwise the next tick would undo the human.
if [ -f "$VIEWER_OFF" ] && [ -z "$WORKER_MODE" ]; then
    echo "watch-panes: viewer is switched off (\`watch-panes.sh on\` to bring it back)."
    exit 0
fi
MAP="$(mktemp)"                     # reconstructed each poll: <pane> <lane> <ticket>
USED="$(mktemp)"
LIVE="$(mktemp)"                    # verified: <pane> <role> <lane|-> <ticket|->
DEAD="$(mktemp)"                    # complete owned records with no expected follower
_wp_cleanup() {
    local rc=$?
    rm -f "$MAP" "$MAP.new" "$USED" "$LIVE" "$DEAD"
    return $rc
}
trap _wp_cleanup EXIT

if [ "${HERDR_ENV:-}" != 1 ]; then
    echo "watch-panes: not inside a herdr session — run this from a herdr pane." >&2
    echo "             To watch one lane anywhere: $TICK render-log <id> --follow" >&2
    exit 1
fi
command -v "$HERDR" >/dev/null 2>&1 || { echo "watch-panes: herdr is not on PATH" >&2; exit 1; }
command -v jq    >/dev/null 2>&1 || { echo "watch-panes: jq is required" >&2; exit 1; }

# The ticket key a lane id carries: impl-7 → 7, gate-7-r3 → 7, merge-7 → 7,
# probe-audio-spine → audio-spine. Lane kinds are fixed by spawn-lane, so
# stripping the known prefixes and a trailing -r<round> is exact, not a guess.
tkey() {
    local id="$1"
    id="${id#impl-}"; id="${id#gate-}"; id="${id#merge-}"; id="${id#probe-}"
    case "$id" in *-r[0-9]|*-r[0-9][0-9]) id="${id%-r*}" ;; esac
    printf '%s' "$id"
}

# Layout contract (asked for by the human, 2026-08-02): the pane this viewer
# is launched from (the loom session) and the ticker form the LEFT
# column — ticker as a 25% strip under the session. Lane panes form the RIGHT
# column, stacked top to bottom. Split ORDER makes the columns: the right
# anchor splits off the session while it is still full width, THEN the ticker
# splits the session down — so the ticker stays inside the left column
# instead of spanning the window. `--ratio R` is the share the ORIGINAL pane
# keeps (measured empirically, herdr 2026-08).
#
# That order is an invariant, not a startup step: ANY time a right column is
# opened off the session pane while the ticker is live — startup or mid-run —
# the ticker must be closed first and reopened after, or the new pane lands
# inside the left column on top of it.
new_pane() { # <direction> [target-pane] [ratio] → new pane id
    local dir="$1" target="${2:-}" ratio="${3:-}"; local args=()
    if [ -n "$target" ]; then args+=(--pane "$target"); else args+=(--current); fi
    args+=(--direction "$dir" --cwd "$PWD" --no-focus)
    [ -n "$ratio" ] && args+=(--ratio "$ratio")
    "$HERDR" pane split "${args[@]}" 2>/dev/null \
        | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true
}

# Every right-column split hangs off the pane this viewer was launched from.
# When that session is gone, the id refers to nothing and EVERY split fails —
# and `new_pane` returns an empty string on failure, which the startup check
# read as "skip this" rather than "I am broken". Result on 2026-08-04: the
# viewer stayed alive for thirteen minutes and opened nothing at all — no
# anchor, no ticker, no lane panes — while two lanes ran unseen, healthy in
# `pgrep` the whole time, and the human noticed only by asking where the
# ticker was (P39). So the anchor is now a variable that can be re-resolved,
# and a split that fails even against a live anchor is fatal.
ANCHOR="${WATCH_ANCHOR_PANE:-${HERDR_PANE_ID:-}}"
CONTROLLER_PANE="${WATCH_CONTROLLER_PANE:-}"
PANE_JSON=""

# Point ANCHOR at some other live pane. Prefers the old anchor's own
# workspace, so a viewer whose launching pane was closed stays in the window
# the human is watching; skips panes this viewer already owns, since a right
# column split off one of its own lane panes is not a column.
reanchor() {
    local ws="${ANCHOR%%:*}" ids ordered cand
    ids=$(awk '$2 != "ticker" {print $1}' "$LIVE" 2>/dev/null) || ids=""
    [ -n "$ids" ] || return 1
    ordered=$( { printf '%s\n' "$ids" | grep "^$ws:" || :; printf '%s\n' "$ids" | grep -v "^$ws:" || :; } )
    while read -r cand; do
        [ -n "$cand" ] || continue
        [ "$cand" = "$ANCHOR" ] && continue
        [ "$cand" = "${TICKER_PANE:-}" ] && continue
        echo "watch-panes: anchor pane ${ANCHOR:-<unset>} is gone — re-anchoring on $cand" >&2
        ANCHOR="$cand"
        return 0
    done <<< "$ordered"
    return 1
}

# Open a right column off the anchor, re-resolving the anchor once if the
# first attempt fails. Empty means even a live anchor could not split.
anchor_split() {
    local p; p=$(new_pane right "$ANCHOR")
    if [ -z "$p" ] && reanchor; then p=$(new_pane right "$ANCHOR"); fi
    printf '%s' "$p"
}

# The right column decays without this. Every lane pane is opened by splitting
# the newest pane DOWN with no ratio, so herdr halves it: lane 1 gets half the
# column, lane 2 a quarter, lane 3 an eighth — the newest lanes, which are the
# ones the human is most likely to be reading, end up smallest. Measured
# 2026-08-05 in a live session: a four-pane column at 24/21/10/10 rows in a
# 65-row area, where equal is 16 (P44).
#
# Two facts this rests on, both measured against herdr 2026-08. `--amount` is a
# signed delta on the ratio of the nearest ancestor split on that axis, and the
# ratio is the TOP child's share: a split at 0.32258 resized `--direction up
# --amount 0.1` became 0.22258. And in a column built by repeatedly splitting
# the bottom pane downward, pane k is the top child of split k — so targeting
# pane k moves the divider below it and nothing else.
#
# The column is the panes sharing the seed's x/width AND present in MAP. That
# second condition is the safety rule: this viewer resizes only panes it opened
# itself, so the loom session pane, the ticker (never tracked in MAP) and
# anything a human put on screen are out of reach by construction rather than
# by remembering to exclude them. The left column keeps its own contract — the
# ticker's 25% strip under the session is set by `new_pane down "$ANCHOR" 0.75`
# and is not this function's business.
_column_ids() { # <seed pane> → column pane ids, top to bottom
    local seed="$1" owned
    owned=$(awk '{ print $1 }' "$MAP" 2>/dev/null | jq -R . | jq -s . 2>/dev/null) || return 1
    [ -n "$owned" ] || return 1
    "$HERDR" pane layout --pane "$seed" 2>/dev/null | jq -r --arg seed "$seed" --argjson owned "$owned" '
        .result.layout as $l
        | if ($l.zoomed // false) then empty else
            ( $l.panes[]? | select(.pane_id == $seed) | .rect ) as $s
            | $l.panes
            | map(select(.rect.x == $s.x and .rect.width == $s.width
                         and ((.pane_id as $p | $owned | index($p)) != null)))
            | sort_by(.rect.y)[] | .pane_id
          end' 2>/dev/null
}

# The resize for one divider, as a direction plus a magnitude. Negative deltas
# travel as `up` rather than as a negative `--amount`, which the argument parser
# would read as a flag. Re-read per divider rather than solving the column in
# closed form: rows are integers, herdr quantises every ratio to whole rows, and
# a closed-form pass accumulates that rounding all the way down the column.
_split_delta() { # <seed> <ids> <k> <n> → "<up|down> <amount>", empty if settled
    local seed="$1" ids="$2" k="$3" n="$4" heights
    heights=$("$HERDR" pane layout --pane "$seed" 2>/dev/null \
        | jq -r '.result.layout.panes[]? | "H \(.pane_id) \(.rect.height)"' 2>/dev/null) || return 1
    [ -n "$heights" ] || return 1
    printf '%s\n%s\n' "$heights" "$(printf '%s\n' "$ids" | awk 'NF { print "I", NR - 1, $1 }')" \
    | awk -v k="$k" -v n="$n" '
        $1 == "H" { h[$2] = $3; next }
        $1 == "I" { id[$2] = $3; next }
        END {
            R = 0
            for (i = k; i < n; i++) { if (!(id[i] in h)) exit 1; R += h[id[i]] }
            if (R <= 0) exit 1
            d = 1.0 / (n - k) - h[id[k]] / R
            if (d < 0)      { if (-d >= 0.005) printf "up %.5f\n", -d }
            else if (d >= 0.005) printf "down %.5f\n", d
        }'
}

# Everything here fails soft. A `pane layout` that errors, a rect that will not
# parse, or a resize that fails skips the rebalance and never touches the
# pane-opening path above: this viewer's first rule is that deleting herdr from
# the machine leaves the build unaffected (see the header), and a cosmetic pass
# must not be the thing that breaks it.
rebalance_column() { # <a pane in the column>
    local seed="$1" ids n k id step
    [ -n "$seed" ] || return 0
    ids=$(_column_ids "$seed") || return 0
    [ -n "$ids" ] || return 0
    n=$(printf '%s\n' "$ids" | grep -c . || :)
    # Two panes are already 50/50 from herdr's own default split; one is the
    # whole column. Neither has a divider worth moving.
    [ "${n:-0}" -ge 3 ] || return 0
    k=0
    while [ "$k" -le $((n - 2)) ]; do
        id=$(printf '%s\n' "$ids" | sed -n "$((k + 1))p")
        step=$(_split_delta "$seed" "$ids" "$k" "$n") || return 0
        if [ -n "$step" ]; then
            "$HERDR" pane resize --pane "$id" --direction ${step% *} --amount "${step#* }" \
                >/dev/null 2>&1 || return 0
        fi
        k=$((k + 1))
    done
}

# A viewer that cannot open a pane has no job left to do, and staying alive is
# worse than dying: it holds the singleton, so every later launch path exits
# with "already running — nothing to do" and the build runs unwatched. Exiting
# releases the pidfile (see the trap above, which is why P40 lands first) and
# the next tick starts a working one.
wp_blind() {
    echo "watch-panes: $1" >&2
    echo "watch-panes: exiting so the next \`/loom tick\` or \`watch-panes.sh on\` starts a working viewer." >&2
    exit 1
}

echo "watch-panes: polling every ${POLL}s, up to ${MAX_PANES} active worker panes. Ctrl-C to stop."

TICKER_PANE=""
WAITED=""
DISCOVERY_NOTED=""

pane_unused() { ! grep -qxF "$1" "$USED" 2>/dev/null; }
use_pane() { printf '%s\n' "$1" >> "$USED"; }

worker_candidates() { # exact-lane|ticket <value> <ticket-if-exact>
    local field="$1" value="$2" ticket="${3:-}"
    if [ "$field" = lane ]; then
        awk -v lane="$value" -v ticket="$ticket" \
            '$2 == "worker" && $3 == lane && $4 == ticket {print $1}' "$LIVE"
    else
        awk -v ticket="$value" '$2 == "worker" && $4 == ticket {print $1}' "$LIVE"
    fi
}

owned_worker_ids() { owned_role_ids "$PANE_JSON" worker; }

classify_owned_panes() {
    local role pane lane ticket live_rc
    : > "$LIVE"
    : > "$DEAD"
    for role in controller worker ticker; do
        for pane in $(owned_role_ids "$PANE_JSON" "$role"); do
            lane="-"; ticket="-"
            if [ "$role" = worker ]; then
                lane=$(printf '%s\n' "$PANE_JSON" | jq -r --arg pane "$pane" \
                    '.result.panes[] | select(.pane_id == $pane) | .tokens.loom_lane' 2>/dev/null)
                ticket=$(printf '%s\n' "$PANE_JSON" | jq -r --arg pane "$pane" \
                    '.result.panes[] | select(.pane_id == $pane) | .tokens.loom_ticket' 2>/dev/null)
            fi
            if pane_expected_live "$pane" "$role" "$lane"; then
                printf '%s %s %s %s\n' "$pane" "$role" "$lane" "$ticket" >> "$LIVE"
            else
                live_rc=$?
                if [ "$live_rc" -eq 1 ]; then
                    printf '%s %s %s %s\n' "$pane" "$role" "$lane" "$ticket" >> "$DEAD"
                else
                    return 2
                fi
            fi
        done
    done
}

ensure_ticker() {
    local enabled=1 tickers live_tickers keep tp tcmd
    [ "${WATCH_TICKER:-1}" = 1 ] || enabled=0
    [ -f "$TICKER_OFF" ] && enabled=0
    tickers=$(owned_role_ids "$PANE_JSON" ticker)
    live_tickers=$(awk '$2 == "ticker" {print $1}' "$LIVE")
    keep=$(printf '%s\n' "$live_tickers" | sed -n '1p')
    if [ "$enabled" = 0 ]; then
        printf '%s\n' "$tickers" | while read -r tp; do
            [ -n "$tp" ] && "$HERDR" pane close "$tp" >/dev/null 2>&1 || :
        done
        TICKER_PANE=""
        return 0
    fi
    if [ -n "$keep" ]; then
        TICKER_PANE="$keep"
        for tp in $tickers; do
            [ "$tp" = "$keep" ] || "$HERDR" pane close "$tp" >/dev/null 2>&1 || :
        done
        return 0
    fi
    # Every complete ticker record was verified dead. Retire those stale
    # shells before creating the one replacement follower.
    for tp in $tickers; do
        "$HERDR" pane close "$tp" >/dev/null 2>&1 || :
    done
    tp=$(new_pane down "$ANCHOR" 0.75)
    if [ -z "$tp" ] && [ -n "$CONTROLLER_PANE" ] \
       && grep -q "^$CONTROLLER_PANE controller " "$LIVE" 2>/dev/null; then
        tp=$(new_pane down "$CONTROLLER_PANE" 0.75)
    fi
    [ -n "$tp" ] || {
        echo "watch-panes: could not open a ticker pane (run '$TICK render-events --follow' anywhere instead)" >&2
        return 0
    }
    if ! tag_pane "$tp" ticker; then
        "$HERDR" pane close "$tp" >/dev/null 2>&1 || :
        viewer_note "viewer degraded: could not tag the new ticker pane"
        return 0
    fi
    tcmd="LOOM_TICKER_QUIT_HINT='  (press q to close this ticker)'"
    tcmd="$tcmd LOOM_TICKER_REOPEN_HINT='Reopen with: watch-panes.sh ticker on'"
    tcmd="$tcmd $TICK render-events --follow"
    if "$HERDR" pane run "$tp" "$tcmd" >/dev/null 2>&1; then
        "$HERDR" pane rename "$tp" "build ticker" >/dev/null 2>&1 || :
        TICKER_PANE="$tp"
        echo "watch-panes: build ticker → $tp"
    else
        "$HERDR" pane close "$tp" >/dev/null 2>&1 || :
        TICKER_PANE=""
    fi
}

close_owned_display_panes() {
    local role pane
    for role in worker ticker; do
        owned_role_ids "$PANE_JSON" "$role" | while read -r pane; do
            [ -n "$pane" ] && "$HERDR" pane close "$pane" >/dev/null 2>&1 || :
        done
    done
}

open_worker_pane() { # prints a new pane id; caller tags it before use
    local pane="" base="" reopen=""
    # The durable controller is an owned right-column root. After recovery,
    # prefer the bottom-most active worker; if none exists, split below the
    # controller. A direct foreground worker falls back to its explicit caller.
    base=$(tail -1 "$MAP" 2>/dev/null | awk '{print $1}')
    if [ -z "$base" ] && [ -n "$CONTROLLER_PANE" ] \
       && grep -q "^$CONTROLLER_PANE controller " "$LIVE" 2>/dev/null; then
        base="$CONTROLLER_PANE"
    fi
    [ -n "$base" ] && pane=$(new_pane down "$base")
    if [ -z "$pane" ] && [ -s "$MAP" ]; then
        # Panes registered earlier in this same poll are already tagged, even
        # though the single topology snapshot intentionally predates them.
        # Walk that owned local set bottom-up before opening a new column.
        for base in $(awk '{print $1}' "$MAP" | sed '1!G;h;$!d'); do
            pane=$(new_pane down "$base")
            [ -n "$pane" ] && break
        done
    fi
    if [ -z "$pane" ]; then
        if [ -n "$TICKER_PANE" ]; then
            local closed_ticker="$TICKER_PANE"
            "$HERDR" pane close "$closed_ticker" >/dev/null 2>&1 || :
            TICKER_PANE=""
            PANE_JSON=$(printf '%s\n' "$PANE_JSON" | jq --arg pane "$closed_ticker" \
                '.result.panes |= map(select(.pane_id != $pane))' 2>/dev/null) || PANE_JSON=""
            reopen=1
        fi
        pane=$(anchor_split)
        [ -n "$reopen" ] && ensure_ticker
    fi
    printf '%s' "$pane"
}

finish_poll() {
    if [ -n "${WATCH_POLLS:-}" ]; then
        WATCH_POLLS=$((WATCH_POLLS - 1))
        [ "$WATCH_POLLS" -le 0 ] && exit 0
    fi
    sleep "$POLL"
}

while :; do
    # Liveness and pane topology are each sampled exactly once per poll. A
    # stale-but-alive lane remains active because `lanes-alive` owns that
    # classification.
    if ! running=$("$TICK" lanes-alive 2>/dev/null | awk '{ print $1 }'); then
        if [ -z "$DISCOVERY_NOTED" ]; then
            viewer_note "viewer degraded: cannot read live lanes; no pane changes made"
            DISCOVERY_NOTED=1
        fi
        finish_poll
        continue
    fi
    PANE_JSON=$(pane_list) || PANE_JSON=""
    if ! pane_list_valid "$PANE_JSON"; then
        if [ -z "$DISCOVERY_NOTED" ]; then
            viewer_note "viewer degraded: cannot safely discover owned panes; no pane changes made"
            DISCOVERY_NOTED=1
        fi
        finish_poll
        continue
    fi
    if ! owned_metadata_valid "$PANE_JSON"; then
        if [ -z "$DISCOVERY_NOTED" ]; then
            viewer_note "viewer degraded: malformed owned pane metadata; no pane changes made"
            DISCOVERY_NOTED=1
        fi
        finish_poll
        continue
    fi
    if [ -f "$VIEWER_OFF" ]; then
        echo "watch-panes: switched off — closing owned display panes and exiting."
        close_owned_display_panes
        exit 0
    fi
    if ! classify_owned_panes; then
        if [ -z "$DISCOVERY_NOTED" ]; then
            viewer_note "viewer degraded: cannot verify owned pane followers; no pane changes made"
            DISCOVERY_NOTED=1
        fi
        finish_poll
        continue
    fi
    DISCOVERY_NOTED=""

    : > "$MAP"
    : > "$USED"
    ensure_ticker
    unmatched=""

    # Adopt an exact active lane first, then a surviving pane from the same
    # ticket for an immediate stage handoff. Exact adoption never starts a
    # second follower in the pane.
    for lane in $running; do
        t=$(tkey "$lane")
        pane=""
        for cand in $(worker_candidates lane "$lane" "$t"); do
            if pane_unused "$cand"; then pane="$cand"; break; fi
        done
        if [ -n "$pane" ]; then
            use_pane "$pane"
            printf '%s %s %s\n' "$pane" "$lane" "$t" >> "$MAP"
            continue
        fi
        for cand in $(worker_candidates ticket "$t"); do
            if pane_unused "$cand"; then pane="$cand"; break; fi
        done
        if [ -n "$pane" ] && tag_pane "$pane" worker "$lane" "$t" \
           && "$HERDR" pane run "$pane" "$TICK render-log $lane --follow" >/dev/null 2>&1; then
            "$HERDR" pane rename "$pane" "$lane" >/dev/null 2>&1 || :
            use_pane "$pane"
            printf '%s %s %s\n' "$pane" "$lane" "$t" >> "$MAP"
            echo "watch-panes: $lane (ticket $t) → $pane"
            continue
        fi
        unmatched="$unmatched $lane"
    done

    # Anything owned but not matched to a live lane is an orphan. No tracker
    # read and no label can keep it: durable logs preserve the story.
    for pane in $(owned_worker_ids); do
        if pane_unused "$pane"; then
            "$HERDR" pane close "$pane" >/dev/null 2>&1 || :
            echo "watch-panes: closed inactive owned pane $pane" >&2
        fi
    done

    rebalance_seed=""
    for lane in $unmatched; do
        if [ "$(wc -l < "$MAP" | tr -d ' ')" -ge "$MAX_PANES" ]; then
            case " $WAITED " in *" $lane "*) ;; *)
                WAITED="$WAITED $lane"
                "$TICK" event viewer_note note "$lane waiting for a pane (cap $MAX_PANES)" >/dev/null 2>&1 || :
            ;; esac
            continue
        fi
        t=$(tkey "$lane")
        pane=$(open_worker_pane)
        [ -n "$pane" ] || wp_blind "no pane could be opened for $lane — every owned anchor is gone."
        # Metadata is installed before a command, rename, or later poll can
        # observe the pane. If tagging fails, close only this pane we created.
        if ! tag_pane "$pane" worker "$lane" "$t"; then
            "$HERDR" pane close "$pane" >/dev/null 2>&1 || :
            viewer_note "viewer degraded: could not tag the new pane for $lane"
            continue
        fi
        if "$HERDR" pane run "$pane" "$TICK render-log $lane --follow" >/dev/null 2>&1; then
            "$HERDR" pane rename "$pane" "$lane" >/dev/null 2>&1 || :
            use_pane "$pane"
            printf '%s %s %s\n' "$pane" "$lane" "$t" >> "$MAP"
            echo "watch-panes: $lane (ticket $t) → $pane"
            rebalance_seed="$pane"
        else
            "$HERDR" pane close "$pane" >/dev/null 2>&1 || :
        fi
    done
    [ -n "$rebalance_seed" ] && rebalance_column "$rebalance_seed" || :
    finish_poll
done
