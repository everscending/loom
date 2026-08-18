#!/usr/bin/env bash
# Host-owned browser probes run before provider adapters
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

mkdir -p "$LOOM_REPO/scripts"
ORDER="$T/order"
SEEN="$T/provider-artifact.json"
cat > "$LOOM_REPO/scripts/probe.sh" <<'EOF'
#!/usr/bin/env bash
[ -z "${PROBE_ORDER:-}" ] || printf 'host:%s\n' "$1" >> "$PROBE_ORDER"
case "$1" in
  stale)
    jq -n --arg probe "$1" \
      '{schema:1,probe:$probe,head:"obsolete-head",classification:"pass",summary:"stale"}' \
      > "${LOOM_HOST_PROBE_OUTPUT:?}"
    ;;
  product)
    jq -n --arg probe "$1" --arg head "${LOOM_HOST_PROBE_HEAD:?}" \
      '{schema:1,probe:$probe,head:$head,classification:"fail",summary:"acceptance assertion failed"}' \
      > "${LOOM_HOST_PROBE_OUTPUT:?}"
    exit 1
    ;;
  infrastructure)
    jq -n --arg probe "$1" --arg head "${LOOM_HOST_PROBE_HEAD:?}" \
      '{schema:1,probe:$probe,head:$head,classification:"infrastructure",summary:"browser bootstrap denied"}' \
      > "${LOOM_HOST_PROBE_OUTPUT:?}"
    exit 1
    ;;
  *)
    jq -n --arg probe "$1" --arg head "${LOOM_HOST_PROBE_HEAD:?}" \
      '{schema:1,probe:$probe,head:$head,classification:"pass",summary:"acceptance passed"}' \
      > "${LOOM_HOST_PROBE_OUTPUT:?}"
    ;;
esac
EOF
cat > "$T/probe-agent.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  detect|preflight) exit 0 ;;
  run)
    printf 'provider:%s\n' "$3" >> "${PROBE_ORDER:?}"
    cp "${LOOM_HOST_PROBE_ARTIFACT:?}" "${PROBE_SEEN:?}"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$LOOM_REPO/scripts/probe.sh" "$T/probe-agent.sh"
git -C "$LOOM_REPO" add .
git -C "$LOOM_REPO" commit -qm 'probe fixture'
HEAD_SHA=$(git -C "$LOOM_REPO" rev-parse HEAD)
printf 'probe brief\n' > "$T/probe-brief.md"

PROBE_ORDER="$ORDER" PROBE_SEEN="$SEEN" LOOM_AGENT_CMD="$T/probe-agent.sh" \
  "$TICK" spawn-lane probe-e2 --no-tick --host-probe e2 \
    --provider claude --job probe --tier medium --brief "$T/probe-brief.md" \
    --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/probe-e2.rc" ] && break; sleep 0.1; done

if [ "$(cat "$LOOM_HOME/lanes/probe-e2.rc" 2>/dev/null)" = 0 ] \
   && [ "$(sed -n '1p' "$ORDER")" = host:e2 ] \
   && [ "$(sed -n '2p' "$ORDER")" = provider:claude ] \
   && jq -e --arg head "$HEAD_SHA" \
        '.probe == "e2" and .head == $head and .classification == "pass" and .runner_rc == 0' \
        "$SEEN" >/dev/null 2>&1; then
  ok "host probe: repo-owned acceptance runs before the shared provider adapter with immutable HEAD evidence"
else
  bad "host probe: acceptance did not precede the provider with attributable evidence"
fi
for _ in $(seq 1 60); do
  direct_pid=$(cat "$LOOM_HOME/lanes/probe-e2.pid" 2>/dev/null || true)
  [ -z "$direct_pid" ] || ! kill -0 "$direct_pid" 2>/dev/null || { sleep 0.1; continue; }
  break
done

# Codex-authored handoffs cross a durable queue before reaching the same host
# boundary. The semantic id must survive that trip; reconstructing it from a
# brief or lane name would make the queue a provider-specific second protocol.
rm -f "$ORDER" "$SEEN"
PROBE_ORDER="$ORDER" PROBE_SEEN="$SEEN" LOOM_AGENT_CMD="$T/probe-agent.sh" \
  LOOM_DEFER_LANE_LAUNCH=1 \
  "$TICK" spawn-lane probe-e2-queued --no-tick --host-probe e2 \
    --provider codex --job probe --tier medium --brief "$T/probe-brief.md" \
    --cwd "$LOOM_REPO" >/dev/null
