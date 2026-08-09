# Loom — open proposals

Live proposals for making `/loom` faster and more reliable, ordered by impact. Implemented
ones move to [PROPOSALS_ARCHIVED.md](PROPOSALS_ARCHIVED.md), which also holds the review-round
findings and the ranking rationale for work already done.

Everything here is derived from a review of `SKILL.md`, `scripts/tick.sh`, `scripts/tick-test.sh`
and `references/`, checked against the two real unattended runs on disk (crucible Build 2,
2026-07-21 19:55–23:45, 31 logs in `~/.loom/crucible-2014258785/logs/`; boostlingo
build-1, 2026-08-01 23:24 → 2026-08-02 12:28, logs in
`~/.loom/boostlingo-ai-interpreter-workbench-2061292512/logs/`) and against fresh
benchmarks of the crucible gate suite.

## Tracking

**The status table below is the single source of truth.** Update the Status column there when a
proposal moves; the detail sections carry no status of their own. Statuses are `open`,
`in progress`, `deferred` (with a reason), and `dropped` (with a one-line reason). Add the date and,
where useful, the commit or ticket, e.g. `implemented 2026-08-02 (a1b2c3d)`.

IDs are stable. Re-rank the table freely as understanding changes — never renumber.

**Archive on implementation.** The moment a proposal is implemented, move it out of this file:
cut its `## Pn · …` section and its table row, append both to `PROPOSALS_ARCHIVED.md` (sections in
ID order), and set the row's status to `implemented <date> (<what shipped>)`. Do not leave an
implemented row here pointing elsewhere — a stub is still a line to read. This file should answer
"what is left to do" and nothing else, so it stays short enough to read in full before proposing
anything new.

Only `open`, `in progress` and `deferred` proposals live here. A `deferred` one stays because it is
still a live decision that could be revisited; a `dropped` one is archived like an implemented one,
with its reason.

**Stay inside this skill.** Every proposal here is implemented using only the `/loom`
skill's own files — `SKILL.md`, `scripts/`, `references/`. The sibling skills this one routes to
(`/to-tickets`, `/implement`, `/code-review`, `/grilling`, `/lavish`, `/prototype`) are **off
limits**: they are shared by other work, and `/loom` is a consumer of them, not their
owner. Constitution rule 2 — *route, do not teach* — cuts both ways.

If a fix looks like it needs a change in one of them, re-scope it into this skill's own layer
rather than reaching across. That layer already exists and is the intended seam: phase 4 routes
to `/to-tickets` **plus** the additions in `references/ticket-template.md`, and the wave composes
every session prompt itself. Anything that cannot be re-scoped that way is dropped, not deferred.

One boundary worth stating, because it looks like an exception and is not: the machinery writes
files into the *target repo* (`.claude/settings.json`, `scripts/gate.sh`) and the machine
(`~/.loom/config.yml`). That is this skill doing its job on its subject, not a change to
another skill.

**Keep SKILL.md small.** SKILL.md is loaded into every wave, so every line it grows is a tax on
every session forever. Implement a proposal in the machinery — `tick.sh`, `bootstrap.sh`, the
generated config — wherever the machinery can carry it, and add to SKILL.md only what a wave
must *decide* and cannot derive. Prefer deleting or tightening an existing line to appending a
new one; a rule the scripts already enforce does not need restating in prose. Rationale,
evidence, and implementation notes belong in this file, not there.

