# Loom build-efficiency improvements

Last updated: 2026-08-17 13:04 America/Chicago

Status markers: `DONE`, `IN PROGRESS`, `TODO`, `BLOCKED`, `NEEDS DECISION`.

## Practical improvements

- [x] **DONE — Add contract-grounded active-build supervision.** Implemented
  as `/loom mend` in `83ca609` (`feat(mend): add build supervisor`), with
  canonical layered timing policy completed in `823477f`. The
  human-run loop now evaluates stable state, chaining, immutable-head,
  admission, liveness, hold, rejection-cap, classification, completion, and
  provider-compatibility invariants instead of inventing policy from logs. A
  read-only `tick.sh mend-status` composes the canonical snapshot and plan,
  exposes intentional stop state without restarting it, and surfaces evidence
  requiring attention. Direct Claude and durable Codex inputs yield identical
  semantics; no adapter changed. Verification: focused mend 10/10, adjacent
  scheduler/runtime 433/433, full suite 1,327/1,327, and the missing-builder
  planted violation was caught. (`MEND-STATE-01`, `MEND-COMPAT-01`)

- [x] **DONE — Keep mend attached across actionable idle gaps.** Patient
  Imaging Portal Build JOR-267 exposed the missing terminal boundary: mend
  returned "loop armed" with zero lanes while the deterministic plan already
  contained the next UI gate, leaving the human to discover the silence.
  Implemented provider-neutrally in `2a93355` (`fix(mend): flag actionable
  idle gaps`): `mend-status` now emits `MEND-FLOW-01/actionable-idle` whenever
  a non-stopped build has no active lane and a non-empty plan; the default
  mend contract stays in the turn through the next handoff or heartbeat,
  diagnoses a missed trigger if work still does not start, and never treats an
  armed timer or a status question as a terminal condition. Scheduler ownership
  and wave pacing remain unchanged. Verification: focused mend 12/12,
  adjacent scheduler/runtime 399/399, full suite 1,330/1,330, and disabling
  the runnable-action predicate recreated invisible idle work.

- [x] **DONE — Turn observed progress gaps into durable Loom repairs.** Live
  `MEND-FLOW-01` supervision on Patient Imaging Portal exposed two defects
  behind the zero-lane state: a cleanup-only wave reset the paid wave gap after
  making new work visible, and a stale-base gate transition was misclassified
  as a dead lane's partial submit, looping JOR-231 back to Review without ever
  reconciling its branch. Implemented provider-neutrally in `acdf377`
  (`fix(mend): close scheduler progress gaps`) and completed from live proof in
  `285c381` (`fix(mend): close recovery-edge gaps`). Durable post-wave cleanup now
  requests one coalesced scheduler replay from the resulting lane state. Gate
  base deferral writes a tracker-resident, current-HEAD `orch-base-stale`
  decision; snapshot suppresses the false review repair, plan routes the
  stranded ticket to reconciliation, and direct/deferred brief staging carries
  the decision until a new HEAD automatically retires it. The follow-up closes
  both live recovery variants: a heartbeat that inherits queued cleanup admits
  its own wave past the old gap, and a non-hold transition deduplicates by its
  exact machine-decision trailer instead of mistaking historical unblock notes
  for the current decision. `mend` now owns
  `MEND-LEARN-01`: every confirmed avoidable gap must become a public
  reproduction, shared-core repair, regression, and planted mutation rather
  than a one-off ticket nudge. Verification: final full Loom suite 1,341/1,341,
  syntax/jq/diff checks clean; deleting cleanup replay recreates the wave-gap
  stall, and deleting the stale-transition exclusion recreates the review
  loop. (`MEND-FLOW-01`, `MEND-CHAIN-01`, `MEND-LEARN-01`)

