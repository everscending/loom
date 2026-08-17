#!/usr/bin/env bash
# sandboxed Codex waves hand launchd lane kills back to the durable host
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

KILLCTL="$T/kill-launchctl.sh"
KILL_CALLS="$T/kill-launchctl.calls"
KILL_LOADED="$T/kill-launchctl.loaded"
KILL_PID="$T/kill-launchctl.pid"
export KILL_CALLS KILL_LOADED KILL_PID LAUNCHCTL_CMD="$KILLCTL"
: > "$KILL_CALLS"

cat > "$KILLCTL" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$KILL_CALLS"
case "$1" in
  print)
    [ -f "$KILL_LOADED" ] || exit 1
    printf '    pid = %s\n' "$(cat "$KILL_PID")"
    ;;
  bootout)
    rm -f "$KILL_LOADED"
    ;;
  remove) ;;
esac
EOF
chmod +x "$KILLCTL"

sleep 60 & worker=$!
printf '%s\n' "$worker" > "$KILL_PID"
: > "$KILL_LOADED"
id=gate-390
label=com.loom.lane.fixture.gate-390
mkdir -p "$LOOM_HOME/lanes" "$LOOM_HOME/gate.lock.d/390@abc"
printf '%s\n' "$worker" > "$LOOM_HOME/lanes/$id.pid"
printf '%s\n' "$label" > "$LOOM_HOME/lanes/$id.launchd"
printf '%s\n' "$worker" > "$LOOM_HOME/gate.lock.d/390@abc/pid"

# A Codex provider process can see the launchd worker but macOS denies its
# launchctl bootout. The kill must remain durable state for the outer host;
# erasing the lane files here creates an invisible worker and a live gate lock.
CODEX_THREAD_ID=thread-1 CODEX_SESSION_ID= CODEX_CI= \
  "$TICK" kill-lane "$id" >/dev/null 2>&1
if kill -0 "$worker" 2>/dev/null \
   && [ -s "$LOOM_HOME/lanes/$id.pid" ] \
   && [ -s "$LOOM_HOME/lanes/$id.launchd" ] \
   && [ -s "$LOOM_HOME/gate.lock.d/390@abc/pid" ] \
   && find "$LOOM_HOME/lane-cleanup-queue" -mindepth 1 -maxdepth 1 -type d \
        -name 'request-*-gate-390' | grep -q . \
   && ! grep -q '^bootout ' "$KILL_CALLS"; then
    ok "lane kill: a sandboxed Codex wave preserves and queues launchd cleanup"
else
    bad "lane kill: provider-side cleanup killed or forgot the supervised lane"
fi

# The durable wrapper owns launchctl and drains the request before admitting
# queued replacements. It must retire the service, process tree, lane state,
# and the killed process's per-commit gate lock as one operation.
CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI= \
  "$TICK" drain-lane-kills >/dev/null 2>&1
sleep 1
if ! kill -0 "$worker" 2>/dev/null \
   && [ ! -e "$LOOM_HOME/lanes/$id.pid" ] \
   && [ ! -e "$LOOM_HOME/lanes/$id.launchd" ] \
   && [ ! -e "$LOOM_HOME/gate.lock.d/390@abc" ] \
   && [ ! -e "$KILL_LOADED" ] \
   && grep -q '^bootout ' "$KILL_CALLS" \
   && ! find "$LOOM_HOME/lane-cleanup-queue" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    ok "lane kill: the durable host retires the worker, service, state, and gate lock"
else
    bad "lane kill: durable cleanup left a worker, service, state file, or lock"
fi

kill "$worker" 2>/dev/null || true

# A completed one-shot has already lost its launchd marker, but a reparented
# Playwright/Next listener can still own the lane port. Provider-side clear
# cannot signal that sibling process from the Codex sandbox. It must preserve
# the port/cwd evidence and queue the entire clear for the durable host instead
# of reporting a successful reap after kill(2) was denied.
orphan_cwd="$T/dead-lane-worktree"; mkdir -p "$orphan_cwd" "$T/orphan-bin"
(cd "$orphan_cwd" && sleep 60) & orphan_pid=$!
orphan_id=impl-391
orphan_port=45191
ORPHAN_PID="$orphan_pid" ORPHAN_CWD="$orphan_cwd" ORPHAN_PORT="$orphan_port"
export ORPHAN_PID ORPHAN_CWD ORPHAN_PORT
cat > "$T/orphan-bin/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-tiTCP:$ORPHAN_PORT"*) kill -0 "$ORPHAN_PID" 2>/dev/null && printf '%s\n' "$ORPHAN_PID" ;;
  *"-p $ORPHAN_PID -d cwd -Fn"*) printf 'p%s\nfcwd\nn%s\n' "$ORPHAN_PID" "$ORPHAN_CWD" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/orphan-bin/lsof"
printf '%s\n' "$orphan_port" > "$LOOM_HOME/lanes/$orphan_id.port"
printf '%s\n' "$orphan_cwd" > "$LOOM_HOME/lanes/$orphan_id.cwd"

