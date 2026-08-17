#!/usr/bin/env bash
# A durable gate-to-merge handoff waits through an occupied merge lock.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# Use a real repository and remote because a merge lane's host preflight
# reconciles the canonical base before it starts the provider.
mkdir -p "$LOOM_REPO/scripts"
cat > "$LOOM_REPO/scripts/gate.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in ui) sleep 2 ;; esac
exit 0
EOF
chmod +x "$LOOM_REPO/scripts/gate.sh"
git -C "$LOOM_REPO" add scripts/gate.sh
git -C "$LOOM_REPO" commit -qm init
git -C "$LOOM_REPO" branch -M main
git init -q --bare "$T/origin.git"
git -C "$LOOM_REPO" remote add origin "$T/origin.git"
git -C "$LOOM_REPO" push -q -u origin main
QUEUED_HEAD=$(git -C "$LOOM_REPO" rev-parse HEAD)

AGENT="$T/agent.sh"
TRACKER="$T/tracker.sh"
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
  issue) printf '{"id":%s,"state":"open","labels":["build-1","merge-queue"],"body":""}\n' "$2" ;;
  *) printf '[]\n' ;;
esac
EOF
chmod +x "$AGENT" "$TRACKER"
export TRACKER_CMD="$TRACKER"
printf 'merge the reviewed immutable head\n' > "$T/merge-brief.md"

# JOR-287 owns both the merge lock and, during its host pregate, the shared UI
# resource. JOR-286's logic-tier successor is still allowed to reserve a
# durable request; it only collides when the host drains that request.
"$TICK" spawn-lane merge-287 --no-tick --merge-lock --pregate ui \
  --cwd "$LOOM_REPO" -- sleep 30 >/dev/null
for _ in $(seq 1 80); do
    [ -d "$LOOM_HOME/merge.lock.d" ] && [ -f "$LOOM_HOME/lanes/merge-287.ui-resource" ] && break
    sleep 0.05
done

"$TICK" spawn-lane gate-286 --no-tick -- sleep 30 >/dev/null
LOOM_LANE_ID=gate-286 LOOM_DEFER_LANE_LAUNCH=1 LOOM_AGENT_CMD="$AGENT" \
  "$TICK" spawn-lane merge-286 --no-tick --merge-lock --pregate logic \
  --provider codex --job merge --tier medium --brief "$T/merge-brief.md" \
  --cwd "$LOOM_REPO" >/dev/null

drain_rc=0
LOOM_AGENT_CMD="$AGENT" "$TICK" drain-lane-launches >"$T/drain-busy.out" 2>&1 || drain_rc=$?
request_count=$(find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
  -type d -name 'request-*' -exec sh -c \
  '[ "$(cat "$1/id" 2>/dev/null)" = merge-286 ] && printf x' _ {} \; | wc -c | tr -d ' ')
if [ "$drain_rc" = 0 ] \
   && [ "$request_count" = 1 ] \
   && [ ! -e "$LOOM_HOME/lanes/merge-286.pid" ] \
   && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
        -type d -name 'failed-*' | grep -q . \
   && ! grep -q '"ev":"lane_launch_failed".*"id":"merge-286"' "$LOOM_HOME/events.jsonl"; then
    ok "merge lock: a busy direct handoff stays durably queued without failed launch state"
else
    bad "merge lock: occupied lock destroyed or failed the durable handoff (rc=$drain_rc requests=$request_count; $(cat "$T/drain-busy.out"))"
fi

# Release the current merge. The same queued request, not a reconstructed or
# duplicate request, must launch at its originally reviewed commit.
"$TICK" kill-lane merge-287 >/dev/null 2>&1 || true
for _ in $(seq 1 80); do [ ! -d "$LOOM_HOME/merge.lock.d" ] && break; sleep 0.05; done
LOOM_AGENT_CMD="$AGENT" "$TICK" drain-lane-launches >/dev/null 2>&1
for _ in $(seq 1 80); do [ -s "$LOOM_HOME/lanes/merge-286.pid" ] && break; sleep 0.05; done
if [ -s "$LOOM_HOME/lanes/merge-286.pid" ] \
   && [ "$(cat "$LOOM_HOME/lanes/merge-286.head" 2>/dev/null)" = "$QUEUED_HEAD" ] \
   && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
        -type d \( -name 'request-*' -o -name 'launching-*' -o -name 'failed-*' \) | grep -q .; then
    ok "merge lock: the ordinary durable retry launches exactly once at the reviewed commit after release"