- [x] **DONE — Isolate host spawn preflight failures.** Continued live mend
  supervision found that one dirty gate checkout aborted `_prepare_wave_plan`
  before `wave_start`, suppressing dead-lane cleanup and every unrelated safe
  action in the same deterministic plan. Implemented provider-neutrally in
  `cd5377d` (`fix(wave): isolate spawn preflight failures`): host worktree
  preparation now defers only the unsafe spawn as `host-preflight-failed`,
  emits `wave_spawn_deferred`, renumbers the surviving immutable actions, and
  still launches the wave. The `mend` verb now names this as a
  `MEND-FLOW-01`/`MEND-LEARN-01` obligation rather than healthy pacing.
  Verification: focused runtime and mend suites 60/60, full Loom suite
  1,343/1,343, syntax/diff checks clean; restoring the all-or-nothing return
  recreates the pre-provider build gap. Live holding proof: at 19:06:39Z the
  installed runtime emitted `wave_spawn_deferred` for JOR-290's tracked-change
  conflict, started the wave one second later, cleared two dead lanes, and
  launched `impl-231`. Mend preserved JOR-290's explicitly excluded local
  experiment as stash `loom mend: excluded JOR-290 dirty experiment before
  reviewed head`, advanced the clean checkout to reviewed HEAD `0251cd3`, and
  released its supervised lease; unrelated `gate-233` and `impl-231` remained
  active.

- [x] **DONE — Retain rejected-gate evidence through handoff.** JOR-233's
  rc-7 gate handoff queued `clear-lane gate-233` before posting its prose
  verdict. The next heartbeat retired the source launchd job and terminated
  that handoff wave, leaving Review with no verdict at tested HEAD `14e0436`
  and making the same failure gateable again. Implemented provider-neutrally
  in `c5b08b9` (`fix(plan): retain rejected gate evidence`): an rc-7 lane in
  Review is not cleanup-eligible until its immutable-HEAD verdict stands; only
  the following plan clears it. The mend and scheduler contracts now make
  evidence-before-cleanup ordering explicit. Verification: focused planner and
  mend suites 74/74, full Loom suite 1,344/1,344, standalone jq/diff checks
  clean; eager-cleanup mutation recreates the verdict-loss ordering. Mend then
  repaired JOR-233's retained failure as `acceptance-contract`, moved it to
  In Progress, and released the supervised lease. (`MEND-CHAIN-01`,
  `MEND-LEARN-01`, `MEND-STATE-01`)

- [x] **DONE — Deduplicate semantic gate verdict identity.** Linear
  read-after-write lag let JOR-290's immediate cleanup replay post two comments
  for the same ticket, immutable HEAD `56b8f8f`, FAIL outcome, and
  `repo-wide-config-guard` class. The old snapshot counted both transports as
  two rounds and falsely applied the rejection cap. Implemented
  provider-neutrally in `6bfcdf2` (`fix(state): dedupe verdict identity`):
  exact verdict identity collapses after the newest reset marker, while a
  genuine later review remains distinct after reset. Verification: focused
  snapshot 139/139, full Loom suite 1,346/1,346, standalone jq/diff checks
  clean; removing identity grouping recreates the false cap. The old runtime
  blocked JOR-290 before integration; releasing that one false tracker hold is
  pending explicit ticket-specific human authorization. (`MEND-STATE-01`,
  `MEND-LEARN-01`, `MEND-ROUND-01`)

- [x] **DONE — Make scheduling resource-aware.** Serialize every host `ui` pregate, including merge preflights, while API gates, API merges, probes, and the general auxiliary lane pool remain parallel. Implemented in `97c529e` (`fix(gates): serialize shared UI pregates`). Holding coverage: UI gate ↔ UI gate, UI gate ↔ UI merge, simultaneous handoffs, durable queued reservations, retry after release, cleanup, and unaffected API work. Focused result: 37/37.

- [x] **DONE — Release the UI host after mechanical pregate.** Measurement on
  Patient Imaging Portal Build JOR-267 found 134 UI gates consuming 8.13 hours;
  54 rejected gates consumed 4.22 hours, while the single host reservation was
  incorrectly retained through independent provider review after Chromium and
  its fixture had exited. Implemented provider-neutrally in `ad82441`
  (`fix(gates): release UI host after pregate`): `.ui-resource` now owns only
  the active host pregate/probe, while `.pregate` remains durable attribution.
  Direct and queued gates, merge preflights, probes, cleanup, and atomic
  admission share the same boundary. Snapshot fixture correction `05a8957`
  models a genuinely active host phase. Verification: focused/adjacent UI,
  gate, probe, planner, and mend suites 53/53; full suite 1,356/1,356; retaining
  the resource marker recreates false review-time serialization.
  (`MEND-ADMIT-01`, `MEND-LEARN-01`)