| ID | Proposal | Status |
|----|----------|--------|
| P85 | Sweep reports what it kept | open — proposed 2026-08-09; sweep prints "kept, needs a human" to the wave log, emits no event, and reaches no human surface. It announced this problem on every tick for five builds and nobody saw it |
| P81 | The wave's scheduling is a pure function of the snapshot | open — proposed 2026-08-08; steps 2–6 read fields `snapshot.jq` already derives and add no information. A ticket becoming ready waits one whole wave (2m28s average, 36 of them, 57.5% of the seat-reservations span) for a model to re-derive a decision the document already contains. Supersedes the scheduling half of P18 |
| P54 | The wave reads the snapshot once | deferred 2026-08-06 — P51 cut the read it targets from ~19k to ~4k tokens and P57 halves it again, so the estimate fell from 4-6% to about 1%; it fixes no correctness problem. Revisit on the `retro` wave line of the first post-P51 build, against the pre-P51 baseline `retro` now reports for boostlingo build-3: waves $358.14 of $1482.32, 24% |
| P45 | A test must prove it can fail | open — proposed 2026-08-06; 12 vacuous or misdirected tests in a 430-green suite, two of them guarding the only unbounded `rm -rf` |
| P50 | `references/loom-config.md` is generated from `resolve-config` | open — proposed 2026-08-06; three read keys undocumented, four documented facts false |
| P18 | Use a cheaper model for scheduling | open — fresh number 2026-08-03: 36 waves, 1h29m, 57.5% of span |
| P19 | Cut the repeated advisory noise | open |
| P20 | Parallelise the human-gated front half | open |
| P24 | Supervised lanes (part B of "watch a lane") | open — staged behind evidence: build only if watching leaves a real intervention gap; part A archived 2026-08-02 |
| P29 | Model-level observability: LangFuse ingest of lane OTel exhaust | open — proposed 2026-08-02 |
| P77 | The snapshot's per-ticket fan-out grows with the board | open — proposed 2026-08-07; two reads per open member plus one per active member, eight at a time, so ~250 calls per snapshot at 100 tickets and two snapshots per wave. `--brief` trimmed the output, not the reads. Structural finding, never measured — the biggest build on disk is 7 tickets |

## What the evidence says

The newest measured build is **seat-reservations build-1** (2026-08-03 20:47 → 23:23): **2h35m**,
**7 tickets merged**, both epic probes PASS, self-teardown clean. It is not comparable span-for-span
with the boostlingo baseline below — different repo, different gate suite — so read it for its
*shape*, not its total.

| Slice | Time | Share |
|---|---|---|
| Inside wave sessions — 36 waves, 0 failed, 0 retried | 1h29m | 57.5% of span |
| Lane time — 46 lanes, peak 5 concurrent | 3h29m | 134.5% of span |
| Rework: lane time that produced nothing (11 rework lanes, 0 crashes, 0 rc-7) | 55m40s | 26.5% of lane time |
| Impl capacity starved (slots free, nothing ready) | 1h53m | 72.7% |
| Impl capacity slack (slots free **and** work ready) | 42m30s | 27.3% |
| Impl capacity at capacity (`max_lanes` binding) | 0s | 0% |

The loop itself was healthy: zero crashes, zero mechanical rejections, zero failed waves, and the
impl → gate → merge chain handed off in 2–3 seconds every time across 46 lanes. What cost the
build time was everything *around* the loop.

**Starvation was mostly human-block, not graph.** The graph was 4 deep; the actual chain was 2. The
single largest slice of the 1h53m starved is the window **21:50 → 22:55 (1h04m50s)** during which
at least one ticket sat `blocked` waiting on a human — #2 for 64m50s, #5 for 26m41s, #21 for 21m2s.
None of those blocks were caused by the tickets' own code. They came from two tooling defects:

- **Merge lanes had no verb to call.** `lane.sh` had no `merge`, so gate lanes composed merge briefs
  that hand-rolled `glab mr merge`, which the permission classifier denies. A wave named it
  "systemic" at 21:39:46. **6 of 14 merge lanes failed**; three tickets ended up blocked. Separately,
  `merge-1` closed #1 while MR !1 was still open — a wave spent ~3 minutes recovering it at 21:09:52,
  with four lanes seconds from branching off a base that did not contain #1. *Fixed 2026-08-03:
  `lane.sh merge` (merges, verifies GitLab reports `merged`, then closes) plus a `close` guard.*
- **The repo root was untrusted, and the guard that exists to catch that missed it** — because it
  walks filesystem ancestors and this skill puts worktrees *beside* the repo, not inside it.
  *Fixed 2026-08-03 (P30, archived): the guard asks the git repo root's question too; `spawn-lane`
  refuses the first lane instead of the first merge, and bootstrap treats untrusted as incomplete.*
- **A stale snapshot blocked a merged ticket.** #23 merged at 22:23:17 and a wave blocked it at
  22:24:29, then a later wave requeued the closed ticket to `ready-for-agent`. *Fixed 2026-08-03:
  `merge-failed` refuses when a merged MR closes the ticket; `transition` refuses any closed ticket.*

