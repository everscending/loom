#!/usr/bin/env bash
# P60 gate-deps: a gate command may never depend on an unmerged deliverable
#
# Section 24 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- P60 gate-deps: a gate command may never depend on an unmerged deliverable
# ai-workout build-1: the ticket graph was acyclic, but the GATE graph was not —
# .loom.yml tiers invoked scripts/gate.sh (#7's deliverable) and
# gen_openapi_client.py (#6's); merge lanes died on the missing files and the
# build stalled ~1h for a human waiver. The definition-time half: resolve the
# files the gate commands invoke, check them against the base branch, refuse
# naming the offending command.
GD="$T/gatedeps"; mkdir -p "$GD"
git -c init.defaultBranch=main init -q --bare "$GD/origin.git" 2>/dev/null
git clone -q "$GD/origin.git" "$GD/repo" 2>/dev/null
GITG() { git -C "$GD/repo" -c user.email=t@t.t -c user.name=t "$@"; }
mkdir -p "$GD/repo/scripts"
printf '#!/bin/sh\nexit 0\n' > "$GD/repo/scripts/gate.sh"
printf 'client\n' > "$GD/repo/scripts/gen_client.py"
GITG add scripts >/dev/null 2>&1; GITG commit -qm base; GITG push -q origin main
cat > "$GD/repo/.loom.yml" <<'EOF'
runner: scripts/gate.sh
gates:
  api:
    - "python scripts/gen_client.py --check"
    - "pytest tests/*.py"
    - "curl -fsS https://example.com/api.sh"
  ui:
    - "bash scripts/gate.sh ui"
EOF

# gd1. Every invoked file on base → the check can PASS (rc 0), and glob, flag
#      and URL tokens are never resolved as files — a false refusal at
#      definition time is the falsifier the proposal names.
out=$(LOOM_REPO="$GD/repo" "$TICK" gate-deps 2>&1); rc_gd=$?
if [ "$rc_gd" -eq 0 ] && printf '%s' "$out" | grep -q "exists on origin/main"; then
    ok "gate-deps: all files on base passes — globs, flags and URLs are not resolved"
else
    bad "gate-deps: clean repo refused (rc=$rc_gd: $out)"
fi

# gd2. A gate command invoking a file absent from base → refused, NAMING the
#      offending command — the guard holding. The file stays in the working
#      tree, exactly like a deliverable sitting in an unmerged ticket branch.
GITG rm -q --cached scripts/gen_client.py; GITG commit -qm "remove client gen"; GITG push -q origin main
out=$(LOOM_REPO="$GD/repo" "$TICK" gate-deps 2>&1); rc_gd=$?
if [ "$rc_gd" -eq 1 ] && printf '%s' "$out" | grep -q "scripts/gen_client.py" \
   && printf '%s' "$out" | grep -q "python scripts/gen_client.py --check"; then
    ok "gate-deps: a file missing from base is refused naming the offending command"
else
    bad "gate-deps: missing gen_client.py not refused or not named (rc=$rc_gd: $out)"
fi

# gd3. The runner is a dependency of EVERY tier — its absence is named as the
#      runner, not as one tier's command.
GITG rm -q --cached scripts/gate.sh; GITG commit -qm "remove runner"; GITG push -q origin main
out=$(LOOM_REPO="$GD/repo" "$TICK" gate-deps 2>&1); rc_gd=$?
if [ "$rc_gd" -eq 1 ] && printf '%s' "$out" | grep -q "the gate runner"; then
    ok "gate-deps: a missing runner is refused as the runner every tier needs"
else
    bad "gate-deps: missing runner not refused as such (rc=$rc_gd: $out)"
fi

# gd4. A derived-gates repo — no gates block, no explicit runner — is NOT
#      refused for lacking a file it never uses: the standing-false-refusal
#      guard on the other side.
rm -f "$GD/repo/.loom.yml"
out=$(LOOM_REPO="$GD/repo" "$TICK" gate-deps 2>&1); rc_gd=$?
[ "$rc_gd" -eq 0 ] \
    && ok "gate-deps: a repo with no gates block and no runner is not refused" \
    || bad "gate-deps: derived-gates repo falsely refused (rc=$rc_gd: $out)"

test_finish