- [x] **DONE — Detect missing workers per flow stage.** A live implementation
  previously made Mend look healthy even when Review or Merge Queue work had
  no gate/merge owner, so the human had to identify the idle stage. Implemented
  provider-neutrally in `5fc885a` (`fix(mend): detect unowned flow stages`):
  `mend-status` emits `MEND-FLOW-01/unowned-stage` for an In Progress, Review,
  or Merge Queue ticket without its matching implementation, gate, or merge
  lane, and includes its scheduled, deferred, and residue disposition. The
  Mend contract now ranks unowned closure stages and shared-resource pressure
  before lower-impact work and requires diagnosis in the same pass. Verification:
  focused Mend 14/14, full suite 1,356/1,356; removing the detector recreates
  an invisible merge queue while unrelated work remains active.
  (`MEND-FLOW-01`, `MEND-LEARN-01`)

- [ ] **IN PROGRESS — Keep viewer panes equal to active workers.** Patient
  Imaging Portal exposed a dead viewer (`watch-panes.pid` 45610; output stopped
  at 09:59) whose four owned panes outlived it (`impl-231`, `gate-207`,
  `impl-253`, `gate-239`), while the only live lane `impl-291` had no pane.
  Immediate recovery closed those confirmed orphan panes and started a fresh
  viewer, which opened `impl-291`. Durable completion requires active-only pane
  reconciliation on every poll, recoverable ownership across viewer death,
  stale/PID-reuse-safe singleton detection, and automatic recovery that cannot
  strand a live lane until a human runs `watch` again. Add public regressions
  for viewer death with surviving panes and for a new lane arriving after that
  death, plus a planted ownership-recovery mutation. (`MEND-LIVE-01`,
  `MEND-LEARN-01`)

- [x] **DONE — Guard tracker writes with compare-and-set state.** Planner transitions carry the state observed in their snapshot; `lane.sh transition --if-current` re-reads live state and refuses stale mutations. Implemented in `68426b2` (`fix(wave): reject stale transitions`). Focused result: 72/72.

- [x] **DONE — Classify probe infrastructure separately from product failures.** Implemented provider-neutrally in `4940b52` (`fix(probes): classify infrastructure failures`): probe briefs require proof of product contact before `fix-ticket`; sandbox, browser launch, OS permission, and local bind failures instead emit typed `probe-result ... infrastructure`, keep the epic open, and render without claiming a product defect. Claude and Codex adapters remain unchanged. Verification: ticker/verbs, staged-brief mutant, and runtime suites passed 235/235; the isolated full suite passed 1,240/1,240. Extending this typed distinction to ordinary gate retry policy remains future work.

- [ ] **IN PROGRESS — Require supervised diagnosis at round 3.** Current operating rule: no third blind implementation/gate cycle. Route the exact failing artifact to a focused repair worker, prove the failure or invalidate it, then permit one supervised gate. JOR-206, JOR-214, JOR-218, JOR-236, JOR-251, JOR-283, JOR-203, JOR-193, JOR-289, JOR-199, JOR-207, JOR-216, and JOR-239 completed this recovery path and merged. JOR-253 preserved its valid gate-command-contract FAIL at `61537fc`, was requeued after mend repaired a same-HEAD partial transition, and is Review-ready at `50b30ce`; JOR-257's obsolete-base loop ended after JOR-239 merged, then its green product gate exposed JOR-239's branch-specific scope assertion as a shared harness defect. Mend repaired the interrupted rejection transition, removed only that one-time guard, proved the recipient suite 5/5 plus static checks, and recorded the repair at `0aa22f1`. Its next host gate passed every mechanical tier including 153/153 browser tests, but independent review received only the newest of three supervised-repair notes and falsely classified the older cine/CI repairs as scope drift. The repair evidence is now consolidated; after explicit hold-release authorization, Loom's repair lane returned JOR-257 to Review at the same green HEAD and released the lease. JOR-233 is Review-ready at `296f818`; and JOR-231 returned to Review at `fced486` after high-tier rework for incomplete E3 acceptance coverage found by independent review of its green 128/128 mechanical UI gate. Machine-enforced round-three routing itself is still TODO.

- [x] **DONE — Complete a valid supervised repair without falsifying history.** JOR-251 exposed a missing tracker action after the rejection cap: `verdict-reset` truthfully means an invalid gate, while `rescope` truthfully means different work. Implemented provider-neutrally in `45f8308` (`fix(recovery): complete supervised repairs`): human-only `lane.sh supervised-repair` requires a reason, refuses lane and wave callers before tracker writes, retires only prior verdict/rejection history, preserves merge history, exposes immutable repair evidence through snapshot and plan, and carries it into the next gate action for both Claude and Codex. Verification: focused sections 07/16/28/29 passed 380/380 and a planted cutoff mutant restored the stale rejection history and was caught.

