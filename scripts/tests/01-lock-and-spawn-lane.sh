#!/usr/bin/env bash
# the tick lock, detach, lane ids, per-ticket locks, scratch, workspace trust
#
# Section 01 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# 1a. Lock exclusion holds: second tick exits fast while first holds the lock,
#     and the kick it could not run is REMEMBERED rather than dropped (P1).
#     The note is cleared before the holder exits so this test does not also
#     trigger a re-tick — 1d owns that half.
LOOM_WAVE_CMD="sleep 1" "$TICK" tick >/dev/null 2>&1 &
first=$!; sleep 0.3
out=$(LOOM_WAVE_CMD="echo second-wave-ran" "$TICK" tick 2>&1)
case "$out" in *"wave already running"*) ok "lock: concurrent tick skipped";; *) bad "lock: concurrent tick ran ($out)";; esac
[ -f "$LOOM_HOME/tick.pending" ] \
    && ok "lock: the skipped kick left a pending note" \
    || bad "lock: the skipped kick vanished with no note"
rm -f "$LOOM_HOME/tick.pending"
wait "$first"

# 1b. Planted violation: with a DIFFERENT lock dir the exclusion must fail
#     (two waves overlap) — proving the shared lock is the guard.
LOOM_WAVE_CMD="sleep 0.8" LOOM_LOCK_DIR="$T/lockA" "$TICK" tick >/dev/null 2>&1 &
pa=$!; sleep 0.25
out=$(LOOM_WAVE_CMD="echo overlapped" LOOM_LOCK_DIR="$T/lockB" "$TICK" tick 2>&1)
case "$out" in *"wave already running"*) bad "lock-violation: still excluded without shared lock";; *) ok "lock-violation: overlap observed when lock removed";; esac
wait "$pa"

# 1c. Stale lock broken: dead-owner lock does not wedge future ticks.
mkdir -p "$LOOM_HOME/tick.lock.d"; echo 999999 > "$LOOM_HOME/tick.lock.d/pid"
out=$(LOOM_WAVE_CMD="echo revived" "$TICK" tick 2>&1)
case "$out" in *"running wave"*) ok "lock: stale (dead-owner) lock broken";; *) bad "lock: stale lock wedged the tick ($out)";; esac

# 1d. P1: kicks that land mid-wave are replayed, and COALESCED. Build 2 ended on
#     the opposite behaviour — a gate exited at 23:36:03 while W13 held the lock,
#     the kick was discarded, and the loop never ran again, stranding a ticket in
#     `merge-queue`. Three kicks land during one wave here; the correct answer is
#     exactly one extra wave, not three and not zero.
#     Counting waves is the assertion: the wave command appends a line, so the
#     file length IS the number of waves that ran.
_wait_waves() { # <file> <n> — poll until the file has n lines, or give up
    local i; for i in $(seq 1 80); do
        [ "$(wc -l < "$1" | tr -d ' ')" -ge "$2" ] && return 0; sleep 0.1
    done; return 1
}
rm -rf "$LOOM_HOME/tick.lock.d"; rm -f "$LOOM_HOME/tick.pending"
WAVES="$T/waves.txt"; : > "$WAVES"
# The prefix form exports for the holder AND its children, so the re-tick the
# holder fires on exit inherits the same counting command.
LOOM_WAVE_CMD="sh -c 'echo w >> $WAVES; sleep 0.5'" "$TICK" tick >/dev/null 2>&1 &
holder=$!; sleep 0.15
for _ in 1 2 3; do "$TICK" tick >/dev/null 2>&1; done
wait "$holder"
_wait_waves "$WAVES" 2 || true
sleep 1                        # a spurious third wave would have landed by now
n=$(wc -l < "$WAVES" | tr -d ' ')
[ "$n" = "2" ] \
    && ok "pending: three mid-wave kicks replayed as exactly one re-tick" \
    || bad "pending: expected 2 waves (original + one replay), saw $n"

# 1e. Planted violation: point the skipped ticks' note somewhere the holder never
#     looks. That is precisely the old drop-on-the-floor path, and the loop must
#     be seen dying after a single wave — no replay, no second line.
rm -rf "$LOOM_HOME/tick.lock.d"; rm -f "$LOOM_HOME/tick.pending"
: > "$WAVES"
LOOM_WAVE_CMD="sh -c 'echo w >> $WAVES; sleep 0.5'" "$TICK" tick >/dev/null 2>&1 &
holder=$!; sleep 0.15
for _ in 1 2 3; do LOOM_PENDING_FILE="$T/note-nobody-reads" "$TICK" tick >/dev/null 2>&1; done
wait "$holder"; sleep 1
n=$(wc -l < "$WAVES" | tr -d ' ')
[ "$n" = "1" ] \
    && ok "pending-violation: an unrecorded kick stops the loop dead after one wave" \
    || bad "pending-violation: loop advanced anyway ($n waves) — the note is not the guard"
rm -rf "$LOOM_HOME/tick.lock.d"; rm -f "$LOOM_HOME/tick.pending"

# 2. Detach: spawn-lane returns while the child persists; pid file + log exist.
"$TICK" spawn-lane impl-1 -- sleep 5 >/dev/null
pid=$(cat "$LOOM_HOME/lanes/impl-1.pid" 2>/dev/null || echo "")
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -f "$LOOM_HOME/logs/lane-impl-1.log" ]; then
    ok "detach: child alive after spawn returns, pid file + log present"
else
    bad "detach: child/pid/log missing"
fi
kill "$pid" 2>/dev/null

# 3. Dead lane detected (planted: child exits immediately).
"$TICK" spawn-lane impl-2 -- true >/dev/null; sleep 0.2
st=$("$TICK" lane-status | awk '$1=="impl-2"{print $3}')
[ "$st" = "dead" ] && ok "liveness: dead child reported dead" || bad "liveness: dead child reported '$st'"

