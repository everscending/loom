#!/usr/bin/env bash
# P12: cheap checks before an expensive session
#
# Section 04 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 4i. P12: cheap checks before an expensive session ---------------------
# The deterministic suite is effectively free — build 2's merge re-gate lane ran
# 265 tests and a live round trip in FOUR SECONDS — but it sat inside a review
# session that had already spent its expensive reasoning. Running it first, in
# shell, rejects a red branch with zero model time.
# A plain worktree with no gate runner in it — 4i5 below needs exactly that.
# Section 01 built the same one and this section used to inherit it.
WT="$T/worktree-a"; mkdir -p "$WT"
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

# 4i5b. P60: the missing-runner path is DECLARED, never silent. ai-workout
#       build-1 logged "no scripts/gate.sh here, skipping" on every gate all
#       night while the runner sat in an unmerged ticket — the mechanical
#       check ran zero times, nothing said so, and the failure surfaced as
#       merge-lane deaths. The lane log must state what was not checked and
#       why, and the event stream must carry it to the ticker.
if grep -q "reduced to review-only" "$LOOM_HOME/logs/lane-gate-45.log" 2>/dev/null \
   && grep -q "scripts/gate.sh" "$LOOM_HOME/logs/lane-gate-45.log" 2>/dev/null \
   && grep -q "tier api" "$LOOM_HOME/logs/lane-gate-45.log" 2>/dev/null; then
    ok "pregate-reduced: a missing runner is declared in the lane log — runner, tier, and why"
else
    bad "pregate-reduced: the missing-runner path is still a silent skip"
fi
grep -q '"ev":"pregate_reduced"' "$LOOM_HOME/events.jsonl" 2>/dev/null \
    && ok "pregate-reduced: the reduction reaches the event stream for the ticker" \
    || bad "pregate-reduced: no pregate_reduced event was recorded"
# The declaration fires ONLY when the runner is missing: the green lane above
# (gate-41, runner present) must not have declared a reduction — a line that
# fires either way says nothing.
grep -q "reduced to review-only" "$LOOM_HOME/logs/lane-gate-41.log" 2>/dev/null \
    && bad "pregate-reduced: a present runner still declared a reduction" \
    || ok "pregate-reduced: a present runner declares nothing — the line means what it says"
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

test_finish
