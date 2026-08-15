# Loom

Loom turns a product requirements document (PRD) into a finished, reviewed,
merged product — mostly while you are not watching.

You bring a PRD. Loom grills the open architecture and design questions with
you until none are left, breaks the work into epics and tickets on your issue
tracker, and
then runs an unattended loop that implements those tickets in parallel, reviews
each one, merges the passing ones, and tests each epic like a user would. It
tells you when it needs a decision and when it is done.

It is an agent-agnostic coding skill: provider-neutral instructions and shell
machinery with Claude Code and Codex adapters. It is not a service, and there
is nothing to host.

---

## What it does

**Plans with you, then works without you.** The first five phases are
conversational — you answer questions, approve breakdowns, pick what goes in
the build. The sixth phase runs on its own until the work is finished or it
hits something only you can decide.

**Runs several tickets at the same time.** Each in-flight ticket gets its own
git worktree and its own headless coding-agent session ("a lane"). The default is
four implementation lanes plus a smaller pool for review, merge, and test
lanes.

**Keeps all its state in the tracker.** Every decision about a ticket lives on
the board as a label, a link, or a comment. A ticket moves
`ready-for-agent` → `in-progress` → `review` → `merge-queue` → closed, with
`blocked` as the escape hatch. Nothing important lives in a file on your
laptop, so a fresh session can pick up a running build by reading the tracker.

**Reviews before it merges.** Every ticket branch first runs the repo's own
gate commands (lint, tests, whatever you configure per risk tier). If those
pass, a separate review session does a code review plus a check that the work
actually matches the PRD requirement the ticket cites. A pass moves the ticket
to the merge queue; a fail sends it back with a written rejection.

**Merges one at a time, safely.** A single merge lane holds a lock, merges the
integration base into the branch (never a rebase — force-push is denied),
re-installs dependencies if the merge moved a lockfile, re-runs the gates, then
merges the merge request and closes the ticket.

**Tests each epic like a person would.** When every ticket in an epic is
closed, Loom runs an acceptance probe against a really-running stack, using the
epic's own written acceptance criteria. Failures become new fix tickets, which
get built and merged like any other, and then the epic is probed again.

**Knows when to stop and ask.** Repeated review rejections, repeated crashes, a
wedged session, a runaway turn count, or a missing product decision all end the
same way: the ticket is marked `blocked` with a written report saying what was
tried and what single decision is needed, and you get a notification.

**Shows you what is happening.** A build ticker prints one line per event
(claimed, sent to review, verdict, merged). Inside herdr — a terminal
multiplexer for coding agents — you also get a live pane per running lane.
Outside herdr you get the same information as a narrated summary.

**Costs are visible after the fact.** `retro` reports where a finished build's
time and money went and writes up proposals for improving the next one.

---

## Dependencies

### Required

| Dependency | Why Loom needs it |
|---|---|
| **Claude Code or Codex** | The interactive provider starts the build; every headless job then runs through Loom's matching adapter. Provider identity is recorded on the Build issue. |
| **A git repository** | Each in-flight ticket gets its own git worktree, cut as a sibling directory of the repo. Local-only repos will not work — lanes always branch from the remote. |
| **A declared issue tracker** | `docs/agents/issue-tracker.md`, committed, with `# Issue tracker: <Name>` as its heading. Loom scripts and every provider job read that file directly, so there is no second tracker setting that can drift. Without it, every Loom verb refuses. |
| **A board Loom drives** — GitLab or Linear | Epics, issues, labels, blocking links and comments are where **all** build state lives. Loom needs a board it can create labels in. Every board call goes through `scripts/trackers/<name>.sh`, the one file that knows that tracker; a repo declaring anything else is refused by name until a driver for it exists. |
| **A forge** — GitLab or GitHub | Where branches and merge requests live, which on GitLab is the same service as the board and on Linear is not. Loom **derives** it rather than asking: a board that is itself a code host is its own forge, and otherwise your `origin` remote decides. |
| **`glab`** or **`gh`**, logged in — or `LINEAR_API_KEY` | Whatever your drivers need. GitLab and GitHub are driven through their command-line tools: run `glab auth status` (or `gh auth status`) in the repo first, because a tool that cannot resolve the project makes Loom read the board as unknown and skip the wave. Linear has no CLI and is driven over its API, so it wants `LINEAR_API_KEY` in a `secrets:` block in `~/.loom/config.yml` — not in `.loom.yml`, which is committed, and not in your shell profile, which the launchd agent never reads. |
| **`jq`** | Every snapshot, dependency graph, report, and log render is a `jq` query. Missing `jq` is a hard error, not a downgrade. macOS 15 and later ship it at `/usr/bin/jq`; on anything older, `brew install jq`. |
| **A scheduler — launchd (macOS) or cron** | The once-a-minute heartbeat that watches lanes, makes the first wave fire, and resumes a build after a full stall. `/loom start` writes and loads the launchd agent for you. Without one, a build only advances when a lane hands off to the next lane, and a single wedge stops it for good. |
| **A gate runner in your repo** | `scripts/gate.sh <tier>` — yours, not Loom's. Every branch is gated by it before review and again before merge. You do not have to write it up front — it is normally the first epic of your first build. |
| **A trusted workspace and synced guardrails** | Claude uses `.claude/settings.json`; Codex uses `.codex/rules/loom.rules`. `/loom start` preflights the selected provider and refuses if its project policy would be ignored. |

