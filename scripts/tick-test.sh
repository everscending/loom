#!/usr/bin/env bash
# Planted-violation tests for tick.sh (ticket #88 acceptance).
# Every guard is shown BOTH holding and failing when its mechanism is
# removed — a guard you have never seen fail is not a guard.
set -uo pipefail

TICK="$(cd "$(dirname "$0")" && pwd)/tick.sh"
T=$(mktemp -d)
export LOOM_HOME="$T/home" LOOM_REPO="$T/repo"
mkdir -p "$LOOM_REPO"
# Workspace-trust fixture (P16). Trusting $T alone proves the cascade: every
# lane below it spawns without an entry of its own, exactly as a real worktree
# relies on its parent directory.
export LOOM_TRUST_FILE="$T/claude.json"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$T" > "$LOOM_TRUST_FILE"
# The GLOBAL config layer is a fixture too, and an empty one by default.
# Without this the suite fell through to the developer's own
# ~/.loom/config.yml: every `cfg` lookup in every section resolved
# against whatever that machine happened to say, so a run could pass here and
# fail on another laptop. Found by P31's chain test, which asserts the
# unconfigured case and got the human's `lane_model: sonnet` instead.
# Sections that need a global layer still point at their own file.
export LOOM_GLOBAL_CONFIG="$T/global.yml"
: > "$LOOM_GLOBAL_CONFIG"
# Self-trigger is the DEFAULT now (P2), so every lane below fires a tick when it
# exits. Two consequences this file must own rather than discover:
#   * a harmless default wave command, or those ticks would launch real `claude`
#     sessions — tests that care about the wave still override it inline;
#   * bootstrap off by default, since it is now paid on many more ticks. Section
#     9 tests bootstrap itself and switches it back on via BOOTENV.
export LOOM_WAVE_CMD="true"
export LOOM_SKIP_BOOTSTRAP=1
# launchd is stubbed GLOBALLY, like glab: any test path that reaches
# watcher-arm or install must capture argv, never mutate real launchd.
# (Paid for: 2026-08-02 — the suite armed a real watcher agent per run;
# 26 zombie agents accumulated, firing exit-78 every 60s against deleted
# mktemp dirs.) `print` exits 1 (= not armed) so arm paths proceed to the
# stubbed bootstrap instead of short-circuiting on the idempotence check.
export LAUNCHCTL_CMD="$T/launchctl-stub.sh" LOOM_PLIST_DIR="$T/plists"
LCTL_CALLS="$T/launchctl-calls"
cat > "$LAUNCHCTL_CMD" <<STUBEOF
#!/bin/sh
echo "\$@" >> "$LCTL_CALLS"
[ "\$1" = print ] && exit 1
exit 0
STUBEOF
chmod +x "$LAUNCHCTL_CMD"
# The pane opener, stubbed GLOBALLY for the same reason and by the same
# lesson. `install` now raises the viewer, so every test path through it opens
# real herdr panes whenever the suite runs from inside the multiplexer — which
# is where it is always run, since HERDR_ENV is inherited. (Paid for:
# 2026-08-04 — four suite runs left four orphan viewers polling deleted mktemp
# dirs and eight stacked panes on the human's screen.) Belt and braces:
# HERDR_ENV is cleared too, so _raise_viewer returns before it reaches the
# stub. Tests that exercise the raise set both deliberately and RESTORE these
# afterwards — never `unset`, which would disarm the guard for every test after
# them.
export WATCH_PANES_CMD="$T/watch-panes-stub.sh"
WP_GLOBAL_CALLS="$T/watch-panes-calls"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$WP_GLOBAL_CALLS" > "$WATCH_PANES_CMD"
chmod +x "$WATCH_PANES_CMD"
WP_GLOBAL_STUB="$WATCH_PANES_CMD"
export HERDR_ENV=
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

cat > "$LOOM_REPO/.loom.yml" <<'EOF'
heartbeat_stale_minutes: 30
ntfy:
  topic: "test-topic"
  push: [build_complete, ticket_blocked]
EOF

# 1a. Lock exclusion holds: second tick exits fast while first holds the lock,
#     and the kick it could not run is REMEMBERED rather than dropped (P1).
#     The note is cleared before the holder exits so this test does not also
#     trigger a re-tick — 1d owns that half.
LOOM_WAVE_CMD="sleep 3" "$TICK" tick >/dev/null 2>&1 &
first=$!; sleep 0.7
out=$(LOOM_WAVE_CMD="echo second-wave-ran" "$TICK" tick 2>&1)
case "$out" in *"wave already running"*) ok "lock: concurrent tick skipped";; *) bad "lock: concurrent tick ran ($out)";; esac
[ -f "$LOOM_HOME/tick.pending" ] \
    && ok "lock: the skipped kick left a pending note" \
    || bad "lock: the skipped kick vanished with no note"
rm -f "$LOOM_HOME/tick.pending"
wait "$first"

# 1b. Planted violation: with a DIFFERENT lock dir the exclusion must fail
#     (two waves overlap) — proving the shared lock is the guard.
LOOM_WAVE_CMD="sleep 2" LOOM_LOCK_DIR="$T/lockA" "$TICK" tick >/dev/null 2>&1 &
pa=$!; sleep 0.5
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
LOOM_WAVE_CMD="sh -c 'echo w >> $WAVES; sleep 1'" "$TICK" tick >/dev/null 2>&1 &
holder=$!; sleep 0.4
for _ in 1 2 3; do "$TICK" tick >/dev/null 2>&1; done
wait "$holder"
_wait_waves "$WAVES" 2 || true
sleep 1.5                      # a spurious third wave would have landed by now
n=$(wc -l < "$WAVES" | tr -d ' ')
[ "$n" = "2" ] \
    && ok "pending: three mid-wave kicks replayed as exactly one re-tick" \
    || bad "pending: expected 2 waves (original + one replay), saw $n"

# 1e. Planted violation: point the skipped ticks' note somewhere the holder never
#     looks. That is precisely the old drop-on-the-floor path, and the loop must
#     be seen dying after a single wave — no replay, no second line.
rm -rf "$LOOM_HOME/tick.lock.d"; rm -f "$LOOM_HOME/tick.pending"
: > "$WAVES"
LOOM_WAVE_CMD="sh -c 'echo w >> $WAVES; sleep 1'" "$TICK" tick >/dev/null 2>&1 &
holder=$!; sleep 0.4
for _ in 1 2 3; do LOOM_PENDING_FILE="$T/note-nobody-reads" "$TICK" tick >/dev/null 2>&1; done
wait "$holder"; sleep 1.5
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
"$TICK" spawn-lane impl-2 -- true >/dev/null; sleep 0.5
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
sleep 0.5
types=$("$TICK" lane-status | awk '$1 ~ /-7$|-7-r2$|^probe-e11$/{print $4}' | sort -u | tr '\n' ' ')
[ "$types" = "gate impl merge probe " ] \
    && ok "lane-status: type column derived from the id (all four kinds)" \
    || bad "lane-status: type column wrong ('$types')"
# State stays at $3 — appending the column must not move it under existing readers.
st=$("$TICK" lane-status | awk '$1=="impl-7"{print $3}')
[ "$st" = "dead" ] && ok "lane-status: state stays in column 3 for existing readers" \
    || bad "lane-status: state column moved ('$st')"
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

# --- 4f. The merged agent: one program that watches first, then maybe spends -
#     Replaces a 900s scheduler that went BLIND whenever a wave held the lock
#     (it bailed at the lock before it stamped or classified anything) plus a
#     separate 60s watcher that existed only to cover that blindness. Watching
#     first makes the second program unnecessary. (Designed with the human,
#     2026-08-04.)
MT="$T/merged"; mkdir -p "$MT/repo" "$MT/home" "$MT/agents"
MENV() { LOOM_REPO="$MT/repo" LOOM_HOME="$MT/home" LOOM_PLIST_DIR="$MT/agents" \
         LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1 "$@"; }

# The default timer is 60s and the agent runs the AUTO mode, not a bare tick:
# a bare tick means "a human typed it" and would ignore both the switch and
# the gap, turning the timer into an unpaced spender.
out=$(MENV "$TICK" install --dry-run 2>&1)
mplist=$(echo "$out" | sed -n 's/^generated (dry-run): //p')
if [ -n "$mplist" ] && grep -q "<integer>60</integer>" "$mplist" \
   && grep -q "<string>--auto</string>" "$mplist"; then
    ok "merged agent: installs at 60s and fires 'tick --auto', not a bare tick"
else
    bad "merged agent: wrong interval or mode in $mplist"
fi

# stop writes the switch, start clears it. Without the clear, a started build
# would tick forever refusing to do anything.
MENV "$TICK" uninstall >/dev/null 2>&1
[ -f "$MT/home/loop.stopped" ] && ok "stop: writes the loop switch" \
                              || bad "stop: no switch written"
MENV "$TICK" install 60 >/dev/null 2>&1
[ ! -f "$MT/home/loop.stopped" ] && ok "start: clears the switch a previous stop left" \
                                 || bad "start: stale switch survived, build would never run"

# The three callers, three contracts. A wave is stubbed as a counter.
MWAVES="$MT/waves"
# NOTE: env must be EXPORTED, not prefixed onto a shell function — a prefix on
# a function call is not passed through to the command the function runs.
MTICK() { : > "$MWAVES"
          export LOOM_WAVE_CMD="sh -c 'echo w >> $MWAVES'"
          MENV "$TICK" "$@" >/dev/null 2>&1
          export LOOM_WAVE_CMD="true"; }
_mwaves() { [ -f "$MWAVES" ] && wc -l < "$MWAVES" | tr -d ' ' || echo 0; }

: > "$MT/home/loop.stopped"
MTICK tick --auto;      a=$(_mwaves)
MTICK tick --from-lane; b=$(_mwaves)
MTICK tick;             c=$(_mwaves)
if [ "$a" = 0 ] && [ "$b" = 0 ] && [ "$c" != 0 ]; then
    ok "loop switch: stopped silences the timer and lane handoffs, never a typed tick"
else
    bad "loop switch: auto=$a from-lane=$b manual=$c (want 0/0/non-zero)"
fi
rm -f "$MT/home/loop.stopped"

# BUT watching still happens on the silenced firings — that is the whole point
# of merging. A stopped auto-tick must still record that it looked.
rm -f "$MT/home/events.jsonl"; : > "$MT/home/loop.stopped"
MTICK tick --auto
grep -q '"reason":"loop_stopped"' "$MT/home/events.jsonl" 2>/dev/null \
    && ok "merged agent: a silenced tick still runs and records the pass" \
    || bad "merged agent: silenced tick left no trace ($(tail -1 "$MT/home/events.jsonl" 2>/dev/null))"
rm -f "$MT/home/loop.stopped"

# The gap paces spending, so the 60s timer costs nothing. A wave that just
# started blocks the next AUTO tick; a lane handoff ignores the gap, because a
# handoff is work already in progress and making it wait idles the build.
printf '{"t":"now","ts":%s,"ev":"wave_start"}\n' "$(date +%s)" > "$MT/home/events.jsonl"
MTICK tick --auto;      g1=$(_mwaves)
MTICK tick --from-lane; g2=$(_mwaves)
if [ "$g1" = 0 ] && [ "$g2" != 0 ]; then
    ok "wave gap: holds the timer back, never a lane handoff"
else
    bad "wave gap: auto=$g1 (want 0), from-lane=$g2 (want non-zero)"
fi
# An old wave is no longer a reason to wait.
printf '{"t":"old","ts":%s,"ev":"wave_start"}\n' "$(( $(date +%s) - 4000 ))" > "$MT/home/events.jsonl"
MTICK tick --auto
[ "$(_mwaves)" != 0 ] && ok "wave gap: expires, so the timer still backstops a stalled build" \
                      || bad "wave gap: never expired — the backstop is dead"

# Decision 4: stop cuts the direct handoffs too. The chain is spawned BY the
# lanes, so blocking waves alone would carry a ticket all the way to merged
# after the human asked it to stop.
: > "$MT/home/loop.stopped"
export LOOM_LANE_ID=impl-9
out=$(MENV "$TICK" spawn-lane gate-9 -- true 2>&1); rc_ch=$?
unset LOOM_LANE_ID
if [ "$rc_ch" = 0 ] && printf '%s' "$out" | grep -q "not chaining" \
   && [ ! -f "$MT/home/lanes/gate-9.pid" ]; then
    ok "stop: a lane cannot chain to its successor while the loop is stopped"
else
    bad "stop: chained spawn was not refused (rc=$rc_ch: $out)"
fi
# ...but a wave spawning is not a chained handoff, and must still work — that
# is how a typed `tick` gets anything done while stopped.
MENV "$TICK" spawn-lane impl-9 --no-tick -- sleep 5 >/dev/null 2>&1
[ -f "$MT/home/lanes/impl-9.pid" ] \
    && ok "stop: a wave's own spawn is not a chained handoff and still runs" \
    || bad "stop: blocked a non-chained spawn, so a typed tick could do nothing"

# stop --now kills what is running; plain stop leaves it alone to finish.
MENV "$TICK" uninstall --now >/dev/null 2>&1
sleep 0.3
if [ ! -f "$MT/home/lanes/impl-9.pid" ] \
   && grep -q '"ev":"lane_kill"' "$MT/home/events.jsonl" 2>/dev/null; then
    ok "stop --now: kills running workers through kill-lane, and records it"
else
    bad "stop --now: worker survived or the kill went unrecorded"
fi
MENV "$TICK" spawn-lane impl-8 --no-tick -- sleep 5 >/dev/null 2>&1
MENV "$TICK" uninstall >/dev/null 2>&1
if [ -f "$MT/home/lanes/impl-8.pid" ]; then
    ok "stop: plain stop leaves a running worker alone to finish its ticket"
else
    bad "stop-violation: plain stop killed a worker — that is what --now is for"
fi
MENV "$TICK" kill-lane impl-8 >/dev/null 2>&1
rm -f "$MT/home/loop.stopped"

# 4f2. `start` raises the viewer, and outranks both off-switches.
#      Before this, `start` armed an unattended build and opened no window on
#      it: only `watch` and a manual tick raised the panes. Worse, a `q` in one
#      build's ticker persisted, so the next build started blind.
#      (Asked for by the human, 2026-08-04.)
WPCAP="$MT/wp.calls"; WPSTUB="$MT/wp-stub.sh"
printf '#!/bin/sh\necho "wp $*" >> "%s"\n' "$WPCAP" > "$WPSTUB"; chmod +x "$WPSTUB"
export WATCH_PANES_CMD="$WPSTUB"

# Outside the multiplexer there are no panes to open, and no viewer to launch.
: > "$WPCAP"; export HERDR_ENV=0
MENV "$TICK" install 60 >/dev/null 2>&1
[ ! -s "$WPCAP" ] && ok "start: outside herdr, raises no viewer" \
                  || bad "start: launched a viewer with no multiplexer to put it in"

# Inside it, start launches the viewer AND clears both off-switches — a `q` in
# a previous build's ticker must not leave this one unwatched.
: > "$WPCAP"; export HERDR_ENV=1
touch "$MT/home/ticker-off" "$MT/home/viewer-off"
MENV "$TICK" install 60 >/dev/null 2>&1
sleep 0.3
if [ -s "$WPCAP" ] && [ ! -f "$MT/home/ticker-off" ] && [ ! -f "$MT/home/viewer-off" ]; then
    ok "start: raises the viewer and clears a quit ticker / an off viewer"
else
    bad "start: viewer=$(cat "$WPCAP") ticker-off=$([ -f "$MT/home/ticker-off" ] && echo yes) viewer-off=$([ -f "$MT/home/viewer-off" ] && echo yes)"
fi

# But ONLY start clears them. An automatic tick that undid a deliberate `q`
# would make the switch worthless — the human closed it 40 seconds ago.
: > "$WPCAP"; touch "$MT/home/ticker-off" "$MT/home/viewer-off"
MTICK tick --from-lane
if [ -f "$MT/home/ticker-off" ] && [ -f "$MT/home/viewer-off" ] && [ ! -s "$WPCAP" ]; then
    ok "off-switches: a tick never clears them, only a typed start does"
else
    bad "off-switches: a tick undid the human's close"
fi
rm -f "$MT/home/ticker-off" "$MT/home/viewer-off"

# A dry run generates the plist and touches nothing else.
: > "$WPCAP"; touch "$MT/home/ticker-off"
MENV "$TICK" install --dry-run >/dev/null 2>&1
[ ! -s "$WPCAP" ] && [ -f "$MT/home/ticker-off" ] \
    && ok "start --dry-run: no viewer, no switch cleared" \
    || bad "start --dry-run: had side effects"
rm -f "$MT/home/ticker-off"
# RESTORE, never unset: unsetting would hand every later test the real pane
# opener, which is exactly the accident this block is testing the fix for.
export WATCH_PANES_CMD="$WP_GLOBAL_STUB"; export HERDR_ENV=

# THE property the whole merge rests on: watching happens even while a wave
# holds the lock. The old scheduler bailed at the lock BEFORE it stamped or
# classified anything, so during a wave — the exact window in which a lane
# wedges — nothing was looking. That blindness is why a second 60s program had
# to exist. Here: a lane is running, the lock is held, and a tick that cannot
# start a wave must still leave a fresh progress stamp behind.
rm -rf "$MT/home/lanes" "$MT/home/tick.lock.d"; mkdir -p "$MT/home/lanes"
MENV "$TICK" spawn-lane impl-7 --no-tick -- sleep 5 >/dev/null 2>&1
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' \
    > "$MT/home/logs/lane-impl-7.jsonl"
mkdir -p "$MT/home/tick.lock.d"; echo $$ > "$MT/home/tick.lock.d/pid"   # a wave holds it
# No recent wave in the log, so the GAP cannot be what stops this tick — the
# lock must be, which is the path under test.
rm -f "$MT/home/events.jsonl" "$MT/home/lanes/impl-7.progress"
out=$(MENV "$TICK" tick --auto 2>&1)
if [ -f "$MT/home/lanes/impl-7.progress" ] && printf '%s' "$out" | grep -q "already running"; then
    ok "merged agent: a tick blocked by the lock STILL watches — the blindness the split existed to cover"
else
    bad "merged agent: locked-out tick did no watching — lanes=[$(MENV "$TICK" lane-status 2>&1 | tr '\n' ';')] jsonl=$([ -f "$MT/home/logs/lane-impl-7.jsonl" ] && echo yes || echo no) out=[$out]"
fi
rm -rf "$MT/home/tick.lock.d"
MENV "$TICK" kill-lane impl-7 >/dev/null 2>&1

# agent-status reports the SWITCH too. It used to print only whether the
# scheduler plist was loaded, so it said "not loaded" while a separate watcher
# ran fine — half an answer that read as "nothing is watching".
: > "$MT/home/loop.stopped"
out=$(MENV "$TICK" agent-status 2>&1)
printf '%s' "$out" | grep -qi "loop switch: STOPPED" \
    && ok "agent-status: reports the loop switch, not just the agent" \
    || bad "agent-status: switch state missing ($out)"
rm -f "$MT/home/loop.stopped"

# --- 4i. P12: cheap checks before an expensive session ---------------------
# The deterministic suite is effectively free — build 2's merge re-gate lane ran
# 265 tests and a live round trip in FOUR SECONDS — but it sat inside a review
# session that had already spent its expensive reasoning. Running it first, in
# shell, rejects a red branch with zero model time.
# Exit code 7 is the contract: it is how a wave tells "the branch is mechanically
# broken, post a rejection" from "the session crashed, resume it".
GWT="$T/worktree-gate"; mkdir -p "$GWT/scripts"
cat > "$GWT/scripts/gate.sh" <<'GEOF'
#!/usr/bin/env bash
echo "gate runner: tier $1"
[ -f "$(dirname "$0")/../RED" ] && { echo "2 tests failed" >&2; exit 1; }
exit 0
GEOF
chmod +x "$GWT/scripts/gate.sh"
RAN="$T/review-session-ran"

# 4i1. Green branch: the pregate passes and the review session runs as normal.
rm -f "$RAN" "$GWT/RED" "$LOOM_HOME/lanes/gate-41.rc"
"$TICK" spawn-lane gate-41 --no-tick --pregate api --cwd "$GWT" -- touch "$RAN" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/gate-41.rc" ] && break; sleep 0.1; done
if [ -f "$RAN" ] && [ "$(cat "$LOOM_HOME/lanes/gate-41.rc" 2>/dev/null)" = "0" ]; then
    ok "pregate: a green branch runs the review session and exits 0"
else
    bad "pregate: green branch did not reach the session (rc=$(cat "$LOOM_HOME/lanes/gate-41.rc" 2>/dev/null))"
fi

# 4i2. Red branch: the session is NEVER started, and the lane says why in a way
#      the wave can act on without reading prose.
rm -f "$RAN"; touch "$GWT/RED"
rm -f "$LOOM_HOME/lanes/gate-42.rc"
"$TICK" spawn-lane gate-42 --no-tick --pregate api --cwd "$GWT" -- touch "$RAN" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/gate-42.rc" ] && break; sleep 0.1; done
[ -f "$RAN" ] && bad "pregate: a red branch still spent a review session" \
              || ok "pregate: a red branch never starts the review session"
[ "$(cat "$LOOM_HOME/lanes/gate-42.rc" 2>/dev/null)" = "7" ] \
    && ok "pregate: a mechanical failure is reported as rc 7, not as a crash" \
    || bad "pregate: red branch rc was '$(cat "$LOOM_HOME/lanes/gate-42.rc" 2>/dev/null)', expected 7"
"$TICK" lane-status | awk '$1=="gate-42"{print $5}' | grep -q '^7$' \
    && ok "pregate: lane-status carries the exit code for the wave to harvest" \
    || bad "pregate: exit code missing from lane-status"

# 4i3. The rejection path must not swallow the epilogue. Skipping the session is
#      the point; skipping the completion tick would halt the build, which is the
#      P1/P2 failure re-entering through a side door.
rm -rf "$LOOM_HOME/tick.lock.d"; MARKP="$T/pregate-still-ticked"
LOOM_WAVE_CMD="touch $MARKP" "$TICK" spawn-lane gate-43 --pregate api --cwd "$GWT" -- true >/dev/null
for _ in $(seq 1 60); do [ -f "$MARKP" ] && break; sleep 0.1; done
[ -f "$MARKP" ] && ok "pregate: a rejected lane still fires the next wave" \
                || bad "pregate: rejection swallowed the completion tick — the build would halt"
rm -rf "$LOOM_HOME/tick.lock.d"

# 4i4. Planted violation: drop the pregate and the identical red branch spends
#      the session anyway — the behaviour this proposal exists to remove.
rm -f "$RAN"
"$TICK" spawn-lane gate-44 --no-tick --cwd "$GWT" -- touch "$RAN" >/dev/null
for _ in $(seq 1 60); do [ -f "$RAN" ] && break; sleep 0.1; done
[ -f "$RAN" ] && ok "pregate-violation: with no pregate the red branch burns the session" \
              || bad "pregate-violation: session did not run, so the guard proves nothing"

# 4i5. A repo with no gate runner SKIPS the pregate rather than failing it. A
#      false rejection costs far more than a wasted session, and a missing
#      script is not evidence about the branch.
rm -f "$RAN"; rm -f "$LOOM_HOME/lanes/gate-45.rc"
"$TICK" spawn-lane gate-45 --no-tick --pregate api --cwd "$WT" -- touch "$RAN" >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/gate-45.rc" ] && break; sleep 0.1; done
if [ -f "$RAN" ] && [ "$(cat "$LOOM_HOME/lanes/gate-45.rc" 2>/dev/null)" = "0" ]; then
    ok "pregate: a repo with no gate runner is not rejected for lacking one"
else
    bad "pregate: missing runner produced a false rejection"
fi
rm -f "$GWT/RED"

# 4i6. A respawned lane must NOT inherit the previous run's exit code. Rotating
#      the logs but keeping `<id>.rc` meant a freshly respawned, still-working
#      lane reported the old code — and a wave harvesting `rc` 7 posts a
#      mechanical rejection against a ticket whose lane is busy.
#      (Found by an independent review, 2026-08-01.)
touch "$GWT/RED"
"$TICK" spawn-lane impl-46 --no-tick --pregate api --cwd "$GWT" -- true >/dev/null
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/impl-46.rc" ] && break; sleep 0.1; done
[ "$(cat "$LOOM_HOME/lanes/impl-46.rc" 2>/dev/null)" = "7" ] \
    || bad "rc-reset: setup failed, first run did not record rc 7"
rm -f "$GWT/RED"
"$TICK" spawn-lane impl-46 --no-tick -- sleep 10 >/dev/null; sleep 0.4
rc_now=$("$TICK" lane-status | awk '$1=="impl-46"{print $5}')
[ "$rc_now" = "-" ] \
    && ok "rc-reset: a respawned lane reports no exit code while it is working" \
    || bad "rc-reset: respawned lane still reports rc '$rc_now' from its previous run"
kill "$(cat "$LOOM_HOME/lanes/impl-46.pid")" 2>/dev/null
"$TICK" clear-lane impl-46 >/dev/null

# 4i7. The pregate tier reaches the lane through the environment, never spliced
#      into its shell program. Single-quoting was not enough — a tier carrying a
#      quote broke out and ran arbitrary commands inside the lane. The four tier
#      names are fixed, so a bad one fails at spawn instead of running the wrong
#      suite. (Found by an independent review, 2026-08-01.)
PWNED="$T/pregate-pwned"; rm -f "$PWNED"
if "$TICK" spawn-lane gate-47 --no-tick --pregate "api'; touch $PWNED; :'" --cwd "$GWT" -- true >/dev/null 2>&1; then
    bad "pregate-injection: a quoted tier was accepted"
else
    ok "pregate: a tier that is not one of the four names is refused at spawn"
fi
sleep 0.5
[ -f "$PWNED" ] && bad "pregate-injection: interpolated tier executed a command inside the lane" \
                || ok "pregate-injection: nothing from the tier string reached the lane shell"
# Distinct ids and a real verdict: the previous version derived ids from `wc -c`
# of the tier name (which collided with gate-42/43/45 above) and printed its
# `ok` unconditionally, so it was a free pass.
tiers_ok=1; i=90
for t in docs logic api ui; do
    i=$((i+1))
    "$TICK" spawn-lane "gate-$i" --no-tick --pregate "$t" --cwd "$WT" -- true >/dev/null 2>&1 \
        || { tiers_ok=0; bad "pregate: legitimate tier '$t' was refused"; }
done
[ "$tiers_ok" = "1" ] && ok "pregate: all four built-in tiers still spawn" || :

# A repo may declare its OWN gate tiers — `gates:` accepts any `[a-z_]+` key —
# and hardcoding the four built-ins broke pregating them. Validation follows the
# repo's declared set, falling back to the built-ins when it declares none.
CTR="$T/custom-tier"; mkdir -p "$CTR"
printf 'gates:\n  security:\n    - "echo sec"\n' > "$CTR/.loom.yml"
LOOM_REPO="$CTR" "$TICK" spawn-lane gate-96 --no-tick --pregate security --cwd "$WT" -- true >/dev/null 2>&1 \
    && ok "pregate: a repo's own declared tier can be pregated" \
    || bad "pregate: a declared custom tier was refused"
LOOM_REPO="$CTR" "$TICK" spawn-lane gate-97 --no-tick --pregate api --cwd "$WT" -- true >/dev/null 2>&1 \
    && bad "pregate-violation: a tier this repo does not declare was accepted" \
    || ok "pregate-violation: a tier outside the repo's declared set is refused"

# 4i8. A live lane id must never be reused. Overwriting the pid file and
#      rotating the log away loses the lane that is doing the work, and the
#      `gate.eligible` guard cannot cover it because that only sees lanes in
#      state `running`. (Found by an independent review, 2026-08-01.)
"$TICK" spawn-lane impl-48 --no-tick -- sleep 20 >/dev/null
livepid=$(cat "$LOOM_HOME/lanes/impl-48.pid")
if "$TICK" spawn-lane impl-48 --no-tick -- sleep 20 >/dev/null 2>&1; then
    bad "live-lane: a second lane was spawned over a running one"
else
    ok "live-lane: reusing the id of a running lane is refused"
fi
[ "$(cat "$LOOM_HOME/lanes/impl-48.pid")" = "$livepid" ] \
    && ok "live-lane-violation: the working lane keeps its pid file" \
    || bad "live-lane-violation: the running lane's pid file was overwritten"
kill "$livepid" 2>/dev/null; "$TICK" clear-lane impl-48 >/dev/null

# --- 4h. P13: a busy lane must not read as a dead one ----------------------
# `claude -p` writes nothing until it exits, so log mtime — the liveness
# signal — stays frozen while a lane works. A healthy lane past the staleness
# window was therefore classified wedged and killed, losing everything it had
# done. W1 of build 2 spotted this in-band and worked around it by renaming a
# lane, noting "That's a convention, not a fix."
# A fake `claude` stands in throughout: basename is what triggers streaming, so
# a stub named `claude` exercises the real path without a real session.
mkdir -p "$T/fx"
cat > "$T/fx/claude" <<'STUBEOF'
#!/usr/bin/env bash
echo "$@" > "${STUB_ARGV:-/dev/null}"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"reviewing the diff"}]}}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"uv run pytest -q"}}]}}'
sleep "${STUB_SLEEP:-0}"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"PASS"}'
STUBEOF
chmod +x "$T/fx/claude"
FAKE="$T/fx/claude"

# 4h1. The streaming flags are INJECTED, never asked of the caller — the P2
#      lesson: a flag whose omission silently breaks the loop must not be
#      optional. A non-claude command is left exactly as it was.
ARGV="$T/stub-argv"; rm -f "$ARGV"
STUB_ARGV="$ARGV" "$TICK" spawn-lane gate-31 --no-tick -- "$FAKE" -p "/code-review" >/dev/null
for _ in $(seq 1 40); do [ -s "$ARGV" ] && break; sleep 0.1; done
grep -q -- "--output-format stream-json --verbose" "$ARGV" \
    && ok "stream: spawn-lane injects the streaming flags into a claude lane" \
    || bad "stream: claude lane spawned unstreamed ($(cat "$ARGV" 2>/dev/null))"
"$TICK" spawn-lane impl-32 --no-tick -- true >/dev/null; sleep 0.4
[ -f "$LOOM_HOME/logs/lane-impl-32.jsonl" ] \
    && bad "stream: a non-claude lane was given a stream file" \
    || ok "stream: a non-claude command is spawned unchanged"
