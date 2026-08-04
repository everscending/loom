# Orchestrate ticket additions

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
non-relitigable.

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

## Risk tier

`docs | logic | api | ui` — one word. Selects the gate suite from
`.orchestrator.yml`. When in doubt between two tiers, take the higher.

## PRD requirement

The requirement ID(s) from the spec this ticket satisfies. The
verification gate checks faithfulness against the requirement text — a
ticket that passes its own criteria but not its requirement is rejected.
