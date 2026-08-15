#!/usr/bin/env bash
# P13: a busy lane must not read as a dead one; clear-lane, ntfy
#
# Section 06 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 4h. P13: a busy lane must not read as a dead one ----------------------
# `claude -p` writes nothing until it exits, so log mtime — the liveness
# signal — stays frozen while a lane works. A healthy lane past the staleness
# window was therefore classified wedged and killed, losing everything it had
# done. W1 of build 2 spotted this in-band and worked around it by renaming a
# lane, noting "That's a convention, not a fix."
# A fake agent interface stands in throughout. Core owns canonical streaming;
# provider-native flags and parsing are tested with each adapter.
mkdir -p "$T/fx"
cat > "$T/fx/agent.sh" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in
  preflight) exit 0 ;;
  run)
    echo "$@" > "${STUB_ARGV:-/dev/null}"
    printf '%s\n' '{"schema":1,"type":"session_start","provider":"claude","job":"gate","requested_tier":"medium"}'
    printf '%s\n' '{"schema":1,"type":"assistant_progress","provider":"claude","job":"gate","text":"reviewing the diff"}'
    printf '%s\n' '{"schema":1,"type":"tool_progress","provider":"claude","job":"gate","tool":"shell","summary":"pytest"}'
    sleep "${STUB_SLEEP:-0}"
    printf '%s\n' '{"schema":1,"type":"session_end","provider":"claude","job":"gate","status":"success","rc":0}' ;;
esac
STUBEOF
chmod +x "$T/fx/agent.sh"
FAKE="$T/fx/agent.sh"; BRIEF="$T/brief.md"; printf 'review this branch\n' > "$BRIEF"

ARGV="$T/stub-argv"; rm -f "$ARGV"
LOOM_AGENT_CMD="$FAKE" STUB_ARGV="$ARGV" "$TICK" spawn-lane gate-31 --no-tick \
  --provider claude --job gate --tier medium --brief "$BRIEF" --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 40); do [ -s "$ARGV" ] && break; sleep 0.1; done
case "$(cat "$ARGV")" in *"--provider claude"*"--job gate"*"--tier medium"*)
  ok "stream: spawn-lane invokes only the provider-neutral agent interface";;
  *) bad "stream: provider-neutral arguments missing ($(cat "$ARGV" 2>/dev/null))";; esac
[ -s "$LOOM_HOME/logs/lane-gate-31.jsonl" ] \
  && ok "stream: a provider lane records canonical JSONL" \
  || bad "stream: provider lane produced no canonical stream"
"$TICK" spawn-lane impl-32 --no-tick -- true >/dev/null; sleep 0.4
[ -f "$LOOM_HOME/logs/lane-impl-32.jsonl" ] \
  && bad "stream: a custom test-seam command was given a canonical stream" \
  || ok "stream: a custom command is spawned unchanged"

# 4h2. The fix itself, under the REAL 30-minute window rather than a contrived
#      zero: a lane whose .log has not moved since 2020 — which is what a
#      buffered `claude -p` looks like — reads `running`, because the stream is
#      what liveness judges. (A zero-minute window would make this test turn on
#      sub-second timing; the scenario it is modelling is a lane 40 minutes into
#      real work, so the real window is also the honest one.)
LOOM_AGENT_CMD="$FAKE" STUB_SLEEP=6 "$TICK" spawn-lane gate-33 --no-tick \
  --provider claude --job gate --tier medium --brief "$BRIEF" --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 80); do [ -s "$LOOM_HOME/logs/lane-gate-33.jsonl" ] && break; sleep 0.1; done
touch -t 202001010000 "$LOOM_HOME/logs/lane-gate-33.log"   # the buffered .log, frozen
if [ ! -s "$LOOM_HOME/logs/lane-gate-33.jsonl" ]; then
    bad "stream: the lane never produced a stream to judge by (spawn failed?)"
else
    st=$("$TICK" lane-status | awk '$1=="gate-33"{print $3}')
    [ "$st" = "running" ] && ok "stream: a working lane reads running despite a frozen .log" \
                          || bad "stream: working lane reported '$st' — it would have been killed"
    # 4h3. Planted violation: take the stream away and liveness falls back to
    #      the frozen .log — the old behaviour, a healthy lane condemned wedged
    #      and killed with all its work.
    mv "$LOOM_HOME/logs/lane-gate-33.jsonl" "$T/stream-hidden"
    st=$("$TICK" lane-status | awk '$1=="gate-33"{print $3}')
    [ "$st" = "stale" ] && ok "stream-violation: without the stream the same live lane reads stale" \
                        || bad "stream-violation: lane reported '$st' with no stream to judge by"
    mv "$T/stream-hidden" "$LOOM_HOME/logs/lane-gate-33.jsonl"
fi
kill "$(cat "$LOOM_HOME/lanes/gate-33.pid")" 2>/dev/null