# An explicit --output-format is the caller's decision and must survive.
rm -f "$ARGV"
STUB_ARGV="$ARGV" "$TICK" spawn-lane gate-35 --no-tick -- "$FAKE" -p "x" --output-format json >/dev/null
for _ in $(seq 1 40); do [ -s "$ARGV" ] && break; sleep 0.1; done
grep -q -- "stream-json" "$ARGV" \
    && bad "stream: injected a second --output-format over the caller's" \
    || ok "stream: an explicit --output-format is left alone"
# ...and `--output-format json` is NOT a stream, so no stream file is created
# for it: one blob at exit is the pre-P13 shape, and a .jsonl that never gets
# a second line would be a liveness signal that is always stale.
[ -f "$LOOM_HOME/logs/lane-gate-35.jsonl" ] \
    && bad "stream: non-stream --output-format json still got a stream file" \
    || ok "stream: --output-format json gets no stream file"
# The bug this pair exists for: `inject` and `stream` are DIFFERENT questions.
# A caller who writes out `--output-format stream-json` themselves — which
# SKILL.md's own description of the injection invites — must still get the
# stream file. One variable meant both, so that caller silently lost it:
# `render-log --follow` tailed a file that never appeared (a blank viewer
# pane for 30 minutes), `_stamp_progress` skipped the lane, and the .log was
# left as raw JSON. 4 of ~190 lanes hit it, all of them long-running.
rm -f "$ARGV"
STUB_ARGV="$ARGV" "$TICK" spawn-lane gate-36 --no-tick -- \
    "$FAKE" -p "x" --output-format stream-json --verbose >/dev/null
for _ in $(seq 1 40); do [ -s "$ARGV" ] && break; sleep 0.1; done
[ -f "$LOOM_HOME/logs/lane-gate-36.jsonl" ] \
    && ok "stream: an explicitly-streaming lane still gets its stream file" \
    || bad "stream: caller-supplied stream-json lost the .jsonl (blank viewer pane)"
[ "$(grep -o -- "--output-format" "$ARGV" | wc -l | tr -d ' ')" = "1" ] \
    && ok "stream: the flag is not duplicated for a caller who set it" \
    || bad "stream: --output-format appears $(grep -o -- '--output-format' "$ARGV" | wc -l | tr -d ' ') times"

# 4h2. The fix itself, under the REAL 30-minute window rather than a contrived
#      zero: a lane whose .log has not moved since 2020 — which is what a
#      buffered `claude -p` looks like — reads `running`, because the stream is
#      what liveness judges. (A zero-minute window would make this test turn on
#      sub-second timing; the scenario it is modelling is a lane 40 minutes into
#      real work, so the real window is also the honest one.)
STUB_SLEEP=6 "$TICK" spawn-lane gate-33 --no-tick -- "$FAKE" -p "/code-review" >/dev/null
for _ in $(seq 1 80); do [ -s "$LOOM_HOME/logs/lane-gate-33.jsonl" ] && break; sleep 0.1; done
touch -t 202001010000 "$LOOM_HOME/logs/lane-gate-33.log"   # the buffered .log, frozen
if [ ! -s "$LOOM_HOME/logs/lane-gate-33.jsonl" ]; then
    bad "stream: the lane never produced a stream to judge by (spawn failed?)"
else
    st=$("$TICK" lane-status | awk '$1=="gate-33"{print $3}')
    [ "$st" = "running" ] && ok "stream: a working lane reads running despite a frozen .log" \
                          || bad "stream: working lane reported '$st' — it would have been killed"
    # 4h3. Planted violation: take the stream away and liveness falls back to
    #      the frozen .log — the old behaviour, a healthy lane condemned wedged
    #      and killed with all its work.
    mv "$LOOM_HOME/logs/lane-gate-33.jsonl" "$T/stream-hidden"
    st=$("$TICK" lane-status | awk '$1=="gate-33"{print $3}')
    [ "$st" = "stale" ] && ok "stream-violation: without the stream the same live lane reads stale" \
                        || bad "stream-violation: lane reported '$st' with no stream to judge by"
    mv "$T/stream-hidden" "$LOOM_HOME/logs/lane-gate-33.jsonl"
fi
kill "$(cat "$LOOM_HOME/lanes/gate-33.pid")" 2>/dev/null

# 4h4. P32: the third wedge shape. A lane whose long command the harness
#      auto-backgrounds blocks on a polling tool, and the poll emits
#      `tool_progress` forever — so the stamp stayed fresh while merge-50 sat
#      on a pytest deadlocked at 0% CPU for 33 minutes, holding the merge lock
#      and the whole queue behind it (build-3, 2026-08-03). What survives the
#      filter has to be a MODEL TURN. The stamp holds the filtered count, so
#      this is asserted on the number, not on timing.
# The watch pass is what `tick --auto` runs BEFORE it considers the lock, so
# with the loop switch off it stamps, flags and classifies while spending
# nothing. These tests drive that — the production path — rather than a verb
# that would exist only to be tested. (The old separate watcher had its own
# `quiet-tick` entry point; retiring it took the entry point with it.)
WATCH() { : > "$LOOM_HOME/loop.stopped"; "$TICK" tick --auto >/dev/null 2>&1; rm -f "$LOOM_HOME/loop.stopped"; }
"$TICK" spawn-lane gate-34 --no-tick -- sleep 30 >/dev/null
PJ="$LOOM_HOME/logs/lane-gate-34.jsonl"; PS="$LOOM_HOME/lanes/gate-34.progress"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash scripts/gate.sh logic"}}]}}' > "$PJ"
WATCH
p0=$(cat "$PS" 2>/dev/null || echo missing)
for _ in $(seq 1 40); do printf '%s\n' '{"type":"tool_progress"}' >> "$PJ"; done
WATCH
p1=$(cat "$PS" 2>/dev/null || echo missing)
[ "$p0" = "$p1" ] && [ "$p0" != missing ] \
    && ok "staleness: 40 tool_progress polls are not progress — the stamp holds" \
    || bad "staleness: poll chatter moved the stamp ($p0 -> $p1) — a wedged lane reads fresh"
# Planted violation: a real model turn MUST move it, or the stamp would freeze
# on every healthy lane and the watcher would kill working sessions.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"gate came back red"}]}}' >> "$PJ"
WATCH
p2=$(cat "$PS" 2>/dev/null || echo missing)
[ "$p2" != "$p1" ] \
    && ok "staleness: a model turn still counts as progress" \
    || bad "staleness: the stamp froze on a live lane ($p1 -> $p2)"
kill "$(cat "$LOOM_HOME/lanes/gate-34.pid")" 2>/dev/null
"$TICK" clear-lane gate-34 >/dev/null 2>&1

# 4h5. The quiescence watcher must not call an UNACCEPTED build complete.
#      Zero open tickets is "all the work merged", not "the product was
#      accepted" — and `complete` here both notifies and (step 8) tears the
#      agent down, so getting it wrong ends the build over unprobed epics.
#      An epic with every ticket closed and its milestone still open is
#      schedulable work, so it must read `stalled` and let stall_action resume
#      a wave. (Paid for: build-2 2026-08-04, three epics never accepted.)
#      `_quiet_check` calls `glab` bare, so the seam is PATH.
QH="$T/quiet-accept"; mkdir -p "$QH/bin" "$QH/home"
cat > "$QH/bin/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"state=opened"*)          echo '[]' ;;                       # every ticket merged
  *"state=closed"*)          echo '[{"iid":9,"milestone":{"title":"Reporting surface"}}]' ;;
  *"milestones?state=active"*) cat "${QSTUB_MS:?}" ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$QH/bin/glab"
printf 'build-2\n' > "$QH/home/.build-label"
: > "$QH/home/loop.stopped"     # watch, never spend — same reason as WATCH above
# Own ntfy capture: section 7 defines the shared one, and this runs before it.
QSTUB="$QH/ntfy.sh"; QCAP="$T/quiet-ntfy"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$QCAP" > "$QSTUB"; chmod +x "$QSTUB"
# (a) the epic's milestone is still open → not complete.
printf '%s\n' '[{"id":9,"title":"Reporting surface"}]' > "$QH/ms-open.json"
: > "$QCAP"
PATH="$QH/bin:$PATH" LOOM_HOME="$QH/home" LOOM_QUIET_SETTLE=0 \
    NTFY_CMD="$QSTUB" QSTUB_MS="$QH/ms-open.json" LOOM_NTFY_TOPIC=test-topic \
    WATCH
# Assert on the state sentinel, not the push: whether a given event reaches
# ntfy depends on the push allowlist, but the CLASSIFICATION is the thing
# under test — and it is also what step 8 tears the agent down on.
qs=$(cat "$QH/home/quiet.state" 2>/dev/null || echo missing)
if [ "$qs" = stalled ] && ! grep -q "build_complete" "$QCAP"; then
    ok "quiet-check: an epic with no passing probe keeps the build out of complete"
else
    bad "quiet-check: unaccepted epic classified '$qs' (want stalled), pushes: $(tr '\n' ';' < "$QCAP" | tail -c 120)"
fi
# (b) its probe passed and closed the milestone → genuinely complete.
rm -f "$QH/home/quiet.state"; : > "$QCAP"
printf '[]\n' > "$QH/ms-closed.json"
PATH="$QH/bin:$PATH" LOOM_HOME="$QH/home" LOOM_QUIET_SETTLE=0 \
    NTFY_CMD="$QSTUB" QSTUB_MS="$QH/ms-closed.json" LOOM_NTFY_TOPIC=test-topic \
    WATCH
qs=$(cat "$QH/home/quiet.state" 2>/dev/null || echo missing)
[ "$qs" = complete ] \
    && ok "quiet-check: once every epic is accepted the build completes normally" \
    || bad "quiet-check: accepted build classified '$qs' (want complete)"

# 4h3b. P43: the settle window must not be refreshed by the watcher's OWN
#       no-op bookkeeping. `_quiet_check` used to read `events.jsonl`'s mtime as
#       "did anything happen", but every 60s firing writes `tick_skipped` into
#       that same file. 60s < the 120s window, so it answered `active` forever,
#       never reached the halted test, and the halted gate in `cmd_tick` was
#       unreachable: a board whose every open ticket was human-held still spent
#       a model session every `min_wave_gap_minutes`. (Paid for: build-3
#       2026-08-05 — 44 idle overnight waves, ~9 USD, one blocked ticket.)
#       NOTE the settle window is left at its real default here on purpose: the
#       tests above pass LOOM_QUIET_SETTLE=0, which is exactly what let this
#       bug live.
QB="$T/quiet-selfrefresh"; mkdir -p "$QB/bin" "$QB/home"
cat > "$QB/bin/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"state=opened"*) echo '[{"iid":32,"labels":["build-3","blocked","ready-for-agent"]}]' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$QB/bin/glab"
printf 'build-3\n' > "$QB/home/.build-label"
QBS="$QB/ntfy.sh"; QBCAP="$T/quiet-selfrefresh-ntfy"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$QBCAP" > "$QBS"; chmod +x "$QBS"; : > "$QBCAP"
# The file is ONLY the watcher's own no-ops, all stamped right now.
now=$(date +%s)
: > "$QB/home/events.jsonl"
for i in 1 2 3; do
  printf '{"t":"2026-08-05T12:00:0%sZ","ts":%s,"ev":"tick_skipped","build":"build-3","reason":"wave_gap"}\n' \
    "$i" "$(( now - i ))" >> "$QB/home/events.jsonl"
done
rm -f "$QB/home/quiet.state"
PATH="$QB/bin:$PATH" LOOM_HOME="$QB/home" NTFY_CMD="$QBS" LOOM_NTFY_TOPIC=test-topic WATCH
qb=$(cat "$QB/home/quiet.state" 2>/dev/null || echo missing)
[ "$qb" = halted ] \
    && ok "quiet-check: the watcher's own tick_skipped events do not read as activity" \
    || bad "quiet-check: self-refresh — classified '$qb' (want halted) from a file of pure no-ops"
# The watcher's OWN notification must not feed its activity signal either. The
# first cut of this fix excluded only `tick_skipped`, so: classify halted ->
# notify -> the `notify` event lands in this same file -> the firing 60s later
# reads it as activity -> `active` deletes the once-per-state sentinel -> the
# firing after that classifies halted with no memory and notifies again. A
# 2-minute oscillation that re-pushed "Build halted" forever and let a wave
# through at each gap boundary, so the spend never stopped. (Paid for: build-3
# 2026-08-05, spotted by the human as a repeating banner in the ticker.)
rm -f "$QB/home/quiet.state"
: > "$QB/home/events.jsonl"
printf '{"t":"2026-08-05T12:00:01Z","ts":%s,"ev":"notify","build":"build-3"}\n' \
    "$(( $(date +%s) - 5 ))" >> "$QB/home/events.jsonl"
PATH="$QB/bin:$PATH" LOOM_HOME="$QB/home" NTFY_CMD="$QBS" LOOM_NTFY_TOPIC=test-topic WATCH
qb=$(cat "$QB/home/quiet.state" 2>/dev/null || echo missing)
[ "$qb" = halted ] \
    && ok "quiet-check: the watcher's own notify does not read as activity" \
    || bad "quiet-check: notify self-refresh — classified '$qb' (want halted), the halted banner repeats forever"
# And the dedupe survives consecutive firings: the second one says nothing.
: > "$QBCAP"
PATH="$QB/bin:$PATH" LOOM_HOME="$QB/home" NTFY_CMD="$QBS" LOOM_NTFY_TOPIC=test-topic WATCH
[ ! -s "$QBCAP" ] \
    && ok "quiet-check: a second firing in an unchanged state pushes nothing" \
    || bad "quiet-check: re-notified in an unchanged state ($(tr '\n' ';' < "$QBCAP" | tail -c 80))"

# Planted violation: a REAL event just now must still read as activity, or the
# settle window stops doing the job it exists for (a chained handoff's few-second
# gap must not read as a stall).
rm -f "$QB/home/quiet.state"
printf '{"t":"2026-08-05T12:00:09Z","ts":%s,"ev":"ticket_close","build":"build-3","ticket":"73"}\n' \
    "$(date +%s)" >> "$QB/home/events.jsonl"
PATH="$QB/bin:$PATH" LOOM_HOME="$QB/home" NTFY_CMD="$QBS" LOOM_NTFY_TOPIC=test-topic WATCH
qb=$(cat "$QB/home/quiet.state" 2>/dev/null || echo missing)
[ "$qb" = missing ] \
    && ok "quiet-check: a real event inside the settle window still reads as active" \
    || bad "quiet-check: real activity misread as '$qb' — settle window no longer protects a handoff gap"

# 4h4. The log stays human shaped: the stream is rendered back to prose and the
#      commands it ran, because waves and humans read these files for verdicts
#      and crash triage.
rm -f "$LOOM_HOME/logs/lane-gate-34.log" "$LOOM_HOME/logs/lane-gate-34.jsonl"
"$TICK" spawn-lane gate-34 --no-tick -- "$FAKE" -p "/code-review" >/dev/null
for _ in $(seq 1 40); do grep -q "reviewing the diff" "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null && break; sleep 0.1; done
if grep -q "reviewing the diff" "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null \
   && grep -q "uv run pytest -q" "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null; then
    ok "stream: the .log still reads as prose plus the commands the lane ran"
else
    bad "stream: .log did not render ($(head -3 "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null))"
fi

# 4h5. A reused lane id gets a FRESH log — an inherited mtime alone can read as
#      stale — but the previous transcript is rotated aside, never truncated
#      away: build 2 stacked two to four sessions per file and lost its session
#      boundaries, and a crashed lane's transcript is what triage needs.
sleep 1                                    # distinct rotation timestamp
"$TICK" spawn-lane gate-34 --no-tick -- "$FAKE" -p "/code-review round 2" >/dev/null
sleep 0.6
if ls "$LOOM_HOME/logs"/lane-gate-34-*.log >/dev/null 2>&1 \
   && grep -ql "reviewing the diff" "$LOOM_HOME/logs"/lane-gate-34-*.log 2>/dev/null; then
    ok "rotate: the previous session's transcript is preserved under its own name"
else
    bad "rotate: previous transcript lost on respawn"
fi
n=$(grep -c "reviewing the diff" "$LOOM_HOME/logs/lane-gate-34.log" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "rotate: the live log holds this session only, not a stack of them" \
               || bad "rotate: live log holds $n sessions — boundaries are unrecoverable again"

# 4h6. Rotation skips EMPTY files (nothing to preserve), which left the old file
#      in place with its old timestamp — so a lane respawned under an id whose
#      previous run wrote nothing read as `stale` the instant it started, and
#      the wave would kill a lane that had only just begun. The fresh mtime,
#      not the rotation, is what the liveness check depends on.
"$TICK" spawn-lane gate-36 --no-tick -- true >/dev/null; sleep 0.4
"$TICK" clear-lane gate-36 >/dev/null
touch -t 202001010000 "$LOOM_HOME/logs/lane-gate-36.log" 2>/dev/null   # empty, ancient
"$TICK" spawn-lane gate-36 --no-tick -- sleep 10 >/dev/null; sleep 0.4
st=$("$TICK" lane-status | awk '$1=="gate-36"{print $3}')
[ "$st" = "running" ] \
    && ok "rotate: a lane reusing an id whose old log was empty still starts fresh" \
    || bad "rotate: respawned lane reported '$st' — it inherited an empty file's old mtime"
kill "$(cat "$LOOM_HOME/lanes/gate-36.pid" 2>/dev/null)" 2>/dev/null
"$TICK" clear-lane gate-36 >/dev/null

# 5. clear-lane forgets a harvested lane.
"$TICK" clear-lane impl-2 >/dev/null
"$TICK" lane-status | grep -q '^impl-2 ' && bad "clear-lane: impl-2 still listed" || ok "clear-lane: harvested lane forgotten"

# 6. ntfy: payload carries event/title/click; unconfigured events do not fire.
STUB="$T/ntfy-stub.sh"; CAP="$T/ntfy-capture"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$CAP" > "$STUB"; chmod +x "$STUB"
NTFY_CMD="$STUB" "$TICK" notify ticket_blocked "T87 blocked" "missing decision" "https://x/87" >/dev/null
if grep -q "X-Orch-Event: ticket_blocked" "$CAP" && grep -q "Click: https://x/87" "$CAP" && grep -q "test-topic" "$CAP"; then
    ok "ntfy: configured event fired with event header, click url, topic"
else
    bad "ntfy: payload missing fields: $(cat "$CAP" 2>/dev/null)"
fi
: > "$CAP"
NTFY_CMD="$STUB" "$TICK" notify mr_merged "t" "b" >/dev/null
[ -s "$CAP" ] && bad "ntfy-violation: unconfigured event fired" || ok "ntfy-violation: unconfigured event suppressed"

# 6b. The push list is read from the `push:` KEY, never from a line that
#     merely mentions it. An unanchored match ate the explanatory comment
#     above the key ("the reader takes the first `push:` line and stops"),
#     printed that as the event list and exited — so every event failed the
#     allowlist and notifications stopped dead. Silently, because the ticker
#     line lived past that same gate. (Paid for: the comment landed in the
#     global config between build-1 and build-2 on 2026-08-03; build-2 ran a
#     full night and completed twice with zero notifications.)
NCFG="$T/ntfy-cfg.yml"
cat > "$NCFG" <<'EOF'
ntfy:
  topic_prefix: "t-"
  # One line, always: the reader takes the first `push:` line and stops.
  push: [build_complete, ticket_blocked]
EOF
: > "$CAP"
LOOM_GLOBAL_CONFIG="$NCFG" NTFY_CMD="$STUB" "$TICK" notify build_complete "done" "b" >/dev/null 2>&1
grep -q "X-Orch-Event: build_complete" "$CAP" \
    && ok "ntfy: a comment mentioning push: does not shadow the real key" \
    || bad "ntfy: push list misparsed — a commented mention won over the key"
# The gate itself must still work off that correctly-read list.
: > "$CAP"
LOOM_GLOBAL_CONFIG="$NCFG" NTFY_CMD="$STUB" "$TICK" notify lane_stale "t" "b" >/dev/null 2>&1
[ -s "$CAP" ] && bad "ntfy-violation: event outside the parsed list still pushed" \
              || ok "ntfy: an event outside the parsed list is still suppressed"

# 6c. A suppressed push is still recorded in the TICKER. The local pane is the
#     always-on record; a push is a delivery mechanism that can be switched
#     off, misconfigured, or land in a pocket. With the ticker line behind the
#     allowlist gate, the only trace of a finished build was its absence —
#     which is exactly how the miss above stayed invisible for a night.
EVH2="$T/ntfy-ev-home"; mkdir -p "$EVH2"
LOOM_HOME="$EVH2" LOOM_GLOBAL_CONFIG="$NCFG" NTFY_CMD="$STUB" \
    "$TICK" notify lane_stale "wedged" "b" >/dev/null 2>&1
if LOOM_HOME="$EVH2" "$TICK" render-events 2>/dev/null | grep -q "wedged"; then
    ok "ticker: a notification suppressed by the push list is still shown locally"
else
    bad "ticker: suppressed notification left no local trace ($(cat "$EVH2/events.jsonl" 2>/dev/null | tail -1))"
fi

# --- 7. snapshot (P7) -----------------------------------------------------
# Seam: GLAB_CMD points at a stub serving canned API responses and logging
# every invocation, so both the CONTENT of the document and the SHAPE of the
# call pattern are assertable.
FX="$T/fx"; mkdir -p "$FX"; CALLS="$T/calls.log"
cat > "$FX/open.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"**Selected epics** (4 tickets, ~6h):\n- Ledger core (#10, #11, #12) — 4h\n- Reporting surface (#13) — 2h\n\n**Deliberately dropped** (remain unlabeled):\n- Archive sweep\n\nConfig snapshot:\n\n- max_lanes: 4\n"},
 {"iid":10,"title":"Add ledger table","project_id":1,"web_url":"https://x/10",
  "labels":["build-2","ready-for-agent"],"assignees":[],"updated_at":"2026-07-28T10:00:00Z",
  "milestone":{"title":"Ledger core"},
  "description":"## Risk tier\n\napi\n\n## Blocked by\n\n- #7 schema groundwork\n"},
 {"iid":11,"title":"Wire ledger API","project_id":1,"web_url":"https://x/11",
  "labels":["build-2","ready-for-agent","fix"],"assignees":[],"updated_at":"2026-07-28T11:00:00Z",
  "milestone":{"title":"Ledger core"},
  "description":"## Risk tier\n\nlogic\n\n## Blocked by\n\n- #10 ledger table\n- #13 seed data\n"},
 {"iid":12,"title":"Ledger report view","project_id":1,"web_url":"https://x/12",
  "labels":["build-2","review"],"assignees":[{"username":"agent-a"}],"updated_at":"2026-07-28T12:00:00Z",
  "milestone":{"title":"Ledger core"},"description":"## Blocked by\n\nNone - can start immediately\n"},
 {"iid":20,"title":"Unrelated open issue","project_id":1,"labels":["chore"],"assignees":[],"description":"noise"}
]
EOF
echo '[]' > "$FX/links-10.json"
cat > "$FX/links-11.json" <<'EOF'
[{"iid":10,"state":"opened","project_id":1,"link_type":"is_blocked_by"},
 {"iid":14,"state":"closed","project_id":1,"link_type":"is_blocked_by"},
 {"iid":21,"state":"opened","project_id":1,"link_type":"relates_to"}]
EOF
cat > "$FX/links-12.json" <<'EOF'
[{"iid":500,"project_id":42,"link_type":"is_blocked_by"}]
EOF
cat > "$FX/mrs-12.json" <<'EOF'
[{"iid":77,"title":"Ledger report view","state":"opened","draft":false,"web_url":"https://x/mr/77","source_branch":"t12","sha":"e52b7c1000000000000000000000000000000000"}]
EOF
cat > "$FX/notes.json" <<'EOF'
[{"system":true,"created_at":"2026-07-28T09:00:00Z","author":{"username":"bot"},"body":"added ~in-progress label"},
 {"system":false,"created_at":"2026-07-28T09:05:00Z","author":{"username":"wave"},"body":"W3: ui gates need the stack up first."}]
EOF
# P30 fixtures: #12 rejected twice for the SAME class (newest first, as the
# API returns them); #11 rejected twice for DIFFERENT classes.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T09:20:00Z","author":{"username":"gate"},"body":"r2: same trap again\n\n<!-- orch-verdict FAIL bbbb2222 class=marks-attribution -->"},
 {"system":false,"created_at":"2026-07-28T09:10:00Z","author":{"username":"gate"},"body":"r1: FIFO pairing\n\n<!-- orch-verdict FAIL aaaa1111 class=marks-attribution -->"}]
EOF
cat > "$FX/notes-12-changed-class.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T09:20:00Z","author":{"username":"gate"},"body":"r2\n\n<!-- orch-verdict FAIL bbbb2222 class=missing-tests -->"},
 {"system":false,"created_at":"2026-07-28T09:10:00Z","author":{"username":"gate"},"body":"r1\n\n<!-- orch-verdict FAIL aaaa1111 class=marks-attribution -->"}]
EOF
cat > "$FX/glab-stub.sh" <<'EOF'
#!/usr/bin/env bash
FX="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "${STUB_LOG:-/dev/null}"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
case "$*" in
  *"state=opened"*) [ -n "${STUB_FAIL_STAGE1:-}" ] && { echo "500 boom" >&2; exit 1; }
                    cat "${STUB_OPEN:-$FX/open.json}" ;;
  *"state=closed"*) cat "${STUB_CLOSED:-$FX/closed-none.json}" 2>/dev/null || echo '[]' ;;
  *"/links"*)       [ -n "${STUB_403_LINKS:-}" ] && { echo "403 Forbidden" >&2; exit 1; }
                    n=$(echo "$*" | sed -n 's#.*issues/\([0-9]*\)/links.*#\1#p')
                    cat "$FX/links-$n.json" 2>/dev/null || echo '[]' ;;
  *"related_merge_requests"*) n=$(echo "$*" | sed -n 's#.*issues/\([0-9]*\)/related.*#\1#p')
                    cat "$FX/mrs-$n.json" 2>/dev/null || echo '[]' ;;
  *"/notes"*)       n=$(echo "$*" | sed -n 's#.*issues/\([0-9]*\)/notes.*#\1#p')
                    if [ -f "$FX/notes-$n.json" ]; then cat "$FX/notes-$n.json"
                    else cat "$FX/notes.json"; fi ;;
  *"milestones"*)   cat "${STUB_MILESTONES:-$FX/milestones.json}" 2>/dev/null || echo '[]' ;;
  *) echo "[]" ;;