### Required for the planning phases

These are sibling skills. Loom **routes** to them rather than teaching their
techniques; install them where your interactive provider discovers skills:

| Skill | Used by | For |
|---|---|---|
| **`lavish`** (Lavish Editor) | `epics`, `build`, `tickets`, `triage` | Every decision surface Loom puts in front of you — epic breakdowns you can merge and split, the epic-selection screen, ticket bodies with their open questions, the blocked-ticket triage board. It builds an HTML page and opens it in your browser for annotation. It runs through `npx -y lavish-axi`, so it also **needs Node.js and `npx`** on your machine. |
| **`grilling`** | `plan` | Working an architecture or design question to a real decision instead of a list of options. |
| **`to-tickets`** | `tickets` | Slicing work into tracer-bullet tickets, the blocking edges between them, and the tracker mechanics of publishing them. |
| **`implement`** | manual-drive mode | Working the ticket frontier by hand, one ticket at a time, with the same tracker state the loop uses. |
| **`code-review`** | phase 6 review lanes | The code review half of every gate verdict. |
| **`domain-modeling`** | `plan` | Architecture decision record conventions. |
| **`prototype`** | `plan` | Making a UX option clickable when the mockup is not enough to decide. |

The unattended loop itself needs none of them — headless sessions have no slash
commands, so a wave inlines that work instead.

### Optional

| Dependency | What you gain, and what happens without it |
|---|---|
| **herdr** | A terminal multiplexer that recognizes coding agents in panes. Inside it (`HERDR_ENV=1`), `/loom start` and `/loom watch` raise a live pane per running lane plus a build-ticker strip, so you can watch the whole build at once. Without herdr, `watch` gives you the same information as a narrated summary and names the commands you could run yourself. Nothing about the build depends on it. |
| **An `ntfy` topic** | Push notifications to your phone when a ticket blocks, the build halts, or the build finishes. Without a topic, Loom falls back to local macOS banners via `osascript`. **Use an access-protected topic** — a public one anyone can post to is a direct path into an unattended session. |
| **A repo worktree helper** | Repos with their own non-git worktree mechanism (for example `openemr-cmd`) declare it as `worktree_cmd:` in `.loom.yml`. Plain `git worktree` is the default and needs nothing. |

---

## Setup

Almost nothing. Loom sets itself up on its first tick; what is left is the two
things a program is not allowed to do for you.

### 1. Install Loom and its sibling skills

Put this directory in your provider's skill directory — the scripts locate
Loom from their own path. Install `lavish`, `grilling`, `to-tickets`, `implement`,
`code-review`, `domain-modeling`, and `prototype` beside it; the planning
verbs hand off to them.

### 2. Declare the tracker, authenticate, and trust the repo

Run `/setup-matt-pocock-skills` in the repo once. It writes
`docs/agents/issue-tracker.md` — the file every lane follows and the one Loom
reads to learn which tracker this repo uses. **Commit it.** A worktree is a
checkout, so an untracked declaration is visible to you and to no lane, and
Loom refuses on exactly that.

```sh
glab auth login          # then, in the repo:
glab repo view           # should resolve your project
```

