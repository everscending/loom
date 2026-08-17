#!/usr/bin/env bash
# the build ticker, and every lane.sh verb that feeds it
#
# Section 16 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# 16. The build ticker (2026-08-02): lane.sh verbs feed the event stream,
#     render-events turns it into timestamped human lines, and a corrupt
#     line must not kill a --follow pane that runs for a whole build.
LANE="$(dirname "$TICK")/lane.sh"
EVH="$T/ev-home"; mkdir -p "$EVH"
# P86: answers every read with an empty ARRAY rather than with nothing at all.
# A list read that returns no bytes is an unreadable tracker, and the driver
# says so instead of parsing silence as emptiness (P49's rule, now applied to
# lane.sh's reads too).
GSTUB="$T/glab-ok.sh"
cat > "$GSTUB" <<'GSEOF'
#!/bin/sh
# P86: the driver maps every response into loom's shape, so a stub has to
# answer in the right KIND — an array for a list endpoint, an object for a
# single read. Answering everything with nothing at all (the old `exit 0`) is
# an unreadable tracker now, and the driver says so rather than parsing
# silence as emptiness.
case "$*" in
  *notes*|*links*|*closed_by*|*related_merge_requests*|*labels*|*milestones*|*"issues?"*|*"merge_requests?"*) echo "[]" ;;
  *) echo "{}" ;;
esac
exit 0
GSEOF
chmod +x "$GSTUB"
LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" "$LANE" transition 4 review >/dev/null 2>&1
echo "gate looks good" | LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" "$LANE" verdict 4 pass abcd1234 >/dev/null 2>&1
grep -q '"ev":"ticket_transition"' "$EVH/events.jsonl" 2>/dev/null \
    && ok "ticker: lane.sh transition appended its event" \
    || bad "ticker: lane.sh transition wrote no event"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"#4 → review (implementation complete, awaiting gate)"*) \
    ok "ticker: transition renders as a human line";; \
    *) bad "ticker: transition rendered wrong ($out)";; esac
case "$out" in *"#4 gate verdict: PASS @ abcd1234"*) \
    ok "ticker: verdict renders outcome and sha";; \
    *) bad "ticker: verdict rendered wrong ($out)";; esac
printf '%s\n' "$out" | grep -Ev '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}  ' | grep -q . \
    && bad "ticker: a line is missing its local timestamp prefix ($out)" \
    || ok "ticker: every line carries a local timestamp prefix"
# Planted violation: raw jq dies on a corrupt line; fromjson? is the guard.
# Later events must still render after garbage lands mid-stream.
echo 'not json at all' >> "$EVH/events.jsonl"
LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" "$LANE" close 4 >/dev/null 2>&1
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"#4 merged and closed"*) \
    ok "ticker: a corrupt line does not kill the stream";; \
    *) bad "ticker: corrupt line broke rendering ($out)";; esac
# Clean exits are suppressed (their outcome event tells the story; chained
# handoffs stamp them after the successor spawned, which rendered backwards) —
# but failures and probe results must still show.
LOOM_HOME="$EVH" "$TICK" event lane_exit id impl-4 type impl rc 0 secs 5
LOOM_HOME="$EVH" "$TICK" event lane_exit id gate-4 type gate rc 7 secs 5
LOOM_HOME="$EVH" "$TICK" event lane_exit id probe-audio type probe rc 0 secs 5
LOOM_HOME="$EVH" "$TICK" event lane_exit id impl-6 type impl rc 0 provider_rc 2 outcome review secs 5
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"implementation ended"*) \
    bad "ticker: clean impl exit rendered (reads backwards after a chained spawn)";; \
    *) ok "ticker: clean impl exit suppressed — outcome events tell the story";; esac
case "$out" in *"#4 — pregate REJECTED"*) \
    ok "ticker: a pregate rejection still renders";; \
    *) bad "ticker: pregate rejection missing ($out)";; esac
case "$out" in *"epic audio — acceptance probe ended (rc 0"*) \
    ok "ticker: a clean probe exit still renders (it has no outcome event)";; \
    *) bad "ticker: probe exit missing ($out)";; esac
case "$out" in *"#6 — implementation ended"*|*"impl-6"*) \
    bad "ticker: completed implementation was repainted as a provider failure ($out)";; \
    *) ok "ticker: semantic completion stays quiet even when raw provider rc is nonzero";; esac
# A wave's intent line (long silent setup) renders verbatim with the
# "wave:" prefix — the human watching a quiet ticker during probe prep
# read the silence as a stall (2026-08-02).
LOOM_HOME="$EVH" "$TICK" event wave_note note "preparing probe worktrees for E2, E3"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"wave: preparing probe worktrees for E2, E3"*) \
    ok "ticker: a wave_note intent line renders";; \
    *) bad "ticker: wave_note missing ($out)";; esac
# The renderer owns the prefix, so a note that writes its own is deduped, not
# doubled ("wave: wave: only #47 is ready" — human, 2026-08-03). Case and
# spacing vary because a model types it, so the strip must too.
LOOM_HOME="$EVH" "$TICK" event wave_note note "wave: only #47 is ready"
LOOM_HOME="$EVH" "$TICK" event wave_note note "Wave:  spinning up the E5 probe"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"wave: wave:"*|*"wave: Wave:"*) \
    bad "ticker: a self-prefixed wave_note rendered doubled ($(printf '%s' "$out" | grep -c 'wave: [Ww]ave:') line(s))";; \
    *) ok "ticker: a note that writes its own 'wave:' prefix is deduped";; esac
# P95: one invariant — stripping preserves the note text — proved against
# two literal variants (plain lowercase, mixed-case with extra spacing) in
# one loop, replacing two near-identical case blocks that asserted the same
# thing twice.
strip_ok=1
for kept in "only #47 is ready" "spinning up the E5 probe"; do
    case "$out" in *"wave: $kept"*) ;; *) strip_ok=0; bad "ticker: dedupe ate or mangled '$kept' ($out)";; esac
done
[ "$strip_ok" = "1" ] \
    && ok "ticker: stripping the prefix keeps the note text intact, case- and space-insensitively" || :
# Planted violation: a note that merely MENTIONS a wave mid-sentence must not
# be truncated — the strip is anchored to the start, not a search-and-replace.
LOOM_HOME="$EVH" "$TICK" event wave_note note "requeued after the wave: see #12"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"wave: requeued after the wave: see #12"*) \
    ok "ticker: 'wave:' inside a note is left alone";; \
    *) bad "ticker: the strip is not anchored to the start ($out)";; esac
# Notifications land in the ticker too — a banner is transient, a push may
# be missed; the pane must carry the same stalled/wedged/complete facts.
NTFY_CMD=/usr/bin/true LOOM_HOME="$EVH" "$TICK" notify ticket_blocked "T9 blocked — decision needed" "b" >/dev/null 2>&1
grep -q '"ev":"notify"' "$EVH/events.jsonl" 2>/dev/null \
    && ok "ticker: a delivered notification writes its event" \
    || bad "ticker: notify left no event line"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"⚑ T9 blocked — decision needed"*) \
    ok "ticker: a notification renders with its title";; \
    *) bad "ticker: notification missing from render ($out)";; esac
# Failure lines stand out (asked for by the human, 2026-08-02): a glyph in
# the plain bytes always, ANSI color only on a tty or under LOOM_COLOR=1 —
# so pipes, greps and these very assertions see stable bytes by default.
echo "regression in error handling" | LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" "$LANE" verdict 5 fail beef1234 --class error-handling >/dev/null 2>&1
LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" "$LANE" transition 6 blocked >/dev/null 2>&1
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"✗ #5 gate verdict: FAIL @ beef1234"*) \
    ok "ticker: a FAIL verdict wears the failure glyph";; \
    *) bad "ticker: FAIL verdict not glyphed ($out)";; esac
case "$out" in *"⚠ #6 → blocked — a human decision is needed"*) \
    ok "ticker: a blocked transition wears the warning glyph";; \
    *) bad "ticker: blocked transition not glyphed ($out)";; esac
printf '%s\n' "$out" | grep -q $'\033' \
    && bad "ticker: escape codes leaked into non-tty output" \
    || ok "ticker: plain bytes when output is not a terminal"
cout=$(LOOM_COLOR=1 LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
printf '%s\n' "$cout" | grep -q $'\033\[1;31m' \
    && ok "ticker: LOOM_COLOR=1 paints failure lines red" \
    || bad "ticker: forced color produced no red escape"
# Probe outcomes reach the ticker through one verb (asked for by the human,
# 2026-08-02): probe-result posts the report on the Build issue AND emits the
# event — before this, the outcome lived only in prose and the ticker ended
# at "probe ended (rc 0)" with no verdict.
echo "epic exercised end to end, no defects" | LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" \
    "$LANE" probe-result 36 e4 pass >/dev/null 2>&1
echo "2 fix tickets filed" | LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" \
    "$LANE" probe-result 36 e5 fail >/dev/null 2>&1
echo "Chromium denied a Mach service before page open" | LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" \
    "$LANE" probe-result 36 e2 infrastructure >/dev/null 2>&1
grep -q '"ev":"probe_result"' "$EVH/events.jsonl" 2>/dev/null \
    && ok "ticker: probe-result appended its event" \
    || bad "ticker: probe-result wrote no event"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"✓ epic e4 — acceptance probe PASSED"*) \
    ok "ticker: probe PASS renders highlighted";; \
    *) bad "ticker: probe pass rendered wrong ($out)";; esac
case "$out" in *"✗ epic e5 — acceptance probe FAILED (fix tickets filed)"*) \
    ok "ticker: probe FAIL renders highlighted";; \
    *) bad "ticker: probe fail rendered wrong ($out)";; esac
case "$out" in *"⚠ epic e2 — acceptance probe blocked by infrastructure (no product fix filed)"*) \
    ok "D-TICK-34: infrastructure probe is explicit and does not claim a product fix";; \
    *) bad "D-TICK-34: infrastructure probe rendered as a product failure ($out)";; esac
# The requested Loom tier and provider are visible without parsing a native
# command line. A custom test-seam command has neither and stays quiet.
printf '{"ts":1,"ev":"lane_spawn","id":"impl-46","provider":"codex","tier":"high"}\n' >> "$EVH/events.jsonl"
LOOM_HOME="$EVH" "$TICK" spawn-lane impl-47 -- /bin/echo plain >/dev/null 2>&1
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"#46 — implementation started (codex, high tier)"*) \
    ok "ticker: a lane names its provider and requested tier";; \
    *) bad "ticker: escalation not shown ($(printf '%s' "$out" | grep '#4[67]'))";; esac
case "$out" in *"#47 — implementation started (custom)"*) \
    ok "ticker: a custom test-seam lane is identified without inventing a native model";; \
    *) bad "ticker: custom lane runtime metadata wrong";; esac
LOOM_HOME="$EVH" "$TICK" clear-lane impl-47 >/dev/null 2>&1

# 16n. The ticker stops announcing a replay that is not going to happen (P42).
#      `tick_skipped` fires for three unrelated reasons and the renderer
#      collapsed all of them into one sentence. That was harmless while the
#      timer was a 15-minute backstop; the merged 60s scheduler made wave_gap
#      the routine outcome, so on 2026-08-04 the human watched 408 of those
#      lines go by, 253 of them false — that path writes no pending file and
#      no replay follows. wave_gap now stays in the log for `retro` and never
#      renders; lock_held renders once per wave; loop_stopped keeps its own.
SKH="$T/skip-home"; mkdir -p "$SKH"
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason wave_gap
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason wave_gap
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason lock_held first 1
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason lock_held first 0
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason lock_held first 0
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason loop_stopped
LOOM_HOME="$SKH" "$TICK" event tick_replayed
out=$(LOOM_HOME="$SKH" "$TICK" render-events 2>&1)
printf '%s\n' "$out" | grep -qi "wave_gap\|under .*m ago" \
    && bad "ticker: a wave_gap skip still reached the ticker ($out)" \
    || ok "ticker: a timer declining to spend renders nothing at all"
n=$(printf '%s\n' "$out" | grep -c "a tick landed during a wave" || :)
[ "$n" = 1 ] \
    && ok "ticker: three ticks bouncing off one wave render a single line" \
    || bad "ticker: lock_held rendered $n time(s) for one wave, expected 1"
printf '%s\n' "$out" | grep -q "the loop is stopped — this tick did nothing" \
    && ok "ticker: a tick that found the loop stopped keeps its own line" \
    || bad "ticker: loop_stopped lost its distinct line ($out)"
printf '%s\n' "$out" | grep -q "pending tick replayed" \
    && ok "ticker: an actual replay still renders" \
    || bad "ticker: tick_replayed stopped rendering ($out)"
