#!/usr/bin/env bash
# implementation completion hands review directly to one provider-neutral gate
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

git -C "$LOOM_REPO" config user.email loom@test
git -C "$LOOM_REPO" config user.name loom
printf 'implementation\n' > "$LOOM_REPO/product.txt"
git -C "$LOOM_REPO" add .
git -C "$LOOM_REPO" commit -qm seed
git -C "$LOOM_REPO" branch -M loom-236
head=$(git -C "$LOOM_REPO" rev-parse HEAD)

CHAIN_TRACKER="$T/chain-tracker.sh"
cat > "$CHAIN_TRACKER" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  issue)
    printf '%s\n' '{"id":236,"title":"Direct review handoff","state":"open","labels":["review"],"body":"## Risk tier\n\nui\n\n## Acceptance criteria\n\n- [ ] review this exact contract"}' ;;
  issue-notes)
    printf '%s\n' '[
      {"created_at":"2026-08-17T01:02:00Z","body":"Repaired identity fixture ownership at repair123.\n\n<!-- orch-supervised-repair 2026-08-17T01:02:00Z -->"},
      {"created_at":"2026-08-17T01:01:00Z","body":"Active scope owns ShareDialog only; exclude unrelated viewer work.\n\n<!-- orch-scope-reset 2026-08-17T01:01:00Z -->"}
    ]' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$CHAIN_TRACKER"

CHAIN_FORGE="$T/chain-forge.sh"
cat > "$CHAIN_FORGE" <<EOF
#!/usr/bin/env bash
[ "\$1" = mr-for-ticket ] || exit 2
printf '%s\n' '[{"id":17,"state":"open","branch":"loom-236","sha":"$head"}]'
EOF
chmod +x "$CHAIN_FORGE"

CHAIN_AGENT="$T/chain-agent.sh" CHAIN_CALLS="$T/chain-agent.calls"
export CHAIN_CALLS
cat > "$CHAIN_AGENT" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  detect|preflight) exit 0 ;;
  run) printf '%s\n' "$*" >> "$CHAIN_CALLS"; sleep 20 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$CHAIN_AGENT"

TRACKER_CMD="$CHAIN_TRACKER" FORGE_CMD="$CHAIN_FORGE" LOOM_AGENT_CMD="$CHAIN_AGENT" \
  LOOM_LANE_ID=impl-236 "$TICK" chain-gate impl-236 >/dev/null
for _ in $(seq 1 80); do
  [ -s "$LOOM_HOME/lanes/gate-236.pid" ] && [ -s "$CHAIN_CALLS" ] && break
  sleep 0.05
done
gate_pid=$(cat "$LOOM_HOME/lanes/gate-236.pid" 2>/dev/null || true)
if [ -n "$gate_pid" ] && kill -0 "$gate_pid" 2>/dev/null \
   && [ "$(cat "$LOOM_HOME/lanes/gate-236.pregate" 2>/dev/null)" = ui ] \
   && grep -q 'Direct review handoff' "$LOOM_HOME/briefs/gate-236.md" \
   && grep -q 'review this exact contract' "$LOOM_HOME/briefs/gate-236.md" \
   && grep -q 'Active scope owns ShareDialog only' "$LOOM_HOME/briefs/gate-236.md" \
   && grep -q 'Repaired identity fixture ownership at repair123' "$LOOM_HOME/briefs/gate-236.md" \
   && grep -Fq "verdict 236 pass $head --file" "$LOOM_HOME/briefs/gate-236.md" \
   && grep -Fq "verdict 236 fail $head --class" "$LOOM_HOME/briefs/gate-236.md" \
   && grep -q -- '--job gate' "$CHAIN_CALLS"; then
    ok "implementation handoff: live review state starts the configured gate directly"
else
    bad "implementation handoff: chain-gate did not preserve ticket, tier, and provider job"
fi

