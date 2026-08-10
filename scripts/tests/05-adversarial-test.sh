#!/usr/bin/env bash
# P31: the mandatory adversarial test is a checkable deliverable
#
# Section 05 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 4i9. P31: the mandatory adversarial test is a checkable deliverable ----
# seat-reservations build-1 rejected the same shape three times in prose — the
# test absent, then not on the tier's command list, then skipped in CI — at 787s
# of review-session time. A ticket that names inputs which must be rejected, and
# a branch that changes nothing under the paths its tier actually runs, is
# decidable in shell. Strictly one-directional: every unknown skips, because a
# false rc 7 costs more than the round it saves.
ADVR="$T/adv-repo"; mkdir -p "$ADVR/src" "$ADVR/tests/unit" "$ADVR/scripts"
git -c init.defaultBranch=main init -q "$ADVR" 2>/dev/null
git -C "$ADVR" config user.email t@t; git -C "$ADVR" config user.name t
printf 'base: main\ngates:\n  logic:\n    - "bash scripts/gate.sh logic"\n    - "pytest tests/unit"\n' > "$ADVR/.loom.yml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ADVR/scripts/gate.sh"; chmod +x "$ADVR/scripts/gate.sh"
: > "$ADVR/src/app.py"; git -C "$ADVR" add -A >/dev/null 2>&1; git -C "$ADVR" commit -qm base >/dev/null 2>&1
git -C "$ADVR" checkout -qb feat-adv 2>/dev/null
printf 'x = 1\n' > "$ADVR/src/app.py"
git -C "$ADVR" add -A >/dev/null 2>&1; git -C "$ADVR" commit -qm work >/dev/null 2>&1
# The tracker stub serves one issue body. Its description is the only input the
# check reads, so each case swaps it rather than the branch.
ADVG="$T/adv-glab"
cat > "$ADVG" <<'EOF'
#!/bin/sh
echo "$@" >> "${STUB_LOG:-/dev/null}"
[ "${STUB_FAIL:-0}" = 1 ] && exit 1
printf '%s\n' "${STUB_BODY:-}"
EOF
chmod +x "$ADVG"
ADV_MANDATORY='{"description":"## Mandatory adversarial tests\n\n- an empty seat id must be rejected\n\n## Risk tier\n\nlogic\n"}'
ADV_SILENT='{"description":"## Design decisions\n\n- keep the reader dumb\n"}'
ADV_NONE='{"description":"## Mandatory adversarial tests\n\nNone of its own — this ticket verifies, it does not build.\n\n## Risk tier\n\nlogic\n"}'
adv_spawn() { # <lane> <log> <issue-body-json> [fail]
    rm -f "$T/adv-ran-$1" "$LOOM_HOME/lanes/$1.rc"; : > "$2"
    LOOM_REPO="$ADVR" GLAB_CMD="$ADVG" STUB_LOG="$2" STUB_BODY="$3" STUB_FAIL="${4:-0}" \
        "$TICK" spawn-lane "$1" --no-tick --pregate logic --cwd "$ADVR" -- touch "$T/adv-ran-$1" >/dev/null 2>&1
    for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/$1.rc" ] && break; sleep 0.1; done
}

# The rejection itself: no review session, rc 7 like any other mechanical
# failure, and a lane log that names the tier's paths so the wave's rejection
# comment can say what is missing.
adv_spawn gate-61 "$T/adv-calls-61" "$ADV_MANDATORY"
if [ ! -f "$T/adv-ran-gate-61" ] && [ "$(cat "$LOOM_HOME/lanes/gate-61.rc" 2>/dev/null)" = "7" ]; then
    ok "adversarial-pregate: a branch touching nothing the tier runs is rejected at rc 7, no review session"
else
    bad "adversarial-pregate: expected rc 7 with no session (rc=$(cat "$LOOM_HOME/lanes/gate-61.rc" 2>/dev/null), ran=$([ -f "$T/adv-ran-gate-61" ] && echo yes || echo no))"
fi
if grep -q "mandatory adversarial tests" "$LOOM_HOME/logs/lane-gate-61.log" 2>/dev/null \
   && grep -q "tests/unit" "$LOOM_HOME/logs/lane-gate-61.log" 2>/dev/null; then
    ok "adversarial-pregate: the lane log names the reason and the paths the tier runs"
else
    bad "adversarial-pregate: the rejection does not say what is missing"
fi

