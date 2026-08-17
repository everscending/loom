#!/usr/bin/env bash
# the merged-worktree teardown that had never once succeeded
#
# Section 17 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- sweep: the merged-worktree teardown that had never once succeeded ------
# `st=$(git status --porcelain | grep -v '^??' | head -1)` exits 1 whenever the
# grep filters out every line, and under `set -euo pipefail` that killed the
# whole sweep silently (rc=1) before removing anything. A merged worktree whose
# only leftovers are untracked files is the COMMON case, so sweep never worked:
# merged worktrees accumulated and a wave removed one by hand (2026-08-03).
SW="$T/sweep"; mkdir -p "$SW"
# P83: sweep now asks the tracker whether THIS BRANCH's own MR merged, so the
# section needs a glab that answers without a network. Default: no branch has a
# merged MR, which drops every existing case back onto the commit-range test and
# is exactly the old behaviour. $SWEEP_MERGED names the branches that did merge.
cat > "$SW/glab-stub.sh" <<'GLABEOF'
#!/usr/bin/env bash
q=""; for a in "$@"; do case "$a" in *source_branch=*) q="$a" ;; esac; done
br="${q##*source_branch=}"; br="${br%%&*}"
if [ -n "${SWEEP_MERGED:-}" ] && printf '%s' " $SWEEP_MERGED " | grep -q " $br "; then
    printf '[{"iid":1,"state":"merged","source_branch":"%s"}]\n' "$br"
else
    printf '[]\n'
fi
GLABEOF
chmod +x "$SW/glab-stub.sh"
export GLAB_CMD="$SW/glab-stub.sh"
git -c init.defaultBranch=main init -q --bare "$SW/origin.git"
git clone -q "$SW/origin.git" "$SW/repo" 2>/dev/null
git -C "$SW/repo" config user.email t@t; git -C "$SW/repo" config user.name t
echo base > "$SW/repo/f"; git -C "$SW/repo" add f
# The debris the sweep is FOR is debris git already ignores — node_modules, a
# .venv, a build dir. Ignoring it here is what makes the untracked-work case
# below distinguishable from it (D-TICK-17).
printf 'dist/\nlocked/\n' > "$SW/repo/.gitignore"; git -C "$SW/repo" add .gitignore
git -C "$SW/repo" commit -qm base; git -C "$SW/repo" push -q origin main
# A ticket branch that IS merged into origin/main — i.e. genuinely sweepable.
git -C "$SW/repo" checkout -qb done-work
echo more > "$SW/repo/g"; git -C "$SW/repo" add g; git -C "$SW/repo" commit -qm work
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" merge -q --no-edit done-work; git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-7" done-work 2>/dev/null
# The trigger: leftovers that are ALL ignored (build artifacts, node_modules).
mkdir -p "$SW/repo-wt-7/dist"; echo junk > "$SW/repo-wt-7/dist/out.js"
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out" 2>&1; rc_sw=$?
if [ "$rc_sw" = 0 ] && [ ! -e "$SW/repo-wt-7" ]; then
    ok "sweep: removes a merged worktree whose only leftovers are ignored"
else
    bad "sweep: rc=$rc_sw, worktree still present=$([ -e "$SW/repo-wt-7" ] && echo yes || echo no) ($(head -1 "$SW/out"))"
fi

# New Loom worktrees are nested under the writable main clone. Sweep must own
# those paths while retaining compatibility with legacy sibling worktrees.
git -C "$SW/repo" checkout -qb done-work-nested main
echo nested > "$SW/repo/nested"; git -C "$SW/repo" add nested; git -C "$SW/repo" commit -qm nested
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" merge -q --no-edit done-work-nested; git -C "$SW/repo" push -q origin main
mkdir -p "$SW/repo/.worktrees"
git -C "$SW/repo" worktree add -q "$SW/repo/.worktrees/11" done-work-nested 2>/dev/null
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out-nested" 2>&1
if [ ! -e "$SW/repo/.worktrees/11" ]; then
    ok "sweep: removes a merged nested .worktrees lane"
else
    bad "sweep: left a merged nested .worktrees lane behind"
fi