- [ ] **TODO — Reuse mechanical gate evidence by commit SHA.** Record a successful host pregate as durable evidence keyed by repository, tier, command/config fingerprint, and commit SHA. An independent reviewer should consume that evidence instead of rerunning the same full tier. Invalidate it when the commit or gate definition changes.

- [x] **DONE — Pin every gate outcome to its start SHA.** JOR-218's gate pregated `4fdfbcc`, then a supervised repair advanced the branch to `8fcf7ed` before delayed failure classification ran. The classifier incorrectly attached the old `rg ENOENT` failure to the repaired, untested SHA and blocked it. Implemented provider-neutrally in `b96abc8` (`fix(gates): pin verdicts to launch head`): the shared launch boundary captures and persists immutable HEAD provenance, snapshot and plan preserve it, delayed rc-7 verdicts name that concrete SHA, and legacy/missing provenance refuses classification instead of rereading a mutable worktree. Focused result: attribution 6/6 and adjacent planner 50/50; the isolated implementation also passed 282 adjacent assertions.

- [x] **DONE — Prepare every gate worktree at the reviewed MR HEAD.** JOR-207 was Review-eligible at remote MR SHA `b07039c`, but its standard worktree still tracked `origin/main` at `1f6363c`; the queued gate captured that stale local SHA and began the full API suite. Implemented provider-neutrally in `705727e` (`fix(gates): prepare immutable MR head`): the plan carries a machine-readable expected SHA, and shared host preparation fetches and fast-forwards only a clean ancestor worktree to that exact commit or fails before either Claude or Codex starts. RED reproduced the stale checkout at 44/1; GREEN is 46/46 focused plus 131/131 adjacent, with a planted tick-to-worktree transport mutant recreating the stale launch. Three unchanged timing assertions failed only in a heavily repeated parallel full run and passed 116/116 immediately in isolation.

- [ ] **TODO — Right-size the Playwright worker budget.** `playwright.config.ts` does not set `workers`, so Playwright's local default uses 50% of logical CPUs: eight workers on this 16-thread host. Benchmark a fixed four-worker UI gate against the current eight-worker baseline for wall time, timeout rate, and peak host load. Change the configured budget only after the current UI branches finish so the gate fingerprint stays stable during review.

- [x] **DONE — Add a supervised-repair lease.** Implemented in `8d41930` (`fix(wave): lease supervised repairs`), with the restricted-filesystem fail-fast follow-up in `7cf559e` (`fix(lock): fail fast on reservation I/O`). `tick.sh supervise acquire/release` writes bounded host-state leases; snapshots and plans expose them; implementation and gate admission rechecks them under a per-ticket lock for stale plans, Claude handoffs, and Codex durable drains. Expiry fails open, ordinary workers cannot self-lease, and reservation I/O denial is named instead of recursing. Verification: lease 11/11, shared-lock mutant 10/10, snapshot 124/124, planner 50/50, gate admission 9/9, and auxiliary admission 9/9. All current supervised handoffs were released at this checkpoint.

- [x] **DONE — Extend supervised leases through merge admission.** JOR-214 was leased after a known infrastructure-only merge-preflight failure, but merge admission ignored the lease and launched the same expensive UI preflight twice more. Implemented provider-neutrally in `cf1c3a6` (`fix(leases): hold merge admission`): the shared lane-to-ticket parser and admission lock now cover merge lanes; the planner visibly defers leased merges while advancing to the next unrelated queue entry; stale direct plans, Claude handoffs, and Codex durable drains cannot escape. Verification: lease suite 16/16, planner 51/51, 194 adjacent assertions in isolation, and a parser mutant recreated the escaped merge.

- [x] **DONE — Distinguish owned new files from missing prerequisites.** JOR-251 exposed a shared implementation-brief ambiguity: its worker treated two absent route files named in the ticket's own Scope and Files touched as foreign dependencies and blocked instead of creating them. Implemented in `0a7f5bc` (`fix(impl): create ticket-owned surfaces`): the provider-neutral skill contract now requires creation of ticket-owned surfaces and permits `unmerged-dependency` only for a prerequisite owned by a different ticket. Holding coverage in section 22 went RED 6/1 before the clarification and GREEN 7/0 afterward.

