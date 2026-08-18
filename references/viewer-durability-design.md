# Durable viewer controller design

Status: implemented. Consumer: Loom viewer maintainers. The shipping contract
tests live in `scripts/tests/14-viewer-durability.sh`.

## Failure being repaired

The viewer currently has three pieces of volatile authority: a PID checked
only with `kill -0`, an in-memory pane map, and a detached process launched by
the caller. If that process dies, its panes survive but their ownership does
not. A replacement viewer therefore cannot distinguish them from human panes,
cannot adopt an active lane's pane, and cannot remove inactive orphans. A
reused host PID can also keep the singleton wedged forever. The live
Patient Imaging build exposed the lost ownership and orphaned-pane path on
2026-08-17; the existing PID-only singleton makes restart correctness depend
on an unsafe identity check.

## Ownership protocol

Create one stable random owner token per repo state directory at
`$LOOM_HOME/watch-panes.owner`. This is runtime plumbing, not build state.
Every pane the viewer creates must immediately receive Herdr metadata from
source `loom-viewer`:

| token | value |
|---|---|
| `loom_viewer` | the stable owner token |
| `loom_role` | `controller`, `worker`, or `ticker` |
| `loom_lane` | exact lane id for a worker; absent otherwise |
| `loom_ticket` | exact ticket key for a worker; absent otherwise |

Herdr pane IDs are stable and not reused. The owner token prevents one repo's
viewer from claiming another repo's pane. Labels, terminal titles, cwd, and
scrollback are presentation only and must never grant cleanup authority.

The Herdr pane list is the persistent pane map. A process-local file may cache
it for one poll, but recovery always reconstructs ownership by selecting live
panes whose `tokens.loom_viewer` exactly matches the repo token. A malformed
record, missing token, failed list, or failed JSON parse grants no authority:
leave the pane alone and report the viewer degraded.

## Controller topology

`watch-panes.sh raise` and `watch-panes.sh on` must ensure one controller pane
inside the caller's Herdr workspace, then use `herdr pane run` to start
`watch-panes.sh supervise`. Do not rely on `nohup` from a Codex process: Codex
can reap detached descendants when its session returns.

The controller pane is itself tagged before the command starts. `supervise`
runs the polling worker as a child and restarts an unexpected exit after a
bounded backoff. It exits only when `viewer-off` exists or it receives
INT/TERM. Its worker command has the test seam `WATCH_WORKER_CMD`; production
defaults to `watch-panes.sh worker`. A worker crash therefore leaves the
controller alive, and the replacement reconstructs the panes from Herdr.

The PID file becomes diagnostic only. If it remains, write PID plus the
process start identity read from `ps -o lstart=` and accept it only when both
still match. A live PID alone is never singleton authority. Prefer the tagged
controller pane for the singleton decision, which removes PID reuse from the
control path entirely.

`off` writes `viewer-off`. The controller's worker closes only token-matching
worker and ticker panes, then the controller exits and closes its own tagged
pane. `on` removes the marker and ensures the tagged controller. Automatic
ticks still do not create a viewer; only the existing human `start`, `watch`,
and `on` paths may create the controller.

## Active-only reconciliation

At startup and every poll:

1. Read `tick.sh lanes-alive` once. A stale-but-alive lane is active.
2. Read all panes in the controller's workspace once and select only panes
   with this repo's exact owner token.
3. Keep one tagged ticker when enabled; close duplicate tagged tickers.
4. For every active lane, keep exactly one matching worker pane. Prefer an
   already tagged pane for the exact lane, then a pane for the same ticket.
   Retag it to the current lane. Close duplicate tagged panes.
5. Close every other tagged worker pane. There are no idle worker panes: the
   durable logs preserve the story, while a visible pane means a worker is
   active now.
6. Create panes for active lanes still unmatched, up to the existing cap.
7. Never close, rename, resize, run a command in, or use as a split anchor any
   pane lacking the exact owner token, except the explicit human caller anchor
   already supplied to `raise`.

Reconciliation is conservative when discovery fails: do not close anything;
keep the controller alive, emit one `viewer_note`, and retry next poll.

## Delivery stages

1. Implement token helpers and recovery without changing layout. Make the
   ownership/orphan tests in `scripts/tests/14-viewer-durability.sh`
   green, including the unrelated-pane negative assertion.
2. Replace idle affinity with active-only reconciliation and update the old
   idle-pane assertions in section 14. Preserve ticket affinity only while
   stages overlap or through immediate same-poll retagging.
3. Add the Herdr-hosted controller and process-start identity. Make the crash
   restart and PID-reuse tests green.
4. Move the pending assertions into section 14, add planted mutations for
   token filtering and supervisor restart, then run section 14 and the full
   suite before installation.
