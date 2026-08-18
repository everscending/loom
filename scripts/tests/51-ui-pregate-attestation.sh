#!/usr/bin/env bash
# Exact-SHA UI pregate evidence is reusable only after an independent PASS.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# A committed UI repository with a local origin. The gate runner's count is
# the user-visible cost: gate + merge is two browser runs without reuse and
# one browser run with a valid attestation.
mkdir -p "$LOOM_REPO/scripts"
UI_RUNS="$T/ui-runs"
cat > "$LOOM_REPO/scripts/gate.sh" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = ui ] || exit 31
n=\$(cat "$UI_RUNS" 2>/dev/null || echo 0)
echo \$((n + 1)) > "$UI_RUNS"
[ ! -f RED ] || exit 32
exit 0
EOF
chmod +x "$LOOM_REPO/scripts/gate.sh"
cat > "$LOOM_REPO/.loom.yml" <<'EOF'
base: main
runner: scripts/gate.sh
gates:
  ui:
    - "npx playwright test --project=product"
EOF
git -C "$LOOM_REPO" add .
git -C "$LOOM_REPO" commit -qm 'ui fixture'
git -C "$LOOM_REPO" branch -M main
git init -q --bare "$T/origin.git"
git -C "$LOOM_REPO" remote add origin "$T/origin.git"
git -C "$LOOM_REPO" push -q -u origin main
WT="$T/repo-wt-294"
git -C "$LOOM_REPO" worktree add -q "$WT" -b ticket-294
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)

# The public verdict verb writes through a tracker driver. This fixture keeps
# the issue in Review until relabel and records the writes, while all
# attestation behavior remains behind the real lane/tick interfaces.
TRACKER_STUB="$T/tracker-attestation.sh"
TRACKER_CALLS="$T/tracker-attestation.calls"
cat > "$TRACKER_STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TRACKER_CALLS"
case "$1" in
  issue) printf '{"id":%s,"state":"open","labels":["build-1","review"],"body":""}\n' "$2" ;;
  issue-notes) echo '[]' ;;
  issue-note|issue-relabel) exit 0 ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$TRACKER_STUB"
export TRACKER_CMD="$TRACKER_STUB" TRACKER_CALLS

LANE="$({ cd "$(dirname "$TICK")" && pwd; })/lane.sh"
VERDICT_BODY="$T/verdict.md"
printf 'Independent review passed.\n' > "$VERDICT_BODY"

rm -f "$UI_RUNS"
"$TICK" spawn-lane gate-294 --no-tick --pregate ui --cwd "$WT" -- \
  "$LANE" verdict 294 pass "$HEAD_SHA" --file "$VERDICT_BODY" >/dev/null
for _wait in $(seq 1 100); do
  [ -f "$LOOM_HOME/lanes/gate-294.rc" ] && break
  sleep 0.02
done

MERGE_PROVIDER="$T/merge-provider-ran"
"$TICK" spawn-lane merge-294 --no-tick --pregate ui --merge-lock \
  --cwd "$WT" -- touch "$MERGE_PROVIDER" >/dev/null
for _wait in $(seq 1 100); do
  [ -f "$LOOM_HOME/lanes/merge-294.rc" ] && break
  sleep 0.02
done

if [ "$(cat "$UI_RUNS" 2>/dev/null)" = 1 ] \
   && [ -f "$MERGE_PROVIDER" ] \
   && grep -q '"ev":"ui_pregate_reused"' "$LOOM_HOME/events.jsonl" 2>/dev/null; then
  ok "ui attestation: an independently approved exact UI pregate is reused at merge"
else
  bad "ui attestation: gate+merge ran $(cat "$UI_RUNS" 2>/dev/null || echo 0) UI suites or emitted no reuse event ($(find "$LOOM_HOME/ui-pregate-attestations" -type f -maxdepth 3 -print 2>/dev/null | tr '\n' ' '); $(tail -8 "$LOOM_HOME/events.jsonl" 2>/dev/null | tr '\n' '|'))"
fi

APPROVED="$LOOM_HOME/ui-pregate-attestations/approved/294.json"
BASE_APPROVED="$T/approved-base.json"
cp "$APPROVED" "$BASE_APPROVED"
if jq -e '.schema == 1 and .verdict == "PASS" and .tier == "ui"' "$APPROVED" >/dev/null 2>&1 \
   && [ "$(stat -f '%Lp' "$APPROVED" 2>/dev/null || stat -c '%a' "$APPROVED")" = 600 ]; then
  ok "ui attestation: promoted evidence is private, structured, and explicitly UI-only"
