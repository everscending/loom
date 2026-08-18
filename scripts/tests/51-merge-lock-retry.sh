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
  detect) exit 0 ;;
  preflight)
    if [ "${ADVANCE_ON_PREFLIGHT:-}" = 1 ]; then
      while [ "$#" -gt 0 ]; do
        [ "$1" = --cwd ] && { repo="$2"; break; }
        shift
      done
      printf 'preflight raced the deferred launch\n' > "$repo/preflight-race.txt"
      git -C "$repo" add preflight-race.txt
      git -C "$repo" commit -qm 'advance during provider preflight'
    fi
    exit 0
    ;;
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
queued_request=$(find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
  -type d -name 'request-*' -exec sh -c \
  '[ "$(cat "$1/id" 2>/dev/null)" = merge-286 ] && printf "%s\n" "$1"' _ {} \; | head -1)

drain_rc=0
LOOM_AGENT_CMD="$AGENT" "$TICK" drain-lane-launches >"$T/drain-busy.out" 2>&1 || drain_rc=$?
request_count=$(find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
  -type d -name 'request-*' -exec sh -c \
  '[ "$(cat "$1/id" 2>/dev/null)" = merge-286 ] && printf x' _ {} \; | wc -c | tr -d ' ')
if [ "$drain_rc" = 0 ] \
   && [ "$request_count" = 1 ] \
   && [ "$(cat "$queued_request/expected-head" 2>/dev/null)" = "$QUEUED_HEAD" ] \
   && [ ! -e "$LOOM_HOME/lanes/merge-286.pid" ] \
   && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
        -type d -name 'failed-*' | grep -q . \
   && ! grep -q '"ev":"lane_launch_failed".*"id":"merge-286"' "$LOOM_HOME/events.jsonl"; then
    ok "merge lock: a busy direct handoff stays durably queued without failed launch state"
else
    bad "merge lock: occupied lock destroyed or failed the durable handoff (rc=$drain_rc requests=$request_count; $(cat "$T/drain-busy.out"))"
fi

# A direct Claude-style handoff has no durable request to preserve. It remains
# a successful optional fast-path refusal and leaves scheduling to the normal
# heartbeat, without creating lane state or duplicating the queued Codex work.
direct_rc=0
direct_out=$(LOOM_LANE_ID=gate-286 "$TICK" spawn-lane merge-285 --no-tick \
  --merge-lock --cwd "$LOOM_REPO" -- true 2>&1) || direct_rc=$?
if [ "$direct_rc" = 0 ] \
   && printf '%s' "$direct_out" | grep -q 'ordinary heartbeat retries' \
   && [ ! -e "$LOOM_HOME/lanes/merge-285.pid" ] \
   && [ "$request_count" = 1 ]; then
    ok "merge lock: a direct non-durable successor collision remains a soft handoff"
else
    bad "merge lock: direct successor collision became a hard failure or duplicate request"
fi

# The reviewed worktree advances while the request waits. Releasing capacity
# must not let the same durable request silently launch this different commit.
printf 'newer mutable worktree state\n' > "$LOOM_REPO/advanced.txt"
git -C "$LOOM_REPO" add advanced.txt
git -C "$LOOM_REPO" commit -qm 'advance after durable queue'
ADVANCED_HEAD=$(git -C "$LOOM_REPO" rev-parse HEAD)
"$TICK" kill-lane merge-287 >/dev/null 2>&1 || true
for _ in $(seq 1 80); do [ ! -d "$LOOM_HOME/merge.lock.d" ] && break; sleep 0.05; done
drift_rc=0
LOOM_AGENT_CMD="$AGENT" "$TICK" drain-lane-launches >"$T/drain-drift.out" 2>&1 || drift_rc=$?
request_count=$(find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
  -type d -name 'request-*' -exec sh -c \
  '[ "$(cat "$1/id" 2>/dev/null)" = merge-286 ] && printf x' _ {} \; | wc -c | tr -d ' ')
if [ "$drift_rc" = 0 ] \
   && [ "$request_count" = 1 ] \
   && [ ! -e "$LOOM_HOME/lanes/merge-286.pid" ] \
   && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
        -type d -name 'failed-*' | grep -q .; then
    ok "merge head: queue-at-A refuses and retains safely after the worktree advances to B"
else
    bad "merge head: delayed request launched mutable head $ADVANCED_HEAD or lost its retry (rc=$drift_rc requests=$request_count)"
fi

# Return only the fixture checkout to A. A provider preflight that races the
# final launch boundary must receive the same immutable-HEAD refusal.
git -C "$LOOM_REPO" checkout -q "$QUEUED_HEAD"
ADVANCE_ON_PREFLIGHT=1 LOOM_SKIP_AGENT_PREFLIGHT= LOOM_AGENT_CMD="$AGENT" \
  "$TICK" drain-lane-launches >"$T/drain-preflight-race.out" 2>&1
request_count=$(find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
  -type d -name 'request-*' -exec sh -c \
  '[ "$(cat "$1/id" 2>/dev/null)" = merge-286 ] && printf x' _ {} \; | wc -c | tr -d ' ')
if [ "$request_count" = 1 ] \
   && [ ! -e "$LOOM_HOME/lanes/merge-286.pid" ] \
   && [ "$(git -C "$LOOM_REPO" rev-parse HEAD)" != "$QUEUED_HEAD" ]; then
    ok "merge head: a provider preflight race cannot advance the reviewed launch boundary"
else
    bad "merge head: provider preflight advanced the deferred merge past its reviewed commit"