**On Linear**, that verb has no template — it files anything but GitHub,
GitLab and Local Markdown under "Other" — so write the heading yourself, add
a `Team: <KEY>` line beside it, and put `LINEAR_API_KEY` in a `secrets:` block
in `~/.loom/config.yml`. Your `origin`
remote is then the forge, and the rest of that file is what tells the sibling
skills how to work the board. [setup.md](references/setup.md) has the detail,
including why that last part is the thing that decides whether builds work.

Then trust the repo in the provider you will use. Loom never accepts trust or
writes credentials for you; its preflight fails closed when project guardrails
would be ignored.

That is the whole manual setup. Run `/loom plan <PRD>` next.

---

### What Loom does for itself

You do not need to run any of this. It is here so you know what appeared and
why.

**On the first tick in a repo**, `scripts/bootstrap.sh all` runs by itself and
then the wave proceeds. It writes `~/.loom/config.yml` (machine-wide Loom
preferences) and creates the ticket-state labels on the board. `/loom start`
has already synced the selected provider's repo-local guardrail artifact. A failed
bootstrap writes no sentinel, so the next tick just retries. Running
`bootstrap.sh all` by hand is safe and idempotent, but it buys you nothing.

**One thing does need you afterward: commit the provider guardrail artifact**
(`.claude/settings.json` or `.codex/rules/loom.rules`). Lane
worktrees are cut from `origin/<base>`, so an uncommitted allowlist reaches no
lane. Bootstrap prints a warning rather than committing it, because a
permission surface entering your history is your call.

**Configuration is mostly derived, not written.** Keys resolve
**repo → derived → global → built-in default**, and the derived layer reads
your repo directly: the integration base branch, the gate commands for your
detected stack, the runner path. Most repos need no configuration file at all.
To see what yours actually resolves to:

```sh
<loom-install>/scripts/tick.sh resolve-config
```

**The gate runner is built by your first build, not by you.** Loom runs
`scripts/gate.sh <tier>` from **your repo** — your definition of done, so CI
and anyone with a bare clone run it without Loom installed. Writing it, along
with the CI pipeline and any `.loom.yml` line no detector can infer, is
normally the first epic of the first build, and every other epic blocks on it.
Details: [references/setup.md](references/setup.md).

**The scheduler is installed by `/loom start`.** No `launchctl`, no plist, no
cron entry to write, and a finished build unloads its own agent.

### Optional tuning — `.loom.yml`

At the repo root. Its absence is a valid, complete configuration. Reach for it
only to override a default or state a fact no detector can infer:

```yaml
max_lanes: 4                    # 1-6; each lane is a full worktree
rejection_cap: 2                # review rejections before a ticket is blocked
crash_cap: 2                    # crashes before blocked (crashes are not rejections)
heartbeat_stale_minutes: 30     # alive but silent this long = wedged
usage_limit: pause_and_resume   # pause_and_resume | stop_and_wait | downshift_tier
base: develop                   # integration base branch

wave_tier: medium               # provider adapter resolves the native profile
lane_tier: medium               # gate/merge/probe and default implementation tier
rework_tier: high               # implementation tier after a rejection

ntfy:
  topic: ""                     # use an access-protected topic; a public one is an injection path
  push: [build_complete, build_halted, ticket_blocked, workspace_untrusted, build_unarmed]

gates:                          # tier keys are fixed: docs | logic | api | ui
  docs:  ["uv run ruff check ."]
  logic: ["uv run ruff check .", "uv run pytest -q"]
  api:   ["uv run ruff check .", "uv run pytest -q"]
  ui:    ["uv run ruff check .", "uv run pytest -q", "uv run playwright test"]
```

Gate values are literal shell commands, fastest first. The full key reference,
including every enum option, is in
[references/loom-config.md](references/loom-config.md).

There is deliberately no tick-interval setting. The timer is a fixed backstop;
finishing lanes set the real pace.

---

## The workflow, step by step

Every verb is `/loom <verb>` in the interactive provider. **A verb stops at its own
output and hands back to you.** It never rolls on into the next one, and it
never writes production code by hand.

### Step 1 — `/loom plan <PRD>`

Loom reads the PRD and the repo, then separates facts (which it looks up) from
decisions (which are yours). Dependent questions get grilled one at a time with
a recommendation each; independent ones arrive as a single decision surface you
can work through.