- [x] **DONE — Carry supervisor rescope notes into worker briefs.** JOR-251's second worker repeated the original dependency block because tracker scope-reset notes were discarded between snapshot and the implementation brief. Implemented provider-neutrally in `8bceaf1` (`fix(wave): carry supervisor rescope`): snapshot selects the newest active scope reset, plan freezes it into both new-work and rework actions, direct staging appends it mechanically, and deferred Codex requests freeze it before scratch state expires. Verification: snapshot 125/125, brief staging 22/22, planner 51/51, full isolated suite 1,211/1,211, and the transport mutant was caught.

- [x] **DONE — Preserve supervisor context across both gate and rework re-entry.** JOR-240's reviewer restored requirements explicitly removed by an active scope reset, while JOR-193's later rework deleted a verified supervised repair because the original ticket file list did not name its support files. Implemented provider-neutrally in `ce4ac77` (`fix(briefs): preserve supervisor context`): gate actions now freeze and stage active scope resets, and rework actions freeze and stage completed supervised-repair evidence, through both direct Claude and durable Codex paths. RED was 78/2 for the gate scope and 80/2 for repair preservation; final focused result 84/84 plus 91 adjacent provider/chaining assertions, with one planted mutant per escape.

- [x] **DONE — Make scope reset replacement versus extension explicit.** JOR-207's later audit-support rescope became the single newest active reset and silently hid the earlier replacement rule that forbade fixed fixture ports; the reviewer then rejected a mechanically green E8 gate for following the hidden rule. Implemented provider-neutrally in `254166c` (`fix(scopes): preserve additive amendments`): ordinary human-only `rescope` remains a true replacement, while explicit `rescope --extend` records a subsequent additive amendment; snapshot composes only extensions after the newest replacement, and a later replacement supersedes both. Direct Claude and durable Codex staging key on the newest reset-or-extension marker so a pre-staged base cannot suppress an amendment. Focused sections 07/16/23/28/47 passed 410/410, the full suite passed 1,318/1,318, and the accumulation mutant was caught.

- [x] **DONE — Freeze the complete ticket contract into worker briefs.** JOR-221 was dependency-ready but its worker blocked because `LINEAR_API_KEY` was absent and the staged brief carried only a pointer to Linear. Implemented provider-neutrally in `b451d23` (`fix(briefs): freeze ticket contracts`): the host snapshot preserves the full body, the immutable plan carries it for new work, rework, and gates, and the shared launch boundary appends it before direct Claude or deferred Codex execution. Scope resets and supervised repairs remain later, explicit overrides. Verification: focused snapshot/plan/staging 217/217, adjacent provider/gate/chaining 91/91, and deleting the append recreates tracker-dependent work. JOR-221's infrastructure hold was released after this commit.

- [x] **DONE — Make malformed notification calls fail cleanly.** A recovery wave invoked `tick.sh notify` without arguments and tripped a `set -u` unbound-argument error after its scheduled state changes. Implemented provider-neutrally in `aef17c6` (`fix(notify): validate CLI arity`): the public boundary accepts exactly three or four arguments and otherwise returns named usage before reading positionals or touching event/transport state. Verification: notification/liveness 41/41, 254 adjacent assertions in isolation, and removing the guard recreates the unbound-variable crash.

- [x] **DONE — Prioritize closure and dependency impact.** Implemented provider-neutrally in `130ace0` and `f69c248`, then completed for real wave inputs in `b007360` (`fix(plan): retain dependency edges`). Gate candidates are ordered first by how many tickets would become fully unblocked if they merged, then by open-ticket impact, then ticket id. Because `snapshot --brief` intentionally filters blocked ticket rows, it now transports a compact immutable `{id,blocked_by}` graph; the planner validates it and falls back for legacy snapshots. RED was 189/3, including the live-shaped #289 loss to #239; GREEN focused is 192/192 plus 41/41 adjacent assertions and a planted transport mutant. Live proof: JOR-289 was reconciled, repaired, passed 131/131 Playwright plus independent review, merged, and immediately released JOR-231 and JOR-233; both implementation lanes are now live.

