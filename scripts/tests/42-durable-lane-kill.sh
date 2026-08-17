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
  *"-tiTCP:$ORPHAN_PORT"*) printf '%s\n' "$ORPHAN_PID" ;;
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

test_finish
