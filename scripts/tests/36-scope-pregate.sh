#!/usr/bin/env bash
# D-SKILL-16: a ticket may not ship another ticket's work
#
# Section 36 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- D-SKILL-16: the gate checks behaviour, and now also scope --------------
# triggers-api build-2: JOR-72 (`tier::ui`) met all nine of its acceptance
# criteria and also shipped ~105 lines of new API routes. Its gate brief asked
# nine questions about what the diff DID and none about what it TOUCHED, so it
# posted PASS, merged at 20:45, and made JOR-49 unmergeable — in a merge lane,
# where the skill forbids fixing anything. A `trees:` block makes "a `ui`
# ticket wrote `apps/api/src/**`" decidable in shell. One-directional like
# every other pregate check: every unknown skips and the runner decides.
SCR="$T/scope-repo"; mkdir -p "$SCR/apps/console/src" "$SCR/apps/api/src" "$SCR/scripts"
git -c init.defaultBranch=main init -q "$SCR" 2>/dev/null
git -C "$SCR" config user.email t@t; git -C "$SCR" config user.name t
# `logic` is declared in `gates:` but deliberately NOT in `trees:` — that is the
# per-tier absence case below. Every tier's command list is the runner alone, so
# the P31 adversarial check has no path to look at and never fires here; this
# section is about the scope check and nothing else.
cat > "$SCR/.loom.yml" <<'EOF'
base: main
gates:
  ui:
    - "bash scripts/gate.sh ui"
  logic:
    - "bash scripts/gate.sh logic"
trees:
  ui:   ["apps/console/**"]
  api:  ["apps/api/**"]
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCR/scripts/gate.sh"; chmod +x "$SCR/scripts/gate.sh"
: > "$SCR/apps/console/src/app.tsx"; : > "$SCR/apps/api/src/server.ts"
git -C "$SCR" add -A >/dev/null 2>&1; git -C "$SCR" commit -qm base >/dev/null 2>&1

# The tracker stub serves one issue body — the only ticket-side input the check
# reads, so the cases that differ only in what the ticket says swap it alone.
SCG="$T/scope-glab"
cat > "$SCG" <<'EOF'
#!/bin/sh
echo "$@" >> "${STUB_LOG:-/dev/null}"
printf '%s\n' "${STUB_BODY:-}"
EOF
chmod +x "$SCG"
SC_SILENT='{"description":"## Risk tier\n\nui\n\n## Acceptance criteria\n\n- Replay and Discard call the pinned endpoints\n"}'
SC_NAMED='{"description":"## Risk tier\n\nui\n\n## Files\n\n- apps/api/src/routes/replay.ts — the endpoint this ticket pins\n"}'

scope_spawn() { # <lane> <tick-binary> <log> <issue-body-json> <tier> <cwd> [<repo>]
    rm -f "$T/scope-ran-$1" "$LOOM_HOME/lanes/$1.rc"; : > "$3"
    rm -rf "$LOOM_HOME/tick.lock.d"
    LOOM_REPO="${7:-$SCR}" GLAB_CMD="$SCG" STUB_LOG="$3" STUB_BODY="$4" \
        "$2" spawn-lane "$1" --no-tick --pregate "$5" --cwd "$6" -- touch "$T/scope-ran-$1" >/dev/null 2>&1
    for _ in $(seq 1 60); do [ -f "$LOOM_HOME/lanes/$1.rc" ] && break; sleep 0.1; done
}

# 36a. A branch that stays inside its tier's declared tree passes through
#      untouched — the case every well-behaved ticket in an opted-in repo is,
#      so a false rejection here would be the expensive one.
git -C "$SCR" checkout -q -b feat-inside main 2>/dev/null
printf 'export const Replay = () => null;\n' > "$SCR/apps/console/src/replay.tsx"
git -C "$SCR" add -A >/dev/null 2>&1; git -C "$SCR" commit -qm inside >/dev/null 2>&1
scope_spawn gate-91 "$TICK" "$T/scope-calls-91" "$SC_SILENT" ui "$SCR"
if [ -f "$T/scope-ran-gate-91" ] && [ "$(cat "$LOOM_HOME/lanes/gate-91.rc" 2>/dev/null)" = "0" ]; then
    ok "scope-pregate: a branch inside its tier's tree reaches the review session"
