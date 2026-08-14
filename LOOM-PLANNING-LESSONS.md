# Loom planning issues — a journal

A running history of the ways loom's front half (phases 1–5) has produced a
build that then failed downstream, and what was changed in
[`references/phases-1-5.md`](references/phases-1-5.md) to stop each one.

The point is refinement over time: every entry records what was tried, so a
later fix can tell "this was never addressed" apart from "this was addressed
and the fix was not enough." When an old failure recurs, do not open a new
entry — reopen the old one and add a round.

**One entry per class of failure, not per incident.** Each carries:

- **Symptom** — what was observed, and where it surfaced.
- **Cost** — what the failure actually spent.
- **Insight** — why the process allowed it. This is the part worth keeping;
  the fix is downstream of it.
- **Fix** — the exact section changed, and the rule added.
- **Status** — open, fixed, or fixed-and-recurred, with the round count.

Newest first.

---

## PI-09 · The environment contract pinned well-known host ports, and sibling builds own the same machine

**Date:** 2026-08-14 · **Status:** fixed, round 1 · **Incidents:** 1 (three tickets)

**Symptom.** JOR-93, JOR-95 and JOR-114 (demand-letter build-1) all blocked on
one wall: `Bind for 0.0.0.0:5432 failed: port is already allocated`. The
compose file pins Postgres to host port `5432:5432`; another project's
long-running container (`triggers-api-wt-62-postgres-1`) already held 5432, so
this repo's Postgres came up healthy with no published port and every
integration suite authenticated against the wrong database — `password
authentication failed for user "postgres"`. Same class inside the build: a
vite-proxy test bound fixed port 3000 that a sibling worktree's leftover dev
process held.

**Cost.** Three gated tickets parked on a human port decision, two pregate
runs spent rediscovering one diagnosis, four dependent tickets stalled behind
them.

**Insight.** The pin list covers surfaces shared between tickets; the host
machine is a surface shared between builds, and loom's own execution model —
concurrent lanes, sibling worktrees, several projects per machine — guarantees
contention for it. Pinning `5432:5432` asserts the lane owns the machine, and
nothing owns the machine. Executing the compose file at planning time proves
nothing here: the collision is temporal, whoever boots second loses, so the
check must be structural, not empirical.

**Fix.** Two edits to `references/phases-1-5.md`:

1. *Phase 1–2, step 5 (Pin every shared surface)* — the pin list now names the
   host substrate: every host-bound resource in the environment contract
   (published container ports, listen ports of test fixtures, container,
   volume and bucket names) is either namespaced per project and worktree or
   configurable with a non-default per-repo default; a bare well-known port
   (5432, 3000, 6379, 9000…) is refused on sight.
2. *Phase 4, check list (Ends group)* — a gate or live check that binds a
   fixed port is a defect; test fixtures bind port 0 and pass the port to the
   client.

**What to watch.** Whether lanes actually inherit per-worktree values, and
whether the orchestrator cleans leftover dev processes — the port-3000 half of
this incident was runtime hygiene, which no authoring rule reaches.

---

## PI-01 · Sibling tickets co-own one module, and the collision only surfaces in the merge queue

**Date:** 2026-08-13 · **Status:** fixed-and-recurred, round 2 · **Incidents:** 3

**Symptom.** JOR-69 (E11.6 · motion, reduced motion, keyboard) passed its gate
clean — 125 tests, four Playwright e2e tests, an independent review with no
findings — then failed both merge attempts against `origin/main` on a genuine
design conflict and went to `Blocked` for a human.

Four files conflicted: `Segment.tsx`, `PendingSegment.tsx`, `Timeline.tsx`,
`Track.tsx`. E11.1 (JOR-64) built them. E11.3, E11.4 and E11.6 each extended
them, all as siblings hanging off E11.1 with no blocking edge between them.
E11.4 gave Segment an `onSelect`/`onSelectAttempt` contract with local
Enter/Space handling; E11.6 gave the same component a roving-tabindex contract
with `tabIndex`/`onFocus`/`onBlur` and `onActivateSegment` on Track. Two
designs for one interaction. E11.3 had separately rewritten Track to freeze its
layout in a `useMemo` and scroll by a `<g>` transform, so E11.6's keyboard work
no longer had the Track it was written against.

The ticket bodies knew about each other — E11.4's code carries the comment
"roving tabindex … is UX-SPEC.md §11's own ticket (E11.6)" — but knowing is not
an edge and not a pinned contract.

The earlier incident is the same class seen from the other side: JOR-72 built
the replay/discard endpoints that JOR-49 owned, because no edge tied the
consumer to the producer and nothing told the lane to block instead of build.
JOR-49's whole branch was lost. (Logged in `OPEN_DEFECTS.md` as D-REF-16, with
D-SKILL-14/15/16 as the in-lane and at-gate lines of defence.)

**Cost.** Two merge attempts (the cap), a human decision to reconcile two prop
contracts by hand, and a completed, reviewed, green ticket parked
indefinitely — plus JOR-78, the E11 wiring ticket, blocked behind it. In the
earlier incident, one ticket's entire body of work.

