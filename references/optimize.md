# `optimize` — compact SKILL.md without changing what it makes an agent do

Human-run, like `qa` and `retro`. Never invoked by a wave. It rewrites one
file: this skill's `SKILL.md`.

Why the verb exists: SKILL.md is loaded in full by every session that invokes
the skill, including every headless wave. Words in it are paid for on every
tick. But it is also the only place a wave learns how to drive the scripts, so
compaction is a surgical task with a large silent-failure surface — hence a
written procedure rather than "make it shorter".

## The standard

Applied as a **judgment while reading**, not something you execute: *would a
fresh headless session, with no human available to ask, still know exactly
what to do here?* Keep what answers "what do I do". Cut what merely explains
why. If a cut makes that session guess, don't make it.

Nothing in this task requires running the skill, starting a build, or running
the test suite. SKILL.md has no executable test — the only true end-to-end
check is a real build, which costs hours and real money. Do not attempt one.

## Before touching anything

The skill directory **is** a git repository, and its last commit is your revert
path: `git checkout -- SKILL.md` undoes the whole pass. So start from a clean
tree — `git status --short` empty — and report the SHA you started from.

Never make a `.bak` copy. A stale one is a second SKILL.md that nobody knows is
stale, and it is the file a later reader greps by accident.

## Step 1 — structural moves, before any rewording

The largest wins are not wording. They are noticing that two different readers
share one file.

A `tick` wave needs: the constitution, tracker vocabulary, Phase 6, and the
failure policy. A human running `plan` / `epics` / `tickets` / `build` needs
the phase sections — once, interactively, never in a wave.

- **Anything a wave never reads belongs in `references/`**, with a one-line
  pointer left behind. Ask of each section: does a headless `tick` session act
  on this, or does only a human read it, once, interactively? The second kind
  is pure per-tick overhead. This is the progressive-disclosure pattern already
  used by `qa.md`, `retro.md`, `ticket-template.md`, `phases-1-5.md`,
  `setup.md` and this file — extend it, don't reinvent it.
- Keep each `references/` file to **one subject**. A move that would force two
  unrelated topics into one file needs a new file instead, not a compromise.
- Collapse any rule stated in more than one place to a single statement at the
  point of use, cross-referenced elsewhere.
- Cut anything that *teaches technique* belonging to `/grilling`, `/lavish`,
  `/to-tickets`, `/implement` or `/code-review`. Constitution rule 2 forbids it
  being here at all, so this is compliance, not just economy.

## Step 2 — never alter these

They are machine contracts. Quote them byte-for-byte.

**Literal strings** — whichever of these the file currently contains:

- `Closes #<ticket-iid>` (the MR-to-ticket link the scheduler reads)
- `<!-- orch-verdict PASS|FAIL <head-sha> class=<slug> -->`
- lane ids: `impl-<n>`, `gate-<n>[-r<round>]`, `merge-<n>`, `probe-<epic-slug>`
- labels: `ready-for-agent`, `in-progress`, `review`, `merge-queue`,
  `blocked`, `fix`, `build-N`, `model::<tier>`, `tier::<tier>`
- jq paths: `.scalars.<key>.value`, `.model.effective`, `.gate.eligible`,
  `.rejections.same_class_tail`, `.summary.stranded`,
  `.summary.impl_slots_free`, `.summary.merge_in_flight`, and the plan
  document's own `.actions[]`, `.residue[]`, `.deferred[]`, `.reason`

**Every script invocation and every flag.** If a flag is named in the current
file it is named in the rewrite, attached to the same verb: `--pregate`,
`--brief`, `--merge-lock`, `--cwd`, `--no-tick`, `--model`,
`--permission-mode`, `--class`, `--file`, `--follow`, `--to-review`,
`--build`, `--vs`, `--no-panes`, `--force`.

**Section headings** (`## …`). `tick.sh` comments point at them by name — for
example *see SKILL.md "Headless permissions"*. Renaming one orphans the
pointer.

**The frontmatter**, especially `description`: it is what makes the skill
discoverable and is not part of the compaction budget.

