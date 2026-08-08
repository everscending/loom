#!/usr/bin/env bash
# P26: retro
#
# Section 13 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 12. P26: retro --------------------------------------------------------
# The four things `report` deliberately does not compute. A hand-built log with
# known numbers, so every bucket below is checked against arithmetic, not vibes.
# The repo `retro` is pointed at. Section 12 built the same one for the event
# record and this section used to inherit it.
ET="$T/ev"; mkdir -p "$ET/repo"
git -C "$ET/repo" init -q 2>/dev/null || git init -q "$ET/repo" 2>/dev/null || :
RT="$T/retro"; mkdir -p "$RT/home"
RTF="$RT/home/events.jsonl"
echo "build-r" > "$RT/home/.build-label"
RTENV() { LOOM_REPO="$ET/repo" LOOM_HOME="$RT/home" LOOM_GLOBAL_CONFIG="$ET/g.yml" \
          LOOM_SKIP_BOOTSTRAP=1 "$@"; }
_snap() { # _snap <ts> <tickets> <deps> <ready> <free>
    printf '{"ts":%s,"ev":"snapshot","build":"build-r","tickets":%s,"deps":%s,"ready":%s,"impl_free":%s,"max_lanes":4}\n' \
        "$1" "$2" "$3" "$4" "$5" >> "$RTF"
}
_lane() { # _lane <ts> <id> <type> <rc> <secs>
    printf '{"ts":%s,"ev":"lane_exit","build":"build-r","id":"%s","type":"%s","rc":%s,"secs":%s}\n' \
        "$1" "$2" "$3" "$4" "$5" >> "$RTF"
}
: > "$RTF"
# free>0 AND ready>0 for 10m: capacity that existed with work waiting for it.
_snap 1000 '{"1":"in-progress","2":"ready-for-agent"}' '{"1":[],"2":[1]}' 1 2
# every slot busy for 10m
_snap 1600 '{"1":"in-progress","2":"in-progress"}'     '{"1":[],"2":[1]}' 0 0
# ticket 1 gone (closed); slots free but nothing ready for 10m
_snap 2200 '{"2":"review"}'                            '{"2":[1]}'        0 2
_lane 1500 impl-1    impl 0 300
_lane 2100 gate-1    gate 7 10
_lane 2150 impl-2    impl 0 200
_lane 2190 gate-2-r2 gate 0 50
_lane 2195 impl-9    impl 1 20
printf '{"ts":2800,"ev":"wave_end","build":"build-r","rc":0,"secs":5}\n' >> "$RTF"

out=$(RTENV "$TICK" retro --build build-r 2>&1)
case "$out" in
    *"slack          10m0s"*) ok "retro: slack — free slots with ready work — is measured" ;;
    *) bad "retro: slack bucket wrong ($(printf '%s' "$out" | grep slack))" ;;
esac
case "$out" in
    *"capacity that existed, with work waiting"*) ok "retro: slack is called out, not just tabulated" ;;
    *) bad "retro: slack found but never flagged" ;;
esac
case "$out" in
    *"at capacity    10m0s"*) ok "retro: time with every impl slot busy is measured" ;;
    *) bad "retro: at-capacity bucket wrong" ;;
esac
case "$out" in
    *"starved        10m0s"*) ok "retro: starvation is distinguished from being at capacity" ;;
    *) bad "retro: starved bucket wrong" ;;
esac
# 80s of 580s lane-seconds produced nothing: rc7 + crash + re-gate.
case "$out" in
    *"total                  1m20s  13.8% of all lane time"*)
        ok "retro: rework is priced as a share of lane time" ;;
    *) bad "retro: rework total wrong ($(printf '%s' "$out" | grep -A1 're-gates'))" ;;
esac
# #2 was open 20m and had 4m10s of lane time: a queuing problem, not a coding one.
case "$out" in
    *"#2   open 20m0s   work 4m10s   wait 15m50s"*)
        ok "retro: wait is separated from work per ticket" ;;
    *) bad "retro: wait/work wrong ($(printf '%s' "$out" | grep '#2 '))" ;;
esac
case "$out" in
    *"#2 at 20m0s  ←  #1 at 10m0s"*) ok "retro: the chain that finished last is walked back through deps" ;;
    *) bad "retro: critical chain wrong ($(printf '%s' "$out" | grep '←')) " ;;
esac

