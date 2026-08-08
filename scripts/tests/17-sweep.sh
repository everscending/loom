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

test_finish
