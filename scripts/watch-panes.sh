#!/usr/bin/env bash
# watch-panes.sh — one herdr pane per TICKET, following each of its lanes in
# turn. Human-run convenience, never called by the machinery (P24).
#
# Nothing about a build changes if this is never run, or if herdr is not
# installed: it only reads `tick.sh lane-status` and follows files the lanes
# already write. Delete herdr from the machine and the build is unaffected —
# `tick.sh render-log <id> --follow` still works in any terminal.
#
# Pane↔ticket affinity: a ticket's lanes (impl-7 → gate-7[-rN] → merge-7) are
# separate processes, but its story is one story — so the pane that showed
# impl-7 is reserved for gate-7 and then merge-7, and the scrollback reads
# implement → review → merge top to bottom. If a ticket's next lane spawns
# while its previous lane is still exiting (chained handoffs overlap for a
# few seconds), assignment waits a poll rather than splitting the story
# across panes. (Paid for: build-1 2026-08-02 — ticket #3's three stages
# landed in two different panes and read as two unrelated streams.)
#
# Usage: watch-panes.sh            (foreground; Ctrl-C to stop)
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
GLAB="${GLAB_CMD:-glab}"   # one read per merge conclusion (see pane release)

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
    _dir="$("$TICK" orch-home 2>/dev/null)"
    case "${2:-}" in
        off) touch "$_dir/ticker-off"; echo "watch-panes: ticker off — a running viewer closes it within one poll." ;;
        on)  rm -f "$_dir/ticker-off"; echo "watch-panes: ticker on — a running viewer opens it within one poll." ;;
        *)   echo "usage: watch-panes.sh ticker off|on" >&2; exit 2 ;;
    esac
    exit 0
fi

# Singleton per repo: `/orchestrate tick` launches this opportunistically on
# every manual tick, so a second launch must exit quietly instead of opening
# a duplicate pane per lane. The pidfile lives in the repo's state dir (one
# viewer per repo, not per machine); a stale file from a dead viewer is
# overwritten.
WP_PID="$("$TICK" orch-home 2>/dev/null)/watch-panes.pid"
TICKER_OFF="${WP_PID%/*}/ticker-off"
if [ -f "$WP_PID" ] && kill -0 "$(cat "$WP_PID" 2>/dev/null)" 2>/dev/null; then
    echo "watch-panes: already running (pid $(cat "$WP_PID")) — nothing to do."
    exit 0
fi
echo $$ > "$WP_PID" 2>/dev/null || :

MAP="$(mktemp)"                     # lines: <pane_id> <lane_id|-> <ticket|->
trap 'rm -f "$MAP" "$MAP.new" "$WP_PID"' EXIT

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
# is launched from (the orchestration session) and the ticker form the LEFT
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

echo "watch-panes: polling every ${POLL}s, up to ${MAX_PANES} panes, one pane per ticket. Ctrl-C to stop."

# Right-column anchor first (see the layout contract above). It enters MAP as
# an idle pane, so the first lane reuses it instead of splitting again;
# STACK_LAST tracks the newest right-column pane so later lanes stack DOWN
# off it.
STACK_LAST=""
WAITED=""                            # lanes already ticker-noted as waiting at the cap
anchor=$(new_pane right "$HERDR_PANE_ID")
if [ -n "$anchor" ]; then
    "$HERDR" pane run "$anchor" "echo '── watch-panes: waiting for lanes ──'" >/dev/null 2>&1 || :
    "$HERDR" pane rename "$anchor" "waiting for lanes" >/dev/null 2>&1 || :
    printf '%s - -\n' "$anchor" >> "$MAP"
    STACK_LAST="$anchor"
fi

