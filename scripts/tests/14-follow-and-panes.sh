#!/usr/bin/env bash
# P24: following a live lane, and the herdr viewer
#
# Section 14 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 13. P24: following a live lane ----------------------------------------
# P13 taught the MACHINERY to tell a busy lane from a dead one; it did nothing
# for a person. The .log is written in one go at exit, so mid-run there is
# nothing readable to watch. --follow renders the stream instead.
# The repo the followed lanes belong to. Section 12 built the same one for the
# event record and this section used to inherit it.
ET="$T/ev"; mkdir -p "$ET/repo"
seed_tracker_decl "$ET/repo"
git -C "$ET/repo" init -q 2>/dev/null || git init -q "$ET/repo" 2>/dev/null || :
WT="$T/follow"; mkdir -p "$WT/home/lanes" "$WT/home/logs"
FENV() { LOOM_REPO="$ET/repo" LOOM_HOME="$WT/home" LOOM_GLOBAL_CONFIG="$ET/g.yml" \
         LOOM_SKIP_BOOTSTRAP=1 LOOM_FOLLOW_POLL=0.2 "$@"; }
FJ="$WT/home/logs/lane-impl-5.jsonl"
_say() { printf '{"schema":1,"type":"assistant_progress","provider":"codex","job":"implementation","text":"%s"}\n' "$1" >> "$FJ"; }
sleep 30 & FAKEPID=$!
echo "$FAKEPID" > "$WT/home/lanes/impl-5.pid"
# The session's own `system`/`init` record, which precedes any output it
# produces. Rendering it is what puts the model at the top of the pane
# (asked for by the human, 2026-08-03) — and a rate-limit record ahead of it
# is what the real stream opens with, so the model line must survive that.
printf '{"schema":1,"type":"limit","provider":"codex","job":"implementation","reset_at":null}\n' >> "$FJ"
printf '{"schema":1,"type":"session_start","provider":"codex","job":"implementation","requested_tier":"high","resolved_profile":{"model":"gpt-5.6-sol","reasoning_effort":"high"}}\n' >> "$FJ"
_say "first thing the lane said"
( FENV "$TICK" render-log impl-5 --follow > "$WT/out.txt" 2>&1 ) & FOLLOWER=$!
sleep 0.4
_say "something it said while being watched"
sleep 0.4
kill "$FAKEPID" 2>/dev/null || :
wait "$FOLLOWER" 2>/dev/null || :

case "$(cat "$WT/out.txt")" in
    *"first thing the lane said"*"something it said while being watched"*)
        ok "follow: renders what the lane wrote before AND during the watch" ;;
    *) bad "follow: missed events ($(tr '\n' '|' < "$WT/out.txt"))" ;;
esac
grep -q "lane impl-5 ended" "$WT/out.txt" \
    && ok "follow: exits on its own when the lane's process disappears" \
    || bad "follow: did not stop when the lane died"
# The model must be the FIRST thing rendered, not merely present somewhere:
# the point is knowing what a worker is running on before reading its output.
[ "$(grep -vE '^── lane ' "$WT/out.txt" | grep -c .)" -gt 0 ] \
    && [ "$(grep -vE '^── lane ' "$WT/out.txt" | grep . | head -1)" = "── provider codex · implementation · tier high · model gpt-5.6-sol · reasoning high ──" ] \
    && ok "follow: the resolved model is the first line of the pane" \
    || bad "follow: model line not first ($(grep -vE '^── lane ' "$WT/out.txt" | grep . | head -1))"
# Taken from the stream, so an alias or a usage-limit downshift shows what the
# session RESOLVED, not what the spawn line asked for.
grep -q "gpt-5.6-sol" "$WT/out.txt" \
    && ok "follow: the model shown is the one the session resolved" \
    || bad "follow: resolved model missing from the render"

