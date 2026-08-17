#!/usr/bin/env bash
# UI gate pregates share one host resource without shrinking auxiliary capacity
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

printf '\nmax_aux_lanes: 4\n' >> "$LOOM_REPO/.loom.yml"
git -C "$LOOM_REPO" commit -qm fixture
git init -q --bare "$T/origin.git"
git -C "$LOOM_REPO" remote add origin "$T/origin.git"
git -C "$LOOM_REPO" push -q origin HEAD:main

lane_alive() { # <lane-id>
    local pid
    pid=$(cat "$LOOM_HOME/lanes/$1.pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# The public spawn seam admits one UI gate. A direct implementation handoff
# for a second UI gate must fail soft so the finishing implementation is not
# repainted as failed, while unrelated auxiliary work keeps all of its normal
# parallelism.
"$TICK" spawn-lane gate-350 --no-tick --pregate ui --cwd "$LOOM_REPO" -- sleep 30 >/dev/null
out=$(LOOM_LANE_ID=impl-351 "$TICK" spawn-lane gate-351 --no-tick \
  --pregate ui --cwd "$LOOM_REPO" -- sleep 30 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && lane_alive gate-350 && ! lane_alive gate-351 \
   && printf '%s' "$out" | grep -q 'UI pregate'; then
    ok "ui gate admission: a direct handoff waits without starting a second UI gate"
else
    bad "ui gate admission: direct handoff admitted concurrent UI pregates (rc=$rc; out=$out)"
fi

out=$(LOOM_LANE_ID=gate-350 "$TICK" spawn-lane merge-349 --no-tick \
  --pregate ui --merge-lock --cwd "$LOOM_REPO" -- sleep 30 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && lane_alive gate-350 && ! lane_alive merge-349 \
   && printf '%s' "$out" | grep -q 'UI pregate'; then
    ok "ui pregate admission: a merge preflight waits behind a live UI gate"
else
    bad "ui pregate admission: a UI merge overlapped a UI gate (rc=$rc; out=$out)"
fi

"$TICK" spawn-lane gate-352 --no-tick --pregate api --cwd "$LOOM_REPO" -- sleep 30 >/dev/null
"$TICK" spawn-lane merge-353 --no-tick --pregate api --merge-lock \
  --cwd "$LOOM_REPO" -- sleep 30 >/dev/null
"$TICK" spawn-lane probe-ui-admission --no-tick --pregate api \
  --cwd "$LOOM_REPO" -- sleep 30 >/dev/null
if lane_alive gate-350 && lane_alive gate-352 && lane_alive merge-353 \
   && lane_alive probe-ui-admission; then
    ok "ui gate admission: API gates, merges, probes, and auxiliary parallelism remain independent"
else
    bad "ui gate admission: resource-specific admission suppressed unrelated auxiliary work"
fi

live_ui_metadata=$(cat "$LOOM_HOME/lanes/gate-350.pregate" 2>/dev/null || true)
for id in gate-350 gate-351 gate-352 merge-349 merge-353 probe-ui-admission; do
    "$TICK" kill-lane "$id" >/dev/null 2>&1 || true
done
if [ "$live_ui_metadata" = ui ] && [ ! -e "$LOOM_HOME/lanes/gate-350.pregate" ]; then
    ok "ui gate admission: clearing a live lane retires its resource metadata"
else
    bad "ui gate admission: clear-lane left stale UI ownership metadata"
fi

# The reservation is about the pregate, not the review lane kind. A merge can
# own it in the other direction and hold a gate until its UI preflight and
# merge worker are finished.
"$TICK" spawn-lane merge-356 --no-tick --pregate ui --merge-lock \
  --cwd "$LOOM_REPO" -- sleep 30 >/dev/null
out=$(LOOM_LANE_ID=impl-357 "$TICK" spawn-lane gate-357 --no-tick \
  --pregate ui --cwd "$LOOM_REPO" -- sleep 30 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && lane_alive merge-356 && ! lane_alive gate-357 \
   && [ "$(cat "$LOOM_HOME/lanes/merge-356.pregate" 2>/dev/null)" = ui ] \
   && printf '%s' "$out" | grep -q 'UI pregate'; then
    ok "ui pregate admission: a live UI merge reserves the resource from gates"
else
    bad "ui pregate admission: merge ownership was not shared across lane kinds (rc=$rc; out=$out)"
fi
"$TICK" kill-lane merge-356 >/dev/null 2>&1 || true
"$TICK" kill-lane gate-357 >/dev/null 2>&1 || true

# Two implementations can finish on the same scheduler beat. The existing
# auxiliary-admission lock must make the resource decision atomic even with
# spare general capacity: exactly one handoff may become live.
LOOM_LANE_ID=impl-354 "$TICK" spawn-lane gate-354 --no-tick --pregate ui \
  --cwd "$LOOM_REPO" -- sleep 30 >/dev/null 2>&1 &
p354=$!
LOOM_LANE_ID=impl-355 "$TICK" spawn-lane gate-355 --no-tick --pregate ui \
  --cwd "$LOOM_REPO" -- sleep 30 >/dev/null 2>&1 &
p355=$!
wait "$p354"; wait "$p355"
ui_live=0
lane_alive gate-354 && ui_live=$((ui_live + 1))
lane_alive gate-355 && ui_live=$((ui_live + 1))
if [ "$ui_live" -eq 1 ]; then
    ok "ui gate admission: simultaneous handoffs atomically admit one UI gate"
else
    bad "ui gate admission: simultaneous handoffs admitted $ui_live UI gates"
fi
"$TICK" kill-lane gate-354 >/dev/null 2>&1 || true
"$TICK" kill-lane gate-355 >/dev/null 2>&1 || true

AGENT="$T/ui-agent.sh"
TRACKER="$T/ui-tracker.sh"
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
printf 'queued UI gate brief\n' > "$T/ui-brief.md"

# A Codex handoff reserves the UI resource without launching a paid worker.
# The same public seam must refuse a direct competitor while that durable
# request waits for its host.
LOOM_LANE_ID=impl-360 LOOM_DEFER_LANE_LAUNCH=1 LOOM_AGENT_CMD="$AGENT" \
  "$TICK" spawn-lane gate-360 --no-tick --pregate ui --provider codex \
  --job gate --tier medium --brief "$T/ui-brief.md" --cwd "$LOOM_REPO" >/dev/null
rc=0
out=$("$TICK" spawn-lane gate-361 --no-tick --pregate ui \
  --cwd "$LOOM_REPO" -- sleep 30 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && ! lane_alive gate-361 \
   && find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
        -name 'request-*' | grep -q .; then
    ok "ui gate admission: a durable queued handoff reserves the public UI gate seam"
else
    bad "ui gate admission: direct spawn bypassed a queued UI reservation (rc=$rc; out=$out)"
fi
"$TICK" kill-lane gate-361 >/dev/null 2>&1 || true

# Planted violation: model a UI gate started by an older launcher after the
# request was queued. The durable drain must return the request to request-*
# (private rc 75) rather than destroy it or start a second paid worker.
printf '%s\n' "$$" > "$LOOM_HOME/lanes/gate-399.pid"
printf 'ui\n' > "$LOOM_HOME/lanes/gate-399.pregate"
LOOM_AGENT_CMD="$AGENT" "$TICK" drain-lane-launches >/dev/null
if ! lane_alive gate-360 \
   && find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
        -name 'request-*' | grep -q . \
   && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
        -name 'failed-*' | grep -q .; then
    ok "ui gate admission: a contended durable drain retains its request for retry"
else
    bad "ui gate admission: a contended drain launched or destroyed the queued UI gate"
fi

rm -f "$LOOM_HOME/lanes/gate-399.pid" "$LOOM_HOME/lanes/gate-399.pregate"
LOOM_AGENT_CMD="$AGENT" "$TICK" drain-lane-launches >/dev/null
if lane_alive gate-360 \
   && [ "$(cat "$LOOM_HOME/lanes/gate-360.pregate" 2>/dev/null)" = ui ] \
   && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
        \( -name 'request-*' -o -name 'launching-*' \) | grep -q .; then
    ok "ui gate admission: the next durable heartbeat launches the UI gate after release"
else
    bad "ui gate admission: a released UI resource did not admit its queued worker"
fi
"$TICK" kill-lane gate-360 >/dev/null 2>&1 || true

test_finish
