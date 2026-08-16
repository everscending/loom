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

# 13e. Singleton: `/loom tick` launches the viewer opportunistically on
#      every manual tick, so a second launch must exit 0 quietly instead of
#      opening a duplicate pane per lane (2026-08-02). A live pid in the
#      state-dir pidfile short-circuits before the herdr checks; a stale one
#      does not.
echo $$ > "$LOOM_HOME/watch-panes.pid"
out=$(HERDR_ENV= bash "$(dirname "$TICK")/watch-panes.sh" 2>&1); rc_wp=$?
case "$rc_wp:$out" in 0:*"already running"*) \
    ok "watch-panes: second launch exits quietly when one is live";; \
    *) bad "watch-panes: singleton failed (rc=$rc_wp: $out)";; esac
echo 999999 > "$LOOM_HOME/watch-panes.pid"
HERDR_ENV= bash "$(dirname "$TICK")/watch-panes.sh" >/dev/null 2>&1 \
    && bad "watch-panes-violation: stale pidfile still short-circuited" \
    || ok "watch-panes: a stale pidfile does not block a fresh launch"
rm -f "$LOOM_HOME/watch-panes.pid"

# 13f. The ticker is kept alive every poll, not opened once at startup: the
#      viewer is a singleton that can outlive its panes, and launch-on-tick
#      exits at the pidfile — so a startup-only ticker is unrecoverable once
#      its pane dies. (Paid for: build-3 wave 1 2026-08-02 — a between-builds
#      viewer survived with its ticker pane long gone and the human watched a
#      four-lane wave with no ticker.) The stub's process-info always fails,
#      so every poll must reopen: startup + 2 bounded polls ≥ 2 ticker runs;
#      the old startup-only code produces exactly 1.
cat > "$T/herdr-stub" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${HERDR_CALLS:?}"
# Optional: the moment the ticker starts streaming, plant the off-marker —
# deterministic stand-in for "the human ran `ticker off` mid-run" (13g).
case "$*" in *"render-events --follow"*) [ -n "${HERDR_TOUCH_ON_RUN:-}" ] && touch "$HERDR_TOUCH_ON_RUN" ;; esac
# Liveness: with HERDR_DEAD unset, every pane reads dead (13f's reopen loop).
# With it set, only listed panes are dead — and splitting OFF a dead pane
# fails, as real herdr does (13i).
tgt=""; prev=""
for a in "$@"; do [ "$prev" = "--pane" ] && tgt="$a"; prev="$a"; done
dead() { [ -n "${HERDR_DEAD+x}" ] || return 0; case " $HERDR_DEAD " in *" $1 "*) return 0;; *) return 1;; esac; }
case "$1 $2" in
    "pane split")        if [ -n "${HERDR_DEAD+x}" ] && [ -n "$tgt" ] && dead "$tgt"; then exit 1; fi
                         n=$(wc -l < "$HERDR_CALLS" | tr -d ' '); echo "{\"result\":{\"pane\":{\"pane_id\":\"stub:p$n\"}}}" ;;
    "pane process-info") if dead "$tgt"; then exit 1; fi ;;
    # What the viewer re-anchors against (13n). HERDR_PANE_LIST unset means a
    # herdr with no panes left to offer, which is the fatal branch.
    "pane list")         printf '{"result":{"panes":['; s=""
                         for p in ${HERDR_PANE_LIST:-}; do printf '%s{"pane_id":"%s"}' "$s" "$p"; s=","; done
                         printf ']}}\n' ;;
    # The column geometry the rebalance reads (13q). Every pane this stub ever
    # split is reported in ONE column — same x/width — with the halving heights
    # a real column decays into, so the deltas are real. stub:p0 (the launching
    # session pane) is reported in that same column as a decoy: it is not in the
    # viewer's MAP, so a working MAP filter must never resize it. HERDR_NO_LAYOUT
    # is a herdr that cannot answer; HERDR_ZOOMED is a human reading one pane.
    "pane layout")       [ -n "${HERDR_NO_LAYOUT:-}" ] && exit 1
                         awk -v z="${HERDR_ZOOMED:-}" '
                            /^pane split/ { n++; ln[n] = NR }
                            END {
                              printf "{\"result\":{\"layout\":{\"zoomed\":%s,\"panes\":[", (z != "" ? "true" : "false")
                              printf "{\"pane_id\":\"stub:p0\",\"rect\":{\"x\":100,\"y\":0,\"width\":50,\"height\":1}}"
                              y = 1; h = 40
                              for (i = 1; i <= n; i++) {
                                printf ",{\"pane_id\":\"stub:p%d\",\"rect\":{\"x\":100,\"y\":%d,\"width\":50,\"height\":%d}}", ln[i], y, h
                                y += h; h = (h >= 4 ? int(h / 2) : 2)
                              }
                              printf "]}}}\n"
                            }' "$HERDR_CALLS" ;;
