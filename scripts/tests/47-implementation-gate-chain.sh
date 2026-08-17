#!/usr/bin/env bash
# implementation completion hands review directly to one provider-neutral gate
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

git -C "$LOOM_REPO" config user.email loom@test
git -C "$LOOM_REPO" config user.name loom
printf 'implementation\n' > "$LOOM_REPO/product.txt"
mkdir -p "$LOOM_REPO/scripts"
printf '#!/bin/sh\nexit 0\n' > "$LOOM_REPO/scripts/gate.sh"
chmod +x "$LOOM_REPO/scripts/gate.sh"
git -C "$LOOM_REPO" add .
git -C "$LOOM_REPO" commit -qm seed
git -C "$LOOM_REPO" branch -M loom-236
head=$(git -C "$LOOM_REPO" rev-parse HEAD)

CHAIN_TRACKER="$T/chain-tracker.sh"
CHAIN_BUILD_JSON="$T/chain-build.json"
export CHAIN_BUILD_JSON
printf '%s\n' '[{"id":9,"title":"Build 9","state":"open","labels":["provider::claude"]}]' > "$CHAIN_BUILD_JSON"
cat > "$CHAIN_TRACKER" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  issues-open)
    cat "$CHAIN_BUILD_JSON" ;;
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
  detect) [ "${3:-}" = claude ] ;;
  preflight) exit 0 ;;
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

# A manually resumed deterministic handoff starts at the public verb without
# an epilogue environment. It must recover the one canonical Build provider
# and preserve it in the durable request instead of passing an empty provider
# to spawn-lane.
TRACKER_CMD="$CHAIN_TRACKER" FORGE_CMD="$CHAIN_FORGE" LOOM_AGENT_CMD="$CHAIN_AGENT" \
  LOOM_PROVIDER= LOOM_SKIP_PROVIDER_CHECK= LOOM_DEFER_LANE_LAUNCH=1 \
  "$TICK" chain-gate impl-236 >/dev/null 2>&1 || true
manual_request=$(find "$LOOM_HOME/lane-launch-queue" -maxdepth 1 -type d -name 'request-*' | head -1)
if [ -n "$manual_request" ] \
   && [ "$(cat "$manual_request/id" 2>/dev/null)" = gate-236 ] \
   && [ "$(cat "$manual_request/provider" 2>/dev/null)" = claude ]; then
    ok "implementation handoff: manual resume recovers the canonical Build provider"
else
    bad "implementation handoff: manual resume lost the canonical Build provider"
fi
[ -z "$manual_request" ] || mv "$manual_request" "$LOOM_HOME/lane-launch-queue/consumed-manual-request"

# Canonical recovery is deliberately strict. Ambiguous state and a provider
# without a registered adapter must both fail before creating a durable lane
# request; guessing either value can silently move a Build onto another biller.
provider_refusals=0
for labels in '["provider::claude","provider::codex"]' '["provider::future"]'; do
  printf '[{"id":9,"title":"Build 9","state":"open","labels":%s}]\n' "$labels" > "$CHAIN_BUILD_JSON"
  if TRACKER_CMD="$CHAIN_TRACKER" FORGE_CMD="$CHAIN_FORGE" LOOM_AGENT_CMD="$CHAIN_AGENT" \
      LOOM_PROVIDER= LOOM_SKIP_PROVIDER_CHECK= LOOM_DEFER_LANE_LAUNCH=1 \
      "$TICK" chain-gate impl-236 >"$T/provider-refusal.out" 2>&1; then
    :
  else
    provider_refusals=$((provider_refusals + 1))
  fi
done
leftover_request=$(find "$LOOM_HOME/lane-launch-queue" -maxdepth 1 -type d -name 'request-*' | head -1)
if [ "$provider_refusals" = 2 ] && [ -z "$leftover_request" ]; then
    ok "implementation handoff: ambiguous and unregistered Build providers are refused before spawn"