else
    bad "scope-pregate: FALSE REJECTION — the branch touched only its own tree (rc=$(cat "$LOOM_HOME/lanes/gate-91.rc" 2>/dev/null))"
fi
# The tracker read is last, only for a candidate: a branch that stays home must
# not cost a round trip on every gate spawn.
[ -s "$T/scope-calls-91" ] \
    && bad "scope-pregate: an in-tree branch still paid for a tracker read ($(cat "$T/scope-calls-91"))" \
    || ok "scope-pregate: an in-tree branch costs no tracker read — the diff answers first"

# 36b. The rejection itself: JOR-72's shape. A `ui` branch that also writes
#      `apps/api/src/**`, on a ticket whose body says nothing about those files,
#      is rejected at rc 7 with no review session — and the lane log names both
#      the offending path and the tree the tier owns, so the wave's rejection
#      comment can say what went wrong without reading prose.
git -C "$SCR" checkout -q -b feat-outside main 2>/dev/null
printf 'export const Replay = () => null;\n' > "$SCR/apps/console/src/replay.tsx"
mkdir -p "$SCR/apps/api/src/routes"
printf 'export const replay = () => 1;\n' > "$SCR/apps/api/src/routes/replay.ts"
git -C "$SCR" add -A >/dev/null 2>&1; git -C "$SCR" commit -qm outside >/dev/null 2>&1
scope_spawn gate-92 "$TICK" "$T/scope-calls-92" "$SC_SILENT" ui "$SCR"
if [ ! -f "$T/scope-ran-gate-92" ] && [ "$(cat "$LOOM_HOME/lanes/gate-92.rc" 2>/dev/null)" = "7" ]; then
    ok "scope-pregate: a branch writing outside its tier's tree is rejected at rc 7, no review session"
else
    bad "scope-pregate: expected rc 7 with no session (rc=$(cat "$LOOM_HOME/lanes/gate-92.rc" 2>/dev/null), ran=$([ -f "$T/scope-ran-gate-92" ] && echo yes || echo no))"
fi
if grep -q "apps/api/src/routes/replay.ts" "$LOOM_HOME/logs/lane-gate-92.log" 2>/dev/null \
   && grep -q "apps/console/\*\*" "$LOOM_HOME/logs/lane-gate-92.log" 2>/dev/null; then
    ok "scope-pregate: the lane log names the offending path and the tree the tier owns"
else
    bad "scope-pregate: the rejection does not say which path left which tree"
fi

# 36c. The escape valve. Cross-tree work stays possible — it just has to be
#      written down first. The identical branch, on a ticket whose body names
#      the file, is a ticket that was scoped to touch it.
scope_spawn gate-93 "$TICK" "$T/scope-calls-93" "$SC_NAMED" ui "$SCR"
[ -f "$T/scope-ran-gate-93" ] \
    && ok "scope-pregate: a ticket body that names the out-of-tree file is not a violation" \
    || bad "scope-pregate: the escape valve failed — a ticket scoped to the file was rejected anyway (rc=$(cat "$LOOM_HOME/lanes/gate-93.rc" 2>/dev/null))"

# 36d. Per-tier absence. `logic` is a real gate tier in this repo and has no
#      `trees:` entry, so the same out-of-tree branch is not checked at all —
#      a repo may opt in one tier at a time.
scope_spawn gate-94 "$TICK" "$T/scope-calls-94" "$SC_SILENT" logic "$SCR"
[ -f "$T/scope-ran-gate-94" ] \
    && ok "scope-pregate: a tier with no trees entry is never scope-rejected" \
    || bad "scope-pregate: a tier the repo never declared a tree for was rejected anyway"