- [x] **DONE — Release provider-complete lanes from capacity immediately.** Implemented provider-neutrally in `616d3a3` (`fix(capacity): release finished lane slots`): snapshot and final auxiliary admission stop charging a lane after its durable rc/outcome exists, while true PID liveness remains authoritative for worktree safety and same-ticket dedupe. The planner clears cleanup-eligible lanes and fills their released slots in the same ordered wave instead of spending a cleanup-only wave. Verification: planner 54/54, auxiliary admission 10/10, host-probe admission 10/10, full isolated suite 1,257/1,257, and the finished-lane-capacity mutant was caught. No adapter changed.

- [x] **DONE — Pin gate review diffs to the canonical remote base.** JOR-289's mechanical UI gate passed 131/131, but its reviewer compared against a local `main` branch 125 commits behind and falsely reported 62 changed files; `origin/main...HEAD` contained exactly the ticket's two files. Implemented provider-neutrally in `ecac932` (`fix(gates): pin canonical review base`): every gate brief now carries immutable `origin/<base>` and HEAD SHAs, the exact three-dot range, and an explicit refusal to use optional local branches. The host freshness check still suppresses a reviewer if the remote base advances. Verification: focused gate launch 11/11, adjacent launch/chaining/host-probe 134/134, and deleting base capture recreates the unpinned reviewer.

- [ ] **IN PROGRESS — Keep one-time scope review out of committed global suites.** JOR-239 committed a Playwright assertion that compared `origin/main...HEAD` against JOR-239's own file list. After merge, the global UI suite therefore rejected every unrelated feature branch; JOR-257 exposed it after 141 browser passes. The supervised repair at `0aa22f1` deletes only the branch-diff assertion and retains all recipient security checks; the exact previously failing spec passes 5/5 on JOR-257's real diff. Completion requires JOR-257 to pass review and merge so the shared gate is repaired for every later branch.

- [ ] **TODO — Accumulate supervised-repair evidence instead of replacing it.** JOR-257 accumulated valid CI command-list, cine cold-hydration, and shared recipient scope-guard repairs. `active_supervised_repair_of` carried only the newest note into the next gate brief, so independent review saw the cine change without its earlier authorization and emitted a false `scope-violation` after a fully green 153/153 browser gate. Snapshot/plan/chain staging should compose all supervised-repair notes after the latest true scope replacement, in tracker order, with tests proving a later repair cannot erase earlier repair authority.

- [x] **DONE — Reclaim abandoned durable cleanup claims.** A `gate-239-r2` cleanup was atomically renamed from `request-*` to `running-*`, then its drainer died; later heartbeats scanned only requests while dedupe treated the running claim as permanent. Implemented provider-neutrally in `f20a43c` (`fix(cleanup): reclaim abandoned claims`): new claims record drainer PID, live owners are never stolen, dead owners are immediately requeued, and aged legacy ownerless claims are reclaimed after one minute for rolling compatibility. Verification: cleanup 10/10, adjacent admission/runtime 64/64, full isolated suite 1,271/1,271, and the reclamation mutant recreates the wedge.

- [x] **DONE — Keep queued Codex worktrees alive until durable launch.** JOR-240 was prepared, claimed, and queued at 01:24, but the next tick swept its unchanged branch before the durable host launched it. Implemented provider-neutrally in `a5e417c` (`fix(sweep): preserve queued worktrees`): sweep folds both `request-*` and `launching-*` cwd ownership into the same protected set as live processes and fails closed on unreadable or non-absolute queue metadata. Verification: focused sweep 28/28, full suite 1,237/1,237, and removing queued cwd ownership recreates the pre-launch deletion. No adapter changed.

- [x] **DONE — Make implementation-to-gate chaining deterministic.** Implemented provider-neutrally in `f7f9214` (`fix(chain): hand implementations to gates`): the host implementation epilogue calls `chain-gate`, live-reads Review/MR/HEAD state, freezes active scope-reset and supervised-repair evidence, emits exact SHA-pinned verdict commands, and reuses existing UI/aux admission, leases, ticket-at-HEAD dedupe, Claude direct launch, and Codex durable launch. Verification: new direct/deferred/duplicate/mutant seam 5/5 and adjacent admission/chaining suites 183/183; isolated full suite 1,240/1,240.

- [x] **DONE — Resolve the build provider for resumed deterministic handoffs.** Implemented provider-neutrally in `6bc4960` (`fix(chain): recover build provider`): manual `chain-gate` and `chain-merge` recover the active Build's exact single registered `provider::` label when no transport is inherited, while inherited Claude/Codex values are validated and preserved. Ambiguous and unregistered providers fail before spawn. Verification: focused/adjacent suites 93/93, isolated full suite 1,249/1,249, and a deletion mutant recreates the live empty-provider refusal. Live proof: a clean-shell #239 handoff queued `provider=codex` without an explicit environment override.

