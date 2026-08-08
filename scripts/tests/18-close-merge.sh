#!/usr/bin/env bash
# a ticket must never close over its own unmerged MR
#
# Section 18 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

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

test_finish
