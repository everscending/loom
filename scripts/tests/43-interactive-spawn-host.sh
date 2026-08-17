#!/usr/bin/env bash
# interactive Codex operator spawns cross the durable host boundary
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

AGENT="$T/spawn-agent.sh"
MARK="$T/agent-ran"
cat > "$AGENT" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  detect|preflight) exit 0 ;;
  run) touch "${SPAWN_MARK:?}"; sleep 30 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$AGENT"
printf 'implementation brief\n' > "$T/brief.md"

# The operator can invoke spawn-lane from an interactive Codex turn, outside
# any provider lane. That outer process scope is still disposable: starting a
# child directly makes the pane appear and then die when the tool call returns.
CODEX_THREAD_ID=interactive CODEX_SESSION_ID= CODEX_CI= \
  LOOM_AGENT_CMD="$AGENT" SPAWN_MARK="$MARK" \
  "$TICK" spawn-lane impl-430 --no-tick --provider codex --job implementation \
    --tier medium --brief "$T/brief.md" --cwd "$LOOM_REPO" >/dev/null
if [ ! -e "$LOOM_HOME/lanes/impl-430.pid" ] \
   && [ ! -e "$MARK" ] \
   && find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
        -name 'request-*-impl-430' | grep -q .; then
  ok "interactive spawn: Codex queues the worker for a durable host"
else
  bad "interactive spawn: Codex directly owned a disposable worker"
  pid=$(cat "$LOOM_HOME/lanes/impl-430.pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
fi

# Claude compatibility: without an ephemeral Codex host marker, the existing
# direct launch stays direct. The shared core changes only where the request is
# hosted, not either provider adapter or the lane command it eventually runs.
CLAUDE_MARK="$T/claude-agent-ran"
CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI= \
  LOOM_AGENT_CMD="$AGENT" SPAWN_MARK="$CLAUDE_MARK" \
  "$TICK" spawn-lane impl-431 --no-tick --provider claude --job implementation \
    --tier medium --brief "$T/brief.md" --cwd "$LOOM_REPO" >/dev/null
claude_pid=$(cat "$LOOM_HOME/lanes/impl-431.pid" 2>/dev/null || true)
if [ -n "$claude_pid" ] && kill -0 "$claude_pid" 2>/dev/null \
   && [ -e "$CLAUDE_MARK" ]; then
  ok "interactive spawn: durable and Claude hosts retain direct launch"
else
  bad "interactive spawn: provider-neutral fix deferred a durable direct host"
fi
[ -z "$claude_pid" ] || kill "$claude_pid" 2>/dev/null || true

# Planted violation: remove only the ephemeral-host clause. The same Codex
# invocation must then create the disposable worker directly, proving that the
# new clause—not unrelated queue machinery—is the guard under test.
MUT_DIR="$T/mutant"; MUT_TICK=$(mirror_scripts "$MUT_DIR")/tick.sh
sed -i.bak 's/ || _codex_host_is_ephemeral//' "$MUT_TICK"
MUT_HOME="$T/mutant-home"; MUT_MARK="$T/mutant-agent-ran"
out=$(LOOM_HOME="$MUT_HOME" CODEX_THREAD_ID=interactive CODEX_SESSION_ID= CODEX_CI= \
  LOOM_AGENT_CMD="$AGENT" SPAWN_MARK="$MUT_MARK" \
  "$MUT_TICK" spawn-lane impl-432 --no-tick --provider codex --job implementation \
    --tier medium --brief "$T/brief.md" --cwd "$LOOM_REPO" 2>&1)
rc=$?
if assert_mutant_ran "$rc" "$out" "interactive-spawn-violation"; then
  mutant_pid=$(cat "$MUT_HOME/lanes/impl-432.pid" 2>/dev/null || true)
  if [ -n "$mutant_pid" ] && [ -e "$MUT_MARK" ] \
     && ! find "$MUT_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 -type d \
          -name 'request-*-impl-432' 2>/dev/null | grep -q .; then
    ok "interactive-spawn-violation: removing the host guard recreates direct ownership"
  else
    bad "interactive-spawn-violation: mutant did not recreate the disposable launch"
  fi
  [ -z "$mutant_pid" ] || kill "$mutant_pid" 2>/dev/null || true
fi

test_finish