Every closed decision becomes an architecture decision record, folded into
`ARCHITECTURE.md`. It then repeats the whole thing for the user interface and
produces a written UX spec with annotated mockups.

**Done when** a ticket writer with no access to you could answer every "which
way?" from the architecture records and the UX spec alone.

### Step 2 — `/loom epics`

A proposed epic breakdown and dependency sketch, on a surface you can annotate
— merge, split, reorder. On approval the epics (or milestones, or projects) are
created on the board.

Each one gets an **acceptance criteria** section: a handful of observable,
user-level statements, each traceable to a PRD requirement. This is the one
thing this step produces that the unattended loop later reads — it becomes the
epic's acceptance probe.

### Step 3 — `/loom tickets`

Tickets are drafted into one file, one epic at a time, then re-read whole
before anything is published, because cross-ticket contradictions are invisible
from inside any single ticket.

Each ticket carries: design decisions already made, the exact shape of any
interface it shares with another ticket, tests for inputs that must be
*rejected*, a risk tier (`docs`, `logic`, `api`, `ui`) that picks its gate
suite, and the PRD requirement it satisfies.

Every epic ends with a **wiring ticket** — blocked by every other member, and
checked against the running app with real data. Without it, nothing judges the
epic as a whole until the very last step.

You see the ticket bodies and any surviving ambiguities before publishing.

### Step 4 — `/loom build`

Pick which epics go in this build. Loom creates a `Build N` issue and labels
every member ticket `build-N` — from then on the scheduler's whole universe is
"open issues labeled `build-N`".

It then reports the build's *shape*: how many tickets can start at once, how
deep the chains run. A narrow start means every lane idles, and the fix is to
go back and split a blocker. An epic with no wiring ticket is refused outright.

This step spends nothing and starts nothing.

### Step 5 — `/loom start`

The trigger. It detects the interactive provider (or accepts one explicit
`--provider` override), records exactly one `provider::<id>` label on the active
Build issue, syncs that provider's guardrails, installs a repo-specific
scheduler carrying the same provider as a consistency check, clears the stop
switch, and fires the first wave. Inside herdr it also raises the viewer.

This is the only thing you run to go unattended. No `launchctl`, no plist file,
no cron entry to write.

It is also **resume**: after clearing a blocked ticket, or after a `stop`,
`start` picks the build back up with no replanning.

### Step 6 — the loop runs

The agent fires once a minute. Every firing *watches* — stamps each lane's
progress, classifies quiet, notifies you once per state change. Only then does
it consider starting a wave, and only if at least `min_wave_gap_minutes`
(default 10) have passed. Finishing lanes trigger the next wave immediately, so
the loop moves at the speed of the work; the timer is only a slow backstop for
the first kick and for recovering from a full stall.

Each wave does the same seven things:

1. **Read** one JSON snapshot of the build — tickets, labels, blocking edges,
   epic rollup, lane states.
2. **Harvest** finished and wedged lanes. A crash is resumed from its surviving
   worktree. A wedged lane is killed properly (killing it by hand orphans the
   session inside, which keeps pushing). Caps turn repeated failure into a
   `blocked` ticket instead of an infinite retry.
3. **Review** every ticket sitting in `review`. The repo's gate commands run
   first in plain shell, so a mechanically broken branch is rejected in seconds
   having spent no model time. Past that, a session does the code review and
   the PRD-faithfulness check. Pass → merge queue. Fail → back to
   `in-progress` with a written rejection naming the kind of failure.
4. **Fill lanes**, rework before new work. Tickets that just got rejected are
   closest to done, so they get slots first — but two rejections of the *same
   kind* stop the ticket for a design decision rather than a third guess. Then
   fix tickets, then the rest of the ready set. Ready means every blocker's
   merge request has actually merged. Each new ticket gets a fresh worktree cut
   from the freshly fetched remote base.
5. **Merge** the oldest ticket in the queue, one at a time under a lock. If the
   gates go red only *after* merging the base in, the same check is re-run
   against a clean base — the same failure there means the base is broken, not
   this ticket, so a fix ticket is filed and this ticket parks until it lands.
6. **Probe** every epic whose tickets are all closed, exercising it the way a
   user would against a running stack, using that epic's acceptance criteria
   plus regression checks for anything the epic has broken before. Each failure
   files a fix ticket. A failed epic stays open and gets probed again once its
   fixes merge — never waved through because the fixes looked small.
