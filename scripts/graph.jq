# graph.jq — the graph-shape verdict (P8): is there parallelism to exploit at
# all? Reads a snapshot document (stdin by default) so it costs no extra
# tracker calls. `widest_level` is a LOWER bound on real concurrency, not the
# true maximum — see the comment at its use below — and is still the right
# alarm, because a build whose widest level is below `max_lanes` cannot fill
# them at the start, which is exactly when a build is most chain-bound.
#
# Lifted out of tick.sh (P71), where it lived as GRAPH_JQ, a single-quoted
# shell string. In a file it is checkable with
# `jq -L . -n -f graph.jq </dev/null`.
#
# No --arg/--argjson bindings; reads the snapshot document as its top-level
# input (`.tickets`, `.config.max_lanes`). The prelude include is uniform
# across every jq program here (P72), not a dependency this one has yet.
include "lib";
  (.tickets // []) as $ts
| ($ts | map(.id)) as $ids
| ($ts | length) as $n
| ((.config.max_lanes // 4) | tonumber? // 4) as $max_lanes
# A blocker whose closed state is unknown (cross-project link) counts as
# blocking: the snapshot already warns about it and the pessimistic read is the
# safe one here.
# Blockers OUTSIDE this build still hold their dependent back, so they cannot
# simply be dropped — doing that made crucible report "opens 7 wide" when three
# of those seven were waiting on issues outside the build. They get no depth of
# their own (this graph cannot see them), but they do push their dependent off
# depth 0, which is the number that matters.
| ($ts | map({key: (.id | tostring),
              value: [(.blocked_by // [])[]
                      | select((.closed // false) != true)
                      | .id | select(. as $b | ($ids | index($b)) != null)]})
       | from_entries) as $preds
| ($ts | map({key: (.id | tostring),
              value: ((.blocked_by // [])
                      | map(select((.closed // false) != true) | .id)
                      | any(. as $b | ($ids | index($b)) == null))})
       | from_entries) as $ext
| (if $n == 0 then {} else
     reduce range(0; $n + 1) as $_ (
       ($ts | map({key: (.id | tostring), value: 0}) | from_entries);
       reduce ($preds | keys_unsorted[]) as $k (
         .;
         .[$k] = ((([$preds[$k][] as $p | .[$p | tostring]]
                    + (if $ext[$k] then [0] else [] end)) | max // -1) + 1)))
   end) as $depth
| ($depth | to_entries | map({id: (.key | tonumber), depth: .value})) as $dl
| ([$dl[].depth] | max // -1) as $maxdepth
| ($dl | group_by(.depth) | map({depth: .[0].depth, iids: (map(.id) | sort)})
       | sort_by(.depth)) as $levels
| ($levels | map(.iids | length) | max // 0) as $widest
# How wide the build OPENS, which is a different question from how wide it ever
# gets and is the one build 2 actually lost an hour to: "frontier is 1 wide
# until #12 merges; it opens to 3 the moment it does". Both get reported.
# The level at DEPTH 0, not whatever sorts first. When every ticket is blocked
# by something outside the build there is no depth-0 level at all, and reading
# levels[0] then reported the depth-1 group as the frontier — "opens 3 wide"
# while nothing at all could start. Same false reassurance as the out-of-build
# edge bug, one layer up.
| ((($levels | map(select(.depth == 0)) | first | .iids) // []) | length) as $opening
# A DAG of n nodes cannot have depth n; if it does, the fixpoint never settled.
| ($n > 0 and $maxdepth >= $n) as $cycle
| (if $n == 0 then []
   else reduce range(0; $maxdepth) as $_
          ([$dl | map(select(.depth == $maxdepth)) | first | .id];
           . as $path
           | ($path[0] | tostring) as $cur
           | ([$preds[$cur][] | select($depth[(. | tostring)] == ($depth[$cur] - 1))]
              | first) as $prev
           | if $prev == null then $path else [$prev] + $path end)
   end) as $cpath
| ($ts | map(select(.state == "ready-for-agent" and .unblocked == true
                    and (((.assignees // []) | length) == 0))) | length) as $startable
# P53: depth is decided when the ticket is written, same as width — flag an
# outsized one before the build starts rather than discover it at turn 300.
# Thresholds are a starting point (median tickets run well under this), not a
# calibrated cutoff; tighten or loosen them once a build has data to check
# against.
| (6) as $deep_criteria
| (6) as $deep_files
| ($ts | map(select(((.criteria_count // 0) > $deep_criteria)
                    or ((.file_surface // 0) > $deep_files))
           | {id, criteria_count: (.criteria_count // 0), file_surface: (.file_surface // 0)})) as $deep
# P64: unit-tier gates judge tickets; nothing before the epic probe judges the
# EPIC. ai-workout build-1 — every E1 ticket passed its gate while the running
# app never called build_kg1() once, and the probe, the last step of the epic,
# was the first thing that looked. A wiring ticket owns that seam, and it is a
# graph property, so it needs no label of its own: an epic has one when some
# member is blocked by every other member of that epic. A one-ticket epic
# passes trivially — there is nothing to wire together — and a ticket carrying
# no epic belongs to none, so neither can raise a false refusal.
| ([$ts[] | .epic // empty] | unique) as $epic_names
| ($epic_names | map(. as $e
    | ($ts | map(select(.epic == $e))) as $mem
    | ($mem | map(.id)) as $mids
    | if ($mem | any(. as $c
             | (($c.blocked_by // []) | map(.id)) as $bb
             | ($mids | map(select(. != $c.id))
                | all(. as $o | ($bb | index($o)) != null))))
      then empty else $e end)) as $unwired
| {tickets: $n,
   max_lanes: $max_lanes,
   critical_path: {length: ($maxdepth + 1), iids: $cpath},
   widest_level: $widest,
   opening_width: $opening,
   startable_now: $startable,
   levels: $levels,
   cycle_suspected: $cycle,
   likely_deep: $deep,
   unwired_epics: $unwired,
   verdict:
     (($maxdepth + 1) as $len
      | (if $len == 1 then "1 merge cycle" else "\($len) merge cycles" end) as $cyc
      # The alarm is width against BOTH the lane count and the ticket count: a
      # build with fewer tickets than lanes is small, not chain-shaped, and
      # crying wolf there would train the human to ignore this line.
      | if $n == 0 then "no tickets in this build"
        elif $cycle then "dependency cycle — depths did not settle; fix the blocking edges"
        else
          (if $widest < $max_lanes and $widest < $n then "CHAIN-SHAPED — "
           elif $opening < $max_lanes and $opening < $widest then "NARROW START — "
           else "" end)
          + "opens \($opening) wide, widest level \($widest), against \($max_lanes) lanes; critical path \($cyc) through \($n) tickets"
          + (if ($deep | length) > 0
             then "; LIKELY DEEP — #\($deep | map(.id | tostring) | join(", #")) (outsized acceptance-criteria or file count — split before build)"
             else "" end)
          + (if ($unwired | length) > 0
             then "; UNWIRED EPIC — \($unwired | join(", ")) (no ticket blocked by every other member; phase 4 must end each epic with a wiring ticket)"
             else "" end)
        end)}
