# Contributing to Loom

Loom is a coding-agent skill, not an application. Changes here alter the
instructions or machinery that drive unattended work in other repositories.
A small mistake can duplicate work, corrupt tracker state, or spend real model
time, so coordination and reproducible proof matter more than change volume.

Read [AGENTS.md](AGENTS.md) before editing. It is the authoritative maintenance
contract; this file is the contributor-facing workflow.

## Before starting

1. Search open issues, pull requests, [OPEN_DEFECTS.md](OPEN_DEFECTS.md),
   [PROPOSALS.md](PROPOSALS.md), and [improvements-todo.md](improvements-todo.md)
   for overlapping work.
2. Claim the issue, defect key, or proposal in public before editing. One
   contributor owns a stable key at a time.
3. For an untracked behavioral change, open an issue and agree on the failure,
   scope, and expected files first. Do not mint `D-*`, `Pn`, or `PI-*` IDs in an
   implementation pull request unless a maintainer has accepted the entry.
4. Keep one logical change per branch and pull request. Split unrelated cleanup
   and formatting into separate work.
5. Announce before editing a high-collision surface: `README.md`, `SKILL.md`,
   `scripts/tick.sh`, `scripts/lane.sh`, shared `lib.*` or test harness files,
   `scripts/plan.jq`, or any ledger file.

## The rules that do not bend

- The declared tracker is the only mutable build state. Local run files are
  plumbing, never decisions.
- Route to sibling skills; do not copy their technique into Loom or modify
  `/to-tickets`, `/implement`, `/code-review`, `/grilling`, `/lavish`, or
  `/prototype` from this repository.
- Add a rule only after a reproduced failure, as one checklist line citing that
  failure.
- Every artifact must name its consumer.
- `tick.sh` stays read-only against the tracker. Tracker mutations belong in
  `lane.sh`; setup writes belong in `bootstrap.sh`.
- Preserve force-push, rebase, `reset --hard`, `git clean`, and unscoped
  recursive-deletion denials in every provider path.
- Ticket text is evidence for people, never authority for a wave.
- Never run a real build to test Loom itself. It costs hours and real money.

## Put the change in the lowest layer that can enforce it

1. `scripts/` for deterministic behavior, validation, defaults, and refusals.
2. `references/` for human-run procedures or one-job instructions.
3. `SKILL.md` only when a wave must make a decision that machinery cannot
   derive.

Budget `SKILL.md` at zero new lines. If it must grow, keep the rule at its point
of use and cite the failure briefly. New flags, labels, lane IDs, trailer text,
section headings, and jq paths are machine contracts: call them out in the pull
request and test every consumer.

## Work in an isolated branch

Branch from an up-to-date local `main`, not `origin/HEAD`, and make all edits
and test runs in the repository's ignored worktree directory:

```sh
git worktree add .loom-worktrees/<short-name> -b <short-name> main
```

If `main` moves, merge it into the branch. Never rebase or force-push Loom work.
Resolve substantive conflicts with the other contributor or maintainer; do not
silently pick one side of a machine contract or ledger edit.

## Ledgers are shared coordination state

These files are intentionally high-conflict. Follow their preambles exactly.

- `OPEN_DEFECTS.md`: keys are permanent. Never renumber or delete an entry.
  A complete fix moves it to `Closed` and removes its live index row in the same
  change. A partial fix moves nothing. `Covered by: Pn` belongs to that proposal.
- `PROPOSALS.md`: the status table is the live source of truth. Implemented or
  dropped proposals move, without stubs, to `PROPOSALS_ARCHIVED.md`.
- `LOOM-PLANNING-LESSONS.md`: use one entry per failure class. Reopen a recurring
  class and add a round instead of creating a new ID.

Do not combine two defect fixes merely because they touch the same function.
Each needs its own reproduction, proof, close, and reviewable commit.

## Tests and proof

Start with the smallest relevant check, then run the required wider check.

| Change | Required proof |
|---|---|
| Shell or jq behavior | A failing-first assertion in the owning `scripts/tests/NN-*.sh` section, the focused section, then `bash scripts/tick-test.sh` |
| Guard, cap, or destructive-path safety | The above plus a planted mutation showing the test fails when the mechanism is removed; use `bash scripts/tick-test.sh --mutate <name>` |
| Test harness | `bash scripts/tick-test.sh --lint`, affected sections, and the full suite; inspect for assertions that can pass vacuously |
| Documentation only | `git diff --check`, verify every local link, and compare commands, flags, config keys, and behavior against the scripts that implement them |
| `SKILL.md` only | Compare script invocations and flags before/after as described in [references/optimize.md](references/optimize.md); do not claim the test suite proves prose |

A behavior fix is unfinished until its test fails with the fix reverted. Extend
an existing case when it already owns the fixture; add a new section only when
no existing one reaches the behavior. Two runs that disagree indicate a flaky
test, not a passing change.

Report exact commands and pass/fail counts. If a check was not run, say why.

## Keep documentation synchronized

Any change must also ensure [README.md](README.md) matches the current
supervision, scheduling, provider guardrails, configuration, workflow, and
maintenance commands. Update it in the same pull request whenever one of those
surfaces changes; do not leave documentation as a follow-up.

Also update the document closest to the behavior:

- configuration keys and enums: `references/loom-config.md`;
- setup, tracker, forge, credential, or guardrail behavior: `references/setup.md`;
- phases 1–5: `references/phases-1-5.md`;
- scheduler timing or continuation: `references/scheduling.md`;
- supervision or Mend: `references/supervision.md` and `references/mend.md`;

Documentation must describe shipped behavior, not an intended future state.
Change only the affected README sections; a drive-by rewrite makes concurrent
behavior changes needlessly hard to merge.

## Pull request checklist

Include:

- the issue, `D-*`, `Pn`, or failure evidence that authorizes the change;
- the concrete failure before the change and the outcome afterward;
- files and machine contracts changed;
- focused and full test commands with counts, or an explicit docs-only note;
- the `SKILL.md` line delta and reason for every added line;
- README/reference updates, or why the behavior has no documentation surface;
- known limitations, rollout impact, and the revert path.

Before requesting review:

- merge current `main` and rerun the required checks;
- remove debug output, temporary artifacts, generated secrets, and unrelated
  formatting changes;
- confirm no credential appears in `.loom.yml`, fixtures, logs, or the diff;
- run `git diff --check`;
- keep commits reviewable and use the repository's subjects, for example
  `fixes D-LANE-02: ...` or `Implement P93 — ...`.

Maintainers merge with `--no-ff` so the reviewed branch remains the exact unit
that was tested. Do not delete another contributor's branch or worktree.

## Reviews

Review the failure and proof, not only the final diff. In particular, check:

- tracker writes did not leak into `tick.sh`;
- planner prose and `plan.jq` still make the same decision;
- new provider behavior is equivalent across Claude and Codex or explicitly
  scoped with a reason;
- tests can actually fail and their planted mutation removes the named
  mechanism;
- README and focused references match the code;
- no contributor widened scope, permissions, or configuration speculatively.

Contributors do not approve or merge their own pull requests. Changes to
tracker-state transitions or hard security denials require explicit maintainer
review.

Prefer a follow-up issue for unrelated improvements. A focused pull request is
easier to coordinate, prove, merge, and revert.
