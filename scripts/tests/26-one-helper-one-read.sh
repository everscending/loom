#!/usr/bin/env bash
# P74: one helper per mechanism, one read per question
#
# Section 26 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- P74: one helper per mechanism, one read per question ------------------
# Four mechanisms were verbatim copies: three locks, two usage-pause blocks,
# four notify-once sentinels, seven fail-closed tracker reads. Sections 1, 4e,
# 10, 16a3 and 23 above own what each guard DOES and must stay green across the
# swap; this section owns the consolidation itself, and it is here because two
# of those copies had already drifted apart in the direction that costs money:
# the retry's usage-pause block went missing once (P14 reproduced in full), and
# `transition` and `submit` each fetched the SAME issue twice per call, because
# the hold guard and the verb that called it both asked for themselves.
P74="$T/p74"; mkdir -p "$P74"

# A tracker stub that COUNTS plain issue GETs. Writes and the `closed_by`
# endpoint are answered by earlier cases, so only the read under test lands in
# the counter.
cat > "$P74/glab.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"POST projects/:fullpath/merge_requests"*) echo '{"iid":4}' ;;
  *"--method PUT"*|*"--method POST"*) echo '{}' ;;
  *"closed_by"*) echo '[]' ;;
  *"issues/"*)
      echo x >> "${GETS:?}"
      echo '{"state":"opened","title":"Ledger table","labels":["build-9","in-progress"]}' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$P74/glab.sh"

# p74a. `transition` asks the tracker for the issue ONCE. It asks two questions
#       of it — is there a human hold (`_blocked_guard`), and is it closed — and
#       paid a round trip for each, on every state change of every ticket in
#       every lane.
: > "$P74/gets"; : > "$P74/calls"
GLAB_CMD="$P74/glab.sh" GETS="$P74/gets" STUB_LOG="$P74/calls" \
    "$LANE" transition 80 review >"$P74/out" 2>&1; p74_rc=$?
p74_n=$(wc -l < "$P74/gets" | tr -d ' ')
if [ "$p74_rc" = 0 ] && [ "$p74_n" = 1 ] && grep -q 'add_labels=review' "$P74/calls"; then
    ok "one read: transition answers both its questions from a single issue GET"
else
    bad "one read: transition rc=$p74_rc made $p74_n issue GET(s), expected 1"
fi

# p74b. Planted violation: the shared body removed, so every question fetches
#       for itself again — exactly today's code before this proposal, and more
#       than one GET for a single label move. The count is asserted as "more
#       than one", not as an exact number: how many questions `transition` asks
#       of the issue is a detail that moves (D-SNAP-17 added the release check
#       to the hold and closed questions already there), while "each question
#       pays its own round trip once the sharing is gone" is the invariant.
#       p74a above is what pins the real path to exactly one.
mkdir -p "$P74/twice"
ln -sf "$LIBSH" "$P74/twice/lib.sh"; ln -sf "$TICK" "$P74/twice/tick.sh"
link_trackers "$P74/twice"
sed 's|^    \[ "\$iid" = "\$_ISSUE_IID" \] && return 0$|    :|' "$LANE" > "$P74/twice/lane.sh"
chmod +x "$P74/twice/lane.sh"
: > "$P74/gets"
GLAB_CMD="$P74/glab.sh" GETS="$P74/gets" "$P74/twice/lane.sh" transition 81 review >/dev/null 2>&1
p74_n=$(wc -l < "$P74/gets" | tr -d ' ')
[ "$p74_n" -gt 1 ] 2>/dev/null \
    && ok "one read: with the shared body removed transition fetches the same issue again per question" \
    || bad "one read: the doubled read did not reproduce ($p74_n GETs, expected more than 1)"