**Slack sits at the front of the build.** Two windows carry 16m25s of the 42m30s: build start →
`impl-1` spawned (20:47:31 → 20:54:50, **7m19s**), and #1 closing → its four dependents spawned
(21:09:44 → 21:18:46, **9m02s**, ~3 min of it the MR-!1 recovery, then 3m22s to build four
worktrees). Every later ready→spawn was 1–3 minutes, because a wave was usually already running.
The residue is the cost of a wave itself — **2m28s average, 36 of them** — which is P18's number.

**P3 was never armed, and this time it did not matter.** `/loom start` was never run; the
build survived entirely on lane self-triggers, and not one of 36 waves fizzled. One build does not
retire P3 — its claim is that the backstop matters exactly once, when it is the only thing left
alive — but this is the first measured build where the chain held end to end unaided.

`max_lanes` never bound here either (0s at capacity), matching boostlingo. Raising it still buys
nothing.

---

The prior baseline is **build-1** (boostlingo-ai-interpreter-workbench, 2026-08-01 23:24 →
2026-08-02 12:28) — the first build measured by `tick.sh retro` itself rather than reconstructed
by hand, exactly as P23 intended. It took **13h27m** to merge **three tickets**:

| Slice | Time | Share |
|---|---|---|
| Inside wave (scheduler) sessions — 22 waves | 6h0m | 44.7% of span |
| Lane time — 28 lanes, peak 5 concurrent | 5h5m | 37.8% of span |
| Rework: lane time that produced nothing (3 crashes + verdictless re-gates) | 3h48m | 74.8% of lane time |
| Impl capacity starved (slots free, nothing ready) | 12h50m | 95.4% |
| Impl capacity at capacity (`max_lanes` binding) | 0s | 0% |

`max_lanes` never bound; raising it buys nothing. The actual chain ran exactly as deep as the
graph (2) — but neither number is the story. The story is one ticket: **#1 sat in `review` from
00:10 to 10:24**, ten hours for a review whose two healthy rounds took 228 s and 105 s. The night
decomposes into: **~7h of sessions wedged on a dead API stream** with nothing bounding them in
wall-clock time (P27); **2h08m of dead air** after wave-074603 fizzled with no heartbeat armed
(P3, re-opened); and 30 min of healthy loop that finished #1 the moment the human armed the
backstop at 09:54. Everything after that — #1 merged, #2, #3, the epic probe, completion report,
self-teardown — took 2h34m, of which 80 min was ticket #2 correctly `blocked` waiting for a human
to supply provider API keys. The loop at health is fast: #3 went `in-progress` → merged in 11
minutes.

What this build did *not* re-confirm from crucible: no session-limit blackout (0s), no scheduler
serialization — waves themselves were cheap except where the API wedged them. What it retired:
the crucible-era worry that the heartbeat interval doesn't matter. It matters exactly once — when
it is the only thing left alive — and that once cost two hours.

The prior baseline (crucible Build 2, 2026-07-21: 3h50m, six tickets, hand-reconstructed from 31
transcripts; waves 1h21m / 35%, one 57m blackout, peak concurrency 2 of 4, a scheduler costing
~100× the 4-second work it scheduled) remains the evidence base for P18–P20. The two repos' gate
suites differ too much for the spans to be compared directly.

---

## The worktree pile-up — evidence shared by P82–P85

All four were found on 2026-08-09, on `ai-interpreter-workbench` immediately after build-5
completed and tore its agent down. Five builds had run in that repo. Cleanup had never once
happened:

| Leftover | Count |
|---|---|
| Worktrees under `<repo>-wt-*` | 30 (plus 2 orphan directories git no longer tracks) |
| Remote `origin/ticket-*` branches | 122 |
| Local `ticket-*` branches | 51 |
| Worktrees sweep has ever removed | 0 |

Sweep was neither broken nor disabled — it ran on every tick and correctly declined to touch all
30, because each one trips one of its two safety guards. Both guards exist for good reasons and
both are paid for by real incidents. What is wrong is that the loop *manufactures* the conditions
that trip them, so the guards fire on every worktree rather than on the rare unsafe one. P82 and
P83 remove those two conditions. P84 covers branches, which no step owns at all. P85 is why it
stayed invisible for five builds.

