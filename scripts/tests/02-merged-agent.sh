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

# D-TICK-37: the progress pass runs before every early return, including a
# heartbeat that sees a live tick lock. On a fresh run there may be no
# wave-*.jsonl yet. Under the launchd Bash 3.2 `set -u` path, declaring `wj`
# without assigning it left the later `[ -n "$wj" ]` dereference unbound after
# the fallible glob pipeline. Drive the public watcher seam from a fresh home,
# and pin the initialization that makes an empty listing a normal empty value.
D37_HOME="$T/dtick37-home"
mkdir -p "$D37_HOME/tick.lock.d" "$D37_HOME/logs"
printf '%s\n' "$$" > "$D37_HOME/tick.lock.d/pid"
: > "$D37_HOME/loop.stopped"
d37_out=$(LOOM_REPO="$MT/repo" LOOM_HOME="$D37_HOME" LOOM_GLOBAL_CONFIG="$T/none.yml" \
    LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_PROVIDER_CHECK=1 \
    "$TICK" tick --provider claude --auto 2>&1)
d37_rc=$?
if [ "$d37_rc" -eq 0 ] \
   && printf '%s' "$d37_out" | grep -q 'watched, no wave' \
   && ! printf '%s' "$d37_out" | grep -q 'unbound variable' \
   && grep -q 'local wj=""' "$TICK"; then
    ok "D-TICK-37: held-lock watcher treats a missing wave stream as empty"
else
    bad "D-TICK-37: fresh held-lock watcher reached an unset wave stream (rc=$d37_rc out=$d37_out)"
fi

# Planted violation: remove the initialization in a private scripts mirror and
# force the live Bash 3.2 postcondition observed after the empty, fallible
# listing (the local remains unset). The same public tick seam must then die at
# the dereference, proving the regression above guards the actual crash.
D37_MUT=$(mirror_scripts "$T/dtick37-mutant")
sed 's/local wj=""; wj=$(ls -t "$LOGS_DIR"\/wave-\*.jsonl 2>\/dev\/null | head -1)/local wj; wj=$(ls -t "$LOGS_DIR"\/wave-*.jsonl 2>\/dev\/null | head -1); unset wj/' \
    "$D37_MUT/tick.sh" > "$D37_MUT/tick-mutant.sh"
mv "$D37_MUT/tick-mutant.sh" "$D37_MUT/tick.sh"
chmod +x "$D37_MUT/tick.sh"
D37_MUT_HOME="$T/dtick37-mutant-home"
mkdir -p "$D37_MUT_HOME/tick.lock.d" "$D37_MUT_HOME/logs"
printf '%s\n' "$$" > "$D37_MUT_HOME/tick.lock.d/pid"
: > "$D37_MUT_HOME/loop.stopped"
d37_mut_out=$(LOOM_REPO="$MT/repo" LOOM_HOME="$D37_MUT_HOME" LOOM_GLOBAL_CONFIG="$T/none.yml" \
    LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_PROVIDER_CHECK=1 \
    "$D37_MUT/tick.sh" tick --provider claude --auto 2>&1)
d37_mut_rc=$?
if assert_mutant_ran "$d37_mut_rc" "$d37_mut_out" "D-TICK-37-wave-stream-violation"; then
    if [ "$d37_mut_rc" -ne 0 ] && printf '%s' "$d37_mut_out" | grep -q 'wj: unbound variable'; then
        ok "D-TICK-37 mutant: removing initialization recreates the watcher crash"
    else
        bad "D-TICK-37 mutant: unset wave stream did not fail at the public watcher seam (rc=$d37_mut_rc out=$d37_mut_out)"
    fi
fi

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

# The scheduler is the durable host for Codex-deferred lanes, and launchd
# starts it with only the PATH baked into this plist. A repo gate invokes its
# package manager by name, so resolving node alone is insufficient when node
# and pnpm are installed in different directories.
mkdir -p "$MT/package-bin"
printf '#!/bin/sh\nexit 0\n' > "$MT/package-bin/pnpm"; chmod +x "$MT/package-bin/pnpm"
out=$(PATH="$MT/package-bin:$PATH" MENV "$TICK" install --dry-run 2>&1)
path_plist=$(echo "$out" | sed -n 's/^generated (dry-run): //p')
if [ -n "$path_plist" ] && grep -qF "$MT/package-bin" "$path_plist"; then
    ok "scheduler PATH: carries the repo package manager into detached lanes"
else
    bad "scheduler PATH: pnpm directory was omitted from the launchd environment"
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

# A provider session must not invoke the epilogue contract itself. Its sandbox
# may not write the main repo, and a failed optional handoff must never turn
# submitted work into a blocked ticket. The direct call is a successful no-op;
# the deterministic host epilogue carries an explicit marker and still runs.
export LOOM_LANE_ID=merge-9
export LOOM_PROVIDER_SESSION=1
out=$(MENV "$TICK" tick --from-lane 2>&1); direct_rc=$?
direct_waves=$(_mwaves)
unset LOOM_PROVIDER_SESSION
export LOOM_LANE_EPILOGUE=1
MTICK tick --from-lane
epilogue_waves=$(_mwaves)
unset LOOM_LANE_EPILOGUE LOOM_LANE_ID
if [ "$direct_rc" = 0 ] && [ "$direct_waves" = 0 ] \
   && printf '%s' "$out" | grep -q 'host epilogue' \
   && [ "$epilogue_waves" != 0 ]; then
    ok "tick: provider handoff is a no-op; marked host epilogue still runs"
else
    bad "tick: direct rc=$direct_rc waves=$direct_waves, epilogue waves=$epilogue_waves out=$out"
fi

