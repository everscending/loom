# plan.jq — the wave's schedule, derived from the snapshot (P81).
#
# Steps 2–6 of SKILL.md's `tick` used to be a decision table written in prose
# for a model session to follow. Every input to that table is already in the
# snapshot document, computed deterministically: `gate.eligible` with its
# `reason`, `summary.stranded`, `summary.impl_slots_free`,
# `summary.merge_in_flight`, `.merge_hold`, `.merge_attempts`,
# `rejections.total`, `.tier_selection.effective`,
# `summary.epics_awaiting_probe`. Reading those fields and applying the rules
# adds no information the document does not already carry — and it cost a full
# model session between "a ticket became ready" and "a lane exists for it"
# (seat-reservations build-1: 36 waves, 1h29m, 57.5% of a 2h35m span, 2m28s
# each; boostlingo build-1: wave sessions $683 of $3,404).
#
# Input: one snapshot document (`tick.sh snapshot [--brief]`), on stdin.
# Output: one plan document —
#   .actions[]  what to do, in the order SKILL.md's steps prescribe. Each
#               names the verb that owns the write (`via` + `argv`) or, for a
#               spawn, everything `spawn-lane` needs but the brief.
#   .residue[]  the items that need prose a script cannot write: a rejection
#               read off a lane log, a blocked report, a completion report.
#   .deferred[] what was NOT scheduled and why — a cap, a hold, an id
#               `spawn-lane` would refuse. Silent truncation reads as
#               "everything is scheduled" when it is not.
#   .reason     why the plan is empty, when it is. Never a partial plan.
#
# DERIVES, NEVER WRITES. `tick.sh` is read-only against the tracker and
# `scripts/tests/07-snapshot.sh` enforces it by scanning every captured argv;
# section 28 extends that scan to this code path. An action here is an
# instruction for the executor, and the executor is `tick.sh spawn-lane` and
# the `lane.sh` verb that owns each write — never this program.
#
# The plan is derived and disposable, exactly like the snapshot it reads: it
# is never written anywhere a later run reads it back as state (constitution
# rule 1 — a plan file that outlived its wave would be the shadow state that
# rule forbids).

include "lib";

# ---------------------------------------------------------------------------
# Lane ids. `spawn-lane` refuses an id outside `A-Za-z0-9_-` (lane state is a
# space-delimited format, so an id with a space corrupts every reader of it)
# and refuses one `_lane_type` cannot classify. An action naming an id that
# would be refused is a PLANNER bug, so it is caught here, at plan time,
# rather than by a lane that dies at spawn time: such a candidate becomes a
# `deferred` entry naming the id. (paid: `probe-Ledger core` parsed as
# {id: "probe-Ledger", pid: "core", state: "<pid>"} and counted as a live lane
# for the rest of the build.)
def spawnable($id):
    ($id | type) == "string"
    and ($id | test("^[A-Za-z0-9_-]+$"))
    and ($id | test("^(impl|gate|merge)-[0-9]+(-r[0-9]+)?$")
            or test("^probe-[A-Za-z0-9][A-Za-z0-9_-]*$"));

