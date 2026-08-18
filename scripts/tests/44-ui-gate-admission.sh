#!/usr/bin/env bash
# UI gate pregates share one host resource without shrinking auxiliary capacity
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

printf '\nmax_aux_lanes: 4\n' >> "$LOOM_REPO/.loom.yml"
UI_RUNNER="$T/ui-pregate-runner.sh"
UI_RELEASE="$T/ui-pregate-release"
UI_STARTED="$T/ui-pregate-started"
cat > "$UI_RUNNER" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = ui ] && [ ! -f "$UI_RELEASE" ]; then
  : > "$UI_STARTED"
  while [ ! -f "$UI_RELEASE" ]; do sleep 0.05; done
fi
exit 0
EOF
chmod +x "$UI_RUNNER"
printf 'runner: %s\n' "$UI_RUNNER" >> "$LOOM_REPO/.loom.yml"
git -C "$LOOM_REPO" commit -qm fixture
git init -q --bare "$T/origin.git"
git -C "$LOOM_REPO" remote add origin "$T/origin.git"
git -C "$LOOM_REPO" push -q origin HEAD:main

lane_alive() { # <lane-id>
    local pid
    pid=$(cat "$LOOM_HOME/lanes/$1.pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
HOST_ADMISSION_HOME="$LOOM_HOST_ADMISSION_HOME"
DRIVER="$(dirname "$TICK")/tick-test.sh"

# Runtime self-validation is heavyweight host work too. Its exclusive claim
# must hold only UI work: focused/API gates remain free to run while release
# validation owns the browser-class resource.
mkdir -p "$HOST_ADMISSION_HOME/heavy-host-maintenance.d"
printf '%s\n' "$$" > "$HOST_ADMISSION_HOME/heavy-host-maintenance.d/pid"
rc=0
out=$("$TICK" spawn-lane gate-348 --no-tick --pregate ui \
  --cwd "$LOOM_REPO" -- sleep 30 2>&1) || rc=$?
"$TICK" spawn-lane gate-349 --no-tick --pregate api \
  --cwd "$LOOM_REPO" -- sleep 30 >/dev/null
if [ "$rc" -ne 0 ] && ! lane_alive gate-348 && lane_alive gate-349 \
   && printf '%s' "$out" | grep -q 'runtime validation'; then
    ok "host admission: runtime validation defers UI work but not focused API gates"
else
    bad "host admission: maintenance claim did not isolate only heavyweight UI work (rc=$rc; out=$out)"
fi
"$TICK" kill-lane gate-349 >/dev/null 2>&1 || true
"$TICK" kill-lane gate-348 >/dev/null 2>&1 || true
rm -f "$HOST_ADMISSION_HOME/heavy-host-maintenance.d/pid"
rmdir "$HOST_ADMISSION_HOME/heavy-host-maintenance.d"

ln -s missing "$HOST_ADMISSION_HOME/heavy-host-maintenance.d"
rc=0
out=$("$TICK" spawn-lane gate-347 --no-tick --pregate ui \
  --cwd "$LOOM_REPO" -- sleep 30 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && ! lane_alive gate-347 \
   && printf '%s' "$out" | grep -q 'admission state is unreadable'; then
    ok "host admission: unreadable maintenance ownership fails product UI admission visibly"
else
    bad "host admission: malformed maintenance ownership looked idle (rc=$rc; out=$out)"
fi
rm -f "$HOST_ADMISSION_HOME/heavy-host-maintenance.d"

# The active marker and its PID are one host-admission transition. Pause the
# public process launcher after metadata is written but before the child can
# stamp ownership: a direct full suite must wait, not inspect the partial pair
# and reject a valid product spawn as unreadable.
RACE_BIN="$T/pid-race-bin"
RACE_PAUSED="$T/pid-race-paused"
RACE_GO="$T/pid-race-go"
RACE_SUITE_ATTEMPTS="$T/pid-race-suite-attempts"
RACE_SPAWN_OUT="$T/pid-race-spawn.out"
RACE_SUITE_OUT="$T/pid-race-suite.out"
RACE_TESTS="$T/pid-race-tests"
mkdir -p "$RACE_BIN" "$RACE_TESTS"
cat > "$RACE_BIN/nohup" <<'EOF'
#!/bin/sh
: > "${RACE_PAUSED:?}"
while [ ! -f "${RACE_GO:?}" ]; do sleep 0.01; done
exec /usr/bin/nohup "$@"
EOF
cat > "$RACE_BIN/ln" <<'EOF'
#!/bin/sh
/bin/ln "$@"; rc=$?
[ -z "${RACE_SUITE_ATTEMPTS:-}" ] || printf 'attempt\n' >> "$RACE_SUITE_ATTEMPTS"
exit "$rc"
EOF
cat > "$RACE_TESTS/01-ok.sh" <<'EOF'
#!/usr/bin/env bash
printf '1 0\n' > "${LOOM_TEST_COUNTS:?}"
EOF
chmod +x "$RACE_BIN/nohup" "$RACE_BIN/ln" "$RACE_TESTS/01-ok.sh"
rm -f "$RACE_PAUSED" "$RACE_GO" "$RACE_SPAWN_OUT" "$RACE_SUITE_OUT" \
      "$RACE_SUITE_ATTEMPTS" "$UI_RELEASE" "$UI_STARTED"
: > "$RACE_SUITE_ATTEMPTS"
RACE_PAUSED="$RACE_PAUSED" RACE_GO="$RACE_GO" PATH="$RACE_BIN:$PATH" \
  "$TICK" spawn-lane gate-346 --no-tick --pregate ui \
  --cwd "$LOOM_REPO" -- sleep 30 >"$RACE_SPAWN_OUT" 2>&1 & race_spawn_pid=$!
for _wait in $(seq 1 100); do [ -f "$RACE_PAUSED" ] && break; sleep 0.02; done
RACE_SUITE_ATTEMPTS="$RACE_SUITE_ATTEMPTS" PATH="$RACE_BIN:$PATH" \
  LOOM_HOST_ADMISSION_HOME="$HOST_ADMISSION_HOME" LOOM_TEST_DIR="$RACE_TESTS" \
  bash "$DRIVER" >"$RACE_SUITE_OUT" 2>&1 & race_suite_pid=$!
for _wait in $(seq 1 100); do
    [ "$(wc -l < "$RACE_SUITE_ATTEMPTS" 2>/dev/null | tr -d ' ')" -ge 2 ] 2>/dev/null && break
    kill -0 "$race_suite_pid" 2>/dev/null || break
    sleep 0.02
done
race_waited=0
kill -0 "$race_suite_pid" 2>/dev/null \
  && [ "$(wc -l < "$RACE_SUITE_ATTEMPTS" 2>/dev/null | tr -d ' ')" -ge 2 ] 2>/dev/null \
  && [ -f "$LOOM_HOME/lanes/gate-346.ui-resource" ] \
  && [ ! -e "$LOOM_HOME/lanes/gate-346.pid" ] \
  && race_waited=1
: > "$RACE_GO"
wait "$race_spawn_pid"; race_spawn_rc=$?
for _wait in $(seq 1 100); do
    grep -q 'deferring full suite' "$RACE_SUITE_OUT" 2>/dev/null && break
    sleep 0.02
done
race_deferred=0
kill -0 "$race_suite_pid" 2>/dev/null && lane_alive gate-346 \
  && grep -q 'deferring full suite' "$RACE_SUITE_OUT" 2>/dev/null \
  && race_deferred=1
"$TICK" kill-lane gate-346 >/dev/null 2>&1 || true
wait "$race_suite_pid"; race_suite_rc=$?
if [ "$race_waited" -eq 1 ] && [ "$race_spawn_rc" -eq 0 ] \
   && [ "$race_deferred" -eq 1 ] && [ "$race_suite_rc" -eq 0 ] \
   && ! grep -q 'unreadable' "$RACE_SUITE_OUT"; then
    ok "host admission: maintenance waits across UI marker and PID publication"
else
    bad "host admission: maintenance observed partial UI ownership (waited=$race_waited spawn=$race_spawn_rc deferred=$race_deferred suite=$race_suite_rc; $(cat "$RACE_SUITE_OUT"))"
fi

# The public spawn seam admits one UI gate. A direct implementation handoff
# for a second UI gate must fail soft so the finishing implementation is not
# repainted as failed, while unrelated auxiliary work keeps all of its normal
# parallelism.
rm -f "$UI_RELEASE" "$UI_STARTED"
"$TICK" spawn-lane gate-350 --no-tick --pregate ui --cwd "$LOOM_REPO" -- sleep 30 >/dev/null
for _wait in $(seq 1 100); do [ -f "$UI_STARTED" ] && break; sleep 0.02; done
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

live_ui_metadata=$(cat "$LOOM_HOME/lanes/gate-350.ui-resource" 2>/dev/null || true)
for id in gate-350 gate-351 gate-352 merge-349 merge-353 probe-ui-admission; do
    "$TICK" kill-lane "$id" >/dev/null 2>&1 || true
done
if [ "$live_ui_metadata" = ui ] \
   && [ ! -e "$LOOM_HOME/lanes/gate-350.pregate" ] \
   && [ ! -e "$LOOM_HOME/lanes/gate-350.ui-resource" ]; then
    ok "ui gate admission: clearing a live lane retires its resource metadata"
else
    bad "ui gate admission: clear-lane left stale UI ownership metadata"
fi

# The reservation is about the pregate, not the review lane kind. A merge can
# own it in the other direction and hold a gate while its UI preflight runs.
rm -f "$UI_RELEASE" "$UI_STARTED"
"$TICK" spawn-lane merge-356 --no-tick --pregate ui --merge-lock \
  --cwd "$LOOM_REPO" -- sleep 30 >/dev/null
for _wait in $(seq 1 100); do [ -f "$UI_STARTED" ] && break; sleep 0.02; done
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
rm -f "$UI_RELEASE" "$UI_STARTED"
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
printf 'ui\n' > "$LOOM_HOME/lanes/gate-399.ui-resource"
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

rm -f "$LOOM_HOME/lanes/gate-399.pid" "$LOOM_HOME/lanes/gate-399.ui-resource"
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

# Once the mechanical UI pregate finishes, provider review no longer owns a
# browser or fixture. The scarce resource must be released while that review
# lane stays alive, so the next ticket can run its own serialized pregate.
touch "$UI_RELEASE"
FIRST_PROVIDER_STARTED="$T/ui-first-provider-started"
rm -f "$FIRST_PROVIDER_STARTED"
"$TICK" spawn-lane gate-370 --no-tick --pregate ui --cwd "$LOOM_REPO" -- \
  sh -c "touch '$FIRST_PROVIDER_STARTED'; sleep 30" >/dev/null
for _wait in $(seq 1 100); do [ -f "$FIRST_PROVIDER_STARTED" ] && break; sleep 0.02; done
rc=0
out=$("$TICK" spawn-lane gate-371 --no-tick --pregate ui --cwd "$LOOM_REPO" -- sleep 30 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && lane_alive gate-370 && lane_alive gate-371 \
   && [ "$(cat "$LOOM_HOME/lanes/gate-370.pregate" 2>/dev/null)" = ui ]; then
    ok "ui gate admission: completed pregate releases the browser resource before review ends"
else
    bad "ui gate admission: provider review retained the browser resource (rc=$rc; out=$out)"
fi
"$TICK" kill-lane gate-370 >/dev/null 2>&1 || true
"$TICK" kill-lane gate-371 >/dev/null 2>&1 || true

# Planted violation: keep the active-browser marker after the host pregate
# returns. The first provider is still alive, so the public admission seam must
# recreate the old false serialization and refuse the second UI gate.
UI_MUT=$(mirror_scripts "$T/ui-release-mutant")
sed 's/    rm -f "$metadata"/    : # mutate: retain completed UI resource/' \
  "$UI_MUT/tick.sh" > "$UI_MUT/tick-mutant.sh"
mv "$UI_MUT/tick-mutant.sh" "$UI_MUT/tick.sh"
chmod +x "$UI_MUT/tick.sh"
UI_MUT_HOME="$T/ui-release-mutant-home"
MUT_PROVIDER_STARTED="$T/ui-mutant-provider-started"
rm -rf "$UI_MUT_HOME"; mkdir -p "$UI_MUT_HOME"
rm -f "$MUT_PROVIDER_STARTED"
LOOM_HOME="$UI_MUT_HOME" "$UI_MUT/tick.sh" spawn-lane gate-380 --no-tick \
  --pregate ui --cwd "$LOOM_REPO" -- \
  sh -c "touch '$MUT_PROVIDER_STARTED'; sleep 30" >/dev/null
for _wait in $(seq 1 100); do [ -f "$MUT_PROVIDER_STARTED" ] && break; sleep 0.02; done
mut_rc=0
mut_out=$(LOOM_HOME="$UI_MUT_HOME" "$UI_MUT/tick.sh" spawn-lane gate-381 \
  --no-tick --pregate ui --cwd "$LOOM_REPO" -- sleep 30 2>&1) || mut_rc=$?
if [ "$mut_rc" -ne 0 ] && ! LOOM_HOME="$UI_MUT_HOME" lane_alive gate-381 \
   && printf '%s' "$mut_out" | grep -q 'UI pregate'; then
    ok "ui-release-violation: retaining the marker recreates review-time browser serialization"
else
    bad "ui-release-violation: planted marker retention did not block the second UI gate (rc=$mut_rc; out=$mut_out)"
fi
LOOM_HOME="$UI_MUT_HOME" "$UI_MUT/tick.sh" kill-lane gate-380 >/dev/null 2>&1 || true
LOOM_HOME="$UI_MUT_HOME" "$UI_MUT/tick.sh" kill-lane gate-381 >/dev/null 2>&1 || true

test_finish
