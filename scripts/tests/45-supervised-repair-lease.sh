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

test_finish