## P85 · Sweep reports what it kept

**Problem.** Sweep announces every decision to `stdout` inside a wave session — "kept, needs a
human", "git refused to remove", "removed merged worktree". A wave's stdout goes to its log file.
Sweep emits no event, so nothing it says reaches `render-events`, `watch`, the ntfy pushes, or the
completion report.

For five builds in `ai-interpreter-workbench` it printed a "kept, needs a human" line for every
worktree on every tick — the correct message, addressed to a human, into a file no human reads. The
build-5 completion report was posted and the agent unloaded itself with 30 worktrees, 51 local
branches and 122 stale tracking refs standing, and said nothing about any of them. (An earlier
draft of this section said "173 branches", combining two counts that are not the same thing — see
P84, where the 122 turn out to be tracking refs rather than branches.)

This is the reason P82, P83 and P84 went unnoticed rather than being fixed after build-1.

**And a third failure mode outlives both fixes.** `ai-interpreter-workbench-wt-26` survives the
cleanup as a 12 KB husk: the worktree is merged, clean, and correctly identified, and removal still
fails because `web/node_modules` and `server/.venv` are empty directories that refuse `rmdir` with
EPERM despite being user-owned and unflagged — almost certainly stale Docker Desktop mounts. Sweep
already handles this correctly, printing "git refused to remove — kept". P82 and P83 do not touch
it, and nothing else will: after they land, this is the residue class that remains, and it is
invisible for exactly the reason this proposal exists.

**Fix direction.** Two changes, both small:

- Sweep emits one `sweep_held` event per pass carrying the count and the dominant reason, and a
  `sweep_removed` event when it removes. The ticker then shows cleanup the same way it shows
  everything else, and a count that never falls is visible within one build.
- The completion report states the leftover inventory — worktrees held and why, branches merged but
  not deleted — before the build tears itself down. A build that reports complete while leaving 30
  worktrees behind is reporting on part of its own work.

Neither adds a decision for a wave to make, so neither costs a `SKILL.md` line.

**Tests.**

- A sweep pass that holds worktrees emits exactly one `sweep_held` event carrying the count and the
  dominant reason — one per pass, not one per worktree; shown failing when the emit is removed.
- A pass that removes emits `sweep_removed`; a pass that does neither emits nothing.
- `render-events` renders both. This is the load-bearing one: **D-TICK-11 is open** — the renderer
  indexes on `.state` and silently drops any event without it, so a new event that omits `state`
  would be invisible in exactly the pane this proposal exists to reach. Assert the rendered line,
  not the log line.
- The completion-report path names the leftover inventory when there is one, and says nothing when
  the sweep is clean.
- A worktree whose removal `git` refuses — the filesystem case, fixtured with a directory that
  cannot be removed — is reported like any other hold, rather than being the one kept worktree the
  ticker stays silent about.

**Consumer.** The human, who currently discovers this by looking at their own filesystem months
later.

## P81 · The wave's scheduling is a pure function of the snapshot

**Problem.** A wave is a model session, and steps 2–6 of SKILL.md's `tick` are a decision table
written in prose for it to follow. Every input to that table is already computed, deterministically,
by `snapshot.jq`: `gate.eligible` with its `reason`, `summary.stranded`, `summary.impl_slots_free`,
`summary.merge_in_flight`, `.merge_hold`, `.merge_attempts`, `rejections.same_class_tail`,
`.model.effective`, `summary.epics_awaiting_probe`. The wave reads those fields and applies rules
that are total — rework before new work, `fix:` before the rest of the ready set, oldest
`merge-queue` ticket, cap exhausted means block. It adds no information the document does not
already carry. What it costs is a full model session between "a ticket became ready" and "a lane
exists for it".

**Evidence.** Two independent measurements already in this file.

*Latency*, seat-reservations build-1: 36 waves, **1h29m, 57.5% of a 2h35m span**, averaging **2m28s
each**. The slack analysis in "What the evidence says" isolates the residue after the two
front-of-build windows are removed and names it exactly — "a merge lane fires the next tick in
seconds, then the wave it wakes takes minutes to decide anything". Every later ready→spawn in that
build was 1–3 minutes, and the loop was otherwise healthy: 0 crashes, 0 mechanical rejections, 0
failed waves, impl→gate→merge handing off in 2–3 seconds across 46 lanes. The wave *is* the
latency.

