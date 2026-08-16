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
test_finish
