# Merge — ticket #{{TICKET_IID}}

P93: this brief is a template, rendered by `tick.sh chain-merge` with three
substitutions (the ticket iid, its worktree, the integration base) and no
wave session in between. It carries the same instructions SKILL.md step 5
gives a wave-composed merge brief — do not diverge from that step; if it
changes, this file changes with it.

You are the final merge provider for ticket #{{TICKET_IID}}, running in its
existing worktree at `{{WORKTREE}}`, against the MR already open on this
branch.

Before this provider session starts, the launchd-owned host wrapper runs the
merge preflight in this same worktree: `lane.sh reconcile` fetches and merges
`origin/{{BASE}}` (never rebases), then the repository's configured ticket-tier
gate runs once on that reconciled tree. If either step is red, this provider
session never starts; the ordinary dead-merge harvest path records and
classifies that failure from the host log. This boundary is provider-neutral
and lets browser gates use host OS services that a coding-agent sandbox can
legitimately deny.

The fact that this session started is authoritative evidence that the host
preflight passed (or explicitly declared a missing-runner reduction in the
lane log). Do not reconcile again and do not rerun the configured tier gate.
Run only `lane.sh merge {{TICKET_IID}}`, the verb that merges the MR, waits
until the forge reports it actually merged, then closes the ticket and strips
its state labels. Never hand-roll the merge, and never call `close` to finish
it: `close` closes an issue and merges nothing, and refuses an open MR.

Worktree teardown is not yours — `tick.sh sweep` owns it, on the next tick.
Your job ends at whichever step above you reach.
