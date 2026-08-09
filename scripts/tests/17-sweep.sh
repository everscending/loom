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


test_finish