**Insight.** *Width and size are scored on the feature axis, and the edge set
gets drawn there too — but builds die on the file axis.* Two tickets writing
one module is invisible in a dependency graph. Worse, the incentive is
backwards: leaving the edge out makes a draft score **better** on width, the
one dimension the check list actually measured. So the check that existed
rewarded the omission.

Two secondary points, both load-bearing:

- The stacked epic is the normal shape of UI work — one ticket builds a
  component, three more extend it — and it reads as a wide, parallel frontier
  when it is nothing of the kind. A UI epic is the default place to look for
  this, not an exotic case.
- The merge queue is the worst possible discovery point. A merge lane is
  forbidden to make design decisions, so a conflict that *is* a design decision
  can only stop the build and wait for a human. Everything about this failure
  was knowable while writing the tickets, for free.

**Fix.** Three edits to `references/phases-1-5.md`:

1. *Phase 1–2, step 5 (Pin every shared surface)* — the pin list was built from
   process boundaries (wire shapes, environment variables, URLs), so an in-repo
   prop contract fell through it. It now names "the exported signature of any
   in-repo module more than one ticket will touch — a component's props, a
   hook's arguments, a store's actions," with the reason: a prop contract is a
   seam exactly as much as a wire shape is; it simply never leaves the process.
2. *Phase 4, ticket additions* — **Pinned interfaces** now says a seam is
   anything two tickets both touch, and that when several tickets extend one
   component the pinned shape is the **union contract**: the props the module
   carries after the last of them lands, quoted in every co-owner's body, each
   adding its own part and restructuring nothing. A new **Files touched**
   bullet requires each body to name the modules it creates or changes.
3. *Phase 4, the check list* — a new **Ownership** criterion, placed **first**,
   ahead of Shape, so width is measured over an edge set that is already
   complete. It builds a module → tickets map from the Files touched lines and
   settles two cases: *consumed, not built* gets an edge to the builder or a
   shared `interface + stub` ticket (this closes D-REF-16's fix shape);
   *co-edited* is either serialized by an edge or pinned by the union contract,
   never neither. It closes by naming the trade out loud — serialization
   narrows the graph on purpose, and a narrower frontier that merges beats a
   wider one that collides — because the previous list's own width criterion
   pushes the other way.

**What to watch.** Ownership is authoring guidance; nothing mechanical enforces
it. The Files touched line is the hinge — if bodies stop carrying it, the check
goes blind and cannot even tell that it is blind. The mechanical residue worth
building is the one D-SKILL-16 already names: `snapshot` computes
`file_surface` per ticket, so a tier-to-tree map could refuse the collision in
the pregate without judgement. Watch also whether serialization over-narrows a
UI epic into a single chain; if it does, the answer is a smaller first ticket
that pins the union contract, not a looser rule.

**Round 2 — 2026-08-14 · demand-letter build-1 (JOR-97).** E3-1 built
`packages/docx`; the slots ticket and the tracked-changes ticket extended
`document.ts`/`save.ts` as siblings. The merge cap was hit on two incompatible
models for `DocxHandle`'s hidden state — an `editedParts` Map on the handle vs
a `WeakMap<DocxHandle, DocState>` — a design decision the merge lane is
forbidden to make.

Round 1 failed twice over. First, the tickets were published the day before
the fix landed, and nothing re-audits a published set when a lesson arrives: a
fix reaches only the next plan, so a lesson learned mid-build is a lesson not
applied. Second, the union contract pins *exported signatures*, and this
collision lived in state no export names. A stateful core — a handle or store
with hidden internals — can satisfy the union pin and still carry two
irreconcilable designs.

**Fix, round 2.** Two edits to `references/phases-1-5.md`:

1. *Phase 4, Ownership, co-edited case* — when the co-owned module is a
   stateful core, the pin must include the state-ownership model (where state
   lives, how an extender attaches to it), quoted verbatim in every co-owner's
   body; exported signatures alone are not a pin. Default for co-edited
   internals is serialization, not pinning.
2. *Phase 5* — when a planning-lesson fix lands while a build has published,
   not-yet-built tickets, run the new check over the published set before the
   next wave; the kept phase-4 draft file (PI-06) makes this a checklist pass,
   and `replan` carries any amendments.

---

## PI-02 · Phase 1 closed decisions but never pinned seams, and declared its own exit

**Date:** 2026-08-11 · **Status:** fixed, round 1 (partially insufficient — see
PI-01) · **Commit:** `7b587b4`

**Symptom.** Phase 1–2 was four steps: read the PRD, grill open questions,
write ADRs, do the same for UX. Its exit criterion was that a ticket-writer
*could* answer every "which way?" from the ADRs and UX spec alone — a state the
author asserted about their own documents.

**Insight.** An ADR closes a decision; it does not pin a surface. Anything
named in no document of record is decided by whichever lane starts first. And
an author cannot test their own spec: knowing what you meant makes gaps read as
filled, so "could answer" is not a criterion, it is a feeling.

**Fix.** Rewrote phase 1–2 to eight steps, adding: mint stable requirement IDs
first (`REQUIREMENTS.md`); **pin every shared surface** with an explicit seam
test; execute code-shaped artifacts against the real substrate at a scale where
the defect class can appear; make the exit criterion *a test that is run, by
fresh agents given only the files, one per consumer role*, re-audited after
every fix pass; and terminate on a bounded confirmation rather than on zero
findings.

**Round 2 needed.** PI-01 shows the pin list was drawn from process
boundaries, so in-repo module signatures were not covered. Extended there.

---

## PI-03 · A fix ticket closed over unstated leftovers, and live contact waited for the wiring ticket

**Date:** 2026-08-08 · **Status:** fixed · **Commit:** `824ffea`

**Symptom.** Two separate leaks. A `fix` ticket that says "reduce" closes at
whatever residue it reaches, and the remainder is owned by nobody until a later
build's audit pays to re-find it (boostlingo #101 closed at 35.4% residual;
build-5 spent three of nine tickets on the leftover). Separately, every ticket
deferred its live contact to the epic's wiring ticket, which lands *after* the
whole epic — so anything only a live run can show surfaced at the very end,
with every dependent already built on the unverified claim.

