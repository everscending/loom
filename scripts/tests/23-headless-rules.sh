#!/usr/bin/env bash
# P68: every brief carries the headless survival rules
#
# Section 23 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- P68: every brief carries the headless survival rules ------------------
# The probe brief carried rules paid for by dead probes; impl and merge briefs
# carried none of them. ai-workout build-1: impl-2 spawned three times off a
# brief that said to invoke `/implement` — impossible headless — and impl-8's
# first run ended "the harness will notify me automatically" over a backgrounded
# docker build that could never wake it (#8 merged ~6h later).
BR="$T/briefs"; mkdir -p "$BR/wt"
printf 'Implement ticket 12 in this worktree. Run the tier gate before pushing.\n' > "$BR/clean.md"
"$TICK" spawn-lane impl-71 --no-tick --cwd "$BR/wt" --brief "$BR/clean.md" -- true -p @brief >/dev/null 2>&1
COMPOSED="$BR/wt/.lane-brief-impl-71.md"
if [ -f "$COMPOSED" ] && grep -q 'Implement ticket 12' "$COMPOSED" \
   && grep -q 'every step blocks' "$COMPOSED" \
   && grep -q 'wait-ready --timeout' "$COMPOSED" \
   && grep -q 'KillShell' "$COMPOSED"; then
    ok "P68: an impl brief is composed with the headless rules appended to it"
else
    bad "P68: impl brief lacks the headless rules ($(cat "$COMPOSED" 2>/dev/null | tr '\n' ' ' | cut -c1-120))"
fi
# D-TICK-16: the rule names the tool it is about. "I backgrounded it and will be
# notified" was already forbidden, but a lane that thinks of it as "I'll schedule
# a wakeup" sails past a rule it technically read — two lanes did, in one day.
grep -q 'ScheduleWakeup' "$COMPOSED" \
    && ok "D-TICK-16: the appended brief names ScheduleWakeup as the thing not to reach for" \
    || bad "D-TICK-16: the headless rules never name ScheduleWakeup, only the shape"
# The rules are appended to the COPY. Mutating the wave's own file would make a
# reused brief grow a block per spawn.
grep -q 'KillShell' "$BR/clean.md" \
    && bad "P68: spawn-lane wrote the rules back into the wave's source brief" \
    || ok "P68: the source brief is untouched — only the lane's copy carries the rules"
# The composed brief itself must be clean of the shape it forbids, or every
# lane reads an instruction to do the one thing that cannot work.
if grep -qE '(^|[^A-Za-z0-9_./-])/(implement|loom|code-review|to-tickets)([^A-Za-z0-9-]|$)' "$COMPOSED"; then
    bad "P68: the composed brief contains a slash-command invocation"
else
    ok "P68: the composed brief carries no slash-command shape"
fi
# The failing side: the rules are not decoration, so the brief that names a
# skill is refused outright and no lane is spawned to die on it.
printf 'Run /implement 12 and report back.\n' > "$BR/slash.md"
out=$("$TICK" spawn-lane impl-72 --no-tick --cwd "$BR/wt" --brief "$BR/slash.md" -- true -p @brief 2>&1); rc_code=$?
if [ "$rc_code" -ne 0 ] && case "$out" in *"/implement"*) true;; *) false;; esac \
   && [ ! -f "$BR/wt/.lane-brief-impl-72.md" ] && [ ! -f "$LOOM_HOME/lanes/impl-72.pid" ]; then
    ok "P68: a brief instructing a skill invocation is refused, and nothing spawns"
else
    bad "P68: slash-command brief accepted (rc=$rc_code) — $out"
fi
# A brief that merely mentions a path or a word containing the same letters is
# not an invocation; refusing it would push waves back to inline prompts.
printf 'Edit src/implement/queue.ts; the loom/gate script stays as is.\n' > "$BR/pathy.md"
"$TICK" spawn-lane impl-73 --no-tick --cwd "$BR/wt" --brief "$BR/pathy.md" -- true -p @brief >/dev/null 2>&1
[ -f "$BR/wt/.lane-brief-impl-73.md" ] \
    && ok "P68: a path that merely contains a skill name is not a slash command" \
    || bad "P68: false positive — a plain path was read as a skill invocation"