# A gate starts with a plain-text pregate in lane-<id>.log, then changes over
# to canonical JSONL when the provider review starts. The viewer must span
# that handoff. The one-shot render below models the exit epilogue appending
# the rendered JSONL to .log; a follower that keeps reading both sources would
# print the provider turn twice.
sleep 30 & PREGATEPID=$!
echo "$PREGATEPID" > "$WT/home/lanes/gate-284.pid"
PREGATELOG="$WT/home/logs/lane-gate-284.log"
PREGATEJSONL="$WT/home/logs/lane-gate-284.jsonl"
printf '%s\n' '--- pregate: bash scripts/gate.sh unit ---' > "$PREGATELOG"
: > "$PREGATEJSONL"
( FENV "$TICK" render-log gate-284 --follow > "$WT/pregate-out.txt" 2>&1 ) & PREGATEFOLLOWER=$!
sleep 0.4
printf '%s\n' 'pregate checks are still running' >> "$PREGATELOG"
sleep 0.4
printf '%s\n' \
    '{"schema":1,"type":"assistant_progress","provider":"claude","job":"gate","text":"provider review is now live"}' \
    >> "$PREGATEJSONL"
sleep 0.4
FENV "$TICK" render-log gate-284
kill "$PREGATEPID" 2>/dev/null || :
wait "$PREGATEFOLLOWER" 2>/dev/null || :
rm -f "$WT/home/lanes/gate-284.pid"
if grep -q 'pregate: bash scripts/gate.sh unit' "$WT/pregate-out.txt" \
   && grep -q 'pregate checks are still running' "$WT/pregate-out.txt" \
   && [ "$(grep -c 'provider review is now live' "$WT/pregate-out.txt")" -eq 1 ]; then
    ok "follow: a gate pane spans pregate log and provider stream without duplicate review output"
else
    bad "follow: gate handoff lost or duplicated output ($(tr '\n' '|' < "$WT/pregate-out.txt"))"
fi

# Planted violation: remove only the plain-log read from a private tick.sh.
# The same public follower then reproduces the empty pregate pane while still
# proving that the mutant ran through its normal header and exit.
FOLLOWMUT=$(mirror_scripts "$WT/follow-mutant")
sed 's/^        if \[ "\$stream_started" -eq 0 \] && \[ -s "\$log" \]; then$/        if false; then/' \
    "$TICK" > "$FOLLOWMUT/tick.sh"
chmod +x "$FOLLOWMUT/tick.sh"
if cmp -s "$TICK" "$FOLLOWMUT/tick.sh"; then
    bad "follow-violation: sed did not match the pregate-log guard, mutant is identical to the fix"
else
    sleep 30 & MUTPID=$!
    echo "$MUTPID" > "$WT/home/lanes/gate-285.pid"
    printf '%s\n' 'pregate visible only through the plain log' > "$WT/home/logs/lane-gate-285.log"
    : > "$WT/home/logs/lane-gate-285.jsonl"
    ( FENV "$FOLLOWMUT/tick.sh" render-log gate-285 --follow > "$WT/mutant-out.txt" 2>&1 ) & MUTFOLLOWER=$!
    sleep 0.4
    kill "$MUTPID" 2>/dev/null || :
    wait "$MUTFOLLOWER" 2>/dev/null; mut_rc=$?
    rm -f "$WT/home/lanes/gate-285.pid"
    mut_out=$(cat "$WT/mutant-out.txt")
    if assert_mutant_ran "$mut_rc" "$mut_out" "follow-violation"; then
        if ! grep -q 'pregate visible only through the plain log' "$WT/mutant-out.txt" \
           && grep -q 'lane gate-285 ended' "$WT/mutant-out.txt"; then
            ok "follow-violation: without the log handoff a live pregate pane is empty"
        else
            bad "follow-violation: removing the log handoff did not reproduce the empty pane ($mut_out)"
        fi
    fi
fi

# 13a. Planted violation: the exit epilogue owns lane-<id>.log. A follower that
#      appended to it would corrupt the very artifact it is watching, so a
#      viewer writes to stdout and nothing else.
if [ -e "$WT/home/logs/lane-impl-5.log" ]; then
    bad "follow-violation: the follower wrote to the log the epilogue owns"
else
    ok "follow-violation: following writes to stdout, never to lane-<id>.log"
fi

# 13b. Read-only means no lock, no pid file, no event — that is what makes it
#      safe to point several viewers at one lane, and keeps a viewer from ever
#      being mistaken for a lane.
[ "$(ls "$WT/home/lanes" | tr -d ' ')" = "impl-5.pid" ] \
    && ok "follow: a viewer leaves no lane state behind" \
    || bad "follow: the follower wrote into the lanes dir ($(ls "$WT/home/lanes" | tr '\n' ' '))"
[ -s "$WT/home/events.jsonl" ] \
    && bad "follow: the follower recorded an event" \
    || ok "follow: a viewer records no event"

