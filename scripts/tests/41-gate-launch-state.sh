#!/usr/bin/env bash
# delayed gate launches revalidate the ticket state at the spawn boundary
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

STATE_FILE="$T/gate-state"
TRACKER="$T/gate-tracker.sh"
AGENT="$T/gate-agent.sh"
AGENT_CALLS="$T/gate-agent.calls"
TRACKER_CALLS="$T/gate-tracker.calls"
STALE_NOTE="$T/gate-stale-note.md"
export STATE_FILE AGENT_CALLS TRACKER_CALLS STALE_NOTE TRACKER_CMD="$TRACKER" LOOM_AGENT_CMD="$AGENT"

cat > "$TRACKER" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TRACKER_CALLS"
case "$1" in
  note-add) cp "$3" "$STALE_NOTE" ;;
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
LOOM_LANE_ID=impl-333 "$TICK" spawn-lane gate-333 --no-tick --pregate logic \
  --provider claude --job gate --tier medium --brief "$T/gate-brief.md" \
  --cwd "$LOOM_REPO" >/dev/null 2>&1
if grep -q 'The host runs the configured logic pregate before this review session' \
     "$LOOM_HOME/briefs/gate-333.md" \
   && grep -q 'Do not rerun that full tier' "$LOOM_HOME/briefs/gate-333.md"; then
    ok "gate brief: automatic pregate evidence prevents a duplicate full-tier reviewer run"
else
    bad "gate brief: reviewer can repeat the host-owned pregate and double auxiliary occupancy"
fi
if [ -s "$LOOM_HOME/lanes/gate-333.pid" ]; then
    ok "gate-launch-violation: returning to review admits the direct handoff"
else
    bad "gate-launch-violation: review state did not reach the provider launch"
fi

"$TICK" kill-lane gate-333 >/dev/null 2>&1 || true

# A review branch can age while it waits behind the auxiliary cap. Patient
# Imaging JOR-208 reached its UI gate 42 base commits behind: the pregate ran
# an obsolete hard-coded-port test, then hung after a stale test fixture held
# a request forever. Base drift is neither a ticket rejection nor a reason to
# spend the full suite/reviewer. The lane-side write boundary moves it back to
# implementation so the ordinary planner can assign reconciliation.
git -C "$LOOM_REPO" config user.email loom@test
git -C "$LOOM_REPO" config user.name loom
mkdir -p "$LOOM_REPO/scripts"
cat > "$LOOM_REPO/scripts/gate.sh" <<'EOF'
#!/usr/bin/env bash
touch "$STALE_RUNNER"
EOF
chmod +x "$LOOM_REPO/scripts/gate.sh"
git -C "$LOOM_REPO" add .
git -C "$LOOM_REPO" commit -qm base-one
git -C "$LOOM_REPO" branch -M main
git init -q --bare "$T/gate-origin.git"
git -C "$LOOM_REPO" remote add origin "$T/gate-origin.git"
git -C "$LOOM_REPO" push -qu origin main
git -C "$LOOM_REPO" checkout -qb ticket-334
printf 'ticket\n' > "$LOOM_REPO/ticket.txt"
git -C "$LOOM_REPO" add ticket.txt
git -C "$LOOM_REPO" commit -qm ticket
git -C "$LOOM_REPO" push -qu origin ticket-334
git -C "$LOOM_REPO" checkout -q main
printf 'base two\n' > "$LOOM_REPO/base-two.txt"
git -C "$LOOM_REPO" add base-two.txt
git -C "$LOOM_REPO" commit -qm base-two
git -C "$LOOM_REPO" push -qu origin main
git -C "$LOOM_REPO" checkout -q ticket-334

STALE_RUNNER="$T/stale-runner-ran"
export STALE_RUNNER
rm -f "$STALE_RUNNER" "$AGENT_CALLS" "$TRACKER_CALLS"
printf 'review\n' > "$STATE_FILE"
"$TICK" spawn-lane gate-334 --no-tick --pregate logic --provider claude \
  --job gate --tier medium --brief "$T/gate-brief.md" --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 60); do
    [ -f "$LOOM_HOME/lanes/gate-334.rc" ] || [ -f "$STALE_RUNNER" ] || sleep 0.1
done
if [ "$(cat "$LOOM_HOME/lanes/gate-334.rc" 2>/dev/null)" = 0 ] \
   && [ "$(cat "$LOOM_HOME/lanes/gate-334.outcome" 2>/dev/null)" = in-progress ] \
   && [ ! -e "$STALE_RUNNER" ] \
   && ! grep -q '^run ' "$AGENT_CALLS" 2>/dev/null \
   && grep -q '^note-add 334 ' "$TRACKER_CALLS" 2>/dev/null \
   && grep -q '<!-- orch-base-stale [0-9a-f].* base=main behind=1 -->' "$STALE_NOTE" 2>/dev/null \
   && grep -q '^issue-relabel 334 .*--add in-progress' "$TRACKER_CALLS" 2>/dev/null \
   && grep -q 'behind origin/main' "$LOOM_HOME/logs/lane-gate-334.log" 2>/dev/null; then
    ok "gate base: stale review returns to implementation with a head-bound tracker decision"
else
    bad "gate base: a 42-commit-stale branch reached pregate/reviewer or left no durable rework decision"