else
  bad "ui attestation: promoted evidence is not a private schema-1 UI PASS"
fi

# Missing evidence is a cache miss, never a weaker merge. The normal UI gate
# still owns the decision and the provider starts only after it passes.
rm -f "$APPROVED"
before=$(cat "$UI_RUNS")
MISS_PROVIDER="$T/missing-evidence-provider"
"$TICK" spawn-lane merge-294-missing --no-tick --pregate ui --merge-lock \
  --cwd "$WT" -- touch "$MISS_PROVIDER" >/dev/null
for _wait in $(seq 1 100); do
  [ -f "$LOOM_HOME/lanes/merge-294-missing.rc" ] && break
  sleep 0.02
done
after=$(cat "$UI_RUNS")
if [ "$after" -eq "$((before + 1))" ] && [ -f "$MISS_PROVIDER" ]; then
  ok "ui attestation: missing evidence runs the normal UI merge gate"
else
  bad "ui attestation: missing evidence skipped or blocked the normal UI merge gate"
fi
cp "$BASE_APPROVED" "$APPROVED"

seal_approved() {
  local unsigned="$T/unsigned.json" seal
  jq -cS 'del(.seal_sha256)' "$APPROVED" > "$unsigned"
  if command -v shasum >/dev/null 2>&1; then
    seal=$(shasum -a 256 "$unsigned" | awk '{print $1}')
  else
    seal=$(sha256sum "$unsigned" | awk '{print $1}')
  fi
  jq -c --arg seal "$seal" '. + {seal_sha256:$seal}' "$unsigned" > "$APPROVED.tmp"
  mv "$APPROVED.tmp" "$APPROVED"
  chmod 600 "$APPROVED"
}

case_n=0
run_fallback_case() { # <label>
  local label="$1" before after lane provider
  case_n=$((case_n + 1))
  lane="merge-294-drift$case_n"
  provider="$T/provider-drift$case_n"
  before=$(cat "$UI_RUNS")
  "$TICK" spawn-lane "$lane" --no-tick --pregate ui --merge-lock \
    --cwd "$WT" -- touch "$provider" >/dev/null
  for _wait in $(seq 1 100); do
    [ -f "$LOOM_HOME/lanes/$lane.rc" ] && break
    sleep 0.02
  done
  after=$(cat "$UI_RUNS")
  if [ "$after" -eq "$((before + 1))" ] && [ -f "$provider" ]; then
    ok "ui attestation: $label runs the normal UI merge gate"
  else
    bad "ui attestation: $label reused unsafe evidence or suppressed the normal UI gate"
  fi
  cp "$BASE_APPROVED" "$APPROVED"
}

# Every declared binding is independently enforced even when the document has
# a valid seal. Re-sealing here models a well-formed attestation from a
# different context; the public merge seam must still reject it.
jq '.ticket=999 | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "ticket drift"
jq '.head="0000000000000000000000000000000000000000" | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "HEAD drift"
jq '.base_ref="origin/develop" | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "base-ref drift"
jq '.base_sha="1111111111111111111111111111111111111111" | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "base-SHA drift"
jq '.tier="api" | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "tier drift"
jq '.runner_path="scripts/other-gate.sh" | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "runner-path drift"
jq '.runner_sha256="2222222222222222222222222222222222222222222222222222222222222222" | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "runner-content drift"
jq '.config_sha256="3333333333333333333333333333333333333333333333333333333333333333" | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "repository-config drift"
jq '.ui_manifest_sha256="4444444444444444444444444444444444444444444444444444444444444444" | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "normalized UI test-manifest drift"
jq '.host="5555555555555555555555555555555555555555555555555555555555555555" | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "host drift"

# Document integrity, freshness, and review status fail closed too.
printf '{malformed\n' > "$APPROVED"
run_fallback_case "malformed evidence"
jq '.head="tampered"' "$BASE_APPROVED" > "$APPROVED"
run_fallback_case "tampered evidence"
jq '.issued_at=1 | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "expired evidence"
jq '.verdict="FAIL" | del(.seal_sha256)' "$BASE_APPROVED" > "$APPROVED"; seal_approved
run_fallback_case "changed reviewer verdict"

