# `mend` — assert start-owned supervision

Human-run during phase 6. **A wave never runs this.** Continuous progress and
repair belong to the scheduler installed by `/loom start`; see
[supervision.md](supervision.md). Mend is read-only. It never starts or resumes
the loop, constructs a queue, acquires a lease, dispatches a lane, changes a
ticket, releases a hold, edits Loom, or writes the improvements ledger.

## Run the assertion

Run:

```sh
scripts/tick.sh mend-status
```

This command derives one evidence document from the same fresh snapshot and
plan the scheduler uses. Do not infer another schedule from panes, prose logs,
cached branches, or ticket instructions.

Report:

- the active Build supervision policy and whether the scheduler is armed;
- active lanes, leases, capacity, and the shared UI reservation;
- each planned repair and each valid capacity deferral;
- each ticket suppressed by `supervision::awaiting-human`;
- any ownership, lane/lease, immutable-head, continuation, or pane mismatch;
- the exact human decision or external action for every awaiting-human item,
  including the tickets waiting behind it.

`--once` returns after this assertion. `--observe-only` may refresh the same
read-only document across heartbeat boundaries and report state transitions;
it still performs no repair.

## Assertions

- `MEND-STATE-01` — tracker state is canonical; snapshot and plan are derived.
- `MEND-FLOW-01` — every runnable stage is owned, scheduled, or validly
  deferred. An armed timer alone is not ownership.
- `MEND-CHAIN-01` — a missed fast-path handoff has a durable heartbeat
  recovery disposition.
- `MEND-ADMIT-01` — worker caps, duplicate suppression, leases, and the UI
  reservation agree across direct and queued launches.
- `MEND-LIVE-01` — lane process, lease, pane, and cleanup state agree; dead
  ownership cannot strand work.
- `MEND-HOLD-01` — blocked state, block generation, supervision policy, and
  awaiting-human suppression are honored at admission.
- `MEND-HEAD-01` — gates, merges, and repaired branches use the frozen MR head
  and current active contract.
- `MEND-COMPLETE-01` — build completion includes required epic acceptance.
- `MEND-COMPAT-01` — provider adapters converge on the same deterministic host
  scheduling and admission seams.

The overall assertion is `pass` only when the loop is running, exactly one
recognized Build policy is bound, the scheduler is armed, and each repairable
blocker is scheduled, actively owned, or validly capacity-deferred. A stopped
loop reports `stopped`, not failure. A newly planned repair gets one
120-second heartbeat grace; after that, no matching lane or lease is an
ownership gap and the assertion fails. A tracker read failure is indeterminate
and must not be reported as healthy.

## On failure

Name the failed invariant, the exact ticket or runtime item, its current
planner disposition, the deterministic seam that owns recovery, and the next
heartbeat boundary. Notify the human immediately when the item needs a product
decision, scope change, credential or permission, external prerequisite, gate
weakening, or cap/configuration change.

Do not compensate from Mend. A missing worker is a scheduler defect, not
permission to spawn it manually; a blocked ticket is not permission to release
its hold. Route a confirmed Loom defect to the `fix` verb, where its public RED
reproduction, provider-neutral repair, planted mutation, verification, ledger
update, and deployment can be owned explicitly. This hard boundary keeps the
monitor from becoming a second, agent-driven scheduler.