# A merge lane's host epilogue inherits the lane worktree as its cwd. The next
# tick sweeps merged worktrees before provider preflight, so it used to delete
# the directory beneath itself and then launch the provider/version probe from
# a cwd that no longer existed. Drive the public handoff seam from a genuinely
# merged linked worktree: sweep must remove it, while both provider preflight
# and the wave still start from the canonical main checkout without getcwd
# diagnostics. (Paid for: patient-imaging merge-193, 2026-08-17.)
DC="$T/deleted-cwd"; mkdir -p "$DC"
git -c init.defaultBranch=main init -q --bare "$DC/origin.git"
git clone -q "$DC/origin.git" "$DC/repo" 2>/dev/null
git -C "$DC/repo" config user.email loom@test
git -C "$DC/repo" config user.name loom
seed_tracker_decl "$DC/repo"
printf 'heartbeat_stale_minutes: 30\n' > "$DC/repo/.loom.yml"
printf 'base\n' > "$DC/repo/base.txt"
git -C "$DC/repo" add .loom.yml base.txt docs/agents/issue-tracker.md
git -C "$DC/repo" commit -qm base
git -C "$DC/repo" push -q origin main
git -C "$DC/repo" checkout -qb loom-193
printf 'merged\n' > "$DC/repo/merged.txt"
git -C "$DC/repo" add merged.txt
git -C "$DC/repo" commit -qm merged
git -C "$DC/repo" checkout -q main
git -C "$DC/repo" merge -q --no-edit loom-193
git -C "$DC/repo" push -q origin main
mkdir -p "$DC/repo/.worktrees"
git -C "$DC/repo" worktree add -q "$DC/repo/.worktrees/193" loom-193 2>/dev/null

DC_PROVIDER="$DC/provider-version.sh"
cat > "$DC_PROVIDER" <<'DCPROVIDER'
#!/bin/sh
pwd -P > "$DC_PROVIDER_CWD" || exit 71
printf 'provider-version 1.0\n'
DCPROVIDER
chmod +x "$DC_PROVIDER"
DC_AGENT="$DC/agent.sh"
cat > "$DC_AGENT" <<'DCAGENT'
#!/bin/sh
verb="$1"; shift
case "$verb" in
  preflight)
    "$DC_PROVIDER" --version >/dev/null || exit $?
    printf '{"schema":1,"ok":true}\n'
    ;;
  run)
    pwd -P > "$DC_WAVE_CWD" || exit 72
    printf '{"schema":1,"type":"session_end","status":"success","rc":0}\n'
    ;;
  *) exit 2 ;;
esac
DCAGENT
chmod +x "$DC_AGENT"
DC_OUT="$DC/out"; DC_PROVIDER_CWD="$DC/provider.cwd"; DC_WAVE_CWD="$DC/wave.cwd"
DC_ROOT=$(cd "$DC/repo" && pwd -P)
make_glab_fixture "$DC/fx"
cat > "$DC/open.json" <<'DCOPEN'
[{"iid":1,"title":"Build 1","project_id":1,"web_url":"https://x/1","labels":["provider::codex"],"assignees":[],"description":"**Selected epics**\n"}]
DCOPEN
export DC_PROVIDER DC_PROVIDER_CWD DC_WAVE_CWD
(
  cd "$DC/repo/.worktrees/193" || exit 1
  LOOM_REPO= LOOM_HOME="$DC/home" LOOM_GLOBAL_CONFIG="$T/none.yml" \
    GLAB_CMD="$DC/fx/glab-stub.sh" STUB_OPEN="$DC/open.json" \
    LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_PROVIDER_CHECK=1 LOOM_SKIP_AGENT_PREFLIGHT= \
    LOOM_WAVE_CMD= LOOM_AGENT_CMD="$DC_AGENT" LOOM_LANE_ID=merge-193 \
    LOOM_LANE_EPILOGUE=1 "$TICK" tick --from-lane --provider codex
) > "$DC_OUT" 2>&1
dc_rc=$?
if [ "$dc_rc" -eq 0 ] \
   && [ ! -e "$DC/repo/.worktrees/193" ] \
   && [ "$(cat "$DC_PROVIDER_CWD" 2>/dev/null)" = "$DC_ROOT" ] \
   && [ "$(cat "$DC_WAVE_CWD" 2>/dev/null)" = "$DC_ROOT" ] \
   && ! grep -Eqi 'getcwd|cannot access parent|shell-init' "$DC_OUT"; then
    ok "deleted cwd handoff: sweep removes merged lane but provider starts at canonical repo root"
else
    bad "deleted cwd handoff: rc=$dc_rc worktree=$([ -e "$DC/repo/.worktrees/193" ] && echo present || echo removed) provider=$(cat "$DC_PROVIDER_CWD" 2>/dev/null) wave=$(cat "$DC_WAVE_CWD" 2>/dev/null) out=$(tail -4 "$DC_OUT" | tr '\n' ' ')"
fi

# Planted violation: remove only the canonical-entry call from a private copy.
# The same public handoff must sweep its cwd and recreate the provider preflight
# failure, proving the new boundary—not an incidental cd in the test stub—is
# what carries the fix.
git -C "$DC/repo" worktree add -q "$DC/repo/.worktrees/194" -b loom-194 origin/main 2>/dev/null
DC_MUT=$(mirror_scripts "$DC/mutant")
sed 's/^    _enter_tick_repo_root$/: # planted deleted-cwd violation/' \
    "$DC_MUT/tick.sh" > "$DC_MUT/tick-mutant.sh"
