# Loom build-efficiency improvements

Last updated: 2026-08-17 01:05 America/Chicago

Status markers: `DONE`, `IN PROGRESS`, `TODO`.

## Practical improvements

- [x] **DONE — Make scheduling resource-aware.** Serialize every host `ui` pregate, including merge preflights, while API gates, API merges, probes, and the general auxiliary lane pool remain parallel. Implemented in `97c529e` (`fix(gates): serialize shared UI pregates`). Holding coverage: UI gate ↔ UI gate, UI gate ↔ UI merge, simultaneous handoffs, durable queued reservations, retry after release, cleanup, and unaffected API work. Focused result: 37/37.

- [x] **DONE — Guard tracker writes with compare-and-set state.** Planner transitions carry the state observed in their snapshot; `lane.sh transition --if-current` re-reads live state and refuses stale mutations. Implemented in `68426b2` (`fix(wave): reject stale transitions`). Focused result: 72/72.

- [ ] **TODO — Classify infrastructure failures separately from product verdicts.** Lock timeouts, port collisions, stale-base returns, cross-gate fixture resets, and provider/runtime failures must not increment a product rejection round. Preserve the artifact and schedule an infrastructure retry or repair without posting a product `FAIL`.

- [ ] **IN PROGRESS — Require supervised diagnosis at round 3.** Current operating rule: no third blind implementation/gate cycle. Route the exact failing artifact to a focused repair worker, prove the failure or invalidate it, then permit one supervised gate. JOR-206's supervised fixture repair passed 105/105 and merged. JOR-214 reconciled that repair, passed focused verification, and is in its protected merge preflight at `205e06c`. JOR-218's repair passed 107/107 plus independent review and is waiting in the merge queue. JOR-251's mechanical API gate passed 629 unit and 28 integration tests, but independent review found a real `response-contract` gap; Loom blocked it at the rejection cap and a focused supervised repair is active. Machine-enforced round-three routing itself is still TODO.

- [ ] **TODO — Reuse mechanical gate evidence by commit SHA.** Record a successful host pregate as durable evidence keyed by repository, tier, command/config fingerprint, and commit SHA. An independent reviewer should consume that evidence instead of rerunning the same full tier. Invalidate it when the commit or gate definition changes.

- [x] **DONE — Pin every gate outcome to its start SHA.** JOR-218's gate pregated `4fdfbcc`, then a supervised repair advanced the branch to `8fcf7ed` before delayed failure classification ran. The classifier incorrectly attached the old `rg ENOENT` failure to the repaired, untested SHA and blocked it. Implemented provider-neutrally in `b96abc8` (`fix(gates): pin verdicts to launch head`): the shared launch boundary captures and persists immutable HEAD provenance, snapshot and plan preserve it, delayed rc-7 verdicts name that concrete SHA, and legacy/missing provenance refuses classification instead of rereading a mutable worktree. Focused result: attribution 6/6 and adjacent planner 50/50; the isolated implementation also passed 282 adjacent assertions.

- [ ] **TODO — Right-size the Playwright worker budget.** `playwright.config.ts` does not set `workers`, so Playwright's local default uses 50% of logical CPUs: eight workers on this 16-thread host. Benchmark a fixed four-worker UI gate against the current eight-worker baseline for wall time, timeout rate, and peak host load. Change the configured budget only after the current UI branches finish so the gate fingerprint stays stable during review.

- [x] **DONE — Add a supervised-repair lease.** Implemented in `8d41930` (`fix(wave): lease supervised repairs`), with the restricted-filesystem fail-fast follow-up in `7cf559e` (`fix(lock): fail fast on reservation I/O`). `tick.sh supervise acquire/release` writes bounded host-state leases; snapshots and plans expose them; implementation and gate admission rechecks them under a per-ticket lock for stale plans, Claude handoffs, and Codex durable drains. Expiry fails open, ordinary workers cannot self-lease, and reservation I/O denial is named instead of recursing. Verification: lease 11/11, shared-lock mutant 10/10, snapshot 124/124, planner 50/50, gate admission 9/9, and auxiliary admission 9/9. The live build now uses leases for JOR-206 and JOR-218.