# 4. Staleness is output-based, never elapsed-total: an alive, recently-noisy
#    lane is 'running' even under a zero-minute window only if log is fresh;
#    with the window planted to 0 and the log backdated, it must go 'stale'.
"$TICK" spawn-lane impl-3 -- sleep 20 >/dev/null
st=$("$TICK" lane-status | awk '$1=="impl-3"{print $3}')
[ "$st" = "running" ] && ok "staleness: fresh-output lane is running" || bad "staleness: fresh lane reported '$st'"
sed -i.bak 's/heartbeat_stale_minutes: 30/heartbeat_stale_minutes: 0/' "$LOOM_REPO/.loom.yml"
touch -t 202001010000 "$LOOM_HOME/logs/lane-impl-3.log"
st=$("$TICK" lane-status | awk '$1=="impl-3"{print $3}')
[ "$st" = "stale" ] && ok "staleness-violation: silent-but-alive lane goes stale" || bad "staleness: silent lane reported '$st'"
sed -i.bak 's/heartbeat_stale_minutes: 0/heartbeat_stale_minutes: 30/' "$LOOM_REPO/.loom.yml"
kill "$(cat "$LOOM_HOME/lanes/impl-3.pid")" 2>/dev/null

# 4b. Self-trigger is the DEFAULT (P2), so a plain spawn advances the loop with
#     no flag at all. It used to be opt-in, and W4 of build 2 said what that
#     cost: "I spawned both without --on-done-tick… So nothing advances on its
#     own" — 12m44s of dead build until a human ticked it by hand.
#     LOOM_WAVE_CMD is a marker so no real claude session is invoked; the lock
#     dir is cleared so the triggered tick can acquire it.
rm -rf "$LOOM_HOME/tick.lock.d"
MARK="$T/self-trigger-fired"
LOOM_WAVE_CMD="touch $MARK" "$TICK" spawn-lane impl-11 -- true >/dev/null
for _ in $(seq 1 40); do [ -f "$MARK" ] && break; sleep 0.1; done
[ -f "$MARK" ] && ok "self-trigger: a plain lane fires the next wave, no flag needed" || bad "self-trigger: no wave fired after lane exit"
rm -rf "$LOOM_HOME/tick.lock.d"

# 4b2. Planted violation: --no-tick is the deliberate opt-out, and it must
#      actually suppress the trigger — otherwise the default has no off switch
#      and 4b would pass for a lane that always ticks regardless of its flags.
MARK_NO="$T/no-tick-fired"
LOOM_WAVE_CMD="touch $MARK_NO" "$TICK" spawn-lane impl-16 --no-tick -- true >/dev/null
sleep 1.5
[ -f "$MARK_NO" ] && bad "no-tick: the opt-out did not suppress the trigger" \
                  || ok "no-tick-violation: --no-tick lane exits without advancing the loop"
rm -rf "$LOOM_HOME/tick.lock.d"

# 4b3. --on-done-tick still parses (now a no-op), so a caller written against the
#      old opt-in contract is not silently broken.
MARK_LEGACY="$T/legacy-flag-fired"
LOOM_WAVE_CMD="touch $MARK_LEGACY" "$TICK" spawn-lane impl-17 --on-done-tick -- true >/dev/null
for _ in $(seq 1 40); do [ -f "$MARK_LEGACY" ] && break; sleep 0.1; done
[ -f "$MARK_LEGACY" ] && ok "self-trigger: the legacy --on-done-tick flag still works" \
                      || bad "self-trigger: --on-done-tick broke when the default flipped"
rm -rf "$LOOM_HOME/tick.lock.d"

# 4c. Order-tolerance: --on-done-tick BEFORE the id (the build-2 wave-1 form)
#     must now work, not be swallowed as the id.
rm -rf "$LOOM_HOME/tick.lock.d"
MARK2="$T/self-trigger-fired-2"
LOOM_WAVE_CMD="touch $MARK2" "$TICK" spawn-lane --on-done-tick impl-12 -- true >/dev/null 2>&1
for _ in $(seq 1 40); do [ -f "$MARK2" ] && break; sleep 0.1; done
[ -f "$MARK2" ] && ok "spawn-lane: flag-before-id order works" || bad "spawn-lane: flag-before-id was swallowed (regression)"
rm -rf "$LOOM_HOME/tick.lock.d"

# 4d. Loud failures: missing id and missing command must abort non-zero, not spawn.
if "$TICK" spawn-lane --on-done-tick -- true >/dev/null 2>&1; then bad "spawn-lane: missing id did NOT fail"; else ok "spawn-lane: missing id fails loudly"; fi
if "$TICK" spawn-lane impl-13 >/dev/null 2>&1; then bad "spawn-lane: missing command did NOT fail"; else ok "spawn-lane: missing command fails loudly"; fi

# 4e2. Structured lane ids (P10). The observed run used `12`, `gate12`,
#      `gate-12-r2`, `impl-14` and `probe-e4` interchangeably, so no lane's kind
#      could be derived and every lane counted against max_lanes. spawn-lane is
#      the only place an id is created, so it is where the shape is enforced.
for bad_id in 12 gate12 lane_14 impl impl- xyz-1; do
    if "$TICK" spawn-lane "$bad_id" -- true >/dev/null 2>&1; then
        bad "lane-id: ad hoc id '$bad_id' was accepted"; break
    fi
done
[ -n "${bad_id:-}" ] && ! [ -f "$LOOM_HOME/lanes/12.pid" ] \
    && ok "lane-id: ad hoc ids are refused, so type is always derivable" \
    || bad "lane-id: an ad hoc id got through"
# A lane id with a SPACE is the dangerous shape, and the type globs end in `*`
# so they accepted it. `probe-<epic>` with a real epic title ("Ledger core")
# produced `probe-Ledger core`; `lane-status` is space-delimited, so the
# snapshot parsed that lane as {id: "probe-Ledger", pid: "core", state: "<pid>"}
# — and a state that is never "dead" counts as live for the rest of the build.
if "$TICK" spawn-lane "probe-Ledger core" --no-tick -- true >/dev/null 2>&1; then
    bad "lane-id: an id containing a space was accepted"