# The holding side. Add a file under the tier's own path and the identical
# ticket passes through to the review session — which is also where the
# judgement it cannot make (does the test assert the bullet?) still lives.
printf 'def test_rejects_empty_seat_id():\n    assert True\n' > "$ADVR/tests/unit/test_adv.py"
git -C "$ADVR" add -A >/dev/null 2>&1; git -C "$ADVR" commit -qm adv >/dev/null 2>&1
adv_spawn gate-62 "$T/adv-calls-62" "$ADV_MANDATORY"
if [ -f "$T/adv-ran-gate-62" ] && [ "$(cat "$LOOM_HOME/lanes/gate-62.rc" 2>/dev/null)" = "0" ]; then
    ok "adversarial-pregate: a branch that adds a test under the tier's path reaches the review session"
else
    bad "adversarial-pregate: FALSE REJECTION — the adversarial test was there (rc=$(cat "$LOOM_HOME/lanes/gate-62.rc" 2>/dev/null))"
fi
# The tracker read is last, only for a candidate rejection: a branch that
# already touches the suite must not cost a round trip on every gate spawn.
[ -s "$T/adv-calls-62" ] \
    && bad "adversarial-pregate: a passing branch still paid for a tracker read ($(cat "$T/adv-calls-62"))" \
    || ok "adversarial-pregate: a passing branch costs no tracker read — the local checks answer first"
git -C "$ADVR" rm -q "$ADVR/tests/unit/test_adv.py" >/dev/null 2>&1
git -C "$ADVR" commit -qm drop >/dev/null 2>&1

# Gated on the ticket, not on the branch: a ticket that demands no adversarial
# test says nothing about which files the branch should touch.
adv_spawn gate-63 "$T/adv-calls-63" "$ADV_SILENT"
[ -f "$T/adv-ran-gate-63" ] \
    && ok "adversarial-pregate: a ticket with no adversarial section is never rejected for one" \
    || bad "adversarial-pregate: a ticket that asked for no adversarial test was rejected anyway"

# D-TICK-14: a ticket that ANSWERS the section with prose declaring it has
# none ("None of its own — this ticket verifies, it does not build") is the
# same case as ADV_SILENT, spelled out. The section has text, but no bullet —
# so it must skip exactly like the blank section does, not read as a demand.
adv_spawn gate-70 "$T/adv-calls-70" "$ADV_NONE"
[ -f "$T/adv-ran-gate-70" ] \
    && ok "adversarial-pregate: a ticket that declares no adversarial tests in prose is never rejected for one" \
    || bad "adversarial-pregate: a ticket's prose declaration of 'none' was read as a demand for tests"

# Planted violation: revert the guard to "any text counts" — the mechanism
# D-TICK-14 removed — and the identical ADV_NONE ticket, on a branch that
# touches none of the tier's paths, is rejected at rc 7 with no session. This
# is the exact failure reproduced against boostlingo build-4 #97: rc 7 forever,
# unsatisfiable because the section lives in the ticket body.
ADVM2="$T/adv-textonly"; mkdir -p "$ADVM2"
# tick.sh dies at source time without lib.sh beside it (P73), and spawn-lane
# needs lane.sh and the jq helpers too — every sibling file it reads at
# startup, not just the one line under test, or the mutant never reaches the
# pregate at all.
for jf in snapshot.jq render.jq render-events.jq usage.jq report.jq report-ticket.jq retro.jq graph.jq lib.jq; do
    ln -sf "$(dirname "$TICK")/$jf" "$ADVM2/$jf"
done
ln -sf "$(dirname "$TICK")/lib.sh" "$ADVM2/lib.sh"
ln -sf "$(dirname "$TICK")/lane.sh" "$ADVM2/lane.sh"
link_trackers "$ADVM2"
adv_guard_line=$(grep -Fn '[[:space:]]*[-*][[:space:]]' "$TICK" | cut -d: -f1)
if [ -n "$adv_guard_line" ]; then
    sed "${adv_guard_line}s#.*#    [ -n \"\$sect\" ] || return 1#" "$TICK" > "$ADVM2/tick.sh"
else
    cp "$TICK" "$ADVM2/tick.sh"
