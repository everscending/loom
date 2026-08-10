#!/usr/bin/env bash
# P8 parallelism and P64 wiring tickets — both read `tick.sh graph`
#
# Section 08 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 7g. P8: is there parallelism to exploit at all? -----------------------
# Build 2 had four lanes and spent its first hour with zero or one startable
# ticket; peak concurrency for the whole run was 2. That is decided when the
# tickets are written, and it was invisible until wave 1 said so out loud.
# `graph` reads a snapshot, so it costs no extra tracker calls.
GN() { printf '{"id":%s,"blocked_by":[],"state":"ready-for-agent","unblocked":true,"assignees":[]}' "$1"; }
GB() { printf '{"id":%s,"blocked_by":[{"id":%s,"closed":false}],"state":"blocked","unblocked":false,"assignees":[]}' "$1" "$2"; }
GRAPH() { printf '{"config":{"max_lanes":4},"tickets":[%s]}' "$1" | "$TICK" graph; }

# 7g1. Shapes that can be checked by hand. A diamond (1 → 2,3 → 4) is three
#      merge cycles deep and two wide at its widest — no scheduler needed to
#      know that, which is the point of asserting it.
out=$(GRAPH "$(GN 1),$(GB 2 1),$(GB 3 1),$(GB 4 2)")
if [ "$(printf '%s' "$out" | jq -r '.critical_path.length')" = "3" ] \
   && [ "$(printf '%s' "$out" | jq -r '.widest_level')" = "2" ] \
   && [ "$(printf '%s' "$out" | jq -r '.opening_width')" = "1" ] \
   && [ "$(printf '%s' "$out" | jq -c '[.levels[].iids]')" = "[[1],[2,3],[4]]" ]; then
    ok "graph: depth, width and levels match a hand-checked diamond"
else
    bad "graph: diamond analysed wrong ($(printf '%s' "$out" | jq -c '{critical_path,widest_level,opening_width}'))"
fi

# 7g2. The alarm fires on the shape build 2 actually had, and reports BOTH
#      numbers — how wide it opens and how wide it ever gets are different
#      questions, and the hour was lost to the first one.
out=$(GRAPH "$(GN 1),$(GB 2 1),$(GB 3 1)")
case "$(printf '%s' "$out" | jq -r .verdict)" in
    *"CHAIN-SHAPED"*|*"NARROW START"*) ok "graph: a chain-bound build says so before it starts" ;;
    *) bad "graph: no alarm on a build that opens 1 wide ($(printf '%s' "$out" | jq -r .verdict))" ;;
esac

# 7g3. Planted violation: crying wolf would train the human to skip this line.
#      A build with fewer tickets than lanes is SMALL, not chain-shaped, and a
#      build that fills its lanes is fine however deep it runs.
out=$(GRAPH "$(GN 1),$(GN 2),$(GN 3)")
case "$(printf '%s' "$out" | jq -r .verdict)" in
    *"CHAIN-SHAPED"*|*"NARROW START"*) bad "graph-violation: a small all-parallel build was flagged" ;;
    *) ok "graph-violation: fewer tickets than lanes is small, not chain-shaped" ;;
esac
out=$(GRAPH "$(GN 1),$(GN 2),$(GN 3),$(GN 4),$(GN 5)")
case "$(printf '%s' "$out" | jq -r .verdict)" in
    *"CHAIN"*|*"NARROW"*) bad "graph-violation: a build that fills every lane was flagged" ;;
    *) ok "graph-violation: a build that fills every lane raises nothing" ;;
esac

# 7g4. The widening fix P8 exists to enable: split the heavy blocker so the
#      dependents wait on a pinned interface instead of a merged body, and the
#      same four tickets open four wide instead of one.
before=$(GRAPH "$(GN 1),$(GB 2 1),$(GB 3 1),$(GB 4 1)" | jq -r .opening_width)
after=$(GRAPH "$(GN 1),$(GN 2),$(GN 3),$(GN 4)" | jq -r .opening_width)
[ "$before" = "1" ] && [ "$after" = "4" ] \
    && ok "graph: splitting the blocker is visible as the frontier opening 1 → 4" \
    || bad "graph: split not reflected (before=$before after=$after)"

# 7g5. A closed blocker constrains nothing, and a cycle is reported rather than
#      silently producing nonsense depths.
out=$(printf '{"config":{"max_lanes":4},"tickets":[{"id":1,"blocked_by":[{"id":99,"closed":true}],"state":"ready-for-agent","unblocked":true,"assignees":[]},%s]}' "$(GN 2)" | "$TICK" graph)
[ "$(printf '%s' "$out" | jq -r '.opening_width')" = "2" ] \
    && ok "graph: an already-closed blocker does not narrow the frontier" \
    || bad "graph: closed blocker still counted"