# A provider-backed worker can be durably queued after its worktree is
# prepared but before any process exists there. The queued cwd is already
# committed launch ownership; sweep must preserve it through that host gap.
git -C "$SW/repo" worktree add -q "$SW/repo/.worktrees/240" -b loom-240 origin/main 2>/dev/null
printf 'queued implementation\n' > "$SW/queued-brief.md"
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/queued-home" LOOM_DEFER_LANE_LAUNCH=1 \
  "$TICK" spawn-lane impl-240 --no-tick --provider codex --job implementation \
  --tier medium --brief "$SW/queued-brief.md" --cwd "$SW/repo/.worktrees/240" >/dev/null
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/queued-home" "$TICK" sweep >"$SW/out-queued" 2>&1
if [ -d "$SW/repo/.worktrees/240" ] \
   && find "$SW/queued-home/lane-launch-queue" -name 'request-*impl-240' -type d 2>/dev/null | grep -q .; then
    ok "sweep: preserves a prepared worktree owned by a durable lane request"
else
    bad "sweep: deleted a queued lane's prepared worktree before the durable host launched it"
fi
# Planted violation: keep live-process protection but remove queued-cwd
# ownership from a private copy. The same public sweep must delete the clean
# prepared checkout again, proving the durable request guard carries the fix.
MUT_QUEUED_SWEEP=$(mirror_scripts "$SW/mut-queued-sweep")
sed -i.bak 's@protected_cwds="$protected_cwds $queued_cwd"@protected_cwds="$protected_cwds"@' \
  "$MUT_QUEUED_SWEEP/tick.sh"
mut_queued_out=$(LOOM_REPO="$SW/repo" LOOM_HOME="$SW/queued-home" \
  "$MUT_QUEUED_SWEEP/tick.sh" sweep 2>&1); mut_queued_rc=$?
if assert_mutant_ran "$mut_queued_rc" "$mut_queued_out" "queued-worktree-violation"; then
    if [ ! -e "$SW/repo/.worktrees/240" ] \
       && printf '%s' "$mut_queued_out" | grep -q 'removed merged worktree'; then
        ok "sweep-violation: dropping queued cwd ownership recreates the pre-launch deletion"
    else
        bad "sweep-violation: planted queued-cwd omission did not recreate deletion (rc=$mut_queued_rc)"
    fi
fi
# The safety boundary: unmerged work is never ours to delete. Fixing the crash
# above ARMED a deletion path that had never executed, so prove it still stops.
git -C "$SW/repo" checkout -qb live-work origin/main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-8" -b wip origin/main 2>/dev/null
echo wip > "$SW/repo-wt-8/new.txt"
git -C "$SW/repo-wt-8" add new.txt
git -C "$SW/repo-wt-8" -c user.email=t@t -c user.name=t commit -qm wip
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
if [ -e "$SW/repo-wt-8" ]; then
    ok "sweep: keeps a worktree holding unmerged commits"
else
    bad "sweep: deleted a worktree with unmerged work"
fi

