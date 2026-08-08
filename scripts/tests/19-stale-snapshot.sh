#!/usr/bin/env bash
# a merged ticket must not be failed or relabelled; fail-closed guards
#
# Section 19 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- the stale-snapshot race: a merged ticket must not be failed or relabelled
# #23 merged at 22:23:17 and was blocked at 22:24:29. A gate lane had chained
# straight into its merge lane; a wave started 90s BEFORE the merge landed,
# then harvested against that photograph, saw no live merge lane, and applied
# "still merge-queue means it never merged". The wave did not perform the
# merge, so nothing prompted it to re-read. Both verbs now refuse.
SR="$T/stalerace"; mkdir -p "$SR"
cat > "$SR/glab-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  # 51 = merged underneath the caller; 52 = genuinely still open
  *"issues/51/closed_by"*) echo '[{"iid":7,"state":"merged"}]' ;;
  *"issues/52/closed_by"*) echo '[{"iid":8,"state":"opened"}]' ;;
  *"issues/51"*)           echo '{"state":"closed","labels":[]}' ;;
  *"issues/52"*)           echo '{"state":"opened","labels":[]}' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$SR/glab-stub.sh"
echo body > "$SR/report.md"
GLAB_CMD="$SR/glab-stub.sh" STUB_LOG="$SR/c1" "$LANE" merge-failed 51 --file "$SR/report.md" \
    >"$SR/o1" 2>&1; rc_mf=$?
if [ "$rc_mf" != 0 ] && grep -q 'already has MERGED MR !7' "$SR/o1" \
   && ! grep -q '/notes' "$SR/c1"; then
    ok "merge-failed: refuses to record a failure for an already-merged ticket"
else
    bad "merge-failed: rc=$rc_mf, out=$(head -1 "$SR/o1")"
fi
# The cap counts real failures, so the guard must not swallow genuine ones.
GLAB_CMD="$SR/glab-stub.sh" STUB_LOG="$SR/c2" "$LANE" merge-failed 52 --file "$SR/report.md" \
    >"$SR/o2" 2>&1; rc_mf2=$?
if [ "$rc_mf2" = 0 ] && grep -q '/notes' "$SR/c2"; then
    ok "merge-failed: still records a genuine failure while the MR is open"
else
    bad "merge-failed: guard swallowed a real attempt (rc=$rc_mf2)"
fi
# Blocking a CLOSED ticket, and the later "requeue" of one, are the same lie.
GLAB_CMD="$SR/glab-stub.sh" STUB_LOG="$SR/c3" "$LANE" transition 51 blocked \
    >"$SR/o3" 2>&1; rc_tr=$?
if [ "$rc_tr" != 0 ] && grep -q 'is CLOSED' "$SR/o3" \
   && ! grep -q 'add_labels' "$SR/c3"; then
    ok "transition: refuses to label a closed ticket, and writes nothing"
else
    bad "transition: rc=$rc_tr, out=$(head -1 "$SR/o3")"
fi
GLAB_CMD="$SR/glab-stub.sh" STUB_LOG="$SR/c4" "$LANE" transition 51 ready-for-agent \
    >"$SR/o4" 2>&1; rc_tr2=$?
if [ "$rc_tr2" != 0 ] && ! grep -q 'add_labels' "$SR/c4"; then
    ok "transition: a closed ticket cannot be requeued as available work"
else
    bad "transition: requeued a closed ticket (rc=$rc_tr2)"
fi
GLAB_CMD="$SR/glab-stub.sh" STUB_LOG="$SR/c5" "$LANE" transition 52 merge-queue \
    >"$SR/o5" 2>&1; rc_tr3=$?
if [ "$rc_tr3" = 0 ] && grep -q 'add_labels=merge-queue' "$SR/c5"; then
    ok "transition: an open ticket still advances normally"
else
    bad "transition: guard broke the normal path (rc=$rc_tr3)"
fi

# 22. Hard cut from the pre-rename config name. A repo carrying only
#     `.orchestrator.yml` must STOP, naming the rename — never fall through to
#     derived + global defaults, which would silently ignore every setting the
#     human wrote. Shown failing too: add `.loom.yml` and the same repo runs.
HC="$T/hardcut"; mkdir -p "$HC/repo" "$HC/home"
printf 'max_lanes: 2\n' > "$HC/repo/.orchestrator.yml"
LOOM_REPO="$HC/repo" LOOM_HOME="$HC/home" "$TICK" tick >"$HC/out" 2>&1; rc_hc=$?
if [ "$rc_hc" != 0 ] && grep -q 'old config name' "$HC/out" \
   && grep -q 'mv .orchestrator.yml .loom.yml' "$HC/out"; then
    ok "hard cut: a repo on the old config name stops and names the rename"
else
    bad "hard cut: old-name repo did not stop with the rename message (rc=$rc_hc)"
fi
# Planted violation: with the new name present the guard must NOT fire.
printf 'max_lanes: 2\n' > "$HC/repo/.loom.yml"
LOOM_REPO="$HC/repo" LOOM_HOME="$HC/home" "$TICK" tick >"$HC/out2" 2>&1
if grep -q 'old config name' "$HC/out2"; then
    bad "hard cut: guard fired even though .loom.yml exists"
else
    ok "hard cut: a repo carrying both names runs on the new one"
fi

