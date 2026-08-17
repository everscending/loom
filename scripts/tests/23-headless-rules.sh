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
# D-TICK-38: the replacement scope must bind the independent gate as well as
# implementation. JOR-240's gate brief omitted it and restored requirements
# that the human had explicitly assigned to other tickets.
printf 'Original gate brief: require both DST dates and the patient booking collision.\n' > "$BR/pre-rescope-gate.md"
cat > "$BR/gate-rescope-plan.json" <<'EOF'
{"actions":[{"lane":"gate-70","ticket":70,"spawn":{"brief":{"active_scope_reset":{"at":"2026-08-10T09:59:00Z","body":"Replacement gate scope: availability round-trip only; DST and booking are owned elsewhere.\n\n<!-- orch-scope-reset 2026-08-10T09:59:00Z -->"}}}}]}
EOF
LOOM_WAVE_PLAN="$BR/gate-rescope-plan.json" \
    "$TICK" spawn-lane gate-70 --no-tick --cwd "$BR/wt" --brief "$BR/pre-rescope-gate.md" -- true -p @brief >/dev/null 2>&1
if grep -q 'availability round-trip only' "$LOOM_HOME/briefs/gate-70.md" 2>/dev/null \
   && grep -q 'DST and booking are owned elsewhere' "$LOOM_HOME/briefs/gate-70.md" 2>/dev/null \
   && ! grep -q 'availability round-trip only' "$BR/pre-rescope-gate.md"; then
    ok "D-TICK-38: staged gate brief carries the immutable active rescope"
else
    bad "D-TICK-38: staged gate brief reused the superseded review contract"
fi
# D-TICK-39: after a completed supervised repair, a later gate rejection can
# return the ticket to rework. The immutable repair evidence must reach that
# implementation brief or the worker can delete the exact fix as "out of scope."
printf 'Original ticket scope: only edit the four listed feature files.\n' > "$BR/pre-repair-rework.md"
cat > "$BR/repair-plan.json" <<'EOF'
{"actions":[{"lane":"impl-69","ticket":69,"spawn":{"brief":{"active_supervised_repair":{"at":"2026-08-10T09:59:00Z","body":"Verified repair a84fcf3 adds db/deploy/reminder-cron.sql, scripts/configure-reminder-cron.sh, and tests/deploy/reminder-cron-config.test.ts; preserve them.\n\n<!-- orch-supervised-repair 2026-08-10T09:59:00Z -->"}}}}]}
EOF
LOOM_WAVE_PLAN="$BR/repair-plan.json" \
    "$TICK" spawn-lane impl-69 --no-tick --cwd "$BR/wt" --brief "$BR/pre-repair-rework.md" -- true -p @brief >/dev/null 2>&1
if grep -q 'db/deploy/reminder-cron.sql' "$LOOM_HOME/briefs/impl-69.md" 2>/dev/null \
   && grep -q 'preserve them' "$LOOM_HOME/briefs/impl-69.md" 2>/dev/null; then
    ok "D-TICK-39: staged rework brief carries completed repair evidence"
else
    bad "D-TICK-39: staged rework brief lost the repair it must preserve"
fi
# D-TICK-40: workers must not need ambient tracker credentials to learn their
# acceptance contract. Freeze the host-read body into the action and append it
# mechanically before either provider starts.
printf 'Implement ticket 67 using the immutable plan inputs.\n' > "$BR/contract-source.md"
cat > "$BR/contract-plan.json" <<'EOF'
{"actions":[{"lane":"impl-67","ticket":67,"spawn":{"brief":{"ticket_contract":"## Acceptance criteria\n\n- [ ] Run the committed benchmark\n\n## Mandatory adversarial tests\n\n- [ ] Missing baseline fails closed\n"}}}]}
EOF
LOOM_WAVE_PLAN="$BR/contract-plan.json" \
    "$TICK" spawn-lane impl-67 --no-tick --cwd "$BR/wt" --brief "$BR/contract-source.md" -- true -p @brief >/dev/null 2>&1
if grep -q 'Run the committed benchmark' "$LOOM_HOME/briefs/impl-67.md" 2>/dev/null \
   && grep -q 'Missing baseline fails closed' "$LOOM_HOME/briefs/impl-67.md" 2>/dev/null \
   && ! grep -q 'Run the committed benchmark' "$BR/contract-source.md"; then
    ok "D-TICK-40: staged worker brief carries the host-read ticket contract"
else
    bad "D-TICK-40: worker still depends on ambient tracker access"