else
    ok "lane-id: an id containing a space is refused at spawn"
fi
[ -e "$LOOM_HOME/lanes/probe-Ledger core.pid" ] \
    && bad "lane-id-violation: the spaced id still produced a pid file" \
    || ok "lane-id-violation: no lane state was written for the spaced id"
"$TICK" spawn-lane probe-ledger-core --no-tick -- true >/dev/null 2>&1 \
    && ok "lane-id: the slugified form is accepted" \
    || bad "lane-id: slugified probe id was refused"
for good_id in impl-7 gate-7 gate-7-r2 merge-7 probe-e11; do
    "$TICK" spawn-lane "$good_id" -- true >/dev/null 2>&1 \
        || { bad "lane-id: structured id '$good_id' was refused"; break; }
done
sleep 0.3
types=$("$TICK" lane-status | awk '$1 ~ /-7$|-7-r2$|^probe-e11$/{print $4}' | sort -u | tr '\n' ' ')
[ "$types" = "gate impl merge probe " ] \
    && ok "lane-status: type column derived from the id (all four kinds)" \
    || bad "lane-status: type column wrong ('$types')"
# State stays at $3 — appending the column must not move it under existing readers.
st=$("$TICK" lane-status | awk '$1=="impl-7"{print $3}')
[ "$st" = "dead" ] && ok "lane-status: state stays in column 3 for existing readers" \
    || bad "lane-status: state column moved ('$st')"
# P52: `turns` lands at the END (column 6) so `rc` at $5 does not move under
# existing readers — impl-7 ran `true` and already exited 0, which is the
# existing rc contract; only the trailing column is new.
rc5=$("$TICK" lane-status | awk '$1=="impl-7"{print $5}')
[ "$rc5" = "0" ] && ok "lane-status: rc stays in column 5 with turns appended" \
    || bad "lane-status: rc column moved ('$rc5')"
turns0=$("$TICK" lane-status | awk '$1=="impl-7"{print $6}')
[ "$turns0" = "-" ] && ok "lane-status: turns column is '-' before any progress stamp" \
    || bad "lane-status: turns column wrong before stamping ('$turns0')"
printf '42\n' > "$LOOM_HOME/lanes/impl-7.progress"
turns1=$("$TICK" lane-status | awk '$1=="impl-7"{print $6}')
[ "$turns1" = "42" ] && ok "lane-status: turns column reads the same stamp staleness reads" \
    || bad "lane-status: turns column did not read the progress stamp ('$turns1')"
# P55: `cost` lands after `turns` (column 7), priced from the session log's
# own `message.usage` — 1M haiku input tokens at $1.00/MTok is exactly $1,
# chosen to sidestep float-formatting noise in the assertion.
mkdir -p "$LOOM_HOME/logs"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":1000000,"output_tokens":0}}}' \
    > "$LOOM_HOME/logs/lane-impl-7.jsonl"
cost7=$("$TICK" lane-status | awk '$1=="impl-7"{print $7}')
[ "$cost7" = "1" ] && ok "lane-status: cost column prices the session log by its own model" \
    || bad "lane-status: cost column wrong ('$cost7', want 1)"
rm -f "$LOOM_HOME/logs/lane-impl-7.jsonl"
for g in impl-7 gate-7 gate-7-r2 merge-7 probe-e11; do "$TICK" clear-lane "$g" >/dev/null; done

# 4e3. Merge lock (P5). Merging is the only step needing single-writer
#      semantics; it used to borrow the tick lock, so harvest/gate/fill queued
#      behind every rebase-and-merge. Its own lock means one merge at a time
#      AND waves that keep scheduling around it.
rm -rf "$LOOM_HOME/tick.lock.d" "$LOOM_HOME/merge.lock.d"
"$TICK" spawn-lane merge-71 --merge-lock -- sleep 20 >/dev/null
if "$TICK" spawn-lane merge-72 --merge-lock -- true >/dev/null 2>&1; then
    bad "merge-lock: a second merge lane started while one held the lock"
else
    [ -f "$LOOM_HOME/lanes/merge-72.pid" ] \
        && bad "merge-lock: refused but left a pid file" \
        || ok "merge-lock: a second merge waits, and leaves no lane behind"
fi
# THE point of the split: the tick lock is free, so scheduling continues.
out=$(LOOM_WAVE_CMD="echo scheduled-during-merge" "$TICK" tick 2>&1)
case "$out" in *"running wave"*) ok "merge-lock: a wave still ticks while a merge holds its lock";;
    *) bad "merge-lock: merge blocked the whole scheduler ($out)";; esac
rm -rf "$LOOM_HOME/tick.lock.d"
# Planted violation: sharing one lock is what the old code did — prove it stalls.
LOOM_LOCK_DIR="$LOOM_HOME/merge.lock.d" LOOM_WAVE_CMD="echo shared-lock-wave" \
    "$TICK" tick >"$T/shared.out" 2>&1 || true
case "$(cat "$T/shared.out")" in *"wave already running"*) ok "merge-lock-violation: one shared lock stalls the wave (the old behaviour)";;
    *) bad "merge-lock-violation: shared lock did not stall ($(cat "$T/shared.out"))";; esac
# That stalled tick left a pending note (P1); drop it so no later test inherits
# a re-tick it did not ask for.
rm -f "$LOOM_HOME/tick.pending"
# The lane releases on exit, and a merge lane that is killed outright leaves a
# breakable lock rather than a permanent one.
kill "$(cat "$LOOM_HOME/lanes/merge-71.pid")" 2>/dev/null; sleep 0.3
"$TICK" clear-lane merge-71 >/dev/null
if "$TICK" spawn-lane merge-73 --merge-lock -- true >/dev/null 2>&1; then
    ok "merge-lock: a killed merge lane's lock is broken by the next merge"
