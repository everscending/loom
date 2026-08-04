# Orchestrate — open proposals

Live proposals for making `/orchestrate` faster and more reliable, ordered by impact. Implemented
ones move to [PROPOSALS_ARCHIVED.md](PROPOSALS_ARCHIVED.md), which also holds the review-round
findings and the ranking rationale for work already done.

Everything here is derived from a review of `SKILL.md`, `scripts/tick.sh`, `scripts/tick-test.sh`
and `references/`, checked against the two real unattended runs on disk (crucible Build 2,
2026-07-21 19:55–23:45, 31 logs in `~/.orchestrator/crucible-2014258785/logs/`; boostlingo
build-1, 2026-08-01 23:24 → 2026-08-02 12:28, logs in
`~/.orchestrator/boostlingo-ai-interpreter-workbench-2061292512/logs/`) and against fresh
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

**Stay inside this skill.** Every proposal here is implemented using only the `/orchestrate`
skill's own files — `SKILL.md`, `scripts/`, `references/`. The sibling skills this one routes to
(`/to-tickets`, `/implement`, `/code-review`, `/grilling`, `/lavish`, `/prototype`) are **off
limits**: they are shared by other work, and `/orchestrate` is a consumer of them, not their
owner. Constitution rule 2 — *route, do not teach* — cuts both ways.

If a fix looks like it needs a change in one of them, re-scope it into this skill's own layer
rather than reaching across. That layer already exists and is the intended seam: phase 4 routes
to `/to-tickets` **plus** the additions in `references/ticket-template.md`, and the wave composes
every session prompt itself. Anything that cannot be re-scoped that way is dropped, not deferred.

One boundary worth stating, because it looks like an exception and is not: the machinery writes
files into the *target repo* (`.claude/settings.json`, `scripts/gate.sh`) and the machine
(`~/.orchestrator/config.yml`). That is this skill doing its job on its subject, not a change to
another skill.

**Keep SKILL.md small.** SKILL.md is loaded into every wave, so every line it grows is a tax on
every session forever. Implement a proposal in the machinery — `tick.sh`, `bootstrap.sh`, the
generated config — wherever the machinery can carry it, and add to SKILL.md only what a wave
must *decide* and cannot derive. Prefer deleting or tightening an existing line to appending a
new one; a rule the scripts already enforce does not need restating in prose. Rationale,
evidence, and implementation notes belong in this file, not there.

| ID | Proposal | Status |
|----|----------|--------|
| P31 | Make the mandatory adversarial test a checkable deliverable | open — proposed 2026-08-03; 4 of 5 gate rejections in one build |
| P38 | One way for a lane to fire the next wave, not two | open — proposed 2026-08-04; merge-68 self-invoked `tick` in the foreground and blocked on its own lock |
| P3 | Actually arm the safety-net timer, and check that it worked | open — re-opened 2026-08-02; build-1 paid 2h08m for the unarmed backstop, and the shipped warning cried wolf after arming |
| P18 | Use a cheaper model for scheduling | open — fresh number 2026-08-03: 36 waves, 1h29m, 57.5% of span |
| P19 | Cut the repeated advisory noise | open |
| P42 | Stop the ticker announcing a replay that is not going to happen | open — proposed 2026-08-04; 253 of 408 of those lines were false, and the human asked what they were for |
| P20 | Parallelise the human-gated front half | open |
| P24 | Supervised lanes (part B of "watch a lane") | open — staged behind evidence: build only if watching leaves a real intervention gap; part A archived 2026-08-02 |
| P29 | Model-level observability: LangFuse ingest of lane OTel exhaust | open — proposed 2026-08-02 |
| P39 | A viewer that cannot open a pane must say so and exit | open — proposed 2026-08-04; a build ran 13 minutes with no ticker and no lane panes |
| P40 | The viewer singleton guard deletes a pidfile it does not own | open — proposed 2026-08-04; found live, viewer running with no pidfile |
| P41 | A concluded ticket should take its viewer pane with it, however it concluded | open — proposed 2026-08-04; a pane sat labelled with a closed ticket, spotted by the human |

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