REQUEST=$(find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
  -name 'request-*-probe-e2-queued' | head -1)
queued_probe=$(cat "$REQUEST/host-probe" 2>/dev/null || true)
PROBE_ORDER="$ORDER" PROBE_SEEN="$SEEN" LOOM_AGENT_CMD="$T/probe-agent.sh" \
  "$TICK" drain-lane-launches >/dev/null 2>&1
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/probe-e2-queued.rc" ] && break; sleep 0.1; done
if [ "$queued_probe" = e2 ] \
   && [ "$(cat "$LOOM_HOME/lanes/probe-e2-queued.rc" 2>/dev/null)" = 0 ] \
   && [ "$(sed -n '1p' "$ORDER")" = host:e2 ] \
   && [ "$(sed -n '2p' "$ORDER")" = provider:codex ]; then
  ok "host probe: durable Codex requests preserve the probe id and drain through the shared pre-adapter seam"
else
  bad "host probe: durable queue lost or bypassed the host probe (stored=$queued_probe)"
fi
for _ in $(seq 1 60); do
  queued_pid=$(cat "$LOOM_HOME/lanes/probe-e2-queued.pid" 2>/dev/null || true)
  [ -z "$queued_pid" ] || ! kill -0 "$queued_pid" 2>/dev/null || { sleep 0.1; continue; }
  break
done

# Chromium probes and UI gates share the same host fixtures. A queued probe is
# already a reservation: admitting a gate before the durable host drains it
# would recreate the identity/port collisions the resource lock prevents.
LOOM_AGENT_CMD="$T/probe-agent.sh" LOOM_DEFER_LANE_LAUNCH=1 \
  "$TICK" spawn-lane probe-ui-held --no-tick --host-probe e2 \
    --provider codex --job probe --tier medium --brief "$T/probe-brief.md" \
    --cwd "$LOOM_REPO" >/dev/null
admit_rc=0
admit_out=$("$TICK" spawn-lane gate-499 --no-tick --pregate ui \
  --cwd "$LOOM_REPO" -- sleep 30 2>&1) || admit_rc=$?
gate_pid=$(cat "$LOOM_HOME/lanes/gate-499.pid" 2>/dev/null || true)
if [ "$admit_rc" -ne 0 ] && [ -z "$gate_pid" ] \
   && printf '%s' "$admit_out" | grep -q 'UI host capacity'; then
  ok "host probe: a durable Chromium probe reserves the shared UI host resource"
else
  bad "host probe: a UI gate overlapped a queued Chromium probe (rc=$admit_rc pid=$gate_pid)"
fi
[ -z "$gate_pid" ] || kill "$gate_pid" 2>/dev/null || true
rm -rf "$LOOM_HOME/lane-launch-queue"/request-*

# The only provider-controlled host input is a strict slug. There is no runner
# path option and malformed input is rejected before lane state is created.
PWNED="$T/host-probe-pwned"
invalid_rc=0
invalid_out=$(LOOM_AGENT_CMD="$T/probe-agent.sh" "$TICK" spawn-lane probe-bad \
  --no-tick --host-probe "e2;touch-$PWNED" --provider claude --job probe \
  --tier medium --brief "$T/probe-brief.md" --cwd "$LOOM_REPO" 2>&1) || invalid_rc=$?
path_rc=0
path_out=$(LOOM_AGENT_CMD="$T/probe-agent.sh" "$TICK" spawn-lane probe-bad-path \
  --no-tick --host-probe e2 --host-probe-runner /tmp/evil \
  --provider claude --job probe --tier medium --brief "$T/probe-brief.md" \
  --cwd "$LOOM_REPO" 2>&1) || path_rc=$?
if [ "$invalid_rc" -ne 0 ] && [ "$path_rc" -ne 0 ] && [ ! -e "$PWNED" ] \
   && [ ! -e "$LOOM_HOME/lanes/probe-bad.pid" ] \
   && printf '%s' "$invalid_out$path_out" | grep -q 'host-probe'; then
  ok "host probe: malformed ids and arbitrary runner paths are refused before lane mutation"