else
    bad "merge-lock: dead owner's lock wedged the queue permanently"
fi
sleep 0.3
[ -d "$LOOM_HOME/merge.lock.d" ] \
    && bad "merge-lock: lock outlived the lane that finished" \
    || ok "merge-lock: released when the lane's command exits"
"$TICK" clear-lane merge-73 >/dev/null
rm -rf "$LOOM_HOME/tick.lock.d"

# 4e3b. Guard order pin (P75): everything destructive happens below the last
#       guard that can refuse — now a function boundary, not a comment. A
#       spawn that loses the merge-lock reservation must leave the PREVIOUS
#       run's transcript and exit code exactly as it found them: rotating the
#       log and clearing `<id>.rc` before the reservation once destroyed
#       harvest data for a lane that was never replaced.
rm -rf "$LOOM_HOME/tick.lock.d" "$LOOM_HOME/merge.lock.d"
"$TICK" spawn-lane merge-74 --merge-lock --no-tick -- sleep 20 >/dev/null
printf 'previous transcript\n' > "$LOOM_HOME/logs/lane-merge-75.log"
printf '7\n' > "$LOOM_HOME/lanes/merge-75.rc"
"$TICK" spawn-lane merge-75 --merge-lock --no-tick -- true >/dev/null 2>&1 \
    && bad "spawn-order: merge-75 spawned while merge-74 held the lock"
[ "$(cat "$LOOM_HOME/logs/lane-merge-75.log" 2>/dev/null)" = "previous transcript" ] \
    && [ "$(cat "$LOOM_HOME/lanes/merge-75.rc" 2>/dev/null)" = "7" ] \
    && ok "spawn-order: a spawn refused at the merge lock leaves the previous run's log and rc untouched" \
    || bad "spawn-order: the refused spawn destroyed the previous run's transcript or exit code"
# Planted violation: the pre-boundary order — rotate, truncate, clear rc, THEN
# reserve — re-run by hand. The assertion above must see the destruction that
# order causes, or the pin is vacuous.
mv "$LOOM_HOME/logs/lane-merge-75.log" "$LOOM_HOME/logs/lane-merge-75-rotated.log"
: > "$LOOM_HOME/logs/lane-merge-75.log"
rm -f "$LOOM_HOME/lanes/merge-75.rc"
[ "$(cat "$LOOM_HOME/logs/lane-merge-75.log" 2>/dev/null)" = "previous transcript" ] \
    && [ "$(cat "$LOOM_HOME/lanes/merge-75.rc" 2>/dev/null)" = "7" ] \
    && bad "spawn-order-violation: the pin missed a destroyed transcript and rc" \
    || ok "spawn-order-violation: destructive-first ordering is exactly what the pin catches"
kill "$(cat "$LOOM_HOME/lanes/merge-74.pid")" 2>/dev/null; sleep 0.3
"$TICK" clear-lane merge-74 >/dev/null
rm -f "$LOOM_HOME/logs/lane-merge-75.log" "$LOOM_HOME/logs/lane-merge-75-rotated.log"
rm -rf "$LOOM_HOME/merge.lock.d" "$LOOM_HOME/tick.lock.d"

# 4e4. Gate lock (P67). The impl->gate chain handoff and the scheduler's own
#      gate step can both spawn a gate for the same ticket at the same HEAD —
#      ai-workout build-1: gate-14 and gate-14-r2 live at once, #41 gated
#      twice on one SHA, #8 gated twice within a minute. Same mkdir-atomic,
#      dead-owner-breakable shape as the merge lock, but keyed per
#      ticket+commit so unrelated gates never queue behind each other.
rm -rf "$LOOM_HOME/tick.lock.d" "$LOOM_HOME/gate.lock.d"
GL="$T/gatelock"; mkdir -p "$GL/repo"
seed_tracker_decl "$GL/repo"
git init -q "$GL/repo" 2>/dev/null
git -C "$GL/repo" config user.email t@t; git -C "$GL/repo" config user.name t
: > "$GL/repo/f"; git -C "$GL/repo" add f >/dev/null 2>&1
git -C "$GL/repo" commit -qm init >/dev/null 2>&1

"$TICK" spawn-lane gate-14 --no-tick --cwd "$GL/repo" -- sleep 20 >/dev/null
if "$TICK" spawn-lane gate-14-r2 --no-tick --cwd "$GL/repo" -- true >/dev/null 2>&1; then
    bad "gate-lock: a second gate lane started on the same ticket+HEAD (P67 reproduced)"
else
    [ -f "$LOOM_HOME/lanes/gate-14-r2.pid" ] \
        && bad "gate-lock: refused but left a pid file" \
        || ok "gate-lock: a duplicate gate on the same ticket+HEAD is refused, no lane left behind"
fi

# Different ticket, same HEAD: proves the lock is per-TICKET, not one shared
# dir like the merge lock — unrelated gates must never queue behind each other.
"$TICK" spawn-lane gate-15 --no-tick --cwd "$GL/repo" -- true >/dev/null 2>&1 \
    && ok "gate-lock: a different ticket at the same HEAD is unaffected" \
    || bad "gate-lock: an unrelated ticket queued behind another ticket's lock"
"$TICK" clear-lane gate-15 >/dev/null 2>&1

# Same ticket, a NEW commit: proves the lock is per-COMMIT, not a standing
# hold on the ticket that would wedge every later round.
echo more > "$GL/repo/f"; git -C "$GL/repo" add f >/dev/null 2>&1
git -C "$GL/repo" commit -qm second >/dev/null 2>&1
"$TICK" spawn-lane gate-14-r3 --no-tick --cwd "$GL/repo" -- true >/dev/null 2>&1 \
    && ok "gate-lock: the same ticket at a NEW head is not blocked by the old commit's lock" \
    || bad "gate-lock: a stale ticket+HEAD key wedged the next round"