# p74c. `submit` had the same doubled read — the hold guard, then its own
#       closed/label/title read of the very same issue. What it keeps is the
#       read AFTER its own write: opening the MR is a write, and the label move
#       past it asks the hold question again against the live tracker. So two
#       GETs, not three, and never one.
# A repo with an origin, a declared base that exists on it, and a branch this
# section can push. Section 25 builds the same one for the base rule, and this
# section used to inherit it.
LBU="$P74/submitbase"; mkdir -p "$LBU"
git -c init.defaultBranch=main init -q --bare "$LBU/origin.git"
git clone -q "$LBU/origin.git" "$LBU/repo" 2>/dev/null
git -C "$LBU/repo" config user.email t@t; git -C "$LBU/repo" config user.name t
echo base > "$LBU/repo/f"; git -C "$LBU/repo" add f
git -C "$LBU/repo" commit -qm base; git -C "$LBU/repo" push -q origin main
git -C "$LBU/repo" checkout -qb trunk; git -C "$LBU/repo" push -q origin trunk
git -C "$LBU/repo" checkout -q main
printf 'base: trunk\n' > "$LBU/repo/.loom.yml"
git -C "$LBU/repo" checkout -qb ticket-53 main
echo y > "$LBU/repo/i"; git -C "$LBU/repo" add i; git -C "$LBU/repo" commit -qm work53
git -C "$LBU/repo" push -q -u origin ticket-53
: > "$P74/gets"; : > "$P74/calls"
( cd "$LBU/repo" && GLAB_CMD="$P74/glab.sh" GETS="$P74/gets" STUB_LOG="$P74/calls" \
    "$LANE" submit 53 <<'EOB'
Implements the ledger table.
EOB
) >"$P74/out2" 2>&1; p74_rc=$?
p74_n=$(wc -l < "$P74/gets" | tr -d ' ')
if [ "$p74_rc" = 0 ] && [ "$p74_n" = 2 ]; then
    ok "one read: submit collapses its two pre-write reads into one, and re-reads after the MR opens"
else
    bad "one read: submit rc=$p74_rc made $p74_n issue GET(s), expected 2 ($(head -1 "$P74/out2"))"
fi

# p74d. The read is shared, never the FAILURE, and never across a write. This
#       is the whole risk of sharing one fetch: `merge` asks the hold question,
#       merges, then calls `close`, which asks it again. A hold placed while the
#       merge was landing must still bounce the close — the same stomp #29 paid
#       for (2026-08-02), just with a wider window. The stub answers "no hold"
#       first and "blocked" after, so only a genuinely fresh read can see it.
cat > "$P74/glab-hold.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"--method PUT"*"merge_requests/9/merge"*) : > "${MERGED:?}"; echo '{}' ;;
  *"merge_requests/9"*) echo '{"state":"merged"}' ;;
  *"issues/90/closed_by"*)
      if [ -f "${MERGED:?}" ]; then echo '[{"iid":9,"state":"merged"}]'
      else echo '[{"iid":9,"state":"opened"}]'; fi ;;
  *"state_event=close"*) echo '{}' ;;
  *"issues/90"*)
      echo x >> "${GETS:?}"
      if [ "$(wc -l < "${GETS:?}" | tr -d ' ')" -ge 2 ]
      then echo '{"state":"opened","labels":["build-9","blocked"]}'
      else echo '{"state":"opened","labels":["build-9","merge-queue"]}'; fi ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$P74/glab-hold.sh"
P74HOLD() { GLAB_CMD="$P74/glab-hold.sh" GETS="$P74/gets" STUB_LOG="$P74/calls" \
            MERGED="$P74/merged" "$@"; }
: > "$P74/gets"; : > "$P74/calls"; rm -f "$P74/merged"
P74HOLD "$LANE" merge 90 >"$P74/out3" 2>&1; p74_rc=$?
if [ "$p74_rc" != 0 ] && grep -q 'human hold' "$P74/out3" \
   && ! grep -q 'state_event=close' "$P74/calls"; then
    ok "one read: a hold that lands during the merge still bounces the close — the write forgets the body"
else
    bad "one read: merge->close rc=$p74_rc, close write present=$(grep -c 'state_event=close' "$P74/calls") ($(tail -1 "$P74/out3"))"
fi
# Planted violation: `_forget_issue` removed from `merge`, so `close` is
# answered by the photograph taken before the merge — and closes the ticket
# straight through the hold.
mkdir -p "$P74/stale"
ln -sf "$LIBSH" "$P74/stale/lib.sh"; ln -sf "$TICK" "$P74/stale/tick.sh"
link_trackers "$P74/stale"
sed '/^cmd_merge() {/,/^}/s/^    _forget_issue$/    :/' "$LANE" > "$P74/stale/lane.sh"
chmod +x "$P74/stale/lane.sh"
: > "$P74/gets"; : > "$P74/calls"; rm -f "$P74/merged"
P74HOLD "$P74/stale/lane.sh" merge 90 >/dev/null 2>&1
grep -q 'state_event=close' "$P74/calls" \
    && ok "one read: with the write not forgetting, close runs on the pre-merge read and stomps the hold" \
    || bad "one read: the stale-body violation did not reproduce"

