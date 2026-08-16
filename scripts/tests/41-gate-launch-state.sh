#!/usr/bin/env bash
# delayed gate launches revalidate the ticket state at the spawn boundary
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

STATE_FILE="$T/gate-state"
TRACKER="$T/gate-tracker.sh"
AGENT="$T/gate-agent.sh"
AGENT_CALLS="$T/gate-agent.calls"
export STATE_FILE AGENT_CALLS TRACKER_CMD="$TRACKER" LOOM_AGENT_CMD="$AGENT"

cat > "$TRACKER" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  issue)
    [ "$(cat "$STATE_FILE")" != read-fail ] || exit 1
    state=$(cat "$STATE_FILE")
    printf '{"id":%s,"state":"open","labels":["build-1","%s"],"body":""}\n' "$2" "$state"
    ;;
  *) echo '[]' ;;
esac
EOF
cat > "$AGENT" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$AGENT_CALLS"
case "$1" in
  detect|preflight) exit 0 ;;
  run) sleep 30 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TRACKER" "$AGENT"
printf 'gate brief\n' > "$T/gate-brief.md"

# A Codex request is valid when queued, then a human blocks the ticket before
# the durable host drains it. The delayed launch must be discarded, not run.
printf 'review\n' > "$STATE_FILE"
LOOM_LANE_ID=impl-330 LOOM_DEFER_LANE_LAUNCH=1 \
  "$TICK" spawn-lane gate-330 --no-tick --provider codex --job gate --tier medium \
  --brief "$T/gate-brief.md" --cwd "$LOOM_REPO" >/dev/null
printf 'blocked\n' > "$STATE_FILE"
"$TICK" drain-lane-launches >/dev/null 2>&1
if [ ! -e "$LOOM_HOME/lanes/gate-330.pid" ] \
   && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
        \( -name 'request-*' -o -name 'launching-*' \) | grep -q . \
   && ! grep -q '^run ' "$AGENT_CALLS" 2>/dev/null; then
    ok "gate launch: a delayed Codex request cannot cross a later human hold"
else
    bad "gate launch: a queued request started after its ticket left review"
fi

# The same guard covers a direct provider handoff. It succeeds as a no-op so
# the finishing implementation lane is not reported as a crash.
out=$(LOOM_LANE_ID=impl-331 "$TICK" spawn-lane gate-331 --no-tick \
  --provider claude --job gate --tier medium --brief "$T/gate-brief.md" \
  --cwd "$LOOM_REPO" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$LOOM_HOME/lanes/gate-331.pid" ] \
   && printf '%s' "$out" | grep -q 'no longer in review'; then
    ok "gate launch: a direct Claude handoff fails soft after a human hold"
else
    bad "gate launch: direct handoff ignored the tracker state (rc=$rc; out=$out)"
fi

# A tracker outage is not evidence that a queued request became invalid. Keep
# it retryable; fail closed now, let a later heartbeat re-read the board.
printf 'review\n' > "$STATE_FILE"
LOOM_LANE_ID=impl-332 LOOM_DEFER_LANE_LAUNCH=1 \
  "$TICK" spawn-lane gate-332 --no-tick --provider codex --job gate --tier medium \
  --brief "$T/gate-brief.md" --cwd "$LOOM_REPO" >/dev/null
printf 'read-fail\n' > "$STATE_FILE"
"$TICK" drain-lane-launches >/dev/null 2>&1
if [ ! -e "$LOOM_HOME/lanes/gate-332.pid" ] \
   && find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
        -name 'request-*' | grep -q .; then
    ok "gate launch: tracker read failure preserves a queued request for retry"
else
    bad "gate launch: tracker outage launched or destroyed the queued request"
fi

# Countercondition: once the ticket is back in review, the same direct path is
# admitted. This proves the holding assertions reached the state guard.
printf 'review\n' > "$STATE_FILE"
LOOM_LANE_ID=impl-333 "$TICK" spawn-lane gate-333 --no-tick \
  --provider claude --job gate --tier medium --brief "$T/gate-brief.md" \
  --cwd "$LOOM_REPO" >/dev/null 2>&1
if [ -s "$LOOM_HOME/lanes/gate-333.pid" ]; then
    ok "gate-launch-violation: returning to review admits the direct handoff"
else
    bad "gate-launch-violation: review state did not reach the provider launch"
fi

"$TICK" kill-lane gate-333 >/dev/null 2>&1 || true
test_finish
