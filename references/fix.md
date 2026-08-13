# `fix <Dn>|<severity>` — implement one confirmed defect, or a whole severity tier

Human-run, like `qa`, `retro`, `optimize` and `prop`. Never invoked by a wave.
The argument is either a defect key exactly as `OPEN_DEFECTS.md` writes it —
`D-TICK-01`, `D-LANE-02`, case insensitive, with or without the `D-` — or a
severity word from the file's own scale, case insensitive: `critical`,
`high`, `medium`, `low`. A severity argument runs every open defect at that
severity, one at a time, in the order Step 0 derives — everything from Step 1
on is unchanged and runs once per item: its own subagent, its own suite run,
its own close, its own commit.

## Step 0 — resolve it, and read the rules that bind it

**A defect key**: find `^### D-<FILE>-<nn> ·` in `OPEN_DEFECTS.md`. Not
there? Say so and list the open keys in that file's section (or all sections
if the file segment can't be told from the argument). Found under
`## Closed`: it's already fixed — quote the `**Shipped:**` line and stop.

**A severity word**: read the `| Key | Severity | Defect |` table under
`## Index of open defects` and filter its rows to the given severity — that
table *is* the open set, so there is nothing else to query. No matching rows:
say so and stop, naming the severities that do have rows. A batch that stops
partway — human interrupt, context limit, an entry that no longer matches
(Step 2) — needs no bookkeeping to resume: closing an entry already removed
its row from this table, so re-running the same severity word recomputes
exactly what's left.

Then read `## How to use this file` at the top, not just the entry itself.
Those rules are this verb's constitution — stable keys, never renumbered,
line numbers drift, locate by function name — and are restated below only
where this verb adds something.

**A `Covered by: Pn` line means this defect is not a standalone fix.** It is
scoped into a larger change decided in `PROPOSALS.md`. For a single defect
key, refuse outright and point at `prop <Pn>` instead — do not implement a
partial fix that a proposal will later redo. For a severity batch, skip it
instead: name it and the proposal it belongs to in the final tally, and fix
everything else at that severity — a batch that hard-stopped on the first
`prop`-scoped entry it met would make the severity argument useless on any
tier `prop` has already partly claimed.

## Ordering a severity batch

*(Skip this section for a single defect key — there is nothing to order.)*

State the order and a one-line reason per item before the first fix starts,
so a human watching can redirect before any edit lands. This is a judgment
call, not a formula — the same kind of planner judgment this skill surfaces
elsewhere rather than burying, and the reasoning below is exactly what should
be said out loud, not silently applied:

1. **File first.** Group defects by the file section they live under in
   `OPEN_DEFECTS.md` (`scripts/tick.sh`, `scripts/snapshot.jq`, …) and finish
   one file's group before starting the next. Adjacent fixes in the same
   file are cheaper to get right back-to-back — the next subagent locates its
   target against code the previous one already touched, instead of a
   citation that has already drifted — and it keeps the collision Step 1
   already warns about (every fix touches `scripts/tick-test.sh`; every close
   touches `OPEN_DEFECTS.md`) confined to one file pair at a time instead of
   scattering it across the whole batch.
2. **Worst blast radius first, within a file.** Read each entry's
   **Failure** paragraph, not just its title. A defect whose failure is
   silent — wrong state accepted with no warning, a build or milestone
   reporting done when it isn't — outranks one whose failure is visible (a
   refusal, a crash, a stuck-but-flagged state): the silent one keeps
   compounding for as long as it goes unnoticed. Severity in this file is
   already a same-pass judgment call, not a fixed ranking (see `## Index of
   open defects`), and this tiebreak is the same kind of call.

## Step 1 — hand the implementation to a subagent, in its own worktree

Steps 2 and 3 — reproduce, edit, test — are done by **one subagent**, not in
this session, and not against this directory directly. The work is a bounded
read-edit-test loop over two or three files; running it inline spends the
human's context on file dumps and test output that nothing later in this verb
needs, and running it against the human's own checkout leaves an unproven fix
sitting in a tree the human may still be reading.