# The skips are still IN the log — retro counts them, and this is the whole
# reason wave_gap is dropped at the renderer rather than at the emitter.
[ "$(grep -c '"reason":"wave_gap"' "$SKH/events.jsonl")" = 2 ] \
    && ok "ticker: wave_gap is suppressed in the ticker, not lost from the log" \
    || bad "ticker: wave_gap events went missing from events.jsonl"
# A log written before P42 has no "first" field; those lines must still read
# the way they did, or replaying old history rewrites it.
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason lock_held
LOOM_HOME="$SKH" "$TICK" render-events 2>&1 | grep -c "a tick landed during a wave" | grep -qx 2 \
    && ok "ticker: a pre-P42 lock_held event still renders" \
    || bad "ticker: an event with no 'first' field vanished from an old log"
# The emitter half, against the real lock: only the tick that RAISES the
# pending flag is marked, however many bounce off afterwards.
LKH="$T/skip-lock-home"; mkdir -p "$LKH"
LOOM_HOME="$LKH" LOOM_WAVE_CMD="sleep 3" "$TICK" tick >/dev/null 2>&1 &
skpid=$!; sleep 0.7
LOOM_HOME="$LKH" LOOM_WAVE_CMD="echo no" "$TICK" tick >/dev/null 2>&1
LOOM_HOME="$LKH" LOOM_WAVE_CMD="echo no" "$TICK" tick >/dev/null 2>&1
wait "$skpid" 2>/dev/null || :
f1=$(grep -cE '"reason":"lock_held","first":"?1"?' "$LKH/events.jsonl" || :)
f0=$(grep -cE '"reason":"lock_held","first":"?0"?' "$LKH/events.jsonl" || :)
{ [ "$f1" = 1 ] && [ "$f0" = 1 ]; } \
    && ok "tick: the flag-raising bounce is marked, the repeat is not" \
    || bad "tick: expected one first=1 and one first=0 lock_held, got $f1/$f0"
# Planted violation: collapse the three reasons back into one sentence and the
# false line returns — proving the branch, not the fixture, is what suppresses
# it. The copy needs every sibling .jq file beside it, as tick.sh ships with
# (P71: the ticker program that carries this branch now lives in
# render-events.jq, not inline in tick.sh, so the mutation targets that file).
mkdir -p "$T/tickmod"
for jf in snapshot.jq render.jq usage.jq report.jq report-ticket.jq retro.jq graph.jq lib.sh lib.jq; do
    ln -sf "$(dirname "$TICK")/$jf" "$T/tickmod/$jf"
done
link_trackers "$T/tickmod"
cp "$TICK" "$T/tickmod/tick.sh"; chmod +x "$T/tickmod/tick.sh"
sed '/elif $e.ev == "tick_skipped"/,/elif $e.ev == "tick_replayed"/s/else empty end)/else "tick landed mid-wave — remembered for replay" end)/g' \
    "$(dirname "$TICK")/render-events.jq" > "$T/tickmod/render-events.jq"
LOOM_HOME="$SKH" "$T/tickmod/tick.sh" render-events 2>&1 | grep -q "tick landed mid-wave" \
    && ok "ticker-violation: with one sentence for all three, the false line is back" \
    || bad "ticker-violation: the collapsed renderer printed nothing — the test proves nothing"

# 16a. probe-result PASS closes the epic's milestone; FAIL leaves it open
#      (fix tickets land in that very milestone). Slug matching is on the
#      normalized title, so bare "e5" and full "e5-cascade-mode" both close
#      "E5 · Cascade mode" and nothing else. (Asked for by the human,
#      2026-08-02 — complete epics sat open in the tracker.)
MCAP="$T/milestone-calls"; : > "$MCAP"
cat > "$T/glab-milestones.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${MCAP:?}"
case "$*" in
    *"milestones?state=active"*) echo '[{"id":55,"title":"E5 · Cascade mode"},{"id":56,"title":"E6 · Provider swaps"}]' ;;
    *) echo '{}' ;;
esac
EOF
chmod +x "$T/glab-milestones.sh"
echo "clean run" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-milestones.sh" MCAP="$MCAP" \
    "$LANE" probe-result 36 e5 pass >/dev/null 2>&1
grep -q "milestones/55" "$MCAP" && ! grep -q "milestones/56" "$MCAP" \
    && ok "probe-result: PASS closes the matching milestone and only that one" \
    || bad "probe-result: milestone close calls wrong ($(grep milestones/ "$MCAP" | head -2))"
: > "$MCAP"
echo "defects found" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-milestones.sh" MCAP="$MCAP" \
    "$LANE" probe-result 36 e5 fail >/dev/null 2>&1
grep -q "state_event=close" "$MCAP" \
    && bad "probe-result: FAIL closed a milestone — fix tickets land there" \
    || ok "probe-result: FAIL leaves the milestone open"

# 16a2. kill-lane kills the TREE, not just the wrapper: a bare kill orphans
#       the agent session inside, which keeps working and keeps writing —
#       an orphaned impl-29-r2 pushed, flipped its held ticket to review,
#       chained a gate, and #29 merged through a human hold (2026-08-02).
"$TICK" spawn-lane impl-88 -- bash -c 'sleep 60 & wait' >/dev/null
sleep 1
wpid=$(cat "$LOOM_HOME/lanes/impl-88.pid" 2>/dev/null || echo "")
kpids="$wpid $(pgrep -P "$wpid" 2>/dev/null | tr '\n' ' ')"
"$TICK" kill-lane impl-88 >/dev/null 2>&1
sleep 1
survivors=0
for p in $kpids; do kill -0 "$p" 2>/dev/null && survivors=$((survivors+1)); done
if [ "$survivors" = 0 ] && [ ! -f "$LOOM_HOME/lanes/impl-88.pid" ]; then
    ok "kill-lane: wrapper AND descendants dead, lane cleared"
else
    bad "kill-lane: $survivors survivor(s) of [$kpids] or pid file left"
fi
out=$(LOOM_HOME="$LOOM_HOME" "$TICK" render-events 2>/dev/null | grep "impl-88\|#88" | tail -1)
case "$out" in *"⚠ #88 — implementation killed (whole tree)"*) \
    ok "ticker: a killed lane renders with the warning glyph";; \
    *) bad "ticker: lane_kill rendered wrong ($out)";; esac

# 16a3. `blocked` is STICKY: labels are last-writer-wins, so without this an
#       in-flight lane stomps a human hold (#29, 2026-08-02). Every advance
#       bounces off a blocked ticket; only re-blocking may touch it freely, and
#       the release direction needs `--release-hold` from a human caller (P36).
cat > "$T/glab-blocked-stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"--method PUT"*|*"--method POST"*) echo "$*" >> "${BCAP:?}"; echo '{}' ;;
    *"issues/50"*) echo '{"iid":50,"labels":["build-3","blocked","tier::api"]}' ;;
    *"issues/51"*) echo '{"iid":51,"labels":["build-3","review","tier::api"]}' ;;
    *) echo '{}' ;;
esac
EOF
chmod +x "$T/glab-blocked-stub.sh"
BCAP2="$T/blocked-writes"; : > "$BCAP2"
GB() { LOOM_HOME="$EVH" GLAB_CMD="$T/glab-blocked-stub.sh" BCAP="$BCAP2" "$LANE" "$@"; }
GB transition 50 review >/dev/null 2>&1 && bad "sticky-blocked: transition advanced a blocked ticket" \
    || ok "sticky-blocked: transition to review bounces off a hold"
echo r | GB verdict 50 pass abcd1234 >/dev/null 2>&1 && bad "sticky-blocked: verdict advanced a blocked ticket" \
    || ok "sticky-blocked: a gate verdict bounces off a hold"
GB close 50 >/dev/null 2>&1 && bad "sticky-blocked: close closed a blocked ticket" \
    || ok "sticky-blocked: close bounces off a hold"
grep -q "add_labels\|state_event=close" "$BCAP2" \
    && bad "sticky-blocked: a state write reached the tracker despite the hold" \
    || ok "sticky-blocked: no state write reached the tracker"
# P36: the unblock direction is no longer a free pass. It was — `ready-for-agent`
# skipped the guard entirely — so releasing a hold was a plain label write any
# automated caller could make, and one did: a hold comment ended with the
# sentence "Release: when #48 merges, /loom unblock 67", and a wave read
# that prose as an instruction addressed to itself and requeued the held ticket
# nine seconds later. (Paid for: #67, build-3 2026-08-04.)
GB transition 50 ready-for-agent >/dev/null 2>&1 \
    && bad "sticky-blocked: a hold was released without --release-hold" \
    || ok "sticky-blocked: releasing a hold needs --release-hold said out loud"
: > "$BCAP2"
GB transition 50 ready-for-agent --release-hold >/dev/null 2>&1 \
    && ok "sticky-blocked: a human releasing the hold still works" \
    || bad "sticky-blocked: --release-hold refused for a human caller"
test -f "$EVH/continuation.request" \
    && ok "sticky-blocked: a human hold release requests a heartbeat continuation" \
    || bad "sticky-blocked: released work can remain stranded behind the wave gap"
# The same release, from inside a lane and from inside a wave: refused. These
# are the only two callers that can act on ticket prose, and the env markers
# are set by the loop itself, not by the caller asking nicely.
rm -f "$EVH/continuation.request"
: > "$BCAP2"
LOOM_LANE_ID=impl-50 GB transition 50 ready-for-agent --release-hold >/dev/null 2>&1 \
    && bad "sticky-blocked: a lane released a human hold" \
    || ok "sticky-blocked: a lane cannot release a human hold, even with the flag"
LOOM_WAVE_PROMPT="/loom tick" GB transition 50 ready-for-agent --release-hold >/dev/null 2>&1 \
    && bad "sticky-blocked: a wave released a human hold" \
    || ok "sticky-blocked: a wave cannot release a human hold, even with the flag"
grep -q "add_labels" "$BCAP2" \
    && bad "sticky-blocked: an automated release still reached the tracker" \
    || ok "sticky-blocked: no automated release write reached the tracker"
[ ! -f "$EVH/continuation.request" ] \
    && ok "sticky-blocked: refused automated release requested no continuation" \
    || bad "sticky-blocked: refused automated release nudged the scheduler"
# `unblock --to-review` routes through the same door: the human completed the
# work by hand, so it goes back to the gate rather than to the backlog. Before
# P36 this direction had no door at all — `review` bounced with nothing to say.
GB transition 50 review --release-hold >/dev/null 2>&1 \
    && ok "sticky-blocked: a human can release a hold straight to review" \
    || bad "sticky-blocked: --to-review has no way past the guard"
GB transition 51 review >/dev/null 2>&1 \
    && ok "sticky-blocked: an unblocked ticket still advances normally" \
    || bad "sticky-blocked: guard blocked a ticket with no hold"

# 16a4. P30: a FAIL verdict names its defect class machine-readably in the
#       trailer, so the next gate and the snapshot can match consecutive
#       same-class rejections (#39, 2026-08-02). Slugs are kebab-only.
cat > "$T/glab-body-stub.sh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" >> "${VCAP:?}" ;; esac; done
# P86: answer in the KIND the endpoint returns. The driver maps each response
# into loom's shape, so a list read must get an array and a single read an
# object; `verdict`'s duplicate check reads the notes thread, where an object
# is a malformed response rather than "no duplicate".
case "$*" in
  *notes*|*links*|*closed_by*|*related_merge_requests*|*labels*|*milestones*|*"issues?"*) echo '[]' ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$T/glab-body-stub.sh"
VCAP2="$T/verdict-bodies"; : > "$VCAP2"
echo "same trap" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP2" \
    "$LANE" verdict 8 fail beef5678 --class marks-attribution >/dev/null 2>&1
grep -q "orch-verdict FAIL beef5678 class=marks-attribution" "$VCAP2" \
    && ok "verdict: --class folds the defect class into the trailer" \
    || bad "verdict: class missing from trailer ($(tail -2 "$VCAP2" 2>/dev/null))"
echo x | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP2" \
    "$LANE" verdict 8 fail beef5678 --class "Bad Slug" >/dev/null 2>&1 \
    && bad "verdict: accepted a non-kebab class slug" \
    || ok "verdict: a non-kebab class slug is refused"
echo y | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP2" \
    "$LANE" verdict 8 pass beef5678 >/dev/null 2>&1 \
    && ok "verdict: class stays optional" \
    || bad "verdict: classless verdict refused"

# 16a4c. P69: the verdict verb enforces its own trailer instead of relying on
#        SKILL.md prose — three builds running produced unclassed FAILs,
#        spurious classes on PASS trailers and duplicate trailers because
#        nothing in the verb itself checked (ai-workout build-1, 2026-08-07:
#        #5's two FAIL trailers with no class same SHA; spurious
#        class=logic / class=regex-tier-match on PASS; duplicate PASS on #8
#        and #30).
VCAP6="$T/verdict-noclass-bodies"; : > "$VCAP6"
echo "no class given" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP6" \
    "$LANE" verdict 9 fail cafe0000 >/dev/null 2>&1 \
    && bad "verdict: a FAIL with no --class was accepted" \
    || ok "verdict: a FAIL with no --class is refused"