# The scheduler can race this direct handoff under a different round id. The
# shared ticket@HEAD lock must make a second chain a no-op, not a second paid
# reviewer. Count provider runs at the public adapter seam.
TRACKER_CMD="$CHAIN_TRACKER" FORGE_CMD="$CHAIN_FORGE" LOOM_AGENT_CMD="$CHAIN_AGENT" \
  LOOM_LANE_ID=impl-236 "$TICK" chain-gate impl-236 >/dev/null
sleep 0.2
runs=$(wc -l < "$CHAIN_CALLS" | tr -d ' ')
[ "$runs" = 1 ] \
  && ok "implementation handoff: ticket@HEAD admission suppresses a duplicate gate" \
  || bad "implementation handoff: duplicate chain started $runs provider reviews"

kill "$gate_pid" 2>/dev/null || true
TRACKER_CMD="$CHAIN_TRACKER" "$TICK" clear-lane gate-236 >/dev/null 2>&1 || true

# Codex-authored handoffs use the same command but freeze the gate into the
# durable host queue. The chain must treat that request as success; a later
# drain applies the same admission and brief staging as a scheduler spawn.
TRACKER_CMD="$CHAIN_TRACKER" FORGE_CMD="$CHAIN_FORGE" LOOM_AGENT_CMD="$CHAIN_AGENT" \
  LOOM_LANE_ID=impl-236 LOOM_DEFER_LANE_LAUNCH=1 \
  "$TICK" chain-gate impl-236 >/dev/null
request=$(find "$LOOM_HOME/lane-launch-queue" -maxdepth 1 -type d -name 'request-*' | head -1)
if [ -n "$request" ] \
   && [ "$(cat "$request/id" 2>/dev/null)" = gate-236 ] \
   && [ "$(cat "$request/job" 2>/dev/null)" = gate ] \
   && [ "$(cat "$request/pregate" 2>/dev/null)" = ui ] \
   && grep -q 'review this exact contract' "$request/brief.md" \
   && grep -q 'Active scope owns ShareDialog only' "$request/brief.md" \
   && grep -q 'Repaired identity fixture ownership at repair123' "$request/brief.md" \
   && grep -Fq "verdict 236 pass $head --file" "$request/brief.md" \
   && grep -Fq "verdict 236 fail $head --class" "$request/brief.md" \
   && grep -q 'exactly one tracker verdict' "$request/brief.md" \
   && grep -q 'host epilogue owns `chain-merge`' "$request/brief.md"; then
    ok "implementation handoff: deferred Codex path durably queues the same gate contract"
else
    bad "implementation handoff: deferred path lost its gate metadata or brief"
fi
[ -z "$request" ] || mv "$request" "$LOOM_HOME/lane-launch-queue/consumed-test-request"

# Planted violation: remove only the implementation epilogue's chain-gate
# branch. The same launch plist seam that caught D-TICK-33 must lose the direct
# handoff even though all tracker and provider machinery remains present.
MUT=$(mirror_scripts "$T/mut-chain-gate")
sed -i.bak '/if \[ "$(_lane_type "$id")" = impl \]; then/,/elif \[/ s/chain-gate/chain-no-gate/' \
  "$MUT/tick.sh"
MUT_LAUNCH="$T/mut-launchctl.sh" MUT_ARGS="$T/mut.args"
export MUT_ARGS
cat > "$MUT_LAUNCH" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  bootstrap) plutil -convert json -o - "$3" | jq -r '.ProgramArguments[]' > "$MUT_ARGS" ;;
  print) printf '    pid = 4242\n' ;;
esac
EOF
chmod +x "$MUT_LAUNCH"
LAUNCHCTL_CMD="$MUT_LAUNCH" LOOM_LANE_LAUNCHER=launchd \
  "$MUT/tick.sh" spawn-lane impl-237 -- sleep 1 >/dev/null 2>&1 || true
if ! grep -Eq "chain-gate '?impl-237'?" "$MUT_ARGS"; then
    ok "implementation handoff violation: deleting the host chain recreates scheduler-only review"
else
    bad "implementation handoff violation: planted deletion still exposed a direct gate chain"
fi

test_finish