# 4h4. P32: the third wedge shape. A lane whose long command the harness
#      auto-backgrounds blocks on a polling tool, and the poll emits
#      `tool_progress` forever — so the stamp stayed fresh while merge-50 sat
#      on a pytest deadlocked at 0% CPU for 33 minutes, holding the merge lock
#      and the whole queue behind it (build-3, 2026-08-03). What survives the
#      filter has to be a MODEL TURN. The stamp holds the filtered count, so
#      this is asserted on the number, not on timing.
# The watch pass is what `tick --auto` runs BEFORE it considers the lock, so
# with the loop switch off it stamps, flags and classifies while spending
# nothing. These tests drive that — the production path — rather than a verb
# that would exist only to be tested. (The old separate watcher had its own
# `quiet-tick` entry point; retiring it took the entry point with it.)
WATCH() { : > "$LOOM_HOME/loop.stopped"; "$TICK" tick --auto >/dev/null 2>&1; rm -f "$LOOM_HOME/loop.stopped"; }
"$TICK" spawn-lane gate-34 --no-tick -- sleep 30 >/dev/null
PJ="$LOOM_HOME/logs/lane-gate-34.jsonl"; PS="$LOOM_HOME/lanes/gate-34.progress"
printf '%s\n' '{"schema":1,"type":"assistant_progress","provider":"claude","job":"gate","text":"starting gate"}' > "$PJ"
WATCH
p0=$(cat "$PS" 2>/dev/null || echo missing)
for _ in $(seq 1 40); do printf '%s\n' '{"type":"tool_progress"}' >> "$PJ"; done
WATCH
p1=$(cat "$PS" 2>/dev/null || echo missing)
[ "$p0" = "$p1" ] && [ "$p0" != missing ] \
    && ok "staleness: 40 tool_progress polls are not progress — the stamp holds" \
    || bad "staleness: poll chatter moved the stamp ($p0 -> $p1) — a wedged lane reads fresh"
# Planted violation: a real model turn MUST move it, or the stamp would freeze
# on every healthy lane and the watcher would kill working sessions.
printf '%s\n' '{"schema":1,"type":"assistant_progress","provider":"claude","job":"gate","text":"gate came back red"}' >> "$PJ"
WATCH
p2=$(cat "$PS" 2>/dev/null || echo missing)
[ "$p2" != "$p1" ] \
    && ok "staleness: a model turn still counts as progress" \
    || bad "staleness: the stamp froze on a live lane ($p1 -> $p2)"
kill "$(cat "$LOOM_HOME/lanes/gate-34.pid")" 2>/dev/null
"$TICK" clear-lane gate-34 >/dev/null 2>&1

# 4h4b. P61: the stamp counts MODEL TURNS, so a thinking-heavy lane's
#       `thinking_tokens` system events are worth zero. The old count was a
#       denylist of known chatter, so every event type nobody had thought of
#       counted as progress: ai-workout build-1, impl-25's stream held 23 real
#       assistant turns among 163 system events and reported 162 against a
#       `lane_turn_cap` of 150. Two healthy lanes four minutes old were killed
#       and blocked on that number (2026-08-07 23:16–23:19), and every wave's
#       turn commentary was wrong all night. The fixture is that stream's
#       shape: assert the number, 23, not merely that it is smaller.
"$TICK" spawn-lane gate-61 --no-tick -- sleep 30 >/dev/null
PJ="$LOOM_HOME/logs/lane-gate-61.jsonl"; PS="$LOOM_HOME/lanes/gate-61.progress"
: > "$PJ"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"s61"}' >> "$PJ"
for i in $(seq 1 23); do
    # Each real turn arrives behind a burst of thinking-token records; the
    # interleaving is what a denylist filter cannot see past.
    for _ in $(seq 1 7); do
        printf '%s\n' '{"type":"system","subtype":"thinking_tokens","thinking_tokens":128}' >> "$PJ"
    done
    printf '%s\n' "{\"schema\":1,\"type\":\"assistant_progress\",\"provider\":\"claude\",\"job\":\"gate\",\"text\":\"turn $i\"}" >> "$PJ"
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}' >> "$PJ"
done
printf '%s\n' '{"type":"system","subtype":"thinking_tokens","thinking_tokens":64}' >> "$PJ"
printf '%s\n' '{"type":"system","subtype":"thinking_tokens","thinking_tokens":64}' >> "$PJ"
WATCH
p61=$(cat "$PS" 2>/dev/null || echo missing)
[ "$p61" = "23" ] \
    && ok "turns: 163 thinking events among 23 assistant turns stamp 23" \
    || bad "turns: stamped '$p61' for a 23-turn stream — the cap and the staleness clock both read it"