# The build ticker: a strip under the session pane streaming
# `render-events --follow` — a timestamped line per step (claimed, → review,
# gate verdict, merged) across the whole build, while the lane panes carry
# each ticket's full transcript. Not tracked in MAP and not counted against
# MAX_PANES: it belongs to the build, not to a lane. WATCH_TICKER=0 disables it.
#
# Checked EVERY poll, not once at startup: the viewer is a singleton that can
# outlive its own panes, and launch-on-tick exits at the pidfile — so a ticker
# opened only at startup is unrecoverable once its pane dies. (Paid for:
# build-3 wave 1 2026-08-02 — a viewer from between builds survived with its
# ticker pane long gone; it reopened lane panes fine, and the human watched a
# four-lane wave with no ticker.) Consequence: closing the ticker pane by hand
# brings it back next poll — the deliberate gesture is `watch-panes.sh ticker
# off` (the state-dir marker above, honored here every poll); WATCH_TICKER=0
# still disables it for a whole viewer run.
TICKER_PANE=""
ensure_ticker() {
    [ "${WATCH_TICKER:-1}" = 1 ] || return 0
    if [ -f "$TICKER_OFF" ]; then
        if [ -n "$TICKER_PANE" ]; then
            "$HERDR" pane close "$TICKER_PANE" >/dev/null 2>&1 || :
            TICKER_PANE=""
        fi
        return 0
    fi
    if [ -n "$TICKER_PANE" ] && "$HERDR" pane process-info --pane "$TICKER_PANE" >/dev/null 2>&1; then
        return 0
    fi
    local tp; tp=$(new_pane down "$HERDR_PANE_ID" 0.75)
    if [ -n "$tp" ] && "$HERDR" pane run "$tp" "$TICK render-events --follow" >/dev/null 2>&1; then
        "$HERDR" pane rename "$tp" "build ticker" >/dev/null 2>&1 || :
        TICKER_PANE="$tp"
        echo "watch-panes: build ticker → $tp"
    else
        TICKER_PANE=""
        echo "watch-panes: could not open a ticker pane (run '$TICK render-events --follow' anywhere instead)" >&2
    fi
}
ensure_ticker

