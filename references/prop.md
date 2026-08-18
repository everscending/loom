# `prop <Pn>` — implement one open proposal

Human-run, like `qa`, `retro` and `optimize`. Never invoked by a wave. The
argument is a proposal ID exactly as `PROPOSALS.md` writes it — `P37`, case
insensitive, with or without the `P`.

## Step 0 — resolve it, and read the rules that bind it

Find `^## P<n> ·` in `PROPOSALS.md`. Not there? Look in
`PROPOSALS_ARCHIVED.md`: a hit means it was already implemented or dropped —
say which, quote the status line, and stop. In neither file: stop and list the
open IDs.

Then read the whole preamble of `PROPOSALS.md`, through the status table, not
just your section. Those rules are this verb's constitution — *stay inside this
skill*, *keep SKILL.md small*, *archive on implementation* — and they are
restated below only where this verb adds something.

A row marked `deferred` is a live decision someone parked; report the reason
and ask before proceeding. `in progress` means edits may already be on disk —
check `git log` before writing anything.

## Step 1 — the proposal is the decision, not the starting point

The **Fix** section was argued when it was written. Implement it; do not
re-open it, improve it, or generalise it.

Deviate only when the fix is factually impossible against today's code. Then
stop, say what changed since the proposal was written, and let the human
re-decide. Never silently substitute a different fix — a proposal that shipped
as something else leaves the archive lying about what the code does.

Check the **Evidence** still holds first. Line numbers drift (`tick.sh:1893`
was true the day it was written) — locate the function by name, not by line.
Evidence that no longer reproduces is worth a sentence in your summary.

## Where the work happens

Not in the main clone. Cut a worktree first and make every edit, every suite
run and the archive edit there:

    git worktree add .worktrees/prop-<Pn> -b prop-<Pn> main

**Branch from local `main` by name, never from `origin/HEAD`.** That is the
whole reason this step is written down: an agent harness cutting a worktree
for itself branches from the remote's default head, which lags by however many
commits this repo has not pushed, and the work then lands on a base that is
missing its own dependencies. *(paid: D-SNAP-17's worktree came from
`origin/main`, 32 unpushed commits behind, so the fix was written against a
function `main` had already rewritten — one hand-resolved conflict and a
second full suite run.)*

`.worktrees/` is git-ignored, which is what makes a path inside the
repo safe here. A **sibling** directory is not: this repo lives in the skills
tree, and a sibling of it carrying a `SKILL.md` registers as a second skill.

Step 5 merges it back and removes it. Nothing is left standing.

## Step 2 — where the code goes

Layer order. Use a layer only when the one above it genuinely cannot carry the
change:

1. **`scripts/`** — `tick.sh`, `lane.sh`, `bootstrap.sh`, `watch-panes.sh`.
   Anything mechanical, deterministic and checkable: guards, derivations,
   refusals, defaults, config. Most proposals belong entirely here.
2. **`references/`** — anything only a human reads, or that a wave reads once
   for one specific job. One subject per file; a change needing two unrelated
   subjects needs a new file.
3. **`SKILL.md`** — last resort. Only what a *wave* must decide and cannot
   derive from the tracker or from a script's own output. A rule the scripts
   now enforce does not need restating here.

**Budget SKILL.md at zero new lines and work up from there.** Prefer editing an
existing line, or deleting one the fix has made redundant. If it must grow: one
line, at the point of use, with the citation compressed to a 2–5 word tag
— `*(paid: verdictless gate exit)*`. Rationale, evidence and implementation
notes stay in the proposal and leave with it for the archive; they are never
copied into `SKILL.md`.

The untouchable list in [optimize.md](optimize.md) step 2 applies in reverse
here: every literal string, flag, lane id, label, jq path or section heading
you *add* becomes a machine contract that later compaction passes must
preserve. Introduce them deliberately and name them in your summary.

Sibling skills (`/to-tickets`, `/implement`, `/code-review`, `/grilling`,
`/lavish`, `/prototype`) are off limits, per the preamble. Re-scope into this
skill's own layer or stop; do not reach across.

## Step 3 — tests

A proposal's **Tests** section is its acceptance criteria. They go into the
section they belong to — the tests live in `scripts/tests/NN-<topic>.sh`, one
process each over the harness in `scripts/test-lib.sh` — in that file's house
style: every guard shown both holding *and* failing once its mechanism is
removed. A fix that lands in `tick.sh` or `lane.sh` with no test in that suite
is not finished.

While iterating, run the one section: `bash scripts/tick-test.sh snapshot`
takes seconds where the whole suite takes minutes (`--list` names them all).

Run `scripts/tick-test.sh` in full and report the counts, pass and fail. It is
the only executable check this skill has. `SKILL.md` and `references/` have
none, so their correctness is a reading — say so plainly rather than implying
a check that did not happen.

Never run a real build to verify. It costs hours and real money.

## Step 4 — archive the proposal

Per the tracking rules, and in the same commit as the code:

- cut the `## Pn · …` section from `PROPOSALS.md`, append it to
  `PROPOSALS_ARCHIVED.md` in ID order;
- move its table row across too, status `implemented <date> (<what shipped>)`;
- leave no stub row or pointer behind.

Implemented only in part? Nothing moves. Update the row in place to say what
shipped and what is left, and keep the section where it is.

## Step 5 — commit, merge back, push, clean up

Still in the worktree. Commit everything the change touched — scripts,
references, `SKILL.md`, both proposal files — as one commit whose subject names
what shipped rather than the proposal ID (`git log --oneline` shows the house
style). That commit is the revert path; do not leave `.bak` copies behind.

Then, back in the main clone: `git merge --no-ff prop-<Pn>` into `main` — never
rebase, so what merges is exactly what the suite ran green. Resolve a real
conflict as a stop-and-report, not a silent pick. Then
`git worktree remove .worktrees/prop-<Pn>` and delete the branch;
teardown is this session's job, not a chore left for the human.

**Then push `main`.** Not housekeeping — a worktree is cut from `origin/HEAD`
whenever an agent harness cuts it, not from local `HEAD`, so an unpushed commit
here is a commit the next `prop` or `fix` run will be handed a base without.
Skip it when the repo has no remote; otherwise `git push origin main` is the
last act of the verb.

## Deliver

- what changed, one line per file
- the `SKILL.md` line delta, and the reason for each line added
- test counts from `scripts/tick-test.sh`
- any new machine contract you introduced
- anything in the **Fix** section you could not implement as written — flag it,
  do not improvise