else
    bad "implementation handoff: invalid canonical provider reached spawn (refused=$provider_refusals request=${leftover_request:-none})"
fi
printf '%s\n' '[{"id":9,"title":"Build 9","state":"open","labels":["provider::claude"]}]' > "$CHAIN_BUILD_JSON"

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

# D-TICK-43: direct implementation handoff is a fast path around plan.jq, so
# it must derive the same minimum host gate from the frozen live contract. An
# API implementation whose acceptance explicitly names Playwright still queues
# a UI pregate; otherwise the reviewer is forced to try Chromium in its sandbox.
CHAIN_BROWSER_TRACKER="$T/chain-browser-tracker.sh"
cat > "$CHAIN_BROWSER_TRACKER" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  issues-open) printf '%s\n' '[{"id":9,"title":"Build 9","state":"open","labels":["provider::claude"]}]' ;;
  issue)
    printf '%s\n' '{"id":238,"title":"API wiring with browser acceptance","state":"open","labels":["review"],"body":"## Risk tier\n\napi\n\n## Acceptance criteria\n\n- [ ] `npx playwright test e2e/e2-wiring.spec.ts --project=e2-wiring` passes"}' ;;
  issue-notes) printf '%s\n' '[]' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$CHAIN_BROWSER_TRACKER"
TRACKER_CMD="$CHAIN_BROWSER_TRACKER" FORGE_CMD="$CHAIN_FORGE" LOOM_AGENT_CMD="$CHAIN_AGENT" \
  LOOM_LANE_ID=impl-238 LOOM_DEFER_LANE_LAUNCH=1 \
  "$TICK" chain-gate impl-238 >/dev/null
browser_request=$(find "$LOOM_HOME/lane-launch-queue" -maxdepth 1 -type d -name 'request-*' | head -1)
if [ -n "$browser_request" ] \
   && [ "$(cat "$browser_request/id" 2>/dev/null)" = gate-238 ] \
   && [ "$(cat "$browser_request/pregate" 2>/dev/null)" = ui ]; then
    ok "D-TICK-43: direct gate chain promotes mandatory Playwright evidence to the host UI pregate"
else
    bad "D-TICK-43: direct gate chain left mandatory browser evidence below UI"
fi
[ -z "$browser_request" ] || mv "$browser_request" "$LOOM_HOME/lane-launch-queue/consumed-browser-request"

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

# Planted D-TICK-35 violation: delete only canonical recovery from a private
# copy. The public manual verb must again reach spawn-lane with no provider.
MUT_PROVIDER=$(mirror_scripts "$T/mut-handoff-provider")
sed -i.bak '/provider=$(\_canonical_build_provider)/s/.*/        provider="${LOOM_PROVIDER:-}"/' \
  "$MUT_PROVIDER/tick.sh"
if TRACKER_CMD="$CHAIN_TRACKER" FORGE_CMD="$CHAIN_FORGE" LOOM_AGENT_CMD="$CHAIN_AGENT" \
    LOOM_PROVIDER= LOOM_SKIP_PROVIDER_CHECK= LOOM_DEFER_LANE_LAUNCH=1 \
    "$MUT_PROVIDER/tick.sh" chain-gate impl-236 >"$T/mut-provider.out" 2>&1; then
  mut_provider_rc=0
else
  mut_provider_rc=$?
fi
mut_request=$(find "$LOOM_HOME/lane-launch-queue" -maxdepth 1 -type d -name 'request-*' | head -1)
if [ -z "$mut_request" ] \
   && grep -q "no provider job or custom command" "$LOOM_HOME/logs/self-trigger.log"; then
    ok "implementation handoff violation: deleting canonical recovery recreates the empty-provider refusal"
else
    bad "implementation handoff violation: provider mutant did not recreate D-TICK-35 (rc=$mut_provider_rc request=${mut_request:-none})"
fi

test_finish