*Spend*, boostlingo build-1: wave sessions cost **$683 of $3,404 (20%)** across **407 sessions
averaging 28 turns at 118k context per turn**. The same section establishes that cost is
`context × turns × sessions`. A planner attacks two of those three terms at once — a wave that
executes a prepared plan is a handful of turns instead of 28, and a wave with an empty residue does
not need to launch at all.

Neither number is a prediction: both are `retro` output over real builds. What is *not* measured is
how much of the 2m28s survives the change — some waves will still have residue to write. Measuring
that split is the first job of any implementation, not an assumption to build on.

**Fix direction.** Split the wave in two along the line the design already draws — *models judge,
scripts plumb*.

- **`tick.sh plan`** — read-only, takes a snapshot document, emits one JSON document: `.actions[]`,
  each a fully-formed instruction (`spawn` with its id, cwd, model, brief inputs and pregate tier;
  `clear-lane`; `kill-lane`; `transition … blocked`; `merge-failed`), and `.residue[]`, the items
  that need prose a script cannot write. Every rule it encodes is one already written in SKILL.md
  steps 2–6.
- **The executor runs the actions.** Spawning is already `tick.sh spawn-lane`; every *tracker* write
  in an action goes through the `lane.sh` verb that owns it. This is load-bearing: `tick.sh` is
  read-only against the tracker and `scripts/tests/07-snapshot.sh` enforces it by checking every
  captured argv against a mutating denylist.
  `plan` must not become the exception that dissolves that guarantee — it derives, it does not
  write.
- **A model session launches only for the residue**, and receives the residue alone rather than the
  whole board.
- **SKILL.md shrinks.** Steps 2–6 stop being prose a wave interprets and become "run the plan, then
  handle the residue". That is a line *reduction* in the file every session loads — the preamble's
  "keep SKILL.md small" pulls the same direction as the fix rather than against it.

**The plan is derived and disposable, like the snapshot.** It is never written anywhere a later run
reads it back as state; constitution rule 1 is the reason, and a plan file that outlived its wave
would be exactly the shadow state that rule forbids.

**What stays a model, and should.** The gate verdict, the implementation, the probe, merge-conflict
surgery, the blocked report, the completion report. Those are the four lane kinds plus two report
writers — the work worth paying for. This proposal removes none of it; it stops paying a model to
read a table.

**Relationship to the neighbours.** P18 has two halves: a cheaper model for scheduling, and fewer
scheduling turns. This proposal supersedes the second half and makes the first half cheap to keep —
`wave_model` still applies to whatever residue remains. P54 and P77 both shrink the snapshot a wave
must carry; a planner that reads the document in `jq` rather than into context makes P54 moot for
the scheduling path specifically, and leaves P77's call count exactly where it is. Do P18's config
change first: it is one line and costs nothing to try.

**Tests.**

- `plan` over a fixture snapshot emits the same actions the SKILL.md steps prescribe, one case per
  step: a `dead` lane at rc 7, a `stale` lane, a stranded ticket with `same_class_tail` at 1 and at
  2, a ready set with `fix:` and non-`fix:` members and fewer slots than candidates, two
  `merge-queue` tickets one of which holds a `merge_hold`, an epic in `epics_awaiting_probe`.
- Ordering is asserted, not incidental: rework outranks backlog, `fix:` outranks the rest, oldest
  merge-queue wins.
- `plan` makes no mutating call — the existing argv scan extended to the new code path, shown
  failing once the guard is removed.
- An action naming a lane id `spawn-lane` would refuse is a planner bug, and the suite catches it
  at plan time rather than at spawn time.
- A snapshot the planner cannot read produces an empty plan and a named reason, never a partial one.

**Consumer.** The `tick` verb, which currently pays a model session per scheduling decision; and
`retro`, whose wave line is the number this is judged on.

## P18 · Use a cheaper model for scheduling

No model is specified anywhere in the skill. Deciding "this lane is dead, clear it, start the
next ticket" does not need the model that reviews code.