# p74e. The usage pause on the RETRY path. 10e2 above asserts it fires; this
#       asserts it is the SAME mechanism as the first attempt (one helper,
#       parameterised) — the two firings are told apart only by the event's
#       `source` field and one clause of the message — and shows the build
#       losing its pause when that single call is removed. The copy that used
#       to carry this went missing once, and every tick after it burned a fresh
#       session against the same wall.
PU="$T/p74usage"; mkdir -p "$PU/repo" "$PU/home" "$PU/fx"
seed_tracker_decl "$PU/repo"
: > "$PU/g.yml"
printf 'ntfy:\n  topic: "p74-topic"\n  push: [usage_pause]\n' > "$PU/repo/.loom.yml"
make_wave_stub "$PU/fx/wave-stub"   # the shared wave stub, `crash_then_limit` mode
PUENV() { LOOM_REPO="$PU/repo" LOOM_HOME="$PU/home" LOOM_GLOBAL_CONFIG="$PU/g.yml" \
          NTFY_CMD=true WAVE_COUNT="$PU/count" WAVE_ARGV="$PU/argv" \
          LOOM_WAVE_CMD="$PU/fx/wave-stub wave" LOOM_RETRY_BACKOFF_SECONDS=0 \
          LOOM_SKIP_BOOTSTRAP=1 "$@"; }
PUFUT=$(( $(date +%s) + 3600 ))
echo 0 > "$PU/count"
WAVE_MODE=crash_then_limit WAVE_RESET="$PUFUT" PUENV "$TICK" tick >"$PU/out" 2>&1
if [ "$(cat "$PU/home/usage.pause" 2>/dev/null)" = "$PUFUT" ] \
   && grep -q 'usage limit hit on the retry' "$PU/out" \
   && jq -e 'select(.ev=="usage_pause" and .source=="retry")' "$PU/home/events.jsonl" >/dev/null 2>&1; then
    ok "usage: the retry's pause is the same helper, and names itself as the retry"
else
    bad "usage: retry pause=$(cat "$PU/home/usage.pause" 2>/dev/null), out=$(grep -c 'on the retry' "$PU/out")"
fi
# Planted violation: the retry's single call to the helper removed. The limit
# is met, nothing is written, and the tick exits as a crash.
mkdir -p "$PU/nopause"
for jf in snapshot.jq render.jq render-events.jq usage.jq report.jq report-ticket.jq retro.jq graph.jq lib.jq; do
    ln -sf "$(dirname "$TICK")/$jf" "$PU/nopause/$jf"
done
link_trackers "$PU/nopause"
ln -sf "$LIBSH" "$PU/nopause/lib.sh"; ln -sf "$LANE" "$PU/nopause/lane.sh"
sed 's|^    _pause_on_limit "\$stem-retry" retry && return 0$|    :|' "$TICK" > "$PU/nopause/tick.sh"
chmod +x "$PU/nopause/tick.sh"
rm -rf "$PU/home/tick.lock.d"; rm -f "$PU/home/usage.pause"; echo 0 > "$PU/count"
WAVE_MODE=crash_then_limit WAVE_RESET="$PUFUT" PUENV "$PU/nopause/tick.sh" tick >/dev/null 2>&1
pu_rc=$?
if [ ! -f "$PU/home/usage.pause" ] && [ "$pu_rc" != 0 ]; then
    ok "usage: with the retry's call removed the limit writes no pause and counts as a crash"
else
    bad "usage: the missing-retry-pause violation did not reproduce (rc=$pu_rc, pause=$(cat "$PU/home/usage.pause" 2>/dev/null))"
fi

# p74f. The lock shape, now written once, still refuses a second merge lane and
#       still breaks a dead owner's lock — sections 4e and 4e4 assert that for
#       the merge and gate locks through `spawn-lane`. What is new is that all
#       three locks share the code: remove the dead-owner break from the ONE
#       helper and the tick lock, the merge lock and the gate lock all wedge
#       together. Section 1c above shows the tick lock breaking a stale lock;
#       here is the same lock under a lib whose break has been removed.
mkdir -p "$P74/wedged"
for jf in snapshot.jq render.jq render-events.jq usage.jq report.jq report-ticket.jq retro.jq graph.jq lib.jq; do
    ln -sf "$(dirname "$TICK")/$jf" "$P74/wedged/$jf"