# P31: the implementer's half of the adversarial deliverable rides the same
# append, so a wave cannot forget it. ai-workout build-1: four of seven gate
# FAILs were tests that ran and passed without asserting the bullet they were
# written for, and #31 spent a whole round being told its bullet was
# unsatisfiable — the one case more rounds cannot help.
if grep -q 'Mandatory adversarial tests' "$COMPOSED" \
   && grep -q 'the test function that asserts it' "$COMPOSED" \
   && grep -q 'unfinished work' "$COMPOSED" \
   && grep -q 'unsatisfiable ends the lane blocked' "$COMPOSED"; then
    ok "P31: an impl brief carries the bullet-to-test mapping and the unsatisfiable-bullet path"
else
    bad "P31: the impl brief does not require the bullet-to-test mapping"
fi
# Implementer instructions, and only the implementer's: a reviewer told to
# publish the mapping would be reading someone else's job off its own brief.
"$TICK" spawn-lane gate-74 --no-tick --cwd "$BR/wt" --brief "$BR/clean.md" -- true -p @brief >/dev/null 2>&1
if grep -q 'every step blocks' "$BR/wt/.lane-brief-gate-74.md" 2>/dev/null \
   && ! grep -q 'the test function that asserts it' "$BR/wt/.lane-brief-gate-74.md" 2>/dev/null; then
    ok "P31: a gate brief gets the headless rules and not the implementer's mapping duty"
else
    bad "P31: the mapping requirement leaked into a non-impl brief"
fi

# D-TICK-18: the brief plumbing is a pair of halves, and only one half was
# guarded. `--brief` with no `-p @brief` placeholder already died; `-p @brief`
# with no `--brief` sailed through and the lane was launched with the literal
# string `@brief` as its whole prompt — an @-mention of a file that does not
# exist. The pregate runs first, so the discovery costs a whole gate:
# boostlingo build-4 gate-98-r3 printed `gate[ui]: PASS`, then asked three times
# which of six brief-shaped files it meant to read and exited rc 0 with no
# verdict posted.
out=$("$TICK" spawn-lane gate-75 --no-tick --cwd "$BR/wt" -- true -p @brief 2>&1); rc_code=$?
if [ "$rc_code" -ne 0 ] && case "$out" in *"no --brief"*) true;; *) false;; esac \
   && [ ! -f "$LOOM_HOME/lanes/gate-75.pid" ]; then
    ok "D-TICK-18: '-p @brief' with no --brief is refused, and nothing spawns"
else
    bad "D-TICK-18: a placeholder with no file behind it was accepted (rc=$rc_code) — $out"
fi
# The refusal it mirrors, which had no test of its own either.
out=$("$TICK" spawn-lane gate-76 --no-tick --cwd "$BR/wt" --brief "$BR/clean.md" -- true -p 'do the thing' 2>&1); rc_code=$?
if [ "$rc_code" -ne 0 ] && case "$out" in *"-p @brief"*) true;; *) false;; esac; then
    ok "D-TICK-18: --brief with no '-p @brief' placeholder is still refused"
else
    bad "D-TICK-18: a brief with nowhere to go was accepted (rc=$rc_code) — $out"
fi
# A lane that carries its own prompt and never mentions the placeholder is the
# ordinary case, and refusing it would be worse than the defect.
"$TICK" spawn-lane gate-77 --no-tick --cwd "$BR/wt" -- true -p 'do the thing' >/dev/null 2>&1
[ -f "$LOOM_HOME/lanes/gate-77.pid" ] \
    && ok "D-TICK-18: a command with no placeholder and no brief still spawns" \
    || bad "D-TICK-18: false positive — a plain prompt was refused"

test_finish