else
    bad "merge lock: released resource did not launch the preserved immutable request"
fi

"$TICK" kill-lane merge-286 >/dev/null 2>&1 || true
"$TICK" kill-lane gate-286 >/dev/null 2>&1 || true

# Planted violation: make only a genuine merge-lock collision non-retryable in
# a private scripts mirror. The public gate -> durable queue -> drain flow must
# recreate the failed-* misclassification that stranded JOR-286's request.
MUT51=$(mirror_scripts "$T/mut51")
sed -i.bak 's/return 75 # mutate:merge-lock-retry/return 1 # mutate:merge-lock-retry/' "$MUT51/tick.sh"
"$MUT51/tick.sh" spawn-lane merge-387 --no-tick --merge-lock --pregate ui \
  --cwd "$LOOM_REPO" -- sleep 30 >/dev/null
for _ in $(seq 1 80); do
    [ -d "$LOOM_HOME/merge.lock.d" ] && [ -f "$LOOM_HOME/lanes/merge-387.ui-resource" ] && break
    sleep 0.05
done
"$MUT51/tick.sh" spawn-lane gate-386 --no-tick -- sleep 30 >/dev/null
LOOM_LANE_ID=gate-386 LOOM_DEFER_LANE_LAUNCH=1 LOOM_AGENT_CMD="$AGENT" \
  "$MUT51/tick.sh" spawn-lane merge-386 --no-tick --merge-lock --pregate logic \
  --provider codex --job merge --tier medium --brief "$T/merge-brief.md" \
  --cwd "$LOOM_REPO" >/dev/null
mut_out=$(LOOM_AGENT_CMD="$AGENT" "$MUT51/tick.sh" drain-lane-launches 2>&1); mut_rc=$?
if assert_mutant_ran "$mut_rc" "$mut_out" "merge-lock-retry-violation"; then
    if find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
         -type d -name 'failed-*' -exec sh -c \
         '[ "$(cat "$1/id" 2>/dev/null)" = merge-386 ] && printf x' _ {} \; | grep -q . \
       && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
            -type d -name 'request-*' -exec sh -c \
            '[ "$(cat "$1/id" 2>/dev/null)" = merge-386 ] && printf x' _ {} \; | grep -q .; then
        ok "merge-lock-retry-violation: removing retry rc recreates the failed durable handoff"
    else
        bad "merge-lock-retry-violation: planted non-retry did not recreate failed-*"
    fi
fi
"$MUT51/tick.sh" kill-lane merge-387 >/dev/null 2>&1 || true
"$MUT51/tick.sh" kill-lane gate-386 >/dev/null 2>&1 || true

# Retry is only for a live owner's ordinary collision. An uncreatable lock
# path is unsafe host state and must still fail closed instead of cycling a
# poisoned request forever.
: > "$T/not-a-lock-parent"
unsafe_out=$(LOOM_MERGE_LOCK_DIR="$T/not-a-lock-parent/merge.lock" \
  "$TICK" spawn-lane merge-486 --no-tick --merge-lock --cwd "$LOOM_REPO" -- true 2>&1)
unsafe_rc=$?
if [ "$unsafe_rc" -ne 0 ] \
   && printf '%s' "$unsafe_out" | grep -q 'cannot reserve the merge lock safely' \
   && [ ! -e "$LOOM_HOME/lanes/merge-486.pid" ]; then
    ok "merge lock: unsafe reservation failure remains fail-closed and leaves no lane state"
else
    bad "merge lock: unsafe host state was retried or admitted (rc=$unsafe_rc; $unsafe_out)"
fi
test_finish