# 36e. THE case that matters most: a repo with no `trees:` block at all. Absence
#      is a complete configuration, and this feature must be incapable of newly
#      rejecting a branch in any repo that never opted in.
SCR2="$T/scope-repo-notrees"; mkdir -p "$SCR2/apps/console/src" "$SCR2/apps/api/src" "$SCR2/scripts"
git -c init.defaultBranch=main init -q "$SCR2" 2>/dev/null
git -C "$SCR2" config user.email t@t; git -C "$SCR2" config user.name t
printf 'base: main\ngates:\n  ui:\n    - "bash scripts/gate.sh ui"\n' > "$SCR2/.loom.yml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCR2/scripts/gate.sh"; chmod +x "$SCR2/scripts/gate.sh"
: > "$SCR2/apps/console/src/app.tsx"
git -C "$SCR2" add -A >/dev/null 2>&1; git -C "$SCR2" commit -qm base >/dev/null 2>&1
git -C "$SCR2" checkout -q -b feat-everywhere main 2>/dev/null
mkdir -p "$SCR2/apps/api/src/routes" "$SCR2/packages/core"
printf 'export const replay = () => 1;\n' > "$SCR2/apps/api/src/routes/replay.ts"
printf 'export const core = 1;\n' > "$SCR2/packages/core/index.ts"
git -C "$SCR2" add -A >/dev/null 2>&1; git -C "$SCR2" commit -qm everywhere >/dev/null 2>&1
scope_spawn gate-95 "$TICK" "$T/scope-calls-95" "$SC_SILENT" ui "$SCR2" "$SCR2"
[ -f "$T/scope-ran-gate-95" ] \
    && ok "scope-pregate: a repo with no trees: block is never scope-rejected, whatever the diff touches" \
    || bad "scope-pregate: an un-opted-in repo was rejected — this feature broke every existing repo"
[ -s "$T/scope-calls-95" ] \
    && bad "scope-pregate: an un-opted-in repo still paid for a tracker read ($(cat "$T/scope-calls-95"))" \
    || ok "scope-pregate: an un-opted-in repo costs no tracker read either"

# 36f. Gate lanes only. The check reads a FINISHED branch; run against an
#      implementer it would reject work before the lane had written any of it.
scope_spawn impl-96 "$TICK" "$T/scope-calls-96" "$SC_SILENT" ui "$SCR"
[ -f "$T/scope-ran-impl-96" ] \
    && ok "scope-pregate: an impl lane is never scope-rejected before it has written anything" \
    || bad "scope-pregate: the check fired on an implementer"

# 36g. Planted violation: take the scope check out of the pregate — today's
#      behaviour before this fix — and JOR-72's branch spends the review
#      session, passes on behaviour alone, and reaches the merge queue carrying
#      another ticket's module.
SCM_A="$(mirror_scripts "$T/scope-mut-nocheck")"
sed 's|^        elif \[ -n "\$adv_iid" \] \&\& scope_hit=\$(_scope_pregate_reject "\$adv_iid" "\$pregate" "\$abs"); then$|        elif false; then|' \
    "$TICK" > "$SCM_A/tick.sh"
chmod +x "$SCM_A/tick.sh"
if ! diff -q "$TICK" "$SCM_A/tick.sh" >/dev/null 2>&1; then
    git -C "$SCR" checkout -q feat-outside 2>/dev/null
    scope_spawn gate-97 "$SCM_A/tick.sh" "$T/scope-calls-97" "$SC_SILENT" ui "$SCR"
    [ -f "$T/scope-ran-gate-97" ] \
        && ok "scope-pregate-violation: with no scope check the out-of-tree branch burns the session and ships" \
        || bad "scope-pregate-violation: something else rejected the branch, so the guard proves nothing"
else
    bad "scope-pregate-violation: sed did not match the wiring line, mutant is identical to the fix"
fi

# 36h. Planted violation, the other half: drop the ticket-body escape valve and
#      a ticket that legitimately names its cross-tree file is rejected anyway —
#      unsatisfiable, since the answer lives in the ticket, not the branch.
SCM_B="$(mirror_scripts "$T/scope-mut-novalve")"
sed 's|^        case "\$body" in \*"\$f"\*) continue ;; esac$|        :|' "$TICK" > "$SCM_B/tick.sh"
chmod +x "$SCM_B/tick.sh"
if ! diff -q "$TICK" "$SCM_B/tick.sh" >/dev/null 2>&1; then
    scope_spawn gate-98 "$SCM_B/tick.sh" "$T/scope-calls-98" "$SC_NAMED" ui "$SCR"
    if [ ! -f "$T/scope-ran-gate-98" ] && [ "$(cat "$LOOM_HOME/lanes/gate-98.rc" 2>/dev/null)" = "7" ]; then
        ok "scope-pregate-violation: without the escape valve a ticket that named its file is rejected forever"
    else
        bad "scope-pregate-violation: the mutant did not reject, so the escape valve proves nothing (rc=$(cat "$LOOM_HOME/lanes/gate-98.rc" 2>/dev/null))"
    fi
else
    bad "scope-pregate-violation: sed did not match the escape-valve line, mutant is identical to the fix"
fi

test_finish