# A blocker OUTSIDE the build still holds its dependent back. Dropping those
# edges because the graph cannot see their depth made crucible report "opens 7
# wide" when three of the seven were waiting on issues outside the build —
# false reassurance, which is worse than no report at all.
out=$(printf '{"config":{"max_lanes":4},"tickets":[%s,{"id":2,"blocked_by":[{"id":900,"closed":false}],"state":"ready-for-agent","unblocked":false,"assignees":[]}]}' "$(GN 1)" | "$TICK" graph)
if [ "$(printf '%s' "$out" | jq -r '.opening_width')" = "1" ] \
   && [ "$(printf '%s' "$out" | jq -c '[.levels[].iids]')" = "[[1],[2]]" ]; then
    ok "graph: a blocker outside the build still keeps its dependent off the frontier"
else
    bad "graph: out-of-build blocker ignored ($(printf '%s' "$out" | jq -c '{opening_width, levels}'))"
fi
# The frontier is the level at DEPTH 0, not whatever sorts first. With every
# ticket blocked by something outside the build there is no depth-0 level, and
# reading levels[0] reported the depth-1 group as the frontier — "opens 3 wide"
# while nothing at all could start. The test above happens to include a free
# ticket, which is exactly why it missed this.
# (Found by an independent review, 2026-08-01.)
out=$(printf '{"config":{"max_lanes":4},"tickets":[
 {"id":1,"blocked_by":[{"id":900,"closed":false}],"state":"ready-for-agent","unblocked":false,"assignees":[]},
 {"id":2,"blocked_by":[{"id":901,"closed":false}],"state":"ready-for-agent","unblocked":false,"assignees":[]},
 {"id":3,"blocked_by":[{"id":902,"closed":false}],"state":"ready-for-agent","unblocked":false,"assignees":[]}]}' | "$TICK" graph)
if [ "$(printf '%s' "$out" | jq -r '.opening_width')" = "0" ] \
   && [ "$(printf '%s' "$out" | jq -r '.startable_now')" = "0" ]; then
    ok "graph: a build where nothing can start reports a frontier of 0, not its first level"
else
    bad "graph: opening_width $(printf '%s' "$out" | jq -r '.opening_width') with startable_now $(printf '%s' "$out" | jq -r '.startable_now') — false reassurance"
fi

out=$(GRAPH "$(GB 1 2),$(GB 2 1)")
[ "$(printf '%s' "$out" | jq -r '.cycle_suspected')" = "true" ] \
    && ok "graph: a dependency cycle is named, not silently mis-analysed" \
    || bad "graph: cycle went undetected"
out=$(printf '{"config":{"max_lanes":4},"tickets":[]}' | "$TICK" graph)
[ "$(printf '%s' "$out" | jq -r '.tickets')" = "0" ] \
    && ok "graph: an empty build analyses cleanly instead of erroring" \
    || bad "graph: empty build broke the analysis"

# 7g6. P53: depth is decided when the ticket is written, same as width. An
#      outsized acceptance-criteria or file count on a single ticket is
#      flagged as LIKELY DEEP, named in both the structured list and the
#      verdict string — a build under threshold raises nothing.
out=$(printf '{"config":{"max_lanes":4},"tickets":[%s]}' \
    '{"id":1,"blocked_by":[],"state":"ready-for-agent","unblocked":true,"assignees":[],"criteria_count":9,"file_surface":1}' \
    | "$TICK" graph)
if [ "$(printf '%s' "$out" | jq -c '.likely_deep')" = '[{"id":1,"criteria_count":9,"file_surface":1}]' ] \
   && case "$(printf '%s' "$out" | jq -r .verdict)" in *"LIKELY DEEP"*"#1"*) true ;; *) false ;; esac; then
    ok "graph: an outsized acceptance-criteria count is flagged LIKELY DEEP"
else
    bad "graph: no depth alarm on an outsized criteria count ($(printf '%s' "$out" | jq -c '{likely_deep, verdict}'))"
fi
out=$(printf '{"config":{"max_lanes":4},"tickets":[%s]}' \
    '{"id":2,"blocked_by":[],"state":"ready-for-agent","unblocked":true,"assignees":[],"criteria_count":1,"file_surface":9}' \
    | "$TICK" graph)
case "$(printf '%s' "$out" | jq -r .verdict)" in
    *"LIKELY DEEP"*"#2"*) ok "graph: an outsized file count is flagged LIKELY DEEP too" ;;
    *) bad "graph: file-count-only depth signal missed ($(printf '%s' "$out" | jq -r .verdict))" ;;
esac
# Planted violation: a ticket comfortably under both thresholds must not cry
# wolf, same discipline as 7g3 for width.
out=$(GRAPH "$(printf '{"id":3,"blocked_by":[],"state":"ready-for-agent","unblocked":true,"assignees":[],"criteria_count":3,"file_surface":2}')")
case "$(printf '%s' "$out" | jq -r .verdict)" in
    *"LIKELY DEEP"*) bad "graph-violation: a normally-sized ticket was flagged LIKELY DEEP" ;;
    *) ok "graph-violation: a normally-sized ticket raises no depth alarm" ;;
