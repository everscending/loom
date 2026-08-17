# Contract-grounded observations for the human-run `mend` supervisor.
#
# This program deliberately derives only from snapshot + plan. It does not
# invent scheduler state, infer intent from prose logs, or mutate anything.

include "lib";

def attention_of($s):
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
         shape: .shape, fix: .fix}]);

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
      min_wave_gap_minutes: $s.config.min_wave_gap_minutes,
      stall_action: $s.config.stall_action
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
    attention: attention_of($s)
  }