**P3 was never armed, and this time it did not matter.** `/orchestrate start` was never run; the
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
test is committed, it is **named in the tier's command list in `.orchestrator.yml`**, and it is
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

**What would falsify it.** A build where re-gate lane count does not drop, or where the pregate
check exits 7 on a branch the review gate would have passed — a false rc 7 is more expensive than
the round it saves.

## P38 · One way for a lane to fire the next wave, not two

**Evidence.** build-3, 2026-08-04 14:19:48. The merge lane for #68 merged MR !65, closed the
ticket, and then ran `tick.sh tick` itself in the foreground — pid 26952 — instead of letting its
exit epilogue fire one. It took the tick lock and then waited on itself. The wave that noticed
logged it verbatim: *"self-invoked tick.sh tick directly … waiting for that nested wave to release
the tick lock before proceeding."* Cost was a few minutes, not correctness, but it recurs at every
merge and the loop is the one thing that must not deadlock.

**Root cause.** Two mechanisms produce the same effect. `spawn-lane` already appends the epilogue
`( "$SELF_PATH" tick --from-lane … & )` to a lane's command (`scripts/tick.sh:1143`), and
`_tick_exit` replays a pending tick on the way out (`:656`). Meanwhile SKILL.md step 5 tells the
reader *"the merge lane fires its own tick when it lands"* (`SKILL.md:350`) — an invitation a model
takes literally. It then reaches for the wrong verb: `tick` is the human contract (always runs,
ignores switch and gap), where a lane handoff is `tick --from-lane` (respects the switch, ignores
the gap). Foreground, wrong contract, wrong pacing.