fi
if ! diff -q "$TICK" "$ADVM2/tick.sh" >/dev/null 2>&1; then
    chmod +x "$ADVM2/tick.sh"
    adv_spawn2() { # <lane> <tick-binary> <log> <issue-body-json>
        rm -f "$T/adv-ran-$1" "$LOOM_HOME/lanes/$1.rc"
        LOOM_REPO="$ADVR" GLAB_CMD="$ADVG" STUB_LOG="$3" STUB_BODY="$4" \
            "$2" spawn-lane "$1" --no-tick --pregate logic --cwd "$ADVR" -- touch "$T/adv-ran-$1" >/dev/null 2>&1
        for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/$1.rc" ] && break; sleep 0.1; done
    }
    adv_spawn2 gate-71 "$ADVM2/tick.sh" "$T/adv-calls-71" "$ADV_NONE"
    if [ ! -f "$T/adv-ran-gate-71" ] && [ "$(cat "$LOOM_HOME/lanes/gate-71.rc" 2>/dev/null)" = "7" ]; then
        ok "adversarial-pregate-violation: reverting to a text-only check rejects the prose 'none' declaration, unsatisfiable forever"
    else
        bad "adversarial-pregate-violation: the mutant did not reject, so the fix proves nothing (rc=$(cat "$LOOM_HOME/lanes/gate-71.rc" 2>/dev/null))"
    fi
else
    bad "adversarial-pregate-violation: sed did not match the guard line, mutant is identical to the fix"
fi

# An unreadable tracker is not evidence about the branch — the same rule the
# missing runner follows.
adv_spawn gate-64 "$T/adv-calls-64" "$ADV_MANDATORY" 1
[ -f "$T/adv-ran-gate-64" ] \
    && ok "adversarial-pregate: an unreadable ticket skips the check rather than rejecting" \
    || bad "adversarial-pregate: a tracker failure produced a false rejection"

# Gate lanes only. The check reads a finished branch; run against an
# implementer it would reject the work before the lane had written any of it.
adv_spawn impl-65 "$T/adv-calls-65" "$ADV_MANDATORY"
[ -f "$T/adv-ran-impl-65" ] \
    && ok "adversarial-pregate: an impl lane is never rejected for a test it has not written yet" \
    || bad "adversarial-pregate: the check fired on an implementer"

# The gate runner is excluded from the paths. Every tier invokes it and no
# ticket branch changes it, so counting it would reject every branch in a repo
# whose tier is one runner call — the commonest shape there is.
ADVR2="$T/adv-repo-runner-only"; mkdir -p "$ADVR2/src" "$ADVR2/scripts"
git -c init.defaultBranch=main init -q "$ADVR2" 2>/dev/null
git -C "$ADVR2" config user.email t@t; git -C "$ADVR2" config user.name t
printf 'base: main\ngates:\n  logic:\n    - "bash scripts/gate.sh logic"\n' > "$ADVR2/.loom.yml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ADVR2/scripts/gate.sh"; chmod +x "$ADVR2/scripts/gate.sh"
: > "$ADVR2/src/app.py"; git -C "$ADVR2" add -A >/dev/null 2>&1; git -C "$ADVR2" commit -qm base >/dev/null 2>&1
git -C "$ADVR2" checkout -qb feat-adv2 2>/dev/null
printf 'y = 2\n' > "$ADVR2/src/app.py"
git -C "$ADVR2" add -A >/dev/null 2>&1; git -C "$ADVR2" commit -qm work >/dev/null 2>&1
rm -f "$T/adv-ran-gate-66" "$LOOM_HOME/lanes/gate-66.rc"
LOOM_REPO="$ADVR2" GLAB_CMD="$ADVG" STUB_BODY="$ADV_MANDATORY" STUB_LOG="$T/adv-calls-66" \
    "$TICK" spawn-lane gate-66 --no-tick --pregate logic --cwd "$ADVR2" -- touch "$T/adv-ran-gate-66" >/dev/null 2>&1
for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/gate-66.rc" ] && break; sleep 0.1; done
[ -f "$T/adv-ran-gate-66" ] \
    && ok "adversarial-pregate: a tier whose only path is the gate runner checks nothing" \
    || bad "adversarial-pregate: a runner-only tier rejected every branch in the repo"

# Planted violation: take the path token out of the tier's command list — the
# mechanism the check reads — and the identical branch, on the identical
# ticket, spends the review session the guard exists to save.
printf 'base: main\ngates:\n  logic:\n    - "bash scripts/gate.sh logic"\n    - "pytest -q"\n' > "$ADVR/.loom.yml"
adv_spawn gate-67 "$T/adv-calls-67" "$ADV_MANDATORY"
[ -f "$T/adv-ran-gate-67" ] \
    && ok "adversarial-pregate-violation: with no path on the tier's command list the branch burns the session" \
    || bad "adversarial-pregate-violation: something else rejected the branch, so the guard proves nothing"
printf 'base: main\ngates:\n  logic:\n    - "bash scripts/gate.sh logic"\n    - "pytest tests/unit"\n' > "$ADVR/.loom.yml"