CODEX_THREAD_ID=thread-2 CODEX_SESSION_ID= CODEX_CI= PATH="$T/orphan-bin:$PATH" \
  "$TICK" clear-lane "$orphan_id" >/dev/null 2>&1
if kill -0 "$orphan_pid" 2>/dev/null \
   && [ -s "$LOOM_HOME/lanes/$orphan_id.port" ] \
   && [ -s "$LOOM_HOME/lanes/$orphan_id.cwd" ] \
   && find "$LOOM_HOME/lane-cleanup-queue" -mindepth 1 -maxdepth 1 -type d \
        -name "request-*-$orphan_id" | grep -q .; then
    ok "lane clear: sandboxed Codex preserves dead-lane port evidence for durable cleanup"
else
    bad "lane clear: provider-side cleanup lost or falsely reaped the orphan listener"
fi

CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI= PATH="$T/orphan-bin:$PATH" \
  "$TICK" drain-lane-cleanups >/dev/null 2>&1
if ! kill -0 "$orphan_pid" 2>/dev/null \
   && [ ! -e "$LOOM_HOME/lanes/$orphan_id.port" ] \
   && [ ! -e "$LOOM_HOME/lanes/$orphan_id.cwd" ] \
   && ! find "$LOOM_HOME/lane-cleanup-queue" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    ok "lane clear: durable host reaps the orphan listener and retires its evidence"
else
    bad "lane clear: durable cleanup left the orphan listener or lane state"
    kill "$orphan_pid" 2>/dev/null || true
fi

# A Playwright webServer can detach a process group whose listening process is
# the deepest child. Killing only that child is a false reap: the group leader
# stays alive and can recreate the listener after clear-lane has already
# erased the port/cwd recovery evidence. Resolve the verified group leader and
# retire the entire lane-owned tree before declaring cleanup complete.
group_cwd="$T/group-lane-worktree"; mkdir -p "$group_cwd" "$T/group-bin"
GROUP_LEAF_FILE="$T/group-leaf.pid"
export GROUP_LEAF_FILE
(
  cd "$group_cwd"
  sleep 60 & printf '%s\n' "$!" > "$GROUP_LEAF_FILE"
  while :; do sleep 60; done
) & group_root=$!
for _ in $(seq 1 50); do [ -s "$GROUP_LEAF_FILE" ] && break; sleep 0.1; done
group_leaf=$(cat "$GROUP_LEAF_FILE")
group_id=merge-392
group_port=45192
GROUP_ROOT="$group_root" GROUP_LEAF="$group_leaf" GROUP_CWD="$group_cwd" GROUP_PORT="$group_port"
export GROUP_ROOT GROUP_LEAF GROUP_CWD GROUP_PORT
cat > "$T/group-bin/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-tiTCP:$GROUP_PORT"*)
    state=$(/bin/ps -o state= -p "$GROUP_LEAF" 2>/dev/null | tr -d '[:space:]')
    case "$state" in ''|Z*) ;; *) printf '%s\n' "$GROUP_LEAF" ;; esac
    ;;
  *"-p $GROUP_LEAF -d cwd -Fn"*|*"-p $GROUP_ROOT -d cwd -Fn"*)
    printf 'p%s\nfcwd\nn%s\n' "$GROUP_ROOT" "$GROUP_CWD"
    ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/group-bin/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-o pgid= -p $GROUP_LEAF"*) printf ' %s\n' "$GROUP_ROOT" ;;
  *) exec /bin/ps "$@" ;;
esac
EOF
chmod +x "$T/group-bin/lsof" "$T/group-bin/ps"
printf '%s\n' "$group_port" > "$LOOM_HOME/lanes/$group_id.port"
printf '%s\n' "$group_cwd" > "$LOOM_HOME/lanes/$group_id.cwd"

CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI= PATH="$T/group-bin:$PATH" \
  "$TICK" clear-lane "$group_id" >/dev/null 2>&1
for _ in $(seq 1 30); do
    group_root_state=$(/bin/ps -o state= -p "$group_root" 2>/dev/null | tr -d '[:space:]')
    group_leaf_state=$(/bin/ps -o state= -p "$group_leaf" 2>/dev/null | tr -d '[:space:]')
    case "$group_root_state:$group_leaf_state" in
      ''|Z*:|:Z*|Z*:Z*) break ;;
    esac
    sleep 0.1
done
group_root_state=$(/bin/ps -o state= -p "$group_root" 2>/dev/null | tr -d '[:space:]')
group_leaf_state=$(/bin/ps -o state= -p "$group_leaf" 2>/dev/null | tr -d '[:space:]')
if { [ -z "$group_root_state" ] || [ "${group_root_state#Z}" != "$group_root_state" ]; } \
   && { [ -z "$group_leaf_state" ] || [ "${group_leaf_state#Z}" != "$group_leaf_state" ]; } \
   && [ ! -e "$LOOM_HOME/lanes/$group_id.port" ] \
   && [ ! -e "$LOOM_HOME/lanes/$group_id.cwd" ]; then
    ok "lane clear: a detached lane-owned server group is fully retired before its evidence"