**Fix.** Make the wrong call impossible rather than discouraged: `cmd_tick` refuses when
`ORCH_LANE_ID` is set, naming `--from-lane` and the epilogue in the error. Then delete the sentence
in step 5 that invites it — the epilogue already does this work, and a rule the scripts enforce
does not need restating in prose (this file's own "Keep SKILL.md small").

**Tests.** `ORCH_LANE_ID=merge-9 tick.sh tick` exits non-zero, writes no lock and starts no wave;
`tick --from-lane` from the same environment still runs.

## P3 · Actually arm the safety-net timer, and check that it worked

A slow background timer exists to restart a stalled loop. It was never running.

**Evidence.** Eight of thirteen waves report `agent-status: not loaded` and spend a paragraph
advising the operator to run `/orchestrate start` (W1, W2, W4, W5, W9, W10, W12, W13). The
entire run therefore depended on the self-trigger chain — precisely the mechanism dropping
signals in P1.

**Re-opened 2026-08-02 (build-1).** The deferral reason — "the skill is driven by `tick` alone" —
is exactly how build-1 paid: the loop was kicked with manual `tick` on Friday night and left
unattended with nothing armed. When wave-074603 fizzled at 07:46 (Bash denied wholesale, misread
as "never bootstrapped", exited without harvesting), **nothing fired again for 2h08m** until the
human ran `start` at 09:54 — after which #1 merged within 30 minutes. The stderr warning shipped
since crucible fired on every tick, fifteen times, into a log nobody was reading overnight. Two
additions to the fix:

- **The warning must reach the human, not the log.** Route the un-armed warning through
  `tick.sh notify`, once per state change like the quiescence watcher — an un-armed build should
  produce one push, not fifteen stderr lines.
- **The armed-check is wrong from detached contexts.** After the agent was armed at 09:54
  (launchd demonstrably fired wave-095403; `uninstall` at 12:28 unloaded it), every later
  self-triggered tick *still* warned "not installed": `launchctl print gui/$(id -u)/$ORCH_LABEL`
  fails from a nohup'd lane context. Probe the installed plist file first, with `launchctl list`
  as fallback.

**Fix.** `start` verifies the agent actually loaded and fails loudly otherwise. A wave that
detects `not loaded` installs it rather than advising about it thirteen times.

**What would falsify it.** An un-armed build that does not push a notification within one tick,
or an armed build that still logs false "not installed" warnings.

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

## P42 · Stop the ticker announcing a replay that is not going to happen

**Evidence.** The human, watching build-3 on 2026-08-04: *"I see the 'tick landed mid-wave —
remembered for replay' message appearing every minute. This adds more noise than its worth."* The
event log for that day:

| Event | Count | Actually replayed? |
|---|---|---|
| `tick_skipped reason=wave_gap` | 253 | no — nothing was remembered |
| `tick_skipped reason=lock_held` | 155 | yes, but many collapse into one replay |
| `tick_replayed` | 79 | — |

All 408 `tick_skipped` events render as the same sentence, and 79 replays actually happened. The
253 `wave_gap` lines are not merely noisy, they are **false**: no pending file is written on that
path and no replay follows. The `lock_held` lines are true but repeat a flag that is already set —
the pending file is a flag, not a counter, so every extra one during a wave changes nothing.

**Root cause.** `tick_skipped` is emitted for three different reasons — `loop_stopped`
(`scripts/tick.sh:717`), `wave_gap` (`:722`), `lock_held` (`:727`) — and the renderer collapses all
three into one string (`:1418`). That was harmless when the timer was a slow ~15-minute backstop:
`tick_skipped` was rare and usually meant `lock_held`. The merged-scheduler design fires every 60s
and *watches* on every firing, spending only once `min_wave_gap_minutes` has elapsed — correct, and
it makes `wave_gap` the routine outcome of nine ticks in ten. A line written for the exceptional
case now prints for the normal one.

**Fix.** Mostly deletion, all in the renderer plus one condition:

- **Do not render `wave_gap` at all.** A timer declining to spend is the absence of an event. It
  stays in `events.jsonl`, where `retro` already counts it — it just stops reaching the ticker.
- **Render `lock_held` once per wave**, when the pending flag is newly set rather than every time a
  tick bounces off the lock, and word it for what it is: a tick arrived during a wave and the wave
  will re-tick on exit.
- **Keep `loop_stopped` as its own line.** Rare, and it means something specific: the loop is off
  and this tick did nothing. (Zero occurrences in the day above, which is the point — it would have
  been worth seeing.)

Roughly 408 ticker lines become roughly 79, and every survivor is true.

**Why this is not just cosmetics.** The ticker is the human's only continuous view of the build, and
its value is entirely in signal-to-noise. A line that appears every minute and means nothing trains
the reader to skim the strip, which is where the real events — `ticket_blocked`, a gate FAIL, a
merge conclusion — also live. P19 is the same complaint about wave advisories; this is its ticker
half.

**Tests.** `render-events` on a fixture log: a `wave_gap` event produces no line; consecutive
`lock_held` events during one wave produce exactly one; `loop_stopped` produces its own distinct
line; `tick_replayed` is unchanged.

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

**Fix sketch.** One seam: `spawn-lane`. When `~/.orchestrator/config.yml`
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

## P39 · A viewer that cannot open a pane must say so and exit

**Evidence.** build-3, 2026-08-04, 12:46 → 12:59. `watch-panes.sh` was alive the whole time, and
opened nothing: no anchor pane, no build ticker, no lane panes. The build ran two implementation
lanes through it unseen, and the human noticed only by asking why the ticker was missing. Killing
it and relaunching from a live pane opened all three panes in four seconds.

**Root cause.** The viewer anchors every split to the pane it was launched from,
`$HERDR_PANE_ID` (`scripts/watch-panes.sh:168`, and again at `:343`). When the launching session is
gone, that pane id refers to nothing and every `herdr pane split` fails. `new_pane` swallows the
failure — `2>/dev/null`, `|| true`, empty string on error (`:151`) — and the startup check is
`if [ -n "$anchor" ]`, so an empty result reads as "skip this", not "I am broken". `ensure_ticker`
does log its own failure, but the launcher redirects the viewer's output to `/dev/null`, so nothing
reaches a human. The result is a process that looks healthy in `pgrep`, polls forever, and shows
nothing.

**Fix.** Treat a failed split off the anchor as fatal, not as a skip. On the first failure,
re-resolve the anchor against a live pane; if that also fails, print the reason and exit non-zero
so the singleton is released and the next `/orchestrate watch` or manual tick starts a working
viewer. Separately, launch it with its output going to `$ORCH_HOME/watch-panes.log` rather than
`/dev/null` — a silent diagnostic is not a diagnostic. Depends on P40: exiting is only safe once
the pidfile is owned correctly.

**Tests.** With the pane opener stubbed to fail, the viewer exits non-zero within one poll, prints
a reason naming the dead anchor, and leaves no pidfile behind. With it succeeding, behaviour is
unchanged.

## P40 · The viewer singleton guard deletes a pidfile it does not own

**Evidence.** build-3, 2026-08-04. Found live: `watch-panes.sh` running as pid 1805 with
`$ORCH_HOME/watch-panes.pid` absent. The likely sequence is an older viewer still shutting down
when 1805 started — 1805 found no pidfile, wrote its own, and the older one's `EXIT` trap then
deleted it.

**Root cause.** `trap 'rm -f "$MAP" "$MAP.new" "$WP_PID"' EXIT` (`scripts/watch-panes.sh:118`)
removes the pidfile unconditionally, without checking it still contains this process's own pid.

**Why it matters in both directions.** With the pidfile missing, the guard at `:112` passes and the
next manual tick opens a **duplicate** viewer — two panes per lane, two tickers. With the pidfile
present but belonging to a viewer that can no longer open panes (P39), the guard does the opposite:
it reports "already running — nothing to do" and refuses to start a healthy one. The guard is
load-bearing precisely because `/orchestrate tick` launches the viewer opportunistically on every
manual tick.

**Fix.** Remove the pidfile only when it still holds this process's own pid — read it back in the
trap and compare against `$$` before deleting. Pair with P39 so a broken viewer releases the guard
by exiting rather than holding it forever.

**Tests.** Two viewers started in sequence leave exactly one pidfile holding the surviving pid; a
viewer whose pidfile was overwritten by a newer one does not delete it on exit.

## P41 · A concluded ticket should take its viewer pane with it, however it concluded

**Evidence.** build-3, 2026-08-04. #72 was reclassified from defect to finding and closed by hand;
its three lanes were killed. Its pane stayed on screen labelled `ticket 72 — idle` for a ticket
that will never have another lane. The human spotted it and asked whether closing the ticket should
have closed the pane.

**Root cause.** Panes are recycled on purpose — a finished lane keeps its ticket stamp so the next
stage of the same ticket returns to the same pane, which is what makes implement → gate → merge
read as one continuous transcript. The exception is the "finished story" rule
(`scripts/watch-panes.sh:253-266`): a `probe-*` pane always closes when its lane ends, and a
`merge-*` pane closes only if a tracker read says the ticket actually closed — that read exists
because merge lanes sometimes exit cleanly without merging, and a blocked merge must keep its pane.
Every other lane kind skips the check entirely. So a ticket that concludes any other way — closed by
hand, killed mid-flight, closed by a human outside the loop — leaves its pane stamped forever.

**Severity: cosmetic, and worth fixing anyway.** Nothing leaks. Reuse prefers a pane stamped with
the incoming lane's own ticket but falls back to *any* idle pane, so a stale stamp is claimed by the
next lane that needs one and never starves the cap. The cost is that a pane labelled with a closed
ticket reads as work still pending, which is the exact confusion the idle stamp was introduced to
prevent (build-1 2026-08-02: an idle pane read as a stall).

**Fix.** Run the ticket-closed check for **every** lane kind, not only `merge-*`, at the moment the
pane goes idle. That is the same single tracker read, at the same moment, already paid for on the
merge path — it is not new polling, and the "a failed read keeps the pane" default stays. Keep the
`probe-*` rule as is (a probe's story ends with its lane whatever the tracker says), and keep the
merge rationale in the comment, since it explains why the read exists at all.

**Tests.** With the tracker stub reporting a closed ticket, an idle `gate-*` pane closes on the next
poll; with it reporting open, the pane idles and keeps its stamp; with the read failing, the pane is
kept. Sibling viewer items: P39, P40.