[ -s "$VCAP6" ] \
    && bad "verdict: the refused classless FAIL still posted a trailer ($(cat "$VCAP6"))" \
    || ok "verdict: the refused classless FAIL posted nothing"

VCAP7="$T/verdict-pass-strip-bodies"; : > "$VCAP7"
echo "green, but a stray class rode along" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP7" \
    "$LANE" verdict 9 pass cafe0000 --class logic >/dev/null 2>&1
grep -q "orch-verdict PASS cafe0000 -->" "$VCAP7" \
    && ok "verdict: a PASS strips a passed-in --class from the trailer" \
    || bad "verdict: PASS trailer missing or malformed ($(tail -2 "$VCAP7" 2>/dev/null))"
grep -q "class=" "$VCAP7" \
    && bad "verdict: PASS trailer leaked class= ($(tail -2 "$VCAP7" 2>/dev/null))" \
    || ok "verdict: no class= survives on a PASS trailer"

# A second identical ticket+SHA+outcome trailer is a duplicate re-gate, not a
# new verdict — refuse it, and post nothing while refusing.
cat > "$T/glab-dup-stub.sh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" >> "${VCAP:?}"; echo '{}'; exit 0 ;; esac; done
# P86: the notes thread is the point of this stub, but `verdict` also reads the
# ISSUE (the hold guard) and writes its label. The driver maps each response
# into loom's shape, so those have to answer as objects rather than being
# handed the notes array.
case "$*" in
  *"/notes"*) cat "${NOTES_FIXTURE:?}" ;;
  *)          echo '{"iid":9,"state":"opened","labels":[]}' ;;
esac
EOF
chmod +x "$T/glab-dup-stub.sh"
NOTES_FIXTURE="$T/dup-notes.json"
cat > "$NOTES_FIXTURE" <<'EOF'
[{"created_at":"2026-08-07T06:00:00Z","body":"Passed on re-review.\n\n<!-- orch-verdict PASS cafe0000 -->"}]
EOF
VCAP8="$T/verdict-dup-bodies"; : > "$VCAP8"
echo "same SHA, same outcome, again" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-dup-stub.sh" \
    VCAP="$VCAP8" NOTES_FIXTURE="$NOTES_FIXTURE" \
    "$LANE" verdict 9 pass cafe0000 >/dev/null 2>&1 \
    && bad "verdict: a second identical ticket+SHA+outcome trailer was accepted" \
    || ok "verdict: a duplicate ticket+SHA+outcome trailer is refused"
[ -s "$VCAP8" ] \
    && bad "verdict: the refused duplicate still posted a trailer ($(cat "$VCAP8"))" \
    || ok "verdict: the refused duplicate posted nothing"
# The same outcome at a DIFFERENT sha is a fresh gate result, not a
# duplicate, and must still land.
VCAP9="$T/verdict-nodup-bodies"; : > "$VCAP9"
echo "re-gated at a new HEAD" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-dup-stub.sh" \
    VCAP="$VCAP9" NOTES_FIXTURE="$NOTES_FIXTURE" \
    "$LANE" verdict 9 pass beef0001 >/dev/null 2>&1 \
    && ok "verdict: the same outcome at a new sha is not treated as a duplicate" \
    || bad "verdict: a fresh SHA was wrongly refused as a duplicate"
grep -q "orch-verdict PASS beef0001 -->" "$VCAP9" \
    && ok "verdict: the non-duplicate verdict posted its trailer" \
    || bad "verdict: the non-duplicate verdict posted no trailer ($(cat "$VCAP9"))"

# D-SNAP-19: a human reset retires duplicate detection too. The work and HEAD
# are unchanged, so a fresh independent gate must be allowed to write the same
# outcome/SHA after the reset instead of fabricating a product commit.
cat > "$NOTES_FIXTURE" <<'EOF'
[{"created_at":"2026-08-07T07:00:00Z","body":"Background QoS invalidated the gate.\n\n<!-- orch-verdict-reset 2026-08-07T07:00:00Z -->"},
 {"created_at":"2026-08-07T06:00:00Z","body":"Passed on re-review.\n\n<!-- orch-verdict PASS cafe0000 -->"}]
EOF
VCAP10="$T/verdict-after-reset-bodies"; : > "$VCAP10"
echo "independently re-gated after the reset" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-dup-stub.sh" \
    VCAP="$VCAP10" NOTES_FIXTURE="$NOTES_FIXTURE" \
    "$LANE" verdict 9 pass cafe0000 >/dev/null 2>&1 \
    && ok "D-SNAP-19: the same outcome and SHA can be written after a verdict reset" \
    || bad "D-SNAP-19: a pre-reset duplicate still blocked the new verdict"
grep -q "orch-verdict PASS cafe0000 -->" "$VCAP10" \
    && ok "D-SNAP-19: the post-reset verdict wrote its trailer" \
    || bad "D-SNAP-19: accepted post-reset verdict wrote no trailer ($(cat "$VCAP10"))"

# 16a4d. P72: the two facts the write half and the read half had to spell the
#        same way, and which nothing in this suite ever compared. Both now come
#        from lib.jq, the one jq prelude every program includes.
#
#   (a) The epic slugify. snapshot.jq derives an epic's key from its milestone
#       title; `lane.sh probe-result <epic> pass` closes the milestone whose
#       title normalizes to the key it was handed. Nothing asserted that those
#       two normalizations agree — a comment in each file asking the other to
#       stay byte-identical was the whole bond. The fixture title carries every
#       way they could disagree: uppercase, punctuation, and a separator at
#       both ends.
FX="$T/fx"; make_glab_fixture "$FX"   # the snapshot section's canned tracker
P72FX="$T/fx72"; cp -R "$FX" "$P72FX"
P72HOME="$T/p72-home"; mkdir -p "$P72HOME"
printf '%s\n' '[{"id":91,"title":" REPORTING/surface! ","state":"active"}]' > "$P72FX/milestones.json"
snapkey=$(LOOM_HOME="$P72HOME" GLAB_CMD="$P72FX/glab-stub.sh" "$TICK" snapshot 2>/dev/null \
    | jq -r '[.warnings[] | capture("spawn probe-(?<k>[a-z0-9-]+)") | .k] | first // "none"')
cat > "$T/glab-milestones-p72.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${MCAP:?}"
case "$*" in
    *"milestones?state=active"*) echo '[{"id":91,"title":" REPORTING/surface! "}]' ;;
    *) echo '{}' ;;
esac
EOF
chmod +x "$T/glab-milestones-p72.sh"
MC72="$T/milestone-calls-p72"; : > "$MC72"
echo "probe green" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-milestones-p72.sh" MCAP="$MC72" \
    "$LANE" probe-result 36 "$snapkey" pass >/dev/null 2>&1
if [ "$snapkey" = "reporting-surface" ] && grep -q "milestones/91" "$MC72"; then
    ok "P72: the key snapshot.jq derives from a milestone title is the key lane.sh closes it by"
else
    bad "P72: slugify disagreement — snapshot said [$snapkey], lane.sh closed [$(grep -o 'milestones/[0-9]*' "$MC72" | head -1)]"
fi
# Planted violation: give lane.sh back a private slugify — the pre-P72 `sed`
# pipeline with one of its three rules dropped, which is exactly the drift two
# comments cannot prevent. Nothing else changes, and the milestone silently
# stays open.
D72="$T/slugdrift"; mkdir -p "$D72"
for sib in lib.sh lib.jq tick.sh snapshot.jq render.jq render-events.jq usage.jq report.jq report-ticket.jq retro.jq graph.jq; do
    ln -sf "$(dirname "$TICK")/$sib" "$D72/$sib"
done
link_trackers "$D72"
cat > "$T/drift-line.txt" <<'EOF'
        norm=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/-+$//')
EOF
awk 'NR==FNR {repl = repl $0 ORS; next} /norm=\$\(printf/ {printf "%s", repl; next} {print}' \
    "$T/drift-line.txt" "$LANE" > "$D72/lane.sh"
chmod +x "$D72/lane.sh"
: > "$MC72"
echo "probe green" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-milestones-p72.sh" MCAP="$MC72" \
    "$D72/lane.sh" probe-result 36 "$snapkey" pass >/dev/null 2>&1
grep -q "state_event=close" "$MC72" \
    && bad "P72-violation: a drifted private slugify still closed the milestone — this fixture does not exercise the difference" \
    || ok "P72-violation: with lane.sh back on a slugify of its own the milestone is missed, and no comment could have caught it"

#   (b) The verdict trailer. `lane.sh verdict` writes it and snapshot.jq's
#       `judged_at` reads it back to answer "this HEAD is already judged" —
#       one regex, formerly written out three times. The roundtrip is checked
#       end to end: the note this suite feeds the snapshot is the one lane.sh
#       actually posted, not a hand-written trailer.
VCAP72="$T/verdict-roundtrip-body"; : > "$VCAP72"
echo "gate green at the fixture HEAD" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP72" \
    "$LANE" verdict 12 pass e52b7c1 >/dev/null 2>&1
jq -Rs '[{system: false, created_at: "2026-08-07T10:00:00Z", author: {username: "gate"}, body: .}]' \
    < "$VCAP72" > "$P72FX/notes-12.json"
LOOM_HOME="$P72HOME" GLAB_CMD="$P72FX/glab-stub.sh" "$TICK" snapshot 2>/dev/null > "$T/p72-snap.json"
if [ "$(jq -r '.tickets[]|select(.id==12)|.gate.last_verdict.verdict' "$T/p72-snap.json")" = "PASS" ] \
   && [ "$(jq -r '.tickets[]|select(.id==12)|.gate.eligible' "$T/p72-snap.json")" = "false" ]; then
    ok "P72: a verdict lane.sh wrote is found by the snapshot at the same HEAD"
else
    bad "P72: trailer roundtrip broken ($(jq -c '.tickets[]|select(.id==12)|.gate' "$T/p72-snap.json" 2>&1))"
fi
# Planted violation: change the trailer regex in the ONE place it now lives.
# Both readers must go blind together — that is the claim. Three writings
# became one landing site, so a trailer format change cannot half-land.
V72="$T/trailer-onesite"; mkdir -p "$V72"
for sib in tick.sh lane.sh snapshot.jq render.jq render-events.jq usage.jq report.jq report-ticket.jq retro.jq graph.jq lib.sh; do
    ln -sf "$(dirname "$TICK")/$sib" "$V72/$sib"
done
link_trackers "$V72"
sed 's/scan("orch-verdict/scan("orch-verdict-v2/' "$(dirname "$TICK")/lib.jq" > "$V72/lib.jq"
# D-TEST-14: prove the planted mutation is the prelude jq ACTUALLY loads, before
# asserting anything about behaviour. `jq -L <dir> 'include "lib"'` resolves a
# relative include against the CURRENT WORKING DIRECTORY first, so running the
# suite from scripts/ — where the real lib.jq lives — silently shadowed every
# mutated copy: the duplicate refusal kept working and the violation could not
# fail. The verdict of the whole section depended on nothing but the caller's
# cwd (139/1 from scripts/, 140/0 from the repo root).
#
# Two halves, and both are needed. Every command below runs with cwd = $V72, so
# the mutated copy wins by cwd AND by -L; and this check fails loudly if it ever
# stops winning, rather than passing quietly as a violation that cannot fail.
if ( cd "$V72" && printf '%s' '[{"body":"x <!-- orch-verdict PASS cafe0000 -->"}]' \
     | jq -L "$V72" -e 'include "lib"; [.[] | .body | orch_verdict_scan] | length > 0' >/dev/null 2>&1 ); then
    bad "D-TEST-14: the mutated prelude never loaded (jq resolved include \"lib\" elsewhere) — every assertion below is vacuous"
else
    ok "D-TEST-14: the planted mutation is the prelude jq actually loads"
fi
( cd "$V72" && LOOM_HOME="$P72HOME" GLAB_CMD="$P72FX/glab-stub.sh" \
    "$V72/tick.sh" snapshot 2>/dev/null ) > "$T/p72-snap-v2.json"