# 23. Guards fail closed (P47): every guard read in lane.sh used to be
#     `… 2>/dev/null … || true`, so an API failure could not be told apart
#     from "read succeeded and says no" — the guard just passed. Demonstrated:
#     with the closed_by read failing, `lane.sh close 70` closed the ticket
#     having checked no MR; with the issue read failing, a lane transitioned a
#     ticket carrying a human `blocked` hold. Each case below fails the ONE
#     read the guard depends on and asserts both a `die` and that nothing was
#     written — a refused write costs one wave, a write made blind costs the
#     thing it was guarding.
GF="$T/guardsfail"; mkdir -p "$GF"

# (a) _blocked_guard's own read, exercised through `close` (which calls it
#     before its closed_by check): the issue-state read fails outright.
cat > "$GF/fail-issue-70.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"issues/70/closed_by"*) echo '[]' ;;
  *"issues/70"*) exit 1 ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$GF/fail-issue-70.sh"
GLAB_CMD="$GF/fail-issue-70.sh" STUB_LOG="$GF/ca" "$LANE" close 70 >"$GF/oa" 2>&1; rc_a=$?
if [ "$rc_a" != 0 ] && grep -q 'could not read issue state' "$GF/oa" \
   && ! grep -q 'closed_by' "$GF/ca" && ! grep -q 'state_event=close' "$GF/ca"; then
    ok "guards fail closed: _blocked_guard dies on a failed issue read, writes nothing"
else
    bad "guards fail closed: close/_blocked_guard rc=$rc_a, out=$(head -1 "$GF/oa")"
fi

# (b) cmd_transition's own closed-ticket read fails outright.
cat > "$GF/fail-issue-71.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"issues/71"*) exit 1 ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$GF/fail-issue-71.sh"
GLAB_CMD="$GF/fail-issue-71.sh" STUB_LOG="$GF/cb" "$LANE" transition 71 review >"$GF/ob" 2>&1; rc_b=$?
if [ "$rc_b" != 0 ] && grep -q 'could not read issue state' "$GF/ob" \
   && ! grep -q 'add_labels' "$GF/cb"; then
    ok "guards fail closed: transition dies on a failed issue read, writes nothing"
else
    bad "guards fail closed: transition rc=$rc_b, out=$(head -1 "$GF/ob")"
fi

# (c) cmd_close's own closed_by read fails outright (issue-state read, i.e.
#     _blocked_guard, still succeeds — isolates the second guard).
cat > "$GF/fail-closedby-72.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"issues/72/closed_by"*) exit 1 ;;
  *"issues/72"*) echo '{"state":"opened","labels":[]}' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$GF/fail-closedby-72.sh"
GLAB_CMD="$GF/fail-closedby-72.sh" STUB_LOG="$GF/cc" "$LANE" close 72 >"$GF/oc" 2>&1; rc_c=$?
if [ "$rc_c" != 0 ] && grep -q 'could not read closed_by' "$GF/oc" \
   && ! grep -q 'state_event=close' "$GF/cc"; then
    ok "guards fail closed: close dies on a failed closed_by read, writes nothing"
else
    bad "guards fail closed: close/closed_by rc=$rc_c, out=$(head -1 "$GF/oc")"
fi

# (d) cmd_merge_failed's own closed_by read fails outright.
cat > "$GF/fail-closedby-73.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"issues/73/closed_by"*) exit 1 ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$GF/fail-closedby-73.sh"
echo body > "$GF/report.md"
GLAB_CMD="$GF/fail-closedby-73.sh" STUB_LOG="$GF/cd" "$LANE" merge-failed 73 --file "$GF/report.md" \
    >"$GF/od" 2>&1; rc_d=$?
if [ "$rc_d" != 0 ] && grep -q 'could not read closed_by' "$GF/od" \
   && ! grep -q '/notes' "$GF/cd"; then
    ok "guards fail closed: merge-failed dies on a failed closed_by read, writes nothing"
else
    bad "guards fail closed: merge-failed rc=$rc_d, out=$(head -1 "$GF/od")"
fi

# (e) cmd_sweep's `git log origin/$base..$branch` range: an unresolvable base
#     ref (unfetched or missing) used to read as "no commits ahead" and arm
#     the delete path. Give it a base that has no origin ref at all.
SWF="$T/sweepfail"; mkdir -p "$SWF"
git -c init.defaultBranch=main init -q --bare "$SWF/origin.git"
git clone -q "$SWF/origin.git" "$SWF/repo" 2>/dev/null
git -C "$SWF/repo" config user.email t@t; git -C "$SWF/repo" config user.name t
echo base > "$SWF/repo/f"; git -C "$SWF/repo" add f
git -C "$SWF/repo" commit -qm base; git -C "$SWF/repo" push -q origin main
git -C "$SWF/repo" checkout -qb ticket-work
echo more > "$SWF/repo/g"; git -C "$SWF/repo" add g; git -C "$SWF/repo" commit -qm work
git -C "$SWF/repo" checkout -q main
git -C "$SWF/repo" worktree add -q "$SWF/repo-wt-9" ticket-work 2>/dev/null
printf 'base: doesnotexist\n' > "$SWF/repo/.loom.yml"
LOOM_REPO="$SWF/repo" LOOM_HOME="$SWF/home" "$TICK" sweep >"$SWF/out" 2>&1
if [ -e "$SWF/repo-wt-9" ] && grep -q 'cannot resolve' "$SWF/out"; then
    ok "guards fail closed: sweep refuses an unresolved base ref, never reads it as merged"
else
    bad "guards fail closed: sweep worktree present=$([ -e "$SWF/repo-wt-9" ] && echo yes || echo no) ($(head -1 "$SWF/out"))"
fi

test_finish
