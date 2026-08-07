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
| P54 | The wave reads the snapshot once | deferred 2026-08-06 — P51 cut the read it targets from ~19k to ~4k tokens and P57 halves it again, so the estimate fell from 4-6% to about 1%; it fixes no correctness problem. Revisit on the `retro` wave line of the first post-P51 build, against the pre-P51 baseline `retro` now reports for boostlingo build-3: waves $358.14 of $1482.32, 24% |
| P31 | Make the mandatory adversarial test a checkable deliverable | open — reproduced 2026-08-06 in a second, unrelated repo: 4 of 7 gate rejections, in a new sub-shape the proposed pregate check cannot see |
| P60 | A gate command may never depend on an unmerged ticket's deliverable | open — adopted 2026-08-07, ai-workout build-1: ~8 incidents, ~1h halt; tranche 3 (before next ticket generation) |
| P64 | Every epic ends with a wiring ticket | open — adopted 2026-08-07, ai-workout build-1: E1 probe found the epic's whole point unwired; tranche 3 |
| P45 | A test must prove it can fail | open — proposed 2026-08-06; 12 vacuous or misdirected tests in a 430-green suite, two of them guarding the only unbounded `rm -rf` |
| P50 | `references/loom-config.md` is generated from `resolve-config` | open — proposed 2026-08-06; three read keys undocumented, four documented facts false |
| P58 | Phase 4 drafts the whole set, then checks its own output once | open — proposed 2026-08-06; nine cross-ticket ambiguities in a 54-ticket set, none visible from inside one ticket; folds in the width and size rules, which check the same draft |
| P18 | Use a cheaper model for scheduling | open — fresh number 2026-08-03: 36 waves, 1h29m, 57.5% of span |
| P19 | Cut the repeated advisory noise | open |
| P20 | Parallelise the human-gated front half | open |
| P24 | Supervised lanes (part B of "watch a lane") | open — staged behind evidence: build only if watching leaves a real intervention gap; part A archived 2026-08-02 |
| P29 | Model-level observability: LangFuse ingest of lane OTel exhaust | open — proposed 2026-08-02 |

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

## P31 · Make the mandatory adversarial test a checkable deliverable

`references/ticket-template.md` asks every ticket for "Mandatory adversarial tests". The gate then
enforces that in prose, one expensive review round at a time.

**Evidence (seat-reservations build-1).** Five gate FAILs in the build. **Four were the same
family** — the mandatory adversarial test was not real, enforced coverage:

| Ticket | Round | Class the gate named |
|---|---|---|
| #2 | 1 | `missing-adversarial-test` |
| #2 | 2 | `adversarial-test-not-wired-to-gate` |
| #21 | 1 | `missing-adversarial-test` |
| #21 | 2 | `adversarial-test-skipped-in-ci` |
| #4 | 1 | `scope-creep` (the odd one out) |

Each round produced a *nearer miss*: absent → present but not on the tier's command list → on the
list but silently skipped in CI. Three rounds to converge on "the test must actually run." Total
rework was **11 lanes, 55m40s, 26.5% of all lane time**; #2 and #21 alone account for 5 gate lanes
and 5 impl lanes of it.

