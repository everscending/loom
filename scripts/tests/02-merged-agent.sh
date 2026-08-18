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

# Once a validated selector exists, fresh heartbeats enter through the stable
# dispatcher. The plist must never pin the mutable checkout or one release.
RID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RTH="$T/runtime"; RSEL="$RTH/consumers/test.active"; RLAUNCH="$RTH/bin/loom-runtime"
mkdir -p "${RSEL%/*}" "${RLAUNCH%/*}"
printf 'schema 1\ncurrent %s\n' "$RID" > "$RSEL"
printf '#!/bin/sh\nexit 0\n' > "$RLAUNCH"; chmod +x "$RLAUNCH"
runtime_out=$(LOOM_REPO="$MT/repo" LOOM_HOME="$MT/home" LOOM_PLIST_DIR="$MT/agents" \
  LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1 LOOM_RUNTIME_RELEASE="$RID" \
  LOOM_RUNTIME_HOME="$RTH" LOOM_RUNTIME_SELECTOR="$RSEL" LOOM_RUNTIME_LAUNCHER="$RLAUNCH" \
  "$TICK" install --dry-run 2>&1)
runtime_plist=$(echo "$runtime_out" | sed -n 's/^generated (dry-run): //p')
if grep -qF "<string>$RLAUNCH</string><string>run</string><string>--</string><string>tick</string><string>tick</string>" "$runtime_plist" \
   && grep -qF "<string>$RSEL</string>" "$runtime_plist"; then
    ok "runtime release: scheduler plist selects through the stable dispatcher"
else
    bad "runtime release: scheduler plist still pins mutable or release-local code"
fi
mkdir -p "$RTH/publish.lock"
printf '%s\n' "$$" > "$RTH/publish.lock/pid"
publish_tick_out=$(LOOM_REPO="$MT/repo" LOOM_HOME="$MT/home" LOOM_PLIST_DIR="$MT/agents" \
  LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1 LOOM_RUNTIME_RELEASE="$RID" \
  LOOM_RUNTIME_HOME="$RTH" LOOM_RUNTIME_SELECTOR="$RSEL" LOOM_RUNTIME_LAUNCHER="$RLAUNCH" \
  "$TICK" tick --provider claude 2>&1)
if printf '%s' "$publish_tick_out" | grep -q 'runtime publication is in progress' \
   && [ ! -d "$MT/home/tick.lock.d" ]; then
    ok "runtime release: tick admission cannot race a selector publication"
else
    bad "runtime release: a new old-runtime tick crossed selector publication"
fi
start_during_publish=$(env -u LOOM_ALLOW_MUTABLE_RUNTIME LOOM_REPO="$MT/repo" LOOM_HOME="$MT/home" \
  LOOM_PLIST_DIR="$MT/agents" LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1 \
  LOOM_RUNTIME_RELEASE="$RID" LOOM_RUNTIME_HOME="$RTH" LOOM_RUNTIME_SELECTOR="$RSEL" \
  LOOM_RUNTIME_LAUNCHER="$RLAUNCH" "$TICK" install --provider claude 2>&1)
start_during_publish_rc=$?
if [ "$start_during_publish_rc" -ne 0 ] \
   && printf '%s' "$start_during_publish" | grep -q 'runtime publication'; then
    ok "runtime release: start cannot race a selected-runtime migration"
else
    bad "runtime release: start crossed a selected-runtime migration"
fi
rm -f "$RSEL"
mkdir -p "$MT/home/lane-launch-queue/request-late"
printf 'still queued\n' > "$MT/home/lane-launch-queue/request-late/proof"
legacy_tick_out=$(env -u LOOM_ALLOW_MUTABLE_RUNTIME LOOM_REPO="$MT/repo" LOOM_HOME="$MT/home" \
  LOOM_PLIST_DIR="$MT/agents" LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1 \
  LOOM_RUNTIME_RELEASE= LOOM_RUNTIME_HOME="$RTH" LOOM_RUNTIME_SELECTOR="$RSEL" \
  LOOM_RUNTIME_LAUNCHER="$RLAUNCH" "$TICK" tick --provider claude 2>&1)
if printf '%s' "$legacy_tick_out" | grep -q 'runtime publication is in progress' \
   && [ ! -d "$MT/home/tick.lock.d" ] \
   && [ -f "$MT/home/lane-launch-queue/request-late/proof" ] \
   && [ -z "$(find "$MT/home/lane-launch-queue" -type d -name 'launching-*' -print)" ]; then
    ok "runtime release: first cutover blocks a late mutable tick before queue drain"
else
    bad "runtime release: a mutable tick drained work across first-cutover publication"
fi
rm -rf "$MT/home/lane-launch-queue"
printf 'schema 1\ncurrent %s\n' "$RID" > "$RSEL"
rm -rf "$RTH/publish.lock"

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
cutover_out=$(MENV "$TICK" runtime publish 2>&1); cutover_rc=$?
if [ "$cutover_rc" -ne 0 ] && printf '%s' "$cutover_out" | grep -q 'cutover requires the scheduler to be unloaded'; then
    ok "runtime release: first cutover refuses an armed mutable scheduler"
else
    bad "runtime release: first cutover left an armed mutable scheduler behind"
fi

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
sed 's/\[ "$continuation_kick" -eq 0 \] && \[ "$cleanup_kick"/\[ "$cleanup_kick"/' \
    "$CONT_MUT/tick.sh" > "$CONT_MUT/tick-mutant.sh"
mv "$CONT_MUT/tick-mutant.sh" "$CONT_MUT/tick.sh"
chmod +x "$CONT_MUT/tick.sh"
rm -f "$MT/home/continuation.request"
printf '{"t":"now","ts":%s,"ev":"wave_start"}\n' "$(date +%s)" > "$MT/home/events.jsonl"
MENV "$CONT_MUT/tick.sh" request-continuation hold-release 290 >/dev/null 2>&1
: > "$MWAVES"
export LOOM_WAVE_CMD="sh -c 'echo w >> $MWAVES'"
cont_mut_out=$(MENV "$CONT_MUT/tick.sh" tick --auto 2>&1); cont_mut_rc=$?
export LOOM_WAVE_CMD="true"
if assert_mutant_ran "$cont_mut_rc" "$cont_mut_out" "hold-release-continuation-violation"; then
    if [ "$(_mwaves)" = 0 ] && [ -f "$MT/home/continuation.request" ]; then
        ok "hold release continuation mutant: ignoring the marker recreates the idle gap"
    else
        bad "hold release continuation mutant: violation did not strand the request (waves=$(_mwaves) request=$([ -f "$MT/home/continuation.request" ] && echo yes || echo no) out=$cont_mut_out)"
    fi
fi
rm -f "$MT/home/continuation.request"

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
rm -f "$MT/home/loop.stopped" "$MT/home/continuation.request"

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