v2read=$(jq -r '.tickets[]|select(.id==12)|.gate.last_verdict' "$T/p72-snap-v2.json")
if ( cd "$V72" && echo "same SHA, same outcome, again" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-dup-stub.sh" \
    VCAP="$T/p72-dup-bodies" NOTES_FIXTURE="$NOTES_FIXTURE" \
    "$V72/lane.sh" verdict 9 pass cafe0000 >/dev/null 2>&1 ); then
    v2dup=accepted; else v2dup=refused; fi
if [ "$v2read" = null ] && [ "$v2dup" = accepted ]; then
    ok "P72-violation: one edit to the shared scan blinds the snapshot read AND lane.sh's duplicate refusal together"
else
    bad "P72-violation: a trailer format change half-landed (snapshot read [$v2read], duplicate $v2dup)"
fi

# 16a-2. P32: `merge-failed` records a merge attempt that did NOT merge. The
#      merge step always takes the OLDEST merge-queue ticket, so without a
#      count one poisoned ticket is re-picked by every lane behind it — three
#      consecutive lanes wedged on #50 while gate-passed #52 and #53 waited
#      (build-3, 2026-08-03). The trailer keeps the count in the TRACKER,
#      because blocking the ticket is a decision, not plumbing.
VCAP3="$T/merge-attempt-bodies"; : > "$VCAP3"
echo "combined gate deadlocked in pytest" | LOOM_HOME="$EVH" \
    LOOM_LANE_ID=merge-8 \
    GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP3" \
    "$LANE" merge-failed 8 >/dev/null 2>&1
grep -q "orch-merge-attempt 8" "$VCAP3" \
    && grep -q "deadlocked in pytest" "$VCAP3" \
    && ok "merge-failed: records the attempt with its reason and a trailer" \
    || bad "merge-failed: trailer or body missing ($(tail -3 "$VCAP3" 2>/dev/null))"
[ "$(cat "$EVH/lanes/merge-8.outcome" 2>/dev/null)" = "merge-failed" ] \
    && ok "merge-failed: stamps the lane outcome so harvest cannot count the attempt twice" \
    || bad "merge-failed: successful recording left no semantic lane outcome"
# Planted violation: it must NOT move the ticket. Recording an attempt and
# judging one are different acts — the wave decides when the cap is reached,
# and a verb that silently relabelled would take that call away from it.
# Captured from real argv, so "it only posts a note" is proven, not assumed.
cat > "$T/glab-argv-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ACAP:?}"
echo '{}'
EOF
chmod +x "$T/glab-argv-stub.sh"
ACAP2="$T/merge-attempt-calls"; : > "$ACAP2"
echo "second attempt, same wall" | LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAP2" \
    "$LANE" merge-failed 8 >/dev/null 2>&1
if grep -qE "add_labels|remove_labels|state_event" "$ACAP2"; then
    bad "merge-failed: changed ticket state ($(grep -m1 -E 'add_labels|state_event' "$ACAP2"))"
else
    ok "merge-failed: records only — leaves the merge-queue label alone"
fi
grep -q "issues/8/notes" "$ACAP2" \
    && ok "merge-failed: posted the attempt on the ticket thread" \
    || bad "merge-failed: no note call ($(cat "$ACAP2" | tr '\n' ';'))"

# 16a-2b. P62: an attempt that failed on a check ALSO red on clean
#      origin/<base> is a base defect, not this ticket's — merge-12 and
#      merge-26 failed on main-is-red, #26 and #15 burned full caps on it,
#      and the spent caps had no reset when the fix ticket merged (ai-workout
#      build-1, 2026-08-07: seven incidents). `--base-red <check> --fix <n>`
#      folds both facts into the trailer: base-red= keeps the attempt out of
#      the cap count, fix= is what releases the park when that issue closes.
VCAP5="$T/base-red-bodies"; : > "$VCAP5"
echo "model-literal guard red on clean main too" | LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP5" \
    "$LANE" merge-failed 8 --base-red model-literal-guard --fix 65 >/dev/null 2>&1
grep -q "orch-merge-attempt 8 base-red=model-literal-guard fix=65" "$VCAP5" \
    && ok "merge-failed: --base-red records check id and fix link in the trailer" \
    || bad "merge-failed: base-red trailer missing ($(tail -2 "$VCAP5" 2>/dev/null))"
# Planted violation: a base-red attempt with no fix link would park the
# ticket with nothing that can ever release it — refused, and nothing posted.
ACAP5="$T/base-red-calls"; : > "$ACAP5"
echo "red on base" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAP5" \
    "$LANE" merge-failed 8 --base-red model-literal-guard >/dev/null 2>&1 \
    && bad "merge-failed: accepted --base-red without --fix" \
    || ok "merge-failed: --base-red without --fix is refused"
# The closed_by READ may land before the refusal; what must not land is the
# note POST.
grep -q "notes" "$ACAP5" \
    && bad "merge-failed: the refused base-red attempt still posted to the tracker" \
    || ok "merge-failed: the refused base-red attempt posted nothing"
echo "red on base" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP5" \
    "$LANE" merge-failed 8 --base-red "two words" --fix 65 >/dev/null 2>&1 \
    && bad "merge-failed: accepted a check id with a space (breaks the trailer parse)" \
    || ok "merge-failed: a malformed check id is refused"
echo "orphan fix" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP5" \
    "$LANE" merge-failed 8 --fix 65 >/dev/null 2>&1 \
    && bad "merge-failed: accepted --fix without --base-red" \
    || ok "merge-failed: --fix without --base-red is refused"

# 16a4b. P37: `rescope` retires the rejections of a ticket's OLD scope. It is a
#       human's judgement about what the ticket now IS, so — like
#       `--release-hold` — it is refused outright inside a lane or a wave: a
#       lane that can reset its own cap has no cap. (#67, build-3 2026-08-04.)
VCAP4="$T/rescope-bodies"; : > "$VCAP4"
echo "Re-scoped: the race moved to #48" | LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP4" "$LANE" rescope 8 >/dev/null 2>&1
grep -qE "orch-scope-reset [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" "$VCAP4" \
    && grep -q "the race moved to #48" "$VCAP4" \
    && ok "rescope: a human posts the reason and the marker together" \
    || bad "rescope: marker or reason missing ($(tail -3 "$VCAP4" 2>/dev/null))"
# JOR-207: an additive amendment has an explicit marker. Reusing the default
# replacement marker made the later audit repair silently hide the earlier E8
# replacement scope in every fresh snapshot and provider brief.
VCAP4E="$T/rescope-extend-bodies"; : > "$VCAP4E"
printf '%s\n' "Extend active E8 scope with the audit/body proof" > "$T/rescope-extend-reason"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP4E" \
    "$LANE" rescope 8 --extend --file "$T/rescope-extend-reason" >/dev/null 2>&1
grep -qE "orch-scope-extend [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" "$VCAP4E" \
    && grep -q "audit/body proof" "$VCAP4E" \
    && ! grep -q "orch-scope-reset" "$VCAP4E" \
    && ok "rescope --extend: a human records an additive scope amendment" \
    || bad "rescope --extend: amendment marker or reason missing ($(tail -3 "$VCAP4E" 2>/dev/null))"
VCAP4EMPTY="$T/rescope-extend-empty"; : > "$VCAP4EMPTY"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP4EMPTY" \
    "$LANE" rescope 8 --extend </dev/null >/dev/null 2>&1 \
    && bad "rescope --extend: accepted an empty amendment" \
    || ok "rescope --extend: amendment reason remains mandatory"
[ -s "$VCAP4EMPTY" ] \
    && bad "rescope --extend: an empty amendment reached the tracker" \
    || ok "rescope --extend: empty amendment posted nothing"
echo "no body, no record" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP4" \
    "$LANE" rescope notanumber >/dev/null 2>&1 \
    && bad "rescope: accepted a non-numeric iid" \
    || ok "rescope: bad iid refused"
# Planted violation: the two automated callers, each with a body ready to post.
# Captured from real argv, so "it wrote nothing" is proven rather than assumed.
ACAP4="$T/rescope-calls"; : > "$ACAP4"
echo "the ticket changed, honest" | LOOM_LANE_ID=impl-8 LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAP4" "$LANE" rescope 8 >/dev/null 2>&1 \
    && bad "rescope: a lane retired its own rejection history" \
    || ok "rescope: a lane cannot reset its own cap"
echo "the ticket changed, honest" | LOOM_WAVE_PROMPT="/loom tick" LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAP4" "$LANE" rescope 8 >/dev/null 2>&1 \
    && bad "rescope: a wave retired a ticket's rejection history" \
    || ok "rescope: a wave cannot reset a ticket's cap"
echo "additive amendment" | LOOM_LANE_ID=impl-8 LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAP4" "$LANE" rescope 8 --extend >/dev/null 2>&1 \
    && bad "rescope --extend: a lane amended its own scope" \
    || ok "rescope --extend: a lane cannot amend its own scope"
[ -s "$ACAP4" ] \
    && bad "rescope: an automated caller still reached the tracker ($(head -1 "$ACAP4"))" \
    || ok "rescope: no automated reset write reached the tracker"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP3" \
    "$LANE" merge-failed abc </dev/null >/dev/null 2>&1 \
    && bad "merge-failed: accepted a non-numeric iid" \
    || ok "merge-failed: a bad iid is refused"

# D-SNAP-19: same work and unchanged HEAD, but the prior gate result was
# invalidated externally. Only a human can retire it, and the reason is the
# durable decision record beside the reset marker.
VCAPVR="$T/verdict-reset-bodies"; : > "$VCAPVR"
echo "Background QoS invalidated the gate; rerun after D-TICK-21" | LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAPVR" "$LANE" verdict-reset 8 >/dev/null 2>&1
grep -qE "orch-verdict-reset [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" "$VCAPVR" \
    && grep -q "Background QoS invalidated" "$VCAPVR" \
    && ok "verdict-reset: a human posts the mandatory reason and marker together" \
    || bad "verdict-reset: marker or reason missing ($(tail -3 "$VCAPVR" 2>/dev/null))"
ACAPVR="$T/verdict-reset-calls"; : > "$ACAPVR"
echo "the old gate was invalid, honest" | LOOM_LANE_ID=gate-8 LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAPVR" "$LANE" verdict-reset 8 >/dev/null 2>&1 \
    && bad "verdict-reset: a lane retired its own verdict" \
    || ok "verdict-reset: a lane cannot retire its own verdict"
echo "the old gate was invalid, honest" | LOOM_WAVE_PROMPT="/loom tick" LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAPVR" "$LANE" verdict-reset 8 >/dev/null 2>&1 \
    && bad "verdict-reset: a wave retired a ticket's verdict" \
    || ok "verdict-reset: a wave cannot retire a ticket's verdict"
[ -s "$ACAPVR" ] \
    && bad "verdict-reset: an automated caller still reached the tracker ($(head -1 "$ACAPVR"))" \
    || ok "verdict-reset: no automated reset write reached the tracker"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAPVR" \
    "$LANE" verdict-reset 8 </dev/null >/dev/null 2>&1 \
    && bad "verdict-reset: accepted an empty reason" \
    || ok "verdict-reset: an empty reason is refused"

# A valid gate rejection repaired under human supervision is neither an
# invalid verdict nor different work. Record that fact with its own marker so
# the rejection cap can retire without lying about why, while keeping the
# decision human-only and auditable.
VCAPSR="$T/supervised-repair-bodies"; : > "$VCAPSR"
echo "Fixed the response boundary at a84fcf3 and reconciled main" | LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAPSR" "$LANE" supervised-repair 8 >/dev/null 2>&1
grep -qE "orch-supervised-repair [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" "$VCAPSR" \
    && grep -q "Fixed the response boundary at a84fcf3" "$VCAPSR" \
    && ok "supervised-repair: a human posts the mandatory reason and marker together" \
    || bad "supervised-repair: marker or reason missing ($(tail -3 "$VCAPSR" 2>/dev/null))"
ACAPSR="$T/supervised-repair-calls"; : > "$ACAPSR"
echo "valid defects repaired" | LOOM_LANE_ID=impl-8 LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAPSR" "$LANE" supervised-repair 8 >/dev/null 2>&1 \
    && bad "supervised-repair: a lane retired its own rejection history" \
    || ok "supervised-repair: a lane cannot retire its own rejection history"
echo "valid defects repaired" | LOOM_WAVE_PROMPT="/loom tick" LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAPSR" "$LANE" supervised-repair 8 >/dev/null 2>&1 \
    && bad "supervised-repair: a wave retired a ticket's rejection history" \
    || ok "supervised-repair: a wave cannot retire a ticket's rejection history"
[ -s "$ACAPSR" ] \
    && bad "supervised-repair: an automated caller reached the tracker ($(head -1 "$ACAPSR"))" \
    || ok "supervised-repair: no automated reset write reached the tracker"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAPSR" \
    "$LANE" supervised-repair 8 </dev/null >/dev/null 2>&1 \
    && bad "supervised-repair: accepted an empty reason" \
    || ok "supervised-repair: an empty reason is refused"

# 16a4b-2. P96: `merge-reset` retires the MERGE cap of a ticket whose merges
#       failed on something since resolved — a conflict a human untangled, a
#       dependency that has landed. Until it existed a spent cap had no reset
#       at all (build-1 #26, 2026-08-07). Same work, so `rescope` is the wrong
#       verb; same human-only refusal, for the same reason a lane that can
#       reset its own cap has no cap.
VCAP6="$T/merge-reset-bodies"; : > "$VCAP6"
echo "Untangled the schema.ts conflict by hand and pushed it" | LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP6" "$LANE" merge-reset 8 >/dev/null 2>&1
grep -qE "orch-merge-reset [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" "$VCAP6" \
    && grep -q "Untangled the schema.ts conflict" "$VCAP6" \
    && ok "merge-reset: a human posts the reason and the marker together" \
    || bad "merge-reset: marker or reason missing ($(tail -3 "$VCAP6" 2>/dev/null))"
# Planted violation: the two automated callers, each with a body ready to post,
# captured from real argv so "it wrote nothing" is proven rather than assumed.
ACAP6="$T/merge-reset-calls"; : > "$ACAP6"
echo "the conflict is fine now, honest" | LOOM_LANE_ID=merge-8 LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAP6" "$LANE" merge-reset 8 >/dev/null 2>&1 \
    && bad "merge-reset: a lane retired its own merge cap" \
    || ok "merge-reset: a lane cannot reset its own merge cap"
echo "the conflict is fine now, honest" | LOOM_WAVE_PROMPT="/loom tick" LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAP6" "$LANE" merge-reset 8 >/dev/null 2>&1 \
    && bad "merge-reset: a wave retired a ticket's merge cap" \
    || ok "merge-reset: a wave cannot reset a ticket's merge cap"
[ -s "$ACAP6" ] \
    && bad "merge-reset: an automated caller still reached the tracker ($(head -1 "$ACAP6"))" \
    || ok "merge-reset: no automated reset write reached the tracker"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP6" \
    "$LANE" merge-reset 8 </dev/null >/dev/null 2>&1 \
    && bad "merge-reset: accepted an empty body — a bare marker retires a cap explaining nothing" \
    || ok "merge-reset: an empty body is refused"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP6" \
    "$LANE" merge-reset notanumber </dev/null >/dev/null 2>&1 \
    && bad "merge-reset: accepted a non-numeric iid" \
    || ok "merge-reset: a bad iid is refused"

# 16a4c. P78: the three writes `triage` stands on.
#
#   `blocked-report` — the blocked report used to be a hand-composed comment.
#   SKILL.md described its CONTENTS and nothing wrote it, so nothing could find
#   it again: every other fact snapshot.jq mines out of a thread has a trailer
#   (orch-verdict, orch-merge-attempt, orch-scope-reset) and this one had none.
#   Recording only, like merge-failed — the wave still transitions to blocked.
VCAP6="$T/blocked-report-bodies"; : > "$VCAP6"
printf 'Cap spent. Attempt 3 tried the adapter seam.\n' | LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP6" \
    "$LANE" blocked-report 8 --category rejection-cap >/dev/null 2>&1
grep -qE "orch-blocked category=rejection-cap [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" "$VCAP6" \
    && grep -q "Attempt 3 tried the adapter seam" "$VCAP6" \
    && ok "blocked-report: the report and its locating trailer post together" \
    || bad "blocked-report: trailer or body missing ($(tail -3 "$VCAP6" 2>/dev/null))"
printf 'no category given\n' | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" \
    VCAP="$VCAP6" "$LANE" blocked-report 8 >/dev/null 2>&1
grep -qE "orch-blocked [0-9]{4}-" "$VCAP6" \
    && ok "blocked-report: the category is optional, the trailer is not" \
    || bad "blocked-report: a category-less report lost its trailer"
# The category is read back by a parser, so it takes a slug for the same reason
# `verdict --class` does: a `-->` or a newline inside it ends the trailer early
# and takes the rest of the comment with it.
printf 'x\n' | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP6" \
    "$LANE" blocked-report 8 --category "not a slug" >/dev/null 2>&1 \
    && bad "blocked-report: accepted a category that can break its own trailer" \
    || ok "blocked-report: a non-slug category is refused"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP6" \
    "$LANE" blocked-report 8 </dev/null >/dev/null 2>&1 \
    && bad "blocked-report: posted an empty report" \
    || ok "blocked-report: an empty body is refused — the comment IS the report"
# Planted violation: recording, not judging. A verb that also set the label
# would make the wave's own `transition <n> blocked` a double write.
ACAP6="$T/blocked-report-calls"; : > "$ACAP6"
printf 'records only\n' | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-argv-stub.sh" \
    ACAP="$ACAP6" "$LANE" blocked-report 8 >/dev/null 2>&1
grep -qE "add_labels|remove_labels|state_event" "$ACAP6" \
    && bad "blocked-report: changed ticket state ($(grep -m1 -E 'add_labels|state_event' "$ACAP6"))" \
    || ok "blocked-report: records only — the wave still owns the transition"

#   `model-tier` — snapshot.jq's model_of has read `model::<tier>` since P31 and
#   nothing has ever written one, so a human escalation meant editing labels in
#   the tracker UI. Refused for automated callers like rescope: a lane that can
#   escalate itself has no chain.
cat > "$T/glab-tier-stub.sh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"--method PUT"*) echo "$*" >> "${TCAP:?}"; echo '{}' ;;
    *"issues/8"*) echo '{"iid":8,"labels":["build-3","blocked","model::medium"]}' ;;
    *) echo '{}' ;;
