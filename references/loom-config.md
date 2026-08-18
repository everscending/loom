# Canonical config schema

Config is read-only to the loom (the human sets it; it is never build
state). **Do not reinvent key names per repo** — a bootstrap that renames keys
makes two repos read differently for no gain. The keys below are fixed; only
the *values* are repo-specific.

Legacy `wave_model`, `lane_model`, `rework_model`, `fallback_model`,
`permission_mode`, and `usage_limit: downshift_model` fail with the exact
replacement. Loom does not guess whether a native model name means `medium` or
`high`; migrate ticket labels and config explicitly. Provider choice is not a
config key: it is the active Build issue's single `provider::<id>` label.

## Three layers (P22)

Every key resolves as **repo → derived → global → built-in default**, and
`tick.sh resolve-config` prints the merged document with each scalar's source,
so the effective config is one command away rather than something to reason
about.

1. **Global — `~/.loom/config.yml`** (override with `LOOM_GLOBAL_CONFIG`).
   Machine- and person-level preference, identical across every repo:
   `max_lanes`, `crash_cap`, `rejection_cap`, `heartbeat_stale_minutes`,
   `usage_limit`, the ntfy block. Written once, ever.
2. **Derived — no file.** Anything readable off the repo: `base`
   (`origin/develop` if it exists, else `main`), the `gates` pack (from the
   detected stack), `runner` (`scripts/gate.sh`), `tracker` (read off
   `docs/agents/issue-tracker.md` — see below), and the provider-neutral
   guardrail surface. `agent.sh sync-guardrails --provider <id>` renders the
   selected adapter's owned repo artifact and preserves unrelated settings.
3. **Repo — `.loom.yml`, optional.** Only facts no detector can infer.
   Its absence is a valid, complete configuration.

## The tracker is declared, not configured (P86)

`tracker` has **no `.loom.yml` key, deliberately**. Which tracker a repo uses
is already declared in `docs/agents/issue-tracker.md` — the file
`/setup-matt-pocock-skills` writes, and the one Loom scripts and all provider
jobs read directly. A second copy of the answer here would not be a config key;
it would be a way for `tick.sh` to read one board while the lanes it spawns
write to another, with nothing in the design able to notice.

So loom reads that file's `# Issue tracker: <Name>` heading and **halts**
without it — in `bootstrap.sh` before any write, in `cmd_tick` before any wave
is paid for, in `cmd_snapshot` (the read every other read verb funnels
through), and at `lane.sh`'s verb dispatch. The declaration must also be
**tracked by git**: worktrees live under the ignored `.worktrees/` directory
and each is a checkout, so an untracked file in the main clone is visible to
the human and absent from every lane.

A tracker loom has no driver for halts too, by name. Resolving the declaration
and then ignoring it is the failure the declaration exists to prevent.
`tick.sh resolve-config` reports the resolved name and never halts — it is how
the halt gets diagnosed.

Drivers today: **gitlab** and **linear**.

## The forge is derived first, declared as a fallback (P87)

A board holds tickets; a **forge** holds branches and merge requests. GitLab is
both, which is why loom never had to tell them apart. Linear is a board and
nothing else, so a Linear repo keeps its code somewhere else and loom resolves
two backends.

`forge` is guessed the same way `tracker` is derived, and for free: a tracker
that is itself a code host is its own forge, and otherwise `origin` says where
the code lives (`github.com` → github, a GitLab host recognisable by a
`gitlab` substring in its domain → gitlab). That covers every GitLab repo, on
any remote host, without a human writing anything down.

**When the guess fails, `forge:` is a real `.loom.yml` key** — the one
exception to "derived, never declared" this file used to state flatly, paid
for by a self-hosted GitLab whose own domain carries no `gitlab` substring
(`labs.gauntletai.com`): nothing on the repo answers the question, so every
read-only verb refused it outright with no way to resolve short of renaming
the remote. A human confirms which forge it actually is — once — and the
answer is recorded:

```yaml
forge: gitlab   # or: github
```

Checked **before** the guess on every later resolution, not after: the guess
would fail identically next time, so without checking the recorded answer
first, a human would be asked again on every run. `tick.sh resolve-config`
reports which path won at `.scalars.forge.source` — `config` for a recorded
answer, `derived` for a successful guess, empty when neither resolved.

Recording it is a human's decision, never a lane's or a wave's: nothing
headless may write `.loom.yml`'s `forge:` key on its own guess, only report
that the guess failed. A board that is not a code host, on a remote loom
cannot place AND with no `forge:` key recorded, is the fourth halt — in
`cmd_tick`, in `cmd_snapshot` and at `lane.sh`'s dispatch — and its message
names the fix.

One thing the forge owns that looks like the board's: **the ticket marker**.
GitLab answers "which merge request closes issue 41" natively because it parses
`Closes #41`. GitHub does the same for *GitHub* issues, which with a Linear
board belong to somebody else and would be closed on merge — so on that pairing
loom writes a `Loom-Ticket: 41` trailer instead and looks for that. The forge
decides both halves; `lane.sh` asks it rather than composing a link itself.

