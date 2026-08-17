# The timer, the quiet gate, and the loop switch

How `tick.sh` decides *when* to spend a wave. All of it is the script's own
behaviour — a wave never implements any of it, which is why it lives here and
not in `SKILL.md`. Read it when changing the scheduler, arming a build by
hand, or explaining why nothing ran.

## One agent, watching first, spending second

A single launchd entry per repo fires `tick.sh tick --auto` every **60s**
(prefer launchd on macOS over cron). Every firing *watches* — stamps lane
progress, classifies quiet (`stalled` / `halted` / `complete` / `unknown`),
notifies once per state change — **before anything touches the lock**, and only
then considers a wave. That order is the whole design: the old scheduler bailed
at the lock, so during a wave — the exact window in which a lane wedges —
nothing was looking, and a second 60s watcher process had to exist to cover it.
Watching first makes that process unnecessary — `install` retires the old one.

The same heartbeat drains validated worker requests left by Codex sessions.
On macOS it bootstraps each worker as a separate **one-shot** launchd plist,
with no KeepAlive key: the lane epilogue schedules the next wave, while launchd
must never repeat a completed implementation, gate, or merge. Lane liveness
uses launchd's active pid when a sandboxed Codex caller cannot use `kill -0`
against that sibling job. This is also the source Herdr's viewer follows when
it raises one pane per active lane.

## Spending is paced by the gap, not the timer

**`min_wave_gap_minutes` (default 10)** paces spend, so a 60s tick costs
nothing: a wave starts only when the gap has elapsed. Three callers, three
contracts — **`tick`** (a human typed it: always runs one wave, ignores switch
and gap), **`tick --auto`** (the timer: respects both, except the one-shot
RunAtLoad kick written by `start`), **`tick --from-lane`** (a lane finished:
respects the switch, ignores the gap, because a handoff is work already in
progress). The start kick is consumed only when a wave is admitted, so a lock
or unreadable board cannot silently discard the human's request to resume now.

Quiet gates spend before any of that, and the gate is an **allowlist**:
`halted` skips the wave entirely, `stalled` + `stall_action: notify_only` skips
and waits, `unknown` — the board could not be read at all — skips on the timer,
and only `active` and `complete` buy a wave. Every skip writes a `tick_skipped`
event naming its reason, so the ticker can say why nothing ran. *(paid: the
gate used to name only the states that block, so `unknown` fell through. A
sleeping laptop runs the missed firing the instant it darkwakes, before WiFi is
back; the tracker read fails, the board reads `unknown`, and a full model
session launches on a build where every ticket is blocked — four overnight
waves, one of them 84 minutes.)*

## The timer is a backstop, not the pace

A finishing lane fires the next wave immediately, so the loop advances at the
speed of work. The timer only covers the two things completion cannot signal:
the initial kick, and resuming after a full stall. Redundant fires are safe — a
tick landing mid-wave is remembered and replayed once when that wave exits.
The same one-shot replay is requested when the durable post-wave boundary
clears one or more completed lanes. The provider planned against the old lane
set; cleanup can expose runnable work after the provider is gone, when no lane
remains to hand off and the heartbeat is still inside the wave gap. Replanning
once from that durable post-cleanup state closes the gap without a human or
`mend` issuing a manual tick. Multiple cleanup requests in one batch coalesce
to the same single replay. If the original host dies before that postlude, the
next durable heartbeat can inherit the queued cleanup. Because it drains
before the automatic wave-gap check, any cleanup it completes admits that
same heartbeat's wave once; draining durable state and then stopping at the
old gap would recreate the exact lost-host stall the queue exists to recover.
Every tick arms the backstop itself if none is armed, so a loop kicked by a
manual `tick` acquires one; if launchd refuses, one push says so and the build
is running unprotected. *(paid: a wave misread a permission denial as "never
bootstrapped", exited without harvesting, and nothing fired again for hours.)*

## The loop switch

`start` clears `$LOOM_HOME/loop.stopped`; `stop` writes it. While it exists,
**automatic** continuation stops — the timer no-ops, and a lane may not chain
to its successor (`spawn-lane` refuses when `LOOM_LANE_ID` is set, which is
true only inside a lane). A lane already running still finishes its own ticket;
nothing follows it. `stop --now` additionally kills every live lane through
`kill-lane` — those kills are deliberate and **never count toward
`crash_cap`**; the worktrees survive and `start` resumes each ticket from
there. A human's explicit `tick` is never gated: an explicit command is not
automatic continuation. *(paid: `stop` used to unload the timer and nothing
else, so a "stopped" build kept chaining, kept scheduling and kept spawning,
with no agent installed and nothing watching.)*