mv "$DC_MUT/tick-mutant.sh" "$DC_MUT/tick.sh"
chmod +x "$DC_MUT/tick.sh"
rm -f "$DC_PROVIDER_CWD" "$DC_WAVE_CWD"
(
  cd "$DC/repo/.worktrees/194" || exit 1
  LOOM_REPO= LOOM_HOME="$DC/mutant-home" LOOM_GLOBAL_CONFIG="$T/none.yml" \
    GLAB_CMD="$DC/fx/glab-stub.sh" STUB_OPEN="$DC/open.json" \
    LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_PROVIDER_CHECK=1 LOOM_SKIP_AGENT_PREFLIGHT= \
    LOOM_WAVE_CMD= LOOM_AGENT_CMD="$DC_AGENT" LOOM_LANE_ID=merge-194 \
    LOOM_LANE_EPILOGUE=1 "$DC_MUT/tick.sh" tick --from-lane --provider codex
) > "$DC/mutant.out" 2>&1
dc_mut_rc=$?
dc_mut_out=$(cat "$DC/mutant.out" 2>/dev/null)
if assert_mutant_ran "$dc_mut_rc" "$dc_mut_out" "deleted-cwd-handoff-violation"; then
    if [ "$dc_mut_rc" -ne 0 ] \
       && [ ! -e "$DC/repo/.worktrees/194" ] \
       && printf '%s' "$dc_mut_out" | grep -Eqi 'getcwd|cannot access parent|shell-init'; then
        ok "deleted cwd handoff mutant: removing canonical entry recreates provider preflight failure"
    else
        bad "deleted cwd handoff mutant: violation did not recreate failure (rc=$dc_mut_rc worktree=$([ -e "$DC/repo/.worktrees/194" ] && echo present || echo removed) out=$(printf '%s' "$dc_mut_out" | tail -4 | tr '\n' ' '))"
    fi
fi

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

# `start` is an explicit request to resume now, not twenty minutes from now.
# Its RunAtLoad firing still uses automatic mode so later heartbeats remain
# paced, but the first firing after install must bypass a recent wave gap once.
printf '{"t":"now","ts":%s,"ev":"wave_start"}\n' "$(date +%s)" > "$MT/home/events.jsonl"
MENV "$TICK" install 60 >/dev/null 2>&1
MTICK tick --auto; start_first=$(_mwaves)
MTICK tick --auto; start_second=$(_mwaves)
if [ "$start_first" != 0 ] && [ "$start_second" = 0 ]; then
    ok "start kick: RunAtLoad bypasses the old gap once, then timer pacing resumes"
else
    bad "start kick: first=$start_first (want non-zero), second=$start_second (want 0)"
fi

# A human hold release is another explicit transition from no runnable work to
# runnable work. It requests one durable heartbeat continuation rather than
# launching a wave itself; the heartbeat owns the launch and consumes the
# request only after it passes the quiet/usage gates.
printf '{"t":"now","ts":%s,"ev":"wave_start"}\n' "$(date +%s)" > "$MT/home/events.jsonl"
MENV "$TICK" request-continuation hold-release 290 >/dev/null 2>&1
MTICK tick --auto; release_first=$(_mwaves)
MTICK tick --auto; release_second=$(_mwaves)
if [ "$release_first" != 0 ] && [ "$release_second" = 0 ]; then
    ok "hold release continuation: heartbeat bypasses the old gap once"
else
    bad "hold release continuation: first=$release_first (want non-zero), second=$release_second (want 0)"
fi

# A Mend-filed fix has no worker epilogue to advance it. Its successful create
# uses the same durable, coalesced heartbeat request and therefore cannot wait
# out a stale paid-wave gap.
printf '{"t":"now","ts":%s,"ev":"wave_start"}\n' "$(date +%s)" > "$MT/home/events.jsonl"
MENV "$TICK" request-continuation fix-ticket 292 >/dev/null 2>&1
MTICK tick --auto; fix_first=$(_mwaves)
MTICK tick --auto; fix_second=$(_mwaves)
if [ "$fix_first" != 0 ] && [ "$fix_second" = 0 ]; then
    ok "fix-ticket continuation: heartbeat bypasses the old gap once"
else
    bad "fix-ticket continuation: first=$fix_first (want non-zero), second=$fix_second (want 0)"
fi

# Planted violation: make the automatic wave-gap gate ignore the durable
# continuation marker. The public request still succeeds, but its heartbeat
# must now strand the work exactly as the live JOR-290 incident did.
CONT_MUT=$(mirror_scripts "$T/hold-release-continuation-mutant")
sed -e 's/\[ "$continuation_kick" -eq 0 \] && \[ "$cleanup_kick"/\[ "$cleanup_kick"/' \
    -e 's/ && \[ "$pending_kick" -eq 0 \]//' \
    "$CONT_MUT/tick.sh" > "$CONT_MUT/tick-mutant.sh"
mv "$CONT_MUT/tick-mutant.sh" "$CONT_MUT/tick.sh"
chmod +x "$CONT_MUT/tick.sh"
rm -f "$MT/home/tick.pending" "$MT/home/continuation.request" "$MT/home/continuation.claimed"
printf '{"t":"now","ts":%s,"ev":"wave_start"}\n' "$(date +%s)" > "$MT/home/events.jsonl"
MENV "$CONT_MUT/tick.sh" request-continuation hold-release 290 >/dev/null 2>&1
: > "$MWAVES"
export LOOM_WAVE_CMD="sh -c 'echo w >> $MWAVES'"
cont_mut_out=$(MENV "$CONT_MUT/tick.sh" tick --auto 2>&1); cont_mut_rc=$?
export LOOM_WAVE_CMD="true"
if assert_mutant_ran "$cont_mut_rc" "$cont_mut_out" "hold-release-continuation-violation"; then
    if [ "$(_mwaves)" = 0 ] \
       && [ ! -f "$MT/home/continuation.request" ] \
       && [ -f "$MT/home/continuation.claimed" ]; then
        ok "hold release continuation mutant: ignoring the marker recreates the idle gap"
    else
        bad "hold release continuation mutant: violation did not strand the claim (waves=$(_mwaves) request=$([ -f "$MT/home/continuation.request" ] && echo yes || echo no) claim=$([ -f "$MT/home/continuation.claimed" ] && echo yes || echo no) out=$cont_mut_out)"
    fi
