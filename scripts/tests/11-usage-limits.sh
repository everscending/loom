#!/usr/bin/env bash
# P14 usage limits and P15 wave crashes
#
# Section 11 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 10. P14 usage limits and P15 wave crashes ----------------------------
# One session-limit event cost build 2 57m35s, a quarter of the whole run, and
# three wave logs were exactly `Execution error` — 15 bytes, no retry, no
# notification. Both live on the same code path (what happens when a wave exits
# nonzero), so they are tested together and asserted apart.
# Isolated state dir: these tests pause and halt builds, which no earlier test
# should inherit.
UT="$T/usage"; mkdir -p "$UT/repo" "$UT/home" "$UT/fx"
seed_tracker_decl "$UT/repo"
: > "$UT/g.yml"
cat > "$UT/repo/.loom.yml" <<'EOF'
crash_cap: 2
ntfy:
  topic: "usage-topic"
  push: [usage_pause, usage_resume, build_halted]
EOF
UCAP="$UT/ntfy-capture"; USTUB="$UT/ntfy-stub.sh"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$UCAP" > "$USTUB"; chmod +x "$USTUB"
make_wave_stub "$UT/fx/claude"   # every WAVE_MODE below is a mode of that stub
UENV() { LOOM_REPO="$UT/repo" LOOM_HOME="$UT/home" LOOM_GLOBAL_CONFIG="$UT/g.yml" \
         NTFY_CMD="$USTUB" WAVE_COUNT="$UT/count" WAVE_ARGV="$UT/argv" \
         LOOM_WAVE_CMD="$UT/fx/claude -p wave" LOOM_RETRY_BACKOFF_SECONDS=0 \
         LOOM_SKIP_BOOTSTRAP=1 "$@"; }
_ureset() { rm -rf "$UT/home/tick.lock.d"; rm -f "$UT/home/usage.pause" "$UT/home/tick.pending"; \
            echo 0 > "$UT/count"; : > "$UT/argv"; : > "$UCAP"; }

# 10a. P15: a crashed wave retries — and exactly once. Build 2's waves did
#      neither: `exit 1` and wait, while a crashed LANE at least still fired the
#      next tick. A retry that never gives up is its own failure mode, so the
#      count is asserted on the nose.
_ureset; : > "$UT/home/wave-failures"
WAVE_MODE=crash UENV "$TICK" tick >/dev/null 2>&1
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "2" ] && ok "crash: a failed wave is retried exactly once (2 attempts)" \
               || bad "crash: expected 2 wave attempts, saw $n"

# 10b. P15: stderr gets its own file. Merging it into the log is why those three
#      crashes left 15 bytes and nothing to diagnose from.
if ls "$UT/home/logs"/wave-*.err.log >/dev/null 2>&1 \
   && grep -ql "Execution error" "$UT/home/logs"/wave-*.err.log 2>/dev/null; then
    ok "crash: the error is captured in its own .err.log, not merged away"
else
    bad "crash: no separate stderr capture"
fi

# 10c. P15: a transient crash recovers inside the same tick.
_ureset
WAVE_MODE=flaky UENV "$TICK" tick >/dev/null 2>&1
rc=$?
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$rc" = "0" ] && [ "$n" = "2" ] \
    && ok "crash: a transient wave failure recovers on the retry, same tick" \
    || bad "crash: flaky wave gave rc=$rc after $n attempts"

# 10d. P15: what survives the retry escalates to a human instead of repeating
#      silently, and a success clears the count.
#      The threshold is a CONSTANT (3), not `crash_cap`: that key means
#      "implementer crashes before a ticket is blocked" everywhere else, and
#      one key driving two mechanisms meant tuning it for a flapping ticket
#      also changed when the whole build halted.
_ureset; : > "$UT/home/wave-failures"
for _ in 1 2 3; do
    rm -rf "$UT/home/tick.lock.d"
    WAVE_MODE=crash UENV "$TICK" tick >/dev/null 2>&1
done
grep -q "X-Orch-Event: build_halted" "$UCAP" 2>/dev/null \
    && ok "crash: repeated wave failures reach the human as build_halted" \
    || bad "crash: crash_cap consecutive failures raised no notification"
rm -rf "$UT/home/tick.lock.d"
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
[ -s "$UT/home/wave-failures" ] \
    && bad "crash: a good wave left the failure count standing" \
    || ok "crash: a good wave resets the consecutive-failure count"

# 10e. P14: a usage limit is NOT a crash. It must not be retried — the observed
#      run spent sessions rediscovering the same wall — and the resume time is
#      read from the stream's rate_limit_event, not parsed out of "resets 10pm".
_ureset
FUTURE=$(( $(date +%s) + 3600 ))
WAVE_MODE=limit WAVE_RESET="$FUTURE" UENV "$TICK" tick >/dev/null 2>&1
rc=$?
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "usage: a limit is not retried (1 attempt, no wasted session)" \
               || bad "usage: limit produced $n attempts — it was treated as a crash"
[ "$rc" = "0" ] && ok "usage: a limit exits clean — it is a pause, not a failure" \
                || bad "usage: limit exited $rc, which counts the build as broken"
[ "$(cat "$UT/home/usage.pause" 2>/dev/null)" = "$FUTURE" ] \
    && ok "usage: the pause holds the machine-readable resetsAt from the stream" \
    || bad "usage: pause file holds '$(cat "$UT/home/usage.pause" 2>/dev/null)', expected $FUTURE"