# P46: a `stale` lane is alive but silent, not gone — filtering the live-cwd
# guard on `running` alone let it fall through, and a lane that had not yet
# committed (indistinguishable from merged work, its new files untracked) was
# seconds from `rm -rf` under its own live process. Same merged-branch setup as
# repo-wt-7, but this worktree holds a REAL process the status reads `stale`.
git -C "$SW/repo" checkout -qb done-work-2 main
echo more2 > "$SW/repo/h"; git -C "$SW/repo" add h; git -C "$SW/repo" commit -qm work2
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" merge -q --no-edit done-work-2; git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-9" done-work-2 2>/dev/null
printf 'heartbeat_stale_minutes: 0\n' > "$SW/repo/.loom.yml"
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" spawn-lane impl-96 --cwd "$SW/repo-wt-9" -- sleep 20 >/dev/null
touch -t 202001010000 "$SW/home/logs/lane-impl-96.log"
st=$(LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" lane-status | awk '$1=="impl-96"{print $3}')
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out96" 2>&1
if [ "$st" = stale ] && [ -e "$SW/repo-wt-9" ]; then
    ok "sweep: a stale-but-alive lane's worktree survives (P46)"
else
    bad "sweep: stale lane's worktree mishandled (state=$st, present=$([ -e "$SW/repo-wt-9" ] && echo yes || echo no))"
fi
kill "$(cat "$SW/home/lanes/impl-96.pid" 2>/dev/null)" 2>/dev/null
rm -f "$SW/repo/.loom.yml"

# D-TICK-17: a lane's unsaved work is UNTRACKED work, and the merged path used
# to filter untracked files out before asking whether the worktree was empty.
# A lane that had not committed yet was therefore indistinguishable from a
# swept-clean merged worktree: zero commits ahead of the base, nothing modified
# among tracked files. boostlingo build-4 #98 lost ~100 turns of work that way.
# Ignored debris (dist/, above) is still debris; this file is not ignored.
git -C "$SW/repo" checkout -qb done-work-3 main
echo more3 > "$SW/repo/i"; git -C "$SW/repo" add i; git -C "$SW/repo" commit -qm work3
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" merge -q --no-edit done-work-3; git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-10" done-work-3 2>/dev/null
mkdir -p "$SW/repo-wt-10/scripts"; echo 'the instrument the ticket was built around' > "$SW/repo-wt-10/scripts/verify.mjs"
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out10" 2>&1
if [ -e "$SW/repo-wt-10/scripts/verify.mjs" ] && grep -q 'holds untracked work' "$SW/out10"; then
    ok "D-TICK-17: a merged worktree holding untracked, non-ignored work is kept"
else
    bad "D-TICK-17: untracked work swept (file present=$([ -e "$SW/repo-wt-10/scripts/verify.mjs" ] && echo yes || echo no)) — $(grep -c . "$SW/out10") line(s): $(head -2 "$SW/out10" | tr '\n' ' ')"
fi

# The two cases below need a directory git and `rm -rf` genuinely CANNOT
# remove. Permissions do not bind root, so as root there is no way to stage the
# failure at all — say so rather than assert something weaker.
if [ "$(id -u)" != 0 ]; then
    # D-TICK-17: "kept" was a promise sweep broke about sixty seconds later.
    # `worktree remove` is not atomic — it drops .git/worktrees/<name> before
    # it fails on the unreadable directory, `worktree prune` finishes that off,
    # and the next pass reads its own leftover as an orphaned corpse and
    # deletes it down a path with no ahead check and no dirty check.
    git -C "$SW/repo" checkout -qb done-work-4 main
    echo more4 > "$SW/repo/j"; git -C "$SW/repo" add j; git -C "$SW/repo" commit -qm work4
    git -C "$SW/repo" checkout -q main
    git -C "$SW/repo" merge -q --no-edit done-work-4; git -C "$SW/repo" push -q origin main
    git -C "$SW/repo" worktree add -q "$SW/repo-wt-11" done-work-4 2>/dev/null
    # Ignored, so the guard above does not fire — this worktree reaches the
    # removal exactly as wt-14 did, and the removal fails exactly as it did.
    mkdir -p "$SW/repo-wt-11/locked"; echo pinned > "$SW/repo-wt-11/locked/f"
    chmod 500 "$SW/repo-wt-11/locked"
    LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out11" 2>&1
    if [ -e "$SW/repo-wt-11" ] && [ -f "$SW/repo-wt-11/.loom-sweep-hold" ] && grep -q 'refused to remove' "$SW/out11"; then
        ok "D-TICK-17: a refused removal leaves the hold marker behind"
    else
        bad "D-TICK-17: no hold marker after a refused removal ($(head -3 "$SW/out11" | tr '\n' ' '))"
    fi
    # The corpse shape the live log showed, staged exactly: the gitdir pointer
    # still in the worktree, the metadata it points at already pruned away.
    printf 'gitdir: %s/.git/worktrees/repo-wt-11\n' "$SW/repo" > "$SW/repo-wt-11/.git"
    rm -rf "$SW/repo/.git/worktrees/repo-wt-11"
    LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out11b" 2>&1
    if [ -f "$SW/repo-wt-11/locked/f" ] && grep -q 'held from an earlier failed removal' "$SW/out11b"; then
        ok "D-TICK-17: the corpse path honours the earlier pass's 'kept' instead of deleting it"
    else
        bad "D-TICK-17: the corpse path deleted what the previous pass promised to keep ($(head -3 "$SW/out11b" | tr '\n' ' '))"
    fi
    chmod 700 "$SW/repo-wt-11/locked"

    # `rm -rf`'s status was thrown away, so a partial delete printed the same
    # line as a completed one — in the one place in the program that destroys
    # work. The live log showed five `rm` failures immediately above "removed".
    git -C "$SW/repo" worktree add -q "$SW/repo-wt-12" -b done-work-5 origin/main 2>/dev/null
    mkdir -p "$SW/repo-wt-12/locked"; echo pinned > "$SW/repo-wt-12/locked/f"
    chmod 500 "$SW/repo-wt-12/locked"
    printf 'gitdir: %s/.git/worktrees/repo-wt-12\n' "$SW/repo" > "$SW/repo-wt-12/.git"
    rm -rf "$SW/repo/.git/worktrees/repo-wt-12"
    LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out12" 2>&1
    if grep -q 'could not fully remove' "$SW/out12" && ! grep -q 'removed orphaned worktree corpse .*repo-wt-12' "$SW/out12"; then
        ok "D-TICK-17: a corpse only partly deleted is reported as partly deleted"
    else
        bad "D-TICK-17: a failed corpse removal read as success ($(grep 'repo-wt-12' "$SW/out12" | head -2 | tr '\n' ' '))"
    fi
    chmod 700 "$SW/repo-wt-12/locked"
else
    echo "note: running as root — the two unremovable-directory cases cannot be staged, so they did not run"
fi

# --- P83: "merged" is a tracker fact, not a commit-range guess -------------
# `lane.sh reconcile` merges origin/<base> into the branch. Run once more after
# the push whose MR merged, the local tip carries a merge commit that was never
# pushed, so origin/<base>..<branch> is non-empty FOREVER and the worktree is
# permanently unsweepable. Fifteen of build-5's thirty held worktrees were this,
# every one showing a single unpushed reconcile merge.
# The shape that produces it: GitLab merged the MR by squash, so main carries an
# EQUIVALENT commit with a different sha, and the branch's own commit is never an
# ancestor of main. The reconcile merge is then a real merge, not a fast-forward,
# and the range is non-empty forever. (Build-5's example named both shas:
# cd520f8 the pushed tip, e583729 what landed on main.)
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" checkout -qb ticket-96-reconciled
echo p83 > "$SW/repo/p83"; git -C "$SW/repo" add p83; git -C "$SW/repo" commit -qm p83
git -C "$SW/repo" checkout -q main
echo p83 > "$SW/repo/p83"; git -C "$SW/repo" add p83
git -C "$SW/repo" commit -qm 'p83 (squashed onto main, different sha)'
git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-96" ticket-96-reconciled 2>/dev/null
git -C "$SW/repo-wt-96" -c user.email=t@t -c user.name=t merge -q --no-edit origin/main 2>/dev/null
[ -n "$(git -C "$SW/repo" log "origin/main..ticket-96-reconciled" --oneline 2>/dev/null)" ] \
    && ok "P83-setup: the reconciled branch really is ahead of base — the old test would keep it" \
    || bad "P83-setup: fixture does not reproduce the unpushed reconcile merge"
SWEEP_MERGED="ticket-96-reconciled" LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out96" 2>&1
[ ! -e "$SW/repo-wt-96" ] \
    && ok "P83: a branch whose own MR merged is swept even with an unpushed reconcile merge on top" \
    || bad "P83: the reconciled worktree survived ($(head -1 "$SW/out96"))"

# Planted violation: the identical worktree, with the tracker answering "no
# merged MR" so the commit range decides as it used to. It must be kept — that
# is the failure this proposal is about, reproduced on demand.
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" checkout -qb ticket-97-reconciled
echo p83b > "$SW/repo/p83b"; git -C "$SW/repo" add p83b; git -C "$SW/repo" commit -qm p83b
git -C "$SW/repo" checkout -q main
echo p83b > "$SW/repo/p83b"; git -C "$SW/repo" add p83b
git -C "$SW/repo" commit -qm 'p83b (squashed onto main, different sha)'
git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-97" ticket-97-reconciled 2>/dev/null
git -C "$SW/repo-wt-97" -c user.email=t@t -c user.name=t merge -q --no-edit origin/main 2>/dev/null
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
[ -e "$SW/repo-wt-97" ] \
    && ok "P83-violation: with the range deciding, the reconciled worktree is kept — the old failure" \
    || bad "P83-violation: worktree removed with no merged MR to justify it"

# THE constraint. #67 shipped as bbac984 from ticket-67-pending-turn-bound;
# ticket-67-realtime-turn-mark-pairing sat beside it with three commits and a
# 238-line variant that merged in no form. The ticket was closed and the feature
# live, so any fix keyed on TICKET state deletes this worktree and those lines —
# D-TICK-17 through another door. Nothing at sweep time separates a discarded
# draft from live work; only the branch's own merged MR may decide.
git -C "$SW/repo" worktree add -q "$SW/repo-wt-67" -b ticket-67-abandoned origin/main 2>/dev/null
echo draft > "$SW/repo-wt-67/draft.txt"; git -C "$SW/repo-wt-67" add draft.txt
git -C "$SW/repo-wt-67" -c user.email=t@t -c user.name=t commit -qm 'rejected first draft'
# the ticket's OTHER branch is the one that merged — ticket state says "closed"
SWEEP_MERGED="ticket-67-shipped" LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
if [ -e "$SW/repo-wt-67" ] && [ -f "$SW/repo-wt-67/draft.txt" ]; then
    ok "P83: a branch whose ticket closed via a DIFFERENT branch's MR is not swept"
else
    bad "P83: the abandoned #67-shape branch was deleted — ticket state reached the delete path"
fi

# An MR that was closed UNMERGED is not a merge. The query asks state=merged, so
# this is the same "no" as never having opened one — assert it, or the cheap
# variant's gap would be implied rather than recorded.
git -C "$SW/repo" worktree add -q "$SW/repo-wt-68" -b ticket-68-rejected origin/main 2>/dev/null
echo rej > "$SW/repo-wt-68/rej.txt"; git -C "$SW/repo-wt-68" add rej.txt
git -C "$SW/repo-wt-68" -c user.email=t@t -c user.name=t commit -qm 'closed unmerged'
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
[ -e "$SW/repo-wt-68" ] \
    && ok "P83: a branch whose MR was closed unmerged is not swept" \
    || bad "P83: a closed-unmerged branch was swept"

# The tracker being unreadable is not an answer. A glab that fails must drop
# sweep back to the conservative range test, never to "merged".
cat > "$SW/glab-dead.sh" <<'DEADEOF'
#!/usr/bin/env bash
echo "fatal: could not read the board" >&2; exit 1
DEADEOF
chmod +x "$SW/glab-dead.sh"
GLAB_CMD="$SW/glab-dead.sh" LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
[ -e "$SW/repo-wt-67" ] \
    && ok "P83: an unreadable tracker falls back to the range test, and keeps the work" \
    || bad "P83: a failed board read reached the delete path"


# --- P85: sweep's decisions reach a human ----------------------------------
# For five builds sweep printed "kept, needs a human" for every worktree on
# every tick — into a wave's log file, which no human reads. It emitted no
# event, so nothing reached the ticker, the pushes or the completion report,
# and build-5 tore its agent down with thirty worktrees standing, silently.
P85="$T/p85"; mkdir -p "$P85"
git -c init.defaultBranch=main init -q --bare "$P85/origin.git"
git clone -q "$P85/origin.git" "$P85/repo" 2>/dev/null
git -C "$P85/repo" config user.email t@t; git -C "$P85/repo" config user.name t
echo base > "$P85/repo/f"; git -C "$P85/repo" add f; git -C "$P85/repo" commit -qm base
git -C "$P85/repo" push -q origin main
git -C "$P85/repo" worktree add -q "$P85/repo-wt-3" -b held-work origin/main 2>/dev/null
echo unsaved > "$P85/repo-wt-3/unsaved.txt"     # untracked, not ignored — the D-TICK-17 hold
EV="$P85/home/events.jsonl"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
if grep -q '"ev":"sweep_held"' "$EV" 2>/dev/null; then
    ok "P85: a pass that keeps a worktree emits sweep_held"
else
    bad "P85: sweep kept a worktree and emitted nothing ($(tail -1 "$EV" 2>/dev/null))"
fi
grep -q '"ev":"sweep_held".*"count":1' "$EV" \
    && ok "P85: the event carries the count" \
    || bad "P85: sweep_held has no usable count ($(grep sweep_held "$EV" | head -1))"
grep -q '"reason":"untracked-work"' "$EV" \
    && ok "P85: the event names the dominant reason" \
    || bad "P85: sweep_held does not name why"
# One event per PASS, not per worktree — thirty lines a tick is not a signal.
git -C "$P85/repo" worktree add -q "$P85/repo-wt-4" -b held-work-2 origin/main 2>/dev/null
echo unsaved > "$P85/repo-wt-4/unsaved.txt"
: > "$EV"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
n=$(grep -c '"ev":"sweep_held"' "$EV" 2>/dev/null || echo 0)
[ "$n" = 1 ] && grep -q '"count":2' "$EV" \
    && ok "P85: two held worktrees produce one event carrying 2, not two events" \
    || bad "P85: $n sweep_held events for two worktrees"
# Planted violation: with the emit removed, the pane learns nothing — which is
# exactly the five-build silence this proposal is about.
sed 's/_ev sweep_held /: sweep_held /' "$TICK" > "$P85/tick-mute.sh"; chmod +x "$P85/tick-mute.sh"
: > "$EV"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$P85/tick-mute.sh" sweep >/dev/null 2>&1
grep -q '"ev":"sweep_held"' "$EV" 2>/dev/null \
    && bad "P85-violation: the muted sweep still emitted" \
    || ok "P85-violation: with the emit removed the ticker hears nothing — the old behaviour"

# D-TICK-11 is OPEN: render-events indexes on .state and silently drops any
# event without one. A sweep event that omitted it would be invisible in the
# exact pane this proposal exists to reach — so assert the RENDERED line, not
# the log line.
: > "$EV"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
out=$(LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" render-events 2>&1)
case "$out" in
    *"sweep kept"*) ok "P85: the ticker renders the hold — it survives the D-TICK-11 .state drop" ;;
    *) bad "P85: sweep_held is logged but never rendered ($(printf '%s' "$out" | tail -1))" ;;