**Evidence (seat-reservations build-1).** 36 waves cost **1h29m — 57.5% of a 2h35m span**, averaging
**2m28s each**, and 24 ticks landed mid-wave (13 replayed). Wave cost is also what is left in the
slack number once the two front-of-build windows are removed: a merge lane fires the next tick in
seconds, then the wave it wakes takes minutes to decide anything.

**Fix.** Set `--model` per lane type: strong for gates, fast for waves and harvest.

## P19 · Cut the repeated advisory noise

**Evidence.** Eight of thirteen waves re-issue the same "arm the heartbeat" advisory, and the
"#19/#20 lack the `build-2` label" observation is rediscovered and re-reported in W1, W5, W7 and
W11. That is scheduler time spent restating unchanged state.

**Fix.** Largely dissolves with P7's snapshot plus an "acknowledged" section in the Build issue
that waves read and do not re-derive.

## P20 · Parallelise the human-gated front half

Phases 1–2 grill architecture to closure and then "repeat" the same process for UI/UX. Where
UX questions do not depend on unresolved architecture questions, both `/lavish` surfaces can go
to the human in one review round instead of two — human round-trips dominate that phase.
Similarly, phase 4 writes every epic's tickets in one session, when epics are largely
independent once interfaces are pinned: fan out one sub-agent per epic with the pinned
interfaces and ADR set injected, then reconcile the edges in a single pass. `/code-review`
already uses that shape.

## P24 · Supervised lanes (part B of "let a human watch a lane")

Part A (read-only live viewing: `render-log --follow`, `watch-panes.sh`, the
`watch` verb opening panes) is implemented and archived — the full design
record, the rejected pane-agent alternative, and the four planted violations
live in [PROPOSALS_ARCHIVED.md](PROPOSALS_ARCHIVED.md).

What remains open: `spawn-lane <id> --supervised` — run one lane
interactively in the foreground for the debugging case where watching is not
enough and the human must answer or redirect a session. Two guards from the
original design still bind: its `.rc` must feed no automatic path (no
self-trigger, no rc-7 verdict; resolve by hand), and `--supervised` is
mutually exclusive with `--merge-lock`. A wave must never emit it.

**Build it only if evidence demands it**: a real build where read-only
watching left an intervention gap that killing + respawning could not cover.
No build has produced that evidence yet.

## P29 · Model-level observability: LangFuse ingest of lane OTel exhaust

A complement, never a replacement. Everything the skill logs today is
control-plane plumbing the machine itself reads — the tracker (the only build
state, constitution 1), `events.jsonl` (the ticker's offline, zero-dependency
feed), lane logs/`.jsonl` (rc codes, progress stamps, crash forensics the
harvest depends on). None of it can move to a network service. What none of it
contains is *model-level* telemetry: tokens, cost, per-call latency, retry
spans. LangFuse (self-hostable, ingests OpenTelemetry) would add exactly that
layer as exhaust.

**Evidence.** All 2026-08-02, build-3: (a) every worker silently ran on the
top-tier model until the human noticed by reading a config comment — a spend
dashboard makes that an anomaly, not archaeology; the same day a wave nearly
repeated it because the model keys weren't surfaced by `resolve-config`;
(b) "where did impl-13's 35 minutes go" was answerable only by reading the
transcript; (c) the staleness watcher *infers* retry storms from filtered log
chatter — traces would carry them as first-class spans.

**Fix sketch.** One seam: `spawn-lane`. When `~/.loom/config.yml`
carries a `langfuse:` block (OTLP endpoint + key env refs), `spawn-lane`
exports the Claude Code telemetry env (`CLAUDE_CODE_ENABLE_TELEMETRY=1`,
`OTEL_EXPORTER_OTLP_*` — verify the exact env surface per Claude Code
version) plus resource attributes into each lane: build label, lane id,
ticket, tier, round. Every session then groups itself by build/ticket in the
LangFuse UI with zero per-lane work. No config block → nothing exported;
bootstrap seeds nothing.

**Guards (constitution-shaped).**
- *Fire-and-forget*: an unreachable LangFuse must never fail, slow, or block
  a wave or lane. The exporter is exhaust, not a dependency.
- *No shadow state*: nothing in the skill ever reads LangFuse back to make a
  scheduling decision. Tracker stays the only truth.
