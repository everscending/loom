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
COMPOSED="$LOOM_HOME/briefs/impl-71.md"
if [ -f "$COMPOSED" ] && grep -q 'Implement ticket 12' "$COMPOSED" \
   && grep -q 'every step blocks' "$COMPOSED" \
   && grep -q 'Finite commands.*builds, tests and gates.*foreground' "$COMPOSED" \
   && grep -q 'poll that same running session' "$COMPOSED" \
   && grep -q 'Do not rerun the command' "$COMPOSED" \
   && grep -q 'Do not add.*timeout' "$COMPOSED" \
   && grep -q 'wait-ready --timeout' "$COMPOSED" \
   && grep -q 'KillShell' "$COMPOSED" \
   && grep -q 'blocked-report <iid> --category <slug>' "$COMPOSED" \
   && grep -q 'transition <iid> blocked' "$COMPOSED" \
   && grep -q 'Do not exit after only the report or only the transition' "$COMPOSED"; then
    ok "P68: an impl brief is composed with the headless rules appended to it"
else
    bad "P68: impl brief lacks the headless rules ($(cat "$COMPOSED" 2>/dev/null | tr '\n' ' ' | cut -c1-120))"
fi
# P106: #130 reproduced #136's half-transition from a non-merge lane: the
# report landed, the state did not. Every lane kind receives this sequence
# from the common append, so recovery is immediate rather than waiting for a
# later planner wave to notice and repair it.
grep -q 'blocked-report <iid>.*then immediately run .*transition <iid> blocked' "$COMPOSED" \
    && ok "P106: every headless lane is told that blocked report + transition is one terminal sequence" \
    || bad "P106: a lane may still exit after only half of the blocked transition"
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
# D-TICK-28: a wave may compose from the ticket's original body even after a
# human rescope. The immutable action is the provider-neutral source of truth;
# spawn-lane must mechanically carry that later note into the staged brief.
printf 'Original ticket body: adjust the existing booking UI only.\n' > "$BR/pre-rescope.md"
cat > "$BR/rescope-plan.json" <<'EOF'
{"actions":[{"lane":"impl-70","ticket":70,"spawn":{"brief":{"active_scope_reset":{"at":"2026-08-10T09:58:00Z","body":"Supervisor scope: own lib/scheduling/booking.ts list and persisted-transition seam.\n\n<!-- orch-scope-reset 2026-08-10T09:58:00Z -->"}}}}]}
EOF
LOOM_WAVE_PLAN="$BR/rescope-plan.json" \
    "$TICK" spawn-lane impl-70 --no-tick --cwd "$BR/wt" --brief "$BR/pre-rescope.md" -- true -p @brief >/dev/null 2>&1
if grep -q 'lib/scheduling/booking.ts' "$LOOM_HOME/briefs/impl-70.md" 2>/dev/null \
   && grep -q 'persisted-transition seam' "$LOOM_HOME/briefs/impl-70.md" 2>/dev/null \
   && ! grep -q 'lib/scheduling/booking.ts' "$BR/pre-rescope.md"; then
    ok "D-TICK-28: staged implementation brief carries the immutable active rescope"
else
    bad "D-TICK-28: staged brief reused the original pre-rescope scope"
fi
# The Codex path crosses a durable queue instead of staging immediately. The
# plan may be scratch-lifetime state, so its rescope must be frozen into the
# queue request before the provider session exits.
LOOM_DEFER_LANE_LAUNCH=1 LOOM_WAVE_PLAN="$BR/rescope-plan.json" \
    "$TICK" spawn-lane impl-70 --no-tick --provider codex --job implementation --tier medium \
    --cwd "$LOOM_REPO" --brief "$BR/pre-rescope.md" >/dev/null 2>&1
queued_rescope=$(find "$LOOM_HOME/lane-launch-queue" -type f -name brief.md -print -quit 2>/dev/null)
if [ -n "$queued_rescope" ] && grep -q 'lib/scheduling/booking.ts' "$queued_rescope"; then
    ok "D-TICK-28: deferred provider request freezes the rescope before the plan expires"
else
    bad "D-TICK-28: deferred provider request lost the active rescope"
fi
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
   && [ ! -f "$LOOM_HOME/briefs/impl-72.md" ] && [ ! -f "$LOOM_HOME/lanes/impl-72.pid" ]; then
    ok "P68: a brief instructing a skill invocation is refused, and nothing spawns"
else
    bad "P68: slash-command brief accepted (rc=$rc_code) — $out"
fi
# A brief that merely mentions a path or a word containing the same letters is
# not an invocation; refusing it would push waves back to inline prompts.
printf 'Edit src/implement/queue.ts; the loom/gate script stays as is.\n' > "$BR/pathy.md"
"$TICK" spawn-lane impl-73 --no-tick --cwd "$BR/wt" --brief "$BR/pathy.md" -- true -p @brief >/dev/null 2>&1
[ -f "$LOOM_HOME/briefs/impl-73.md" ] \
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
if grep -q 'every step blocks' "$LOOM_HOME/briefs/gate-74.md" 2>/dev/null \
   && ! grep -q 'the test function that asserts it' "$LOOM_HOME/briefs/gate-74.md" 2>/dev/null; then
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

