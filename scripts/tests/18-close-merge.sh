#!/usr/bin/env bash
# a ticket must never close over its own unmerged MR
#
# Section 18 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- close/merge: a ticket must never close over its own unmerged MR --------
# merge-1 ran reconcile, ran the gate, ran `lane.sh close 1` and reported
# "merged and closed" — but nothing merged MR !1, and four downstream lanes
# were seconds from branching off a base without the work in it (2026-08-03).
MG="$T/mergeverb"; mkdir -p "$MG"
cat > "$MG/glab-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"issues/41/closed_by"*) echo '[{"iid":9,"state":"opened"}]' ;;
  *"issues/42/closed_by"*) echo '[]' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$MG/glab-stub.sh"
GLAB_CMD="$MG/glab-stub.sh" STUB_LOG="$MG/calls" "$LANE" close 41 >"$MG/out" 2>&1; rc_cl=$?
if [ "$rc_cl" != 0 ] && grep -q 'unmerged MR !9' "$MG/out" \
   && ! grep -q 'state_event=close' "$MG/calls"; then
    ok "close: refuses to close over an unmerged MR, and writes nothing"
else
    bad "close: rc=$rc_cl, out=$(head -1 "$MG/out")"
fi
# `closed_by`, not `related_merge_requests`: the latter lists any MR that merely
# MENTIONS the issue — on this very build, issue #1 listed #21's open MR next to
# its own, so "merge the first open one" would have merged the wrong branch.
if grep -q 'closed_by' "$MG/calls" && ! grep -q 'related_merge_requests' "$MG/calls"; then
    ok "close: asks closed_by, never the looser related_merge_requests"
else
    bad "close: wrong MR-lookup endpoint ($(head -1 "$MG/calls"))"
fi
: > "$MG/calls"
GLAB_CMD="$MG/glab-stub.sh" STUB_LOG="$MG/calls" "$LANE" merge 42 >"$MG/out2" 2>&1; rc_mg=$?
if [ "$rc_mg" != 0 ] && grep -q "Closes #42" "$MG/out2" \
   && ! grep -q '/merge' "$MG/calls"; then
    ok "merge: refuses when no open MR closes the issue"
else
    bad "merge: rc=$rc_mg, out=$(head -1 "$MG/out2")"
fi

# --- P84: the merge deletes its own source branch --------------------------
# Nothing in the loop ever deleted a branch. Sweep's `git branch -d` fires only
# as a side effect of removing a worktree and covers the local side alone, so
# five builds left 51 local ticket-* branches. The remote stayed clean only
# because that project happened to set remove_source_branch_after_merge — a
# per-project setting this skill neither reads nor writes.
P84="$T/p84"; mkdir -p "$P84"
cat > "$P84/glab-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"issues/84/closed_by"*)        echo '[{"iid":84,"state":"opened"}]' ;;
  *"merge_requests/84/merge"*)    echo '{}' ;;
  *"merge_requests/84")           echo '{"state":"merged"}' ;;
  *"issues/84")                   echo '{"iid":84,"state":"opened","labels":["build-1","merge-queue"]}' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$P84/glab-stub.sh"
: > "$P84/calls"
GLAB_CMD="$P84/glab-stub.sh" STUB_LOG="$P84/calls" "$LANE" merge 84 >"$P84/out" 2>&1 || true
mergeline=$(grep -- '/merge' "$P84/calls" | head -1)
case "$mergeline" in
    *should_remove_source_branch=true*) ok "P84: the merge call asks GitLab to delete the source branch" ;;
    *) bad "P84: merge issued without should_remove_source_branch ($mergeline)" ;;
esac
# On the merge, and on nothing else — a flag that leaked onto the verification
# read or the close would be a different request than the one it was argued for.
others=$(grep -c 'should_remove_source_branch' "$P84/calls" 2>/dev/null || echo 0)
[ "$others" = 1 ] \
    && ok "P84: the flag rides the merge request alone" \
    || bad "P84: should_remove_source_branch appears on $others calls, not 1"

# --- P84: sweep's fetch prunes ---------------------------------------------
# Without --prune a remote-tracking ref outlives the branch it tracks forever.
# Five builds left 122 stale origin/ticket-* refs, which is also what made the
# remote LOOK like it held 122 branches when ls-remote said 3.
PR="$T/p84prune"; mkdir -p "$PR"
git -c init.defaultBranch=main init -q --bare "$PR/origin.git"
git clone -q "$PR/origin.git" "$PR/repo" 2>/dev/null
git -C "$PR/repo" config user.email t@t; git -C "$PR/repo" config user.name t
echo x > "$PR/repo/f"; git -C "$PR/repo" add f; git -C "$PR/repo" commit -qm base
git -C "$PR/repo" push -q origin main
git -C "$PR/repo" push -q origin main:refs/heads/ticket-99-gone
git -C "$PR/repo" fetch -q origin
# Delete it SERVER-side. `git push --delete` would update this clone's tracking
# ref as a side effect, and the ref would never be stale — which is the state
# the fixture exists to produce.
git -C "$PR/origin.git" update-ref -d refs/heads/ticket-99-gone
git -C "$PR/repo" branch -r --list 'origin/ticket-99-gone' | grep -q . \
    && ok "P84-setup: the tracking ref outlives the deleted remote branch" \
    || bad "P84-setup: fixture never created a stale tracking ref"
LOOM_REPO="$PR/repo" LOOM_HOME="$PR/home" "$TICK" sweep >/dev/null 2>&1
git -C "$PR/repo" branch -r --list 'origin/ticket-99-gone' | grep -q . \
    && bad "P84: sweep's fetch left the stale tracking ref in place" \
    || ok "P84: sweep's fetch prunes a tracking ref whose branch the server deleted"


test_finish
