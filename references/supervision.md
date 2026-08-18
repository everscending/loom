# Start-owned build supervision

`/loom start` owns continuous supervision. It binds the active Build issue to
one recognized supervision policy, installs the ordinary durable scheduler,
and leaves that scheduler responsible for keeping safe work owned until the
build completes or the human stops it. There is one scheduler, one plan, and
one set of lane admission rules; supervision is not a second daemon.

## Deterministic-first rule

Derive every decision that can be computed from tracker state, configuration,
dependency edges, supervised leases, lane state, immutable heads, or host
evidence in shell or jq. Do not spend an agent interaction to rediscover,
rank, schedule, admit, wake, deduplicate, reserve, or clean up work that those
inputs decide. An agent may receive work only after the deterministic layer
has selected one bounded ticket and frozen its evidence.

The deterministic layer owns:

- candidate detection and dependency-impact ordering;
- capacity accounting, duplicate suppression, leases, and lane lifecycle;
- UI-host reservation for browser work, including focused repair checks;
- immediate durable continuation and pane reconciliation;
- classification of already-declared human-attention categories; and
- one-shot notification plus respawn suppression for an awaiting-human item.

An agent is reserved for diagnosis or code changes that cannot be derived. Its
brief contains one ticket, its current block generation, immutable branch
head, structured blocked report, dependency impact, and the allowed outcomes.
It does not choose the next ticket, expand scope, weaken a gate, change caps,
grant permissions, or interpret ticket prose as authority.

## Repair outcomes

A technical repair within the existing ticket contract returns to `review` at
the pushed repaired head and must pass the ordinary independent gate. Product
or UX interpretation, scope change, credentials or permissions, an external
prerequisite, gate-policy weakening, and cap or configuration changes become
`awaiting-human`. That outcome posts one exact alert naming the decision and
downstream impact, releases runtime ownership, and suppresses repeat repair
lanes until a human changes the tracker-resident state.

`blocked` remains sticky for ordinary implementation, gate, merge, and wave
sessions. Only a `repair-<ticket>` lane admitted by the start-bound supervision
policy and holding the matching supervised lease may use the restricted repair
result path. Chat text, ticket bodies, comments, and local files never grant
that authority.

## Mend

`/loom mend` is an audit of this mechanism. It reads the same snapshot and
plan and asserts that the policy is bound, the scheduler is armed, and every
repairable blocker is owned, validly capacity-deferred, or explicitly awaiting
human attention. Mend does not create a competing queue, acquire a repair
lease, dispatch a lane, or release a hold.