fi
rm -f "$MT/home/tick.pending" "$MT/home/continuation.request" "$MT/home/continuation.claimed"

# The continuation is scheduling plumbing, not a second start verb. A stopped
# loop still refuses it and leaves the request durable for an explicit start.
printf '{"t":"now","ts":%s,"ev":"wave_start"}\n' "$(date +%s)" > "$MT/home/events.jsonl"
: > "$MT/home/loop.stopped"
MENV "$TICK" request-continuation hold-release 290 >/dev/null 2>&1
MTICK tick --auto; stopped_release=$(_mwaves)
if [ "$stopped_release" = 0 ] && [ -f "$MT/home/continuation.request" ]; then
    ok "hold release continuation: stopped loop stays stopped and retains request"
else
    bad "hold release continuation: stopped=$stopped_release request=$([ -f "$MT/home/continuation.request" ] && echo yes || echo no)"
fi
mv "$MT/home/continuation.request" "$MT/home/continuation.claimed"
MTICK tick --auto; stopped_claim_wave=$(_mwaves)
MENV "$TICK" install 60 >/dev/null 2>&1
MTICK tick --auto; resumed_claim_wave=$(_mwaves)
if [ "$stopped_claim_wave" = 0 ] \
   && [ "$resumed_claim_wave" != 0 ] \
   && [ ! -f "$MT/home/continuation.claimed" ]; then
    ok "continuation wake: stop preserves an owned claim and start resumes it"
else
    bad "continuation wake: stop/start lost or stranded an owned claim"
fi

# A continuation is useful only when the periodic heartbeat notices it. Mend
# releases work from a human process with no finishing lane, so wake the one
# already-armed scheduler immediately. The durable marker remains the source
# of truth: duplicate requests coalesce, and stop suppresses the wake without
# consuming the request. `kickstart` names the existing label only; this path
# must never bootstrap a second scheduler or launch a wave itself.
: > "$LCTL_CALLS"
rm -f "$MT/home/continuation.request"
MENV "$TICK" request-continuation hold-release 290 >/dev/null 2>&1
MENV "$TICK" request-continuation fix-ticket 292 >/dev/null 2>&1
wake_count=$(grep -c '^kickstart gui/' "$LCTL_CALLS" 2>/dev/null || true)
if [ "$wake_count" = 1 ] \
   && ! grep -q '^bootstrap\|^bootout' "$LCTL_CALLS" \
   && [ -f "$MT/home/continuation.request" ]; then
    ok "continuation wake: one armed scheduler is kicked immediately and duplicate requests coalesce"
else
    bad "continuation wake: expected one existing-label kick without scheduler creation (count=$wake_count calls=$(tr '\n' '|' < "$LCTL_CALLS"))"
fi

# `kickstart` without replacement cannot wake a launchd job that is already
# running. Hold one heartbeat after it has acquired the tick lock, then release
# new Mend work. The durable pending flag must make that same process re-tick
# immediately when its current wave exits.
ACTIVE_WAVES="$T/continuation-active-waves"
ACTIVE_STARTED="$T/continuation-active-started"
ACTIVE_RELEASE="$T/continuation-active-release"
export ACTIVE_WAVES ACTIVE_STARTED ACTIVE_RELEASE
ACTIVE_CMD="$T/continuation-active-wave.sh"
cat > "$ACTIVE_CMD" <<'ACTIVE_WAVE'
#!/bin/sh
echo wave >> "$ACTIVE_WAVES"
if [ "$(wc -l < "$ACTIVE_WAVES" | tr -d ' ')" = 1 ]; then
    : > "$ACTIVE_STARTED"
    while [ ! -f "$ACTIVE_RELEASE" ]; do sleep 0.01; done
fi
ACTIVE_WAVE
chmod +x "$ACTIVE_CMD"
: > "$ACTIVE_WAVES"
rm -f "$ACTIVE_STARTED" "$ACTIVE_RELEASE" "$MT/home/tick.pending" \
      "$MT/home/continuation.request" "$MT/home/continuation.claimed"
LOOM_LANE_LAUNCHER=launchd LOOM_WAVE_CMD="$ACTIVE_CMD" \
  MENV "$TICK" tick >/dev/null 2>&1 &
active_tick=$!
for _ in $(seq 1 200); do
    [ -f "$ACTIVE_STARTED" ] && [ -d "$MT/home/tick.lock.d" ] && break
    sleep 0.01
done
MENV "$TICK" request-continuation fix-ticket 397 >/dev/null 2>&1
: > "$ACTIVE_RELEASE"
wait "$active_tick"
active_wave_count=$(wc -l < "$ACTIVE_WAVES" | tr -d ' ')
if [ "$active_wave_count" = 2 ] \
   && [ ! -f "$MT/home/tick.pending" ] \
   && [ ! -f "$MT/home/continuation.request" ] \
   && [ ! -f "$MT/home/continuation.claimed" ]; then
    ok "continuation wake: a request after active planning replays immediately"
else
    bad "continuation wake: running launchd job stranded the request (waves=$active_wave_count pending=$([ -f "$MT/home/tick.pending" ] && echo yes || echo no) request=$([ -f "$MT/home/continuation.request" ] && echo yes || echo no))"
fi

# Freeze a private tick after its EXIT trap has observed no pending work but
# before the launchd-owned process actually exits. A writer in that window
# must wait for the process boundary; a non-replacing kick while it is still
# alive is accepted by launchctl but starts nothing.
EXIT_RACE=$(mirror_scripts "$T/continuation-exit-race")
sed '/return $rc # mutate:continuation-exit-boundary/i\
    if [ -n "${LOOM_TEST_EXIT_READY:-}" ]; then\
        : > "$LOOM_TEST_EXIT_READY"\
        while [ ! -f "$LOOM_TEST_EXIT_RELEASE" ]; do sleep 0.01; done\
    fi' "$EXIT_RACE/tick.sh" > "$EXIT_RACE/tick-race.sh"