**Fix, in two halves.** *Ticket side* (`references/ticket-template.md`, this skill's own layer):
the section stops being prose and states the three conditions the implementer must satisfy — the
test is committed, it is **named in the tier's command list in `.loom.yml`**, and it is
demonstrated to fail when its subject is broken. *Pregate side* (`tick.sh --pregate`): when the
ticket body carries a non-empty adversarial-test section, check mechanically that the branch's diff
adds or modifies at least one file named in that tier's command list, and exit 7 if not.

That mechanical check would have caught three of the four — #2 r1, #21 r1, #2 r2 — at rc 7 in
seconds instead of spending **787s (13m07s)** of review-session time on `gate-2`, `gate-21` and
`gate-2-r2`. It cannot catch the fourth (`adversarial-test-skipped-in-ci`); judging whether a test
that runs actually asserts anything stays a review job.

**One limit worth recording, which is not a fix.** The `same_class_tail` ≥ 2 rule never fired,
because each round's gate coined a fresh slug for what a human reads as one problem. Here that was
the right outcome — round 3 passed on both tickets, so blocking at round 3 would have been strictly
worse. Do not tighten slug matching on this evidence.

**Reproduced 2026-08-06 in a second repo, in a shape the pregate half cannot see.**
ai-workout-generator-copilot build-1, first 20 gate verdicts: 13 PASS, 7 FAIL. **Four of the seven
are this same family** — and unlike seat-reservations, every one of the four *did* commit a test
that `pytest` already runs.

| Ticket | Class the gate named | What was actually wrong |
|---|---|---|
| #3 | `adversarial-test-mismatch` | test present, asserting a different thing than the bullet |
| #25 | `missing-adversarial-check` | one of the ticket's bullets had no test at all |
| #31 | `duration-budget-both-ends` | two-sided bound, only the upper half asserted |
| #5 | *(no slug — see below)* | boundary test written for `/api/plan`, not for `/api/plan/adjust` |

This is a different failure shape from the first build's. There the family was *absent → not on the
command list → skipped in CI*; the mechanical pregate check catches all three of those. Here the
test is committed, is on the tier's command list, does run, and passes — it just does not assert
what the bullet says. **The proposed pregate check would have caught none of the four**, because
"the diff adds or modifies a file on the tier's command list" is true for every one of them. The
four cost `gate-3` 201s, `gate-25` 291s, `gate-31` 253s and `gate-5` 370s — **1115s (18m35s)** of
review-session time, plus four rework rounds.

Note the pregate did not run at all in this build: `scripts/gate.sh` is itself a build-1 ticket
(#7, "Gate runner and CI"), and a missing runner is skipped rather than failed. So this build tests
the *ticket-side* half of the fix and says nothing either way about the rc-7 saving.

**What the second build adds to the fix — a third condition on the ticket side.** Committing a test
is not the deliverable; covering each bullet is. Require the implementer to state the mapping —
each bullet in `## Mandatory adversarial tests` → the name of the test function that asserts it —
in
the MR description, and to treat a bullet with no name beside it as unfinished work rather than a
lane note. That makes both omission (#25, #5) and partial coverage (#31, #3) visible to the
implementer before push, without asking a script to judge whether an assertion is meaningful. It
also stays inside this skill's layer: the section wording is `references/ticket-template.md`, and
the mapping requirement is one line in the implementer brief the wave already composes.

**And a named path for an unsatisfiable bullet.** #31's mandatory test was not skipped out of
haste — it is *unsatisfiable* against the constants ADR-0015 pins: the required band could not be
met for 162 of 166 accepted inputs. The lane diagnosed that correctly, disclosed it in both the
test docstring and the MR description, and deferred — and still spent a full gate round to be told
so. A bullet the implementer can prove cannot be satisfied should end the lane in `blocked` with
that proof, not in `review`. Cheap to state, and it is the one case where more rounds cannot help.

**One more limit, consistent with the first build's.** #5's FAIL verdict carried no `class=` slug
at all, so `same_class_tail` had nothing to match on. Two builds now show the same-class stop
failing to engage for two different reasons — fresh slug per round there, no slug here. Neither is
an argument for tightening slug matching; both are arguments for not relying on it as the backstop
for this family.

**What would falsify it.** A build where re-gate lane count does not drop, or where the pregate
check exits 7 on a branch the review gate would have passed — a false rc 7 is more expensive than
the round it saves. For the ticket-side half specifically: a build where implementers publish the
bullet-to-test mapping and this family still accounts for over half the rejections, which would
mean the gap is comprehension of the bullet rather than accounting for it.

**Final build-1 tally (ai-workout, 2026-08-07).** The build finished its run at 11 first-round
FAILs in 41 verdicts; the family held at 4 of 11 (#3, #25, #31, #5) plus one late relative, #13's
`adversarial-test-gap`. No change to the fix; the evidence base is now three builds.

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

## P58 · Phase 4 drafts the whole set, then checks its own output once

**Problem.** Phase 4 routes to `/to-tickets`, whose step 5 publishes one issue per ticket in
dependency order. Each body is composed, pushed, and left behind before the next one starts, so
**nothing ever holds the set**. Consistency across tickets is whatever survives in one long context,
and it degrades as the set grows. `/to-tickets` step 4 then reviews the *breakdown* — title, blocking
edges, one line of what each ticket delivers — never the bodies, so the human approves a shape and
nobody reads the acceptance criteria as a body of work.

**Evidence.** A single read of all 54 tickets of ai-workout-generator-copilot build-1, before start
on 2026-08-06, found **nine ambiguities, every one of them in the join between two tickets and
invisible from inside either**. Four would have failed the build or the demo: three tickets promised
a Graph tab the build excluded; #34's acceptance forbade the retry its own design section required,
with a test enforcing the contradiction; #36's intent list omitted the intent #54 exists to handle;
#50 required progress states from an endpoint with no channel to deliver them. The other five were a
rework round each. None was reachable by reviewing one ticket, and the blocking-edge closure check at
build definition could not see any of them — it reads links, and these were written in prose.

The set is ~95KB, about 25k tokens. It fits in one context comfortably; the pass that found all nine
took one read.

**Fix direction.** Publishing moves to the end of the phase, and an artifact the phase currently has
no concept of is added in front of it:

1. Read the source documents — unchanged.
2. Write every ticket body into **one draft file, one epic at a time**. Per-epic because a single
   pass over 58 bodies drifts by the end: the last epic's vocabulary wanders from the first's.
3. Re-read the whole draft **from the file**, not from memory. This step does not exist today and is
   the only one that can see across tickets.
4. Run **one** check list over the draft — the phase's single self-check, replacing three rules
   that today sit in three different files and fire at three different times (see below):

   *Shape* — is this set buildable at speed?
   - **width**: how many tickets can start at once, and at every layer, computed from the draft's own
     edges. Where a heavy blocker gates several dependents, split it with a `Pinned interfaces`
     ticket.
   - **size**: no ticket whose acceptance criteria cannot plausibly be met in one focused sitting
     (P53's `criteria_count` and `file_surface` proxies, read off the draft instead of the tracker).

   *Consistency* — does the set agree with itself?
   - every pinned interface names its fields (P59);
   - every field a later ticket reads exists in the ticket that pins it;
   - every capability one ticket's criteria assume has a ticket that builds it;
   - shared vocabularies — status and severity words, intent lists, state names — are identical
     everywhere they appear;
   - no ticket's acceptance criteria contradict its own mandatory adversarial tests;
   - every command a ticket's gate tier will run exists by the time that ticket merges.
5. Show the human **the bodies**, not the titles, with the surviving ambiguities as decisions to
   answer. `/lavish` already carries this shape.
6. Apply the answers to the draft file.
7. Hand the finished set to `/to-tickets` to publish. It keeps owning slicing, blocking edges and the
   tracker mechanics; it stops owning the order in which bodies are decided.
8. Keep the draft file. `replan` diffs against it.

**Folding in the rules that already exist.** Phase 4 has accumulated three separate "check your own
output" rules, written at three different times and living in three places:

| Rule | Today | Fires |
|------|-------|-------|
| Width | `phases-1-5.md` phase 4 prose: "width is a ticket-writing output, not an afterthought" | decided in phase 4, **measured in phase 5** once the Build issue exists |
| Size | `ticket-template.md` `## Size`, plus `graph`'s `LIKELY DEEP` verdict (P53) | measured in phase 5, from the tracker |
| Consistency | nothing | never |

All three ask the same question — *is the set I just wrote any good?* — and two of them can only be
answered after the tickets are already published, which is why phase 5 exists partly to send you back
to phase 4. The draft file collapses that: width is computable from the draft's edges, size from its
criteria counts, consistency from reading it. **One gate, one list, before anything is published.**
Phase 5 keeps its verdict as a backstop on the published build; it stops being the first time anyone
finds out. A ninth ambiguity from the 2026-08-06 read belongs to that same list and to no existing
rule: three E0 tickets carried gate tiers naming commands their own build had not written yet, which
neither width nor size nor the edge check can see.

**Where it goes.** Loom's own layer, never `/to-tickets` — that skill is shared with other work and
this file's *stay inside this skill* rule binds. The seam already exists: phase 4 is defined as
"route to `/to-tickets` **plus** the additions in `ticket-template.md`". The draft file, the check
list and the human review are more additions; `/to-tickets` step 1 accepts conversation context, so a
finished draft set is valid input to it.

**Cost.** One extra full-set read and a fix round — roughly 40k tokens on a 58-ticket build. Against
one lane blocked at layer five on a shape the rules call non-relitigable, with three tickets queued
behind it, it is not a close call.

**What would falsify it.** A drafted-and-checked set that still ships cross-ticket contradictions at
the same rate — meaning the check list, not the missing artifact, was the constraint. Or a set small
enough (say under 15 tickets) that one context never lost the thread, where the extra pass finds
nothing and should be skipped.


**Consumer.** Phase 4, and every ticket that imports a pinned shape without renegotiating it.
## P60 · A gate command may never depend on an unmerged ticket's deliverable

**Problem.** ai-workout build-1's `.loom.yml` tiers invoke `scripts/gate.sh` (ticket #7's
deliverable), `scripts/gen_openapi_client.py` (#6's) and the `web/` toolchain (#2's). The ticket
graph was acyclic, but the *gate* graph was not: #2's own `ui` tier needs #6's script while #6 is
blocked by #2, and every ticket's merge gate needed #7's runner. No link-based closure check can
see this class — the cycle runs through a shell command's file dependency, not a blocking edge.
The pregate's behaviour on a missing runner (skip, silently) meant the mechanical check ran zero
times all build, and the failure surfaced instead as merge-lane deaths.

**Evidence (2026-08-06/07).** merge-2 died on missing `gen_openapi_client.py` (00:38), merge-5 on
missing `gate.sh` (00:44); a wave then traced the loop, mass-blocked #2, #5, #10, #32, #36, and the
build stalled ~1h for a human waiver — the largest single stall of the run. Every gate all night
logged `pregate: no scripts/gate.sh here, skipping`.

**Fix, two halves.** *Definition side*: when a build is defined (phase 5) — and again whenever
membership is amended — resolve every file/script the tiers' gate commands invoke; each must
either exist on the base branch or be delivered by a ticket that blocks every ticket carrying that
tier, else the definition is refused naming the offending command. P58 already carries this as a
phase-4 draft-check line ("every command a ticket's gate tier will run exists by the time that
ticket merges"); this proposal is that rule with teeth at the two later layers, where tickets
arrive by amendment rather than drafting. *Runtime side*: a missing gate dependency becomes a
declared bootstrap stage — the pregate reports "tier reduced to X until #n merges" instead of a
silent skip, so the log says what is not being checked and why.

**What would falsify it.** A refused build definition whose named cycle a human then shows to be
spurious (e.g. the command exists behind a generator the resolver could not see) — a false refusal
at definition time is cheaper than an hour's stall, but not free.

## P64 · Every epic ends with a wiring ticket

**Problem.** Unit-tier gates judge tickets; nothing before the epic probe judges the epic. In
ai-workout build-1, every E1 (exercise graph) ticket passed its gate while the running app never
called `build_kg1()` once — `/api/graph/focus` served byte-identical fixture output for every
member — and the shipped catalog's 18 `bilateral_pair_id` values all dangled. The probe, the last
step of the epic, was the first thing that looked.

**Evidence.** E1 probe FAIL 06:27 → fix tickets #69 (wire the graph into the app), #70 (docs),
#71 (dangling ids — a product decision, blocked). E0's probe similarly failed twice on gaps
(no run command, undocumented env vars) that a wiring-level ticket would have owned.

**Fix.** Phase 4 must end each epic with a wiring ticket, blocked by the epic's other members,
whose acceptance criteria are the epic's own acceptance criteria exercised against the running
app and the real data — the same bar the probe applies. The build-definition check refuses an
epic without one. The probe then confirms; it never discovers.

**What would falsify it.** Epics whose wiring ticket passes and whose probe still fails at the
same rate — meaning the bar transfer, not the missing owner, was the problem.