touch "$WT/untracked-review-artifact"
run_fallback_case "a dirty reconciled worktree"
rm -f "$WT/untracked-review-artifact"
if grep -q '"ev":"ui_pregate_reuse_miss".*"reason":"host-drift"' "$LOOM_HOME/events.jsonl" \
   && grep -q '"ev":"ui_pregate_reuse_miss".*"reason":"expired"' "$LOOM_HOME/events.jsonl" \
   && grep -q '"ev":"ui_pregate_reuse_miss".*"reason":"missing-or-tampered"' "$LOOM_HOME/events.jsonl"; then
  ok "ui attestation: reuse and fail-closed misses emit auditable reasons"
else
  bad "ui attestation: reuse misses did not preserve their invalidation reason"
fi

# Candidate lifecycle: a runner PASS is necessary but not sufficient. A gate
# that exits without a tracker verdict cannot leave merge-eligible evidence.
"$TICK" spawn-lane gate-295 --no-tick --pregate ui --cwd "$WT" -- true >/dev/null
for _wait in $(seq 1 100); do
  [ -f "$LOOM_HOME/lanes/gate-295.rc" ] && break
  sleep 0.02
done
for _wait in $(seq 1 100); do
  [ ! -e "$LOOM_HOME/ui-pregate-attestations/candidates/gate-295.json" ] && break
  sleep 0.02
done
if [ ! -e "$LOOM_HOME/ui-pregate-attestations/approved/295.json" ] \
   && [ ! -e "$LOOM_HOME/ui-pregate-attestations/candidates/gate-295.json" ]; then
  ok "ui attestation: a runner PASS without a reviewer verdict is not promoted"
else
  bad "ui attestation: verdictless gate evidence became merge-eligible"
fi

# A red runner never reaches the reviewer and never writes a candidate.
touch "$WT/RED"
RED_PROVIDER="$T/red-gate-provider"
"$TICK" spawn-lane gate-296 --no-tick --pregate ui --cwd "$WT" -- touch "$RED_PROVIDER" >/dev/null
for _wait in $(seq 1 100); do
  [ -f "$LOOM_HOME/lanes/gate-296.rc" ] && break
  sleep 0.02
done
if [ "$(cat "$LOOM_HOME/lanes/gate-296.rc" 2>/dev/null)" = 7 ] \
   && [ ! -f "$RED_PROVIDER" ] \
   && [ ! -e "$LOOM_HOME/ui-pregate-attestations/candidates/gate-296.json" ]; then
  ok "ui attestation: a failed UI runner never attests"
else
  bad "ui attestation: a failed UI runner reached review or left evidence"
fi
rm -f "$WT/RED"

# Bootstrap's missing-runner reduction is intentionally review-only. Even a
# later prose PASS cannot turn a suite that never ran into reusable evidence.
mv "$WT/scripts/gate.sh" "$WT/scripts/gate.sh.saved"
"$TICK" spawn-lane gate-297 --no-tick --pregate ui --cwd "$WT" -- \
  "$LANE" verdict 297 pass "$HEAD_SHA" --file "$VERDICT_BODY" >/dev/null
for _wait in $(seq 1 100); do
  [ -f "$LOOM_HOME/lanes/gate-297.rc" ] && break
  sleep 0.02
done
if [ ! -e "$LOOM_HOME/ui-pregate-attestations/approved/297.json" ] \
   && grep -q '"ev":"pregate_reduced".*"id":"gate-297"' "$LOOM_HOME/events.jsonl"; then
  ok "ui attestation: a missing-runner reduction never attests"
else
  bad "ui attestation: review-only reduced evidence became reusable"
fi
mv "$WT/scripts/gate.sh.saved" "$WT/scripts/gate.sh"

# A real PASS promotes; a later real FAIL for the same ticket invalidates it.
"$TICK" spawn-lane gate-298 --no-tick --pregate ui --cwd "$WT" -- \
  "$LANE" verdict 298 pass "$HEAD_SHA" --file "$VERDICT_BODY" >/dev/null
for _wait in $(seq 1 100); do
  [ -f "$LOOM_HOME/lanes/gate-298.rc" ] && break
  sleep 0.02