# 12a2. P55: spend, priced from each lane's own session log — round token
#       counts (1M input tokens per lane) so the dollar amounts land on exact
#       integers and the assertion isn't chasing float formatting.
mkdir -p "$RT/home/logs"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}' \
    > "$RT/home/logs/lane-impl-1.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":1000000,"output_tokens":0}}}' \
    > "$RT/home/logs/lane-gate-1.jsonl"
out=$(RTENV "$TICK" retro --build build-r 2>&1)
case "$out" in
    *"Spend   (priced from every lane and wave session log)"*) ok "retro: spend section is present" ;;
    *) bad "retro: no spend section in output" ;;
esac
case "$out" in
    *"total          \$4"*) ok "retro: spend totals every priced lane, not just one kind" ;;
    *) bad "retro: spend total wrong ($(printf '%s' "$out" | grep -A1 'Spend '))" ;;
esac
case "$out" in
    *"  impl  \$3"*"  gate  \$1"*) ok "retro: spend is split by lane kind, most expensive first" ;;
    *) bad "retro: spend-by-kind wrong ($(printf '%s' "$out" | grep -E '^  (impl|gate)  \$'))" ;;
esac
case "$out" in
    *"top spenders"*"impl-1  \$3"*) ok "retro: the top spender names the lane and its price" ;;
    *) bad "retro: top spenders missing impl-1 ($(printf '%s' "$out" | grep -A3 'top spenders'))" ;;
esac
case "$out" in
    *"  by ticket"*"#1  \$4"*) ok "retro: spend rolls up to the ticket its lanes worked" ;;
    *) bad "retro: per-ticket spend wrong ($(printf '%s' "$out" | grep -A3 'by ticket'))" ;;
esac
rm -f "$RT/home/logs/lane-impl-1.jsonl" "$RT/home/logs/lane-gate-1.jsonl"

# 12a2b. D-TICK-13: wave sessions are priced too. `_spend_by_session` used to
#        glob only `lane-*.jsonl`, so every wave log was skipped before pricing
#        began, and the total silently understated a build's real spend. A
#        wave emits no `lane_exit`, so it cannot join by lane id like the
#        others -- it joins by `stem` (the wave log's own basename) instead.
printf '{"ts":2700,"ev":"wave_end","build":"build-r","stem":"wave-9","rc":0,"secs":5}\n' >> "$RTF"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}' \
    > "$RT/home/logs/lane-impl-1.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":1000000,"output_tokens":0}}}' \
    > "$RT/home/logs/lane-gate-1.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":1000000,"output_tokens":0}}}' \
                '{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":1000000,"output_tokens":0}}}' \
    > "$RT/home/logs/wave-9.jsonl"
out=$(RTENV "$TICK" retro --build build-r 2>&1)
case "$out" in
    *"total          \$6"*) ok "retro: a priced total includes wave sessions, not just lanes" ;;
    *) bad "retro: wave spend missing from total ($(printf '%s' "$out" | grep -A1 'Spend '))" ;;
esac
case "$out" in
    *"  impl  \$3"*"  wave  \$2"*"  gate  \$1"*) ok "retro: wave sessions get their own row, not folded into a lane" ;;
    *) bad "retro: wave-by-kind row wrong ($(printf '%s' "$out" | grep -E '^  (impl|wave|gate)  \$'))" ;;
esac
rm -f "$RT/home/logs/lane-impl-1.jsonl" "$RT/home/logs/lane-gate-1.jsonl" "$RT/home/logs/wave-9.jsonl"

# 12a. Planted violation: strip the field the buckets depend on. A missing
#      impl_free must read as UNKNOWN, never as zero — reading it as zero
#      reported a fully starved build as "at capacity 100%", which is exactly
#      what the first live run of this verb did.
jq -c 'if .ev == "snapshot" then del(.impl_free) else . end' "$RTF" > "$RTF.x" && mv "$RTF.x" "$RTF"
out=$(RTENV "$TICK" retro --build build-r 2>&1)
case "$out" in
    *"at capacity    0s"*"unrecorded     30m0s"*)
        ok "retro-violation: snapshots without the field are unrecorded, not at-capacity" ;;
    *) bad "retro-violation: a missing impl_free was silently bucketed ($(printf '%s' "$out" | grep -E 'capacity|unrecorded'))" ;;
esac

RTENV "$TICK" retro --nonsense >/dev/null 2>&1 \
    && bad "retro: an unknown argument was accepted" \
    || ok "retro: an unknown argument is refused rather than ignored"

test_finish
