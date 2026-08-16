# Loom Agent-Agnostic Runtime Plan

Last updated: 2026-08-15

## Status legend

- `[x]` Design decision accepted.
- `[~]` Implementation in progress.
- `[ ]` Not started.
- `[!]` Rollout gate: support is incomplete until this is proven.

Current state: the design direction is accepted; implementation has not started.

## Outcome

Make Loom independent of Claude Code without weakening its scheduling,
tracker-state, permission, or failure-policy guarantees. Claude Code and Codex
become provider adapters behind one small agent-runtime interface. A future
provider should require a new adapter and conformance fixtures, not changes
throughout Loom's scheduler.

Provider choice is per build, not global. Starting Loom in one project with
Claude and in another project with Codex must allow both unattended builds to
run concurrently without either provider setting leaking into the other.

Codex support is complete only when a fresh Codex session can reconstruct and
advance the same tracker-backed build, under the same failure policy and hard
denials, without requiring a Claude executable or Claude-specific project
files.

## Constraints that this change must preserve

- [x] The tracker remains the only mutable build state. Provider choice is a
  build decision and therefore belongs on the `Build N` issue.
- [x] Run directories contain plumbing only: locks, PIDs, logs, pause markers,
  and other reconstructible process artifacts.
- [x] `tick.sh` remains read-only against the tracker. Tracker writes continue
  through `lane.sh` or `bootstrap.sh`.
- [x] Core scheduling and failure semantics do not vary by provider.
- [x] Force-push, `git reset --hard`, and unscoped recursive deletion remain
  denied for every provider and permission mode.
- [x] Ticket text remains information, never executable instruction.
- [x] Sibling skills remain out of scope. This work changes Loom only.
- [x] Implementation follows Loom's layer order: `scripts/` first,
  `references/` second, and `SKILL.md` only for the irreducible wave contract.
- [x] Every new artifact below names its consumer.
- [x] Provider instruction files such as `CLAUDE.md` and `AGENTS.md` may help
  an interactive agent, but neither is canonical Loom configuration or build
  state. Scripts read Loom's provider-neutral declarations directly.

## Accepted design

### 1. Put a deep agent-runtime module at the provider seam

- [x] Add `scripts/agent.sh` as the only interface Loom core uses to detect,
  validate, configure, or invoke a coding-agent provider.
- [x] Put provider implementations in `scripts/agents/<provider>.sh`, beginning
  with `claude.sh` and `codex.sh`.
- [x] Use the term **Loom job kind**, not "semantic agent role." Initial job
  kinds are `wave`, `implementation`, `gate`, `merge`, and `probe`.
- [x] Keep native CLI flags, output formats, model IDs, authentication checks,
  trust checks, and policy artifacts inside adapters.
- [x] Do not let `tick.sh`, `plan.jq`, `snapshot.jq`, lane prompts, or tracker
  labels construct provider-native commands.

The target interface is:

```sh
scripts/agent.sh detect [--provider <id>]

scripts/agent.sh preflight \
  --provider <id> \
  --job <wave|implementation|gate|merge|probe> \
  --tier <medium|high> \
  --cwd <absolute-path>

scripts/agent.sh sync-guardrails \
  --provider <id> \
  --repo <absolute-path>

scripts/agent.sh run \
  --provider <id> \
  --job <wave|implementation|gate|merge|probe> \
  --tier <medium|high> \
  --cwd <absolute-path> \
  --brief <absolute-path> \
  [--lane-id <id>]
```

Interface behavior:

- `detect` returns exactly one registered provider or fails closed. Provider
  binary presence is validation evidence, not identity evidence: having both
  `claude` and `codex` on `PATH` must not make detection ambiguous or select
  whichever happens to appear first.
- `preflight` validates the selected provider's executable and version,
  authentication, trust/policy state, tier mapping, required network access,
  and job-specific readable/writable paths. It returns actionable structured
  diagnostics and spends no model tokens.
- `sync-guardrails` idempotently installs or updates only the repo-local,
  versionable guardrail artifacts owned by Loom.