# Planted violation: count everything that is not known chatter — the shipped
# behaviour — and the same stream reads far over a 150-turn cap.
old=$(grep -cv '"subtype":"api_retry"\|"type":"rate_limit_event"\|"type":"tool_progress"' "$PJ")
[ "$old" -gt 150 ] \
    && ok "turns-violation: the old not-chatter count reads $old on the same 23 turns" \
    || bad "turns-violation: the fixture no longer reproduces the inflation ($old)"
# A truncated final line is normal mid-write and must not zero the count —
# a zeroed stamp is a frozen clock, which reads every live lane as stale.
printf '%s' '{"type":"assis' >> "$PJ"
WATCH
p61b=$(cat "$PS" 2>/dev/null || echo missing)
[ "$p61b" = "23" ] \
    && ok "turns: a half-written trailing line is skipped, not fatal" \
    || bad "turns: a truncated line moved the stamp to '$p61b'"
kill "$(cat "$LOOM_HOME/lanes/gate-61.pid")" 2>/dev/null
"$TICK" clear-lane gate-61 >/dev/null 2>&1

# 4h5. The quiescence watcher must not call an UNACCEPTED build complete.
#      Zero open tickets is "all the work merged", not "the product was
#      accepted" — and `complete` here both notifies and (step 8) tears the
#      agent down, so getting it wrong ends the build over unprobed epics.
#      An epic with every ticket closed and its milestone still open is
#      schedulable work, so it must read `stalled` and let stall_action resume
#      a wave. (Paid for: build-2 2026-08-04, three epics never accepted.)
#      `_quiet_check` calls `glab` bare, so the seam is PATH.
QH="$T/quiet-accept"; mkdir -p "$QH/bin" "$QH/home"
cat > "$QH/bin/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"state=opened"*)          echo '[]' ;;                       # every ticket merged
  *"state=closed"*)          echo '[{"iid":9,"milestone":{"title":"Reporting surface"}}]' ;;
  *"milestones?state=active"*) cat "${QSTUB_MS:?}" ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$QH/bin/glab"
printf 'build-2\n' > "$QH/home/.build-label"
: > "$QH/home/loop.stopped"     # watch, never spend — same reason as WATCH above
# Own ntfy capture: section 7 defines the shared one, and this runs before it.
QSTUB="$QH/ntfy.sh"; QCAP="$T/quiet-ntfy"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$QCAP" > "$QSTUB"; chmod +x "$QSTUB"
# (a) the epic's milestone is still open → not complete.
printf '%s\n' '[{"id":9,"title":"Reporting surface"}]' > "$QH/ms-open.json"
: > "$QCAP"
PATH="$QH/bin:$PATH" LOOM_HOME="$QH/home" LOOM_QUIET_SETTLE=0 \
    NTFY_CMD="$QSTUB" QSTUB_MS="$QH/ms-open.json" LOOM_NTFY_TOPIC=test-topic \
    WATCH
# Assert on the state sentinel, not the push: whether a given event reaches
# ntfy depends on the push allowlist, but the CLASSIFICATION is the thing
# under test — and it is also what step 8 tears the agent down on.
qs=$(cat "$QH/home/quiet.state" 2>/dev/null || echo missing)
if [ "$qs" = stalled ] && ! grep -q "build_complete" "$QCAP"; then
    ok "quiet-check: an epic with no passing probe keeps the build out of complete"
else
    bad "quiet-check: unaccepted epic classified '$qs' (want stalled), pushes: $(tr '\n' ';' < "$QCAP" | tail -c 120)"
fi
# (b) its probe passed and closed the milestone → genuinely complete.
rm -f "$QH/home/quiet.state"; : > "$QCAP"
printf '[]\n' > "$QH/ms-closed.json"
PATH="$QH/bin:$PATH" LOOM_HOME="$QH/home" LOOM_QUIET_SETTLE=0 \
    NTFY_CMD="$QSTUB" QSTUB_MS="$QH/ms-closed.json" LOOM_NTFY_TOPIC=test-topic \
    WATCH
qs=$(cat "$QH/home/quiet.state" 2>/dev/null || echo missing)
[ "$qs" = complete ] \
    && ok "quiet-check: once every epic is accepted the build completes normally" \
    || bad "quiet-check: accepted build classified '$qs' (want complete)"

