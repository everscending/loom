# retro.jq — the four things `report` deliberately does not compute, because
# each needs the snapshot record rather than the wave/lane totals (P26):
# where the capacity went, rework, wait-vs-work per ticket, spend, and the
# chain that set the build's length. Everything here is arithmetic over
# events — no interpretation, which is the verb's job.
#
# Lifted out of tick.sh (P71), where it lived as RETRO_JQ, a single-quoted
# shell string. In a file it is checkable with
# `jq -L . -n -f retro.jq </dev/null`.
#
# P72: `hms`, `pct` and `usd` are in lib.jq beside this file, included below
# and shared with report.jq, which `retro` prints immediately above its own
# output.
#
# Inputs are bound by tick.sh: --arg build_want (a build label to filter on,
# "" for every build in the log) and --argjson spend (the per-session cost
# array from `_spend_by_session`, joined here by lane id / wave stem); reads
# the full event array via -rs.
include "lib";
  # Seconds of [$a,$b) that fall inside any window in $ws.
  def ov($a; $b; $ws): [$ws[] | (([$b, .b] | min) - ([$a, .a] | max)) | select(. > 0)]
                       | add // 0;
  ($build_want) as $bw
  | map(select($bw == "" or .build == $bw)) as $evs
  | if ($evs | length) == 0
    then "no events recorded\($bw | if . == "" then "" else " for \(.)" end)"
    else
  ($evs | map(.ts) | min) as $t0 | ($evs | map(.ts) | max) as $t1
  | ($evs | map(select(.ev == "snapshot"))) as $snaps
  | ($evs | map(select(.ev == "lane_exit"))) as $lanes
  | ($lanes | map(.secs) | add // 0) as $lane_secs
  | ([$evs | to_entries[] | select(.value.ev == "usage_pause")
      | .key as $i | .value.ts as $pt
      | {a: $pt,
         b: (($evs[$i+1:] | map(select(.ev == "usage_resume")) | first | .ts) // $t1)}])
    as $pauses
  # Each snapshot describes the world until the next one. Blackout is carved out
  # of every interval it overlaps, so a pause cannot masquerade as starvation.
  # A snapshot written before this record existed carries no impl_free. Reading
  # that as zero would report a starved build as "at capacity" — the missing
  # field means UNKNOWN, and unknown time is shown as its own line rather than
  # silently distributed into a bucket.
  | ([range(0; ($snaps | length)) as $i
      | $snaps[$i] as $s
      | {a: $s.ts, b: (($snaps[$i + 1] | .ts) // $t1),
         free: $s.impl_free, ready: ($s.ready // 0),
         known: ($s.impl_free != null)}
      | . + {tot: (.b - .a)} | . + {paused: ov(.a; .b; $pauses)}
      | . + {act: (.tot - .paused)}]) as $ivs
  | ($ivs | map(.paused) | add // 0) as $paused
  | ($ivs | map(select(.known) | .act) | add // 0) as $covered
  | ($ivs | map(select(.known | not) | .act) | add // 0) as $unknown
  | ($ivs | map(select(.known and .free <= 0) | .act) | add // 0) as $atcap
  | ($ivs | map(select(.known and .free > 0 and .ready == 0) | .act) | add // 0) as $starved
  | ($ivs | map(select(.known and .free > 0 and .ready > 0) | .act) | add // 0) as $slack
  | ($lanes | map(select(.rc == 7))) as $rej
  | ($lanes | map(select(.rc != 0 and .rc != 7))) as $crash
  | ($lanes | map(select(.id | test("-r[0-9]+$")))) as $regate
  | (($rej + $crash + $regate) | unique_by(.id)) as $waste
  | ($waste | map(.secs) | add // 0) as $rework
  # Ticket spans, at wave resolution: first and last snapshot that named it.
  | ([$snaps[] | .ts as $ts | (.tickets // {}) | to_entries[]
      | {id: .key, ts: $ts}]
     | group_by(.id)
     | map({id: .[0].id, first: (map(.ts) | min), last: (map(.ts) | max)})) as $tk
  | ($tk | map(. as $t
      | . + {work: ($lanes
                    | map(select(.id | test("^(impl|gate|merge|repair)-\($t.id)(-|$)")))
                    | map(.secs) | add // 0)}
      | . + {open: (.last - .first)}
      | . + {wait: (.open - .work)})) as $tw
  # P55/D-TICK-13: priced per session from its own log, joined here by id.
  # $spend covers every lane AND wave log this repo has ever kept, so joining
  # against $lanes/$waves -- already scoped to $bw via $evs -- is what
  # excludes sessions from any other build. Waves emit no `lane_exit`, so they
  # join on `stem` (the log basename) instead of `id`.
  | ($spend | map({key: .id, value: .cost}) | from_entries) as $spend_by_id
  | ($lanes | map(. + {cost: ($spend_by_id[.id] // null)})) as $lanes_c
  | ($evs | map(select(.ev == "wave_end"))) as $waves
  | ($waves | map(. + {cost: ($spend_by_id[.stem // ""] // null)})) as $waves_c
  | ($waves_c | map(.cost) | map(select(. != null)) | add // 0) as $wave_cost
  | (($lanes_c | map(.cost) | map(select(. != null)) | add // 0) + $wave_cost) as $total_cost
  | (($lanes_c + $waves_c) | map(select(.cost == null)) | length) as $unknown_costs
  | ($lanes_c | map(select(.cost != null)) | group_by(.type)
     | map({type: .[0].type, cost: (map(.cost) | add // 0)})
     | (if $wave_cost > 0 then . + [{type: "wave", cost: $wave_cost}] else . end)
     | sort_by(-.cost)) as $by_kind
  | ($tw | map(. as $t | . + {cost: ($lanes_c
       | map(select(.id | test("^(impl|gate|merge|repair)-\($t.id)(-|$)")))
       | map(.cost) | map(select(. != null)) | add // 0)})) as $twc
  | ($lanes_c | map(select(.cost != null)) | sort_by(-.cost) | [limit(5; .[])]) as $top
  | ($tk | map({key: .id, value: .last}) | from_entries) as $closed_at
  | (($snaps | map(select((.deps // {}) | length > 0)) | first | .deps) // {}) as $deps
  # Longest dependency chain the graph allowed — what `graph` would have
  # predicted from the same edges, recomputed here so the two are comparable.
  | (reduce range(0; 12) as $_ ({};
       . as $d | reduce ($deps | keys[]) as $k ($d;
         .[$k] = (1 + ([($deps[$k] // [])[] | tostring | ($d[.] // 0)] | max // 0))))) as $depth
  | (($depth | to_entries | map(.value) | max) // 0) as $predicted
  # The chain that actually finished last: walk back from the latest-closing
  # ticket, each step taking the blocker that closed latest. limit() is a cycle
  # guard — a dependency cycle would otherwise recurse forever.
  | (($tw | sort_by(.last) | last) // null) as $tail
  | (if $tail == null then []
     else [limit(20; {id: $tail.id, last: $tail.last}
       | recurse(. as $c
           | [($deps[$c.id] // [])[] | tostring | select($closed_at[.] != null)]
           | max_by($closed_at[.]) | select(. != null)
           | {id: ., last: $closed_at[.]}))] end) as $chain
  | ["Where the capacity went   (sampled at wave cadence, so ±one wave)",
     "",
     "  at capacity    \(hms($atcap))  \(pct($atcap; $covered))   every impl slot busy",
     "  starved        \(hms($starved))  \(pct($starved; $covered))   slots free, nothing ready",
     "  slack          \(hms($slack))  \(pct($slack; $covered))   slots free AND work ready",
     "  blackout       \(hms($paused))  \(pct($paused; ($covered + $paused)))   usage limit"]
  + (if $unknown > 0 then
       ["  unrecorded     \(hms($unknown))          snapshots predating this record"]
     else [] end)
  + (if $slack > 0 then
       ["", "  → slack is capacity that existed, with work waiting for it. Start there."]
     elif $starved > $atcap then
       ["", "  → starvation dominates: the graph, not the lane cap, set the pace."]
     else [] end)
  + ["", "Rework — lane time that produced nothing",
     "",
     "  mechanical rejections  \($rej | length) lane(s)  \(hms($rej | map(.secs) | add // 0))",
     "  crashed lanes          \($crash | length) lane(s)  \(hms($crash | map(.secs) | add // 0))",
     "  re-gates               \($regate | length) lane(s)  \(hms($regate | map(.secs) | add // 0))",
     "  total                  \(hms($rework))  \(pct($rework; $lane_secs)) of all lane time"]
  + ["", "Wait vs work per ticket   (open span minus lane time)", ""]
  + (if ($tw | length) == 0 then ["  nothing recorded"]
     else [$tw | sort_by(-.wait) | limit(10; .[])
           | "  #\(.id)   open \(hms(.open))   work \(hms(.work))   wait \(hms(.wait))"] end)
  + ["", "Spend   (priced from every lane and wave session log)", ""]
  + (if ($lanes_c | length) == 0 and ($waves_c | length) == 0 then ["  nothing recorded"]
     else ["  known total    \(usd($total_cost))"]
          + (if $unknown_costs > 0 then ["  unknown        \($unknown_costs) session(s) — provider reported cost_usd: null"] else [] end)
          + ($by_kind | map("  \(.type)  \(usd(.cost))"))
          + ["", "  top spenders", ""]
          + ($top | map("  \(.id)  \(usd(.cost))"))
          + (if ($twc | map(select(.cost > 0)) | length) == 0 then []
             else ["", "  by ticket"]
                  + [$twc | sort_by(-.cost) | limit(5; .[])
                     | select(.cost > 0) | "  #\(.id)  \(usd(.cost))"] end) end)
  + ["", "The chain that set the length", ""]
  + (if ($chain | length) == 0 then ["  no ticket history recorded"]
     else [($chain | map("#\(.id) at \(hms(.last - $t0))") | join("  ←  ") | "  " + .),
           "",
           "  actual chain \($chain | length) deep; deepest chain in the graph was \($predicted)"]
          + (if ($predicted > ($chain | length)) then
               ["  → the longest path was not what finished last; the schedule, not the graph, bound it."]
             else [] end) end)
  | join("\n")
    end