# --- P82: a brief never lands in a working tree ---------------------------
# Five builds, thirty worktrees, none ever swept. Half were held by nothing but
# the brief sitting in them: `git status --porcelain` lists it, sweep's
# unsaved-work guard (D-TICK-17) reads untracked as a lane's unsaved work, and
# keeps the worktree forever. The guard is right; the brief's location was not.
P82WT="$BR/p82wt"; mkdir -p "$P82WT"
git -C "$P82WT" init -q 2>/dev/null
printf 'Do the thing.\n' > "$BR/p82.md"
"$TICK" spawn-lane impl-82 --no-tick --cwd "$P82WT" --brief "$BR/p82.md" -- true -p @brief >/dev/null 2>&1
if [ -z "$(git -C "$P82WT" status --porcelain 2>/dev/null)" ]; then
    ok "P82: a spawned lane leaves its worktree clean — nothing for sweep to hold"
else
    bad "P82: the worktree still holds untracked work after a spawn ($(git -C "$P82WT" status --porcelain | head -1))"
fi
# ...and it landed in the run directory instead, where the pid files and locks
# already live.
[ -s "$LOOM_HOME/briefs/impl-82.md" ] \
    && ok "P82: the composed brief lives in the run directory" \
    || bad "P82: no brief at \$LOOM_HOME/briefs/impl-82.md"
# The pointer prompt must name it ABSOLUTELY. The old prompt said "in your
# working directory"; the file is no longer beside the session's cwd, so a
# relative pointer would send every lane looking for a file that is not there.
capture_spawn_argv() { # <id> <brief> — prints the argv the lane was launched with
    local av="$T/p82-argv-$1"; rm -f "$av"
    cat > "$T/p82-cmd.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$av"
EOS
    chmod +x "$T/p82-cmd.sh"
    "$TICK" spawn-lane "$1" --no-tick --cwd "$P82WT" --brief "$2" -- "$T/p82-cmd.sh" -p @brief >/dev/null 2>&1
    sleep 0.4; cat "$av" 2>/dev/null
}
argv=$(capture_spawn_argv impl-83 "$BR/p82.md")
case "$argv" in
    *"$LOOM_HOME/briefs/impl-83.md"*) ok "P82: the pointer prompt names the brief by absolute path" ;;
    *) bad "P82: pointer prompt does not carry the absolute brief path ($(printf '%s' "$argv" | tr '\n' ' ' | cut -c1-140))" ;;
esac

# The other half: the SOURCE brief. spawn-lane's copy was only one of the three
# filename shapes found in build-5 — `.gate-brief-114.md` and `.impl-brief-128.md`
# were written into the worktree by waves, and this function could not produce
# either. The convention (`lane.sh scratch`) existed; nothing enforced it.
printf 'Do the thing.\n' > "$P82WT/in-tree-brief.md"
out=$("$TICK" spawn-lane impl-84 --no-tick --cwd "$P82WT" --brief "$P82WT/in-tree-brief.md" -- true -p @brief 2>&1); rc_code=$?
if [ "$rc_code" -ne 0 ] && case "$out" in *"lane.sh scratch"*) true;; *) false;; esac; then
    ok "P82: a brief written inside the lane worktree is refused, naming lane.sh scratch"
else
    bad "P82: in-worktree brief accepted (rc=$rc_code) — $out"
fi
printf 'Do the thing.\n' > "$LOOM_REPO/in-repo-brief.md"
out=$("$TICK" spawn-lane impl-85 --no-tick --cwd "$P82WT" --brief "$LOOM_REPO/in-repo-brief.md" -- true -p @brief 2>&1); rc_code=$?
[ "$rc_code" -ne 0 ] \
    && ok "P82: a brief inside the repo root is refused too" \
    || bad "P82: a brief in the repo root was accepted"
rm -f "$LOOM_REPO/in-repo-brief.md"
# The accepting direction, or the refusal would just be a ban on briefs.
out=$("$TICK" spawn-lane impl-86 --no-tick --cwd "$P82WT" --brief "$(cd "$BR" && pwd -P)/p82.md" -- true -p @brief 2>&1); rc_code=$?
[ "$rc_code" -eq 0 ] \
    && ok "P82: a brief outside every working tree is accepted" \
    || bad "P82: a scratch-side brief was refused (rc=$rc_code) — $out"

# P75 pin: the refusal is above the destructive line, so a brief rejected for
# its location leaves the previous run's log and rc byte-identical.
prev_rc=$(cat "$LOOM_HOME/lanes/impl-86.rc" 2>/dev/null || echo missing)
prev_log=$(cksum "$LOOM_HOME/logs/lane-impl-86.log" 2>/dev/null || echo missing)
printf 'Do the thing.\n' > "$P82WT/again.md"
"$TICK" spawn-lane impl-86 --no-tick --cwd "$P82WT" --brief "$P82WT/again.md" -- true -p @brief >/dev/null 2>&1
now_rc=$(cat "$LOOM_HOME/lanes/impl-86.rc" 2>/dev/null || echo missing)
now_log=$(cksum "$LOOM_HOME/logs/lane-impl-86.log" 2>/dev/null || echo missing)
if [ "$prev_rc" = "$now_rc" ] && [ "$prev_log" = "$now_log" ]; then
    ok "P82: a location refusal destroys nothing — prior rc and log untouched"
else
    bad "P82: the refused spawn clobbered the previous run (rc $prev_rc->$now_rc)"
fi


test_finish
