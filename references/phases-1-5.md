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
   loom-plan blueprint page is the reference shape).
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

Route to `/to-tickets` (tracer-bullet slices, blocking edges, tracker
mechanics) **plus** the additions in
[ticket-template.md](ticket-template.md):

- **Design decisions — implement, do not relitigate** (one line each,
  `Decision — reason`), closing every point two engineers could disagree on.
- **Pinned interfaces**: when tickets share a seam, the exact signature goes
  verbatim into *every* affected ticket — fields, values and shapes, never a
  bare endpoint path, type name or file path. A shape named in no document
  of record must be specified here, not invented later by whichever ticket
  starts first.
- **Mandatory adversarial tests**: inputs that must be *rejected*, with the
  sentence "fix the rule, not my examples."
- **Repo-wide guards**: a test asserting over the whole tree is a contract
  change for every later ticket — it must be declared in the ticket body,
  and phase 4 surfaces the declaration across the set.
- **Risk tier**: `docs | logic | api | ui` — selects the gate suite from
  `.loom.yml`.
- **PRD requirement**: the requirement ID this ticket satisfies; the gate
  verifies faithfulness against it.

Ambiguity found while writing a ticket is a phase-1 escape: close the decision
in the ADR/UX spec *first*, then write the ticket.

**Publishing comes last.** Published one at a time, each body is composed,
pushed and left behind before the next starts, so nothing ever holds the set —
consistency across tickets is whatever survives in one long context. *(paid:
nine cross-ticket ambiguities in a 54-ticket set, every one in the join
between two tickets and invisible from inside either; four would have failed
the build or the demo.)* So the phase drafts the whole set first:

1. Read the source documents.
2. Write every ticket body into **one draft file, one epic at a time** — a
   single pass over the whole set drifts by the end: the last epic's
   vocabulary wanders from the first's. Store it beside the PRD; it outlives
   the phase — `replan` diffs against it.
3. Re-read the whole draft **from the file**, not from memory — the only step
   that can see across tickets.
4. Run the check list below over the draft: the phase's single self-check.
5. Show the human **the bodies**, not the titles, with the surviving
   ambiguities as decisions to answer — `/lavish` carries this shape.
6. Apply the answers to the draft file.
7. Hand the finished set to `/to-tickets` to publish. It keeps owning slicing,
   blocking edges and the tracker mechanics; it stops owning the order in
   which bodies are decided.
8. Keep the draft file.

**The check list** — one gate, one list, before anything is published. Phase 5
keeps its `graph` verdict as a backstop on the published build; it stops being
the first time anyone finds out.

*Shape* — is this set buildable at speed?

- **Width**: how many tickets can start at once, and at every layer, computed
  from the draft's own edges. A graph that opens one ticket wide idles every
  lane however well the loop runs *(paid: a build peaked at 2 lanes of 4, its
  first hour at 0–1 startable)*. Where a heavy blocker gates several
  dependents, split it with **Pinned interfaces**: a tiny `interface + stub`
  ticket that merges fast, the implementation behind it — the dependents need
  the signature, not the merged body.
- **Size**: no ticket whose acceptance criteria cannot plausibly be met in one
  focused sitting — a lane's cost is fixed the moment its ticket is written,
  not when it runs. Read the acceptance-criteria count and file surface off
  the draft, and split with the same `interface + stub` tool width uses.

*Consistency* — does the set agree with itself?

- every pinned interface names its fields;
- every field a later ticket reads exists in the ticket that pins it;
- every capability one ticket's criteria assume has a ticket that builds it;
- shared vocabularies — status and severity words, intent lists, state
  names — are identical everywhere they appear;
- no ticket's acceptance criteria contradict its own mandatory adversarial
  tests;
- every command a ticket's gate tier will run exists by the time that ticket
  merges.

## Phase 5 · `build` — define or adjust the build (never starts it)

`build` shapes the build plan and spends nothing. Two modes, auto-detected:

1. **No build defined** → the `/lavish` epic-selection surface (complete epics
   ✓ unselectable, partial with progress — selecting includes only remaining
   open tickets — untouched selectable, size estimates). On submit: create the
   `Build N` issue (selected epics, config snapshot quoted) and label member
   tickets `build-N`. **Only now** does the build exist to measure, so report
   its shape alongside `max_lanes` — `tick.sh snapshot | tick.sh graph` — and
   surface a `CHAIN-SHAPED`, `NARROW START` or `LIKELY DEEP` verdict as a
   reason to go back to phase 4 and split a blocker or an oversized ticket
   per its check list, not a fact to discover at wave 1 — a backstop on the
   published build, not the first time anyone looks. Then **stop**
   — tell the human the trigger is `/loom start`.
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

**`start` also opens the window on the build it just armed.** Inside herdr it
raises the viewer itself — a pane per live worker plus the build ticker — and
clears both off-switches on the way, so a `q` pressed in a previous build's
ticker cannot leave this one unwatched. `watch` clears them too, by the same
argument — both are typed by a human asking to see the build. Those two are the
only paths: an automatic tick undoing a human's close would make the switch
worthless. Outside herdr, and when a viewer is already up, it does nothing.

**`start` is now what makes a build autonomous, not a side effect of ticking.**
Without it, a lane cannot chain and an automatic tick does nothing; a manual
`/loom tick` still runs exactly one wave. *(paid: a single manual tick
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
