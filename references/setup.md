# Setup, bootstrap, and the skill/repo boundary

Read when standing up a new repo or changing this skill's own machinery. A
wave never needs any of it — bootstrap runs itself.

## Config

All tunables in `.loom.yml` at the repo root (lanes, caps, staleness
window, usage-limit policy, ntfy, gate tiers — enum options documented
in-file). Canonical key names: [loom-config.md](loom-config.md).
Only values are repo-specific; renaming keys per repo is a bug.

There is deliberately **no tick-interval key**: the heartbeat is a fixed
backstop and lane self-triggers set the pace. Nothing headless — no wave, no
lane, no bootstrap — ever writes `.loom.yml`; the one exception is a human
answering the forge question below through an interactive verb, and even
then it is the human's answer being recorded, never a guess.

## Choosing the permission mode

`permission_mode` (default `dontAsk`) is what every spawned session runs
under; `SKILL.md`'s "Headless permissions" says how a wave reads and passes
it. Which value to set is a config decision, made here.

`dontAsk` is deterministic: allowlist or immediate denial, never a hang.
`auto` sends the long tail to the classifier instead of hard-denying it;
denials still return to the model. Both honor the repo's `permissions.allow`,
and the deny guardrails bind in every mode. `dontAsk`'s brittleness is paid
for three ways *(a compound command denied wholesale and misread as "never
bootstrapped"; `$VAR` defeating prefix match; worktree-frozen allowlists going
stale)* — prefer `auto` where the machine's global config says so, and treat
"auto aborts after repeated classifier blocks" as a claim to re-verify per
Claude Code version, not settled fact.

The repo's allowlist and denylist (hard guardrails: force-push,
`reset --hard`, `rm -rf`) are a bootstrap-epic artifact, committed so every
worktree and CI inherit them. Never spawn a loop session with
`bypassPermissions` (no guardrails — legitimate only inside a real sandbox) or
`acceptEdits` (hangs on bash).

## Before anything: declare the tracker

A repo must say which issue tracker it uses, in
`docs/agents/issue-tracker.md`, and that file must be committed. It is
`/setup-matt-pocock-skills`' output — run that verb once per repo — and loom
reads its `# Issue tracker: <Name>` heading rather than keeping an answer of
its own. Without it every loom verb refuses: no bootstrap, no wave, no
snapshot, no lane. Details and the reasoning: [loom-config.md](loom-config.md).

Loom drives **GitLab** and **Linear**. It also needs somewhere for a lane's
branch and merge request to go, and that is a second thing — a *forge* —
which it guesses first rather than asking: a tracker that is itself a code
host is its own forge, and otherwise the repo's `origin` remote decides
(`github.com` or a `gitlab`-named host). When neither answers it (a
self-hosted GitLab on a domain with no `gitlab` in it, say), the halt names
the fix: confirm which forge it is and record `forge: gitlab` (or `github`)
in `.loom.yml` once — checked before the guess on every later run, so it is
asked at most once. Details: [loom-config.md](loom-config.md).

**Hitting this halt inside any interactive verb** (`plan`, `epics`, `tickets`,
`build`, `start`, a manual `tick`): the guess already ran and failed — do not
re-run it, do not assume a forge from context. Ask the human once which forge
the repo's remote actually is, write their answer as `forge: <name>` in
`.loom.yml`, and only then retry the command that halted. A headless wave
hits the same halt with nobody to ask, so it can only report it — never guess
past it and never write the key itself.

### If you use Linear

Linear is a board and not a code host, so a Linear repo needs three things
rather than one.

1. **The declaration.** `/setup-matt-pocock-skills` templates GitHub, GitLab
   and Local Markdown, and files everything else under "Other" as freeform
   prose. So write the heading yourself, and a `Team:` line beside it —
   Linear issues belong to a team and no git remote names one:

   ```markdown
   # Issue tracker: Linear

   Team: ENG
   ```

   The `Team:` line is optional when your API key can see exactly one team.
   With several and no line, loom halts and lists them rather than picking.

   **Linear's board is its Status field, not its labels** (P90): loom's five
   ticket states — `ready-for-agent`, `in-progress`, `review`, `merge-queue`,
   `blocked` — are written and read as Status, the same field that drives your
   team's own board columns and cycle progress. `bootstrap.sh states` (part of
   `bootstrap.sh all`) creates whichever of the five your team is missing —
   defaults `Todo`, `In Progress`, `In Review`, `Merge Queue`, `Blocked` — as
   new workflow states of type `started`. **This is more invasive than
   creating a label**: a workflow state is a column in every view your team
   has, not a tag. `bootstrap.sh states --dry-run` names each one it would
   add before you commit to it.

   Override any of the five, or the completed state loom closes tickets into,
   with `Status <loom-state>: <Linear name>` lines beside `Team:` — useful if
   your review column is already called something else, or your team will not
   accept new workflow states:

   ```markdown
   # Issue tracker: Linear

   Team: ENG
   Status review: Code Review
   Status closed: Shipped
   ```

   A name that does not exist on the team is a halt naming it, never a guess
   — run `bootstrap.sh states` to create it, or fix the line.

