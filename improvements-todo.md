# Loom build-efficiency improvements

Last updated: 2026-08-16 23:17 America/Chicago

Status markers: `DONE`, `IN PROGRESS`, `TODO`.

## Practical improvements

- [x] **DONE — Make scheduling resource-aware.** Serialize every host `ui` pregate, including merge preflights, while API gates, API merges, probes, and the general auxiliary lane pool remain parallel. Implemented in `97c529e` (`fix(gates): serialize shared UI pregates`). Holding coverage: UI gate ↔ UI gate, UI gate ↔ UI merge, simultaneous handoffs, durable queued reservations, retry after release, cleanup, and unaffected API work. Focused result: 37/37.

- [x] **DONE — Guard tracker writes with compare-and-set state.** Planner transitions carry the state observed in their snapshot; `lane.sh transition --if-current` re-reads live state and refuses stale mutations. Implemented in `68426b2` (`fix(wave): reject stale transitions`). Focused result: 72/72.

- [ ] **TODO — Classify infrastructure failures separately from product verdicts.** Lock timeouts, port collisions, stale-base returns, cross-gate fixture resets, and provider/runtime failures must not increment a product rejection round. Preserve the artifact and schedule an infrastructure retry or repair without posting a product `FAIL`.

- [ ] **IN PROGRESS — Require supervised diagnosis at round 3.** Current operating rule: no third blind implementation/gate cycle. Route the exact failing artifact to a focused repair worker, prove the failure or invalidate it, then permit one supervised gate. JOR-206 reproduced its forged-cursor defect (`200` instead of `422`), landed and pushed the authenticated-cursor repair at `56e2ebb`, and is waiting for the serialized UI resource. JOR-286's latest reviewer found a test-proof gap rather than a new RPC defect; a supervised test-only repair is in progress. JOR-214's fixture-lease repair remains verified and awaits its serialized gate. Machine-enforced planner routing is still TODO.

- [ ] **TODO — Reuse mechanical gate evidence by commit SHA.** Record a successful host pregate as durable evidence keyed by repository, tier, command/config fingerprint, and commit SHA. An independent reviewer should consume that evidence instead of rerunning the same full tier. Invalidate it when the commit or gate definition changes.

- [ ] **TODO — Add a supervised-repair lease.** A ticket under supervisor/sub-agent repair needs a machine-readable lease. Ordinary waves must not launch a duplicate implementer or gate until the lease is released or expires. This closes the duplicate JOR-214/JOR-287 collisions and the 23:14 JOR-286 race, where a heartbeat launched `impl-286` during supervised reconciliation; it was stopped before editing the verified worktree.

- [ ] **IN PROGRESS — Prioritize closure and dependency impact.** Current recovery order favors a nearly-green ticket or a ticket that unlocks dependents over queue age alone. JOR-208 is merged and closed. JOR-287 now owns the serialized UI gate to unlock JOR-218, while JOR-286's supervised API gate runs concurrently to unlock JOR-244; JOR-206 is reconciling current main before its UI turn and still unlocks JOR-230/JOR-212. Planner scoring and holding tests remain TODO.

- [ ] **TODO — Retire blocked-report residue after a reset.** `verdict-reset` and `rescope` markers must retire earlier blocked reports as well as earlier verdict counts. Snapshot/planner repair logic must never treat a retired report as an unreleased current hold.

## Supporting safety work completed during this build

- [x] **DONE — Forbid branch-history rewrites in both provider paths.** `938467b` denies `git rebase` for Claude and Codex and denies Codex `git push --force-with-lease`; focused runtime result 44/44.

- [x] **DONE — Prevent model-authored helper commands from executing while merge briefs are staged.** `c7aa933` quotes the merge brief heredoc; focused result 27/27.

## Update rule

Update this file whenever an item moves state. A `DONE` item must name its implementation commit and focused verification. An `IN PROGRESS` item must say what is already active and what remains before completion.