done
LOOM_LANE_ID=gate-298 "$LANE" verdict 298 fail "$HEAD_SHA" \
  --class reviewer-changed --file "$VERDICT_BODY" >/dev/null
if [ ! -e "$LOOM_HOME/ui-pregate-attestations/approved/298.json" ] \
   && grep -q '"ev":"ui_pregate_attestation_invalidated".*"ticket":298' "$LOOM_HOME/events.jsonl"; then
  ok "ui attestation: a changed reviewer verdict invalidates approved evidence"
else
  bad "ui attestation: approved evidence survived a reviewer FAIL"
fi

# Planted verifier mutation: remove only the same-host comparison while
# keeping the attestation sealed and every other binding exact. The mutated
# public merge must now reuse foreign-host evidence and skip the UI runner,
# proving the host-drift assertion above is sensitive to the shipped guard.
cp "$BASE_APPROVED" "$APPROVED"
jq '.host="6666666666666666666666666666666666666666666666666666666666666666" | del(.seal_sha256)' \
  "$BASE_APPROVED" > "$APPROVED"
seal_approved
MUT=$(mirror_scripts "$T/ui-attestation-mutant")
sed 's/"ui_manifest_sha256","host"/"ui_manifest_sha256"/' "$MUT/tick.sh" > "$MUT/tick-mutant.sh"
mv "$MUT/tick-mutant.sh" "$MUT/tick.sh"
chmod +x "$MUT/tick.sh"
if ! grep -q '"ui_manifest_sha256","host"' "$MUT/tick.sh" \
   && grep -q '"ui_manifest_sha256"' "$MUT/tick.sh"; then
  before=$(cat "$UI_RUNS")
  MUT_PROVIDER="$T/mutant-provider"
  "$MUT/tick.sh" spawn-lane merge-294-mutant --no-tick --pregate ui --merge-lock \
    --cwd "$WT" -- touch "$MUT_PROVIDER" >/dev/null
  for _wait in $(seq 1 100); do
    [ -f "$LOOM_HOME/lanes/merge-294-mutant.rc" ] && break
    sleep 0.02
  done
  after=$(cat "$UI_RUNS")
  if [ "$after" -eq "$before" ] && [ -f "$MUT_PROVIDER" ]; then
    ok "ui-attestation-violation: removing the host binding reuses foreign-host evidence"
  else
    bad "ui-attestation-violation: planted host-binding removal did not recreate unsafe reuse"
  fi
else
  bad "ui-attestation-violation: mutation did not match both verifier comparisons"
fi

# Reconciliation always happens first. Moving origin/main after review changes
# both the base binding and the reconciled HEAD, so merge must run UI again.
cp "$BASE_APPROVED" "$APPROVED"
printf 'arrived from base\n' > "$LOOM_REPO/base-after-attestation.txt"
git -C "$LOOM_REPO" add base-after-attestation.txt
git -C "$LOOM_REPO" commit -qm 'advance base after UI review'
git -C "$LOOM_REPO" push -q origin main
before=$(cat "$UI_RUNS")
BASE_PROVIDER="$T/base-drift-provider"
"$TICK" spawn-lane merge-294-base-moved --no-tick --pregate ui --merge-lock \
  --cwd "$WT" -- touch "$BASE_PROVIDER" >/dev/null
for _wait in $(seq 1 100); do
  [ -f "$LOOM_HOME/lanes/merge-294-base-moved.rc" ] && break
  sleep 0.02
done
after=$(cat "$UI_RUNS")
if [ -f "$WT/base-after-attestation.txt" ] \
   && [ "$after" -eq "$((before + 1))" ] && [ -f "$BASE_PROVIDER" ]; then
  ok "ui attestation: merge reconciles before reuse validation and reruns UI on base drift"
else
  bad "ui attestation: merge reused pre-reconcile evidence after the base moved"
fi

rendered=$(NO_COLOR=1 "$TICK" render-events 2>/dev/null)
if printf '%s' "$rendered" | grep -q '#294 — merge: exact-SHA UI gate evidence reused after reconcile'; then
  ok "ui attestation: the build ticker exposes successful UI evidence reuse"
else
  bad "ui attestation: successful reuse is absent from the build ticker"
fi

sleep 0.2

test_finish
