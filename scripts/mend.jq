# Contract-grounded observations for the human-run `mend` supervisor.
#
# This program deliberately derives only from snapshot + plan. It does not
# invent scheduler state, infer intent from prose logs, or mutate anything.

include "lib";

def iso_epoch:
  if type == "string"
  then (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?)
  else null end;

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

def lane_ticket_of($id):
  $id | sub("^(impl|repair|gate|merge)-"; "") | sub("-r[0-9]+$"; "");

def expected_owner_of($state):
  if $state == "in-progress" then "impl"
  elif $state == "review" then "gate"
  elif $state == "merge-queue" then "merge"
  else null
  end;

# A busy build can still have a silent gap in one flow stage. In particular,
# an unrelated implementation must not hide an eligible review or merge queue
# whose owning lane never started. This is an observation only: the ordinary
# scheduler remains the sole owner of launch decisions.
def unowned_stages_of($s; $p; $stopped):
  if $stopped then []
  else
    [($s.tickets // [])[]
     | . as $ticket
     | expected_owner_of(.state) as $owner
     | select($owner != null and .supervised_lease == null)
     | select(any(($s.lanes // [])[];
                  .state == "running"
                  and .type == $owner
                  and lane_ticket_of(.id) == ($ticket.id | tostring)) | not)
     | {kind: "unowned-stage", contract: "MEND-FLOW-01",
        ticket: .id, state: .state, expected_owner: $owner,
        scheduled: [($p.actions // [])[] | select(.ticket == $ticket.id)],
        deferred: [($p.deferred // [])[] | select(.ticket == $ticket.id)],
        residue: [($p.residue // [])[] | select(.ticket == $ticket.id)],
        boundary: "observe through the next handoff or scheduler heartbeat; diagnose if the owning lane still has not started"}]
  end;

# Mend does not construct or dispatch the repair queue. It audits the
# dispositions already derived by the start-owned planner: scheduled repair,
# capacity deferral, active lease/lane, or explicit awaiting-human state.
def supervision_audit_of($s; $p; $stopped; $armed):
  ([($p.actions // [])[]
    | select(.step == "supervise" and .kind == "spawn")
    | {ticket, lane, block_token, dependency_impact, direct_dependents}]) as $candidates
  | ([($p.deferred // [])[]
      | select(.step == "supervise" and .kind == "awaiting-human")
      | .ticket]) as $awaiting
  | ([($p.deferred // [])[]
      | select(.step == "supervise" and (.kind == "capacity" or .kind == "ui-resource"))
      | .ticket]) as $capacity
  | (($s.generated_at | iso_epoch) // 0) as $now
  | ([$candidates[]
      | select((.block_token | iso_epoch) as $at
               | $at == null or $now == 0 or ($now - $at) > 120)
      | .ticket]) as $candidate_gaps
  | ([($s.tickets // [])[]
      | select(.state == "blocked")
      | . as $ticket
      | ($ticket.id) as $iid
      | select(
          (($candidates | map(.ticket) | index($iid)) == null)
          and (($awaiting | index($iid)) == null)
          and (($capacity | index($iid)) == null)
          and .supervised_lease == null
          and (any(($s.lanes // [])[];
                   .state == "running"
                   and .type == "repair"
                   and lane_ticket_of(.id) == ($ticket.id | tostring)) | not))
      | .id] + $candidate_gaps | unique) as $gaps
  | {policy: ($s.build.supervision_policy // null),
     scheduler_armed: $armed,
     candidates: $candidates,
     awaiting_human: $awaiting,
     capacity_deferred: $capacity,
     ownership_gaps: $gaps,
     assertion:
       (if $stopped then "stopped"
        elif ($s.build.supervision_policy // null) != "autonomous-repair-v1"
        then "fail"
        elif ($armed | not) then "fail"
        elif ($gaps | length) > 0 then "fail"
        else "pass" end)};

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
   + unowned_stages_of($s; $p; $stopped)
   + actionable_idle_of($s; $p; $stopped));

$snapshot[0] as $s
| $plan[0] as $p
| supervision_audit_of($s; $p; $stopped; $armed) as $supervision
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
    supervision: $supervision,
    attention: attention_of($s; $p; $stopped)
  }