esac
STUB
chmod +x "$T/glab-tier-stub.sh"
TCAP="$T/tier-calls"; : > "$TCAP"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-tier-stub.sh" TCAP="$TCAP" \
    "$LANE" model-tier 8 high >/dev/null 2>&1 \
    && ok "model-tier: a human can escalate a ticket's model" \
    || bad "model-tier: refused a human caller"
grep -q "add_labels=model::high" "$TCAP" \
    && ok "model-tier: the new tier is written as a label" \
    || bad "model-tier: no label write reached the tracker ($(tail -1 "$TCAP"))"
# One `model::` label at a time. Two resolve (the higher rank wins) but the
# board then shows a ticket claiming both, and the next human to read it cannot
# tell which is the live decision.
grep -q "remove_labels=model::medium" "$TCAP" \
    && ok "model-tier: the tier it replaces is removed in the same write" \
    || bad "model-tier: left two model:: labels on the ticket ($(tail -1 "$TCAP"))"
# Planted violation: both automated callers, each naming a real tier.
TCAP2="$T/tier-auto-calls"; : > "$TCAP2"
LOOM_LANE_ID=impl-8 LOOM_HOME="$EVH" GLAB_CMD="$T/glab-tier-stub.sh" TCAP="$TCAP2" \
    "$LANE" model-tier 8 high >/dev/null 2>&1 \
    && bad "model-tier: a lane escalated its own model" \
    || ok "model-tier: a lane cannot escalate its own model"
LOOM_WAVE_PROMPT="/loom tick" LOOM_HOME="$EVH" GLAB_CMD="$T/glab-tier-stub.sh" TCAP="$TCAP2" \
    "$LANE" model-tier 8 high >/dev/null 2>&1 \
    && bad "model-tier: a wave escalated a ticket's model" \
    || ok "model-tier: a wave cannot escalate a ticket's model"
[ -s "$TCAP2" ] \
    && bad "model-tier: an automated escalation still reached the tracker ($(head -1 "$TCAP2"))" \
    || ok "model-tier: no automated escalation write reached the tracker"
# Provider-native model names are no longer tracker state. Only Loom's two
# public tiers are valid, and an ambiguous legacy value must be chosen by a
# human rather than guessed.
TCAP3="$T/tier-unknown"; : > "$TCAP3"
out=$(LOOM_HOME="$EVH" GLAB_CMD="$T/glab-tier-stub.sh" TCAP="$TCAP3" \
    "$LANE" model-tier 8 some-new-model 2>&1)
case "$out" in *"medium|high"*) \
    ok "model-tier: an unknown provider-native tier is refused with its replacement";; \
    *) bad "model-tier: an unknown tier passed or gave no migration help ($out)";; esac
[ ! -s "$TCAP3" ] \
    && ok "model-tier: an invalid tier makes no tracker write" \
    || bad "model-tier: invalid tier reached the tracker"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-tier-stub.sh" TCAP="$TCAP3" \
    "$LANE" model-tier 8 "bad tier" >/dev/null 2>&1 \
    && bad "model-tier: accepted a tier that is not label-safe" \
    || ok "model-tier: a tier that cannot be a label is refused"

#   `transition --note` — the decision and the relabel are ONE verb. The pair
#   was two commands, and `triage` runs that pair once per ticket across a whole
#   batch, so a death mid-batch strands some tickets with a comment and no
#   release. Same shape P63 turned `submit` into one verb over.
cat > "$T/glab-note-stub.sh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" >> "${NCAP:?}" ;; esac; done
echo "$*" >> "${NARGV:?}"
case "$*" in
    *"issues/60/notes"*) cat "${NTHREAD:-/dev/null}" 2>/dev/null || echo '[]' ;;
    *"issues/60"*) echo '{"iid":60,"state":"opened","labels":["build-3","blocked"]}' ;;
    *) echo '{}' ;;
esac
STUB
chmod +x "$T/glab-note-stub.sh"
NCAP="$T/note-bodies"; NARGV="$T/note-argv"; : > "$NCAP"; : > "$NARGV"
echo '[]' > "$T/thread-empty.json"
printf 'Decision: the adapter is out of scope, resume on the old seam.\n' \
    | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-note-stub.sh" NCAP="$NCAP" NARGV="$NARGV" \
      NTHREAD="$T/thread-empty.json" \
      "$LANE" transition 60 ready-for-agent --release-hold --note >/dev/null 2>&1
grep -q "resume on the old seam" "$NCAP" \
    && grep -qE "orch-unblock [0-9]{4}-[0-9]{2}-[0-9]{2}T" "$NCAP" \
    && ok "transition --note: the decision posts with its own trailer" \
    || bad "transition --note: body or trailer missing ($(tail -3 "$NCAP" 2>/dev/null))"
grep -q "add_labels=ready-for-agent" "$NARGV" && grep -q "assignee_ids=0" "$NARGV" \
    && ok "transition --note: one verb posts the decision AND clears the assignee" \
    || bad "transition --note: the relabel half did not run ($(tail -1 "$NARGV"))"
# Re-run after a failed label write must complete the missing half without
# doubling the note. The window is bounded by the block it answers: an
# orch-unblock trailer NEWER than the newest orch-blocked one is this
# release'"'"'s note.
cat > "$T/thread-noted.json" <<'STUB'
[{"body":"Cap spent.\n\n<!-- orch-blocked category=rejection-cap 2026-08-08T10:00:00Z -->\n",
  "created_at":"2026-08-08T10:00:00Z"},
 {"body":"Decision: resume.\n\n<!-- orch-unblock 2026-08-08T11:00:00Z -->\n",
  "created_at":"2026-08-08T11:00:00Z"}]
STUB
: > "$NCAP"; : > "$NARGV"
printf 'Decision: resume.\n' | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-note-stub.sh" \
    NCAP="$NCAP" NARGV="$NARGV" NTHREAD="$T/thread-noted.json" \
    "$LANE" transition 60 ready-for-agent --release-hold --note >/dev/null 2>&1
[ -s "$NCAP" ] \
    && bad "transition --note: a re-run posted a second decision note" \
    || ok "transition --note: a re-run does not double the note it already posted"
grep -q "add_labels=ready-for-agent" "$NARGV" \
    && ok "transition --note: a re-run still completes the missing label half" \
    || bad "transition --note: a re-run skipped the half that had not landed"
# Planted violation: the bound must be the newest block, not the mere presence
# of a trailer. A ticket blocked and released TWICE would otherwise see round
# one'"'"'s trailer and silently drop round two'"'"'s decision.
cat > "$T/thread-reblocked.json" <<'STUB'
[{"body":"Round one.\n\n<!-- orch-unblock 2026-08-08T11:00:00Z -->\n",
  "created_at":"2026-08-08T11:00:00Z"},
 {"body":"Blocked again.\n\n<!-- orch-blocked category=external-dep 2026-08-08T12:00:00Z -->\n",
  "created_at":"2026-08-08T12:00:00Z"}]
STUB
: > "$NCAP"
printf 'Round two decision.\n' | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-note-stub.sh" \
    NCAP="$NCAP" NARGV="$NARGV" NTHREAD="$T/thread-reblocked.json" \
    "$LANE" transition 60 ready-for-agent --release-hold --note >/dev/null 2>&1
grep -q "Round two decision" "$NCAP" \
    && ok "transition --note: a second block gets its own decision note" \
    || bad "transition --note: round one'"'"'s trailer swallowed round two'"'"'s decision"