else
  bad "host probe: provider-controlled text reached the host command boundary"
fi

# A runner artifact is evidence only for the HEAD captured at launch. A stale
# or malformed claim becomes infrastructure and the provider never starts.
rm -f "$ORDER" "$SEEN"
PROBE_ORDER="$ORDER" PROBE_SEEN="$SEEN" LOOM_AGENT_CMD="$T/probe-agent.sh" \
  "$TICK" spawn-lane probe-stale --no-tick --host-probe stale \
    --provider claude --job probe --tier medium --brief "$T/probe-brief.md" \
    --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/probe-stale.rc" ] && break; sleep 0.1; done
if [ "$(cat "$LOOM_HOME/lanes/probe-stale.rc" 2>/dev/null)" = 10 ] \
   && [ ! -e "$SEEN" ] \
   && jq -e --arg head "$HEAD_SHA" \
        '.head == $head and .classification == "infrastructure" and (.summary | contains("HEAD-attributed"))' \
        "$LOOM_HOME/lanes/probe-stale.host-probe.json" >/dev/null 2>&1; then
  ok "host probe: stale HEAD evidence is normalized to infrastructure and suppresses the provider"
else
  bad "host probe: stale acceptance evidence reached a provider as current"
fi
for _ in $(seq 1 60); do
  stale_pid=$(cat "$LOOM_HOME/lanes/probe-stale.pid" 2>/dev/null || true)
  [ -z "$stale_pid" ] || ! kill -0 "$stale_pid" 2>/dev/null || { sleep 0.1; continue; }
  break
done

# A product assertion is not an infrastructure launch failure. Its nonzero
# test status is retained in the artifact while the provider starts to report
# the product result through the existing tracker workflow.
rm -f "$ORDER" "$SEEN"
PROBE_ORDER="$ORDER" PROBE_SEEN="$SEEN" LOOM_AGENT_CMD="$T/probe-agent.sh" \
  "$TICK" spawn-lane probe-product --no-tick --host-probe product \
    --provider claude --job probe --tier medium --brief "$T/probe-brief.md" \
    --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/probe-product.rc" ] && break; sleep 0.1; done
if [ "$(cat "$LOOM_HOME/lanes/probe-product.rc" 2>/dev/null)" = 0 ] \
   && jq -e '.classification == "fail" and .runner_rc == 1' "$SEEN" >/dev/null 2>&1 \
   && [ "$(sed -n '2p' "$ORDER")" = provider:claude ]; then
  ok "host probe: product assertion evidence reaches the provider without becoming a pregate rejection"
else
  bad "host probe: product evidence was confused with host infrastructure"
fi
for _ in $(seq 1 60); do
  product_pid=$(cat "$LOOM_HOME/lanes/probe-product.pid" 2>/dev/null || true)
  [ -z "$product_pid" ] || ! kill -0 "$product_pid" 2>/dev/null || { sleep 0.1; continue; }
  break
done

# Pre-product Chromium/bootstrap failures stop before a paid provider and use a
# dedicated rc, never pregate's rc 7 (which would create rejection history).
rm -f "$ORDER" "$SEEN"
PROBE_ORDER="$ORDER" PROBE_SEEN="$SEEN" LOOM_AGENT_CMD="$T/probe-agent.sh" \
  "$TICK" spawn-lane probe-infrastructure --no-tick --host-probe infrastructure \
    --provider claude --job probe --tier medium --brief "$T/probe-brief.md" \
    --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/probe-infrastructure.rc" ] && break; sleep 0.1; done
if [ "$(cat "$LOOM_HOME/lanes/probe-infrastructure.rc" 2>/dev/null)" = 10 ] \
   && [ ! -e "$SEEN" ] \
   && jq -e '.classification == "infrastructure" and .runner_rc == 1' \
        "$LOOM_HOME/lanes/probe-infrastructure.host-probe.json" >/dev/null 2>&1; then
  ok "host probe: Chromium infrastructure failure suppresses the provider without rc 7 rejection semantics"
else
  bad "host probe: infrastructure failure spent a provider or looked like a rejection"