mv "$EXIT_RACE/tick-race.sh" "$EXIT_RACE/tick.sh"
chmod +x "$EXIT_RACE/tick.sh"
EXIT_READY="$T/continuation-exit-ready"
EXIT_RELEASE="$T/continuation-exit-release"
EXIT_CALLS="$T/continuation-exit-launchctl"
EXIT_LCTL="$T/continuation-exit-launchctl.sh"
cat > "$EXIT_LCTL" <<'EXIT_LAUNCHCTL'
#!/bin/sh
state=dead
kill -0 "$EXIT_OWNER" 2>/dev/null && state=alive
echo "$1 $state" >> "$EXIT_CALLS"
exit 0
EXIT_LAUNCHCTL
chmod +x "$EXIT_LCTL"
rm -rf "$MT/home/tick.lock.d" "$MT/home/continuation.lock.d"
rm -f "$EXIT_READY" "$EXIT_RELEASE" "$EXIT_CALLS" "$MT/home/tick.pending" \
      "$MT/home/continuation.request" "$MT/home/continuation.claimed"
: > "$MWAVES"
export LOOM_TEST_EXIT_READY="$EXIT_READY" LOOM_TEST_EXIT_RELEASE="$EXIT_RELEASE"
LOOM_WAVE_CMD="sh -c 'echo w >> $MWAVES'" \
  MENV "$EXIT_RACE/tick.sh" tick >/dev/null 2>&1 &
exit_tick=$!
exit_ready_seen=0
for _ in $(seq 1 200); do
    if [ -f "$EXIT_READY" ]; then exit_ready_seen=1; break; fi
    sleep 0.01
done
export EXIT_OWNER="$exit_tick" EXIT_CALLS
MENV env LAUNCHCTL_CMD="$EXIT_LCTL" "$EXIT_RACE/tick.sh" \
  request-continuation fix-ticket 394 >/dev/null 2>&1 &
exit_request=$!
for _ in $(seq 1 100); do
    grep -q '^kickstart ' "$EXIT_CALLS" 2>/dev/null && break
    sleep 0.01
done
early_exit_kick=0
grep -q '^kickstart ' "$EXIT_CALLS" 2>/dev/null && early_exit_kick=1
: > "$EXIT_RELEASE"
wait "$exit_tick"
wait "$exit_request"
unset LOOM_TEST_EXIT_READY LOOM_TEST_EXIT_RELEASE
exit_kick_state=$(sed -n 's/^kickstart //p' "$EXIT_CALLS" | tail -1)
LOOM_LANE_LAUNCHER=launchd LOOM_WAVE_CMD="sh -c 'echo w >> $MWAVES'" \
  MENV "$TICK" tick --auto >/dev/null 2>&1
exit_wave_count=$(_mwaves)
if [ "$exit_ready_seen" = 1 ] \
   && [ "$early_exit_kick" = 0 ] && [ "$exit_kick_state" = dead ] \
   && [ "$exit_wave_count" = 2 ] \
   && [ ! -f "$MT/home/tick.pending" ] \
   && [ ! -f "$MT/home/continuation.request" ] \
   && [ ! -f "$MT/home/continuation.claimed" ]; then
    ok "continuation wake: exit-boundary writer waits and kicks the stopped job"
else
    bad "continuation wake: exit-boundary request raced the running job (ready=$exit_ready_seen early=$early_exit_kick state=$exit_kick_state waves=$exit_wave_count)"
fi

# The same flag exists before an idle kick acquires the lock. That tick owns
# it and consumes it at admission, so its successful wave must not self-replay.
: > "$ACTIVE_WAVES"
rm -f "$ACTIVE_STARTED" "$ACTIVE_RELEASE" "$MT/home/tick.pending" \
      "$MT/home/continuation.request" "$MT/home/continuation.claimed"
MENV "$TICK" request-continuation fix-ticket 398 >/dev/null 2>&1
idle_pending=0; [ -f "$MT/home/tick.pending" ] && idle_pending=1
: > "$ACTIVE_RELEASE"
LOOM_LANE_LAUNCHER=launchd LOOM_WAVE_CMD="$ACTIVE_CMD" \
  MENV "$TICK" tick --auto >/dev/null 2>&1
idle_wave_count=$(wc -l < "$ACTIVE_WAVES" | tr -d ' ')
if [ "$idle_pending" = 1 ] \
   && [ "$idle_wave_count" = 1 ] \
   && [ ! -f "$MT/home/tick.pending" ] \
   && [ ! -f "$MT/home/continuation.request" ] \
   && [ ! -f "$MT/home/continuation.claimed" ]; then
    ok "continuation wake: an idle scheduler consumes its pending replay without a double wave"
else
    bad "continuation wake: idle scheduler did not own exactly one pending request (before=$idle_pending waves=$idle_wave_count pending=$([ -f "$MT/home/tick.pending" ] && echo yes || echo no))"
fi

# Planted violation: if successful lock acquisition does not consume the
# pending work it already owns, the first idle wave exits into a redundant
# second wave.
PENDING_MUT=$(mirror_scripts "$T/continuation-pending-owner-mutant")
sed 's/rm -f "$PENDING_FILE" # mutate:continuation-pending-owner/: # mutate:continuation-pending-owner/' \
    "$PENDING_MUT/tick.sh" > "$PENDING_MUT/tick-mutant.sh"