fi
# JOR-221: receiving the whole host-snapshotted contract was not enough. Its
# implementation worker still tried to rediscover the ticket with nonexistent
# `lane.sh show 221`. The public staging seam must bind both a direct Claude
# brief and a deferred Codex request to the immutable contract as their complete
# authority, including the documented lane.sh terminal paths.
cat > "$BR/authority-plan.json" <<'EOF'
{"actions":[
  {"lane":"impl-65","ticket":65,"spawn":{"brief":{"ticket_contract":"## Acceptance criteria\n\n- [ ] Trust the embedded contract\n"}}},
  {"lane":"impl-66","ticket":66,"spawn":{"brief":{"ticket_contract":"## Acceptance criteria\n\n- [ ] Trust the embedded contract\n"}}}
]}
EOF
AUTHORITY_AGENT="$BR/authority-agent.sh"
cat > "$AUTHORITY_AGENT" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  detect|preflight|run) exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$AUTHORITY_AGENT"
AUTHORITY_HOME="$T/authority-home"
AUTHORITY_REPO="$T/authority-repo"
mkdir -p "$AUTHORITY_REPO"
seed_tracker_decl "$AUTHORITY_REPO"
cp "$LOOM_REPO/.loom.yml" "$AUTHORITY_REPO/.loom.yml"
git -C "$AUTHORITY_REPO" add .
git -C "$AUTHORITY_REPO" commit -qm 'authority fixture'
if LOOM_HOME="$AUTHORITY_HOME" LOOM_REPO="$AUTHORITY_REPO" LOOM_DEFER_LANE_LAUNCH= \
    LOOM_AGENT_CMD="$AUTHORITY_AGENT" LOOM_WAVE_PLAN="$BR/authority-plan.json" \
    "$TICK" spawn-lane impl-66 --no-tick --provider claude --job implementation --tier medium \
    --cwd "$AUTHORITY_REPO" --brief "$BR/contract-source.md" >"$BR/authority-claude.out" 2>&1; then
    claude_spawn_rc=0
else
    claude_spawn_rc=$?
fi
LOOM_HOME="$AUTHORITY_HOME" LOOM_REPO="$AUTHORITY_REPO" LOOM_DEFER_LANE_LAUNCH=1 LOOM_WAVE_PLAN="$BR/authority-plan.json" \
    "$TICK" spawn-lane impl-65 --no-tick --provider codex --job implementation --tier medium \
    --cwd "$AUTHORITY_REPO" --brief "$BR/contract-source.md" >/dev/null 2>&1
claude_authority="$AUTHORITY_HOME/briefs/impl-66.md"
codex_authority=""
for authority_request in "$AUTHORITY_HOME/lane-launch-queue"/request-*; do
    [ -d "$authority_request" ] || continue
    [ "$(cat "$authority_request/id" 2>/dev/null)" = impl-65 ] || continue
    codex_authority="$authority_request/brief.md"
    break
done
authority_paths=0
for authority_brief in "$claude_authority" "$codex_authority"; do
    [ -n "$authority_brief" ] || continue
    if grep -q 'complete and authoritative' "$authority_brief" \
       && grep -q 'Do not query the tracker' "$authority_brief" \
       && grep -q 'lane.sh show' "$authority_brief" \
       && grep -q 'lane.sh scratch' "$authority_brief" \
       && grep -q 'lane.sh blocked-report' "$authority_brief" \
       && grep -q 'lane.sh submit' "$authority_brief" \
       && grep -q 'exact.*verdict.*merge.*command' "$authority_brief"; then
        authority_paths=$((authority_paths + 1))
    fi
done
if [ "$authority_paths" = 2 ]; then
    ok "immutable authority: direct Claude and deferred Codex briefs forbid tracker rediscovery and invented lane verbs"
else
    bad "immutable authority: only $authority_paths/2 provider paths received the authoritative contract rules (Claude spawn rc=$claude_spawn_rc: $(tr '\n' ' ' < "$BR/authority-claude.out"))"
fi
# Planted violation: remove only the mechanically appended authority block.
# The ticket body must still reach the public spawn seam while the protection
# against tracker rediscovery disappears, proving the assertion is sensitive
# to this rule rather than merely to D-TICK-40's contract transport.
AUTHORITY_MUT=$(mirror_scripts "$T/immutable-authority-mutant")
sed '/## Immutable contract authority (appended by spawn-lane)/,/^\$_contract_marker$/d' \
    "$AUTHORITY_MUT/tick.sh" > "$AUTHORITY_MUT/tick-mutant.sh"