- *Named consumers*: the human's cost/latency dashboards, and `retro`, which
  may cite spend-per-ticket and in-lane latency splits alongside its
  wall-clock numbers.

**What would falsify it.** A lane or wave that errors or measurably slows
with the collector down (seam built wrong), or dashboards nobody has opened
after two instrumented builds (artifact without a consumer — drop it).


## P45 · A test must prove it can fail

**Problem.** The suite is green at 430 and its trustworthiness did not grow with its size. Twelve
tests were found on 2026-08-06 that cannot fail, or prove something other than what they name.
The two worst guard the two most destructive mechanisms in the program: `tick-test.sh:394-397`
never invokes `tick.sh` at all (it asserts on a `case` statement it writes itself inside
`bash -c`, so deleting the guard in front of the only unbounded `rm -rf` leaves it green), and
`tick-test.sh:2902-2906` greps for event-log readers matching `(<|read|cat|jq…)`, so it cannot
see the two `tail`/`grep` readers already in production. Three watch-panes planted violations
assert only the absence of a call, and pass against a stand-in that is `exit 127`. The
`ok`-in-both-branches pattern killed in the ntfy block on 2026-08-01 survived at
`tick-test.sh:2361-2363`.

The `tick-test.sh:<line>` citations above are from 2026-08-06, when the suite was one file at 430
tests. They no longer resolve — the suite grew, and P76 then split it into
`scripts/tests/NN-<topic>.sh`. Find each test by the string it asserts; the sections are named
after their subject, so the search is narrow.

**Fix direction.** Make vacuity mechanically detectable rather than a review finding:

- A `--mutate` mode that, for a named set of production lines (the guards, the destructive
  paths, the caps), deletes or inverts the line in a scratch copy and asserts the suite goes
  **red**. A test that stays green over its own mutation is reported by name. Run it in `qa`,
  not on every suite run.
- Every planted-violation test asserts the mutated copy *ran* — the `[ "$rc_n" = 0 ] && ok`
  shape already used at `tick-test.sh:3498` — before asserting what it no longer does.
- A lint pass over the suite banning `|| ok`, and banning an `ok` whose condition contains only
  the loop variable that produced it.
- Where a test asserts "no mutation reached the tracker", assert on the shape every mutation in
  this codebase actually takes (`glab api --method PUT|POST|DELETE`), not on `glab` subcommands
  nothing uses.

**Consumer.** `qa`, which currently has to find this by reading 4,435 lines.

## P50 · `references/loom-config.md` is generated from `resolve-config`

**Problem.** The file that calls itself the canonical config schema is wrong in both directions.
Undocumented but read: `max_aux_lanes`, `merge_attempt_cap`, `min_wave_gap_minutes` — the last of
which is the primary spend control. Documented but false: the heartbeat is 60s, not the stated
900s; the generated allowlist has no `cd` rule, and deliberately so; `tick.sh` does read the
`gates:` key, to build that allowlist; `runner` is a settable repo key presented as derived only;
`ticket_done`/`ticket_review`/`mr_merged` are listed as push events nothing emits; and
`resolve-config`, sold in two files as "the effective config", emits no `ntfy` block at all.

**Fix direction.** `resolve-config` grows a `--schema` mode printing every key it reads with its
default, source layer and accepted values, and `loom-config.md`'s schema block is that output with
prose around it. `ntfy` resolution moves into `resolve-config` so one command really does answer
"where do pushes go". A suite case diffs the documented key set against the emitted one.

## Token spend — the measurement these six proposals come from

Measured 2026-08-06 against the full boostlingo build-1 log set
(`~/.loom/boostlingo-ai-interpreter-workbench-2061292512/logs/`, 780 sessions,
81 tickets), by summing `message.usage` per session and pricing each message at its own
model's published rate. Total: **6.17B cache-read, 169M cache-creation, 12.6M output
tokens ≈ $3,404 API-equivalent.**

| Session kind | Cost | Share | Sessions | Avg turns | Avg context/turn |
|---|---|---|---|---|---|
| impl lanes | $1,948 | 57% | 139 | 119 | 202k |
| wave sessions | $683 | 20% | 407 | 28 | 118k |
| gate lanes | $423 | 12% | 121 | 92 | 66k |
| probe lanes | $239 | 7% | 22 | 162 | 164k |
| merge lanes | $111 | 3% | 91 | 30 | 75k |