mv "$PENDING_MUT/tick-mutant.sh" "$PENDING_MUT/tick.sh"
chmod +x "$PENDING_MUT/tick.sh"
: > "$ACTIVE_WAVES"
rm -f "$ACTIVE_STARTED" "$ACTIVE_RELEASE" "$MT/home/tick.pending" \
      "$MT/home/continuation.request" "$MT/home/continuation.claimed"
MENV "$PENDING_MUT/tick.sh" request-continuation fix-ticket 398 >/dev/null 2>&1
: > "$ACTIVE_RELEASE"
pending_mut_out=$(LOOM_LANE_LAUNCHER=launchd LOOM_WAVE_CMD="$ACTIVE_CMD" \
  MENV "$PENDING_MUT/tick.sh" tick --auto 2>&1); pending_mut_rc=$?
pending_mut_waves=$(wc -l < "$ACTIVE_WAVES" | tr -d ' ')
if assert_mutant_ran "$pending_mut_rc" "$pending_mut_out" "continuation-pending-owner-violation"; then
    if [ "$pending_mut_waves" = 2 ]; then
        ok "continuation pending mutant: retaining owned replay recreates the idle double wave"
    else
        bad "continuation pending mutant: planted owner violation ran $pending_mut_waves waves instead of two"
    fi
fi

# Freeze a private copy immediately after its first continuation claim. This
# makes the otherwise tiny claim->wave-gap->tick-lock window deterministic
# without adding a production test hook.
CLAIM_LOCK_RACE=$(mirror_scripts "$T/continuation-claim-lock-race")
sed '/continuation_kick=$(\(_continuation_claim\))/a\
    if [ -n "${LOOM_TEST_CONTINUATION_READY:-}" ]; then\
        : > "$LOOM_TEST_CONTINUATION_READY"\
        while [ ! -f "$LOOM_TEST_CONTINUATION_RELEASE" ]; do sleep 0.01; done\
    fi' "$CLAIM_LOCK_RACE/tick.sh" > "$CLAIM_LOCK_RACE/tick-race.sh"
mv "$CLAIM_LOCK_RACE/tick-race.sh" "$CLAIM_LOCK_RACE/tick.sh"
chmod +x "$CLAIM_LOCK_RACE/tick.sh"
RACE_READY="$T/continuation-claim-lock-ready"
RACE_RELEASE="$T/continuation-claim-lock-release"
export LOOM_TEST_CONTINUATION_READY="$RACE_READY"
export LOOM_TEST_CONTINUATION_RELEASE="$RACE_RELEASE"

# A request after the empty first claim must itself bypass the recent-wave gap
# and be claimed at successful lock acquisition. Otherwise this firing returns
# before it owns either a trap or a claim, leaving the immediate wake stranded.
rm -rf "$MT/home/tick.lock.d"
rm -f "$RACE_READY" "$RACE_RELEASE" "$MT/home/tick.pending" \
      "$MT/home/continuation.request" "$MT/home/continuation.claimed"
printf '{"t":"now","ts":%s,"ev":"wave_start"}\n' "$(date +%s)" > "$MT/home/events.jsonl"
: > "$MWAVES"
LOOM_LANE_LAUNCHER=launchd LOOM_WAVE_CMD="sh -c 'echo w >> $MWAVES'" \
  MENV "$CLAIM_LOCK_RACE/tick.sh" tick --auto >/dev/null 2>&1 &
claim_gap_tick=$!
for _ in $(seq 1 200); do [ -f "$RACE_READY" ] && break; sleep 0.01; done
MENV "$CLAIM_LOCK_RACE/tick.sh" request-continuation fix-ticket 395 >/dev/null 2>&1
: > "$RACE_RELEASE"
wait "$claim_gap_tick"
claim_gap_waves=$(_mwaves)
if [ "$claim_gap_waves" = 1 ] \
   && [ ! -f "$MT/home/tick.pending" ] \
   && [ ! -f "$MT/home/continuation.request" ] \
   && [ ! -f "$MT/home/continuation.claimed" ]; then
    ok "continuation wake: a request after initial claim is owned before the wave gap"
else
    bad "continuation wake: claim-to-lock request was stranded (waves=$claim_gap_waves pending=$([ -f "$MT/home/tick.pending" ] && echo yes || echo no) request=$([ -f "$MT/home/continuation.request" ] && echo yes || echo no))"
fi

# If the first pass already owns an older claim, a later request is a distinct
# generation. The successful lock acquisition must leave its pending marker
# for EXIT replay instead of consuming it with the old claim.
rm -rf "$MT/home/tick.lock.d"
rm -f "$RACE_READY" "$RACE_RELEASE" "$MT/home/tick.pending" \
      "$MT/home/continuation.request" "$MT/home/continuation.claimed"
: > "$MT/home/continuation.claimed"
: > "$MWAVES"
LOOM_LANE_LAUNCHER=launchd LOOM_WAVE_CMD="sh -c 'echo w >> $MWAVES'" \
  MENV "$CLAIM_LOCK_RACE/tick.sh" tick --auto >/dev/null 2>&1 &
old_claim_tick=$!
for _ in $(seq 1 200); do [ -f "$RACE_READY" ] && break; sleep 0.01; done
MENV "$CLAIM_LOCK_RACE/tick.sh" request-continuation fix-ticket 396 >/dev/null 2>&1
: > "$RACE_RELEASE"
wait "$old_claim_tick"
old_claim_waves=$(_mwaves)
if [ "$old_claim_waves" = 2 ] \
   && [ ! -f "$MT/home/tick.pending" ] \
   && [ ! -f "$MT/home/continuation.request" ] \
   && [ ! -f "$MT/home/continuation.claimed" ]; then
    ok "continuation wake: an older claim preserves a later request for replay"
else
    bad "continuation wake: older claim consumed the later replay (waves=$old_claim_waves pending=$([ -f "$MT/home/tick.pending" ] && echo yes || echo no) request=$([ -f "$MT/home/continuation.request" ] && echo yes || echo no))"