Spawn a single general-purpose subagent with `isolation: "worktree"` — the
harness cuts a fresh worktree off this branch and the subagent's edits land
there, not here. Split of duties, and it is not negotiable in either
direction:

| this session | the subagent |
|---|---|
| step 0 (resolve, refuse a `Covered by`) | steps 2–3 (reproduce, fix, test) |
| step 3 (**run the suite**, close) in the worktree; step 4 (merge back, commit, remove the worktree) | nothing in `OPEN_DEFECTS.md`, no commit, no merge |

The subagent reports; it does not close and it does not commit. Closing is a
judgment about whether the fix is whole (step 3's partial-fix rule), and the
commit is the durable record — both stay where the human can see them.

**One defect per subagent, and one subagent at a time.** Two defects sound
parallel and are not: every fix touches `scripts/tick-test.sh` and every close
touches `OPEN_DEFECTS.md`, so a second lane in flight collides on both. Run
the second `fix` after the first commits. A severity batch is this same rule
applied automatically down its ordered list: finish one item's Step 4
(committed, merged, worktree removed) before Step 1 opens for the next —
nothing about a severity argument grants two items in flight together.

**Model.** Pick by the shape of the entry, not its severity. An entry whose
**Fix** line names the exact edit and whose blast radius is one function is
mechanical — the session default is right. An entry that leaves a choice open
("cheaper alternative worth considering"), spans layers, or touches a function
with no existing test coverage needs the top tier, because the subagent is
deciding, not typing.

**The brief is the failure surface** — the subagent has none of this skill's
context. Inline into it: the defect entry **verbatim**, the layer order and
untouchable-contract rules from step 2, the test rule from step 3, *sibling
skills are off limits*, *never run a real build*, and *do not touch
`OPEN_DEFECTS.md` and do not commit*. Ask back for: files changed with one
line each, the `SKILL.md` line delta if any, the new assertion — case name,
and whether it's a new case or folded into an existing one — full
`tick-test.sh` counts, and anything in **Failure** that would not reproduce.

If the report says the described behaviour is no longer in the code, stop —
do not close an entry that no longer matches. Say what changed and let the
human re-decide.

**Green is the one claim you never take on trust.** The subagent runs the
suite while it works, but this session runs `bash scripts/tick-test.sh` again
itself before step 3 — the counts are what the whole verb rests on, and a
subagent has every incentive to report the run it meant to finish rather than
the one it finished. Read the `FAIL:` lines, not just the total. *(paid:
D-TICK-14's subagent reported done across three idle cycles without ever
sending counts; the suite showed its own planted-violation case failing with
an empty `rc=`, because it had copied `tick.sh` into a scratch directory
without `lib.sh` beside it — the mutant died at source time and the case
proved nothing. Left alone it would have passed vacuously the moment the
fixture drifted.)*

Two runs that disagree mean a flaky test, not a fixed one: name it before
dismissing it, and say so when reporting the counts.

## Step 2 — the entry is the diagnosis, not the starting point

*(This step and the next are the subagent's work, briefed per step 1.)*

**Failure** is the reproduction; **Test** says what the suite currently
misses. Implement the fix that closes the exact failure described — do not
generalise to adjacent code the entry doesn't name.

Check the defect still reproduces first. Line numbers drift (`tick.sh:164`
was true the day it was recorded) — locate the function by name.

### Where the code goes

Same layer order as `prop` ([prop.md](prop.md) step 2): `scripts/` first,
`references/` second, `SKILL.md` last resort, same budget-zero-lines
discipline. The untouchable-machine-contract list in
[optimize.md](optimize.md) step 2 applies the same way here.

Sibling skills (`/to-tickets`, `/implement`, `/code-review`, `/grilling`,
`/lavish`, `/prototype`) are off limits, per the `PROPOSALS.md` preamble,
which governs this file too. Re-scope into this skill's own layer or stop.

### Tests

*"A fix is not done until a test fails without it"* — the file's own rule,
and it is about proof, not about volume: what's required is one new
red-then-green **assertion**, not necessarily one new test process. *(paid:
`16-ticker-and-lane-verbs.sh:82-93` carries three separate `ok` blocks
asserting the exact same prefix-stripping invariant against three literal
string variants — one parametrized case would have proven the same thing.
Nothing wrong with any one of them alone; nothing in this step ever asked
whether the assertion belonged inside a case that already existed.)*

The entry's **Test** line names what's missing. Before writing anything,
check whether a test in that section already exercises the function or
scenario the defect lives in. If one does, extend it — a new row in a
table-driven case, a new assertion inside a test that already builds the
right fixture — rather than standing up a separate `ok` block beside it.
Write a wholly new case only when nothing existing reaches this code path.
Either way it lands in the section it belongs to —
`scripts/tests/NN-<topic>.sh`, one process each over `scripts/test-lib.sh`
— in its house style, asserting the guard both holding and failing with the
fix reverted. While iterating, run that section alone
(`bash scripts/tick-test.sh <name>`, seconds rather than minutes).

Run `scripts/tick-test.sh` in full and report the counts, pass and fail. It
is the only executable check this skill has. A fix that lands with no new
red-then-green assertion in that suite is not finished — assertion, not
necessarily test count.

Never run a real build to verify. It costs hours and real money.

## Step 3 — run the suite, then close the entry

Back in this session, `cd`'d into the worktree path the subagent's `isolation:
"worktree"` result returned — not this directory, which never saw the edits.
`bash scripts/tick-test.sh` first, per step 1 — a red suite means the fix is
not finished, and the failing case is usually the subagent's own new one. Send
it the failing lines and have it fix them; do not repair its test yourself,
and do not close over a red run.

Then, per `OPEN_DEFECTS.md`'s own rule — never delete a row, never renumber:

- cut the `### D-<FILE>-<nn> · …` entry from its file section, append it
  under `## Closed` in key order (after the last closed entry);
- keep the key and the original title;
- replace the body with `*Closed <date>.*` followed by a short restatement
  of the defect (what was true, condensed — the reproduction detail can
  drop) and a `**Shipped:**` paragraph naming what changed and where;
- if the fix is partial, nothing moves — leave the entry where it is and
  add a line noting what shipped and what remains.

## Step 4 — commit, merge back, clean up

Still in the worktree. Commit everything the change touched — scripts,
references, `SKILL.md`, `OPEN_DEFECTS.md` — as one commit whose subject names
what shipped, citing the key (`git log --oneline` shows the house style:
`"fixes D-LANE-02"` per the file's own convention).

Then, back in this directory (the main clone): `git merge --no-ff
<worktree-branch>` into `main` — never rebase, so the worktree's history stays
exactly what step 3 tested green. Resolve a real conflict as a stop-and-report,
not a silent pick; a `fix` touching two or three files should rarely produce
one. Once merged, `git worktree remove <path>` and delete the branch —
teardown is this session's job, not something to leave for later, and not
something the subagent does (it has no merge rights).

## Deliver

Relay the subagent's report — the counts are your own from step 3, the rest
is its work and does not need re-deriving:

- what changed, one line per file
- the `SKILL.md` line delta, and the reason for each line added
- test counts from `scripts/tick-test.sh`, and which assertion is new — a
  new case, or an addition to one that already existed
- anything in **Failure** you could not reproduce, or **Covered by** you
  deferred to `prop` — flag it, do not improvise

For a severity batch, deliver each item as its own block in the order it
landed, then close with one line: how many fixed, how many skipped as
`Covered by` (naming the proposal each defers to), and confirmation the
suite was green after every single close along the way, not just the last
one.