esac
EOF
chmod +x "$FX/glab-stub.sh"
echo '[]' > "$FX/closed-none.json"
SNAP() { GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$CALLS" "$TICK" snapshot 2>"$T/snap.err"; }

# 7a. Assembly holds: one document carrying the whole read set.
: > "$CALLS"
"$TICK" spawn-lane merge-51 -- sleep 20 >/dev/null
SNAP > "$T/snap.json"; rc=$?
if [ "$rc" = 0 ] && jq -e . "$T/snap.json" >/dev/null 2>&1; then
    q() { jq -r "$1" "$T/snap.json"; }
    if [ "$(q '.build.label')" = "build-2" ] \
       && [ "$(q '[.tickets[].iid] | @csv')" = '10,11,12' ] \
       && [ "$(q '.tickets[] | select(.iid==10) | .state')" = "ready-for-agent" ] \
       && [ "$(q '.tickets[] | select(.iid==10) | .tier')" = "api" ] \
       && [ "$(q '.tickets[] | select(.iid==12) | .related_merge_requests[0].iid')" = "77" ] \
       && [ "$(q '.lanes[] | select(.id=="merge-51") | .state')" = "running" ] \
       && [ "$(q '[.lessons_tail[].body] | length')" = "1" ] \
       && [ "$(q '.lessons_tail[0].author')" = "wave" ] \
       && [ "$(q '.summary.by_state["ready-for-agent"]')" = "2" ]; then
        ok "snapshot: one document carries tickets, tier, MRs, lanes, lessons, summary"
    else
        bad "snapshot: document assembled wrong ($(head -c 300 "$T/snap.json"))"
    fi
else
    bad "snapshot: did not emit valid JSON (rc=$rc, $(head -2 "$T/snap.err"))"
fi
# 7a2. Lane accounting (P10). The snapshot is what the wave reads before
#      deciding to fill a lane, so the impl/aux split has to be visible there.
#      Two gates plus a probe alongside one implementer is the exact shape that
#      turned `max_lanes: 4` into a single implementer.
for l in gate-61 gate-62 probe-e61; do "$TICK" spawn-lane "$l" -- sleep 20 >/dev/null; done
# Its own stub log: appending to $CALLS would corrupt the call-count test below.
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-lanes" "$TICK" snapshot \
    > "$T/snap-lanes.json" 2>/dev/null
q2() { jq -r "$1" "$T/snap-lanes.json"; }
if [ "$(q2 '.summary.lanes_running_by_type.impl')" = "0" ] \
   && [ "$(q2 '.summary.lanes_running_by_type.gate')" = "2" ] \
   && [ "$(q2 '.summary.lanes_running_by_type.probe')" = "1" ] \
   && [ "$(q2 '.summary.lanes_running_by_type.merge')" = "1" ] \
   && [ "$(q2 '.summary.lanes_running')" = "4" ]; then
    ok "snapshot: lanes counted by type, not lumped together"
else
    bad "snapshot: lane type counts wrong ($(q2 '.summary.lanes_running_by_type|@json'))"
fi
# Four lanes are running, yet every implementer slot is still free: that
# difference IS the proposal. Compare against the resolved cap, not a literal —
# max_lanes is layered config and this machine's global value may not be 4.
[ "$(q2 '.summary.impl_slots_free')" = "$(q2 '.config.max_lanes')" ] \
    && ok "snapshot: gates/probes/merges leave all impl slots free (P10)" \
    || bad "snapshot: impl_slots_free = $(q2 '.summary.impl_slots_free'), cap = $(q2 '.config.max_lanes')"
[ "$(q2 '.config.max_aux_lanes')" != "null" ] \
    && ok "snapshot: aux cap is published so the wave can bound gates/probes" \
    || bad "snapshot: no max_aux_lanes in config"
# 7a3. Stranded detection: `in-progress` with no ALIVE lane — where a gate
#      rejection parks a ticket (verdict fail → in-progress, assignee kept).
#      No wave step read that state, so gate-rejected #11/#12 sat unworked
#      while fresh backlog tickets took the slots (build-3 2026-08-02). A
#      lane of ANY kind covers its ticket, round suffix included:
#      gate-31-r2 must cover #31 while laneless #30 is flagged.
cat > "$FX/open-stranded.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"**Selected epics**:\n- Ledger core (#30, #31)\n"},
 {"iid":30,"title":"Rejected, awaiting rework","project_id":1,"web_url":"https://x/30",
  "labels":["build-2","in-progress"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":31,"title":"In its second gate round","project_id":1,"web_url":"https://x/31",
  "labels":["build-2","in-progress"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"}
]
EOF
"$TICK" spawn-lane gate-31-r2 -- sleep 20 >/dev/null
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-stranded.json" STUB_LOG="$T/calls-stranded" \
    "$TICK" snapshot > "$T/snap-stranded.json" 2>/dev/null
[ "$(jq -c '.summary.stranded' "$T/snap-stranded.json" 2>/dev/null)" = "[30]" ] \
    && ok "snapshot: laneless in-progress ticket is stranded; a live gate round covers its own" \
    || bad "snapshot: stranded = $(jq -c '.summary.stranded' "$T/snap-stranded.json" 2>/dev/null) (want [30])"
# 7a4. Fix tickets are first-class in the snapshot: the fill step claims
#      `fix: true` before the rest of the ready set (a fix ticket holds an
#      epic's re-probe hostage — asked for by the human, 2026-08-02), so the
#      flag must be derivable without label-parsing in every wave.
[ "$(q '.tickets[] | select(.iid==11) | .fix')" = "true" ] \
    && [ "$(q '.tickets[] | select(.iid==10) | .fix')" = "false" ] \
    && ok "snapshot: fix label surfaces as a per-ticket flag" \
    || bad "snapshot: fix flag wrong (11=$(q '.tickets[] | select(.iid==11) | .fix'), 10=$(q '.tickets[] | select(.iid==10) | .fix'))"
# 7a5. P30: the rejection history is a decision input. Two consecutive FAILs
#      naming one class → tail 2 (the wave blocks for a design decision);
#      different classes → tail 1; no verdicts at all → 0. (#39 burned
#      round 3 on a class the round-2 verdict had named, 2026-08-02.)
[ "$(q '.tickets[] | select(.iid==12) | .rejections | "\(.total)/\(.last_class)/\(.same_class_tail)"')" = "2/marks-attribution/2" ] \
    && ok "snapshot: two same-class FAILs count as a tail of 2" \
    || bad "snapshot: same-class tail wrong for #12 ($(q '.tickets[] | select(.iid==12) | .rejections | @json'))"
cp "$FX/notes-12.json" "$FX/notes-12-orig.json"
cp "$FX/notes-12-changed-class.json" "$FX/notes-12.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-cls" "$TICK" snapshot > "$T/snap-cls.json" 2>/dev/null
cp "$FX/notes-12-orig.json" "$FX/notes-12.json"
[ "$(jq -r '.tickets[] | select(.iid==12) | .rejections.same_class_tail' "$T/snap-cls.json")" = "1" ] \
    && ok "snapshot: a class change resets the tail to 1" \
    || bad "snapshot: differing classes did not reset the tail ($(jq -c '.tickets[] | select(.iid==12) | .rejections' "$T/snap-cls.json"))"
[ "$(q '.tickets[] | select(.iid==10) | .rejections | "\(.total)/\(.same_class_tail)"')" = "0/0" ] \
    && ok "snapshot: no verdicts means zero rejections" \
    || bad "snapshot: phantom rejections on a clean ticket"
# 7a5b. P37: the cap belongs to the SCOPE, not the issue number. A ticket
#      rewritten into different work carries an `orch-scope-reset` marker
#      (lane.sh rescope), and verdicts older than the newest one stop counting.
#      #67 came back to the board with 3 of 3 rejections against code #48 had
#      deleted; its first gate FAIL would have blocked it (build-3, 2026-08-04).
cat > "$FX/notes-12-rescoped.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T10:00:00Z","author":{"username":"human"},"body":"Re-scoped: the pairing race moved to #48, which deleted this code.\n\n<!-- orch-scope-reset 2026-07-28T10:00:00Z -->"},
 {"system":false,"created_at":"2026-07-28T09:30:00Z","author":{"username":"gate"},"body":"r3\n\n<!-- orch-verdict FAIL cccc3333 class=marks-attribution -->"},
 {"system":false,"created_at":"2026-07-28T09:20:00Z","author":{"username":"gate"},"body":"r2\n\n<!-- orch-verdict FAIL bbbb2222 class=marks-attribution -->"},
 {"system":false,"created_at":"2026-07-28T09:10:00Z","author":{"username":"gate"},"body":"r1\n\n<!-- orch-verdict FAIL aaaa1111 class=marks-attribution -->"}]
EOF
cp "$FX/notes-12-rescoped.json" "$FX/notes-12.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-rescope" "$TICK" snapshot > "$T/snap-rescope.json" 2>/dev/null
[ "$(jq -r '.tickets[] | select(.iid==12) | .rejections | "\(.total)/\(.same_class_tail)"' "$T/snap-rescope.json")" = "0/0" ] \
    && ok "snapshot: a scope reset retires every rejection older than it" \
    || bad "snapshot: re-scoped ticket still carries its old cap ($(jq -c '.tickets[] | select(.iid==12) | .rejections' "$T/snap-rescope.json"))"
# Planted violation: the marker must not eat history NEWER than itself, or a
# single rescope would make the cap permanently unreachable. Same fixture, the
# marker moved back between r2 and r3 — r3 still counts.
sed 's/2026-07-28T10:00:00Z/2026-07-28T09:25:00Z/g' "$FX/notes-12-rescoped.json" > "$FX/notes-12.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-rescope-mid" "$TICK" snapshot > "$T/snap-rescope-mid.json" 2>/dev/null
cp "$FX/notes-12-orig.json" "$FX/notes-12.json"
[ "$(jq -r '.tickets[] | select(.iid==12) | .rejections | "\(.total)/\(.last_class)/\(.same_class_tail)"' "$T/snap-rescope-mid.json")" = "1/marks-attribution/1" ] \
    && ok "snapshot: rejections newer than the reset marker still count" \
    || bad "snapshot: the reset swallowed a later rejection ($(jq -c '.tickets[] | select(.iid==12) | .rejections' "$T/snap-rescope-mid.json"))"
# 7a6. P31: the model escalation chain is RESOLVED in the snapshot, not
#      reasoned about per wave — ticket `model::` label > rework_model (a
#      round following a rejection) > lane_model > the session default.
#      With neither key set, the chain must resolve to "inherit", never to an
#      invented tier (2026-08-02: a fable interactive default silently ran
#      every worker top-tier — the failure that made lane_model exist).
[ "$(q '.tickets[] | select(.iid==10) | .model | "\(.effective)/\(.source)"')" = "null/session-default" ] \
    && ok "snapshot: no model config resolves to inherit-the-default, not an invented tier" \
    || bad "snapshot: unconfigured model chain invented $(q '.tickets[] | select(.iid==10) | .model | @json')"
cat > "$FX/open-model.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"**Selected epics**:\n- Ledger core (#10, #11, #12, #13)\n"},
 {"iid":10,"title":"Fresh, unlabeled","project_id":1,"web_url":"https://x/10",
  "labels":["build-2","ready-for-agent"],"assignees":[],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":11,"title":"Two escalation labels","project_id":1,"web_url":"https://x/11",
  "labels":["build-2","in-progress","model::haiku","model::opus"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":12,"title":"Rejected twice AND labeled","project_id":1,"web_url":"https://x/12",
  "labels":["build-2","review","model::fable"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":13,"title":"Rejected twice, unlabeled","project_id":1,"web_url":"https://x/13",
  "labels":["build-2","in-progress"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"}
]
EOF
cp "$FX/notes-12.json" "$FX/notes-13.json"
printf 'lane_model: sonnet\nrework_model: opus\n' >> "$LOOM_REPO/.loom.yml"
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-model.json" STUB_LOG="$T/calls-model" \
    "$TICK" snapshot > "$T/snap-model.json" 2>/dev/null
sed -i.bak '/^lane_model: sonnet$/d;/^rework_model: opus$/d' "$LOOM_REPO/.loom.yml"
rm -f "$FX/notes-13.json"
m() { jq -r ".tickets[] | select(.iid==$1) | .model | \"\(.effective)/\(.source)\"" "$T/snap-model.json"; }
[ "$(m 10)" = "sonnet/lane_model" ] \
    && ok "snapshot: an unlabeled first round takes lane_model" \
    || bad "snapshot: first round resolved $(m 10), want sonnet/lane_model"
[ "$(m 13)" = "opus/rework_model" ] \
    && ok "snapshot: a round following a rejection takes rework_model" \
    || bad "snapshot: rework round resolved $(m 13), want opus/rework_model"
[ "$(m 12)" = "fable/label" ] \
    && ok "snapshot: the human's model:: label outranks rework_model" \
    || bad "snapshot: label lost to the config chain ($(m 12))"
[ "$(m 11)" = "opus/label" ] \
    && ok "snapshot: two model:: labels resolve to the highest tier" \
    || bad "snapshot: two labels resolved $(m 11), want opus/label"
jq -e '[.warnings[] | select(test("2 .model::. labels"))] | length == 1' "$T/snap-model.json" >/dev/null \
    && ok "snapshot: the ambiguous ticket is warned about once, not silently picked" \
    || bad "snapshot: two model:: labels produced no warning ($(jq -c .warnings "$T/snap-model.json"))"
# 7a7. Comment threads are read for every MEMBER ticket, not just the active
#      ones, and a ticket left claimed in `ready-for-agent` is warned about.
#      Both are the same failure: #47 went rejected -> blocked -> unblocked,
#      came back `ready-for-agent` still holding its lane's assignee, and read
#      as `rejections.total: 0` with `ready_set_empty: true` — its cap
#      restarted from zero, the same-class stop rule went blind, and the only
#      actionable ticket in the build was invisible to BOTH fill paths
#      (2026-08-03).
cat > "$FX/open-unblocked.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"**Selected epics**:\n- Ledger core (#30, #31)\n"},
 {"iid":30,"title":"Rejected, blocked, then unblocked cleanly","project_id":1,"web_url":"https://x/30",
  "labels":["build-2","ready-for-agent"],"assignees":[],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":31,"title":"Unblocked but never unassigned","project_id":1,"web_url":"https://x/31",
  "labels":["build-2","ready-for-agent"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"},
 {"iid":32,"title":"Tier carried by the scoped label alone","project_id":1,"web_url":"https://x/32",
  "labels":["build-2","ready-for-agent","tier::api"],"assignees":[],
  "milestone":{"title":"Ledger core"},"description":"No risk-tier section here.\n"},
 {"iid":33,"title":"Poisons every merge lane that picks it","project_id":1,"web_url":"https://x/33",
  "labels":["build-2","merge-queue"],"assignees":[{"username":"agent-a"}],
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\nlogic\n"}
]
EOF
cat > "$FX/notes-33.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T11:20:00Z","author":{"username":"merge"},
  "body":"combined gate deadlocked in pytest\n\n<!-- orch-merge-attempt 33 -->"},
 {"system":false,"created_at":"2026-07-28T11:10:00Z","author":{"username":"merge"},
  "body":"conflict in live-app.ts, aborted\n\n<!-- orch-merge-attempt 33 -->"}]
EOF
cat > "$FX/notes-30.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T09:10:00Z","author":{"username":"gate"},
  "body":"r1: positional pairing\n\n<!-- orch-verdict FAIL aaaa1111 class=positional-correlation -->"}]
EOF
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-unblocked.json" STUB_LOG="$T/calls-unblocked" \
    "$TICK" snapshot > "$T/snap-unblocked.json" 2>/dev/null
rm -f "$FX/notes-30.json" "$FX/notes-33.json"
u() { jq -r "$1" "$T/snap-unblocked.json"; }
[ "$(u '.tickets[] | select(.iid==30) | .rejections | "\(.total)/\(.last_class)"')" = "1/positional-correlation" ] \
    && ok "snapshot: a rejection history survives the trip through blocked and back to ready" \
    || bad "snapshot: history lost on a non-active member ($(u '.tickets[] | select(.iid==30) | .rejections | @json'))"
jq -e '[.warnings[] | select(test("#31") and test("still assigned")
                             and test("lane.sh transition 31 ready-for-agent"))] | length == 1' \
    "$T/snap-unblocked.json" >/dev/null \
    && ok "snapshot: a claimed ready-for-agent ticket is warned about, with the fixing command" \
    || bad "snapshot: no unassign warning for #31 ($(jq -c .warnings "$T/snap-unblocked.json"))"
# Planted violation: the warning must key on the ASSIGNEE, not on the state.
# #30 is ready-for-agent too — warning on it would make the signal noise.
jq -e '[.warnings[] | select(test("#30") and test("still assigned"))] | length == 0' \
    "$T/snap-unblocked.json" >/dev/null \
    && ok "snapshot: an unassigned ready-for-agent ticket is not warned about" \
    || bad "snapshot: unassign warning fired on a clean ticket"
# P32: the snapshot counts merge attempts from the trailers, so the wave can
# stop feeding lanes into one poisoned ticket. #30 carries a FAIL verdict and
# no merge attempt; #33 carries two attempts — the cap default is 2, so that
# is the ticket the queue must give up on and step past.
[ "$(u '.tickets[] | select(.iid==33) | .merge_attempts')" = "2" ] \
    && ok "snapshot: merge attempts counted from the orch-merge-attempt trailers" \
    || bad "snapshot: merge_attempts = $(u '.tickets[] | select(.iid==33) | .merge_attempts'), want 2"
# Planted violation: a gate verdict is not a merge attempt. If the count
# matched any trailer, #30's FAIL would inflate it and the queue would give
# up on a ticket that has never once been merged.
[ "$(u '.tickets[] | select(.iid==30) | .merge_attempts')" = "0" ] \
    && ok "snapshot: a gate verdict does not count as a merge attempt" \
    || bad "snapshot: verdict trailer leaked into merge_attempts"
[ "$(jq -r '.config.merge_attempt_cap' "$T/snap-unblocked.json")" != "null" ] \
    && ok "snapshot: merge_attempt_cap is published so the wave can bound retries" \
    || bad "snapshot: no merge_attempt_cap in config"
# Tier falls back to the SCOPED label when the body has no `## Risk tier`.
# The fallback existed but matched a bare `ui`, while `bootstrap.sh` creates
# `tier::ui` — so it was dead in every repo this skill bootstraps, and a
# probe-filed ticket that set the label and not the section read `tier: null`,
# leaving no suite for `--pregate` to run (#52, 2026-08-03).
[ "$(u '.tickets[] | select(.iid==32) | .tier')" = "api" ] \
    && ok "snapshot: tier falls back to the scoped tier:: label, prefix stripped" \
    || bad "snapshot: scoped tier label ignored ($(u '.tickets[] | select(.iid==32) | .tier'))"
jq -e '[.warnings[] | select(test("#32") and test("Risk tier"))] | length == 0' \
    "$T/snap-unblocked.json" >/dev/null \
    && ok "snapshot: a label-only tier is not warned about as missing" \
    || bad "snapshot: label-only tier still warned as missing"
# Planted violation: the body section must still WIN over the label, so a
# ticket whose body says logic is not silently regraded by a stray label.
[ "$(u '.tickets[] | select(.iid==31) | .tier')" = "logic" ] \
    && ok "snapshot: the body's Risk tier section still outranks the label" \
    || bad "snapshot: body tier lost to the label ($(u '.tickets[] | select(.iid==31) | .tier'))"
# The hole itself, documented: #31 is in neither fill path. That is WHY the
# warning exists — the scheduler cannot see it, so a human has to.
[ "$(u '.summary.ready_set_empty')" = "false" ] \
    && [ "$(jq -c '.summary.stranded' "$T/snap-unblocked.json")" = "[]" ] \
    && ok "snapshot: the claimed ticket is in neither the ready set nor stranded" \
    || bad "snapshot: fill-path membership changed ($(u '.summary | "\(.ready_set_empty)/\(.stranded|tostring)"'))"

# The wave must be able to see a merge in flight without holding its lock (P5).
[ "$(q2 '.summary.merge_in_flight')" = "false" ] || bad "snapshot: merge_in_flight true with no merge running"
"$TICK" spawn-lane merge-63 --merge-lock -- sleep 20 >/dev/null
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-lanes" "$TICK" snapshot > "$T/snap-merge.json" 2>/dev/null
[ "$(jq -r '.summary.merge_in_flight' "$T/snap-merge.json")" = "true" ] \
    && ok "snapshot: a merge in flight is visible to the wave" \
    || bad "snapshot: merge_in_flight did not reflect the held lock"
kill "$(cat "$LOOM_HOME/lanes/merge-63.pid" 2>/dev/null)" 2>/dev/null
"$TICK" clear-lane merge-63 >/dev/null; rm -rf "$LOOM_HOME/merge.lock.d"
for l in gate-61 gate-62 probe-e61; do
    kill "$(cat "$LOOM_HOME/lanes/$l.pid" 2>/dev/null)" 2>/dev/null
    "$TICK" clear-lane "$l" >/dev/null
done

# The scheduler's universe is "open issues labeled build-N" — #20 is neither.
jq -e '[.tickets[].iid] | index(20)' "$T/snap.json" >/dev/null 2>&1 \
    && bad "snapshot: non-member issue leaked into tickets" \
    || ok "snapshot: membership is exactly the build-N label"
# System notes are label-change spam, not lessons.
jq -e '[.lessons_tail[].body] | any(test("added ~"))' "$T/snap.json" >/dev/null 2>&1 \
    && bad "snapshot: system notes leaked into the lessons tail" \
    || ok "snapshot: system notes excluded from the lessons tail"

# 7b. One-shot property: the whole read set costs 1 + members + active +
#     members + 1 calls from ONE invocation (3 members, 1 active, 1 build) —
#     the guard against re-adding a serial question-per-fact read, plus the
#     project-level milestone read that carries epic acceptance. Comment
#     threads and milestones ride the same concurrent fan-out, so they cost a
#     call each but almost no wall clock. P35 adds one more: the closed
#     members, without which an epic whose last ticket closed cannot be seen
#     at all — bought deliberately, and on the same fan-out.
n=$(wc -l < "$CALLS" | tr -d ' ')
[ "$n" = 11 ] && ok "snapshot: whole read set cost 11 calls (1 list + 1 milestones + 3 links + 1 MR + 3 threads + 1 lessons + 1 closed members)" \
             || bad "snapshot: read set cost $n calls, expected 11 ($(cat "$CALLS" | tr '\n' ';'))"
# Planted violation: MRs are fetched only for started tickets. If the active
# filter were dropped, ready-for-agent tickets (which cannot have an MR) would
# each add a call — the count above is what proves the filter is live.
grep -c "related_merge_requests" "$CALLS" | grep -q '^1$' \
    && ok "snapshot: MRs fetched only for started tickets, not the ready set" \
    || bad "snapshot: MR fan-out not bounded to started tickets"
# The mirror of it: comment threads are fetched for every member, active or
# not, because the rejection history has to survive `blocked` and `ready`.
# Narrowing this back to the active set is what lost #47's history.
grep -c "/notes" "$CALLS" | grep -q '^4$' \
    && ok "snapshot: comment threads fetched per member, not per active ticket" \
    || bad "snapshot: thread fan-out is $(grep -c '/notes' "$CALLS"), expected 4 (3 members + lessons)"

# 7c. Concurrency is real: with each call sleeping, wall clock must track the
#     slowest call, not the sum. Planted violation is the serial bound itself.
: > "$CALLS"
start=$(date +%s)
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$CALLS" STUB_SLEEP=0.6 "$TICK" snapshot >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 3 ] && ok "snapshot: fan-out is concurrent (${elapsed}s for 6 x 0.6s calls)" \
                     || bad "snapshot: fan-out ran serially (${elapsed}s — a serial run costs ~4s)"

# 7d. Blocking edges come from BOTH sources (SKILL.md: native links where the
#     tier allows, else the body's `## Blocked by` list), deduped and tagged.
b() { jq -r ".tickets[] | select(.iid==11) | .blocked_by[] | select(.iid==$1) | .$2" "$T/snap.json"; }
if [ "$(b 10 source)" = "both" ] && [ "$(b 14 source)" = "native" ] && [ "$(b 13 source)" = "body" ] \
   && [ "$(jq '.tickets[] | select(.iid==11) | .blocked_by | length' "$T/snap.json")" = 3 ]; then
    ok "snapshot: native + body blockers unioned, deduped, source-tagged"
else
    bad "snapshot: blocker union wrong ($(jq -c '.tickets[]|select(.iid==11)|.blocked_by' "$T/snap.json"))"
fi
# Planted violation: on a tier without issue links the API 403s. Body-sourced
# edges must survive, with a warning — a degraded field, not a dead document.
GLAB_CMD="$FX/glab-stub.sh" STUB_403_LINKS=1 "$TICK" snapshot > "$T/snap403.json" 2>/dev/null
if jq -e '(.tickets[] | select(.iid==11) | .blocked_by | map(.source) | unique == ["body"])
          and (.warnings | any(test("links")))' "$T/snap403.json" >/dev/null 2>&1; then
    ok "snapshot-violation: links 403 degrades to body edges + warning, not failure"
else
    bad "snapshot-violation: links 403 lost the body edges or the warning"
fi

# 7e. Blocker closed-state needs no extra call: the universe is the open set,
#     so a blocker absent from it is closed. #10 is open, #7 and #13 are not.
if [ "$(jq -r '.tickets[]|select(.iid==11)|.blocked_by[]|select(.iid==10)|.closed' "$T/snap.json")" = "false" ] \
   && [ "$(jq -r '.tickets[]|select(.iid==11)|.unblocked' "$T/snap.json")" = "false" ] \
   && [ "$(jq -r '.tickets[]|select(.iid==10)|.blocked_by[0].closed' "$T/snap.json")" = "true" ] \
   && [ "$(jq -r '.tickets[]|select(.iid==10)|.unblocked' "$T/snap.json")" = "true" ]; then
    ok "snapshot: blocker closed-state derived from the open set, no extra call"
else
    bad "snapshot: closed-state/unblocked derivation wrong"
fi
# A cross-project link cannot use that inference — say so, never guess.
if [ "$(jq -r '.tickets[]|select(.iid==12)|.blocked_by[0].closed' "$T/snap.json")" = "null" ] \
   && jq -e '.warnings | any(test("cross-project"))' "$T/snap.json" >/dev/null 2>&1 \
   && [ "$(jq -r '.tickets[]|select(.iid==12)|.unblocked' "$T/snap.json")" = "false" ]; then
    ok "snapshot: cross-project blocker is unknown + warned, never assumed closed"
else
    bad "snapshot: cross-project blocker was guessed at"
fi

# 7f. Epic rollup, no calls: an epic with open members is incomplete; one whose
#     last ticket closed is invisible in an open-issue payload, so it comes from
#     the Build issue body — which also carries a dropped-epic list and a config
#     snapshot, and neither is a build epic.
if [ "$(jq -r '.epics[]|select(.name=="Ledger core")|.complete' "$T/snap.json")" = "false" ] \
   && [ "$(jq -r '.epics[]|select(.name=="Ledger core")|.open_tickets' "$T/snap.json")" = "3" ] \
   && [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.complete' "$T/snap.json")" = "true" ] \
   && [ "$(jq '.epics|length' "$T/snap.json")" = "2" ]; then
    ok "snapshot: epic rollup derived from open members + build body, no calls"
else
    bad "snapshot: epic rollup wrong ($(jq -c '.epics' "$T/snap.json"))"
fi

# 7a2. Epic ACCEPTANCE is read back from the milestone the probe closes.
#      `lane.sh probe-result <epic> pass` closes that milestone and its own
#      source said "completeness stays DERIVED (nothing reads milestone
#      state)" — so `complete` meant only "no open tickets", an epic that was
#      never probed was indistinguishable from one that passed, and the
#      completion path closed the build over both. (Paid for: build-2
#      2026-08-04 — E4 probe FAILED and was never re-run after its fixes
#      merged, E6 and E7 never probed at all, build closed 97s after the last
#      ticket did; the human found it by noticing three open milestones.)
#      "Reporting surface" is the complete epic in this fixture; "Ledger core"
#      still has open tickets and must never be asked for a probe.
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"active"}]' \
    > "$FX/milestones.json"
SNAP > "$T/snap-probe.json" 2>/dev/null
if [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.needs_probe' "$T/snap-probe.json")" = "true" ] \
   && [ "$(jq -r '.epics[]|select(.name=="Ledger core")|.needs_probe' "$T/snap-probe.json")" = "false" ] \
   && [ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-probe.json")" = '["Reporting surface"]' ]; then
    ok "snapshot: a complete epic with an open milestone is listed as awaiting its probe"
else
    bad "snapshot: acceptance rollup wrong ($(jq -c '[.epics[]|{name,complete,accepted,needs_probe}]' "$T/snap-probe.json"))"
fi
# P34: the epic's OWN acceptance criteria travel with it, so a probe brief is
# ASSEMBLED from what must be true rather than invented from what has already
# broken. Without them a brief can only enumerate the last round's defects —
# it cannot catch what nobody has broken yet, and no two runs are comparable.
# (Paid for: E4 failed five straight probes and no run ever checked the
# FR-2/TR-2/PF-1 the epic itself cites. 2026-08-04.)
[ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.acceptance' "$T/snap-probe.json")" = "null" ] \
    && ok "snapshot: an epic with no criteria section reports acceptance null" \
    || bad "snapshot: invented acceptance from a description that has none"
# The warning fires ONLY for the epic actually about to be probed — an epic
# with open tickets still has time to write them, and warning on it is noise.
jq -e '[.warnings[] | select(test("Reporting surface") and test("Acceptance criteria"))] | length == 1' \
    "$T/snap-probe.json" >/dev/null \
    && jq -e '[.warnings[] | select(test("Ledger core") and test("Acceptance criteria"))] | length == 0' \
       "$T/snap-probe.json" >/dev/null \
    && ok "snapshot: warns about missing criteria only on the probe-ready epic" \
    || bad "snapshot: criteria warning fired wrong ($(jq -c '[.warnings[]|select(test("Acceptance"))]' "$T/snap-probe.json"))"
# With criteria present: surfaced verbatim, and the warning goes quiet.
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"active","description":"Scope prose.\n\n## Acceptance criteria\n\n- [ ] A user can file a report and read it back\n\n## Notes\n\nignored\n"}]' \
    > "$FX/milestones.json"
SNAP > "$T/snap-crit.json" 2>/dev/null
acc=$(jq -r '.epics[]|select(.name=="Reporting surface")|.acceptance' "$T/snap-crit.json")
case "$acc" in
    *"file a report and read it back"*)
        case "$acc" in
            *"Scope prose"*|*ignored*) bad "snapshot: acceptance leaked neighbouring sections" ;;
            *) ok "snapshot: acceptance is the criteria section alone, not the whole description" ;;
        esac ;;
    *) bad "snapshot: criteria not surfaced ($acc)" ;;
esac
jq -e '[.warnings[] | select(test("Acceptance criteria"))] | length == 0' "$T/snap-crit.json" >/dev/null \
    && ok "snapshot: the criteria warning goes quiet once they exist" \
    || bad "snapshot: still warning about criteria that are present"
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"active"}]' \
    > "$FX/milestones.json"
# The warning matters as much as the field: this failure is silent AND
# terminal, since the completion path tears the agent down on its way out.
jq -e '.warnings | any(test("no acceptance probe has passed"))' "$T/snap-probe.json" >/dev/null 2>&1 \
    && ok "snapshot: an unaccepted epic raises a warning, not just a field" \
    || bad "snapshot: unaccepted epic passed silently ($(jq -c '.warnings' "$T/snap-probe.json"))"
# A passed probe closed the milestone → accepted, and nothing left to schedule.
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"closed"}]' \
    > "$FX/milestones.json"
SNAP > "$T/snap-acc.json" 2>/dev/null
if [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.accepted' "$T/snap-acc.json")" = "true" ] \
   && [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.needs_probe' "$T/snap-acc.json")" = "false" ] \
   && [ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-acc.json")" = '[]' ]; then
    ok "snapshot: a closed milestone reads back as an accepted epic"
else
    bad "snapshot: accepted epic still wanted a probe ($(jq -c '[.epics[]|{name,accepted,needs_probe}]' "$T/snap-acc.json"))"
fi
# 7a3. P35: a finished epic is found from the milestones of this builds CLOSED
#      members, not from prose in the Build issue. The body parse reads markdown
#      LIST items; a Build issue that lists its epics in a TABLE matches nothing,
#      so every epic whose last ticket closed went invisible at exactly the
#      moment it became probe-ready. (Paid for: build-3 2026-08-04 — E4 reached
#      zero open tickets six times with `epics_awaiting_probe` empty each time,
#      and the probe only ever ran because a wave spotted the gap and reasoned
#      around it; in build-2 the same blind spot let E6 and E7 close unprobed.)
cat > "$FX/open-table.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":[],"assignees":[],
  "description":"## Selected epics\n\n| Epic | Milestone | Tickets | Status |\n|------|-----------|---------|--------|\n| Ledger core | %4 | #10 | open |\n| Reporting surface | %5 | #13 | open |\n"},
 {"iid":10,"title":"Add ledger table","project_id":1,"web_url":"https://x/10",
  "labels":["build-2","ready-for-agent"],"assignees":[],"updated_at":"2026-07-28T10:00:00Z",
  "milestone":{"title":"Ledger core"},"description":"## Risk tier\n\napi\n"}
]
EOF
printf '%s\n' '[{"iid":13,"milestone":{"title":"Reporting surface"}}]' > "$FX/closed-members.json"
printf '%s\n' '[{"title":"Ledger core","state":"active"},{"title":"Reporting surface","state":"active"}]' \
    > "$FX/milestones.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-table.json" STUB_CLOSED="$FX/closed-members.json" \
    STUB_LOG="$T/calls-p35" "$TICK" snapshot > "$T/snap-p35.json" 2>/dev/null
