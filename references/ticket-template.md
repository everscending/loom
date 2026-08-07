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

## Risk tier

`docs | logic | api | ui` — one word. Selects the gate suite from
`.loom.yml`. When in doubt between two tiers, take the higher.

## PRD requirement

The requirement ID(s) from the spec this ticket satisfies. The
verification gate checks faithfulness against the requirement text — a
ticket that passes its own criteria but not its requirement is rejected.

Width and size are checked over the whole drafted set at once — the phase-4
check list in [phases-1-5.md](phases-1-5.md) owns both, before anything is
published.