# D-SNAP-17: the trailer is MACHINERY and `--note` is a human courtesy, so the
# stamp cannot hang off the flag. Moving a `blocked` ticket anywhere else IS the
# release, and without the trailer the thread still reads as an open block
# forever — build-2 #83 was released, verified and moved to review, and a wave
# put `blocked` back on it 3h43m later off exactly that reading. Same fixture,
# no --note.
cat > "$T/thread-blocked-only.json" <<'STUB'
[{"body":"Cap spent.\n\n<!-- orch-blocked category=rejection-cap 2026-08-08T10:00:00Z -->\n",
  "created_at":"2026-08-08T10:00:00Z"}]
STUB
: > "$NCAP"; : > "$NARGV"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-note-stub.sh" NCAP="$NCAP" NARGV="$NARGV" \
    NTHREAD="$T/thread-blocked-only.json" \
    "$LANE" transition 60 review --release-hold >/dev/null 2>&1
grep -qE "orch-unblock [0-9]{4}-[0-9]{2}-[0-9]{2}T" "$NCAP" \
    && ok "transition: a release with no --note still stamps the unblock trailer" \
    || bad "transition: the released hold left no trailer on the thread ($(tail -3 "$NCAP" 2>/dev/null))"
grep -q "add_labels=review" "$NARGV" \
    && ok "transition: the stamp does not cost the label half" \
    || bad "transition: the relabel did not run ($(tail -1 "$NARGV"))"
# Re-run safety holds on this path too: the trailer already answers the newest
# block, so a second run completes the label half and posts nothing.
: > "$NCAP"; : > "$NARGV"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-note-stub.sh" NCAP="$NCAP" NARGV="$NARGV" \
    NTHREAD="$T/thread-noted.json" \
    "$LANE" transition 60 review --release-hold >/dev/null 2>&1
[ -s "$NCAP" ] \
    && bad "transition: a re-run stamped a second unblock trailer ($(tail -3 "$NCAP"))" \
    || ok "transition: a re-run of a stamped release does not double the trailer"
# A transition that is not a release writes no trailer: nothing to release, and
# a stray `orch-unblock` would answer a block that never happened.
cat > "$T/glab-unheld-stub.sh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" >> "${NCAP:?}" ;; esac; done
echo "$*" >> "${NARGV:?}"
case "$*" in
    *"issues/61/notes"*) cat "${NTHREAD:-/dev/null}" 2>/dev/null || echo '[]' ;;
    *"issues/61"*) echo '{"iid":61,"state":"opened","labels":["build-3","in-progress"]}' ;;
    *) echo '{}' ;;
esac
STUB
chmod +x "$T/glab-unheld-stub.sh"
: > "$NCAP"; : > "$NARGV"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-unheld-stub.sh" NCAP="$NCAP" NARGV="$NARGV" \
    "$LANE" transition 61 review >/dev/null 2>&1
[ -s "$NCAP" ] \
    && bad "transition: stamped a release on a ticket that was never held ($(tail -3 "$NCAP"))" \
    || ok "transition: a transition that releases nothing writes no trailer"
# A machine decision on an ordinary transition is not a release. Patient
# Imaging JOR-231 already had a historical blocked/unblock pair; consulting
# release dedup swallowed its later stale-base note while still moving it to
# in-progress, recreating the review loop. The exact machine trailer owns
# idempotence on this path and no new orch-unblock is fabricated.
cat > "$T/thread-historical-release.json" <<'STUB'
[{"body":"Old block.\n\n<!-- orch-blocked category=old 2026-08-08T10:00:00Z -->","created_at":"2026-08-08T10:00:00Z"},
 {"body":"Old release.\n\n<!-- orch-unblock 2026-08-08T11:00:00Z -->","created_at":"2026-08-08T11:00:00Z"}]
STUB
: > "$NCAP"; : > "$NARGV"
printf 'Reconcile current base.\n\n<!-- orch-base-stale abc1234 base=main behind=4 -->\n' \
  | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-unheld-stub.sh" NCAP="$NCAP" NARGV="$NARGV" \
      NTHREAD="$T/thread-historical-release.json" \
      "$LANE" transition 61 in-progress --note >/dev/null 2>&1
if grep -q 'orch-base-stale abc1234' "$NCAP" \
   && ! grep -q 'orch-unblock' "$NCAP" \
   && grep -q 'add_labels=in-progress' "$NARGV"; then
    ok "transition decision: historical release cannot swallow a new head-bound note"
else
    bad "transition decision: non-hold machine note was lost or mislabeled as a release"
fi
cat > "$T/thread-machine-noted.json" <<'STUB'
[{"body":"Reconcile current base.\n\n<!-- orch-base-stale abc1234 base=main behind=4 -->","created_at":"2026-08-17T18:41:49Z"}]
STUB
: > "$NCAP"; : > "$NARGV"
printf 'Reconcile current base.\n\n<!-- orch-base-stale abc1234 base=main behind=4 -->\n' \
  | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-unheld-stub.sh" NCAP="$NCAP" NARGV="$NARGV" \
      NTHREAD="$T/thread-machine-noted.json" \
      "$LANE" transition 61 in-progress --note >/dev/null 2>&1
[ ! -s "$NCAP" ] && grep -q 'add_labels=in-progress' "$NARGV" \
    && ok "transition decision: exact machine trailer deduplicates a label-write retry" \
    || bad "transition decision: retry duplicated the note or skipped the label half"
# --note does not buy a way past the hold guard: releasing still needs
# --release-hold, and an automated caller still cannot say it.
: > "$NARGV"
printf 'sneaking past\n' | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-note-stub.sh" \
    NCAP="$NCAP" NARGV="$NARGV" NTHREAD="$T/thread-empty.json" \
    "$LANE" transition 60 ready-for-agent --note >/dev/null 2>&1 \
    && bad "transition --note: --note released a hold without --release-hold" \
    || ok "transition --note: --note is not a way past the hold guard"
printf 'lane sneaking past\n' | LOOM_LANE_ID=impl-60 LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-note-stub.sh" NCAP="$NCAP" NARGV="$NARGV" \
    NTHREAD="$T/thread-empty.json" \
    "$LANE" transition 60 ready-for-agent --release-hold --note >/dev/null 2>&1 \
    && bad "transition --note: a lane released a hold by attaching a note" \
    || ok "transition --note: a lane still cannot release a hold"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-note-stub.sh" NCAP="$NCAP" NARGV="$NARGV" \
    NTHREAD="$T/thread-empty.json" \
    "$LANE" transition 60 ready-for-agent --release-hold --note </dev/null >/dev/null 2>&1 \
    && bad "transition --note: released a hold with an empty decision note" \
    || ok "transition --note: an empty decision note is refused"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-note-stub.sh" NCAP="$NCAP" NARGV="$NARGV" \
    "$LANE" transition 60 review --file /dev/null >/dev/null 2>&1 \
    && bad "transition --note: --file was accepted without --note" \
    || ok "transition --note: --file alone is refused, not silently ignored"

# 16a-3. P33: `fix-ticket` applies all FIVE things a schedulable fix ticket
#      needs, or refuses. The skill prose enumerated four — build-N, fix,
#      tier, milestone — and left "entering at ready" as narrative, so a probe
#      lane did exactly what the list said and filed #64 with no state label:
#      in the build's universe, in no state, invisible to the ready set, while
#      four lanes idled (2026-08-04).
cat > "$FX/fixtkt-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ACAP:?}"
case "$*" in
  *"milestones"*)          echo '[{"id":31,"title":"E4 · Realtime mode"}]' ;;
  *"issues?state=opened"*) echo '[{"iid":36,"title":"Build 3"},{"iid":9,"title":"Build 2"}]' ;;
  *"POST"*"issues"*)       echo '{"iid":64}' ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$FX/fixtkt-stub.sh"
FCAP="$T/fixtkt-calls"; : > "$FCAP"
echo "turns after the first never complete" | LOOM_HOME="$EVH" \
    GLAB_CMD="$FX/fixtkt-stub.sh" ACAP="$FCAP" \
    "$LANE" fix-ticket --title "realtime turns stall" --tier logic \
        --milestone "E4 · Realtime mode" >/dev/null 2>&1
lbl=$(grep -o 'labels=[^ ]*' "$FCAP" | grep ',' | head -1)
miss=""
for want in build-3 fix tier::logic ready-for-agent; do
    case "$lbl" in *"$want"*) ;; *) miss="$miss $want" ;; esac
done
[ -z "$miss" ] \
    && ok "fix-ticket: applies build-N, fix, tier:: and ready-for-agent together" \
    || bad "fix-ticket: missing labels —$miss (got '$lbl')"
grep -q "milestone_id=31" "$FCAP" \
    && ok "fix-ticket: resolves the milestone title to its id" \
    || bad "fix-ticket: no milestone_id ($(cat "$FCAP" | tr '\n' ';'))"
# The build label is DERIVED from the highest open `Build N`, never asked for:
# a lane that had to name it could name last week's.
case "$lbl" in *build-3*) ok "fix-ticket: derives the build label, highest Build N wins" ;;
               *) bad "fix-ticket: wrong build label in '$lbl' (want build-3, not build-2)" ;; esac
# Planted violations: the two flags whose absence is silent damage rather than
# a loud error must be REFUSED, not defaulted.
echo x | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-stub.sh" ACAP="$FCAP" \
    "$LANE" fix-ticket --title t --milestone "E4 · Realtime mode" >/dev/null 2>&1 \
    && bad "fix-ticket: accepted a ticket with no tier — no gate lane could pick a suite" \
    || ok "fix-ticket: a missing --tier is refused"
echo x | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-stub.sh" ACAP="$FCAP" \
    "$LANE" fix-ticket --title t --tier logic >/dev/null 2>&1 \
    && bad "fix-ticket: accepted a milestone-less ticket — its epic could close over the defect" \
    || ok "fix-ticket: a missing --milestone is refused"
echo x | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-stub.sh" ACAP="$FCAP" \
    "$LANE" fix-ticket --title t --tier bogus --milestone "E4 · Realtime mode" >/dev/null 2>&1 \
    && bad "fix-ticket: accepted a tier outside docs|logic|api|ui" \
    || ok "fix-ticket: an unknown tier is refused"

# P104: a tracker-side create refusal must retain the driver's reason. The
# former command-substitution assignment was subject to `set -e` and also
# redirected stderr to /dev/null, so Linear's `usage limit exceeded` vanished
# and a merge lane could only disappear with an unexplained rc=1.
cat > "$FX/fixtkt-fail-stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"milestones"*)          echo '[{"id":31,"title":"E4 · Realtime mode"}]' ;;
  *"issues?state=opened"*) echo '[{"iid":36,"title":"Build 3"}]' ;;
  *"POST"*"issues"*)       echo 'graphql: usage limit exceeded' >&2; exit 1 ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$FX/fixtkt-fail-stub.sh"
set +e
out=$(echo "base is red" | LOOM_HOME="$EVH" \
    GLAB_CMD="$FX/fixtkt-fail-stub.sh" \
    "$LANE" fix-ticket --title "fix base timeout" --tier api \
        --milestone "E4 · Realtime mode" 2>&1)
rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'usage limit exceeded'; then
    ok "fix-ticket: tracker create failure preserves the actionable driver diagnostic"
else
    bad "fix-ticket: tracker create failure was silent (rc=$rc, out='$out')"
fi

# 16a-3b. P65: a probe-filed fix ticket used to enter the graph edgeless —
#      `fix-ticket` now takes `--blocked-by`, writing the `## Blocked by`
#      section the scheduler already parses (snapshot.jq's
#      section("Blocked by") / scan("#([0-9]+)")). ai-workout build-1
#      2026-08-07: #69 ran while the decision it depended on (#71) sat
#      blocked, with no edge recorded either way.
FCAP6="$T/fixtkt-blockedby-calls"; : > "$FCAP6"
echo "graph gap" | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-stub.sh" ACAP="$FCAP6" \
    "$LANE" fix-ticket --title "wire graph before boot" --tier logic \
        --milestone "E4 · Realtime mode" --blocked-by "71, 55" >/dev/null 2>&1
descf=$(grep -o 'description=@[^ ]*' "$FCAP6" | tail -1 | cut -d@ -f2)
if [ -n "$descf" ] && [ -f "$descf" ] \
   && grep -q '^## Blocked by$' "$descf" \
   && grep -q '^- #71$' "$descf" && grep -q '^- #55$' "$descf"; then
    ok "fix-ticket: --blocked-by writes a Blocked by section the scheduler can parse"
else
    bad "fix-ticket: --blocked-by section missing or malformed ($(cat "$descf" 2>/dev/null | tail -5 | tr '\n' ';'))"
fi
echo x | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-stub.sh" ACAP="$FCAP6" \
    "$LANE" fix-ticket --title t --tier logic --milestone "E4 · Realtime mode" \
        --blocked-by "71,abc" >/dev/null 2>&1 \
    && bad "fix-ticket: accepted a non-numeric --blocked-by id" \
    || ok "fix-ticket: a non-numeric --blocked-by id is refused"