fi

# The same queued request, not a reconstructed or duplicate request, can then
# launch at its captured head after a human restores the checkout.
git -C "$LOOM_REPO" checkout -q "$QUEUED_HEAD"
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

# Planted HEAD violation: remove only the deferred expected-HEAD refusal.
# Queue at A, advance the same worktree to B, then prove the mutated public
# drain starts B instead of preserving the reviewed request.
MUT_HEAD=$(mirror_scripts "$T/mut-head")
sed -i.bak 's/return 75 # mutate:deferred-merge-head/: # mutate:deferred-merge-head/' "$MUT_HEAD/tick.sh"
git -C "$LOOM_REPO" checkout -q "$QUEUED_HEAD"
"$MUT_HEAD/tick.sh" spawn-lane gate-686 --no-tick -- sleep 30 >/dev/null
LOOM_LANE_ID=gate-686 LOOM_DEFER_LANE_LAUNCH=1 LOOM_AGENT_CMD="$AGENT" \
  "$MUT_HEAD/tick.sh" spawn-lane merge-686 --no-tick --merge-lock --pregate logic \
  --provider codex --job merge --tier medium --brief "$T/merge-brief.md" \
  --cwd "$LOOM_REPO" >/dev/null
printf 'mutated delayed head\n' > "$LOOM_REPO/mutated-head.txt"
git -C "$LOOM_REPO" add mutated-head.txt
git -C "$LOOM_REPO" commit -qm 'advance mutated durable queue'
MUTABLE_HEAD=$(git -C "$LOOM_REPO" rev-parse HEAD)
head_mut_out=$(LOOM_AGENT_CMD="$AGENT" "$MUT_HEAD/tick.sh" drain-lane-launches 2>&1); head_mut_rc=$?
if assert_mutant_ran "$head_mut_rc" "$head_mut_out" "merge-head-violation"; then
    if [ "$(cat "$LOOM_HOME/lanes/merge-686.head" 2>/dev/null)" = "$MUTABLE_HEAD" ] \
       && ! find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
            -type d -name 'request-*' -exec sh -c \
            '[ "$(cat "$1/id" 2>/dev/null)" = merge-686 ] && printf x' _ {} \; | grep -q .; then
        ok "merge-head-violation: removing the HEAD check launches mutable B from a queue created at A"
    else
        bad "merge-head-violation: planted omission did not launch the advanced worktree"
    fi
fi
"$MUT_HEAD/tick.sh" kill-lane merge-686 >/dev/null 2>&1 || true
"$MUT_HEAD/tick.sh" kill-lane gate-686 >/dev/null 2>&1 || true
git -C "$LOOM_REPO" checkout -q "$QUEUED_HEAD"

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

# Existing directories with missing or malformed owner metadata are equally
# unsafe: Loom cannot prove they are stale, so it must preserve them and fail.
rm -f "$T/not-a-lock-parent"
mkdir -p "$T/malformed-merge.lock"
missing_out=$(LOOM_MERGE_LOCK_DIR="$T/malformed-merge.lock" \
  "$TICK" spawn-lane merge-487 --no-tick --merge-lock --cwd "$LOOM_REPO" -- true 2>&1)
missing_rc=$?
printf 'not-a-pid\n' > "$T/malformed-merge.lock/pid"
nonnumeric_out=$(LOOM_MERGE_LOCK_DIR="$T/malformed-merge.lock" \
  "$TICK" spawn-lane merge-488 --no-tick --merge-lock --cwd "$LOOM_REPO" -- true 2>&1)
nonnumeric_rc=$?
if [ "$missing_rc" -ne 0 ] && [ "$nonnumeric_rc" -ne 0 ] \
   && [ "$(cat "$T/malformed-merge.lock/pid" 2>/dev/null)" = not-a-pid ] \
   && [ ! -e "$LOOM_HOME/lanes/merge-487.pid" ] \
   && [ ! -e "$LOOM_HOME/lanes/merge-488.pid" ]; then
    ok "merge lock: missing and nonnumeric owner metadata fail closed without deleting the lock"
else
    bad "merge lock: malformed owner metadata was treated as a stale lock and admitted a merge"
fi

# Planted lock violation: bypass only owner-shape validation. The old stale
# path deletes the unowned directory and starts a merge, proving the malformed
# metadata assertion is held by the new fail-closed check.
MUT_LOCK=$(mirror_scripts "$T/mut-lock")
sed -i.bak 's/_lock_owner_valid "$owner" || return 2 # mutate:lock-owner-shape/: # mutate:lock-owner-shape/' "$MUT_LOCK/tick.sh"
mkdir -p "$T/mut-malformed.lock"
lock_mut_out=$(LOOM_MERGE_LOCK_DIR="$T/mut-malformed.lock" \
  "$MUT_LOCK/tick.sh" spawn-lane merge-586 --no-tick --merge-lock \
  --cwd "$LOOM_REPO" -- sleep 30 2>&1); lock_mut_rc=$?
if assert_mutant_ran "$lock_mut_rc" "$lock_mut_out" "merge-lock-owner-violation"; then
    if [ "$lock_mut_rc" = 0 ] && [ -s "$LOOM_HOME/lanes/merge-586.pid" ]; then
        ok "merge-lock-owner-violation: removing owner validation deletes the malformed lock and admits a merge"
    else
        bad "merge-lock-owner-violation: planted omission did not admit the unsafe merge"
    fi
fi
"$MUT_LOCK/tick.sh" kill-lane merge-586 >/dev/null 2>&1 || true
test_finish