- `run` accepts no raw provider flags. It resolves the tier to a provider
  execution profile, invokes the native CLI, and emits canonical Loom events.
- Internal adapter operations may be more numerous, but they are not part of
  the core interface. Adding a provider must not expand what callers learn.

### 2. Detect the provider only at the interactive start boundary

- [x] `/loom start` auto-detects the current interactive provider. The user
  does not need an `agent_provider` configuration key.
- [x] Detection uses strong, adapter-owned runtime identity signals. It must
  not infer identity from installed binaries, a global default, a parent PID,
  or the last project that ran Loom.
- [x] If no provider or more than one provider matches, `start` stops with an
  explanation and accepts a one-time explicit `--provider <id>` override.
  That override is invocation input, not a persisted config default.
- [x] Headless waves and lanes never auto-detect. They receive the already
  selected provider explicitly.

This separates two different contexts:

1. Interactive `/loom start` has enough host context to identify the caller.
2. A scheduled or chained headless process does not, so it consumes the
   build's recorded provider rather than guessing.

### 3. Persist provider identity on the build and transport it explicitly

- [x] Record the canonical provider as one label on the active `Build N`
  issue: `provider::claude`, `provider::codex`, or a future registered ID.
- [x] Add a human-only `lane.sh build-provider` mutation for applying the
  label. It must refuse calls from waves and lanes and enforce exactly one
  `provider::` label.
- [x] Have `bootstrap.sh` ensure the selected provider label exists before it
  is applied. Do not pre-create labels for every hypothetical provider.
- [x] Install the scheduler with `tick.sh install --provider <id>`. Store that
  argument in the repo-specific launchd/cron entry as transport and an early
  consistency check, not as canonical build state.
- [x] On every scheduled tick, query the current `Build N` issue and compare
  its provider label with the scheduler argument before starting a paid
  session. Missing, multiple, unknown, or mismatched values fail closed.
- [x] Pass the provider through every wave spawn, lane spawn, and chained
  handoff. The provider must be visible in canonical start/end events.
- [x] Resuming a build with the same provider is automatic. Starting it from a
  different provider refuses a silent switch. Provider migration is a later,
  explicit operation, not part of `start`.

The scheduler argument is intentionally duplicated from the tracker. The
tracker value makes the build reconstructible; the scheduler value lets Loom
detect a stale or incorrectly installed scheduler before money is spent.

### 4. Keep simultaneous projects isolated

- [x] Provider state is scoped to `Build N` and the repo-specific scheduler.
  Never write a global "current provider" file.
- [x] Preserve the existing per-repo `REPO_KEY`, run directory, lock, logs,
  lanes, and scheduler label.
- [x] Namespace provider-specific profile overrides by provider ID so a Claude
  mapping cannot be read as a Codex mapping.
- [x] Build A in Project A may carry `provider::claude` while Build B in
  Project B carries `provider::codex`; both schedulers may run at the same
  time.
- [x] Scheduler `PATH` construction resolves the selected adapter's executable
  instead of special-casing `claude`.

### 5. Replace provider model names with two Loom model tiers

- [x] Loom's public model tiers are only `medium` and `high`.
- [x] Do not add `low`. Work that does not need meaningful judgment belongs in
  deterministic scripts; the remaining Loom jobs do not have a justified
  low-capability use case.
- [x] Tracker labels become `model::medium` and `model::high`. A ticket without
  a model label uses the configured lane tier.
- [x] Ticket model labels affect implementation lanes only. Gates, merges, and
  probes continue to use the configured lane tier.
- [x] The implementation-lane resolution order is:
  ticket `model::<tier>` label, then `rework_tier` after a rejection, then
  `lane_tier`.
- [x] Waves use `wave_tier`.
- [x] A usage-limit downshift is `high` to `medium`. A limit at `medium`
  pauses/halt-notifies according to the existing usage policy; it never
  silently invents a lower tier.
- [x] For Codex, that downshift is specifically
  `gpt-5.6-sol`/`high` reasoning to `gpt-5.6-terra`/`medium` reasoning,
  followed by pause/notification if the medium profile also reaches a limit.

