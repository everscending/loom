# snapshot.jq — the tracker snapshot document, built in one pass.
#
# Lifted out of `cmd_snapshot` in tick.sh, where it was 370 lines of jq inside
# a single-quoted shell string: too big to navigate, impossible to syntax-check
# on its own, and quietly unable to contain an apostrophe (one in a comment
# ends the shell quote mid-word and breaks the whole script — it happened).
# In a file it is checkable with `jq -n -f snapshot.jq </dev/null`, and prose
# may use apostrophes like prose.
#
# Inputs are bound by tick.sh: --slurpfile open/links/mrs/notes/tnotes/
# milestones/closed, --rawfile lanes_raw/warn_raw, --argjson config/brief, and
# --arg logs_dir/generated_at/label/build_iid/merge_owner. Output is the single
# JSON document a wave reads; every consumer of a field is named at the field.

    def section($name):
        (. // "")
        | (capture("(?ms)^##[ \\t]*" + $name + "[ \\t]*$(?<b>.*?)(?=^##[ \\t]|\\z)") // {b: ""})
        | .b;
    def state_of($labels):
        (["blocked", "merge-queue", "review", "in-progress", "ready-for-agent"]
         | map(select(. as $s | $labels | index($s))) | first) // null;
    # Must stay byte-identical to the milestone slugify in lane.sh, or an
    # epic acceptance is written to one key and read from another.
    def epic_norm:
        ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+"; "") | gsub("-+$"; "");
    # The body section is primary; the label is the fallback. That fallback was
    # dead for every repo this skill bootstraps: it matched a BARE `ui`, while
    # `bootstrap.sh` creates the SCOPED `tier::ui`, so a ticket carrying a
    # perfectly good tier label still read `tier: null` and no gate lane could
    # pick a suite (#52, 2026-08-03 — and #51 before it, both filed by probe
    # lanes that set the label and not the section).
    def tier_of($labels):
        ([(.description | section("Risk tier")) | scan("\\b(docs|logic|api|ui)\\b") | .[0]] | first)
        // ($labels | map(select(test("^(tier::)?(docs|logic|api|ui)$")) | ltrimstr("tier::"))
                    | first) // null;
    # P11. Build 2 spawned a 12m53s verifier on a ticket whose code had merged
    # 95 seconds earlier — it dutifully FAILED shipped code — and gated another
    # twice at the identical commit, the duplicate re-running the live suite for
    # ~4 minutes before noticing. Both are answerable from data already here,
    # so the wave is told rather than left to work it out: gate only where
    # `gate.eligible`. The verdict trailer is what makes "this HEAD is already
    # judged" exact instead of a guess; short shas match long ones either way.
    def gate_of($iid; $state; $mrs; $notes; $gating):
        ($mrs | map(select((.state // "") == "opened")) | first) as $mr
      | ($mr.sha // null) as $head
      # Carry each verdict timestamp and sort on it. Relying on the arrival
      # order was a real bug: notes are fetched sort=desc, so the array is
      # newest-first and taking the LAST match returned the OLDEST verdict —
      # a ticket rejected and then passed at an unchanged commit read as
      # "already judged FAIL" and would never merge. Sorting here cannot be
      # broken later by changing the query.
      # `i` is the arrival index, and it is the tiebreaker — without it a
      # missing `created_at` makes every verdict tie, and since jq sort is
      # stable over a newest-first list, `last` would quietly return the OLDEST
      # again: the original bug, restored with no signal. Notes arrive newest
      # first, so a SMALLER index is newer; sorting on -i puts the newest last.
      | ([$notes | to_entries[] | .key as $i | .value as $note
          | ($note.body // "")
          | scan("orch-verdict\\s+(PASS|FAIL)\\s+([0-9a-fA-F]{7,40})")
          | {verdict: .[0], sha: .[1], at: ($note.created_at // ""), i: $i}]) as $vs
      # Bind the element before comparing: `$head | startswith(.sha)` would
      # evaluate `.sha` against $head — a string — not against the verdict.
      | (if $head == null then null
         else ($vs | map(select(. as $v | ($head | startswith($v.sha))
                                       or ($v.sha | startswith($head))))
                   | sort_by([.at, -.i]) | last)
         end) as $judged
      | if $state != "review" then
            {eligible: false, reason: "not in review", head: $head, last_verdict: null}
        elif $mr == null then
            {eligible: false, reason: "no open merge request — merged or closed while queued",
             head: null, last_verdict: null}
        elif ($gating[$iid | tostring] // null) != null then
            {eligible: false,
             reason: (if $gating[$iid | tostring] == "stale"
                      then "a gate lane on this ticket is STALE — harvest it (kill-lane) before it can be gated again"
                      else "a gate lane is already running for this ticket" end),
             head: $head, last_verdict: null}
        elif $judged != null then
            {eligible: false, reason: ("already judged " + $judged.verdict + " at this HEAD"),
             head: $head, last_verdict: $judged}
        else
            {eligible: true, reason: null, head: $head, last_verdict: null}
        end;
    # P30: the rejection history as a decision input. A FAIL trailer may name
    # its defect class (class=<slug>, written by lane.sh verdict --class);
    # same_class_tail counts consecutive newest-first FAILs sharing one class.
    # Consumer: the wave fill step — a tail of 2 means block for a design
    # decision, not a third same-tier guess (#39 burned round 3 on a class
    # the round-2 verdict had already named, 2026-08-02). A FAIL without a
    # class, or a PASS, breaks the run — conservative by design.
    # P37: a `<!-- orch-scope-reset … -->` marker (lane.sh rescope) says the
    # ticket became different work, so the cap is attached to the SCOPE and not
    # to the issue number: verdicts older than the newest marker count toward
    # neither `total` nor `same_class_tail`. #67 was rewritten into a bounded
    # give-up after the race it was rejected over moved to #48 and #48 deleted
    # the code — and it returned to the board with 3 of 3 rejections against
    # machinery that no longer existed (build-3, 2026-08-04). Ordering uses the
    # created_at of the marker note itself, with the same tiebreak as the
    # verdicts it is compared against — one clock, the one the tracker stamps.
    # The iso8601 inside the marker is the human-readable record, never the
    # comparison key. (No apostrophes in this comment: the whole jq program is a
    # single-quoted shell string, and one would end it mid-word.)
    def rejections_of($notes):
        ([$notes | to_entries[]
          | select((.value.body // "") | test("orch-scope-reset"))
          | {at: (.value.created_at // ""), i: .key}]
         | sort_by([.at, -.i]) | last) as $reset
      | ([$notes | to_entries[] | .key as $i | .value as $note
          | ($note.body // "")
          | scan("orch-verdict\\s+(PASS|FAIL)\\s+([0-9a-fA-F]{7,40})(?:\\s+class=([a-z0-9-]+))?")
          | {verdict: .[0], class: .[2], at: ($note.created_at // ""), i: $i}]
         | sort_by([.at, -.i])
         | if $reset == null then .
           else map(select([.at, -.i] > [$reset.at, -$reset.i])) end) as $vs
      | ($vs | reverse
             | reduce .[] as $v ({run: 0, cls: null, stop: false};
                 if .stop then .
                 elif $v.verdict != "FAIL" then .stop = true
                 elif $v.class == null then .stop = true
                 elif .cls == null then {run: 1, cls: $v.class, stop: false}
                 elif .cls == $v.class then .run += 1
                 else .stop = true end)) as $tail
      | { total: ($vs | map(select(.verdict == "FAIL")) | length),
          last_class: $tail.cls, same_class_tail: $tail.run };
    # P32: how many merge lanes have already failed on this ticket, from the
    # `orch-merge-attempt` trailers `lane.sh merge-failed` writes. Consumer:
    # the harvest step in the wave — the merge queue always takes the OLDEST
    # merge-queue ticket, so one poisoned ticket is re-picked by every lane
    # behind it until something counts the attempts and blocks it. (build-3
    # 2026-08-03: three lanes in a row wedged on #50 while #52 and #53 waited.)
    def merge_attempts_of($notes):
        [$notes[] | select((.body // "") | test("orch-merge-attempt"))] | length;
    # P31: which model this ticket next IMPLEMENTATION lane gets. The chain is
    # deterministic, so it is resolved here rather than reasoned about in each
    # wave: ticket `model::` label > `rework_model` (round 2 and later) >
    # `lane_model` > the session default (null = inherit, pass no --model).
    # Round is derived, not stored: a rework round is exactly one that follows
    # a rejection, so round == rejections.total + 1.
    # Rank exists only to break the two-labels case; a `model::` value that is
    # not one of the known tiers still resolves (the human may name any model
    # the CLI accepts) but ranks below all of them.
    def model_rank($m):
        (["haiku", "sonnet", "fable", "opus"] | index($m)) // -1;
    def model_of($labels; $rejections; $config):
        ([$labels[] | select(startswith("model::")) | ltrimstr("model::")
          | select(length > 0)] | unique) as $picked
      | ($picked | sort_by(model_rank(.)) | last) as $lbl
      | (if $lbl != null then {effective: $lbl, source: "label"}
         elif ($rejections.total > 0 and ($config.rework_model // null) != null)
              then {effective: $config.rework_model, source: "rework_model"}
         elif ($config.lane_model // null) != null
              then {effective: $config.lane_model, source: "lane_model"}
         else {effective: null, source: "session-default"} end)
      | . + { label: $lbl, labels_seen: $picked };
    def blocker($iid; $src; $state; $proj; $open_iids; $home):
        # State comes straight off a native link when present; otherwise the
        # open-set inference, which is only valid inside this project.
        { iid: $iid, source: $src,
          closed: (if $state != null then ($state == "closed")
                   elif ($proj != null and $home != null and $proj != $home) then null
                   else (($open_iids | index($iid)) == null) end) };
    # P51: --brief keeps a full ticket row only where a wave can act THIS
    # turn; everything else collapses to a bare iid in `.other_iids`, since
    # `summary` already carries the counts. $working is the iid (as string)
    # of every ticket holding a lane of any kind, alive or stale — the same
    # set `summary.stranded` is defined against, so the two can never drift
    # apart. The five clauses are the five bullets in the proposal: ready and
    # unblocked and unclaimed; gateable; in the merge queue (the whole queue,
    # not just the head — order matters there); stranded (in-progress, no
    # lane); and holding a lane whatever its label, which is what still needs
    # a full row for a ticket already `review` behind a running gate lane —
    # `gate.eligible` is false there precisely because it is already gated.
    def is_actionable($t; $working):
        ($t.state == "ready-for-agent" and $t.unblocked and (($t.assignees | length) == 0))
        or ($t.state == "review" and ($t.gate.eligible // false))
        or ($t.state == "merge-queue")
        or ($t.state == "in-progress"
            and ((($t.iid | tostring) as $i | $working | index($i)) == null))
        or ((($t.iid | tostring) as $i | $working | index($i)) != null);

    ($open[0]) as $issues
    | ($issues | map(.iid)) as $open_iids
    | ($issues | map(select((.title // "") | test("^Build [0-9]+$"))) | sort_by(.iid) | last) as $bi
    | ($bi.project_id? // null) as $home
    | ($links[0]) as $L | ($mrs[0]) as $M | ($tnotes[0]) as $N
    | ($lanes_raw | split("\n") | map(select(length > 0) | split(" "))
       | map({id: .[0], pid: .[1], state: .[2], type: (.[3] // "unknown"),
              rc: (.[4] // "-"), turns: (.[5] // "-")})) as $lanes
    # The ticket iid (as a string) behind every ALIVE lane, whatever its kind
    # — a probe's id has no ticket iid in it and simply never matches. Shared
    # by `summary.stranded` (in-progress AND absent here) and the P51 brief
    # filter (present here, in ANY state) so the two definitions cannot drift.
    | ($lanes | map(select(.state != "dead")
                 | .id | sub("^(impl|gate|merge|probe)-"; "")
                 | sub("-r[0-9]+$"; ""))) as $working
    # Which tickets already have a verifier on them. Needed because a lane may
    # now spawn its own gate (P6), and the completion tick it fires lands on a
    # wave that would otherwise spawn a second one under the same id — which
    # overwrites the running pid file and rotates that log out from under it.
    # (No apostrophes in here: this whole program is one single-quoted string.)
# `state != "dead"` covers running AND stale. A stale lane is alive but silent —
# its process still holds the ticket, so filtering on "running" let a second
# verifier be dispatched onto a lane that was merely quiet.
# The STATE travels with it, because "a gate lane is on this ticket" is not
# actionable on its own: a wedged verifier would otherwise hold its ticket
# ineligible forever behind a reason that reads like healthy progress. Harvest
# (step 2) kills stale lanes, and the reason now says which case this is.
    | ($lanes | map(select(.state != "dead" and .type == "gate"))
              | map({key: (.id | capture("^gate-(?<n>[0-9]+)") | .n),
                     value: .state}) | from_entries) as $gating
    | (if $label == "" then [] else $issues | map(select((.labels // []) | index($label))) end) as $members
    | ($members | map(
        . as $t | ($t.labels // []) as $lb
        | (($L[$t.iid | tostring]) // []) as $lk
        | ($lk | map(select((.link_type // "") == "is_blocked_by"))) as $nat
        | ($t.description | section("Blocked by")
           | [scan("#([0-9]+)") | .[0] | tonumber] | unique) as $body
        | ($nat | map(.iid)) as $natids
        | (($nat | map(.iid as $n
                       | blocker($n; (if ($body | index($n)) then "both" else "native" end);
                                 (.state // null); (.project_id // null); $open_iids; $home)))
           + ($body | map(select(. as $b | ($natids | index($b)) == null))
                    | map(blocker(.; "body"; null; null; $open_iids; $home)))) as $bb
        | rejections_of((($N[$t.iid | tostring]) // [])) as $rej
        # P53: depth, like width, is decided when the ticket is written. Two cheap
        # proxies read straight off the body `graph` can flag before a lane ever
        # opens it — how many acceptance criteria it promises, and how many
        # distinct files it already names. Both are heuristics (a stray "e.g."-
        # shaped token can inflate file_surface by one), which is why `graph`
        # only ever uses them to flag, never to block.
        | ($t.description // "") as $desc
        | ($desc | section("Acceptance criteria")
           | [scan("(?m)^[ \\t]*[-*+][ \\t]+\\[[ xX]\\][ \\t]+")] | length) as $criteria_count
        | ($desc
           | [scan("[A-Za-z0-9_][A-Za-z0-9_./-]*\\.(?:ts|tsx|js|jsx|py|go|rb|rs|java|c|cpp|h|hpp|cs|md|json|ya?ml|sh|sql|css|html|vue)\\b")]
           | unique | length) as $file_surface
        | { iid: $t.iid, title: $t.title, url: ($t.web_url // null), labels: $lb,
            state: state_of($lb), tier: ($t | tier_of($lb)),
            fix: (($lb | index("fix")) != null),
            assignees: [($t.assignees // [])[] | .username],
            updated_at: ($t.updated_at // null),
            epic: ($t.epic.title? // $t.milestone.title? // null),
            criteria_count: $criteria_count,
            file_surface: $file_surface,
            blocked_by: $bb,
            unblocked: ($bb | all(.closed == true)),
            related: ($lk | map(select((.link_type // "") == "relates_to") | .iid)),
            related_merge_requests: ((($M[$t.iid | tostring]) // [])
                | map({iid, title, state, draft, web_url, source_branch, sha})),
            rejections: $rej,
            merge_attempts: merge_attempts_of((($N[$t.iid | tostring]) // [])),
            model: model_of($lb; $rej; $config),
            gate: gate_of($t.iid; state_of($lb);
                          (($M[$t.iid | tostring]) // []);
                          (($N[$t.iid | tostring]) // []); $gating) })) as $tickets
    | ([$tickets[] | .epic | select(. != null)] | group_by(.)
       | map({name: .[0], open_tickets: length, complete: false, source: "open-members"})) as $epics_open
    # An epic whose last ticket closed is invisible in an open-issue payload,
    # so the candidate list comes from the Build issue body (already here).
    # Heuristic, hence the `source` tag: markdown list items, scoped to the
    # selected-epics list where the body marks one (so a "deliberately
    # dropped" list below cannot masquerade as build epics), stripped of
    # `(#12)` / `— 2h` trailers, minus config-snapshot `key: value` lines.
    | (($bi.description // "")
       | (if test("(?i)selected epic")
          then (capture("(?is)selected epic(?<b>.*?)(?=\\n[ \\t]*\\n(?![ \\t]*[-*+][ \\t]))") // {b: .}) | .b
          else . end)
       | [scan("(?m)^[ \\t]*[-*+][ \\t]+(?:\\[[ xX]\\][ \\t]+)?(.+)$") | .[0]
          | gsub("[*`\\[\\]]"; "") | sub("\\s*\\(#[^)]*\\).*$"; "")
          | sub("\\s+[—–-]\\s+[^—–]*$"; "") | gsub("^\\s+|\\s+$"; "")]
       | map(select(length > 0 and length < 120 and (test("^[a-z_][a-z0-9_]*:") | not)))) as $items
    # P35: completed epics derived EXACTLY, from the milestone titles of this
    # builds CLOSED members. The body parse above is a heuristic that reads
    # markdown list items, so a Build issue listing its epics in a table
    # matches nothing and every finished epic goes invisible at the exact
    # moment it becomes probe-ready. Milestone titles on closed members are
    # the same fact without the guesswork; the parse stays only as a fallback
    # for a build whose tickets carry no milestone at all.
    | (($closed[0] // []) | map(.milestone.title? // empty) | unique
       | map(select(. as $t | ($epics_open | map(.name) | index($t)) | not))
       | map({name: ., open_tickets: 0, complete: true, source: "closed-members"})) as $epics_closed
    | ($items | map(select(ascii_downcase as $it
        | (($epics_open + $epics_closed) | map(.name | ascii_downcase)
           | any(. as $n | ($it | contains($n)) or ($n | contains($it)))) | not))
       | map({name: ., open_tickets: 0, complete: true, source: "build-issue"})) as $epics_done
    # Acceptance, joined from the milestone the probe closes. Matching uses the
    # SAME normalisation `lane.sh _close_epic_milestone` slugs with, so what
    # closes a milestone and what reads it back can never disagree about which
    # milestone belongs to which epic. `accepted: null` = no milestone found,
    # which asserts nothing and never manufactures a probe.
    | (($epics_open + $epics_closed + $epics_done)
       | map(. as $e
             | ($milestones[0] // []
                | map(select((.title | epic_norm) as $mt | ($e.name | epic_norm) as $en
                             | $mt == $en or ($mt | startswith($en)) or ($en | startswith($mt))))
                | first) as $ms
             | . + { milestone: ($ms.title // null),
                     accepted: (if $ms == null then null else ($ms.state == "closed") end),
                     # P34: the acceptance criteria belonging to this epic, from its
                     # milestone description. The probe brief is assembled
                     # from this plus regression checks for defects the epic
                     # already produced — criteria say what must be true,
                     # regressions say what has broken before. Without them a
                     # brief can only be written backwards from the defect
                     # history, so the probe is structurally unable to catch
                     # anything nobody has broken yet. (Paid for: E4 failed
                     # five straight probes, each brief enumerated from the
                     # tickets from the previous round, and no run ever checked
                     # FR-2/TR-2/PF-1 it cites. 2026-08-04.)
                     acceptance: (($ms.description // "") | section("Acceptance criteria")
                                  | if (gsub("\\s"; "") | length) == 0 then null else . end),
                     # Level-triggered on purpose. Step 6 used to read as an
                     # EDGE (when the last ticket of an epic closes) — a thing
                     # a stateless wave cannot see, since it gets one
                     # photograph and no previous frame. "All members closed
                     # and the milestone still open" is the same fact, read
                     # from one snapshot, and it stays true until a probe
                     # passes.
                     needs_probe: (.complete and $ms != null and $ms.state != "closed") }))
      as $epics
    | (($warn_raw | split("\n") | map(select(length > 0)))
       + [$tickets[] | select(.state == null) | "ticket #\(.iid): no state label"]
       + [$tickets[] | select(.tier == null) | "ticket #\(.iid): no `## Risk tier` section"]
       # An epic about to be probed with nothing to probe against. Fires
       # exactly when it matters — not for every epic, only the one whose
       # last ticket has closed and whose milestone is still open. A brief
       # written without criteria can only enumerate past defects, and a
       # probe that only re-tests past defects cannot catch what nobody has
       # broken yet.
       + [$epics[] | select(.needs_probe and .acceptance == null)
          | "epic \(.name): ready to probe but its milestone has no "
            + "`## Acceptance criteria` section — the probe brief would have "
            + "nothing to check against but the defect history"]
       + [$tickets[] | select((.model.labels_seen | length) > 1)
          | "ticket #\(.iid): \(.model.labels_seen | length) `model::` labels "
            + "(\(.model.labels_seen | join(", "))) — using \(.model.label)"]
       # A ticket still holding the assignee its lane wrote, after returning to
       # `ready-for-agent` falls between BOTH fill paths: `summary.stranded`
       # only looks at `in-progress`, and the ready set only takes unclaimed.
       # #47 sat there for 90 minutes after its human decision landed, with
       # `ready_set_empty: true` and nothing else schedulable — one step from
       # `build_complete` closing the build over it. The warning names the
       # one command that fixes it, because the unblock that dropped it was
       # composed by hand.
       + [$tickets[] | select(.state == "ready-for-agent" and .unblocked
                              and ((.assignees | length) > 0))
          | "ticket #\(.iid): `ready-for-agent` but still assigned to "
            + "\(.assignees | join(", ")) — invisible to the ready set AND to "
            + "`summary.stranded`. Clear it: lane.sh transition \(.iid) ready-for-agent"]
       + [$tickets[] | select(.blocked_by | any(.closed == null))
          | "ticket #\(.iid): blocker closed-state unknown (cross-project link) — treated as not closed"]
       + (if ($bi != null and ($items | length) == 0)
          then ["build issue body has no parseable epic list — epics[] shows only epics with open tickets"]
          else [] end)
       # Loud, because the failure it names is silent and terminal: nothing
       # else in the document distinguishes "every ticket merged" from "this
       # epic was actually accepted", and the completion path tears the agent
       # down on its way out.
       + [$epics[] | select(.needs_probe)
          | "epic \(.name): every member ticket is closed but its milestone is "
            + "still open — no acceptance probe has passed on it. The build is "
            + "NOT complete until one does: spawn probe-\((.milestone // .name) | epic_norm)"]) as $warnings
    | { generated_at: $generated_at, logs_dir: $logs_dir, config: $config,
        build: (if $bi == null then null
                else { iid: $bi.iid, label: $label, title: $bi.title, url: ($bi.web_url // null) } end),
        epics: $epics,
        # P51: --brief keeps a full row only for what is_actionable calls
        # in-play this turn; the rest are still counted in `summary` below,
        # just not carried here — `other_iids` is the bare list so a wave can
        # still name one without a second read. Plain `snapshot` (the default)
        # never filters: `$brief` is false and every ticket keeps its row.
        tickets: (if $brief then [$tickets[] | select(is_actionable(.; $working))]
                  else $tickets end),
        other_iids: (if $brief then [$tickets[] | select(is_actionable(.; $working) | not) | .iid]
                     else [] end),
        lanes: $lanes,
        lessons_tail: ($notes[0] | map(select((.system // false) | not))
                       | map({author: (.author.username? // null), created_at, body})),
        summary: {
            open_tickets: ($tickets | length),
            by_state: ($tickets | map(.state // "unlabeled") | group_by(.)
                       | map({key: .[0], value: length}) | from_entries),
            all_blocked: (($tickets | length) > 0
                          and ($tickets | all(.state == "blocked" or (.unblocked | not)))),
            # The step-6 worklist, as a list rather than something a wave has
            # to notice. An empty ready set with a non-empty list here means
            # the build has unfinished ACCEPTANCE, not unfinished work — the
            # exact state that closed build-2 over three unprobed epics.
            epics_awaiting_probe: [$epics[] | select(.needs_probe) | .name],
            ready_set_empty: (($tickets | map(select(.state == "ready-for-agent" and .unblocked
                               and ((.assignees | length) == 0))) | length) == 0),
            # Every count in `summary` means ALIVE — running or stale. A stale
            # lane still holds its process and its worktree, so treating it as
            # free over-subscribes the caps. Per-lane detail stays in `lanes[]`.
            lanes_running: ($lanes | map(select(.state != "dead")) | length),
            # How many `review` tickets are actually worth a verifier right now
            # — never simply the count in `review` (P11).
            gateable: ($tickets | map(select(.gate.eligible)) | length),
            # Only `impl` fills `max_lanes`; gates, merges and probes share
            # `max_aux_lanes` so they can never crowd out implementers (P10).
            lanes_running_by_type:
              (["impl","gate","merge","probe","unknown"]
               | map(. as $t | {key: $t,
                     value: ($lanes | map(select(.state != "dead" and .type == $t)) | length)})
               | from_entries),
            # Occupancy counts ALIVE lanes, not merely `running` ones: a stale
            # lane still holds its process and its worktree, so treating it as a
            # free slot over-subscribes `max_lanes`. Harvest clears it, and the
            # snapshot is re-run after the wave writes.
            impl_slots_free: ((($config.max_lanes | tonumber?) // 4)
                              - ($lanes | map(select(.state != "dead"
                                 and .type == "impl")) | length)),
            # A merge is in flight in its own lane; scheduling continues around
            # it, but a second merge waits (P5).
            merge_in_flight: ($merge_owner != ""),
            # Claimed but unworked: `in-progress`, yet no ALIVE lane carries
            # the ticket. This is exactly where a gate rejection lands a
            # ticket (verdict fail → in-progress, assignee kept) — and no
            # other step reads that state: harvest sees only lanes, gate needs
            # `review`, fill needs unclaimed — so without this list rejected
            # tickets strand forever while fresh claims take the slots.
            # Consumer: the wave fill step, rework FIRST. (Paid for:
            # build-3 2026-08-02 — #11/#12 gate-FAILed and sat unworked.)
            stranded: ($tickets
                       | map(select(.state == "in-progress"
                              and (((.iid | tostring) as $i
                                    | $working | index($i)) | not)))
                       | map(.iid)) },
        warnings: $warnings }
