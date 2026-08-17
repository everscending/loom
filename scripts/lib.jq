# lib.jq — the shared jq prelude (P72), the jq counterpart of lib.sh.
#
# Three facts used to live in two or three copies each, held together by
# comments and discipline: the epic slugify (snapshot.jq's `epic_norm` and
# lane.sh's `sed`, whose only bond was a comment saying "must stay
# byte-identical"), the orch-verdict trailer regex (written three times, so a
# trailer format change could half-land), and the hms/pct/usd formatters
# (copied between report.jq and retro.jq). Written once here and included,
# byte-identical becomes structural instead of disciplined.
#
# Every jq program beside this file opens with `include "lib";`, and every
# caller passes `jq -L <the directory this file is in>` — see `_jq_lib_dir` in
# lib.sh, which resolves that directory and refuses when this file is missing.
# lib.sh is the bash half of the same idea and stays a separate file: bash
# functions there, jq definitions here.
#
# Every program includes it, including the four that use nothing from here yet
# (render.jq, usage.jq, graph.jq, report-ticket.jq): one rule at every call
# site beats a per-file question about which programs need `-L`, and a program
# that starts printing a duration needs no new mechanism to do it the same way.
#
# ENTRY RULE — pure definitions only, over their inputs. Nothing here may read
# a `--arg` that one caller happens to bind, because a program that does not
# bind it would then fail to compile; a def that needs a binding takes it as a
# parameter.

# The epic slug, one definition for both halves. lane.sh's
# `_close_epic_milestone` normalizes milestone titles through THIS def now
# (`jq -L … 'include "lib"; epic_norm'`) instead of its own `sed`, so an epic
# acceptance can no longer be written to one key and read from another.
# Consumers: snapshot.jq (epic completeness, probe naming) and lane.sh.
def epic_norm:
    ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+"; "") | gsub("-+$"; "");