# 4h5p. P49: every tracker read paginates. `per_page=100` returns page 1 and
#       says nothing about the rest, so past 100 members the acceptance gate
#       and the quiescence count both read a truncated board — and the build
#       ends over an unprobed epic by size alone. Fixture: 101 closed members
#       whose only carrier of the unaccepted epic's milestone is #101, and 101
#       open tickets of which only #101 is unblocked. Both facts live on page 2
#       and are invisible to a single page. The stub honours `--paginate` the
#       way glab does — one array PER PAGE, which is why the fold in
#       `_glab_list` is part of the read.
QPG="$T/quiet-paginate"; mkdir -p "$QPG/bin" "$QPG/home"
cat > "$QPG/bin/glab" <<'EOF'
#!/usr/bin/env bash
# STUB_NOPAGE ignores --paginate: that is exactly the pre-P49 read, and it is
# how the planted violations below remove the mechanism.
paged=no
case "$*" in *--paginate*) paged=yes ;; esac
[ -n "${STUB_NOPAGE:-}" ] && paged=no
case "$*" in
  *"state=closed"*)
      jq -nc '[range(1;101) | {iid: ., milestone: {title: "Ledger core"}}]'
      [ "$paged" = yes ] && jq -nc '[{iid: 101, milestone: {title: "Reporting surface"}}]' ;;
  *"state=opened"*)
      [ -n "${STUB_NO_OPEN:-}" ] && { echo '[]'; exit 0; }
      jq -nc '[range(1;101) | {iid: ., labels: ["build-4", "blocked"]}]'
      [ "$paged" = yes ] && jq -nc '[{iid: 101, labels: ["build-4", "ready-for-agent"]}]' ;;
  *"milestones"*) cat "${QSTUB_MS:?}" ;;
  *) echo '[]' ;;
esac
exit 0
EOF
chmod +x "$QPG/bin/glab"
printf 'build-4\n' > "$QPG/home/.build-label"
printf '%s\n' '[{"id":9,"title":"Reporting surface"}]' > "$QPG/ms-open.json"
QPGRUN() { PATH="$QPG/bin:$PATH" LOOM_HOME="$QPG/home" LOOM_QUIET_SETTLE=0 \
    QSTUB_MS="$QPG/ms-open.json" WATCH; }
# (a) the acceptance gate: the unaccepted epic is member #101.
rm -f "$QPG/home/quiet.state"
STUB_NO_OPEN=1 QPGRUN
qp=$(cat "$QPG/home/quiet.state" 2>/dev/null || echo missing)
[ "$qp" = stalled ] \
    && ok "P49: an epic awaiting probe past the first page of closed members still blocks complete" \
    || bad "P49: acceptance gate classified '$qp' (want stalled) — the closed-member read truncated"
# Planted violation: remove the pagination and the same board reads complete —
# the agent is torn down with that epic never probed.
rm -f "$QPG/home/quiet.state"
STUB_NO_OPEN=1 STUB_NOPAGE=1 QPGRUN
qp=$(cat "$QPG/home/quiet.state" 2>/dev/null || echo missing)
[ "$qp" = complete ] \
    && ok "P49-violation: a single-page closed read calls the same unprobed build complete" \
    || bad "P49-violation: unpaginated read classified '$qp' — the fixture no longer exceeds one page"
# (b) the quiescence count: `blocked == count` compared over 101 open tickets.
rm -f "$QPG/home/quiet.state"
QPGRUN
qp=$(cat "$QPG/home/quiet.state" 2>/dev/null || echo missing)
[ "$qp" = stalled ] \
    && ok "P49: one schedulable ticket on page 2 keeps the build out of halted" \
    || bad "P49: quiescence count classified '$qp' (want stalled) — the open read truncated"
# Planted violation: page 1 is 100 blocked tickets, so a single-page read calls
# a build with live work human-held.
rm -f "$QPG/home/quiet.state"
STUB_NOPAGE=1 QPGRUN
qp=$(cat "$QPG/home/quiet.state" 2>/dev/null || echo missing)
[ "$qp" = halted ] \
    && ok "P49-violation: a single-page open read calls a build with schedulable work halted" \
    || bad "P49-violation: unpaginated count classified '$qp' — the open fixture no longer exceeds one page"

# 4h5b. P46: a `stale` lane still holds its ticket — `_quiet_check` must read
#       it as `active` and return before ever touching the tracker, the same
#       as a `running` one. Proven by absence: `glab` is stubbed to leave a
#       marker on every call, and with a stale-but-alive lane present that
#       marker must never appear — the old `running`-only check fell through
#       into this exact read.
QAL="$T/quiet-alive"; mkdir -p "$QAL/bin" "$QAL/home/lanes" "$QAL/home/logs" "$QAL/repo"
cat > "$QAL/bin/glab" <<EOF
#!/usr/bin/env bash
: > "$QAL/glab-called"
echo '[]'
EOF
chmod +x "$QAL/bin/glab"
printf 'build-9\n' > "$QAL/home/.build-label"
printf 'heartbeat_stale_minutes: 0\n' > "$QAL/repo/.loom.yml"
LOOM_REPO="$QAL/repo" LOOM_HOME="$QAL/home" "$TICK" spawn-lane gate-40 -- sleep 20 >/dev/null
touch -t 202001010000 "$QAL/home/logs/lane-gate-40.log"
PATH="$QAL/bin:$PATH" LOOM_REPO="$QAL/repo" LOOM_HOME="$QAL/home" LOOM_QUIET_SETTLE=0 WATCH
if [ ! -e "$QAL/glab-called" ]; then
    ok "quiet-check: a stale-but-alive lane reads active without touching the tracker (P46)"
