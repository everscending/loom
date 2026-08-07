# report.jq — the build-wide view over events.jsonl: span, wave/lane time,
# usage blackout, peak concurrency, lanes by type, and mechanical outcomes.
# One of two views `report` composes over the one event log (see
# report-ticket.jq for the per-ticket view); neither reads anything but
# events.jsonl, so a report costs no tracker calls and works long after a
# build is over.
#
# Lifted out of tick.sh (P71), where it lived as REPORT_JQ, a single-quoted
# shell string. In a file it is checkable with `jq -n -f report.jq </dev/null`.
#
# Input is bound by tick.sh: --arg build_want (a build label to filter on,
# "" for every build in the log); reads the full event array via -rs.
  def hms($s): ($s // 0) as $x
    | if $x >= 3600 then "\($x / 3600 | floor)h\(($x % 3600) / 60 | floor)m"
      elif $x >= 60 then "\($x / 60 | floor)m\($x % 60)s" else "\($x)s" end;
  def pct($n; $d): if ($d // 0) == 0 then "  -  "
                   else "\(($n * 1000 / $d | round) / 10)%" end;
  ($build_want) as $bw
  | map(select($bw == "" or .build == $bw)) as $evs
  | if ($evs | length) == 0 then "no events recorded\($bw | if . == "" then "" else " for \(.)" end)"
    else
  ($evs | map(.build) | map(select(. != null)) | last // "(unlabelled)") as $blabel
  | ($evs | map(.ts) | min) as $t0 | ($evs | map(.ts) | max) as $t1
  | ($t1 - $t0) as $span
  | ($evs | map(select(.ev == "wave_end"))) as $waves
  | ($evs | map(select(.ev == "lane_exit"))) as $lanes
  | ($waves | map(.secs) | add // 0) as $wave_secs
  | ($lanes | map(.secs) | add // 0) as $lane_secs
  # Blackout: each pause runs to its own resume, or to the last event if the
  # build never resumed. Counted from the events, not from the clock.
  | ([$evs | to_entries[] | select(.value.ev == "usage_pause")
      | .key as $i | .value.ts as $pt
      | (($evs[$i+1:] | map(select(.ev == "usage_resume")) | first | .ts) // $t1) - $pt]
     | add // 0) as $black
  # Peak concurrency by sweep: +1 on spawn, -1 on exit, ordered by time.
  | ([$evs | map(select(.ev == "lane_spawn" or .ev == "lane_exit"))
      | sort_by(.ts)[] | if .ev == "lane_spawn" then 1 else -1 end]
     | reduce .[] as $d ({n: 0, peak: 0};
         (.n + $d) as $x | {n: $x, peak: (if $x > .peak then $x else .peak end)})
     | .peak) as $peak
  | ($evs | map(select(.ev == "snapshot"))) as $snaps
  | (($snaps | first | .tickets | keys?) // []) as $first_ids
  | (($snaps | last  | .tickets | keys?) // []) as $last_ids
  | ($first_ids | map(select(. as $i | ($last_ids | index($i)) == null)) | length) as $closed
  | [ "Build \($blabel)   span \(hms($span))   \($closed) ticket(s) closed",
      "",
      "  inside waves   \(hms($wave_secs))   \(pct($wave_secs; $span))   \($waves | length) wave(s), \($waves | map(select(.rc != 0)) | length) failed, \($evs | map(select(.ev == "wave_start" and .retry == 1)) | length) retried",
      "  lane-seconds   \(hms($lane_secs))   \(pct($lane_secs; $span))   \($lanes | length) lane(s), peak \($peak) concurrent",
      "  usage blackout \(hms($black))   \(pct($black; $span))   \($evs | map(select(.ev == "usage_pause")) | length) pause(s)",
      "",
      "  lanes by type  " + (if ($lanes | length) == 0 then "none"
                             else ($lanes | group_by(.type)
                                   | map("\(.[0].type // "?")=\(length)") | join("  ")) end),
      "  mechanical rejections (rc 7)   \($lanes | map(select(.rc == 7)) | length)",
      "  crashed lanes (rc not 0 or 7)  \($lanes | map(select(.rc != 0 and .rc != 7)) | length)",
      "  ticks skipped mid-wave \($evs | map(select(.ev == "tick_skipped")) | length), replayed \($evs | map(select(.ev == "tick_replayed")) | length)"
    ] | join("\n")
    end
