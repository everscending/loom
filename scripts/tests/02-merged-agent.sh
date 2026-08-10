#!/usr/bin/env bash
# one program that watches first, then maybe spends
#
# Section 02 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 4f. The merged agent: one program that watches first, then maybe spends -
#     Replaces a 900s scheduler that went BLIND whenever a wave held the lock
#     (it bailed at the lock before it stamped or classified anything) plus a
#     separate 60s watcher that existed only to cover that blindness. Watching
#     first makes the second program unnecessary. (Designed with the human,
#     2026-08-04.)
MT="$T/merged"; mkdir -p "$MT/repo" "$MT/home" "$MT/agents"
seed_tracker_decl "$MT/repo"
MENV() { LOOM_REPO="$MT/repo" LOOM_HOME="$MT/home" LOOM_PLIST_DIR="$MT/agents" \
         LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1 "$@"; }

# The default timer is 60s and the agent runs the AUTO mode, not a bare tick:
# a bare tick means "a human typed it" and would ignore both the switch and
# the gap, turning the timer into an unpaced spender.
out=$(MENV "$TICK" install --dry-run 2>&1)
mplist=$(echo "$out" | sed -n 's/^generated (dry-run): //p')
if [ -n "$mplist" ] && grep -q "<integer>60</integer>" "$mplist" \
   && grep -q "<string>--auto</string>" "$mplist"; then
    ok "merged agent: installs at 60s and fires 'tick --auto', not a bare tick"
else
    bad "merged agent: wrong interval or mode in $mplist"
fi

# stop writes the switch, start clears it. Without the clear, a started build
# would tick forever refusing to do anything.
MENV "$TICK" uninstall >/dev/null 2>&1
[ -f "$MT/home/loop.stopped" ] && ok "stop: writes the loop switch" \
                              || bad "stop: no switch written"
MENV "$TICK" install 60 >/dev/null 2>&1
[ ! -f "$MT/home/loop.stopped" ] && ok "start: clears the switch a previous stop left" \
                                 || bad "start: stale switch survived, build would never run"

# The three callers, three contracts. A wave is stubbed as a counter.
MWAVES="$MT/waves"
# NOTE: env must be EXPORTED, not prefixed onto a shell function — a prefix on
# a function call is not passed through to the command the function runs.
MTICK() { : > "$MWAVES"
          export LOOM_WAVE_CMD="sh -c 'echo w >> $MWAVES'"
          MENV "$TICK" "$@" >/dev/null 2>&1
          export LOOM_WAVE_CMD="true"; }
_mwaves() { [ -f "$MWAVES" ] && wc -l < "$MWAVES" | tr -d ' ' || echo 0; }

: > "$MT/home/loop.stopped"
MTICK tick --auto;      a=$(_mwaves)
MTICK tick --from-lane; b=$(_mwaves)
MTICK tick;             c=$(_mwaves)
if [ "$a" = 0 ] && [ "$b" = 0 ] && [ "$c" != 0 ]; then
    ok "loop switch: stopped silences the timer and lane handoffs, never a typed tick"
else
    bad "loop switch: auto=$a from-lane=$b manual=$c (want 0/0/non-zero)"
fi
rm -f "$MT/home/loop.stopped"

# P38: a lane must hand off through its own epilogue ('tick --from-lane'),
# never call a bare 'tick' itself — that takes the manual, always-runs
# contract in the foreground and can deadlock on its own pending replay.
# (build-3 2026-08-04, merge-68.)
: > "$MWAVES"
export LOOM_WAVE_CMD="sh -c 'echo w >> $MWAVES'"
out=$(LOOM_LANE_ID=merge-9 MENV "$TICK" tick 2>&1); rc_lane=$?
export LOOM_WAVE_CMD="true"
if [ "$rc_lane" != 0 ] && [ ! -d "$MT/home/tick.lock.d" ] && [ "$(_mwaves)" = 0 ] \
   && printf '%s' "$out" | grep -q -- "--from-lane"; then
    ok "tick: a lane self-invoking a bare tick is refused, no lock, no wave"
else
    bad "tick: lane self-invoke rc=$rc_lane lock=$([ -d "$MT/home/tick.lock.d" ] && echo held) waves=$(_mwaves) out=$out"
fi

# ...but the SAME environment through the epilogue's own contract still runs:
# the refusal must catch the wrong call, not the lane's environment itself.
export LOOM_LANE_ID=merge-9
MTICK tick --from-lane
unset LOOM_LANE_ID
[ "$(_mwaves)" != 0 ] && ok "tick: --from-lane still runs from inside a lane's own environment" \
                       || bad "tick: --from-lane was refused too — the epilogue itself would deadlock"