done
ln -sf "$LIBSH" "$P74/wedged/lib.sh"; ln -sf "$LANE" "$P74/wedged/lane.sh"
sed 's|^    rm -rf "\$dir"                         # owner dead: break the stale lock$|    return 1|' \
    "$TICK" > "$P74/wedged/tick.sh"
chmod +x "$P74/wedged/tick.sh"
PW="$T/p74lock"; mkdir -p "$PW/repo" "$PW/home/tick.lock.d"
seed_tracker_decl "$PW/repo"
echo 999999 > "$PW/home/tick.lock.d/pid"       # an owner that cannot be alive
pw_out=$(LOOM_REPO="$PW/repo" LOOM_HOME="$PW/home" LOOM_WAVE_CMD="echo revived" \
         LOOM_SKIP_BOOTSTRAP=1 "$P74/wedged/tick.sh" tick 2>&1)
case "$pw_out" in
  *"wave already running"*) ok "lock: with the break removed from the one helper, a dead owner wedges the tick" ;;
  *) bad "lock: the stale-break violation did not reproduce ($pw_out)" ;;
esac

# p74g. The notify-once core, likewise: the four sentinels are one function
#       now, so removing the "has it already been said" comparison must make
#       every one of them repeat. Section 15 asserts the quiet states dedupe;
#       this drives the same states through a tick.sh whose core always fires.
mkdir -p "$P74/loud"
for jf in snapshot.jq render.jq render-events.jq usage.jq report.jq report-ticket.jq retro.jq graph.jq lib.jq; do
    ln -sf "$(dirname "$TICK")/$jf" "$P74/loud/$jf"
done
ln -sf "$LIBSH" "$P74/loud/lib.sh"; ln -sf "$LANE" "$P74/loud/lane.sh"
sed 's|^    \[ "\$state" = "\$prev" \] && return 1$|    :|' "$TICK" > "$P74/loud/tick.sh"
chmod +x "$P74/loud/tick.sh"
PN="$T/p74notify"; mkdir -p "$PN/repo" "$PN/home"
seed_tracker_decl "$PN/repo"
PNCAP="$PN/ntfy"; PNSTUB="$PN/ntfy.sh"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$PNCAP" > "$PNSTUB"; chmod +x "$PNSTUB"
printf 'ntfy:\n  topic: "p74-quiet"\n  push: [workspace_untrusted]\n' > "$PN/repo/.loom.yml"
: > "$PN/g.yml"
PNRUN() { LOOM_REPO="$PN/repo" LOOM_HOME="$PN/home" LOOM_GLOBAL_CONFIG="$PN/g.yml" \
          NTFY_CMD="$PNSTUB" LOOM_SKIP_BOOTSTRAP=1 LOOM_WAVE_CMD=true "$@"; }
# Two spawns into the same untrusted workspace, twice over. Both runs start
# from no sentinel and are handed the identical state, so the ONLY difference
# is the code: the real tick.sh says it once, the mutant says it every time.
printf '{"projects":{}}\n' > "$PN/notrust.json"
: > "$PNCAP"; rm -f "$PN/home/trust.state"
for _ in 1 2; do
    rm -rf "$PN/home/tick.lock.d"
    LOOM_TRUST_FILE="$PN/notrust.json" PNRUN "$TICK" spawn-lane impl-91 --no-tick \
        --cwd "$PN/repo" -- true >/dev/null 2>&1
done
pn_one=$(grep -c 'X-Orch-Event: workspace_untrusted' "$PNCAP" 2>/dev/null || echo 0)
: > "$PNCAP"; rm -f "$PN/home/trust.state"
for _ in 1 2; do
    rm -rf "$PN/home/tick.lock.d"
    LOOM_TRUST_FILE="$PN/notrust.json" PNRUN "$P74/loud/tick.sh" spawn-lane impl-92 --no-tick \
        --cwd "$PN/repo" -- true >/dev/null 2>&1
done
pn_two=$(grep -c 'X-Orch-Event: workspace_untrusted' "$PNCAP" 2>/dev/null || echo 0)
if [ "$pn_one" = 1 ] && [ "$pn_two" = 2 ]; then
    ok "notify-once: one push per state change, and with the comparison removed every tick pushes again"
else
    bad "notify-once: real tick pushed $pn_one (want 1), mutant pushed $pn_two (want 2)"
fi

test_finish
