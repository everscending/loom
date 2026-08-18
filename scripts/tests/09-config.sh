#!/usr/bin/env bash
# P22 layered config: repo > derived > global > built-in
#
# Section 09 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

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
# lane/wave tier invisible in output, wave nearly spawned every lane high).
printf 'lane_tier: high\nwave_tier: medium\n' >> "$RC/global.yml"
out=$(rc "$RC/bare" "$RC/global.yml")
[ "$(echo "$out" | jq -r '.scalars.lane_tier.value')" = "high" ] \
    && [ "$(echo "$out" | jq -r '.scalars.wave_tier.value')" = "medium" ] \
    && [ "$(echo "$out" | jq -r '.scalars.lane_tier.source')" = "global" ] \
    && ok "resolve-config: wave/lane tiers surfaced with source" \
    || bad "resolve-config: spend-controlling scalars hidden from output"
[ "$(rc "$RC/bare" | jq -r '.scalars.lane_tier.value')" = "medium" ] \
    && ok "resolve-config: unset lane_tier uses the locked medium default" \
    || bad "resolve-config: lane_tier default is not medium"
# P31: rework_tier is spend-controlling too — it reprices every round-2+
# implementer — so it is surfaced with its layer like the rest.
printf 'rework_tier: high\n' >> "$RC/global.yml"
[ "$(rc "$RC/bare" "$RC/global.yml" | jq -r '.scalars.rework_tier | "\(.value)/\(.source)"')" = "high/global" ] \
    && ok "resolve-config: rework_tier surfaced with its source layer" \
    || bad "resolve-config: rework_tier hidden ($(rc "$RC/bare" "$RC/global.yml" | jq -c '.scalars.rework_tier'))"
sed -i.bak '/^rework_tier: high$/d' "$RC/global.yml"
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

# 8d³. P52: lane_turn_cap bounds EFFORT, unlike rejection_cap/crash_cap which
# bound failures — hidden here is a wave silently never noticing a runaway lane.
printf 'lane_turn_cap: 80\n' >> "$RC/global.yml"
[ "$(rc "$RC/bare" "$RC/global.yml" | jq -r '.scalars.lane_turn_cap | "\(.value)/\(.source)"')" = "80/global" ] \
    && ok "resolve-config: lane_turn_cap surfaced with its layer" \
    || bad "resolve-config: lane_turn_cap hidden ($(rc "$RC/bare" "$RC/global.yml" | jq -c '.scalars.lane_turn_cap'))"
sed -i.bak '/^lane_turn_cap: 80$/d' "$RC/global.yml"
[ "$(rc "$RC/bare" | jq -r '.scalars.lane_turn_cap | "\(.value)/\(.source)"')" = "150/default" ] \
    && ok "resolve-config: unset lane_turn_cap reports the real default (150)" \
    || bad "resolve-config: lane_turn_cap default disagrees with the code ($(rc "$RC/bare" | jq -c '.scalars.lane_turn_cap'))"

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
echo "$out" | jq -e '.guardrails.allow | index("Bash(CRUCIBLE_LIVE=1 uv *)")' >/dev/null \
    && ok "P4: env-prefixed gate command gets its own matching allow rule" \
    || bad "P4: env-prefixed command has no matching rule"
# Planted violation: the bare-command rule alone must NOT be what matches it.
if echo "$out" | jq -e '.guardrails.allow | index("Bash(uv *)") | not' >/dev/null; then
    ok "P4-violation: bare Bash(uv *) is absent, so only the prefixed rule can match"
else
    echo "P4: bare rule also present (harmless — the prefixed rule is what matters)"
fi

# 8g. Every generated allow rule traces to a command that will actually run.
missing=0
# read -r line, never `for c in $(...)`: an env-prefixed head like
# `CRUCIBLE_LIVE=1 uv` contains a space and word-splitting would tear it in two.
while IFS= read -r c; do
    [ -n "$c" ] || continue
    echo "$out" | jq -e --arg r "Bash($c *)" '.guardrails.allow | index($r)' >/dev/null || missing=1
