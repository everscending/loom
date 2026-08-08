# `fix <Dn>` — implement one confirmed defect

Human-run, like `qa`, `retro`, `optimize` and `prop`. Never invoked by a wave.
The argument is a defect key exactly as `OPEN_DEFECTS.md` writes it —
`D-TICK-01`, `D-LANE-02`, case insensitive, with or without the `D-`.

## Step 0 — resolve it, and read the rules that bind it

Find `^### D-<FILE>-<nn> ·` in `OPEN_DEFECTS.md`. Not there? Say so and list
the open keys in that file's section (or all sections if the file segment
can't be told from the argument). Found under `## Closed`: it's already
fixed — quote the `**Shipped:**` line and stop.

Then read `## How to use this file` at the top, not just the entry itself.
Those rules are this verb's constitution — stable keys, never renumbered,
line numbers drift, locate by function name — and are restated below only
where this verb adds something.

**A `Covered by: Pn` line means this defect is not a standalone fix.** It is
scoped into a larger change decided in `PROPOSALS.md`. Refuse, name the
proposal, and point at `prop <Pn>` instead — do not implement a partial fix
that a proposal will later redo.

## Step 1 — hand the implementation to a subagent

Steps 2 and 3 — reproduce, edit, test — are done by **one subagent**, not in
this session. The work is a bounded read-edit-test loop over two or three
files; running it inline spends the human's context on file dumps and test
output that nothing later in this verb needs.

Spawn a single general-purpose subagent. Split of duties, and it is not
negotiable in either direction:

| this session | the subagent |
|---|---|
| step 0 (resolve, refuse a `Covered by`) | steps 2–3 (reproduce, fix, test) |
| steps 3–4 (close the entry, commit) | nothing in `OPEN_DEFECTS.md`, no commit |

The subagent reports; it does not close and it does not commit. Closing is a
judgment about whether the fix is whole (step 3's partial-fix rule), and the
commit is the durable record — both stay where the human can see them.

**One defect per subagent, and one subagent at a time.** Two defects sound
parallel and are not: every fix touches `scripts/tick-test.sh` and every close
touches `OPEN_DEFECTS.md`, so a second lane in flight collides on both. Run
the second `fix` after the first commits.

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
line each, the `SKILL.md` line delta if any, the new test case name, full
`tick-test.sh` counts, and anything in **Failure** that would not reproduce.

If the report says the described behaviour is no longer in the code, stop —
do not close an entry that no longer matches. Say what changed and let the
human re-decide.

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

*"A fix is not done until a test fails without it"* — the file's own rule.
The entry's **Test** line names what's missing; add that case to
`scripts/tick-test.sh` in its house style, asserting the guard both holding
and failing with the fix reverted.

Run `scripts/tick-test.sh` in full and report the counts, pass and fail. It
is the only executable check this skill has. A fix that lands with no new
red-then-green case in that suite is not finished.

Never run a real build to verify. It costs hours and real money.

## Step 3 — close the entry

Back in this session, on the subagent's report.


Per `OPEN_DEFECTS.md`'s own rule — never delete a row, never renumber:

- cut the `### D-<FILE>-<nn> · …` entry from its file section, append it
  under `## Closed` in key order (after the last closed entry);
- keep the key and the original title;
- replace the body with `*Closed <date>.*` followed by a short restatement
  of the defect (what was true, condensed — the reproduction detail can
  drop) and a `**Shipped:**` paragraph naming what changed and where;
- if the fix is partial, nothing moves — leave the entry where it is and
  add a line noting what shipped and what remains.

## Step 4 — commit

The skill directory is a git repository. Commit everything the change
touched — scripts, references, `SKILL.md`, `OPEN_DEFECTS.md` — as one commit
whose subject names what shipped, citing the key (`git log --oneline` shows
the house style: `"fixes D-LANE-02"` per the file's own convention).

## Deliver

Relay the subagent's report — do not re-run its work to confirm it:

- what changed, one line per file
- the `SKILL.md` line delta, and the reason for each line added
- test counts from `scripts/tick-test.sh`, and which case is new
- anything in **Failure** you could not reproduce, or **Covered by** you
  deferred to `prop` — flag it, do not improvise
