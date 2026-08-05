# Canonical config schema

Config is read-only to the loom (the human sets it; it is never build
state). **Do not reinvent key names per repo** — a bootstrap that renames keys
makes two repos read differently for no gain. The keys below are fixed; only
the *values* are repo-specific.

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
   detected stack), `runner` (`scripts/gate.sh`), and the whole
   `.claude/settings.json` permission surface. `tick.sh install-settings`
   writes that surface; it is idempotent and refuses to overwrite a differing
   hand-edited file without `--force`.
3. **Repo — `.loom.yml`, optional.** Only facts no detector can infer.
   Its absence is a valid, complete configuration.

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
max_lanes: 4                    # 1-6; each lane is a full worktree (+ stack where the repo has one)
rejection_cap: 2                # gate-review rejections before a ticket is blocked
crash_cap: 2                    # implementer crashes before blocked (crashes are not rejections)
heartbeat_stale_minutes: 30     # PID alive but log silent this long = wedged (never a wall-clock ticket timeout)
permission_mode: dontAsk        # dontAsk | auto — mode for every spawned wave/lane session.
                                # dontAsk: deterministic (allowlist or immediate denial).
                                # auto: classifier judges the long tail; denials still
                                # return to the model. Both honor allow/deny rules.
                                # (build-1 2026-08-02 paid three dontAsk failures in one
                                # morning; that machine's global config selects auto.)
usage_limit: pause_and_resume   # pause_and_resume | stop_and_wait | downshift_model
                                # pause_and_resume: pause until the limit's own reset time, then
                                #   carry on — the reset epoch is read from the session's
                                #   rate_limit_event, never parsed out of prose
                                # stop_and_wait:    pause and stay paused; `tick.sh resume` clears it
                                # downshift_model:  pass --fallback-model to waves and lanes
fallback_model: sonnet          # only read under downshift_model; an alias (sonnet|opus|haiku) or full id
base: develop                   # integration base; the merge queue rebases onto origin/<base>
                                # NOTE: there is deliberately no tick_interval key — the
                                # heartbeat is a fixed 900s backstop (tick.sh cmd_install).
                                # Lane self-triggers, not the timer, set the loop's pace.

wave_model: ""                  # model for scheduling waves (alias like sonnet|opus|haiku
                                # or a full id). EMPTY INHERITS THE HUMAN'S SAVED
                                # INTERACTIVE DEFAULT — set these, or an interactive
                                # /model switch silently reprices every worker
                                # (2026-08-02: a fable default ran all lanes top-tier).
lane_model: ""                  # model for impl/gate/merge/probe lanes, same rules
rework_model: ""                # P31: model for an IMPLEMENTATION lane on round 2+
                                # (a round that follows a rejection). Empty = same as
                                # lane_model. Late rounds are rare and self-select for
                                # hardness; gates keep lane_model either way. A ticket
                                # `model::<tier>` label outranks this.
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
  push: [build_complete, build_halted, build_stalled, ticket_blocked, lane_stale, wave_stale, workspace_untrusted]
                                # KEEP THIS ON ONE LINE — the reader takes the first `push:` line
                                # and stops, so a wrapped list silently drops its tail
                                # lane_stale/wave_stale: a session alive but making no real
                                # progress past heartbeat_stale_minutes (retry chatter excluded)
                                # workspace_untrusted: the repo root has no accepted trust dialog,
                                # so every lane ignores .claude/settings.json (P30). Deduped like
                                # the quiet states — one push per state change, not one per tick.
                                # + ticket_done | ticket_review | mr_merged | usage_pause | usage_resume

gates:                          # tier keys are FIXED: docs | logic | api | ui (assigned per ticket at gen)
  docs:  ["<lint cmd>"]         # VALUES are the repo's literal, fastest-first, fail-fast shell commands —
  logic: ["<lint>", "<unit>"]   #   NOT abstract tokens. A token like `unit` needs a resolver that does not
  api:   ["<lint>", "<unit>", "<integration>"]   #   exist; a literal command is self-contained and runs as-is.
  ui:    ["<lint>", "<unit>", "<integration>", "<e2e>"]
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
