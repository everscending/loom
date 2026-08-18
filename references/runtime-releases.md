# Immutable Loom runtime releases

These are human-run host controls. They do not merge branches, edit tickets,
restart lanes, or start a stopped build.

## `publish [--migrate] [git-ref]`

Run `scripts/tick.sh runtime publish [--migrate] [git-ref]` from the installed Loom Git
checkout. The default is committed `HEAD`. Refuse a dirty checkout. Publication
exports the exact committed tree, rejects symlinks and submodules, validates
every shell file and the full Loom suite, retains the commit objects needed to
verify it without the source checkout, then atomically selects the complete
read-only release for this repository. A failed validation leaves the selector
unchanged.

The full release suite shares heavyweight-host admission with product UI
pregates and browser probes. Publication waits before taking its publication
lock while product UI work is active, then resumes automatically after the
last claim releases. A queued UI reservation keeps product priority while the
build is running; a stopped build cannot drain it and may validate. While
validation runs, new UI work waits; API and focused work remain concurrent.
The same host-global boundary covers a direct no-argument `tick-test.sh` run,
even from a Loom worktree with no product `LOOM_HOME`; focused sections and
`--lint` do not take it. Runtime marks its nested full suite so that suite
reuses the outer claim instead of deadlocking on itself. Unreadable admission
state refuses validation instead of guessing that the host is idle.
The host-global admission plumbing lives under `~/.loom/host-admission` by
default, independent of any product or runtime worktree.

The first publication requires `/loom stop`, no live wave, no lane or deferred
launch metadata, and an unloaded scheduler. Each release carries `runtime-abi`;
an API change requires the same boundary and the explicit `--migrate` flag.
Rollback never crosses an API boundary.

Fresh human commands and scheduler heartbeats use the new release. A running
wave, lane, epilogue, or deferred handoff stays pinned to its creator release.
Live publication is allowed only while the host-state API remains compatible.

## `rollback`

Run `scripts/tick.sh runtime rollback`. It atomically swaps active and previous
for this repository. Running work is not killed or rewritten; the next fresh
heartbeat uses the rolled-back release.

## `runtime-status`

Run `scripts/tick.sh runtime status`. Report the selector, launcher, active and
previous release IDs, and every live lane or queued handoff pin. Runtime release
state is host plumbing under `~/.loom/runtime`; it never goes to the tracker.

Published releases are retained. Do not delete one while a lane or queued
handoff can still reference it.