2. **The API key, in a `secrets:` block.** Put it in `~/.loom/config.yml`
   (every repo on this machine) or in this repo's own state directory,
   `$LOOM_HOME/config.yml` (this repo only — which is how two repos point at
   two different Linear workspaces):

   ```yaml
   secrets:
     LINEAR_API_KEY: lin_api_…
   ```

   `chmod 600` it. Loom exports it once, early, before any tracker call, and
   only when the variable is not already set — so a one-off `LINEAR_API_KEY=…`
   in front of a command still wins, and CI that supplies its own is untouched.

   **Never in `.loom.yml`.** That file is committed, so a key in it goes to the
   forge on your next push. Loom refuses by name if it finds one there.

   Exporting in `.zshrc` does not work, and neither does `launchctl setenv`
   for long: the loop runs from a launchd agent, which reads no shell profile,
   and a `setenv` value is gone after a reboot. `/loom start` refuses to arm a
   build whose tracker needs a key nothing supplies — a build that cannot read
   its own board fails as a *silent skipped wave*, not as an error.

3. **`origin` pointing at the code.** That is where the merge requests go.

**And the part that decides whether builds actually work.** Loom's own
tracker calls are perhaps a third of what a build makes. The rest come from
inside lanes: each lane is a `claude -p` session running `/implement`,
`/code-review` and the rest, and those skills do their own tracker work by
reading this same file — not just its heading, but the whole workflow it
describes: how to create an issue, apply a label, open and merge a merge
request. Loom cannot teach them Linear; they are somebody else's skills.

So the rest of `docs/agents/issue-tracker.md` is yours to write, and a thin
"Other" entry produces lanes that improvise. Describe the workflow the way
the GitLab template does — name the states, the labels, the commands, and
say plainly that merge requests live on GitHub (or GitLab) while tickets
live in Linear.

## New repo bootstrap

Mostly derived, not authored, and it runs itself. The **first `tick` in a
repo** invokes `scripts/bootstrap.sh all` — seed `~/.loom/config.yml`,
write `.claude/settings.json`, create the missing ticket-state labels (and,
on Linear, the missing ticket-state Statuses) — then proceeds with the wave.
A sentinel in the repo's state dir makes every later
tick skip it; a *failed* bootstrap writes no sentinel, so the next tick
retries, and it never blocks the wave. It is hooked to `tick`, not `start`,
because `tick` is the verb that always runs. Run it by hand any time:
`bootstrap.sh all` is idempotent.

Underneath, `tick.sh resolve-config` detects the stack and emits the effective
config — `base`, the gate tiers as literal commands, the runner path, and the
whole permission surface — resolving repo → derived → global → default. Run it
*before* writing bootstrap tickets and only ticket what it could not derive.
Because the allowlist is generated from the same commands the gates and probes
run, it cannot drift from them.

**What still needs a repo-bootstrap epic**: tracker labels, the CI pipeline,
the **repo-resident gate runner** (`scripts/gate.sh <tier>`, which reads those
commands and runs them fail-fast — the repo's own definition of done, so CI and
bare-clone contributors run it without the skill), and any `.loom.yml`
line no detector can infer (an env var the gates need, a live target URL, a
non-git `worktree_cmd`). Everything else blocks on that epic. Never copy
another repo's gate suites verbatim — derive them.

## Read half vs. write half

`tick.sh` is **read-only against the tracker** — the wave re-runs it
constantly, so a mutating call there would be unsafe to repeat, and
`tick-test.sh` enforces it by scanning captured argv for mutating verbs. Setup
genuinely must write, so it lives in `scripts/bootstrap.sh` instead of eroding
that guarantee. Nothing in bootstrap ever deletes, and nothing already present
is overwritten without `--force`.

## Skill vs. repo boundary

`tick.sh` (loom mechanism) lives in the skill: only the
loom driver runs it, never CI or a bare clone. The gate runner lives in
the *repo*: it is the repo's own definition of done — CI, contributors, and the
wave all run it without the skill installed, and its commands are
repo-specific. One source of truth for the tier→command map
(`.loom.yml`), one runner both CI and the wave invoke.
