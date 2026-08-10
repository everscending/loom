# Setup, bootstrap, and the skill/repo boundary

Read when standing up a new repo or changing this skill's own machinery. A
wave never needs any of it — bootstrap runs itself.

## Config

All tunables in `.loom.yml` at the repo root (lanes, caps, staleness
window, usage-limit policy, ntfy, gate tiers — enum options documented
in-file). Canonical key names: [loom-config.md](loom-config.md).
Only values are repo-specific; renaming keys per repo is a bug.

There is deliberately **no tick-interval key**: the heartbeat is a fixed
backstop and lane self-triggers set the pace. The loom never writes
`.loom.yml`.

## Before anything: declare the tracker

A repo must say which issue tracker it uses, in
`docs/agents/issue-tracker.md`, and that file must be committed. It is
`/setup-matt-pocock-skills`' output — run that verb once per repo — and loom
reads its `# Issue tracker: <Name>` heading rather than keeping an answer of
its own. Without it every loom verb refuses: no bootstrap, no wave, no
snapshot, no lane. Details and the reasoning: [loom-config.md](loom-config.md).

Loom drives **GitLab** and **Linear**. It also needs somewhere for a lane's
branch and merge request to go, and that is a second thing — a *forge* —
which it derives rather than asks for: a tracker that is itself a code host
is its own forge, and otherwise the repo's `origin` remote decides
(`github.com` or a GitLab host).

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

2. **`LINEAR_API_KEY`** in the environment the loop runs in. A launchd agent
   does not read your shell profile, so exporting it in `.zshrc` is not
   enough — put it where the agent will see it.

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
write `.claude/settings.json`, create the missing ticket-state labels — then
proceeds with the wave. A sentinel in the repo's state dir makes every later
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