fi
unset LOOM_TEST_CONTINUATION_READY LOOM_TEST_CONTINUATION_RELEASE

# Concurrent Mend completions must share one atomic absent->present decision.
# A check followed by truncate lets several callers all decide they are first
# and kick the same launchd label; the marker lock makes the burst one request.
: > "$LCTL_CALLS"
rm -f "$MT/home/continuation.request" "$MT/home/continuation.claimed"
CONT_START="$T/continuation-race-start"; rm -f "$CONT_START"
for ticket in $(seq 300 331); do
    ( while [ ! -f "$CONT_START" ]; do sleep 0.001; done
      MENV "$TICK" request-continuation fix-ticket "$ticket" >/dev/null 2>&1 ) &
done
touch "$CONT_START"
wait
concurrent_wakes=$(grep -c '^kickstart gui/' "$LCTL_CALLS" 2>/dev/null || true)
if [ "$concurrent_wakes" = 1 ] && [ -f "$MT/home/continuation.request" ]; then
    ok "continuation wake: concurrent requests atomically coalesce to one scheduler kick"
else
    bad "continuation wake: concurrent absent-to-present race kicked $concurrent_wakes times"
fi

# The shared lock follows the scheduler's other mkdir locks: a dead owner is
# reclaimed, so one crashed requester cannot strand every later completion.
rm -f "$MT/home/continuation.request" "$MT/home/continuation.claimed"
mkdir -p "$MT/home/continuation.lock.d"
printf '999999\n' > "$MT/home/continuation.lock.d/pid"
MENV "$TICK" request-continuation fix-ticket 398 >/dev/null 2>&1
if [ -f "$MT/home/continuation.request" ] \
   && [ ! -e "$MT/home/continuation.lock.d" ]; then
    ok "continuation wake: a dead request-lock owner is reclaimed"
else
    bad "continuation wake: stale request lock stranded the durable marker"
fi

# Planted violation: leave the request in place instead of atomically moving
# it to the scheduler's owned claim. A later request then sees the old marker,
# coalesces into it, and the scheduler can erase both generations together.
CLAIM_MUT=$(mirror_scripts "$T/continuation-claim-mutant")
sed 's/if ! mv "$CONTINUATION_FILE" "$CONTINUATION_CLAIM_FILE"; then # mutate:continuation-claim/if ! :; then # mutate:continuation-claim/' \
    "$CLAIM_MUT/tick.sh" > "$CLAIM_MUT/tick-mutant.sh"
mv "$CLAIM_MUT/tick-mutant.sh" "$CLAIM_MUT/tick.sh"
chmod +x "$CLAIM_MUT/tick.sh"
printf '%s\n' "$(( $(date +%s) + 300 ))" > "$MT/home/usage.pause"
claim_mut_out=$(LOOM_LANE_LAUNCHER=launchd MENV "$CLAIM_MUT/tick.sh" tick --auto 2>&1); claim_mut_rc=$?
rm -f "$MT/home/usage.pause"
if assert_mutant_ran "$claim_mut_rc" "$claim_mut_out" "continuation-claim-violation"; then
    if [ -f "$MT/home/continuation.request" ] \
       && [ ! -f "$MT/home/continuation.claimed" ]; then
        ok "continuation claim mutant: removing the atomic move recreates the shared generation"
    else
        bad "continuation claim mutant: violation unexpectedly isolated the scheduler generation"
    fi
fi
rm -f "$MT/home/tick.pending"

# The scheduler must claim the generation it is consuming before it clears it.
# A later request then creates the next marker instead of coalescing into a
# marker the scheduler is about to delete. A usage pause holds the first claim
# short of the cost boundary, making that interleaving deterministic.
printf '%s\n' "$(( $(date +%s) + 300 ))" > "$MT/home/usage.pause"
MTICK tick --auto
claim_shape=0
[ -f "$MT/home/continuation.claimed" ] \
  && [ ! -f "$MT/home/continuation.request" ] && claim_shape=1
: > "$LCTL_CALLS"
MENV "$TICK" request-continuation hold-release 399 >/dev/null 2>&1
rm -f "$MT/home/usage.pause"
LOOM_LANE_LAUNCHER=launchd MTICK tick --auto; first_claim_wave=$(_mwaves)
if [ "$claim_shape" = 1 ] && [ "$first_claim_wave" = 2 ] \
   && [ ! -f "$MT/home/tick.pending" ] \
   && [ ! -f "$MT/home/continuation.claimed" ] \
   && [ ! -f "$MT/home/continuation.request" ]; then
    ok "continuation wake: consuming one claim immediately replays the later generation"
else
    bad "continuation wake: scheduler consumption stranded a later request (claim=$claim_shape waves=$first_claim_wave request=$([ -f "$MT/home/continuation.request" ] && echo yes || echo no))"
fi
MTICK tick --auto; second_claim_wave=$(_mwaves)
if [ "$second_claim_wave" = 0 ] \
   && [ ! -f "$MT/home/continuation.request" ] \
   && [ ! -f "$MT/home/continuation.claimed" ]; then
    ok "continuation wake: replayed generation does not create a third wave"
else
    bad "continuation wake: replayed generation left another wave behind (wave=$second_claim_wave)"
fi

# Claiming is not consuming. A quiet-board refusal happens after the claim but
# before the cost boundary, and must leave it for the next eligible heartbeat.
QUIET_BIN="$T/continuation-quiet-bin"; mkdir -p "$QUIET_BIN"
cat > "$QUIET_BIN/glab" <<'QUIET_GLAB'
#!/bin/sh
case "$*" in
  *"state=opened"*) echo '[{"iid":402,"labels":["build-quiet","blocked"]}]' ;;
  *) echo '[]' ;;
