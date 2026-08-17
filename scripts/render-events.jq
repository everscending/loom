# render-events.jq — the build ticker: one timestamped, human-readable line
# per event in events.jsonl.
#
# Lifted out of tick.sh (P71), where it lived inline in cmd_render_events as
# a local shell string. In a file it is checkable with
# `jq -L . -n -f render-events.jq </dev/null`.
#
# P72: `stage` — the lane-id split this file used to define — is in lib.jq
# beside this one, included below, opposite its bash mirror `_lane_type`.
#
# Inputs are bound by tick.sh: --arg bad/warn/good/rst (ANSI color codes, ""
# when color is off) and --arg when_mode ("ts" formats the numeric `.ts` with
# strflocaltime; "t" falls back to the pre-rendered `.t` field on a jq old
# enough to lack strflocaltime). when_mode used to be a jq fragment spliced
# into the shell string at the point of use; as a file it is passed in as
# data instead, the way it should have been.
include "lib";
def when:
  if $when_mode == "ts"
  then ((.ts // 0) | strflocaltime("%m-%d %H:%M:%S"))
  else (.t // "") end;
def round($id): (($id | capture("-r(?<n>[0-9]+)$") | " (round \(.n))") // "");
# P31: an escalation the human asked for must be visibly taken. Empty model
# (the lane inherits the session default) renders nothing — the common case
# should stay quiet.
def runtime($e):
  if ($e.provider // "") == "" then ""
  elif $e.provider == "custom" then " (custom)"
  else " (\($e.provider), \(if ($e.tier // "") == "" then "?" else $e.tier end) tier)" end;
fromjson? // empty | . as $e
| (if $e.ev == "snapshot" then empty else . end)
| (
  if   $e.ev == "wave_start" then "wave started"
  elif $e.ev == "wave_end"  then
    (if ($e.rc | tostring) == "0" then "wave ended (rc \($e.rc), \($e.secs)s)"
     else $bad + "✗ wave ended (rc \($e.rc), \($e.secs)s)" + $rst end)
  elif $e.ev == "lane_spawn" then (stage($e.id) | "\(.t) — \(.s) started") + round($e.id) + runtime($e)
  elif $e.ev == "lane_exit" then
    # A clean exit is suppressed (except probes): its story is already told by
    # its outcome event (→ review / verdict / closed), and chained handoffs
    # stamp it after the successor spawned — rendered, that read backwards
    # ("gate started, then implementation ended"; human, 2026-08-02).
    stage($e.id) as $s
    | if ($e.rc | tostring) == "7"
      then $bad + "✗ \($s.t) — pregate REJECTED the branch (no review session spent)" + $rst
      elif ($e.rc | tostring) == "0" and (($e.id | startswith("probe-")) | not)
      then empty
      elif ($e.rc | tostring) == "0"
      then "\($s.t) — \($s.s) ended (rc \($e.rc), \($e.secs)s)"
      else $bad + "✗ \($s.t) — \($s.s) ended (rc \($e.rc), \($e.secs)s)" + $rst end
  elif $e.ev == "lane_kill" then
    stage($e.id) as $s | $warn + "⚠ \($s.t) — \($s.s) killed (whole tree)" + $rst
  elif $e.ev == "ticket_claim" then "#\($e.ticket) claimed — implementation begins"
  elif $e.ev == "ticket_transition" then
    (({"review": " (implementation complete, awaiting gate)",
       "merge-queue": " (gate passed)",
       "blocked": " — a human decision is needed",
       "ready-for-agent": " (requeued, unassigned)"} | .[$e.state]) // "") as $gloss
    | (if $e.state == "blocked"
       then $warn + "⚠ #\($e.ticket) → \($e.state)\($gloss)" + $rst
       else "#\($e.ticket) → \($e.state)\($gloss)" end)
  elif $e.ev == "gate_verdict" then
    (if $e.verdict == "PASS" then $good + "✓ " else $bad + "✗ " end)
    + "#\($e.ticket) gate verdict: \($e.verdict) @ \($e.sha | tostring | .[0:8])" + $rst
  elif $e.ev == "ticket_close" then "#\($e.ticket) merged and closed"
  elif $e.ev == "probe_result" then
    (if $e.result == "PASS"
     then $good + "✓ epic \($e.epic) — acceptance probe PASSED" + $rst
     elif $e.result == "INFRASTRUCTURE"
     then $warn + "⚠ epic \($e.epic) — acceptance probe blocked by infrastructure (no product fix filed)" + $rst
     else $bad + "✗ epic \($e.epic) — acceptance probe FAILED (fix tickets filed)" + $rst end)
  elif $e.ev == "sweep_held" then
    $warn + "⚠ sweep kept \($e.count) worktree(s) — mostly \($e.reason) — each needs a human" + $rst
  elif $e.ev == "sweep_removed" then "sweep removed \($e.count) merged worktree(s)"
  elif $e.ev == "usage_pause" then "usage limit — paused (until \($e.until))"
  elif $e.ev == "usage_resume" then "usage limit cleared — resuming"
  # Three unrelated outcomes shared one sentence (P42). Harmless while the
  # timer was a 15-minute backstop and a skip nearly always meant lock_held;
  # the merged 60s scheduler watches on every firing and spends on the gap, so
  # wave_gap became the routine outcome and printed an exceptional-case line
  # nine ticks in ten. Of 408 such lines in one day, 253 were wave_gap and
  # false: that path writes no pending file and no replay follows it. So
  # wave_gap stays in events.jsonl for retro and never reaches the ticker,
  # lock_held renders once per wave on the tick that raised the flag, and
  # loop_stopped keeps a line of its own because it is rare and specific.
  # (No apostrophes in this comment: the whole program is a single-quoted
  # shell string, and one would end it mid-word.)
  elif $e.ev == "tick_skipped" then
    (if $e.reason == "loop_stopped" then "the loop is stopped — this tick did nothing"
     elif $e.reason == "lock_held" then
       # Events written before P42 carry no "first" field; render those, so
       # replaying an old log still reads the way it did.
       (if (($e.first // "1") | tostring) == "1"
        then "a tick landed during a wave — the wave will re-tick on exit"
        else empty end)
     else empty end)
  elif $e.ev == "tick_replayed" then "pending tick replayed"
  # The renderer owns the "wave:" prefix, so a note that writes its own gets
  # it stripped rather than doubled ("wave: wave: only #47 is ready" —
  # observed by the human, 2026-08-03). A wave author naturally types the
  # prefix; deduping it here is plumbing, and cheaper than a rule telling
  # every wave not to.
  elif $e.ev == "wave_note" then
    "wave: " + (($e.note // "") | sub("(?i)^\\s*wave\\s*:\\s*"; ""))  # mutate:wave-prefix-strip
  elif $e.ev == "pregate_reduced" then
    $warn + "⚠ " + (stage($e.id // "") | "\(.t) — \(.s)")
    + ": \($e.runner // "the gate runner") missing — tier \($e.tier // "?") reduced to review-only (bootstrap not merged)" + $rst
  elif $e.ev == "viewer_note" then "viewer: \($e.note // "")"
  elif $e.ev == "notify" then
    (if (($e.event // "") | test("complete")) then $good else $warn end)
    + "⚑ \($e.title // $e.event)" + $rst
  else ([$e | del(.t, .ts, .ev, .build) | to_entries[] | "\(.key)=\(.value | tostring)"] | join(" ")) as $kv
       | "\($e.ev)\(if $kv == "" then "" else " " + $kv end)"
  end
) as $line
| "\(when)  \($line)"