"$TICK" clear-lane gate-14-r3 >/dev/null 2>&1

# Dead owner: a killed gate lane's lock is broken by the next attempt — one
# skipped gate, never a permanently wedged ticket.
kill "$(cat "$LOOM_HOME/lanes/gate-14.pid")" 2>/dev/null; sleep 0.3
"$TICK" clear-lane gate-14 >/dev/null
if "$TICK" spawn-lane gate-14-r4 --no-tick --cwd "$GL/repo" -- true >/dev/null 2>&1; then
    ok "gate-lock: a killed gate lane's lock is broken by the next attempt"
else
    bad "gate-lock: dead owner's lock wedged the ticket permanently"
fi
sleep 0.3
"$TICK" clear-lane gate-14-r4 >/dev/null 2>&1
rm -rf "$LOOM_HOME/gate.lock.d" "$LOOM_HOME/tick.lock.d"

# Released on exit, no stamp race: an instant gate lane must not fail its own
# spawn, and the very next spawn on the same ticket+HEAD must find the lock
# genuinely free (mirrors the merge-lock's own instant-lane case).
"$TICK" spawn-lane gate-16 --no-tick --cwd "$GL/repo" -- true >/dev/null 2>&1 \
    && ok "gate-lock: an instant gate lane spawns cleanly (no stamp race)" \
    || bad "gate-lock: spawn failed because the lane released before the stamp"
sleep 0.4
"$TICK" spawn-lane gate-16-r2 --no-tick --cwd "$GL/repo" -- true >/dev/null 2>&1 \
    && ok "gate-lock-violation: the released lock is genuinely free for the next round" \
    || bad "gate-lock-violation: lock left behind by an instant lane"
"$TICK" clear-lane gate-16 >/dev/null 2>&1; "$TICK" clear-lane gate-16-r2 >/dev/null 2>&1
rm -rf "$LOOM_HOME/gate.lock.d"

# A non-git cwd has no HEAD to key on, so a same-ticket respawn must never be
# blocked by it — the graceful-skip path every plain-directory (WT/GWT) gate
# fixture elsewhere in this suite already relies on.
mkdir -p "$GL/plain"
"$TICK" spawn-lane gate-17 --no-tick --cwd "$GL/plain" -- sleep 5 >/dev/null
"$TICK" spawn-lane gate-17-r2 --no-tick --cwd "$GL/plain" -- true >/dev/null 2>&1 \
    && ok "gate-lock: a non-git cwd has no HEAD to key on, so it never blocks" \
    || bad "gate-lock: a directory with no HEAD wrongly blocked a spawn"
kill "$(cat "$LOOM_HOME/lanes/gate-17.pid" 2>/dev/null)" 2>/dev/null
"$TICK" clear-lane gate-17 >/dev/null 2>&1; "$TICK" clear-lane gate-17-r2 >/dev/null 2>&1
rm -rf "$LOOM_HOME/tick.lock.d"

# 4f. A lane runs where its work is: --cwd puts it in the worktree, which is
#     what removes the need for a `cd` allow rule (P4). Planted violation:
#     the same spawn WITHOUT the flag must land in the repo root instead.
WT="$T/worktree-a"; mkdir -p "$WT"
"$TICK" spawn-lane gate-21 --cwd "$WT" -- pwd >/dev/null; sleep 0.5
grep -q "^$WT$" "$LOOM_HOME/logs/lane-gate-21.log" \
    && ok "spawn-lane: --cwd starts the lane inside its worktree" \
    || bad "spawn-lane: --cwd ignored (log: $(cat "$LOOM_HOME/logs/lane-gate-21.log"))"
"$TICK" spawn-lane gate-22 -- pwd >/dev/null; sleep 0.5
grep -q "^$LOOM_REPO$" "$LOOM_HOME/logs/lane-gate-22.log" \
    && ok "spawn-lane-violation: without --cwd the lane is in the repo root" \
    || bad "spawn-lane: default cwd is not the repo root"

# 4f2. D-TICK-19: the scripts dir (home of lane.sh/tick.sh) must be on PATH
#      inside a lane, so a handoff can say `lane.sh reconcile` by bare name
#      instead of retyping the absolute path. Assert both the PATH entry and
#      that `command -v lane.sh` actually resolves from inside the lane.
SCRIPTS_DIR="$(dirname "$TICK")"
"$TICK" spawn-lane gate-22b -- sh -c 'echo "$PATH"' >/dev/null; sleep 0.5
case "$(cat "$LOOM_HOME/logs/lane-gate-22b.log" 2>/dev/null)" in
    "$SCRIPTS_DIR":*) ok "spawn-lane: PATH inside a lane leads with the scripts dir" ;;
    *) bad "spawn-lane: PATH inside a lane has no scripts dir (D-TICK-19) ($(cat "$LOOM_HOME/logs/lane-gate-22b.log" 2>/dev/null))" ;;
esac
"$TICK" spawn-lane gate-22c -- sh -c 'command -v lane.sh' >/dev/null; sleep 0.5
if grep -q "^$SCRIPTS_DIR/lane.sh$" "$LOOM_HOME/logs/lane-gate-22c.log" 2>/dev/null; then
    ok "spawn-lane: lane.sh resolves by bare name from inside a lane"
else
    bad "spawn-lane: lane.sh does NOT resolve by bare name inside a lane (D-TICK-19) (log: $(cat "$LOOM_HOME/logs/lane-gate-22c.log" 2>/dev/null))"
fi

# 4g. Flag order-tolerance extends to --cwd, and it composes with self-trigger.
rm -rf "$LOOM_HOME/tick.lock.d"
MARK3="$T/self-trigger-fired-3"
LOOM_WAVE_CMD="touch $MARK3" "$TICK" spawn-lane --cwd "$WT" gate-23 --on-done-tick -- pwd >/dev/null
for _ in $(seq 1 40); do [ -f "$MARK3" ] && break; sleep 0.1; done
if [ -f "$MARK3" ] && grep -q "^$WT$" "$LOOM_HOME/logs/lane-gate-23.log"; then
    ok "spawn-lane: --cwd before the id composes with --on-done-tick"
