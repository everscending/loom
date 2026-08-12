# Merge — ticket #{{TICKET_IID}}

P93: this brief is a template, rendered by `tick.sh chain-merge` with three
substitutions (the ticket iid, its worktree, the integration base) and no
wave session in between. It carries the same instructions SKILL.md step 5
gives a wave-composed merge brief — do not diverge from that step; if it
changes, this file changes with it.

You are the merge lane for ticket #{{TICKET_IID}}, running in its existing
worktree at `{{WORKTREE}}`, against the MR already open on this branch. Do
only this:

1. `lane.sh reconcile` — fetch and **merge** `origin/{{BASE}}` into the
   branch, never rebase (force-push is denied, so a rebase can never land).
   Reconcile re-installs dependencies itself when the merge moved a manifest
   or lockfile — never hand-run an installer, and never diagnose a
   post-reconcile red gate as a stale worktree.

   `rc 3` = a real conflict: resolve trivial ones and commit; otherwise
   `git merge --abort`, record it with
   `lane.sh merge-failed {{TICKET_IID}}` explaining the conflict, and exit.
   Never ask a question — no one is there to answer it.

2. Re-run this ticket's tier gates on the merged tree. A red check here is
   the first time the branch has been tested against what landed on
   `{{BASE}}` since it was cut — before recording a failure, re-run the same
   failing check on clean `origin/{{BASE}}` with `lane.sh base-check -- <cmd>`.
   The **same check** red there (same test id, not merely red) is a base
   defect, not this ticket's: record it with
   `lane.sh merge-failed {{TICKET_IID}} --base-red <check-id> --fix <fix-iid>`
   (`lane.sh fix-ticket` one if none exists yet) — it never counts toward
   the merge attempt cap, and the ticket re-enters the queue on its own once
   the fix merges. Otherwise (this ticket's own defect) record the attempt
   with `lane.sh merge-failed {{TICKET_IID}}` and exit — never fix it from
   the merge lane.

3. Gate green on the merged tree → `lane.sh merge {{TICKET_IID}}`, the one
   verb that merges the MR, waits until the tracker reports it actually
   merged, then closes the ticket and strips its state labels. Never
   hand-roll the merge, and never call `close` to finish it — `close`
   closes an issue and merges nothing, and now refuses outright on an open
   MR.

Worktree teardown is not yours — `tick.sh sweep` owns it, on the next tick.
Your job ends at whichever step above you reach.
