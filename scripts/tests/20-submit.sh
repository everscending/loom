#!/usr/bin/env bash
# P63 submit: finishing is ONE verb
#
# Section 20 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- P63 submit: finishing is ONE verb ------------------------------------
# An impl lane finished with three writes in a row — push, open the MR, move
# the label — and a session death between any two of them stranded finished
# work where no scheduler step looks. ai-workout build-1 lost four tickets that
# way (#31 pushed MR !8 and died before the relabel), hours each.
SB="$T/submitverb"; mkdir -p "$SB"
git -c init.defaultBranch=main init -q --bare "$SB/origin.git"
git clone -q "$SB/origin.git" "$SB/repo" 2>/dev/null
git -C "$SB/repo" config user.email t@t; git -C "$SB/repo" config user.name t
echo base > "$SB/repo/f"; git -C "$SB/repo" add f
git -C "$SB/repo" commit -qm base; git -C "$SB/repo" push -q origin main
git -C "$SB/repo" checkout -qb ticket-41
echo work > "$SB/repo/g"; git -C "$SB/repo" add g; git -C "$SB/repo" commit -qm work
git -C "$SB/repo" push -q -u origin ticket-41
cat > "$SB/glab-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
for a in "$@"; do case "$a" in
  description=@*) cat "${a#description=@}" >> "${STUB_BODY:-/dev/null}" ;;
esac; done
case "$*" in
  *"POST projects/:fullpath/merge_requests"*)
      [ -n "${STUB_MR_FAIL:-}" ] && exit 1
      echo '{"iid":9}' ;;
  *"merge_requests?source_branch=ticket-41"*)
      if [ -n "${STUB_BRANCH_MR:-}" ]; then cat "$STUB_BRANCH_MR"; else echo '[]'; fi ;;
  *"PUT projects/:fullpath/merge_requests/8"*) echo '{"iid":8}' ;;
  *"closed_by"*)  cat "${STUB_CLOSEDBY:-/dev/null}" 2>/dev/null; echo ;;
  *"issues/44"*)  echo '{"state":"opened","title":"Already judged","labels":["build-2","merge-queue"]}' ;;
  *"issues/"*)    echo '{"state":"opened","title":"Add ledger table","labels":["build-2","in-progress"]}' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$SB/glab-stub.sh"
: > "$SB/calls"; : > "$SB/body"
( cd "$SB/repo" && GLAB_CMD="$SB/glab-stub.sh" STUB_LOG="$SB/calls" STUB_BODY="$SB/body" \
    "$LANE" submit 41 <<'EOB'
Implements the ledger table.
EOB
) >"$SB/o1" 2>&1; rc_s1=$?
if [ "$rc_s1" = 0 ] && grep -q 'source_branch=ticket-41' "$SB/calls" \
   && grep -q 'target_branch=main' "$SB/calls" \
   && grep -q 'add_labels=review' "$SB/calls" \
   && grep -q 'Closes #41' "$SB/body"; then
    ok "submit: one call opens the MR carrying 'Closes #41' AND moves the label to review"
else
    bad "submit: rc=$rc_s1, out=$(head -1 "$SB/o1"), calls=$(tr '\n' ';' < "$SB/calls")"
fi
# The write order is the whole point: MR first, label second, and NO label when
# the MR did not open. A `review` label with no MR queues a gate against
# nothing; an MR with no label is what the snapshot detector below repairs.
: > "$SB/calls2"
( cd "$SB/repo" && GLAB_CMD="$SB/glab-stub.sh" STUB_LOG="$SB/calls2" STUB_MR_FAIL=1 \
    "$LANE" submit 41 <<'EOB'
body
EOB
) >"$SB/o2" 2>&1; rc_s2=$?
if [ "$rc_s2" != 0 ] && grep -q 'opening the MR failed' "$SB/o2" \
   && ! grep -q 'add_labels' "$SB/calls2"; then
    ok "submit: a failed MR creation leaves the label exactly where it was"
else
    bad "submit: label moved over a failed MR (rc=$rc_s2, $(head -1 "$SB/o2"))"
fi
# An MR opened over an unpushed HEAD reviews work nobody can see. Shown BOTH
# ways: refused while the branch is local, accepted the moment it is pushed.
git -C "$SB/repo" checkout -q -b ticket-42
echo more > "$SB/repo/h"; git -C "$SB/repo" add h; git -C "$SB/repo" commit -qm work42
: > "$SB/calls3"
( cd "$SB/repo" && GLAB_CMD="$SB/glab-stub.sh" STUB_LOG="$SB/calls3" "$LANE" submit 42 <<'EOB'
body
EOB
) >"$SB/o3" 2>&1; rc_s3=$?
if [ "$rc_s3" != 0 ] && grep -q 'not on origin' "$SB/o3" \
   && ! grep -q 'merge_requests' "$SB/calls3" && ! grep -q 'add_labels' "$SB/calls3"; then
    ok "submit: refuses an unpushed branch, and writes nothing at all"