else
    bad "spawn-lane: --cwd + --on-done-tick lost the cwd or the trigger"
fi
rm -rf "$LOOM_HOME/tick.lock.d"

# 4h. A bad worktree path must abort at spawn — never become a lane that dies
#     on its first command and reads as an ordinary crash.
if "$TICK" spawn-lane gate-24 --cwd "$T/no-such-worktree" -- true >/dev/null 2>&1; then
    bad "spawn-lane: nonexistent --cwd did NOT fail"
else
    [ -f "$LOOM_HOME/lanes/gate-24.pid" ] \
        && bad "spawn-lane: nonexistent --cwd failed but left a pid file" \
        || ok "spawn-lane: nonexistent --cwd fails loudly, spawns nothing"
fi
if "$TICK" spawn-lane gate-25 --cwd >/dev/null 2>&1; then bad "spawn-lane: --cwd without a value did NOT fail"; else ok "spawn-lane: --cwd without a value fails loudly"; fi

# 4i. Scratch (P17). Every session is handed its own fresh, empty, writable
#     directory — no session may run `mkdir`, so tick.sh must create it.
"$TICK" spawn-lane probe-e1 --cwd "$WT" -- sh -c 'echo "$LOOM_SCRATCH" > "$LOOM_SCRATCH/where"' >/dev/null
sleep 0.5
SC1=$(cat "$LOOM_HOME"/scratch/lane-probe-e1-*/where 2>/dev/null | head -1)
if [ -n "$SC1" ] && [ -d "$SC1" ]; then
    ok "scratch: a lane gets a writable \$LOOM_SCRATCH of its own"
else
    bad "scratch: lane had no usable \$LOOM_SCRATCH"
fi

# 4i2. The P17 bug itself: a second run under the same lane id must NOT see the
#      first run's files. A fixed path is what let a stale note be posted to the
#      wrong ticket, so re-running an id has to land somewhere new and empty.
# The listing is written OUTSIDE the scratch dir: a redirect into it would
# create the very file the check is looking for.
"$TICK" spawn-lane probe-e1 --cwd "$WT" -- sh -c 'ls "$LOOM_SCRATCH" > sc-listing; echo "$LOOM_SCRATCH" > "$LOOM_SCRATCH/where2"' >/dev/null
sleep 0.5
SC2=$(cat "$LOOM_HOME"/scratch/lane-probe-e1-*/where2 2>/dev/null | head -1)
if [ -n "$SC2" ] && [ "$SC2" != "$SC1" ]; then
    ok "scratch: re-running a lane id gets a different directory"
else
    bad "scratch: lane id reused the same directory ($SC1 vs $SC2)"
fi
if [ -s "$WT/sc-listing" ]; then
    bad "scratch-violation: a fresh lane saw leftover files ($(cat "$WT/sc-listing"))"
else
    ok "scratch-violation: a fresh lane starts empty — no stale file to pick up"
fi

# 4i3. Waves get the same treatment, and two waves never share a directory.
rm -rf "$LOOM_HOME/tick.lock.d"
LOOM_WAVE_CMD='sh -c "echo $LOOM_SCRATCH > $LOOM_SCRATCH/wave-marker"' "$TICK" tick >/dev/null 2>&1
rm -rf "$LOOM_HOME/tick.lock.d"
LOOM_WAVE_CMD='sh -c "echo $LOOM_SCRATCH > $LOOM_SCRATCH/wave-marker"' "$TICK" tick >/dev/null 2>&1
rm -rf "$LOOM_HOME/tick.lock.d"
WAVES=$(cat "$LOOM_HOME"/scratch/wave-*/wave-marker 2>/dev/null | sort -u | wc -l | tr -d ' ')
[ "$WAVES" -ge 2 ] && ok "scratch: consecutive waves get separate directories" \
    || bad "scratch: two waves shared a scratch directory"

# 4i4. Unique-per-session grows without bound and no session may run `rm`, so
#      the scheduler prunes. Old goes, current stays.
mkdir -p "$LOOM_HOME/scratch/wave-ancient"
touch -t 202001010000 "$LOOM_HOME/scratch/wave-ancient"
FRESH=$(ls -d "$LOOM_HOME"/scratch/wave-2* 2>/dev/null | head -1)
rm -rf "$LOOM_HOME/tick.lock.d"
LOOM_WAVE_CMD="true" "$TICK" tick >/dev/null 2>&1
rm -rf "$LOOM_HOME/tick.lock.d"
if [ ! -d "$LOOM_HOME/scratch/wave-ancient" ] && [ -d "$FRESH" ]; then
    ok "scratch: prune removes stale directories, keeps recent ones"
else
    bad "scratch: prune removed the wrong thing (ancient gone? $([ -d "$LOOM_HOME/scratch/wave-ancient" ] && echo no || echo yes); fresh kept? $([ -d "$FRESH" ] && echo yes || echo no))"
fi

# 4i5. Planted violation: a guarded root must delete nothing. With the guard
#      removed this is the line that would wipe a home directory.
GUARD=$(SCRATCH_ROOT="" LOOM_HOME="$LOOM_HOME" bash -c '
    SCRATCH_ROOT=""; case "$SCRATCH_ROOT" in ""|"/"|"$HOME") echo guarded ;; *) echo unguarded ;; esac')
[ "$GUARD" = "guarded" ] && ok "scratch: empty/root scratch root is refused by the prune guard" \
    || bad "scratch: prune guard does not cover an empty root"