- [x] **DONE — Make host-state commands linked-worktree safe.** Implemented provider-neutrally in `37a23bd` (`fix(state): canonicalize linked worktrees`) with missing-Git fixture compatibility in `4e43677` (`fix(state): distinguish linked gitfiles`): before deriving `LOOM_HOME`, Git common state and porcelain worktree identity resolve linked callers to the main checkout; unprovable or unreadable linked identities fail before state creation. Verification: integrated lease and adjacent suites 106/106; the core resolver's isolated full suite 1,248/1,248; final snapshot/lease coverage 149/149; and a cwd-derived mutant recreates false-success release. Live proof: releasing #251 from `.worktrees/251` removed the canonical lease and created no parallel residue.

- [x] **DONE — Eliminate watcher unbound-state crashes.** Implemented in `8e1a2e5` (`fix(watch): initialize empty wave stream`): the progress watcher initializes `wj` before the fallible empty-glob pipeline used when a tick lock exists without a wave JSONL. Verification: watcher/liveness suites 66/66, isolated full suite 1,247/1,247, and a public planted mutant recreates `wj: unbound variable`. Shared host code only; adapters unchanged.

- [ ] **IN PROGRESS — Run browser acceptance probes at a viable provider boundary.** Loom core implementation `0d2b0df` adds validated `--host-probe <id>` execution at the launchd-owned host prelude, fixed runner lookup, immutable HEAD artifacts, typed pass/fail/infrastructure outcomes, durable Codex transport, and shared UI admission without widening the sandbox or changing either adapter. Focused host-probe coverage is 10/10 and the isolated full suite is 1,265/1,265. The E8 milestone probe passed its live application/REST/Postgres boundary: 8/8 checks, including two-run and overlap behavior, with 10/10 due reminders sent and zero duplicates. JOR-290 was re-scoped to the repository-owned `e2` runner only; PR #69 contains the two-file runner, its 51/51 focused contract suite, and a real host run that passed all 11 E2 checks. Completion requires its independent host-probe review and merge; arbitrary provider-authored host commands remain explicitly out of scope.

- [ ] **IN PROGRESS — Promote shared UI harness repairs before retrying dependent branches.** JOR-236, JOR-289, and JOR-239 passed full UI review and merged, releasing JOR-231, JOR-233, and JOR-248. JOR-233 is host-verified and in Review at `296f818`. JOR-231's exact E3 project passed 128/128 before independent review found incomplete acceptance coverage; its focused rework is back in Review at `fced486`. JOR-257 was reconciled merge-only after JOR-239 landed, repaired JOR-239's globally invalid branch-scope guard, and passed a fresh full host gate including 153/153 browser tests at `0aa22f1`; it is back in Review after explicit hold-release authorization and is queued behind the active JOR-260 UI gate. JOR-240, JOR-253, JOR-257, JOR-260, and JOR-290 remain in the serialized UI frontier.

- [ ] **TODO — Make merge-lock collisions durably retryable.** A direct gate-to-merge handoff that encounters the merge lock must remain queued and retry after the current merge exits. It must not be moved to `lane-launch-queue/failed-*` while its reviewed commit is otherwise mergeable. JOR-286 exposed this gap at 23:22 while JOR-287 owned the merge lock; the separate post-merge chain scan recovered it after JOR-287 closed, but the original durable request was still misclassified as failed.

- [ ] **TODO — Retire blocked-report residue after a reset.** `verdict-reset` and `rescope` markers must retire earlier blocked reports as well as earlier verdict counts. Snapshot/planner repair logic must never treat a retired report as an unreleased current hold.

- [x] **DONE — Preserve Loom's ticket marker when an existing MR body is refreshed.** JOR-199's worker updated PR #65 after `lane.sh submit` and accidentally removed `Loom-Ticket: 199`; snapshot then saw Review with no MR and stranded the gate until the marker was restored manually. Implemented provider-neutrally in `44123ab` (`fix(submit): preserve ticket markers`): `lane.sh submit --file <final-body>` owns MR-body refresh, falls back from marker lookup to the current branch's single open MR, appends the forge-specific marker, updates through reviewed file-only GitHub/GitLab verbs, and refuses duplicate or ambiguous MRs. RED reproduced a duplicate POST; GREEN focused/adjacent tracker, forge, and lane suites passed 334/334.

