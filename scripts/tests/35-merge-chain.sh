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

# A real repo at $LOOM_REPO, one commit, so worktrees can branch off it.
# `seed_tracker_decl` (test-lib.sh) already ran `git init` + staged the
# tracker declaration; this section is the first to need a commit and a
# worktree.
git -C "$LOOM_REPO" commit -qm init >/dev/null 2>&1
# The next merge-queue ticket's worktree, a SIBLING of the repo (SKILL.md
# step 4's convention) — _worktree_for_branch reads this back by branch,
# never by the `<repo>-wt-<n>` name.
WT28="$T/repo-wt-28"
git -C "$LOOM_REPO" worktree add -q "$WT28" -b ticket-28 >/dev/null 2>&1

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
 {"iid":1,"title":"Build 9","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],"description":"noise"},
 {"iid":28,"title":"Second in queue's blocker","project_id":1,"web_url":"https://x/28",
  "labels":["build-9","merge-queue"],"assignees":[],"updated_at":"2026-08-10T02:00:00Z"},
 {"iid":30,"title":"Newer, behind 28","project_id":1,"web_url":"https://x/30",
  "labels":["build-9","merge-queue"],"assignees":[],"updated_at":"2026-08-10T03:00:00Z"}
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

# --- D. fallback: a queue head with no checked-out worktree also falls back,
#     rather than spawning a merge lane with nowhere to run -----------------

cat > "$FX/open.json" <<'EOF'
[{"iid":1,"title":"Build 9","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],"description":"noise"},
 {"iid":50,"title":"No worktree for this one","project_id":1,"web_url":"https://x/50",
  "labels":["build-9","merge-queue"],"assignees":[]}]
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
  "labels":["build-9","merge-queue"],"assignees":[],"updated_at":"2026-08-10T02:00:00Z"}]
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