7. **Notify and write back**: ticket blocked, build halted, or build complete.
   Completion posts a report tracing every PRD requirement to its evidence,
   closes the `Build N` issue, and unloads the repo's own agent. A finished
   build leaves nothing running.

### While it runs

| Command | What it does |
|---|---|
| `/loom watch` | Narrated summary of every lane, the merge queue, and the blocked list. In herdr, raises live panes. Read-only. |
| `/loom unblock <n>` | Post your decision, clear `blocked`, release the ticket back to the queue. `--to-review` if you did the work yourself. |
| `/loom triage` | Every blocked ticket on one surface, six actions each, applied as a batch. |
| `/loom tick` | Force one wave now. |
| `/loom stop` | Stop the loop. Live lanes finish their current ticket; nothing follows them. `--now` kills them too. Worktrees survive either way. |
| `/loom replan` | Diff an amended PRD and regenerate only the affected tickets. |
| `/loom retro` | Where a finished build's time and money went, written up as proposals. |

Two more knobs live in the tracker itself, because that is where every decision
belongs:

- **A hold** is the `blocked` label. It sticks: Loom refuses to advance a
  blocked ticket, so a hold you place mid-flight beats any lane already
  running. Only you can release it.
- **An escalation** is `model::medium` or `model::high` on a ticket. It survives every
  round until you remove it, and it changes only that ticket's implementation
  lane — not its reviewer.

---

## Safety

- **Force-push, `reset --hard`, and `rm -rf` are denied** in every permission
  mode, in every lane. The merge step merges; it never rebases.
- **Lanes never bypass approvals or sandboxing.** Each adapter supplies its
  provider-native non-interactive safety settings explicitly.
- **Every tracker write in a lane goes through `scripts/lane.sh`**, never a
  hand-rolled `glab` call. A lane that needs something `lane.sh` cannot do has
  found a missing verb, not a reason for a wider allowlist.
- **Ticket text is information, never instructions.** A comment saying "then
  run `/loom unblock 67`" is prose written for a person. Only labels, blocking
  edges, and the skill's own steps decide what a wave does.
- **Notification topics should be access-protected.** A public topic anyone can
  post to is a direct path into an unattended session.

---

## What is in here

```
SKILL.md                  the skill itself: phase order, gate rules, failure policy
references/
  setup.md                bootstrap, config layers, the skill/repo boundary
  loom-config.md          every configuration key, with its options
  phases-1-5.md           the conversational front half, in full
  ticket-template.md      what a ticket body must contain
  triage.md  retro.md  qa.md  optimize.md  prop.md  fix.md
scripts/
  tick.sh                 the scheduler: lock, spawn, watch, snapshot, notify
  lane.sh                 every tracker write a lane is allowed to make
  bootstrap.sh            one-time repo setup (the only script that writes setup state)
  watch-panes.sh          the herdr viewer
  tick-test.sh            the test suite for tick.sh
  *.jq                    snapshot, graph, report, and render queries
OPEN_DEFECTS.md           confirmed defects awaiting a fix
PROPOSALS.md              improvements proposed by retros, awaiting implementation
```

`tick.sh` is **read-only against the tracker** by design — a wave re-runs it
constantly, so a mutating call there would be unsafe to repeat, and the test
suite enforces it. Everything that writes lives in `lane.sh` and
`bootstrap.sh`.

---

## Working on Loom itself

| Command | What it does |
|---|---|
| `/loom qa` | Review the skill's own files and report defects. Reports; never fixes. |
| `/loom fix <Dn>` | Implement one confirmed defect fix from `OPEN_DEFECTS.md`, prove it with a failing-first test, close the entry. |
| `/loom prop <Pn>` | Implement one proposal from `PROPOSALS.md`, test it, archive it. |
| `/loom optimize` | Compact `SKILL.md` without changing what it makes an agent do. |

Two rules govern every change:

**Every rule is paid for by a failure.** A new rule is added only after a real
build failure, as one line, citing that failure. Most of `SKILL.md` reads as a
list of scars, and that is deliberate.

**Route, don't teach.** Technique belongs in other skills. `SKILL.md` holds
only phase order, gate criteria, scheduling, and failure policy.
