# `mend` — contract-grounded build supervision

Human-run during phase 6. **A wave never runs this.** `mend` observes and
repairs the build machinery while the ordinary scheduler remains the sole
owner of scheduling. It never starts or resumes a stopped build; only the
human-facing `start` verb can do that.

Use `/loom mend` for the continuing supervisory loop, `/loom mend --once` for
one inspection/repair pass, or `/loom mend --observe-only` for a pass that
reports findings without changing repositories, tracker state, or lane state.
The default verb stays attached to the build. A status request is an update
inside that loop, not a reason to end it.

## Normative contract

Judge behavior against sources that already own it, in this order:

1. `SKILL.md` constitution, phase-6 scheduling, and failure policy.
2. `references/scheduling.md`, `references/build-controls.md`, and
   `references/loom-config.md` for timing, controls, admission, and caps.
3. A fresh tracker-backed `snapshot` and its deterministic `plan` for the
   current build. The tracker remains the only mutable build state.
4. Public tests and immutable lane artifacts as evidence that an
   implementation satisfies the contract.

`improvements-todo.md` is an operational ledger, not a source of truth. Never
change Loom policy merely to make a ledger item pass. When desired behavior is
not owned by one of the sources above, mark the item `NEEDS DECISION` and ask
the human to choose before implementing it.

## Start every pass from one document

Run:

```sh
scripts/tick.sh mend-status
```

This read-only command composes a fresh snapshot and plan into one compact
JSON document. It surfaces stopped state, caps, active lanes and leases,
scheduled/deferred work, tracker warnings, partial transitions, stale lanes,
blocked tickets, and tickets at the rejection cap. It is evidence, not a
second scheduler. Do not infer a competing schedule from logs, pane layout,
or cached local branches. Refresh it after every write made during a mend
pass.

## Invariants

Classify every finding against at least one stable invariant. Cite its ID in
the ledger and in repair evidence.

- `MEND-STATE-01` — tracker state is canonical; snapshot/plan are derived;
  local files hold only runtime plumbing; partial transitions are repaired.
- `MEND-CHAIN-01` — implementation → gate → merge chaining is a fast path;
  durable heartbeat recovery must make every missed handoff eventually move.
- `MEND-FLOW-01` — a running build with zero active lanes and a non-empty
  deterministic plan has an actionable idle gap. Keep supervision attached
  until the scheduler starts that work or the missed handoff/heartbeat is
  diagnosed and repaired. An armed timer is recovery plumbing, not progress.
- `MEND-LEARN-01` — every confirmed avoidable progress gap feeds back into
  Loom itself: preserve the live evidence, establish a public reproduction,
  repair the provider-neutral owning seam, and add regression plus planted
  mutation coverage. A one-off ticket nudge is not completion of mend.
- `MEND-HEAD-01` — gates and merges use the exact immutable MR head, correct
  tier, complete active scope, and a verdict attributed to that head.
- `MEND-ADMIT-01` — implementation and auxiliary caps, UI serialization,
  reservations, and duplicate suppression hold across direct and queued paths.
- `MEND-LIVE-01` — liveness, progress, cleanup, worktree preservation, and
  stale detection agree; no dead ownership can strand future work.
- `MEND-HOLD-01` — stop markers, blocked reports, scope resets, supervised
  leases, and human decisions are honored before launch and at the spawn seam.
- `MEND-ROUND-01` — a ticket reaching the configured rejection cap gets
  supervised diagnosis; it is not blindly retried for another round.
- `MEND-CLASS-01` — product defects, ticket-test defects, shared test
  infrastructure, Loom core, provider adapters, configuration, and expected
  deferrals are distinguished before choosing an owner or action.
- `MEND-COMPLETE-01` — epic completion follows its acceptance probe and
  tracker contract; ticket closure alone is not substituted for acceptance.
- `MEND-COMPAT-01` — scheduling and state semantics remain agent-agnostic.
  Claude direct launch and Codex durable launch must converge at shared core
  boundaries; provider-specific flags and permissions stay in adapters.

## The supervisory loop

1. Read `mend-status`. Honor `loop.stopped` as an intentional control, not a
   defect. Observe already-running lanes, but do not chain or schedule new work
   while stopped.
