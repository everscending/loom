#!/usr/bin/env bash
# lane.sh — the WRITE half for lane sessions: every tracker mutation a lane
# needs, as one deterministic verb each. tick.sh stays read-only against the
# tracker (tick-test.sh enforces it); bootstrap.sh writes at setup time; this
# writes at lane time. Same split, third leg.
#
# Why this exists (paid for, build-1 2026-08-02): every permission denial that
# morning was a model hand-rolling plumbing — `glab api … body=@$LOOM_SCRATCH/…`
# (any $VAR/$(…) in a command defeats allowlist prefix-matching), inline
# `glab issue note -m` bodies (denied on length alone), label flips with the
# unassign rule forgotten. Models judge; scripts plumb. A lane that needs a
# mutation this file lacks has found a missing VERB — add it here, never a new
# allow rule.
#
#   lane.sh scratch                          print (create if needed) a private
#                                            scratch dir — a LITERAL path, so
#                                            no $VAR ever enters a command
#   lane.sh note <iid> [--file F]            post an issue comment from F or
#                                            stdin (heredoc-friendly)
#   lane.sh mr-note <mr-iid> [--file F]      same, on a merge request
#   lane.sh verdict <iid> pass|fail <sha> [--class <slug>] [--file F]
#                                            post the gate verdict (body from
#                                            F/stdin) with the orch-verdict
#                                            trailer appended, then flip the
#                                            label: pass → merge-queue,
#                                            fail → in-progress
#   lane.sh reconcile [<base>]               fetch + MERGE origin/<base> into
#                                            the branch — the only sanctioned
#                                            reconciliation; rc 3 = real
#                                            conflict (resolve or abort+block).
#                                            Re-installs dependencies when the
#                                            merge moved a manifest/lockfile,
#                                            so the gate tests this worktree
#                                            and not an hours-stale one
#   lane.sh merge-failed <iid> [--base-red <check-id> --fix <fix-iid>] [--file F]
#                                            record a merge attempt that did
#                                            NOT merge (conflict, red combined
#                                            gate, wedged lane), body from
#                                            F/stdin. Keeps the merge-queue
#                                            label; the count is what lets the
#                                            queue stop retrying one poisoned
#                                            ticket and advance to the next.
#                                            --base-red: the SAME check is red
#                                            on clean origin/<base> (prove it
#                                            with base-check first) — the
#                                            defect is on base, not in this
#                                            branch, so the attempt never
#                                            counts toward merge_attempt_cap
#                                            and the ticket parks until the
#                                            linked fix ticket merges
#   lane.sh base-check [--] <cmd...>         run <cmd> in a throwaway worktree
#                                            of clean origin/<base> (develop
#                                            if it exists, else main), print
#                                            its output, exit with its rc —
#                                            the evidence a --base-red claim
#                                            must be built on
#   lane.sh wait-ready --timeout <secs> [--interval <secs>] (--url <url> | -- <cmd...>)
#                                            poll a URL or command until it
#                                            succeeds or the deadline passes;
#                                            replaces a probe's hand-rolled
#                                            curl+sleep loop (P56 — probe lanes
#                                            averaged 162 turns, most of it
#                                            polling). One shell call, never a
#                                            hang: exits 0 ready, 1 not-ready
#                                            at the deadline — the caller's cue
#                                            to report the failure, not retry
#                                            forever
#   lane.sh rescope <iid> [--file F]          this ticket is now DIFFERENT work:
#                                            post what changed and retire the
#                                            rejections recorded before it. A
#                                            human's call only — refused inside
#                                            a lane or a wave
#   lane.sh fix-ticket --title <t> --tier <t> --milestone <m>
#                       [--blocked-by <iids>] [--force] [--file F]
#                                            file a fix ticket a wave can
#                                            actually schedule: applies all
#                                            FIVE of build-N (derived), fix,
#                                            tier::<t>, the epic milestone and
#                                            ready-for-agent, or refuses.
#                                            --blocked-by writes a `## Blocked
#                                            by` section (comma-separated
#                                            iids) the scheduler already
#                                            parses. Before creating, refuses
#                                            on a near-duplicate title among
#                                            open fix tickets in the same
#                                            milestone unless --force.
#   lane.sh probe-result <build-iid> <epic-slug> pass|fail [--file F]
#                                            post the epic probe's report on
#                                            the Build issue with a PASS/FAIL
#                                            header, feed the outcome to the
#                                            build ticker; a PASS also closes
#                                            the epic's milestone
#   lane.sh transition <iid> <state>         move the ticket's state label;
#                                            ready-for-agent also clears the
#                                            assignee (the unblock rule — a
#                                            claimed "ready" ticket is
#                                            invisible to the scheduler)
#   lane.sh claim <iid>                      assign self + in-progress (the
#                                            first write of an impl lane)
#   lane.sh submit <iid> [--title <t>] [--file F]
#                                            the LAST write of an impl lane:
#                                            opens the MR (description from
#                                            F/stdin, `Closes #<iid>` appended)
#                                            and moves the label to `review`,
#                                            in one call. Refuses an unpushed
#                                            HEAD, a closed ticket, and a
#                                            ticket the gate already passed;
#                                            re-run after a death completes
#                                            whichever half is missing instead
#                                            of opening a second MR
#
# Long bodies: pipe them.   lane.sh note 7 <<'EOF' … EOF
# Every verb is safe to re-run; nothing here deletes.
set -euo pipefail

# P73: the derivations this file used to keep its own copy of — the
# base-branch rule, the lockfile→installer table, `die` — live in lib.sh
# beside this script. This is NOT the thing "lane.sh deliberately stands
# alone" was ever about: that rule is about not sourcing tick.sh, whose top
# level makes directories, resolves REPO_ROOT and can exit. lib.sh is pure
# functions and runs nothing at source time, so the write half loses no
# independence by sharing it — and stops drifting from the read half.
LIB_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
[ -f "$LIB_SH" ] \
    || { echo "lane.sh: $LIB_SH is missing — it holds the shared derivations and ships beside lane.sh" >&2; exit 2; }
