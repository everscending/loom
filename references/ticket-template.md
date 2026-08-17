# Loom ticket additions

Appended to `/to-tickets`' issue template for every orchestrated ticket.
Write tickets as **specs a sub-agent parses, not essays**: fragments and
bullets; Context ≤ 2 sentences; no lead-ins; no restating other sections.
(Both rules and the two blocks below are paid for by the tdd-swarm era:
7 of 8 rejections in a 15-ticket run traced to ticket ambiguity.)

## Design decisions — implement, do not relitigate

One line each: `Decision — reason`. Close every point two engineers could
disagree on. A vague phrase in the ADR/UX spec ("a response that loses its
substance") must be decided and written back *there* first — never
silently turned into an invented threshold here.

## Pinned interfaces

Only when this ticket shares a seam with another in-flight ticket: the
exact signature(s), verbatim, identical in every affected ticket. Marked
non-relitigable. States fields, values and shapes — a type body, a JSON
example with its field rules, a function signature. An endpoint path, a
bare type name or a file path is a reference, not a pin. An interface
ticket whose shape appears in no document of record must specify the
shape itself.

**This is also the widening tool.** A dependent needs its blocker's
*interface*, not its merged body — so a heavy blocker gating several
tickets should be split in two: a small **interface + stub** ticket
carrying the pinned signature (one fast merge cycle), and the
implementation behind it. The dependents block on the stub, so the
frontier opens that much sooner and the implementation runs beside them
instead of ahead of them.

## Mandatory adversarial tests

Inputs that must be **rejected**, one per line, ending with:
"fix the rule, not my examples."

State the three conditions the implementer must satisfy, not prose: the
test is **committed**, it is **named in this tier's command list in
`.loom.yml`**, and it is **demonstrated to fail** when its subject is
broken. Each bullet is answered by name — bullet → the test function
asserting it — in the MR description; a bullet with no name beside it is
unfinished work, not a lane note. A bullet the implementer can *prove*
unsatisfiable ends the lane `blocked` with that proof, never in `review`.
*(paid: seat-reservations build-1 — 4 of 5 gate FAILs were this one
family, three rounds converging on "the test must actually run";
ai-workout build-1 — 4 of 7, every test committed and running, none
asserting its bullet.)*

## Repo-wide guards

Only when a deliverable asserts over the **whole tree** — a lint rule, a
scan of `src/`, a conventions test — rather than this ticket's own files:
declare it here, one line per guard, scope and rule. A repo-wide guard is a
contract change binding every later ticket, so phase 4 surfaces this
section across the set and tightens an over-broad rule before it ships. A
tree-wide assertion that appears in no ticket's declaration is a defect in
the ticket, not a stricter test. *(paid: ai-workout build-1 — #30 shipped
an undeclared model-literal scan of all of `src`; it matched `"60s/side"`,
`"text/event-stream"` and `EMBEDDING_MODEL_NAME`, and merges started
failing on defects already on `origin/main`.)*

## Live check — running-app claims

Only when the deliverable claims something about the **running app**: one
acceptance criterion exercised against the running app, scoped to *this
ticket's* claim — never the epic's criteria, which stay with the wiring
ticket. Reuse the epic's wiring script where one exists, or write the
check the wiring ticket will later absorb.

The check runs in the **implementation lane** and records an artifact — a
log or run file, named in the criterion — which the gate then reads. Gates
never call live providers; this moves first contact earlier in the lane's
work, not into the gate.

A ticket whose live check needs billable provider spend may defer to the
wiring ticket, as a written decision in **Design decisions**. Silence is
not deferral. *(paid: boostlingo build-4 — #106, the turn render
disagreeing with the wire frame, surfaced only while running wiring ticket
#98's script, after every E10 implementation member had merged; #105, a
balance-check script crashing on a missing dependency, surfaced the first
time #102's preflight actually ran it. Each needed its own subject run
once, live — not the assembled epic.)*

## Terminal condition — `fix` tickets only

Where the defect ends, in the acceptance criteria, one of exactly two
shapes: **zero** — the measured count reaches zero — or an **accepted
residue** threshold carrying its number, how that number is measured, and
why that much is tolerable. "Reduce" and "improve" are not terminal
conditions; a fix ticket without one is a phase-4 defect, not something a
lane discovers at gate time.

The threshold is the escape valve, not a loophole. Closing over residue
stays legal; it stops being *silent* — at or under the threshold the gate
demands a filed, linked follow-up before it passes the ticket (SKILL.md
step 3). *(paid: boostlingo build-4 #101 cut speech-end mark
misattribution from 64.9% to 35.4% of turns and closed with the remainder
accepted and nothing tracking it; build-5's audit re-found it and spent
three of its nine tickets — #107 to finish the fix, #110 and #112 to
re-measure the two numbers it had corrupted — plus the audit time to
rediscover a figure the closing lane already knew.)*

## Risk tier

`docs | logic | api | ui` — one word. Selects the gate suite from
`.loom.yml`. When in doubt between two tiers, take the higher.

When Acceptance criteria or Mandatory adversarial tests explicitly name
Playwright or an `e2e/*.spec.*` test, Loom mechanically raises the effective
host pregate/admission tier to `ui` without rewriting this section. UI scope
rules then apply; cross-tree paths remain legal when the ticket names them.
A missing UI runner fails closed before the review provider starts; browser
evidence is never reconstructed inside an agent sandbox. *(Paid: Patient
Imaging Portal JOR-294.)*

## PRD requirement

The requirement ID(s) from the spec this ticket satisfies. The
verification gate checks faithfulness against the requirement text — a
ticket that passes its own criteria but not its requirement is rejected.

Width and size are checked over the whole drafted set at once — the phase-4
check list in [phases-1-5.md](phases-1-5.md) owns both, before anything is
published.
