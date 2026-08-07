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