esac
exit 0
EOF
chmod +x "$T/herdr-stub"
mkdir -p "$T/wp13f-home"; : > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    LOOM_HOME="$T/wp13f-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=0 \
    bash "$(dirname "$TICK")/watch-panes.sh" >/dev/null 2>&1 || :
tn=$(grep -c "render-events --follow" "$T/herdr-calls" || :)
if [ "$tn" -ge 2 ]; then
    ok "watch-panes: a dead ticker pane is reopened on the next poll"
else
    bad "watch-panes: ticker opened $tn time(s) across 2 polls — startup-only regression"
fi

# 13g. The deliberate off-gesture: reopen-every-poll (13f) ate the natural
#      "Ctrl-C, close the pane" gesture, so `ticker off|on` parks/removes a
#      state-dir marker the poll loop honors — off closes a live ticker and
#      keeps it closed; on brings it back. (Asked for by the human,
#      2026-08-02.) The verb needs no herdr and no running viewer.
WP="$(dirname "$TICK")/watch-panes.sh"
out=$(LOOM_HOME="$T/wp13f-home" bash "$WP" ticker off 2>&1) \
    && [ -f "$T/wp13f-home/ticker-off" ] \
    && ok "watch-panes: 'ticker off' plants the marker from any terminal" \
    || bad "watch-panes: ticker off failed ($out)"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    LOOM_HOME="$T/wp13f-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
tn=$(grep -c "render-events --follow" "$T/herdr-calls" || :)
[ "$tn" -eq 0 ] \
    && ok "watch-panes: the off-marker suppresses the ticker across polls" \
    || bad "watch-panes: ticker opened $tn time(s) despite the off-marker"
LOOM_HOME="$T/wp13f-home" bash "$WP" ticker on >/dev/null 2>&1 \
    && [ ! -f "$T/wp13f-home/ticker-off" ] \
    && ok "watch-panes: 'ticker on' clears the marker" \
    || bad "watch-panes: ticker on left the marker behind"

# 13g-raise. `/loom watch` uses `raise`, which clears BOTH switches, where `on`
#      clears the viewer switch alone and leaves a deliberate `ticker off`
#      standing. Without it a `q` pressed earlier makes `watch` raise a viewer
#      that closes its own ticker every poll, and the human reads a setting as
#      a broken viewer. (Paid for: build-3 2026-08-05.)
touch "$T/wp13f-home/ticker-off" "$T/wp13f-home/viewer-off"
HERDR_ENV= LOOM_HOME="$T/wp13f-home" bash "$WP" raise >/dev/null 2>&1 || :
if [ ! -f "$T/wp13f-home/ticker-off" ] && [ ! -f "$T/wp13f-home/viewer-off" ]; then
    ok "watch-panes: 'raise' clears both the ticker and viewer switches"
else
    bad "watch-panes: raise left ticker-off=$([ -f "$T/wp13f-home/ticker-off" ] && echo yes || echo no) viewer-off=$([ -f "$T/wp13f-home/viewer-off" ] && echo yes || echo no)"
fi
# `on` must NOT touch the ticker switch — the two axes stay independent, so a
# human can keep the panes and drop the strip.
touch "$T/wp13f-home/ticker-off" "$T/wp13f-home/viewer-off"
HERDR_ENV= LOOM_HOME="$T/wp13f-home" bash "$WP" on >/dev/null 2>&1 || :
if [ -f "$T/wp13f-home/ticker-off" ] && [ ! -f "$T/wp13f-home/viewer-off" ]; then
    ok "watch-panes: 'on' leaves a deliberate ticker-off standing"
else
    bad "watch-panes: 'on' wrongly cleared the ticker switch"
fi
rm -f "$T/wp13f-home/ticker-off" "$T/wp13f-home/viewer-off"
# Mid-run off: the stub plants the marker the instant the ticker starts
# streaming; the next poll must CLOSE the live ticker pane, not just stop
# reopening it.
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_TOUCH_ON_RUN="$T/wp13f-home/ticker-off" \
    LOOM_HOME="$T/wp13f-home" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
rm -f "$T/wp13f-home/ticker-off"
grep -q "^pane close " "$T/herdr-calls" \
    && ok "watch-panes: a mid-run off-marker closes the live ticker pane" \
    || bad "watch-panes: off-marker arrived mid-run but the ticker pane was never closed"