mv "$AUTHORITY_MUT/tick-mutant.sh" "$AUTHORITY_MUT/tick.sh"
chmod +x "$AUTHORITY_MUT/tick.sh"
AUTHORITY_MUT_HOME="$T/immutable-authority-mutant-home"
authority_mut_out=$(LOOM_HOME="$AUTHORITY_MUT_HOME" LOOM_WAVE_PLAN="$BR/authority-plan.json" \
    "$AUTHORITY_MUT/tick.sh" spawn-lane impl-65 --no-tick --cwd "$BR/wt" \
    --brief "$BR/contract-source.md" -- /bin/echo immutable-authority-violation -p @brief 2>&1)
authority_mut_rc=$?
if assert_mutant_ran "$authority_mut_rc" "$authority_mut_out" "immutable-authority-violation" \
   && grep -q 'Trust the embedded contract' "$AUTHORITY_MUT_HOME/briefs/impl-65.md" 2>/dev/null \
   && ! grep -q 'complete and authoritative' "$AUTHORITY_MUT_HOME/briefs/impl-65.md" 2>/dev/null; then
    ok "immutable authority mutant: deleting the rule recreates tracker-dependent worker discretion"
else
    bad "immutable authority mutant: planted rule deletion did not reach the public spawn seam (rc=$authority_mut_rc)"
fi
# Planted violations prove these assertions exercise the shared spawn boundary,
# not only the fixture text.
D38_MUT=$(mirror_scripts "$T/dtick38-mutant")
sed 's/impl|gate) ;; \*) return 0 ;;/impl) ;; *) return 0 ;;/' "$D38_MUT/tick.sh" > "$D38_MUT/tick-mutant.sh"
mv "$D38_MUT/tick-mutant.sh" "$D38_MUT/tick.sh"
chmod +x "$D38_MUT/tick.sh"
cat > "$BR/gate-rescope-mutant-plan.json" <<'EOF'
{"actions":[{"lane":"gate-72","ticket":72,"spawn":{"brief":{"active_scope_reset":{"at":"2026-08-10T09:59:00Z","body":"Replacement gate scope: availability round-trip only.\n\n<!-- orch-scope-reset 2026-08-10T09:59:00Z -->"}}}}]}
EOF
D38_HOME="$T/dtick38-mutant-home"
d38_out=$(LOOM_HOME="$D38_HOME" LOOM_WAVE_PLAN="$BR/gate-rescope-mutant-plan.json" \
    "$D38_MUT/tick.sh" spawn-lane gate-72 --no-tick --cwd "$BR/wt" \
    --brief "$BR/pre-rescope-gate.md" -- /bin/echo D-TICK-38-scope-transport-violation -p @brief 2>&1)
d38_rc=$?
if assert_mutant_ran "$d38_rc" "$d38_out" "D-TICK-38-scope-transport-violation" \
   && ! grep -q 'availability round-trip only' "$D38_HOME/briefs/gate-72.md" 2>/dev/null; then
    ok "D-TICK-38 mutant: excluding gates recreates the superseded-contract escape"
else
    bad "D-TICK-38 mutant: planted gate exclusion did not recreate the escape (rc=$d38_rc)"
fi

D39_MUT=$(mirror_scripts "$T/dtick39-mutant")
sed '/_append_active_supervised_repair "$id" "$BRIEFS_DIR\/$id.md"/d' \
    "$D39_MUT/tick.sh" > "$D39_MUT/tick-mutant.sh"
mv "$D39_MUT/tick-mutant.sh" "$D39_MUT/tick.sh"
chmod +x "$D39_MUT/tick.sh"
cat > "$BR/repair-mutant-plan.json" <<'EOF'
{"actions":[{"lane":"impl-68","ticket":68,"spawn":{"brief":{"active_supervised_repair":{"at":"2026-08-10T09:59:00Z","body":"Verified repair a84fcf3 adds db/deploy/reminder-cron.sql; preserve it.\n\n<!-- orch-supervised-repair 2026-08-10T09:59:00Z -->"}}}}]}
EOF
D39_HOME="$T/dtick39-mutant-home"
d39_out=$(LOOM_HOME="$D39_HOME" LOOM_WAVE_PLAN="$BR/repair-mutant-plan.json" \
    "$D39_MUT/tick.sh" spawn-lane impl-68 --no-tick --cwd "$BR/wt" \
    --brief "$BR/pre-repair-rework.md" -- /bin/echo D-TICK-39-repair-transport-violation -p @brief 2>&1)