else
    bad "lane clear: killing only the listener left its lane-owned server group alive"
fi
kill "$group_root" "$group_leaf" 2>/dev/null || true

# A durable host can itself exit after atomically claiming a cleanup request
# but before it runs the action. A later heartbeat must recover that abandoned
# running claim; otherwise queue deduplication sees it forever and clear-lane
# can only report "already queued" while the dead lane remains visible.
sleep 60 & abandoned_worker=$!
abandoned_id=gate-393
abandoned_claim="$LOOM_HOME/lane-cleanup-queue/running-abandoned-$abandoned_id"
mkdir -p "$abandoned_claim"
printf '%s\n' "$abandoned_id" > "$abandoned_claim/id"
printf '%s\n' kill > "$abandoned_claim/action"
printf '%s\n' "$abandoned_worker" > "$abandoned_claim/pid"
printf '%s\n' "$abandoned_worker" > "$LOOM_HOME/lanes/$abandoned_id.pid"
# Legacy claims did not carry a drainer owner. Only an aged legacy claim is
# safe to recover across a rolling skill update.
touch -t 202001010000 "$abandoned_claim"

CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI= \
  "$TICK" drain-lane-cleanups >/dev/null 2>&1
if ! kill -0 "$abandoned_worker" 2>/dev/null \
   && [ ! -e "$LOOM_HOME/lanes/$abandoned_id.pid" ] \
   && [ ! -e "$abandoned_claim" ]; then
    ok "lane cleanup: a later durable heartbeat reclaims an abandoned running request"
else
    bad "lane cleanup: an abandoned running request remains wedged"
    kill "$abandoned_worker" 2>/dev/null || true
fi

# Current claims name their owning drainer. A concurrent heartbeat must leave
# a live owner alone, then recover the same claim as soon as that owner dies.
sleep 60 & claim_owner=$!
owned_id=gate-394
owned_claim="$LOOM_HOME/lane-cleanup-queue/running-pid-$claim_owner-owned-$owned_id"
mkdir -p "$owned_claim"
printf '%s\n' "$owned_id" > "$owned_claim/id"
printf '%s\n' clear > "$owned_claim/action"
: > "$owned_claim/pid"
printf '%s\n' "$T/owned-worktree" > "$LOOM_HOME/lanes/$owned_id.cwd"

CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI= \
  "$TICK" drain-lane-cleanups >/dev/null 2>&1
if [ -e "$owned_claim" ] && [ -e "$LOOM_HOME/lanes/$owned_id.cwd" ]; then
    ok "lane cleanup: a live drainer retains exclusive ownership of its running request"
else
    bad "lane cleanup: a concurrent heartbeat stole a live drainer's request"
fi

kill "$claim_owner" 2>/dev/null || true
wait "$claim_owner" 2>/dev/null || true
CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI= \
  "$TICK" drain-lane-cleanups >/dev/null 2>&1
if [ ! -e "$owned_claim" ] && [ ! -e "$LOOM_HOME/lanes/$owned_id.cwd" ]; then
    ok "lane cleanup: a dead drainer's owned request is reclaimed immediately"
else
    bad "lane cleanup: a dead drainer's owned request remains wedged"
fi

# Planted violation: delete only the recovery call from a private script copy.
# The public drain command must recreate the production wedge, proving the
# holding checks above are sensitive to the mechanism rather than incidental
# cleanup elsewhere in the command.
cleanup_mutant_dir=$(mirror_scripts "$T/cleanup-mutant")
sed '/^    _reclaim_lane_cleanup_claims$/d' "$cleanup_mutant_dir/tick.sh" \
  > "$cleanup_mutant_dir/tick-mutant.sh"
chmod +x "$cleanup_mutant_dir/tick-mutant.sh"
mutant_id=gate-395
mutant_claim="$LOOM_HOME/lane-cleanup-queue/running-pid-999999-mutant-$mutant_id"
mkdir -p "$mutant_claim"
printf '%s\n' "$mutant_id" > "$mutant_claim/id"
printf '%s\n' clear > "$mutant_claim/action"
: > "$mutant_claim/pid"
printf '%s\n' "$T/mutant-worktree" > "$LOOM_HOME/lanes/$mutant_id.cwd"
mutant_rc=0
CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI= \
  "$cleanup_mutant_dir/tick-mutant.sh" drain-lane-cleanups >/dev/null 2>&1 \
  || mutant_rc=$?
if [ "$mutant_rc" -eq 0 ] \
   && [ -e "$mutant_claim" ] \
   && [ -e "$LOOM_HOME/lanes/$mutant_id.cwd" ]; then
    ok "lane-cleanup-violation: deleting stale-claim recovery recreates the wedge"
else
    bad "lane-cleanup-violation: planted omission did not recreate the wedge"
fi

test_finish