# 16a-3c. P65: before creating, `fix-ticket` refuses a near-duplicate title
#      among open fix tickets in the same milestone unless --force.
#      ai-workout build-1 2026-08-07: #68 duplicated #67, discovered only
#      mid-flight by the implementing lane.
cat > "$FX/fixtkt-dup-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ACAP:?}"
case "$*" in
  *"milestones"*)                     echo '[{"id":31,"title":"E4 · Realtime mode"}]' ;;
  *"issues?state=opened&labels=fix"*) echo '[{"iid":67,"title":"Wire probe result into dashboard","milestone":{"title":"E4 · Realtime mode"}}]' ;;
  *"issues?state=opened"*)            echo '[{"iid":36,"title":"Build 3"},{"iid":9,"title":"Build 2"}]' ;;
  *"POST"*"issues"*)                  echo '{"iid":68}' ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$FX/fixtkt-dup-stub.sh"
FCAP7="$T/fixtkt-dup-calls"; : > "$FCAP7"
echo "duplicate" | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-dup-stub.sh" ACAP="$FCAP7" \
    "$LANE" fix-ticket --title "Wire probe results into dashboard" --tier logic \
        --milestone "E4 · Realtime mode" >/dev/null 2>&1 \
    && bad "fix-ticket: created a near-duplicate fix ticket without --force" \
    || ok "fix-ticket: a near-duplicate title in the same milestone is refused"
grep -q -- '--method POST' "$FCAP7" \
    && bad "fix-ticket: the refused duplicate attempt still posted a create" \
    || ok "fix-ticket: refused duplicate posted nothing"
FCAP8="$T/fixtkt-dup-force-calls"; : > "$FCAP8"
echo "duplicate forced" | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-dup-stub.sh" ACAP="$FCAP8" \
    "$LANE" fix-ticket --title "Wire probe results into dashboard" --tier logic \
        --milestone "E4 · Realtime mode" --force >/dev/null 2>&1 \
    && ok "fix-ticket: --force overrides the near-duplicate refusal" \
    || bad "fix-ticket: --force still refused a near-duplicate"
grep -q -- '--method POST' "$FCAP8" \
    && ok "fix-ticket: --force still creates the ticket" \
    || bad "fix-ticket: --force accepted but nothing was created"
FCAP9="$T/fixtkt-nodup-calls"; : > "$FCAP9"
echo "different work" | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-dup-stub.sh" ACAP="$FCAP9" \
    "$LANE" fix-ticket --title "Add retry backoff to websocket client" --tier logic \
        --milestone "E4 · Realtime mode" >/dev/null 2>&1 \
    && ok "fix-ticket: a dissimilar title in the same milestone is not blocked" \
    || bad "fix-ticket: an unrelated title was refused as a duplicate"

# 16a-3d. P70: lane.sh's own list reads paginate. P49 routed tick.sh's nine
#      reads through `_glab_list`; lane.sh is a separate script and kept four
#      plain `per_page=100` GETs, each of which silently sees only page 1.
#      Every fixture below puts the one item that matters on page 2, and each
#      is shown failing once `--paginate` is stripped (STUB_NOPAGE) — the
#      counterfactual switch P49's own stub already uses.
#      The `notes?sort=desc` read at `verdict` is deliberately capped and is
#      NOT in scope here: it wants the newest 100, not the whole thread.
cat > "$FX/p70-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ACAP:?}"
paged=no
case "$*" in *--paginate*) paged=yes ;; esac
[ -n "${STUB_NOPAGE:-}" ] && paged=no
case "$*" in
  *"--method POST"*"issues"*) echo '{"iid":200}'; exit 0 ;;
  *"milestones?state=active"*)
      # Filler titles normalize to legacy-epic-N, so none of them can match
      # the e5 slug the probe closes on.
      jq -nc '[range(1;101) | {id: ., title: "Legacy epic \(.)"}]'
      [ "$paged" = yes ] && jq -nc '[{id: 555, title: "E5 · Cascade mode"}]'
      exit 0 ;;
  *"milestones"*)
      jq -nc '[range(1;101) | {id: ., title: "Legacy epic \(.)"}]'
      if [ -n "${STUB_MS_P1:-}" ]; then jq -nc '[{id: 31, title: "E4 · Realtime mode"}]'
      elif [ "$paged" = yes ]; then jq -nc '[{id: 31, title: "E4 · Realtime mode"}]'; fi
      exit 0 ;;
  *"issues?state=opened&labels=fix"*)
      jq -nc '[range(1;101) | {iid: ., title: "Filler fix \(.)", milestone: {title: "E9 · Other epic"}}]'
      [ "$paged" = yes ] && jq -nc '[{iid: 167, title: "Wire probe result into dashboard", milestone: {title: "E4 · Realtime mode"}}]'
      exit 0 ;;
  *"issues?state=opened"*)
      jq -nc '[range(1;101) | {iid: ., title: "Filler ticket \(.)"}]'
      if [ -n "${STUB_BUILD_P1:-}" ]; then jq -nc '[{iid: 136, title: "Build 3"}]'
      elif [ "$paged" = yes ]; then jq -nc '[{iid: 136, title: "Build 3"}]'; fi
      exit 0 ;;
esac
echo '{}'
EOF
chmod +x "$FX/p70-stub.sh"
P70RUN() { # <capture-file> -- <lane.sh args...>
    local cap="$1"; shift; shift
    : > "$cap"
    echo "p70" | LOOM_HOME="$EVH" GLAB_CMD="$FX/p70-stub.sh" ACAP="$cap" "$LANE" "$@"
}
# (a) the build label: past 100 open issues the `Build N` issue itself is on
#     page 2, and without it fix-ticket cannot derive the label at all.
P70A="$T/p70-blabel"
P70RUN "$P70A" -- fix-ticket --title "Add retry backoff to websocket client" \
    --tier logic --milestone "E4 · Realtime mode" >/dev/null 2>&1
grep -q 'labels=build-3,' "$P70A" \
    && ok "P70: fix-ticket finds a Build issue that only page 2 of the open read holds" \
    || bad "P70: build label not derived ($(grep -o 'labels=[^ ]*' "$P70A" | head -1))"
STUB_NOPAGE=1 P70RUN "$P70A" -- fix-ticket --title "Add retry backoff to websocket client" \
    --tier logic --milestone "E4 · Realtime mode" >/dev/null 2>&1
grep -q -- '--method POST' "$P70A" \
    && bad "P70-violation: an unpaginated open read still found the Build issue — fixture no longer exceeds one page" \
    || ok "P70-violation: strip --paginate and every fix filing dies with no Build N issue"
# (b) the milestone id: the epic's own milestone is on page 2. A milestone-less
#     fix ticket is what lets an epic close over an open defect, so this read
#     truncating is the failure `fix-ticket` exists to make impossible.
P70B="$T/p70-milestone"
STUB_BUILD_P1=1 P70RUN "$P70B" -- fix-ticket --title "Add retry backoff to websocket client" \
    --tier logic --milestone "E4 · Realtime mode" >/dev/null 2>&1
grep -q 'milestone_id=31' "$P70B" \
    && ok "P70: fix-ticket resolves a milestone that only page 2 holds" \
    || bad "P70: milestone_id not resolved ($(grep -o 'milestone_id=[0-9]*' "$P70B" | head -1))"
STUB_BUILD_P1=1 STUB_NOPAGE=1 P70RUN "$P70B" -- fix-ticket \
    --title "Add retry backoff to websocket client" --tier logic \
    --milestone "E4 · Realtime mode" >/dev/null 2>&1
grep -q -- '--method POST' "$P70B" \
    && bad "P70-violation: an unpaginated milestone read still found E4 — fixture no longer exceeds one page" \
    || ok "P70-violation: strip --paginate and the epic's own milestone reads as missing"
# (c) the duplicate scan: the twin is on page 2, so a truncated read reports
#     "no twin" and files the duplicate P65's check exists to stop.
P70C="$T/p70-dup"
STUB_BUILD_P1=1 STUB_MS_P1=1 P70RUN "$P70C" -- fix-ticket \
    --title "Wire probe results into dashboard" --tier logic \
    --milestone "E4 · Realtime mode" >/dev/null 2>&1
grep -q -- '--method POST' "$P70C" \
    && bad "P70: the duplicate scan missed a twin sitting on page 2 and filed anyway" \
    || ok "P70: fix-ticket refuses a near-duplicate that only page 2 of the fix read holds"
STUB_BUILD_P1=1 STUB_MS_P1=1 STUB_NOPAGE=1 P70RUN "$P70C" -- fix-ticket \
    --title "Wire probe results into dashboard" --tier logic \
    --milestone "E4 · Realtime mode" >/dev/null 2>&1
grep -q -- '--method POST' "$P70C" \
    && ok "P70-violation: an unpaginated fix read files the twin it was meant to catch" \
    || bad "P70-violation: unpaginated scan still refused — fixture no longer exceeds one page"
# (d) epic acceptance: `probe-result … pass` closes the epic's milestone, and
#     on a truncated active-milestone read a passed epic simply stays open.
P70D="$T/p70-msclose"
P70RUN "$P70D" -- probe-result 36 e5 pass >/dev/null 2>&1
if grep -q 'milestones/555' "$P70D" && grep -q 'state_event=close' "$P70D"; then
    ok "P70: probe-result closes a milestone that only page 2 of the active read holds"
else
    bad "P70: passed epic's milestone never closed ($(grep -o 'milestones/[0-9]*' "$P70D" | head -2 | tr '\n' ' '))"
fi
STUB_NOPAGE=1 P70RUN "$P70D" -- probe-result 36 e5 pass >/dev/null 2>&1
grep -q 'state_event=close' "$P70D" \
    && bad "P70-violation: an unpaginated active-milestone read still found E5 — fixture no longer exceeds one page" \
    || ok "P70-violation: strip --paginate and a passed epic's milestone is never closed"

# 16b. lane.sh reconcile: reconciliation is a SCRIPT so a merge lane cannot
#      choose rebase. Two lanes chose it off the skill prose and dead-ended
#      at the force-push guardrail (build-1 2026-08-02; merge-21 build-3
#      2026-08-02, which then asked a headless void for permission). The
#      whole point: after reconcile, a PLAIN push must succeed.
RG="$T/reconcile"; mkdir -p "$RG"
git -c init.defaultBranch=main init -q --bare "$RG/origin.git"
git clone -q "$RG/origin.git" "$RG/work" 2>/dev/null
git -C "$RG/work" config user.email t@t; git -C "$RG/work" config user.name t
GITW() { git -C "$RG/work" "$@"; }
echo one > "$RG/work/f"; GITW add f; GITW commit -qm base; GITW push -q origin main
GITW checkout -qb ticket; echo two > "$RG/work/g"; GITW add g; GITW commit -qm ticket-work
GITW checkout -q main; echo three > "$RG/work/h"; GITW add h; GITW commit -qm mainline
GITW push -q origin main; GITW checkout -q ticket
old=$(GITW rev-parse HEAD)
( cd "$RG/work" && GLAB_CMD=/usr/bin/true "$LANE" reconcile ) >/dev/null 2>&1; rc_rec=$?
if [ "$rc_rec" = 0 ] && GITW merge-base --is-ancestor "$old" HEAD \
   && [ "$(GITW rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" = "3" ] \
   && GITW push -q origin ticket 2>/dev/null; then
    ok "reconcile: merges origin base, rewrites nothing, plain push succeeds"
else
    bad "reconcile: rc=$rc_rec, or history rewritten, or plain push failed"
fi
# A real conflict is rc 3 with the merge state left for the model to judge.
GITW checkout -q main; echo MAINLINE > "$RG/work/f"; GITW commit -qam clash-main
GITW push -q origin main; GITW checkout -q ticket
echo TICKET > "$RG/work/f"; GITW commit -qam clash-ticket
( cd "$RG/work" && GLAB_CMD=/usr/bin/true "$LANE" reconcile ) >/dev/null 2>&1; rc_rec=$?
if [ "$rc_rec" = 3 ] && GITW status --porcelain | grep -q "^UU f"; then
    ok "reconcile: a real conflict exits 3 with the merge state left to judge"
else
    bad "reconcile: conflict path rc=$rc_rec ($(GITW status --porcelain | head -2))"
fi
GITW merge --abort 2>/dev/null || :

# 16b2. P62: `base-check` is the evidence step under a --base-red claim — it
#       runs the caller's command against CLEAN origin/<base> in a throwaway
#       detached worktree, so a lane never improvises checkout/stash
#       gymnastics in the branch it is about to merge. The branch here has g
#       (ticket work) and base does not: a check keyed on the branch's own
#       state must come back different on clean base, or base-check is
#       running in the wrong tree and every base-red claim it feeds is
#       misattribution.
( cd "$RG/work" && GLAB_CMD=/usr/bin/true "$LANE" base-check -- test -e f ) >/dev/null 2>&1 \
    && ok "base-check: runs the command against origin/<base> (base file present, rc 0)" \
    || bad "base-check: a file on base read as missing"