else
    bad "quiet-check: a stale lane fell through to a tracker read — treated as gone"
fi
kill "$(cat "$QAL/home/lanes/gate-40.pid" 2>/dev/null)" 2>/dev/null

# 4h3b. P43: the settle window must not be refreshed by the watcher's OWN
#       no-op bookkeeping. `_quiet_check` used to read `events.jsonl`'s mtime as
#       "did anything happen", but every 60s firing writes `tick_skipped` into
#       that same file. 60s < the 120s window, so it answered `active` forever,
#       never reached the halted test, and the halted gate in `cmd_tick` was
#       unreachable: a board whose every open ticket was human-held still spent
#       a model session every `min_wave_gap_minutes`. (Paid for: build-3
#       2026-08-05 — 44 idle overnight waves, ~9 USD, one blocked ticket.)
#       NOTE the settle window is left at its real default here on purpose: the
#       tests above pass LOOM_QUIET_SETTLE=0, which is exactly what let this
#       bug live.
QB="$T/quiet-selfrefresh"; mkdir -p "$QB/bin" "$QB/home"
cat > "$QB/bin/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"state=opened"*) echo '[{"iid":32,"labels":["build-3","blocked","ready-for-agent"]}]' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$QB/bin/glab"
printf 'build-3\n' > "$QB/home/.build-label"
QBS="$QB/ntfy.sh"; QBCAP="$T/quiet-selfrefresh-ntfy"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$QBCAP" > "$QBS"; chmod +x "$QBS"; : > "$QBCAP"
# The file is ONLY the watcher's own no-ops, all stamped right now.
now=$(date +%s)
: > "$QB/home/events.jsonl"
for i in 1 2 3; do
  printf '{"t":"2026-08-05T12:00:0%sZ","ts":%s,"ev":"tick_skipped","build":"build-3","reason":"wave_gap"}\n' \
    "$i" "$(( now - i ))" >> "$QB/home/events.jsonl"
done
rm -f "$QB/home/quiet.state"
PATH="$QB/bin:$PATH" LOOM_HOME="$QB/home" NTFY_CMD="$QBS" LOOM_NTFY_TOPIC=test-topic WATCH
qb=$(cat "$QB/home/quiet.state" 2>/dev/null || echo missing)
[ "$qb" = halted ] \
    && ok "quiet-check: the watcher's own tick_skipped events do not read as activity" \
    || bad "quiet-check: self-refresh — classified '$qb' (want halted) from a file of pure no-ops"
# The watcher's OWN notification must not feed its activity signal either. The
# first cut of this fix excluded only `tick_skipped`, so: classify halted ->
# notify -> the `notify` event lands in this same file -> the firing 60s later
# reads it as activity -> `active` deletes the once-per-state sentinel -> the
# firing after that classifies halted with no memory and notifies again. A
# 2-minute oscillation that re-pushed "Build halted" forever and let a wave
# through at each gap boundary, so the spend never stopped. (Paid for: build-3
# 2026-08-05, spotted by the human as a repeating banner in the ticker.)
rm -f "$QB/home/quiet.state"
: > "$QB/home/events.jsonl"
printf '{"t":"2026-08-05T12:00:01Z","ts":%s,"ev":"notify","build":"build-3"}\n' \
    "$(( $(date +%s) - 5 ))" >> "$QB/home/events.jsonl"
PATH="$QB/bin:$PATH" LOOM_HOME="$QB/home" NTFY_CMD="$QBS" LOOM_NTFY_TOPIC=test-topic WATCH
qb=$(cat "$QB/home/quiet.state" 2>/dev/null || echo missing)
[ "$qb" = halted ] \
    && ok "quiet-check: the watcher's own notify does not read as activity" \
    || bad "quiet-check: notify self-refresh — classified '$qb' (want halted), the halted banner repeats forever"
# And the dedupe survives consecutive firings: the second one says nothing.
: > "$QBCAP"
PATH="$QB/bin:$PATH" LOOM_HOME="$QB/home" NTFY_CMD="$QBS" LOOM_NTFY_TOPIC=test-topic WATCH
[ ! -s "$QBCAP" ] \
    && ok "quiet-check: a second firing in an unchanged state pushes nothing" \
    || bad "quiet-check: re-notified in an unchanged state ($(tr '\n' ';' < "$QBCAP" | tail -c 80))"

# Planted violation: a REAL event just now must still read as activity, or the
# settle window stops doing the job it exists for (a chained handoff's few-second
# gap must not read as a stall).
rm -f "$QB/home/quiet.state"
printf '{"t":"2026-08-05T12:00:09Z","ts":%s,"ev":"ticket_close","build":"build-3","ticket":"73"}\n' \
    "$(date +%s)" >> "$QB/home/events.jsonl"
