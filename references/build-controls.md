# Human controls on a running build — `stop`, `watch`, `unblock`

The three verbs a human types at a build that is already running. None is ever
invoked by a wave, so none of them belongs in `SKILL.md`, which every headless
wave loads in full. `triage` (batch unblocking) is
[triage.md](triage.md); `start` is [phases-1-5.md](phases-1-5.md).

## `stop [--now]`

`tick.sh uninstall [--now]` — writes the loop switch, unloads this repo's agent
and removes its plist. Plain `stop` lets live lanes finish their current ticket
and cuts the chain after them; `--now` kills them through `kill-lane` instead
(deliberate, so not `crash_cap` crashes). `start` reverses either. For stopping
a build before completion; completion tears down on its own.

## `watch [--no-panes]`

From any session: read `tick.sh lane-status` and tracker state, then narrate
per lane — what it's doing, why, what's next — plus merge-queue depth and
blocked list. Read-only.

Then give the human eyes on the work: inside herdr (`$HERDR_ENV` is `1`),
**always `scripts/watch-panes.sh raise`, detached** — a pane per live lane
running `tick.sh render-log <id> --follow`, plus a build-ticker strip running
`tick.sh render-events --follow` (one timestamped line per step: claimed, →
review, gate verdict, merged — deterministic, zero model time; narrating
mechanical events with a session is the wrong tool). The viewer keeps the
ticker alive every poll, so Ctrl-C and closing the pane is futile — the
gestures that stick are **`q` inside the ticker pane**, `watch-panes.sh ticker
off|on` for that strip, and `watch-panes.sh off|on` for the whole viewer
(closes every pane it owns and exits, honored mid-run and at launch, so the
next tick cannot undo it). `raise` is what clears both switches, which is why
`watch` uses it and a plain launch is wrong here: a human typing `watch` is
asking to see the build, an intent newer than whatever earlier close is on
disk. Only `start` and `watch` may clear them — an *automatic* tick undoing a
human's close is the thing the switches exist to prevent. Detached, so the
panes outlive this session. *(paid: a stale ticker-off marker made `watch`
raise a viewer that silently closed its own ticker every poll.)*

Outside herdr, name those commands instead. `--no-panes` for the summary
alone. Never hand the human a command to paste when it can just be run.

## `unblock <n> [--to-review]`

**`lane.sh transition <n> ready-for-agent --release-hold --note`**, decision on
stdin — one verb posts it, removes `blocked` and clears the assignee. Never
compose those writes by hand: the unassign is the half that gets dropped, and a
claimed `ready-for-agent` ticket is invisible to *both* fill paths (see
`SKILL.md`'s failure policy) *(paid: hand-composed unblock, a ticket
unschedulable for 90 minutes)*. Re-running after a failed write completes the
missing half without doubling the note. `--to-review` → the same with `review`
(human completed the work; it takes the same gate as agent work — no bypass),
assignee kept.

`--release-hold` is refused outright inside a lane or a wave, so this verb is
only ever reachable from a human's own session. That is the point: see the
ticket-text rule in the failure policy.