# 13h. The pane cap follows the build's width, and a lane waiting at the cap
#      is announced in the ticker, never silently invisible. `max_lanes` caps
#      implementers only — aux lanes (gate/merge/probe) run beside them — so
#      a flat cap of 4 hid a fifth lane with no trace (build-3 wave 2
#      2026-08-02: ticker said "#16 implementation begins", no pane appeared,
#      the human had to ask). Cap default = max_lanes + 2; WATCH_MAX_PANES
#      still overrides.
mkdir -p "$T/wp-cap-repo" "$T/wp-cap-home"
printf 'max_lanes: 7\n' > "$T/wp-cap-repo/.loom.yml"
: > "$T/herdr-calls"
out=$(HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    LOOM_REPO="$T/wp-cap-repo" LOOM_HOME="$T/wp-cap-home" LOOM_GLOBAL_CONFIG="$T/none.yml" \
    WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" 2>/dev/null || :)
case "$out" in *"up to 9 panes"*) ok "watch-panes: pane cap derives from max_lanes (+2 aux)";; \
    *) bad "watch-panes: cap did not derive from max_lanes ($(echo "$out" | head -1))";; esac
# Two lanes, cap 1: the second must leave a viewer_note in the event stream,
# and the ticker must render it.
mkdir -p "$T/wp-cap-home/lanes"
echo $$ > "$T/wp-cap-home/lanes/impl-91.pid"
echo $$ > "$T/wp-cap-home/lanes/impl-92.pid"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    LOOM_REPO="$T/wp-cap-repo" LOOM_HOME="$T/wp-cap-home" \
    WATCH_MAX_PANES=1 WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" >/dev/null 2>&1 || :
grep -q '"viewer_note"' "$T/wp-cap-home/events.jsonl" 2>/dev/null \
    && ok "watch-panes: a lane at the pane cap writes a viewer_note event" \
    || bad "watch-panes: lane waited at the cap with no trace in the event stream"
LOOM_HOME="$T/wp-cap-home" "$TICK" render-events 2>/dev/null | grep -q "viewer: impl-9[12] waiting for a pane (cap 1)" \
    && ok "ticker: a cap-waiting lane renders as a viewer line" \
    || bad "ticker: viewer_note did not render"
rm -f "$T/wp-cap-home/lanes"/impl-9*.pid

# 13i. Layout: when the stack anchor dies (humans tidy idle panes) but the
#      right column is alive, a new lane RE-ANCHORS on the bottom-most live
#      column pane — never a fresh right split off the session pane, which
#      dropped impl-39 into the left region on top of the ticker (human,
#      2026-08-02). Pane ids are pinned to the stub's call counter: anchor
#      = call 1 → stub:p1; lane92's split = call 6 → stub:p6 (the pane the
#      test then kills); the only --direction right split allowed is call 1.
mkdir -p "$T/wp13i-home/lanes"
for n in 91 92 93; do echo $$ > "$T/wp13i-home/lanes/impl-$n.pid"; done
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_DEAD="stub:p6" WATCH_TICKER=0 WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13i-home" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
rights=$(grep -c -- "--direction right" "$T/herdr-calls" || :)
if [ "$rights" = 1 ] && grep -q -- "split --pane stub:p1 --direction down" "$T/herdr-calls"; then
    ok "watch-panes: dead stack anchor re-anchors on a live column pane"
else
    bad "watch-panes: re-anchor failed (right-splits=$rights, calls: $(grep split "$T/herdr-calls" | tail -3 | tr '\n' ';'))"
fi
rm -f "$T/wp13i-home/lanes"/impl-9*.pid

# 13k. Same layout invariant, the OTHER branch: when the column has vanished
#      entirely, the viewer reopens it off the session pane — and must repeat
#      the STARTUP ORDER while doing so (close ticker → split right → reopen
#      ticker), or the new pane is carved out of the left column and lands on
#      the ticker. (Asked for by the human, 2026-08-03.) Setup: the anchor
#      (stub:p1) is dead, so lane 91 takes it, lane 92 cannot split down off
#      it, and no live column pane remains to re-anchor on — the fresh-right
#      path, with a live ticker to move out of the way first.
mkdir -p "$T/wp13k-home/lanes"
for n in 91 92; do echo $$ > "$T/wp13k-home/lanes/impl-$n.pid"; done
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_DEAD="stub:p1" WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13k-home" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
close_ln=$(grep -n "^pane close " "$T/herdr-calls" | head -1 | cut -d: -f1)
right_ln=$(grep -n -- "--direction right" "$T/herdr-calls" | tail -1 | cut -d: -f1)
tick_ln=$(grep -n -- "render-events --follow" "$T/herdr-calls" | tail -1 | cut -d: -f1)
ticks=$(grep -c -- "render-events --follow" "$T/herdr-calls" || :)
if [ -n "$close_ln" ] && [ -n "$right_ln" ] && [ -n "$tick_ln" ] \
   && [ "$close_ln" -lt "$right_ln" ] && [ "$right_ln" -lt "$tick_ln" ] && [ "$ticks" -ge 2 ]; then
    ok "watch-panes: a fresh column closes the ticker, splits right, reopens it"
