#!/usr/bin/env bash
# P93: the merge queue drains itself — chain-merge's narrow snapshot read
# and its end-to-end fast path off a merge lane's own exit.
#
# Section 35 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# A `claude` stub on PATH: chain-merge's own spawn line names the binary
# literally (never a path), so is_claude/stream detection in spawn-lane
# resolves it off $PATH exactly like a real lane would. It sleeps rather
# than exiting immediately: this fixture never mutates itself the way a
# real merge lane would (closing its ticket), so an instantly-exiting stub
# would have the chained lane immediately chain AGAIN off the same still-
# eligible ticket — a tight, self-perpetuating loop the section never
# means to exercise. Sleeping keeps every chained lane alive for the whole
# section; `reap_lanes` below is what ends them, on purpose, between
# scenarios.
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
sleep 5
exit 0
EOF
chmod +x "$T/bin/claude"
export PATH="$T/bin:$PATH"

# A real repo at $LOOM_REPO, one commit and a local origin, so worktrees can
# branch off it and the host merge preflight can reconcile without a network.
# `seed_tracker_decl` (test-lib.sh) already ran `git init` + staged the
# tracker declaration; this section is the first to need a commit and a
# worktree.
mkdir -p "$LOOM_REPO/scripts"
HOST_GATE_MARK="$T/host-merge-gate"
printf '#!/usr/bin/env bash\n[ -f base-after.txt ] || exit 44\n[ ! -f RED ] || exit 45\ntouch %q\n' \
    "$HOST_GATE_MARK" > "$LOOM_REPO/scripts/gate.sh"
chmod +x "$LOOM_REPO/scripts/gate.sh"
git -C "$LOOM_REPO" add scripts/gate.sh
git -C "$LOOM_REPO" commit -qm init >/dev/null 2>&1
git -C "$LOOM_REPO" branch -M main
git init -q --bare "$T/origin.git"
git -C "$LOOM_REPO" remote add origin "$T/origin.git"
git -C "$LOOM_REPO" push -q -u origin main
# The next merge-queue ticket's worktree, a SIBLING of the repo (SKILL.md
# step 4's convention) — _worktree_for_branch reads this back by branch,
# never by the `<repo>-wt-<n>` name.
WT28="$T/repo-wt-28"
git -C "$LOOM_REPO" worktree add -q "$WT28" -b ticket-28 >/dev/null 2>&1
# Make main move after the ticket branch is cut. The host preflight must merge
# this commit before invoking the gate; the gate script itself refuses unless
# it can see the marker file.
printf 'arrived from main\n' > "$LOOM_REPO/base-after.txt"
git -C "$LOOM_REPO" add base-after.txt
git -C "$LOOM_REPO" commit -qm 'move integration base'
git -C "$LOOM_REPO" push -q origin main

# `git worktree list` always reports the PHYSICALLY resolved path (git
# canonicalizes at `add` time), where $T itself is mktemp's LOGICAL spelling
# — on macOS, /var is a symlink to /private/var. The trust fixture above
# keyed its one entry on the logical form; add the physical one too, the
# same "ask both spellings" the trust cascade itself already documents
# (_trust_check_dir's own P30 history), so this section tests chain-merge's
# worktree resolution rather than an artifact of mktemp on macOS.
T_PHYS="$(cd -P "$T" && pwd)"
if [ "$T_PHYS" != "$T" ]; then
    jq --arg d "$T_PHYS" '.projects[$d] = {hasTrustDialogAccepted: true}' \
        "$LOOM_TRUST_FILE" > "$LOOM_TRUST_FILE.tmp" && mv "$LOOM_TRUST_FILE.tmp" "$LOOM_TRUST_FILE"
fi