Target provider-neutral project configuration:

```yaml
wave_tier: medium
lane_tier: medium
rework_tier: high
```

- [x] The initial provider-neutral defaults are locked as
  `wave_tier: medium`, `lane_tier: medium`, and `rework_tier: high`.
  No default resolves to a provider-native model in Loom core.

Each adapter maps a tier to an execution profile, not merely a model string:

| Loom tier | Intent | Claude adapter default | Codex adapter default |
|---|---|---|---|
| `medium` | Normal wave and lane judgment | Sonnet-family profile | `gpt-5.6-terra` with `medium` reasoning |
| `high` | Difficult rework or explicit escalation | Opus-family profile | `gpt-5.6-sol` with `high` reasoning |

The Codex profile contains both `model` and `model_reasoning_effort` because
those are separate controls. The adapter translates its `reasoning_effort`
profile field to Codex's `model_reasoning_effort` setting explicitly on every
headless invocation. It never inherits a user's interactive model or reasoning
default. Exact provider model IDs stay in adapter defaults, this
provider-specific design record, or optional provider-namespaced overrides;
they never enter tracker state, planner actions, `SKILL.md`, or generic config.

Do not use `gpt-5.6-luna` for Loom: that would recreate the intentionally
omitted low tier. Do not make `xhigh` or `max` the default high profile.
Evaluate `xhigh` only if representative failed/rework tickets show a measured
quality gain that justifies the additional latency and spend.

Example optional overrides, which customize a provider but do not select it:

```yaml
provider_profiles:
  claude:
    medium: {model: sonnet}
    high: {model: opus}
  codex:
    medium: {model: gpt-5.6-terra, reasoning_effort: medium}
    high: {model: gpt-5.6-sol, reasoning_effort: high}
```

Resolution order is repo provider override, global provider override, then the
adapter default. A missing or invalid mapping is a preflight failure; there is
no silent fallback to a provider default that Loom cannot report. If the
selected Codex account or CLI cannot use one of these models, preflight reports
that exact profile as unavailable and requires an explicit provider-namespaced
override rather than substituting another model.

### 6. Normalize provider output before Loom consumes it

- [x] Adapters translate native Claude and Codex output into versioned
  canonical JSONL.
- [x] `render.jq`, liveness, turn/cap accounting, usage handling, diagnostics,
  and retro consume only the canonical schema.
- [x] The canonical event vocabulary covers session start, assistant progress,
  tool/command progress, usage, limit, error, and session end.
- [x] Every session records provider, Loom job kind, requested tier, and
  resolved execution profile. Planner state carries only the tier.
- [x] Unknown dollar cost is `null`, never guessed. This is important for
  Codex sessions whose authentication path may not expose per-session dollar
  cost.
- [x] Native logs may be retained as run-directory diagnostics, with a named
  diagnostics consumer. They are plumbing, not build state.

Illustrative canonical event shape:

```json
{
  "schema": 1,
  "type": "session_start",
  "timestamp": "2026-08-15T12:00:00Z",
  "provider": "codex",
  "job": "implementation",
  "lane_id": "impl-42",
  "requested_tier": "high",
  "resolved_profile": {
    "model": "<provider-native-id>",
    "reasoning_effort": "high"
  }
}
```

### 7. Separate deterministic setup from agent judgment

- [x] Move new-lane worktree creation, remote-base fetch, worktree path
  validation, and `.env` copying into deterministic Loom scripts.
- [x] Keep ticket interpretation, implementation, review, merge-conflict
  judgment, and epic acceptance in agent jobs.
- [x] Use the narrower filesystem requirements to give each provider the
  least authority its job needs. In particular, a Codex session should not
  need broad access to the parent directory merely because the old wave prompt
  created worktrees itself.

### 8. Make guardrail installation provider-specific and narrow

- [x] Use `sync-guardrails`, not `install-policy`. The former describes the
  actual operation and avoids implying that Loom owns the provider's entire
  security policy.