done <<EOF
$(echo "$out" | jq -r '.gates | to_entries[] | .value[]' | sed 's/^\(\([A-Za-z_][A-Za-z0-9_]*=[^ ]* \)*[^ ]*\).*/\1/' | sort -u)
EOF
[ "$missing" -eq 0 ] \
    && ok "P4: every gate command has a generated rule — allowlist cannot drift" \
    || bad "P4: a gate command has no allow rule"

# 8h. Lane cwd is a spawn concern, not a permission concern: spawn-lane --cwd
#     starts the lane in its worktree, so the allowlist must NOT need `cd`.
#     A cd rule reappearing means the spawn fix was reverted (P4/P16).
echo "$out" | jq -e '.guardrails.allow | index("Bash(cd *)") | not' >/dev/null \
    && ok "P4/P16: no cd rule — lanes are spawned in their worktree instead" \
    || bad "P4/P16: cd rule is back; spawn-lane --cwd was bypassed"

# 8h2. The probe's live-stack commands stay allowed — the E4 probe needed these
#      and neither was in the hand-written allowlist (P16).
echo "$out" | jq -e '.guardrails.allow | index("Bash(curl *)") and index("Bash(sleep *)")' >/dev/null \
    && ok "P16: probe live-stack commands (curl, sleep) are allowed" \
    || bad "P16: probe cannot run its live stack"

# 8h3. Polling a background stack is the only shape a headless probe can use —
#      it receives no notifications. Without these it can neither read the
#      server's output nor stop it, and the lane outlives its own server (P16).
echo "$out" | jq -e '.guardrails.allow | index("BashOutput") and index("KillShell")' >/dev/null \
    && ok "P16: probe can poll and kill a background stack" \
    || bad "P16: probe cannot poll/stop a background stack"

# 8i. Machine state must not leak into a repo's allowlist: a worktree helper
#     is a declared repo fact, never a PATH probe.
echo "$out" | jq -e '[.guardrails.allow[] | select(startswith("Bash(openemr-cmd"))] | length == 0' >/dev/null \
    && ok "resolve-config: undeclared worktree helper stays out of the allowlist" \
    || bad "resolve-config: machine PATH leaked into the allowlist"
printf 'worktree_cmd: openemr-cmd\n' >> "$RC/uv/.loom.yml"
rc "$RC/uv" | jq -e '.guardrails.allow | index("Bash(openemr-cmd *)")' >/dev/null \
    && ok "resolve-config: declared worktree_cmd is allowlisted" || bad "resolve-config: declared worktree_cmd ignored"

# 8j. Guardrails are global and non-negotiable — a repo cannot derive them away.
rc "$RC/uv" | jq -e '.guardrails.deny | index("Bash(git push --force*)") and index("Bash(rm -rf *)")' >/dev/null \
    && ok "resolve-config: hard guardrails always present in deny" || bad "resolve-config: guardrails missing"

# 8k. The compatibility alias preserves unrelated user rules and is idempotent.
mkdir -p "$RC/uv/.claude"; printf '{"permissions":{"allow":["Bash(handwritten *)"],"deny":[]}}\n' > "$RC/uv/.claude/settings.json"
out=$(LOOM_REPO="$RC/uv" "$TICK" install-settings 2>&1); rc_code=$?
if [ "$rc_code" -eq 0 ] && grep -q 'handwritten' "$RC/uv/.claude/settings.json"; then
    ok "install-settings: preserves a hand-edited allow rule"
else
    bad "install-settings: lost a hand-edited file (rc=$rc_code)"
fi
cp "$RC/uv/.claude/settings.json" "$T/settings-before"
LOOM_REPO="$RC/uv" "$TICK" install-settings >/dev/null 2>&1
cmp -s "$T/settings-before" "$RC/uv/.claude/settings.json" \
    && ok "install-settings: idempotent on an unchanged repo" || bad "install-settings: changed on repeat"

test_finish
