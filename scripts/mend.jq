# Contract-grounded observations for the human-run `mend` supervisor.
#
# This program deliberately derives only from snapshot + plan. It does not
# invent scheduler state, infer intent from prose logs, or mutate anything.

include "lib";

def actionable_idle_of($s; $p; $stopped):
  if ($stopped == false)
     and (($s.summary.lanes_running // 0) == 0)
     and (($p.actions // []) | length) > 0
  then [{kind: "actionable-idle", contract: "MEND-FLOW-01",
         action_count: (($p.actions // []) | length),
         first_action: (($p.actions[0] // {})
                        | {step, kind, ticket, lane}),
         boundary: "observe through the next handoff or scheduler heartbeat; diagnose if the action still has not started"}]
  else []
  end;

def attention_of($s; $p; $stopped):
  ([($s.warnings // [])[] |
      {kind: "snapshot-warning", contract: "MEND-STATE-01", message: .}]
   + [($s.tickets // [])[]
      | select((.rejections.total // 0) >= ($s.config.rejection_cap // 2))
      | {kind: "round-three", contract: "MEND-ROUND-01", ticket: .id,
         rejections: (.rejections.total // 0),
         last_class: (.rejections.last_class // null)}]
   + [($s.tickets // [])[]
      | select(.state == "blocked")
      | {kind: "blocked-ticket", contract: "MEND-HOLD-01", ticket: .id,
         category: (.blocked_report.category // null),
         report: (.blocked_report.body // null)}]
   + [($s.lanes // [])[]
      | select(.state == "stale")
      | {kind: "stale-lane", contract: "MEND-LIVE-01", lane: .id,
         type: (.type // "unknown"), turns: (.turns // null)}]
   + [($s.summary.repairs // [])[]
      | {kind: "partial-transition", contract: "MEND-STATE-01", ticket: .id,
         shape: .shape, fix: .fix}]
   + actionable_idle_of($s; $p; $stopped));

$snapshot[0] as $s
| $plan[0] as $p
| {
    schema: 1,
    generated_at: $s.generated_at,
    build: $s.build,
    loop: {stopped: $stopped},
    configuration: {
      max_lanes: $s.config.max_lanes,
      max_aux_lanes: $s.config.max_aux_lanes,
      rejection_cap: $s.config.rejection_cap,
      crash_cap: $s.config.crash_cap,
      heartbeat_stale_minutes: $s.config.heartbeat_stale_minutes,
      min_wave_gap_minutes: ($s.config.min_wave_gap_minutes
                             // ($min_wave_gap | tonumber? // $min_wave_gap)),
      stall_action: ($s.config.stall_action // $stall_action)
    },
    summary: $s.summary,
    lanes: ($s.lanes // []),
    supervised_leases: ($s.supervised_leases // []),
    schedule: {
      reason: ($p.reason // null),
      actions: ($p.actions // []),
      residue: ($p.residue // []),
      deferred: ($p.deferred // [])
    },
    attention: attention_of($s; $p; $stopped)
  }