- [x] The Claude adapter owns Loom-managed entries in
  `.claude/settings.json`. The Claude CLI is their consumer.
- [x] The Codex adapter owns `.codex/rules/loom.rules` if Codex rule evaluation
  proves capable of enforcing Loom's hard denials. The Codex CLI is its
  consumer.
- [x] Per-run sandbox, approval, network, and writable-root choices are made by
  `agent.sh run`; they are not durable files installed by
  `sync-guardrails`.
- [x] `sync-guardrails` does not install credentials, accept workspace trust,
  write global provider config, create `AGENTS.md`, or install a general
  `.codex/config.toml`.
- [x] Managed artifacts are idempotent and preserve unrelated user settings.

- [!] Codex support cannot be declared complete until an automated
  conformance test proves the actual headless CLI blocks force-push,
  `git reset --hard`, and unscoped recursive deletion in a disposable test
  repository. If Codex project rules cannot enforce the invariant, the adapter
  must add an equally strong execution wrapper or remain unavailable.

At implementation time, validate Codex invocation and policy behavior against
the current official documentation:

- [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Codex rules](https://learn.chatgpt.com/docs/agent-configuration/rules)

### 9. Keep installation and project metadata provider-neutral

- [x] `agent.sh`, `tick.sh`, and `lane.sh` locate Loom from their own script
  paths. Core machinery does not assume `~/.claude/skills`, `$CODEX_HOME`, or
  another provider's install root.
- [x] The committed issue-tracker declaration and `.loom.yml` remain the
  provider-neutral project contract. Provider instruction files may point to
  that contract but do not duplicate it as a second source of truth.
- [x] Active maintenance worktree paths move away from `.claude/worktrees` to
  a Loom-owned neutral path, with a safe compatibility migration.
- [x] Provider-specific project artifacts are limited to artifacts with a
  provider consumer, such as `.claude/settings.json` and
  `.codex/rules/loom.rules`. Generic Loom behavior does not live in them.
- [x] Documentation may explain provider-specific installation/discovery, but
  the runtime interface and tracker model remain the same for all providers.

## Implementation steps

### Phase 0 — Characterize the current contracts

- [ ] Inventory every Claude/model dependency in scripts, jq programs,
  references, tests, and generated policy files. Classify each occurrence as
  core behavior, adapter behavior, documentation, fixture, or historical text.
- [ ] Capture failing-first/characterization fixtures for Claude command
  construction, streaming, liveness, retry/usage limits, lane chaining,
  scheduler installation, trust checks, and guardrail generation.
- [ ] Record current config resolution and tracker-label behavior before
  changing names.
- [ ] Decide and document the canonical event schema and stable error
  categories at the `agent.sh` interface.
- [ ] Capture baseline quality, latency, token, and retry data for the locked
  tier defaults so later profile changes are evidence-based.

Done when the existing Claude behavior can be tested without launching a real
paid session, and every provider-specific dependency has an intended owner.

### Phase 1 — Add the agent-runtime interface and conformance harness

- [ ] Add `scripts/agent.sh` with strict argument validation and the `detect`,
  `preflight`, `sync-guardrails`, and `run` verbs.
- [ ] Add adapter discovery/registration under `scripts/agents/` without a
  global selected-provider setting.
- [ ] Define stable structured results and exit categories for detection,
  preflight, policy failure, authentication failure, usage limit, native CLI
  crash, and successful completion.
- [ ] Add fake-provider fixtures that capture argv/stdin/cwd and emit native
  success, progress, rate-limit, malformed-output, and crash streams.
- [ ] Add adapter conformance tests that every provider must pass.

Done when core tests can exercise the full module through its interface with a
fake adapter and no knowledge of a provider's native CLI.

### Phase 2 — Extract Claude behind the adapter with parity

- [ ] Move `claude -p` argv construction, permission-mode handling, trust
  checks, streaming flags, retry/downshift detection, and native JSON parsing
  into `scripts/agents/claude.sh`.
- [ ] Make the Claude adapter emit canonical events while retaining native logs
  only for diagnostics.
- [ ] Move `.claude/settings.json` management behind
  `agent.sh sync-guardrails --provider claude`.
- [ ] Replace Claude-named fake binaries in generic tests with agent-interface
  fakes; retain Claude-native fixtures only in Claude adapter tests.
- [ ] Prove behavior parity for waves, all four lane types, chaining, liveness,
  usage limits, and retro before adding Codex.

Done when a Claude-backed build follows the old scheduling behavior but no
core launcher constructs or parses a Claude command.

### Phase 3 — Bind provider identity during `/loom start`

- [ ] Implement strong provider detection and explicit ambiguity failure.
- [ ] Add the human-only `lane.sh build-provider` verb and tracker-driver
  support needed to apply exactly one `provider::` label to `Build N`.
- [ ] Change `tick.sh install` and scheduler templates to require and transport
  `--provider`.
- [ ] Cross-check the scheduler provider against the active Build issue before
  launching a wave.
- [ ] Thread the selected provider through wave launches, lane launches, and
  chained handoffs.
- [ ] Preserve same-provider resume and refuse silent provider changes.
- [ ] Add a two-repository fixture proving Claude and Codex scheduler/provider
  state do not collide.

Done when a fresh scheduled tick can reconstruct provider identity from the
tracker and detects stale scheduler transport before model invocation.

### Phase 4 — Migrate model selection to tiers

- [ ] Replace `wave_model`, `lane_model`, and `rework_model` with
  `wave_tier`, `lane_tier`, and `rework_tier` in config resolution and docs.
- [ ] Replace `usage_limit: downshift_model` with provider-neutral tier
  downshift behavior and remove `fallback_model` from the steady-state schema.
- [ ] Change snapshots and plans to carry `{tier, source}` rather than native
  model strings.
- [ ] Change `lane.sh model-tier` and bootstrap label creation to accept only
  `medium` or `high` and enforce one `model::` label.
- [ ] Resolve the provider execution profile only inside `agent.sh run`.
- [ ] Record requested tier and actual resolved profile in canonical events and
  retro output.
- [ ] Add config and tracker migration diagnostics. Automatically translate
  only legacy values whose intent is unambiguous. Attached `model::haiku`,
  `model::fable`, custom aliases, and ambiguous native IDs require an explicit
  human choice between `medium` and `high`; do not guess. Unattached legacy
  label definitions may remain harmless but are no longer created.
- [ ] Support legacy config keys for one documented transition window only if
  they can be translated without ambiguity; otherwise fail with the exact key
  and replacement.

Done when no planner, snapshot, ticket, or generic config path contains a
provider-native model choice, and no supported path produces a low tier.

### Phase 5 — Move worktree preparation into deterministic machinery

- [ ] Add a script-level operation for fetching the remote base, validating
  the sibling worktree target, creating/reusing the worktree, copying the
  root `.env`, and reporting the resulting cwd.
- [ ] Make the operation idempotent and compatible with repos that declare a
  custom worktree mechanism.
- [ ] Update wave actions and briefs so the agent consumes the prepared path
  instead of performing filesystem setup itself.
- [ ] Test path traversal, nested worktree refusal, spaces in paths, stale
  branches, missing remotes, `.env` preservation, and rework reuse.

Done when provider sessions need write access only to the selected repo or
worktree and Loom's scratch area for their job.

### Phase 6 — Implement the Codex adapter

- [ ] Implement Codex `preflight`: executable/version, authentication,
  non-interactive availability, project policy/trust, profile mapping,
  network, and writable-root validation.
- [ ] Invoke headless Codex through `codex exec` with the brief on stdin or the
  documented non-interactive prompt channel, `--json`, `--ephemeral`, and
  explicit job-appropriate sandbox/approval settings.
- [ ] Implement the locked Codex mappings: `medium` resolves to
  `gpt-5.6-terra` with `model_reasoning_effort=medium`; `high` resolves to
  `gpt-5.6-sol` with `model_reasoning_effort=high`.
- [ ] Pass both model and reasoning effort explicitly on every invocation
  (`--model` plus the Codex config override); never inherit either from the
  user's interactive Codex defaults.
- [ ] Reject unavailable mapped models during preflight. Do not fall back to
  `gpt-5.6-luna`, `xhigh`, `max`, or another account default.
- [ ] Normalize Codex JSONL and errors into the canonical event/error schema.
- [ ] Implement idempotent Codex guardrail synchronization without writing
  unrelated project or global configuration.
- [ ] Prove destructive-command denial using the real CLI in a disposable
  repository.
- [ ] Prove wave, implementation, gate, merge, and probe behavior with fake
  tracker and fake/native-agent fixtures; never verify by running a real Loom
  product build.

Done when Codex passes the same adapter conformance suite and Loom safety gates
as Claude.

### Phase 7 — Migrate all consumers to canonical events

- [ ] Update rendering/watch output to show provider, requested tier, and
  resolved profile from canonical events.
- [ ] Update liveness and turn-cap logic to use canonical progress events
  rather than Claude message shapes or log text.
- [ ] Update usage-limit handling to consume canonical limit/usage events.
- [ ] Update retro to aggregate known tokens/cost while preserving `null` for
  unavailable provider costs.
- [ ] Add mixed-provider historical-log fixtures so one project's reports do
  not assume all sessions came from the current adapter.

Done when deleting all native JSON fixtures outside adapter tests does not
break core tests.

### Phase 8 — Update bootstrap, references, and user-facing instructions

- [ ] Replace `bootstrap settings`/Claude-only wording with
  provider-neutral guardrail synchronization while keeping compatibility
  aliases only for the documented migration window.
- [ ] Remove active core dependencies on `CLAUDE.md` and provider-specific
  skill-install roots. Read the shared tracker declaration and Loom config
  directly.
- [ ] Move Loom maintenance worktrees from `.claude/worktrees` to a neutral,
  git-ignored Loom path without disturbing existing worktrees.
- [ ] Update `references/setup.md`, `references/loom-config.md`, README, and
  relevant maintenance references with provider detection, build binding,
  tier mapping, guardrail artifacts, and migration instructions.
- [ ] Reduce `SKILL.md` changes to the facts every wave must know: provider is
  explicit, spawns use the agent interface, plans carry tiers, and events are
  canonical.
- [ ] Remove stale claims that Loom is intrinsically a Claude Code skill or
  that every lane runs `claude -p`.
- [ ] Preserve historical proposal/defect text unless current instructions
  depend on it; history is evidence, not active implementation guidance.

Done when a new user can start either provider without reading the other's
setup instructions and a wave does not pay for migration prose.

### Phase 9 — Verification and rollout

- [ ] Run focused sections while developing, then run
  `bash scripts/tick-test.sh` twice. Two disagreeing runs are a flaky test, not
  a pass.
- [ ] Run static checks proving provider-native command construction and
  native stream parsing occur only in adapters and adapter tests.
- [ ] Run the two-project/two-provider concurrency fixture with distinct repo
  roots, build issues, scheduler labels, locks, logs, and tier mappings.
- [ ] Verify start, stop, resume, chained handoff, scheduler reinstall, build
  completion teardown, and mismatched-provider refusal for both providers.
- [ ] Verify legacy Claude projects receive precise migration guidance and no
  provider or model is chosen silently.
- [ ] Document rollback: preserve tracker provider/tier labels, uninstall the
  new scheduler, restore the prior release, and reinstall with Claude. Never
  rewrite ticket history to roll back runtime machinery.

- [!] Do not enable Codex by default until the real-CLI guardrail conformance
  test, canonical stream suite, and full Loom suite all pass.

Done when all acceptance criteria below are proven without a real paid build.

## Test matrix

| Area | Required cases |
|---|---|
| Provider detection | Claude only, Codex only, explicit override, no match, ambiguous match, both binaries installed |
| Provider persistence | missing label, duplicate label, unknown label, scheduler mismatch, same-provider resume, attempted silent switch |
| Concurrency | two repos, two Build issues, two providers, simultaneous locks/schedulers/logs, no shared selected-provider state |
| Runtime interface | argv/stdin/cwd capture, spaces in paths, malformed adapter output, auth failure, policy failure, native crash, usage limit |
| Model tiers | default tiers, exact Codex Terra/medium and Sol/high mappings, ticket override, rework escalation, implementation-only override, Sol/high-to-Terra/medium downshift, medium-limit pause, unavailable model, missing mapping, no Luna/xhigh/max fallback |
| Streams | each canonical event type, unknown native events, partial lines, abrupt exit, unknown cost, mixed-provider historical logs |
| Guardrails | idempotent sync, preservation of user config, force-push denial, reset-hard denial, recursive-delete denial, allowed `lane.sh` path |
| Worktrees | remote-base freshness, sibling-only path, custom worktree command, rework reuse, `.env` copy, dirty-worktree preservation |
| Regression | waves, gates, merges, probes, chaining, liveness, caps, notify, retro, teardown |

## Acceptance criteria

- [ ] `/loom start` requires no provider config in a recognized interactive
  Claude or Codex session.
- [ ] The active `Build N` issue has exactly one recognized `provider::` label.
- [ ] Every scheduled/headless invocation has an explicit provider and rejects
  disagreement with tracker state before model invocation.
- [ ] Two project folders can run simultaneous builds with different providers
  and no shared provider state.
- [ ] Core Loom constructs neither `claude -p` nor `codex exec`; only adapters
  do.
- [ ] Core Loom consumes no provider-native event shape.
- [ ] Core Loom requires neither `CLAUDE.md` nor a Claude skill-install path
  when running through Codex; provider-specific guardrail artifacts remain
  adapter-owned exceptions.
- [ ] Planner, snapshot, tracker, and generic config expose only `medium` and
  `high`, never native model IDs or a `low` tier.
- [ ] The Codex adapter maps `medium` to `gpt-5.6-terra` with `medium`
  reasoning and `high` to `gpt-5.6-sol` with `high` reasoning, passing both
  values explicitly for every headless session.
- [ ] Codex usage downshift follows Sol/high to Terra/medium to
  pause/notification, with no Luna, `xhigh`, `max`, or user-default fallback.
- [ ] Missing tier mappings and ambiguous legacy values fail clearly rather
  than silently falling back.
- [ ] Claude passes behavior-parity tests.
- [ ] Codex passes the same job, failure, liveness, usage, and security
  conformance tests.
- [ ] Actual provider CLIs enforce Loom's hard destructive-command denials in
  disposable test repositories.
- [ ] Both full-suite runs pass and no new flaky section is dismissed.
- [ ] README, setup, config reference, and the minimal wave instructions agree
  with the implemented interface.

## Non-goals

- [x] No global or user-level selected-provider setting.
- [x] No provider auto-detection inside scheduled waves or lanes.
- [x] No public `low` model tier.
- [x] No provider-native model IDs in tracker state.
- [x] No silent provider migration for an active build.
- [x] No rewrite of Loom's scheduling, tracker, gate, merge, or failure policy.
- [x] No changes to sibling skills.
- [x] No real product build as a verification method.

## Principal risks and fail-closed responses

| Risk | Response |
|---|---|
| Interactive detection signals are absent or ambiguous | Stop `/loom start`; accept a one-time explicit provider argument; never inspect `PATH` order to choose |
| Scheduler was installed for the wrong provider | Compare its argument with the Build label and refuse before launching a session |
| Codex policy artifacts do not enforce hard denials | Keep the Codex adapter unavailable until a wrapper or policy mechanism passes the real-CLI denial suite |
| Provider output changes | Contain the change in its adapter and fail malformed canonicalization explicitly |
| Provider model names or defaults change | Update adapter defaults; keep tiers, tracker state, and plans unchanged |
| A provider does not expose dollar cost | Record tokens when available and `cost_usd: null`; do not estimate |
| Legacy model names have unclear capability intent | Require explicit migration to `medium` or `high`; do not guess |
| Shared global config leaks between projects | Namespace optional mappings by provider and keep selected provider on each Build issue |