else
    bad "watch-panes: ticker was not moved out of the way for a fresh column (close=$close_ln right=$right_ln ticker=$tick_ln runs=$ticks)"
fi
rm -f "$T/wp13k-home/lanes"/impl-9*.pid

# 13l. The viewer needs its OWN off-switch, not just the ticker's. Until now,
#      closing everything meant killing the process by its pidfile from a
#      command someone had to be told — and the header's "Ctrl-C to stop" is
#      true only of a foreground run, while the skill launches this detached
#      on purpose. So in normal use there was no way to stop it. (Asked for by
#      the human, 2026-08-04.)
VH="$T/viewer-off-home"; mkdir -p "$VH/lanes"
out=$(LOOM_HOME="$VH" bash "$WP" off 2>&1)
[ -f "$VH/viewer-off" ] && ok "watch-panes: 'off' plants the viewer switch from any terminal" \
                        || bad "watch-panes: off did not plant the switch ($out)"
# The switch outranks every launch path — including the opportunistic launch a
# manual tick does, which would otherwise undo the human on the next tick.
: > "$T/herdr-calls"
out=$(HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    LOOM_HOME="$VH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" 2>&1)
if [ ! -s "$T/herdr-calls" ] && printf '%s' "$out" | grep -q "switched off"; then
    ok "watch-panes: a switched-off viewer refuses to launch and opens no panes"
else
    bad "watch-panes: off-switch did not stop a launch ($(head -c 120 "$T/herdr-calls"))"
fi
LOOM_HOME="$VH" bash "$WP" on >/dev/null 2>&1
[ ! -f "$VH/viewer-off" ] && ok "watch-panes: 'on' clears the viewer switch" \
                          || bad "watch-panes: on left the switch behind"
# Mid-run: a viewer already polling must notice the switch and close its panes
# on the way out, since it can outlive the session that started it.
mkdir -p "$VH/lanes"; echo $$ > "$VH/lanes/impl-77.pid"
: > "$T/herdr-calls"
# Wait for the viewer to be genuinely up (pidfile written) before switching
# it off — startup reads config and can outlast a fixed sleep, and planting
# the marker first would test the startup path instead of the mid-run one.
( for _ in $(seq 1 40); do
      [ -f "$VH/watch-panes.pid" ] && break; sleep 0.1
  done
  LOOM_HOME="$VH" bash "$WP" off >/dev/null 2>&1 ) &
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 LOOM_HOME="$VH" WATCH_POLLS=10 WATCH_POLL_SECONDS=0.3 bash "$WP" >/dev/null 2>&1 || :
wait 2>/dev/null || :
grep -q "^pane close " "$T/herdr-calls" \
    && ok "watch-panes: a mid-run 'off' closes the panes it owns and exits" \
    || bad "watch-panes: mid-run off left panes open ($(grep -c . "$T/herdr-calls") calls)"
rm -f "$VH/lanes/impl-77.pid" "$VH/viewer-off"

# 13m. The ticker advertises its own quit key, and the words for both the hint
#      and the reopen come from HERE — tick.sh must never learn this viewer
#      exists (13-violation enforces that), so it prints what it is handed.
grep -q "LOOM_TICKER_QUIT_HINT" "$WP" && grep -q "LOOM_TICKER_REOPEN_HINT" "$WP" \
    && ok "watch-panes: supplies the ticker's quit hint and reopen wording" \
    || bad "watch-panes: ticker hints are not passed to the follow command"
# And the quit key must leave the SAME durable marker the off-switch uses, or
# the viewer would simply reopen the pane on its next poll.
grep -q 'ticker-off' "$TICK" \
    && ok "ticker: quitting leaves the durable marker, so it stays closed" \
    || bad "ticker: quit does not persist — the viewer would reopen the pane"