2. Let healthy work progress. Use configured heartbeat, wave-gap, rejection,
   crash, and cap values rather than ad-hoc elapsed-time guesses. Silence is a
   finding only after the owner has exceeded its declared liveness boundary.
   When `mend-status` reports `actionable-idle`, do not end the mend turn or
   describe the build as merely "armed." Keep a bounded wait through the next
   lane handoff or 60-second scheduler heartbeat, refresh, and confirm the
   planned action started. A wave-gap may explain an initial timer delay, but
   it never makes runnable work a terminal mend state; lane completion is
   specified to bypass that gap. If the action is still idle past its owning
   boundary, inspect the durable request, `tick_skipped` event, pending replay,
   and host epilogue, then establish a public RED reproduction and repair the
   shared scheduler seam. Do not launch the action by hand: scheduler ownership
   remains intact.
   Two known examples are structural contracts, not ad-hoc exceptions:
   durable post-wave cleanup requests one immediate replay from the resulting
   lane state; cleanup inherited by the next heartbeat admits that heartbeat
   past the old wave gap. An `orch-base-stale` decision at the current MR HEAD routes
   the ticket to implementation reconciliation instead of the generic
   MR-open repair back to review.
3. Inspect every `attention` item and any plan residue. Correlate it with the
   immutable lane head/log and current tracker state. Confirm the failure at a
   public seam before calling it a defect.
4. Classify ownership using `MEND-CLASS-01`. Expected cap deferral, dependency
   waiting, deliberate stop, and an active supervised lease are healthy states.
5. For a ticket intervention, acquire `tick.sh supervise acquire <iid>
   --owner <id>` before tracker reconciliation or branch work, then release it
   in all terminal paths. At the rejection cap, diagnose the sequence and give
   the ticket direct help. Use `verdict-reset`, replacement `rescope`, additive
   `rescope --extend`, or `supervised-repair` only when its documented semantics
   match the evidence; never erase a valid product rejection as infrastructure.
6. For a confirmed Loom defect, establish RED at the public provider-neutral
   seam in an isolated worktree. Make the smallest complete shared-core fix.
   If launch behavior changes, prove both Claude direct and Codex durable paths
   while leaving adapters unchanged unless the defect is truly adapter-owned.
   Run focused and adjacent tests, syntax/static checks, the full suite, and an
   applicable planted mutation. Commit and push each verified fix before
   beginning the next one. Deploy a live runtime change only by a syntax-tested
   atomic integration while no lane can read a partially updated skill.
   This feedback step is part of the default mend outcome under
   `MEND-LEARN-01`; do not stop after making the current build move if the same
   gap can recur on its next ticket or in another repository.
7. For an inefficiency, record the measured cost and a falsifiable expected
   improvement. A narrative without a number is not an actionable optimization.
8. Update `improvements-todo.md` after each meaningful transition. Use
   `TODO`, `IN PROGRESS`, `BLOCKED`, `NEEDS DECISION`, or `DONE`; include the
   invariant, evidence, verification, and commit when applicable. Keep only one
   writer for the ledger. Independent subagents may investigate disjoint
   tickets or files, but must not overlap runtime or ledger edits.
9. Refresh `mend-status` and continue until the build completes, the human
   stops it, `--once` finishes, or a missing authority/external prerequisite
   prevents all remaining progress and requires a human decision. Do not
   return a final response merely because no lane is visible, a wave gap is in
   force, one ticket is held, or the human asks for status while other work is
   runnable. Use the environment's wait/monitor mechanism, report meaningful
   transitions and decisions, and suppress unchanged polling noise. *(paid:
   Patient Imaging Portal Build JOR-267 — mend returned "loop armed" with zero
   lanes while the deterministic plan already contained the next UI gate; the
   human had to ask whether supervision was doing anything.)*

## Safety boundary

`mend` may perform normal, reversible repairs that are already authorized by
the active build and the contract above. It does not widen ticket scope,
change lane caps, weaken gates, grant provider permissions, resume a stopped
loop, or reinterpret acceptance criteria without explicit human authority.
When one of those choices is required, preserve the evidence, mark the ledger
item `NEEDS DECISION`, and stop that repair path while unrelated healthy work
continues.