# The ticket a lane belongs to, as a string; a probe id yields itself and
# never matches a ticket. Same split as snapshot.jq's `$working` and lib.jq's
# `stage` — one shape of id, read the same way everywhere.
def lane_ticket($id): $id | sub("^(impl|gate|merge)-"; "") | sub("-r[0-9]+$"; "");
def lane_round($id): (($id | capture("-r(?<n>[0-9]+)$") | .n | tonumber) // 1);
def lease_why:
    "supervised repair lease owned by \(.supervised_lease.owner) until epoch \(.supervised_lease.expires_at) — ordinary implementation, gate and merge launches wait for release or expiry";

def empty_plan($gen; $build; $reason):
    { generated_at: $gen, build: $build, reason: $reason,
      actions: [], residue: [], deferred: [], supervised_leases: [] };

# ---------------------------------------------------------------------------
# A snapshot the planner cannot read produces an empty plan and a named
# reason, never a partial one: a plan built from half a document schedules
# against half a board, and every rule below is total only over the whole one.
if . == null then
    empty_plan(null; null;
        "no snapshot document was readable on stdin — re-run `tick.sh snapshot --brief` and pipe it in")
elif (type != "object") or (has("tickets") and has("lanes") and has("summary") | not) then
    empty_plan(null; null;
        "the input is not a loom snapshot document (no .tickets / .lanes / .summary) — the planner never guesses")
elif (.build == null) then
    empty_plan(.generated_at; null;
        "no open `Build N` issue — empty universe, nothing to schedule")
elif ((.build.provider // "") == "") then
    empty_plan(.generated_at; .build;
        "Build issue has no single provider:: label — provider identity must be tracker-resident before scheduling")
elif any(.tickets[]?; ((.tier_selection.invalid_labels // []) | length) > 0) then
    empty_plan(.generated_at; .build;
        "a ticket carries a provider-native or legacy model:: label — choose model::medium or model::high explicitly before scheduling")
else

. as $s
| ($s.config // {}) as $cfg
| ($s.tickets // []) as $tickets
| ($s.lanes // []) as $lanes
| ($s.summary // {}) as $sum
| ($s.epics // []) as $epics
| ($s.build.provider // null) as $provider
| (($cfg.lane_turn_cap | tonumber?) // 150) as $turn_cap
| (($cfg.merge_attempt_cap | tonumber?) // 2) as $merge_cap
| (($cfg.max_aux_lanes | tonumber?) // 4) as $aux_cap
| (($cfg.rejection_cap | tonumber?) // 2) as $rejection_cap
| (($sum.impl_slots_free | tonumber?) // 0) as $impl_free
| ($cfg.lane_tier // "medium") as $lane_tier
| ($s.logs_dir // "") as $logs
| ([ $tickets[]
     | ([.related_merge_requests[]? | select(.state == "merged")] | first) as $mr
     | select($mr != null)
     | { ticket: .id, mr: $mr.id, sha: $mr.sha,
         verdict: (.merged_verdict.verdict // null),
         class: (.merged_verdict.class // null) } ]) as $merged_open

# One lookup, so every rule below reads the same row for the same ticket.
| def ticket($iid): ($tickets | map(select((.id | tostring) == ($iid | tostring))) | first);
  # Plans are immutable for one wave, but tracker state can change while the
  # provider is still executing them. Every planned transition carries the
  # source state this snapshot observed; lane.sh compares it live before the
  # write. `unlabeled` preserves the same fail-closed rule for a repair whose
  # source has no Loom state label.
  def transition_argv($iid; $target):
      ["transition", ($iid | tostring), $target, "--if-current",
       (ticket($iid).state // "unlabeled")];

# `blocked-report` and `transition … blocked` are two tracker writes. If the
# first lands and the lane dies (or a provider stops after reporting), the
# report itself is durable proof that the second write is still owed. Treat
# that half-transition like the other repairable shapes, never like a fresh
# merge failure or another runnable ticket. (paid: #136 reported a Linear
# rate-limit base defect, exited rc 0 in merge-queue, and was scheduled to run
# the same six-minute gate again.)
  ([ $tickets[]
     | select(.state != "blocked" and .blocked_report != null
              and ((.blocked_report.released // false) == false)) ]) as $reported_blocks
| ([ $reported_blocks[] | .id ]) as $reported_block_ids

# =========================================================================
# Step 2 — harvest. The lane states are already classified by `lane-status`
# (running / stale / dead) and carried in `.lanes[]` with their rc and turn
# count, so which lanes need what is arithmetic, not judgement.
# =========================================================================

# `stale` = alive but no real progress. ALWAYS `kill-lane`, never a bare kill:
# that orphans the agent session inside, which keeps pushing. (paid: a ticket
# merged through a human hold that way.) The ticket it held becomes stranded,
# and the rework path picks it up on the next plan — after the write, when the
# snapshot has been re-read.
| ([ $lanes[] | select(.state == "stale" and lane_holds_capacity)
     | { step: "harvest", kind: "kill-lane", lane: .id, ticket: (lane_ticket(.id)),
         via: "tick.sh", argv: ["kill-lane", .id],
         why: "lane is stale — alive but no real progress; a bare kill would orphan the session inside it" } ])
  as $kill_stale

# `running` past `lane_turn_cap` is effort, not progress — treated exactly the
# way a spent rejection cap is: kill, then block for a human. (paid: impl-43
# ran 456 turns, ~$300, with nothing watching the cost.)
| ([ $lanes[] | select(.state == "running" and lane_holds_capacity
                       and ((.turns | tonumber?) // 0) > $turn_cap) ]) as $overrun
| ([ $overrun[]
     | { step: "harvest", kind: "kill-lane", lane: .id, ticket: (lane_ticket(.id)),
         via: "tick.sh", argv: ["kill-lane", .id],
         why: "lane has taken \(.turns) turns against a cap of \($turn_cap) — that is effort, not progress" } ])
  as $kill_overrun
| ([ $overrun[] | select(ticket(lane_ticket(.id)) != null)
     | { step: "harvest", kind: "transition", lane: .id, ticket: (lane_ticket(.id) | tonumber),
         via: "lane.sh", argv: transition_argv(lane_ticket(.id); "blocked"),
         why: "turn cap spent — a ticket that needs this many turns was written too big or the lane is lost; the next step is a human decision",
         needs_report: true } ])
  as $block_overrun

# Every dead or provider-complete lane is cleared. A provider may have written
# rc/outcome while its host epilogue still owns the pid; that lane is finished
# work and cleanup-eligible even though process liveness still protects it from
# duplicate reuse until this ordered clear runs.
| ([ $lanes[] | select(lane_cleanup_eligible)
     | . as $l | (lane_ticket(.id)) as $tk
     | { step: "harvest", kind: "clear-lane", lane: .id, ticket: $tk,
         via: "tick.sh", argv: ["clear-lane", .id],
         why: (if .rc == "7" then "pregate rejected the branch (rc 7) — the lane is finished with it"
               elif .type == "gate" and .rc == "0" and ((ticket($tk).gate.eligible // false))
               then "gate exited rc 0 with no verdict standing at HEAD — respawn it a round on"
               else "lane is dead or provider-complete — clear its bookkeeping" end) } ])
  as $clear_dead

# The two half-finished shapes, each carrying the ONE command that repairs it.
# `snapshot.jq` located them (P63); the plan is where they stop being a warning
# a wave has to notice and become work with a place in the order.
| ([ ($sum.repairs // [])[]
     | . as $repair
     | (.fix | ltrimstr("lane.sh ") | split(" ")) as $argv
     | { step: "harvest", kind: "repair", ticket: .id,
         via: "lane.sh",
         argv: (if $argv[0] == "transition"
                then $argv + ["--if-current", (ticket($repair.id).state // "unlabeled")]
                else $argv end),
         why: "\(.shape) — a lane died between its two writes" } ])
  as $repairs
| ([ $reported_blocks[]
     | { step: "harvest", kind: "repair", ticket: .id,
         via: "lane.sh", argv: transition_argv(.id; "blocked"),
         report_already_present: true,
         why: "an unreleased blocked report landed while the ticket stayed `\(.state // "unlabeled")` — finish the second half of that tracker transition" } ])
  as $blocked_repairs

# rc 7 is its pregate's rejection, not a crash: the verdict is posted straight
# from the lane log, with no verifier spawned. The log is prose only a reader
# can turn into a rejection comment, so it is residue by construction.
| ([ $lanes[] | select(lane_cleanup_eligible and .rc == "7")
     | select(ticket(lane_ticket(.id)) != null)
     | ((.head // "")
        | if type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$") then . else null end) as $head
     | (lane_ticket(.id) | tonumber) as $iid
     | { kind: "pregate-rejection", ticket: $iid, lane: .id, sha: $head,
         log: "\($logs)/lane-\(.id).log",
         why: (if $head != null
               then "rc 7 = the pregate rejected the branch at immutable launch HEAD \($head), not a crash — post the rejection from the lane log, no verifier"
               else "rc 7 says the pregate rejected, but this lane has no immutable launch HEAD — refuse classification; never substitute the mutable worktree HEAD" end),
         verb: (if $head != null
                then "lane.sh verdict \($iid) fail \($head) --class <slug> (reuse the previous class when it is the same failure)"
                else null end) } ])
  as $res_pregate

# A dead merge lane whose ticket is still `merge-queue` did not merge — but
# `merge-queue` in the snapshot is NOT evidence of that. Chained lanes land
# while a wave is mid-flight, so the ticket is re-read LIVE before anything is
# written. (paid: #23 merged at 22:23:17 and was blocked at 22:24:29 by a wave
# harvesting against a photograph taken 90 seconds before the merge.)
| ([ $lanes[] | select(lane_cleanup_eligible and .type == "merge")
     | select((.outcome // "none") != "merge-failed")
     | select((ticket(lane_ticket(.id)).state // "") == "merge-queue")
     | (lane_ticket(.id) | tonumber) as $iid
     | select(($reported_block_ids | index($iid)) == null)
     | { kind: "merge-failed", ticket: $iid, lane: .id,
         log: "\($logs)/lane-\(.id).log",
         attempts: (ticket($iid).merge_attempts // 0), cap: $merge_cap,
         why: "a dead merge lane whose ticket is still `merge-queue` — re-check the ticket LIVE first; `merge-queue` in a snapshot is not evidence it did not merge",
         verb: "lane.sh merge-failed \($iid) (body: what it died on)" } ])
  as $res_merge_failed

# =========================================================================
# Step 3 — gate. Only where `gate.eligible`, never merely "in review": the
# snapshot has already dropped tickets whose MR merged underneath and HEADs an
# existing verdict covers. (paid: a 12m53s verifier FAILED code that had
# merged 95 seconds earlier; another ticket was gated twice at one commit.)
# =========================================================================

| ($lanes | map(select(lane_holds_capacity
                       and (.type == "gate" or .type == "merge" or .type == "probe")))
          | length) as $aux_alive
| (($aux_cap - $aux_alive) | if . < 0 then 0 else . end) as $aux_free

# The round number comes off the lane ids already spawned for this ticket, so
# a respawn can never overwrite a live lane's pid file or rotate its log away.
| def gate_lane($iid):
      ([ $lanes[] | select(.type == "gate" and lane_ticket(.id) == ($iid | tostring))
                  | lane_round(.id) ] | max) as $r
    | if $r == null then "gate-\($iid)" else "gate-\($iid)-r\($r + 1)" end;

  ([ $tickets[] | select(.gate.eligible // false) ] | sort_by(.id)) as $gate_candidates
| ([ $gate_candidates[] | select(.supervised_lease != null) ]) as $gate_leased
| ([ $gate_candidates[] | select(.supervised_lease == null) ]) as $gate_all
| ($gate_all[0:$aux_free]) as $gate_take
| ([ $gate_take[]
     | (gate_lane(.id)) as $lid
     | select(spawnable($lid))
     | { step: "gate", kind: "spawn", lane: $lid, ticket: .id,
         spawn: { id: $lid, type: "gate", provider: $provider, tier: $lane_tier, pregate: .tier,
                  merge_lock: false,
                  cwd_from: "the ticket's existing lane worktree (MR branch \(([.related_merge_requests[] | select(.state == "open") | .branch] | first) // "unknown"))",
                  brief: { step: 3,
                           active_scope_reset: (.active_scope_reset // null),
                           active_supervised_repair: (.active_supervised_repair // null),
                           inputs: ["ticket #\(.id) body and its `PRD requirement`",
                                    "the active scope reset in this action, when non-null — it replaces conflicting original ticket and PRD review requirements",
                                    "the active supervised repair in this action, when non-null — evidence of valid defects repaired since the retired gate history",
                                    "the open MR at HEAD \(.gate.head // "unknown")",
                                    "the merge spawn line to run on a PASS"] } },
         why: "gate.eligible — in `review`, an open MR, and no verdict standing at this HEAD" } ])
  as $gate_actions
| ([ $gate_leased[] | { step: "gate", ticket: .id, why: lease_why } ]
   + [ $gate_take[] | (gate_lane(.id)) as $lid | select(spawnable($lid) | not)
     | { step: "gate", ticket: .id, lane: $lid,
         why: "lane id `\($lid)` is not one `spawn-lane` accepts — a planner bug, not a lane failure" } ]
   + [ $gate_all[$aux_free:][]
     | { step: "gate", ticket: .id,
         why: "no aux slot free (\($aux_alive) of \($aux_cap) held by gates, merges and probes)" } ])
  as $gate_deferred
| (($aux_free - ($gate_actions | length)) | if . < 0 then 0 else . end) as $aux_left

# =========================================================================
# Step 4 — fill lanes, REWORK BEFORE NEW WORK. `summary.stranded` is where
# every gate rejection lands (verdict fail → in-progress, assignee kept) and
# no other step looks: harvest reads lanes, gate needs `review`, the ready set
# needs unclaimed. (paid: gate-FAILed tickets stranded while fresh backlog
# tickets took the slots.)
# =========================================================================

# A ticket with a repair standing against it is left alone by both fill paths.
# Its label is one write behind what already happened (an MR is open, or a
# PASS is on the thread), so the repair above moves it to the state it is
# really in — and a lane spawned from the stale label would be working on a
# ticket that has already left this step. (paid: the P63 shapes, four
# stranded finishes in one build.)
| (([ ($sum.repairs // [])[] | .id ]) + $reported_block_ids) as $repairing
| ([ ($sum.stranded // [])[] | ticket(.) | select(. != null)
     | select(.id as $i | ($repairing | index($i)) == null) ] | sort_by(.id)) as $stranded_candidates
| ([ $stranded_candidates[] | select(.supervised_lease != null) ]) as $stranded_leased
| ([ $stranded_candidates[] | select(.supervised_lease == null) ]) as $stranded

# Two rejections mean stop, not respawn: round three needs diagnosis even when
# the failure classes differ. Alternating labels are not evidence of healthy
# convergence; JOR-220 reached round six by oscillating between an exact 204
# contract, the central response guard, and ticket scope.
| ([ $stranded[] | select((.rejections.total // 0) >= $rejection_cap) ]) as $rejection_spent  # mutate:rejection-total-cap
| ([ $rejection_spent[]
     | { step: "fill", kind: "transition", ticket: .id,
         via: "lane.sh", argv: transition_argv(.id; "blocked"),
         why: "\(.rejections.total) gate rejections reached the cap of \($rejection_cap) — round three needs diagnosis, rescope, or prerequisite work instead of another automatic guess",
         needs_report: true } ])
  as $block_rejections

| ([ $stranded[] | select((.rejections.total // 0) < $rejection_cap) ]) as $rework
# Then the backlog. Ready means unblocked (every blocker issue closed, not
# merely opened — auto-merge is async), unclaimed, and a member of this build;
# `fix: true` tickets come first, because every open fix ticket holds an
# epic's re-probe hostage. Ties break on iid, oldest first — a total order, so
# two plans over one snapshot are the same plan.
| ([ $tickets[] | select(.state == "ready-for-agent" and (.unblocked // false)
                         and ((.assignees | length) == 0))
                | select(.id as $i | ($repairing | index($i)) == null) ]
   | sort_by([(if .fix then 0 else 1 end), .id])) as $ready_candidates
| ([ $ready_candidates[] | select(.supervised_lease != null) ]) as $ready_leased
| ([ $ready_candidates[] | select(.supervised_lease == null) ]) as $ready

| ($rework[0:$impl_free]) as $rework_take
| (($impl_free - ($rework_take | length)) | if . < 0 then 0 else . end) as $impl_left
| ($ready[0:$impl_left]) as $ready_take

| ([ $rework_take[]
     | ("impl-\(.id)") as $lid
     | select(spawnable($lid))
     | { step: "fill", kind: "spawn", lane: $lid, ticket: .id,
         spawn: { id: $lid, type: "implementation", provider: $provider, tier: (.tier_selection.effective), pregate: null,
                  merge_lock: false,
                  cwd_from: "the ticket's SURVIVING worktree — this is a respawn, not a new lane",
                  brief: { step: 4,
                           active_scope_reset: (.active_scope_reset // null),
                           active_supervised_repair: (.active_supervised_repair // null),
                           inputs: ["ticket #\(.id) body",
                                    "the active scope reset in this action, when non-null — it overrides conflicting original ticket scope",
                                    "the active supervised repair in this action, when non-null — verified repair evidence that later rework must preserve",
                                    "the latest rejection comment on #\(.id)",
                                    "the build lessons thread"] } },
         why: "stranded rework (round \((.rejections.total // 0) + 1), tier source `\(.tier_selection.source)`) — closest to done and its rejection cap is already counting" } ]
   + [ $ready_take[]
     | ("impl-\(.id)") as $lid
     | select(spawnable($lid))
     | { step: "fill", kind: "spawn", lane: $lid, ticket: .id,
         spawn: { id: $lid, type: "implementation", provider: $provider, tier: (.tier_selection.effective), pregate: null,
                  merge_lock: false,
                  prepare: {via:"worktree.sh", argv:["prepare","--repo","<repo-root>","--ticket",(.id|tostring),"--base",($cfg.base // "<base>")]},
                  cwd_from: "the absolute path returned by the deterministic prepare operation",
                  brief: { step: 4,
                           active_scope_reset: (.active_scope_reset // null),
                           active_supervised_repair: (.active_supervised_repair // null),
                           inputs: ["ticket #\(.id) body",
                                    "the active scope reset in this action, when non-null — it overrides conflicting original ticket scope",
                                    "the active supervised repair in this action, when non-null — verified repair evidence that later work must preserve",
                                    "the build lessons thread"] } },
         claim_first: true,
         why: (if .fix then "ready `fix:` ticket — fix tickets outrank the rest of the ready set"
               else "ready, unblocked and unclaimed" end) } ])
  as $fill_actions
| ([ ($stranded_leased + $ready_leased)[]
     | { step: "fill", ticket: .id, why: lease_why } ]
   + [ ($rework[$impl_free:] + $ready[$impl_left:])[]
     | { step: "fill", ticket: .id,
         why: "no implementation slot free (`summary.impl_slots_free` was \($impl_free))" } ])
  as $fill_deferred

# =========================================================================
# Step 5 — merge queue. After the fill, so a ticket ready at wave start does
# not wait out a whole merge before its worktree exists. The OLDEST
# `merge-queue` ticket whose `.merge_hold` is null; a second merge is refused
# while one is in flight.
# =========================================================================

| ([ $tickets[] | select(.state == "merge-queue")
                   | select(.id as $i | ($reported_block_ids | index($i)) == null) ]
   | sort_by(.id)) as $queue
| ([ $queue[] | select(.supervised_lease != null) ]) as $merge_leased
| ([ $queue[] | select(.supervised_lease == null) ]) as $merge_available
# At `merge_attempt_cap` recorded attempts, stop retrying that ticket: block
# it so the queue ADVANCES to the next-oldest instead of feeding every later
# lane into the same wall. (paid: three consecutive lanes wedged on one ticket
# while two gate-passed tickets waited behind it.) Attempts recorded
# `base-red` never count — `snapshot.jq` already excludes them.
| ([ $merge_available[] | select((.merge_attempts // 0) >= $merge_cap)  # mutate:merge-attempt-cap
     | { step: "merge", kind: "transition", ticket: .id,
         via: "lane.sh", argv: transition_argv(.id; "blocked"),
         why: "\(.merge_attempts) merge attempts against a cap of \($merge_cap) — blocking it advances the queue instead of feeding the next lane into the same wall",
         needs_report: true } ])
  as $block_merge_cap
| ([ $merge_available[] | select((.merge_attempts // 0) < $merge_cap and .merge_hold == null) ] | first)
  as $merge_head
| (if ($sum.merge_in_flight // false) or $merge_head == null or $aux_left < 1 then []
   else [ $merge_head
          | ("merge-\(.id)") as $lid
          | select(spawnable($lid))
          | { step: "merge", kind: "spawn", lane: $lid, ticket: .id,
              spawn: { id: $lid, type: "merge", provider: $provider, tier: $lane_tier, pregate: .tier,
                       merge_lock: true,
                       cwd_from: "the ticket's existing lane worktree (MR branch \(([.related_merge_requests[] | select(.state == "open") | .branch] | first) // "unknown"))",
                       brief: { step: 5,
                                inputs: ["ticket #\(.id) and its open MR",
                                         "the integration base `\($cfg.base // "<declared base, else develop, else main>")`"] } },
              why: "oldest `merge-queue` ticket with no merge hold" } ]
   end) as $merge_actions
| ([ $merge_leased[]
     | { step: "merge", ticket: .id, why: lease_why } ]
   + [ $merge_available[] | select(.merge_hold != null)
     | { step: "merge", ticket: .id,
         why: "parked behind an open base-red fix (\(.merge_hold.fixes | map("#\(.)") | join(", "))) — it re-enters the queue on its own when the fix merges" } ]
   + (if ($sum.merge_in_flight // false)
      then [ { step: "merge",
               why: "a merge lane already holds the merge lock — a second merge waits" } ]
      elif $merge_head != null and $aux_left < 1
      then [ { step: "merge", ticket: $merge_head.id,
               why: "no aux slot free (\($aux_alive) of \($aux_cap) held by gates, merges and probes)" } ]
      else [] end))
  as $merge_deferred
| (($aux_left - ($merge_actions | length)) | if . < 0 then 0 else . end) as $aux_left2

# =========================================================================
# Step 6 — epic acceptance. `summary.epics_awaiting_probe` is a LEVEL, re-read
# every wave: all members closed, milestone still open. An epic with zero open
# tickets is in it. (paid: build-2 closed over three unprobed epics; E4 hit
# zero open tickets six times with the list empty each time.)
# =========================================================================

| ([ ($sum.epics_awaiting_probe // [])[] as $n
     | ($epics | map(select(.name == $n)) | first) // {name: $n, acceptance: null, milestone: null} ])
  as $probe_epics
# A probe with no acceptance criteria can only enumerate past defects, and a
# probe that only re-tests past defects cannot catch what nobody has broken
# yet. That is a brief to WRITE, not a lane to spawn. (paid: E4 failed five
# straight probes, every brief enumerated backwards from the last round.)
| ([ $probe_epics[] | select(.acceptance == null)
     | { kind: "probe-criteria", epic: .name,
         why: "ready to probe but its milestone carries no `## Acceptance criteria` — write them first; a brief written from the defect history alone cannot catch what nobody has broken yet",
         verb: "author the criteria on milestone `\(.milestone // .name)`, then probe" } ])
  as $res_probe_criteria
| ([ $probe_epics[] | select(.acceptance != null) ][0:$aux_left2]) as $probe_take
| ([ $probe_take[]
     | ("probe-" + ((.milestone // .name) | epic_norm)) as $lid
     | select(spawnable($lid))
     | { step: "probe", kind: "spawn", lane: $lid, epic: .name,
         spawn: { id: $lid, type: "probe", provider: $provider, tier: $lane_tier, pregate: null,
                  merge_lock: false,
                  prepare: {via:"worktree.sh", argv:["prepare","--repo","<repo-root>","--key",$lid,"--base",($cfg.base // "<base>")]},
                  cwd_from: "the absolute path returned by the deterministic prepare operation",
                  brief: { step: 6,
                           inputs: ["the epic's `## Acceptance criteria` (.epics[].acceptance)",
                                    "targeted regression checks for defects this epic has already produced"] } },
         why: "every member ticket closed and the milestone is still open — the build is not complete until a probe passes on it" } ])
  as $probe_actions
| ([ $probe_take[] | ("probe-" + ((.milestone // .name) | epic_norm)) as $lid
     | select(spawnable($lid) | not)
     | { step: "probe", epic: .name, lane: $lid,
         why: "epic slug `\($lid)` is not a lane id `spawn-lane` accepts — slugify the epic title, then probe" } ]
   + [ ([ $probe_epics[] | select(.acceptance != null) ][$aux_left2:])[]
     | { step: "probe", epic: .name,
         why: "no aux slot free (\($aux_alive) of \($aux_cap) held by gates, merges and probes)" } ])
  as $probe_deferred

# =========================================================================
# The residue a blocked ticket needs, and the two reports that end a build.
# Every `transition … blocked` above carries `needs_report: true`, and the
# report is the one comment that tells a human why they are being asked for a
# decision — prose, by definition, and located later by its `orch-blocked`
# trailer.
# =========================================================================

| ([ ($block_overrun + $block_rejections + $block_merge_cap)[]
     | { kind: "blocked-report", ticket: .ticket,
         why: .why,
         verb: "lane.sh blocked-report \(.ticket) --category <slug> (body on stdin), then the `transition` action above" } ])
  as $res_blocked

# A forge merge is durable code state. An open tracker ticket whose MR already
# merged must never be sent through rework against a missing local checkout.
# When a FAIL stands at that merged SHA, closing silently would lose a known
# shipped defect, so the wave must file the follow-up first; otherwise this is
# the ordinary half-finished merge shape and only the tracker close is owed.
| ([ $merged_open[]
     | (.class // "gate") as $class
     | { kind: "merged-ticket-open", ticket: .ticket, mr: .mr, sha: .sha,
         why: (if .verdict == "FAIL"
               then "MR !\(.mr) is already merged, but a \($class) FAIL stands at its merged head — file a fix ticket for that shipped residue, then close the landed ticket"
               else "MR !\(.mr) is already merged while its ticket remains open — finish the tracker close; never reconstruct the branch as rework" end),
         verb: (if .verdict == "FAIL"
                then "lane.sh fix-ticket --title <shipped-defect> --tier <tier> --milestone <epic> --file <body>, then lane.sh close \(.ticket)"
                else "lane.sh close \(.ticket)" end) } ]) as $res_merged_open

| (($sum.open_tickets | tonumber?) // ($tickets | length)) as $open_count
# Halted is tested FIRST because it is the survivable answer: a build where
# every open ticket is blocked satisfies "ready set empty and no lanes"
# exactly as a finished one does, and calling that complete tears the agent
# down over work a human was about to unblock. Completion additionally
# requires an EMPTY board — an unaccepted epic or a ticket parked in any state
# means the build is not finished, however many tickets merged. (paid:
# build-2's completion wave closed the build over three unprobed epics.)
| (if ($sum.all_blocked // false)
   then [ { kind: "halted-report", build: ($s.build.id),
            why: "every open ticket is blocked or waiting on a blocker — the build is halted and a human has to move it",
            verb: "tick.sh notify build_halted …" } ]
   elif ($sum.ready_set_empty // false)
      and (($sum.lanes_running // 0) == 0)
      and (($sum.epics_awaiting_probe // []) | length) == 0
      and ($gate_all | length) == 0 and ($queue | length) == 0
      and ($stranded | length) == 0 and $open_count == 0
   then [ { kind: "completion-report", build: ($s.build.id),
            why: "no open ticket, no lane, no unaccepted epic — the completion report, the digest and closing the `Build N` issue are all prose",
            verb: "tick.sh notify build_complete …, then lane.sh close \($s.build.id)" } ]
   else [] end) as $res_build

# =========================================================================
# Assembly. Step order IS the contract: harvest before gate before fill
# before merge before probe, and inside the fill, rework before backlog and
# `fix:` before the rest of the ready set. `order` is written into each action
# so a consumer that reorders them is visibly wrong rather than quietly so.
# =========================================================================

| ($kill_stale + $kill_overrun + $block_overrun + $repairs + $blocked_repairs + $clear_dead
   + $gate_actions + $block_rejections + $fill_actions
   + $block_merge_cap + $merge_actions + $probe_actions) as $actions
| ($res_pregate + $res_merge_failed + $res_blocked + $res_merged_open + $res_probe_criteria + $res_build)
  as $residue
| ($gate_deferred + $fill_deferred + $merge_deferred + $probe_deferred) as $deferred
| { generated_at: $s.generated_at,
    build: { id: $s.build.id, label: $s.build.label, provider: $provider },
    reason: (if ($actions | length) == 0 and ($residue | length) == 0
             then "nothing to schedule: \($open_count) open ticket(s), \($sum.lanes_running // 0) lane(s) running"
             else null end),
    actions: [ $actions | to_entries[] | .value + { order: (.key + 1) } ],
    residue: $residue,
    deferred: $deferred,
    supervised_leases: ($s.supervised_leases // []) }

end