FX="$T/fx35"
make_glab_fixture "$FX"
cat > "$FX/open.json" <<'EOF'
[
 {"iid":1,"title":"Build 9","project_id":1,"web_url":"https://x/1","labels":["provider::claude"],"assignees":[],"description":"noise"},
 {"iid":28,"title":"Second in queue's blocker","project_id":1,"web_url":"https://x/28",
  "labels":["build-9","merge-queue","tier::logic"],"assignees":[],"updated_at":"2026-08-10T02:00:00Z"},
 {"iid":30,"title":"Newer, behind 28","project_id":1,"web_url":"https://x/30",
  "labels":["build-9","merge-queue","tier::api"],"assignees":[],"updated_at":"2026-08-10T03:00:00Z"}
]
EOF
cat > "$FX/mrs-28.json" <<'EOF'
[{"iid":101,"title":"t28","state":"opened","draft":false,"web_url":"https://x/mr/101","source_branch":"ticket-28","sha":"aaaaaaa"}]
EOF
cat > "$FX/mrs-30.json" <<'EOF'
[{"iid":102,"title":"t30","state":"opened","draft":false,"web_url":"https://x/mr/102","source_branch":"ticket-30","sha":"bbbbbbb"}]
EOF
echo '[]' > "$FX/notes-28.json"
echo '[]' > "$FX/notes-30.json"

GQ() { GLAB_CMD="$FX/glab-stub.sh" "$TICK" snapshot --merge-queue 2>"$T/mq.err"; }