if [ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-p35.json")" = '["Reporting surface"]' ] \
   && [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.source' "$T/snap-p35.json")" = "closed-members" ] \
   && [ "$(jq -r '.epics[]|select(.name=="Ledger core")|.needs_probe' "$T/snap-p35.json")" = "false" ]; then
    ok "snapshot: an epic whose last ticket closed is found even when the Build issue lists epics in a table"
else
    bad "snapshot: finished epic invisible ($(jq -c '[.epics[]|{name,source,complete,needs_probe}]' "$T/snap-p35.json"))"
fi
# Planted violation: the fix must come from the CLOSED members, not from a
# loosened body parse. Same table body, no closed members — nothing is invented.
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-table.json" STUB_CLOSED="$FX/closed-none.json" \
    "$TICK" snapshot > "$T/snap-p35b.json" 2>/dev/null
[ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-p35b.json")" = '[]' ] \
    && ok "snapshot: with no closed members, a table-listed epic is not conjured into a probe" \
    || bad "snapshot: invented a probe-ready epic from prose ($(jq -c '.summary.epics_awaiting_probe' "$T/snap-p35b.json"))"
# An epic still holding open tickets is never reported complete, however many of
# its OTHER tickets have closed — closed members widen discovery, never verdict.
printf '%s\n' '[{"iid":9,"milestone":{"title":"Ledger core"}},{"iid":13,"milestone":{"title":"Reporting surface"}}]' \
    > "$FX/closed-mixed.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/open-table.json" STUB_CLOSED="$FX/closed-mixed.json" \
    "$TICK" snapshot > "$T/snap-p35c.json" 2>/dev/null
[ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-p35c.json")" = '["Reporting surface"]' ] \
    && ok "snapshot: an epic with an open ticket stays out of the probe list even with closed members" \
    || bad "snapshot: probed an epic that still has open work ($(jq -c '.summary.epics_awaiting_probe' "$T/snap-p35c.json"))"

# Planted violation: with NO milestones at all (a tier or project that does not
# use them) acceptance is UNKNOWN — it must never manufacture a probe request.
printf '[]\n' > "$FX/milestones.json"
SNAP > "$T/snap-noms.json" 2>/dev/null
if [ "$(jq -r '.epics[]|select(.name=="Reporting surface")|.accepted' "$T/snap-noms.json")" = "null" ] \
   && [ "$(jq -c '.summary.epics_awaiting_probe' "$T/snap-noms.json")" = '[]' ]; then
    ok "snapshot: no milestones means acceptance unknown, never a fabricated probe"
else
    bad "snapshot-violation: invented acceptance state with no milestones ($(jq -c '[.epics[]|{name,accepted,needs_probe}]' "$T/snap-noms.json"))"
fi
# Planted violation: an unscoped list scan would read the dropped epics and the
# config snapshot as build epics, and report them complete.
if jq -e '.epics | any(.name | test("Archive sweep|max_lanes"))' "$T/snap.json" >/dev/null 2>&1; then
    bad "snapshot-violation: dropped-epic / config list items read as build epics"
else
    ok "snapshot-violation: dropped epics and config lines are not build epics"
fi

# 7g. Empty universe is VALID, not an error: a heartbeat wave with no active
#     build must get a document it can no-op on.
echo '[{"iid":9,"title":"Some other issue","project_id":1,"labels":[],"assignees":[],"description":""}]' > "$FX/empty.json"
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/empty.json" "$TICK" snapshot > "$T/snapempty.json" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ "$(jq -r '.build' "$T/snapempty.json")" = "null" ] \
   && [ "$(jq '.tickets | length' "$T/snapempty.json")" = "0" ] \
   && [ "$(jq -r '.summary.ready_set_empty' "$T/snapempty.json")" = "true" ]; then
    ok "snapshot: no open Build issue yields a valid null-build document, exit 0"
else
    bad "snapshot: empty universe not handled (rc=$rc)"
fi

# 7h. Planted violation: the FOUNDATIONAL call failing must die, never emit an
#     empty ticket list — a failed query and an empty build must not look alike.
out=$(GLAB_CMD="$FX/glab-stub.sh" STUB_FAIL_STAGE1=1 "$TICK" snapshot 2>"$T/e2"); rc=$?
if [ "$rc" != 0 ] && [ -z "$out" ] && grep -q "open-issue list failed" "$T/e2"; then
    ok "snapshot-violation: failed list call dies loudly with no partial document"
else
    bad "snapshot-violation: failed list call produced rc=$rc, output '$out'"
fi

# 7i. A malformed `## Blocked by` section invents nothing.
cat > "$FX/malformed.json" <<'EOF'
[{"iid":1,"title":"Build 3","project_id":1,"labels":[],"assignees":[],"description":"- Solo epic\n"},
 {"iid":30,"title":"Odd ticket","project_id":1,"labels":["build-3","ready-for-agent"],"assignees":[],
  "description":"## Blocked by\n\nsee the thread, probably issue seven-ish\n"}]
EOF
GLAB_CMD="$FX/glab-stub.sh" STUB_OPEN="$FX/malformed.json" "$TICK" snapshot > "$T/snapmal.json" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ "$(jq '.tickets[0].blocked_by | length' "$T/snapmal.json")" = "0" ] \
   && [ "$(jq -r '.tickets[0].unblocked' "$T/snapmal.json")" = "true" ] \
   && jq -e '.warnings | any(test("Risk tier"))' "$T/snapmal.json" >/dev/null 2>&1; then
    ok "snapshot: unparseable Blocked-by invents no blockers; missing tier warns"
else
    bad "snapshot: malformed body mishandled (rc=$rc, $(jq -c '.tickets[0].blocked_by' "$T/snapmal.json"))"
fi

# 7j. jq is a hard dependency (the first one past shell/curl/launchctl, hence
#     its addition to the launchd PATH) — say so, do not emit garbage. macOS
#     ships jq in /usr/bin, so the jq-less PATH is built from symlinks to
#     exactly the tools the script touches before the dependency check.
JQLESS="$T/nojq"; mkdir -p "$JQLESS"
for b in bash basename cksum cut mkdir; do ln -sf "$(command -v "$b")" "$JQLESS/$b"; done
out=$(PATH="$JQLESS" GLAB_CMD="$FX/glab-stub.sh" "$TICK" snapshot 2>&1); rc=$?
case "$rc:$out" in
    0:*) bad "snapshot: missing jq did not fail" ;;
    *"jq required"*) ok "snapshot: missing jq fails loudly" ;;
    *) bad "snapshot: missing jq failed unclearly ($out)" ;;
esac

# 7j2. The document builder is a FILE now (snapshot.jq beside tick.sh), not a
#      370-line string inside a shell quote. Two things follow, and both are
#      cheap to check: it must parse on its own — which is the whole reason it
#      was lifted out, after an apostrophe in a comment ended the shell quote
#      mid-word and broke 250 tests — and a missing one must be named as a
#      missing file, not left to jq to complain about its -f argument.
SNAPJQ="$(dirname "$TICK")/snapshot.jq"
err=$(jq -n -f "$SNAPJQ" </dev/null 2>&1 || true)
case "$err" in
    *"syntax error"*|*"unexpected"*) bad "snapshot.jq: does not parse ($(printf '%s' "$err" | head -1))" ;;
    *) ok "snapshot.jq: parses standalone — checkable without running a snapshot" ;;
esac
# Planted violation: hide the file and the guard must name it.
mv "$SNAPJQ" "$T/snapshot.jq.hidden"
out=$(GLAB_CMD="$FX/glab-stub.sh" "$TICK" snapshot 2>&1); rc=$?
mv "$T/snapshot.jq.hidden" "$SNAPJQ"
case "$rc:$out" in
    0:*) bad "snapshot: ran with no document builder on disk" ;;
    *snapshot.jq*) ok "snapshot: a missing snapshot.jq is named as the missing file" ;;
    *) bad "snapshot: missing builder failed unclearly ($(printf '%s' "$out" | head -1))" ;;
esac

# 7k. Read-only guardrail: tick.sh must never mutate tracker state (its whole
#     charter). Every captured argv is checked against a mutating denylist.
if grep -Eq "issue (update|close|create|note)|mr (merge|create|update)|label (create|delete)|-X *(POST|PUT|DELETE|PATCH)" "$CALLS"; then
    bad "snapshot: a mutating glab call was issued ($(grep -E 'update|close|create|merge|-X' "$CALLS" | head -1))"
else
    ok "snapshot: every call was a read — no mutating verb in the captured argv"
fi
kill "$(cat "$LOOM_HOME/lanes/merge-51.pid" 2>/dev/null)" 2>/dev/null

# 7f. P11: gate eligibility is DERIVED, not left to the wave to work out.
#     Build 2 spawned a 12m53s verifier on a ticket whose code had merged 95
#     seconds earlier — it produced a FAIL verdict on shipped code — and gated
#     another twice at the identical commit, the duplicate re-running the live
#     suite for ~4 minutes before noticing.
PSNAP() { GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$T/calls-p11" "$TICK" snapshot 2>"$T/p11.err"; }
rm -f "$FX/notes-12.json"
PSNAP > "$T/p11.json"
if [ "$(jq -r '.tickets[] | select(.iid==12) | .gate.eligible' "$T/p11.json")" = "true" ] \
   && [ "$(jq -r '.summary.gateable' "$T/p11.json")" = "1" ] \
   && [ "$(jq -r '.tickets[] | select(.iid==12) | .gate.head' "$T/p11.json")" = "e52b7c1000000000000000000000000000000000" ]; then
    ok "gate: a ticket in review with an open MR and no verdict is gateable"
else
    bad "gate: a genuinely gateable ticket was not marked so ($(jq -c '.tickets[]|select(.iid==12)|.gate' "$T/p11.json"))"
fi

# 7f2. The merged-underneath case: no open MR left, so no verifier.
cat > "$FX/mrs-12.json" <<'EOF'
[{"iid":77,"title":"Ledger report view","state":"merged","draft":false,"web_url":"https://x/mr/77","source_branch":"t12","sha":"e52b7c1000000000000000000000000000000000"}]
EOF
PSNAP > "$T/p11b.json"
if [ "$(jq -r '.tickets[] | select(.iid==12) | .gate.eligible' "$T/p11b.json")" = "false" ] \
   && jq -e '.tickets[] | select(.iid==12) | .gate.reason | test("no open merge request")' "$T/p11b.json" >/dev/null 2>&1; then
    ok "gate: a ticket whose MR already merged is not gated again"
else
    bad "gate: merged-underneath ticket still gateable ($(jq -c '.tickets[]|select(.iid==12)|.gate' "$T/p11b.json"))"
fi
cat > "$FX/mrs-12.json" <<'EOF'
[{"iid":77,"title":"Ledger report view","state":"opened","draft":false,"web_url":"https://x/mr/77","source_branch":"t12","sha":"e52b7c1000000000000000000000000000000000"}]
EOF

# 7f3. The duplicate-dispatch case. A short sha in the comment must match the
#      long sha on the MR — verdicts are written by humans and models, and both
#      abbreviate.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Review complete. Verdict: PASS.\n\n<!-- orch-verdict PASS e52b7c1 -->"}]
EOF
PSNAP > "$T/p11c.json"
if [ "$(jq -r '.tickets[] | select(.iid==12) | .gate.eligible' "$T/p11c.json")" = "false" ] \
   && [ "$(jq -r '.tickets[] | select(.iid==12) | .gate.last_verdict.verdict' "$T/p11c.json")" = "PASS" ] \
   && [ "$(jq -r '.summary.gateable' "$T/p11c.json")" = "0" ]; then
    ok "gate: a HEAD already judged is not judged twice (short sha matches long)"
else
    bad "gate: duplicate dispatch not caught ($(jq -c '.tickets[]|select(.iid==12)|.gate' "$T/p11c.json" 2>&1) | err: $(head -2 "$T/p11.err"))"
fi

# 7f4. Planted violation: a verdict against a DIFFERENT commit must not suppress
#      the gate — otherwise a rejected ticket that was fixed and re-pushed would
#      never be re-reviewed, which is worse than the duplicate it prevents.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Rejected.\n\n<!-- orch-verdict FAIL 9999999 -->"}]
EOF
PSNAP > "$T/p11d.json"
[ "$(jq -r '.tickets[] | select(.iid==12) | .gate.eligible' "$T/p11d.json")" = "true" ] \
    && ok "gate-violation: a verdict on an older commit still leaves the new HEAD gateable" \
    || bad "gate-violation: a stale verdict suppressed the gate — fixes would never be re-reviewed"

# 7f6. The NEWEST verdict at a HEAD wins. Notes arrive newest-first, so taking
#      the last match returned the OLDEST — a ticket rejected and then passed at
#      an unchanged commit read as "already judged FAIL" and would never merge.
#      7f3 planted a single note, so ordering was never exercised at all.
#      (Found by an independent review, 2026-08-01.)
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T15:00:00Z","author":{"username":"gate"},
  "body":"Passed on re-review.\n\n<!-- orch-verdict PASS e52b7c1 -->"},
 {"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Rejected.\n\n<!-- orch-verdict FAIL e52b7c1 -->"}]
EOF
PSNAP > "$T/p11g.json"
[ "$(jq -r '.tickets[] | select(.iid==12) | .gate.last_verdict.verdict' "$T/p11g.json")" = "PASS" ] \
    && ok "gate: the newest verdict at a HEAD wins, not the first one fetched" \
    || bad "gate: took the older verdict ($(jq -c '.tickets[]|select(.iid==12)|.gate.last_verdict' "$T/p11g.json"))"
# Reversed arrival order must give the same answer. This is a CONSISTENCY check,
# not a guard: with notes already ascending, a plain `last` would also return
# PASS, so it would still pass with the fix reverted. The assertion above is the
# one that actually guards the behaviour.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T13:00:00Z","author":{"username":"gate"},
  "body":"Rejected.\n\n<!-- orch-verdict FAIL e52b7c1 -->"},
 {"system":false,"created_at":"2026-07-28T15:00:00Z","author":{"username":"gate"},
  "body":"Passed on re-review.\n\n<!-- orch-verdict PASS e52b7c1 -->"}]
EOF
PSNAP > "$T/p11h.json"
[ "$(jq -r '.tickets[] | select(.iid==12) | .gate.last_verdict.verdict' "$T/p11h.json")" = "PASS" ] \
    && ok "gate-violation: arrival order does not change which verdict wins" \
    || bad "gate-violation: answer flipped with arrival order — the sort is not doing the work"
rm -f "$FX/notes-12.json"

# 7f7. A `stale` gate lane still holds its ticket. Filtering on `running` alone
#      let a second verifier be dispatched onto a lane that was merely quiet.
#      (Found by an independent review, 2026-08-01.)
"$TICK" spawn-lane gate-12 --no-tick -- sleep 20 >/dev/null
for _ in $(seq 1 40); do [ -f "$LOOM_HOME/logs/lane-gate-12.log" ] && break; sleep 0.1; done
touch -t 202001010000 "$LOOM_HOME/logs/lane-gate-12.log"   # alive, silent since 2020
st=$("$TICK" lane-status | awk '$1=="gate-12"{print $3}')
PSNAP > "$T/p11i.json"
if [ "$st" = "stale" ] \
   && [ "$(jq -r '.tickets[] | select(.iid==12) | .gate.eligible' "$T/p11i.json")" = "false" ]; then
    ok "gate: a stale (alive but silent) verifier still blocks a second dispatch"
else
    bad "gate: stale lane state '$st' left the ticket gateable — a duplicate would spawn"
fi
kill "$(cat "$LOOM_HOME/lanes/gate-12.pid" 2>/dev/null)" 2>/dev/null
"$TICK" clear-lane gate-12 >/dev/null

# 7f5. P6 makes this one load-bearing. A lane may now spawn its own gate, and it
#      also fires a completion tick — so the very next wave sees the ticket in
#      `review` with a verifier already on it. Spawning a second under the same
#      id would overwrite the running pid file and rotate its log away, losing
#      the lane that is doing the work.
"$TICK" spawn-lane gate-12 --no-tick -- sleep 20 >/dev/null
PSNAP > "$T/p11e.json"
if [ "$(jq -r '.tickets[] | select(.iid==12) | .gate.eligible' "$T/p11e.json")" = "false" ] \
   && jq -e '.tickets[] | select(.iid==12) | .gate.reason | test("already running")' "$T/p11e.json" >/dev/null 2>&1; then
    ok "gate: a ticket with a verifier already running is not gated again"
else
    bad "gate: running gate lane did not suppress a second one ($(jq -c '.tickets[]|select(.iid==12)|.gate' "$T/p11e.json"))"
fi
kill "$(cat "$LOOM_HOME/lanes/gate-12.pid" 2>/dev/null)" 2>/dev/null
"$TICK" clear-lane gate-12 >/dev/null
# And it must free up again once that lane is gone, or a ticket gated once could
# never be re-gated after a rejection.
PSNAP > "$T/p11f.json"
[ "$(jq -r '.tickets[] | select(.iid==12) | .gate.eligible' "$T/p11f.json")" = "true" ] \
    && ok "gate-violation: with the lane cleared the ticket is gateable again" \
    || bad "gate-violation: ticket stayed suppressed after its gate lane ended"

# --- 7g. P8: is there parallelism to exploit at all? -----------------------
# Build 2 had four lanes and spent its first hour with zero or one startable
# ticket; peak concurrency for the whole run was 2. That is decided when the
# tickets are written, and it was invisible until wave 1 said so out loud.
# `graph` reads a snapshot, so it costs no extra tracker calls.
GN() { printf '{"iid":%s,"blocked_by":[],"state":"ready-for-agent","unblocked":true,"assignees":[]}' "$1"; }
GB() { printf '{"iid":%s,"blocked_by":[{"iid":%s,"closed":false}],"state":"blocked","unblocked":false,"assignees":[]}' "$1" "$2"; }
GRAPH() { printf '{"config":{"max_lanes":4},"tickets":[%s]}' "$1" | "$TICK" graph; }

# 7g1. Shapes that can be checked by hand. A diamond (1 → 2,3 → 4) is three
#      merge cycles deep and two wide at its widest — no scheduler needed to
#      know that, which is the point of asserting it.
out=$(GRAPH "$(GN 1),$(GB 2 1),$(GB 3 1),$(GB 4 2)")
if [ "$(printf '%s' "$out" | jq -r '.critical_path.length')" = "3" ] \
   && [ "$(printf '%s' "$out" | jq -r '.widest_level')" = "2" ] \
   && [ "$(printf '%s' "$out" | jq -r '.opening_width')" = "1" ] \
   && [ "$(printf '%s' "$out" | jq -c '[.levels[].iids]')" = "[[1],[2,3],[4]]" ]; then
    ok "graph: depth, width and levels match a hand-checked diamond"
else
    bad "graph: diamond analysed wrong ($(printf '%s' "$out" | jq -c '{critical_path,widest_level,opening_width}'))"
fi

# 7g2. The alarm fires on the shape build 2 actually had, and reports BOTH
#      numbers — how wide it opens and how wide it ever gets are different
#      questions, and the hour was lost to the first one.
out=$(GRAPH "$(GN 1),$(GB 2 1),$(GB 3 1)")
case "$(printf '%s' "$out" | jq -r .verdict)" in
    *"CHAIN-SHAPED"*|*"NARROW START"*) ok "graph: a chain-bound build says so before it starts" ;;
    *) bad "graph: no alarm on a build that opens 1 wide ($(printf '%s' "$out" | jq -r .verdict))" ;;
esac

# 7g3. Planted violation: crying wolf would train the human to skip this line.
#      A build with fewer tickets than lanes is SMALL, not chain-shaped, and a
#      build that fills its lanes is fine however deep it runs.
out=$(GRAPH "$(GN 1),$(GN 2),$(GN 3)")
case "$(printf '%s' "$out" | jq -r .verdict)" in
    *"CHAIN-SHAPED"*|*"NARROW START"*) bad "graph-violation: a small all-parallel build was flagged" ;;
    *) ok "graph-violation: fewer tickets than lanes is small, not chain-shaped" ;;
esac
out=$(GRAPH "$(GN 1),$(GN 2),$(GN 3),$(GN 4),$(GN 5)")
case "$(printf '%s' "$out" | jq -r .verdict)" in
    *"CHAIN"*|*"NARROW"*) bad "graph-violation: a build that fills every lane was flagged" ;;
    *) ok "graph-violation: a build that fills every lane raises nothing" ;;
esac

# 7g4. The widening fix P8 exists to enable: split the heavy blocker so the
#      dependents wait on a pinned interface instead of a merged body, and the
#      same four tickets open four wide instead of one.
before=$(GRAPH "$(GN 1),$(GB 2 1),$(GB 3 1),$(GB 4 1)" | jq -r .opening_width)
after=$(GRAPH "$(GN 1),$(GN 2),$(GN 3),$(GN 4)" | jq -r .opening_width)
[ "$before" = "1" ] && [ "$after" = "4" ] \
    && ok "graph: splitting the blocker is visible as the frontier opening 1 → 4" \
    || bad "graph: split not reflected (before=$before after=$after)"

# 7g5. A closed blocker constrains nothing, and a cycle is reported rather than
#      silently producing nonsense depths.
out=$(printf '{"config":{"max_lanes":4},"tickets":[{"iid":1,"blocked_by":[{"iid":99,"closed":true}],"state":"ready-for-agent","unblocked":true,"assignees":[]},%s]}' "$(GN 2)" | "$TICK" graph)
[ "$(printf '%s' "$out" | jq -r '.opening_width')" = "2" ] \
    && ok "graph: an already-closed blocker does not narrow the frontier" \
    || bad "graph: closed blocker still counted"
# A blocker OUTSIDE the build still holds its dependent back. Dropping those
# edges because the graph cannot see their depth made crucible report "opens 7
# wide" when three of the seven were waiting on issues outside the build —
# false reassurance, which is worse than no report at all.
out=$(printf '{"config":{"max_lanes":4},"tickets":[%s,{"iid":2,"blocked_by":[{"iid":900,"closed":false}],"state":"ready-for-agent","unblocked":false,"assignees":[]}]}' "$(GN 1)" | "$TICK" graph)
if [ "$(printf '%s' "$out" | jq -r '.opening_width')" = "1" ] \
   && [ "$(printf '%s' "$out" | jq -c '[.levels[].iids]')" = "[[1],[2]]" ]; then
    ok "graph: a blocker outside the build still keeps its dependent off the frontier"
else
    bad "graph: out-of-build blocker ignored ($(printf '%s' "$out" | jq -c '{opening_width, levels}'))"
fi
# The frontier is the level at DEPTH 0, not whatever sorts first. With every
# ticket blocked by something outside the build there is no depth-0 level, and
# reading levels[0] reported the depth-1 group as the frontier — "opens 3 wide"
# while nothing at all could start. The test above happens to include a free
# ticket, which is exactly why it missed this.
# (Found by an independent review, 2026-08-01.)
out=$(printf '{"config":{"max_lanes":4},"tickets":[
 {"iid":1,"blocked_by":[{"iid":900,"closed":false}],"state":"ready-for-agent","unblocked":false,"assignees":[]},
 {"iid":2,"blocked_by":[{"iid":901,"closed":false}],"state":"ready-for-agent","unblocked":false,"assignees":[]},
 {"iid":3,"blocked_by":[{"iid":902,"closed":false}],"state":"ready-for-agent","unblocked":false,"assignees":[]}]}' | "$TICK" graph)
if [ "$(printf '%s' "$out" | jq -r '.opening_width')" = "0" ] \
   && [ "$(printf '%s' "$out" | jq -r '.startable_now')" = "0" ]; then
    ok "graph: a build where nothing can start reports a frontier of 0, not its first level"
else
    bad "graph: opening_width $(printf '%s' "$out" | jq -r '.opening_width') with startable_now $(printf '%s' "$out" | jq -r '.startable_now') — false reassurance"
fi

out=$(GRAPH "$(GB 1 2),$(GB 2 1)")
[ "$(printf '%s' "$out" | jq -r '.cycle_suspected')" = "true" ] \
    && ok "graph: a dependency cycle is named, not silently mis-analysed" \
    || bad "graph: cycle went undetected"
out=$(printf '{"config":{"max_lanes":4},"tickets":[]}' | "$TICK" graph)
[ "$(printf '%s' "$out" | jq -r '.tickets')" = "0" ] \
    && ok "graph: an empty build analyses cleanly instead of erroring" \
    || bad "graph: empty build broke the analysis"

# --- 8. P22 layered config: repo > derived > global > built-in -------------
RC="$T/rc"; mkdir -p "$RC"
rc() { LOOM_REPO="$1" LOOM_GLOBAL_CONFIG="${2:-$RC/none.yml}" "$TICK" resolve-config; }

# 8a. Stack detection drives the gate pack, and tiers escalate.
mkdir -p "$RC/uv"; touch "$RC/uv/uv.lock"
out=$(rc "$RC/uv")
[ "$(echo "$out" | jq -r .stack)" = "uv" ] \
    && ok "resolve-config: uv stack detected from lockfile" \
    || bad "resolve-config: stack was $(echo "$out" | jq -r .stack)"
[ "$(echo "$out" | jq -r '.gates.docs|length')" -lt "$(echo "$out" | jq -r '.gates.logic|length')" ] \
    && ok "resolve-config: tiers escalate (docs < logic)" \
    || bad "resolve-config: tiers do not escalate"

# 8b. A derived tier never promises a command the repo cannot run: the
#     integration suite appears ONLY once its conventional marker exists.
[ "$(echo "$out" | jq -r '.gates.api|length')" -eq "$(echo "$out" | jq -r '.gates.logic|length')" ] \
    && ok "resolve-config: api == logic with no tests/integration present" \
    || bad "resolve-config: api suite invented an absent integration run"
mkdir -p "$RC/uv/tests/integration"
[ "$(rc "$RC/uv" | jq -r '.gates.api|length')" -gt "$(echo "$out" | jq -r '.gates.logic|length')" ] \
    && ok "resolve-config: integration tier appears once its marker exists" \
    || bad "resolve-config: integration marker ignored"

# 8c. An undetectable stack is a valid answer, not a crash (the `set -e`
#     trailing-false trap: a helper whose last test is false returns 1, and
#     `x=$(f)` then aborts the entire script).
mkdir -p "$RC/bare"
out=$(rc "$RC/bare" 2>&1); rc_code=$?
if [ "$rc_code" -eq 0 ] && [ "$(echo "$out" | jq -r '.gates|length')" = "0" ]; then
    ok "resolve-config: unknown stack yields empty gates, exit 0"
else
    bad "resolve-config: unknown stack failed (rc=$rc_code)"
fi

# 8d. Precedence: repo beats global beats built-in default.
printf 'max_lanes: 9\n' > "$RC/global.yml"
[ "$(rc "$RC/bare" | jq -r '.scalars.max_lanes.source')" = "default" ] \
    && ok "precedence: built-in default when neither layer sets it" || bad "precedence: default layer wrong"
[ "$(rc "$RC/bare" "$RC/global.yml" | jq -r '.scalars.max_lanes.value')" = "9" ] \
    && ok "precedence: global layer supplies the value" || bad "precedence: global layer ignored"
printf 'max_lanes: 2\n' > "$RC/bare/.loom.yml"
[ "$(rc "$RC/bare" "$RC/global.yml" | jq -r '.scalars.max_lanes.value')" = "2" ] \
    && ok "precedence: repo overrides global" || bad "precedence: repo did not win"

# 8d². The spend-controlling scalars are SURFACED, not just read internally:
# a wave composes spawn lines off resolve-config output, so a key it hides is
# a key the wave silently defaults (build-3 wave 1 2026-08-02 — global
# permission_mode/lane_model invisible in output, wave nearly spawned
# dontAsk lanes on the top-tier model).
printf 'permission_mode: auto\nlane_model: sonnet\nwave_model: sonnet\n' >> "$RC/global.yml"
out=$(rc "$RC/bare" "$RC/global.yml")
[ "$(echo "$out" | jq -r '.scalars.permission_mode.value')" = "auto" ] \
    && [ "$(echo "$out" | jq -r '.scalars.lane_model.value')" = "sonnet" ] \
    && [ "$(echo "$out" | jq -r '.scalars.wave_model.value')" = "sonnet" ] \
    && [ "$(echo "$out" | jq -r '.scalars.lane_model.source')" = "global" ] \
    && ok "resolve-config: permission_mode + wave/lane models surfaced with source" \
    || bad "resolve-config: spend-controlling scalars hidden from output"
[ "$(rc "$RC/bare" | jq -r '.scalars.lane_model.value')" = "" ] \
    && ok "resolve-config: unset lane_model is empty (inherit), not invented" \
    || bad "resolve-config: unset lane_model invented a value"
# P31: rework_model is spend-controlling too — it reprices every round-2+
# implementer — so it is surfaced with its layer like the rest.
printf 'rework_model: opus\n' >> "$RC/global.yml"
[ "$(rc "$RC/bare" "$RC/global.yml" | jq -r '.scalars.rework_model | "\(.value)/\(.source)"')" = "opus/global" ] \
    && ok "resolve-config: rework_model surfaced with its source layer" \
    || bad "resolve-config: rework_model hidden ($(rc "$RC/bare" "$RC/global.yml" | jq -c '.scalars.rework_model'))"
sed -i.bak '/^rework_model: opus$/d' "$RC/global.yml"
# `stall_action` decides whether a quiet-but-unfinished build resumes itself or
# just pings the human — the difference between an unattended loop and a
# manual-drive one. `tick.sh` acts on it every heartbeat, but it was readable
# only from the source: not in `resolve-config`, and not in `snapshot` either,
# so there was no way to ask what the build would actually do. `max_aux_lanes`
# is the milder case — `snapshot` publishes it, `resolve-config` did not.
printf 'stall_action: notify_only\nmax_aux_lanes: 2\n' >> "$RC/global.yml"
out=$(rc "$RC/bare" "$RC/global.yml")
[ "$(echo "$out" | jq -r '.scalars.stall_action | "\(.value)/\(.source)"')" = "notify_only/global" ] \
    && [ "$(echo "$out" | jq -r '.scalars.max_aux_lanes | "\(.value)/\(.source)"')" = "2/global" ] \
    && ok "resolve-config: stall_action and max_aux_lanes surfaced with their layer" \
    || bad "resolve-config: hidden ($(echo "$out" | jq -c '.scalars | {stall_action, max_aux_lanes}'))"
sed -i.bak '/^stall_action: notify_only$/d;/^max_aux_lanes: 2$/d' "$RC/global.yml"
# Planted violation: with nothing set anywhere, both must report the SAME
# defaults `tick.sh` itself falls back to. A published value that disagrees
# with the code is worse than no value — it is a confident wrong answer.
[ "$(rc "$RC/bare" | jq -r '.scalars.stall_action | "\(.value)/\(.source)"')" = "resume/default" ] \
    && [ "$(rc "$RC/bare" | jq -r '.scalars.max_aux_lanes.value')" = "4" ] \
    && ok "resolve-config: unset stall_action/max_aux_lanes report the real defaults" \
    || bad "resolve-config: default disagrees with the code ($(rc "$RC/bare" | jq -c '.scalars | {stall_action, max_aux_lanes}'))"

# 8e. A repo `gates:` block overrides the derived pack wholesale.
cat > "$RC/uv/.loom.yml" <<'EOF'
gates:
  docs:
    - "custom lint"
  api:
    - "CRUCIBLE_LIVE=1 uv run pytest -q"
EOF
out=$(rc "$RC/uv")
[ "$(echo "$out" | jq -r .gates_source)" = "repo" ] \
    && ok "resolve-config: repo gates block wins over the derived pack" \
    || bad "resolve-config: repo gates ignored ($(echo "$out" | jq -r .gates_source))"