esac
QUIET_GLAB
chmod +x "$QUIET_BIN/glab"
printf 'build-quiet\n' > "$MT/home/.build-label"
: > "$MT/home/events.jsonl"
MENV "$TICK" request-continuation fix-ticket 402 >/dev/null 2>&1
quiet_out=$(PATH="$QUIET_BIN:$PATH" LOOM_QUIET_SETTLE=0 MENV "$TICK" tick --auto 2>&1)
if printf '%s' "$quiet_out" | grep -q 'every open ticket is blocked' \
   && [ -f "$MT/home/continuation.claimed" ] \
   && [ ! -f "$MT/home/continuation.request" ]; then
    ok "continuation wake: quiet-board refusal preserves the owned claim"
else
    bad "continuation wake: quiet-board refusal consumed or failed to claim the request"
fi
rm -f "$MT/home/.build-label" "$MT/home/quiet.state" \
      "$MT/home/continuation.request" "$MT/home/continuation.claimed"

: > "$LCTL_CALLS"
: > "$MT/home/loop.stopped"
rm -f "$MT/home/continuation.request" "$MT/home/continuation.claimed"
MENV "$TICK" request-continuation hold-release 290 >/dev/null 2>&1
if ! grep -q '^kickstart ' "$LCTL_CALLS" \
   && [ -f "$MT/home/continuation.request" ]; then
    ok "continuation wake: stopped loop retains the request without waking its scheduler"
else
    bad "continuation wake: stop did not suppress the wake or lost its request (calls=$(tr '\n' '|' < "$LCTL_CALLS"))"
fi
rm -f "$MT/home/loop.stopped" "$MT/home/tick.pending" \
      "$MT/home/continuation.request" "$MT/home/continuation.claimed"

: > "$LCTL_CALLS"
rm -f "$MT/agents"/*.plist "$MT/home/continuation.request" "$MT/home/continuation.claimed"
UNARMED_LCTL="$T/launchctl-unarmed.sh"
cat > "$UNARMED_LCTL" <<UNARMED
#!/bin/sh
echo "\$@" >> "$LCTL_CALLS"
case "\$1" in print|list) exit 1 ;; esac
exit 0
UNARMED
chmod +x "$UNARMED_LCTL"
MENV env LAUNCHCTL_CMD="$UNARMED_LCTL" "$TICK" request-continuation fix-ticket 401 >/dev/null 2>&1
if ! grep -q '^kickstart\|^bootstrap\|^bootout' "$LCTL_CALLS" \
   && [ -f "$MT/home/continuation.request" ]; then
    ok "continuation wake: unarmed loop retains the request without starting a scheduler"
else
    bad "continuation wake: unarmed request started a scheduler or lost its marker (calls=$(tr '\n' '|' < "$LCTL_CALLS"))"
fi
rm -f "$MT/home/tick.pending" "$MT/home/continuation.request" "$MT/home/continuation.claimed"

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
if grep -qxF 'wp raise' "$WPCAP" \
   && [ ! -f "$MT/home/ticker-off" ] && [ ! -f "$MT/home/viewer-off" ]; then
    ok "start: raises the viewer and clears a quit ticker / an off viewer"
else
    bad "start: viewer=$(cat "$WPCAP") ticker-off=$([ -f "$MT/home/ticker-off" ] && echo yes) viewer-off=$([ -f "$MT/home/viewer-off" ] && echo yes)"
fi

# But ONLY start clears them. An automatic tick that undid a deliberate `q`
# would make the switch worthless — the human closed it 40 seconds ago.
: > "$WPCAP"; touch "$MT/home/ticker-off" "$MT/home/viewer-off"
MTICK tick --auto
MTICK tick --from-lane
MENV "$TICK" tick --provider claude >/dev/null 2>&1
if [ -f "$MT/home/ticker-off" ] && [ -f "$MT/home/viewer-off" ] && [ ! -s "$WPCAP" ]; then
    ok "off-switches: a tick never clears them, only a typed start does"
else
    bad "off-switches: a tick undid the human's close"
fi
rm -f "$MT/home/ticker-off" "$MT/home/viewer-off"

# SKILL.md promises the same visibility for a human-typed tick as for start.
# This is especially important for Codex: a manual wave may queue work for the
# next heartbeat, and the waiting viewer must already be present when it lands.
: > "$WPCAP"; export HERDR_ENV=1
MENV "$TICK" tick --provider claude >/dev/null 2>&1
sleep 0.2
[ -s "$WPCAP" ] && ok "manual tick: raises the singleton worker viewer in herdr" \
                || bad "manual tick: ran in herdr without raising the viewer"

# A viewer failure stays visible, but it cannot block the scheduler work the
# human asked the manual tick to perform.
WPFAIL="$MT/wp-fail.sh"
printf '#!/bin/sh\necho "wp $*" >> "%s"\nexit 9\n' "$WPCAP" > "$WPFAIL"; chmod +x "$WPFAIL"
export WATCH_PANES_CMD="$WPFAIL"; : > "$WPCAP"
wp_fail_out=$(MENV "$TICK" tick --provider claude 2>&1); wp_fail_rc=$?
if [ "$wp_fail_rc" -eq 0 ] \
   && printf '%s\n' "$wp_fail_out" | grep -q 'viewer raise FAILED' \
   && ! printf '%s\n' "$wp_fail_out" | grep -q 'viewer raised'; then
    ok "manual tick: a failed viewer raise is visible without blocking scheduling"
else
    bad "manual tick: viewer failure was hidden, misreported, or blocked scheduling"
fi
export WATCH_PANES_CMD="$WPSTUB"
export HERDR_ENV=

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
printf '%s\n' '{"schema":1,"type":"assistant_progress","provider":"claude","job":"implementation","text":"working"}' \
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