while :; do
    ensure_ticker
    running=$("$TICK" lane-status 2>/dev/null | awk '$3 == "running" { print $1 }') || running=""

    # Release panes whose lane is gone, keeping the ticket stamp so the next
    # stage of the same ticket comes back to the same pane. The follow command
    # has already exited on its own, so the pane is sitting at a prompt.
    # Stamp the pane when its lane ends: without a marker, the last lines of a
    # finished lane are indistinguishable from a live-but-quiet one, and an idle
    # pane reads as a stall (build-1 2026-08-02, observed by the human).
    if [ -s "$MAP" ]; then
        while read -r pane lane tkt; do
            [ -n "$pane" ] || continue
            if [ "$lane" != "-" ] && ! printf '%s\n' "$running" | grep -qxF "$lane"; then
                # A finished STORY closes its pane (asked for by the human,
                # 2026-08-02): a probe's story ends with its lane; a merge's
                # ends only if the ticket actually closed — merge lanes exit
                # cleanly without merging (merge-21 did, twice), and a blocked
                # merge must keep its pane. One tracker read per merge
                # conclusion; a failed read keeps the pane (safe default).
                # The scrollback is not the record: `render-log <id>` replays
                # any lane. Everything else idles for reuse as before.
                story_done=""
                case "$lane" in
                    probe-*) story_done=1 ;;
                    merge-*) [ "$("$GLAB" api "projects/:fullpath/issues/$tkt" 2>/dev/null \
                                 | jq -r '.state' 2>/dev/null)" = "closed" ] && story_done=1 ;;
                esac
                if [ -n "$story_done" ]; then
                    "$HERDR" pane close "$pane" >/dev/null 2>&1 || :
                    # stderr: the loop's stdout IS the rewritten MAP file
                    echo "watch-panes: ticket ${tkt:--} concluded — closed its pane" >&2
                    continue                    # drop from MAP
                fi
                "$HERDR" pane run "$pane" "echo '── lane $lane ended — pane stays with ticket ${tkt:--} ──'" >/dev/null 2>&1 || :
                # The pane's name tracks its CURRENT occupant: a pane still
                # labeled with a finished lane reads as that lane running.
                "$HERDR" pane rename "$pane" "ticket ${tkt:--} — idle" >/dev/null 2>&1 || :
                printf '%s - %s\n' "$pane" "${tkt:--}"
            else
                printf '%s %s %s\n' "$pane" "$lane" "${tkt:--}"
            fi
        done < "$MAP" > "$MAP.new"
        mv "$MAP.new" "$MAP"
    fi

    for lane in $running; do
        if grep -qE "^[^ ]+ ${lane} " "$MAP" 2>/dev/null; then
            continue                                   # already on screen
        fi
        t=$(tkey "$lane")
        # The previous stage of this ticket is still on screen exiting (chained
        # handoffs overlap briefly): wait a poll instead of splitting the
        # ticket's story across two panes.
        if awk -v t="$t" '$2 != "-" && $3 == t { found=1 } END { exit !found }' "$MAP" 2>/dev/null; then
            continue
        fi
        # Prefer the pane already stamped with this ticket; else any idle pane;
        # else split a new one under the cap.
        pane=$(awk -v t="$t" '$2 == "-" && $3 == t { print $1; exit }' "$MAP" 2>/dev/null || echo "")
        [ -n "$pane" ] || pane=$(awk '$2 == "-" { print $1; exit }' "$MAP" 2>/dev/null || echo "")
        if [ -n "$pane" ]; then
            grep -v "^$pane " "$MAP" > "$MAP.new" 2>/dev/null || :
            mv "$MAP.new" "$MAP" 2>/dev/null || :
        else
            if [ "$(wc -l < "$MAP" | tr -d ' ')" -ge "$MAX_PANES" ]; then
                # A lane with no pane must never be invisible: say so once, in
                # the ticker, where the human is already looking (build-3
                # wave 2 2026-08-02 — the ticker said "#16 implementation
                # begins", no pane appeared, and the human had to ask why).
                case " $WAITED " in *" $lane "*) ;; *)
                    WAITED="$WAITED $lane"
                    "$TICK" event viewer_note note "$lane waiting for a pane (cap $MAX_PANES)" >/dev/null 2>&1 || :
                ;; esac
                continue                               # at the cap; it waits
            fi
            # Stack down off the newest right-column pane. If that pane died
            # (humans tidy idle panes away), RE-ANCHOR on the bottom-most
            # live pane already in the column before ever starting a fresh
            # column: the old fallback split right off the session pane even
            # while the column was alive, dropping impl-39 into the left
            # region on top of the ticker (human, 2026-08-02). A fresh right
            # split is only for a fully vanished column.
            pane=""
            [ -n "$STACK_LAST" ] && pane=$(new_pane down "$STACK_LAST")
            if [ -z "$pane" ]; then
                last_live=""
                while read -r cand _; do
                    [ -n "$cand" ] && "$HERDR" pane process-info --pane "$cand" >/dev/null 2>&1 && last_live="$cand"
                done < "$MAP"
                [ -n "$last_live" ] && pane=$(new_pane down "$last_live")
            fi
            # Fresh column off the session pane — and the ONE place mid-run
            # that repeats the startup split, so it must repeat the startup
            # ORDER too. The ticker already sits under the session in the left
            # column, so splitting right now carves the new pane out of that
            # column and lands it on the ticker instead of opening a right
            # column at all. Close the ticker first, split the session while
            # it is full width again, then let it back in underneath. (Asked
            # for by the human, 2026-08-03.)
            if [ -z "$pane" ]; then
                reopen_ticker=""
                if [ -n "$TICKER_PANE" ]; then
                    "$HERDR" pane close "$TICKER_PANE" >/dev/null 2>&1 || :
                    TICKER_PANE=""
                    reopen_ticker=1
                fi
                pane=$(new_pane right "$HERDR_PANE_ID")
                # Unconditionally, even if the split failed: the ticker is the
                # human's only view of a build with no lane panes left.
                [ -n "$reopen_ticker" ] && ensure_ticker
            fi
            [ -n "$pane" ] || { echo "watch-panes: could not split a pane" >&2; continue; }
            STACK_LAST="$pane"
        fi
        # A pane the user closed makes this fail; drop it and try again next poll
        # rather than taking the whole viewer down with it.
        if "$HERDR" pane run "$pane" "$TICK render-log $lane --follow" >/dev/null 2>&1; then
            "$HERDR" pane rename "$pane" "$lane" >/dev/null 2>&1 || :
            printf '%s %s %s\n' "$pane" "$lane" "$t" >> "$MAP"
            echo "watch-panes: $lane (ticket $t) → $pane"
        else
            echo "watch-panes: pane $pane is gone; dropping it" >&2
        fi
    done

    # Test seam: a bounded run for the suite (real use never sets it).
    if [ -n "${WATCH_POLLS:-}" ]; then
        WATCH_POLLS=$((WATCH_POLLS - 1))
        [ "$WATCH_POLLS" -le 0 ] && exit 0
    fi
    sleep "$POLL"
done