# 8f. THE P4 DEFECT. A command with a leading VAR=VALUE does not match a rule
#     written for the bare command — that mismatch cost a completed gate
#     review its verdict. A generated allowlist must carry the env prefix.
echo "$out" | jq -e '.settings.permissions.allow | index("Bash(CRUCIBLE_LIVE=1 uv *)")' >/dev/null \
    && ok "P4: env-prefixed gate command gets its own matching allow rule" \
    || bad "P4: env-prefixed command has no matching rule"
# Planted violation: the bare-command rule alone must NOT be what matches it.
echo "$out" | jq -e '.settings.permissions.allow | index("Bash(uv *)") | not' >/dev/null \
    && ok "P4-violation: bare Bash(uv *) is absent, so only the prefixed rule can match" \
    || ok "P4: bare rule also present (harmless — the prefixed rule is what matters)"

# 8g. Every generated allow rule traces to a command that will actually run.
missing=0
# read -r line, never `for c in $(...)`: an env-prefixed head like
# `CRUCIBLE_LIVE=1 uv` contains a space and word-splitting would tear it in two.
while IFS= read -r c; do
    [ -n "$c" ] || continue
    echo "$out" | jq -e --arg r "Bash($c *)" '.settings.permissions.allow | index($r)' >/dev/null || missing=1
done <<EOF
$(echo "$out" | jq -r '.gates | to_entries[] | .value[]' | sed 's/^\(\([A-Za-z_][A-Za-z0-9_]*=[^ ]* \)*[^ ]*\).*/\1/' | sort -u)
EOF
[ "$missing" -eq 0 ] \
    && ok "P4: every gate command has a generated rule — allowlist cannot drift" \
    || bad "P4: a gate command has no allow rule"

# 8h. Lane cwd is a spawn concern, not a permission concern: spawn-lane --cwd
#     starts the lane in its worktree, so the allowlist must NOT need `cd`.
#     A cd rule reappearing means the spawn fix was reverted (P4/P16).
echo "$out" | jq -e '.settings.permissions.allow | index("Bash(cd *)") | not' >/dev/null \
    && ok "P4/P16: no cd rule — lanes are spawned in their worktree instead" \
    || bad "P4/P16: cd rule is back; spawn-lane --cwd was bypassed"

# 8h2. The probe's live-stack commands stay allowed — the E4 probe needed these
#      and neither was in the hand-written allowlist (P16).
echo "$out" | jq -e '.settings.permissions.allow | index("Bash(curl *)") and index("Bash(sleep *)")' >/dev/null \
    && ok "P16: probe live-stack commands (curl, sleep) are allowed" \
    || bad "P16: probe cannot run its live stack"

# 8h3. Polling a background stack is the only shape a headless probe can use —
#      it receives no notifications. Without these it can neither read the
#      server's output nor stop it, and the lane outlives its own server (P16).
echo "$out" | jq -e '.settings.permissions.allow | index("BashOutput") and index("KillShell")' >/dev/null \
    && ok "P16: probe can poll and kill a background stack" \
    || bad "P16: probe cannot poll/stop a background stack"

# 8i. Machine state must not leak into a repo's allowlist: a worktree helper
#     is a declared repo fact, never a PATH probe.
echo "$out" | jq -e '[.settings.permissions.allow[] | select(startswith("Bash(openemr-cmd"))] | length == 0' >/dev/null \
    && ok "resolve-config: undeclared worktree helper stays out of the allowlist" \
    || bad "resolve-config: machine PATH leaked into the allowlist"
printf 'worktree_cmd: openemr-cmd\n' >> "$RC/uv/.loom.yml"
rc "$RC/uv" | jq -e '.settings.permissions.allow | index("Bash(openemr-cmd *)")' >/dev/null \
    && ok "resolve-config: declared worktree_cmd is allowlisted" || bad "resolve-config: declared worktree_cmd ignored"

# 8j. Guardrails are global and non-negotiable — a repo cannot derive them away.
rc "$RC/uv" | jq -e '.settings.permissions.deny | index("Bash(git push --force*)") and index("Bash(rm -rf *)")' >/dev/null \
    && ok "resolve-config: hard guardrails always present in deny" || bad "resolve-config: guardrails missing"

# 8k. install-settings never silently discards a hand-edited allowlist.
mkdir -p "$RC/uv/.claude"; printf '{"permissions":{"allow":["Bash(handwritten *)"],"deny":[]}}\n' > "$RC/uv/.claude/settings.json"
out=$(LOOM_REPO="$RC/uv" "$TICK" install-settings 2>&1); rc_code=$?
if [ "$rc_code" -ne 0 ] && case "$out" in *"--force"*) true;; *) false;; esac; then
    ok "install-settings: differing hand-edited settings refused without --force"
else
    bad "install-settings: clobbered or accepted a hand-edited file (rc=$rc_code)"
fi
LOOM_REPO="$RC/uv" "$TICK" install-settings --force >/dev/null 2>&1
grep -q "CRUCIBLE_LIVE=1 uv" "$RC/uv/.claude/settings.json" \
    && ok "install-settings: --force writes the generated surface" || bad "install-settings: --force did not write"
out=$(LOOM_REPO="$RC/uv" "$TICK" install-settings 2>&1)
case "$out" in *"already current"*) ok "install-settings: idempotent on an unchanged repo";; *) bad "install-settings: not idempotent ($out)";; esac

# --- 9. P22 bootstrap: the WRITE half, split from tick.sh's read-only charter
BOOT="$(cd "$(dirname "$TICK")" && pwd)/bootstrap.sh"
BT="$T/boot"; mkdir -p "$BT/repo" "$BT/fx"
# bootstrap.sh now refuses to write repo files into a directory that is not a
# repo — REPO_ROOT falls back to $PWD, and from $HOME that targeted the human's
# own ~/.claude/settings.json. The fixture has to be a real repo to exercise the
# write paths at all.
git -C "$BT/repo" init -q 2>/dev/null || git init -q "$BT/repo" 2>/dev/null || :
cat > "$BT/fx/glab" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"/labels"*)    [ -n "${STUB_LABEL_FAIL:-}" ] && { echo "401 unauthorized" >&2; exit 1; }
                  # Names come from the API now, not `label list` text: the text
                  # includes DESCRIPTIONS, and a label described as "waiting on
                  # review" made the `review` state label look present.
                  if [ -n "${STUB_LABELS_JSON:-}" ] && [ -s "${STUB_LABELS_JSON}" ]; then
                    cat "$STUB_LABELS_JSON"
                  else
                    printf '%s' '[{"name":"blocked"},{"name":"unrelated"}]'
                  fi ;;
  "label create"*) [ -n "${STUB_CREATE_FAIL:-}" ] && { echo "denied" >&2; exit 1; }; exit 0 ;;
  *) echo "[]" ;;
esac
EOF
chmod +x "$BT/fx/glab"
BCALLS="$BT/calls.log"; : > "$BCALLS"
# LOOM_SKIP_BOOTSTRAP is emptied here — this section is the one that tests
# bootstrap, and the file-wide default switches it off everywhere else.
BOOTENV() { LOOM_REPO="$BT/repo" LOOM_HOME="$BT/home" LOOM_GLOBAL_CONFIG="$BT/g.yml" \
            GLAB_CMD="$BT/fx/glab" STUB_LOG="$BCALLS" LOOM_SKIP_BOOTSTRAP= \
            LOOM_WAVE_CMD="${WAVE_CMD:-echo wave-ran}" "$@"; }

# 9a. Seeds the global layer once, then leaves it alone.
BOOTENV "$BOOT" global-config >/dev/null
[ -f "$BT/g.yml" ] && ok "bootstrap: seeds the global config" || bad "bootstrap: no global config written"
printf 'max_lanes: 6\n' >> "$BT/g.yml"
BOOTENV "$BOOT" global-config >/dev/null
grep -q "max_lanes: 6" "$BT/g.yml" \
    && ok "bootstrap: existing global config is never clobbered" || bad "bootstrap: clobbered global config"

# 9b. Idempotent labels: only the missing ones are created, and nothing is
#     ever deleted — the write half gets the same class of guard as 7k.
out=$(BOOTENV "$BOOT" labels 2>&1)
case "$out" in *"9 created, 1 already present"*) ok "bootstrap: creates only the missing labels";;
               *) bad "bootstrap: label run reported '$out'";; esac
# P31's escalation labels are GitLab SCOPED labels — the colon is part of the
# name. The label table was `:`-separated, so read that way `model::opus`
# splits into name "model", no colour, and the rest as description: four
# labels created wrong and none of them ever matched.
grep -q -- "label create --name model::opus --color #6C3483" "$BCALLS" \
    && ok "bootstrap: a scoped model:: label keeps its colon and its colour" \
    || bad "bootstrap: model:: label mangled ($(grep -c 'label create' "$BCALLS") creates: $(grep 'label create' "$BCALLS" | tr '\n' ';'))"
if grep -qE "label (delete|remove)" "$BCALLS"; then
    bad "bootstrap: a label-destroying call was issued"
else
    ok "bootstrap: no destructive label call in the captured argv"
fi

# 9c. A tracker failure must not be recorded as success.
out=$(STUB_CREATE_FAIL=1 BOOTENV "$BOOT" labels 2>&1); rc_code=$?
[ "$rc_code" -ne 0 ] && ok "bootstrap: failed label creation exits nonzero" \
                     || bad "bootstrap: swallowed a label failure"

# 9c2. A failed label READ must not read as an empty tracker. Swallowing it
#      (`2>/dev/null || echo ""`) meant an auth error produced "no labels
#      exist", so every create was attempted, the first failed against a tracker
#      that already had it, and bootstrap then died on every tick forever. The
#      fixture has always had a STUB_LABEL_FAIL hook and nothing ever used it.
out=$(STUB_LABEL_FAIL=1 BOOTENV "$BOOT" labels 2>&1); rc_code=$?
if [ "$rc_code" -ne 0 ] && ! printf '%s' "$out" | grep -q "0 created"; then
    ok "bootstrap: an unreadable label list fails loudly, it does not look empty"
else
    bad "bootstrap: label read failure was treated as an empty tracker ($out)"
fi
printf '%s' "$out" | grep -q "label create" && bad "bootstrap: created labels despite a failed read" \
                                            || ok "bootstrap-violation: no creates attempted on a failed read"

# 9c3. Existence is matched on the NAME, never on free text. `glab label list`
#      output includes descriptions, so a label described as "waiting on review"
#      made the `review` state label look present: never created, exit 0,
#      sentinel written, never retried.
DESCJSON="$BT/desc-labels.json"
printf '%s' '[{"name":"triage","description":"waiting on review before merge-queue"}]' > "$DESCJSON"
out=$(STUB_LABELS_JSON="$DESCJSON" BOOTENV "$BOOT" labels --dry-run 2>&1)
case "$out" in
    *"would create 10"*) ok "bootstrap: a description mentioning a label name does not fake its presence" ;;
    *) bad "bootstrap: description text matched as a label name ($out)" ;;
esac

# 9c4. `--dry-run` must write nothing and must not claim it did. It also has to
#      survive `all`, which used to discard its arguments entirely — so
#      `bootstrap.sh all --dry-run` really created labels and really wrote
#      settings, the exact opposite of the flag.
: > "$BCALLS"
out=$(BOOTENV "$BOOT" all --dry-run 2>&1)
if printf '%s' "$out" | grep -q "would create" && ! grep -q "label create" "$BCALLS"; then
    ok "bootstrap: 'all --dry-run' honours the flag and writes nothing"
else
    bad "bootstrap: 'all --dry-run' performed real work ($out)"
fi
printf '%s' "$out" | grep -qE "^labels: [0-9]+ created" \
    && bad "bootstrap-violation: a dry run reported work it did not do" \
    || ok "bootstrap-violation: a dry run does not report creations it never made"
BOOTENV "$BOOT" all --bogus-flag >/dev/null 2>&1 \
    && bad "bootstrap: an unknown flag to 'all' was silently ignored" \
    || ok "bootstrap: an unknown flag to 'all' is refused, not dropped"

# 9c5. REPO_ROOT falls back to $PWD, so a repo-scoped write outside a repo must
#      be refused. From $HOME this targeted the human's own
#      ~/.claude/settings.json — the git check ran after the write and warned.
NOTREPO="$BT/not-a-repo"; mkdir -p "$NOTREPO"
if LOOM_REPO="$NOTREPO" LOOM_GLOBAL_CONFIG="$BT/g.yml" GLAB_CMD="$BT/fx/glab" \
   "$BOOT" settings >/dev/null 2>&1; then
    bad "bootstrap: wrote settings into a directory that is not a repo"
else
    ok "bootstrap: refuses to write repo files outside a repo"
fi
[ -e "$NOTREPO/.claude" ] \
    && bad "bootstrap-violation: it created .claude/ outside a repo anyway" \
    || ok "bootstrap-violation: nothing at all was created outside the repo"

# 9d. First tick bootstraps; later ticks do not pay for it again.
rm -rf "$BT/home"
out=$(BOOTENV "$TICK" tick 2>&1)
case "$out" in *"one-time bootstrap"*) ok "tick: first tick runs bootstrap";;
               *) bad "tick: first tick skipped bootstrap ($out)";; esac
[ -f "$BT/home/.bootstrapped" ] && ok "tick: sentinel written after a clean bootstrap" \
                                || bad "tick: no sentinel after bootstrap"
out=$(BOOTENV "$TICK" tick 2>&1)
case "$out" in *"one-time bootstrap"*) bad "tick: bootstrap re-ran on a later tick";;
               *) ok "tick: later ticks skip bootstrap";; esac

# 9e. Planted violation: a bootstrap that fails must NOT leave a sentinel, or
#     an unreachable tracker would be recorded as set up forever.
rm -rf "$BT/home"
out=$(STUB_CREATE_FAIL=1 BOOTENV "$TICK" tick 2>&1)
[ -f "$BT/home/.bootstrapped" ] && bad "tick: sentinel written despite a failed bootstrap" \
                                || ok "tick-violation: failed bootstrap leaves no sentinel, so it retries"
# The wave's own output goes to its log, never to tick's stdout — assert there.
if grep -rq "wave-ran" "$BT/home/logs" 2>/dev/null; then
    ok "tick: a failed bootstrap still runs the wave"
else
    bad "tick: bootstrap failure blocked the wave"
fi

# 9e-2. P30: an untrusted repo root is an INCOMPLETE bootstrap, never a fatal
#     one. `.claude/settings.json` is an artifact whose whole effect depends on
#     that flag, so writing it into an untrusted repo produces an artifact with
#     no consumer — but everything up to the first merge really does work
#     untrusted (build-1 got 77 minutes in), so the wave must still run and the
#     retry must be the existing sentinel machinery, not a new mechanism.
printf '{"projects":{"%s":{"hasTrustDialogAccepted":false}}}\n' "$BT/repo" > "$BT/untrusted-root.json"
rm -rf "$BT/home"
out=$(LOOM_TRUST_FILE="$BT/untrusted-root.json" BOOTENV "$TICK" tick 2>&1) || true
[ -f "$BT/home/.bootstrapped" ] && bad "bootstrap-violation (P30): untrusted repo recorded as bootstrapped" \
    || ok "bootstrap-violation (P30): an untrusted repo leaves no sentinel, so it retries"
case "$out" in *"not a trusted"*|*"incomplete"*) ok "bootstrap (P30): says plainly that trust is what is missing";;
    *) bad "bootstrap (P30): untrusted bootstrap gave no actionable reason ($out)";; esac
if grep -rq "wave-ran" "$BT/home/logs" 2>/dev/null; then
    ok "bootstrap (P30): untrusted is incomplete, not fatal — the wave still ran"
else
    bad "bootstrap (P30): an untrusted repo blocked the wave"
fi
# And it clears itself: once the human accepts, the very next tick completes.
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$BT/repo" > "$BT/untrusted-root.json"
out=$(LOOM_TRUST_FILE="$BT/untrusted-root.json" BOOTENV "$TICK" tick 2>&1) || true
[ -f "$BT/home/.bootstrapped" ] \
    && ok "bootstrap (P30): the next tick after accepting trust completes the bootstrap" \
    || bad "bootstrap (P30): bootstrap never completed after trust was granted ($out)"

# 9f. ntfy topic is layered like every other key, and derives from one global
#     prefix so no per-repo topic is ever hand-written.
NT="$T/ntfy"; mkdir -p "$NT/repo"; : > "$NT/calls"
cat > "$NT/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in http*) echo "$a" >> "$STUB_URL";; esac; done
EOF
chmod +x "$NT/curl"
printf 'ntfy:\n  topic_prefix: "pre-fix-"\n  push: [build_complete]\n' > "$NT/g.yml"
NTFY() { LOOM_REPO="$NT/repo" LOOM_HOME="$NT/home" LOOM_GLOBAL_CONFIG="$NT/g.yml" \
         NTFY_CMD="$NT/curl" NTFY_BASE="https://n" STUB_URL="$NT/calls" \
         "$TICK" notify build_complete t b >/dev/null 2>&1; }
# Both branches used to call `ok`, so this assertion could not fail — and its
# planted-violation partner below greps for a pattern that also passes on an
# empty file, so the whole ntfy subsection went green with notify completely
# broken. A test that reports safety it never checked is worse than no test.
NTFY; grep -q "https://n/pre-fix-repo" "$NT/calls" \
    && ok "ntfy: topic derived as <global prefix><repo name>" \
    || bad "ntfy: derived topic not observed ($(tail -1 "$NT/calls" 2>/dev/null))"
[ -s "$NT/calls" ] \
    && ok "ntfy: the stub actually recorded a call, so the checks below mean something" \
    || bad "ntfy: nothing was posted at all — every assertion here is vacuous"
# Planted violation: `topic:` lookup must not match `topic_prefix:` — if it
# did, the prefix itself would be posted to as a topic.
grep -q "https://n/pre-fix-$" "$NT/calls" \
    && bad "ntfy: topic_prefix was matched as topic" \
    || ok "ntfy-violation: topic_prefix is not mistaken for topic"
: > "$NT/calls"
printf 'ntfy:\n  topic: "repo-wins"\n  push: [build_complete]\n' > "$NT/repo/.loom.yml"
NTFY; grep -q "https://n/repo-wins" "$NT/calls" \
    && ok "ntfy: repo topic overrides the derived one" || bad "ntfy: repo topic ignored"

# --- 10. P14 usage limits and P15 wave crashes ----------------------------
# One session-limit event cost build 2 57m35s, a quarter of the whole run, and
# three wave logs were exactly `Execution error` — 15 bytes, no retry, no
# notification. Both live on the same code path (what happens when a wave exits
# nonzero), so they are tested together and asserted apart.
# Isolated state dir: these tests pause and halt builds, which no earlier test
# should inherit.
UT="$T/usage"; mkdir -p "$UT/repo" "$UT/home" "$UT/fx"
: > "$UT/g.yml"
cat > "$UT/repo/.loom.yml" <<'EOF'
crash_cap: 2
ntfy:
  topic: "usage-topic"
  push: [usage_pause, usage_resume, build_halted]
EOF
UCAP="$UT/ntfy-capture"; USTUB="$UT/ntfy-stub.sh"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$UCAP" > "$USTUB"; chmod +x "$USTUB"
# A fake `claude` for the wave: the basename is what makes tick treat it as a
# claude session, so the stub exercises the real streaming path. It counts its
# own invocations, which is how "retries exactly once" becomes observable.
cat > "$UT/fx/claude" <<'STUBEOF'
#!/usr/bin/env bash
echo "$@" >> "${WAVE_ARGV:-/dev/null}"
n=$(cat "$WAVE_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$WAVE_COUNT"
DONE='{"type":"result","subtype":"success","is_error":false,"result":"wave done"}'
case "${WAVE_MODE:-ok}" in
  ok)    printf '%s\n' "$DONE" ;;
  crash) echo "Execution error" >&2; exit 1 ;;
  flaky) if [ "$n" -ge 2 ]; then printf '%s\n' "$DONE"
         else echo "Execution error" >&2; exit 1; fi ;;
  limit) printf '%s\n' "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"rejected\",\"resetsAt\":${WAVE_RESET:-0},\"rateLimitType\":\"five_hour\"}}"
         echo "You've hit your session limit · resets 10pm" >&2; exit 1 ;;
  quiet_limit)                       # a limit with no resetsAt to read
         echo "You've hit your usage limit" >&2; exit 1 ;;
  crash_then_limit)                  # crashes once, then meets the wall
         if [ "$n" -ge 2 ]; then
           printf '%s\n' "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"rejected\",\"resetsAt\":${WAVE_RESET:-0},\"rateLimitType\":\"five_hour\"}}"
           echo "You have hit your session limit" >&2
         else echo "Execution error" >&2; fi
         exit 1 ;;
  healthy_limit_event)               # a NORMAL wave that merely reports capacity
         printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1,"rateLimitType":"five_hour"}}'
         printf '%s\n' "$DONE" ;;
esac
STUBEOF
chmod +x "$UT/fx/claude"
UENV() { LOOM_REPO="$UT/repo" LOOM_HOME="$UT/home" LOOM_GLOBAL_CONFIG="$UT/g.yml" \
         NTFY_CMD="$USTUB" WAVE_COUNT="$UT/count" WAVE_ARGV="$UT/argv" \
         LOOM_WAVE_CMD="$UT/fx/claude -p wave" LOOM_RETRY_BACKOFF_SECONDS=0 \
         LOOM_SKIP_BOOTSTRAP=1 "$@"; }
_ureset() { rm -rf "$UT/home/tick.lock.d"; rm -f "$UT/home/usage.pause" "$UT/home/tick.pending"; \
            echo 0 > "$UT/count"; : > "$UT/argv"; : > "$UCAP"; }

# 10a. P15: a crashed wave retries — and exactly once. Build 2's waves did
#      neither: `exit 1` and wait, while a crashed LANE at least still fired the
#      next tick. A retry that never gives up is its own failure mode, so the
#      count is asserted on the nose.
_ureset; : > "$UT/home/wave-failures"
WAVE_MODE=crash UENV "$TICK" tick >/dev/null 2>&1
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "2" ] && ok "crash: a failed wave is retried exactly once (2 attempts)" \
               || bad "crash: expected 2 wave attempts, saw $n"

# 10b. P15: stderr gets its own file. Merging it into the log is why those three
#      crashes left 15 bytes and nothing to diagnose from.
if ls "$UT/home/logs"/wave-*.err.log >/dev/null 2>&1 \
   && grep -ql "Execution error" "$UT/home/logs"/wave-*.err.log 2>/dev/null; then
    ok "crash: the error is captured in its own .err.log, not merged away"
else
    bad "crash: no separate stderr capture"
fi

# 10c. P15: a transient crash recovers inside the same tick.
_ureset
WAVE_MODE=flaky UENV "$TICK" tick >/dev/null 2>&1
rc=$?
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$rc" = "0" ] && [ "$n" = "2" ] \
    && ok "crash: a transient wave failure recovers on the retry, same tick" \
    || bad "crash: flaky wave gave rc=$rc after $n attempts"

# 10d. P15: what survives the retry escalates to a human instead of repeating
#      silently, and a success clears the count.
#      The threshold is a CONSTANT (3), not `crash_cap`: that key means
#      "implementer crashes before a ticket is blocked" everywhere else, and
#      one key driving two mechanisms meant tuning it for a flapping ticket
#      also changed when the whole build halted.
_ureset; : > "$UT/home/wave-failures"
for _ in 1 2 3; do
    rm -rf "$UT/home/tick.lock.d"
    WAVE_MODE=crash UENV "$TICK" tick >/dev/null 2>&1
done
grep -q "X-Orch-Event: build_halted" "$UCAP" 2>/dev/null \
    && ok "crash: repeated wave failures reach the human as build_halted" \
    || bad "crash: crash_cap consecutive failures raised no notification"
rm -rf "$UT/home/tick.lock.d"
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
[ -s "$UT/home/wave-failures" ] \
    && bad "crash: a good wave left the failure count standing" \
    || ok "crash: a good wave resets the consecutive-failure count"

# 10e. P14: a usage limit is NOT a crash. It must not be retried — the observed
#      run spent sessions rediscovering the same wall — and the resume time is
#      read from the stream's rate_limit_event, not parsed out of "resets 10pm".
_ureset
FUTURE=$(( $(date +%s) + 3600 ))
WAVE_MODE=limit WAVE_RESET="$FUTURE" UENV "$TICK" tick >/dev/null 2>&1
rc=$?
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "usage: a limit is not retried (1 attempt, no wasted session)" \
               || bad "usage: limit produced $n attempts — it was treated as a crash"
[ "$rc" = "0" ] && ok "usage: a limit exits clean — it is a pause, not a failure" \
                || bad "usage: limit exited $rc, which counts the build as broken"
[ "$(cat "$UT/home/usage.pause" 2>/dev/null)" = "$FUTURE" ] \
    && ok "usage: the pause holds the machine-readable resetsAt from the stream" \
    || bad "usage: pause file holds '$(cat "$UT/home/usage.pause" 2>/dev/null)', expected $FUTURE"
grep -q "X-Orch-Event: usage_pause" "$UCAP" 2>/dev/null \
    && ok "usage: the human is told the build is paused and until when" \
    || bad "usage: no usage_pause notification"

# 10e2. The limit check has to cover the RETRY too. A crash followed by a limit
#       wrote no pause, exited nonzero and counted as a crash — so every later
#       tick burned a fresh session against the same wall, which is precisely the
#       behaviour P14 exists to stop. The retry was checked only for crashes.
#       (Found by an independent review, 2026-08-01.)
_ureset; : > "$UT/home/wave-failures"
FUTURE2=$(( $(date +%s) + 3600 ))
WAVE_MODE=crash_then_limit WAVE_RESET="$FUTURE2" UENV "$TICK" tick >/dev/null 2>&1
rc=$?
[ "$(cat "$UT/home/usage.pause" 2>/dev/null)" = "$FUTURE2" ] \
    && ok "usage: a limit met on the retry still pauses the build" \
    || bad "usage: retry limit wrote pause '$(cat "$UT/home/usage.pause" 2>/dev/null)', expected $FUTURE2"
[ "$rc" = "0" ] && ok "usage: a limit on the retry exits clean, not as a build failure" \
                || bad "usage: retry limit exited $rc"
[ -s "$UT/home/wave-failures" ] \
    && bad "usage: a limit on the retry was counted against the crash cap" \
    || ok "usage-violation: a limit on the retry does not increment the failure count"

# 10f. P14: while paused, a tick spends NO session. This is the whole point —
#      polling a limit costs a session per poll and learns nothing.
echo 0 > "$UT/count"; rm -rf "$UT/home/tick.lock.d"
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "0" ] && ok "usage: a tick during the pause spends no session at all" \
               || bad "usage: paused tick still ran $n wave(s)"

# 10g. P14: and it resumes on its own once capacity is back.
echo 0 > "$UT/count"; rm -rf "$UT/home/tick.lock.d"
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$UT/home/usage.pause"
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "1" ] && [ ! -f "$UT/home/usage.pause" ] \
    && ok "usage: the pause lifts by itself once the reset time passes" \
    || bad "usage: after reset saw $n wave(s), pause file present=$([ -f "$UT/home/usage.pause" ] && echo yes || echo no)"
grep -q "X-Orch-Event: usage_resume" "$UCAP" 2>/dev/null \
    && ok "usage: resuming is announced too, so the pause has a visible end" \
    || bad "usage: no usage_resume notification"

# 10h. Planted violation: `rate_limit_event` appears in perfectly HEALTHY runs —
#      a live capture of a two-word session contains one with status "allowed".
#      Pausing on the event's mere presence would stall a working build, so the
#      failed session is the trigger and the event only supplies the time.
_ureset
WAVE_MODE=healthy_limit_event UENV "$TICK" tick >/dev/null 2>&1
[ -f "$UT/home/usage.pause" ] \
    && bad "usage-violation: a healthy wave's rate_limit_event paused the build" \
    || ok "usage-violation: a healthy rate_limit_event does not pause anything"

# 10i. A limit with nothing to read the reset time from still pauses — on a
#      fixed interval rather than a guessed clock time.
_ureset
WAVE_MODE=quiet_limit UENV "$TICK" tick >/dev/null 2>&1
at=$(cat "$UT/home/usage.pause" 2>/dev/null || echo 0)
[ "$at" -gt "$(date +%s)" ] 2>/dev/null \
    && ok "usage: a limit with no resetsAt still pauses, on a fixed backoff" \
    || bad "usage: unreadable reset time produced pause '$at'"

# 10j. `stop_and_wait` is for someone who wants to decide when to spend capacity
#      again: the pause never lifts on its own, and `resume` is the one step.
_ureset
printf 'usage_limit: stop_and_wait\n' >> "$UT/repo/.loom.yml"
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$UT/home/usage.pause"   # long past due
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "0" ] && ok "usage: stop_and_wait holds the pause past the reset time" \
               || bad "usage: stop_and_wait resumed by itself after $n wave(s)"
