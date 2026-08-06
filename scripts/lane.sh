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
#   lane.sh merge-failed <iid> [--file F]     record a merge attempt that did
#                                            NOT merge (conflict, red combined
#                                            gate, wedged lane), body from
#                                            F/stdin. Keeps the merge-queue
#                                            label; the count is what lets the
#                                            queue stop retrying one poisoned
#                                            ticket and advance to the next
#   lane.sh rescope <iid> [--file F]          this ticket is now DIFFERENT work:
#                                            post what changed and retire the
#                                            rejections recorded before it. A
#                                            human's call only — refused inside
#                                            a lane or a wave
#   lane.sh fix-ticket --title <t> --tier <t> --milestone <m> [--file F]
#                                            file a fix ticket a wave can
#                                            actually schedule: applies all
#                                            FIVE of build-N (derived), fix,
#                                            tier::<t>, the epic milestone and
#                                            ready-for-agent, or refuses
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
#
# Long bodies: pipe them.   lane.sh note 7 <<'EOF' … EOF
# Every verb is safe to re-run; nothing here deletes.
set -euo pipefail

die() { echo "lane.sh: $*" >&2; exit 2; }
# Same seam as tick.sh, for the same reason: the test suite exercises these
# verbs against a capture stub, never the real tracker.
GLAB="${GLAB_CMD:-glab}"
command -v "$GLAB" >/dev/null 2>&1 || die "glab not on PATH"

STATES="ready-for-agent in-progress review merge-queue blocked"

# Every state-changing verb appends one line to the build's event stream via
# `tick.sh event` (sibling script; LOOM_REPO reaches lanes via spawn-lane's
# export, so a worktree cwd still resolves the right state dir). Consumer:
# `tick.sh render-events` — the live build ticker. Best-effort by design: a
# tracker write must never fail because the ticker could not be fed.
TICK_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tick.sh"
_lane_ev() { "$TICK_SH" event "$@" >/dev/null 2>&1 || true; }

# Stage stdin/--file into a private temp file so the glab command the harness
# sees contains only a literal path this script produced.
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

_post_note() { # <issues|merge_requests> <iid> <bodyfile>
    "$GLAB" api --method POST "projects/:fullpath/$1/$2/notes" \
        --field "body=@$3" >/dev/null
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
    local _issue rc
    _issue=$("$GLAB" api "projects/:fullpath/issues/$iid" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] \
        || die "issue $iid: could not read issue state (glab api failed, rc=$rc) — refusing to guess whether it carries a human hold. Retry once the tracker is reachable."
    if printf '%s' "$_issue" | jq -e '.labels | index("blocked")' >/dev/null 2>&1; then
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
    "$GLAB" api --method PUT "projects/:fullpath/issues/$iid" \
        -f "add_labels=$state" -f "remove_labels=${remove#,}" "$@" >/dev/null
    echo "lane.sh: issue $iid → $state"
}

_check_iid() { case "${1:-}" in ''|*[!0-9]*) die "bad iid: '${1:-}'";; esac; }

cmd_scratch() {
    local d="${LOOM_SCRATCH:-}"
    if [ -z "$d" ]; then d=$(mktemp -d "${TMPDIR:-/tmp}/lane-scratch.XXXXXX")
    else mkdir -p "$d"; fi
    printf '%s\n' "$d"
}

