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
| P94 | `fix` proves a defect died; it doesn't have to grow the suite to do it | open — proposed 2026-08-13; suite now 36 files, 11,358 lines, ~1008 tests, entirely reactive growth; a live duplication example found on inspection |
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


## P94 · `fix` proves a defect died; it doesn't have to grow the suite to do it

**Problem.** `references/fix.md`'s own rule — *"a fix is not done until a test fails without
it"* — is read by `fix`'s Step 2 as "add a new test case", every time, with no check for whether
an existing case in that file already exercises the function or scenario the defect lives in.
Every one of the 76 (now 75) entries in `OPEN_DEFECTS.md` that has shipped added at least one new
`ok` block this way. The suite is now 36 files, 11,358 lines, ~1008 assertions — up from the 430
in one file that P45 was proposed against a week earlier — and the growth is entirely additive:
nothing in `fix` or `prop` ever folds a new assertion into an existing case.
`16-ticker-and-lane-verbs.sh:82-93` shows the shape concretely: three separate `ok` blocks assert
the exact same `wave:`-prefix-stripping invariant against three literal string variants (case,
spacing, mixed-case) — a single parametrized loop proves the same thing with the same coverage.
Nothing wrong with any one of these tests in isolation; the process that adds them has no step
that ever asks whether the assertion belongs inside a case that already exists.

*(paid: no single incident yet — this is a rate problem, not a correctness incident. The cost is
diffuse: every wave and every human running `qa` reads a suite that grows by one file-sized unit
per fix regardless of whether the fix touched new ground or well-trodden ground, and `references/
optimize.md`'s own warning about `SKILL.md` — "every line it grows is a tax on every session
forever" — applies just as much to a suite every `fix` and `prop` run has to run in full before
closing.)*

**Fix direction.** Change what "add that case" means in `references/fix.md`'s Step 2, not the
red-then-green requirement itself:

- Before writing a new test, check whether a test in that file already exercises the function or
  scenario the defect lives in. If one does, extend it — a new row in a table-driven case, a new
  assertion inside a test that already builds the right fixture — rather than standing up a
  separate `ok` block beside it. Write a wholly new case only when nothing existing reaches this
  code path.
- The red-then-green proof is unchanged either way: reverting the fix must still turn the
  (possibly folded-in) assertion red.
- Step 1's ask-back list and the Deliver section both currently say "the new test case name" /
  "which case is new" — reword to "the new assertion — case name, and whether it's a new case or
  folded into an existing one" so the report can't paper over which happened.

**Retroactive scope, deliberately excluded here.** The same logic could in principle be run
backward over the existing ~1008 assertions to consolidate duplicates like the one above — but
not blind, and not in this proposal. `fix`'s whole reason for existing is proof a specific defect
died; merging two assertions by hand risks silently weakening that proof exactly the way the
`D-TEST-*` entries already show it can (a merged case that still passes for the wrong reason is
worse than two verbose ones that each pass for the right one). That's P45's `--mutate` machinery's
job, not a hand-audit: gate any retroactive consolidation pass behind P45 shipping, and run it
file-by-file through `--mutate` so a fold that stops the assertion from going red on its original
defect is caught mechanically, not trusted to review. File that as its own proposal once P45
lands, scoped to whichever files a `qa` pass or an incidental `fix` touch flags — not a single
blanket rewrite of all 1008 assertions at once.

**Consumer.** `fix`, and `qa`, which currently has no way to tell a reactively-added duplicate
from a load-bearing one without reading the whole file.

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