UENV "$TICK" resume >/dev/null 2>&1
rm -rf "$UT/home/tick.lock.d"
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
n=$(cat "$UT/count" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "usage: \`resume\` clears a stop_and_wait pause by hand" \
               || bad "usage: resume did not release the build ($n waves)"
sed -i.bak '/usage_limit: stop_and_wait/d' "$UT/repo/.loom.yml"

# 10k. `downshift_model` is the third policy: hand the session a cheaper model to
#      fall back to rather than stopping. Asserted on the argv the wave actually
#      received, and absent under the default policy.
_ureset
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
grep -q -- "--fallback-model" "$UT/argv" 2>/dev/null \
    && bad "downshift: fallback model passed under the default policy" \
    || ok "downshift: the default policy passes no fallback model"
_ureset
printf 'usage_limit: downshift_model\nfallback_model: sonnet\n' >> "$UT/repo/.loom.yml"
WAVE_MODE=ok UENV "$TICK" tick >/dev/null 2>&1
grep -q -- "--fallback-model sonnet" "$UT/argv" 2>/dev/null \
    && ok "downshift: the configured fallback model reaches the wave's argv" \
    || bad "downshift: no --fallback-model in '$(cat "$UT/argv" 2>/dev/null)'"
sed -i.bak '/^usage_limit: downshift_model/d;/^fallback_model: sonnet/d' "$UT/repo/.loom.yml"

# --- 11. P23: the diagnostic record ---------------------------------------
# Every number behind P1–P22 was reconstructed by hand from 31 transcripts plus
# filename arithmetic, and none of it survived to the next build. These events
# are written by the MACHINERY, so they exist even when a wave dies.
ET="$T/ev"; mkdir -p "$ET/repo"
git -C "$ET/repo" init -q 2>/dev/null || git init -q "$ET/repo" 2>/dev/null || :
EVENV() { LOOM_REPO="$ET/repo" LOOM_HOME="$ET/home" LOOM_GLOBAL_CONFIG="$ET/g.yml" \
          LOOM_TRUST_FILE="$LOOM_TRUST_FILE" LOOM_RETRY_BACKOFF_SECONDS=0 \
          LOOM_SKIP_BOOTSTRAP=1 "$@"; }
mkdir -p "$ET/home"; echo "build-9" > "$ET/home/.build-label"
EVF="$ET/home/events.jsonl"

# 11a. A crashed wave still leaves its record — the case a model-written log
#      would have missed, which is exactly when the record is needed.
LOOM_WAVE_CMD='sh -c "exit 1"' EVENV "$TICK" tick >/dev/null 2>&1
if [ -s "$EVF" ] && jq -e 'select(.ev=="wave_end" and .rc==1)' "$EVF" >/dev/null 2>&1; then
    ok "events: a wave that died still recorded its start, end and exit code"
else
    bad "events: nothing recorded for a crashed wave"
fi
[ "$(jq -s '[.[] | select(.ev=="wave_start" and .retry==1)] | length' "$EVF")" = "1" ] \
    && ok "events: the retry is distinguishable from the first attempt" \
    || bad "events: retry flag missing or wrong"

# 11b. Lane events carry type, exit code and a measured duration — not a
#      duration inferred from file mtimes, which is what build 2 forced.
LOOM_WAVE_CMD=true EVENV "$TICK" spawn-lane gate-77 --no-tick --cwd "$ET/repo" -- sh -c 'exit 7' >/dev/null 2>&1
for _ in $(seq 1 40); do jq -e 'select(.ev=="lane_exit")' "$EVF" >/dev/null 2>&1 && break; sleep 0.1; done
if jq -e 'select(.ev=="lane_exit" and .id=="gate-77" and .type=="gate" and .rc==7 and (.secs|type=="number"))' \
       "$EVF" >/dev/null 2>&1; then
    ok "events: a lane records id, type, exit code and measured seconds"
else
    bad "events: lane_exit missing fields ($(jq -c 'select(.ev=="lane_exit")' "$EVF" | tail -1))"
fi

# 11c. Both report views work off that one file, with no tracker calls.
out=$(EVENV "$TICK" report 2>&1)
case "$out" in
    *"Build build-9"*"mechanical rejections (rc 7)   1"*)
        ok "report: aggregates waves, lanes and rejections for the build" ;;
    *) bad "report: aggregate view wrong ($(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
out=$(EVENV "$TICK" report --ticket 77 2>&1)
case "$out" in
    *"gate-77"*"pregate rejection"*) ok "report: the per-ticket view traces its lanes and says why" ;;
    *) bad "report: ticket view wrong ($(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
# P31: the per-ticket trace names the model each round ran on — otherwise an
# escalation cannot be priced against its outcome, which is the whole test of
# whether escalating was worth it.
LOOM_WAVE_CMD=true EVENV "$TICK" spawn-lane impl-77 --no-tick --cwd "$ET/repo" -- /bin/echo --model opus >/dev/null 2>&1
out=$(EVENV "$TICK" report --ticket 77 2>&1)
case "$out" in *"impl-77"*"on opus"*) ok "report: a lane's model appears in the per-ticket trace" ;;
               *) bad "report: model missing from the ticket trace ($(printf '%s' "$out" | tr '\n' '|'))" ;;
esac

# 11d. Planted violation: the record must never feed a decision. If a wave read
#      it, it would be shadow state and constitution rule 1 would be broken — so
#      nothing outside the reporting verbs may even open it. `retro` joins that
#      allowlist for the same reason `report` is on it: neither is ever consulted
#      by a scheduling decision (P26). `render-events` (the build ticker,
#      2026-08-02) is the third display verb on the list: it renders the log
#      for a human pane and decides nothing.
if grep -nE '(<|read|cat|jq[^|]*)[^|]*\$EVENTS' "$TICK" | grep -vqE '_ev\(\)|>>|cmd_report|cmd_retro|REPORT|RETRO|-s "\$EVENTS"|render-events: display-only reader'; then
    bad "events-violation: something other than report/retro reads the event log"
else
    ok "events-violation: the event log is write-only outside report and retro"
fi

# 11e. A merge lane that finishes instantly must not fail its own spawn. The
#      lane releases the lock on exit, so stamping it from the parent AFTER the
#      spawn raced the lane — and lost, fatally, under set -e.
EVENV "$TICK" spawn-lane merge-78 --merge-lock --no-tick --cwd "$ET/repo" -- true >/dev/null 2>&1 \
    && ok "merge-lock: an instant merge lane spawns cleanly (no stamp race)" \
    || bad "merge-lock: spawn failed because the lane released before the stamp"
sleep 0.5
EVENV "$TICK" spawn-lane merge-79 --merge-lock --no-tick --cwd "$ET/repo" -- true >/dev/null 2>&1 \
    && ok "merge-lock-violation: the released lock is genuinely free for the next merge" \
    || bad "merge-lock-violation: lock left behind by an instant lane"


# --- 12. P26: retro --------------------------------------------------------
# The four things `report` deliberately does not compute. A hand-built log with
# known numbers, so every bucket below is checked against arithmetic, not vibes.
RT="$T/retro"; mkdir -p "$RT/home"
RTF="$RT/home/events.jsonl"
echo "build-r" > "$RT/home/.build-label"
RTENV() { LOOM_REPO="$ET/repo" LOOM_HOME="$RT/home" LOOM_GLOBAL_CONFIG="$ET/g.yml" \
          LOOM_SKIP_BOOTSTRAP=1 "$@"; }
_snap() { # _snap <ts> <tickets> <deps> <ready> <free>
    printf '{"ts":%s,"ev":"snapshot","build":"build-r","tickets":%s,"deps":%s,"ready":%s,"impl_free":%s,"max_lanes":4}\n' \
        "$1" "$2" "$3" "$4" "$5" >> "$RTF"
}
_lane() { # _lane <ts> <id> <type> <rc> <secs>
    printf '{"ts":%s,"ev":"lane_exit","build":"build-r","id":"%s","type":"%s","rc":%s,"secs":%s}\n' \
        "$1" "$2" "$3" "$4" "$5" >> "$RTF"
}
: > "$RTF"
# free>0 AND ready>0 for 10m: capacity that existed with work waiting for it.
_snap 1000 '{"1":"in-progress","2":"ready-for-agent"}' '{"1":[],"2":[1]}' 1 2
# every slot busy for 10m
_snap 1600 '{"1":"in-progress","2":"in-progress"}'     '{"1":[],"2":[1]}' 0 0
# ticket 1 gone (closed); slots free but nothing ready for 10m
_snap 2200 '{"2":"review"}'                            '{"2":[1]}'        0 2
_lane 1500 impl-1    impl 0 300
_lane 2100 gate-1    gate 7 10
_lane 2150 impl-2    impl 0 200
_lane 2190 gate-2-r2 gate 0 50
_lane 2195 impl-9    impl 1 20
printf '{"ts":2800,"ev":"wave_end","build":"build-r","rc":0,"secs":5}\n' >> "$RTF"

out=$(RTENV "$TICK" retro --build build-r 2>&1)
case "$out" in
    *"slack          10m0s"*) ok "retro: slack — free slots with ready work — is measured" ;;
    *) bad "retro: slack bucket wrong ($(printf '%s' "$out" | grep slack))" ;;
esac
case "$out" in
    *"capacity that existed, with work waiting"*) ok "retro: slack is called out, not just tabulated" ;;
    *) bad "retro: slack found but never flagged" ;;
esac
case "$out" in
    *"at capacity    10m0s"*) ok "retro: time with every impl slot busy is measured" ;;
    *) bad "retro: at-capacity bucket wrong" ;;
esac
case "$out" in
    *"starved        10m0s"*) ok "retro: starvation is distinguished from being at capacity" ;;
    *) bad "retro: starved bucket wrong" ;;
esac
# 80s of 580s lane-seconds produced nothing: rc7 + crash + re-gate.
case "$out" in
    *"total                  1m20s  13.8% of all lane time"*)
        ok "retro: rework is priced as a share of lane time" ;;
    *) bad "retro: rework total wrong ($(printf '%s' "$out" | grep -A1 're-gates'))" ;;
esac
# #2 was open 20m and had 4m10s of lane time: a queuing problem, not a coding one.
case "$out" in
    *"#2   open 20m0s   work 4m10s   wait 15m50s"*)
        ok "retro: wait is separated from work per ticket" ;;
    *) bad "retro: wait/work wrong ($(printf '%s' "$out" | grep '#2 '))" ;;
esac
case "$out" in
    *"#2 at 20m0s  ←  #1 at 10m0s"*) ok "retro: the chain that finished last is walked back through deps" ;;
    *) bad "retro: critical chain wrong ($(printf '%s' "$out" | grep '←')) " ;;
esac

# 12a. Planted violation: strip the field the buckets depend on. A missing
#      impl_free must read as UNKNOWN, never as zero — reading it as zero
#      reported a fully starved build as "at capacity 100%", which is exactly
#      what the first live run of this verb did.
jq -c 'if .ev == "snapshot" then del(.impl_free) else . end' "$RTF" > "$RTF.x" && mv "$RTF.x" "$RTF"
out=$(RTENV "$TICK" retro --build build-r 2>&1)
case "$out" in
    *"at capacity    0s"*"unrecorded     30m0s"*)
        ok "retro-violation: snapshots without the field are unrecorded, not at-capacity" ;;
    *) bad "retro-violation: a missing impl_free was silently bucketed ($(printf '%s' "$out" | grep -E 'capacity|unrecorded'))" ;;
esac

RTENV "$TICK" retro --nonsense >/dev/null 2>&1 \
    && bad "retro: an unknown argument was accepted" \
    || ok "retro: an unknown argument is refused rather than ignored"


# --- 13. P24: following a live lane ----------------------------------------
# P13 taught the MACHINERY to tell a busy lane from a dead one; it did nothing
# for a person. The .log is written in one go at exit, so mid-run there is
# nothing readable to watch. --follow renders the stream instead.
WT="$T/follow"; mkdir -p "$WT/home/lanes" "$WT/home/logs"
FENV() { LOOM_REPO="$ET/repo" LOOM_HOME="$WT/home" LOOM_GLOBAL_CONFIG="$ET/g.yml" \
         LOOM_SKIP_BOOTSTRAP=1 LOOM_FOLLOW_POLL=0.2 "$@"; }
FJ="$WT/home/logs/lane-impl-5.jsonl"
_say() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$1" >> "$FJ"; }
sleep 30 & FAKEPID=$!
echo "$FAKEPID" > "$WT/home/lanes/impl-5.pid"
# The session's own `system`/`init` record, which precedes any output it
# produces. Rendering it is what puts the model at the top of the pane
# (asked for by the human, 2026-08-03) — and a rate-limit record ahead of it
# is what the real stream opens with, so the model line must survive that.
printf '{"type":"rate_limit_event","rate_limit_info":{}}\n' >> "$FJ"
printf '{"type":"system","subtype":"init","model":"claude-opus-5","permissionMode":"auto","cwd":"/tmp/wt"}\n' >> "$FJ"
_say "first thing the lane said"
( FENV "$TICK" render-log impl-5 --follow > "$WT/out.txt" 2>&1 ) & FOLLOWER=$!
sleep 1
_say "something it said while being watched"
sleep 1
kill "$FAKEPID" 2>/dev/null || :
wait "$FOLLOWER" 2>/dev/null || :

case "$(cat "$WT/out.txt")" in
    *"first thing the lane said"*"something it said while being watched"*)
        ok "follow: renders what the lane wrote before AND during the watch" ;;
    *) bad "follow: missed events ($(tr '\n' '|' < "$WT/out.txt"))" ;;
esac
grep -q "lane impl-5 ended" "$WT/out.txt" \
    && ok "follow: exits on its own when the lane's process disappears" \
    || bad "follow: did not stop when the lane died"
# The model must be the FIRST thing rendered, not merely present somewhere:
# the point is knowing what a worker is running on before reading its output.
[ "$(grep -vE '^── lane ' "$WT/out.txt" | grep -c .)" -gt 0 ] \
    && [ "$(grep -vE '^── lane ' "$WT/out.txt" | grep . | head -1)" = "── model claude-opus-5 · permission auto ──" ] \
    && ok "follow: the resolved model is the first line of the pane" \
    || bad "follow: model line not first ($(grep -vE '^── lane ' "$WT/out.txt" | grep . | head -1))"
# Taken from the stream, so an alias or a usage-limit downshift shows what the
# session RESOLVED, not what the spawn line asked for.
grep -q "claude-opus-5" "$WT/out.txt" \
    && ok "follow: the model shown is the one the session resolved" \
    || bad "follow: resolved model missing from the render"

# 13a. Planted violation: the exit epilogue owns lane-<id>.log. A follower that
#      appended to it would corrupt the very artifact it is watching, so a
#      viewer writes to stdout and nothing else.
if [ -e "$WT/home/logs/lane-impl-5.log" ]; then
    bad "follow-violation: the follower wrote to the log the epilogue owns"
else
    ok "follow-violation: following writes to stdout, never to lane-<id>.log"
fi

# 13b. Read-only means no lock, no pid file, no event — that is what makes it
#      safe to point several viewers at one lane, and keeps a viewer from ever
#      being mistaken for a lane.
[ "$(ls "$WT/home/lanes" | tr -d ' ')" = "impl-5.pid" ] \
    && ok "follow: a viewer leaves no lane state behind" \
    || bad "follow: the follower wrote into the lanes dir ($(ls "$WT/home/lanes" | tr '\n' ' '))"
[ -s "$WT/home/events.jsonl" ] \
    && bad "follow: the follower recorded an event" \
    || ok "follow: a viewer records no event"

# 13c. Several viewers on one lane, because following is a file read.
sleep 30 & FAKE2=$!
echo "$FAKE2" > "$WT/home/lanes/impl-6.pid"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"shared"}]}}\n' \
    > "$WT/home/logs/lane-impl-6.jsonl"
( FENV "$TICK" render-log impl-6 --follow > "$WT/a.txt" 2>&1 ) & V1=$!
( FENV "$TICK" render-log impl-6 --follow > "$WT/b.txt" 2>&1 ) & V2=$!
sleep 1; kill "$FAKE2" 2>/dev/null || :; wait "$V1" "$V2" 2>/dev/null || :
if grep -q shared "$WT/a.txt" && grep -q shared "$WT/b.txt"; then
    ok "follow: two viewers can watch one lane at once"
else
    bad "follow: concurrent viewers interfered"
fi

FENV "$TICK" render-log impl-5 --bogus >/dev/null 2>&1 \
    && bad "follow: an unknown option was accepted" \
    || ok "follow: an unknown option is refused rather than treated as a lane id"
FENV "$TICK" render-log no-such-lane --follow >/dev/null 2>&1 \
    && bad "follow: followed a lane that does not exist" \
    || ok "follow: a lane with no pid file and no stream is refused"

# 13d. The pane opener is an accessory: it must refuse outside herdr rather than
#      degrade, and the UNATTENDED machinery must never call it.
#      Narrowed 2026-08-04. This used to be a text grep — tick.sh was not
#      allowed to contain the word "herdr" at all — and `install` now breaks
#      that letter deliberately: `start` raises the viewer, so arming a build
#      and opening a window on it are one gesture. What the rule protects is
#      unchanged and is now tested directly: nothing that runs without a human
#      at the keyboard may touch the pane opener.
HERDR_ENV= bash "$(dirname "$TICK")/watch-panes.sh" >/dev/null 2>&1 \
    && bad "watch-panes: ran outside a herdr session" \
    || ok "watch-panes: refuses to run outside herdr instead of degrading"
WPT="$T/wp-layer"; mkdir -p "$WPT/repo" "$WPT/home" "$WPT/agents"
WPCALLS="$WPT/calls"
printf '#!/bin/sh\necho called >> "%s"\n' "$WPCALLS" > "$WPT/stub"; chmod +x "$WPT/stub"
: > "$WPCALLS"
# HERDR_ENV=1 throughout: a lane inherits its parent's environment, so the
# multiplexer variable IS set in the unattended paths. Only the caller decides.
(  export HERDR_ENV=1 WATCH_PANES_CMD="$WPT/stub" LOOM_WAVE_CMD=true
   export LOOM_REPO="$WPT/repo" LOOM_HOME="$WPT/home" LOOM_PLIST_DIR="$WPT/agents"
   export LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1
   "$TICK" tick --auto      >/dev/null 2>&1 || :
   "$TICK" tick --from-lane >/dev/null 2>&1 || :
   "$TICK" snapshot         >/dev/null 2>&1 || :
   "$TICK" spawn-lane impl-1 --no-tick -- true >/dev/null 2>&1 || : ) || :
sleep 0.3
if [ ! -s "$WPCALLS" ]; then
    ok "watch-panes: no unattended path — tick, wave, snapshot, spawn — calls the pane opener"
else
    bad "watch-panes-violation: the unattended machinery opened panes ($(wc -l < "$WPCALLS") calls)"
fi
# And what launchd actually runs must carry no trace of the multiplexer.
out=$(LOOM_REPO="$WPT/repo" LOOM_HOME="$WPT/home" LOOM_PLIST_DIR="$WPT/agents" \
      LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1 \
      "$TICK" install --dry-run 2>&1)
wplist=$(echo "$out" | sed -n 's/^generated (dry-run): //p')
if [ -n "$wplist" ] && ! grep -qiE 'herdr|watch-panes' "$wplist"; then
    ok "watch-panes: the installed agent has no idea herdr exists"
else
    bad "watch-panes-violation: the launchd agent references the multiplexer"
fi

# 13e. Singleton: `/loom tick` launches the viewer opportunistically on
#      every manual tick, so a second launch must exit 0 quietly instead of
#      opening a duplicate pane per lane (2026-08-02). A live pid in the
#      state-dir pidfile short-circuits before the herdr checks; a stale one
#      does not.
echo $$ > "$LOOM_HOME/watch-panes.pid"
out=$(HERDR_ENV= bash "$(dirname "$TICK")/watch-panes.sh" 2>&1); rc_wp=$?
case "$rc_wp:$out" in 0:*"already running"*) \
    ok "watch-panes: second launch exits quietly when one is live";; \
    *) bad "watch-panes: singleton failed (rc=$rc_wp: $out)";; esac
echo 999999 > "$LOOM_HOME/watch-panes.pid"
HERDR_ENV= bash "$(dirname "$TICK")/watch-panes.sh" >/dev/null 2>&1 \
    && bad "watch-panes-violation: stale pidfile still short-circuited" \
    || ok "watch-panes: a stale pidfile does not block a fresh launch"
rm -f "$LOOM_HOME/watch-panes.pid"

# 13f. The ticker is kept alive every poll, not opened once at startup: the
#      viewer is a singleton that can outlive its panes, and launch-on-tick
#      exits at the pidfile — so a startup-only ticker is unrecoverable once
#      its pane dies. (Paid for: build-3 wave 1 2026-08-02 — a between-builds
#      viewer survived with its ticker pane long gone and the human watched a
#      four-lane wave with no ticker.) The stub's process-info always fails,
#      so every poll must reopen: startup + 2 bounded polls ≥ 2 ticker runs;
#      the old startup-only code produces exactly 1.
cat > "$T/herdr-stub" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${HERDR_CALLS:?}"
# Optional: the moment the ticker starts streaming, plant the off-marker —
# deterministic stand-in for "the human ran `ticker off` mid-run" (13g).
case "$*" in *"render-events --follow"*) [ -n "${HERDR_TOUCH_ON_RUN:-}" ] && touch "$HERDR_TOUCH_ON_RUN" ;; esac
# Liveness: with HERDR_DEAD unset, every pane reads dead (13f's reopen loop).
# With it set, only listed panes are dead — and splitting OFF a dead pane
# fails, as real herdr does (13i).
tgt=""; prev=""
for a in "$@"; do [ "$prev" = "--pane" ] && tgt="$a"; prev="$a"; done
dead() { [ -n "${HERDR_DEAD+x}" ] || return 0; case " $HERDR_DEAD " in *" $1 "*) return 0;; *) return 1;; esac; }
case "$1 $2" in
    "pane split")        if [ -n "${HERDR_DEAD+x}" ] && [ -n "$tgt" ] && dead "$tgt"; then exit 1; fi
                         n=$(wc -l < "$HERDR_CALLS" | tr -d ' '); echo "{\"result\":{\"pane\":{\"pane_id\":\"stub:p$n\"}}}" ;;
    "pane process-info") if dead "$tgt"; then exit 1; fi ;;
    # What the viewer re-anchors against (13n). HERDR_PANE_LIST unset means a
    # herdr with no panes left to offer, which is the fatal branch.
    "pane list")         printf '{"result":{"panes":['; s=""
                         for p in ${HERDR_PANE_LIST:-}; do printf '%s{"pane_id":"%s"}' "$s" "$p"; s=","; done
                         printf ']}}\n' ;;
esac
exit 0
EOF
chmod +x "$T/herdr-stub"
mkdir -p "$T/wp13f-home"; : > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    LOOM_HOME="$T/wp13f-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=0 \
    bash "$(dirname "$TICK")/watch-panes.sh" >/dev/null 2>&1 || :
tn=$(grep -c "render-events --follow" "$T/herdr-calls" || :)
if [ "$tn" -ge 2 ]; then
    ok "watch-panes: a dead ticker pane is reopened on the next poll"
else
    bad "watch-panes: ticker opened $tn time(s) across 2 polls — startup-only regression"
fi

# 13g. The deliberate off-gesture: reopen-every-poll (13f) ate the natural
#      "Ctrl-C, close the pane" gesture, so `ticker off|on` parks/removes a
#      state-dir marker the poll loop honors — off closes a live ticker and
#      keeps it closed; on brings it back. (Asked for by the human,
#      2026-08-02.) The verb needs no herdr and no running viewer.
WP="$(dirname "$TICK")/watch-panes.sh"
out=$(LOOM_HOME="$T/wp13f-home" bash "$WP" ticker off 2>&1) \
    && [ -f "$T/wp13f-home/ticker-off" ] \
    && ok "watch-panes: 'ticker off' plants the marker from any terminal" \
    || bad "watch-panes: ticker off failed ($out)"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    LOOM_HOME="$T/wp13f-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
tn=$(grep -c "render-events --follow" "$T/herdr-calls" || :)
[ "$tn" -eq 0 ] \
    && ok "watch-panes: the off-marker suppresses the ticker across polls" \
    || bad "watch-panes: ticker opened $tn time(s) despite the off-marker"
LOOM_HOME="$T/wp13f-home" bash "$WP" ticker on >/dev/null 2>&1 \
    && [ ! -f "$T/wp13f-home/ticker-off" ] \
    && ok "watch-panes: 'ticker on' clears the marker" \
    || bad "watch-panes: ticker on left the marker behind"
# Mid-run off: the stub plants the marker the instant the ticker starts
# streaming; the next poll must CLOSE the live ticker pane, not just stop
# reopening it.
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_TOUCH_ON_RUN="$T/wp13f-home/ticker-off" \
    LOOM_HOME="$T/wp13f-home" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
rm -f "$T/wp13f-home/ticker-off"
grep -q "^pane close " "$T/herdr-calls" \
    && ok "watch-panes: a mid-run off-marker closes the live ticker pane" \
    || bad "watch-panes: off-marker arrived mid-run but the ticker pane was never closed"

# 13h. The pane cap follows the build's width, and a lane waiting at the cap
#      is announced in the ticker, never silently invisible. `max_lanes` caps
#      implementers only — aux lanes (gate/merge/probe) run beside them — so
#      a flat cap of 4 hid a fifth lane with no trace (build-3 wave 2
#      2026-08-02: ticker said "#16 implementation begins", no pane appeared,
#      the human had to ask). Cap default = max_lanes + 2; WATCH_MAX_PANES
#      still overrides.
mkdir -p "$T/wp-cap-repo" "$T/wp-cap-home"
printf 'max_lanes: 7\n' > "$T/wp-cap-repo/.loom.yml"
: > "$T/herdr-calls"
out=$(HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    LOOM_REPO="$T/wp-cap-repo" LOOM_HOME="$T/wp-cap-home" LOOM_GLOBAL_CONFIG="$T/none.yml" \
    WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" 2>/dev/null || :)
case "$out" in *"up to 9 panes"*) ok "watch-panes: pane cap derives from max_lanes (+2 aux)";; \
    *) bad "watch-panes: cap did not derive from max_lanes ($(echo "$out" | head -1))";; esac
# Two lanes, cap 1: the second must leave a viewer_note in the event stream,
# and the ticker must render it.
mkdir -p "$T/wp-cap-home/lanes"
echo $$ > "$T/wp-cap-home/lanes/impl-91.pid"
echo $$ > "$T/wp-cap-home/lanes/impl-92.pid"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    LOOM_REPO="$T/wp-cap-repo" LOOM_HOME="$T/wp-cap-home" \
    WATCH_MAX_PANES=1 WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" >/dev/null 2>&1 || :
grep -q '"viewer_note"' "$T/wp-cap-home/events.jsonl" 2>/dev/null \
    && ok "watch-panes: a lane at the pane cap writes a viewer_note event" \
    || bad "watch-panes: lane waited at the cap with no trace in the event stream"
LOOM_HOME="$T/wp-cap-home" "$TICK" render-events 2>/dev/null | grep -q "viewer: impl-9[12] waiting for a pane (cap 1)" \
    && ok "ticker: a cap-waiting lane renders as a viewer line" \
    || bad "ticker: viewer_note did not render"
rm -f "$T/wp-cap-home/lanes"/impl-9*.pid

# 13i. Layout: when the stack anchor dies (humans tidy idle panes) but the
#      right column is alive, a new lane RE-ANCHORS on the bottom-most live
#      column pane — never a fresh right split off the session pane, which
#      dropped impl-39 into the left region on top of the ticker (human,
#      2026-08-02). Pane ids are pinned to the stub's call counter: anchor
#      = call 1 → stub:p1; lane92's split = call 6 → stub:p6 (the pane the
#      test then kills); the only --direction right split allowed is call 1.
mkdir -p "$T/wp13i-home/lanes"
for n in 91 92 93; do echo $$ > "$T/wp13i-home/lanes/impl-$n.pid"; done
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_DEAD="stub:p6" WATCH_TICKER=0 WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13i-home" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
rights=$(grep -c -- "--direction right" "$T/herdr-calls" || :)
if [ "$rights" = 1 ] && grep -q -- "split --pane stub:p1 --direction down" "$T/herdr-calls"; then
    ok "watch-panes: dead stack anchor re-anchors on a live column pane"
else
    bad "watch-panes: re-anchor failed (right-splits=$rights, calls: $(grep split "$T/herdr-calls" | tail -3 | tr '\n' ';'))"
fi
rm -f "$T/wp13i-home/lanes"/impl-9*.pid

# 13k. Same layout invariant, the OTHER branch: when the column has vanished
#      entirely, the viewer reopens it off the session pane — and must repeat
#      the STARTUP ORDER while doing so (close ticker → split right → reopen
#      ticker), or the new pane is carved out of the left column and lands on
#      the ticker. (Asked for by the human, 2026-08-03.) Setup: the anchor
#      (stub:p1) is dead, so lane 91 takes it, lane 92 cannot split down off
#      it, and no live column pane remains to re-anchor on — the fresh-right
#      path, with a live ticker to move out of the way first.
mkdir -p "$T/wp13k-home/lanes"
for n in 91 92; do echo $$ > "$T/wp13k-home/lanes/impl-$n.pid"; done
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_DEAD="stub:p1" WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13k-home" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$WP" >/dev/null 2>&1 || :
close_ln=$(grep -n "^pane close " "$T/herdr-calls" | head -1 | cut -d: -f1)
right_ln=$(grep -n -- "--direction right" "$T/herdr-calls" | tail -1 | cut -d: -f1)
tick_ln=$(grep -n -- "render-events --follow" "$T/herdr-calls" | tail -1 | cut -d: -f1)
ticks=$(grep -c -- "render-events --follow" "$T/herdr-calls" || :)
if [ -n "$close_ln" ] && [ -n "$right_ln" ] && [ -n "$tick_ln" ] \
   && [ "$close_ln" -lt "$right_ln" ] && [ "$right_ln" -lt "$tick_ln" ] && [ "$ticks" -ge 2 ]; then
    ok "watch-panes: a fresh column closes the ticker, splits right, reopens it"
else
    bad "watch-panes: ticker was not moved out of the way for a fresh column (close=$close_ln right=$right_ln ticker=$tick_ln runs=$ticks)"
fi
rm -f "$T/wp13k-home/lanes"/impl-9*.pid

# 13l. The viewer needs its OWN off-switch, not just the ticker's. Until now,
#      closing everything meant killing the process by its pidfile from a
#      command someone had to be told — and the header's "Ctrl-C to stop" is
#      true only of a foreground run, while the skill launches this detached
#      on purpose. So in normal use there was no way to stop it. (Asked for by
#      the human, 2026-08-04.)
VH="$T/viewer-off-home"; mkdir -p "$VH/lanes"
out=$(LOOM_HOME="$VH" bash "$WP" off 2>&1)
[ -f "$VH/viewer-off" ] && ok "watch-panes: 'off' plants the viewer switch from any terminal" \
                        || bad "watch-panes: off did not plant the switch ($out)"
# The switch outranks every launch path — including the opportunistic launch a
# manual tick does, which would otherwise undo the human on the next tick.
: > "$T/herdr-calls"
out=$(HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    LOOM_HOME="$VH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" 2>&1)
if [ ! -s "$T/herdr-calls" ] && printf '%s' "$out" | grep -q "switched off"; then
    ok "watch-panes: a switched-off viewer refuses to launch and opens no panes"
else
    bad "watch-panes: off-switch did not stop a launch ($(head -c 120 "$T/herdr-calls"))"
fi
LOOM_HOME="$VH" bash "$WP" on >/dev/null 2>&1
[ ! -f "$VH/viewer-off" ] && ok "watch-panes: 'on' clears the viewer switch" \
                          || bad "watch-panes: on left the switch behind"