PATH="$QB/bin:$PATH" LOOM_HOME="$QB/home" NTFY_CMD="$QBS" LOOM_NTFY_TOPIC=test-topic WATCH
qb=$(cat "$QB/home/quiet.state" 2>/dev/null || echo missing)
[ "$qb" = missing ] \
    && ok "quiet-check: a real event inside the settle window still reads as active" \
    || bad "quiet-check: real activity misread as '$qb' — settle window no longer protects a handoff gap"

# The SCHEDULER's own events are the same trap one level up. A wave that finds
# nothing schedulable still writes wave_start, snapshot and wave_end; the tick a
# minute later read the trailing wave_end as build activity, answered `active`,
# and walked straight through the halted gate into another wave. (Paid for:
# build-3 2026-08-06 — wave-035350 started 62s after wave-022852 ended, board
# holding one blocked ticket the whole time.)
rm -f "$QB/home/quiet.state"
now=$(date +%s)
: > "$QB/home/events.jsonl"
printf '{"t":"2026-08-06T08:53:50Z","ts":%s,"ev":"wave_start","build":"build-3","stem":"w1"}\n' \
    "$(( now - 90 ))" >> "$QB/home/events.jsonl"
printf '{"t":"2026-08-06T08:54:12Z","ts":%s,"ev":"snapshot","build":"build-3","ready":0}\n' \
    "$(( now - 70 ))" >> "$QB/home/events.jsonl"
printf '{"t":"2026-08-06T08:55:43Z","ts":%s,"ev":"wave_end","build":"build-3","stem":"w1","rc":0}\n' \
    "$(( now - 60 ))" >> "$QB/home/events.jsonl"
PATH="$QB/bin:$PATH" LOOM_HOME="$QB/home" NTFY_CMD="$QBS" LOOM_NTFY_TOPIC=test-topic WATCH
qb=$(cat "$QB/home/quiet.state" 2>/dev/null || echo missing)
[ "$qb" = halted ] \
    && ok "quiet-check: an idle wave's own events do not read as activity" \
    || bad "quiet-check: wave self-refresh — classified '$qb' (want halted); each idle wave buys the next one"

# 4h6. The quiescence gate in cmd_tick is an ALLOWLIST. It named only the states
#      that block, so a board the tracker call could not read at all fell
#      through into a full wave. On a sleeping laptop launchd runs the missed
#      firing at darkwake, before WiFi is back: glab fails and a model session
#      launches on a build where every ticket is blocked. (Paid for: build-3
#      2026-08-06 — four overnight waves, one 84 minutes long, each within a
#      minute of a darkwake.)
QU="$T/quiet-unreadable"; mkdir -p "$QU/bin" "$QU/home"
printf '#!/bin/sh\nexit 1\n' > "$QU/bin/glab"; chmod +x "$QU/bin/glab"   # no network
printf 'build-3\n' > "$QU/home/.build-label"
: > "$QU/home/events.jsonl"
# A wave writes to its own log, never to the tick's stdout, so the only honest
# probe is a marker the stub command creates.
UW="$QU/waves"; rm -f "$UW"
PATH="$QU/bin:$PATH" LOOM_HOME="$QU/home" \
    LOOM_WAVE_CMD="sh -c 'echo w >> $UW'" "$TICK" tick --auto >/dev/null 2>&1
if [ -s "$UW" ]; then
    bad "tick-gate: an unreadable board still spent a wave — the gate is a blocklist again"
else
    ok "tick-gate: a board that cannot be read spends nothing"
fi
grep -q '"reason":"unreadable"' "$QU/home/events.jsonl" 2>/dev/null \
    && ok "tick-gate: the skip is recorded, so the ticker can say why nothing ran" \
    || bad "tick-gate: skipped silently — the next investigation starts from zero again"
# A failed read is not a state change: it must leave the sentinel alone. Erasing
# it re-arms whatever state the build was already in, so every network blip
# re-pushed the same "Build halted" banner (five in one night, build-3
# 2026-08-06 — the repetition is how the human noticed).
printf 'halted\n' > "$QU/home/quiet.state"
PATH="$QU/bin:$PATH" LOOM_HOME="$QU/home" LOOM_WAVE_CMD="true" "$TICK" tick --auto >/dev/null 2>&1
[ "$(cat "$QU/home/quiet.state" 2>/dev/null)" = halted ] \
    && ok "tick-gate: an unreadable board forgets nothing, so the banner does not repeat" \
    || bad "tick-gate: a failed read erased the quiet sentinel — the halted push repeats forever"