**86% of the bill is cache read plus cache creation, so cost is context size × turns ×
sessions.** Only those three terms are worth optimising. Two things that look expensive
and are not: ticket bodies run ~1,500 characters (~400 tokens) and account for roughly
0.1% of a build even though they sit in context for every turn of every lane; and
`SKILL.md`, loaded in full by all 780 sessions, is about 1% of spend — worth keeping small
for readability, but it is not where the money is.

Three findings were config changes rather than proposals, and were applied to
`~/.loom/config.yml` on 2026-08-06: `rejection_cap` 3 → 2, `rework_model` opus → sonnet
(19 impl reworks and 35 re-gates in that build, one of them a round-4 Opus lane costing
102M cache reads on its own), and `min_wave_gap_minutes` 10 → 20.

## P54 · The wave reads the snapshot once

**Problem.** SKILL.md step 1 says to re-run `snapshot` after the wave's own writes rather
than query piecemeal, and that instruction is correct — the stale-snapshot failures in step
2 are what paid for it. But the wave obeys it by re-reading the whole document into context,
so a 15k-token input lands twice in a session that averages 28 turns, and both copies are
re-read on every turn after.

**Fix direction.** Have the wave write the snapshot to a file (`tick.sh snapshot --out
<path>`, or a fixed path in the run directory) and read what it needs with `jq` — the
re-read after writes then costs one field, not one document. The existing `jq` allow rule
covers it and the guarded paths in SKILL.md's optimize list are already jq paths. Largely
subsumes itself into P51: with `--brief` the second read is much cheaper anyway, so
implement P51 first and re-measure before doing this one.

## P77 · The snapshot's per-ticket fan-out grows with the board

**Problem.** `cmd_snapshot` makes three kinds of per-ticket read: one `links` call for every
open build member, one `notes` call for every open build member, and one
`related_merge_requests` call for every *active* member. They run eight at a time
(`SNAP_BATCH`, `tick.sh:101`). The count is therefore linear in board size, and P51's `--brief`
did not touch it — `--brief` trims what the snapshot *prints*, not what it *reads*, and the
notes scope was deliberately widened to full membership twice (the comment at the
`review_iids="$member_iids"` assignment records both reasons, the second being #47's lost
rejection history). So a 100-ticket board costs roughly 250 calls per snapshot, and a wave takes
at least two snapshots — the second is mandatory after the wave's own writes.

**Evidence.** Structural, not measured: this is read off the call structure in `cmd_snapshot`,
not off a timed run. The largest measured build on disk is seat-reservations build-1 at 7
tickets. Nothing here has ever been exercised near 100 members, so the cost is a prediction and
the first job of any implementation is to measure it. Say so rather than quoting a number.

**Fix direction.** Cache the two per-member reads in the run directory, keyed on the issue's
own `updated_at` — which the open-issues list read already returns, at no extra call. A ticket
whose `updated_at` has not moved since the last snapshot cannot have gained a comment, so its
cached `notes` payload is exact rather than heuristic, and the read is skipped entirely. On a
board where most tickets are quiet between waves this collapses the fan-out to the handful that
actually changed.

Two things to settle *before* writing code, both cheap to check against a live tracker:

1. Does adding or removing an issue **link** bump the issue's `updated_at`? Notes certainly do.
   If links do not, the links cache needs a different key — or links stay uncached and only the
   notes half is cached, which is still half the calls.
2. What the cache costs on a cold run, and whether the win survives the extra file I/O at small
   board sizes. If it does not, gate it on member count.

The cheap partial, if the cache proves not to be worth it: raise `SNAP_BATCH` from 8. It is
already an environment override, so this is a default change, not new machinery — but it trades
wall clock for rate-limit exposure and should not be raised blind.

Constitution note: the cache is disposable derived data and belongs in `~/.loom/<repo>/` beside
the other run-directory plumbing, never in the tracker. A missing or stale cache must always
degrade to the read it replaced — the snapshot already has that shape in `_snap_api`, which
falls back to `[]` with a warning rather than failing the document.

**Consumer.** Every wave, on any build big enough to matter; and `watch`, which takes the full
snapshot rather than `--brief`.