# Mid-run: a viewer already polling must notice the switch and close its panes
# on the way out, since it can outlive the session that started it.
mkdir -p "$VH/lanes"; echo $$ > "$VH/lanes/impl-77.pid"
: > "$T/herdr-calls"
# Wait for the viewer to be genuinely up (pidfile written) before switching
# it off — startup reads config and can outlast a fixed sleep, and planting
# the marker first would test the startup path instead of the mid-run one.
( for _ in $(seq 1 40); do
      [ -f "$VH/watch-panes.pid" ] && break; sleep 0.25
  done
  LOOM_HOME="$VH" bash "$WP" off >/dev/null 2>&1 ) &
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 LOOM_HOME="$VH" WATCH_POLLS=10 WATCH_POLL_SECONDS=1 bash "$WP" >/dev/null 2>&1 || :
wait 2>/dev/null || :
grep -q "^pane close " "$T/herdr-calls" \
    && ok "watch-panes: a mid-run 'off' closes the panes it owns and exits" \
    || bad "watch-panes: mid-run off left panes open ($(grep -c . "$T/herdr-calls") calls)"
rm -f "$VH/lanes/impl-77.pid" "$VH/viewer-off"

# 13m. The ticker advertises its own quit key, and the words for both the hint
#      and the reopen come from HERE — tick.sh must never learn this viewer
#      exists (13-violation enforces that), so it prints what it is handed.
grep -q "LOOM_TICKER_QUIT_HINT" "$WP" && grep -q "LOOM_TICKER_REOPEN_HINT" "$WP" \
    && ok "watch-panes: supplies the ticker's quit hint and reopen wording" \
    || bad "watch-panes: ticker hints are not passed to the follow command"
# And the quit key must leave the SAME durable marker the off-switch uses, or
# the viewer would simply reopen the pane on its next poll.
grep -q 'ticker-off' "$TICK" \
    && ok "ticker: quitting leaves the durable marker, so it stays closed" \
    || bad "ticker: quit does not persist — the viewer would reopen the pane"

# 13p. A concluded ticket takes its pane with it however it concluded (P41).
#      Panes are recycled on purpose, so a finished lane keeps its ticket
#      stamp — but the "did the ticket actually close" read ran for merge-*
#      alone, so a ticket closed any other way left its pane stamped forever.
#      #72 was reclassified and closed by hand on 2026-08-04 and its pane sat
#      labelled "ticket 72 — idle" for work that would never come back.
cat > "$T/glab-p41-stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"issues/95"*) echo '{"state":"closed"}' ;;
    *"issues/96"*) echo '{"state":"opened"}' ;;
    *"issues/97"*) exit 1 ;;                      # tracker unreachable
    *) echo '{}' ;;
esac
EOF
chmod +x "$T/glab-p41-stub.sh"
mkdir -p "$T/wp13p-home/lanes"
sleep 1 & echo $! > "$T/wp13p-home/lanes/gate-95.pid"
sleep 1 & echo $! > "$T/wp13p-home/lanes/impl-96.pid"
sleep 1 & echo $! > "$T/wp13p-home/lanes/gate-97.pid"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    GLAB_CMD="$T/glab-p41-stub.sh" WATCH_TICKER=0 WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13p-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=2 \
    bash "$WP" >/dev/null 2>&1 || :
[ "$(grep -c "^pane close " "$T/herdr-calls" || :)" = 1 ] \
    && ok "watch-panes: a gate lane whose ticket closed takes its pane with it" \
    || bad "watch-panes: expected exactly 1 close (the closed ticket), got $(grep -c '^pane close ' "$T/herdr-calls" || :)"
grep -q "rename .* ticket 96 — idle" "$T/herdr-calls" \
    && ok "watch-panes: an open ticket keeps its pane and its stamp" \
    || bad "watch-panes: the open ticket lost its pane — reuse is broken"
grep -q "rename .* ticket 97 — idle" "$T/herdr-calls" \
    && ok "watch-panes: a failed tracker read keeps the pane, as before" \
    || bad "watch-panes: an unreachable tracker closed a pane it could not judge"