esac
# Removals are visible too, and a clean pass says nothing at all.
: > "$EV"
rm -rf "$P85/repo-wt-3/unsaved.txt" "$P85/repo-wt-4/unsaved.txt"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
grep -q '"ev":"sweep_removed"' "$EV" \
    && ok "P85: a pass that removes says so" \
    || bad "P85: removals are still silent"
: > "$EV"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
if grep -q '"ev":"sweep_held"' "$EV" || grep -q '"ev":"sweep_removed"' "$EV"; then
    bad "P85: a sweep with nothing to do still emitted"
else
    ok "P85: a clean pass emits nothing — the count is a signal, not a heartbeat"
fi

# The completion announcement carries the inventory, because a build that
# reports complete while leaving worktrees behind is reporting on part of its
# own work. Appended by cmd_notify rather than asked of the wave.
git -C "$P85/repo" worktree add -q "$P85/repo-wt-5" -b held-work-3 origin/main 2>/dev/null
echo unsaved > "$P85/repo-wt-5/unsaved.txt"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
# The body is only observable on the push path — the no-topic fallback hands it
# to osascript and prints nothing. Give the repo a topic and record the args.
printf 'ntfy:\n  topic: p85-topic\n  push: [build_complete]\n' > "$P85/repo/.loom.yml"
cat > "$P85/ntfy-stub.sh" <<'NTFYEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${NTFY_ARGS:-/dev/null}"
NTFYEOF
chmod +x "$P85/ntfy-stub.sh"
NTFY_ARGS="$P85/ntfy-args" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" \
    NTFY_CMD="$P85/ntfy-stub.sh" "$TICK" notify build_complete "Build complete" "every ticket merged" >/dev/null 2>&1
if grep -q 'kept by sweep' "$P85/ntfy-args" 2>/dev/null; then
    ok "P85: a completion announcement names the leftover inventory"
else
    bad "P85: build_complete said nothing about the worktrees it left standing"
fi
grep -q 'repo-wt-5' "$P85/ntfy-args" 2>/dev/null \
    && ok "P85: the inventory names the worktrees, not just a number" \
    || bad "P85: the inventory carries no worktree names ($(tr '\n' ' ' < "$P85/ntfy-args" | cut -c1-120))"
rm -f "$P85/home/sweep-held.txt"
NTFY_ARGS="$P85/ntfy-args2" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" \
    NTFY_CMD="$P85/ntfy-stub.sh" "$TICK" notify build_complete "Build complete" "every ticket merged" >/dev/null 2>&1
grep -q 'kept by sweep' "$P85/ntfy-args2" 2>/dev/null \
    && bad "P85: a clean build still reported an inventory" \
    || ok "P85: with nothing held, the announcement stays quiet about it"


test_finish
