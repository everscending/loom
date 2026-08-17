#!/usr/bin/env bash
# successor handoffs share the auxiliary lane cap with scheduler spawns
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

printf '\nmax_aux_lanes: 4\n' >> "$LOOM_REPO/.loom.yml"

aux_alive() {
    "$TICK" lane-status 2>/dev/null \
        | awk '($3=="running"||$3=="stale") && ($4=="gate"||$4=="merge"||$4=="probe") { n++ } END { print n+0 }'
}

for id in 221 222 223 224; do
    "$TICK" spawn-lane "gate-$id" --no-tick -- sleep 30 >/dev/null
done

# D-TICK-25: the planner already holds at four auxiliary lanes, but an
# implementation lane's direct successor handoff used to bypass that planner
# and start a fifth gate. A soft refusal must preserve the previous lane state:
# the ordinary heartbeat will see the ticket in review and schedule it later.
printf 'previous gate transcript\n' > "$LOOM_HOME/logs/lane-gate-225.log"
printf '7\n' > "$LOOM_HOME/lanes/gate-225.rc"
out=$(LOOM_LANE_ID=impl-225 "$TICK" spawn-lane gate-225 --no-tick -- sleep 30 2>&1)
if [ "$(aux_alive)" = 4 ] \
   && [ "$(cat "$LOOM_HOME/logs/lane-gate-225.log" 2>/dev/null)" = "previous gate transcript" ] \
   && [ "$(cat "$LOOM_HOME/lanes/gate-225.rc" 2>/dev/null)" = 7 ] \
   && printf '%s' "$out" | grep -q 'auxiliary lane cap'; then
    ok "aux cap: a direct successor handoff at 4 of 4 fails soft without destructive lane state"
else
    bad "aux cap: direct successor bypassed the cap or damaged prior state (alive=$(aux_alive); out=$out)"
fi

# Planted violation: the same fifth lane is admitted when the configured cap
# is deliberately raised. This proves the holding assertion above reached the
# capacity guard rather than some unrelated spawn refusal.
sed -i.bak 's/^max_aux_lanes: 4$/max_aux_lanes: 5/' "$LOOM_REPO/.loom.yml"
LOOM_LANE_ID=impl-225 "$TICK" spawn-lane gate-225 --no-tick -- sleep 30 >/dev/null 2>&1 || true
if [ "$(aux_alive)" = 5 ]; then
    ok "aux-cap-violation: raising the cap admits the fifth successor"
else
    bad "aux-cap-violation: the fifth successor stayed blocked after the cap was raised"
fi
"$TICK" kill-lane gate-225 >/dev/null 2>&1 || true
sed -i.bak 's/^max_aux_lanes: 5$/max_aux_lanes: 4/' "$LOOM_REPO/.loom.yml"

# Codex queues its handoff until it returns to a durable host. That queued
# request reserves the last slot: a scheduler/direct competitor cannot take it
# between queue and drain, and the drain launches exactly the fourth aux lane.
"$TICK" kill-lane gate-224 >/dev/null 2>&1 || true

# Two implementations can finish together. The admission decision is atomic:
# only one may consume the last slot, even when both check concurrently.
LOOM_LANE_ID=impl-228 "$TICK" spawn-lane gate-228 --no-tick -- sleep 30 >/dev/null 2>&1 &
p228=$!
LOOM_LANE_ID=impl-229 "$TICK" spawn-lane gate-229 --no-tick -- sleep 30 >/dev/null 2>&1 &
p229=$!
wait "$p228"; wait "$p229"
if [ "$(aux_alive)" = 4 ]; then
    ok "aux cap: simultaneous successor handoffs atomically share the last slot"
else
    bad "aux cap: simultaneous successor handoffs raced past the last slot (alive=$(aux_alive))"
fi
"$TICK" kill-lane gate-228 >/dev/null 2>&1 || true
"$TICK" kill-lane gate-229 >/dev/null 2>&1 || true

AGENT="$T/aux-agent.sh"
TRACKER="$T/aux-tracker.sh"
cat > "$AGENT" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  detect|preflight) exit 0 ;;
  run) sleep 30 ;;
  *) exit 2 ;;
esac
EOF
cat > "$TRACKER" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  issue) printf '{"id":%s,"state":"open","labels":["build-1","review"],"body":""}\n' "$2" ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$AGENT" "$TRACKER"
export TRACKER_CMD="$TRACKER"
printf 'queued gate brief\n' > "$T/aux-brief.md"

