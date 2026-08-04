# `qa` — reviewing this skill's own files

Human-run maintenance. **A wave never runs this.** It reviews the skill, not a build; `retro`
reviews a run.

Paid for: on 2026-08-01 four independent readers found **fourteen defects in the scripts and twelve
in `SKILL.md`**, against a suite that was green at 71 tests. Fixing six of the confirmed findings
introduced **five more**. None of it was reachable by running the tests.

## Three rules

**A green suite is not evidence.** It is a claim by `tick-test.sh`, the largest file here and the
one least scrutinised. Three of the worst findings that day were *caused* by the tests. Run the
suite for the signal it does give, then review as if it had told you nothing.

**Confirm before reporting.** A reviewer produces claims. Each one is reproduced against the real
code — read the lines, or run it — or it is dropped. An unverified list spends the reader's
attention on false positives, which is worse than no list.

**Report; do not fix.** Repair is a separate action the human approves. Five of the defects that day
were introduced by the repairs, so the repair step needs supervision at least as much as the review
did.

## Step 1 — the cheap signals

    bash scripts/tick-test.sh              # expect all green; note the count
    tick.sh snapshot | tick.sh graph       # against a real repo, read-only
    tick.sh lane-status
    tick.sh report

The live check is not optional. `graph` reporting the wrong opening width was caught **only** by
running against a real tracker — out-of-build blockers were being dropped, and no fixture in the
suite could have shown it. Anything that reads live tracker state can be wrong in ways fixtures are
structurally unable to reproduce.

If the suite is red, stop and report that. Do not review on top of a broken baseline.

## Step 2 — one reviewer per file

Spawn independent subagents, one per file, in parallel. Each gets the file and its brief below —
**not** this round's other findings, and not the history of why the code looks as it does.
Independence is the whole value; a reviewer told what to expect confirms it.

Herdr panes are a fine way to watch them work, and are not required.

### `scripts/tick.sh` — the machinery

Ordering and fallback, not logic. Four of the five defects introduced on 2026-08-01 were of this
shape. Look for: destructive work (log rotation, clearing `<id>.rc`) placed **above** a guard that
can still refuse; a sort whose tiebreak silently restores the original bug when a field is absent;
validation hardcoded to a value set that `.orchestrator.yml` can extend; a jq pipe that rebinds `.`
so a `//` fallback evaluates against the wrong value — that one shipped twice in one day; any path
that assumes a lane is alive or dead without reading its state; and any window between reserving
something and stamping ownership of it.

### `scripts/tick-test.sh` — the suite

Assume it is lying. Find: assertions that **cannot fail** — `ok` called in both branches, or a
planted-violation partner that passes vacuously on an empty file; fixtures too simple to exercise
the axis being tested, such as a single item where the bug is in *ordering*, or a set that happens
to contain the case that masks the defect; counters read from a file that was created empty, so the
comparison sees `""` and not `0`; and any test whose planted violation removes a different mechanism
from the one the test names.

A planted violation only proves what it plants.

### `scripts/bootstrap.sh` — the write half

It is the only code here that writes. Find: a write that happens **before** the check that would
refuse it — this file once took `REPO_ROOT` from `$PWD` with the git check afterwards, so running it
from `$HOME` would create the human's own `~/.claude/settings.json`; detection by substring where an
exact match is required; a flag accepted and then not forwarded, so `--dry-run` did real work; and
anything that overwrites without `--force` or is not idempotent.

### `SKILL.md` — prose against machinery

The one file loaded into every wave, and the two worst findings that day were places prose and
machinery had drifted apart. Check every command shown actually runs **as written** — verbs and
`--` separators included. Check every field, flag and config key the prose names still exists and
behaves as described. Check every identifier the prose tells a wave to construct survives the format
that parses it: `probe-<epic>` with a real epic title produced `probe-Ledger core`, which
`lane-status`'s space-delimited output parsed as a lane whose state was a pid — never `dead`, so it
counted as live for the rest of the build. And check that a rule stated in one place is not silently
contradicted in another, or doing two unrelated jobs under one key.

### `references/*.md`

Never independently reviewed. Confirm key names match what `resolve-config` actually reads,
documented options match the enum the code accepts, and nothing describes behaviour the scripts no
longer have.

## Step 3 — confirm

For each claim: name the file and line, state the failure as concrete inputs → wrong outcome, and
reproduce it. Drop what cannot be shown. Where a reviewer is right for the wrong reason, keep the
defect and fix the reasoning.

Then sort the survivors: **which of these should the suite have caught?** Each one is a test gap,
and the gap is the more valuable finding. A fix for it is not done until a test fails without it.

## Step 4 — report

To the human: findings most severe first, each with its failure scenario, and the test gaps called
out separately.

Then append a dated review-round section to `PROPOSALS_ARCHIVED.md`, following the 2026-08-01 entry:
what was found, what it says about the tests, and any runtime lesson worth keeping. That section is
the evidence the next round starts from — it is why this brief exists at all.

Anything that turns out to need a change rather than a fix becomes a proposal in `PROPOSALS.md`.

## When this earns nothing

If a round on already-reviewed code returns nothing that survives confirmation, say so plainly. This
verb is worth keeping only while it finds things; kept as ritual it is just cost.