fi
"$TICK" kill-lane gate-334 >/dev/null 2>&1 || true

# Countercondition: once origin/main is an ancestor, the same provider-neutral
# path reaches both the configured pregate and the provider session.
git -C "$LOOM_REPO" merge -q --no-edit origin/main
rm -f "$STALE_RUNNER" "$AGENT_CALLS" "$TRACKER_CALLS"
printf 'review\n' > "$STATE_FILE"
"$TICK" spawn-lane gate-335 --no-tick --pregate logic --provider claude \
  --job gate --tier medium --brief "$T/gate-brief.md" --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 60); do
    [ -f "$STALE_RUNNER" ] && grep -q '^run ' "$AGENT_CALLS" 2>/dev/null && break
    sleep 0.1
done
if [ -f "$STALE_RUNNER" ] && grep -q '^run ' "$AGENT_CALLS" 2>/dev/null; then
    ok "gate-base-violation: a reconciled branch still reaches pregate and review"
else
    bad "gate base: the freshness guard suppressed a current branch"
fi
base_sha=$(git -C "$LOOM_REPO" rev-parse origin/main)
head_sha=$(git -C "$LOOM_REPO" rev-parse HEAD)
if grep -Fq "canonical review base is \`origin/main\` at \`$base_sha\`" "$LOOM_HOME/briefs/gate-335.md" \
   && grep -Fq "\`$base_sha...$head_sha\`" "$LOOM_HOME/briefs/gate-335.md" \
   && grep -Fq 'Never compare against a local base branch' "$LOOM_HOME/briefs/gate-335.md"; then
    ok "gate review base: staged brief pins the canonical remote base and immutable diff range"
else
    bad "gate review base: reviewer can compare against a stale local main and invent scope creep"
fi
"$TICK" kill-lane gate-335 >/dev/null 2>&1 || true

# Planted violation: delete only launch-time canonical-base capture while
# leaving the existing stale-base preflight intact. The provider still starts,
# but its staged brief again has no immutable comparison range — exactly the
# seam that let JOR-289 compare against a stale local main.
BASE_MIRROR=$(mirror_scripts "$T/gate-base-review-mutant")
sed '/# D-TICK-38:/,/^    fi$/d' "$BASE_MIRROR/tick.sh" > "$BASE_MIRROR/tick-mutant.sh"
chmod +x "$BASE_MIRROR/tick-mutant.sh"
rm -f "$AGENT_CALLS"
printf 'review\n' > "$STATE_FILE"
out=$("$BASE_MIRROR/tick-mutant.sh" spawn-lane gate-336 --no-tick --pregate logic \
  --provider claude --job gate --tier medium --brief "$T/gate-brief.md" \
  --cwd "$LOOM_REPO" 2>&1); rc=$?
out="$out
mutant-ran rc=$rc"
for _ in $(seq 1 60); do
    [ -s "$LOOM_HOME/lanes/gate-336.pid" ] && grep -q '^run ' "$AGENT_CALLS" 2>/dev/null && break
    sleep 0.1
done
pid=$(cat "$LOOM_HOME/lanes/gate-336.pid" 2>/dev/null || echo "")
if assert_mutant_ran "$rc" "$out" "gate review base mutant" \
   && [ -n "$pid" ] && grep -q '^run ' "$AGENT_CALLS" 2>/dev/null \
   && ! grep -Fq 'canonical review base' "$LOOM_HOME/briefs/gate-336.md"; then
    ok "gate-review-base-violation: deleting canonical capture recreates an unpinned reviewer"
else
    bad "gate-review-base-violation: planted capture deletion did not recreate the missing base contract"
fi
"$TICK" kill-lane gate-336 >/dev/null 2>&1 || true

# Planted violation: retain the production call site but make its write-side
# base check always claim current. The stale branch must again burn both the
# runner and the provider, proving the holding assertion is about this guard.
git -C "$LOOM_REPO" checkout -q ticket-334
MIRROR=$(mirror_scripts "$T/stale-mirror")
sed '/^cmd_gate_base_check()/,/^}/c\
cmd_gate_base_check() { return 0; }' "$MIRROR/lane.sh" > "$MIRROR/lane-mutant.sh"
mv "$MIRROR/lane-mutant.sh" "$MIRROR/lane.sh"
chmod +x "$MIRROR/lane.sh"
rm -f "$STALE_RUNNER" "$AGENT_CALLS" "$TRACKER_CALLS"
printf 'review\n' > "$STATE_FILE"
"$MIRROR/tick.sh" spawn-lane gate-336 --no-tick --pregate logic --provider claude \
  --job gate --tier medium --brief "$T/gate-brief.md" --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 60); do
    [ -f "$STALE_RUNNER" ] && grep -q '^run ' "$AGENT_CALLS" 2>/dev/null && break
    sleep 0.1
done
if [ -f "$STALE_RUNNER" ] && grep -q '^run ' "$AGENT_CALLS" 2>/dev/null; then
    ok "gate-base-violation: bypassing the stale-base decision recreates paid work on an obsolete branch"
else
    bad "gate-base-violation: planted bypass did not recreate the stale-branch spend"
fi
"$MIRROR/tick.sh" kill-lane gate-336 >/dev/null 2>&1 || true
test_finish