# An auxiliary worker's successor replaces the slot that worker is about to
# release. Count the live source as transferable so its provider session can
# reserve the successor before exiting; otherwise the reservation is refused
# at N of N, the source exits, and the slot sits idle until a later scheduling
# wave. The queued reservation still blocks unrelated competitors.
"$TICK" spawn-lane gate-224 --no-tick -- sleep 30 >/dev/null
LOOM_LANE_ID=gate-224 LOOM_DEFER_LANE_LAUNCH=1 LOOM_AGENT_CMD="$AGENT" \
  "$TICK" spawn-lane merge-224 --no-tick --provider codex --job merge --tier medium \
  --brief "$T/aux-brief.md" --cwd "$LOOM_REPO" >/dev/null
if find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
     -name 'request-*' -exec sh -c \
     '[ "$(cat "$1/id" 2>/dev/null)" = merge-224 ] && printf "%s\n" "$1"' _ {} \; | grep -q .; then
    ok "aux cap: an exiting auxiliary lane reserves its successor's slot"
else
    bad "aux cap: full-cap auxiliary handoff was discarded instead of reserved"
fi
"$TICK" kill-lane gate-224 >/dev/null 2>&1 || true
LOOM_AGENT_CMD="$AGENT" "$TICK" drain-lane-launches >/dev/null
if [ "$(aux_alive)" = 4 ] && [ -s "$LOOM_HOME/lanes/merge-224.pid" ]; then
    ok "aux cap: the durable host fills the source lane's released slot"
else
    bad "aux cap: a released auxiliary slot stayed idle despite its successor handoff"
fi
"$TICK" kill-lane merge-224 >/dev/null 2>&1 || true

LOOM_LANE_ID=impl-226 LOOM_DEFER_LANE_LAUNCH=1 LOOM_AGENT_CMD="$AGENT" \
  "$TICK" spawn-lane gate-226 --no-tick --provider codex --job gate --tier medium \
  --brief "$T/aux-brief.md" --cwd "$LOOM_REPO" >/dev/null

# A request can meet a full cap at drain time after config/capacity changes.
# That refusal is retryable: it goes back to request-* rather than failed-* or
# disappearing, and a later heartbeat can launch it once capacity returns.
sed -i.bak 's/^max_aux_lanes: 4$/max_aux_lanes: 3/' "$LOOM_REPO/.loom.yml"
LOOM_AGENT_CMD="$AGENT" "$TICK" drain-lane-launches >/dev/null
if [ "$(aux_alive)" = 3 ] \
   && [ ! -e "$LOOM_HOME/lanes/gate-226.pid" ] \
   && find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
          -name 'request-*' | grep -q . \
   && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
          -name 'failed-*' | grep -q .; then
    ok "aux cap: a full-cap Codex drain keeps the handoff retryable for a later heartbeat"
else
    bad "aux cap: a full-cap Codex drain launched or destroyed its queued handoff"
fi
sed -i.bak 's/^max_aux_lanes: 3$/max_aux_lanes: 4/' "$LOOM_REPO/.loom.yml"

if LOOM_AGENT_CMD="$AGENT" "$TICK" spawn-lane gate-227 --no-tick \
   --provider codex --job gate --tier medium --brief "$T/aux-brief.md" \
   --cwd "$LOOM_REPO" >/dev/null 2>&1; then
    bad "aux cap: a competing spawn consumed a slot already reserved by a queued Codex handoff"
else
    [ ! -e "$LOOM_HOME/lanes/gate-227.pid" ] \
        && ok "aux cap: a queued Codex handoff reserves its slot without destructive competitor state" \
        || bad "aux cap: refused competitor still wrote lane state"
fi

LOOM_AGENT_CMD="$AGENT" "$TICK" drain-lane-launches >/dev/null
if [ "$(aux_alive)" = 4 ] \
   && [ -s "$LOOM_HOME/lanes/gate-226.pid" ] \
   && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
          \( -name 'request-*' -o -name 'launching-*' \) | grep -q .; then
    ok "aux cap: the durable Codex drain launches the reserved fourth worker without exceeding the cap"
else
    bad "aux cap: Codex drain lost its reservation or exceeded the cap (alive=$(aux_alive))"
fi

for id in 221 222 223 224 225 226 227; do
    "$TICK" kill-lane "gate-$id" >/dev/null 2>&1 || true
done

test_finish