# A repo with no build label yet is NOT unreadable — it is pre-plan, and its
# first wave is what plans it. Gating that would mean a fresh repo never starts.
QP="$T/quiet-prebuild"; mkdir -p "$QP/home"
: > "$QP/home/events.jsonl"          # no .build-label at all
PW="$QP/waves"; rm -f "$PW"
LOOM_HOME="$QP/home" LOOM_WAVE_CMD="sh -c 'echo w >> $PW'" "$TICK" tick --auto >/dev/null 2>&1
[ -s "$PW" ] \
    && ok "tick-gate: a repo with no build label still gets its first wave" \
    || bad "tick-gate: pre-plan repo refused a wave — nothing would ever plan it"
# The classification is captured with $(...), so only the classification may
# reach stdout. The notifier used to print into that capture, and the ONE firing
# where a build first goes halted is exactly the firing that notifies: the gate
# compared "notify: …\nhalted" against "halted", matched nothing, and spent.
QN="$T/quiet-capture"; mkdir -p "$QN/bin" "$QN/home"
cat > "$QN/bin/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"state=opened"*) echo '[{"iid":87,"labels":["build-3","blocked"]}]' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$QN/bin/glab"
printf 'build-3\n' > "$QN/home/.build-label"; : > "$QN/home/events.jsonl"
rm -f "$QN/home/quiet.state"          # first sight of halted → this tick notifies
NW="$QN/waves"; rm -f "$NW"
PATH="$QN/bin:$PATH" LOOM_HOME="$QN/home" NTFY_CMD="true" LOOM_NTFY_TOPIC=test-topic \
    LOOM_WAVE_CMD="sh -c 'echo w >> $NW'" "$TICK" tick --auto >/dev/null 2>&1
[ -s "$NW" ] \
    && bad "tick-gate: the firing that notifies spent a wave — notifier chatter is in the capture again" \
    || ok "tick-gate: the firing that first reports halted spends nothing"

# And the halted skip must be visible too: it used to return with no event at
# all, which is why four overnight waves took a morning to explain.
QV="$T/quiet-halted-ev"; mkdir -p "$QV/bin" "$QV/home"
cat > "$QV/bin/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"state=opened"*) echo '[{"iid":87,"labels":["build-3","blocked"]}]' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$QV/bin/glab"
printf 'build-3\n' > "$QV/home/.build-label"; : > "$QV/home/events.jsonl"
HW="$QV/waves"; rm -f "$HW"
PATH="$QV/bin:$PATH" LOOM_HOME="$QV/home" \
    LOOM_WAVE_CMD="sh -c 'echo w >> $HW'" "$TICK" tick --auto >/dev/null 2>&1
if [ -s "$HW" ]; then
    bad "tick-gate: an all-blocked board still spent a wave"
elif grep -q '"reason":"halted"' "$QV/home/events.jsonl" 2>/dev/null; then
    ok "tick-gate: an all-blocked board skips and says so in the event log"
else
    bad "tick-gate: halted skip left no event ($(tail -1 "$QV/home/events.jsonl" 2>/dev/null))"
fi

# 4h4. The log stays human shaped: the stream is rendered back to prose and the
#      commands it ran, because waves and humans read these files for verdicts
#      and crash triage.
rm -f "$LOOM_HOME/logs/lane-gate-34.log" "$LOOM_HOME/logs/lane-gate-34.jsonl"
LOOM_AGENT_CMD="$FAKE" "$TICK" spawn-lane gate-34 --no-tick \
  --provider claude --job gate --tier medium --brief "$BRIEF" --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 40); do grep -q "reviewing the diff" "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null && break; sleep 0.1; done
if grep -q "reviewing the diff" "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null \
   && grep -q "pytest" "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null; then
    ok "stream: the .log still reads as prose plus the commands the lane ran"
else
    bad "stream: .log did not render ($(head -3 "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null))"
fi

# 4h5. A reused lane id gets a FRESH log — an inherited mtime alone can read as
#      stale — but the previous transcript is rotated aside, never truncated
#      away: build 2 stacked two to four sessions per file and lost its session
#      boundaries, and a crashed lane's transcript is what triage needs.
sleep 1                                    # distinct rotation timestamp
LOOM_AGENT_CMD="$FAKE" "$TICK" spawn-lane gate-34 --no-tick \
  --provider claude --job gate --tier medium --brief "$BRIEF" --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 40); do grep -q "reviewing the diff" "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null && break; sleep 0.1; done
if ls "$LOOM_HOME/logs"/lane-gate-34-*.log >/dev/null 2>&1 \
   && grep -ql "reviewing the diff" "$LOOM_HOME/logs"/lane-gate-34-*.log 2>/dev/null; then
    ok "rotate: the previous session's transcript is preserved under its own name"
else
    bad "rotate: previous transcript lost on respawn"