- [x] **DONE — Extend supervised leases through merge admission.** JOR-214 was leased after a known infrastructure-only merge-preflight failure, but merge admission ignored the lease and launched the same expensive UI preflight twice more. Implemented provider-neutrally in `cf1c3a6` (`fix(leases): hold merge admission`): the shared lane-to-ticket parser and admission lock now cover merge lanes; the planner visibly defers leased merges while advancing to the next unrelated queue entry; stale direct plans, Claude handoffs, and Codex durable drains cannot escape. Verification: lease suite 16/16, planner 51/51, 194 adjacent assertions in isolation, and a parser mutant recreated the escaped merge.

- [x] **DONE — Distinguish owned new files from missing prerequisites.** JOR-251 exposed a shared implementation-brief ambiguity: its worker treated two absent route files named in the ticket's own Scope and Files touched as foreign dependencies and blocked instead of creating them. Implemented in `0a7f5bc` (`fix(impl): create ticket-owned surfaces`): the provider-neutral skill contract now requires creation of ticket-owned surfaces and permits `unmerged-dependency` only for a prerequisite owned by a different ticket. Holding coverage in section 22 went RED 6/1 before the clarification and GREEN 7/0 afterward.

- [x] **DONE — Carry supervisor rescope notes into worker briefs.** JOR-251's second worker repeated the original dependency block because tracker scope-reset notes were discarded between snapshot and the implementation brief. Implemented provider-neutrally in `8bceaf1` (`fix(wave): carry supervisor rescope`): snapshot selects the newest active scope reset, plan freezes it into both new-work and rework actions, direct staging appends it mechanically, and deferred Codex requests freeze it before scratch state expires. Verification: snapshot 125/125, brief staging 22/22, planner 51/51, full isolated suite 1,211/1,211, and the transport mutant was caught.

- [x] **DONE — Make malformed notification calls fail cleanly.** A recovery wave invoked `tick.sh notify` without arguments and tripped a `set -u` unbound-argument error after its scheduled state changes. Implemented provider-neutrally in `aef17c6` (`fix(notify): validate CLI arity`): the public boundary accepts exactly three or four arguments and otherwise returns named usage before reading positionals or touching event/transport state. Verification: notification/liveness 41/41, 254 adjacent assertions in isolation, and removing the guard recreates the unbound-variable crash.

- [ ] **IN PROGRESS — Prioritize closure and dependency impact.** Current recovery order favors a nearly-green ticket or a ticket that unlocks dependents over queue age alone. JOR-208, JOR-287, JOR-286, JOR-244, and now JOR-206 are merged and closed. JOR-214 is actively running its protected merge preflight at `205e06c`; it unlocks JOR-224/JOR-221/JOR-231. JOR-218 passed its repaired UI gate at `8fcf7ed` (107/107 plus independent PASS) and is next in the merge queue; it unlocks JOR-233/JOR-236/JOR-239. JOR-251 is blocked under the round-three rule while a focused agent repairs the exact response-envelope escape found after its otherwise-green API gate; it directly unlocks nine tickets. Planner scoring and holding tests remain TODO.

- [ ] **TODO — Make merge-lock collisions durably retryable.** A direct gate-to-merge handoff that encounters the merge lock must remain queued and retry after the current merge exits. It must not be moved to `lane-launch-queue/failed-*` while its reviewed commit is otherwise mergeable. JOR-286 exposed this gap at 23:22 while JOR-287 owned the merge lock; the separate post-merge chain scan recovered it after JOR-287 closed, but the original durable request was still misclassified as failed.

- [ ] **TODO — Retire blocked-report residue after a reset.** `verdict-reset` and `rescope` markers must retire earlier blocked reports as well as earlier verdict counts. Snapshot/planner repair logic must never treat a retired report as an unreleased current hold.

## Supporting safety work completed during this build

- [x] **DONE — Forbid branch-history rewrites in both provider paths.** `938467b` denies `git rebase` for Claude and Codex and denies Codex `git push --force-with-lease`; focused runtime result 44/44.

- [x] **DONE — Prevent model-authored helper commands from executing while merge briefs are staged.** `c7aa933` quotes the merge brief heredoc; focused result 27/27.

## Update rule

Update this file whenever an item moves state. A `DONE` item must name its implementation commit and focused verification. An `IN PROGRESS` item must say what is already active and what remains before completion.