# BUT watching still happens on the silenced firings — that is the whole point
# of merging. A stopped auto-tick must still record that it looked.
rm -f "$MT/home/events.jsonl"; : > "$MT/home/loop.stopped"
MTICK tick --auto
grep -q '"reason":"loop_stopped"' "$MT/home/events.jsonl" 2>/dev/null \
    && ok "merged agent: a silenced tick still runs and records the pass" \
    || bad "merged agent: silenced tick left no trace ($(tail -1 "$MT/home/events.jsonl" 2>/dev/null))"
rm -f "$MT/home/loop.stopped"

# The gap paces spending, so the 60s timer costs nothing. A wave that just
# started blocks the next AUTO tick; a lane handoff ignores the gap, because a
# handoff is work already in progress and making it wait idles the build.
printf '{"t":"now","ts":%s,"ev":"wave_start"}\n' "$(date +%s)" > "$MT/home/events.jsonl"
MTICK tick --auto;      g1=$(_mwaves)
MTICK tick --from-lane; g2=$(_mwaves)
if [ "$g1" = 0 ] && [ "$g2" != 0 ]; then
    ok "wave gap: holds the timer back, never a lane handoff"
else
    bad "wave gap: auto=$g1 (want 0), from-lane=$g2 (want non-zero)"
fi
# An old wave is no longer a reason to wait.
printf '{"t":"old","ts":%s,"ev":"wave_start"}\n' "$(( $(date +%s) - 4000 ))" > "$MT/home/events.jsonl"
MTICK tick --auto
[ "$(_mwaves)" != 0 ] && ok "wave gap: expires, so the timer still backstops a stalled build" \
                      || bad "wave gap: never expired — the backstop is dead"

# Decision 4: stop cuts the direct handoffs too. The chain is spawned BY the
# lanes, so blocking waves alone would carry a ticket all the way to merged
# after the human asked it to stop.
: > "$MT/home/loop.stopped"
export LOOM_LANE_ID=impl-9
out=$(MENV "$TICK" spawn-lane gate-9 -- true 2>&1); rc_ch=$?
unset LOOM_LANE_ID
if [ "$rc_ch" = 0 ] && printf '%s' "$out" | grep -q "not chaining" \
   && [ ! -f "$MT/home/lanes/gate-9.pid" ]; then
    ok "stop: a lane cannot chain to its successor while the loop is stopped"
else
    bad "stop: chained spawn was not refused (rc=$rc_ch: $out)"
fi
# ...but a wave spawning is not a chained handoff, and must still work — that
# is how a typed `tick` gets anything done while stopped.
MENV "$TICK" spawn-lane impl-9 --no-tick -- sleep 5 >/dev/null 2>&1
[ -f "$MT/home/lanes/impl-9.pid" ] \
    && ok "stop: a wave's own spawn is not a chained handoff and still runs" \
    || bad "stop: blocked a non-chained spawn, so a typed tick could do nothing"

# stop --now kills what is running; plain stop leaves it alone to finish.
MENV "$TICK" uninstall --now >/dev/null 2>&1
sleep 0.3
if [ ! -f "$MT/home/lanes/impl-9.pid" ] \
   && grep -q '"ev":"lane_kill"' "$MT/home/events.jsonl" 2>/dev/null; then
    ok "stop --now: kills running workers through kill-lane, and records it"
else
    bad "stop --now: worker survived or the kill went unrecorded"
fi
MENV "$TICK" spawn-lane impl-8 --no-tick -- sleep 5 >/dev/null 2>&1
MENV "$TICK" uninstall >/dev/null 2>&1
if [ -f "$MT/home/lanes/impl-8.pid" ]; then
    ok "stop: plain stop leaves a running worker alone to finish its ticket"
else
    bad "stop-violation: plain stop killed a worker — that is what --now is for"
fi
MENV "$TICK" kill-lane impl-8 >/dev/null 2>&1
rm -f "$MT/home/loop.stopped"

# 4f2. `start` raises the viewer, and outranks both off-switches.
#      Before this, `start` armed an unattended build and opened no window on
#      it: only `watch` and a manual tick raised the panes. Worse, a `q` in one
#      build's ticker persisted, so the next build started blind.
#      (Asked for by the human, 2026-08-04.)
WPCAP="$MT/wp.calls"; WPSTUB="$MT/wp-stub.sh"
printf '#!/bin/sh\necho "wp $*" >> "%s"\n' "$WPCAP" > "$WPSTUB"; chmod +x "$WPSTUB"
export WATCH_PANES_CMD="$WPSTUB"

