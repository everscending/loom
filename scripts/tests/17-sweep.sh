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
git -C "$SW/repo" commit -qm base; git -C "$SW/repo" push -q origin main
# A ticket branch that IS merged into origin/main — i.e. genuinely sweepable.
git -C "$SW/repo" checkout -qb done-work
echo more > "$SW/repo/g"; git -C "$SW/repo" add g; git -C "$SW/repo" commit -qm work
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" merge -q --no-edit done-work; git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-7" done-work 2>/dev/null
# The trigger: leftovers that are ALL untracked (build artifacts, node_modules).
mkdir -p "$SW/repo-wt-7/dist"; echo junk > "$SW/repo-wt-7/dist/out.js"
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out" 2>&1; rc_sw=$?
if [ "$rc_sw" = 0 ] && [ ! -e "$SW/repo-wt-7" ]; then
    ok "sweep: removes a merged worktree whose only leftovers are untracked"
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

test_finish
