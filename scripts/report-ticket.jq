# report-ticket.jq — per-ticket forensics over events.jsonl: every lane that
# touched the ticket, and the states it passed through, with the log path to
# read next.
#
# Lifted out of tick.sh (P71), where it lived as REPORT_TICKET_JQ, a
# single-quoted shell string. In a file it is checkable with
# `jq -L . -n -f report-ticket.jq </dev/null`.
#
# Input is bound by tick.sh: --arg iid (the ticket number); reads the full
# event array via -rs. The prelude include is uniform across every jq program
# here (P72), not a dependency this one has yet.
include "lib";
  ($iid) as $n
  | (map(select(.ev == "lane_spawn" or .ev == "lane_exit"))
     | map(select(.id | test("^(impl|gate|merge)-\($n)(-|$)")))) as $ls
  | (map(select(.ev == "snapshot"))
     | map({ts, t, state: (.tickets[$n] // null)})
     | map(select(.state != null))) as $st
  | if ($ls | length) == 0 and ($st | length) == 0
    then "ticket #\($n): nothing recorded"
    else
  ["ticket #\($n)", ""]
  + (if ($st | length) > 0 then
       ["  states:"] + ([$st[0]] + [$st[1:][] as $x | $x] | . as $all
        | [range(0; ($all | length)) | select(. == 0 or ($all[.].state != $all[.-1].state))
           | "    \($all[.].t)  \($all[.].state)"])
     else [] end)
  + (if ($ls | length) > 0 then
       ["", "  lanes:"]
       + ([$ls | group_by(.id)[]
           | (map(select(.ev == "lane_spawn")) | first) as $s
           | (map(select(.ev == "lane_exit")) | last) as $e
           | "    \($s.id // $e.id)  " +
             (if $e == null then "still running" else "\($e.secs)s  rc \($e.rc)" end) +
             (if $e.rc == 7 then "  (pregate rejection — no review session spent)" else "" end) +
             # P31: which model the round ran on, so an escalation can be
             # priced against its outcome (does the stronger tier actually
             # clear a ticket the base tier failed?). Blank = session default.
             (if ($s.model // "") == "" then "" else "  on \($s.model)" end) +
             "  \($s.log // "")"])
     else [] end)
  | join("\n") end
