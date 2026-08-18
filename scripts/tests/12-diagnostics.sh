#!/usr/bin/env bash
# P23: the diagnostic record
#
# Section 12 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 11. P23: the diagnostic record ---------------------------------------
# Every number behind P1–P22 was reconstructed by hand from 31 transcripts plus
# filename arithmetic, and none of it survived to the next build. These events
# are written by the MACHINERY, so they exist even when a wave dies.
ET="$T/ev"; mkdir -p "$ET/repo"
seed_tracker_decl "$ET/repo"
git -C "$ET/repo" init -q 2>/dev/null || git init -q "$ET/repo" 2>/dev/null || :
EVENV() { LOOM_REPO="$ET/repo" LOOM_HOME="$ET/home" LOOM_GLOBAL_CONFIG="$ET/g.yml" \
          LOOM_TRUST_FILE="$LOOM_TRUST_FILE" LOOM_RETRY_BACKOFF_SECONDS=0 \
          LOOM_SKIP_BOOTSTRAP=1 "$@"; }
mkdir -p "$ET/home"; echo "build-9" > "$ET/home/.build-label"
EVF="$ET/home/events.jsonl"

# 11a. A crashed wave still leaves its record — the case a model-written log
#      would have missed, which is exactly when the record is needed.
LOOM_WAVE_CMD='sh -c "exit 1"' EVENV "$TICK" tick >/dev/null 2>&1
if [ -s "$EVF" ] && jq -e 'select(.ev=="wave_end" and .rc==1)' "$EVF" >/dev/null 2>&1; then
    ok "events: a wave that died still recorded its start, end and exit code"
else
    bad "events: nothing recorded for a crashed wave"
fi
[ "$(jq -s '[.[] | select(.ev=="wave_start" and .retry==1)] | length' "$EVF")" = "1" ] \
    && ok "events: the retry is distinguishable from the first attempt" \
    || bad "events: retry flag missing or wrong"

# 11b. Lane events carry type, exit code and a measured duration — not a
#      duration inferred from file mtimes, which is what build 2 forced.
LOOM_WAVE_CMD=true EVENV "$TICK" spawn-lane gate-77 --no-tick --cwd "$ET/repo" -- sh -c 'exit 7' >/dev/null 2>&1
for _ in $(seq 1 40); do jq -e 'select(.ev=="lane_exit")' "$EVF" >/dev/null 2>&1 && break; sleep 0.1; done
if jq -e 'select(.ev=="lane_exit" and .id=="gate-77" and .type=="gate" and .rc==7 and (.secs|type=="number"))' \
       "$EVF" >/dev/null 2>&1; then
    ok "events: a lane records id, type, exit code and measured seconds"
else
    bad "events: lane_exit missing fields ($(jq -c 'select(.ev=="lane_exit")' "$EVF" | tail -1))"
fi

# 11c. Both report views work off that one file, with no tracker calls.
out=$(EVENV "$TICK" report 2>&1)
case "$out" in
    *"Build build-9"*"mechanical rejections (rc 7)   1"*)
        ok "report: aggregates waves, lanes and rejections for the build" ;;
    *) bad "report: aggregate view wrong ($(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
out=$(EVENV "$TICK" report --ticket 77 2>&1)
case "$out" in
    *"gate-77"*"pregate rejection"*) ok "report: the per-ticket view traces its lanes and says why" ;;
    *) bad "report: ticket view wrong ($(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
# The per-ticket trace names the provider and Loom tier each round used — otherwise an
# escalation cannot be priced against its outcome, which is the whole test of
# whether escalating was worth it.
EVENV "$TICK" event lane_spawn id impl-77 type impl job implementation provider codex tier high log /tmp/impl-77.log
out=$(EVENV "$TICK" report --ticket 77 2>&1)
case "$out" in *"impl-77"*"on codex/high"*) ok "report: a lane's provider/tier appears in the per-ticket trace" ;;
               *) bad "report: provider/tier missing from the ticket trace ($(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
EVENV "$TICK" event lane_spawn id repair-77 type repair job repair provider codex tier high log /tmp/repair-77.log
out=$(EVENV "$TICK" report --ticket 77 2>&1)
case "$out" in *"repair-77"*"still running"*) ok "report: start-owned repair work is attributed to its ticket" ;;
               *) bad "report: repair lane missing from the ticket trace ($(printf '%s' "$out" | tr '\n' '|'))" ;;
esac

# 11d. Planted violation: the record must never feed a decision. If a wave read
#      it, it would be shadow state and constitution rule 1 would be broken — so
#      nothing outside the reporting verbs may even open it. `retro` joins that
#      allowlist for the same reason `report` is on it: neither is ever consulted
#      by a scheduling decision (P26). `render-events` (the build ticker,
#      2026-08-02) is the third display verb on the list: it renders the log
#      for a human pane and decides nothing.
if grep -nE '(<|read|cat|jq[^|]*)[^|]*\$EVENTS' "$TICK" | grep -vqE '_ev\(\)|>>|cmd_report|cmd_retro|REPORT|RETRO|-s "\$EVENTS"|render-events: display-only reader'; then
    bad "events-violation: something other than report/retro reads the event log"
else
    ok "events-violation: the event log is write-only outside report and retro"
fi

# 11e. A merge lane that finishes instantly must not fail its own spawn. The
#      lane releases the lock on exit, so stamping it from the parent AFTER the
#      spawn raced the lane — and lost, fatally, under set -e.
EVENV "$TICK" spawn-lane merge-78 --merge-lock --no-tick --cwd "$ET/repo" -- true >/dev/null 2>&1 \
    && ok "merge-lock: an instant merge lane spawns cleanly (no stamp race)" \
    || bad "merge-lock: spawn failed because the lane released before the stamp"
sleep 0.5
EVENV "$TICK" spawn-lane merge-79 --merge-lock --no-tick --cwd "$ET/repo" -- true >/dev/null 2>&1 \
    && ok "merge-lock-violation: the released lock is genuinely free for the next merge" \
    || bad "merge-lock-violation: lock left behind by an instant lane"

test_finish
