#!/usr/bin/env bash
# A human-supervised repair owns a ticket independently of tracker prose. The
# scheduler must see that ownership, and spawn-lane must enforce it again at
# the final mutation boundary so stale plans and queued launches cannot race it.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

FX="$T/lease"; mkdir -p "$FX"
make_glab_fixture "$FX"

out=$("$TICK" supervise acquire 10 --owner root/repair-286 --ttl-seconds 3600 2>&1); rc=$?
lease="$LOOM_HOME/supervised-leases/10.json"
if [ "$rc" -eq 0 ] && jq -e '.schema == 1 and .ticket == 10
    and .owner == "root/repair-286" and .expires_at > .acquired_at' "$lease" >/dev/null 2>&1; then
    ok "supervised lease: human acquires bounded machine-readable ownership"
else
    bad "supervised lease: acquire failed or wrote an invalid lease (rc=$rc; out=$out)"
fi

out=$(LOOM_LANE_ID=impl-99 "$TICK" supervise acquire 11 --owner nested-agent --ttl-seconds 60 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$LOOM_HOME/supervised-leases/11.json" ]; then
    ok "supervised lease: an ordinary lane cannot self-exempt from scheduling"
else
    bad "supervised lease: automated lane acquired a supervisor lease (rc=$rc; out=$out)"
fi

GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$FX/calls" "$TICK" snapshot > "$FX/snapshot.json" 2>"$FX/snapshot.err"
if jq -e '.supervised_leases == [.tickets[] | select(.id == 10) | .supervised_lease]
          and .supervised_leases[0].owner == "root/repair-286"' "$FX/snapshot.json" >/dev/null; then
    ok "supervised lease: snapshot joins host ownership to its ticket"
else
    bad "supervised lease: snapshot omitted the active lease ($(cat "$FX/snapshot.err"))"
fi

"$TICK" plan "$FX/snapshot.json" > "$FX/plan.json"
if ! jq -e '.actions[] | select(.ticket == 10)' "$FX/plan.json" >/dev/null \
   && jq -e '.deferred[] | select(.ticket == 10 and (.why | contains("root/repair-286")))' "$FX/plan.json" >/dev/null; then
    ok "supervised lease: planner defers the leased implementation visibly"
else
    bad "supervised lease: planner scheduled or silently dropped leased ticket #10"
fi

mark="$FX/launched"
out=$("$TICK" spawn-lane impl-10 --no-tick -- sh -c "touch '$mark'" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$mark" ] && printf '%s' "$out" | grep -qi 'supervised'; then
    ok "supervised lease: launch boundary refuses a stale ordinary spawn"
else
    bad "supervised lease: leased implementation launched (rc=$rc; out=$out)"
fi

# No sleep: a past deadline proves stale leases fail open by their own bounded
# machine timestamp and do not require a cleanup mutation to restore progress.
jq '.expires_at = 1' "$lease" > "$lease.tmp" && mv "$lease.tmp" "$lease"
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$FX/calls-expired" "$TICK" snapshot > "$FX/expired.json" 2>/dev/null
"$TICK" plan "$FX/expired.json" > "$FX/expired-plan.json"
if jq -e '.supervised_leases == []
          and any(.actions[]; .lane == "impl-10")' "$FX/expired-plan.json" >/dev/null; then
    ok "supervised lease: expiry automatically returns the ticket to scheduling"
else
    bad "supervised lease: expired ownership still wedges ticket #10"
fi

"$TICK" supervise acquire 10 --owner root/repair-286 --ttl-seconds 60 >/dev/null 2>&1
"$TICK" supervise release 10 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$lease" ]; then
    ok "supervised lease: explicit release removes ownership"
else
    bad "supervised lease: release did not remove ownership (rc=$rc)"
fi

# Gate dispatch uses the same provider-neutral admission seam as implementation
# dispatch, including planner visibility and the final stale-plan guard.
"$TICK" supervise acquire 12 --owner root/review-286 --ttl-seconds 60 >/dev/null
GLAB_CMD="$FX/glab-stub.sh" STUB_LOG="$FX/calls-gate" "$TICK" snapshot > "$FX/gate.json" 2>/dev/null
"$TICK" plan "$FX/gate.json" > "$FX/gate-plan.json"
gate_mark="$FX/gate-launched"
gate_out=$("$TICK" spawn-lane gate-12 --no-tick -- sh -c "touch '$gate_mark'" 2>&1); gate_rc=$?
if ! jq -e '.actions[] | select(.ticket == 12 and .step == "gate")' "$FX/gate-plan.json" >/dev/null \
   && jq -e '.deferred[] | select(.ticket == 12 and (.why | contains("root/review-286")))' "$FX/gate-plan.json" >/dev/null \
   && [ "$gate_rc" -ne 0 ] && [ ! -e "$gate_mark" ]; then
    ok "supervised lease: gate planning and direct gate launch share the hold"
else
    bad "supervised lease: gate escaped the common hold (rc=$gate_rc; out=$gate_out)"
fi
"$TICK" supervise release 12 >/dev/null

# D-TICK-29: a supervised infrastructure repair owns the entire ticket, not
# only its first two stages. A fresh plan visibly defers a leased merge while
# preserving queue progress for the next unrelated ticket.
jq '
  .tickets |= map(
    if .id == 10 then
      .state = "merge-queue" | .merge_attempts = 2 | .merge_hold = null
      | .gate = {eligible:false,reason:"already passed",head:null,last_verdict:null}
    elif .id == 12 then
      .state = "merge-queue" | .merge_attempts = 0 | .merge_hold = null
      | .supervised_lease = null
      | .gate = {eligible:false,reason:"already passed",head:null,last_verdict:null}
    else . end)
  | .summary.merge_in_flight = false
  | .summary.stranded = []
' "$FX/snapshot.json" > "$FX/merge-snapshot.json"
"$TICK" plan "$FX/merge-snapshot.json" > "$FX/merge-plan.json"
if ! jq -e '.actions[] | select(.ticket == 10 and .step == "merge")' "$FX/merge-plan.json" >/dev/null \
   && jq -e '.deferred[] | select(.ticket == 10 and .step == "merge"
                                      and (.why | contains("root/repair-286")))' "$FX/merge-plan.json" >/dev/null \
   && jq -e '.actions[] | select(.ticket == 12 and .step == "merge" and .lane == "merge-12")' "$FX/merge-plan.json" >/dev/null; then
    ok "supervised lease: merge plan defers the held ticket and advances to the next queue entry"
else
    bad "supervised lease: merge plan escaped, hid, or stalled behind the held ticket ($(jq -c '{actions,deferred}' "$FX/merge-plan.json"))"
fi

# The final public admission boundary covers all paths that can outlive a
# plan: an ordinary stale-plan launch refuses; a Claude/direct handoff and a
# Codex durable drain consume the now-obsolete successor request softly.
"$TICK" supervise acquire 10 --owner root/merge-repair --ttl-seconds 60 >/dev/null
direct_mark="$FX/merge-direct-launched"
direct_out=$("$TICK" spawn-lane merge-10 --no-tick -- sh -c "touch '$direct_mark'" 2>&1); direct_rc=$?
for _ in $(seq 1 20); do [ -e "$direct_mark" ] && break; sleep 0.05; done
if [ "$direct_rc" -ne 0 ] && [ ! -e "$direct_mark" ] && printf '%s' "$direct_out" | grep -qi supervised; then
    ok "supervised lease: stale merge plan is refused at final admission"
else
    bad "supervised lease: stale merge launch escaped (rc=$direct_rc; out=$direct_out)"
fi
[ ! -e "$LOOM_HOME/lanes/merge-10.pid" ] || "$TICK" clear-lane merge-10 >/dev/null

handoff_mark="$FX/merge-handoff-launched"
handoff_out=$(LOOM_LANE_ID=gate-99 "$TICK" spawn-lane merge-10 --no-tick -- sh -c "touch '$handoff_mark'" 2>&1); handoff_rc=$?
for _ in $(seq 1 20); do [ -e "$handoff_mark" ] && break; sleep 0.05; done
if [ "$handoff_rc" -eq 0 ] && [ ! -e "$handoff_mark" ] && printf '%s' "$handoff_out" | grep -qi supervised; then
    ok "supervised lease: direct lane handoff consumes a held merge without launching it"
else
    bad "supervised lease: direct merge handoff escaped or became a hard failure (rc=$handoff_rc; out=$handoff_out)"
fi
[ ! -e "$LOOM_HOME/lanes/merge-10.pid" ] || "$TICK" clear-lane merge-10 >/dev/null

drain_mark="$FX/merge-drain-launched"
drain_out=$(LOOM_AUX_DRAIN_ID=merge-10 "$TICK" spawn-lane merge-10 --no-tick -- sh -c "touch '$drain_mark'" 2>&1); drain_rc=$?
for _ in $(seq 1 20); do [ -e "$drain_mark" ] && break; sleep 0.05; done
if [ "$drain_rc" -eq 0 ] && [ ! -e "$drain_mark" ] && printf '%s' "$drain_out" | grep -qi supervised; then
    ok "supervised lease: durable Codex drain consumes a held merge request without launching it"
else
    bad "supervised lease: durable merge drain escaped or retained an obsolete request (rc=$drain_rc; out=$drain_out)"
fi
[ ! -e "$LOOM_HOME/lanes/merge-10.pid" ] || "$TICK" clear-lane merge-10 >/dev/null
"$TICK" supervise release 10 >/dev/null

# Planted violation: remove merge recognition from a private copy of the
# shared lane-to-ticket admission seam. The identical leased launch must
# escape again, proving the common parser—not provider behavior—holds it.
MUT=$(mirror_scripts "$FX/mut-no-merge-lease")
sed -i.bak '/merge-\*) iid="${id#merge-}" ;;/d' "$MUT/tick.sh"
MUT_HOME="$FX/mut-home"; MUT_MARK="$FX/mut-merge-launched"
LOOM_HOME="$MUT_HOME" "$MUT/tick.sh" supervise acquire 10 --owner root/mutant --ttl-seconds 60 >/dev/null
mut_out=$(LOOM_HOME="$MUT_HOME" "$MUT/tick.sh" spawn-lane merge-10 --no-tick -- sh -c "touch '$MUT_MARK'" 2>&1); mut_rc=$?
for _ in $(seq 1 20); do [ -e "$MUT_MARK" ] && break; sleep 0.05; done
if [ "$mut_rc" -eq 0 ] && [ -e "$MUT_MARK" ]; then
    ok "supervised lease violation: removing merge admission recreates the escaped worker"
else
    bad "supervised lease violation: parser mutant did not recreate escape (rc=$mut_rc; out=$mut_out)"
fi
[ ! -e "$MUT_HOME/lanes/merge-10.pid" ] || LOOM_HOME="$MUT_HOME" "$MUT/tick.sh" clear-lane merge-10 >/dev/null

# The ticket admission lock makes acquire honest at the one remaining race:
# it cannot report ownership while an already-admitted spawn command is live.
mkdir -p "$LOOM_HOME/supervised-admission/13.lock.d"
printf '%s\n' "$$" > "$LOOM_HOME/supervised-admission/13.lock.d/pid"
busy_out=$("$TICK" supervise acquire 13 --owner root/race --ttl-seconds 60 2>&1); busy_rc=$?
if [ "$busy_rc" -ne 0 ] && [ ! -e "$LOOM_HOME/supervised-leases/13.json" ] \
   && printf '%s' "$busy_out" | grep -q 'admission is busy'; then
    ok "supervised lease: acquire cannot race an already-admitted launch"
else
    bad "supervised lease: acquire claimed ownership across live admission (rc=$busy_rc; out=$busy_out)"
fi
rm -rf "$LOOM_HOME/supervised-admission/13.lock.d"

# A restricted operator can see the state directory but be unable to create a
# child lock (the interactive Codex sandbox is the live example). That is an
# I/O failure, not a stale lock to recursively break forever.
chmod 500 "$LOOM_HOME/supervised-admission"
io_out=$(perl -e 'alarm 2; exec @ARGV' "$TICK" supervise acquire 14 --owner root/restricted --ttl-seconds 60 2>&1); io_rc=$?
chmod 700 "$LOOM_HOME/supervised-admission"
if [ "$io_rc" -ne 0 ] && [ "$io_rc" -ne 142 ] \
   && printf '%s' "$io_out" | grep -q 'cannot reserve'; then
    ok "supervised lease: admission I/O denial fails promptly instead of recursing"
else
    bad "supervised lease: admission I/O denial hung or lacked a named failure (rc=$io_rc; out=$io_out)"
fi

# D-TICK-36: a human commonly runs the public supervise verb while inspecting
# a ticket's linked worktree. Host state belongs to the repository's main
# checkout, not to whichever linked worktree happened to be the caller's cwd.
D36="$FX/linked-worktree-state"; mkdir -p "$D36/main" "$D36/operator-home"
git -C "$D36/main" init -q
git -C "$D36/main" config user.email loom@test
git -C "$D36/main" config user.name loom
printf 'fixture\n' > "$D36/main/tracked"
git -C "$D36/main" add tracked
git -C "$D36/main" commit -qm fixture
git -C "$D36/main" worktree add -qb repair "$D36/repair"
main_root=$(git -C "$D36/main" rev-parse --show-toplevel)
repair_root=$(git -C "$D36/repair" rev-parse --show-toplevel)
main_key="$(basename "$main_root")-$(printf '%s' "$main_root" | cksum | cut -d' ' -f1)"
repair_key="$(basename "$repair_root")-$(printf '%s' "$repair_root" | cksum | cut -d' ' -f1)"
repair_alias_key="$(basename "$D36/repair")-$(printf '%s' "$D36/repair" | cksum | cut -d' ' -f1)"
main_state="$D36/operator-home/.loom/$main_key"
repair_state="$D36/operator-home/.loom/$repair_key"
repair_alias_state="$D36/operator-home/.loom/$repair_alias_key"

env -u LOOM_HOME HOME="$D36/operator-home" LOOM_REPO="$main_root" \
    "$TICK" supervise acquire 236 --owner root/worktree-release --ttl-seconds 60 >/dev/null
release_out=$(cd "$D36/repair" && env -u LOOM_HOME -u LOOM_REPO HOME="$D36/operator-home" \
    "$TICK" supervise release 236 2>&1); release_rc=$?
if [ "$release_rc" -eq 0 ] && [ ! -e "$main_state/supervised-leases/236.json" ] \
   && [ ! -e "$repair_state" ] && [ ! -e "$repair_alias_state" ]; then
    ok "supervised lease: release from a linked worktree reaches canonical host state"
else
    bad "supervised lease: linked-worktree release silently used parallel state (rc=$release_rc; out=$release_out)"
fi

acquire_out=$(cd "$D36/repair" && env -u LOOM_HOME -u LOOM_REPO HOME="$D36/operator-home" \
    "$TICK" supervise acquire 214 --owner root/worktree-acquire --ttl-seconds 60 2>&1); acquire_rc=$?
if [ "$acquire_rc" -eq 0 ] && [ -e "$main_state/supervised-leases/214.json" ] \
   && [ ! -e "$repair_state" ] && [ ! -e "$repair_alias_state" ]; then
    ok "supervised lease: acquire from a linked worktree publishes canonical host state"
else
    bad "supervised lease: linked-worktree acquire silently used parallel state (rc=$acquire_rc; out=$acquire_out)"
fi
env -u LOOM_HOME HOME="$D36/operator-home" LOOM_REPO="$main_root" \
    "$TICK" supervise release 214 >/dev/null

mkdir -p "$D36/broken-linked"
printf 'gitdir: %s\n' "$D36/missing-common/worktrees/broken" > "$D36/broken-linked/.git"
broken_out=$(cd "$D36/broken-linked" && env -u LOOM_HOME -u LOOM_REPO HOME="$D36/broken-home" \
    "$TICK" supervise release 999 2>&1); broken_rc=$?
if [ "$broken_rc" -ne 0 ] && printf '%s' "$broken_out" | grep -qi 'linked worktree' \
   && [ ! -e "$D36/broken-home/.loom" ]; then
    ok "supervised lease: unreadable linked-worktree identity fails before host-state mutation"
else
    bad "supervised lease: unreadable linked worktree silently derived state (rc=$broken_rc; out=$broken_out)"
fi

# Planted violation: restore the old cwd-derived repository assignment in a
# private copy. The linked release must again report success while leaving the
# canonical lease intact, proving repository canonicalization is the guard.
D36_MUT=$(mirror_scripts "$D36/mut-cwd-state")
sed -i.bak 's/^REPO_ROOT=.*/REPO_ROOT="${LOOM_REPO:-$PWD}"/' "$D36_MUT/tick.sh"
env -u LOOM_HOME HOME="$D36/operator-home" LOOM_REPO="$main_root" \
    "$D36_MUT/tick.sh" supervise acquire 237 --owner root/worktree-mutant --ttl-seconds 60 >/dev/null
mut_release_out=$(cd "$D36/repair" && env -u LOOM_HOME -u LOOM_REPO HOME="$D36/operator-home" \
    "$D36_MUT/tick.sh" supervise release 237 2>&1); mut_release_rc=$?
if [ "$mut_release_rc" -eq 0 ] && [ -n "$mut_release_out" ] \
   && [ -e "$main_state/supervised-leases/237.json" ] \
   && { [ -d "$repair_state" ] || [ -d "$repair_alias_state" ]; }; then
    ok "supervised lease violation: cwd-derived state recreates false-success release"
else
    bad "supervised lease violation: cwd mutant did not recreate parallel state (rc=$mut_release_rc; out=$mut_release_out)"
fi

test_finish
