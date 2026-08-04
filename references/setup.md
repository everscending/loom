# Setup, bootstrap, and the skill/repo boundary

Read when standing up a new repo or changing this skill's own machinery. A
wave never needs any of it — bootstrap runs itself.

## Config

All tunables in `.orchestrator.yml` at the repo root (lanes, caps, staleness
window, usage-limit policy, ntfy, gate tiers — enum options documented
in-file). Canonical key names: [orchestrator-config.md](orchestrator-config.md).
Only values are repo-specific; renaming keys per repo is a bug.

There is deliberately **no tick-interval key**: the heartbeat is a fixed
backstop and lane self-triggers set the pace. The orchestrator never writes
`.orchestrator.yml`.

## New repo bootstrap

Mostly derived, not authored, and it runs itself. The **first `tick` in a
repo** invokes `scripts/bootstrap.sh all` — seed `~/.orchestrator/config.yml`,
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
bare-clone contributors run it without the skill), and any `.orchestrator.yml`
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

`tick.sh` (orchestration mechanism) lives in the skill: only the
orchestrator-driver runs it, never CI or a bare clone. The gate runner lives in
the *repo*: it is the repo's own definition of done — CI, contributors, and the
wave all run it without the skill installed, and its commands are
repo-specific. One source of truth for the tier→command map
(`.orchestrator.yml`), one runner both CI and the wave invoke.