cmd_note()    { _check_iid "${1:-}"; local f; f=$(_stage_body "${@:2}"); _post_note issues "$1" "$f"; }
cmd_mr_note() { _check_iid "${1:-}"; local f; f=$(_stage_body "${@:2}"); _post_note merge_requests "$1" "$f"; }

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
    local f up; f=$(_stage_body ${bodyargs[@]+"${bodyargs[@]}"})
    up=$(printf '%s' "$res" | tr 'a-z' 'A-Z')
    printf '\n\n<!-- orch-verdict %s %s%s -->\n' "$up" "$sha" "${klass:+ class=$klass}" >> "$f"
    # Note first, label second: a verdict note with no label flip is repaired
    # by the next wave (it reads the trailer); a label flip with no note is a
    # verdict that never happened.
    _post_note issues "$iid" "$f"
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
    _closed_by=$("$GLAB" api "projects/:fullpath/issues/$iid/closed_by" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] \
        || die "issue $iid: could not read closed_by (glab api failed, rc=$rc) — refusing to record a merge-failed attempt blind; cannot rule out the merge having already succeeded."
    merged_mr=$(printf '%s' "$_closed_by" | jq -r '[.[] | select(.state == "merged")] | .[0].iid // empty' || true)
    [ -z "$merged_mr" ] \
        || die "issue $iid already has MERGED MR !$merged_mr — the merge succeeded; refusing to record a failed attempt. Re-read the ticket: your snapshot is stale."
    local f; f=$(_stage_body "${@:2}")
    printf '\n\n<!-- orch-merge-attempt %s -->\n' "$iid" >> "$f"
    _post_note issues "$iid" "$f"
    _lane_ev merge_failed ticket "$iid"
    echo "lane.sh: issue $iid — merge attempt recorded"
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
    _post_note issues "$iid" "$f"
    _lane_ev ticket_rescope ticket "$iid"
    echo "lane.sh: issue $iid re-scoped — rejections recorded before this note no longer count"
}