esac
# A ticket with no size signal at all (a synthetic snapshot from before P53,
# or a test fixture that never sets criteria_count/file_surface) must default
# to 0, not null propagating into a false comparison.
out=$(GRAPH "$(GN 4)")
[ "$(printf '%s' "$out" | jq -c '.likely_deep')" = "[]" ] \
    && ok "graph: a ticket with no size fields defaults to not-deep" \
    || bad "graph: missing size fields broke the depth read ($(printf '%s' "$out" | jq -c '.likely_deep'))"

# --- 7g7. P64: every epic ends with a wiring ticket ------------------------
# Unit-tier gates judge tickets; nothing before the epic probe judges the EPIC.
# ai-workout build-1: every E1 ticket passed its gate while the running app
# never called build_kg1() once, and the probe — the last step of the epic —
# was the first thing that looked. An epic has its wiring ticket when some
# member is blocked by every other member, which is a graph property and needs
# no label. A definition whose epic has none is REFUSED (rc 1), not annotated.
GE() { # iid epic [blocker-iid...] — a build member carrying its epic
    local iid="$1" epic="$2" bb="" b; shift 2
    for b in "$@"; do bb="$bb${bb:+,}{\"id\":$b,\"closed\":false}"; done
    printf '{"id":%s,"epic":"%s","blocked_by":[%s],"state":"ready-for-agent","unblocked":true,"assignees":[]}' \
        "$iid" "$epic" "$bb"
}

# 7g7a. The guard holding: E1's #3 is blocked by #1 but not #2, so no member
#       covers the epic. Refused by exit code, named in the structured field
#       AND in the verdict — and the document still prints, because phase 5
#       reads the rest of it either way.
out=$(GRAPH "$(GE 1 E1),$(GE 2 E1),$(GE 3 E1 1)" 2>"$T/wiring.err"); rc_g=$?
if [ "$rc_g" -eq 1 ] \
   && [ "$(printf '%s' "$out" | jq -c '.unwired_epics')" = '["E1"]' ] \
   && [ "$(printf '%s' "$out" | jq -r '.tickets')" = "3" ] \
   && grep -q "wiring ticket" "$T/wiring.err" \
   && case "$(printf '%s' "$out" | jq -r .verdict)" in *"UNWIRED EPIC"*"E1"*) true ;; *) false ;; esac; then
    ok "graph: an epic with no ticket blocked by every other member is refused"
else
    bad "graph: unwired epic not refused (rc=$rc_g: $(printf '%s' "$out" | jq -c '{unwired_epics,verdict}'))"
fi

# 7g7b. The mechanism removed: give #3 the one missing edge and the same three
#       tickets pass. That single edge is the whole fix, so the test that
#       cannot tell these two apart is testing nothing.
out=$(GRAPH "$(GE 1 E1),$(GE 2 E1),$(GE 3 E1 1 2)"); rc_g=$?
if [ "$rc_g" -eq 0 ] && [ "$(printf '%s' "$out" | jq -c '.unwired_epics')" = "[]" ] \
   && case "$(printf '%s' "$out" | jq -r .verdict)" in *"UNWIRED"*) false ;; *) true ;; esac; then
    ok "graph: adding the last blocking edge turns the refusal into a pass"
else
    bad "graph: a wired epic was still refused (rc=$rc_g: $(printf '%s' "$out" | jq -c '.unwired_epics'))"
fi

# 7g7c. Only the offending epic is named. A build is refused for E2 while E1 is
#       correctly wired, so the human is sent back to phase 4 for one epic, not
#       told the whole set is wrong.
out=$(GRAPH "$(GE 1 E1),$(GE 2 E1),$(GE 3 E1 1 2),$(GE 4 E2),$(GE 5 E2)" 2>/dev/null); rc_g=$?
if [ "$rc_g" -eq 1 ] && [ "$(printf '%s' "$out" | jq -c '.unwired_epics')" = '["E2"]' ]; then
    ok "graph: only the epic missing its wiring ticket is named"
else
    bad "graph: wrong epics named (rc=$rc_g: $(printf '%s' "$out" | jq -c '.unwired_epics'))"
fi

# 7g7d. Planted violation, the same discipline as 7g3: a false refusal at
#       definition time is more expensive than the check is worth. A one-ticket
#       epic has nothing to wire together, and every fixture in this suite
#       carries no epic at all — neither may be refused.
out=$(GRAPH "$(GE 6 E3)"); rc_g=$?
[ "$rc_g" -eq 0 ] && [ "$(printf '%s' "$out" | jq -c '.unwired_epics')" = "[]" ] \
    && ok "graph-violation: a one-ticket epic is not refused for lacking a wiring ticket" \
    || bad "graph-violation: single-member epic falsely refused (rc=$rc_g)"
out=$(GRAPH "$(GN 1),$(GB 2 1),$(GB 3 1)"); rc_g=$?
[ "$rc_g" -eq 0 ] && [ "$(printf '%s' "$out" | jq -c '.unwired_epics')" = "[]" ] \
    && ok "graph-violation: tickets carrying no epic raise no wiring refusal" \
    || bad "graph-violation: epicless tickets falsely refused (rc=$rc_g)"

test_finish