. "$LIB_SH"
DIE_RC=2   # every refusal in this file exits 2, and briefs read that code
# Same seam as tick.sh, for the same reason: the test suite exercises these
# verbs against a capture stub, never the real tracker.
# P86: every tracker call this file makes goes through the driver for the
# repo's declared tracker. `glab` used to be named here and at seventeen call
# sites below; it is now named in scripts/trackers/gitlab.sh and nowhere else.
TRACKER="$(_tracker_cmd "${LIB_SH%/*}" "${LOOM_REPO:-.}")"
[ -x "$TRACKER" ] || die "tracker driver '$TRACKER' is missing or not executable"

STATES="ready-for-agent in-progress review merge-queue blocked"

# Every state-changing verb appends one line to the build's event stream via
# `tick.sh event` (sibling script; LOOM_REPO reaches lanes via spawn-lane's
# export, so a worktree cwd still resolves the right state dir). Consumer:
# `tick.sh render-events` — the live build ticker. Best-effort by design: a
# tracker write must never fail because the ticker could not be fed.
TICK_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tick.sh"
_lane_ev() { "$TICK_SH" event "$@" >/dev/null 2>&1 || true; }

# Stage stdin/--file into a private temp file so the tracker command the
# harness sees contains only a literal path this script produced.
_stage_body() { # [--file F] ; prints staged file path
    local src="" tmp
    if [ "${1:-}" = "--file" ]; then
        [ -n "${2:-}" ] || die "--file needs a path"
        src="$2"; [ -f "$src" ] || die "no such file: $src"
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/lane-body.XXXXXX")
    if [ -n "$src" ]; then cat "$src" > "$tmp"; else cat > "$tmp"; fi
    [ -s "$tmp" ] || die "empty body (pass --file or pipe stdin)"
    printf '%s\n' "$tmp"
}

_post_note() { # <issue|mr> <iid> <bodyfile> — the driver's own vocabulary
    "$TRACKER" note-add "$1" "$2" "$3"
    echo "lane.sh: note posted on $1/$2"
}

# P36: is this process running inside something the loop spawned? A lane
# exports LOOM_LANE_ID; a wave session is launched carrying LOOM_WAVE_PROMPT.
# A human at a terminal has neither. Consumer: the release guard below — the
# one write no automated caller may ever make.
_automated_caller() {
    [ -n "${LOOM_LANE_ID:-}" ] || [ -n "${LOOM_WAVE_PROMPT:-}" ]
}

RELEASE_HOLD=0   # set by `transition --release-hold`; never inherited

# P47's fail-closed read, in one place. Every guard below asks the tracker a
# question, and "could not read" is never an answer: a transient API failure
# that read as "not blocked" let an orphaned lane stomp a human hold, one that
# read as "not closed" put state labels back on a finished ticket, and one that
# read as "no open MR" closed a ticket over an unmerged branch.
#
# Two properties this helper must keep, because both were paid for:
#   * The refusal text belongs to the CALLER. Each question refuses for its own
#     reason and the human needs to know which one went unanswered, so the
#     clause is an argument and the die happens at the asking site.
#   * A failed read is NEVER remembered. Only a successful body is cached, so
#     `_blocked_guard` and the verb that called it share ONE round trip (both
#     `transition` and `submit` used to fetch the same issue twice) while every
#     question still has a read that can fail closed on its own.
# Any write that could change an answer forgets the body again — see
# `_forget_issue` in `_set_state`, after the MR opens in `cmd_submit` and after
# the merge in `cmd_merge`. No guard is ever satisfied by a photograph taken
# before the write it guards; only the reads that ask the same question of the
# same unchanged tracker are the ones that collapse.
_ISSUE_IID=""; _ISSUE_JSON=""; _OPEN_MR=""
_forget_issue() { _ISSUE_IID=""; _ISSUE_JSON=""; }

_read_issue() { # <iid> <what-a-failed-read-would-mean> — sets _ISSUE_JSON, or dies
    local iid="$1" refusal="$2" body rc
    [ "$iid" = "$_ISSUE_IID" ] && return 0
    body=$("$TRACKER" issue "$iid" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] \
        || die "issue $iid: could not read issue state (tracker read failed, rc=$rc) — $refusal Retry once the tracker is reachable."
    _ISSUE_IID="$iid"; _ISSUE_JSON="$body"
    return 0
}

# `closed_by`, never `related_merge_requests`: the looser endpoint lists any MR
# that merely mentions the issue, and on build-1 2026-08-03 issue #1 listed
# #21's open MR alongside its own. Not cached — an MR's state is exactly what
# the writes around these calls change.
_open_mr_closing() { # <iid> <what-a-failed-read-would-mean> — sets _OPEN_MR, or dies
    local iid="$1" refusal="$2" body rc
    body=$("$TRACKER" issue-closed-by "$iid" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] \
        || die "issue $iid: could not read closed_by (tracker read failed, rc=$rc) — $refusal"
    _OPEN_MR=$(printf '%s' "$body" | jq -r '[.[] | select(.state == "opened")] | .[0].iid // empty' || true)
    return 0
}

_blocked_guard() { # <iid> [intended-state] — a human hold outranks machine flow
    # `blocked` is STICKY: labels are last-writer-wins, so before this guard
    # an in-flight lane could stomp a human hold — an orphaned impl-29-r2
    # flipped its held ticket to review and #29 merged straight through the
    # hold (2026-08-02). Blocking itself may always proceed; every other
    # direction bounces.
    #
    # P36: releasing a hold is a HUMAN act and needs `--release-hold` said out
    # loud, which an automated caller may not say at all. `ready-for-agent`
    # used to be a free pass here, so the release path was a plain label write
    # any wave could make — and one did: a hold comment ended with the sentence
    # "Release: when #48 merges, /loom unblock 67", a wave read that
    # prose as an instruction addressed to itself, and requeued the held ticket
    # nine seconds later. The hold is the one mechanism that must outrank
    # everything the loop decides on its own, so the prose can stay wrong
    # forever as long as the write is refused. (Paid for: #67, build-3
    # 2026-08-04.)
    local iid="$1" intended="${2:-}"
    case "$intended" in blocked) return 0 ;; esac
    # P47: a read failure here used to fall through as "not blocked" (an empty
    # pipe fails jq -e, the `if` reads false, the guard passes) — an orphaned
    # lane could then stomp a human hold on a transient API blip, not just a
    # race. Read succeeded-and-says-no is the only path that may proceed;
    # read failed dies instead of guessing.
    _read_issue "$iid" "refusing to guess whether it carries a human hold."
    if printf '%s' "$_ISSUE_JSON" | jq -e '.labels | index("blocked")' >/dev/null 2>&1; then
        [ "$RELEASE_HOLD" = 1 ] \
            || die "issue $iid is blocked — a human hold. Refusing to advance it. Releasing a hold is a human decision, made with 'transition $iid <state> --release-hold'; nothing written in the ticket authorises it."
        if _automated_caller; then
            die "issue $iid is blocked — a human hold, and this is an automated session (${LOOM_LANE_ID:-wave}). --release-hold is refused here: a hold is released by a person, never by a lane or a wave acting on ticket text."
        fi
    fi
    return 0
}

_set_state() { # <iid> <state> [extra -f args...]
    local iid="$1" state="$2"; shift 2
    _blocked_guard "$iid" "$state"
    local remove="" s
    for s in $STATES; do [ "$s" = "$state" ] || remove="$remove,$s"; done
    "$TRACKER" issue-relabel "$iid" --add "$state" --remove "${remove#,}" "$@"
    _forget_issue   # the labels just changed; no later guard may read the old set
    echo "lane.sh: issue $iid → $state"
}

_check_iid() { case "${1:-}" in ''|*[!0-9]*) die "bad iid: '${1:-}'";; esac; }

cmd_scratch() {
    local d="${LOOM_SCRATCH:-}"
    if [ -z "$d" ]; then d=$(mktemp -d "${TMPDIR:-/tmp}/lane-scratch.XXXXXX")
    else mkdir -p "$d"; fi
    printf '%s\n' "$d"
}

cmd_note()    { _check_iid "${1:-}"; local f; f=$(_stage_body "${@:2}"); _post_note issue "$1" "$f"; }
cmd_mr_note() { _check_iid "${1:-}"; local f; f=$(_stage_body "${@:2}"); _post_note mr "$1" "$f"; }

cmd_verdict() { # <iid> pass|fail <head-sha> [--class <kebab-slug>] [--file F]
    local iid="${1:-}" res="${2:-}" sha="${3:-}"
    _check_iid "$iid"
    case "$res" in pass|fail) ;; *) die "verdict must be pass|fail" ;; esac
    case "$sha" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) die "bad head sha: '$sha'" ;; esac
    # P30: a FAIL names its defect class in the machine-readable trailer.
    # Two consecutive same-class FAILs make the wave stop for a design
    # decision instead of a third same-tier guess (#39, 2026-08-02).
    local klass="" bodyargs=()
    set -- "${@:4}"
    while [ $# -gt 0 ]; do case "$1" in
        --class) klass="${2:-}"; [ -n "$klass" ] || die "--class needs a slug"; shift 2 ;;
        *) bodyargs+=("$1"); shift ;;
    esac; done
    case "$klass" in *[!a-z0-9-]*) die "--class must be a kebab slug (a-z, 0-9, -): '$klass'" ;; esac
    local up; up=$(printf '%s' "$res" | tr 'a-z' 'A-Z')
    # P69: the same-class rejection stop (P30) and the SKILL.md prose both
    # assume a FAIL always carries a class and a PASS never does, but the verb
    # itself enforced neither — three builds running produced unclassed FAILs
    # and spurious classes riding along on PASS trailers (ai-workout build-1,
    # 2026-08-07). Machinery, not prose: refuse the first, strip the second.
    if [ "$res" = fail ]; then
        [ -n "$klass" ] \
            || die "verdict: a FAIL needs --class <slug> — without it the same-class rejection stop (P30) has nothing to match"
    else
        klass=""
    fi
    # P69: a second identical ticket+SHA+outcome trailer is a duplicate
    # re-gate, not a new verdict (duplicate PASS trailers landed on #8 and
    # #30, ai-workout build-1) — refuse it before anything is staged or
    # posted. Fail closed on the read, same as the blocked-hold guard above:
    # a transient API failure must never read as "definitely not a duplicate".
    local _notes rc
    _notes=$("$TRACKER" issue-notes "$iid" --limit 100 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] \
        || die "issue $iid: could not read existing verdict trailers (tracker read failed, rc=$rc) — refusing to guess whether this is a duplicate. Retry once the tracker is reachable."
    # P72: the trailer regex is `orch_verdict_scan` in lib.jq, the one the
    # snapshot reads verdicts back with. It used to be written out here as a
    # third copy, so a trailer format change could land in the reader and not
    # in this refusal.
    local jqd; jqd="$(_jq_lib_dir "${LIB_SH%/*}")"
    if printf '%s' "$_notes" | jq -L "$jqd" -e --arg up "$up" --arg sha "$sha" \
        'include "lib"; [.[] | (.body // "") | orch_verdict_scan | select(.[0] == $up and .[1] == $sha)] | length > 0' \
        >/dev/null 2>&1
    then
        die "issue $iid already carries an orch-verdict $up $sha trailer — refusing a duplicate"
    fi
    local f; f=$(_stage_body ${bodyargs[@]+"${bodyargs[@]}"})
    printf '\n\n<!-- orch-verdict %s %s%s -->\n' "$up" "$sha" "${klass:+ class=$klass}" >> "$f"
    # Note first, label second: a verdict note with no label flip is repaired
    # by the next wave (it reads the trailer); a label flip with no note is a
    # verdict that never happened.
    _post_note issue "$iid" "$f"
    if [ "$res" = pass ]; then _set_state "$iid" merge-queue
    else _set_state "$iid" in-progress; fi
    _lane_ev gate_verdict ticket "$iid" verdict "$up" sha "$sha"
}

cmd_merge_failed() { # <iid> [--file F]
    # P32: a merge attempt that did not merge. The merge step always takes the
    # OLDEST `merge-queue` ticket, so a ticket that poisons its merge lane is
    # picked again by every lane after it — three consecutive lanes wedged on
    # #50 while #52 and #53 sat behind it (build-3, 2026-08-03). Counting the
    # attempts is what lets the queue give up on one ticket and advance.
    #
    # The count has to survive in the tracker, not the run directory: it
    # decides whether a ticket gets blocked, and decisions are tracker-state.
    # Hence a trailer, exactly like `orch-verdict`. The ticket KEEPS its
    # `merge-queue` label here — this verb records an attempt, it does not
    # judge. Blocking on the cap is the wave's call, via `transition`.
    local iid="${1:-}" merged_mr
    _check_iid "$iid"
    # A chained merge lane can land WHILE a wave is mid-flight. The wave
    # snapshots, the lane merges 90s later, the wave then harvests against its
    # now-stale photograph, sees no live merge lane, and concludes the merge
    # never happened — recording a failed attempt against a ticket that is
    # already merged and closed, then blocking it one step later. Because the
    # wave did not perform the merge, nothing prompts it to re-read. So the
    # check lives here, where every path must pass: a merged MR is proof the
    # attempt succeeded, whatever the caller's snapshot says.
    # (Paid for: #23, 2026-08-03 — merged at 22:23:17, blocked at 22:24:29,
    # with a confident blocked report citing a merge lane "stale for ~5h" on a
    # ticket 13 minutes old.)
    # P47: this read must fail closed too — a transient API failure must never
    # read as "definitely not merged" and let a failed-merge note land on a
    # ticket that in fact just succeeded.
    local _closed_by rc
    _closed_by=$("$TRACKER" issue-closed-by "$iid" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] \
        || die "issue $iid: could not read closed_by (tracker read failed, rc=$rc) — refusing to record a merge-failed attempt blind; cannot rule out the merge having already succeeded."
    merged_mr=$(printf '%s' "$_closed_by" | jq -r '[.[] | select(.state == "merged")] | .[0].iid // empty' || true)
    [ -z "$merged_mr" ] \
        || die "issue $iid already has MERGED MR !$merged_mr — the merge succeeded; refusing to record a failed attempt. Re-read the ticket: your snapshot is stale."
    # P62: an attempt that failed on a check that is ALSO red on clean
    # origin/<base> is not this ticket's failure — merge-12 and merge-26 both
    # failed on a defect already on main, #26 and #15 burned their full caps
    # on it, and when the fix ticket merged the spent caps had no reset
    # (ai-workout build-1, 2026-08-07: seven incidents, one build halt).
    # `base-red=` in the trailer is what keeps the attempt OUT of the cap
    # count, and `fix=` is what releases the park: snapshot holds the ticket
    # out of the merge queue exactly while that fix issue is open. Both facts
    # or neither — a base-red attempt with no fix link would park the ticket
    # with nothing that can ever release it.
    local klass="" fixiid="" bodyargs=()
    set -- "${@:2}"
    while [ $# -gt 0 ]; do case "$1" in
        --base-red) klass="${2:-}"; [ -n "$klass" ] || die "--base-red needs a check id"; shift 2 ;;
        --fix) fixiid="${2:-}"; [ -n "$fixiid" ] || die "--fix needs an issue iid"; shift 2 ;;
        *) bodyargs+=("$1"); shift ;;
    esac; done
    if [ -n "$klass" ]; then
        case "$klass" in *[!A-Za-z0-9._:/#-]*) die "--base-red check id may use only A-Za-z0-9 . _ : / # - (no spaces): '$klass'" ;; esac
        [ -n "$fixiid" ] || die "--base-red needs --fix <fix-iid>: the linked fix ticket is what un-parks this ticket when it merges (file one with lane.sh fix-ticket first)"
        _check_iid "$fixiid"
    elif [ -n "$fixiid" ]; then
        die "--fix only accompanies --base-red"
    fi
    local f; f=$(_stage_body ${bodyargs[@]+"${bodyargs[@]}"})
    printf '\n\n<!-- orch-merge-attempt %s%s -->\n' "$iid" \
        "${klass:+ base-red=$klass fix=$fixiid}" >> "$f"
    _post_note issue "$iid" "$f"
    _lane_ev merge_failed ticket "$iid" ${klass:+base_red "$klass"}
    echo "lane.sh: issue $iid — merge attempt recorded${klass:+ (base-red: $klass, fix #$fixiid — does not count toward the cap)}"
}

cmd_base_check() { # [--] <cmd...> — run <cmd> against clean origin/<base>
    # P62: the evidence step under a --base-red claim. The falsification risk
    # is misattribution — the branch has a real defect that HAPPENS to also be
    # red on base, and a lane that compared mere redness would retry forever —
    # so the caller must run the one failing check (same test id), and this
    # verb only supplies the clean-base ground to run it on: a throwaway
    # detached worktree at freshly-fetched origin/<base>, removed on the way
    # out whatever the rc. A script, not instructions, for the reconcile
    # reason: a lane improvising this with checkout/stash gymnastics in its
    # own worktree would dirty the branch it is about to merge.
    [ "${1:-}" = "--" ] && shift
    [ $# -gt 0 ] || die "base-check: no command given (usage: lane.sh base-check [--] <cmd...>)"
    git fetch origin >/dev/null 2>&1 || die "base-check: git fetch failed"
    local base
    base=$(_detect_base .)
    git show-ref --verify --quiet "refs/remotes/origin/$base" 2>/dev/null \
        || die "base-check: origin/$base does not exist"
    local wtp rc=0
    wtp=$(mktemp -d "${TMPDIR:-/tmp}/lane-base-check.XXXXXX")
    git worktree add --detach "$wtp/base" "origin/$base" >/dev/null 2>&1 \
        || { rmdir "$wtp" 2>/dev/null || true; die "base-check: could not create a worktree at origin/$base"; }
    ( cd "$wtp/base" && "$@" ) && rc=0 || rc=$?
    git worktree remove --force "$wtp/base" >/dev/null 2>&1 || true
    rmdir "$wtp" 2>/dev/null || true
    echo "lane.sh: base-check on clean origin/$base exited rc=$rc" >&2
    return "$rc"
}

cmd_wait_ready() { # --timeout <secs> [--interval <secs>] (--url <url> | -- <cmd...>)
    # P56: the probe brief already told sessions to poll under a hard attempt
    # cap, but that cap was prose in a generated brief, not anything the
    # machine enforced — and most of a probe's 162-turn average was the poll
    # loop itself, one model turn per curl+sleep. This is that loop as a
    # single deterministic call: it returns ready/not-ready, it can never run
    # past its own deadline, and it costs one shell call instead of a dozen
    # model turns. Same argument P32/P36/etc already made for tracker writes,
    # applied to spend instead of correctness.
    local timeout="" interval=2 url=""
    while [ $# -gt 0 ]; do case "$1" in
        --timeout)  timeout="${2:-}";  shift 2 ;;
        --interval) interval="${2:-}"; shift 2 ;;
        --url)      url="${2:-}";      shift 2 ;;
        --)         shift; break ;;
        *) break ;;
    esac; done
    case "$timeout" in ''|*[!0-9]*|0) die "wait-ready: --timeout must be a positive integer (seconds) — an unbounded poll is exactly the turn-burn this verb exists to remove" ;; esac
    case "$interval" in ''|*[!0-9]*|0) die "wait-ready: --interval must be a positive integer (seconds), default 2" ;; esac
    if [ -n "$url" ]; then
        [ $# -eq 0 ] || die "wait-ready: pass either --url or -- <cmd...>, not both"
        set -- curl -fsS -o /dev/null "$url"
    fi
    [ $# -gt 0 ] || die "wait-ready: need --url <url> or -- <cmd...>"
    local deadline elapsed=0
    deadline=$(( $(date +%s) + timeout ))
    while :; do
        if "$@" >/dev/null 2>&1; then
            echo "lane.sh: ready after ${elapsed}s — $*"
            return 0
        fi
        [ "$(date +%s)" -lt "$deadline" ] \
            || { echo "lane.sh: not ready after ${timeout}s (deadline hit) — $* — this is a failure to report, not a hang" >&2; return 1; }
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
}

cmd_rescope() { # <iid> [--file F]
    # P37: retire the rejection cap when a ticket becomes DIFFERENT WORK.
    # `rejections_of` (tick.sh) derives the whole history by scanning every
    # `orch-verdict FAIL` trailer in the thread, and that scan is deliberately
    # un-losable — the fetch was widened twice so a ticket could not shed its
    # history by passing through `blocked`. So there was no way to say "this is
    # not the same ticket any more": #67 was rejected three times over
    # browser-side arrival-order pairing, a human then narrowed it to a bounded
    # give-up and moved the race to #48, #48 merged and deleted the pairing code
    # outright — and the rewritten ticket came back to the board carrying 3 of 3
    # rejections against machinery that no longer existed. Its first gate FAIL
    # would have blocked it on the spot, and same_class_tail 3 would have
    # skipped even the rework round. It passed, so it did not bite that time.
    # (build-3, 2026-08-04.)
    #
    # The marker is a tracker comment, not run state: the cap decides whether a
    # ticket gets blocked, and decisions are tracker-state (constitution rule
    # 1), so a fresh session reads the same history any wave does. The old
    # trailers stay in the thread — this retires the cap, it does not hide it.
    local iid="${1:-}"
    _check_iid "$iid"
    # Refused for automated callers, exactly as `--release-hold` is, and for the
    # same reason: re-scoping is a human's judgement about what a ticket IS. A
    # lane that could reset its own cap has no cap — and the ticket prose that
    # would talk it into doing so is the same prose the hold guard already
    # refuses to obey.
    if _automated_caller; then
        die "rescope is refused in an automated session (${LOOM_LANE_ID:-wave}): retiring a ticket's rejection history is a human's decision about what the ticket now IS, never a lane's or a wave's."
    fi
    # A body is mandatory (_stage_body refuses an empty one): the comment IS the
    # record of what changed, and a bare marker retires a cap while explaining
    # nothing to the next reader.
    local f; f=$(_stage_body "${@:2}")
    printf '\n\n<!-- orch-scope-reset %s -->\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$f"
    _post_note issue "$iid" "$f"
    _lane_ev ticket_rescope ticket "$iid"
    echo "lane.sh: issue $iid re-scoped — rejections recorded before this note no longer count"
}

cmd_blocked_report() { # <iid> [--category <slug>] [--file F]
    # P78: the blocked report used to be a hand-composed comment. SKILL.md
    # described its CONTENTS — category, what each attempt tried, branch/MR
    # links, the one decision needed — and nothing wrote it, so nothing could
    # find it again. Every other fact `snapshot.jq` mines out of a thread has a
    # trailer to locate it by (`orch-verdict`, `orch-merge-attempt`,
    # `orch-scope-reset`); this one had none, which is why the human triaging a
    # blocked ticket had to read the whole thread by eye.
    #
    # Recording only, exactly like `merge-failed`: this verb writes the report,
    # it does not judge. The wave still calls `transition <n> blocked` — which
    # `_blocked_guard` always permits, since blocking is the direction nothing
    # needs protecting from.
    local iid="${1:-}" category="" bodyargs=()
    _check_iid "$iid"
    set -- "${@:2}"
    while [ $# -gt 0 ]; do case "$1" in
        --category) category="${2:-}"; [ -n "$category" ] || die "--category needs a value"; shift 2 ;;
        *) bodyargs+=("$1"); shift ;;
    esac; done
    # A label-safe slug, for the same reason `verdict --class` takes one: it is
    # read back by a parser, and a category carrying a `-->` or a newline ends
    # the trailer early and takes the rest of the comment with it.
    case "$category" in
        ''|*[!A-Za-z0-9._-]*) [ -z "$category" ] \
            || die "blocked-report: --category must be a slug (letters, digits, . _ -), got '$category'" ;;
    esac
    # Mandatory body, as `rescope` has: the comment IS the report, and a bare
    # trailer blocks a ticket while telling the human nothing.
    local f; f=$(_stage_body "${bodyargs[@]+"${bodyargs[@]}"}")
    printf '\n\n<!-- orch-blocked%s %s -->\n' \
        "${category:+ category=$category}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$f"
    _post_note issue "$iid" "$f"
    _lane_ev ticket_blocked_report ticket "$iid" ${category:+category "$category"}
    echo "lane.sh: blocked report posted on issue $iid${category:+ (category: $category)}"
}

cmd_model_tier() { # <iid> <tier>
    # P78: `snapshot.jq`'s `model_of` has read `model::<tier>` since P31, and
    # nothing has ever written one — a human escalation meant editing labels in
    # the tracker UI. `triage` offers escalation as one of its six actions, so
    # it needs a command.
    #
    # Refused for automated callers, like `rescope` and `--release-hold`: which
    # model a ticket deserves is a human's read of why the last round failed,
    # and a lane that could escalate itself has no chain.
    local iid="${1:-}" tier="${2:-}"
    _check_iid "$iid"
    [ -n "$tier" ] || die "usage: lane.sh model-tier <iid> <tier>"
    if _automated_caller; then
        die "model-tier is refused in an automated session (${LOOM_LANE_ID:-wave}): escalating a ticket's model is a human's judgement about why the last round failed, never a lane's or a wave's."
    fi
    case "$tier" in *[!A-Za-z0-9._-]*|'') die "model-tier: '$tier' is not a label-safe tier (letters, digits, . _ -)" ;; esac
    # Deliberately NOT restricted to the four `model_rank` knows: that ranking
    # exists only to break the two-labels case, and its comment is explicit
    # that a human may name any model the CLI accepts. An unknown tier resolves
    # and ranks below the known ones, so the only thing worth doing here is
    # saying so out loud.
    case "$tier" in haiku|sonnet|fable|opus) ;; *)
        echo "lane.sh: note — '$tier' is not one of haiku|sonnet|fable|opus; it will resolve but ranks below all of them" >&2 ;;
    esac
    # One `model::` label at a time. Two would resolve (the higher rank wins)
    # but the board would show a ticket claiming both, and the next human to
    # read it cannot tell which one is the live decision.
    _read_issue "$iid" "refusing to guess which model labels it already carries."
    local drop
    drop=$(printf '%s' "$_ISSUE_JSON" \
        | jq -r '[.labels[]? | select(startswith("model::"))] | join(",")' || true)
    "$TRACKER" issue-relabel "$iid" --add "model::$tier" ${drop:+--remove "$drop"}
    _forget_issue
    _lane_ev ticket_model_tier ticket "$iid" tier "$tier"
    echo "lane.sh: issue $iid → model::$tier"
}

cmd_fix_ticket() { # --title <t> --tier <docs|logic|api|ui> --milestone <title> [--blocked-by <iids>] [--force] [--file F]
    # P33: a fix ticket needs FIVE things to be schedulable — `build-N`, `fix`,
    # a `tier::` label, the defective epic's milestone, AND a state label. The
    # skill prose enumerated four of them and left "entering at ready" as
    # narrative, so a probe lane did exactly what the list said and filed #64
    # with no state: in the build's universe, in no state, invisible to the
    # ready set, sitting unclaimed while four lanes idled (2026-08-04). Same
    # shape as the unblock-without-unassign bug — the effect described, the
    # mechanism unnamed. So it stops being prose: one verb applies all five or
    # refuses, and `--tier`/`--milestone` are required because a tier-less
    # ticket has no gate suite and a milestone-less one lets its epic close
    # over an open defect.
    #
    # P65: a probe-filed ticket used to enter the graph edgeless and
    # unchecked for twins — #68 duplicated #67, #69 ran while the decision it
    # depended on (#71) sat blocked, ai-workout build-1 2026-08-07. So this
    # verb also takes the edges (`--blocked-by`, written into the `##
    # Blocked by` section the scheduler already parses — SKILL.md's tracker
    # vocabulary) and checks for a near-duplicate open fix ticket in the same
    # milestone before creating, refusing unless `--force`: the filing lane
    # decides with eyes open instead of the graph silently growing a twin.
    local title="" tier="" ms="" blockedby="" force=false bodyargs=()
    while [ $# -gt 0 ]; do case "$1" in
        --title)      title="${2:-}"; [ -n "$title" ] || die "--title needs a value"; shift 2 ;;
        --tier)       tier="${2:-}";  shift 2 ;;
        --milestone)  ms="${2:-}";    shift 2 ;;
        --blocked-by) blockedby="${2:-}"; shift 2 ;;
        --force)      force=true; shift ;;
        *) bodyargs+=("$1"); shift ;;
    esac; done
    [ -n "$title" ] || die "fix-ticket: --title is required"
    case "$tier" in docs|logic|api|ui) ;;
        *) die "fix-ticket: --tier must be docs|logic|api|ui (got '${tier:-<empty>}') — without it no gate lane can pick a suite" ;; esac
    [ -n "$ms" ] || die "fix-ticket: --milestone is required — completeness and the re-probe derive from membership, so a milestone-less fix ticket lets its epic close over an open defect"
    local f; f=$(_stage_body ${bodyargs[@]+"${bodyargs[@]}"})
    if [ -n "$blockedby" ]; then
        # Same section, same parser the scheduler already reads
        # (snapshot.jq's `section("Blocked by")` / `scan("#([0-9]+)")`) — a
        # second format here would be invisible to it.
        printf '\n\n## Blocked by\n\n' >> "$f"
        local _bb b
        IFS=',' read -ra _bb <<< "$blockedby"
        for b in "${_bb[@]}"; do
            b="${b//[[:space:]]/}"
            case "$b" in ''|*[!0-9]*) die "fix-ticket: --blocked-by ids must be numeric issue iids (got '$b')" ;; esac
            printf -- '- #%s\n' "$b" >> "$f"
        done
    fi
    # The build label is DERIVED, never asked for: the scheduler's universe is
    # "open issues labeled build-N" for the highest open `Build N` issue, and a
    # lane that had to name it could name last week's.
    # P70: through the driver's paginating list read, like every other list
    # read in this skill. A
    # bare `per_page=100` is page 1 and says nothing about the rest, so on a
    # board with more than 100 open issues the `Build N` issue itself can fall
    # off the read and every filing die "no open Build N issue".
    local blabel
    blabel=$("$TRACKER" issues-open 2>/dev/null \
        | jq -r '[.[] | select((.title // "") | test("^Build [0-9]+$"))]
                 | sort_by(.iid) | last | (.title // "") | sub("^Build "; "build-")')
    case "$blabel" in build-[0-9]*) ;; *) die "fix-ticket: no open \`Build N\` issue — cannot derive the build label" ;; esac
    local mid
    mid=$("$TRACKER" milestones 2>/dev/null \
        | jq -r --arg t "$ms" '.[] | select(.title == $t) | .id' | head -1)
    [ -n "$mid" ] || die "fix-ticket: no milestone titled '$ms'"
    if ! $force; then
        # Near-duplicate = word-overlap (Jaccard) >= 0.5 against every OTHER
        # open fix ticket in the same milestone. A heuristic, like tier_of's
        # and graph's in snapshot.jq — cheap enough to run on every filing,
        # and wrong only in the direction that costs a --force flag, never
        # the direction that silently ships a twin. Paginated (P70): a missed
        # page reads as "no twin" and files the duplicate this check exists to
        # stop.
        local dups
        dups=$("$TRACKER" issues-by-label fix opened 2>/dev/null \
            | jq -c --arg ms "$ms" --arg newt "$title" '
                def words: ascii_downcase | gsub("[^a-z0-9]+"; " ") | split(" ") | map(select(length > 0));
                ($newt | words) as $nw
                | [ .[] | select((.milestone.title // "") == $ms)
                    | . + {sim: ((.title // "" | words) as $ew
                                 | (($nw - ($nw - $ew)) | length) as $inter
                                 | (($nw + $ew) | unique | length) as $uni
                                 | if $uni == 0 then 0 else ($inter / $uni) end)}
                    | select(.sim >= 0.5)
                    | {iid, title, sim} ]')
        if [ -n "$dups" ] && [ "$dups" != "[]" ] && [ "$dups" != "null" ]; then
            local hits; hits=$(printf '%s' "$dups" | jq -r '.[] | "#\(.iid) \"\(.title)\""' | tr '\n' ';' | sed 's/;$//')
            die "fix-ticket: near-duplicate open fix ticket(s) in milestone '$ms' — $hits — refile with --force if this is genuinely separate work"
        fi
    fi
    local iid
    iid=$("$TRACKER" issue-create --title "$title" --body-file "$f" \
        --labels "$blabel,fix,tier::$tier,ready-for-agent" \
        --milestone-id "$mid" 2>/dev/null)
    [ -n "$iid" ] || die "fix-ticket: create failed"
    echo "lane.sh: filed #$iid — $blabel, fix, tier::$tier, ready-for-agent, milestone '$ms'${blockedby:+, blocked by $blockedby}"
    _lane_ev fix_filed ticket "$iid" tier "$tier"
}

cmd_probe_result() { # <build-iid> <epic-slug> pass|fail [--file F]
    # A probe's outcome used to live only inside its report note, so the
    # ticker showed "probe started … probe ended (rc 0)" and never the
    # verdict (asked for by the human, 2026-08-02). Same shape as
    # cmd_verdict: the tracker note is the record, the event feeds the
    # ticker, one verb does both so they cannot drift.
    local iid="${1:-}" slug="${2:-}" res="${3:-}"
    _check_iid "$iid"
    [ -n "$slug" ] || die "probe-result: need <epic-slug>"
    case "$res" in pass|fail) ;; *) die "probe-result must be pass|fail" ;; esac
    local f up; f=$(_stage_body "${@:4}")
    up=$(printf '%s' "$res" | tr 'a-z' 'A-Z')
    local hdr; hdr=$(mktemp "${TMPDIR:-/tmp}/lane-body.XXXXXX")
    printf '**Epic acceptance probe `%s`: %s**\n\n' "$slug" "$up" > "$hdr"
    cat "$f" >> "$hdr"
    _post_note issue "$iid" "$hdr"
    _lane_ev probe_result epic "$slug" result "$up"
    # A PASS also closes the epic's milestone — completeness stays DERIVED
    # (nothing reads milestone state), but a finished epic left open misleads
    # the human reading the tracker, same argument as closing Build issues
    # (asked for by the human, 2026-08-02). Last-merge is the wrong trigger:
    # the probe may still fail and file fix tickets into this very milestone.
    # Best-effort; combined probes (e.g. e2e3) call this verb once per epic.
    [ "$res" = pass ] && _close_epic_milestone "$slug" || :
}

_close_epic_milestone() { # <slug> — close active milestones matching the slug
    local slug="$1"
    # P72: normalized through lib.jq's `epic_norm` — the SAME def the snapshot
    # derives epic completeness with. This was a `sed` pipeline whose only bond
    # to the jq side was a comment asking both to stay byte-identical; a drift
    # writes the acceptance to one key and reads it from another. lane.sh
    # already requires jq, so the shared def costs nothing but a process.
    local jqd; jqd="$(_jq_lib_dir "${LIB_SH%/*}")"
    # P70: paginated, like the snapshot's own active-milestone read. On the
    # unpaginated read an epic past page 1 is simply not seen, and the probe
    # reports PASS while its milestone stays open forever.
    "$TRACKER" milestones --state active 2>/dev/null \
    | jq -r '.[] | [.id, .title] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r mid title; do
        # "E5 · Cascade mode" normalizes to e5-cascade-mode, so both the full
        # slug and a bare "e5" match it.
        norm=$(printf '%s' "$title" | jq -L "$jqd" -rR 'include "lib"; epic_norm')
        case "$norm" in "$slug"|"$slug"-*)
            "$TRACKER" milestone-close "$mid" >/dev/null 2>&1 \
                && echo "lane.sh: closed milestone '$title' (epic complete, probe passed)"
        ;; esac
    done
}

cmd_reconcile() { # [<base>] — fetch and MERGE origin/<base> into the branch
    # The one repo-side verb in this file, and deliberately so: merge lanes
    # kept choosing rebase (SKILL step 5 said "rebase" long after build-1
    # recorded merge-never-rebase), then dead-ending at the force-push
    # guardrail — merge-21 did it twice in one evening and ended by asking a
    # headless void for permission (build-3 2026-08-02). Models cannot pick
    # rebase if the reconcile step is a script. Never rewrites history: a
    # merge pushes without force, always.
    local base="${1:-}"
    git fetch origin >/dev/null 2>&1 || die "reconcile: git fetch failed"
    if [ -z "$base" ]; then
        base=$(_detect_base .)
    elif ! git show-ref --verify --quiet "refs/remotes/origin/$base" 2>/dev/null; then
        # Every other verb in this file takes <iid> first (verdict, merge,
        # merge-failed, claim, transition, ...) — reconcile is the one
        # exception, taking an optional BASE BRANCH. A brief following that
        # surrounding convention naturally writes `reconcile <iid>`, and
        # origin/<iid> silently not existing must never look like the rc=3
        # conflict path: that sends a lane into conflict-resolution over
        # nothing (merge-71 did exactly this, build-4 2026-08-04). Caught
        # here, before the merge attempt, with a message that names the fix.
        die "reconcile: origin/$base does not exist — reconcile takes an optional BASE BRANCH name (e.g. main), not a ticket number; omit the argument to auto-detect main/develop"
    fi
    local _before; _before=$(git rev-parse HEAD 2>/dev/null || echo "")
    if git merge --no-edit "origin/$base" >/dev/null 2>&1; then
        echo "lane.sh: reconciled with origin/$base (merge — no history rewrite, no force-push)"
    else
        echo "lane.sh: merge conflict with origin/$base — resolve trivial conflicts and commit, or 'git merge --abort' + blocked report. Never rebase, never force." >&2
        exit 3
    fi
    _sync_deps "$_before"
}

# A worktree's installed dependencies are DERIVED state, and reconcile is the
# one verb that moves the ground under them: a worktree cut before some ticket
# added a dependency has a node_modules/venv that predates it, so the moment
# the base merges in, the gate goes red on a module that was never installed.
# Nothing else re-runs setup — SKILL step 4 installs at worktree CREATION and
# the worktree then lives for hours. So reconcile finishes the job it started.
#
# Deterministic on purpose (P-constitution: models judge, scripts plumb). The
# recovery it replaces was a wave spending ~3 minutes reading lane logs, this
# file's own source, and gate.sh before concluding "run the install" — every
# second of it re-derived, and every future stale worktree would have paid it
# again. (Paid for: build-2 #14, 2026-08-03 — merge attempt 1 died on a red
# logic gate because `zod` landed on main via #7 while wt-14's node_modules
# was 18 minutes older; the retry merged clean after nothing but an install.)
_sync_deps() { # <sha-before-merge>
    local before="$1"
    [ -n "$before" ] || return 0
    [ "${LANE_SYNC_DEPS:-1}" = 1 ] || return 0
    # Only when the merge actually moved a manifest or a lockfile. The common
    # case is a base merge that touches neither, and an unconditional install
    # would tax every merge in the build to fix the minority that need it.
    local changed
    changed=$(git diff --name-only "$before"..HEAD 2>/dev/null || echo "")
    changed=$(printf '%s\n' "$changed" | grep -E '(^|/)(uv\.lock|poetry\.lock|pyproject\.toml|pnpm-lock\.yaml|yarn\.lock|package-lock\.json|package\.json|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock)$' || true)
    [ -n "$changed" ] || return 0
    # EVERY ecosystem the merge moved, not just the repo root's. This used to
    # resolve one command against the working directory, so a merge that moved
    # `web/pnpm-lock.yaml` ran the ROOT installer (or none) and left the nested
    # ecosystem exactly as stale as before — the gate then died on a binary
    # that lives in `web/node_modules`. (Paid for: ai-workout build-1 #10 —
    # merge-10 failed twice on a missing `openapi-typescript`, and the ticket
    # never merged.)
    local done_list="" p resolved d cmd
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        # "<install dir>\t<command>" — the directory is resolved too, because a
        # workspace member's install belongs at the lockfile, not beside the
        # manifest that moved.
        resolved=$(_install_cmd_for "$(dirname "$p")")
        [ -n "$resolved" ] || continue
        d=${resolved%%	*}; cmd=${resolved#*	}
        # dedupe on dir+cmd: a merge that moves both pnpm-lock.yaml and
        # package.json in one directory is still one install, and every member
        # of one workspace resolves to the same root install.
        case "$done_list" in *"|$cmd@$d|"*) continue ;; esac
        done_list="$done_list|$cmd@$d|"
        _run_install "$cmd" "$d"
    done <<EOF
$changed
EOF
    return 0
}

# `_install_cmd_for` is in lib.sh now, over the one toolchain table tick.sh's
# `detect_stack` reads too. It was a second hand-kept copy of that table — its
# own comment said "kept as its own copy" — and an ecosystem added to one copy
# was silently missing from the other.

# Never fatal: a failed install is not a failed reconcile. The tier gate is
# the arbiter of whether this branch is mergeable, and it runs next — so this
# reports loudly and returns, leaving the verdict where it belongs.
_run_install() { # <cmd> <dir>
    local cmd="${LANE_INSTALL_CMD:-$1}" d="$2"
    echo "lane.sh: the base merge moved a manifest or lockfile under '$d' — running '$cmd' there so the gate tests this worktree, not a stale one"
    if ( cd "$d" && $cmd >/dev/null 2>&1 ); then
        echo "lane.sh: dependencies synced in '$d'"
    else
        # Worth saying twice: this line is what a merge-failed report should
        # quote when the gate then fails on a missing module.
        echo "lane.sh: '$cmd' FAILED in '$d' — the gate will likely go red on missing dependencies; say so in the merge-failed report" >&2
    fi
    return 0
}

cmd_transition() { # <iid> <state> [--release-hold] [--note [--file F]]
    local iid="${1:-}" state="${2:-}" ok=0 s istate note=0 bodyargs=()
    _check_iid "$iid"
    # P36: the only way out of a human hold, and deliberately unpleasant to
    # reach by accident — see `_blocked_guard`.
    set -- "${@:3}"
    while [ $# -gt 0 ]; do case "$1" in
        --release-hold) RELEASE_HOLD=1; shift ;;
        # P78: the decision and the relabel are ONE verb. Releasing a hold was
        # two commands — `note` then `transition` — and the batch path in
        # `triage` runs that pair once per ticket, so a session death mid-batch
        # strands some tickets with a decision comment and no release and
        # others with neither. Exactly the shape P63 turned `submit` into one
        # verb over, after ai-workout build-1 lost four tickets to it. The note
        # goes FIRST: a released ticket carrying no reason is the half a later
        # reader cannot reconstruct.
        --note) note=1; shift ;;
        --file) bodyargs+=("$1" "${2:-}"); shift 2 ;;
        *) die "transition: unknown option '$1'" ;;
    esac; done
    [ "$note" = 1 ] || [ ${#bodyargs[@]} -eq 0 ] \
        || die "transition: --file needs --note (the body is the decision note)"
    for s in $STATES; do [ "$s" = "$state" ] && ok=1; done
    [ "$ok" = 1 ] || die "unknown state '$state' (one of: $STATES)"
    # A closed ticket is finished; state labels on it are pure misinformation.
    # The same stale-snapshot race that produced the merge-failed above went on
    # to label closed #23 `blocked`, and a later wave then "requeued" it to
    # `ready-for-agent` — a closed ticket advertising itself as available work.
    # Invisible to the scheduler (its universe is open issues), but a lie on
    # the board and a trap for the human reading it. (Paid for: #23.)
    # P47: read-failed must die, not read as "not closed" — a blind pass here
    # is exactly how a closed ticket got relabeled "requeued".
    # This read is also the one `_blocked_guard` asks for a moment later, from
    # inside `_set_state`: one GET answers both questions.
    _read_issue "$iid" "refusing to guess whether it's closed."
    istate=$(printf '%s' "$_ISSUE_JSON" | jq -r '.state // empty' || true)
    [ "$istate" != closed ] \
        || die "issue $iid is CLOSED — refusing to set '$state' on finished work. Re-read the ticket: your snapshot is stale."
    if [ "$note" = 1 ]; then
        local f; f=$(_stage_body "${bodyargs[@]+"${bodyargs[@]}"}")
        # Re-run safety. The label half can fail after the note half has landed
        # (a dropped connection, a 500), and the human's fix is to run the same
        # command again — which must complete the missing half without doubling
        # the one that stuck. `submit` asks "is there an MR already"; a comment
        # has no such question, so the note carries its own trailer and this
        # asks the thread.
        #
        # The window is bounded by the block it answers: an `orch-unblock`
        # trailer NEWER than the newest `orch-blocked` one is this release's
        # note. Without that bound, a ticket blocked and released twice would
        # see round one's trailer and silently drop round two's decision —
        # losing the record, which is the half that cannot be reconstructed.
        # A thread with no `orch-blocked` trailer (blocked by hand, or before
        # this verb existed) has no bound to compute, so it posts: a duplicate
        # comment is noise, a missing decision is not.
        if _release_noted "$iid"; then
            echo "lane.sh: issue $iid already carries a release note for this block — not posting a second one"
        else
            printf '\n\n<!-- orch-unblock %s -->\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$f"
            _post_note issue "$iid" "$f"
        fi
    fi
    if [ "$state" = ready-for-agent ]; then _set_state "$iid" "$state" --assignee 0
    else _set_state "$iid" "$state"; fi
    _lane_ev ticket_transition ticket "$iid" state "$state"
}

# True when this ticket already carries a release note for the block it is
# currently under. Fails CLOSED in the P47 sense inverted: a read that fails
# returns false, so the note posts. Refusing the whole transition over an
# unreadable thread would leave the human unable to release a hold at all, and
# the cost of the wrong answer here is one duplicate comment, not a lost write.
_release_noted() { # <iid>
    local iid="$1" body rc
    body=$("$TRACKER" issue-notes "$iid" --limit 30 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || return 1
    printf '%s' "$body" | jq -e '
        def newest($pat): [.[] | select((.body // "") | test($pat)) | .created_at // ""]
                          | sort | last;
        (newest("orch-blocked")) as $b
        | (newest("orch-unblock")) as $u
        | $b != null and $u != null and $u > $b' >/dev/null 2>&1
}

cmd_claim() { # <iid>
    _check_iid "${1:-}"
    local me; me=$("$TRACKER" whoami | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)
    [ -n "$me" ] || die "cannot resolve current user id"
    _set_state "$1" in-progress --assignee "$me"
    _lane_ev ticket_claim ticket "$1"
}

cmd_submit() { # <iid> [--title <t>] [--file F] — open the MR AND move the label
    # P63: finishing was several writes in a row — push, open the MR, move the
    # label — so a session death between any two of them stranded finished work
    # in a state no scheduler step looks at, and recovery was a later wave
    # re-deriving history from the tracker. ai-workout build-1 lost four
    # tickets that way (#31 pushed MR !8 and died before the relabel; #26, #36
    # and #10 the same shape), hours of latency each, three repair waves. So
    # finishing is one verb: it refuses every half-state it can see, and
    # re-running it completes whichever half is missing rather than doubling
    # the half that landed.
    local iid="${1:-}" title="" bodyargs=()
    _check_iid "$iid"
    set -- "${@:2}"
    while [ $# -gt 0 ]; do case "$1" in
        --title) title="${2:-}"; [ -n "$title" ] || die "--title needs a value"; shift 2 ;;
        *) bodyargs+=("$1"); shift ;;
    esac; done
    _blocked_guard "$iid" review
    # One issue read, FOUR questions: the hold the guard above just asked
    # about, plus is it closed, has the gate already moved it past review, and
    # what is its title. P47: a failed read dies rather than guessing — an MR
    # opened over a stale answer is a write nothing undoes.
    local istate cur
    _read_issue "$iid" "refusing to open an MR blind."
    istate=$(printf '%s' "$_ISSUE_JSON" | jq -r '.state // empty' || true)
    [ "$istate" != closed ] \
        || die "issue $iid is CLOSED — refusing to submit finished work. Re-read the ticket: your snapshot is stale."
    cur=$(printf '%s' "$_ISSUE_JSON" | jq -r '[.labels[]? | select(. == "merge-queue")] | .[0] // empty' || true)
    [ "$cur" != merge-queue ] \
        || die "issue $iid is already 'merge-queue' — its gate passed. Submitting again would drag a judged ticket back to review."
    # The source branch, and proof the remote already has exactly this commit.
    # An MR opened over an unpushed HEAD reviews work nobody can see, and the
    # gate then judges a different tree than the lane built.
    local branch head remote_head base
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [ -n "$branch" ] && [ "$branch" != HEAD ] \
        || die "submit: detached HEAD — an MR needs a source branch (this verb runs in the lane worktree)"
    # P73: the SAME base rule every other call site uses, config key included.
    # This one used to probe `ls-remote` for develop and never look at
    # `base:`, so a repo that declared a base got its MRs targeted at a branch
    # its own merges never reconcile against.
    base=$(_detect_base .)
    [ "$branch" != "$base" ] \
        || die "submit: the current branch IS the base branch ($base) — there is nothing to merge"
    head=$(git rev-parse HEAD 2>/dev/null || true)
    remote_head=$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}') \
        || remote_head=""
    [ -n "$remote_head" ] \
        || die "submit: branch '$branch' is not on origin — push it first: git push -u origin $branch"
    [ "$remote_head" = "$head" ] \
        || die "submit: origin/$branch is at ${remote_head:0:8}, this worktree is at ${head:0:8} — push before submitting, or the MR carries work the gate will never see"
    # Already-open MR = the strand this verb exists to end. Complete the missing
    # half; never open a second MR for the same ticket.
    local mr
    _open_mr_closing "$iid" "refusing to open an MR that may be the second one."
    mr="$_OPEN_MR"
    if [ -n "$mr" ]; then
        echo "lane.sh: MR !$mr is already open on issue $iid — completing the label move only"
    else
        [ -n "$title" ] || title=$(printf '%s' "$_ISSUE_JSON" | jq -r '.title // empty' || true)
        [ -n "$title" ] || die "submit: no title on issue $iid and none given — pass --title"
        local f; f=$(_stage_body ${bodyargs[@]+"${bodyargs[@]}"})
        # `Closes #<iid>` is the literal string the scheduler links MR to ticket
        # by; an MR without it is invisible to the build. Appended here rather
        # than asked for, exactly as verdict appends its own trailer.
        grep -Eq "[Cc]loses #$iid([^0-9]|$)" "$f" || printf '\n\nCloses #%s\n' "$iid" >> "$f"
        mr=$("$TRACKER" mr-create --source "$branch" --target "$base" \
            --title "$title" --body-file "$f" 2>/dev/null) || mr=""
        # MR first, label second, and the label is skipped when the MR failed:
        # an open MR with no label flip is a state the snapshot now names and a
        # wave repairs in one call, where a `review` label with no MR is a
        # ticket queued for a gate that has nothing to read.
        [ -n "$mr" ] || die "submit: opening the MR failed ($branch → $base) — the label was NOT moved; fix the push or the target branch and re-run"
        # Opening the MR is a write, and `_set_state` below asks the hold
        # question again on the far side of it. Forget the body read at the top
        # of this verb so that guard sees the tracker as it is after the MR
        # opened — a hold placed while this verb was running must still bounce
        # the label move (#29's stomp is what the guard is for).
        _forget_issue
        echo "lane.sh: MR !$mr opened ($branch → $base), closes #$iid"
        _lane_ev mr_opened ticket "$iid" mr "$mr"
    fi
    _set_state "$iid" review
}

cmd_merge() { # <iid> — merge THIS ticket's MR, verify it landed, then close.
    # The second repo-side verb, for exactly the reason `reconcile` is the
    # first: the step was left to prose in a brief, and prose is not a
    # mechanism. merge-1 ran reconcile, ran the gate, ran `lane.sh close 1`,
    # then reported "merged and closed" — but `close` closes an ISSUE, and
    # nothing had merged MR !1. Four downstream lanes were seconds from
    # branching off a base with no workspace in it (build-1 2026-08-03).
    #
    # Uses `closed_by`, never `related_merge_requests`: the latter includes any
    # MR that merely mentions the issue, and on that same build issue #1 listed
    # #21's open MR alongside its own — "merge the first open one" would have
    # merged the wrong branch.
    local iid="${1:-}" mr state n
    _check_iid "$iid"
    _blocked_guard "$iid" merge
    mr=$("$TRACKER" issue-closed-by "$iid" 2>/dev/null \
         | jq -r '[.[] | select(.state == "opened")] | .[0].iid // empty' || true)
    [ -n "$mr" ] || die "no open MR closes issue $iid — its description must contain 'Closes #$iid'"
    # P84: delete the source branch as part of the merge. Nothing else in the
    # loop ever deletes a branch — sweep's `git branch -d` only fires as a side
    # effect of removing a worktree, and covers the local side alone — so five
    # builds left 51 local `ticket-*` branches behind. The remote survived only
    # because that project happened to set `remove_source_branch_after_merge`,
    # a per-project setting this skill neither reads nor writes; a repo without
    # it accumulates every branch it ever merges. This is the one moment the
    # branch is provably disposable, and it is one field on a request the verb
    # already makes.
    "$TRACKER" mr-merge "$mr" >/dev/null 2>&1 \
        || die "merge of MR !$mr refused (conflicts, red pipeline, or approvals) — record it: lane.sh merge-failed $iid"
    # GitLab merges asynchronously; never report a merge we have not observed.
    for n in 1 2 3 4 5 6 7 8 9 10; do
        state=$("$TRACKER" mr "$mr" 2>/dev/null \
                | jq -r '.state // empty' || true)
        [ "$state" = merged ] && break
        sleep 2
    done
    [ "$state" = merged ] \
        || die "MR !$mr is '${state:-unknown}', not 'merged' — refusing to close issue $iid. Record it: lane.sh merge-failed $iid"
    echo "lane.sh: MR !$mr merged"
    _lane_ev mr_merged ticket "$iid" mr "$mr"
    # The merge took seconds to land and `close` re-asks the hold question on
    # the other side of it: forget the issue read this verb's own guard took,
    # so that guard runs against the tracker as it is NOW, exactly as it did
    # when every verb fetched for itself.
    _forget_issue
    cmd_close "$iid"
}

cmd_close() { # <iid> — merged and done: strip every state label, then close.
    # Closing with the state label left on strands a stale "merge-queue" on a
    # closed ticket (build-1 #1, 2026-08-02) — harmless to the scheduler
    # (its universe is open issues) but a lie to every human reading the board.
    local iid="${1:-}" remove="" s open_mr
    _check_iid "$iid"
    _blocked_guard "$iid" close
    # A closed ticket whose MR never merged is the worst lie this machine can
    # tell: the scheduler's universe is open issues, so the ticket vanishes,
    # its blockers-cleared dependents start, and they branch off a base that
    # does not contain the work. `merge` calls this verb *after* observing the
    # merge, so the guard is already satisfied by then (build-1 2026-08-03).
    # P47: read-failed must die, not read as "no open MR" — that blind pass is
    # literally the failure this guard exists to catch, just via a different
    # cause (API error instead of a stale snapshot).
    _open_mr_closing "$iid" "refusing to close blind; cannot rule out an unmerged MR."
    open_mr="$_OPEN_MR"
    [ -z "$open_mr" ] \
        || die "issue $iid still has unmerged MR !$open_mr — 'close' closes the issue only, it does not merge. Use: lane.sh merge $iid"
    for s in $STATES; do remove="$remove,$s"; done
    "$TRACKER" issue-close "$iid" --remove "${remove#,}"
    echo "lane.sh: issue $iid closed, state labels stripped"
    _lane_ev ticket_close ticket "$iid"
}

_usage() {
    die "usage: lane.sh scratch | note <iid> [--file F] | mr-note <iid> [--file F] | verdict <iid> pass|fail <sha> [--class <slug>] [--file F] | merge-failed <iid> [--base-red <check-id> --fix <fix-iid>] [--file F] | base-check [--] <cmd...> | wait-ready --timeout <secs> [--interval <secs>] (--url <url> | -- <cmd...>) | blocked-report <iid> [--category <slug>] [--file F] | model-tier <iid> <tier> | rescope <iid> [--file F] | fix-ticket --title <t> --tier <docs|logic|api|ui> --milestone <title> [--blocked-by <iids>] [--force] [--file F] | probe-result <build-iid> <epic-slug> pass|fail [--file F] | reconcile [<base>] | transition <iid> <state> [--release-hold] [--note] [--file F] | claim <iid> | submit <iid> [--title <t>] [--file F] | merge <iid> | close <iid>   (bodies: --file or stdin)"
}

# The usage path deliberately comes FIRST and needs no tracker: `lane.sh` with
# no verb prints the roster, and that is how tick.sh derives the verb list it
# injects into every wave prompt (`_lane_verbs`). A halt above this line makes
# the roster empty in every repo — the wave then loses the list of verbs it is
# supposed to use, which is the opposite of what a missing declaration should
# cost. (Caught by P48's roster test, which is exactly why that test exists.)
case "${1:-}" in ''|-h|--help|help) _usage ;; esac

# P86: no declaration, no lane — checked once here so every verb inherits it
# rather than each growing a copy. This is the sharpest of the three halts: a
# lane is headless, so it cannot be asked which tracker the repo uses, and the
# alternative to refusing is a session inferring one from the git remote. The
# question is asked of `$LOOM_REPO` for the same reason `_lane_ev` above reads
# it: spawn-lane exports it to every lane, so a worktree cwd still resolves the
# repo whose index the tracked-by-git half is really about. A human running
# this by hand has it unset and is answered about the repo they are standing in.
_require_tracker "${LOOM_REPO:-.}" "lane.sh" >/dev/null

case "${1:-}" in
    scratch)    shift; cmd_scratch "$@" ;;
    note)       shift; cmd_note "$@" ;;
    mr-note)    shift; cmd_mr_note "$@" ;;
    verdict)    shift; cmd_verdict "$@" ;;
    merge-failed) shift; cmd_merge_failed "$@" ;;
    blocked-report) shift; cmd_blocked_report "$@" ;;
    model-tier) shift; cmd_model_tier "$@" ;;
    base-check) shift; cmd_base_check "$@" ;;
    wait-ready) shift; cmd_wait_ready "$@" ;;
    fix-ticket) shift; cmd_fix_ticket "$@" ;;
    rescope)    shift; cmd_rescope "$@" ;;
    probe-result) shift; cmd_probe_result "$@" ;;
    reconcile)  shift; cmd_reconcile "$@" ;;
    submit)     shift; cmd_submit "$@" ;;
    merge)      shift; cmd_merge "$@" ;;
    transition) shift; cmd_transition "$@" ;;
    claim)      shift; cmd_claim "$@" ;;
    close)      shift; cmd_close "$@" ;;
    *) _usage ;;
esac