cmd_fix_ticket() { # --title <t> --tier <docs|logic|api|ui> --milestone <title> [--file F]
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
    local title="" tier="" ms="" bodyargs=()
    while [ $# -gt 0 ]; do case "$1" in
        --title)     title="${2:-}"; [ -n "$title" ] || die "--title needs a value"; shift 2 ;;
        --tier)      tier="${2:-}";  shift 2 ;;
        --milestone) ms="${2:-}";    shift 2 ;;
        *) bodyargs+=("$1"); shift ;;
    esac; done
    [ -n "$title" ] || die "fix-ticket: --title is required"
    case "$tier" in docs|logic|api|ui) ;;
        *) die "fix-ticket: --tier must be docs|logic|api|ui (got '${tier:-<empty>}') — without it no gate lane can pick a suite" ;; esac
    [ -n "$ms" ] || die "fix-ticket: --milestone is required — completeness and the re-probe derive from membership, so a milestone-less fix ticket lets its epic close over an open defect"
    local f; f=$(_stage_body ${bodyargs[@]+"${bodyargs[@]}"})
    # The build label is DERIVED, never asked for: the scheduler's universe is
    # "open issues labeled build-N" for the highest open `Build N` issue, and a
    # lane that had to name it could name last week's.
    local blabel
    blabel=$("$GLAB" api "projects/:fullpath/issues?state=opened&per_page=100" 2>/dev/null \
        | jq -r '[.[] | select((.title // "") | test("^Build [0-9]+$"))]
                 | sort_by(.iid) | last | (.title // "") | sub("^Build "; "build-")')
    case "$blabel" in build-[0-9]*) ;; *) die "fix-ticket: no open \`Build N\` issue — cannot derive the build label" ;; esac
    local mid
    mid=$("$GLAB" api "projects/:fullpath/milestones?per_page=100" 2>/dev/null \
        | jq -r --arg t "$ms" '.[] | select(.title == $t) | .id' | head -1)
    [ -n "$mid" ] || die "fix-ticket: no milestone titled '$ms'"
    local iid
    iid=$("$GLAB" api --method POST "projects/:fullpath/issues" \
        -f "title=$title" --field "description=@$f" \
        -f "labels=$blabel,fix,tier::$tier,ready-for-agent" \
        -f "milestone_id=$mid" 2>/dev/null | jq -r '.iid // empty')
    [ -n "$iid" ] || die "fix-ticket: create failed"
    echo "lane.sh: filed #$iid — $blabel, fix, tier::$tier, ready-for-agent, milestone '$ms'"
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
    _post_note issues "$iid" "$hdr"
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
    "$GLAB" api "projects/:fullpath/milestones?state=active&per_page=100" 2>/dev/null \
    | jq -r '.[] | [.id, .title] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r mid title; do
        # "E5 · Cascade mode" normalizes to e5-cascade-mode, so both the full
        # slug and a bare "e5" match it.
        norm=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
        case "$norm" in "$slug"|"$slug"-*)
            "$GLAB" api --method PUT "projects/:fullpath/milestones/$mid" \
                --field state_event=close >/dev/null 2>&1 \
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
        if git show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null
        then base=develop; else base=main; fi
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
#
# Never fatal: a failed install is not a failed reconcile. The tier gate is
# the arbiter of whether this branch is mergeable, and it runs next — so this
# reports loudly and returns, leaving the verdict where it belongs.
_sync_deps() { # <sha-before-merge>
    local before="$1"
    [ -n "$before" ] || return 0
    [ "${LANE_SYNC_DEPS:-1}" = 1 ] || return 0
    # Only when the merge actually moved a manifest or a lockfile. The common
    # case is a base merge that touches neither, and an unconditional install
    # would tax every merge in the build to fix the minority that need it.
    local changed
    changed=$(git diff --name-only "$before"..HEAD 2>/dev/null || echo "")
    printf '%s\n' "$changed" | grep -qE '(^|/)(uv\.lock|poetry\.lock|pyproject\.toml|pnpm-lock\.yaml|yarn\.lock|package-lock\.json|package\.json|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock)$' \
        || return 0
    # Lockfile before manifest, exactly as tick.sh detect_stack orders it: a
    # lockfile names the toolchain actually in use, a manifest only the
    # ecosystem. Kept as its own copy rather than sourcing tick.sh — lane.sh
    # is the write half and deliberately stands alone.
    local cmd=""
    if   [ -f uv.lock ];         then cmd="uv sync"
    elif [ -f poetry.lock ];     then cmd="poetry install"
    elif [ -f pnpm-lock.yaml ];  then cmd="pnpm install"
    elif [ -f yarn.lock ];       then cmd="yarn install"
    elif [ -f package-lock.json ]; then cmd="npm ci"
    elif [ -f package.json ];    then cmd="npm install"
    elif [ -f go.mod ];          then cmd="go mod download"
    elif [ -f Cargo.toml ];      then cmd="cargo fetch"
    else return 0; fi
    cmd="${LANE_INSTALL_CMD:-$cmd}"
    echo "lane.sh: the base merge moved a manifest or lockfile — running '$cmd' so the gate tests this worktree, not a stale one"
    if $cmd >/dev/null 2>&1; then
        echo "lane.sh: dependencies synced"
    else
        # Worth saying twice: this line is what a merge-failed report should
        # quote when the gate then fails on a missing module.
        echo "lane.sh: '$cmd' FAILED — the gate will likely go red on missing dependencies; say so in the merge-failed report" >&2
    fi
    return 0
}

cmd_transition() { # <iid> <state> [--release-hold]
    local iid="${1:-}" state="${2:-}" ok=0 s istate
    _check_iid "$iid"
    # P36: the only way out of a human hold, and deliberately unpleasant to
    # reach by accident — see `_blocked_guard`.
    set -- "${@:3}"
    while [ $# -gt 0 ]; do case "$1" in
        --release-hold) RELEASE_HOLD=1; shift ;;
        *) die "transition: unknown option '$1'" ;;
    esac; done
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
    local _issue rc
    _issue=$("$GLAB" api "projects/:fullpath/issues/$iid" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] \
        || die "issue $iid: could not read issue state (glab api failed, rc=$rc) — refusing to guess whether it's closed. Retry once the tracker is reachable."
    istate=$(printf '%s' "$_issue" | jq -r '.state // empty' || true)
    [ "$istate" != closed ] \
        || die "issue $iid is CLOSED — refusing to set '$state' on finished work. Re-read the ticket: your snapshot is stale."
    if [ "$state" = ready-for-agent ]; then _set_state "$iid" "$state" -f assignee_ids=0
    else _set_state "$iid" "$state"; fi
    _lane_ev ticket_transition ticket "$iid" state "$state"
}