Linear needs one more thing from the declaration file: a `Team: <KEY>` line,
because Linear issues belong to a team and no git remote names one. That is a
second *line* in the one file, not a second file, so the single-source rule
above still holds.

## `secrets:` — the credential a CLI-driven tracker never needed (P88)

`glab` and `gh` keep their own tokens, so loom never saw one. Linear has no CLI,
and the variable it wants has to reach the launchd agent — every tracker call in
a build descends from that one process, and environment only travels downward.
The plist carries a fixed four-key dict, which left `launchctl setenv`: it puts
the secret in every process launchd starts for you, no reboot survives it, and
what follows a reboot is a board that reads `unknown` and a wave silently
skipped.

So a `secrets:` map lives in the config files loom already reads:

```yaml
secrets:
  LINEAR_API_KEY: lin_api_…
```

- **In the global config** (`~/.loom/config.yml`) or **in the repo's own state
  config** (`$LOOM_HOME/config.yml`). The second is read first, so it wins —
  which is how two repos on one machine reach two different workspaces.
- **Never in `.loom.yml`.** That file is committed. A `secrets:` block there is
  refused by name, everywhere, and the refusal tells you to rotate the key.
- **The real environment wins over both.** A variable already set is left
  alone, so a one-off override works and CI is untouched.
- The value is exported once, early, before any tracker call, and never becomes
  a command argument. `resolve-config` reports `credential: {name, present,
  source}` — presence and origin only, because its output is pasted into every
  wave prompt.
- `/loom start` **refuses to arm** a build whose tracker needs a credential
  nothing supplies. Arming one is worse than refusing: the refusal is visible,
  and the stall that would follow is not.
- `bootstrap` seeds the global config at mode 600 and warns when it finds a
  `secrets:` block in a file others can read.

A repo `gates:` block overrides the derived pack wholesale. The one extra repo
key is `worktree_cmd:` — a non-git worktree helper such as `openemr-cmd`. It is
declared, never probed from `PATH`: a machine-wide binary must not leak an
allow rule into every unrelated repo.

**The allowlist is generated, not validated.** It is built from the same
commands the gates and probes will run, so it cannot drift from them — which
dissolves P4 rather than detecting it. It includes `cd` (a lane starts in
`$REPO_ROOT` and must reach its own worktree), `curl` and `sleep` (live
probes), and one rule per gate command *including any leading `VAR=VALUE`*,
because `CRUCIBLE_LIVE=1 uv run pytest` does not match `Bash(uv *)`.

## Repo-layer schema

```yaml
forge: gitlab                   # gitlab | github — ONLY when the derivation (tracker-as-forge,
                                 # then a github.com/gitlab substring in origin) fails. A human
                                 # writes this after confirming; loom never writes it itself.
max_lanes: 4                    # 1-6; each lane is a full worktree (+ stack where the repo has one)
rejection_cap: 2                # gate-review rejections before a ticket is blocked
crash_cap: 2                    # implementer crashes before blocked (crashes are not rejections)
heartbeat_stale_minutes: 30     # PID alive but log silent this long = wedged (never a wall-clock ticket timeout)
usage_limit: pause_and_resume   # pause_and_resume | stop_and_wait | downshift_tier
                                # pause_and_resume: pause until the limit's own reset time, then
                                #   carry on — the reset epoch is read from the canonical
                                #   limit event, never parsed out of prose
                                # stop_and_wait:    pause and stay paused; `tick.sh resume` clears it
                                # downshift_tier: high retries once at medium; a medium limit pauses
min_wave_gap_minutes: 10        # floor between wave STARTS, measured from the last
                                # `wave_start` event (not from when the wave ended, and
                                # not from a second state file that could drift). This is
                                # the one knob that paces spending: the 60s heartbeat only
                                # starts a wave once the gap has passed. 0 disables it;
                                # a non-numeric value falls back to 10.
                                # Only gates the TIMER (`tick --auto`). A lane's own
                                # finish-trigger (`--from-lane`) and a hand-run `tick` are
                                # not gated — a finishing lane must be able to start the
                                # next one immediately.
base: develop                   # integration base; the merge queue merges origin/<base>
                                # NOTE: there is deliberately no tick_interval key — the
                                # heartbeat is a fixed 60s (tick.sh HEARTBEAT_INTERVAL). One
                                # agent does both jobs: it watches on every firing, and starts
                                # a wave only once min_wave_gap_minutes has passed. That gap,
                                # not the timer, paces spending — so the fast tick costs
                                # nothing. Lane self-triggers set the loop's real pace.

wave_tier: medium               # Loom tier; adapter resolves its native model profile
lane_tier: medium               # default implementation and every gate/merge/probe tier
rework_tier: high               # implementation tier after a rejection; a ticket
                                # model::medium|high label outranks it
provider_profiles:              # OPTIONAL customization; never selects the provider
  claude:
    medium: {model: sonnet}
    high: {model: opus}
  codex:
    medium: {model: gpt-5.6-terra, reasoning_effort: medium}
    high: {model: gpt-5.6-sol, reasoning_effort: high}
stall_action: resume            # resume | notify_only — what a tick does when the
                                # quiescence check finds work ready but nothing
                                # running. resume: the wave is the recovery (the
                                # unattended default). notify_only: ping the human
                                # and wait — for builds run under a diagnose-first
                                # protocol. Both notify; halted (all blocked) and
                                # complete are always notify-only by nature.

ntfy:
  topic: ""                     # ACCESS-PROTECTED topic before enabling pushes (public topic = injection)
                                # No topic at all → local macOS banner via osascript instead
  push: [build_complete, build_halted, build_stalled, ticket_blocked, lane_stale, wave_stale, workspace_untrusted, build_unarmed]
                                # KEEP THIS ON ONE LINE — the reader takes the first `push:` line
                                # and stops, so a wrapped list silently drops its tail
                                # lane_stale/wave_stale: a session alive but making no real
                                # progress past heartbeat_stale_minutes (retry chatter excluded)
                                # workspace_untrusted: the repo root has no accepted trust dialog,
                                # so every lane ignores .claude/settings.json (P30). Deduped like
                                # the quiet states — one push per state change, not one per tick.
                                # build_unarmed: a tick found no heartbeat agent AND launchd refused
                                # to load one, so a fizzled wave would stall the build silently.
                                # Deduped the same way — one push, not one stderr line per tick.
                                # + ticket_done | ticket_review | mr_merged | usage_pause | usage_resume

gates:                          # tier keys are FIXED: docs | logic | api | ui (assigned per ticket at gen)
  docs:  ["<lint cmd>"]         # VALUES are the repo's literal, fastest-first, fail-fast shell commands —
  logic: ["<lint>", "<unit>"]   #   NOT abstract tokens. A token like `unit` needs a resolver that does not
  api:   ["<lint>", "<unit>", "<integration>"]   #   exist; a literal command is self-contained and runs as-is.
  ui:    ["<lint>", "<unit>", "<integration>", "<e2e>"]

trees:                          # OPTIONAL. Which part of the tree each tier OWNS — the scope
  docs:  ["docs/**"]            #   half of the gate, where `gates:` is the behaviour half.
  logic: ["packages/core/**"]   #   Paths are repo-specific, so nothing is ever derived.
  api:   ["apps/api/**"]
  ui:    ["apps/console/**"]
```