d39_rc=$?
if assert_mutant_ran "$d39_rc" "$d39_out" "D-TICK-39-repair-transport-violation" \
   && ! grep -q 'db/deploy/reminder-cron.sql' "$D39_HOME/briefs/impl-68.md" 2>/dev/null; then
    ok "D-TICK-39 mutant: deleting the shared append recreates repair erasure"
else
    bad "D-TICK-39 mutant: planted append deletion did not recreate the escape (rc=$d39_rc)"
fi

D40_MUT=$(mirror_scripts "$T/dtick40-mutant")
sed '/_append_ticket_contract "$id" "$BRIEFS_DIR\/$id.md"/d' \
    "$D40_MUT/tick.sh" > "$D40_MUT/tick-mutant.sh"
mv "$D40_MUT/tick-mutant.sh" "$D40_MUT/tick.sh"
chmod +x "$D40_MUT/tick.sh"
D40_HOME="$T/dtick40-mutant-home"
d40_out=$(LOOM_HOME="$D40_HOME" LOOM_WAVE_PLAN="$BR/contract-plan.json" \
    "$D40_MUT/tick.sh" spawn-lane impl-67 --no-tick --cwd "$BR/wt" \
    --brief "$BR/contract-source.md" -- /bin/echo D-TICK-40-contract-transport-violation -p @brief 2>&1)
d40_rc=$?
if assert_mutant_ran "$d40_rc" "$d40_out" "D-TICK-40-contract-transport-violation" \
   && ! grep -q 'Run the committed benchmark' "$D40_HOME/briefs/impl-67.md" 2>/dev/null; then
    ok "D-TICK-40 mutant: deleting the shared append recreates tracker-dependent work"
else
    bad "D-TICK-40 mutant: planted append deletion did not recreate the missing contract (rc=$d40_rc)"
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
# D-TICK-34: a browser that dies in the provider sandbox before opening a page
# has not observed the product. The live E2 probe filed a product ticket for
# Chromium's macOS Mach-port denial even though host-owned UI gates launched
# Chromium from the same checkout. The staged probe brief is the public,
# provider-neutral seam that must classify that boundary.
printf 'Exercise E2 in a real browser against the running stack.\n' > "$BR/probe.md"
"$TICK" spawn-lane probe-e2 --no-tick --cwd "$BR/wt" --brief "$BR/probe.md" \
    -- true -p @brief >/dev/null 2>&1
PROBE_COMPOSED="$LOOM_HOME/briefs/probe-e2.md"
if grep -q 'before the first product request is probe infrastructure' "$PROBE_COMPOSED" \
   && grep -q 'do not call.*lane.sh fix-ticket' "$PROBE_COMPOSED" \
   && grep -q 'probe-result <build-iid> <epic-slug> infrastructure' "$PROBE_COMPOSED"; then
    ok "D-TICK-34: staged probe classifies pre-product browser denial without a product fix"
else
    bad "D-TICK-34: staged probe can still turn provider infrastructure into a product ticket"
fi

# Planted violation: delete only the classifier from a private scripts mirror.
# The public spawn seam must then reproduce the missing guard.
D34_MUT=$(mirror_scripts "$T/dtick34-mutant")
sed '/Before filing a product fix/d' "$D34_MUT/tick.sh" > "$D34_MUT/tick-mutant.sh"
mv "$D34_MUT/tick-mutant.sh" "$D34_MUT/tick.sh"
chmod +x "$D34_MUT/tick.sh"
D34_HOME="$T/dtick34-mutant-home"
d34_out=$(LOOM_HOME="$D34_HOME" "$D34_MUT/tick.sh" spawn-lane probe-e2-mutant \
    --no-tick --cwd "$BR/wt" --brief "$BR/probe.md" -- /bin/echo mutant-ran -p @brief 2>&1)
d34_rc=$?
if assert_mutant_ran "$d34_rc" "$d34_out" "D-TICK-34-probe-classification-violation"; then
    if [ "$d34_rc" -eq 0 ] \
       && ! grep -q 'before the first product request is probe infrastructure' "$D34_HOME/briefs/probe-e2-mutant.md" 2>/dev/null; then
        ok "D-TICK-34 mutant: removing the classifier recreates the false-product-ticket escape"
    else
        bad "D-TICK-34 mutant: planted classifier removal did not reach the public spawn seam (rc=$d34_rc)"
    fi
fi
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
