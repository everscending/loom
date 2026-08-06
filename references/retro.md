# `retro` — turning a finished build into proposals

Human-run, after `build_complete`. Read-only on the tracker. **A wave never runs this.** It reviews
the *run*; `qa` reviews the *code*.

Why it exists: every entry in `PROPOSALS.md` came from a human reading raw transcripts on a spare
afternoon, which is why exactly one build was ever analysed. P23 made the numbers survive; this
turns them into decisions.

## Step 1 — the numbers, which the machinery computes

    tick.sh retro                       # the last build
    tick.sh retro --build build-3 --vs build-2

`retro` prints `report` first, then four analyses `report` deliberately does not do. **Do not
recompute any of it.** Arithmetic over 31 transcripts is where a model burns tokens and makes
mistakes; the machinery already did it exactly.

## Step 2 — what each number accuses

**Where the capacity went.** Three buckets, and they point at different fixes:

- **slack** — slots free *and* work ready. Capacity you had, with work waiting for it, and nothing
  spawned. This is the one to chase first. It means scheduling latency: how long after a lane exits
  does the next wave start? Suspect the self-trigger chain and the cost of a wave itself.
- **starved** — slots free, nothing ready. The dependency graph set the pace, not the lane cap.
  Raising `max_lanes` would do nothing. Widening the graph would.
- **at capacity** — every impl slot busy. `max_lanes` is the binding constraint, and raising it is
  the cheapest fix on this list if the machine can take it.
- **blackout** — usage limit. Check whether the configured downshift actually fired; a pause with
  `source: retry` and no downshift means the fallback model never engaged.
- **unrecorded** — snapshots predating the record. Not a finding; a gap.

**Rework.** Lane time that produced nothing, as a share of all lane time. Read the three kinds
differently: rc-7 rejections mean the cheap mechanical gate is *working* — it caught a branch before
a review session was spent — unless the count is high, which means implementers keep shipping
branches that cannot pass. Crashes need a log read. Re-gates mean a rejection loop; ask whether the
gate's brief was clear enough to satisfy.

**Wait vs work per ticket.** A ticket open three hours with forty minutes of lane time has a
queuing problem, not an implementation problem — and that decides which proposal is worth writing.
Large waits with small work are the schedule's fault; the reverse is the ticket's.

**Spend.** Priced straight from each lane's own session log, so it needs no separate investigation
script. Read it next to the time numbers, not instead of them — a lane that took the longest and
one that cost the most are not always the same lane (a slow lane spent turns waiting, not spending
tokens; an expensive one paced through a lot of context in a short span). The top-spenders list is
where an escalated `model::` label or a runaway `lane_turn_cap` candidate shows up first.

**The chain that set the length.** If the actual chain is as deep as the deepest chain in the graph,
the graph bound the build: widen it. If it is shallower, the schedule bound it, and the graph was
never the constraint. If one chain accounts for most of the span, nothing else found this round
matters as much.

## Step 3 — the why, which only transcripts hold

Events record *what* happened, never why a wave chose it. So read logs — but only the ones the
numbers accuse: the lanes inside the slack windows, the crashed lanes, the re-gated tickets, the
longest waits. Fan out, one reader per lane, in parallel. `report --ticket <n>` gives the log path
for each.

Reading all 31 transcripts is the thing this verb exists to stop.

## Step 4 — write proposals, do not fix

Findings go into `PROPOSALS.md` as new proposals, in the house format: the problem, the evidence
with its numbers, the proposed fix, and what would falsify it. Then the human picks. Handing a
finding to an agent that repairs it unattended is how a working loop breaks — on 2026-08-01 six
confirmed fixes introduced five new defects.

**The discipline that keeps this from becoming an essay.** Every claimed inefficiency carries a
number and a falsifiable fix. A model handed a table of timings will always find a narrative; the
number is what separates a finding from a plausible story. If it cannot be stated as *"X cost N
minutes, and here is the change that would show up as N minutes saved next build"*, drop it. Do not
soften it and keep it.

Where a comparison exists (`--vs`), say plainly whether the last round's changes moved the number
they were supposed to move. A proposal that shipped and changed nothing is a finding.

## Honest limits

- Ticket timings are sampled at **wave cadence** — every span is ±one wave. Present them that way.
- The dependency graph comes from the first snapshot that recorded one. Edges added mid-build are
  not reflected.
- A build with no prior build has **no baseline**. Say so; do not invent a standard to judge it
  against.
- `retro` reads `events.jsonl` and — for spend — the per-lane session logs under `logs/`; nothing
  else in the loop reads either. Keep it that way: a scheduling decision that consulted them would
  make them shadow state.
- **Spend prices are hardcoded and go stale** (`USAGE_JQ` in `tick.sh`, dated at the comment).
  A number that looks wrong after a price change probably is — check the date before trusting it.
