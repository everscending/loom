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

# The gate verdict trailer, in one regex. Emits [verdict, sha, class], class
# null when the trailer carries none — a PASS never does (lane.sh strips one
# that rides along) and a FAIL always does. Consumers: snapshot.jq's
# `judged_at` ("this HEAD is already judged", which reads the first two) and
# `rejections_of` (the same-class rejection stop, which reads all three), plus
# lane.sh's duplicate-verdict refusal. A change to the trailer format is one
# edit here and cannot half-land any more.
def orch_verdict_scan:
    scan("orch-verdict\\s+(PASS|FAIL)\\s+([0-9a-fA-F]{7,40})(?:\\s+class=([a-z0-9-]+))?");

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
      | select((.value.body // "") | test("<!-- orch-(merge|scope)-reset "))
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
def merge_hold_of($notes; $open_iids):
    ([$notes[] | (.body // "")
      | scan("orch-merge-attempt\\s+[0-9]+\\s+base-red=([A-Za-z0-9._:/#-]+)\\s+fix=([0-9]+)")
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