- [x] **DONE — Make immutable-contract authority explicit in the staged brief.** Implemented provider-neutrally in `744e794` (`fix(briefs): declare contract authority`): the shared contract-staging boundary says the host snapshot is complete and authoritative, forbids tracker rediscovery and invented verbs such as `lane.sh show`, names the documented implementation terminal paths, and defers gate/merge work to each brief's exact appended command while preserving later scope-reset and supervised-repair precedence. RED showed 0/2 direct-Claude/deferred-Codex paths carrying the rule; GREEN is 32/32 focused plus 109/109 adjacent assertions, and deleting only the authority block recreates the gap. Adapters remain unchanged.

- [x] **DONE — Preserve supervised worktrees from sweep.** JOR-221's diagnostic checkout and then JOR-216's freshly recreated branch were swept while valid supervised leases were active. Implemented provider-neutrally in `dc4df12` (`fix(sweep): preserve supervised worktrees`): active-only canonical leases add both current `.worktrees/<ticket>` and legacy `<repo>-wt-<ticket>` paths to the shared protected-cwd set; release and expiry restore normal cleanup. RED reproduced the #216 deletion at the public acquire → sweep seam; GREEN is sweep 32/32, lease/canonical-state 20/20, full Loom 1,299/1,299, with a planted omission recreating deletion. No adapters changed.

- [ ] **IN PROGRESS — Provision the deployed application schema before performance work.** JOR-221 is correctly blocked on environment readiness, not product code: the configured Supabase project authenticates the demo user, but both authenticated and service-role PostgREST reads return `PGRST205` for `patients` and `audit_events`, proving migrations/seed are absent from the exposed schema. JOR-252 owns promotion of the finished build; completion must apply migrations 001–008, align `authenticated`/`app_user` grants, seed demo data/assets, and expose a repeatable verification command before JOR-221 can record honest baselines.

- [ ] **TODO — Deploy live Loom runtime files atomically.** An epilogue parsed `tick.sh` while it was being updated and logged a transient syntax error near `|`; the completed file passed `bash -n`, proving the reader saw a partial write. Stage changed runtime files, run syntax/jq checks on the staged set, then replace them atomically so active Claude and Codex lanes always read a complete version. Develop larger runtime patches in an isolated checkout until this boundary exists.

- [x] **DONE — Canonicalize tick cwd before sweep and provider launch.** Implemented provider-neutrally in `b079cfc` (`fix(tick): enter canonical repo root`): the public tick boundary enters the already-canonical main checkout before tracker helpers, sweep, or provider/version startup and fails loudly if stable ground is unavailable. RED reproduced merge-193's exact deleted-worktree `shell-init/getcwd` failure and rc 71; GREEN is 27/27 focused, 100/100 adjacent, and 1,295/1,295 full-suite assertions. A planted mutant removing only the root entry recreates the failure. No adapter changed.

- [x] **DONE — Make the planner reserve the serialized UI resource.** Implemented provider-neutrally in `d1223af` (`fix(plan): reserve shared UI resource`): snapshot freezes live/queued UI ownership, the pure planner selects no UI work while occupied and exactly the highest-priority UI gate when free, and a planned UI gate also reserves the same-wave UI merge seam. API gates and API merges remain parallel; final admission remains the atomic race guard. RED was 2 pass/3 fail with duplicate UI gates and an overlapping UI merge; GREEN is 6/6 focused, 199/199 snapshot/planner, 67/67 adjacent admission/chaining, and full Loom 1,307/1,307. A planted selection mutant recreates the overlap.

## Supporting safety work completed during this build

- [x] **DONE — Forbid branch-history rewrites in both provider paths.** `938467b` denies `git rebase` for Claude and Codex and denies Codex `git push --force-with-lease`; focused runtime result 44/44.

- [x] **DONE — Prevent model-authored helper commands from executing while merge briefs are staged.** `c7aa933` quotes the merge brief heredoc; focused result 27/27.

## Update rule

Update this file whenever an item moves state. A `DONE` item must name its
implementation commit and focused verification. An `IN PROGRESS` item must
say what is already active and what remains before completion. A `BLOCKED`
item must name the external condition that can release it. A `NEEDS DECISION`
item must state the policy choice and must not be implemented until the human
chooses it.