# 13c. Several viewers on one lane, because following is a file read.
sleep 30 & FAKE2=$!
echo "$FAKE2" > "$WT/home/lanes/impl-6.pid"
printf '{"schema":1,"type":"assistant_progress","provider":"claude","job":"implementation","text":"shared"}\n' \
    > "$WT/home/logs/lane-impl-6.jsonl"
( FENV "$TICK" render-log impl-6 --follow > "$WT/a.txt" 2>&1 ) & V1=$!
( FENV "$TICK" render-log impl-6 --follow > "$WT/b.txt" 2>&1 ) & V2=$!
sleep 0.4; kill "$FAKE2" 2>/dev/null || :; wait "$V1" "$V2" 2>/dev/null || :
if grep -q shared "$WT/a.txt" && grep -q shared "$WT/b.txt"; then
    ok "follow: two viewers can watch one lane at once"
else
    bad "follow: concurrent viewers interfered"
fi

FENV "$TICK" render-log impl-5 --bogus >/dev/null 2>&1 \
    && bad "follow: an unknown option was accepted" \
    || ok "follow: an unknown option is refused rather than treated as a lane id"
FENV "$TICK" render-log no-such-lane --follow >/dev/null 2>&1 \
    && bad "follow: followed a lane that does not exist" \
    || ok "follow: a lane with no pid file and no stream is refused"

# 13d. The pane opener is an accessory: it must refuse outside herdr rather than
#      degrade, and the UNATTENDED machinery must never call it.
#      Narrowed 2026-08-04. This used to be a text grep — tick.sh was not
#      allowed to contain the word "herdr" at all — and `install` now breaks
#      that letter deliberately: `start` raises the viewer, so arming a build
#      and opening a window on it are one gesture. What the rule protects is
#      unchanged and is now tested directly: nothing that runs without a human
#      at the keyboard may touch the pane opener.
HERDR_ENV= bash "$(dirname "$TICK")/watch-panes.sh" >/dev/null 2>&1 \
    && bad "watch-panes: ran outside a herdr session" \
    || ok "watch-panes: refuses to run outside herdr instead of degrading"
WPT="$T/wp-layer"; mkdir -p "$WPT/repo" "$WPT/home" "$WPT/agents"
seed_tracker_decl "$WPT/repo"
WPCALLS="$WPT/calls"
printf '#!/bin/sh\necho called >> "%s"\n' "$WPCALLS" > "$WPT/stub"; chmod +x "$WPT/stub"
: > "$WPCALLS"
# HERDR_ENV=1 throughout: a lane inherits its parent's environment, so the
# multiplexer variable IS set in the unattended paths. Only the caller decides.
(  export HERDR_ENV=1 WATCH_PANES_CMD="$WPT/stub" LOOM_WAVE_CMD=true
   export LOOM_REPO="$WPT/repo" LOOM_HOME="$WPT/home" LOOM_PLIST_DIR="$WPT/agents"
   export LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1
   "$TICK" tick --auto      >/dev/null 2>&1 || :
   "$TICK" tick --from-lane >/dev/null 2>&1 || :
   "$TICK" snapshot         >/dev/null 2>&1 || :
   "$TICK" spawn-lane impl-1 --no-tick -- true >/dev/null 2>&1 || : ) || :
sleep 0.3
if [ ! -s "$WPCALLS" ]; then
    ok "watch-panes: no unattended path — tick, wave, snapshot, spawn — calls the pane opener"
else
    bad "watch-panes-violation: the unattended machinery opened panes ($(wc -l < "$WPCALLS") calls)"
fi
# And what launchd actually runs must carry no trace of the multiplexer.
out=$(LOOM_REPO="$WPT/repo" LOOM_HOME="$WPT/home" LOOM_PLIST_DIR="$WPT/agents" \
      LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1 \
      "$TICK" install --dry-run 2>&1)
wplist=$(echo "$out" | sed -n 's/^generated (dry-run): //p')
if [ -n "$wplist" ] && ! grep -qiE 'herdr|watch-panes' "$wplist"; then
    ok "watch-panes: the installed agent has no idea herdr exists"
else
    bad "watch-panes-violation: the launchd agent references the multiplexer"
fi

# Controller, ownership, active-only reconciliation, and viewer layout
# contracts live in the adjacent 14-viewer-durability.sh section.
test_finish