# 4j. Workspace trust (P16). The cascade holds — gate-21 above spawned from a
#     worktree with no entry of its own, covered by $T. Planted violation: point
#     the trust file somewhere that grants nothing and the same spawn must abort
#     before creating a lane, rather than producing one that is denied
#     everything and reads as a normal crash.
printf '{"projects":{}}\n' > "$T/untrusted.json"
if LOOM_TRUST_FILE="$T/untrusted.json" "$TICK" spawn-lane impl-41 --cwd "$WT" -- true >/dev/null 2>&1; then
    bad "trust-violation: untrusted workspace still spawned a lane"
else
    [ -f "$LOOM_HOME/lanes/impl-41.pid" ] \
        && bad "trust: spawn failed but left a pid file" \
        || ok "trust-violation: untrusted workspace aborts the spawn, spawns nothing"
fi
# The refusal must be actionable: name the ancestor that would fix it.
out=$(LOOM_TRUST_FILE="$T/untrusted.json" "$TICK" spawn-lane impl-42 --cwd "$WT" -- true 2>&1 || true)
case "$out" in *"$T"*trust*|*trust*"$T"*) ok "trust: refusal names the ancestor to trust";;
    *) bad "trust: refusal is not actionable ($out)";; esac
# A missing trust file is not tacit permission.
if LOOM_TRUST_FILE="$T/no-such-file.json" "$TICK" spawn-lane impl-43 --cwd "$WT" -- true >/dev/null 2>&1; then
    bad "trust: missing trust file was treated as trusted"
else
    ok "trust: missing trust file is not tacit permission"
fi
# Trust is explicit: an entry set to false must not pass as an entry.
printf '{"projects":{"%s":{"hasTrustDialogAccepted":false}}}\n' "$T" > "$T/denied.json"
if LOOM_TRUST_FILE="$T/denied.json" "$TICK" spawn-lane impl-44 --cwd "$WT" -- true >/dev/null 2>&1; then
    bad "trust: hasTrustDialogAccepted=false was accepted"
else
    ok "trust: an explicitly untrusted entry is refused"
fi
# The nearest entry wins: a declined worktree is refused even under a trusted
# parent — someone answered that dialog `no` on purpose.
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true},"%s":{"hasTrustDialogAccepted":false}}}\n' \
    "$T" "$WT" > "$T/leaf-denied.json"
if LOOM_TRUST_FILE="$T/leaf-denied.json" "$TICK" spawn-lane impl-45 --cwd "$WT" -- true >/dev/null 2>&1; then
    bad "trust: a declined worktree was rescued by its trusted parent"
else
    ok "trust: nearest entry wins — declined worktree refused under a trusted parent"
fi