# 13p. A concluded ticket takes its pane with it however it concluded (P41).
#      Panes are recycled on purpose, so a finished lane keeps its ticket
#      stamp — but the "did the ticket actually close" read ran for merge-*
#      alone, so a ticket closed any other way left its pane stamped forever.
#      #72 was reclassified and closed by hand on 2026-08-04 and its pane sat
#      labelled "ticket 72 — idle" for work that would never come back.
cat > "$T/glab-p41-stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"issues/95"*) echo '{"state":"closed"}' ;;
    *"issues/96"*) echo '{"state":"opened"}' ;;
    *"issues/97"*) exit 1 ;;                      # tracker unreachable
    *) echo '{}' ;;
esac
EOF
chmod +x "$T/glab-p41-stub.sh"
mkdir -p "$T/wp13p-home/lanes"
sleep 1.5 & echo $! > "$T/wp13p-home/lanes/gate-95.pid"
sleep 1.5 & echo $! > "$T/wp13p-home/lanes/impl-96.pid"
sleep 1.5 & echo $! > "$T/wp13p-home/lanes/gate-97.pid"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    GLAB_CMD="$T/glab-p41-stub.sh" WATCH_TICKER=0 WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13p-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=1.7 \
    bash "$WP" >/dev/null 2>&1 || :
[ "$(grep -c "^pane close " "$T/herdr-calls" || :)" = 1 ] \
    && ok "watch-panes: a gate lane whose ticket closed takes its pane with it" \
    || bad "watch-panes: expected exactly 1 close (the closed ticket), got $(grep -c '^pane close ' "$T/herdr-calls" || :)"
grep -q "rename .* ticket 96 — idle" "$T/herdr-calls" \
    && ok "watch-panes: an open ticket keeps its pane and its stamp" \
    || bad "watch-panes: the open ticket lost its pane — reuse is broken"
grep -q "rename .* ticket 97 — idle" "$T/herdr-calls" \
    && ok "watch-panes: a failed tracker read keeps the pane, as before" \
    || bad "watch-panes: an unreachable tracker closed a pane it could not judge"