cmd_claim() { # <iid>
    _check_iid "${1:-}"
    local me; me=$("$GLAB" api user | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)
    [ -n "$me" ] || die "cannot resolve current user id"
    _set_state "$1" in-progress -f "assignee_ids=$me"
    _lane_ev ticket_claim ticket "$1"
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
    mr=$("$GLAB" api "projects/:fullpath/issues/$iid/closed_by" 2>/dev/null \
         | jq -r '[.[] | select(.state == "opened")] | .[0].iid // empty' || true)
    [ -n "$mr" ] || die "no open MR closes issue $iid — its description must contain 'Closes #$iid'"
    "$GLAB" api --method PUT "projects/:fullpath/merge_requests/$mr/merge" >/dev/null 2>&1 \
        || die "merge of MR !$mr refused (conflicts, red pipeline, or approvals) — record it: lane.sh merge-failed $iid"
    # GitLab merges asynchronously; never report a merge we have not observed.
    for n in 1 2 3 4 5 6 7 8 9 10; do
        state=$("$GLAB" api "projects/:fullpath/merge_requests/$mr" 2>/dev/null \
                | jq -r '.state // empty' || true)
        [ "$state" = merged ] && break
        sleep 2
    done
    [ "$state" = merged ] \
        || die "MR !$mr is '${state:-unknown}', not 'merged' — refusing to close issue $iid. Record it: lane.sh merge-failed $iid"
    echo "lane.sh: MR !$mr merged"
    _lane_ev mr_merged ticket "$iid" mr "$mr"
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
    local _closed_by rc
    _closed_by=$("$GLAB" api "projects/:fullpath/issues/$iid/closed_by" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] \
        || die "issue $iid: could not read closed_by (glab api failed, rc=$rc) — refusing to close blind; cannot rule out an unmerged MR."
    open_mr=$(printf '%s' "$_closed_by" | jq -r '[.[] | select(.state == "opened")] | .[0].iid // empty' || true)
    [ -z "$open_mr" ] \
        || die "issue $iid still has unmerged MR !$open_mr — 'close' closes the issue only, it does not merge. Use: lane.sh merge $iid"
    for s in $STATES; do remove="$remove,$s"; done
    "$GLAB" api --method PUT "projects/:fullpath/issues/$iid" \
        -f "remove_labels=${remove#,}" -f state_event=close >/dev/null
    echo "lane.sh: issue $iid closed, state labels stripped"
    _lane_ev ticket_close ticket "$iid"
}

case "${1:-}" in
    scratch)    shift; cmd_scratch "$@" ;;
    note)       shift; cmd_note "$@" ;;
    mr-note)    shift; cmd_mr_note "$@" ;;
    verdict)    shift; cmd_verdict "$@" ;;
    merge-failed) shift; cmd_merge_failed "$@" ;;
    fix-ticket) shift; cmd_fix_ticket "$@" ;;
    rescope)    shift; cmd_rescope "$@" ;;
    probe-result) shift; cmd_probe_result "$@" ;;
    reconcile)  shift; cmd_reconcile "$@" ;;
    merge)      shift; cmd_merge "$@" ;;
    transition) shift; cmd_transition "$@" ;;
    claim)      shift; cmd_claim "$@" ;;
    close)      shift; cmd_close "$@" ;;
    *) die "usage: lane.sh scratch | note <iid> [--file F] | mr-note <iid> [--file F] | verdict <iid> pass|fail <sha> [--class <slug>] [--file F] | merge-failed <iid> [--file F] | rescope <iid> [--file F] | fix-ticket --title <t> --tier <docs|logic|api|ui> --milestone <title> [--file F] | probe-result <build-iid> <epic-slug> pass|fail [--file F] | reconcile [<base>] | transition <iid> <state> [--release-hold] | claim <iid> | merge <iid> | close <iid>   (bodies: --file or stdin)" ;;
esac