# Markdown section extraction and the product risk tier are shared by the
# full scheduler snapshot and chain-merge's narrow queue read. A chained merge
# must carry the same configured gate tier as a wave-spawned merge; duplicating
# the label/body fallback here would let those two paths drift.
def section($name):
    (. // "")
    | (capture("(?ms)^##[ \\t]*" + $name + "[ \\t]*$(?<b>.*?)(?=^##[ \\t]|\\z)") // {b: ""})
    | .b;
def tier_of($labels):
    ([(.body | section("Risk tier")) | scan("\\b(docs|logic|api|ui)\\b") | .[0]] | first)
    // ($labels | map(select(test("^(tier::)?(docs|logic|api|ui)$")) | ltrimstr("tier::"))
                | first) // null;

# The gate verdict trailer, in one regex. Emits [verdict, sha, class], class
# null when the trailer carries none — a PASS never does (lane.sh strips one
# that rides along) and a FAIL always does. Consumers: snapshot.jq's
# `judged_at` ("this HEAD is already judged", which reads the first two) and
# `rejections_of` (the round-three rejection stop, which reads all three), plus
# lane.sh's duplicate-verdict refusal. A change to the trailer format is one
# edit here and cannot half-land any more.
def orch_verdict_scan:
    scan("orch-verdict\\s+(PASS|FAIL)\\s+([0-9a-fA-F]{7,40})(?:\\s+class=([a-z0-9-]+))?");

# Gate verdicts that still stand after the newest human reset. `verdict-reset`
# retires an invalid gate outcome, `supervised-repair` retires valid defects a
# human has repaired, and replacement or additive rescope is the superset for
# changed work.
# Ordering uses tracker timestamps plus arrival index, so verdicts at the
# marker timestamp are retired too. Consumers:
# snapshot.jq (`judged_at`, `rejections_of`) and lane.sh duplicate refusal.
def verdicts_after_reset($notes):
    ([$notes | to_entries[]
      | select((.value.body // "") | test("<!-- orch-(scope-(reset|extend)|verdict-reset|supervised-repair) "))
      | {at: (.value.created_at // ""), i: .key}]
     | sort_by([.at, -.i]) | last) as $reset
  | [$notes | to_entries[] | .key as $i | .value as $note
     | [($note.body // "") | orch_verdict_scan] | to_entries[]
     | {verdict: .value[0], sha: .value[1], class: .value[2],
        at: ($note.created_at // ""), i: $i, mi: .key}]
  | group_by([.i, .sha]) | map(max_by(.mi))
  | sort_by([.at, -.i, .mi])
  | if $reset == null then .
    else map(select([.at, -.i] > [$reset.at, -$reset.i])) end
  # Tracker read-after-write lag can let an immediate cleanup replay post the
  # same ticket/HEAD/outcome twice. Exact verdict identity is one gate round,
  # regardless of how many comments transported it. A reset still permits a
  # later review of the same HEAD because the older identity was removed above.
  | group_by([.verdict, .sha, .class]) # mutate:duplicate-verdict-comments
  | map(max_by([.at, -.i, .mi]))
  | sort_by([.at, -.i, .mi]);

# The active replacement scope plus every later additive amendment, not merely
# the cutoff they create for old verdicts. `rescope` is a true replacement;
# `rescope --extend` adds to that replacement without hiding it. A later true
# replacement supersedes the old replacement and its amendments. The composed
# body is executable build input: snapshot.jq carries it into the ticket row,
# plan.jq freezes it into an action, and tick.sh stages the same string for
# Claude and Codex. Keep tracker-stamped ordering identical to
# verdicts_after_reset: notes arrive newest-first, so lower arrival indexes win
# timestamp ties.
def active_scope_reset_of($notes):
    ([$notes | to_entries[]
      | select((.value.body // "") | test("<!-- orch-scope-reset "))
      | {at: (.value.created_at // ""), i: .key, body: (.value.body // "")}]
     | sort_by([.at, -.i]) | last) as $reset
  | ([$notes | to_entries[]
      | select((.value.body // "") | test("<!-- orch-scope-extend "))  # mutate:scope-extend-accumulate
      | {at: (.value.created_at // ""), i: .key, body: (.value.body // "")}]
     | sort_by([.at, -.i])
     | if $reset == null then .
       else map(select([.at, -.i] > [$reset.at, -$reset.i])) end) as $extensions
  | if $reset == null and ($extensions | length) == 0 then null
    else {
      at: (if ($extensions | length) > 0 then $extensions[-1].at else $reset.at end),
      body: ((if $reset == null then [] else [$reset.body] end)
             + ($extensions | map("## Additive supervisor scope amendment\n" + .body))
             | join("\n\n"))
    } end;

# The newest completed supervised repair, carried as evidence rather than as
# replacement scope. snapshot.jq exposes it on the ticket row and plan.jq
# freezes it into the next gate action. It never participates in merge history.
def active_supervised_repair_of($notes):
    ([$notes | to_entries[]
      | select((.value.body // "") | test("<!-- orch-supervised-repair "))
      | {at: (.value.created_at // ""), i: .key, body: (.value.body // "")}]
     | sort_by([.at, -.i]) | last) as $repair
  | if $repair == null then null else ($repair | del(.i)) end;

# A gate that deliberately returns a stale branch to implementation records
# the decision against the exact MR head it inspected.  The marker remains
# active only while that head is still current: reconciliation advances HEAD
# and retires the instruction without a second tracker write.  Consumers:
# snapshot.jq (suppress the false half-transition repair) and plan.jq (freeze
# the reconciliation instruction into the implementation action).
def active_base_reconcile_of($notes; $head):
    ([$notes | to_entries[] | .key as $i | .value as $note
      | [($note.body // "")
         | scan("<!-- orch-base-stale ([0-9a-fA-F]{7,40}) base=([A-Za-z0-9._/-]+) behind=([0-9]+|unknown) -->")]
      | to_entries[]
      | {at: ($note.created_at // ""), i: $i, mi: .key,
         body: ($note.body // ""), head: .value[0], base: .value[1],
         behind: .value[2]}]
     | map(select($head != null and
                  (. as $m | ($head | startswith($m.head)) or
                              ($m.head | startswith($head)))))
     | sort_by([.at, -.i, .mi]) | last) as $stale
  | if $stale == null then null else ($stale | del(.i, .mi)) end;

# A lane can finish its paid provider job and durably write rc/outcome while
# its host epilogue still owns the process id. It is then cleanup-eligible, not
# capacity-bearing. Keep the two predicates shared because snapshot.jq reports
# capacity and plan.jq consumes the same lane rows for harvest/admission.
def lane_cleanup_eligible:
    .state == "dead" or ((.rc // "-") != "-");
def lane_holds_capacity:
    .state != "dead" and ((.rc // "-") == "-"); # mutate:finished-lane-capacity

# Durations, shares and money, formatted the same way wherever they are
# printed. Consumers: report.jq and retro.jq, which `retro` prints one after
# the other — two spellings of an hour in one output is a reading error
# waiting to happen.
def hms($s): ($s // 0) as $x
  | if $x >= 3600 then "\($x / 3600 | floor)h\(($x % 3600) / 60 | floor)m"
    elif $x >= 60 then "\($x / 60 | floor)m\($x % 60)s" else "\($x)s" end;
def pct($n; $d): if ($d // 0) == 0 then "  -  "
                 else "\(($n * 1000 / $d | round) / 10)%" end;
def usd($n): "$\(($n * 100 | round) / 100)";

# A ticket's state, as the first of these labels it carries — mirrors the
# priority a lane's own state transitions enforce. P93: moved here (from
# snapshot.jq) so merge-queue.jq's narrow read computes the SAME state a full
# snapshot would, rather than a second, driftable guess (e.g. testing for the
# `merge-queue` label alone, which a ticket can carry stale alongside
# `blocked`). Consumers: snapshot.jq (every ticket row) and merge-queue.jq
# (the queue filter).
def state_of($labels):
    (["blocked", "merge-queue", "review", "in-progress", "ready-for-agent"]
     | map(select(. as $s | $labels | index($s))) | first) // null;

# P32: how many merge lanes have already failed on this ticket, from the
# `orch-merge-attempt` trailers `lane.sh merge-failed` writes. Consumer:
# the harvest step in the wave — the merge queue always takes the OLDEST
# merge-queue ticket, so one poisoned ticket is re-picked by every lane
# behind it until something counts the attempts and blocks it. (build-3
# 2026-08-03: three lanes in a row wedged on #50 while #52 and #53 waited.)
# P62: an attempt recorded with `base-red=` failed on a check that is red
# on clean origin/<base> — a base defect, not this ticket, so it never
# counts toward merge_attempt_cap (#26 and #15 burned full caps on
# main-is-red, and the spent caps had no reset when the fix merged).
# P93: moved here so merge-queue.jq's narrow read counts attempts the same
# way a full snapshot does. Consumers: snapshot.jq and merge-queue.jq.
# P96, two changes, both paid for by build-1 #26 (2026-08-07):
#   1. The match is the trailer's FULL form, not a bare substring. A note that
#      merely names `orch-merge-attempt` in prose used to count as an attempt —
#      and the blocked report the cap itself mandates has every reason to name
#      the marker it is reporting on. #26's did, so the count read 3 against a
#      cap of 2, past even a raised cap. The plain form is also what excludes
#      P62's base-red attempts: they carry ` base-red=… fix=…` before the `-->`
#      and so cannot match, which is the same exclusion the old second test did.
#   2. Attempts older than the newest reset marker do not count, exactly as
#      `rejections_of` retires verdicts older than an `orch-scope-reset`. Two
#      markers reset here: `orch-merge-reset` (lane.sh merge-reset — the merge
#      history is stale, e.g. a conflict a human untangled) and `orch-scope-
#      reset` (lane.sh rescope — the ticket became different work, which is a
#      superset). Before this a spent cap had no reset at all: the exits were
#      deleting the ticket's comments, raising `merge_attempt_cap` past the
#      count, or merging outside the queue. Ordering uses the created_at of the
#      notes themselves with the same `[.at, -.i]` tiebreak `rejections_of`
#      uses — one clock, the one the tracker stamps.
def merge_attempts_of($notes):
    ([$notes | to_entries[]
      | select((.value.body // "") | test("<!-- orch-(merge-reset|scope-(reset|extend)) "))
      | {at: (.value.created_at // ""), i: .key}]
     | sort_by([.at, -.i]) | last) as $reset
  | [$notes | to_entries[] | .key as $i | .value as $note
     | select((($note.body // "") | test("<!-- orch-merge-attempt \\d+ -->")))  # mutate:merge-attempt-anchor
     | {at: ($note.created_at // ""), i: $i}]
  | (if $reset == null then . else map(select([.at, -.i] > [$reset.at, -$reset.i])) end)  # mutate:merge-reset-cutoff
  | length;

# P62 release side: the park and its automatic release, derived rather
# than written. A ticket whose base-red attempts link a fix issue that is
# still OPEN is held out of the merge queue (the wave skips tickets with a
# merge_hold); the moment the fix merges — its issue closes, so it leaves
# the open set — the hold computes to null and the ticket re-enters on its
# own, with no requeue write and nothing for a wave to remember. Open-set
# inference is valid here because fix tickets are filed in this project
# (lane.sh fix-ticket). P93: moved here for merge-queue.jq. Consumers:
# snapshot.jq and merge-queue.jq.
# D-SNAP-18: the match is the trailer's FULL form — `<!-- … -->` and all —
# exactly as `merge_attempts_of` above was anchored by P96. The scan used to
# read the marker's INNER text anywhere in a note body, so any prose quoting
# it parked the ticket: the note that most wants to quote a trailer is the
# blocked report explaining WHY the ticket is parked, and markdown renders a
# raw `<!-- … -->` as nothing, so a writer quotes the inside of it in
# backticks. That gave a merge_hold naming a check and a fix issue no lane
# ever recorded, and the wave skipped the ticket for as long as that issue
# stayed open. Both halves of one mechanism now read the marker the same way.
# (A note quoting the whole trailer verbatim, delimiters included, still
# counts — the same limit `merge_attempts_of` accepts, and the same answer:
# the trailer is machinery, prose about it should name it, not reproduce it.)
# The check id is `\S+` rather than its character class because the anchors
# already bound it — and because a pattern with no `[…]` in it is one
# scripts/mutate.sh can substitute whole (registry: merge-hold-anchor); the
# writer side still validates the class, in lane.sh merge-failed.
def merge_hold_of($notes; $open_iids):
    ([$notes[] | (.body // "")
      | scan("<!-- orch-merge-attempt \\d+ base-red=(\\S+) fix=(\\d+) -->")  # mutate:merge-hold-anchor
      | {check: .[0], fix: (.[1] | tonumber)}]
     | map(select(.fix as $f | ($open_iids | index($f)) != null))) as $held
  | if ($held | length) == 0 then null
    else {checks: ($held | map(.check) | unique),
          fixes: ($held | map(.fix) | unique)} end;

# The lane id split, jq side: which ticket a lane belongs to and what it was
# doing. Its bash mirror is `_lane_type` in lib.sh (a hot-path string split,
# which is why it stays bash); each names the other, so a new lane kind added
# to one is visibly missing from the other. Consumer: render-events.jq.
def ref: if test("^[0-9]+$") then "#\(.)" else . end;
def stage($id):
  if   ($id | startswith("impl-"))  then {t: ($id | ltrimstr("impl-")  | ref), s: "implementation"}
  elif ($id | startswith("gate-"))  then {t: ($id | ltrimstr("gate-")  | sub("-r[0-9]+$"; "") | ref), s: "gate review"}
  elif ($id | startswith("merge-")) then {t: ($id | ltrimstr("merge-") | ref), s: "merge"}
  elif ($id | startswith("probe-")) then {t: "epic \($id | ltrimstr("probe-"))", s: "acceptance probe"}
  else {t: $id, s: "lane"} end;