else
    bad "submit: unpushed branch rc=$rc_s3, out=$(head -1 "$SB/o3")"
fi
git -C "$SB/repo" push -q -u origin ticket-42
: > "$SB/calls4"
( cd "$SB/repo" && GLAB_CMD="$SB/glab-stub.sh" STUB_LOG="$SB/calls4" "$LANE" submit 42 <<'EOB'
body
EOB
) >"$SB/o4" 2>&1; rc_s4=$?
if [ "$rc_s4" = 0 ] && grep -q 'add_labels=review' "$SB/calls4"; then
    ok "submit: the same branch submits once it is pushed"
else
    bad "submit: guard fired on a pushed branch (rc=$rc_s4, $(head -1 "$SB/o4"))"
fi
# Re-running after a death completes the missing half instead of doubling the
# half that landed: MR !8 is already open, so only the label moves.
printf '[{"iid":8,"state":"opened"}]\n' > "$SB/closedby.json"
: > "$SB/calls5"
( cd "$SB/repo" && git checkout -q ticket-41 && GLAB_CMD="$SB/glab-stub.sh" \
    STUB_LOG="$SB/calls5" STUB_CLOSEDBY="$SB/closedby.json" "$LANE" submit 41 <<'EOB'
body
EOB
) >"$SB/o5" 2>&1; rc_s5=$?
if [ "$rc_s5" = 0 ] && grep -q 'already open' "$SB/o5" \
   && grep -q 'PUT projects/:fullpath/merge_requests/8' "$SB/calls5" \
   && ! grep -q 'POST projects/:fullpath/merge_requests' "$SB/calls5" \
   && grep -q 'add_labels=review' "$SB/calls5"; then
    ok "submit: re-run refreshes the existing MR safely — never a second MR"
else
    bad "submit: re-run mishandled (rc=$rc_s5, $(head -1 "$SB/o5"), $(tr '\n' ';' < "$SB/calls5"))"
fi
# D-TICK-41: an existing MR body can be refreshed after submit. If that edit
# drops Loom's marker, marker-only lookup sees no MR and the old verb opens a
# duplicate. The current branch is the second, forge-owned identity: recover
# its one open MR, rewrite the supplied final body with the marker appended,
# and only then move the ticket to Review.
printf '[{"iid":8,"title":"work","state":"opened","draft":false,"web_url":"u","source_branch":"ticket-41","sha":"abc","description":"Acceptance mapping without marker"}]\n' > "$SB/branch-mr.json"
printf 'Final acceptance mapping from the implementation worker.\n' > "$SB/final-body.md"
: > "$SB/calls7"; : > "$SB/body7"
( cd "$SB/repo" && git checkout -q ticket-41 && GLAB_CMD="$SB/glab-stub.sh" \
    STUB_LOG="$SB/calls7" STUB_BODY="$SB/body7" STUB_BRANCH_MR="$SB/branch-mr.json" \
    "$LANE" submit 41 --file "$SB/final-body.md"
) >"$SB/o7" 2>&1; rc_s7=$?
if [ "$rc_s7" = 0 ] \
   && grep -q 'PUT projects/:fullpath/merge_requests/8' "$SB/calls7" \
   && ! grep -q 'POST projects/:fullpath/merge_requests' "$SB/calls7" \
   && grep -q 'Final acceptance mapping' "$SB/body7" \
   && grep -q 'Closes #41' "$SB/body7" \
   && grep -q 'add_labels=review' "$SB/calls7"; then
    ok "D-TICK-41: submit repairs a markerless current-branch MR instead of opening a duplicate"
else
    bad "D-TICK-41: markerless MR was stranded or duplicated (rc=$rc_s7, $(tr '\n' ';' < "$SB/calls7"))"
fi
# A ticket the gate already passed must not be dragged back to review.
: > "$SB/calls6"
( cd "$SB/repo" && GLAB_CMD="$SB/glab-stub.sh" STUB_LOG="$SB/calls6" "$LANE" submit 44 <<'EOB'
body
EOB
) >"$SB/o6" 2>&1; rc_s6=$?
if [ "$rc_s6" != 0 ] && grep -q "already 'merge-queue'" "$SB/o6" \
   && ! grep -q 'add_labels' "$SB/calls6"; then
    ok "submit: refuses a ticket the gate already moved to merge-queue"
else
    bad "submit: dragged a judged ticket back (rc=$rc_s6, $(head -1 "$SB/o6"))"
fi

test_finish