# Outside the multiplexer there are no panes to open, and no viewer to launch.
: > "$WPCAP"; export HERDR_ENV=0
MENV "$TICK" install 60 >/dev/null 2>&1
[ ! -s "$WPCAP" ] && ok "start: outside herdr, raises no viewer" \
                  || bad "start: launched a viewer with no multiplexer to put it in"

# Inside it, start launches the viewer AND clears both off-switches — a `q` in
# a previous build's ticker must not leave this one unwatched.
: > "$WPCAP"; export HERDR_ENV=1
touch "$MT/home/ticker-off" "$MT/home/viewer-off"
MENV "$TICK" install 60 >/dev/null 2>&1
sleep 0.3
if [ -s "$WPCAP" ] && [ ! -f "$MT/home/ticker-off" ] && [ ! -f "$MT/home/viewer-off" ]; then
    ok "start: raises the viewer and clears a quit ticker / an off viewer"
else
    bad "start: viewer=$(cat "$WPCAP") ticker-off=$([ -f "$MT/home/ticker-off" ] && echo yes) viewer-off=$([ -f "$MT/home/viewer-off" ] && echo yes)"
fi

# But ONLY start clears them. An automatic tick that undid a deliberate `q`
# would make the switch worthless — the human closed it 40 seconds ago.
: > "$WPCAP"; touch "$MT/home/ticker-off" "$MT/home/viewer-off"
MTICK tick --from-lane
if [ -f "$MT/home/ticker-off" ] && [ -f "$MT/home/viewer-off" ] && [ ! -s "$WPCAP" ]; then
    ok "off-switches: a tick never clears them, only a typed start does"
else
    bad "off-switches: a tick undid the human's close"
fi
rm -f "$MT/home/ticker-off" "$MT/home/viewer-off"

# A dry run generates the plist and touches nothing else.
: > "$WPCAP"; touch "$MT/home/ticker-off"
MENV "$TICK" install --dry-run >/dev/null 2>&1
[ ! -s "$WPCAP" ] && [ -f "$MT/home/ticker-off" ] \
    && ok "start --dry-run: no viewer, no switch cleared" \
    || bad "start --dry-run: had side effects"
rm -f "$MT/home/ticker-off"
# RESTORE, never unset: unsetting would hand every later test the real pane
# opener, which is exactly the accident this block is testing the fix for.
export WATCH_PANES_CMD="$WP_GLOBAL_STUB"; export HERDR_ENV=

# THE property the whole merge rests on: watching happens even while a wave
# holds the lock. The old scheduler bailed at the lock BEFORE it stamped or
# classified anything, so during a wave — the exact window in which a lane
# wedges — nothing was looking. That blindness is why a second 60s program had
# to exist. Here: a lane is running, the lock is held, and a tick that cannot
# start a wave must still leave a fresh progress stamp behind.
rm -rf "$MT/home/lanes" "$MT/home/tick.lock.d"; mkdir -p "$MT/home/lanes"
MENV "$TICK" spawn-lane impl-7 --no-tick -- sleep 5 >/dev/null 2>&1
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' \
    > "$MT/home/logs/lane-impl-7.jsonl"
mkdir -p "$MT/home/tick.lock.d"; echo $$ > "$MT/home/tick.lock.d/pid"   # a wave holds it
# No recent wave in the log, so the GAP cannot be what stops this tick — the
# lock must be, which is the path under test.
rm -f "$MT/home/events.jsonl" "$MT/home/lanes/impl-7.progress"
out=$(MENV "$TICK" tick --auto 2>&1)
if [ -f "$MT/home/lanes/impl-7.progress" ] && printf '%s' "$out" | grep -q "already running"; then
    ok "merged agent: a tick blocked by the lock STILL watches — the blindness the split existed to cover"
else
    bad "merged agent: locked-out tick did no watching — lanes=[$(MENV "$TICK" lane-status 2>&1 | tr '\n' ';')] jsonl=$([ -f "$MT/home/logs/lane-impl-7.jsonl" ] && echo yes || echo no) out=[$out]"
fi
rm -rf "$MT/home/tick.lock.d"
MENV "$TICK" kill-lane impl-7 >/dev/null 2>&1

# agent-status reports the SWITCH too. It used to print only whether the
# scheduler plist was loaded, so it said "not loaded" while a separate watcher
# ran fine — half an answer that read as "nothing is watching".
: > "$MT/home/loop.stopped"
out=$(MENV "$TICK" agent-status 2>&1)
printf '%s' "$out" | grep -qi "loop switch: STOPPED" \
    && ok "agent-status: reports the loop switch, not just the agent" \
    || bad "agent-status: switch state missing ($out)"
rm -f "$MT/home/loop.stopped"

test_finish