rm -f "$T/wp13p-home/lanes"/*.pid
# Planted violation: put the read back behind merge-* and the closed ticket
# keeps its pane — the stale stamp the human spotted.
# The copy needs tick.sh beside it: the viewer finds tick.sh by its own
# directory, so a copy alone in $T resolves nothing and dies before it can
# prove anything.
mkdir -p "$T/wpmod"; ln -sf "$TICK" "$T/wpmod/tick.sh"
sed 's/\*)  # P41/merge-*)  # P41/' "$WP" > "$T/wpmod/wp-mergeonly.sh"; chmod +x "$T/wpmod/wp-mergeonly.sh"
mkdir -p "$T/wp13p2-home/lanes"
sleep 1 & echo $! > "$T/wp13p2-home/lanes/gate-95.pid"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    GLAB_CMD="$T/glab-p41-stub.sh" WATCH_TICKER=0 WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13p2-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=2 \
    bash "$T/wpmod/wp-mergeonly.sh" >/dev/null 2>&1 || :
grep -q "^pane close " "$T/herdr-calls" \
    && bad "watch-panes-violation: the merge-only check still closed the pane" \
    || ok "watch-panes-violation: with merge-* alone, a closed ticket keeps its pane forever"
rm -f "$T/wp13p2-home/lanes"/*.pid

# 13n. A viewer that cannot open a pane says so and exits, instead of polling
#      forever looking healthy (P39). Every split hangs off the pane the
#      viewer was launched from; when that session is gone the id refers to
#      nothing, every split fails, and the empty string `new_pane` returns
#      used to read as "skip this". build-3 2026-08-04, 12:46→12:59: the
#      process was alive the whole time and opened nothing — no anchor, no
#      ticker, no lane panes — while two lanes ran unseen.
NH="$T/wp13n-home"; mkdir -p "$NH/lanes"; : > "$T/herdr-calls"
out=$(HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_DEAD="stub:p0" WATCH_TICKER=0 LOOM_HOME="$NH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$WP" 2>&1); rc_n=$?
if [ "$rc_n" != 0 ] && printf '%s' "$out" | grep -q "stub:p0" && printf '%s' "$out" | grep -q "exiting"; then
    ok "watch-panes: a viewer with a dead anchor exits non-zero and names it"
else
    bad "watch-panes: blind viewer survived (rc=$rc_n: $(printf '%s' "$out" | tr '\n' ' ' | head -c 140))"
fi
# Exiting is only useful if it releases the singleton — otherwise every later
# launch path still reports "already running" against a viewer showing nothing.
[ ! -f "$NH/watch-panes.pid" ] \
    && ok "watch-panes: a blind viewer leaves no pidfile holding the singleton" \
    || bad "watch-panes: the dead viewer kept the pidfile — nothing can replace it"
# The other direction: with a live pane to re-anchor on, the viewer recovers
# and opens its column there rather than dying. stub:p0 is the dead launching
# pane and is skipped; stub:p9 is what herdr still has.
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_DEAD="stub:p0" HERDR_PANE_LIST="stub:p0 stub:p9" WATCH_TICKER=0 \
    LOOM_HOME="$NH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" >/dev/null 2>&1; rc_n=$?
if [ "$rc_n" = 0 ] && grep -q -- "split --pane stub:p9 --direction right" "$T/herdr-calls"; then
    ok "watch-panes: a dead anchor re-anchors on a live pane instead of dying"
else
    bad "watch-panes: re-anchor failed (rc=$rc_n, calls: $(grep split "$T/herdr-calls" | tr '\n' ';'))"
fi
# Planted violation: strip the fatal call and the identical run polls on and
# exits 0 — the exact 13-minute shape, a healthy-looking process showing
# nothing. `wp_blind ` → `: ` leaves the function definition alone.
# The copy needs tick.sh beside it — the viewer finds tick.sh by its own
# directory, so a copy alone in $T resolves nothing and dies at 127 before it
# can prove anything.
mkdir -p "$T/wpmod"; ln -sf "$TICK" "$T/wpmod/tick.sh"
sed 's/wp_blind /: /' "$WP" > "$T/wpmod/wp-noblind.sh"; chmod +x "$T/wpmod/wp-noblind.sh"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    HERDR_DEAD="stub:p0" WATCH_TICKER=0 LOOM_HOME="$NH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
    bash "$T/wpmod/wp-noblind.sh" >/dev/null 2>&1; rc_n=$?
[ "$rc_n" = 0 ] \
    && ok "watch-panes-violation: without the fatal exit the blind viewer runs on" \
    || bad "watch-panes-violation: rc=$rc_n — something other than wp_blind ended the run"

# 13o. The singleton pidfile is removed only while it still names this
#      process (P40). The trap used to delete it unconditionally, so an older
#      viewer shutting down took a newer one's file with it — found live on
#      2026-08-04: pid 1805 running with no pidfile at all. Stand-in for the
#      overlap: overwrite the file with a foreign pid once the viewer is up,
#      the way a newer viewer would.
PH="$T/wp13o-home"; mkdir -p "$PH/lanes"; : > "$T/herdr-calls"
( for _ in $(seq 1 40); do
      [ -f "$PH/watch-panes.pid" ] && break; sleep 0.25
  done
  echo 999999 > "$PH/watch-panes.pid" ) &
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 LOOM_HOME="$PH" WATCH_POLLS=3 WATCH_POLL_SECONDS=1 bash "$WP" >/dev/null 2>&1 || :
wait 2>/dev/null || :
[ "$(cat "$PH/watch-panes.pid" 2>/dev/null)" = 999999 ] \
    && ok "watch-panes: an exiting viewer keeps a pidfile it no longer owns" \
    || bad "watch-panes: the exiting viewer deleted another viewer's pidfile"
# And it still cleans up after itself in the ordinary case, or every crashed
# viewer would block the next launch forever.
rm -f "$PH/watch-panes.pid"; : > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 LOOM_HOME="$PH" WATCH_POLLS=1 WATCH_POLL_SECONDS=0 bash "$WP" >/dev/null 2>&1 || :
[ ! -f "$PH/watch-panes.pid" ] \
    && ok "watch-panes: a viewer that owns its pidfile removes it on exit" \
    || bad "watch-panes: pidfile survived its own viewer — the next launch is blocked"
# Planted violation: remove the ownership test and the foreign pidfile goes
# with it, which is how a live viewer ends up with none.
sed 's/_owns_pidfile &&/: \&\&/' "$WP" > "$T/wpmod/wp-noown.sh"; chmod +x "$T/wpmod/wp-noown.sh"
( for _ in $(seq 1 40); do
      [ -f "$PH/watch-panes.pid" ] && break; sleep 0.25
  done
  echo 999999 > "$PH/watch-panes.pid" ) &
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    WATCH_TICKER=0 LOOM_HOME="$PH" WATCH_POLLS=3 WATCH_POLL_SECONDS=1 \
    bash "$T/wpmod/wp-noown.sh" >/dev/null 2>&1 || :
wait 2>/dev/null || :
[ ! -f "$PH/watch-panes.pid" ] \
    && ok "watch-panes-violation: without the check the foreign pidfile is deleted" \
    || bad "watch-panes-violation: pidfile survived, so the ownership test proves nothing"

# 13j. A finished STORY closes its pane (2026-08-02): probe pane closes when
#      its lane ends; a merge pane closes only if the ticket really closed —
#      merge lanes exit cleanly without merging (merge-21, twice), so a
#      blocked merge keeps its pane idle. Lanes live at poll 1, die before
#      poll 2 (their pid is a short sleep).
cat > "$T/glab-close-stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"issues/95"*) echo '{"state":"closed"}' ;;
    *"issues/96"*) echo '{"state":"opened"}' ;;
    *) echo '{}' ;;
esac
EOF
chmod +x "$T/glab-close-stub.sh"
mkdir -p "$T/wp13j-home/lanes"
sleep 1 & echo $! > "$T/wp13j-home/lanes/merge-95.pid"
sleep 1 & echo $! > "$T/wp13j-home/lanes/merge-96.pid"
sleep 1 & echo $! > "$T/wp13j-home/lanes/probe-e9.pid"
: > "$T/herdr-calls"
HERDR_CALLS="$T/herdr-calls" HERDR_CMD="$T/herdr-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
    GLAB_CMD="$T/glab-close-stub.sh" WATCH_TICKER=0 WATCH_MAX_PANES=9 \
    LOOM_HOME="$T/wp13j-home" WATCH_POLLS=2 WATCH_POLL_SECONDS=2 \
    bash "$WP" >/dev/null 2>&1 || :
closes=$(grep -c "^pane close " "$T/herdr-calls" || :)
[ "$closes" = 2 ] \
    && ok "watch-panes: merged ticket and finished probe close their panes" \
    || bad "watch-panes: expected 2 pane closes (merged + probe), got $closes"
grep -q "rename .* ticket 96 — idle" "$T/herdr-calls" \
    && ok "watch-panes: a merge that did not merge keeps its pane idle" \
    || bad "watch-panes: blocked-merge pane was not kept"
rm -f "$T/wp13j-home/lanes"/*.pid

# 14. Proposals hygiene: PROPOSALS.md holds ONLY open / in progress / deferred
#     rows — implemented and dropped ones move to PROPOSALS_ARCHIVED.md, per
#     the file's own "Archive on implementation" rule. That rule is prose at
#     the top of a file that gets edited surgically, so twice in one day an
#     editor changed a row without ever reading it (retro session and the
#     interactive session, 2026-08-02). A prose rule partial readers skip
#     must be a failing test instead.
PROPOSALS="$(dirname "$TICK")/../PROPOSALS.md"
if [ -f "$PROPOSALS" ]; then
    stray=$(awk -F'|' '/^\| P[0-9]+/ {
        s=$4; gsub(/^[ \t]+|[ \t]+$/, "", s)
        if (s !~ /^(open|in progress|deferred)/) print $2 ": " s
    }' "$PROPOSALS")
    if [ -n "$stray" ]; then
        bad "proposals-hygiene: non-open rows squatting in PROPOSALS.md → $stray"
    else
        ok "proposals-hygiene: every PROPOSALS.md row is open/in progress/deferred"
    fi
else
    bad "proposals-hygiene: PROPOSALS.md not found next to scripts/"
fi

# 15. Retiring the old separate watcher. There used to be a second launchd
#     agent per repo, and `tick --auto` watching before the lock made it
#     redundant. The way OUT is what has to keep working: a machine with the
#     old agent still loaded lands on `quiet-tick` once, sheds it, and is
#     done. Without that the stale agent would spin on a usage error every
#     60s with nothing able to unload it. (Paid for: 2026-08-02 — 26 zombie
#     launchd agents from earlier suite runs.)
export LOOM_PLIST_DIR="$T/plists15"
mkdir -p "$LOOM_PLIST_DIR"
: > "$LCTL_CALLS"
out=$("$TICK" quiet-tick 2>&1); rc=$?
[ "$rc" = 0 ] && case "$out" in *retired*) true ;; *) false ;; esac \
    && ok "watcher: the old entry point retires itself and exits clean" \
    || bad "watcher: quiet-tick rc=$rc, said: $out"
grep -q '^bootout ' "$LCTL_CALLS" \
    && ok "watcher: retirement booted the old agent out through the seam" \
    || bad "watcher: retirement never reached the launchctl stub"
# Planted violation: arming is GONE, not merely discouraged. A verb still able
# to write a watcher plist would let the retired agent come back.
: > "$LCTL_CALLS"
"$TICK" watcher-arm >/dev/null 2>&1 \
    && bad "watcher: watcher-arm still exists — the second agent can be resurrected" \
    || ok "watcher: no verb can arm a second agent any more"
ls "$LOOM_PLIST_DIR" 2>/dev/null | grep -q '\.watch\.plist$' \
    && bad "watcher: a .watch plist was written after arm was removed" \
    || ok "watcher: arming wrote no plist, because there is nothing left to arm"

# 16. The build ticker (2026-08-02): lane.sh verbs feed the event stream,
#     render-events turns it into timestamped human lines, and a corrupt
#     line must not kill a --follow pane that runs for a whole build.
LANE="$(dirname "$TICK")/lane.sh"
EVH="$T/ev-home"; mkdir -p "$EVH"
GSTUB="$T/glab-ok.sh"; printf '#!/bin/sh\nexit 0\n' > "$GSTUB"; chmod +x "$GSTUB"
LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" "$LANE" transition 4 review >/dev/null 2>&1
echo "gate looks good" | LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" "$LANE" verdict 4 pass abcd1234 >/dev/null 2>&1
grep -q '"ev":"ticket_transition"' "$EVH/events.jsonl" 2>/dev/null \
    && ok "ticker: lane.sh transition appended its event" \
    || bad "ticker: lane.sh transition wrote no event"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"#4 → review (implementation complete, awaiting gate)"*) \
    ok "ticker: transition renders as a human line";; \
    *) bad "ticker: transition rendered wrong ($out)";; esac
case "$out" in *"#4 gate verdict: PASS @ abcd1234"*) \
    ok "ticker: verdict renders outcome and sha";; \
    *) bad "ticker: verdict rendered wrong ($out)";; esac
printf '%s\n' "$out" | grep -Ev '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}  ' | grep -q . \
    && bad "ticker: a line is missing its local timestamp prefix ($out)" \
    || ok "ticker: every line carries a local timestamp prefix"
# Planted violation: raw jq dies on a corrupt line; fromjson? is the guard.
# Later events must still render after garbage lands mid-stream.
echo 'not json at all' >> "$EVH/events.jsonl"
LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" "$LANE" close 4 >/dev/null 2>&1
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"#4 merged and closed"*) \
    ok "ticker: a corrupt line does not kill the stream";; \
    *) bad "ticker: corrupt line broke rendering ($out)";; esac
# Clean exits are suppressed (their outcome event tells the story; chained
# handoffs stamp them after the successor spawned, which rendered backwards) —
# but failures and probe results must still show.
LOOM_HOME="$EVH" "$TICK" event lane_exit id impl-4 type impl rc 0 secs 5
LOOM_HOME="$EVH" "$TICK" event lane_exit id gate-4 type gate rc 7 secs 5
LOOM_HOME="$EVH" "$TICK" event lane_exit id probe-audio type probe rc 0 secs 5
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"implementation ended"*) \
    bad "ticker: clean impl exit rendered (reads backwards after a chained spawn)";; \
    *) ok "ticker: clean impl exit suppressed — outcome events tell the story";; esac
case "$out" in *"#4 — pregate REJECTED"*) \
    ok "ticker: a pregate rejection still renders";; \
    *) bad "ticker: pregate rejection missing ($out)";; esac
case "$out" in *"epic audio — acceptance probe ended (rc 0"*) \
    ok "ticker: a clean probe exit still renders (it has no outcome event)";; \
    *) bad "ticker: probe exit missing ($out)";; esac
# A wave's intent line (long silent setup) renders verbatim with the
# "wave:" prefix — the human watching a quiet ticker during probe prep
# read the silence as a stall (2026-08-02).
LOOM_HOME="$EVH" "$TICK" event wave_note note "preparing probe worktrees for E2, E3"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"wave: preparing probe worktrees for E2, E3"*) \
    ok "ticker: a wave_note intent line renders";; \
    *) bad "ticker: wave_note missing ($out)";; esac
# The renderer owns the prefix, so a note that writes its own is deduped, not
# doubled ("wave: wave: only #47 is ready" — human, 2026-08-03). Case and
# spacing vary because a model types it, so the strip must too.
LOOM_HOME="$EVH" "$TICK" event wave_note note "wave: only #47 is ready"
LOOM_HOME="$EVH" "$TICK" event wave_note note "Wave:  spinning up the E5 probe"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"wave: wave:"*|*"wave: Wave:"*) \
    bad "ticker: a self-prefixed wave_note rendered doubled ($(printf '%s' "$out" | grep -c 'wave: [Ww]ave:') line(s))";; \
    *) ok "ticker: a note that writes its own 'wave:' prefix is deduped";; esac
case "$out" in *"wave: only #47 is ready"*) \
    ok "ticker: stripping the prefix keeps the note itself intact";; \
    *) bad "ticker: dedupe ate the note ($out)";; esac
case "$out" in *"wave: spinning up the E5 probe"*) \
    ok "ticker: dedupe is case- and space-insensitive";; \
    *) bad "ticker: mixed-case self-prefix survived ($out)";; esac
# Planted violation: a note that merely MENTIONS a wave mid-sentence must not
# be truncated — the strip is anchored to the start, not a search-and-replace.
LOOM_HOME="$EVH" "$TICK" event wave_note note "requeued after the wave: see #12"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"wave: requeued after the wave: see #12"*) \
    ok "ticker: 'wave:' inside a note is left alone";; \
    *) bad "ticker: the strip is not anchored to the start ($out)";; esac
# Notifications land in the ticker too — a banner is transient, a push may
# be missed; the pane must carry the same stalled/wedged/complete facts.
NTFY_CMD=/usr/bin/true LOOM_HOME="$EVH" "$TICK" notify ticket_blocked "T9 blocked — decision needed" "b" >/dev/null 2>&1
grep -q '"ev":"notify"' "$EVH/events.jsonl" 2>/dev/null \
    && ok "ticker: a delivered notification writes its event" \
    || bad "ticker: notify left no event line"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"⚑ T9 blocked — decision needed"*) \
    ok "ticker: a notification renders with its title";; \
    *) bad "ticker: notification missing from render ($out)";; esac
# Failure lines stand out (asked for by the human, 2026-08-02): a glyph in
# the plain bytes always, ANSI color only on a tty or under LOOM_COLOR=1 —
# so pipes, greps and these very assertions see stable bytes by default.
echo "regression in error handling" | LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" "$LANE" verdict 5 fail beef1234 >/dev/null 2>&1
LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" "$LANE" transition 6 blocked >/dev/null 2>&1
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"✗ #5 gate verdict: FAIL @ beef1234"*) \
    ok "ticker: a FAIL verdict wears the failure glyph";; \
    *) bad "ticker: FAIL verdict not glyphed ($out)";; esac
case "$out" in *"⚠ #6 → blocked — a human decision is needed"*) \
    ok "ticker: a blocked transition wears the warning glyph";; \
    *) bad "ticker: blocked transition not glyphed ($out)";; esac
printf '%s\n' "$out" | grep -q $'\033' \
    && bad "ticker: escape codes leaked into non-tty output" \
    || ok "ticker: plain bytes when output is not a terminal"
cout=$(LOOM_COLOR=1 LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
printf '%s\n' "$cout" | grep -q $'\033\[1;31m' \
    && ok "ticker: LOOM_COLOR=1 paints failure lines red" \
    || bad "ticker: forced color produced no red escape"
# Probe outcomes reach the ticker through one verb (asked for by the human,
# 2026-08-02): probe-result posts the report on the Build issue AND emits the
# event — before this, the outcome lived only in prose and the ticker ended
# at "probe ended (rc 0)" with no verdict.
echo "epic exercised end to end, no defects" | LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" \
    "$LANE" probe-result 36 e4 pass >/dev/null 2>&1
echo "2 fix tickets filed" | LOOM_HOME="$EVH" GLAB_CMD="$GSTUB" \
    "$LANE" probe-result 36 e5 fail >/dev/null 2>&1
grep -q '"ev":"probe_result"' "$EVH/events.jsonl" 2>/dev/null \
    && ok "ticker: probe-result appended its event" \
    || bad "ticker: probe-result wrote no event"
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"✓ epic e4 — acceptance probe PASSED"*) \
    ok "ticker: probe PASS renders highlighted";; \
    *) bad "ticker: probe pass rendered wrong ($out)";; esac
case "$out" in *"✗ epic e5 — acceptance probe FAILED (fix tickets filed)"*) \
    ok "ticker: probe FAIL renders highlighted";; \
    *) bad "ticker: probe fail rendered wrong ($out)";; esac
# P31: an escalation the human paid for must be visibly TAKEN. The model is
# read off the spawned command line, not self-reported, and the default case
# (no --model, the lane inherits the session model) stays quiet.
LOOM_HOME="$EVH" "$TICK" spawn-lane impl-46 -- /bin/echo --model opus >/dev/null 2>&1
LOOM_HOME="$EVH" "$TICK" spawn-lane impl-47 -- /bin/echo plain >/dev/null 2>&1
out=$(LOOM_HOME="$EVH" "$TICK" render-events 2>&1)
case "$out" in *"#46 — implementation started (opus)"*) \
    ok "ticker: an escalated lane names its model";; \
    *) bad "ticker: escalation not shown ($(printf '%s' "$out" | grep '#4[67]'))";; esac
case "$out" in *"#47 — implementation started ("*) \
    bad "ticker: an unescalated lane invented a model suffix";; \
    *) ok "ticker: the default model stays quiet";; esac
for l in impl-46 impl-47; do LOOM_HOME="$EVH" "$TICK" clear-lane "$l" >/dev/null 2>&1; done

# 16n. The ticker stops announcing a replay that is not going to happen (P42).
#      `tick_skipped` fires for three unrelated reasons and the renderer
#      collapsed all of them into one sentence. That was harmless while the
#      timer was a 15-minute backstop; the merged 60s scheduler made wave_gap
#      the routine outcome, so on 2026-08-04 the human watched 408 of those
#      lines go by, 253 of them false — that path writes no pending file and
#      no replay follows. wave_gap now stays in the log for `retro` and never
#      renders; lock_held renders once per wave; loop_stopped keeps its own.
SKH="$T/skip-home"; mkdir -p "$SKH"
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason wave_gap
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason wave_gap
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason lock_held first 1
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason lock_held first 0
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason lock_held first 0
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason loop_stopped
LOOM_HOME="$SKH" "$TICK" event tick_replayed
out=$(LOOM_HOME="$SKH" "$TICK" render-events 2>&1)
printf '%s\n' "$out" | grep -qi "wave_gap\|under .*m ago" \
    && bad "ticker: a wave_gap skip still reached the ticker ($out)" \
    || ok "ticker: a timer declining to spend renders nothing at all"
n=$(printf '%s\n' "$out" | grep -c "a tick landed during a wave" || :)
[ "$n" = 1 ] \
    && ok "ticker: three ticks bouncing off one wave render a single line" \
    || bad "ticker: lock_held rendered $n time(s) for one wave, expected 1"
printf '%s\n' "$out" | grep -q "the loop is stopped — this tick did nothing" \
    && ok "ticker: a tick that found the loop stopped keeps its own line" \
    || bad "ticker: loop_stopped lost its distinct line ($out)"
printf '%s\n' "$out" | grep -q "pending tick replayed" \
    && ok "ticker: an actual replay still renders" \
    || bad "ticker: tick_replayed stopped rendering ($out)"
# The skips are still IN the log — retro counts them, and this is the whole
# reason wave_gap is dropped at the renderer rather than at the emitter.
[ "$(grep -c '"reason":"wave_gap"' "$SKH/events.jsonl")" = 2 ] \
    && ok "ticker: wave_gap is suppressed in the ticker, not lost from the log" \
    || bad "ticker: wave_gap events went missing from events.jsonl"
# A log written before P42 has no "first" field; those lines must still read
# the way they did, or replaying old history rewrites it.
LOOM_HOME="$SKH" "$TICK" event tick_skipped reason lock_held
LOOM_HOME="$SKH" "$TICK" render-events 2>&1 | grep -c "a tick landed during a wave" | grep -qx 2 \
    && ok "ticker: a pre-P42 lock_held event still renders" \
    || bad "ticker: an event with no 'first' field vanished from an old log"
# The emitter half, against the real lock: only the tick that RAISES the
# pending flag is marked, however many bounce off afterwards.
LKH="$T/skip-lock-home"; mkdir -p "$LKH"
LOOM_HOME="$LKH" LOOM_WAVE_CMD="sleep 3" "$TICK" tick >/dev/null 2>&1 &
skpid=$!; sleep 0.7
LOOM_HOME="$LKH" LOOM_WAVE_CMD="echo no" "$TICK" tick >/dev/null 2>&1
LOOM_HOME="$LKH" LOOM_WAVE_CMD="echo no" "$TICK" tick >/dev/null 2>&1
wait "$skpid" 2>/dev/null || :
f1=$(grep -cE '"reason":"lock_held","first":"?1"?' "$LKH/events.jsonl" || :)
f0=$(grep -cE '"reason":"lock_held","first":"?0"?' "$LKH/events.jsonl" || :)
{ [ "$f1" = 1 ] && [ "$f0" = 1 ]; } \
    && ok "tick: the flag-raising bounce is marked, the repeat is not" \
    || bad "tick: expected one first=1 and one first=0 lock_held, got $f1/$f0"
# Planted violation: collapse the three reasons back into one sentence and the
# false line returns — proving the branch, not the fixture, is what suppresses
# it. The copy needs snapshot.jq beside it, as tick.sh ships with.
mkdir -p "$T/tickmod"; ln -sf "$(dirname "$TICK")/snapshot.jq" "$T/tickmod/snapshot.jq"
sed '/elif $e.ev == "tick_skipped"/,/elif $e.ev == "tick_replayed"/s/else empty end)/else "tick landed mid-wave — remembered for replay" end)/g' \
    "$TICK" > "$T/tickmod/tick.sh"; chmod +x "$T/tickmod/tick.sh"
LOOM_HOME="$SKH" "$T/tickmod/tick.sh" render-events 2>&1 | grep -q "tick landed mid-wave" \
    && ok "ticker-violation: with one sentence for all three, the false line is back" \
    || bad "ticker-violation: the collapsed renderer printed nothing — the test proves nothing"

# 16a. probe-result PASS closes the epic's milestone; FAIL leaves it open
#      (fix tickets land in that very milestone). Slug matching is on the
#      normalized title, so bare "e5" and full "e5-cascade-mode" both close
#      "E5 · Cascade mode" and nothing else. (Asked for by the human,
#      2026-08-02 — complete epics sat open in the tracker.)
MCAP="$T/milestone-calls"; : > "$MCAP"
cat > "$T/glab-milestones.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${MCAP:?}"
case "$*" in
    *"milestones?state=active"*) echo '[{"id":55,"title":"E5 · Cascade mode"},{"id":56,"title":"E6 · Provider swaps"}]' ;;
    *) echo '{}' ;;
esac
EOF
chmod +x "$T/glab-milestones.sh"
echo "clean run" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-milestones.sh" MCAP="$MCAP" \
    "$LANE" probe-result 36 e5 pass >/dev/null 2>&1
grep -q "milestones/55" "$MCAP" && ! grep -q "milestones/56" "$MCAP" \
    && ok "probe-result: PASS closes the matching milestone and only that one" \
    || bad "probe-result: milestone close calls wrong ($(grep milestones/ "$MCAP" | head -2))"
: > "$MCAP"
echo "defects found" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-milestones.sh" MCAP="$MCAP" \
    "$LANE" probe-result 36 e5 fail >/dev/null 2>&1
grep -q "state_event=close" "$MCAP" \
    && bad "probe-result: FAIL closed a milestone — fix tickets land there" \
    || ok "probe-result: FAIL leaves the milestone open"

# 16a2. kill-lane kills the TREE, not just the wrapper: a bare kill orphans
#       the agent session inside, which keeps working and keeps writing —
#       an orphaned impl-29-r2 pushed, flipped its held ticket to review,
#       chained a gate, and #29 merged through a human hold (2026-08-02).
"$TICK" spawn-lane impl-88 -- bash -c 'sleep 60 & wait' >/dev/null
sleep 1
wpid=$(cat "$LOOM_HOME/lanes/impl-88.pid" 2>/dev/null || echo "")
kpids="$wpid $(pgrep -P "$wpid" 2>/dev/null | tr '\n' ' ')"
"$TICK" kill-lane impl-88 >/dev/null 2>&1
sleep 1
survivors=0
for p in $kpids; do kill -0 "$p" 2>/dev/null && survivors=$((survivors+1)); done
if [ "$survivors" = 0 ] && [ ! -f "$LOOM_HOME/lanes/impl-88.pid" ]; then
    ok "kill-lane: wrapper AND descendants dead, lane cleared"
else
    bad "kill-lane: $survivors survivor(s) of [$kpids] or pid file left"
fi
out=$(LOOM_HOME="$LOOM_HOME" "$TICK" render-events 2>/dev/null | grep "impl-88\|#88" | tail -1)
case "$out" in *"⚠ #88 — implementation killed (whole tree)"*) \
    ok "ticker: a killed lane renders with the warning glyph";; \
    *) bad "ticker: lane_kill rendered wrong ($out)";; esac

# 16a3. `blocked` is STICKY: labels are last-writer-wins, so without this an
#       in-flight lane stomps a human hold (#29, 2026-08-02). Every advance
#       bounces off a blocked ticket; only re-blocking may touch it freely, and
#       the release direction needs `--release-hold` from a human caller (P36).
cat > "$T/glab-blocked-stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"--method PUT"*|*"--method POST"*) echo "$*" >> "${BCAP:?}"; echo '{}' ;;
    *"issues/50"*) echo '{"iid":50,"labels":["build-3","blocked","tier::api"]}' ;;
    *"issues/51"*) echo '{"iid":51,"labels":["build-3","review","tier::api"]}' ;;
    *) echo '{}' ;;
esac
EOF
chmod +x "$T/glab-blocked-stub.sh"
BCAP2="$T/blocked-writes"; : > "$BCAP2"
GB() { LOOM_HOME="$EVH" GLAB_CMD="$T/glab-blocked-stub.sh" BCAP="$BCAP2" "$LANE" "$@"; }
GB transition 50 review >/dev/null 2>&1 && bad "sticky-blocked: transition advanced a blocked ticket" \
    || ok "sticky-blocked: transition to review bounces off a hold"
echo r | GB verdict 50 pass abcd1234 >/dev/null 2>&1 && bad "sticky-blocked: verdict advanced a blocked ticket" \
    || ok "sticky-blocked: a gate verdict bounces off a hold"
GB close 50 >/dev/null 2>&1 && bad "sticky-blocked: close closed a blocked ticket" \
    || ok "sticky-blocked: close bounces off a hold"
grep -q "add_labels\|state_event=close" "$BCAP2" \
    && bad "sticky-blocked: a state write reached the tracker despite the hold" \
    || ok "sticky-blocked: no state write reached the tracker"
# P36: the unblock direction is no longer a free pass. It was — `ready-for-agent`
# skipped the guard entirely — so releasing a hold was a plain label write any
# automated caller could make, and one did: a hold comment ended with the
# sentence "Release: when #48 merges, /loom unblock 67", and a wave read
# that prose as an instruction addressed to itself and requeued the held ticket
# nine seconds later. (Paid for: #67, build-3 2026-08-04.)
GB transition 50 ready-for-agent >/dev/null 2>&1 \
    && bad "sticky-blocked: a hold was released without --release-hold" \
    || ok "sticky-blocked: releasing a hold needs --release-hold said out loud"
: > "$BCAP2"
GB transition 50 ready-for-agent --release-hold >/dev/null 2>&1 \
    && ok "sticky-blocked: a human releasing the hold still works" \
    || bad "sticky-blocked: --release-hold refused for a human caller"
# The same release, from inside a lane and from inside a wave: refused. These
# are the only two callers that can act on ticket prose, and the env markers
# are set by the loop itself, not by the caller asking nicely.
: > "$BCAP2"
LOOM_LANE_ID=impl-50 GB transition 50 ready-for-agent --release-hold >/dev/null 2>&1 \
    && bad "sticky-blocked: a lane released a human hold" \
    || ok "sticky-blocked: a lane cannot release a human hold, even with the flag"
LOOM_WAVE_PROMPT="/loom tick" GB transition 50 ready-for-agent --release-hold >/dev/null 2>&1 \
    && bad "sticky-blocked: a wave released a human hold" \
    || ok "sticky-blocked: a wave cannot release a human hold, even with the flag"
grep -q "add_labels" "$BCAP2" \
    && bad "sticky-blocked: an automated release still reached the tracker" \
    || ok "sticky-blocked: no automated release write reached the tracker"
# `unblock --to-review` routes through the same door: the human completed the
# work by hand, so it goes back to the gate rather than to the backlog. Before
# P36 this direction had no door at all — `review` bounced with nothing to say.
GB transition 50 review --release-hold >/dev/null 2>&1 \
    && ok "sticky-blocked: a human can release a hold straight to review" \
    || bad "sticky-blocked: --to-review has no way past the guard"
GB transition 51 review >/dev/null 2>&1 \
    && ok "sticky-blocked: an unblocked ticket still advances normally" \
    || bad "sticky-blocked: guard blocked a ticket with no hold"

# 16a4. P30: a FAIL verdict names its defect class machine-readably in the
#       trailer, so the next gate and the snapshot can match consecutive
#       same-class rejections (#39, 2026-08-02). Slugs are kebab-only.
cat > "$T/glab-body-stub.sh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" >> "${VCAP:?}" ;; esac; done
echo '{}'
EOF
chmod +x "$T/glab-body-stub.sh"
VCAP2="$T/verdict-bodies"; : > "$VCAP2"
echo "same trap" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP2" \
    "$LANE" verdict 8 fail beef5678 --class marks-attribution >/dev/null 2>&1
grep -q "orch-verdict FAIL beef5678 class=marks-attribution" "$VCAP2" \
    && ok "verdict: --class folds the defect class into the trailer" \
    || bad "verdict: class missing from trailer ($(tail -2 "$VCAP2" 2>/dev/null))"
echo x | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP2" \
    "$LANE" verdict 8 fail beef5678 --class "Bad Slug" >/dev/null 2>&1 \
    && bad "verdict: accepted a non-kebab class slug" \
    || ok "verdict: a non-kebab class slug is refused"
echo y | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP2" \
    "$LANE" verdict 8 pass beef5678 >/dev/null 2>&1 \
    && ok "verdict: class stays optional" \
    || bad "verdict: classless verdict refused"

# 16a-2. P32: `merge-failed` records a merge attempt that did NOT merge. The
#      merge step always takes the OLDEST merge-queue ticket, so without a
#      count one poisoned ticket is re-picked by every lane behind it — three
#      consecutive lanes wedged on #50 while gate-passed #52 and #53 waited
#      (build-3, 2026-08-03). The trailer keeps the count in the TRACKER,
#      because blocking the ticket is a decision, not plumbing.
VCAP3="$T/merge-attempt-bodies"; : > "$VCAP3"
echo "combined gate deadlocked in pytest" | LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP3" \
    "$LANE" merge-failed 8 >/dev/null 2>&1
grep -q "orch-merge-attempt 8" "$VCAP3" \
    && grep -q "deadlocked in pytest" "$VCAP3" \
    && ok "merge-failed: records the attempt with its reason and a trailer" \
    || bad "merge-failed: trailer or body missing ($(tail -3 "$VCAP3" 2>/dev/null))"
# Planted violation: it must NOT move the ticket. Recording an attempt and
# judging one are different acts — the wave decides when the cap is reached,
# and a verb that silently relabelled would take that call away from it.
# Captured from real argv, so "it only posts a note" is proven, not assumed.
cat > "$T/glab-argv-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ACAP:?}"
echo '{}'
EOF
chmod +x "$T/glab-argv-stub.sh"
ACAP2="$T/merge-attempt-calls"; : > "$ACAP2"
echo "second attempt, same wall" | LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAP2" \
    "$LANE" merge-failed 8 >/dev/null 2>&1
if grep -qE "add_labels|remove_labels|state_event" "$ACAP2"; then
    bad "merge-failed: changed ticket state ($(grep -m1 -E 'add_labels|state_event' "$ACAP2"))"
else
    ok "merge-failed: records only — leaves the merge-queue label alone"
fi
grep -q "issues/8/notes" "$ACAP2" \
    && ok "merge-failed: posted the attempt on the ticket thread" \
    || bad "merge-failed: no note call ($(cat "$ACAP2" | tr '\n' ';'))"

# 16a4b. P37: `rescope` retires the rejections of a ticket's OLD scope. It is a
#       human's judgement about what the ticket now IS, so — like
#       `--release-hold` — it is refused outright inside a lane or a wave: a
#       lane that can reset its own cap has no cap. (#67, build-3 2026-08-04.)
VCAP4="$T/rescope-bodies"; : > "$VCAP4"
echo "Re-scoped: the race moved to #48" | LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP4" "$LANE" rescope 8 >/dev/null 2>&1
grep -qE "orch-scope-reset [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" "$VCAP4" \
    && grep -q "the race moved to #48" "$VCAP4" \
    && ok "rescope: a human posts the reason and the marker together" \
    || bad "rescope: marker or reason missing ($(tail -3 "$VCAP4" 2>/dev/null))"
echo "no body, no record" | LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP4" \
    "$LANE" rescope notanumber >/dev/null 2>&1 \
    && bad "rescope: accepted a non-numeric iid" \
    || ok "rescope: bad iid refused"
# Planted violation: the two automated callers, each with a body ready to post.
# Captured from real argv, so "it wrote nothing" is proven rather than assumed.
ACAP4="$T/rescope-calls"; : > "$ACAP4"
echo "the ticket changed, honest" | LOOM_LANE_ID=impl-8 LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAP4" "$LANE" rescope 8 >/dev/null 2>&1 \
    && bad "rescope: a lane retired its own rejection history" \
    || ok "rescope: a lane cannot reset its own cap"
echo "the ticket changed, honest" | LOOM_WAVE_PROMPT="/loom tick" LOOM_HOME="$EVH" \
    GLAB_CMD="$T/glab-argv-stub.sh" ACAP="$ACAP4" "$LANE" rescope 8 >/dev/null 2>&1 \
    && bad "rescope: a wave retired a ticket's rejection history" \
    || ok "rescope: a wave cannot reset a ticket's cap"
[ -s "$ACAP4" ] \
    && bad "rescope: an automated caller still reached the tracker ($(head -1 "$ACAP4"))" \
    || ok "rescope: no automated reset write reached the tracker"
LOOM_HOME="$EVH" GLAB_CMD="$T/glab-body-stub.sh" VCAP="$VCAP3" \
    "$LANE" merge-failed abc </dev/null >/dev/null 2>&1 \
    && bad "merge-failed: accepted a non-numeric iid" \
    || ok "merge-failed: a bad iid is refused"

# 16a-3. P33: `fix-ticket` applies all FIVE things a schedulable fix ticket
#      needs, or refuses. The skill prose enumerated four — build-N, fix,
#      tier, milestone — and left "entering at ready" as narrative, so a probe
#      lane did exactly what the list said and filed #64 with no state label:
#      in the build's universe, in no state, invisible to the ready set, while
#      four lanes idled (2026-08-04).
cat > "$FX/fixtkt-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ACAP:?}"
case "$*" in
  *"milestones"*)          echo '[{"id":31,"title":"E4 · Realtime mode"}]' ;;
  *"issues?state=opened"*) echo '[{"iid":36,"title":"Build 3"},{"iid":9,"title":"Build 2"}]' ;;
  *"POST"*"issues"*)       echo '{"iid":64}' ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$FX/fixtkt-stub.sh"
FCAP="$T/fixtkt-calls"; : > "$FCAP"
echo "turns after the first never complete" | LOOM_HOME="$EVH" \
    GLAB_CMD="$FX/fixtkt-stub.sh" ACAP="$FCAP" \
    "$LANE" fix-ticket --title "realtime turns stall" --tier logic \
        --milestone "E4 · Realtime mode" >/dev/null 2>&1
lbl=$(grep -o 'labels=[^ ]*' "$FCAP" | head -1)
miss=""
for want in build-3 fix tier::logic ready-for-agent; do
    case "$lbl" in *"$want"*) ;; *) miss="$miss $want" ;; esac
done
[ -z "$miss" ] \
    && ok "fix-ticket: applies build-N, fix, tier:: and ready-for-agent together" \
    || bad "fix-ticket: missing labels —$miss (got '$lbl')"
grep -q "milestone_id=31" "$FCAP" \
    && ok "fix-ticket: resolves the milestone title to its id" \
    || bad "fix-ticket: no milestone_id ($(cat "$FCAP" | tr '\n' ';'))"
# The build label is DERIVED from the highest open `Build N`, never asked for:
# a lane that had to name it could name last week's.
case "$lbl" in *build-3*) ok "fix-ticket: derives the build label, highest Build N wins" ;;
               *) bad "fix-ticket: wrong build label in '$lbl' (want build-3, not build-2)" ;; esac
# Planted violations: the two flags whose absence is silent damage rather than
# a loud error must be REFUSED, not defaulted.
echo x | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-stub.sh" ACAP="$FCAP" \
    "$LANE" fix-ticket --title t --milestone "E4 · Realtime mode" >/dev/null 2>&1 \
    && bad "fix-ticket: accepted a ticket with no tier — no gate lane could pick a suite" \
    || ok "fix-ticket: a missing --tier is refused"
echo x | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-stub.sh" ACAP="$FCAP" \
    "$LANE" fix-ticket --title t --tier logic >/dev/null 2>&1 \
    && bad "fix-ticket: accepted a milestone-less ticket — its epic could close over the defect" \
    || ok "fix-ticket: a missing --milestone is refused"
echo x | LOOM_HOME="$EVH" GLAB_CMD="$FX/fixtkt-stub.sh" ACAP="$FCAP" \
    "$LANE" fix-ticket --title t --tier bogus --milestone "E4 · Realtime mode" >/dev/null 2>&1 \
    && bad "fix-ticket: accepted a tier outside docs|logic|api|ui" \
    || ok "fix-ticket: an unknown tier is refused"

# 16b. lane.sh reconcile: reconciliation is a SCRIPT so a merge lane cannot
#      choose rebase. Two lanes chose it off the skill prose and dead-ended
#      at the force-push guardrail (build-1 2026-08-02; merge-21 build-3
#      2026-08-02, which then asked a headless void for permission). The
#      whole point: after reconcile, a PLAIN push must succeed.
RG="$T/reconcile"; mkdir -p "$RG"
git -c init.defaultBranch=main init -q --bare "$RG/origin.git"
git clone -q "$RG/origin.git" "$RG/work" 2>/dev/null
git -C "$RG/work" config user.email t@t; git -C "$RG/work" config user.name t
GITW() { git -C "$RG/work" "$@"; }
echo one > "$RG/work/f"; GITW add f; GITW commit -qm base; GITW push -q origin main
GITW checkout -qb ticket; echo two > "$RG/work/g"; GITW add g; GITW commit -qm ticket-work
GITW checkout -q main; echo three > "$RG/work/h"; GITW add h; GITW commit -qm mainline
GITW push -q origin main; GITW checkout -q ticket
old=$(GITW rev-parse HEAD)
( cd "$RG/work" && GLAB_CMD=/usr/bin/true "$LANE" reconcile ) >/dev/null 2>&1; rc_rec=$?
if [ "$rc_rec" = 0 ] && GITW merge-base --is-ancestor "$old" HEAD \
   && [ "$(GITW rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" = "3" ] \
   && GITW push -q origin ticket 2>/dev/null; then
    ok "reconcile: merges origin base, rewrites nothing, plain push succeeds"
else
    bad "reconcile: rc=$rc_rec, or history rewritten, or plain push failed"
fi
# A real conflict is rc 3 with the merge state left for the model to judge.
GITW checkout -q main; echo MAINLINE > "$RG/work/f"; GITW commit -qam clash-main
GITW push -q origin main; GITW checkout -q ticket
echo TICKET > "$RG/work/f"; GITW commit -qam clash-ticket
( cd "$RG/work" && GLAB_CMD=/usr/bin/true "$LANE" reconcile ) >/dev/null 2>&1; rc_rec=$?
if [ "$rc_rec" = 3 ] && GITW status --porcelain | grep -q "^UU f"; then
    ok "reconcile: a real conflict exits 3 with the merge state left to judge"
else
    bad "reconcile: conflict path rc=$rc_rec ($(GITW status --porcelain | head -2))"
fi
GITW merge --abort 2>/dev/null || :

# 16c. reconcile re-syncs DERIVED state. A worktree cut before a ticket added
#      a dependency carries an install that predates it, so the instant the
#      base merges in the gate goes red on a module nobody installed — and
#      nothing else re-runs setup, because SKILL step 4 installs at worktree
#      CREATION and the worktree then lives for hours. (Paid for: build-2 #14
#      2026-08-03 — merge attempt 1 died on a red logic gate because `zod`
#      landed on main via #7 while wt-14's node_modules was 18 minutes older;
#      the recovery cost a wave ~3 minutes of re-derived diagnosis and the
#      retry then merged clean after nothing but an install.)
#      LANE_INSTALL_CMD stands in for the real installer so the suite never
#      shells out to pnpm.
GITW checkout -q ticket 2>/dev/null
GITW reset -q --hard origin/ticket 2>/dev/null || :
# (a) base merge that moves a lockfile → the installer runs.
GITW checkout -q main; printf 'lock: v2\n' > "$RG/work/pnpm-lock.yaml"
GITW add pnpm-lock.yaml; GITW commit -qm "add a dependency"; GITW push -q origin main
GITW checkout -q ticket
: > "$T/install-ran"
( cd "$RG/work" && GLAB_CMD=/usr/bin/true \
    LANE_INSTALL_CMD="touch $T/install-ran.yes" "$LANE" reconcile ) >/dev/null 2>&1
[ -f "$T/install-ran.yes" ] \
    && ok "reconcile: a base merge that moves a lockfile re-installs dependencies" \
    || bad "reconcile: lockfile moved under the worktree and nothing re-installed"
# (b) base merge that touches no manifest → no install. An unconditional one
#     would tax every merge in the build to fix the minority that need it.
GITW checkout -q main; echo more > "$RG/work/unrelated"; GITW add unrelated
GITW commit -qm "no dependency change"; GITW push -q origin main; GITW checkout -q ticket
rm -f "$T/install-ran.yes"
( cd "$RG/work" && GLAB_CMD=/usr/bin/true \
    LANE_INSTALL_CMD="touch $T/install-ran.yes" "$LANE" reconcile ) >/dev/null 2>&1
[ ! -f "$T/install-ran.yes" ] \
    && ok "reconcile: an unrelated base merge does not pay for an install" \
    || bad "reconcile: installed on a merge that touched no manifest or lockfile"
# (c) a failing installer is NOT a failing reconcile — the tier gate is the
#     arbiter of mergeability and it runs next. Reconcile says so and returns 0.
GITW checkout -q main; printf 'lock: v3\n' > "$RG/work/pnpm-lock.yaml"
GITW commit -qam "another dependency"; GITW push -q origin main; GITW checkout -q ticket
out=$( cd "$RG/work" && GLAB_CMD=/usr/bin/true \
    LANE_INSTALL_CMD=/usr/bin/false "$LANE" reconcile 2>&1 ); rc_rec=$?
if [ "$rc_rec" = 0 ] && printf '%s' "$out" | grep -q "FAILED"; then
    ok "reconcile: a failed install warns loudly but leaves the verdict to the gate"
else
    bad "reconcile: failed install gave rc=$rc_rec (want 0) or said nothing"
fi

# Killing a --follow ticker must take its tail+jq children with it. An
# orphaned pipeline kept writing to the pane after its wrapper was killed,
# so every new event rendered once per ghost — duplicate lines that
# survived a restart and grew over time (2026-08-02).
LOOM_HOME="$EVH" "$TICK" render-events --follow >/dev/null 2>&1 &
TKPID=$!
sleep 1
kill "$TKPID" 2>/dev/null; sleep 1
if pgrep -f "tail -n 100 -F $EVH/events.jsonl" >/dev/null 2>&1; then
    bad "ticker: killed --follow wrapper left an orphaned tail behind"
    pkill -f "tail -n 100 -F $EVH/events.jsonl" 2>/dev/null || :
else
    ok "ticker: killing a --follow wrapper takes its pipeline with it"
fi

# --- sweep: the merged-worktree teardown that had never once succeeded ------
# `st=$(git status --porcelain | grep -v '^??' | head -1)` exits 1 whenever the
# grep filters out every line, and under `set -euo pipefail` that killed the
# whole sweep silently (rc=1) before removing anything. A merged worktree whose
# only leftovers are untracked files is the COMMON case, so sweep never worked:
# merged worktrees accumulated and a wave removed one by hand (2026-08-03).
SW="$T/sweep"; mkdir -p "$SW"
git -c init.defaultBranch=main init -q --bare "$SW/origin.git"
git clone -q "$SW/origin.git" "$SW/repo" 2>/dev/null
git -C "$SW/repo" config user.email t@t; git -C "$SW/repo" config user.name t
echo base > "$SW/repo/f"; git -C "$SW/repo" add f
git -C "$SW/repo" commit -qm base; git -C "$SW/repo" push -q origin main
# A ticket branch that IS merged into origin/main — i.e. genuinely sweepable.
git -C "$SW/repo" checkout -qb done-work
echo more > "$SW/repo/g"; git -C "$SW/repo" add g; git -C "$SW/repo" commit -qm work
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" merge -q --no-edit done-work; git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-7" done-work 2>/dev/null
# The trigger: leftovers that are ALL untracked (build artifacts, node_modules).
mkdir -p "$SW/repo-wt-7/dist"; echo junk > "$SW/repo-wt-7/dist/out.js"
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out" 2>&1; rc_sw=$?
if [ "$rc_sw" = 0 ] && [ ! -e "$SW/repo-wt-7" ]; then
    ok "sweep: removes a merged worktree whose only leftovers are untracked"
else
    bad "sweep: rc=$rc_sw, worktree still present=$([ -e "$SW/repo-wt-7" ] && echo yes || echo no) ($(head -1 "$SW/out"))"
fi
# The safety boundary: unmerged work is never ours to delete. Fixing the crash
# above ARMED a deletion path that had never executed, so prove it still stops.
git -C "$SW/repo" checkout -qb live-work origin/main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-8" -b wip origin/main 2>/dev/null
echo wip > "$SW/repo-wt-8/new.txt"
git -C "$SW/repo-wt-8" add new.txt
git -C "$SW/repo-wt-8" -c user.email=t@t -c user.name=t commit -qm wip
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
if [ -e "$SW/repo-wt-8" ]; then
    ok "sweep: keeps a worktree holding unmerged commits"
else
    bad "sweep: deleted a worktree with unmerged work"
fi

# --- close/merge: a ticket must never close over its own unmerged MR --------
# merge-1 ran reconcile, ran the gate, ran `lane.sh close 1` and reported
# "merged and closed" — but nothing merged MR !1, and four downstream lanes
# were seconds from branching off a base without the work in it (2026-08-03).
MG="$T/mergeverb"; mkdir -p "$MG"
cat > "$MG/glab-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"issues/41/closed_by"*) echo '[{"iid":9,"state":"opened"}]' ;;
  *"issues/42/closed_by"*) echo '[]' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$MG/glab-stub.sh"
GLAB_CMD="$MG/glab-stub.sh" STUB_LOG="$MG/calls" "$LANE" close 41 >"$MG/out" 2>&1; rc_cl=$?
if [ "$rc_cl" != 0 ] && grep -q 'unmerged MR !9' "$MG/out" \
   && ! grep -q 'state_event=close' "$MG/calls"; then
    ok "close: refuses to close over an unmerged MR, and writes nothing"
else
    bad "close: rc=$rc_cl, out=$(head -1 "$MG/out")"
fi
# `closed_by`, not `related_merge_requests`: the latter lists any MR that merely
# MENTIONS the issue — on this very build, issue #1 listed #21's open MR next to
# its own, so "merge the first open one" would have merged the wrong branch.
if grep -q 'closed_by' "$MG/calls" && ! grep -q 'related_merge_requests' "$MG/calls"; then
    ok "close: asks closed_by, never the looser related_merge_requests"
else
    bad "close: wrong MR-lookup endpoint ($(head -1 "$MG/calls"))"
fi
: > "$MG/calls"
GLAB_CMD="$MG/glab-stub.sh" STUB_LOG="$MG/calls" "$LANE" merge 42 >"$MG/out2" 2>&1; rc_mg=$?
if [ "$rc_mg" != 0 ] && grep -q "Closes #42" "$MG/out2" \
   && ! grep -q '/merge' "$MG/calls"; then
    ok "merge: refuses when no open MR closes the issue"
else
    bad "merge: rc=$rc_mg, out=$(head -1 "$MG/out2")"
fi

# --- the stale-snapshot race: a merged ticket must not be failed or relabelled
# #23 merged at 22:23:17 and was blocked at 22:24:29. A gate lane had chained
# straight into its merge lane; a wave started 90s BEFORE the merge landed,
# then harvested against that photograph, saw no live merge lane, and applied
# "still merge-queue means it never merged". The wave did not perform the
# merge, so nothing prompted it to re-read. Both verbs now refuse.
SR="$T/stalerace"; mkdir -p "$SR"
cat > "$SR/glab-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  # 51 = merged underneath the caller; 52 = genuinely still open
  *"issues/51/closed_by"*) echo '[{"iid":7,"state":"merged"}]' ;;
  *"issues/52/closed_by"*) echo '[{"iid":8,"state":"opened"}]' ;;
  *"issues/51"*)           echo '{"state":"closed","labels":[]}' ;;
  *"issues/52"*)           echo '{"state":"opened","labels":[]}' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$SR/glab-stub.sh"
echo body > "$SR/report.md"
GLAB_CMD="$SR/glab-stub.sh" STUB_LOG="$SR/c1" "$LANE" merge-failed 51 --file "$SR/report.md" \
    >"$SR/o1" 2>&1; rc_mf=$?
if [ "$rc_mf" != 0 ] && grep -q 'already has MERGED MR !7' "$SR/o1" \
   && ! grep -q '/notes' "$SR/c1"; then
    ok "merge-failed: refuses to record a failure for an already-merged ticket"
else
    bad "merge-failed: rc=$rc_mf, out=$(head -1 "$SR/o1")"
fi
# The cap counts real failures, so the guard must not swallow genuine ones.
GLAB_CMD="$SR/glab-stub.sh" STUB_LOG="$SR/c2" "$LANE" merge-failed 52 --file "$SR/report.md" \
    >"$SR/o2" 2>&1; rc_mf2=$?
if [ "$rc_mf2" = 0 ] && grep -q '/notes' "$SR/c2"; then
    ok "merge-failed: still records a genuine failure while the MR is open"
else
    bad "merge-failed: guard swallowed a real attempt (rc=$rc_mf2)"
fi
# Blocking a CLOSED ticket, and the later "requeue" of one, are the same lie.
GLAB_CMD="$SR/glab-stub.sh" STUB_LOG="$SR/c3" "$LANE" transition 51 blocked \
    >"$SR/o3" 2>&1; rc_tr=$?
if [ "$rc_tr" != 0 ] && grep -q 'is CLOSED' "$SR/o3" \
   && ! grep -q 'add_labels' "$SR/c3"; then
    ok "transition: refuses to label a closed ticket, and writes nothing"
else
    bad "transition: rc=$rc_tr, out=$(head -1 "$SR/o3")"
fi
GLAB_CMD="$SR/glab-stub.sh" STUB_LOG="$SR/c4" "$LANE" transition 51 ready-for-agent \
    >"$SR/o4" 2>&1; rc_tr2=$?
if [ "$rc_tr2" != 0 ] && ! grep -q 'add_labels' "$SR/c4"; then
    ok "transition: a closed ticket cannot be requeued as available work"
else
    bad "transition: requeued a closed ticket (rc=$rc_tr2)"
fi
GLAB_CMD="$SR/glab-stub.sh" STUB_LOG="$SR/c5" "$LANE" transition 52 merge-queue \
    >"$SR/o5" 2>&1; rc_tr3=$?
if [ "$rc_tr3" = 0 ] && grep -q 'add_labels=merge-queue' "$SR/c5"; then
    ok "transition: an open ticket still advances normally"
else
    bad "transition: guard broke the normal path (rc=$rc_tr3)"
fi

# 22. Hard cut from the pre-rename config name. A repo carrying only
#     `.orchestrator.yml` must STOP, naming the rename — never fall through to
#     derived + global defaults, which would silently ignore every setting the
#     human wrote. Shown failing too: add `.loom.yml` and the same repo runs.
HC="$T/hardcut"; mkdir -p "$HC/repo" "$HC/home"
printf 'max_lanes: 2\n' > "$HC/repo/.orchestrator.yml"
LOOM_REPO="$HC/repo" LOOM_HOME="$HC/home" "$TICK" tick >"$HC/out" 2>&1; rc_hc=$?
if [ "$rc_hc" != 0 ] && grep -q 'old config name' "$HC/out" \
   && grep -q 'mv .orchestrator.yml .loom.yml' "$HC/out"; then
    ok "hard cut: a repo on the old config name stops and names the rename"
else
    bad "hard cut: old-name repo did not stop with the rename message (rc=$rc_hc)"
fi
# Planted violation: with the new name present the guard must NOT fire.
printf 'max_lanes: 2\n' > "$HC/repo/.loom.yml"
LOOM_REPO="$HC/repo" LOOM_HOME="$HC/home" "$TICK" tick >"$HC/out2" 2>&1
if grep -q 'old config name' "$HC/out2"; then
    bad "hard cut: guard fired even though .loom.yml exists"
else
    ok "hard cut: a repo carrying both names runs on the new one"
fi

# Whole-suite guard, checked last because it is a property of every test above
# it: nothing in this file may reach the pane opener. The global stub catches a
# test that sets HERDR_ENV=1 without its own stub; a test that `unset`s the
# seam instead of restoring it escapes to the real script, which is why the two
# blocks that touch it restore. (Paid for: 2026-08-04, eight orphan panes.)
if [ ! -s "$WP_GLOBAL_CALLS" ]; then
    ok "suite: no test reached the pane opener — a run opens no real panes"
else
    bad "suite: $(wc -l < "$WP_GLOBAL_CALLS" | tr -d ' ') call(s) escaped to the pane opener"
fi

echo; echo "== $PASS passed, $FAIL failed =="
rm -rf "$T"
exit $((FAIL > 0))