# 4j-2. P30: the guard must ask the GIT REPO's question, not just the filesystem's.
#     A lane worktree is a SIBLING of the repo (SKILL.md step 4), so walking its
#     filesystem ancestors reaches the trusted parent without ever passing through
#     the repo root — while Claude Code resolves trust through the git repo and
#     ignores the allowlist. Build-1 paid 47m43s of blocked ticket time for the gap:
#     46 spawns passed, every one of them allowlist-blind.
#     The fixture is the real shape: trusted parent, DENIED repo root, and a linked
#     worktree beside the repo with no entry of its own.
#     PHYSICAL paths throughout: `git worktree list` resolves symlinks and mktemp
#     hands out /var/... which is really /private/var/..., so a fixture keyed the
#     logical way tests the mismatch case instead of the one meant here (that case
#     gets its own test below).
mkdir -p "$T/p30"; TR=$(cd "$T/p30" && pwd -P)
git init -q "$TR/repo" 2>/dev/null
git -C "$TR/repo" config user.email t@t; git -C "$TR/repo" config user.name t
: > "$TR/repo/f"; git -C "$TR/repo" add f >/dev/null 2>&1
git -C "$TR/repo" commit -qm init >/dev/null 2>&1
git -C "$TR/repo" worktree add -q "$TR/repo-wt-1" -b wt1 >/dev/null 2>&1
if [ -d "$TR/repo-wt-1" ]; then
    printf '{"projects":{"%s":{"hasTrustDialogAccepted":true},"%s":{"hasTrustDialogAccepted":false}}}\n' \
        "$TR" "$TR/repo" > "$TR/root-denied.json"
    # The worktree itself has no entry and a trusted parent — the OLD guard passed
    # here, which is exactly the bug.
    if LOOM_TRUST_FILE="$TR/root-denied.json" "$TICK" spawn-lane impl-46 --cwd "$TR/repo-wt-1" -- true >/dev/null 2>&1; then
        bad "trust-violation (P30): sibling worktree of an untrusted repo still spawned a lane"
    else
        [ -f "$LOOM_HOME/lanes/impl-46.pid" ] \
            && bad "trust (P30): spawn failed but left a pid file" \
            || ok "trust-violation (P30): untrusted REPO ROOT refuses the lane, not the 77th minute"
    fi
    # Actionable means naming the repo root — the worktree path is not what the
    # human must accept, and the old message named only the cwd.
    out=$(LOOM_TRUST_FILE="$TR/root-denied.json" "$TICK" spawn-lane impl-47 --cwd "$TR/repo-wt-1" -- true 2>&1 || true)
    case "$out" in *"$TR/repo'"*|*"$TR/repo "*)
        ok "trust (P30): refusal names the repo root, the path the human must accept" ;;
        *) bad "trust (P30): refusal does not name the repo root ($out)" ;; esac
    # The falsification criterion from the proposal: a tightened guard that refuses
    # lanes which would have worked is worse than the gap it closes. A repo root
    # with NO entry of its own must still cascade from its trusted parent.
    printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$TR" > "$TR/root-absent.json"
    if LOOM_TRUST_FILE="$TR/root-absent.json" "$TICK" spawn-lane impl-48 --cwd "$TR/repo-wt-1" --no-tick -- true >/dev/null 2>&1; then
        ok "trust (P30): a repo root with no entry still cascades — no false refusal"
    else
        bad "trust (P30): FALSE REFUSAL — repo root without its own entry was refused"
    fi
    "$TICK" clear-lane impl-48 >/dev/null 2>&1 || true
    # The verb answers the same question, and never writes the trust file.
    before=$(shasum "$TR/root-denied.json" | cut -d' ' -f1)
    LOOM_TRUST_FILE="$TR/root-denied.json" LOOM_REPO="$TR/repo" "$TICK" trust-check >/dev/null 2>&1 \
        && bad "trust-check: reported an untrusted repo as trusted" \
        || ok "trust-check: reports the untrusted repo root"
    LOOM_TRUST_FILE="$TR/root-absent.json" LOOM_REPO="$TR/repo" "$TICK" trust-check >/dev/null 2>&1 \
        && ok "trust-check: reports a cascaded repo as trusted" \
        || bad "trust-check: refused a repo covered by a trusted ancestor"
    [ "$(shasum "$TR/root-denied.json" | cut -d' ' -f1)" = "$before" ] \
        && ok "trust-check: never writes the trust file (only a human grants trust)" \
        || bad "trust-check: MUTATED the trust file"
    # The false-refusal pair. P30 names a tightened guard that refuses working
    # lanes as worse than the gap it closes, so "no entry recorded for the repo
    # root" must read as CANNOT TELL, never as declined. It is reachable two ways:
    # a worktree trusted somewhere its repo root's tree is not, and the spelling
    # mismatch where `git worktree list` returns the physically-resolved path
    # while the trust file is keyed by the path Claude Code was launched with.
    # Fixture: the worktree sits under a trusted directory; the repo root's own
    # tree has no entry at any level.
    mkdir -p "$TR/wt-home" "$TR/hidden"
    git init -q "$TR/hidden/repo" 2>/dev/null
    git -C "$TR/hidden/repo" config user.email t@t; git -C "$TR/hidden/repo" config user.name t
    : > "$TR/hidden/repo/f"; git -C "$TR/hidden/repo" add f >/dev/null 2>&1
    git -C "$TR/hidden/repo" commit -qm init >/dev/null 2>&1
    git -C "$TR/hidden/repo" worktree add -q "$TR/wt-home/repo-wt-1" -b wt1 >/dev/null 2>&1
    printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$TR/wt-home" > "$TR/unknown-root.json"
    if LOOM_TRUST_FILE="$TR/unknown-root.json" "$TICK" spawn-lane impl-49 --cwd "$TR/wt-home/repo-wt-1" --no-tick -- true >/dev/null 2>&1; then
        ok "trust (P30): an unrecorded repo root is 'cannot tell', not a refusal"
    else
        bad "trust (P30): FALSE REFUSAL — an unrecorded repo root was treated as declined"
    fi
    "$TICK" clear-lane impl-49 >/dev/null 2>&1 || true
    # Same fixture, one `false` added: the guard must now refuse. This is the pair
    # that shows the three-valued read doing real work — identical missing-entry
    # machinery, opposite answer, decided only by the explicit decline.
    printf '{"projects":{"%s":{"hasTrustDialogAccepted":true},"%s":{"hasTrustDialogAccepted":false}}}\n' \
        "$TR/wt-home" "$TR/hidden/repo" > "$TR/known-denied.json"
    if LOOM_TRUST_FILE="$TR/known-denied.json" "$TICK" spawn-lane impl-50 --cwd "$TR/wt-home/repo-wt-1" -- true >/dev/null 2>&1; then
        bad "trust (P30): an explicit decline on the repo root was ignored"
    else
        ok "trust (P30): explicit decline still refuses — 'cannot tell' is not 'trusted'"
    fi
    # Deduped like the quiet states: the second call in the same state is silent.
    # (Paid for by P3: fifteen identical stderr lines into a log nobody read.)
    TN="$T/p30-notify"; mkdir -p "$TN"
    printf 'ntfy:\n  push: [workspace_untrusted]\n' > "$TN/global.yml"
    n1=$(LOOM_HOME="$TN" LOOM_GLOBAL_CONFIG="$TN/global.yml" LOOM_TRUST_FILE="$TR/root-denied.json" \
         LOOM_REPO="$TR/repo" NTFY_CMD="true" "$TICK" trust-check --notify 2>&1 || true)
    n2=$(LOOM_HOME="$TN" LOOM_GLOBAL_CONFIG="$TN/global.yml" LOOM_TRUST_FILE="$TR/root-denied.json" \
         LOOM_REPO="$TR/repo" NTFY_CMD="true" "$TICK" trust-check --notify 2>&1 || true)
    if [ -f "$TN/trust.state" ]; then
        case "$n2" in *"not a trusted"*) : ;; *) bad "trust-check: second call lost the stderr report";; esac
        ok "trust-check --notify: state recorded once, warning still printed every call"
    else
        bad "trust-check --notify: no state sentinel written ($n1)"
    fi
else
    bad "trust (P30): fixture failed — could not create a linked worktree"
fi

# 4e. install --dry-run generates a valid, correctly-targeted plist without loading.
export LOOM_PLIST_DIR="$T/agents"
out=$(LOOM_REPO="$LOOM_REPO" "$TICK" install --dry-run 300 2>&1)
plist=$(echo "$out" | sed -n 's/^generated (dry-run): //p')
if [ -n "$plist" ] && [ -f "$plist" ]; then
    lint_ok=1; command -v plutil >/dev/null 2>&1 && { plutil -lint "$plist" >/dev/null 2>&1 || lint_ok=0; }
    if [ "$lint_ok" = 1 ] && grep -q "com.loom.$(basename "$LOOM_REPO")-" "$plist" \
       && grep -q "<string>$LOOM_REPO</string>" "$plist" && grep -q "<integer>300</integer>" "$plist"; then
        ok "install: dry-run generated a valid per-repo plist (label+repo+interval), not loaded"
    else
        bad "install: generated plist malformed or mistargeted"
    fi
else
    bad "install: dry-run produced no plist ($out)"
fi

test_finish