# The tier's command list is read from the BRANCH's checkout, not the repo's.
# ai-interpreter-workbench build-4 #90: the branch wired its mandatory test in
# by ADDING a command to the logic tier. That line lives only on the branch, so
# a check reading the repo's .loom.yml derived main's paths, saw the branch
# touch none of them, and rejected rc 7 — for doing exactly the thing the
# ticket pinned it to do. Deterministic on every respawn, and unpassable by
# construction for any ticket that adds a brand-new gate command.
ADVR3="$T/adv-repo-newcmd"; mkdir -p "$ADVR3/tests/unit" "$ADVR3/scripts"
git -c init.defaultBranch=main init -q "$ADVR3" 2>/dev/null
git -C "$ADVR3" config user.email t@t; git -C "$ADVR3" config user.name t
printf 'base: main\ngates:\n  logic:\n    - "bash scripts/gate.sh logic"\n    - "pytest tests/unit"\n' > "$ADVR3/.loom.yml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ADVR3/scripts/gate.sh"; chmod +x "$ADVR3/scripts/gate.sh"
: > "$ADVR3/tests/unit/.keep"
git -C "$ADVR3" add -A >/dev/null 2>&1; git -C "$ADVR3" commit -qm base >/dev/null 2>&1
# The repo root stays on main; the lane runs in a worktree, as a real wave does.
ADVW3="$T/adv-wt-newcmd"
git -C "$ADVR3" worktree add -q -b feat-newcmd "$ADVW3" main >/dev/null 2>&1
mkdir -p "$ADVW3/scripts/lib"
printf 'export const ok = 1;\n' > "$ADVW3/scripts/lib/report.test.mjs"
printf 'base: main\ngates:\n  logic:\n    - "bash scripts/gate.sh logic"\n    - "pytest tests/unit"\n    - "node --test scripts/lib/report.test.mjs"\n' > "$ADVW3/.loom.yml"
git -C "$ADVW3" add -A >/dev/null 2>&1; git -C "$ADVW3" commit -qm newcmd >/dev/null 2>&1
adv_newcmd_spawn() { # <lane> <tick-binary>
    rm -f "$T/adv-ran-$1" "$LOOM_HOME/lanes/$1.rc"; rm -rf "$LOOM_HOME/tick.lock.d"
    LOOM_REPO="$ADVR3" GLAB_CMD="$ADVG" STUB_BODY="$ADV_MANDATORY" STUB_LOG="$T/adv-calls-$1" \
        "$2" spawn-lane "$1" --no-tick --pregate logic --cwd "$ADVW3" -- touch "$T/adv-ran-$1" >/dev/null 2>&1
    for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/$1.rc" ] && break; sleep 0.1; done
}
adv_newcmd_spawn gate-68 "$TICK"
[ -f "$T/adv-ran-gate-68" ] \
    && ok "adversarial-pregate: a branch that adds a NEW gate command reaches the review session" \
    || bad "adversarial-pregate: FALSE REJECTION — the branch wired its own test into the tier (rc=$(cat "$LOOM_HOME/lanes/gate-68.rc" 2>/dev/null))"

# Planted violation: read the tier's commands from the repo's .loom.yml instead
# of the branch's — the exact shape that blocked #90 — and the identical branch
# is rejected without a session.
ADVM="$T/adv-mainonly"; mkdir -p "$ADVM"
for jf in snapshot.jq render.jq render-events.jq usage.jq report.jq report-ticket.jq retro.jq graph.jq lib.jq; do
    ln -sf "$(dirname "$TICK")/$jf" "$ADVM/$jf"
done
ln -sf "$(dirname "$TICK")/lib.sh" "$ADVM/lib.sh"
ln -sf "$(dirname "$TICK")/lane.sh" "$ADVM/lane.sh"
link_trackers "$ADVM"
sed 's|^    \[ -n "\$dir" \] && \[ -f "\$dir/.loom.yml" \] && cfg="\$dir/.loom.yml"$|    :|' \
    "$TICK" > "$ADVM/tick.sh"
chmod +x "$ADVM/tick.sh"
adv_newcmd_spawn gate-69 "$ADVM/tick.sh"
if [ ! -f "$T/adv-ran-gate-69" ] && [ "$(cat "$LOOM_HOME/lanes/gate-69.rc" 2>/dev/null)" = "7" ]; then
    ok "adversarial-pregate-violation: reading the repo's command list rejects a branch that added its own gate command"
else
    bad "adversarial-pregate-violation: the mutant did not reject, so the branch-side read proves nothing (rc=$(cat "$LOOM_HOME/lanes/gate-69.rc" 2>/dev/null))"
fi

test_finish