grep -q "X-Orch-Event: usage_pause" "$UCAP" 2>/dev/null \
    && ok "usage: the human is told the build is paused and until when" \
    || bad "usage: no usage_pause notification"

# 10e2. The limit check has to cover the RETRY too. A crash followed by a limit
#       wrote no pause, exited nonzero and counted as a crash — so every later
#       tick burned a fresh session against the same wall, which is precisely the
#       behaviour P14 exists to stop. The retry was checked only for crashes.
#       (Found by an independent review, 2026-08-01.)
_ureset; : > "$UT/home/wave-failures"
FUTURE2=$(( $(date +%s) + 3600 ))
WAVE_MODE=crash_then_limit WAVE_RESET="$FUTURE2" UENV "$TICK" tick >/dev/null 2>&1
rc=$?
[ "$(cat "$UT/home/usage.pause" 2>/dev/null)" = "$FUTURE2" ] \
    && ok "usage: a limit met on the retry still pauses the build" \
    || bad "usage: retry limit wrote pause '$(cat "$UT/home/usage.pause" 2>/dev/null)', expected $FUTURE2"
[ "$rc" = "0" ] && ok "usage: a limit on the retry exits clean, not as a build failure" \
                || bad "usage: retry limit exited $rc"
[ -s "$UT/home/wave-failures" ] \
    && bad "usage: a limit on the retry was counted against the crash cap" \
    || ok "usage-violation: a limit on the retry does not increment the failure count"

# 10f. P14: while paused, a tick spends NO session. This is the whole point —
#      polling a limit costs a session per poll and learns nothing.
echo 0 > "$UT/count"; rm -rf "$UT/home/tick.lock.d"
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "0" ] && ok "usage: a tick during the pause spends no session at all" \
               || bad "usage: paused tick still ran $n wave(s)"

# 10g. P14: and it resumes on its own once capacity is back.
echo 0 > "$UT/count"; rm -rf "$UT/home/tick.lock.d"
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$UT/home/usage.pause"
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "1" ] && [ ! -f "$UT/home/usage.pause" ] \
    && ok "usage: the pause lifts by itself once the reset time passes" \
    || bad "usage: after reset saw $n wave(s), pause file present=$([ -f "$UT/home/usage.pause" ] && echo yes || echo no)"
grep -q "X-Orch-Event: usage_resume" "$UCAP" 2>/dev/null \
    && ok "usage: resuming is announced too, so the pause has a visible end" \
    || bad "usage: no usage_resume notification"

# 10h. Planted violation: `rate_limit_event` appears in perfectly HEALTHY runs —
#      a live capture of a two-word session contains one with status "allowed".
#      Pausing on the event's mere presence would stall a working build, so the
#      failed session is the trigger and the event only supplies the time.
_ureset
WAVE_MODE=healthy_limit_event UENV "$TICK" tick >/dev/null 2>&1
[ -f "$UT/home/usage.pause" ] \
    && bad "usage-violation: a healthy wave's rate_limit_event paused the build" \
    || ok "usage-violation: a healthy rate_limit_event does not pause anything"

# 10i. A limit with nothing to read the reset time from still pauses — on a
#      fixed interval rather than a guessed clock time.
_ureset
WAVE_MODE=quiet_limit UENV "$TICK" tick >/dev/null 2>&1
at=$(cat "$UT/home/usage.pause" 2>/dev/null || echo 0)
[ "$at" -gt "$(date +%s)" ] 2>/dev/null \
    && ok "usage: a limit with no resetsAt still pauses, on a fixed backoff" \
    || bad "usage: unreadable reset time produced pause '$at'"

# 10j. `stop_and_wait` is for someone who wants to decide when to spend capacity
#      again: the pause never lifts on its own, and `resume` is the one step.
_ureset
printf 'usage_limit: stop_and_wait\n' >> "$UT/repo/.loom.yml"
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$UT/home/usage.pause"   # long past due
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "0" ] && ok "usage: stop_and_wait holds the pause past the reset time" \
               || bad "usage: stop_and_wait resumed by itself after $n wave(s)"
UENV "$TICK" resume >/dev/null 2>&1
rm -rf "$UT/home/tick.lock.d"
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "usage: \`resume\` clears a stop_and_wait pause by hand" \
               || bad "usage: resume did not release the build ($n waves)"
sed -i.bak '/usage_limit: stop_and_wait/d' "$UT/repo/.loom.yml"

# 10k. `downshift_model` is the third policy: hand the session a cheaper model to
#      fall back to rather than stopping. Asserted on the argv the wave actually
#      received, and absent under the default policy.
_ureset
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
grep -q -- "--fallback-model" "$UT/argv" 2>/dev/null \
    && bad "downshift: fallback model passed under the default policy" \
    || ok "downshift: the default policy passes no fallback model"
_ureset
printf 'usage_limit: downshift_model\nfallback_model: sonnet\n' >> "$UT/repo/.loom.yml"
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
grep -q -- "--fallback-model sonnet" "$UT/argv" 2>/dev/null \
    && ok "downshift: the configured fallback model reaches the wave's argv" \
    || bad "downshift: no --fallback-model in '$(cat "$UT/argv" 2>/dev/null)'"
sed -i.bak '/^usage_limit: downshift_model/d;/^fallback_model: sonnet/d' "$UT/repo/.loom.yml"

test_finish
