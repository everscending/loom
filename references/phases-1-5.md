# Phases 1–5 — from PRD to a defined build

The human-driven front half: `plan`, `epics`, `tickets`, `build`, `start`.
Each is interactive and run once, so it lives here rather than in `SKILL.md`,
which every headless wave loads in full.

**Verb boundaries are hard stops.** A verb ends at its own output and returns
to the human — never auto-advance to the next verb, and never implement by
hand under any verb. Deadline pressure does not change a verb's scope; surface
the tension and let the human choose. *(paid: a plan run chained plan → epics →
hand-coding under a deadline.)*

## Phase 1–2 · `plan <PRD>`

1. Read the PRD fully. Explore the repo (respect `CONTEXT.md`, existing ADRs).
   Facts are looked up; only *decisions* go to the human.
2. Split open architectural questions: **dependent chains** → `/grilling` one
   at a time with a recommendation each; **independent batches** → one
   `/lavish` decision surface (options, tradeoffs, recommendation badged — the
   orchestrator-plan blueprint page is the reference shape).
3. Record each closed decision as an ADR (`docs/adr/`, via `/domain-modeling`
   conventions) and fold the whole into `ARCHITECTURE.md`. No open question
   survives this phase.
4. Repeat for UI/UX: grill to closure, mockup options side-by-side on a
   `/lavish` surface (`/prototype` for anything worth clicking). Output: a
   **written UX spec with annotated mockups** — the source of truth the build's
   UI verification checks against. Store beside the PRD.

Exit criterion: a ticket-writer with no access to the human could answer every
"which way?" from the ADRs + UX spec alone.

## Phase 3 · `epics`

Best-guess epic breakdown + dependency sketch, presented on a `/lavish` surface
for merge/split/reorder annotation. On approval, create the epics/milestones in
the tracker. Nothing else — epics are grouping, not state.

**Every milestone gets a `## Acceptance criteria` section**, and it is the one
thing this phase produces that a *wave* later reads. Write it from the epic's
own **PRD requirement IDs** — a handful of observable, user-level statements
that say what must be true for the epic to be done, each traceable to a
requirement it cites. Not a restatement of scope, and not a test plan.

Its consumer is the phase-6 acceptance probe: `snapshot` surfaces it at
`.epics[].acceptance`, and the probe brief is assembled from it plus
regression checks for defects the epic has since produced. Skip it and the
brief can only be written backwards from the defect history, which means the
probe tests the last round's damage and nothing else — it cannot catch what
nobody has broken yet, and no two runs are comparable. *(paid: E4 failed five
straight probes with no criteria of its own; every brief was enumerated from
the previous round's tickets, and no run ever checked the FR-2/TR-2/PF-1 the
epic cites.)* `snapshot` warns when an epic reaches probe-ready with none.

## Phase 4 · `tickets`

Route to `/to-tickets` (tracer-bullet slices, blocking edges, publish in
dependency order) **plus** the additions in
[ticket-template.md](ticket-template.md):

- **Design decisions — implement, do not relitigate** (one line each,
  `Decision — reason`), closing every point two engineers could disagree on.
- **Pinned interfaces**: when tickets share a seam, the exact signature goes
  verbatim into *every* affected ticket.
- **Mandatory adversarial tests**: inputs that must be *rejected*, with the
  sentence "fix the rule, not my examples."
- **Risk tier**: `docs | logic | api | ui` — selects the gate suite from
  `.orchestrator.yml`.
- **PRD requirement**: the requirement ID this ticket satisfies; the gate
  verifies faithfulness against it.

Ambiguity found while writing a ticket is a phase-1 escape: close the decision
in the ADR/UX spec *first*, then write the ticket.

**Width is a ticket-writing output, not an afterthought.** Correct blocking
edges are not enough — a graph that opens one ticket wide idles every lane
however well the loop runs *(paid: a build peaked at 2 lanes of 4, its first
hour at 0–1 startable)*. While writing the edges, ask how many tickets can
start at once. Where a heavy blocker gates several dependents, split it with
**Pinned interfaces**: a tiny `interface + stub` ticket that merges fast, the
implementation behind it — the dependents need the signature, not the merged
body. Phase 5 measures the result; this phase is where it is decided.

## Phase 5 · `build` — define or adjust the build (never starts it)

`build` shapes the build plan and spends nothing. Two modes, auto-detected:

1. **No build defined** → the `/lavish` epic-selection surface (complete epics
   ✓ unselectable, partial with progress — selecting includes only remaining
   open tickets — untouched selectable, size estimates). On submit: create the
   `Build N` issue (selected epics, config snapshot quoted) and label member
   tickets `build-N`. **Only now** does the build exist to measure, so report
   its shape alongside `max_lanes` — `tick.sh snapshot | tick.sh graph` — and
   surface a `CHAIN-SHAPED` or `NARROW START` verdict as a reason to go back to
   phase 4 and split a blocker, not a fact to discover at wave 1. Then **stop**
   — tell the human the trigger is `/orchestrate start`.
2. **A build already defined** → the same surface, pre-filled with the current
   selection, for adjustment: add an epic (label its open tickets `build-N`),
   remove one (unlabel its *not-yet-started* tickets only — never touch
   in-flight or merged), update the `Build N` issue body. Adjusting a *running*
   build is allowed — the next wave simply schedules the new ready set. Still
   starts nothing.

`build` never loads the agent and never spends; the deliberate trigger is a
separate verb.

## `start` — the trigger (and resume)

`start` kicks the loop: `tick.sh install` generates this repo's launchd agent
(label + state dir + logs all derived from the repo path → unique per repo),
clears the loop switch a previous `stop` left, and loads it. One agent, firing
every 60s: it watches on every firing and starts a wave only when the switch is
on and `min_wave_gap_minutes` (default 10) has elapsed. `RunAtLoad` fires wave 1,
and lane handoffs carry it from there. This is the *only* thing the human runs
to go unattended — no `launchctl`, no plist, no cron.

**`start` is now what makes a build autonomous, not a side effect of ticking.**
Without it, a lane cannot chain and an automatic tick does nothing; a manual
`/orchestrate tick` still runs exactly one wave. *(paid: a single manual tick
once produced a 92-wave overnight build the human never armed — so it ran with
no backstop, and a separate notification bug meant it reported nothing.)*

Idempotent, so it doubles as **resume**: a halted build (a `blocked` ticket
cleared, or a `stop`ped one) restarts with `start` — no re-planning.
Multi-repo: each repo's `start` installs its own independent agent, run
concurrently. The build **auto-unloads its own agent on completion** (phase 6
step 8), so a finished build leaves nothing behind.

## Manual-drive

**A supported mode, not a violation.** The tick loop is just one scheduler over
the tickets; a human in a session may work the frontier instead — `/implement`
one ready ticket at a time, gate included — with the same tracker state
throughout. When the deadline is tighter than the bootstrap, this is the
sanctioned fast path; freestyle coding outside tickets never is.

*One manual session is serial* — it holds one branch at a time, so it cannot
exploit a parallel frontier. To parallelize, give each concurrent ticket its
own worktree and session (`git worktree add ../<repo>-wt-<n> -b <branch>
<base>`); a lone blocking ticket needs none. The tick loop does this for you
(fill-lanes creates a worktree per lane) — parallelism is the reason to prefer
it once the frontier widens. *(paid: a manual run did the sole-blocker
bootstrap in-place, then hit a 2-wide frontier with no worktrees.)*