**Insight.** A ticket must say where it stops, and the wiring ticket is the
epic's last proof, not its first live contact.

**Fix.** Phase 4 additions: a **Terminal condition** on every `fix` ticket
(zero, or a threshold with its number, its measurement and its reason — the
gate turns a stated threshold into a filed follow-up), and a **Live check** on
any ticket claiming something about the running app, scoped to its own claim,
run in the implementation lane. Deferring is still allowed but must be written
down as a decision. Both echoed in the check list's *Ends* group.

---

## PI-04 · An epic with no wiring ticket was judged only by its own unit gates

**Date:** 2026-08-07 · **Status:** fixed · **Commit:** `9ac3659`

**Symptom.** Every E1 ticket in ai-workout build-1 passed its gate while the
running app never called `build_kg1()` once, `/api/graph/focus` served
byte-identical fixture output for every member, and 18 `bilateral_pair_id`
values dangled. The acceptance probe found all of it, at a cost of three fix
tickets.

**Insight.** Tier gates judge tickets. Nothing judged the *epic* until the
probe, which is the last step of the build.

**Fix.** Every epic ends with a wiring ticket, blocked by every other member,
whose acceptance criteria are the epic's own criteria run against the running
app and real data. `tick.sh graph` refuses a build definition whose epics lack
one — `UNWIRED EPIC` exits 1, so it costs a phase-5 rerun rather than an epic.

---

## PI-05 · Gate commands depended on files no ticket had delivered yet

**Date:** 2026-08-07 · **Status:** fixed · **Commit:** `477ca7f`

**Symptom.** ai-workout build-1 merge lanes died on a missing `gate.sh` and
`gen_openapi_client.py`. Five tickets mass-blocked, about an hour of stall
waiting for a human waiver.

**Insight.** An acyclic ticket graph proves nothing here — the cycle runs
through a shell command's file dependency, which no link-based closure check
can see.

**Fix.** Phase 5 runs `tick.sh gate-deps` when the build is defined and on
every membership amendment: it resolves every file the tiers' gate commands
invoke and checks each against the base branch. A missing file must be
delivered by a ticket blocking every ticket carrying that tier, or the
definition is refused. At runtime the pregate declares the gap instead of
silently skipping.

---

## PI-06 · Tickets were published one at a time, so nothing ever held the set

**Date:** 2026-08-07 · **Status:** fixed · **Commit:** `83940fb`

**Symptom.** Nine cross-ticket ambiguities in a 54-ticket set. Every one lived
in the join between two tickets and was invisible from inside either. Four
would have failed the build or the demo.

**Insight.** Composing, pushing and dropping each body in turn means
consistency across tickets is only whatever survives in one long context.

**Fix.** Phase 4 now drafts every body into **one file, one epic at a time**,
re-reads the whole draft *from the file*, and runs a single check list over it
before `/to-tickets` publishes anything. The draft file is kept — `replan` diffs
against it. (PI-01 added the Ownership group to that check list; PI-03 added
*Ends*.)

---

## PI-07 · Pinned interfaces named references instead of fields

**Date:** 2026-08-06 · **Status:** fixed · **Commit:** `e4efea3` (P59)

**Insight.** A pin that says "the endpoint in the ADR" or names a type is not a
pin — the reader still has to go and decide something.

**Fix.** The exact signature goes verbatim into every affected ticket: fields,
values and shapes, never a bare endpoint path, type name or file path.

---

## PI-08 · Ticket size was discovered at run time, not at authoring time

**Date:** 2026-08-06 · **Status:** fixed · **Commit:** `ab01fa2`

**Insight.** A lane's cost is fixed the moment its ticket is written, not when
it runs.

**Fix.** **Size** joined **Width** in the check list: no ticket whose
acceptance criteria cannot plausibly be met in one focused sitting, read off
the draft's own criteria count and file surface, split with the same
`interface + stub` tool width uses.