( cd "$RG/work" && GLAB_CMD=/usr/bin/true "$LANE" base-check -- test -e g ) >/dev/null 2>&1 \
    && bad "base-check: saw the BRANCH's file on clean base — it is not running on base" \
    || ok "base-check: the branch's own work is absent from clean base (rc propagated)"
# The throwaway worktree is gone either way — a leaked one becomes exactly
# the standing-cleanup-chore shape the sweeper exists to prevent.
[ "$(GITW worktree list | wc -l | tr -d ' ')" = "1" ] \
    && ok "base-check: the throwaway worktree is removed on the way out" \
    || bad "base-check: leaked a worktree ($(GITW worktree list | tail -1))"
( cd "$RG/work" && GLAB_CMD=/usr/bin/true "$LANE" base-check ) >/dev/null 2>&1 \
    && bad "base-check: ran with no command" \
    || ok "base-check: no command is refused"

# A clean detached worktree has no derived dependencies. Comparing a gate
# there before installing turns every missing compiler/test runner into a
# false "base is red" result. The installer is resolved from the base tree's
# own lockfile/manifest and must complete before the requested check runs.
BC="$T/base-check-install"; mkdir -p "$BC/bin"
git init -q --bare "$BC/origin.git"
git clone -q "$BC/origin.git" "$BC/work"
git -C "$BC/work" config user.email t@t
git -C "$BC/work" config user.name t
printf '{"name":"base-check-install","private":true}\n' > "$BC/work/package.json"
git -C "$BC/work" add package.json
git -C "$BC/work" commit -qm init
git -C "$BC/work" push -qu origin HEAD:main
cat > "$BC/bin/npm" <<'EOF'
#!/usr/bin/env bash
[ "$1" = install ] || exit 94
mkdir -p node_modules
: > node_modules/.base-check-ready
EOF
chmod +x "$BC/bin/npm"
( cd "$BC/work" && PATH="$BC/bin:$PATH" LANE_BASE_CHECK_PREPARE=1 GLAB_CMD=/usr/bin/true \
    "$LANE" base-check -- test -f node_modules/.base-check-ready ) >/dev/null 2>&1 \
    && ok "base-check: prepares the clean base's derived dependencies before comparison" \
    || bad "base-check: compared against a dependency-less checkout and invented base-red"

# 16b3. P56: `wait-ready` replaces a probe's hand-rolled curl+sleep turn loop
#       with one deterministic call — ready/not-ready, never a hang past its
#       own deadline. A command that is already true returns fast; a command
#       that never becomes true still returns, at the deadline, not before.
GLAB_CMD=/usr/bin/true "$LANE" wait-ready --timeout 5 -- true >/dev/null 2>&1 \
    && ok "wait-ready: an already-ready command returns 0 immediately" \
    || bad "wait-ready: an already-ready command was not reported ready"
_wr_start=$(date +%s)
GLAB_CMD=/usr/bin/true "$LANE" wait-ready --timeout 2 --interval 1 -- false >/dev/null 2>&1
_wr_rc=$?
_wr_elapsed=$(( $(date +%s) - _wr_start ))
if [ "$_wr_rc" = 1 ] && [ "$_wr_elapsed" -ge 2 ] && [ "$_wr_elapsed" -le 6 ]; then
    ok "wait-ready: a command that never succeeds returns 1 at the deadline, not before and not hung"
else
    bad "wait-ready: never-ready command rc=$_wr_rc elapsed=${_wr_elapsed}s (want rc=1, ~2s)"
fi
GLAB_CMD=/usr/bin/true "$LANE" wait-ready -- true >/dev/null 2>&1 \
    && bad "wait-ready: ran with no --timeout" \
    || ok "wait-ready: --timeout is required"
GLAB_CMD=/usr/bin/true "$LANE" wait-ready --timeout 2 >/dev/null 2>&1 \
    && bad "wait-ready: ran with neither --url nor a command" \
    || ok "wait-ready: needs --url or -- <cmd...>"
GLAB_CMD=/usr/bin/true "$LANE" wait-ready --timeout 2 --url http://example.invalid -- true >/dev/null 2>&1 \
    && bad "wait-ready: accepted both --url and a command" \
    || ok "wait-ready: --url and -- <cmd...> together are refused"
_WR_URL_CALLS="$T/wait-ready-url-calls"; : > "$_WR_URL_CALLS"
_WR_CURL_STUB="$T/curl"; mkdir -p "$T/wrbin"
cat > "$T/wrbin/curl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$_WR_URL_CALLS"
exit 0
EOF
chmod +x "$T/wrbin/curl"
PATH="$T/wrbin:$PATH" GLAB_CMD=/usr/bin/true "$LANE" wait-ready --timeout 5 --url https://example.invalid/health >/dev/null 2>&1 \
    && grep -q "example.invalid/health" "$_WR_URL_CALLS" \
    && ok "wait-ready: --url polls via curl against that URL" \
    || bad "wait-ready: --url did not invoke curl against the URL"

# 16c. reconcile re-syncs DERIVED state. A worktree cut before a ticket added
#      a dependency carries an install that predates it, so the instant the
#      base merges in the gate goes red on a module nobody installed — and
#      nothing else re-runs setup, because SKILL step 4 installs at worktree
#      CREATION and the worktree then lives for hours. (Paid for: build-2 #14
#      2026-08-03 — merge attempt 1 died on a red logic gate because `zod`
#      landed on main via #7 while wt-14's node_modules was 18 minutes older;
#      the recovery cost a wave ~3 minutes of re-derived diagnosis and the
#      retry then merged clean after nothing but an install.)
#      LANE_INSTALL_CMD stands in for the real installer so the suite never
#      shells out to pnpm.
GITW checkout -q ticket 2>/dev/null
GITW reset -q --hard origin/ticket 2>/dev/null || :
# (a) base merge that moves a lockfile → the installer runs.
GITW checkout -q main; printf 'lock: v2\n' > "$RG/work/pnpm-lock.yaml"
GITW add pnpm-lock.yaml; GITW commit -qm "add a dependency"; GITW push -q origin main
GITW checkout -q ticket
: > "$T/install-ran"
( cd "$RG/work" && GLAB_CMD=/usr/bin/true \
    LANE_INSTALL_CMD="touch $T/install-ran.yes" "$LANE" reconcile ) >/dev/null 2>&1
[ -f "$T/install-ran.yes" ] \
    && ok "reconcile: a base merge that moves a lockfile re-installs dependencies" \
    || bad "reconcile: lockfile moved under the worktree and nothing re-installed"
# (b) base merge that touches no manifest → no install. An unconditional one
#     would tax every merge in the build to fix the minority that need it.
GITW checkout -q main; echo more > "$RG/work/unrelated"; GITW add unrelated
GITW commit -qm "no dependency change"; GITW push -q origin main; GITW checkout -q ticket
rm -f "$T/install-ran.yes"
( cd "$RG/work" && GLAB_CMD=/usr/bin/true \
    LANE_INSTALL_CMD="touch $T/install-ran.yes" "$LANE" reconcile ) >/dev/null 2>&1
[ ! -f "$T/install-ran.yes" ] \
    && ok "reconcile: an unrelated base merge does not pay for an install" \
    || bad "reconcile: installed on a merge that touched no manifest or lockfile"
# (c) a failing installer is NOT a failing reconcile — the tier gate is the
#     arbiter of mergeability and it runs next. Reconcile says so and returns 0.
GITW checkout -q main; printf 'lock: v3\n' > "$RG/work/pnpm-lock.yaml"
GITW commit -qam "another dependency"; GITW push -q origin main; GITW checkout -q ticket
out=$( cd "$RG/work" && GLAB_CMD=/usr/bin/true \
    LANE_INSTALL_CMD=/usr/bin/false "$LANE" reconcile 2>&1 ); rc_rec=$?
if [ "$rc_rec" = 0 ] && printf '%s' "$out" | grep -q "FAILED"; then
    ok "reconcile: a failed install warns loudly but leaves the verdict to the gate"
else
    bad "reconcile: failed install gave rc=$rc_rec (want 0) or said nothing"
fi
# (d) P66: a merge that moves ONLY a nested lockfile installs in that nested
#     directory. The old code matched the nested path with its regex and then
#     resolved one command against the WORKING DIRECTORY, so the root
#     ecosystem got a pointless re-install and `web/node_modules` stayed
#     exactly as stale as before. The marker is written with a RELATIVE path,
#     so where it lands is the whole assertion. (Paid for: ai-workout build-1
#     #10 — merge-10 failed twice on `openapi-typescript` missing from
#     `web/node_modules`, and the ticket never merged.)
GITW checkout -q main; mkdir -p "$RG/work/web"; printf 'lock: web-v1\n' > "$RG/work/web/pnpm-lock.yaml"
GITW add web/pnpm-lock.yaml; GITW commit -qm "add a nested dependency"; GITW push -q origin main
GITW checkout -q ticket
rm -f "$RG/work/install-ran.yes" "$RG/work/web/install-ran.yes"
( cd "$RG/work" && GLAB_CMD=/usr/bin/true \
    LANE_INSTALL_CMD="touch install-ran.yes" "$LANE" reconcile ) >/dev/null 2>&1
if [ -f "$RG/work/web/install-ran.yes" ] && [ ! -f "$RG/work/install-ran.yes" ]; then
    ok "reconcile: a nested lockfile installs in its own directory, not the root"
elif [ -f "$RG/work/install-ran.yes" ]; then
    bad "reconcile: nested lockfile moved and the ROOT installer ran — web/ still stale"
else
    bad "reconcile: nested lockfile moved and nothing installed anywhere"
fi
rm -f "$RG/work/web/install-ran.yes"
# (e) two ecosystems moved in one merge → both install. One install per
#     ecosystem is the fix; installing the first one found is the defect.
GITW checkout -q main
printf 'lock: v4\n' > "$RG/work/pnpm-lock.yaml"; printf 'lock: web-v2\n' > "$RG/work/web/pnpm-lock.yaml"
GITW commit -qam "both ecosystems move"; GITW push -q origin main; GITW checkout -q ticket
rm -f "$RG/work/install-ran.yes" "$RG/work/web/install-ran.yes"
( cd "$RG/work" && GLAB_CMD=/usr/bin/true \
    LANE_INSTALL_CMD="touch install-ran.yes" "$LANE" reconcile ) >/dev/null 2>&1
if [ -f "$RG/work/install-ran.yes" ] && [ -f "$RG/work/web/install-ran.yes" ]; then
    ok "reconcile: a merge moving two ecosystems installs both"
else
    bad "reconcile: only one ecosystem installed (root=$([ -f "$RG/work/install-ran.yes" ] && echo yes || echo no), web=$([ -f "$RG/work/web/install-ran.yes" ] && echo yes || echo no))"
fi
rm -f "$RG/work/install-ran.yes" "$RG/work/web/install-ran.yes"
# (f) a workspace member with no lockfile of its own installs at the workspace
#     ROOT, where the lockfile lives — guessing `npm install` inside a pnpm
#     workspace package writes a second, wrong node_modules.
GITW checkout -q main; mkdir -p "$RG/work/apps/api"
printf '{"name":"api"}\n' > "$RG/work/apps/api/package.json"
GITW add apps/api/package.json; GITW commit -qm "a workspace member"; GITW push -q origin main
GITW checkout -q ticket
( cd "$RG/work" && GLAB_CMD=/usr/bin/true \
    LANE_INSTALL_CMD="touch install-ran.yes" "$LANE" reconcile ) >/dev/null 2>&1
if [ -f "$RG/work/install-ran.yes" ] && [ ! -f "$RG/work/apps/api/install-ran.yes" ]; then
    ok "reconcile: a lockfile-less workspace member installs at the workspace root"
else
    bad "reconcile: workspace member installed in the wrong directory"
fi
rm -f "$RG/work/install-ran.yes" "$RG/work/apps/api/install-ran.yes"

# Killing a --follow ticker must take its tail+jq children with it. An
# orphaned pipeline kept writing to the pane after its wrapper was killed,
# so every new event rendered once per ghost — duplicate lines that
# survived a restart and grew over time (2026-08-02).
LOOM_HOME="$EVH" "$TICK" render-events --follow >/dev/null 2>&1 &
TKPID=$!
sleep 1
kill "$TKPID" 2>/dev/null; sleep 1
if pgrep -f "tail -n 100 -F $EVH/events.jsonl" >/dev/null 2>&1; then
    bad "ticker: killed --follow wrapper left an orphaned tail behind"
    pkill -f "tail -n 100 -F $EVH/events.jsonl" 2>/dev/null || :
else
    ok "ticker: killing a --follow wrapper takes its pipeline with it"
fi

test_finish