fi
n=$(grep -c "reviewing the diff" "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "rotate: the live log holds this session only, not a stack of them" \
               || bad "rotate: live log holds $n sessions — boundaries are unrecoverable again"

# 4h6. Rotation skips EMPTY files (nothing to preserve), which left the old file
#      in place with its old timestamp — so a lane respawned under an id whose
#      previous run wrote nothing read as `stale` the instant it started, and
#      the wave would kill a lane that had only just begun. The fresh mtime,
#      not the rotation, is what the liveness check depends on.
"$TICK" spawn-lane gate-36 --no-tick -- true >/dev/null; sleep 0.4
"$TICK" clear-lane gate-36 >/dev/null
touch -t 202001010000 "$LOOM_HOME/logs/lane-gate-36.log" 2>/dev/null   # empty, ancient
"$TICK" spawn-lane gate-36 --no-tick -- sleep 10 >/dev/null; sleep 0.4
st=$("$TICK" lane-status | awk '$1=="gate-36"{print $3}')
[ "$st" = "running" ] \
    && ok "rotate: a lane reusing an id whose old log was empty still starts fresh" \
    || bad "rotate: respawned lane reported '$st' — it inherited an empty file's old mtime"
kill "$(cat "$LOOM_HOME/lanes/gate-36.pid" 2>/dev/null)" 2>/dev/null
"$TICK" clear-lane gate-36 >/dev/null

# 5. clear-lane forgets a harvested lane.
"$TICK" clear-lane impl-2 >/dev/null
"$TICK" lane-status | grep -q '^impl-2 ' && bad "clear-lane: impl-2 still listed" || ok "clear-lane: harvested lane forgotten"

# 6. ntfy: payload carries event/title/click; unconfigured events do not fire.
STUB="$T/ntfy-stub.sh"; CAP="$T/ntfy-capture"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$CAP" > "$STUB"; chmod +x "$STUB"
NTFY_CMD="$STUB" "$TICK" notify ticket_blocked "T87 blocked" "missing decision" "https://x/87" >/dev/null
if grep -q "X-Orch-Event: ticket_blocked" "$CAP" && grep -q "Click: https://x/87" "$CAP" && grep -q "test-topic" "$CAP"; then
    ok "ntfy: configured event fired with event header, click url, topic"
else
    bad "ntfy: payload missing fields: $(cat "$CAP" 2>/dev/null)"
fi
: > "$CAP"
NTFY_CMD="$STUB" "$TICK" notify mr_merged "t" "b" >/dev/null
[ -s "$CAP" ] && bad "ntfy-violation: unconfigured event fired" || ok "ntfy-violation: unconfigured event suppressed"

# 6b. The push list is read from the `push:` KEY, never from a line that
#     merely mentions it. An unanchored match ate the explanatory comment
#     above the key ("the reader takes the first `push:` line and stops"),
#     printed that as the event list and exited — so every event failed the
#     allowlist and notifications stopped dead. Silently, because the ticker
#     line lived past that same gate. (Paid for: the comment landed in the
#     global config between build-1 and build-2 on 2026-08-03; build-2 ran a
#     full night and completed twice with zero notifications.)
NCFG="$T/ntfy-cfg.yml"
cat > "$NCFG" <<'EOF'
ntfy:
  topic_prefix: "t-"
  # One line, always: the reader takes the first `push:` line and stops.
  push: [build_complete, ticket_blocked]
EOF
: > "$CAP"
LOOM_GLOBAL_CONFIG="$NCFG" NTFY_CMD="$STUB" "$TICK" notify build_complete "done" "b" >/dev/null 2>&1
grep -q "X-Orch-Event: build_complete" "$CAP" \
    && ok "ntfy: a comment mentioning push: does not shadow the real key" \
    || bad "ntfy: push list misparsed — a commented mention won over the key"
# The gate itself must still work off that correctly-read list.
: > "$CAP"
LOOM_GLOBAL_CONFIG="$NCFG" NTFY_CMD="$STUB" "$TICK" notify lane_stale "t" "b" >/dev/null 2>&1
[ -s "$CAP" ] && bad "ntfy-violation: event outside the parsed list still pushed" \
              || ok "ntfy: an event outside the parsed list is still suppressed"

# 6c. A suppressed push is still recorded in the TICKER. The local pane is the
#     always-on record; a push is a delivery mechanism that can be switched
#     off, misconfigured, or land in a pocket. With the ticker line behind the
#     allowlist gate, the only trace of a finished build was its absence —
#     which is exactly how the miss above stayed invisible for a night.
EVH2="$T/ntfy-ev-home"; mkdir -p "$EVH2"
LOOM_HOME="$EVH2" LOOM_GLOBAL_CONFIG="$NCFG" NTFY_CMD="$STUB" \
    "$TICK" notify lane_stale "wedged" "b" >/dev/null 2>&1
if LOOM_HOME="$EVH2" "$TICK" render-events 2>/dev/null | grep -q "wedged"; then
    ok "ticker: a notification suppressed by the push list is still shown locally"
else
    bad "ticker: suppressed notification left no local trace ($(cat "$EVH2/events.jsonl" 2>/dev/null | tail -1))"
fi

test_finish