**This verb's own row and pointer.** You are editing the file that describes
you. Do not remove the `optimize` verb while optimizing.

## Step 3 — the silent-failure set

No script parses SKILL.md — every mention of it under `scripts/` is a comment,
so you cannot break a script mechanically. What you can break is the wave's
ability to compose a correct command.

Some breakage is loud and therefore safe: `spawn-lane` validates lane ids and
pregate tiers and refuses bad ones; inline arguments over 1000 characters are
refused. A wave dies visibly at the spawn.

These fail **silently** — nothing errors, the build just quietly behaves
worse. Each looks optional and is not:

- `Closes #<ticket-iid>` in the MR description — without it the MR is
  invisible to the scheduler. (Known gap as of the first optimize run: this
  rule lives in the *repo's* `CLAUDE.md`, not in `SKILL.md`. Do not add it
  during an optimize pass — authoring is not compaction — but report it again
  if it is still missing.)
- the `orch-verdict` trailer — without it a HEAD is re-gated forever.
- clearing the assignee on unblock — the ticket never rejoins the ready set,
  and the build can report itself complete with it still open.
- a probe-filed fix ticket needing **all four** of: `build-N`, `fix`, a risk
  tier, and the defective epic's milestone.
- `--pregate` on a gate spawn — the cheap mechanical check silently stops
  running first, and full review sessions get spent on red branches.
- `--merge-lock` on a merge spawn — two merges run at once.

## Step 4 — definitional drift

Several `tick.sh` comments mirror this file by name: the ticket state machine
("as SKILL.md defines it"), epic completeness ("no open member still carries
it"), the scheduler's universe ("open issues labeled `build-N`"), the
blocking-edge rule, and what `crash_cap` versus `rejection_cap` each count.

Rewording those definitions into something *nearly* the same breaks nothing
today and leaves the code and the doc slowly disagreeing. Keep them
word-stable.

## Step 5 — provenance

The constitution says every rule is paid for by a real failure, cited. Those
citations are what let a later reader — and the `qa` verb — tell an earned
rule from an invented one. Delete them wholesale and every remaining rule
looks equally authoritative, so nothing can ever be pruned again.

So: **compress, never delete.** Reduce each citation to a 2–5 word tag naming
the failure, dropping dates, ticket numbers and build numbers.

    before: *(Paid for: build-1 2026-08-02 — gate-1-r2's review subagent
             stalled 600s, the session exited 0, and #1 sat in review with
             no lane.)*
    after:  *(paid: verdictless gate exit)*

## Step 6 — what to keep

- **Every "never" and negative constraint.** Highest value per token in the
  file; they are what stop failures repeating.
- **Reasoning that exists to stop a plausible-looking wrong change** — why
  rebase can never work here, why staleness counts progress and not bytes.
  A bare imperative there invites the next agent to undo it. Compress the
  reasoning that merely justifies a decision already made; keep the
  reasoning that defends one.

Prefer tables and lists over paragraphs. Prefer one imperative sentence over
a paragraph arguing for it.

## Step 7 — verify mechanically

This part *is* executable, and it takes two seconds. Run both lists against the
committed file and the rewrite, and diff:

    inv() { grep -oE '(tick|lane|bootstrap|watch-panes)\.sh [a-z-]+' "$1" | sort -u; }
    flg() { grep -oE '\-\-[a-z-]+' "$1" | sort -u; }
    git show HEAD:SKILL.md > /tmp/skill-before.md
    diff <(inv /tmp/skill-before.md) <(inv SKILL.md)
    diff <(flg /tmp/skill-before.md) <(flg SKILL.md)

Any invocation or flag present before and absent after is a defect unless you
can name the sentence that made it redundant. This catches the whole
silent-damage class, which is why it is not optional.

## Deliver

- the rewritten `SKILL.md`, plus any new `references/` files
- the SHA you started from
- before/after word counts, overall and per section
- the two grep diffs from step 7
- anything you were unsure whether to cut — **flag it, do not guess**

Do not run `/loom qa` yourself. The human runs it separately as an
independent read of the result.