rm -f "$T/wp13p-home/lanes"/*.pid
# Planted violation: put the read back behind merge-* and the closed ticket
# keeps its pane — the stale stamp the human spotted.
# The copy needs tick.sh beside it: the viewer finds tick.sh by its own
# directory, so a copy alone in $T resolves nothing and dies before it can
# prove anything. And tick.sh needs lib.sh beside IT (P73), for the same
# reason it needs snapshot.jq — the shared derivations ship as a sibling file.
mkdir -p "$T/wpmod"; ln -sf "$TICK" "$T/wpmod/tick.sh"
link_trackers "$T/wpmod"
ln -sf "$(dirname "$TICK")/lib.sh" "$T/wpmod/lib.sh"   # P73: tick.sh sources it
sed 's/\*)  # P41/merge-*)  # P41/' "$WP" > "$T/wpmod/wp-mergeonly.sh"; chmod +x "$T/wpmod/wp-mergeonly.sh"
mkdir -p "$T/wp13p2-home/lanes"
sleep 0.3 & echo $! > "$T/wp13p2-home/lanes/gate-95.pid"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    GLAB_CMD="$T/glab-p41-stub.sh" WATCH_TICKER=0 WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13p2-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=0.6 \
    bash "$T/wpmod/wp-mergeonly.sh" >/dev/null 2>&1 || :
grep -q "^pane close " "$T/herdr-calls" \
    && bad "watch-panes-violation: the merge-only check still closed the pane" \
    || ok "watch-panes-violation: with merge-* alone, a closed ticket keeps its pane forever"
rm -f "$T/wp13p2-home/lanes"/*.pid

# 13p2. P46: a `stale` lane's pane must not be released — the process still
#       holds the ticket, it is only quiet. Same real-lane fixture, pointed at
#       a config that makes any existing log read stale on sight.
WPQ_REPO="$T/wp13q-repo"; mkdir -p "$WPQ_REPO"
printf 'heartbeat_stale_minutes: 0\n' > "$WPQ_REPO/.loom.yml"
mkdir -p "$T/wp13q-home/lanes" "$T/wp13q-home/logs"
sleep 30 & echo $! > "$T/wp13q-home/lanes/impl-96.pid"
touch -t 202001010000 "$T/wp13q-home/logs/lane-impl-96.log"
: > "$T/herdr-calls"
LOOM_REPO="$WPQ_REPO" HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    GLAB_CMD="$T/glab-p41-stub.sh" WATCH_TICKER=0 WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13q-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=0.6 \
    bash "$WP" >/dev/null 2>&1 || :
kill "$(cat "$T/wp13q-home/lanes/impl-96.pid" 2>/dev/null)" 2>/dev/null
if grep -Eq "rename [^ ]+ impl-96$" "$T/herdr-calls" \
   && ! grep -q -- "— idle" "$T/herdr-calls" \
   && ! grep -q "^pane close " "$T/herdr-calls"; then
    ok "watch-panes: a stale-but-alive lane's pane stays live, not idle (P46)"
else
    bad "watch-panes: stale lane pane mishandled ($(grep -E 'rename|close' "$T/herdr-calls" | tr '\n' ';'))"
fi
rm -f "$T/wp13q-home/lanes"/*.pid

# 13n. A viewer that cannot open a pane says so and exits, instead of polling
#      forever looking healthy (P39). Every split hangs off the pane the
#      viewer was launched from; when that session is gone the id refers to
#      nothing, every split fails, and the empty string `new_pane` returns
#      used to read as "skip this". build-3 2026-08-04, 12:46→12:59: the
#      process was alive the whole time and opened nothing — no anchor, no
#      ticker, no lane panes — while two lanes ran unseen.
NH="$T/wp13n-home"; mkdir -p "$NH/lanes"; : > "$T/herdr-calls"
out=$(HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_DEAD="stub:p0" WATCH_TICKER=0 LOOM_HOME="$NH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$WP" 2>&1); rc_n=$?
if [ "$rc_n" != 0 ] && printf '%s' "$out" | grep -q "stub:p0" && printf '%s' "$out" | grep -q "exiting"; then
    ok "watch-panes: a viewer with a dead anchor exits non-zero and names it"
else
    bad "watch-panes: blind viewer survived (rc=$rc_n: $(printf '%s' "$out" | tr '\n' ' ' | head -c 140))"
fi
# Exiting is only useful if it releases the singleton — otherwise every later
# launch path still reports "already running" against a viewer showing nothing.
[ ! -f "$NH/watch-panes.pid" ] \
    && ok "watch-panes: a blind viewer leaves no pidfile holding the singleton" \
    || bad "watch-panes: the dead viewer kept the pidfile — nothing can replace it"
# The other direction: with a live pane to re-anchor on, the viewer recovers
# and opens its column there rather than dying. stub:p0 is the dead launching
# pane and is skipped; stub:p9 is what herdr still has.
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_DEAD="stub:p0" HERDR_PANE_LIST="stub:p0 stub:p9" WATCH_TICKER=0 \
    LOOM_HOME="$NH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" >/dev/null 2>&1; rc_n=$?
if [ "$rc_n" = 0 ] && grep -q -- "split --pane stub:p9 --direction right" "$T/herdr-calls"; then
    ok "watch-panes: a dead anchor re-anchors on a live pane instead of dying"
else
    bad "watch-panes: re-anchor failed (rc=$rc_n, calls: $(grep split "$T/herdr-calls" | tr '\n' ';'))"
fi
# Planted violation: strip the fatal call and the identical run polls on and
# exits 0 — the exact 13-minute shape, a healthy-looking process showing
# nothing. `wp_blind ` → `: ` leaves the function definition alone.
# The copy needs tick.sh beside it — the viewer finds tick.sh by its own
# directory, so a copy alone in $T resolves nothing and dies at 127 before it
# can prove anything.
mkdir -p "$T/wpmod"; ln -sf "$TICK" "$T/wpmod/tick.sh"
ln -sf "$(dirname "$TICK")/lib.sh" "$T/wpmod/lib.sh"   # P73: tick.sh sources it
sed 's/wp_blind /: /' "$WP" > "$T/wpmod/wp-noblind.sh"; chmod +x "$T/wpmod/wp-noblind.sh"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_DEAD="stub:p0" WATCH_TICKER=0 LOOM_HOME="$NH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$T/wpmod/wp-noblind.sh" >/dev/null 2>&1; rc_n=$?
[ "$rc_n" = 0 ] \
    && ok "watch-panes-violation: without the fatal exit the blind viewer runs on" \
    || bad "watch-panes-violation: rc=$rc_n — something other than wp_blind ended the run"

# 13o. The singleton pidfile is removed only while it still names this
#      process (P40). The trap used to delete it unconditionally, so an older
#      viewer shutting down took a newer one's file with it — found live on
#      2026-08-04: pid 1805 running with no pidfile at all. Stand-in for the
#      overlap: overwrite the file with a foreign pid once the viewer is up,
#      the way a newer viewer would.
PH="$T/wp13o-home"; mkdir -p "$PH/lanes"; : > "$T/herdr-calls"
( for _ in $(seq 1 40); do
      [ -f "$PH/watch-panes.pid" ] && break; sleep 0.1
  done
  echo 999999 > "$PH/watch-panes.pid" ) &
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 LOOM_HOME="$PH" WATCH_POLLS=3 WATCH_POLL_SECONDS=0.3 bash "$WP" >/dev/null 2>&1 || :
wait 2>/dev/null || :
[ "$(cat "$PH/watch-panes.pid" 2>/dev/null)" = 999999 ] \
    && ok "watch-panes: an exiting viewer keeps a pidfile it no longer owns" \
    || bad "watch-panes: the exiting viewer deleted another viewer's pidfile"
# And it still cleans up after itself in the ordinary case, or every crashed
# viewer would block the next launch forever.
rm -f "$PH/watch-panes.pid"; : > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 LOOM_HOME="$PH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" >/dev/null 2>&1 || :
[ ! -f "$PH/watch-panes.pid" ] \
    && ok "watch-panes: a viewer that owns its pidfile removes it on exit" \
    || bad "watch-panes: pidfile survived its own viewer — the next launch is blocked"
# Planted violation: remove the ownership test and the foreign pidfile goes
# with it, which is how a live viewer ends up with none.
sed 's/_owns_pidfile &&/: \&\&/' "$WP" > "$T/wpmod/wp-noown.sh"; chmod +x "$T/wpmod/wp-noown.sh"
( for _ in $(seq 1 40); do
      [ -f "$PH/watch-panes.pid" ] && break; sleep 0.1
  done
  echo 999999 > "$PH/watch-panes.pid" ) &
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 LOOM_HOME="$PH" WATCH_POLLS=3 WATCH_POLL_SECONDS=0.3 \
    bash "$T/wpmod/wp-noown.sh" >/dev/null 2>&1 || :
wait 2>/dev/null || :
[ ! -f "$PH/watch-panes.pid" ] \
    && ok "watch-panes-violation: without the check the foreign pidfile is deleted" \
    || bad "watch-panes-violation: pidfile survived, so the ownership test proves nothing"

# 13j. A finished STORY closes its pane (2026-08-02): probe pane closes when
#      its lane ends; a merge pane closes only if the ticket really closed —
#      merge lanes exit cleanly without merging (merge-21, twice), so a
#      blocked merge keeps its pane idle. Lanes live at poll 1, die before
#      poll 2 (their pid is a short sleep).
cat > "$T/glab-close-stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"issues/95"*) echo '{"state":"closed"}' ;;
    *"issues/96"*) echo '{"state":"opened"}' ;;
    *) echo '{}' ;;
esac
EOF
chmod +x "$T/glab-close-stub.sh"
mkdir -p "$T/wp13j-home/lanes"
sleep 1.5 & echo $! > "$T/wp13j-home/lanes/merge-95.pid"
sleep 1.5 & echo $! > "$T/wp13j-home/lanes/merge-96.pid"
sleep 1.5 & echo $! > "$T/wp13j-home/lanes/probe-e9.pid"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    GLAB_CMD="$T/glab-close-stub.sh" WATCH_TICKER=0 WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13j-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=1.7 \
    bash "$WP" >/dev/null 2>&1 || :
closes=$(grep -c "^pane close " "$T/herdr-calls" || :)
[ "$closes" = 2 ] \
    && ok "watch-panes: merged ticket and finished probe close their panes" \
    || bad "watch-panes: expected 2 pane closes (merged + probe), got $closes"
grep -q "rename .* ticket 96 — idle" "$T/herdr-calls" \
    && ok "watch-panes: a merge that did not merge keeps its pane idle" \
    || bad "watch-panes: blocked-merge pane was not kept"
rm -f "$T/wp13j-home/lanes"/*.pid

# 13q. The right column is evened out when a lane pane opens, and only then
#      (P44). Every lane pane is split off the newest pane with no ratio, so
#      herdr halves it and the column decays 1/2, 1/4, 1/8 — measured live
#      2026-08-05 at 24/21/10/10 rows where equal is 16. The stub reports that
#      decay; the viewer must move every divider except the last one's.
#      Pane ids follow the stub's call counter, as in 13i: with the ticker off,
#      the anchor is stub:p1 (call 1), lane 92's split is call 6 → stub:p6, and
#      lane 93's is call 9 → stub:p9. The bottom pane has no divider below it.
QH="$T/wp13q-home"; mkdir -p "$QH/lanes"
for n in 91 92 93; do echo $$ > "$QH/lanes/impl-$n.pid"; done
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 WATCH_MAX_PANES=9 LOOM_HOME="$QH" WATCH_POLLS=2 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
rs=$(grep -c "^pane resize " "$T/herdr-calls" || :)
# Two polls, three lanes: poll 1 opens the panes and rebalances once, poll 2
# opens nothing and must resize nothing. A human who drags a divider to read
# one lane keeps that size until the next lane arrives.
if [ "$rs" = 2 ] \
   && grep -q -- "pane resize --pane stub:p1 --direction up" "$T/herdr-calls" \
   && grep -q -- "pane resize --pane stub:p6 --direction up" "$T/herdr-calls"; then
    ok "watch-panes: a new lane pane evens out the column above it"
else
    bad "watch-panes: expected 2 resizes of stub:p1 and stub:p6, got $rs ($(grep '^pane resize' "$T/herdr-calls" | tr '\n' ';'))"
fi
grep -q -- "pane resize --pane stub:p9" "$T/herdr-calls" \
    && bad "watch-panes: resized the bottom pane, which has no divider below it" \
    || ok "watch-panes: the bottom pane of the column is left alone"
# The safety rule: the viewer resizes only panes it owns. stub:p0 is the loom
# session pane and the stub reports it in the same column as a decoy; the
# ticker is never tracked in MAP either. Neither may ever be resized — that is
# what keeps this to the RIGHT column and off the ticker's 25% strip.
grep -q -- "pane resize --pane stub:p0" "$T/herdr-calls" \
    && bad "watch-panes: resized the loom session pane — the MAP filter is broken" \
    || ok "watch-panes: never resizes the session pane it split from"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_MAX_PANES=9 LOOM_HOME="$QH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
tp=$(grep -n -- "render-events --follow" "$T/herdr-calls" | head -1 | cut -d: -f1)
if [ -n "$tp" ] && ! grep -q -- "pane resize --pane stub:p$((tp - 1))" "$T/herdr-calls"; then
    ok "watch-panes: the ticker strip keeps its own size"
else
    bad "watch-panes: the ticker pane was resized by the column rebalance"
fi
# A column of two is already 50/50 from herdr's own split default: nothing to move.
rm -f "$QH/lanes"/impl-93.pid; : > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 WATCH_MAX_PANES=9 LOOM_HOME="$QH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
[ "$(grep -c "^pane resize " "$T/herdr-calls" || :)" = 0 ] \
    && ok "watch-panes: a two-pane column is left as herdr split it" \
    || bad "watch-panes: resized a column with no divider worth moving"
echo $$ > "$QH/lanes/impl-93.pid"
# Fails soft, both ways: a herdr that cannot report geometry, and a human
# zoomed into one pane. Panes still open in both cases — deleting herdr from
# the machine leaves the build unaffected, and a cosmetic pass must not be the
# thing that breaks that.
for mode in HERDR_NO_LAYOUT HERDR_ZOOMED; do
    : > "$T/herdr-calls"
    env "$mode=1" HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 \
        HERDR_PANE_ID=stub:p0 WATCH_TICKER=0 WATCH_MAX_PANES=9 LOOM_HOME="$QH" \
        WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" >/dev/null 2>&1 || :
    if [ "$(grep -c "^pane resize " "$T/herdr-calls" || :)" = 0 ] \
       && [ "$(grep -c "render-log" "$T/herdr-calls" || :)" -ge 3 ]; then
        ok "watch-panes: $mode — no resize, and the lane panes still open"
    else
        bad "watch-panes: $mode left $(grep -c '^pane resize ' "$T/herdr-calls" || :) resizes / $(grep -c 'render-log' "$T/herdr-calls" || :) lane panes"
    fi
done
# Planted violation: cut the rebalance call and the column decays untouched,
# which is the shape the human measured. The copy needs tick.sh beside it, as
# in 13n — the viewer finds tick.sh by its own directory.
mkdir -p "$T/wpmod"; ln -sf "$TICK" "$T/wpmod/tick.sh"
ln -sf "$(dirname "$TICK")/lib.sh" "$T/wpmod/lib.sh"   # P73: tick.sh sources it
sed 's/&& rebalance_column .*$/|| :/' "$WP" > "$T/wpmod/wp-nobalance.sh"
chmod +x "$T/wpmod/wp-nobalance.sh"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 WATCH_MAX_PANES=9 LOOM_HOME="$QH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$T/wpmod/wp-nobalance.sh" >/dev/null 2>&1 || :
[ "$(grep -c "^pane resize " "$T/herdr-calls" || :)" = 0 ] \
    && ok "watch-panes-violation: without the call the column is never evened out" \
    || bad "watch-panes-violation: something other than rebalance_column issued a resize"
rm -f "$QH/lanes"/impl-9*.pid

test_finish
