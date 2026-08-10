# plan.jq — the wave's schedule, derived from the snapshot (P81).
#
# Steps 2–6 of SKILL.md's `tick` used to be a decision table written in prose
# for a model session to follow. Every input to that table is already in the
# snapshot document, computed deterministically: `gate.eligible` with its
# `reason`, `summary.stranded`, `summary.impl_slots_free`,
# `summary.merge_in_flight`, `.merge_hold`, `.merge_attempts`,
# `rejections.same_class_tail`, `.model.effective`,
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

def empty_plan($gen; $build; $reason):
    { generated_at: $gen, build: $build, reason: $reason,
      actions: [], residue: [], deferred: [] };

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
else

. as $s
| ($s.config // {}) as $cfg
| ($s.tickets // []) as $tickets
| ($s.lanes // []) as $lanes
| ($s.summary // {}) as $sum
| ($s.epics // []) as $epics
| (($cfg.lane_turn_cap | tonumber?) // 150) as $turn_cap
| (($cfg.merge_attempt_cap | tonumber?) // 2) as $merge_cap
| (($cfg.max_aux_lanes | tonumber?) // 4) as $aux_cap
| (($sum.impl_slots_free | tonumber?) // 0) as $impl_free
| ($cfg.lane_model // null) as $lane_model
| ($s.logs_dir // "") as $logs

# One lookup, so every rule below reads the same row for the same ticket.
| def ticket($iid): ($tickets | map(select((.iid | tostring) == ($iid | tostring))) | first);

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
  ([ $lanes[] | select(.state == "stale")
     | { step: "harvest", kind: "kill-lane", lane: .id, ticket: (lane_ticket(.id)),
         via: "tick.sh", argv: ["kill-lane", .id],
         why: "lane is stale — alive but no real progress; a bare kill would orphan the session inside it" } ])
  as $kill_stale

# `running` past `lane_turn_cap` is effort, not progress — treated exactly the
# way a spent rejection cap is: kill, then block for a human. (paid: impl-43
# ran 456 turns, ~$300, with nothing watching the cost.)
| ([ $lanes[] | select(.state == "running"
                       and ((.turns | tonumber?) // 0) > $turn_cap) ]) as $overrun
| ([ $overrun[]
     | { step: "harvest", kind: "kill-lane", lane: .id, ticket: (lane_ticket(.id)),
         via: "tick.sh", argv: ["kill-lane", .id],
         why: "lane has taken \(.turns) turns against a cap of \($turn_cap) — that is effort, not progress" } ])
  as $kill_overrun
| ([ $overrun[] | select(ticket(lane_ticket(.id)) != null)
     | { step: "harvest", kind: "transition", lane: .id, ticket: (lane_ticket(.id) | tonumber),
         via: "lane.sh", argv: ["transition", lane_ticket(.id), "blocked"],
         why: "turn cap spent — a ticket that needs this many turns was written too big or the lane is lost; the next step is a human decision",
         needs_report: true } ])
  as $block_overrun

# Every `dead` lane is cleared. Clearing is bookkeeping — the pid file and the
# progress stamp — and it is correct for every death; what the death MEANS is
# the residue and the steps below.
| ([ $lanes[] | select(.state == "dead")
     | . as $l | (lane_ticket(.id)) as $tk
     | { step: "harvest", kind: "clear-lane", lane: .id, ticket: $tk,
         via: "tick.sh", argv: ["clear-lane", .id],
         why: (if .rc == "7" then "pregate rejected the branch (rc 7) — the lane is finished with it"
               elif .type == "gate" and .rc == "0" and ((ticket($tk).gate.eligible // false))
               then "gate exited rc 0 with no verdict standing at HEAD — respawn it a round on"
               else "lane is dead — clear its bookkeeping" end) } ])
  as $clear_dead

# The two half-finished shapes, each carrying the ONE command that repairs it.
# `snapshot.jq` located them (P63); the plan is where they stop being a warning
# a wave has to notice and become work with a place in the order.
| ([ ($sum.repairs // [])[]
     | { step: "harvest", kind: "repair", ticket: .iid,
         via: "lane.sh", argv: (.fix | ltrimstr("lane.sh ") | split(" ")),
         why: "\(.shape) — a lane died between its two writes" } ])
  as $repairs

# rc 7 is its pregate's rejection, not a crash: the verdict is posted straight
# from the lane log, with no verifier spawned. The log is prose only a reader
# can turn into a rejection comment, so it is residue by construction.
| ([ $lanes[] | select(.state == "dead" and .rc == "7")
     | select(ticket(lane_ticket(.id)) != null)
     | { kind: "pregate-rejection", ticket: (lane_ticket(.id) | tonumber), lane: .id,
         log: "\($logs)/lane-\(.id).log",
         why: "rc 7 = the pregate rejected the branch, not a crash — post the rejection from the lane log, no verifier",
         verb: "lane.sh verdict <iid> fail <head-sha> --class <slug> (reuse the previous class when it is the same failure)" } ])
  as $res_pregate

# A dead merge lane whose ticket is still `merge-queue` did not merge — but
# `merge-queue` in the snapshot is NOT evidence of that. Chained lanes land
# while a wave is mid-flight, so the ticket is re-read LIVE before anything is
# written. (paid: #23 merged at 22:23:17 and was blocked at 22:24:29 by a wave
# harvesting against a photograph taken 90 seconds before the merge.)
| ([ $lanes[] | select(.state == "dead" and .type == "merge")
     | select((ticket(lane_ticket(.id)).state // "") == "merge-queue")
     | (lane_ticket(.id) | tonumber) as $iid
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

| ($lanes | map(select(.state != "dead"
                       and (.type == "gate" or .type == "merge" or .type == "probe")))
          | length) as $aux_alive
| (($aux_cap - $aux_alive) | if . < 0 then 0 else . end) as $aux_free

# The round number comes off the lane ids already spawned for this ticket, so
# a respawn can never overwrite a live lane's pid file or rotate its log away.
| def gate_lane($iid):
      ([ $lanes[] | select(.type == "gate" and lane_ticket(.id) == ($iid | tostring))
                  | lane_round(.id) ] | max) as $r
    | if $r == null then "gate-\($iid)" else "gate-\($iid)-r\($r + 1)" end;

  ([ $tickets[] | select(.gate.eligible // false) ] | sort_by(.iid)) as $gate_all
| ($gate_all[0:$aux_free]) as $gate_take
| ([ $gate_take[]
     | (gate_lane(.iid)) as $lid
     | select(spawnable($lid))
     | { step: "gate", kind: "spawn", lane: $lid, ticket: .iid,
         spawn: { id: $lid, type: "gate", model: $lane_model, pregate: .tier,
                  merge_lock: false,
                  cwd_from: "the ticket's existing lane worktree (MR branch \(([.related_merge_requests[] | select(.state == "opened") | .source_branch] | first) // "unknown"))",
                  brief: { step: 3,
                           inputs: ["ticket #\(.iid) body and its `PRD requirement`",
                                    "the open MR at HEAD \(.gate.head // "unknown")",
                                    "the merge spawn line to run on a PASS"] } },
         why: "gate.eligible — in `review`, an open MR, and no verdict standing at this HEAD" } ])
  as $gate_actions
| ([ $gate_take[] | (gate_lane(.iid)) as $lid | select(spawnable($lid) | not)
     | { step: "gate", ticket: .iid, lane: $lid,
         why: "lane id `\($lid)` is not one `spawn-lane` accepts — a planner bug, not a lane failure" } ]
   + [ $gate_all[$aux_free:][]
     | { step: "gate", ticket: .iid,
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
| ([ ($sum.repairs // [])[] | .iid ]) as $repairing
| ([ ($sum.stranded // [])[] | ticket(.) | select(. != null)
     | select(.iid as $i | ($repairing | index($i)) == null) ] | sort_by(.iid)) as $stranded

# Two same-class rejections mean stop, not respawn: block for a design
# decision instead of a third same-tier guess. The cap stays for DIFFERENT
# failures. (paid: a ticket burned round 3 on a class the round-2 verdict had
# already named.)
| ([ $stranded[] | select((.rejections.same_class_tail // 0) >= 2) ]) as $same_class
| ([ $same_class[]
     | { step: "fill", kind: "transition", ticket: .iid,
         via: "lane.sh", argv: ["transition", (.iid | tostring), "blocked"],
         why: "\(.rejections.same_class_tail) consecutive `\(.rejections.last_class)` rejections — a third same-tier guess is not the next step, a design decision is",
         needs_report: true } ])
  as $block_same_class

| ([ $stranded[] | select((.rejections.same_class_tail // 0) < 2) ]) as $rework
# Then the backlog. Ready means unblocked (every blocker issue closed, not
# merely opened — auto-merge is async), unclaimed, and a member of this build;
# `fix: true` tickets come first, because every open fix ticket holds an
# epic's re-probe hostage. Ties break on iid, oldest first — a total order, so
# two plans over one snapshot are the same plan.
| ([ $tickets[] | select(.state == "ready-for-agent" and (.unblocked // false)
                         and ((.assignees | length) == 0))
                | select(.iid as $i | ($repairing | index($i)) == null) ]
   | sort_by([(if .fix then 0 else 1 end), .iid])) as $ready

| ($rework[0:$impl_free]) as $rework_take
| (($impl_free - ($rework_take | length)) | if . < 0 then 0 else . end) as $impl_left
| ($ready[0:$impl_left]) as $ready_take

| ([ $rework_take[]
     | ("impl-\(.iid)") as $lid
     | select(spawnable($lid))
     | { step: "fill", kind: "spawn", lane: $lid, ticket: .iid,
         spawn: { id: $lid, type: "impl", model: (.model.effective), pregate: null,
                  merge_lock: false,
                  cwd_from: "the ticket's SURVIVING worktree — this is a respawn, not a new lane",
                  brief: { step: 4,
                           inputs: ["ticket #\(.iid) body",
                                    "the latest rejection comment on #\(.iid)",
                                    "the build lessons thread"] } },
         why: "stranded rework (round \((.rejections.total // 0) + 1), model source `\(.model.source)`) — closest to done and its rejection cap is already counting" } ]
   + [ $ready_take[]
     | ("impl-\(.iid)") as $lid
     | select(spawnable($lid))
     | { step: "fill", kind: "spawn", lane: $lid, ticket: .iid,
         spawn: { id: $lid, type: "impl", model: (.model.effective), pregate: null,
                  merge_lock: false,
                  cwd_from: "a NEW worktree cut from the freshly-fetched `origin/\($cfg.base // "<base>")`, a sibling of the repo; copy the repo root's untracked .env in when present",
                  brief: { step: 4,
                           inputs: ["ticket #\(.iid) body",
                                    "the build lessons thread"] } },
         claim_first: true,
         why: (if .fix then "ready `fix:` ticket — fix tickets outrank the rest of the ready set"
               else "ready, unblocked and unclaimed" end) } ])
  as $fill_actions
| ([ ($rework[$impl_free:] + $ready[$impl_left:])[]
     | { step: "fill", ticket: .iid,
         why: "no implementation slot free (`summary.impl_slots_free` was \($impl_free))" } ])
  as $fill_deferred

# =========================================================================
# Step 5 — merge queue. After the fill, so a ticket ready at wave start does
# not wait out a whole merge before its worktree exists. The OLDEST
# `merge-queue` ticket whose `.merge_hold` is null; a second merge is refused
# while one is in flight.
# =========================================================================

| ([ $tickets[] | select(.state == "merge-queue") ] | sort_by(.iid)) as $queue
# At `merge_attempt_cap` recorded attempts, stop retrying that ticket: block
# it so the queue ADVANCES to the next-oldest instead of feeding every later
# lane into the same wall. (paid: three consecutive lanes wedged on one ticket
# while two gate-passed tickets waited behind it.) Attempts recorded
# `base-red` never count — `snapshot.jq` already excludes them.
| ([ $queue[] | select((.merge_attempts // 0) >= $merge_cap)
     | { step: "merge", kind: "transition", ticket: .iid,
         via: "lane.sh", argv: ["transition", (.iid | tostring), "blocked"],
         why: "\(.merge_attempts) merge attempts against a cap of \($merge_cap) — blocking it advances the queue instead of feeding the next lane into the same wall",
         needs_report: true } ])
  as $block_merge_cap
| ([ $queue[] | select((.merge_attempts // 0) < $merge_cap and .merge_hold == null) ] | first)
  as $merge_head
| (if ($sum.merge_in_flight // false) or $merge_head == null or $aux_left < 1 then []
   else [ $merge_head
          | ("merge-\(.iid)") as $lid
          | select(spawnable($lid))
          | { step: "merge", kind: "spawn", lane: $lid, ticket: .iid,
              spawn: { id: $lid, type: "merge", model: $lane_model, pregate: null,
                       merge_lock: true,
                       cwd_from: "the ticket's existing lane worktree (MR branch \(([.related_merge_requests[] | select(.state == "opened") | .source_branch] | first) // "unknown"))",
                       brief: { step: 5,
                                inputs: ["ticket #\(.iid) and its open MR",
                                         "the integration base `\($cfg.base // "<declared base, else develop, else main>")`"] } },
              why: "oldest `merge-queue` ticket with no merge hold" } ]
   end) as $merge_actions
| ([ $queue[] | select(.merge_hold != null)
     | { step: "merge", ticket: .iid,
         why: "parked behind an open base-red fix (\(.merge_hold.fixes | map("#\(.)") | join(", "))) — it re-enters the queue on its own when the fix merges" } ]
   + (if ($sum.merge_in_flight // false)
      then [ { step: "merge",
               why: "a merge lane already holds the merge lock — a second merge waits" } ]
      elif $merge_head != null and $aux_left < 1
      then [ { step: "merge", ticket: $merge_head.iid,
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
         spawn: { id: $lid, type: "probe", model: $lane_model, pregate: null,
                  merge_lock: false,
                  cwd_from: "a worktree on the freshly-fetched `origin/\($cfg.base // "<base>")` with the stack really running",
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

| ([ ($block_overrun + $block_same_class + $block_merge_cap)[]
     | { kind: "blocked-report", ticket: .ticket,
         why: .why,
         verb: "lane.sh blocked-report \(.ticket) --category <slug> (body on stdin), then the `transition` action above" } ])
  as $res_blocked

| (($sum.open_tickets | tonumber?) // ($tickets | length)) as $open_count
# Halted is tested FIRST because it is the survivable answer: a build where
# every open ticket is blocked satisfies "ready set empty and no lanes"
# exactly as a finished one does, and calling that complete tears the agent
# down over work a human was about to unblock. Completion additionally
# requires an EMPTY board — an unaccepted epic or a ticket parked in any state
# means the build is not finished, however many tickets merged. (paid:
# build-2's completion wave closed the build over three unprobed epics.)
| (if ($sum.all_blocked // false)
   then [ { kind: "halted-report", build: ($s.build.iid),
            why: "every open ticket is blocked or waiting on a blocker — the build is halted and a human has to move it",
            verb: "tick.sh notify build_halted …" } ]
   elif ($sum.ready_set_empty // false)
      and (($sum.lanes_running // 0) == 0)
      and (($sum.epics_awaiting_probe // []) | length) == 0
      and ($gate_all | length) == 0 and ($queue | length) == 0
      and ($stranded | length) == 0 and $open_count == 0
   then [ { kind: "completion-report", build: ($s.build.iid),
            why: "no open ticket, no lane, no unaccepted epic — the completion report, the digest and closing the `Build N` issue are all prose",
            verb: "tick.sh notify build_complete …, then lane.sh close \($s.build.iid)" } ]
   else [] end) as $res_build

# =========================================================================
# Assembly. Step order IS the contract: harvest before gate before fill
# before merge before probe, and inside the fill, rework before backlog and
# `fix:` before the rest of the ready set. `order` is written into each action
# so a consumer that reorders them is visibly wrong rather than quietly so.
# =========================================================================

| ($kill_stale + $kill_overrun + $block_overrun + $repairs + $clear_dead
   + $gate_actions + $block_same_class + $fill_actions
   + $block_merge_cap + $merge_actions + $probe_actions) as $actions
| ($res_pregate + $res_merge_failed + $res_blocked + $res_probe_criteria + $res_build)
  as $residue
| ($gate_deferred + $fill_deferred + $merge_deferred + $probe_deferred) as $deferred
| { generated_at: $s.generated_at,
    build: { iid: $s.build.iid, label: $s.build.label },
    reason: (if ($actions | length) == 0 and ($residue | length) == 0
             then "nothing to schedule: \($open_count) open ticket(s), \($sum.lanes_running // 0) lane(s) running"
             else null end),
    actions: [ $actions | to_entries[] | .value + { order: (.key + 1) } ],
    residue: $residue,
    deferred: $deferred }

end