# Between scenarios: a chained merge can itself chain again (merge-28's own
# exit reads the same fixture merge-30 is still sitting in), so more than
# the one pid this section named explicitly may be alive by the time a
# later scenario starts. Reap all of them rather than one name, and clear
# the lock unconditionally — these are independent scenarios, not a
# continuation of one build.
reap_lanes() {
    local f pid
    for f in "$LOOM_HOME"/lanes/*.pid; do
        [ -f "$f" ] || continue
        pid="$(cat "$f" 2>/dev/null || true)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done
    sleep 0.2
    rm -rf "$LOOM_HOME/merge.lock.d" "$LOOM_HOME/tick.lock.d" "$LOOM_HOME/lanes"
}

# --- A. the narrow read itself, no worktree involved -----------------------

GQ > "$T/mq.json"; rc=$?
if [ "$rc" = 0 ] && jq -e . "$T/mq.json" >/dev/null 2>&1; then
    [ "$(jq -c '[.[].id]' "$T/mq.json")" = "[28,30]" ] \
        && ok "merge-queue: both tickets, oldest first" \
        || bad "merge-queue: wrong set/order ($(jq -c . "$T/mq.json"))"
    [ "$(jq -r '.[0].branch' "$T/mq.json")" = "ticket-28" ] \
        && ok "merge-queue: the head names its MR's branch" \
        || bad "merge-queue: branch missing or wrong ($(jq -c '.[0]' "$T/mq.json"))"
    [ "$(jq -c '[.[].tier]' "$T/mq.json")" = '["logic","api"]' ] \
        && ok "merge-queue: the narrow read carries each ticket's gate tier" \
        || bad "merge-queue: gate tiers missing ($(jq -c . "$T/mq.json"))"
else
    bad "merge-queue: read failed rc=$rc ($(cat "$T/mq.err"))"
fi

# A2. Planted violation: a ticket at the attempt cap is excluded, same rule
#     plan.jq's own $merge_head applies — a narrow read that forgot the cap
#     would re-offer a poisoned ticket forever.
cat > "$FX/notes-28.json" <<'EOF'
[{"system":false,"created_at":"2026-08-10T01:00:00Z","author":{"username":"merge"},"body":"<!-- orch-merge-attempt 28 -->"},
 {"system":false,"created_at":"2026-08-10T01:30:00Z","author":{"username":"merge"},"body":"<!-- orch-merge-attempt 28 -->"}]
EOF
GQ > "$T/mq2.json"
[ "$(jq -c '[.[].id]' "$T/mq2.json")" = "[30]" ] \
    && ok "merge-queue: a cap-exhausted head is excluded, the next ticket takes its place" \
    || bad "merge-queue: cap-exhausted ticket #28 leaked through ($(jq -c . "$T/mq2.json"))"
echo '[]' > "$FX/notes-28.json"   # restore for the end-to-end tests below

# --- B. end to end: a merge lane's exit chains straight to the next merge,
#     with no wave in between ------------------------------------------------

WAVE_MARK="$T/wave-fired-b"
reap_lanes
GLAB_CMD="$FX/glab-stub.sh" LOOM_WAVE_CMD="touch $WAVE_MARK" \
    "$TICK" spawn-lane merge-24 --merge-lock --cwd "$LOOM_REPO" -- sleep 0.2 >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/merge-28.pid" ] && break; sleep 0.1; done
if [ -f "$LOOM_HOME/lanes/merge-28.pid" ]; then
    ok "chain-merge: the next merge-queue ticket spawns directly off the exiting lane"
else
    bad "chain-merge: merge-28 never spawned"
fi
sleep 0.5   # settle: prove no wave follows, not just that none has yet
if [ -f "$WAVE_MARK" ]; then
    bad "chain-merge: a wave fired even though the fast path had a ticket to chain to"
else
    ok "chain-merge: no wave fired — the fast path alone advanced the queue"
fi
if [ -f "$LOOM_HOME/briefs/merge-28.md" ] \
   && grep -q '28' "$LOOM_HOME/briefs/merge-28.md" \
   && grep -qF "$WT28" "$LOOM_HOME/briefs/merge-28.md" \
   && grep -q 'main' "$LOOM_HOME/briefs/merge-28.md"; then
    ok "chain-merge: the rendered brief carries the ticket, its worktree and the base"
else
    bad "chain-merge: brief substitution incomplete ($(cat "$LOOM_HOME/briefs/merge-28.md" 2>/dev/null | head -3))"
fi
if grep -q 'host merge preflight' "$LOOM_HOME/briefs/merge-28.md" \
   && grep -q 'Do not rerun.*configured tier gate.*provider session' "$LOOM_HOME/briefs/merge-28.md"; then
    ok "chain-merge: the provider trusts host reconcile and gate evidence"
else
    bad "chain-merge: the merge provider still owns the sandboxed full gate"
fi
if [ "$(grep -c 'lane.sh reconcile' "$LOOM_HOME/briefs/merge-28.md")" -ge 2 ] \
   && grep -qF "$(cd "$(dirname "$TICK")" && pwd)/lane.sh merge 28" "$LOOM_HOME/briefs/merge-28.md" \
   && ! grep -q 'lane.sh: MR .* merged' "$LOOM_HOME/briefs/merge-28.md"; then
    ok "merge preflight: staging preserves helper commands as brief text"
else
    bad "merge preflight: staging executed a helper command from Markdown backticks"
fi
grep -q '"ev":"lane_spawn".*"id":"merge-28".*"pregate":"logic"' "$LOOM_HOME/events.jsonl" \
    && ok "chain-merge: the ticket tier reaches the host merge preflight" \
    || bad "chain-merge: the chained merge lost its host preflight tier"
if [ -f "$HOST_GATE_MARK" ] && [ -f "$WT28/base-after.txt" ]; then
    ok "chain-merge: host reconciliation completes before the configured gate and provider"
else
    bad "chain-merge: merge provider started without a reconciled host gate"
fi
reap_lanes

# A red host merge gate is not a gate-review rejection. It suppresses the
# provider and leaves rc 9 for the ordinary dead-merge harvest path; rc 7
# would make the wave post a gate verdict against a ticket already in the
# merge queue.
RED_PROVIDER_MARK="$T/red-merge-provider-ran"
touch "$WT28/RED"
"$TICK" spawn-lane merge-29 --no-tick --pregate logic --cwd "$WT28" -- \
    touch "$RED_PROVIDER_MARK" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/merge-29.rc" ] && break; sleep 0.1; done
if [ ! -f "$RED_PROVIDER_MARK" ] \
   && [ "$(cat "$LOOM_HOME/lanes/merge-29.rc" 2>/dev/null)" = 9 ]; then
    ok "merge preflight: a red host gate suppresses the provider as an ordinary merge failure"
else
    bad "merge preflight: red host gate ran the provider or became a gate rejection"
fi
rm -f "$WT28/RED"
reap_lanes

# B2. A human can ask Loom to advance the merge queue from inside an
# interactive Codex turn. That host process is ephemeral: a child detached
# directly from it is reaped when the tool call returns, even if its lane
# bookkeeping was written first. Keep the fast decision, but defer the worker
# launch to the durable scheduler boundary.
printf 'must arrive only at host launch\n' > "$LOOM_REPO/base-after-staging.txt"
git -C "$LOOM_REPO" add base-after-staging.txt
git -C "$LOOM_REPO" commit -qm 'move base before deferred staging'
git -C "$LOOM_REPO" push -q origin main
CODEX_THREAD_ID=interactive-codex GLAB_CMD="$FX/glab-stub.sh" \
    "$TICK" chain-merge >/dev/null 2>&1
queued_merge=$(find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
    -type d -name 'request-*' -exec sh -c \
    '[ "$(cat "$1/id" 2>/dev/null)" = merge-28 ] && printf "%s\n" "$1"' _ {} \; | head -1)
if [ -n "$queued_merge" ] && [ ! -e "$LOOM_HOME/lanes/merge-28.pid" ]; then
    ok "chain-merge: interactive Codex defers the worker to the durable host queue"
else
    bad "chain-merge: interactive Codex launched a disposable worker instead of queuing it"
fi
if [ ! -e "$WT28/base-after-staging.txt" ]; then
    ok "merge preflight: staging a deferred provider brief does not execute reconcile"
else
    bad "merge preflight: the provider brief executed reconcile while it was being staged"
fi
rm -rf "$LOOM_HOME/lane-launch-queue"/request-*
reap_lanes

# D-TICK-35's other deterministic successor has the same clean-shell seam.
# With no inherited provider, a manual chain-merge recovers the canonical
# Build provider and freezes it into the durable host request.
CODEX_THREAD_ID=interactive-codex GLAB_CMD="$FX/glab-stub.sh" \
  LOOM_PROVIDER= LOOM_SKIP_PROVIDER_CHECK= "$TICK" chain-merge >/dev/null 2>&1
manual_merge=$(find "$LOOM_HOME/lane-launch-queue" -mindepth 1 -maxdepth 1 \
    -type d -name 'request-*' -exec sh -c \
    '[ "$(cat "$1/id" 2>/dev/null)" = merge-28 ] && printf "%s\n" "$1"' _ {} \; | head -1)
if [ -n "$manual_merge" ] \
   && [ "$(cat "$manual_merge/provider" 2>/dev/null)" = claude ]; then
    ok "chain-merge: manual resume recovers the canonical Build provider"
else
    bad "chain-merge: manual resume lost the canonical Build provider"
fi
rm -rf "$LOOM_HOME/lane-launch-queue"/request-*
reap_lanes

# --- C. fallback: an empty queue still fires the ordinary wave -------------

cat > "$FX/open.json" <<'EOF'
[{"iid":1,"title":"Build 9","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],"description":"noise"}]
EOF
WAVE_MARK_C="$T/wave-fired-c"
GLAB_CMD="$FX/glab-stub.sh" LOOM_WAVE_CMD="touch $WAVE_MARK_C" \
    "$TICK" spawn-lane merge-24 --merge-lock --cwd "$LOOM_REPO" -- true >/dev/null
for _ in $(seq 1 60); do [ -f "$WAVE_MARK_C" ] && break; sleep 0.1; done
[ -f "$WAVE_MARK_C" ] \
    && ok "chain-merge-violation: an empty queue falls back to firing the wave" \
    || bad "chain-merge: empty queue neither chained nor fired a wave — the build would stall"
[ -f "$LOOM_HOME/lanes/merge-30.pid" ] \
    && bad "chain-merge: a ticket was chained from a queue fixture holding none" \
    || ok "chain-merge: nothing spawned from an empty queue"
reap_lanes

# C2. D-TICK-28: launchd owns the exiting lane's whole process group. The
# outer epilogue supervises chain-merge, but an empty/declined fast path used
# to background its fallback tick one level deeper. chain-merge then returned,
# launchd reaped that grandchild, and the build waited for the timer. At the
# public verb seam, a launchd epilogue must not return until its fallback wave
# has completed. A delayed mark distinguishes supervision from a child that is
# merely started before the parent exits.
WAVE_MARK_C2="$T/wave-fired-c2"
start_c2=$(date +%s)
GLAB_CMD="$FX/glab-stub.sh" LOOM_WAVE_CMD="sleep 1; touch $WAVE_MARK_C2" \
  LOOM_LANE_ID=gate-208 LOOM_LANE_EPILOGUE=1 LOOM_LANE_LAUNCHER=launchd \
  "$TICK" chain-merge >/dev/null 2>&1
end_c2=$(date +%s)
if [ -f "$WAVE_MARK_C2" ] && [ "$((end_c2 - start_c2))" -ge 1 ]; then
    ok "chain-merge: launchd supervises a declined fast path through the fallback wave"
else
    bad "chain-merge: launchd epilogue returned before its nested fallback wave completed"
fi
reap_lanes

# Planted violation: remove only the launchd supervision branch from a private
# copy. The same public command must again return before the delayed mark,
# proving the assertion above is held by that lifecycle guard.
MUT35=$(mirror_scripts "$T/mut35")
sed -i.bak 's/if \[ "${LOOM_LANE_LAUNCHER:-}" = launchd \]; then/if false; then/' "$MUT35/tick.sh"
WAVE_MARK_C2_MUT="$T/wave-fired-c2-mut"
GLAB_CMD="$FX/glab-stub.sh" LOOM_WAVE_CMD="sleep 1; touch $WAVE_MARK_C2_MUT" \
  LOOM_LANE_ID=gate-208 LOOM_LANE_EPILOGUE=1 LOOM_LANE_LAUNCHER=launchd \
  "$MUT35/tick.sh" chain-merge >/dev/null 2>&1
if [ ! -f "$WAVE_MARK_C2_MUT" ]; then
    ok "chain-merge-violation: backgrounding the nested launchd fallback recreates the lost handoff"
else
    bad "chain-merge-violation: the planted background fallback remained supervised"
fi
for _ in $(seq 1 30); do [ -f "$WAVE_MARK_C2_MUT" ] && break; sleep 0.1; done
reap_lanes

# --- D. fallback: a queue head with no checked-out worktree also falls back,
#     rather than spawning a merge lane with nowhere to run -----------------

cat > "$FX/open.json" <<'EOF'
[{"iid":1,"title":"Build 9","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],"description":"noise"},
 {"iid":50,"title":"No worktree for this one","project_id":1,"web_url":"https://x/50",
  "labels":["build-9","merge-queue","tier::logic"],"assignees":[]}]
EOF
cat > "$FX/mrs-50.json" <<'EOF'
[{"iid":103,"title":"t50","state":"opened","draft":false,"web_url":"https://x/mr/103","source_branch":"ticket-50-never-checked-out","sha":"ccccccc"}]
EOF
echo '[]' > "$FX/notes-50.json"
WAVE_MARK_D="$T/wave-fired-d"
GLAB_CMD="$FX/glab-stub.sh" LOOM_WAVE_CMD="touch $WAVE_MARK_D" \
    "$TICK" spawn-lane merge-24 --merge-lock --cwd "$LOOM_REPO" -- true >/dev/null
for _ in $(seq 1 60); do [ -f "$WAVE_MARK_D" ] && break; sleep 0.1; done
[ -f "$WAVE_MARK_D" ] \
    && ok "chain-merge-violation: a queue head with no worktree falls back to the wave" \
    || bad "chain-merge: an unresolvable worktree neither chained nor fell back"
[ -f "$LOOM_HOME/lanes/merge-50.pid" ] \
    && bad "chain-merge: a merge lane spawned with no worktree to run in" \
    || ok "chain-merge: no lane spawned for a branch with no worktree"
reap_lanes

# --- E. D-TICK-13: the exiting lane died on the ACCOUNT's usage limit, not on
#     its own work — so the successor must not spend ------------------------
#     Live failure (triggers-api build-2, ticket #83): merge-83's session was
#     killed in ~5s, its epilogue recorded rc 1 (schema-identical to a crash)
#     and chained, and the identical lane was respawned into the same wall
#     eight times in 47 seconds. Nothing paced it: the pause is written only by
#     the two WAVE attempts, so `_usage_gate` had nothing to gate on and the
#     ticker showed a crash loop. The queue fixture here is the one scenario B
#     chained through, so the only difference is what the lane said on its way
#     out.
LIMIT_CMD='echo "You'"'"'ve hit your usage limit"; exit 1'
cat > "$FX/open.json" <<'EOF'
[{"iid":1,"title":"Build 9","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],"description":"noise"},
 {"iid":28,"title":"Second in queue's blocker","project_id":1,"web_url":"https://x/28",
  "labels":["build-9","merge-queue","tier::logic"],"assignees":[],"updated_at":"2026-08-10T02:00:00Z"}]
EOF
WAVE_MARK_E="$T/wave-fired-e"
rm -f "$LOOM_HOME/usage.pause"
GLAB_CMD="$FX/glab-stub.sh" LOOM_WAVE_CMD="touch $WAVE_MARK_E" \
    "$TICK" spawn-lane merge-24 --merge-lock --cwd "$LOOM_REPO" -- sh -c "$LIMIT_CMD" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/usage.pause" ] && break; sleep 0.1; done
at=$(cat "$LOOM_HOME/usage.pause" 2>/dev/null || echo 0)
[ "$at" -gt "$(date +%s)" ] 2>/dev/null \
    && ok "chain-merge: a lane killed by the usage limit pauses the build from its own exit" \
    || bad "chain-merge: lane-side limit wrote pause '$at' — nothing gates the successor"
sleep 0.5   # settle: prove nothing follows, not just that nothing has yet
[ -f "$LOOM_HOME/lanes/merge-28.pid" ] \
    && bad "chain-merge: the fast path respawned a merge lane into a live usage limit" \
    || ok "chain-merge: no successor lane spawned while the usage limit is up"
[ -f "$WAVE_MARK_E" ] \
    && bad "chain-merge: a wave was spent under a usage limit the lane already proved" \
    || ok "chain-merge: no wave spent either — the pause is honoured by both successors"
jq -e 'select(.ev=="usage_pause" and .source=="lane-merge-24")' "$LOOM_HOME/events.jsonl" >/dev/null 2>&1 \
    && ok "chain-merge: the pause is recorded as the LANE's, so the ticker can tell it from a crash" \
    || bad "chain-merge: no usage_pause event naming the lane — a busy-loop still reads as a crash loop"
reap_lanes

# F. The other successor: a non-merge lane chains through `tick --from-lane`,
#    which ignores min_wave_gap_minutes on purpose. Same limit, same refusal —
#    the gap timer is not what stops this, the pause is.
WAVE_MARK_F="$T/wave-fired-f"
rm -f "$LOOM_HOME/usage.pause"
GLAB_CMD="$FX/glab-stub.sh" LOOM_WAVE_CMD="touch $WAVE_MARK_F" \
    "$TICK" spawn-lane impl-24 --cwd "$LOOM_REPO" -- sh -c "$LIMIT_CMD" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/usage.pause" ] && break; sleep 0.1; done
sleep 0.5
[ -f "$LOOM_HOME/usage.pause" ] \
    && ok "from-lane: a limit met by any lane kind pauses before the handoff wave" \
    || bad "from-lane: the lane's own limit left no pause, so the wave ran blind"
[ -f "$WAVE_MARK_F" ] \
    && bad "from-lane: the handoff wave spent a session under the lane's own usage limit" \
    || ok "from-lane: the handoff wave is gated by the pause its lane wrote"
rm -f "$LOOM_HOME/usage.pause"
reap_lanes

test_finish