Example `gates` values for a Python/uv repo (crucible):

```yaml
gates:
  docs:  ["uv run ruff check ."]
  logic: ["uv run ruff check .", "uv run pytest -q"]
  api:   ["uv run ruff check .", "uv run pytest -q"]
  ui:    ["uv run ruff check .", "uv run pytest -q"]
```

The only thing that reads `gates` is the repo's own gate runner (e.g.
`scripts/gate.sh`) and the wave session — so the file and that runner must
agree on the key. `tick.sh` reads no gate key. **The gate runner lives in
the repo, not the skill**: CI and bare-clone contributors run it without
the skill installed, and its commands are repo-specific — it is the repo's
definition of done. `tick.sh` (loom mechanism) is the opposite:
skill-resident, run only by the loom driver. Values are literal commands
by design (decided 2026-07-21, crucible): the abstract-token form the first
openemr config used (`[unit, phpstan]`) needs a token→command map that was
never built, so literal commands are canonical.

## `trees` — the tier's file surface

`gates` says what a tier **runs**; `trees` says where its tickets are allowed
to **write**. A `gate` lane's pregate diffs the branch against the base and
refuses it — rc 7, no review session — when a changed path falls outside every
glob its tier declares. Without it the gate only ever asks what a diff *does*,
never what it *touches*: triggers-api build-2 passed a `ui` ticket that met all
nine of its acceptance criteria and also shipped ~105 lines of a neighbouring
ticket's API routes, and the collision surfaced in a merge lane, which is the
one place the skill forbids fixing anything.

```yaml
trees:
  docs:  ["docs/**"]
  api:   ["apps/api/**"]
  ui:    ["apps/console/**", "packages/ui/**"]
```

Both list spellings are read — the flow form above and the block form
(`ui:` on its own line, then `- "apps/console/**"` items). Globs are matched as
shell `case` patterns, where `*` crosses `/`, so `apps/api/**` covers the whole
subtree; a bare directory (`apps/api`) matches that directory and everything
under it.

**Absence is a valid, complete configuration**, wholly and per tier. A repo
with no `trees` block gets no mechanical scope check at all; a repo declaring
`api` and `ui` but not `docs` gets none for `docs`. Nothing is derived from the
folder layout — a guessed tree would reject correct branches in every repo that
never opted in, and a false rc 7 costs more than the round it saves. The check
skips on every other unknown too: no base ref, an empty diff, an unreadable
ticket. Its escape valve is the ticket itself — a changed path the **ticket
body names** is a path the ticket was scoped to touch, whatever tree it sits
in, so cross-tree work stays possible once it is written down. Unlike `gates`,
`tick.sh` reads this key itself (`_repo_trees_tsv`), from the branch's own
`.loom.yml` where the worktree has one: the layout the diff is about is the
branch's, not the caller's.