fi
for _ in $(seq 1 60); do
  infra_pid=$(cat "$LOOM_HOME/lanes/probe-infrastructure.pid" 2>/dev/null || true)
  [ -z "$infra_pid" ] || ! kill -0 "$infra_pid" 2>/dev/null || { sleep 0.1; continue; }
  break
done

# On macOS the one-shot launchd process—not the provider adapter—must own the
# browser. Execute the generated plist with a launchctl stand-in and observe
# the same host-before-provider contract through the public spawn interface.
LAUNCH_MARK="$T/launchd-provider-ran"
cat > "$T/launchd-agent.sh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  detect|preflight) exit 0 ;;
  run) [ -f "\${LOOM_HOST_PROBE_ARTIFACT:?}" ] && touch "$LAUNCH_MARK" ;;
  *) exit 2 ;;
esac
EOF
LAUNCH_CALLS="$T/host-probe-launchctl.calls"
cat > "$T/host-probe-launchctl.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LAUNCH_CALLS:?}"
case "$1" in
  bootstrap)
    args_file="${LAUNCH_CALLS}.args"
    plutil -convert json -o - "$3" | jq -r '.ProgramArguments[]' > "$args_file"
    args=(); while IFS= read -r arg; do args+=("$arg"); done < "$args_file"
    "${args[@]}" &
    ;;
  print) exit 1 ;;
  bootout|remove) exit 0 ;;
esac
EOF
chmod +x "$T/launchd-agent.sh" "$T/host-probe-launchctl.sh"
LAUNCH_CALLS="$LAUNCH_CALLS" LAUNCHCTL_CMD="$T/host-probe-launchctl.sh" \
  LOOM_LANE_LAUNCHER=launchd LOOM_AGENT_CMD="$T/launchd-agent.sh" \
  "$TICK" spawn-lane probe-launchd --no-tick --host-probe e2 \
    --provider claude --job probe --tier medium --brief "$T/probe-brief.md" \
    --cwd "$LOOM_REPO" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/probe-launchd.rc" ] && break; sleep 0.1; done
launch_program=$(plutil -convert json -o - "$LOOM_HOME/lanes/probe-launchd.plist" \
  | jq -r '.ProgramArguments | map(select(contains("run-host-probe"))) | first // ""')
if [ "$(cat "$LOOM_HOME/lanes/probe-launchd.rc" 2>/dev/null)" = 0 ] \
   && [ -e "$LAUNCH_MARK" ] \
   && printf '%s' "$launch_program" | grep -q 'run-host-probe'; then
  ok "host probe: launchd owns the Chromium prelude before the provider adapter"
else
  bad "host probe: launchd plist did not retain the host-owned prelude"
fi

# Planted violation: remove the one shared pre-adapter call. The provider then
# starts without host evidence, proving the test observes the intended guard
# rather than merely the fixture runner or the adapter stub.
MUT_DIR="$T/mutant"; MUT_TICK=$(mirror_scripts "$MUT_DIR")/tick.sh
sed -i.bak '/^[[:space:]]*_spawn_build_host_probe$/d' "$MUT_TICK"
MUT_HOME="$T/mutant-home" MUT_ORDER="$T/mutant-order" MUT_SEEN="$T/mutant-seen"
mut_out=$(LOOM_HOME="$MUT_HOME" PROBE_ORDER="$MUT_ORDER" PROBE_SEEN="$MUT_SEEN" \
  LOOM_AGENT_CMD="$T/probe-agent.sh" "$MUT_TICK" spawn-lane probe-mutant \
    --no-tick --host-probe e2 --provider claude --job probe --tier medium \
    --brief "$T/probe-brief.md" --cwd "$LOOM_REPO" 2>&1)
mut_rc=$?
if assert_mutant_ran "$mut_rc" "$mut_out" "host-probe-violation"; then
  for _ in $(seq 1 60); do [ -f "$MUT_HOME/lanes/probe-mutant.rc" ] && break; sleep 0.1; done
  if [ "$(sed -n '1p' "$MUT_ORDER" 2>/dev/null)" = provider:claude ] \
     && ! grep -q '^host:' "$MUT_ORDER" 2>/dev/null; then
    ok "host-probe-violation: removing the shared prelude starts the provider without host acceptance"
  else
    bad "host-probe-violation: mutant did not recreate provider-first execution"
  fi
fi

test_finish
