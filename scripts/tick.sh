#!/usr/bin/env bash
# Loom tick plumbing (spec #85, ticket #88).
#
# Deterministic machinery only: lock, detach, liveness, snapshot, notify.
# Scheduling decisions (what to claim, merge, block) belong to the wave
# session this script launches — it never edits tracker state itself.
#
# Subcommands:
#   tick                         cron entry: take the lock, run one wave, exit.
#                                A tick that arrives mid-wave is remembered, and
#                                the running wave re-ticks once on exit. A wave
#                                that hits a usage limit pauses the build until
#                                capacity returns; one that crashes retries once.
#   resume                       clear a usage pause by hand, reset the failure
#                                count (needed under usage_limit: stop_and_wait)
#   spawn-lane <id> [--cwd <dir>] [--merge-lock] [--no-tick] -- <cmd...>
#                                start a detached lane with PID file + log,
#                                running in <dir> (default: the repo root).
#                                The lane fires the next wave when it exits
#                                unless --no-tick; --merge-lock holds the
#                                single-writer merge lock for its lifetime.
#                                A gate-<ticket> lane refuses outright when a
#                                live gate lane already holds that ticket at
#                                the same HEAD (P67) — chain and scheduler may
#                                race for it; the loser exits in milliseconds.
#   lane-status                  one line per lane: running | stale | dead
#   render-log <id> [--follow]   lane-<id>.jsonl stream → readable log, or stdout
#   retro [--build|--vs <l>]     capacity, rework, wait/work, critical chain
#                                (a lane calls this itself as it exits)
#   clear-lane <id>              forget a harvested lane (removes pid file)
#   snapshot                     the wave read set as one JSON document
#   graph [file]                 dependency shape of that snapshot: critical
#                                path, widest level, what can start now; rc 1
#                                when an epic has no wiring ticket (P64)
#   notify <event> <title> <body> [click-url]
#   trust-check [--notify] [dir]  will a headless lane there load the repo
#                                allowlist? Asks both the filesystem walk and
#                                the git repo root (P30). Never writes trust.
#
# Test seams (env): LOOM_HOME, LOOM_REPO, LOOM_LOCK_DIR, LOOM_WAVE_CMD,
# GLAB_CMD, SNAP_BATCH, NTFY_CMD, NTFY_BASE, WATCH_PANES_CMD. macOS has no flock(1), so the
# lock is an atomic mkdir holding the owner PID — exit-if-held, and a lock
# whose owner PID is dead is broken on the next tick (same semantics,
# portable). That same bash-3.2 floor is why the snapshot fan-out batches
# instead of using `wait -n`.
set -euo pipefail

REPO_ROOT="${LOOM_REPO:-$PWD}"
# Stable per-repo key (basename + path hash). Drives the state dir AND the
# launchd label, so every repo is isolated and a repo's plist / manual runs
# resolve to the same lock. Two repos never collide.
REPO_KEY="$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | cksum | cut -d' ' -f1)"
LOOM_HOME="${LOOM_HOME:-$HOME/.loom/$REPO_KEY}"
export LOOM_REPO="$REPO_ROOT" LOOM_HOME
CONFIG="$REPO_ROOT/.loom.yml"
# Hard cut from the pre-rename name. A repo still carrying `.orchestrator.yml`
# with no `.loom.yml` would otherwise run silently on derived + global defaults,
# quietly ignoring every setting the human wrote. Refuse instead, and say the
# exact rename. No fallback path: one name, or a stop.
if [ ! -f "$CONFIG" ] && [ -f "$REPO_ROOT/.orchestrator.yml" ]; then
    printf '%s\n' \
        "loom: this repo still uses the old config name." \
        "  found:    $REPO_ROOT/.orchestrator.yml" \
        "  expected: $CONFIG" \
        "Rename it:  git -C \"$REPO_ROOT\" mv .orchestrator.yml .loom.yml" >&2
    exit 1
fi
LOCK_DIR="${LOOM_LOCK_DIR:-$LOOM_HOME/tick.lock.d}"
# Merging is the only step that genuinely needs single-writer semantics, and it
# used to borrow the tick lock for it — so harvest, gate and fill all queued
# behind a rebase-and-merge (P5). Its own lock lets a merge run in a lane while
# waves keep scheduling. Same mkdir-atomic, dead-owner-breakable semantics.
MERGE_LOCK_DIR="${LOOM_MERGE_LOCK_DIR:-$LOOM_HOME/merge.lock.d}"
# P67: the chain handoff and the scheduler's own gate step can both spawn a
# gate for the same ticket at the same HEAD — two full review sessions for one
# diff, and the last verdict write wins. One lock dir per ticket+commit (never
# one global dir like MERGE_LOCK_DIR: unrelated gates must never queue behind
# each other) gets the same mkdir-atomic, dead-owner-breakable shape.
GATE_LOCK_DIR="${LOOM_GATE_LOCK_DIR:-$LOOM_HOME/gate.lock.d}"
# D-TICK-25: planner capacity is not enough for lane-to-lane handoffs, which
# never pass through plan.jq. Serialize the small admission window so two
# finishing lanes cannot both observe the last auxiliary slot as free. Queued
# Codex launches count as reservations until the durable host starts them.
AUX_LOCK_DIR="${LOOM_AUX_LOCK_DIR:-$LOOM_HOME/aux-admission.lock.d}"
# A tick that arrives while a wave holds the lock used to be discarded outright,
# and that is how build 2 ended: a gate exited at 23:36:03 during W13, the kick
# was dropped, and the loop never ran again — leaving a ticket in `merge-queue`,
# unmerged. The skipped tick now leaves this note instead, and the lock holder
# re-ticks once on its way out (P1). It is a single flag, not a queue, so a burst
# of finishing lanes costs one extra wave rather than one per lane.
PENDING_FILE="${LOOM_PENDING_FILE:-$LOOM_HOME/tick.pending}"
# `start` is a human request to resume now. Its launchd RunAtLoad firing still
# uses --auto so every later heartbeat keeps the normal pacing contract, but
# this one-shot marker lets the first eligible firing bypass an old wave gap.
# It is consumed only when a wave is actually admitted, so a lock or unreadable
# board cannot lose the kick. (Paid for: patient-imaging Build JOR-267 waited
# behind a 20m gap immediately after `/loom start`, 2026-08-16.)
START_KICK_FILE="${LOOM_START_KICK_FILE:-$LOOM_HOME/start.kick}"
LANES_DIR="$LOOM_HOME/lanes"
LOGS_DIR="$LOOM_HOME/logs"
# P82: a lane's brief lives HERE, never in the working tree it is about.
# `spawn-lane` used to copy it to $cwd/.lane-brief-<id>.md, which made every
# lane worktree hold an untracked file by construction, so sweep's
# unsaved-work guard (D-TICK-17) kept all 30 of them across five builds.
BRIEFS_DIR="$LOOM_HOME/briefs"
# Codex owns the whole process scope beneath `codex exec`: a worker started by
# a shell command inside that session is reaped when the session exits, even
# when the shell used nohup. Provider sessions therefore leave validated
# launch requests here. A safe host wrapper, normally the scheduler heartbeat,
# drains them only after the provider has returned.
LANE_LAUNCH_DIR="$LOOM_HOME/lane-launch-queue"
# A Codex provider session cannot unload sibling launchd jobs from its sandbox.
# Stale-lane kills and dead-lane clears therefore cross the same durable-host
# boundary as deferred launches. Cleanup is drained first so a replacement can
# never collide with the service or lock left by the worker it replaces.
LANE_CLEANUP_DIR="$LOOM_HOME/lane-cleanup-queue"
# P85: what the last sweep pass could not remove, and why. Sweep said all of
# this to stdout inside a wave session for five builds — the right message,
# addressed to a human, into a file no human reads.
SWEEP_HELD_FILE="$LOOM_HOME/sweep-held.txt"
# Every session gets its own scratch directory here (P17). Fixed paths were the
# bug: a wave wrote /tmp/wave-note-16.md, a stale file of that name from an
# earlier wave won, and its content was posted as a comment on the wrong ticket.
SCRATCH_ROOT="$LOOM_HOME/scratch"
SCRATCH_KEEP_DAYS="${LOOM_SCRATCH_KEEP_DAYS:-7}"
NTFY_BASE="${NTFY_BASE:-https://ntfy.sh}"
NTFY_CMD="${NTFY_CMD:-curl}"
# Seam like GLAB_CMD/NTFY_CMD, and for the same reason: the test suite must
# never touch real launchd. (Paid for: 2026-08-02 — every tick-test run armed
# a real watcher agent for its mktemp sandbox; 26 zombie agents accumulated,
# each firing exit-78 every 60s against a deleted temp dir.)
LAUNCHCTL_CMD="${LAUNCHCTL_CMD:-launchctl}"
SNAP_BATCH="${SNAP_BATCH:-8}"
# Absolute path to this script, so a lane can re-invoke it on completion
# regardless of the cwd it exits in.
SELF_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
# Sibling script, same seam pattern as LAUNCHCTL_CMD: `start` raises the herdr
# viewer itself (see _raise_viewer), and the test suite must never open a real
# pane.
WATCH_PANES_CMD="${WATCH_PANES_CMD:-${SELF_PATH%/*}/watch-panes.sh}"
AGENT_SH="${LOOM_AGENT_CMD:-${SELF_PATH%/*}/agent.sh}"

mkdir -p "$LOOM_HOME" "$LANES_DIR" "$LOGS_DIR" "$SCRATCH_ROOT" "$BRIEFS_DIR" \
         "$LANE_LAUNCH_DIR" "$LANE_CLEANUP_DIR"

TRUST_FILE="${LOOM_TRUST_FILE:-$HOME/.claude.json}"

# P73: the facts both halves of this skill derive — the base-branch rule, the
# config readers, the lockfile→toolchain table, the paginating list read, and
# `die` itself — live in lib.sh beside this script, sourced instead of written
# twice. Pure functions only and nothing runs at source time, which is what
# lets lane.sh (the write half) share the same file without ever sourcing
# tick.sh. Named loudly when absent, exactly as snapshot.jq is: unchecked, the
# failure is a stream of "command not found" from whichever function ran first
# and says nothing about the file that went missing. `die` comes FROM the lib,
# so this one check has to speak for itself.
# Resolved off `${BASH_SOURCE[0]}` with parameter expansion, not `dirname`
# and not SELF_PATH: this runs at source time, ahead of every `command -v`
# check in the file, so a PATH carrying neither `dirname` nor `basename` must
# still get far enough to report the real problem (SELF_PATH collapses to `/`
# in exactly that case, and the suite pins it).
LIB_DIR="${BASH_SOURCE[0]%/*}"
[ "$LIB_DIR" != "${BASH_SOURCE[0]}" ] || LIB_DIR="."   # invoked with a bare name
LIB_SH="$LIB_DIR/lib.sh"
[ -f "$LIB_SH" ] \
    || { echo "tick.sh: $LIB_SH is missing — it holds the shared derivations and ships beside tick.sh" >&2; exit 1; }
. "$LIB_SH"
DIE_RC=1   # lane.sh sets 2; the lib defaults to 1 but never leaves it to chance

# P86: every tracker read this file makes goes through the driver for the
# repo's declared tracker, so `glab` is named in scripts/trackers/gitlab.sh and
# nowhere else. Resolved ONCE, here — after lib.sh and after SELF_PATH, and
# before any verb, because tick.sh cds to the repo root mid-verb and a relative
# resolution would then answer differently depending on which verb asked.
TRACKER_SH="$(_tracker_cmd "${SELF_PATH%/*}" "$REPO_ROOT")"
# P87: the forge is the other half — where branches and merge requests live.
# GitLab is both and resolves to itself; a board that is not a code host
# (Linear) resolves this from the repo's own remote. Resolved here for the same
# reason, at the same moment, under the same rule.
FORGE_SH="$(_forge_cmd "${SELF_PATH%/*}" "$REPO_ROOT")"

# A fresh, empty, uniquely-named directory for one session to write in, handed
# over as $LOOM_SCRATCH. `mkdir` is the uniqueness test, not a name guess: it
# fails if the directory exists, so two sessions starting in the same second
# cannot land on the same path. Created here because no spawned session may run
# `mkdir` itself, and never reused — a reused directory is the P17 bug.
_new_scratch() { # <prefix> → prints the directory
    local base="$SCRATCH_ROOT/$1-$(date +%Y%m%d-%H%M%S)" d n=0
    d="$base"
    while ! mkdir "$d" 2>/dev/null; do
        n=$((n+1)); d="$base-$n"
        [ "$n" -gt 200 ] && die "scratch: no unique directory under $SCRATCH_ROOT"
    done
    printf '%s\n' "$d"
}

# Unique-per-session means unbounded growth, and no session may run `rm`, so the
# scheduler prunes its own. Scoped to $SCRATCH_ROOT and guarded: an empty or
# unset root must delete nothing.
_prune_scratch() {
    case "$SCRATCH_ROOT" in ""|"/"|"$HOME") return 0 ;; esac  # mutate:scratch-prune-guard
    [ -d "$SCRATCH_ROOT" ] || return 0
    find "$SCRATCH_ROOT" -mindepth 1 -maxdepth 1 -type d \
         -mtime +"$SCRATCH_KEEP_DAYS" -exec rm -rf {} + 2>/dev/null || true
}

# Worktree sweep — the build cleans up after itself, on the same trust model
# as _prune_scratch: deterministic plumbing with provable scope, approved by
# the human 2026-08-02. A candidate must live at
# `.worktrees/<digits|probe-slug>` (current layout) or be named exactly
# `<repo>-wt-<digits|probe-slug>` (legacy sibling layout), AND either be a
# registered worktree of this repo whose branch is fully contained in
# origin/<base>, or an
# orphaned corpse whose .git file points into this repo's pruned metadata.
# A live lane's cwd is never touched; a tree with modified TRACKED files is
# never deleted (possible human work) — untracked droppings (chain briefs,
# build artifacts) don't count. The one irreplaceable file, a hand-filled
# .env, is backed up to the state dir first. (Paid for: build-1 2026-08-02 —
# two merged worktrees' artifact dirs became standing human chores the
# guardrails wouldn't let a lane clear.)
_sweep_env_backup() {
    local d="$1" dst="$LOOM_HOME/env-backups"
    [ -f "$d/.env" ] || return 0
    mkdir -p "$dst"
    cp "$d/.env" "$dst/$(basename "$d").env" 2>/dev/null || true
}

# P83: does an MR whose SOURCE BRANCH is this one exist in state `merged`?
# rc 0 yes, 1 a real "no", 2 the tracker could not be read. The distinction
# between 1 and 2 is the whole point: a definite "no merged MR" is a decision,
# an unreadable board is not, and only the first may keep a worktree on its own.
# Read-only, like everything else in this script.
_branch_merged() { # <branch>
    local br="$1" out=""
    [ -n "$br" ] || return 2
    out=$("$FORGE_SH" mr-for-branch "$br" --state merged 2>/dev/null) || return 2
    printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
    printf '%s' "$out" | jq -e 'length > 0' >/dev/null 2>&1 && return 0
    return 1
}

# P85: sweep's decisions have to leave the wave log. It printed "kept, needs a
# human" for thirty worktrees on every tick for five builds, into a file nobody
# reads, and the build-5 completion report tore the agent down without
# mentioning any of it. One event per PASS, not per worktree — a count that
# never falls is the signal, and thirty lines a tick is not.
_SWEEP_HELD=0
_SWEEP_REMOVED=0
_sweep_hold() { # <dir> <reason>
    _SWEEP_HELD=$((_SWEEP_HELD + 1))
    printf '%s\t%s\n' "$2" "$1" >> "$SWEEP_HELD_FILE.new"
}
_sweep_report() {
    # The inventory is rewritten whole each pass, so a worktree a human cleared
    # by hand stops being reported without anyone telling the loom about it.
    if [ -s "$SWEEP_HELD_FILE.new" ]; then mv -f "$SWEEP_HELD_FILE.new" "$SWEEP_HELD_FILE"
    else rm -f "$SWEEP_HELD_FILE.new" "$SWEEP_HELD_FILE"; fi
    [ "$_SWEEP_REMOVED" -gt 0 ] && _ev sweep_removed count "$_SWEEP_REMOVED"
    if [ "$_SWEEP_HELD" -gt 0 ]; then
        local reason
        reason=$(cut -f1 "$SWEEP_HELD_FILE" 2>/dev/null | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
        _ev sweep_held count "$_SWEEP_HELD" reason "${reason:-unknown}"
    fi
    return 0
}

# P85: the leftover inventory as one human-readable block, or nothing at all.
# Read by cmd_notify so a completion announcement cannot omit it.
_sweep_held_summary() {
    [ -s "$SWEEP_HELD_FILE" ] || return 0
    local n; n=$(wc -l < "$SWEEP_HELD_FILE" | tr -d ' ')
    printf '\n%s worktree(s) kept by sweep, needing a human:\n' "$n"
    while IFS="$(printf '\t')" read -r reason dir; do
        printf '  %s — %s\n' "${dir##*/}" "$reason"
    done < "$SWEEP_HELD_FILE"
}

cmd_sweep() {
    _SWEEP_HELD=0; _SWEEP_REMOVED=0; rm -f "$SWEEP_HELD_FILE.new"
    local base dir name branch st gd dir_p root_p
    # git always reports worktrees by their PHYSICAL path, so a REPO_ROOT
    # carrying a symlink (macOS /tmp -> private/tmp, /var -> private/var, or
    # any symlinked checkout) never matched below — and sweep silently swept
    # nothing, rc 0, no output. Same visible symptom as the pipefail crash,
    # different cause, so it has its own regression test.
    root_p=$(cd "$REPO_ROOT" 2>/dev/null && pwd -P) || root_p="$REPO_ROOT"
    base=$(_detect_base "$REPO_ROOT" "$CONFIG")
    # P84: --prune, so a remote-tracking ref expires with the branch it tracks.
    # Without it nothing ever expires them: five builds left 122 stale
    # `origin/ticket-*` refs pointing at branches the server had deleted, which
    # is also what made the remote LOOK like it held 122 branches when
    # `git ls-remote --heads` said 3. Any measurement of this must use
    # ls-remote, not `git branch -r`.
    git -C "$REPO_ROOT" fetch origin --prune --quiet 2>/dev/null || true
    # cwd of every ALIVE lane (running or stale) — never sweep ground a live
    # process stands on. A `stale` lane is quiet, not gone (P46).
    local live_cwds="" pid live_n=0
    for pid in $(_lanes_alive | awk '{print $2}' || true); do
        live_n=$((live_n + 1))
        live_cwds="$live_cwds $(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' || true)"
    done
    # This guard is the only thing standing between a live lane and `rm -rf` of
    # its worktree: a lane that has not committed yet is indistinguishable from
    # merged work (no commits ahead of base), and its new files are untracked,
    # so the modified-tracked-files check below does not see them either. If
    # lsof is missing or blocked we cannot tell live from dead — so do nothing.
    if [ "$live_n" -gt 0 ] && [ -z "${live_cwds//[[:space:]]/}" ]; then
        echo "sweep: $live_n lane(s) running but no cwd resolved (lsof unavailable?) — skipping sweep rather than risk a live worktree"
        rm -f "$SWEEP_HELD_FILE.new"   # a skipped pass observed nothing; keep the last real inventory
        return 0
    fi
    for dir in "$REPO_ROOT/.worktrees/"* "$REPO_ROOT"-wt-*; do
        [ -e "$dir" ] || continue
        case "$dir" in
            "$REPO_ROOT/.worktrees/"*) name="${dir##*/}" ;;
            *)                          name="${dir##*-wt-}" ;;
        esac
        case "$name" in
            ''  ) continue ;;
            *[!0-9]*) case "$name" in probe-*) ;; *) continue ;; esac ;;
        esac                                 # digits = ticket lanes; probe-* =
                                             # epic-acceptance worktrees
        dir_p=$(cd "$dir" 2>/dev/null && pwd -P) || dir_p="$dir"
        case " $live_cwds " in *" $dir "*|*" $dir_p "*) continue ;; esac
        if git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $dir_p"; then
            branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
            [ -n "$branch" ] || continue
            # P83: ask the tracker whether THIS BRANCH landed, because the
            # commit range answers a different question. `lane.sh reconcile`
            # merges origin/<base> into the branch; run once more after the
            # push the MR merged, the local tip carries a merge commit that was
            # never pushed and is unreachable from the base forever. Fifteen of
            # build-5's thirty held worktrees were exactly that: ticket closed,
            # MR merged, main holding the work, only the local topology
            # disagreeing.
            if _branch_merged "$branch"; then
                :                            # this branch's own MR is merged
            else
            # NEVER key this on ticket state. #67 shipped as bbac984 from
            # ticket-67-pending-turn-bound while ticket-67-realtime-turn-mark-pairing
            # sat beside it holding three commits and a 238-line variant that
            # merged in no form at all. Nothing at sweep time separates a
            # discarded draft from live work — both are commits on a branch
            # with no merged MR of its own — so "the ticket is closed" would
            # have armed rm -rf over it. That is D-TICK-17 through another door.
            #
            # With no merged MR, the range test decides, and it decides only
            # the safe direction: empty means nothing to lose (a probe
            # worktree, or a lane that never committed), so sweeping costs
            # nothing. Anything ahead of base stays.
            #
            # P47: `git log A..B` cannot tell "no commits ahead" from "range
            # does not resolve" once its own exit status is thrown away — an
            # unfetched or missing base ref used to read as "merged" and arm
            # the delete path on a worktree holding real, unmerged work.
            # Capture the exit status on its own (no pipe) so a failed
            # resolve dies instead of guessing.
            local _ahead ahead_rc
            _ahead=$(git -C "$REPO_ROOT" log "origin/$base..$branch" --oneline 2>/dev/null) && ahead_rc=0 || ahead_rc=$?
            if [ "$ahead_rc" -ne 0 ]; then
                echo "sweep: $dir — cannot resolve origin/$base..$branch (rc=$ahead_rc), base ref missing or unfetched — skipping rather than risk deleting unmerged work"
                continue
            fi
            if [ -n "$_ahead" ]; then
                continue                     # unmerged work — not ours to touch
            fi
            fi
            # `|| true` is load-bearing: under `set -euo pipefail`, a `grep -v`
            # that filters out every line exits 1, pipefail propagates it to the
            # assignment, and `set -e` killed the whole sweep silently with rc=1
            # before removing anything — including the `worktree prune` below.
            # Every merged worktree whose only leftovers were untracked files hit
            # this, i.e. the common case. (Paid for: build-1 2026-08-03 — sweep
            # had never once succeeded; a wave burned 80s under `bash -x` and
            # removed the worktree by hand.)
            #
            # D-TICK-17: that `grep -v '^??'` used to filter out UNTRACKED files
            # too, and untracked is where a lane's unsaved work lives. A lane
            # that has not committed yet is zero commits ahead of the base and
            # every new file it wrote is untracked, so filtering `??` made a
            # worktree full of work look exactly like an empty merged one and
            # armed `rm -rf` over it (boostlingo build-4 #98 — ~100 turns of
            # work gone). Only the hold marker below is filtered now. Untracked
            # here means untracked AND NOT IGNORED: `git status --porcelain`
            # never lists ignored paths, so node_modules, .venv and dist stay
            # invisible and the common tidy case still sweeps.
            st=$(git -C "$dir" status --porcelain 2>/dev/null | grep -vxF '?? .loom-sweep-hold' | head -1 || true)
            if [ -n "$st" ]; then
                case "$st" in
                    '??'*) echo "sweep: $dir merged but holds untracked work git does not ignore (${st#\?\? }) — kept, needs a human"; _sweep_hold "$dir" untracked-work ;;
                    *)     echo "sweep: $dir merged but has modified tracked files — kept, needs a human"; _sweep_hold "$dir" modified-tracked ;;
                esac
                continue
            fi
            _sweep_env_backup "$dir"
            if ! git -C "$REPO_ROOT" worktree remove --force "$dir_p" 2>/dev/null; then
                # D-TICK-17: `worktree remove` is not atomic, so "kept" was a
                # promise sweep broke about sixty seconds later. By the time it
                # fails on a root-owned node_modules or .venv it has usually
                # already dropped `.git/worktrees/<name>`, and the `worktree
                # prune` at the bottom of this function finishes that off — so
                # the next pass sees this very directory as an orphaned corpse
                # and deletes it down a path carrying none of the guards above.
                # The marker is the promise, written where the corpse path
                # reads it. It is filtered out of the status check above so a
                # later pass can still retry the removal it is holding.
                printf 'kept by sweep: git worktree remove failed here; do not delete without a human\n' \
                    > "$dir/.loom-sweep-hold" 2>/dev/null || true
                echo "sweep: git refused to remove $dir — kept"; _sweep_hold "$dir" git-refused
                continue
            fi
            [ -d "$dir" ] && rm -rf "$dir"  # mutate:sweep-merged-rmrf
            git -C "$REPO_ROOT" branch -d "$branch" >/dev/null 2>&1 || true
            echo "sweep: removed merged worktree $dir (branch $branch)"; _SWEEP_REMOVED=$((_SWEEP_REMOVED+1))
        else
            gd=""
            [ -f "$dir/.git" ] && gd=$(sed -n 's/^gitdir: //p' "$dir/.git" 2>/dev/null)
            case "$gd" in
                "$REPO_ROOT/.git/worktrees/"*|"$root_p/.git/worktrees/"*)
                    [ -d "$gd" ] && continue # metadata still live — not a corpse
                    # D-TICK-17: a corpse sweep made itself is not a corpse.
                    # This path has none of the merged path's guards — no ahead
                    # check, no dirty check — and it cannot re-derive them,
                    # because the gitdir it would need is exactly what is gone.
                    # So an earlier pass's "kept" is the only thing standing
                    # here, and it stands.
                    if [ -e "$dir/.loom-sweep-hold" ]; then
                        echo "sweep: $dir held from an earlier failed removal — kept, needs a human"; _sweep_hold "$dir" earlier-failure
                        continue
                    fi
                    _sweep_env_backup "$dir"
                    # `rm -rf`'s status used to be thrown away, so a partial
                    # delete — root-owned node_modules, an unwritable .venv —
                    # was announced as a completed one, in the one place in the
                    # program that destroys work.
                    if rm -rf "$dir" 2>/dev/null && [ ! -e "$dir" ]; then
                        echo "sweep: removed orphaned worktree corpse $dir"; _SWEEP_REMOVED=$((_SWEEP_REMOVED+1))
                    else
                        echo "sweep: could not fully remove orphaned worktree corpse $dir — what is left needs a human"; _sweep_hold "$dir" partial-corpse
                    fi ;;
                *) : ;;                      # not provably ours — never touch
            esac
        fi
    done
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
    _sweep_report
    return 0
}

# Quiescence watcher — deterministic and wave-independent, because the events
# that most need a notification are exactly the ones where no wave is alive
# to send it (paid for: build-1 2026-08-02 — a stalled build was silent for
# hours; quiet is indistinguishable from working unless something looks).
# Runs at the top of every tick, so the heartbeat doubles as the watcher.
# One cheap tracker read classifies quiet; a settle window keeps a chained
# handoff's few-second gap from reading as a stall. Notifications fire once
# per state change (sentinel in the run dir — plumbing, not build state).
# True when some epic in this build has all its tickets closed and its
# milestone still open — i.e. no probe has passed on it. Deliberately reads
# CLOSED members: an accepted-but-unprobed epic has no open tickets left to
# find it by. Costs one extra pair of calls, and only on the completion path
# (`count == 0`), so the common tick pays nothing. Any failure returns false —
# this gate must never invent a reason to withhold a legitimate completion.
_epics_unaccepted() { # <build-label>
    local label="$1" closed ms
    [ -n "$label" ] || return 1
    closed=$("$TRACKER_SH" issues-by-label "$label" closed 2>/dev/null) || return 1
    ms=$("$TRACKER_SH" milestones --state active 2>/dev/null) || return 1
    printf '%s' "$closed" | jq -e --argjson ms "${ms:-[]}" '
        ([.[] | .epic // empty] | unique) as $mine
        | ($ms | map(.title) | map(select(. as $t | $mine | index($t))) | length) > 0
    ' >/dev/null 2>&1
}

# P43: the timestamp of the newest event that means the BUILD did something.
# `tick_skipped` and `notify` are both excluded: each is the watcher writing
# about ITSELF, not the build doing work. **If the watcher emits an event kind,
# that kind must never be able to feed the watcher's own activity signal** —
# missing `notify` cost a second round. The first fix classified `halted`,
# notified, and the notification landed in this same file; the firing 60s later
# read it as activity, answered `active`, and deleted the
# once-per-state-change sentinel; the firing after that classified `halted`
# with no memory and notified again. A 2-minute oscillation that re-pushed
# "Build halted" forever and let a wave through at each gap boundary, so the
# spend never stopped. The settle window used to read this file's mtime,
# which every 60s firing refreshed with exactly such a no-op. 60s < the 120s
# window, so `_quiet_check` returned `active` on every firing, never reached
# the halted test, and the halted gate in `cmd_tick` was unreachable code:
# a build whose every open ticket was human-held still launched a model
# session every `min_wave_gap_minutes` to be told so. (Paid for: build-3
# 2026-08-05 — 44 idle waves overnight, ~9 USD, on a board holding one
# blocked ticket.) An empty result reads as "no activity ever", which is the
# honest answer and lets the classification below run.
#
# The same rule reaches one level up: `wave_start`, `wave_end` and `snapshot`
# are the SCHEDULER writing about itself. A wave that finds nothing schedulable
# still writes all three, and the tick 60s later reads the trailing `wave_end`
# as build activity, answers `active`, and sails through the halted gate into
# another wave. Only lanes and tracker mutations — `lane_*`, `ticket_*`,
# `mr_merged`, `gate_verdict` — mean the BUILD did something. A wave doing real
# work is covered anyway: it spawns lanes, and those events do count.
# (Paid for: build-3 2026-08-06 — wave-035350 started 62s after wave-022852
# ended, on a board holding one blocked ticket.)
_last_activity_ts() {
    [ -f "$EVENTS" ] || { echo 0; return 0; }
    tail -n 500 "$EVENTS" 2>/dev/null \
        | jq -r 'select(.ev | IN("tick_skipped","notify","wave_start","wave_end",
                                 "snapshot","tick_replayed") | not) | .ts // empty' 2>/dev/null \
        | tail -1 | grep -E '^[0-9]+$' || echo 0
}

# `unknown` and `unreadable` are two different facts and the spend gate treats
# them differently. `unknown` = there is no build to classify yet (no label
# written), which is the normal pre-plan state and must not stop a tick.
# `unreadable` = there IS a build and the tracker call FAILED, so the board's
# real state is unavailable — that one must never buy a wave on the timer.
_quiet_check() { # prints: active | stalled | halted | complete | unknown | unreadable
    local label age open count blocked
    [ -f "$LOOM_HOME/.build-label" ] || { echo unknown; return 0; }
    label=$(cat "$LOOM_HOME/.build-label" 2>/dev/null)
    [ -n "$label" ] || { echo unknown; return 0; }
    if [ -n "$(_lanes_alive)" ]; then
        echo active; return 0
    fi
    age=$(( $(date +%s) - $(_last_activity_ts) ))
    [ "$age" -lt "${LOOM_QUIET_SETTLE:-120}" ] && { echo active; return 0; }
    open=$("$TRACKER_SH" issues-by-label "$label" opened 2>/dev/null) \
        || { echo unreadable; return 0; }
    count=$(printf '%s' "$open" | jq 'length' 2>/dev/null) || { echo unreadable; return 0; }
    # Zero open tickets is "all the work merged", NOT "the product was
    # accepted". An epic whose probe never ran — or ran, FAILED, and had its
    # fixes merged — reaches this line looking exactly like one that passed,
    # and `complete` here both notifies and (via step 8) tears the agent down.
    # An unaccepted epic is schedulable work, so it reads as `stalled`: the
    # existing stall_action machinery then resumes a wave, which finds
    # `summary.epics_awaiting_probe` waiting for it. (Paid for: build-2
    # 2026-08-04 — E4 never re-probed after its FAIL, E6 and E7 never probed,
    # build closed anyway 97s after the last ticket merged.)
    if [ "$count" = "0" ]; then
        if _epics_unaccepted "$label"; then echo stalled; else echo complete; fi
        return 0
    fi
    blocked=$(printf '%s' "$open" | jq '[.[] | select(.labels | index("blocked"))] | length' 2>/dev/null)
    [ "$blocked" = "$count" ] && { echo halted; return 0; }
    echo stalled
    return 0
}

# The "once per state change" core, written four times before this: the quiet
# states, workspace trust, the un-armed heartbeat, and the two stale flags. A
# per-tick warning is fifteen stderr lines into a log nobody reads, or five
# identical "Build halted" pushes in one night; the sentinel file is what turns
# it into one message per change. Deciding and RECORDING are one step here, so
# a caller cannot notify twice by forgetting to write the sentinel. Empty
# <state> re-arms: the sentinel goes, and the next non-empty state is a change
# again.
_once_per_state() { # <sentinel> <state> → 0 say it now, 1 already said
    local sentinel="$1" state="${2:-}" prev=""
    if [ -z "$state" ]; then rm -f "$sentinel"; return 1; fi
    [ -f "$sentinel" ] && prev=$(cat "$sentinel" 2>/dev/null)
    [ "$state" = "$prev" ] && return 1
    mkdir -p "$(dirname "$sentinel")" 2>/dev/null || :
    printf '%s\n' "$state" > "$sentinel"
    return 0
}

_notify_quiet() { # <state> — notify once per state change; activity re-arms
    local state="$1" sentinel="$LOOM_HOME/quiet.state"
    # A failed read is not a state change and must not erase the memory of one.
    # Clearing the sentinel here re-arms whatever the build was already in, so
    # every network blip re-pushed the same "Build halted" banner — five of them
    # in one night, which is how the human noticed any of this. Say nothing,
    # remember nothing, wait for a firing that could actually see the board.
    [ "$state" = unreadable ] && return 0
    # Both carve-outs stay HERE, not in the core: `unreadable` is this reader's
    # own third answer, and re-arming on activity is this state machine's rule
    # about which states mean "the build is moving again".
    if [ "$state" = active ] || [ "$state" = unknown ]; then rm -f "$sentinel"; return 0; fi
    _once_per_state "$sentinel" "$state" || return 0
    case "$state" in
        complete) cmd_notify build_complete "Build complete" \
            "Ready set empty, no lanes left. The completion wave posts the report." || : ;;
        halted)   cmd_notify build_halted "Build halted — every open ticket is blocked" \
            "Resolve a blocked ticket (unblock verb) and the next tick resumes." || : ;;
        stalled)  cmd_notify build_stalled "Build stalled — work is ready but nothing is running" \
            "No lanes, no wave, unblocked tickets waiting. stall_action decides resume vs wait." || : ;;
    esac
    return 0
}

# A headless session loads the repo's allowlist only in a TRUSTED workspace. In
# an untrusted one, `--permission-mode dontAsk` prints "Ignoring N
# permissions.allow entries from .claude/settings.json" and every command falls
# to the classifier, which denies most of them — a lane that burns a whole
# session accomplishing nothing (P16). Trust cascades from any ancestor, so the
# parent directory usually already covers a freshly-created worktree; this reads
# that state and never writes it (granting a directory blanket auto-approval is
# the human's call, not a script's).
# The NEAREST entry wins, either way: a directory whose own entry says false is
# refused even under a trusted parent, because someone declined that dialog on
# purpose. (Whether Claude Code itself resolves that case the same way is
# unverified — this is the conservative reading, and it errs toward a loud
# refusal the human can clear in one step.)
# Exit codes are THREE-valued, because "declined" and "never asked" are different
# facts and P30's repo-root check must treat them differently:
#   0  trusted (prints the ancestor that grants it)
#   2  explicitly declined — a `false` entry, someone answered that dialog no
#   1  no entry anywhere, or no readable trust file — we cannot tell
_nearest_trust() { # <absolute-dir> → prints the trusted ancestor, or fails
    [ -f "$TRUST_FILE" ] || return 1
    local d="$1" v
    while [ -n "$d" ]; do
        # `tostring`, never `// "none"` — jq's alternative operator treats false
        # as absent, which would walk straight past a declined directory to its
        # trusted parent and spawn the lane anyway.
        v=$(jq -r --arg d "$d" '.projects[$d].hasTrustDialogAccepted | tostring' \
               "$TRUST_FILE" 2>/dev/null) || return 1
        case "$v" in
            true)  printf '%s\n' "$d"; return 0 ;;
            false) return 2 ;;
        esac
        [ "$d" = "/" ] && break
        d=$(dirname "$d")
    done
    return 1
}

# The main worktree's root — NOT `rev-parse --show-toplevel`, which in a linked
# worktree returns the worktree itself. `worktree list` puts the main one first,
# always; `sed` rather than awk so a path containing spaces survives.
_git_main_root() { # <dir> → prints the main worktree root; empty if not a repo
    git -C "$1" worktree list --porcelain 2>/dev/null | sed -n '1s|^worktree ||p'
}

# P93: chain-merge's own lookup — the next merge-queue ticket names its
# branch, not its worktree, so the fast path resolves the worktree the same
# way `git` itself tracks the pairing, never by guessing a `<repo>-wt-<n>`
# name. Empty means no worktree is checked out on that branch (swept,
# never created, or a plain-tracker auto-merge raced it) — chain-merge reads
# that as "cannot chain" and falls back to firing a wave, same as an empty
# queue.
_worktree_for_branch() { # <repo-dir> <branch> → prints the worktree path, or nothing
    git -C "$1" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$2" '
        /^worktree / { w = substr($0, 10) }
        $0 == "branch " b { print w; exit }
    '
}

_lane_launch_label() { # <lane-id> — stable until clear-lane retires the job
    printf 'com.loom.lane.%s.%s\n' "$REPO_KEY" "$1"
}

# A fixed repository PORT is safe for one checkout and wrong for parallel
# linked worktrees: Playwright either refuses the occupied port or polls a
# server from another ticket. Give every lane a stable local port so retries
# keep their address while concurrent lanes cannot cross-test one another.
# The public range is deliberately away from the repo default and common DB
# ports; LOOM_LANE_PORT remains an explicit test/operator override.
_lane_port() { # <lane-id>
    local sum
    sum=$(printf '%s' "$REPO_KEY:$1" | cksum | awk '{print $1}')
    printf '%s\n' "$((30000 + (sum % 20000)))"
}

_plist_string() { # <value> — one XML-safe plist string element
    printf '<string>'
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
    printf '</string>\n'
}

_write_lane_plist() { # <path> <label> <log> -- <program arguments...>
    local path="$1" label="$2" log="$3"; shift 3
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0"><dict>'
        printf '%s\n' '<key>Label</key>'; _plist_string "$label"
        printf '%s\n' '<key>ProgramArguments</key><array>'
        while [ $# -gt 0 ]; do _plist_string "$1"; shift; done
        printf '%s\n' '</array>'
        printf '%s\n' '<key>RunAtLoad</key><true/>'
        # Deliberately omit KeepAlive. `launchctl submit` inferred it for these
        # workers and replayed a completed merge every 15–20 seconds. A lane is
        # one build action: its epilogue requests the next scheduler tick, but
        # launchd must never execute that same action a second time.
        # Standard avoids Background throttling that tripped Vitest's worker RPC timeout (JOR-262).
        printf '%s\n' '<key>ProcessType</key><string>Standard</string>'
        printf '%s\n' '<key>StandardOutPath</key>'; _plist_string "$log"
        printf '%s\n' '<key>StandardErrorPath</key>'; _plist_string "$log"
        printf '%s\n' '</dict></plist>'
    } > "$path"
}

_lane_launchd_pid() { # <lane-id> — authoritative pid when launchd says active
    local id="$1" marker="$LANES_DIR/$1.launchd" label info
    [ -s "$marker" ] || return 1
    label=$(cat "$marker" 2>/dev/null || true); [ -n "$label" ] || return 1
    info=$("$LAUNCHCTL_CMD" print "gui/$(id -u)/$label" 2>/dev/null) || return 1
    printf '%s\n' "$info" | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -1
}

_lane_process_alive() { # <lane-id> <recorded-pid>
    local id="$1" pid="$2" launch_pid marker="$LANES_DIR/$1.launchd"
    [ -n "$pid" ] || return 1
    if [ -s "$marker" ]; then
        # The launchd record is authoritative for a launchd-owned one-shot.
        # After the job exits, its numeric pid can be reused by an unrelated
        # process; trusting kill -0 first then resurrects a completed lane in
        # the ticker. This also covers Codex sandboxes that cannot signal-probe
        # a live sibling job: active launchd jobs expose a pid, exited jobs do
        # not, regardless of the recorded pid file.
        launch_pid=$(_lane_launchd_pid "$id" 2>/dev/null || true)
        [ -n "$launch_pid" ]
        return
    fi
    kill -0 "$pid" 2>/dev/null
}

# The question the walk above asks is the FILESYSTEM one, and Claude Code answers
# a different one (P30). SKILL.md step 4 mandates lane worktrees be SIBLINGS of
# the repo, so `…/Projects/<repo>-wt-5` has parent `…/Projects` and the walk
# reaches a trusted ancestor without ever passing through the repo root. Claude
# Code, running inside that worktree, resolves trust through the GIT REPO and
# reads the repo root's entry instead.
#
# Paid for: seat-reservations build-1, 2026-08-03. `…/Projects: true` and
# `…/Projects/seat-reservations: false` — all 46 lane spawns passed the old
# guard and the allowlist was ignored in every one. Nothing surfaced until the
# first command that needed it, the first merge, 77 minutes in; #5 and #21 went
# blocked for 47m43s combined and then merged in under four minutes, with no
# code change, once the human accepted the dialog. impl-1's own log names the
# resolution rule outright: its cwd was `…/seat-reservations-wt-1` and the
# refusal named `…/seat-reservations`.
#
# So: ask BOTH. A repo root with no entry of its own still cascades from its
# ancestors, so this refuses only what the old guard should have — never a lane
# that would have worked.
_trust_check_dir() { # <absolute-dir> → 0 trusted; else 1, printing the path to fix
    local dir="$1" main rc=0
    _nearest_trust "$dir" >/dev/null || { printf '%s\n' "$dir"; return 1; }
    main=$(_git_main_root "$dir")
    if [ -n "$main" ] && [ "$main" != "$dir" ]; then
        _nearest_trust "$main" >/dev/null || rc=$?
        # Only an EXPLICIT decline (rc 2) refuses. rc 1 — no entry anywhere for
        # that spelling — means we cannot tell, and refusing on it would be the
        # false refusal P30 calls worse than the gap being closed: `git worktree
        # list` reports the PHYSICALLY RESOLVED path while the trust file is
        # keyed by whatever path Claude Code was launched with, so under any
        # symlinked prefix (/tmp, /var, a symlinked home) the two spellings
        # disagree and every lane in a perfectly trusted repo would be refused.
        [ "$rc" -eq 2 ] && { printf '%s\n' "$main"; return 1; }
    fi
    return 0
}

# Once per state change, like _notify_quiet — a per-tick warning becomes P3's
# fifteen stderr lines into a log nobody reads.
_notify_trust() { # <untrusted-path> | "" (empty = trusted, re-arms)
    local bad="${1:-}"
    # The state IS the path: a different untrusted directory is a new fact and
    # says so, the same one twice says nothing, and trusted (empty) re-arms.
    _once_per_state "$LOOM_HOME/trust.state" "$bad" || return 0
    cmd_notify workspace_untrusted "Workspace not trusted — lanes will ignore the allowlist" \
        "$bad has not been trusted, so .claude/settings.json is ignored there and lane commands fall to the classifier. Run \`claude\` in it once and accept the trust prompt." >/dev/null 2>&1 || :
    return 0
}

# --- config readers (ntfy block; the flat-key readers are in lib.sh) ------
_ntfy_key() { # _ntfy_key <file> <key>   (key is matched with its colon, so
              # `topic` never matches `topic_prefix`)
    [ -f "$1" ] || { echo ""; return; }
    awk -v k="$2" '$0 ~ /^ntfy:/{f=1;next} f&&/^[^[:space:]]/{f=0}
        f && $0 ~ ("[[:space:]]" k ":") {
            sub(".*" k ":[[:space:]]*",""); sub(/[[:space:]]*#.*$/,"");
            gsub(/"/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit }' "$1"
}

# Layered like every other key: repo topic, else global topic, else derived as
# <global topic_prefix><repo name> — so one global line covers every repo and
# no per-repo topic is ever hand-written.
cfg_ntfy_topic() {
    local v
    v=$(_ntfy_key "$CONFIG" topic);        [ -n "$v" ] && { printf '%s\n' "$v"; return; }
    v=$(_ntfy_key "$GLOBAL_CONFIG" topic); [ -n "$v" ] && { printf '%s\n' "$v"; return; }
    v=$(_ntfy_key "$GLOBAL_CONFIG" topic_prefix)
    [ -n "$v" ] && printf '%s%s\n' "$v" "$(basename "$REPO_ROOT")"
    return 0
}

cfg_ntfy_events() {
    local f
    for f in "$CONFIG" "$GLOBAL_CONFIG"; do
        [ -f "$f" ] || continue
        # `push:` must be the line's first token — not merely somewhere on it.
        # An unanchored match ate the COMMENT above the real key ("the reader
        # takes the first `push:` line and stops", backticks and all), printed
        # that as the event list, and exited. Every event then failed the
        # allowlist and no notification fired again — silently, because the
        # ticker line lives past that gate too. (Paid for: the comment landed
        # in the global config at 19:59 on 2026-08-03, between build-1 and
        # build-2; build-2 then ran a whole night and completed twice with
        # zero notifications, and the human found it by noticing the ticker
        # never said "build complete".)
        awk '/^ntfy:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/^[[:space:]]*push:/{
            sub(/.*\[/,""); sub(/\].*/,""); gsub(/,/," "); print; exit }' "$f" | grep . && return 0
    done
    return 0
}

# --- lock (mkdir-atomic, PID-owned, stale-broken) -------------------------
# ONE shape, three locks: the tick lock, the merge lock and the per-gate lock
# were the same fifteen lines written three times, so a fix to the break-stale
# rule had three places to land and could miss one. mkdir is the atom (it
# either creates the directory or it does not, with no window between asking
# and having); the pid file names the owner; an owner that is gone gets its
# lock broken by the next attempt, so the worst case is one skipped
# tick/merge/gate and never two at once.
_lock_reserve() { # <dir> → 0 reserved (pid stamped), 1 genuinely held
    local dir="$1" owner
    mkdir -p "$(dirname "$dir")" 2>/dev/null || :
    if mkdir "$dir" 2>/dev/null; then
        echo $$ > "$dir/pid"; return 0
    fi
    owner=$(cat "$dir/pid" 2>/dev/null || echo "")
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        return 1                          # genuinely held
    fi
    rm -rf "$dir"                         # owner dead: break the stale lock
    _lock_reserve "$dir"
}

_lock_owner() { # <dir> → prints the live owner pid, or nothing
    local owner
    owner=$(cat "$1/pid" 2>/dev/null || echo "")
    [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && printf '%s\n' "$owner"
    return 0
}

# The EXIT trap is the tick lock's alone and stays at this call site: this lock
# dies with the process that takes it, and the other two deliberately outlive
# theirs.
lock_acquire() {
    _lock_reserve "$LOCK_DIR" || return 1  # genuinely held — skip this tick
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
}

# Same rules, no EXIT trap: this lock outlives the process that takes it. It is
# reserved here, stamped with the LANE's pid once the lane exists, and released
# by the lane itself on exit. A lane killed outright leaves the directory
# behind, and the dead-owner check breaks it on the next attempt — the failure
# mode is one skipped merge, never two merges at once.
_merge_lock_reserve() { # → 0 reserved, 1 genuinely held
    _lock_reserve "$MERGE_LOCK_DIR"
}

# Keep the previous run's transcript, but never its mtime. A reused lane id
# inheriting an old log reads as `stale` on the first status check and gets a
# healthy lane killed; truncating instead would throw away exactly what crash
# triage needs. Build 2's logs stacked two to four sessions in one file, which is
# why several of its session boundaries are unrecoverable (P13).
_rotate_log() { # <path>
    [ -s "$1" ] || return 0
    local ext="${1##*.}" stem="${1%.*}"
    # $$ as well as the timestamp: two spawns in the same second must not
    # overwrite each other's rotated file.
    mv "$1" "$stem-$(date +%Y%m%d-%H%M%S)-$$.$ext" 2>/dev/null || :
    return 0
}

_merge_lock_owner() { # prints the live owner pid, or nothing
    _lock_owner "$MERGE_LOCK_DIR"
}

# Same shape as the merge lock, keyed per ticket+commit instead of one global
# dir (P67) — <key> is "<ticket>@<sha>", so gate-14 at one HEAD never queues
# behind gate-9 at another, only behind its own true duplicate.
_gate_lock_reserve() { # <key> → 0 reserved, 1 genuinely held
    _lock_reserve "$GATE_LOCK_DIR/$1"
}

_gate_lock_owner() { # <key> → prints the live owner pid, or nothing
    _lock_owner "$GATE_LOCK_DIR/$1"
}

_aux_lane_id() { # <lane-id> → true for the max_aux_lanes population
    case "$1" in gate-*|merge-*|probe-*) return 0 ;; *) return 1 ;; esac
}

_aux_capacity_usage() { # live aux lanes + queued reservations, excluding the request being drained
    local alive reserved=0 request queued_id drain_id="${LOOM_AUX_DRAIN_ID:-}"
    alive=$(_lanes_alive | awk '$4=="gate"||$4=="merge"||$4=="probe" { n++ } END { print n+0 }')
    for request in "$LANE_LAUNCH_DIR"/request-* "$LANE_LAUNCH_DIR"/launching-*; do
        [ -d "$request" ] || continue
        queued_id=$(cat "$request/id" 2>/dev/null || true)
        [ -n "$queued_id" ] || continue
        [ "$queued_id" != "$drain_id" ] || continue
        _aux_lane_id "$queued_id" && reserved=$((reserved + 1))
    done
    printf '%s\n' "$((alive + reserved))"
}

_aux_admission_refusal() { # <id> <from-lane> <used> <cap> — soft for handoff, retryable for drain
    local id="$1" from="$2" used="$3" cap="$4"
    echo "spawn-lane: auxiliary lane cap full ($used of $cap held by gates, merges, probes, or queued handoffs) — not starting '$id'."
    if [ -n "$from" ]; then
        echo "  Successor handoff from '$from' is optional; the ordinary heartbeat schedules it when a slot is free."
    fi
    _ev lane_chain_skipped id "$id" from "${from:-scheduler}" reason aux_cap used "$used" cap "$cap"
    # A durable drain must keep the queued request. 75 is private to this
    # tick.sh-to-tick.sh boundary; direct lane handoffs remain successful no-ops.
    [ "${LOOM_AUX_DRAIN_ID:-}" != "$id" ] || return 75
    [ -n "$from" ] && return 0
    return 1
}

_gate_ticket_in_review() { # <gate-id> → 0 review, 1 definite non-review, 2 unreadable
    local id="$1" iid issue
    iid="${id#gate-}"; iid="${iid%%-*}"
    case "$iid" in ''|*[!0-9]*) return 1 ;; esac
    issue=$("$TRACKER_SH" issue "$iid" 2>/dev/null) || return 2
    printf '%s' "$issue" | jq -e '
      (.state // "open") == "open"
      and (((.labels // []) | index("review")) != null)
    ' >/dev/null 2>&1 || return 1
    return 0
}

_gate_launch_refusal() { # <id> <from-lane> <reason> — shared direct/queued semantics
    local id="$1" from="$2" reason="$3"
    case "$reason" in
        unreadable)
            echo "spawn-lane: cannot verify whether '$id' is still in review — failing closed."
            _ev lane_chain_skipped id "$id" from "${from:-scheduler}" reason gate_state_unreadable
            # A durable request survives a transient tracker outage. A direct
            # handoff is optional and the heartbeat will derive it again.
            [ "${LOOM_AUX_DRAIN_ID:-}" != "$id" ] || return 75
            [ -n "$from" ] && return 0
            return 1
            ;;
        *)
            echo "spawn-lane: ticket for '$id' is no longer in review — discarding this stale gate launch."
            echo "  A later tracker state outranks an earlier wave plan or queued handoff."
            _ev lane_chain_skipped id "$id" from "${from:-scheduler}" reason gate_no_longer_review
            return 0
            ;;
    esac
}

# --- usage limits (P14) and wave crashes (P15) ----------------------------
# One session-limit event cost build 2 **57m35s — a quarter of the whole run**.
# The wave log for it is a single line ("You've hit your session limit · resets
# 10pm"), nothing recorded that it had happened, and every tick that followed
# burned a fresh session to rediscover the same wall.
#
# The signal is machine-readable, and P13 is what put it within reach: a streamed
# session emits `rate_limit_event` carrying `resetsAt` as an epoch. No parsing of
# "resets 10pm (America/Chicago)" out of prose, and no timezone guessing.
USAGE_PAUSE="${LOOM_USAGE_PAUSE:-$LOOM_HOME/usage.pause}"
# The loop's on/off switch, and the whole reason one program can do the work of
# the two it replaces. `stop` writes it, `start` removes it. It gates AUTOMATIC
# continuation only — the timer, and a lane chaining to its own successor —
# never a human typing `tick`. Run-dir plumbing, not build state (constitution
# carve-out), and deliberately a file rather than a launchd fact: a lane that
# was spawned before `stop` has its follow-on command already baked in, so the
# only place the decision can be read is when that command runs.
LOOP_STOPPED="${LOOM_LOOP_STOPPED:-$LOOM_HOME/loop.stopped}"
# Sentinel for the un-armed push, same shape as quiet.state: one notification
# per state change, not one line per tick.
UNARMED_STATE="${LOOM_UNARMED_STATE:-$LOOM_HOME/agent.unarmed}"
WAVE_FAILS="${LOOM_WAVE_FAILS:-$LOOM_HOME/wave-failures}"
RETRY_BACKOFF="${LOOM_RETRY_BACKOFF_SECONDS:-30}"

# --- events (P23): the diagnostic record --------------------------------
# Every number behind proposals P1–P22 was reconstructed BY HAND from 31 raw
# transcripts plus filename arithmetic. That evidence base does not survive to
# the next build, so improvements stayed anecdotal and no change could be shown
# to have helped. This makes the evidence fall out of running a build.
#
# Three rules hold this honest:
#   * The MACHINERY writes it, never the model. A model-written log goes missing
#     exactly when a wave crashes, which is when it is needed.
#   * WRITE-ONLY from the loop's point of view. Nothing in a scheduling decision
#     ever reads it. If a wave consulted this file it would become shadow state
#     and break constitution rule 1. It is for humans and for `report`.
#   * It SURVIVES builds. Every line carries the build label, so build 3 can be
#     measured against build 2 instead of replacing it.
EVENTS="${LOOM_EVENTS_FILE:-$LOOM_HOME/events.jsonl}"
# The build label is cached when a snapshot resolves it, purely to TAG these
# records. It is never read to decide anything — see the write-only rule above.
BUILD_LABEL_CACHE="$LOOM_HOME/.build-label"

_ev() { # _ev <event> [key value]...  — one JSON line, appended
    [ -z "${LOOM_NO_EVENTS:-}" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local build; build=$(cat "$BUILD_LABEL_CACHE" 2>/dev/null || echo "")
    local ev="$1"; shift
    # One line, one write. Short lines stay under PIPE_BUF, so concurrent
    # appends from lanes and waves cannot interleave.
    jq -nc --arg ev "$ev" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --argjson ts "$(date +%s)" --arg build "$build" --args '
        {t: $t, ts: $ts, ev: $ev,
         build: (if $build == "" then null else $build end)}
        # Bind the index and the value; never lean on `.` here. A piped
        # fallback rebinds `.` to the value, so `$p[.+1]` became
        # "<value> + 1" and the whole event silently failed to write. Second
        # time this exact trap has cost something in this file.
        + ([$ARGS.positional as $p
            | range(0; ($p | length); 2) as $i
            | ($p[$i + 1]) as $val
            | {($p[$i]): ($val | tonumber? // ($val | fromjson? // $val))}] | add // {})' \
        "$@" >> "$EVENTS" 2>/dev/null || true
    return 0
}

cmd_event() { # event <name> [key value]...  — so a lane can record its own exit
    [ -n "${1:-}" ] || die "event: missing event name"
    _ev "$@"
}

_now() { date +%s; }
_stamp() { # <epoch> → local human time, for a human reading a push notification
    date -r "$1" '+%H:%M %Z' 2>/dev/null || date -d "@$1" '+%H:%M %Z' 2>/dev/null || printf '%s' "$1"
}

_is_agent_cmd() { [ "${1:-}" = "$AGENT_SH" ] || [ "$(basename "${1:-}")" = agent.sh ]; }

_assert_build_provider() { # <provider> — tracker is canonical, argument is transport
    local provider="$1" raw build labels count current
    [ -n "${LOOM_SKIP_PROVIDER_CHECK:-}" ] && return 0
    "$AGENT_SH" detect --provider "$provider" >/dev/null \
      || die "tick: '$provider' has no registered provider adapter"
    raw=$("$TRACKER_SH" issues-open) || die "tick: cannot verify provider — open Build issue read failed"
    build=$(printf '%s' "$raw" | jq -r '[.[]|select((.title//"")|test("^Build [0-9]+$"))]|sort_by(.id)|last|.id//empty')
    [ -n "$build" ] || die "tick: cannot verify provider — no open Build N issue"
    labels=$(printf '%s' "$raw" | jq -r --argjson id "$build" '.[]|select(.id==$id)|[.labels[]?|select(startswith("provider::"))]|join(",")')
    count=$(printf '%s' "$raw" | jq -r --argjson id "$build" '.[]|select(.id==$id)|[.labels[]?|select(startswith("provider::"))]|length')
    [ "$count" -eq 1 ] || die "tick: Build #$build must carry exactly one provider:: label (found ${count}: ${labels:-none})"
    current="${labels#provider::}"
    "$AGENT_SH" detect --provider "$current" >/dev/null \
      || die "tick: Build #$build carries provider::$current, but that adapter is not registered"
    [ "$current" = "$provider" ] || die "tick: scheduler transport says '$provider' but Build #$build says '$current' — refusing before model invocation"
}

# Only ever consulted on a FAILED session. A `rate_limit_event` with status
# "allowed" appears in perfectly normal runs — treating one as a limit would
# stall a healthy build — so the failure is the trigger and the event only
# supplies the resume time.
_limit_reset_at() { # <jsonl> <log> <err> → epoch to resume after, or nothing
    local jsonl="$1" at=""
    shift
    # A limit must be named somewhere in what the session actually said.
    grep -qiE 'usage limit|session limit|rate limit|quota|limit reached|resets? (at|in) ' "$@" 2>/dev/null \
        || { [ -s "$jsonl" ] && grep -q '"type":"limit"' "$jsonl" 2>/dev/null; } \
        || return 0
    if command -v jq >/dev/null 2>&1; then
        at=$(cat "$jsonl" "$@" 2>/dev/null \
             | jq -Rr 'fromjson? | select(.type == "limit") | .reset_at // empty' 2>/dev/null \
             | tail -1)
    fi
    case "$at" in
        ''|*[!0-9]*) # Known to be a limit, but the runtime did not say when it
                     # lifts. Re-check on a fixed interval rather than guess a
                     # clock time — one skipped tick is the whole cost of being
                     # wrong, and a wrong parsed timezone is much more expensive.
                     at=$(( $(_now) + 900 )) ;;
    esac
    printf '%s\n' "$at"
}

# Returns 1 when this tick must not run — the capacity is not back yet, so a
# session would be spent proving that again.
_usage_gate() {
    [ -f "$USAGE_PAUSE" ] || return 0
    local until_at; until_at=$(cat "$USAGE_PAUSE" 2>/dev/null || echo 0)
    case "$until_at" in ''|*[!0-9]*) rm -f "$USAGE_PAUSE"; return 0 ;; esac
    # `stop_and_wait` is the policy for someone who wants to decide by hand when
    # to spend capacity again: the pause never lifts on its own, and `tick.sh
    # resume` is the one step that clears it.
    if [ "$(cfg usage_limit pause_and_resume)" = "stop_and_wait" ]; then
        echo "tick: paused on a usage limit (policy stop_and_wait) — clear it with \`tick.sh resume\`"
        return 1
    fi
    if [ "$(_now)" -lt "$until_at" ]; then
        echo "tick: usage limit — capacity returns at $(_stamp "$until_at"); not spending a session until then"
        return 1
    fi
    rm -f "$USAGE_PAUSE"
    _ev usage_resume
    echo "tick: usage limit lifted — resuming"
    cmd_notify usage_resume "Build resumed" "Usage limit lifted; scheduling again." >/dev/null 2>&1 || :
    return 0
}

# Both attempt paths hit the same wall and must answer it identically. Written
# twice, the retry copy was simply MISSING for a while: a crash followed by a
# limit wrote no pause, exited nonzero and counted as a crash, so every tick
# after it burned a fresh session against the same wall — the exact behaviour
# P14 exists to stop. One helper, called from both, is what makes that
# impossible to reintroduce by editing only one of them.
_pause_on_limit() { # <stem> <first|retry|lane-<id>> → 0 paused, 1 no limit there
    local stem="$1" source="$2" until_at where=""
    until_at=$(_limit_reset_at "$LOGS_DIR/$stem.jsonl" "$LOGS_DIR/$stem.log" \
                               "$LOGS_DIR/$stem.err.log")
    [ -n "$until_at" ] || return 1
    case "$source" in
        retry)  where=" on the retry" ;;
        lane-*) where=" in lane ${source#lane-}" ;;
    esac
    printf '%s\n' "$until_at" > "$USAGE_PAUSE"
    _ev usage_pause until "$until_at" source "$source"
    echo "tick: usage limit hit$where — pausing until $(_stamp "$until_at")"
    cmd_notify usage_pause "Build paused — usage limit" \
        "No capacity until $(_stamp "$until_at"). The build resumes on the first tick after that." \
        >/dev/null 2>&1 || :
    return 0
}

# D-TICK-20: the same wall, met by a LANE instead of by a wave. A lane's own
# A provider session is killed by the account-wide limit in ~5s, its epilogue records
# `lane_exit rc=1` — schema-identical to a crash — and chains onward
# (`chain-merge`, or `tick --from-lane`, which ignores `min_wave_gap_minutes`
# because a handoff is work already in progress). The successor recomputes the
# same plan off an untouched ticket and respawns the identical lane, which dies
# to the same still-active limit. Nothing paced it: `_pause_on_limit` was
# reachable only from the two wave attempts, so `_usage_gate` had nothing to
# gate on and no `usage_pause` event ever said what was happening.
# (triggers-api build-2, 2026-08-14: merge-83 cycled lane_exit rc=1 → lane_spawn
# eight times in 47 seconds, ~6s each, until the limit lifted on its own.)
#
# Called by both of the exiting lane's successors, BEFORE either spends
# anything: whichever runs, the pause is written first and the ordinary gate
# then refuses. Keyed on LOOM_LANE_ID, which the epilogue's children inherit
# from the lane that spawned them, and on `<id>.rc`, which the epilogue writes
# before it chains — a limit is only ever read out of a FAILED session, the same
# rule `_limit_reset_at` states for waves.
_pause_on_lane_limit() { # → 0 a pause was written (do not spend), 1 otherwise
    local id="${LOOM_LANE_ID:-}" rc=""
    [ -n "$id" ] || return 1
    rc=$(cat "$LANES_DIR/$id.rc" 2>/dev/null || echo 0)
    case "$rc" in ''|0|*[!0-9]*) return 1 ;; esac
    _pause_on_limit "lane-$id" "lane-$id"
}

cmd_resume() {
    if [ -f "$USAGE_PAUSE" ]; then
        rm -f "$USAGE_PAUSE"; echo "resume: usage pause cleared"
    else
        echo "resume: no usage pause was set"
    fi
    : > "$WAVE_FAILS"
    echo "resume: consecutive-wave-failure count reset"
}

# --- subcommands ----------------------------------------------------------
# One-time setup, hooked to the verb actually used rather than to `start`.
# Guarded by a sentinel in the per-repo state dir, so it costs one file test on
# every tick after the first. On failure NO sentinel is written: a repo whose
# tracker is not reachable yet must not be recorded as bootstrapped, and the
# next tick simply retries. Never fatal — a wave must still run.
_bootstrap_once() {
    local sentinel="$LOOM_HOME/.bootstrapped" boot
    [ -n "${LOOM_SKIP_BOOTSTRAP:-}" ] && return 0
    [ -f "$sentinel" ] && return 0
    boot="$(dirname "$SELF_PATH")/bootstrap.sh"
    [ -x "$boot" ] || return 0
    echo "tick: first tick for this repo — running one-time bootstrap"
    if LOOM_REPO="$REPO_ROOT" LOOM_HOME="$LOOM_HOME" "$boot" all; then
        : > "$sentinel"
    else
        echo "tick: bootstrap incomplete — retrying next tick" >&2
    fi
    return 0
}

# cmd_tick's exit path, replacing lock_acquire's plain lock removal. Order is the
# whole point: the lock is released FIRST, because a follow-up tick fired while
# this process still held it would find the lock taken and skip — reproducing the
# exact bug (P1). Runs on every exit path, including the nonzero-wave one.
_tick_exit() {
    local rc=$?
    rm -rf "$LOCK_DIR"
    if [ -f "$PENDING_FILE" ]; then
        rm -f "$PENDING_FILE"
        _ev tick_replayed
        echo "tick: a lane finished during this wave — re-ticking once"
        ( nohup "$SELF_PATH" tick --from-lane --provider "${LOOM_PROVIDER:-}" \
            >>"$LOGS_DIR/self-trigger.log" 2>&1 </dev/null & )
    fi
    return $rc
}

# --- the loop switch and the wave gap ------------------------------------
_loop_stopped() { [ -f "$LOOP_STOPPED" ]; }

# Minutes since the last wave STARTED, read from the event log rather than a
# new file: the log already records it, and a second copy is a second thing to
# get out of sync. Returns 0 when a wave may start.
_wave_gap_ok() {
    local gap last now
    gap=$(cfg min_wave_gap_minutes 10)
    case "$gap" in ''|*[!0-9]*) gap=10 ;; esac
    [ "$gap" -gt 0 ] || return 0
    [ -f "$EVENTS" ] || return 0
    last=$(grep '"ev":"wave_start"' "$EVENTS" 2>/dev/null | tail -1 \
           | sed -n 's/.*"ts":\([0-9][0-9]*\).*/\1/p')
    [ -n "$last" ] || return 0
    now=$(date +%s)
    [ "$(( now - last ))" -ge "$(( gap * 60 ))" ]
}

# The watching half, run on EVERY firing before anything takes the lock. That
# ordering is the entire point of the merge: the old scheduler bailed at the
# lock, so during a wave — the exact window where a lane wedges — nothing
# stamped progress and nothing classified quiet. A separate 60s program had to
# exist to cover it. Watching first makes that program unnecessary.
# Prints the quiet state so the caller can reuse it without a second read.
# The caller captures this with `$(...)`, so the classification is the ONLY
# thing allowed on stdout. Everything else here — stale-lane warnings, the
# notifier's own chatter about whether a push went out — goes to stderr, or it
# is prepended to the state string and every downstream comparison silently
# stops matching. The quiescence gate then reads
# "notify: event 'build_halted' not in push list…\nhalted" instead of "halted",
# matches no case arm, and spends a wave on the ONE firing where the build just
# went halted — the firing that notifies is exactly the firing that must not.
_watch_pass() {
    { _stamp_progress; _notify_stale; } >&2
    local q; q=$(_quiet_check)
    _notify_quiet "$q" >&2
    printf '%s' "$q"
}

# P48: the verb roster injected into every wave is DERIVED from lane.sh's own
# usage line, never restated here. The hand-maintained list went five verbs
# stale (no merge, merge-failed, fix-ticket, reconcile, probe-result) and told
# merge lanes to finish with `close` — the build-1 merge-1 failure `cmd_merge`
# was written to end and `cmd_close` now hard-refuses. Segments split on " | "
# so the alternatives written INSIDE one segment (`pass|fail`, `--url <url> |
# -- <cmd...>`) cannot masquerade as verbs, and a first token that is not a
# bare lowercase word is dropped for the same reason.
_lane_verbs() { # _lane_verbs <lane.sh> → "scratch, note, …"; empty if unreadable
    [ -x "$1" ] || return 1
    "$1" 2>&1 >/dev/null \
      | sed -n 's/.*usage: lane\.sh //p' \
      | awk -F' \\| ' '{for (i=1;i<=NF;i++) {split($i,w," "); print w[1]}}' \
      | grep -E '^[a-z][a-z0-9-]*$' \
      | awk 'NR==1{printf "%s",$0;next}{printf ", %s",$0}'
}

cmd_tick() {
    # Three callers, three contracts (see SKILL "one program, one switch"):
    #   tick            a human typed it — always runs one wave, ignores both
    #                   the switch and the gap. An explicit command is not
    #                   automatic continuation.
    #   tick --auto     the timer fired — respects the switch AND the gap.
    #   tick --from-lane a lane finished — respects the switch, ignores the
    #                   gap. A handoff is work already in progress, and making
    #                   it wait would idle the build for no reason.
    #
    # Two stages (P75): _tick_gates is every refusal — mode, switch, gap, lock,
    # quiescence — and _launch_wave is every cost. The gates report through
    # tick_go rather than a return code so the call sits outside any condition
    # and `set -e` keeps its teeth inside them.
    # P86: before any gate, because the cheapest wave is the one never launched.
    # `cmd_snapshot` carries the halt for every read verb, but a wave calls that
    # from INSIDE a model session — so without this line an undeclared repo pays
    # a whole session to be told what one stat could have said. The heartbeat
    # fires on this every 60s and says the same thing each time, which is the
    # correct amount of noise for a build that cannot legally start.
    _require_tracker "$REPO_ROOT" tick >/dev/null
    _require_forge "$REPO_ROOT" tick >/dev/null
    _refuse_legacy_runtime_config
    local mode="manual" quiet="" tick_go=0 start_kick=0 provider="${LOOM_PROVIDER:-}"
    _tick_gates "$@"
    [ "$tick_go" -eq 1 ] || return 0
    _launch_wave
}

_tick_gates() { # reads cmd_tick's "$@"; sets, in its caller's scope: mode,
    # quiet, and tick_go — 1 when a wave should launch, 0 when this firing
    # already did everything it may (watch, note, event). Gate ORDER here is
    # load-bearing; each gate's comment names the build that paid for it.
    while [ $# -gt 0 ]; do case "$1" in
        --auto) mode="auto"; shift ;;
        --from-lane) mode="lane"; shift ;;
        --provider) provider="${2:-}"; shift 2 ;;
        *) die "tick: unknown argument '$1'" ;;
    esac; done
    [ -n "$provider" ] || die "tick: --provider <id> is required (scheduled and chained sessions never auto-detect)"
    export LOOM_PROVIDER="$provider"
    _assert_build_provider "$provider"
    # A lane hands off through its own epilogue ('tick --from-lane'), never by
    # calling a bare 'tick' itself: that takes the manual, always-runs
    # contract in the foreground, and a lane that self-invokes it takes the
    # tick lock and then waits on its own epilogue to release it. Refuse
    # before the lock is even reached. (P38: merge-68, build-3 2026-08-04.)
    if [ "$mode" = manual ] && [ -n "${LOOM_LANE_ID:-}" ]; then
        die "tick: refusing a bare 'tick' from inside lane '$LOOM_LANE_ID' — use 'tick --from-lane', which the lane's own epilogue already runs on exit."
    fi
    # The provider process tree and its deterministic host epilogue share the
    # lane id, so agent.sh marks only the provider child. A model following a
    # bad brief once invoked --from-lane itself; Codex then tried to preflight a wave
    # against the main repo outside that lane's writable sandbox and blocked
    # already-submitted JOR-202. Optional continuation is host plumbing, never
    # ticket work: make a provider-side attempt a successful no-op, while the
    # unmarked host epilogue still owns the real handoff. Provider-neutral by
    # construction — Claude lanes cross the same boundary.
    if [ "$mode" = lane ] && [ -n "${LOOM_LANE_ID:-}" ] \
       && [ "${LOOM_PROVIDER_SESSION:-}" = 1 ]; then
        echo "tick: host epilogue already owns --from-lane for '$LOOM_LANE_ID' — no action needed; finish the ticket normally"
        return 0
    fi
    [ "$mode" != manual ] || _raise_viewer
    # D-TICK-20: before the environment is cleared, because the exiting lane's
    # id is the only way to find its transcript — and before `_usage_gate`
    # below, which is what actually refuses. A handoff from a lane the account's
    # usage limit killed is not work in progress; it is the front of a respawn
    # loop that nothing else paces.
    if [ "$mode" = lane ]; then _pause_on_lane_limit || : ; fi
    # A tick fired from a lane's epilogue inherits that lane's environment, but
    # the wave it launches is the scheduler, not a lane — and must not have its
    # own spawns read as chained handoffs.
    unset LOOM_LANE_ID
    # WATCH FIRST — before the lock, before every gate below. Nothing here
    # spends, and it must happen even on the firings that do nothing else.
    quiet=$(_watch_pass)
    if [ "$mode" != manual ] && _loop_stopped; then
        echo "tick: the loop is stopped (\`/loom start\` resumes it) — watched, no wave"
        _ev tick_skipped reason loop_stopped
        return 0
    fi
    # Before every gate below, because the firing that gets skipped is exactly
    # the firing after which nothing else may fire. Cheap: one file test once
    # armed.
    _ensure_armed
    # Queue draining is work already scheduled, not a new paid wave. It must
    # happen before the auto-wave gap so an interactive Codex tick can hand
    # workers to the very next durable heartbeat without waiting 10–20m.
    if ! _codex_host_is_ephemeral; then
        _drain_lane_cleanups \
          || die "tick: one or more queued lane cleanups failed at the durable host boundary"
        _drain_lane_launches \
          || die "tick: one or more queued lanes failed at the durable host boundary"
    fi
    [ ! -f "$START_KICK_FILE" ] || start_kick=1
    if [ "$mode" = auto ] && [ "$start_kick" -eq 0 ] && ! _wave_gap_ok; then
        echo "tick: last wave was under $(cfg min_wave_gap_minutes 10)m ago — watched, no wave"
        _ev tick_skipped reason wave_gap
        return 0
    fi
    if ! lock_acquire; then
        # The pending file is a FLAG, not a counter: every tick after the first
        # during one wave sets something already set, and only one replay
        # follows however many arrive (155 lock_held ticks produced 79 replays
        # in a day). Record which tick raised the flag so the ticker can show
        # that one and stay quiet for the rest (P42). The event itself is still
        # written every time — `retro` counts them.
        local first=0; [ -f "$PENDING_FILE" ] || first=1
        : > "$PENDING_FILE"
        _ev tick_skipped reason lock_held first "$first"
        echo "tick: wave already running — noted, the running wave will re-tick on exit"
        exit 0
    fi
    trap _tick_exit EXIT
    _usage_gate || exit 0
    _bootstrap_once
    _prune_scratch
    cmd_sweep || true
    # No separate watcher to arm any more: this tick already watched, above,
    # before it took the lock.
    # Quiescence gate: classify before spending a wave. halted → nothing is
    # schedulable, skip (a heartbeat on a halted build otherwise burns a
    # model session every 15 min just to be told so). stalled with
    # stall_action=notify_only → ping the human and wait (testbed fizzle
    # protocol); default resume → the wave IS the recovery. complete → let
    # the wave run: it posts the completion report and tears the agent down.
    #
    # This is an ALLOWLIST, and it must stay one. It used to name only the two
    # states that block, so every state it did not name fell through into a
    # wave — including the one meaning "the tracker call FAILED, we have no idea
    # what the board says". On a laptop that sleeps, launchd runs the missed
    # firing the instant the machine darkwakes, before WiFi is back: glab fails,
    # and a full model session launches on a build whose every ticket is
    # blocked. "We could not read the board" is the state that most obviously
    # must not spend. (Paid for: build-3 2026-08-06 — four overnight waves, one
    # of them 84 minutes, each within a minute of a darkwake, on a board holding
    # one blocked ticket.)
    #
    # `unreadable` is gated on `--auto` alone, because the timer is the only
    # caller that spends unattended and forever. A human's `tick` and a lane's
    # handoff are both bounded and both have someone or something behind them;
    # refusing those on a transient read failure would strand a chained lane for
    # a whole heartbeat interval. The timer retries in 60s regardless, so a
    # skipped automatic firing costs nothing but the wave it did not buy.
    # `unknown` — no build label yet — is the pre-plan state and still runs: it
    # is how a repo that has never planned gets its first wave.
    case "$quiet" in
        halted) echo "tick: every open ticket is blocked — nothing to schedule, no wave"
                _ev tick_skipped reason halted
                return 0 ;;
        unreadable) if [ "$mode" = auto ]; then
                     echo "tick: could not read the board (glab, auth or network) — no wave until it reads clean"
                     _ev tick_skipped reason unreadable
                     return 0
                 fi ;;
        stalled) if [ "$(cfg stall_action resume)" = "notify_only" ]; then
                     echo "tick: stalled and stall_action=notify_only — notified, waiting for the human"
                     _ev tick_skipped reason stalled_notify_only
                     return 0
                 fi ;;
        active|complete|unknown) ;;
        *)      echo "tick: unrecognised quiescence state '$quiet' — no wave"
                _ev tick_skipped reason unclassified state "$quiet"
                return 0 ;;
    esac
    # Consume only at the cost boundary. A start kick that met a lock, a usage
    # pause, or a quiet-board refusal must survive for the next heartbeat.
    [ "$start_kick" -eq 0 ] || rm -f "$START_KICK_FILE"
    tick_go=1
}

_prepare_wave_plan() { # <scratch> — resolve every spawn cwd before sandboxing the wave
    local scratch="$1" snapshot="$1/snapshot.json" plan="$1/plan.json" raw="$1/plan.raw.json"
    local worktree_sh="${SELF_PATH%/*}/worktree.sh" lane ticket base branch cwd tmp lane_type has_open_mr
    [ -x "$worktree_sh" ] || die "wave: deterministic worktree helper missing: $worktree_sh"
    "$SELF_PATH" snapshot --brief > "$snapshot" \
      || die "wave: could not capture the tracker snapshot before provider invocation"
    "$SELF_PATH" plan "$snapshot" > "$raw" \
      || die "wave: could not derive the deterministic schedule before provider invocation"
    if [ -z "${LOOM_SKIP_PROVIDER_CHECK:-}" ]; then
      local planned_provider
      planned_provider=$(jq -r '.build.provider // empty' "$raw")
      [ "$planned_provider" = "$provider" ] \
        || die "wave: provider changed while deriving the schedule (transport '$provider', snapshot '${planned_provider:-none}') — refusing before provider invocation"
    fi
    cp "$raw" "$plan"
    jq -r --slurpfile snap "$snapshot" '
      .actions[] | select(.spawn != null and .spawn.cwd == null)
      | ((.ticket // "") | tostring) as $ticket
      | ((.spawn.prepare.argv // []) as $a
         | ($a | index("--base")) as $i
         | if $i == null then "" else ($a[$i + 1] // "") end) as $base
      | ([ $snap[0].tickets[]?
           | select((.id | tostring) == $ticket)
           | .related_merge_requests[]?
           | select(.state == "open")
           | .branch ] | first // "") as $branch
      | [.lane, $ticket, $base, $branch, (.spawn.type // "")] | join("\u001c")' "$raw" \
      | while IFS="$(printf '\034')" read -r lane ticket base branch lane_type; do
        [ -n "$lane" ] || continue
        # plan.jq uses <base> when the repo has no explicit `base:` key. It is
        # a host-side instruction to apply Loom's shared base rule, not a Git
        # ref. Leaving it literal makes worktree.sh look for origin/<base> and
        # aborts the entire wave before the provider can spawn any lane.
        [ "$base" = '<base>' ] && base=$(_detect_base "$REPO_ROOT" "$CONFIG")
        if [ -n "$base" ]; then
          if [ -n "$ticket" ]; then
            cwd=$("$worktree_sh" prepare --repo "$REPO_ROOT" --ticket "$ticket" --base "$base") \
              || exit 1
          else
            cwd=$("$worktree_sh" prepare --repo "$REPO_ROOT" --key "$lane" --base "$base") \
              || exit 1
          fi
        else
          [ -n "$ticket" ] \
            || die "wave: spawn '$lane' needs an existing ticket worktree but has no ticket id"
          has_open_mr=0
          [ -z "$branch" ] || has_open_mr=1
          if [ -z "$branch" ]; then
            [ "$lane_type" = implementation ] \
              || die "wave: spawn '$lane' needs an existing worktree but its ticket has no open MR branch"
            # A stranded implementation often has no MR because it was killed
            # before submit. worktree.sh created it on the deterministic local
            # branch; requiring forge state here loses exactly the dirty work
            # this recovery action says to resume.
            branch="loom-$ticket"
          fi
          cwd=$(_worktree_for_branch "$REPO_ROOT" "$branch")
          if [ -n "$cwd" ]; then
            cwd=$("$worktree_sh" prepare --repo "$REPO_ROOT" --ticket "$ticket" --reuse "$cwd") \
              || exit 1
          else
            # An implementation with no MR may contain uncommitted-only work;
            # recreating loom-<ticket> from a branch tip would silently lose
            # it, so that shape still fails closed. Rework WITH an open MR is
            # different: its reviewed branch is durable forge state, and a
            # swept local worktree is safe to reconstruct exactly like a gate
            # or merge checkout.
            if [ "$lane_type" = implementation ] && [ "$has_open_mr" -eq 0 ]; then
              die "wave: stranded implementation '$lane' has no surviving worktree on branch '$branch'"
            fi
            base=$(_detect_base "$REPO_ROOT")
            cwd=$("$worktree_sh" prepare --repo "$REPO_ROOT" --ticket "$ticket" --branch "$branch" --base "$base") \
              || exit 1
          fi
        fi
        tmp="$plan.tmp.$$"
        jq --arg lane "$lane" --arg cwd "$cwd" '
          (.actions[] | select(.lane == $lane) | .spawn) |=
            ((. + {cwd:$cwd, cwd_from:"the linked worktree resolved by tick.sh before this wave"}) | del(.prepare))' \
          "$plan" > "$tmp" && mv "$tmp" "$plan"
      done \
      || die "wave: could not resolve every spawn worktree before provider invocation"
    printf '%s\n' "$plan"
}

_launch_wave() { # the spend half of cmd_tick: prompt assembly through the
    # retry policy. Runs only after every gate in _tick_gates has passed, with
    # the tick lock held and _tick_exit trapped.
    LOOM_SCRATCH=$(_new_scratch wave); export LOOM_SCRATCH
    local wave_tier; wave_tier="$(cfg wave_tier medium)"
    case "$wave_tier" in medium|high) ;; *) die "wave_tier must be medium or high, got '$wave_tier'";; esac
    if [ -z "${LOOM_WAVE_CMD:-}" ]; then
      [ -x "$AGENT_SH" ] || die "wave: provider runtime missing or not executable: $AGENT_SH"
      if [ -z "${LOOM_SKIP_AGENT_PREFLIGHT:-}" ]; then
        "$AGENT_SH" preflight --provider "$provider" --job wave --tier "$wave_tier" --cwd "$REPO_ROOT" >/dev/null
      fi
    fi
    local lane_path verb_txt wave_plan="" first_action
    lane_path="$(dirname "$SELF_PATH")/lane.sh"
    verb_txt="$(_lane_verbs "$lane_path" 2>/dev/null || true)"
    if [ -n "$verb_txt" ]; then verb_txt="verbs: $verb_txt; "
    else verb_txt=""; fi
    # Production sessions receive the one snapshot-derived plan that this wave
    # will execute. Worktree creation happens here, outside every provider
    # sandbox; the wave gets only absolute prepared cwd values. LOOM_WAVE_CMD
    # remains a deterministic test seam and keeps its self-contained prompt
    # unless a test explicitly opts into preparation.
    if [ -z "${LOOM_WAVE_CMD:-}" ] || [ -n "${LOOM_PREPARE_PLAN_WITH_WAVE_CMD:-}" ]; then
      wave_plan=$(_prepare_wave_plan "$LOOM_SCRATCH")
    fi
    if [ -n "$wave_plan" ]; then
      first_action="read $wave_plan — it is the immutable schedule derived from this wave's tracker snapshot. Run its .actions[] in order; every new-worktree spawn already carries .spawn.cwd and no provider session creates a worktree."
    else
      first_action="run \"$SELF_PATH\" snapshot --brief | \"$SELF_PATH\" plan — the read step and the schedule."
    fi
    # The wave prompt carries the ground truth the spawner already has. A fresh
    # headless session that must rediscover repo/state/config by shelling
    # around can get its exploratory commands denied and misread that as
    # "repo was never bootstrapped" (build-1 2026-08-02: the recovery wave
    # concluded exactly that, asked two questions to nobody, and exited having
    # harvested nothing — stalling the build).
    LOOM_WAVE_PROMPT="/loom tick

Wave context from tick.sh — trust it over rediscovery:
- repo root: $REPO_ROOT (this repo IS loom-managed; bootstrap already ran)
- tick.sh: $SELF_PATH
- state dir: $LOOM_HOME
- FIRST action: $first_action The plan's .actions[] are already decided: run them in order (each carries via + argv, or everything a spawn needs but its brief). .residue[] is what needs prose from you; .deferred[] is what a cap or a hold cut. Absence of .loom.yml is normal (config resolves from derived/global layers).
- Every spawn action carries a Loom tier. Spawn with --provider $provider --job <kind> --tier <medium|high>; never construct provider-native flags.
- Lanes make EVERY tracker write through the verb script $lane_path (${verb_txt}long bodies via stdin or --file; run it bare for usage).
- Long lane briefs travel as FILES: write the brief, then spawn-lane <id> --provider $provider --job <kind> --tier <tier> --brief <file> --cwd <wt>. spawn-lane stages it outside the worktree and agent.sh invokes the selected provider. A brief that tells the session to invoke a skill by slash command is refused; inline the work instead. Never hand-roll tracker mutations in a lane prompt.
- You are headless: no human will ever read a question. If truly blocked, post a comment on the Build issue and exit. A wave that ends by asking questions is a failed wave."
    export LOOM_WAVE_PROMPT
    local wave_brief="$LOOM_SCRATCH/wave.md"
    printf '%s\n' "$LOOM_WAVE_PROMPT" > "$wave_brief"
    # Seconds alone collided when two test/manual ticks began in one second:
    # the later limit parser inherited reset_at=1 from the earlier log and
    # treated an expired timestamp as a fresh pause (full-suite run 2026-08-15).
    # The process id makes each session's diagnostic artifact unambiguous.
    local stem="wave-$(date +%Y%m%d-%H%M%S)-$$" rc=0
    _run_wave "$stem" "$provider" "$wave_tier" "$wave_brief" || rc=$?
    if [ "$rc" -eq 0 ]; then : > "$WAVE_FAILS"; return 0; fi

    # A usage limit is not a crash: retrying it immediately spends a session to
    # be told the same thing, which is exactly what the observed run did.
    _pause_on_limit "$stem" first && return 0

    # P15: three wave logs in build 2 were exactly `Execution error`, 15 bytes,
    # and the wave simply set exit 1 and waited — a crashed LANE at least still
    # fired the next tick. One retry after a backoff covers the transient case;
    # what survives that is escalated to a human rather than silently repeated.
    echo "tick: wave failed (see $LOGS_DIR/$stem.err.log) — retrying once in ${RETRY_BACKOFF}s"
    sleep "$RETRY_BACKOFF"
    rc=0; _run_wave "$stem-retry" "$provider" "$wave_tier" "$wave_brief" || rc=$?
    if [ "$rc" -eq 0 ]; then : > "$WAVE_FAILS"; return 0; fi

    # The retry needs the SAME limit check as the first attempt — the same
    # call, not a copy of it.
    _pause_on_limit "$stem-retry" retry && return 0

    local fails; fails=$(( $(cat "$WAVE_FAILS" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$fails" > "$WAVE_FAILS"
    echo "tick: wave failed twice ($fails consecutive) — see $LOGS_DIR/$stem-retry.err.log"
    # A CONSTANT, deliberately not `crash_cap`. That key means "implementer
    # crashes before a ticket is blocked" everywhere else — in SKILL.md, in the
    # config reference, and in the seeded global config. Borrowing it here gave
    # one key two mechanisms, so lowering it to stop a flapping ticket would
    # also make the whole build halt sooner. No repo needs to tune how many
    # dead waves in a row are worth a notification (P21 rule 1).
    if [ "$fails" -ge 3 ]; then
        cmd_notify build_halted "Build halted — waves keep crashing" \
            "$fails consecutive scheduling waves failed. Last error: $(head -c 300 "$LOGS_DIR/$stem-retry.err.log" 2>/dev/null)" \
            >/dev/null 2>&1 || :
    fi
    exit 1
}

# stdout and stderr go to SEPARATE files. Merging them is why build 2's crashed
# waves left 15 bytes and no diagnosis: with a stream on stdout, an error on
# stderr is the only thing that explains an empty transcript (P15).
_run_wave() { # _run_wave <stem> <provider> <tier> <brief> → exit code
    local stem="$1" provider="$2" tier="$3" brief="$4" rc=0 t0 retry=0
    t0=$(_now)
    case "$stem" in *-retry) retry=1 ;; esac
    _ev wave_start stem "$stem" retry "$retry" provider "$provider" tier "$tier"
    echo "tick: running wave (log: $LOGS_DIR/$stem.log)"
    if [ -n "${LOOM_WAVE_CMD:-}" ]; then
        ( cd "$REPO_ROOT" && eval "$LOOM_WAVE_CMD" ) >>"$LOGS_DIR/$stem.log" 2>"$LOGS_DIR/$stem.err.log" || rc=$?
    else
        LOOM_AGENT_NATIVE_LOG="$LOGS_DIR/$stem.native.jsonl" \
          "$AGENT_SH" run --provider "$provider" --job wave --tier "$tier" --cwd "$REPO_ROOT" --brief "$brief" \
          >"$LOGS_DIR/$stem.jsonl" 2>"$LOGS_DIR/$stem.err.log" || rc=$?
        _render_stream "$LOGS_DIR/$stem.jsonl" "$LOGS_DIR/$stem.log"
    fi
    # An actual scheduler process is a durable host once the inner provider
    # session is gone. A human-typed tick beneath interactive Codex is not:
    # Codex owns that outer process scope too and reaps its descendants at turn
    # end. Leave those requests for the next launchd/cron heartbeat instead.
    if ! _codex_host_is_ephemeral; then
        if ! _drain_lane_cleanups; then
            [ "$rc" -ne 0 ] || rc=26
        elif ! _drain_lane_launches; then
            [ "$rc" -ne 0 ] || rc=26
        fi
    elif find "$LANE_LAUNCH_DIR" -mindepth 1 -maxdepth 1 -type d -name 'request-*' 2>/dev/null | grep -q .; then
        echo "tick: Codex-hosted wave left lane launches queued for the durable scheduler"
    fi
    _ev wave_end stem "$stem" rc "$rc" secs "$(( $(_now) - t0 ))" provider "$provider" tier "$tier"
    return $rc
}

_queue_lane_launch() { # caller scope: id/provider/job/tier/abs/brief/pregate/locks
    local base request n=0 existing
    # Do not let two commands in one provider session enqueue the same lane id.
    # There is no pid yet for the ordinary live-lane guard to see.
    for existing in "$LANE_LAUNCH_DIR"/request-* "$LANE_LAUNCH_DIR"/launching-*; do
        [ -d "$existing" ] || continue
        [ "$(cat "$existing/id" 2>/dev/null || true)" != "$id" ] \
          || die "spawn-lane: lane '$id' already has a deferred host launch pending"
    done
    base="$LANE_LAUNCH_DIR/request-$(date +%Y%m%d-%H%M%S)-$$-$id"
    request="$base.tmp"
    while ! mkdir "$request" 2>/dev/null; do
        n=$((n+1)); request="$base-$n.tmp"
        [ "$n" -le 200 ] || die "spawn-lane: cannot allocate a deferred launch request"
    done
    printf '%s\n' "$id" > "$request/id"
    printf '%s\n' "$provider" > "$request/provider"
    printf '%s\n' "$job" > "$request/job"
    printf '%s\n' "$agent_tier" > "$request/tier"
    printf '%s\n' "$abs" > "$request/cwd"
    printf '%s\n' "$pregate" > "$request/pregate"
    printf '%s\n' "$merge_lock" > "$request/merge-lock"
    printf '%s\n' "$on_done" > "$request/on-done"
    cp "$brief" "$request/brief.md" \
      || { rm -rf "$request"; die "spawn-lane: cannot stage deferred brief '$brief'"; }
    local ready="${request%.tmp}"
    mv "$request" "$ready"
    _ev lane_queued id "$id" type "$(_lane_type "$id")" job "$job" \
        provider "$provider" tier "$agent_tier" cwd "$abs"
    echo "lane $id: queued for host launch after the provider session exits"
}

_drain_lane_launches() {
    local request name launching id provider job tier cwd pregate merge_lock on_done launch_rc rc=0
    for request in "$LANE_LAUNCH_DIR"/request-*; do
        [ -d "$request" ] || continue
        name="${request##*/request-}"
        launching="$LANE_LAUNCH_DIR/launching-$name"
        # Another host wrapper may be draining concurrently. Atomic rename
        # gives exactly one of them ownership of this request.
        mv "$request" "$launching" 2>/dev/null || continue
        id=$(cat "$launching/id" 2>/dev/null || true)
        provider=$(cat "$launching/provider" 2>/dev/null || true)
        job=$(cat "$launching/job" 2>/dev/null || true)
        tier=$(cat "$launching/tier" 2>/dev/null || true)
        cwd=$(cat "$launching/cwd" 2>/dev/null || true)
        pregate=$(cat "$launching/pregate" 2>/dev/null || true)
        merge_lock=$(cat "$launching/merge-lock" 2>/dev/null || true)
        on_done=$(cat "$launching/on-done" 2>/dev/null || true)
        local args=("$id" --provider "$provider" --job "$job" --tier "$tier" \
                    --brief "$launching/brief.md" --cwd "$cwd")
        [ -z "$pregate" ] || args+=(--pregate "$pregate")
        [ "$merge_lock" = 1 ] && args+=(--merge-lock)
        [ "$on_done" = 0 ] && args+=(--no-tick)
        launch_rc=0
        LOOM_DEFER_LANE_LAUNCH= LOOM_AUX_DRAIN_ID="$id" \
          "$SELF_PATH" spawn-lane "${args[@]}" || launch_rc=$?
        if [ "$launch_rc" -eq 0 ]; then
            rm -rf "$launching"
        elif [ "$launch_rc" -eq 75 ]; then
            # Capacity is temporary, not a broken request. Put it back under
            # its original ready name for the next ordinary heartbeat.
            mv "$launching" "$request" 2>/dev/null || true
        else
            mv "$launching" "$LANE_LAUNCH_DIR/failed-$name" 2>/dev/null || true
            _ev lane_launch_failed id "${id:-unknown}" provider "${provider:-unknown}" job "${job:-unknown}"
            echo "tick: deferred host launch failed for ${id:-unknown}" >&2
            rc=1
        fi
    done
    return "$rc"
}

_queue_lane_cleanup() { # <lane-id> kill|clear — provider → durable host
    local id="$1" action="$2" base request n=0 existing
    for existing in "$LANE_CLEANUP_DIR"/request-* "$LANE_CLEANUP_DIR"/running-*; do
        [ -d "$existing" ] || continue
        if [ "$(cat "$existing/id" 2>/dev/null || true)" = "$id" ]; then
            # A later kill is stronger than an earlier harvest request. Keep
            # one queue entry, but never let deduplication downgrade a live
            # process to metadata-only cleanup.
            [ "$action" != kill ] || printf '%s\n' kill > "$existing/action"
            echo "lane $id: durable host cleanup already queued"
            return 0
        fi
    done
    base="$LANE_CLEANUP_DIR/request-$(date +%Y%m%d-%H%M%S)-$$-$id"
    request="$base.tmp"
    while ! mkdir "$request" 2>/dev/null; do
        n=$((n+1)); request="$base-$n.tmp"
    done
    printf '%s\n' "$id" > "$request/id"
    printf '%s\n' "$action" > "$request/action"
    cat "$LANES_DIR/$id.pid" > "$request/pid" 2>/dev/null || : > "$request/pid"
    mv "$request" "${request%.tmp}"
    _ev lane_cleanup_queued id "$id" action "$action"
    echo "lane $id: $action queued for the durable host"
}

_drain_lane_cleanups() {
    local request name running id action expected current cleanup_rc rc=0
    for request in "$LANE_CLEANUP_DIR"/request-*; do
        [ -d "$request" ] || continue
        name="${request##*/request-}"
        running="$LANE_CLEANUP_DIR/running-$name"
        mv "$request" "$running" 2>/dev/null || continue
        id=$(cat "$running/id" 2>/dev/null || true)
        action=$(cat "$running/action" 2>/dev/null || true)
        expected=$(cat "$running/pid" 2>/dev/null || true)
        current=$(cat "$LANES_DIR/$id.pid" 2>/dev/null || true)
        # A delayed request must never kill a newer reuse of the same lane id.
        if [ -n "$expected" ] && [ -n "$current" ] && [ "$current" != "$expected" ]; then
            rm -rf "$running"
            _ev lane_cleanup_discarded id "${id:-unknown}" reason pid_changed
            continue
        fi
        cleanup_rc=0
        case "$action" in
            kill)  LOOM_HOST_LANE_CLEANUP=1 cmd_kill_lane "$id" >/dev/null || cleanup_rc=$? ;;
            clear) LOOM_HOST_LANE_CLEANUP=1 cmd_clear_lane "$id" >/dev/null || cleanup_rc=$? ;;
            *) cleanup_rc=2 ;;
        esac
        if [ "$cleanup_rc" -eq 0 ]; then
            rm -rf "$running"
        else
            mv "$running" "$request" 2>/dev/null || true
            _ev lane_cleanup_failed id "${id:-unknown}" action "${action:-unknown}"
            echo "tick: durable host cleanup failed for ${id:-unknown}" >&2
            rc=1
        fi
    done
    return "$rc"
}

cmd_drain_lane_cleanups() {
    [ -z "${LOOM_DEFER_LANE_LAUNCH:-}" ] \
      || die "drain-lane-cleanups: provider sessions cannot drain their own process scope"
    ! _codex_host_is_ephemeral \
      || die "drain-lane-cleanups: interactive Codex is not a durable worker host; the scheduler heartbeat will drain this queue"
    _drain_lane_cleanups
}

cmd_drain_lane_launches() {
    [ -z "${LOOM_DEFER_LANE_LAUNCH:-}" ] \
      || die "drain-lane-launches: provider sessions cannot drain their own process scope"
    ! _codex_host_is_ephemeral \
      || die "drain-lane-launches: interactive Codex is not a durable worker host; the scheduler heartbeat will drain this queue"
    _drain_lane_launches
}

_codex_host_is_ephemeral() {
    [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SESSION_ID:-}" ] || [ -n "${CODEX_CI:-}" ]
}

# Flag parsing for spawn-lane, accepting the flags before OR after the id
# (order-tolerant). Sets, in the caller's scope: id, on_done, cwd, merge_lock,
# pregate, brief — and _spawn_shift, the count of arguments consumed, which
# the caller shifts away to stand on the lane command. A malformed flag dies
# here; the missing-id and missing-command guards are the caller's, because
# only it sees the remainder.
_spawn_parse_flags() {
    _spawn_shift=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --on-done-tick) on_done=1; shift; _spawn_shift=$((_spawn_shift+1)) ;;
            --no-tick) on_done=0; shift; _spawn_shift=$((_spawn_shift+1)) ;;
            --pregate) shift; [ $# -gt 0 ] || die "spawn-lane: --pregate needs a tier"
                       pregate="$1"; shift; _spawn_shift=$((_spawn_shift+2)) ;;
            --merge-lock) merge_lock=1; shift; _spawn_shift=$((_spawn_shift+1)) ;;
            --cwd) shift; [ $# -gt 0 ] || die "spawn-lane: --cwd needs a directory"
                   cwd="$1"; shift; _spawn_shift=$((_spawn_shift+2)) ;;
            --brief) shift; [ $# -gt 0 ] || die "spawn-lane: --brief needs a file"
                     brief="$1"; shift; _spawn_shift=$((_spawn_shift+2)) ;;
            --provider) shift; [ $# -gt 0 ] || die "spawn-lane: --provider needs an id"
                     provider="$1"; shift; _spawn_shift=$((_spawn_shift+2)) ;;
            --job) shift; [ $# -gt 0 ] || die "spawn-lane: --job needs a kind"
                     job="$1"; shift; _spawn_shift=$((_spawn_shift+2)) ;;
            --tier) shift; [ $# -gt 0 ] || die "spawn-lane: --tier needs medium or high"
                     agent_tier="$1"; shift; _spawn_shift=$((_spawn_shift+2)) ;;
            --) shift; _spawn_shift=$((_spawn_shift+1)); break ;;
            --*) die "spawn-lane: unknown flag '$1'" ;;
            *) if [ -z "$id" ]; then id="$1"; shift; _spawn_shift=$((_spawn_shift+1)); else break; fi ;;
        esac
    done
    return 0
}

# P28: long briefs travel as FILES, never inline prompt arguments — the
# CLI/permission boundary mangles or denies them (8 dead impl-1 spawns in
# four minutes, build-1 2026-08-01, before a wave hand-invented the brief
# file). --brief copies the file into the lane's worktree and swaps the
# literal `@brief` placeholder after -p for a one-line pointer prompt.
# Reads, from the caller's scope: brief, id, abs, and the lane command as
# "$@"; leaves the command — rewritten to the pointer prompt when a brief
# travels, untouched otherwise — in _SPAWN_ARGS for the caller to `set --`
# back. Every die in here fires before anything destructive runs.
_spawn_stage_brief() {
    _SPAWN_ARGS=("$@")
    if [ -z "$brief" ]; then
        # D-TICK-18: the mirror of the refusal at the bottom of this function.
        # A `-p @brief` with no `--brief` behind it passed every guard, and the
        # lane was handed the literal string `@brief` as its whole prompt — an
        # @-mention of a file that does not exist. It runs its pregate to
        # completion first, so the discovery costs a full gate: boostlingo
        # build-4 gate-98-r3 printed `gate[ui]: PASS`, then asked three times
        # which of six brief-shaped files it was meant to read and exited rc 0
        # with no verdict. A lane that asks a question is a dead lane (P68).
        local _a=""
        for _a in "$@"; do
            [ "$_a" = "@brief" ] || continue
            die "spawn-lane: the command carries '@brief' but no --brief <file> was given —
  the placeholder has nothing behind it, so the lane would be launched with the
  literal string '@brief' as its entire prompt. Pass --brief <file>, or drop the
  placeholder and give the command a real prompt."
        done
        return 0
    fi
    local _brf=() _b=""
    [ -f "$brief" ] && [ -s "$brief" ] || die "spawn-lane: --brief '$brief' is not a readable, non-empty file"
    # P68: a brief may never instruct a skill invocation. A headless session
    # has no slash commands, so "run /implement <n>" spawns a lane that can
    # only fail — impl-2 died twice that way (ai-workout build-1) before a
    # wave inlined the steps. The check runs on the SOURCE brief, before the
    # rules below are appended.
    local _slash=""
    _slash=$(grep -oE '(^|[^A-Za-z0-9_./-])/(implement|loom|to-tickets|code-review|grilling|lavish|prototype|qa|retro|optimize|prop|fix)([^A-Za-z0-9-]|$)' "$brief" \
             | grep -oE '/[a-z-]+' | head -1 || true)
    [ -z "$_slash" ] || die "spawn-lane: brief '$brief' tells the session to invoke $_slash —
  a headless session has no slash commands (P68). Inline the work that skill
  would do into the brief instead of naming it."
    # P82, the other half: the SOURCE brief must not live in a working tree
    # either. `spawn-lane`'s own copy is what made every worktree unsweepable,
    # but a wave writing its source brief into the worktree does the same
    # damage by hand — build-5 held worktrees on `.gate-brief-114.md` and
    # `.impl-brief-128.md`, neither of which this function can produce. The
    # convention already existed (`lane.sh scratch`); nothing enforced it.
    local _bdir="" _bpath=""
    _bdir=$(cd "$(dirname "$brief")" 2>/dev/null && pwd -P) \
        || die "spawn-lane: cannot resolve the directory of --brief '$brief'"
    _bpath="$_bdir/$(basename "$brief")"
    local _tree=""
    for _tree in "$REPO_ROOT" "$abs"; do
        [ -n "$_tree" ] || continue
        local _t=""; _t=$(cd "$_tree" 2>/dev/null && pwd -P) || continue
        case "$_bpath" in
            "$_t"/*) die "spawn-lane: --brief '$brief' is inside the working tree $_t —
  a brief there is untracked work to every git-facing guard, and sweep will keep
  that worktree forever (P82). Write it where \`lane.sh scratch\` points instead." ;;
        esac
    done
    cp "$brief" "$BRIEFS_DIR/$id.md" || die "spawn-lane: cannot copy brief into $BRIEFS_DIR"
    # P68: every lane kind — impl, gate, merge, probe — gets the headless
    # survival rules the probe brief alone used to carry. They are facts
    # about the execution environment, not about probing, and a wave asked
    # to remember them forgets them: three dead or wedged spawns in
    # ai-workout build-1, one of them ending "the harness will notify me
    # automatically" over a background build that could never wake it.
    cat >> "$BRIEFS_DIR/$id.md" <<BRIEFEOF

## Headless execution rules (appended by spawn-lane — they bind every lane)
- No human will read a question and nothing will ever wake you: every step blocks. "I backgrounded it and will be notified" never returns, and ScheduleWakeup is denied on your command line — there is no main loop to resume you, so scheduling a wakeup ends the session with the job unfinished.
- Finite commands such as builds, tests and gates start once in the foreground. If the shell tool returns a running-session identifier before the command exits, poll that same running session until it completes. Do not rerun the command: a shell response window ending is not a command failure. Do not add a \`timeout\`, alarm, or other synthetic deadline; only the command's own timeout counts. Never background a finite command and poll a status file in a later call: Codex can reap descendants detached from the tool session, so the status file may never be written.
- Poll, never await: start a long-running stack as a background shell, then wait on it with one call — $(dirname "$SELF_PATH")/lane.sh wait-ready --timeout <secs> (--url <url> | -- <cmd...>) — never a hand-rolled curl+sleep turn loop. A timeout is a failure to report, not a reason to wait longer.
- Kill every background shell you started before you exit (KillShell). Ephemeral files go in the directory $(dirname "$SELF_PATH")/lane.sh scratch prints, and are never cleaned up by hand.
- There are no slash commands in a headless session: never invoke or expect a skill by name. Do that work inline.
- The host epilogue owns \`tick --from-lane\`; never invoke it from the provider session. A refused optional successor handoff is not a blocked ticket — finish after the ticket's required submit/verdict/merge write and let the epilogue or heartbeat continue.
- Genuinely blocked? This is one terminal sequence, never two alternatives: first pipe the evidence to $(dirname "$SELF_PATH")/lane.sh blocked-report <iid> --category <slug>, then immediately run $(dirname "$SELF_PATH")/lane.sh transition <iid> blocked. Do not exit after only the report or only the transition. A lane that ends by asking a question is a dead lane.
BRIEFEOF
    # P31: the implementer's half of the mandatory adversarial test, stated
    # where the implementer reads it rather than trusted to a wave. Two
    # builds paid for these two lines: seat-reservations build-1 (4 of 5
    # gate FAILs, converging over three rounds on "the test must actually
    # run") and ai-workout build-1 (4 of 7, every test committed and
    # running, none asserting its bullet — omission and partial coverage a
    # mapping makes visible before push). #31 there also spent a full round
    # being told its bullet was unsatisfiable, which is the one case more
    # rounds cannot help.
    if [ "$(_lane_type "$id")" = impl ]; then
        cat >> "$BRIEFS_DIR/$id.md" <<BRIEFEOF
- Do not run the repository's full configured tier gate from an implementation provider session. Run focused checks for the files you changed, then submit. The launchd-supervised gate lane runs the full configured gate as its pregate against the pushed HEAD; that host-owned result is authoritative even if ticket prose says to run the same full gate before push. This avoids long UI gates losing their provider shell handle and avoids two worktrees sharing one test server.
- Answer every bullet under "## Mandatory adversarial tests" by name in the MR description: bullet → the test function that asserts it, committed, named in your tier's command list in .loom.yml, and shown to fail when its subject is broken. A bullet with no test name beside it is unfinished work, not a lane note.
- A bullet you can PROVE unsatisfiable ends the lane blocked with that proof ($(dirname "$SELF_PATH")/lane.sh transition <iid> blocked), never in review with a note explaining it.
BRIEFEOF
    fi
    if [ "$(_lane_type "$id")" = gate ]; then
        local _verdict_ticket="${id#gate-}" _verdict_head=""
        _verdict_ticket="${_verdict_ticket%-r[0-9]*}"
        _verdict_head=$(git -C "$abs" rev-parse HEAD 2>/dev/null || echo HEAD)
        cat >> "$BRIEFS_DIR/$id.md" <<BRIEFEOF
- A prose verdict is not a completed gate. Before exit, write the review body to a scratch file and run exactly one tracker verdict for the reviewed HEAD. PASS: \`$(dirname "$SELF_PATH")/lane.sh verdict $_verdict_ticket pass $_verdict_head --file <verdict-body-file>\`. FAIL: \`$(dirname "$SELF_PATH")/lane.sh verdict $_verdict_ticket fail $_verdict_head --class <kebab-defect-class> --file <verdict-body-file>\`. Do not merely print PASS/FAIL in your final response; the verdict verb is the required ticket outcome.
BRIEFEOF
    fi
    local _hit=0 _prev=""
    for _b in "$@"; do
        if [ "$_prev" = "-p" ] && [ "$_b" = "@brief" ]; then
            _brf+=("Read the file $BRIEFS_DIR/$id.md and execute it as your complete brief.")
            _hit=1
        else
            _brf+=("$_b")
        fi
        _prev="$_b"
    done
    if [ -n "$provider" ]; then
        _SPAWN_ARGS=("$AGENT_SH" run --provider "$provider" --job "$job" --tier "$agent_tier" \
                     --cwd "$abs" --brief "$BRIEFS_DIR/$id.md" --lane-id "$id")
    else
        [ "$_hit" -eq 1 ] || die "spawn-lane: --brief with a custom command requires '-p @brief' so the staged file has a consumer"
        _SPAWN_ARGS=("${_brf[@]}")
    fi
}

# What the lane does after its command exits, in order: release the merge
# lock first so the next merge can start, then fire the next wave.
# Event-driven ticking means the loop advances at the speed of work, not a
# fixed timer. A fire that lands during a running wave is no longer lost: it
# leaves the pending note and that wave re-ticks once on exit (P1), so the
# heartbeat is a true backstop for the initial kick and post-stall resume.
# Render BEFORE the tick fires: the wave this lane wakes up reads lane logs
# for verdicts and crash triage, and must not race the transcript.
# Reads, from the caller's scope: id, jsonl, stream,
# merge_lock, gate_lock_key, on_done, and the lane command as "$@"; sets epi
# and redirect there, and leaves the (possibly flag-extended) command in
# _SPAWN_ARGS for the caller to `set --` back. Everything the program text needs travels by
# ENVIRONMENT (LOOM_LANE_JSONL) or as single-quoted paths this script owns —
# never caller input spliced into the program. Pure assembly: nothing here
# refuses, nothing here destroys.
_spawn_build_epilogue() {
    epi=""; redirect=""
    if [ "$stream" -eq 1 ]; then
        export LOOM_LANE_JSONL="$jsonl"
        redirect=' >"$LOOM_LANE_JSONL"'
        epi="'$SELF_PATH' render-log '$id'; "
    fi
    [ "$merge_lock" -eq 1 ] && epi="$epi rm -rf '$MERGE_LOCK_DIR'; "
    [ -n "$gate_lock_key" ] && epi="$epi rm -rf '$GATE_LOCK_DIR/$gate_lock_key'; "
    # A provider lane may have queued its successor. Its host shell reaches
    # this epilogue only after the provider session exits, so the successor is
    # safe to detach here. Do this after releasing locks and before firing the
    # ordinary next wave.
    epi="$epi '$SELF_PATH' drain-lane-launches >>'$LOGS_DIR/lane-launches.log' 2>&1 || true; "
    # P93: a merge lane's own exit tries to spawn its successor directly
    # (chain-merge), released lock and all, INSTEAD of firing a whole wave to
    # rediscover a decision that is already deterministic. Gate exits use the
    # same narrow queue reader: a wave-authored gate brief can omit its PASS
    # handoff, but the oldest merge-queue ticket is still deterministic after
    # the verdict. Every other lane kind fires the ordinary wave. chain-merge's
    # own fallback is that same "tick --from-lane" line, for every way the fast
    # path can decline (empty queue, no worktree, a refused spawn). (Paid for:
    # patient-imaging JOR-191 passed but its gate brief said "End after the
    # verdict", losing the direct merge handoff, 2026-08-16.)
    if [ "$on_done" -eq 1 ]; then
        if [ "$merge_lock" -eq 1 ] || [ "$(_lane_type "$id")" = gate ]; then
            if [ "${LOOM_LANE_LAUNCHER:-}" = launchd ]; then
                # D-TICK-22: launchd owns the one-shot job's process group and
                # reaps background descendants when the lane shell exits. Keep
                # the deterministic successor supervised until it returns.
                epi="$epi LOOM_LANE_EPILOGUE=1 '$SELF_PATH' chain-merge >>'$LOGS_DIR/self-trigger.log' 2>&1 || true; "
            else
                epi="$epi( LOOM_LANE_EPILOGUE=1 '$SELF_PATH' chain-merge >>'$LOGS_DIR/self-trigger.log' 2>&1 & ); "
            fi
        else
            if [ "${LOOM_LANE_LAUNCHER:-}" = launchd ]; then
                epi="$epi LOOM_LANE_EPILOGUE=1 '$SELF_PATH' tick --from-lane --provider '${LOOM_PROVIDER:-}' >>'$LOGS_DIR/self-trigger.log' 2>&1 || true; "
            else
                epi="$epi( LOOM_LANE_EPILOGUE=1 '$SELF_PATH' tick --from-lane --provider '${LOOM_PROVIDER:-}' >>'$LOGS_DIR/self-trigger.log' 2>&1 & ); "
            fi
        fi
    fi
    # The exit code is recorded FIRST, before the tick fires, or the wave this
    # lane wakes would race the file it needs to read. It is how a wave tells a
    # mechanical gate failure (7) from a crashed session (anything else), which
    # is what makes the pregate actionable.
    # The lane records its own exit — it is the only thing that knows the code
    # and the moment. `$LANES_DIR/<id>.start` carries the spawn time so the
    # duration is measured, not inferred from file mtimes the way build 2's was.
    # The event goes immediately after the rc write, BEFORE render-log: the
    # transcript render takes seconds, and stamping the exit after it pushed
    # `lane_exit` well past the chained successor's `lane_spawn` — a 17s skew
    # the ticker rendered as "gate started, then implementation ended"
    # (observed by the human, 2026-08-02).
    # A successful tracker handoff is the lane's semantic outcome. Preserve a
    # later provider rc in the event, but normalize the lane rc so diagnostics
    # do not repaint review/verdict/closed work as a red ticket failure.
    epi="_provider_rc=\$_rc; _outcome=\$(cat '$LANES_DIR/$id.outcome' 2>/dev/null || true); [ -z \"\$_outcome\" ] || _rc=0; printf '%s\\n' \"\$_rc\" > '$LANES_DIR/$id.rc'; '$SELF_PATH' event lane_exit id '$id' type '$(_lane_type "$id")' rc \"\$_rc\" provider_rc \"\$_provider_rc\" outcome \"\${_outcome:-none}\" secs \"\$(( \$(date +%s) - \$(cat '$LANES_DIR/$id.start' 2>/dev/null || date +%s) ))\" >/dev/null 2>&1 || true; $epi"
    _SPAWN_ARGS=("$@")
}

# P12: the deterministic suite is effectively free — 868 tests in 10.6s,
# and the merge re-gate lane took 4 SECONDS end to end — yet it currently
# runs inside a review session that has already spent its expensive
# reasoning. Running it first, in shell, rejects a red branch in ~15s with
# zero model time. Roughly half of the twenty-odd full-suite runs quoted
# across build 2's logs were re-runs against an unchanged tree.
# A missing runner SKIPS the pregate rather than failing it: rejecting a
# ticket because the repo has no gate script would be a false verdict, and
# a false rejection costs far more than a review session.
# Tier and runner reach the lane through the ENVIRONMENT, never spliced into
# the shell program. Single-quoting them was not enough: a tier containing a
# quote broke out and ran arbitrary commands inside the lane, and `runner`
# comes from a config file the same way. The tier is also validated, because
# the four names are fixed and a typo should fail at spawn rather than
# silently run the wrong suite.
# Reads, from the caller's scope: pregate, id, abs; sets pre there. The tier
# die in here is the LAST refusal in spawn-lane — this function must always
# be called before anything destructive.
_spawn_build_pregate() {
    local runner tiers
    pre=""
    if [ -n "$pregate" ]; then
        # Validate against the tiers this repo ACTUALLY declares, not the four
        # built-in names: `_repo_gates_tsv` accepts any `[a-z_]+` key, so a repo
        # with a `security:` tier could pregate it — and hardcoding the four
        # broke exactly that. Fall back to the built-ins when no repo block
        # exists. The point of the check is catching a typo before it runs the
        # wrong suite; injection is already impossible, since nothing below is
        # spliced into the lane program.
        tiers=$(_repo_gates_tsv | cut -f1 | sort -u)
        [ -n "$tiers" ] || tiers="docs
logic
api
ui"
        printf '%s\n' "$tiers" | grep -qxF "$pregate" \
            || die "spawn-lane: --pregate '$pregate' is not one of this repo's gate
  tiers ($(printf '%s' "$tiers" | tr '\n' ' '))"
        runner=$(_yaml_scalar "$CONFIG" runner); [ -n "$runner" ] || runner="scripts/gate.sh"
        export LOOM_PREGATE_TIER="$pregate" LOOM_PREGATE_RUNNER="$runner"
        # P31: the adversarial half, and it runs INSTEAD of the runner — the
        # verdict is rc 7 either way, so paying for the suite first buys
        # nothing. A gate lane only: the check reads a finished branch, and
        # applying it to an implementer would reject the work before it starts.
        # The paths travel by ENVIRONMENT like the tier and the runner; nothing
        # here is spliced into the lane's shell program.
        # D-SKILL-16: the scope half, on the same terms and in the same place —
        # a branch that wrote outside its tier's tree does not deserve a paid
        # review any more than one missing its adversarial test does, and after
        # the gate the only place left to catch it is a merge lane. The
        # adversarial check keeps its precedence: it is the older contract, and
        # a repo that declares no `trees:` must see byte-identical behaviour.
        local adv_iid="" adv_paths="" scope_hit=""
        if [ "$(_lane_type "$id")" = gate ]; then
            adv_iid="${id#gate-}"; adv_iid="${adv_iid%%-*}"
            case "$adv_iid" in ''|*[!0-9]*) adv_iid="" ;; esac
        fi
        if [ -n "$adv_iid" ] && adv_paths=$(_adv_pregate_reject "$adv_iid" "$pregate" "$abs"); then
            export LOOM_PREGATE_ADV="$adv_paths"
            pre='echo "--- pregate: this ticket names mandatory adversarial tests and the branch changes no file under what tier $LOOM_PREGATE_TIER runs ($LOOM_PREGATE_ADV) — rejecting with no review session (P31) ---"; _rc=7; '
        elif [ -n "$adv_iid" ] && scope_hit=$(_scope_pregate_reject "$adv_iid" "$pregate" "$abs"); then
            export LOOM_PREGATE_SCOPE="${scope_hit%%	*}" LOOM_PREGATE_TREES="${scope_hit#*	}"
            pre='echo "--- pregate: this branch changes files outside the tree tier $LOOM_PREGATE_TIER owns ($LOOM_PREGATE_TREES) and the ticket names none of them ($LOOM_PREGATE_SCOPE) — rejecting with no review session (D-SKILL-16) ---"; _rc=7; '
        else
            pre='if [ -f "$LOOM_PREGATE_RUNNER" ]; then'
            pre="$pre"' echo "--- pregate: $LOOM_PREGATE_RUNNER $LOOM_PREGATE_TIER ---";'
            pre="$pre"' if ! bash "$LOOM_PREGATE_RUNNER" "$LOOM_PREGATE_TIER"; then'
            pre="$pre"' echo "--- pregate FAILED — rejecting with no review session (P12) ---"; _rc=7; fi;'
            # P60: a missing runner is a DECLARED bootstrap stage, never a
            # silent skip. ai-workout build-1 logged "no scripts/gate.sh here,
            # skipping" on every gate all night while the runner sat in an
            # unmerged ticket — the mechanical check ran zero times and nothing
            # said so, and the failure surfaced as merge-lane deaths instead.
            # The behaviour is unchanged (no false rejection for a repo without
            # a runner); only the report is: the lane log states what was not
            # checked and why, and a `pregate_reduced` event carries it to the
            # ticker.
            pre="$pre"' else echo "--- pregate: $LOOM_PREGATE_RUNNER is missing from this worktree — tier $LOOM_PREGATE_TIER reduced to review-only; nothing mechanical was checked (P60). If a ticket delivers the runner, this stays reduced until it merges ---";'
            pre="$pre"" '$SELF_PATH' event pregate_reduced id '$id' tier \"\$LOOM_PREGATE_TIER\" runner \"\$LOOM_PREGATE_RUNNER\" >/dev/null 2>&1 || true; fi; "
        fi
    fi
    return 0
}

cmd_spawn_lane() {
    # Self-trigger is the DEFAULT (P2). It used to be opt-in, and a wave that
    # forgot the flag said so itself: "I spawned both without --on-done-tick… So
    # nothing advances on its own" — then the build sat 12m44s until a human
    # ticked it. A flag whose omission silently halts the build is the wrong
    # shape; `--no-tick` is the deliberate opt-out for a lane that must not
    # advance the loop. `--on-done-tick` is still accepted, now a no-op, so any
    # caller written against the old contract keeps working.
    local id="" on_done=1 cwd="" merge_lock=0 pregate="" brief="" provider="" job="" agent_tier="" _spawn_shift=0
    local handoff_from="${LOOM_LANE_ID:-}"
    _spawn_parse_flags "$@"; shift "$_spawn_shift"
    # Require a real id, and fail LOUDLY on a missing id or command. A
    # malformed spawn must abort here, never produce a lane that reads as a
    # normal dead one — that silent-stall was the build-2 wave-1 bug.
    [ -n "$id" ] || die "spawn-lane: missing lane id (saw flags but no id)"
    # Charset first, because `_lane_type`'s globs end in `*` and would happily
    # accept a space. `probe-<epic>` with a real epic title ("Ledger core")
    # produced the id `probe-Ledger core`, and `lane-status` is a
    # space-delimited format the snapshot splits on — so that lane parsed as
    # {id: "probe-Ledger", pid: "core", state: "<pid>"}. A state that is never
    # "dead" counts as a live lane for the rest of the build.
    case "$id" in
        *[!A-Za-z0-9_-]*) die "spawn-lane: lane id '$id' contains characters outside
  A-Z a-z 0-9 _ - — lane state is a space-delimited format, so an id with a
  space silently corrupts every reader of it. Slugify it (probe-ledger-core)." ;;
    esac
    _lane_type "$id" >/dev/null || die "spawn-lane: '$id' is not a structured
  lane id, so the scheduler could not tell what kind of lane it is (P10). Use
  impl-<ticket>, gate-<ticket>[-r<round>], merge-<ticket>, or probe-<epic>."
    if [ -n "$provider" ]; then
        "$AGENT_SH" detect --provider "$provider" >/dev/null \
          || die "spawn-lane: no registered adapter for '$provider'"
        case "$job" in implementation|gate|merge|probe) ;; *) die "spawn-lane: --job must be implementation|gate|merge|probe";; esac
        case "$agent_tier" in medium|high) ;; *) die "spawn-lane: --tier must be medium|high";; esac
        [ -n "$brief" ] || die "spawn-lane: provider jobs require --brief"
        [ $# -eq 0 ] || die "spawn-lane: provider jobs accept no raw command after --"
    else
        [ $# -gt 0 ] || die "spawn-lane: no provider job or custom command for lane '$id'"
    fi
    # Decision 4: `stop` cuts the direct handoffs too, so a ticket already in
    # flight finishes its CURRENT worker and nothing follows it. The chain
    # (implementer -> gate -> merge) is spawned by the lanes themselves, not by
    # a wave, so blocking waves alone would let a stopped build carry a ticket
    # all the way to merged. LOOM_LANE_ID is set only inside a lane, which is
    # exactly what distinguishes a chained handoff from a wave doing its job.
    if [ -n "${LOOM_LANE_ID:-}" ] && _loop_stopped; then
        echo "spawn-lane: loop stopped — not chaining '$id' from lane '$LOOM_LANE_ID'."
        echo "  The current worker finishes; nothing follows it. \`/loom start\` picks this ticket back up."
        _ev lane_chain_skipped id "$id" from "$LOOM_LANE_ID"
        return 0
    fi
    # A lane runs where its work is. Spawning in the worktree is what removes
    # the need for a `cd` allow rule — and a bad path must fail here, loudly,
    # not become a lane that dies on its first command (P4).
    local dir="${cwd:-$REPO_ROOT}"
    [ -d "$dir" ] || die "spawn-lane: --cwd '$dir' is not a directory"
    local abs; abs=$(cd "$dir" && pwd)
    if [ -n "$provider" ]; then
        local _repo_main _cwd_main
        _repo_main=$(_git_main_root "$REPO_ROOT")
        _cwd_main=$(_git_main_root "$abs")
        [ -n "$_repo_main" ] && [ "$_cwd_main" = "$_repo_main" ] \
          || die "spawn-lane: provider cwd '$abs' is not the main clone or a linked worktree of '$REPO_ROOT'"
    fi
    if [ -n "$provider" ] && [ -z "${LOOM_SKIP_AGENT_PREFLIGHT:-}" ]; then
        [ -x "$AGENT_SH" ] || die "spawn-lane: provider runtime missing: $AGENT_SH"
        "$AGENT_SH" preflight --provider "$provider" --job "$job" --tier "$agent_tier" --cwd "$abs" >/dev/null \
          || die "spawn-lane: provider preflight failed for $provider/$job/$agent_tier in $abs"
    fi
    # Refuse the FIRST lane rather than the first merge (P30): the untrusted
    # path is usually the repo root, not this worktree, and nothing else looks
    # until a command finally needs the allowlist.
    local _bad=""
    if [ -z "$provider" ] && ! _bad=$(_trust_check_dir "$abs"); then
        _notify_trust "$_bad"
        die "spawn-lane: '$_bad' is not a trusted workspace, so a headless lane
  in '$abs' would ignore the repo allowlist and have nearly every command denied
  (P16, P30). Fix it once, by hand: run \`claude\` in '$_bad' and accept the
  trust prompt — trust cascades to every worktree beneath it. A script must
  never write that flag for you."
    fi
    [ -n "$provider" ] || _notify_trust ""
    # D-TICK-27: a wave plan and a Codex launch request are disposable
    # photographs. A human hold, rejection, or merge that lands after either
    # was created must outrank it. Re-read the ticket at the last shared
    # provider boundary before any gate is queued or started; this covers
    # Claude direct handoffs and Codex durable drains without adapter branches.
    if [ -n "$provider" ] && [ "$job" = gate ]; then
        local gate_state_rc=0 gate_refusal_rc=0
        _gate_ticket_in_review "$id" || gate_state_rc=$?
        if [ "$gate_state_rc" -ne 0 ]; then
            if [ "$gate_state_rc" -eq 2 ]; then
                _gate_launch_refusal "$id" "$handoff_from" unreadable || gate_refusal_rc=$?
            else
                _gate_launch_refusal "$id" "$handoff_from" stale || gate_refusal_rc=$?
            fi
            return "$gate_refusal_rc"
        fi
    fi
    # plan.jq owns normal scheduling, but successor handoffs and durable Codex
    # drains bypass it. Recheck the shared aux cap at the one boundary every
    # provider uses. The lock stays held until this short-lived spawn command
    # exits, after either a queue reservation or a worker pid exists.
    # Raw custom commands are a test/operator escape hatch, not paid Loom
    # workers. Production scheduler and handoff lanes use the provider-neutral
    # interface; direct handoffs are still covered even in a custom-command
    # fixture because LOOM_LANE_ID identifies the path under test.
    if _aux_lane_id "$id" \
       && { [ -n "$provider" ] || [ -n "$handoff_from" ] || [ "${LOOM_AUX_DRAIN_ID:-}" = "$id" ]; }; then
        if ! _lock_reserve "$AUX_LOCK_DIR"; then
            if [ "${LOOM_AUX_DRAIN_ID:-}" = "$id" ]; then return 75; fi
            if [ -n "$handoff_from" ]; then
                echo "spawn-lane: auxiliary admission is busy — not chaining '$id' from '$handoff_from'."
                echo "  The ordinary heartbeat schedules it later."
                _ev lane_chain_skipped id "$id" from "$handoff_from" reason aux_admission_busy
                return 0
            fi
            die "spawn-lane: auxiliary admission is busy — retry '$id' on the next heartbeat"
        fi
        trap 'rm -rf "$AUX_LOCK_DIR"' EXIT
        local aux_cap aux_used aux_source_pid="" aux_rc=0
        aux_cap=$(cfg max_aux_lanes 4)
        case "$aux_cap" in ''|*[!0-9]*) die "spawn-lane: max_aux_lanes must be a non-negative integer, got '$aux_cap'" ;; esac
        aux_used=$(_aux_capacity_usage)
        # An aux-to-aux successor replaces the caller's own slot. Provider
        # sessions must reserve that successor before they return to the host
        # epilogue; counting the still-live source as permanent makes every
        # N-of-N handoff disappear, then leaves N-1 workers until a later wave.
        # Subtract only an actually live source lane. Other handoffs (notably
        # impl -> gate) still consume a new aux slot, and a stale/spoofed lane
        # id cannot borrow capacity it does not own.
        if [ -n "$handoff_from" ] && _aux_lane_id "$handoff_from"; then
            aux_source_pid=$(cat "$LANES_DIR/$handoff_from.pid" 2>/dev/null || true)
            if [ "$aux_used" -gt 0 ] && _lane_process_alive "$handoff_from" "$aux_source_pid"; then
                aux_used=$((aux_used - 1))
            fi
        fi
        if [ "$aux_used" -ge "$aux_cap" ]; then
            _aux_admission_refusal "$id" "$handoff_from" "$aux_used" "$aux_cap" || aux_rc=$?
            return "$aux_rc"
        fi
    fi
    # The lane's own id, inherited by everything it runs — including the
    # `spawn-lane` it calls to hand off to its successor. That inheritance is
    # the seam the stopped-loop check above reads.
    export LOOM_LANE_ID="$id"
    # Never overwrite a LIVE lane. Reusing an id whose process is still running
    # replaces its pid file and rotates its log away, losing the lane that is
    # doing the work — and nothing else prevents it, because the `gate.eligible`
    # guard only looks at lanes in state `running`, so an alive-but-silent
    # (`stale`) lane suppresses nothing. This check does not care about the
    # state name: an alive pid is an alive pid.
    # Caveat, deliberately not coded around: the OS recycles pids, so a
    # long-dead lane whose number has been reused reads as alive and wedges that
    # id until it is cleared. The window is small and every cheap fix costs more
    # than the bug.
    local _old
    _old=$(cat "$LANES_DIR/$id.pid" 2>/dev/null || echo "")
    # A provider lane records rc before its host epilogue drains any queued
    # successor. Under load that small, synchronous epilogue can still be
    # running when a deterministic retry immediately reuses the id. Once rc
    # exists the worker has finished its actual job, so give only that
    # completed process a short grace period to exit; a live worker with no rc
    # still hits the refusal below immediately.
    if [ -n "$_old" ] && [ -f "$LANES_DIR/$id.rc" ] && _lane_process_alive "$id" "$_old"; then
        local _exit_wait
        for _exit_wait in $(seq 1 40); do
            _lane_process_alive "$id" "$_old" || break
            sleep 0.05
        done
    fi
    if [ -n "$_old" ] && _lane_process_alive "$id" "$_old"; then
        die "spawn-lane: lane '$id' is already running as pid $_old — harvest or
  kill it first. Reusing a live lane id would overwrite its pid file and rotate
  its log away, losing the work in progress."
    fi
    if [ -n "$provider" ] && [ "${LOOM_DEFER_LANE_LAUNCH:-}" = 1 ]; then
        _queue_lane_launch
        return 0
    fi
    # Brief staging (P28/P68/P31) — validates, copies and appends in
    # _spawn_stage_brief, which hands the rewritten command back in _SPAWN_ARGS.
    _spawn_stage_brief "$@"; set -- "${_SPAWN_ARGS[@]}"
    # Refuse inline arguments near the boundary where they actually die. The
    # cap is 1000, not lower: the working short-prompt pattern runs 400–600
    # chars and has never been denied.
    local _maxlen="${LOOM_MAX_INLINE_ARG:-1000}" _b=""
    for _b in "$@"; do
        [ "${#_b}" -le "$_maxlen" ] || die "spawn-lane: an inline argument is ${#_b} chars (cap $_maxlen) —
  prompts this long die at the CLI/permission boundary (P28). Write the brief
  to a file and spawn through the provider-neutral --provider/--job/--tier interface."
    done
    local log="$LOGS_DIR/lane-$id.log" jsonl="$LOGS_DIR/lane-$id.jsonl" stream=0
    # Provider jobs emit canonical JSONL through agent.sh. Core never detects,
    # injects, or parses a provider-native streaming flag.
    _is_agent_cmd "${1:-}" && stream=1
    # P31: record the model this lane actually runs on, read off the command
    # rather than asked for as a second flag — a self-reported model can differ
    # from the one spawned, the command line cannot. Empty means the lane
    # inherits the session default. Consumer: the ticker, so an escalation is
    # visibly taken ("#46 — implementation started (opus)"), and `retro`.
    local lane_tier="$agent_tier"
    # Carry the loom's location to any child (the lane, and the
    # completion-triggered tick), so a self-trigger targets the right repo
    # even though the lane runs in a worktree cwd.
    export LOOM_REPO="$REPO_ROOT" LOOM_HOME="$LOOM_HOME"
    [ -z "$provider" ] || export LOOM_PROVIDER="$provider"
    local lane_port="${LOOM_LANE_PORT:-}"
    [ -n "$lane_port" ] || lane_port=$(_lane_port "$id")
    export PORT="$lane_port" APP_BASE_URL="http://localhost:$lane_port"
    LOOM_SCRATCH=$(_new_scratch "lane-$id"); export LOOM_SCRATCH
    # D-TICK-19: put the scripts directory (home of lane.sh and tick.sh) on
    # PATH before spawning, so a handoff a lane composes can say `lane.sh
    # reconcile` by bare name instead of retyping the absolute path. Without
    # this a bare name resolves nowhere inside the lane's environment, and
    # nothing checks that a handoff command can be found before the lane
    # spawns on it.
    export PATH="$(dirname "$SELF_PATH"):$PATH"
    # Reserve the merge lock BEFORE spawning: a refusal must leave no lane and
    # no pid file behind, exactly like the other spawn guards.
    if [ "$merge_lock" -eq 1 ]; then
        _merge_lock_reserve || die "spawn-lane: merge lock held by pid $(_merge_lock_owner) — one merge at a time"
    fi
    # P67: same guard, for a gate lane against its own ticket+HEAD. Keyed off
    # the worktree's actual commit, read here rather than trusted from the id,
    # so a stale round number can never fool it. No HEAD to key on (--cwd is
    # not a git worktree, or has no commits yet) means nothing safe to dedupe
    # against — let it through exactly as before P67.
    local gate_lock_key=""
    if [ "$(_lane_type "$id")" = "gate" ]; then
        local _gticket="${id#gate-}" _ghead
        _gticket="${_gticket%-r[0-9]*}"
        _ghead=$(git -C "$abs" rev-parse HEAD 2>/dev/null || echo "")
        if [ -n "$_ghead" ]; then
            gate_lock_key="$_gticket@$_ghead"
            _gate_lock_reserve "$gate_lock_key" \
                || die "spawn-lane: a gate lane already holds ticket $_gticket at $_ghead
  (pid $(_gate_lock_owner "$gate_lock_key")) — one gate per commit (P67). This is the
  chain/scheduler race resolving itself; the other session owns this verdict."
        fi
    fi

    # The lane's shell program is assembled ABOVE the destructive line, so the
    # pregate tier check inside _spawn_build_pregate — the last guard that can
    # refuse — fires while the previous run's log and rc are still intact.
    local epi="" redirect="" pre=""
    _spawn_build_epilogue "$@"; set -- "${_SPAWN_ARGS[@]}"
    _spawn_build_pregate

    # EVERYTHING DESTRUCTIVE HAPPENS BELOW THIS LINE — since P75 a function
    # boundary, not just a comment: every stage that can refuse has returned by
    # here, so nothing below may die. Rotating logs and clearing `<id>.rc`
    # above the merge-lock reservation once meant a spawn that lost the lock
    # had already destroyed the previous run's transcript and exit code —
    # harvest data for a lane that was never replaced.
    # Rotate, then GUARANTEE a fresh mtime. `_rotate_log` deliberately skips an
    # empty file (there is nothing to preserve), which left the old file in
    # place carrying its old timestamp — so a lane respawned under an id whose
    # previous run wrote nothing read as `stale` the instant it started, and the
    # wave would kill it. Truncating in place is what makes "a reused id cannot
    # inherit an old mtime" actually true.
    _rotate_log "$log"; : > "$log"
    if [ "$stream" -eq 1 ]; then
        _rotate_log "$jsonl"; : > "$jsonl"
    else
        # A leftover stream file from an earlier streaming run of this id would
        # otherwise win the liveness check and never be written to again.
        _rotate_log "$jsonl"; rm -f "$jsonl"
    fi
    # The previous run's exit code must not survive into this one. Rotating the
    # logs but leaving `<id>.rc` made a freshly respawned, still-working lane
    # report the old code — and a wave harvesting `rc` 7 posts a mechanical
    # rejection against a ticket whose lane is busy.
    rm -f "$LANES_DIR/$id.rc" "$LANES_DIR/$id.outcome"
    printf '%s\n' "$lane_port" > "$LANES_DIR/$id.port"
    printf '%s\n' "$abs" > "$LANES_DIR/$id.cwd"
    # The log redirect is attached to the subshell, so it resolves before the
    # cd — a relative LOOM_HOME cannot send a lane's log somewhere else. With a
    # stream, stdout goes to the .jsonl and stderr stays on the .log, so a
    # session that dies before emitting anything still leaves its error there.
    # The pregate writes to the .log, not the stream: it is not JSON.
    # The LANE stamps the merge lock with its own pid, as its first act. Doing
    # it from here after the spawn was a race: a fast merge lane can finish and
    # release the lock before the stamp lands, and then the write failed on a
    # directory that no longer existed — fatal under `set -e`, so spawn-lane
    # reported failure for a lane that had run fine. Worse, if another merge had
    # reserved in between, the stamp would have overwritten ITS ownership with a
    # dead pid. Stamping from inside closes the window entirely.
    local stamp="" program=""
    stamp="printf '%s\\n' \$\$ > '$LANES_DIR/$id.pid'; "
    [ "$merge_lock" -eq 1 ] && stamp="${stamp}printf '%s\\n' \$\$ > '$MERGE_LOCK_DIR/pid'; "
    [ -n "$gate_lock_key" ] && stamp="${stamp}printf '%s\\n' \$\$ > '$GATE_LOCK_DIR/$gate_lock_key/pid'; "
    program='cd "$LOOM_LANE_CWD" || exit 1; _rc=0; '"$stamp$pre"'if [ "$_rc" -eq 0 ]; then "$@"'"$redirect"'; _rc=$?; fi; '"$epi"' exit $_rc'
    rm -f "$LANES_DIR/$id.pid"
    _now > "$LANES_DIR/$id.start"
    export LOOM_LANE_CWD="$abs"
    if [ "${LOOM_LANE_LAUNCHER:-}" = launchd ]; then
        local launch_label launch_domain launch_plist
        launch_label=$(_lane_launch_label "$id")
        launch_domain="gui/$(id -u)"
        launch_plist="$LANES_DIR/$id.plist"
        "$LAUNCHCTL_CMD" bootout "$launch_domain/$launch_label" >/dev/null 2>&1 || true
        # Retire a job left by the short-lived `launchctl submit` implementation.
        "$LAUNCHCTL_CMD" remove "$launch_label" >/dev/null 2>&1 || true
        _write_lane_plist "$launch_plist" "$launch_label" "$log" \
            /usr/bin/env \
              "HOME=${HOME:-}" "PATH=$PATH" "TMPDIR=${TMPDIR:-/tmp}" \
              "PORT=$PORT" "APP_BASE_URL=$APP_BASE_URL" \
              "LOOM_REPO=$REPO_ROOT" "LOOM_HOME=$LOOM_HOME" "LOOM_PROVIDER=${LOOM_PROVIDER:-}" \
              "LOOM_LANE_ID=$id" "LOOM_LANE_CWD=$abs" "LOOM_SCRATCH=$LOOM_SCRATCH" \
              "LOOM_LANE_JSONL=${LOOM_LANE_JSONL:-}" "LOOM_LANE_LAUNCHER=launchd" \
              "LOOM_GLOBAL_CONFIG=${LOOM_GLOBAL_CONFIG:-}" "LOOM_CONFIG=${LOOM_CONFIG:-}" \
              "LOOM_PREGATE_TIER=${LOOM_PREGATE_TIER:-}" "LOOM_PREGATE_RUNNER=${LOOM_PREGATE_RUNNER:-}" \
              "LOOM_PREGATE_ADV=${LOOM_PREGATE_ADV:-}" "LOOM_PREGATE_SCOPE=${LOOM_PREGATE_SCOPE:-}" \
              "LOOM_PREGATE_TREES=${LOOM_PREGATE_TREES:-}" \
              /bin/bash -c "$program" _lane "$@"
        if "$LAUNCHCTL_CMD" bootstrap "$launch_domain" "$launch_plist"; then
            printf '%s\n' "$launch_label" > "$LANES_DIR/$id.launchd"
        else
            rm -f "$launch_plist" "$LANES_DIR/$id.port" "$LANES_DIR/$id.cwd"
            [ "$merge_lock" -eq 0 ] || rm -rf "$MERGE_LOCK_DIR"
            [ -z "$gate_lock_key" ] || rm -rf "$GATE_LOCK_DIR/$gate_lock_key"
            echo "spawn-lane: launchd refused supervised lane '$id'" >&2
            return 1
        fi
    else
        ( exec nohup /bin/bash -c "$program" _lane "$@" ) >>"$log" 2>&1 &
    fi
    local _pid_wait
    for _pid_wait in $(seq 1 40); do
        [ -s "$LANES_DIR/$id.pid" ] && break
        sleep 0.05
    done
    if [ ! -s "$LANES_DIR/$id.pid" ]; then
        [ "$merge_lock" -eq 0 ] || rm -rf "$MERGE_LOCK_DIR"
        [ -z "$gate_lock_key" ] || rm -rf "$GATE_LOCK_DIR/$gate_lock_key"
        echo "spawn-lane: supervised lane '$id' never reported its pid" >&2
        return 1
    fi
    _ev lane_spawn id "$id" type "$(_lane_type "$id")" job "${job:-custom}" \
        provider "${provider:-custom}" tier "$lane_tier" \
        pregate "${pregate:-}" merge_lock "$merge_lock" log "$log"
    # (The merge lock is stamped by the lane itself — see the spawn above.
    # Between reserve and that stamp the lock carries tick.sh's own pid, which
    # is alive for that whole window, so it is never breakable in between.)
    local note=" (self-triggers next wave on exit)"
    [ "$on_done" -eq 0 ] && note=" (--no-tick: does NOT advance the loop)"
    echo "lane $id: pid $(cat "$LANES_DIR/$id.pid")$note log $log"
}

# Lane ids are structured so the scheduler can tell a lane's KIND from its name
# (P10). The run that motivated this had `12`, `gate12`, `gate-12-r2`, `impl-14`
# and `probe-e4` side by side, so type could not be derived at all and every
# lane — gates and probes included — counted against `max_lanes`, turning a
# 4-lane build into one implementer. Enforced here because this is the only
# place a lane id is ever created.
# The stream is machine shaped; the log stays human shaped. This turns one into
# the other when the lane exits, so `lane-status`, crash triage and every wave
# that tails a lane log keep reading plain text (P13). Never fatal: a lane that
# did real work must not be reported as broken because a transcript would not
# render, so every failure path falls back to the raw stream.
# Assistant prose plus the commands it ran — the two things anyone reads a lane
# log for. Shared by the one-shot render and the follower so a live view and the
# saved transcript can never disagree about what the lane said.
# The session announces its resolved model in a `system`/`init` record before
# it emits any output, so rendering that record puts the model at the TOP of
# every lane pane (asked for by the human, 2026-08-03). Taken from the stream
# rather than from the spawn line on purpose: this is the model the session
# actually resolved, so an alias (`opus` → `claude-opus-5`) or a
# `--fallback-model` downshift under a usage limit shows the truth rather than
# the request. No cross-file read, so it costs nothing and works identically in
# `--follow` and in the transcript rendered at exit.
_render_stream() { # _render_stream <jsonl> <log>
    local jsonl="$1" log="$2" tmp
    [ -s "$jsonl" ] || return 0
    if ! command -v jq >/dev/null 2>&1; then cat "$jsonl" >> "$log"; return 0; fi
    # P71: the render program lives in render.jq beside this script — moved
    # out of a single-quoted shell string, following snapshot.jq's own
    # precedent. Resolved here, after the jq check above, so a PATH missing
    # `dirname` (or anything else) still falls back to the raw stream instead
    # of aborting the whole script under `set -e`.
    # P72: every jq program here opens with `include "lib";`, so the same
    # directory is also jq's `-L` path — resolved through `_jq_lib_dir`, which
    # refuses by name when the prelude is missing.
    local jqd; jqd="$(_jq_lib_dir "$(dirname "$SELF_PATH")")"
    RENDER_JQ="$jqd/render.jq"
    [ -f "$RENDER_JQ" ] || die "render-log: $RENDER_JQ is missing — it holds the render program and ships beside tick.sh"
    tmp="$jsonl.render"
    # A killed lane leaves a half-written final line, so jq's exit code is
    # ignored and the partial render is used when there is one.
    jq -L "$jqd" -r -f "$RENDER_JQ" "$jsonl" > "$tmp" 2>/dev/null || :
    if [ -s "$tmp" ]; then cat "$tmp" >> "$log"; else cat "$jsonl" >> "$log"; fi
    rm -f "$tmp"
    return 0
}

# P93: the merge lane's post-exit hook calls this INSTEAD of firing a wave,
# so a queue of merge-ready tickets drains at the speed of the merge lane
# itself rather than one ticket per wave. Runs as its own fresh process
# (spawned from the exiting lane's epilogue, after the lock it held is
# already released — see _spawn_build_epilogue) so a `die` anywhere below
# only ends this process, never the lane it is chaining from.
#
# Every step that can fail falls back to firing the ordinary wave
# (`tick --from-lane`) rather than leaving the build stalled: an empty
# queue, a queue head with no open MR, a branch with no worktree
# (swept, never created, or raced by a plain-tracker auto-merge), or
# spawn-lane itself refusing (lock race, loop stopped, a live lane already
# holding this id). Nothing here depends on the fast path succeeding — the
# numbered steps in SKILL.md do the same merge, next wave, regardless.
cmd_chain_merge() {
    local fallback="( '$SELF_PATH' tick --from-lane --provider '${LOOM_PROVIDER:-}' >>'$LOGS_DIR/self-trigger.log' 2>&1 & )"
    # Cheap and early: a stopped loop is refused by spawn-lane too (P30's
    # LOOM_LANE_ID guard, inherited into this process the same way it is
    # inherited by every other epilogue child), but there is no reason to
    # spend the queue read and the API calls behind it just to be told so.
    if _loop_stopped; then eval "$fallback"; return 0; fi
    # D-TICK-20: the fast path is the tightest loop in the program — a merge
    # lane killed by the account's usage limit chains straight into an identical
    # merge lane, with no wave and therefore no gate in between. Read the
    # exiting lane's own transcript first, then honour any pause (this one, or
    # one an earlier wave wrote). No fallback wave here on purpose: the pause is
    # exactly what the wave would refuse on, so firing it would spend a process
    # to reach the same answer. The heartbeat tick is what picks the build back
    # up once capacity returns.
    _pause_on_lane_limit || :
    _usage_gate || return 0
    command -v jq >/dev/null 2>&1 || { eval "$fallback"; return 0; }
    local queue_json head_id head_branch
    queue_json="$(cmd_snapshot --merge-queue 2>>"$LOGS_DIR/self-trigger.log")" || queue_json="[]"
    head_id="$(printf '%s' "$queue_json" | jq -r '.[0].id // empty' 2>/dev/null)"
    head_branch="$(printf '%s' "$queue_json" | jq -r '.[0].branch // empty' 2>/dev/null)"
    if [ -z "$head_id" ] || [ -z "$head_branch" ]; then eval "$fallback"; return 0; fi
    local wt; wt="$(_worktree_for_branch "$REPO_ROOT" "$head_branch")"
    if [ -z "$wt" ] || [ ! -d "$wt" ]; then eval "$fallback"; return 0; fi
    local base; base="$(_detect_base "$REPO_ROOT")"
    local scratch; scratch="$(_new_scratch "merge-chain-$head_id")"
    local briefpath="$scratch/brief.md"
    local briefsrc; briefsrc="$(dirname "$SELF_PATH")/../references/merge-brief.md"
    [ -f "$briefsrc" ] || { eval "$fallback"; return 0; }
    sed -e "s/{{TICKET_IID}}/$head_id/g" -e "s#{{WORKTREE}}#$wt#g" -e "s/{{BASE}}/$base/g" \
        "$briefsrc" > "$briefpath"
    local tier defer_launch="${LOOM_DEFER_LANE_LAUNCH:-}"; tier="$(cfg lane_tier medium)"
    # A human-triggered chain running beneath interactive Codex is not a
    # durable worker host: Codex reaps descendants when that tool call ends.
    # Preserve the already-determined queue head, but hand its launch to the
    # installed scheduler just like a provider-authored Codex handoff. Claude
    # and durable launchd callers keep their existing direct fast path.
    _codex_host_is_ephemeral && defer_launch=1
    LOOM_DEFER_LANE_LAUNCH="$defer_launch" \
      "$SELF_PATH" spawn-lane "merge-$head_id" --merge-lock --cwd "$wt" --brief "$briefpath" \
        --provider "${LOOM_PROVIDER:-}" --job merge --tier "$tier" \
        >>"$LOGS_DIR/self-trigger.log" 2>&1 || eval "$fallback"
}

# Render new events to STDOUT as they arrive, and stop when the lane is gone.
# Read-only by construction, which is what makes it safe to run several at once
# against one lane: it never touches lane-<id>.log (the exit epilogue owns that
# file, and a follower appending to it would corrupt the artifact it is
# watching), takes no lock, writes no pid file and records no event (P24).
_follow_stream() { # _follow_stream <id>
    local id="$1"
    local jsonl="$LOGS_DIR/lane-$id.jsonl" log="$LOGS_DIR/lane-$id.log" pidfile="$LANES_DIR/$id.pid"
    local n=0 total log_n=0 log_total stream_started=0 pid gone=0
    command -v jq >/dev/null 2>&1 || die "render-log --follow: jq is required"
    local jqd; jqd="$(_jq_lib_dir "$(dirname "$SELF_PATH")")"   # P72: jq -L, the prelude every program includes
    RENDER_JQ="$jqd/render.jq"
    [ -f "$RENDER_JQ" ] || die "render-log --follow: $RENDER_JQ is missing — it holds the render program and ships beside tick.sh"
    [ -e "$pidfile" ] || [ -s "$jsonl" ] \
        || die "render-log --follow: no lane '$id' — nothing at $jsonl"
    printf -- '── lane %s ──\n' "$id"
    while :; do
        # A provider lane's plain-text pregate runs before agent.sh and writes
        # to .log. Follow it until the canonical stream begins, then use JSONL
        # exclusively: the exit epilogue later appends that rendered stream to
        # .log, and continuing to read both would print every provider turn
        # twice in the pane.
        if [ "$stream_started" -eq 0 ] && [ -s "$log" ]; then
            log_total=$(wc -l < "$log" | tr -d ' ')
            if [ "$log_total" -gt "$log_n" ]; then
                sed -n "$((log_n + 1)),${log_total}p" "$log"
                log_n=$log_total
            fi
        fi
        if [ -s "$jsonl" ]; then
            stream_started=1
            total=$(wc -l < "$jsonl" | tr -d ' ')
            if [ "$total" -gt "$n" ]; then
                sed -n "$((n + 1)),${total}p" "$jsonl" | jq -L "$jqd" -r -f "$RENDER_JQ" 2>/dev/null || :
                n=$total
            fi
        fi
        # One full pass AFTER the process disappears, so whatever the lane wrote
        # on its way out is rendered instead of being cut off mid-exit.
        [ "$gone" -eq 1 ] && break
        pid=$(cat "$pidfile" 2>/dev/null || echo "")
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then gone=1; fi
        sleep "${LOOM_FOLLOW_POLL:-1}"
    done
    printf -- '── lane %s ended ──\n' "$id"
}

cmd_render_log() { # render-log <id> [--follow] — the lane-facing verb (a lane calls it itself)
    local id="" follow=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --follow|-f) follow=1; shift ;;
            -*) die "render-log: unknown option '$1' (usage: render-log <id> [--follow])" ;;
            *) [ -z "$id" ] || die "render-log: more than one lane id given ('$id', '$1')"
               id="$1"; shift ;;
        esac
    done
    [ -n "$id" ] || die "render-log: missing lane id"
    if [ "$follow" -eq 1 ]; then _follow_stream "$id"; return; fi
    _render_stream "$LOGS_DIR/lane-$id.jsonl" "$LOGS_DIR/lane-$id.log"
}

# The build ticker: one timestamped, human-readable line per event in
# events.jsonl. Narrating mechanical events is plumbing, not judgment — a
# model relaying "gate-4 passed" would spend a turn per event and die with
# its session; this renderer is free, instant, and survives everything
# (decided with the human, 2026-08-02). It finally gives events.jsonl a live
# consumer. Read-only; works in any terminal; the watch verb opens it as a
# dedicated pane. Like report/retro it may READ the event log because it is
# never consulted by a scheduling decision — rendering is not deciding.
cmd_render_events() { # render-events [--follow]
    local follow=0
    while [ $# -gt 0 ]; do case "$1" in
        --follow|-f) follow=1; shift ;;
        *) die "render-events: unknown option '$1' (usage: render-events [--follow])" ;;
    esac; done
    command -v jq >/dev/null 2>&1 || die "render-events: jq is required"
    # The human asked for local wall-clock prefixes; month-day is included
    # because real builds cross midnight (build-1 did). Ancient jq without
    # strflocaltime falls back to the UTC stamp rather than dying. P71: this
    # used to select which jq fragment to splice into the program text; now
    # the program is a file, so it is passed in as data instead (when_mode
    # "ts" or "t", read by render-events.jq's own `when` definition).
    local when_mode="ts"
    jq -ne '0 | strflocaltime("%H")' >/dev/null 2>&1 || when_mode="t"
    # Failure lines wear a glyph always and color on a terminal (asked for by
    # the human, 2026-08-02: red/gate-fail and merge-conflict lines must stand
    # out in the strip). Glyphs are plain text so greps and tests see the same
    # bytes everywhere; color is auto on a tty, forced with LOOM_COLOR=1|0.
    local bad="" warn="" good="" rst=""
    local want_color="${LOOM_COLOR:-auto}"
    if [ "$want_color" = 1 ] || { [ "$want_color" = auto ] && [ -t 1 ]; }; then
        bad=$'\033[1;31m'; warn=$'\033[1;33m'; good=$'\033[1;32m'; rst=$'\033[0m'
    fi
    # P71: the ticker program lives in render-events.jq beside this script —
    # moved out of a single-quoted shell string, following snapshot.jq's own
    # precedent.
    local jqd; jqd="$(_jq_lib_dir "$(dirname "$SELF_PATH")")"   # P72: jq -L, the prelude `stage` lives in
    local prog_file="$jqd/render-events.jq"
    [ -f "$prog_file" ] || die "render-events: $prog_file is missing — it holds the render program and ships beside tick.sh"
    if [ "$follow" -eq 1 ]; then
        # -F survives rotation, and waits for the file if the build has not
        # started yet; seed with recent history so the pane opens with
        # context. --unbuffered: a ticker that batches lines is not a ticker.
        # The pipeline runs as a job under a kill-children trap: killing this
        # wrapper must take tail+jq with it. Without that, a killed ticker
        # left an orphaned pipeline still writing to the pane, and every new
        # event rendered once per ghost — "duplicates that survive a restart
        # and grow over time" (observed by the human, 2026-08-02).
        trap 'pkill -P $$ 2>/dev/null; exit 0' INT TERM
        tail -n 100 -F "$EVENTS" 2>/dev/null | jq -L "$jqd" -R --unbuffered -r \
            --arg bad "$bad" --arg warn "$warn" --arg good "$good" --arg rst "$rst" \
            --arg when_mode "$when_mode" \
            -f "$prog_file" &   # render-events: display-only reader
        local _pipe=$!
        # `q` quits, when there is a keyboard attached. Ctrl-C could always
        # stop this process, but a viewer that reopens a dead ticker every
        # poll made that gesture futile — the pane simply came back, and the
        # human had no way to say "I meant it" from inside the pane itself.
        # Quitting therefore leaves the same durable marker the off-switch
        # uses, so the intent survives the next poll. Piped or redirected
        # (tests, a file, another program) there is no keyboard, so the reader
        # is skipped entirely and the old blocking wait is used.
        if [ -t 0 ]; then
            [ -n "${LOOM_TICKER_QUIT_HINT:-}" ] && printf '%s\n' "$LOOM_TICKER_QUIT_HINT"
            local _k
            while kill -0 "$_pipe" 2>/dev/null; do
                if IFS= read -rsn1 -t 1 _k 2>/dev/null; then
                    case "$_k" in
                        q|Q) : > "$LOOM_HOME/ticker-off"
                             pkill -P $$ 2>/dev/null || :
                             printf '%s\n' "ticker: closed.${LOOM_TICKER_REOPEN_HINT:+ $LOOM_TICKER_REOPEN_HINT}"
                             return 0 ;;
                    esac
                fi
            done
        else
            wait "$_pipe" || :
        fi
        pkill -P $$ 2>/dev/null || :
    else
        [ -s "$EVENTS" ] || { echo "render-events: no events yet at $EVENTS"; return 0; }
        jq -L "$jqd" -R -r --arg bad "$bad" --arg warn "$warn" --arg good "$good" --arg rst "$rst" \
            --arg when_mode "$when_mode" \
            -f "$prog_file" < "$EVENTS"   # render-events: display-only reader
    fi
}

# P55: provider-reported dollar cost from canonical usage events. Unknown is
# null; Loom never estimates from native model names.
_lane_cost() { # _lane_cost <jsonl-file> -> USD or null when unavailable
    [ -f "$1" ] || { echo null; return; }
    # No jq, no cost — same "0" the old inline `|| echo 0` fallback gave when
    # jq itself was missing, checked explicitly here so the file resolution
    # below (which needs `dirname`) is never reached on a PATH without jq.
    command -v jq >/dev/null 2>&1 || { echo null; return; }
    # P71: the price table lives in usage.jq beside this script — moved out
    # of a single-quoted shell string, following snapshot.jq's own precedent.
    local jqd; jqd="$(_jq_lib_dir "$(dirname "$SELF_PATH")")"   # P72: jq -L, the prelude every program includes
    USAGE_JQ="$jqd/usage.jq"
    [ -f "$USAGE_JQ" ] || die "usage-cost: $USAGE_JQ is missing — it holds the usage-cost program and ships beside tick.sh"
    jq -L "$jqd" -R -s -f "$USAGE_JQ" < "$1" 2>/dev/null || echo null
}

# P55/D-TICK-13: every lane AND wave log this repo has ever kept — `clear-lane`
# never removes the jsonl, only the pid/rc/progress state, and wave logs are
# never pruned either — so `retro` can price a build any time after the fact.
# One entry per lane id or wave stem; `retro` joins lanes against `lane_exit`
# events and waves against `wave_end` events (by `stem`, which is the wave
# log's own basename), both already build-scoped.
_spend_by_session() { # -> JSON array [{id, cost}, ...], id is a lane id or a wave stem
    local f id
    {
        for f in "$LOGS_DIR"/lane-*.jsonl; do
            [ -f "$f" ] || continue
            id=$(basename "$f" .jsonl); id=${id#lane-}
            printf '{"id":%s,"cost":%s}\n' "$(printf '%s' "$id" | jq -R .)" "$(_lane_cost "$f")"
        done
        for f in "$LOGS_DIR"/wave-*.jsonl; do
            [ -f "$f" ] || continue
            id=$(basename "$f" .jsonl)
            printf '{"id":%s,"cost":%s}\n' "$(printf '%s' "$id" | jq -R .)" "$(_lane_cost "$f")"
        done
    } | jq -s '.'
}

cmd_lane_status() {
    local stale_min pidfile id pid log state
    stale_min=$(cfg heartbeat_stale_minutes 30)
    for pidfile in "$LANES_DIR"/*.pid; do
        [ -e "$pidfile" ] || continue
        id=$(basename "$pidfile" .pid)
        pid=$(cat "$pidfile")
        log="$LOGS_DIR/lane-$id.log"
        # Liveness reads the STREAM wherever one exists: the .log is written in
        # one go at exit, so its mtime says nothing about whether the session is
        # working, and judging by it is what killed healthy lanes (P13).
        [ -f "$LOGS_DIR/lane-$id.jsonl" ] && log="$LOGS_DIR/lane-$id.jsonl"
        # P27: and staleness counts PROGRESS, not stream bytes — api_retry
        # chatter kept a wedged lane's jsonl mtime fresh for 2h40m (build-1
        # gate-1-r2). quiet-tick maintains <id>.progress, touched only when
        # the assistant-event count grows; when present it IS the clock.
        [ -f "$LANES_DIR/$id.progress" ] && log="$LANES_DIR/$id.progress"
        if ! _lane_process_alive "$id" "$pid"; then
            state="dead"
        elif [ -f "$log" ] && [ -n "$(find "$log" -mmin +"$stale_min" 2>/dev/null)" ]; then
            state="stale"                 # alive but silent past the window —
        else                              # never an elapsed-total-time check
            state="running"
        fi
        # New columns go on the END: existing readers index state at $3, type
        # at $4. `rc` is `-` until the lane exits; 7 means its pregate rejected
        # the branch before any review session ran (P12). `turns` (P52) is the
        # same assistant-event count `.progress` already stamps for staleness —
        # a spend signal, not a liveness one — `-` when no stamp exists yet.
        # `cost` (P55) comes from canonical provider-reported usage, so a
        # running build shows known spend next to progress and null otherwise.
        echo "$id $pid $state $(_lane_type "$id" || echo unknown) $(cat "$LANES_DIR/$id.rc" 2>/dev/null || echo -) $(cat "$LANES_DIR/$id.progress" 2>/dev/null || echo -) $(_lane_cost "$LOGS_DIR/lane-$id.jsonl")"
    done
}

# P46: `stale` means "alive but silent past the heartbeat window" — the process
# still holds its pid, its worktree and its ticket. Filtering on `running`
# alone read a stale lane as gone: sweep's live-cwd guard nearly `rm -rf`'d a
# wedged lane's worktree, `_quiet_check` walked past it into a full tracker
# read, and `watch-panes.sh` closed its pane. This is the one place that
# question — "is a process still there?" — gets answered; every caller reads
# it, never `cmd_lane_status | awk '$3=="running"'` by hand.
_lanes_alive() { cmd_lane_status 2>/dev/null | awk '$3=="running"||$3=="stale"'; }

_release_lane_port() { # <lane-id> — reap only a listener owned by this lane cwd
    local id="$1" port expected pids pid actual
    port=$(cat "$LANES_DIR/$id.port" 2>/dev/null || true)
    expected=$(cat "$LANES_DIR/$id.cwd" 2>/dev/null || true)
    case "$port" in ''|*[!0-9]*) return 0 ;; esac
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 0
    case "$expected" in /*) ;; *) return 0 ;; esac
    [ "$expected" != "/" ] || return 0
    expected=$(cd "$expected" 2>/dev/null && pwd -P) || return 0
    command -v lsof >/dev/null 2>&1 || return 0
    pids=$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    for pid in $pids; do
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        actual=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)
        if [ -d "$actual" ]; then
            actual=$(cd "$actual" 2>/dev/null && pwd -P) || actual=""
        fi
        case "$actual" in
            "$expected"|"$expected"/*)
                _kill_tree "$pid"
                _ev lane_port_reaped id "$id" port "$port" pid "$pid" cwd "$actual"
                ;;
            *)
                echo "clear-lane: refusing to reap pid $pid on port $port — cwd '${actual:-unknown}' is not lane '$id' cwd '$expected'" >&2
                ;;
        esac
    done
}

cmd_clear_lane() {
    local launch_marker="$LANES_DIR/$1.launchd" launch_label="" launch_plist="$LANES_DIR/$1.plist"
    # The launchd marker can disappear before a reparented lane server does.
    # Interactive Codex cannot reliably boot out the former OR signal the
    # latter, so every cleanup crosses the durable host boundary, not only
    # cleanup of a still-marked service. The host override prevents recursion
    # while draining the request.
    if _codex_host_is_ephemeral && [ "${LOOM_HOST_LANE_CLEANUP:-}" != 1 ]; then
        _queue_lane_cleanup "$1" clear
        return 0
    fi
    launch_label=$(cat "$launch_marker" 2>/dev/null || true)
    if [ -n "$launch_label" ]; then
        if ! "$LAUNCHCTL_CMD" bootout "gui/$(id -u)/$launch_label" >/dev/null 2>&1; then
            # Do not erase the only recovery metadata while launchd still owns
            # the service. A later durable heartbeat can retry the cleanup.
            if "$LAUNCHCTL_CMD" print "gui/$(id -u)/$launch_label" >/dev/null 2>&1; then
                echo "clear-lane: launchd still owns '$launch_label' — preserving lane '$1' for durable cleanup" >&2
                return 1
            fi
        fi
    fi
    [ -z "$launch_label" ] || "$LAUNCHCTL_CMD" remove "$launch_label" >/dev/null 2>&1 || true
    _release_lane_port "$1"
    rm -f "$LANES_DIR/$1.pid" "$LANES_DIR/$1.rc" "$LANES_DIR/$1.outcome" "$LANES_DIR/$1.start" \
          "$LANES_DIR/$1.progress" "$LANES_DIR/$1.stale-notified" "$LANES_DIR/$1.port" \
          "$LANES_DIR/$1.cwd" "$launch_marker" "$launch_plist"
    echo "lane $1: cleared"
}

_kill_tree() { # snapshot the whole descendant tree, then kill it at once
    local root="$1" queue="$1" all="" p kids
    while [ -n "$queue" ]; do
        set -- $queue
        [ $# -gt 0 ] || break   # whitespace-only queue is empty, not a pid
        p="$1"; shift; queue="$*"
        # a leaf has no children: pgrep exits 1 and pipefail must not abort
        kids=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ' || :)
        all="$all $p"; queue="$queue $kids"
    done
    kill $all 2>/dev/null || :
    sleep 1
    for p in $all; do kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || :; done
}

cmd_kill_lane() { # kill-lane <id> — kill the lane's WHOLE process tree, then clear it
    # The only sanctioned way to stop a lane. Killing the bare pid kills the
    # wrapper shell and orphans the agent session inside — which keeps
    # working and keeps WRITING: an orphaned impl-29-r2 pushed, flipped its
    # ticket to review and chained a gate, and #29 merged straight through a
    # human hold (2026-08-02). The tree is snapshotted first so nothing
    # re-parents past the kill.
    local id="${1:-}"; [ -n "$id" ] || die "kill-lane: need a lane id"
    if _codex_host_is_ephemeral && [ "${LOOM_HOST_LANE_CLEANUP:-}" != 1 ]; then
        _queue_lane_cleanup "$id" kill
        return 0
    fi
    local pid; pid=$(cat "$LANES_DIR/$id.pid" 2>/dev/null || echo "")
    if [ -n "$pid" ] && _lane_process_alive "$id" "$pid"; then
        _kill_tree "$pid"
        _ev lane_kill id "$id"
    fi
    cmd_clear_lane "$id" || return $?
    # A hard kill bypasses the lane epilogue that normally releases its lock.
    # Remove only locks stamped by this exact process, never another gate or
    # merge that happens to exist concurrently.
    if [ -n "$pid" ]; then
        local lock owner
        for lock in "$GATE_LOCK_DIR"/*; do
            [ -d "$lock" ] || continue
            owner=$(cat "$lock/pid" 2>/dev/null || true)
            [ "$owner" != "$pid" ] || rm -rf "$lock"
        done
        if [ -d "$MERGE_LOCK_DIR" ] \
           && [ "$(cat "$MERGE_LOCK_DIR/pid" 2>/dev/null || true)" = "$pid" ]; then
            rm -rf "$MERGE_LOCK_DIR"
        fi
    fi
}

cmd_notify() {
    local event="$1" title="$2" body="$3" click="${4:-}"
    # P85: a build that reports complete while leaving worktrees behind is
    # reporting on part of its own work. build-5 posted its completion report
    # and unloaded the agent with thirty standing, and said nothing. Appended
    # here rather than asked of the wave, so it cannot be forgotten.
    case "$event" in
        build_complete|build_halted) body="$body$(_sweep_held_summary)" ;;
    esac
    local topic events
    topic=$(cfg_ntfy_topic)
    events=" $(cfg_ntfy_events) "
    # The ticker records the event FIRST, before any decision about pushing.
    # It used to sit past the allowlist gate, which made the local record
    # conditional on the push config being right — so the one misparse above
    # silenced the pane as well as the phone, and the only trace of a finished
    # build was its absence. The pane is the always-on record; a push is a
    # delivery mechanism that can be switched off, misconfigured, or land in a
    # pocket. Suppression is itself worth a line: "no push" is a fact about
    # the build the human should be able to see.
    local pushed="yes"
    case "$events" in *" $event "*) ;; *) pushed="not-in-push-list" ;; esac
    _ev notify event "$event" title "$title" pushed "$pushed"
    if [ "$pushed" != yes ]; then
        echo "notify: event '$event' not in push list — recorded in the ticker, not pushed"
        return 0
    fi
    if [ -z "$topic" ]; then
        # No ntfy topic: fall back to a local desktop banner, so quiet events
        # still reach a human on this machine. (Paid for: build-1 2026-08-02
        # ran with no topic — every push silently skipped, and stalls were
        # only noticed because a session happened to be watching.)
        if command -v osascript >/dev/null 2>&1; then
            osascript -e "display notification \"${body//\"/}\" with title \"loom: ${title//\"/}\"" \
                >/dev/null 2>&1 || :
            echo "notify: no topic — posted local banner for $event"
        else
            echo "notify: no topic configured — skipping $event"
        fi
        return 0
    fi
    "$NTFY_CMD" -s -H "Title: $title" ${click:+-H "Click: $click"} \
        -H "X-Orch-Event: $event" -d "$body" "$NTFY_BASE/$topic" >/dev/null
    echo "notify: pushed $event"
}

# --- snapshot (read-only: the wave's whole read set in one document) -------
# A wave used to ask the tracker ~30 questions one at a time before spawning
# anything (4–9 minutes of model round-trips against 0.4s calls). cmd_snapshot
# answers them in ONE sequential call plus a concurrent fan-out.
#
# It stays inside this script's charter: it reports raw material (labels,
# edges, lane states) and derives only pure functions of what it already
# holds — never a decision about what to spawn, gate or merge.
#
# Two things that look like they need calls need none:
#   * a blocker is closed iff it is absent from the open-issue set (the
#     scheduler's universe is "open issues labeled build-N", SKILL.md);
#   * epic completeness is "no open member still carries it" (SKILL.md says
#     it is always derived, never stored).

_snap_warn() { printf '%s\n' "$*" >> "$SNAP_TMP/warn.txt"; }

# A degrading GET: one flaky call costs that field, not the document. A 403
# on the links endpoint is the EXPECTED path on a tier without native issue
# links — body-parsed edges carry the wave (SKILL.md's blocking-edge rule).
# P87: `--forge` picks the other driver. One flag rather than a second copy of
# this function, because the degrading behaviour is the point and it is the same
# behaviour whichever backend the call went to.
_snap_api() {  # _snap_api <out> <what> [--forge] -- <driver verb and args...>
    local out="$1" what="$2" why drv; shift 2
    drv="$TRACKER_SH"
    [ "${1:-}" = "--forge" ] && { drv="$FORGE_SH"; shift; }
    [ "${1:-}" = "--" ] && shift
    if ! "$drv" "$@" > "$out" 2>"$out.err"; then
        why=$(head -1 "$out.err" 2>/dev/null | tr -d '\n')
        printf '[]\n' > "$out"
        _snap_warn "degraded: $what — ${why:-non-array response}"
    fi
    rm -f "$out.err"
}

# bash 3.2 has no `wait -n`, so cap the fan-out in counted batches.
_snap_batch_gate() {
    SNAP_JOBS=$((SNAP_JOBS + 1))
    if [ "$SNAP_JOBS" -ge "$SNAP_BATCH" ]; then wait || true; SNAP_JOBS=0; fi
}

cmd_snapshot() {
    # P51: --brief keeps a full row only for a ticket the wave can act on
    # THIS turn (see is_actionable in snapshot.jq); the rest collapse to a
    # bare iid in `.other_iids`. `snapshot` plain stays full — watch, graph
    # and humans read it, and only the wave's own step-1 read asks for less.
    # P93: --merge-queue is a third, narrower shape again — not a smaller
    # version of the document brief/plain read, but a different question
    # (which ticket merges next, and on what branch) answered from a
    # fraction of the fan-out. It dispatches to its own function below,
    # once the checks both modes share have passed.
    local brief=false mq=false
    case "${1:-}" in
        --brief)       brief=true; shift ;;
        --merge-queue) mq=true; shift ;;
    esac
    command -v jq >/dev/null 2>&1 || die "snapshot: jq required"
    _refuse_legacy_runtime_config
    # The document builder lives in snapshot.jq beside this script. Say so
    # here: without the check jq fails deep in stage 3 with its own message
    # about an unreadable -f argument, and the wave reads that as a tracker
    # problem rather than a missing file.
    # P72: the same directory is jq's `-L` path — snapshot.jq includes the
    # shared prelude (the epic slugify and the verdict-trailer regex, both
    # shared with lane.sh), and `_jq_lib_dir` refuses by name without it.
    SNAP_JQD="$(_jq_lib_dir "$(dirname "$SELF_PATH")")"
    SNAP_JQ="$SNAP_JQD/snapshot.jq"
    [ -f "$SNAP_JQ" ] || die "snapshot: $SNAP_JQ is missing — it holds the document builder and ships beside tick.sh"
    # P86: the halt, on the read half, and BEFORE the driver is looked for. This
    # is the one board read every other read verb funnels through — `watch`,
    # `graph` and `plan` all consume a snapshot DOCUMENT rather than the
    # tracker — so one check here covers them all, and `plan` keeps P81's
    # guarantee of making no tracker call of its own. Order matters: a repo
    # declaring a tracker loom has no driver for must be told exactly that, not
    # that some file is missing.
    _require_tracker "$REPO_ROOT" "snapshot" >/dev/null
    _require_forge "$REPO_ROOT" "snapshot" >/dev/null
    [ -x "$TRACKER_SH" ] || die "snapshot: tracker driver '$TRACKER_SH' is missing or not executable"
    [ -x "$FORGE_SH" ] || die "snapshot: forge driver '$FORGE_SH' is missing or not executable"
    # glab api's projects/:id shorthand resolves from the cwd's git remote,
    # and a wave may invoke this from a lane worktree — never assume cwd.
    cd "$REPO_ROOT" || die "snapshot: cannot cd to $REPO_ROOT"
    if $mq; then
        cmd_snapshot_merge_queue
        return
    fi
    SNAP_TMP=$(mktemp -d)
    # Safe only because cmd_tick never calls cmd_snapshot: an EXIT trap here
    # would clobber the lock's. The wave invokes `tick.sh snapshot` itself.
    # LOOM_SNAP_KEEP is a debugging seam: it keeps the intermediate per-ticket
    # files a snapshot builds from, which is the only way to see what the
    # batched and fanned-out paths each actually wrote.
    [ -n "${LOOM_SNAP_KEEP:-}" ] || trap 'rm -rf "$SNAP_TMP"' EXIT
    [ -z "${LOOM_SNAP_KEEP:-}" ] || echo "snapshot: keeping $SNAP_TMP" >&2
    : > "$SNAP_TMP/warn.txt"; : > "$SNAP_TMP/lanes.txt"; printf '[]\n' > "$SNAP_TMP/notes.json"
    SNAP_JOBS=0

    # -- Stage 1: ONE call. Titles, iids, labels, assignees, milestone/epic
    # AND descriptions — so build discovery, membership, `## Blocked by`
    # parsing, tier and the epic rollup are all derived locally from here.
    # Foundational, so a failure DIES: an empty ticket list from a failed
    # call reads exactly like a genuinely empty build, and launching a wave
    # on a garbage universe is how you get ghost gates.
    "$TRACKER_SH" issues-open \
        > "$SNAP_TMP/open.json" 2>"$SNAP_TMP/raw.err" \
        || die "snapshot: open-issue list failed or was not JSON — $(head -2 "$SNAP_TMP/raw.err" | tr '\n' ' ')"

    # Milestones — the epic ACCEPTANCE record, and the one thing this snapshot
    # used to write and never read. `lane.sh probe-result <epic> pass` closes
    # the epic's milestone; its own source said "completeness stays DERIVED
    # (nothing reads milestone state)". So `complete` meant nothing but "no
    # open tickets", an epic that was never probed looked identical to one that
    # passed, and `build_complete` closed the build over both. (Paid for:
    # build-2 2026-08-04 — E4's probe FAILED and was never re-run after its fix
    # tickets merged, E6 and E7 were never probed at all, and the build closed
    # 97 seconds after E6's last ticket did. The human found it by noticing
    # three milestones still open.) Best-effort: a tier or project without
    # milestones yields `accepted: null`, which claims nothing either way.
    # Runs in the BACKGROUND, joining the stage-2 barrier: it depends on
    # nothing in the issue payload, so a serial read here would put a whole
    # round-trip on the critical path of every snapshot the build ever takes.
    printf '[]\n' > "$SNAP_TMP/milestones.json"
    ( "$TRACKER_SH" milestones 2>/dev/null \
        | jq 'map({title, state, description})' > "$SNAP_TMP/ms.json" 2>/dev/null \
      && mv "$SNAP_TMP/ms.json" "$SNAP_TMP/milestones.json" ) &

    local build_iid="" label="" nbuild
    nbuild=$(jq '[.[] | select((.title // "") | test("^Build [0-9]+$"))] | length' "$SNAP_TMP/open.json")
    if [ "$nbuild" -ge 1 ]; then
        build_iid=$(jq -r '[.[] | select((.title // "") | test("^Build [0-9]+$"))]
                           | sort_by(.id) | last | .id' "$SNAP_TMP/open.json")
        label="build-$(jq -r --argjson b "$build_iid" \
            '.[] | select(.id == $b) | .title | capture("(?<n>[0-9]+)$").n' "$SNAP_TMP/open.json")"
        if [ "$nbuild" -gt 1 ]; then
            _snap_warn "$nbuild open \`Build N\` issues — took the highest (#$build_iid)"
        fi
    else
        # An empty universe is VALID (build complete, or not yet started):
        # emit a null-build document so a heartbeat wave no-ops cleanly.
        # Only tool or call failure dies.
        _snap_warn "no open \`Build N\` issue — empty universe"
        # D-LIN-03: unless the repo declares a `Project:`, in which case the
        # read that just came back empty was SCOPED, and a scoped read that
        # hides the `Build N` issue looks exactly like a finished build — the
        # wave says "nothing to schedule" at rc 0, once a minute, forever, and
        # never self-recovers, because the input it needs is the input it
        # cannot see. Same distinction `_quiet_check` already draws between
        # `unknown` (no build yet) and `unreadable` (there IS one and the call
        # failed): two different facts that must not read the same. Named on
        # stderr as well as in the document, because a human running `snapshot`
        # by hand to find out why the loop is idle is looking at a terminal.
        local declared_project
        declared_project=$(_tracker_decl_field "$REPO_ROOT" Project)
        if [ -n "$declared_project" ]; then
            _snap_warn "…and this repo declares \`Project: $declared_project\`, so every issue read was SCOPED to it — a \`Build N\` issue carrying no project is invisible to a scoped read, which is likelier than a workspace with no build at all. Check the board for an open \`Build N\` issue before believing this build is finished."
            printf 'snapshot: no open `Build N` issue, and reads are scoped to `Project: %s` — the build may be hidden, not finished\n' \
                "$declared_project" >&2
        fi
    fi

    local member_iids="" active_iids="" review_iids="" iid
    if [ -n "$label" ]; then
        member_iids=$(jq -r --arg l "$label" \
            '.[] | select((.labels // []) | index($l)) | .id' "$SNAP_TMP/open.json")
        # MRs exist only once work has started: a ready-for-agent ticket has
        # none by definition, so fetching one is waste.
        active_iids=$(jq -r --arg l "$label" \
            '.[] | select((.labels // []) | index($l))
                 | select((.labels // []) | (index("in-progress") or index("review") or index("merge-queue")))
                 | .id' "$SNAP_TMP/open.json")
        # Comment threads are read for EVERY member ticket, active or not.
        # This widened twice, each time for the same reason: a verdict lives
        # in the thread (P11, gating), but so does the rejection history P30
        # decides rework on, and that history has to survive every state the
        # ticket passes through. review-only missed a gate-rejected ticket
        # sitting in `in-progress`; active-only then missed #47, which went
        # rejected -> blocked -> unblocked and came back reading
        # `rejections.total: 0` while still carrying a real
        # `FAIL ... class=positional-correlation` trailer — so the cap
        # restarted from zero and the same-class stop rule went blind on the
        # one ticket a human had just ruled on. Membership is the only scope
        # that cannot lose the history again; it costs the same fan-out as
        # `links`, which is already per-member.
        review_iids="$member_iids"
    fi
    for iid in $member_iids; do
        printf '[]\n' > "$SNAP_TMP/links-$iid.json"; printf '[]\n' > "$SNAP_TMP/mrs-$iid.json"
        printf '[]\n' > "$SNAP_TMP/tnotes-$iid.json"
    done

    # -- Stage 1b: the BATCHED read, when the driver has one.
    #
    # A tracker that can return the whole build — every member's blocking edges
    # and comment thread nested inside one list query — makes the entire
    # per-ticket fan-out below unnecessary. Linear can (`board`); GitLab cannot,
    # and answers non-zero, which is exactly the capability probe. So this is a
    # fast path with the OLD path as its fallback, not a replacement: anything
    # that goes wrong here costs one wasted call and the fan-out still runs.
    #
    # Why it matters more than wall clock: Linear meters 2,500 requests an hour
    # against 3,000,000 complexity points, so the fan-out spends the scarce
    # budget to save the abundant one. Measured on a 63-ticket build: 252
    # requests before, 4 after, identical output. *(paid: an hour's quota gone
    # to 26 snapshots of a board that had barely moved, which then blocked an
    # unrelated publish for an hour.)*
    local batched=false
    if [ -n "$label" ] && [ -n "$member_iids" ]; then
        if "$TRACKER_SH" board --label "$label" > "$SNAP_TMP/board.json" 2>"$SNAP_TMP/board.err" \
           && jq -e 'type == "array" and length > 0' "$SNAP_TMP/board.json" >/dev/null 2>&1; then
            batched=true
            for iid in $member_iids; do
                jq -c --argjson i "$iid" \
                    '[ .[] | select(.id == $i) ][0].links // []' "$SNAP_TMP/board.json" \
                    > "$SNAP_TMP/links-$iid.json" || printf '[]\n' > "$SNAP_TMP/links-$iid.json"
            done
            for iid in $review_iids; do
                jq -c --argjson i "$iid" \
                    '[ .[] | select(.id == $i) ][0].notes // []' "$SNAP_TMP/board.json" \
                    > "$SNAP_TMP/tnotes-$iid.json" || printf '[]\n' > "$SNAP_TMP/tnotes-$iid.json"
            done
        fi
        rm -f "$SNAP_TMP/board.err"
    fi

    # -- Stage 2: concurrent fan-out. Wall clock is the slowest single call.
    # Skipped for links and comments when stage 1b already has them.
    $batched || for iid in $member_iids; do
        ( _snap_api "$SNAP_TMP/links-$iid.json" "issue #$iid links" \
            -- issue-links "$iid" ) &
        _snap_batch_gate
    done
    for iid in $active_iids; do
        ( _snap_api "$SNAP_TMP/mrs-$iid.json" "issue #$iid merge requests" \
            --forge -- issue-mrs "$iid" ) &
        _snap_batch_gate
    done
    $batched || for iid in $review_iids; do
        ( _snap_api "$SNAP_TMP/tnotes-$iid.json" "issue #$iid comments" \
            -- issue-notes "$iid" --limit 30 ) &
        _snap_batch_gate
    done
    if [ -n "$build_iid" ]; then
        ( _snap_api "$SNAP_TMP/notes.json" "build lessons thread" \
            -- issue-notes "$build_iid" --limit 20 ) &
        _snap_batch_gate
    fi
    # P35: the CLOSED members of this build. An epic whose last ticket closed
    # has nothing left in the open-issue payload to find it by, and that is
    # precisely the moment it becomes probe-ready — so the one epic the
    # acceptance step must see is the one an open-only read cannot show it.
    # Deriving completed epics from the milestone titles of closed members is
    # exact; the Build-issue body parse below is a heuristic kept only as a
    # fallback. (Paid for: build-3 2026-08-04 — the Build issue lists its
    # epics as a markdown TABLE, the body parse scans markdown LIST items, so
    # it matched nothing and `epics_awaiting_probe` was empty for every
    # finished epic in the build. E4 reached zero open tickets six times and
    # the probe only ever ran because a wave reasoned around the gap by hand;
    # in build-2 the same blind spot let E6 and E7 close unprobed.)
    printf '[]\n' > "$SNAP_TMP/closed.json"
    if [ -n "$label" ]; then
        ( _snap_api "$SNAP_TMP/closed.json" "closed build members" \
            -- issues-by-label "$label" closed ) &
        _snap_batch_gate
    fi
    ( cmd_lane_status > "$SNAP_TMP/lanes.txt" 2>/dev/null || : ) &
    wait || true

    for iid in $member_iids; do
        jq -c --arg k "$iid" '{key: $k, value: .}' "$SNAP_TMP/links-$iid.json"
    done | jq -s 'from_entries' > "$SNAP_TMP/links.json"
    for iid in $member_iids; do
        jq -c --arg k "$iid" '{key: $k, value: .}' "$SNAP_TMP/mrs-$iid.json"
    done | jq -s 'from_entries' > "$SNAP_TMP/mrs.json"
    for iid in $member_iids; do
        jq -c --arg k "$iid" '{key: $k, value: .}' "$SNAP_TMP/tnotes-$iid.json"
    done | jq -s 'from_entries' > "$SNAP_TMP/tnotes.json"

    # Cache the label for event tagging, and record the open-ticket state map.
    # tick.sh never observes a label change directly, so one map per snapshot is
    # how ticket cycle times become derivable at all: a ticket first seen in
    # `review` entered review around then, and one absent from the final map
    # closed. Resolution is the wave cadence, which is honest and enough.
    [ -n "$label" ] && printf '%s\n' "$label" > "$BUILD_LABEL_CACHE"

    local config_json
    config_json=$(jq -n \
        --arg max_lanes "$(cfg max_lanes 4)" --arg rejection_cap "$(cfg rejection_cap 2)" \
        --arg crash_cap "$(cfg crash_cap 2)" --arg stale "$(cfg heartbeat_stale_minutes 30)" \
        --arg merge_attempt_cap "$(cfg merge_attempt_cap 2)" \
        --arg lane_turn_cap "$(cfg lane_turn_cap 150)" \
        --arg base "$(cfg base '')" --arg max_aux "$(cfg max_aux_lanes 4)" \
        --arg lane_tier "$(_tier_cfg lane_tier medium)" --arg rework_tier "$(_tier_cfg rework_tier high)" \
        '{ max_lanes: ($max_lanes | tonumber? // $max_lanes),
           max_aux_lanes: ($max_aux | tonumber? // $max_aux),
           rejection_cap: ($rejection_cap | tonumber? // $rejection_cap),
           crash_cap: ($crash_cap | tonumber? // $crash_cap),
           merge_attempt_cap: ($merge_attempt_cap | tonumber? // $merge_attempt_cap),
           lane_turn_cap: ($lane_turn_cap | tonumber? // $lane_turn_cap),
           heartbeat_stale_minutes: ($stale | tonumber? // $stale),
           lane_tier: $lane_tier,
           rework_tier: $rework_tier,
           base: (if $base == "" then null else $base end) }')

    # -- Stage 3: assemble. Every derived field is a pure function of fields
    # already in this document — nothing independently sourced.
    jq -L "$SNAP_JQD" -n > "$SNAP_TMP/snapshot.json" \
        --slurpfile open "$SNAP_TMP/open.json" --slurpfile links "$SNAP_TMP/links.json" \
        --slurpfile mrs "$SNAP_TMP/mrs.json" --slurpfile notes "$SNAP_TMP/notes.json" \
        --slurpfile tnotes "$SNAP_TMP/tnotes.json" \
        --slurpfile milestones "$SNAP_TMP/milestones.json" \
        --slurpfile closed "$SNAP_TMP/closed.json" \
        --rawfile lanes_raw "$SNAP_TMP/lanes.txt" --rawfile warn_raw "$SNAP_TMP/warn.txt" \
        --argjson config "$config_json" --arg logs_dir "$LOGS_DIR" \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg label "$label" --arg build_iid "$build_iid" \
        --arg merge_owner "$(_merge_lock_owner)" \
        --argjson brief "$brief" \
        -f "$SNAP_JQ"

    # The retro record is derived from the finished snapshot, never recomputed
    # from the raw payloads: a second implementation of "which tickets are
    # ready" would drift from the one the scheduler actually used, and the whole
    # point of the record is to explain the decisions that were made (P26).
    # tick.sh still never observes a label *change* — one map per snapshot is
    # how cycle times become derivable, at wave resolution (P23).
    if [ -n "$label" ]; then
        _ev snapshot \
            tickets "$(jq -c '[.tickets[] | {(.id | tostring): (.state // "none")}]
                              | add // {}' "$SNAP_TMP/snapshot.json")" \
            deps "$(jq -c '[.tickets[] | {(.id | tostring):
                              [(.blocked_by // [])[] | .id]}] | add // {}' \
                    "$SNAP_TMP/snapshot.json")" \
            ready "$(jq '[.tickets[] | select(.state == "ready-for-agent" and .unblocked
                          and ((.assignees | length) == 0))] | length' "$SNAP_TMP/snapshot.json")" \
            gateable "$(jq '.summary.gateable // 0' "$SNAP_TMP/snapshot.json")" \
            impl_free "$(jq '.summary.impl_slots_free // 0' "$SNAP_TMP/snapshot.json")" \
            max_lanes "$(jq '.config.max_lanes // 4' "$SNAP_TMP/snapshot.json")" \
            merge_in_flight "$(jq 'if .summary.merge_in_flight then 1 else 0 end' \
                               "$SNAP_TMP/snapshot.json")"
    fi

    cat "$SNAP_TMP/snapshot.json"
}

# P93: the narrow read `chain-merge` uses to pick the next merge with none
# of a full snapshot's fan-out. Stage 1 (`issues-open`) still runs whole —
# it is one call, and it is how the build label itself is found — but the
# stage 1b/2 fan-out below it runs ONLY for tickets already in
# `merge-queue`, never for every member: no links, no non-queue MRs, no
# non-queue comment threads, no milestones, no closed-member read, no
# lane-status shellout. `merge_attempts_of`/`merge_hold_of` need nothing
# else — both are pure functions of a ticket's own comment thread plus the
# open-iid set, and `$members` (every open issue carrying the build label)
# already covers that set exactly the way snapshot.jq's fix-ticket
# labelling guarantees (`lane.sh fix-ticket` always adds the build label).
#
# Safe only because `chain-merge` is the only caller, and it always runs as
# a fresh process (never inside `cmd_tick`'s lock): an EXIT trap here would
# clobber the lock's, same invariant as plain `snapshot` above.
#
# Reads SNAP_JQD from the caller (cmd_snapshot sets it before dispatching
# here). Output: merge-queue.jq's array, printed as-is — chain-merge reads
# its first element and nothing else parses this shape.
cmd_snapshot_merge_queue() {
    SNAP_QTMP=$(mktemp -d)
    [ -n "${LOOM_SNAP_KEEP:-}" ] || trap 'rm -rf "$SNAP_QTMP"' EXIT
    "$TRACKER_SH" issues-open > "$SNAP_QTMP/open.json" 2>"$SNAP_QTMP/raw.err" \
        || die "snapshot: open-issue list failed or was not JSON — $(head -2 "$SNAP_QTMP/raw.err" | tr '\n' ' ')"
    local label=""
    if jq -e '[.[] | select((.title // "") | test("^Build [0-9]+$"))] | length >= 1' \
            "$SNAP_QTMP/open.json" >/dev/null 2>&1; then
        label="build-$(jq -r '[.[] | select((.title // "") | test("^Build [0-9]+$"))]
                              | sort_by(.id) | last | .title | capture("(?<n>[0-9]+)$").n' "$SNAP_QTMP/open.json")"
    fi
    printf '{}\n' > "$SNAP_QTMP/mrs.json"; printf '{}\n' > "$SNAP_QTMP/notes.json"
    if [ -n "$label" ]; then
        local qiids iid
        qiids=$(jq -r --arg l "$label" \
            '[.[] | select((.labels // []) | index($l) and index("merge-queue"))] | .[].id' \
            "$SNAP_QTMP/open.json")
        SNAP_JOBS=0
        for iid in $qiids; do
            ( _snap_api "$SNAP_QTMP/mrs-$iid.json" "issue #$iid merge requests" \
                --forge -- issue-mrs "$iid" ) &
            _snap_batch_gate
            ( _snap_api "$SNAP_QTMP/notes-$iid.json" "issue #$iid comments" \
                -- issue-notes "$iid" --limit 30 ) &
            _snap_batch_gate
        done
        wait || true
        for iid in $qiids; do
            jq -c --arg k "$iid" '{key: $k, value: .}' "$SNAP_QTMP/mrs-$iid.json"
        done | jq -s 'from_entries' > "$SNAP_QTMP/mrs.json"
        for iid in $qiids; do
            jq -c --arg k "$iid" '{key: $k, value: .}' "$SNAP_QTMP/notes-$iid.json"
        done | jq -s 'from_entries' > "$SNAP_QTMP/notes.json"
    fi
    jq -L "$SNAP_JQD" -n \
        --slurpfile open "$SNAP_QTMP/open.json" --slurpfile mrs "$SNAP_QTMP/mrs.json" \
        --slurpfile notes "$SNAP_QTMP/notes.json" --arg label "$label" \
        --argjson merge_cap "$(jq -n --arg c "$(cfg merge_attempt_cap 2)" '$c | tonumber? // 2')" \
        -f "$SNAP_JQD/merge-queue.jq"
}

# --- plan (P81): the schedule, derived rather than reasoned about ---------
# Steps 2-6 of SKILL.md's `tick` were a decision table in prose, and every
# input to it is already in the snapshot. A wave read those fields and applied
# rules that are total, adding no information the document did not carry —
# for 2m28s a wave, 36 waves, 57.5% of one build's span.
#
# READ-ONLY, like every other verb here, and load-bearing so: `tick.sh` never
# mutates the tracker, and `scripts/tests/07-snapshot.sh` enforces it by
# scanning every captured argv. This verb makes no tracker call AT ALL — it
# reads one document from stdin or a file and derives from it. The executor
# runs the actions: `spawn-lane` for a spawn, the `lane.sh` verb named in
# `.argv` for a write.
cmd_plan() { # plan [<snapshot.json>]  (default: stdin)
    command -v jq >/dev/null 2>&1 || die "plan: jq required"
    local jqd jqf
    # Same resolution as `snapshot`: the program is a file beside this script,
    # and this directory is jq's -L path because it opens with `include "lib"`.
    jqd="$(_jq_lib_dir "$(dirname "$SELF_PATH")")"
    jqf="$jqd/plan.jq"
    [ -f "$jqf" ] || die "plan: $jqf is missing — it holds the scheduling rules and ships beside tick.sh"
    local src="${1:-}"
    [ "$#" -le 1 ] || die "plan: unknown argument '$2' (usage: plan [<snapshot.json>])"
    # A global, not a local: the EXIT trap below runs after this function has
    # returned, and a `local` would be out of scope and unbound by then.
    PLAN_TMP=$(mktemp)
    # Safe only because cmd_tick never calls cmd_plan: an EXIT trap here would
    # clobber the tick lock's. The wave invokes `tick.sh plan` itself.
    trap 'rm -f "$PLAN_TMP"' EXIT
    if [ -n "$src" ]; then
        [ -f "$src" ] || die "plan: '$src' is not a file"
        cat "$src" > "$PLAN_TMP"
    else
        cat > "$PLAN_TMP"
    fi
    # An unreadable snapshot produces an EMPTY plan and a named reason, never
    # a partial one: `null` in gives the planner's own guard, so the refusal
    # is written once, in the program that owns the document shape.
    if jq -e . "$PLAN_TMP" >/dev/null 2>&1; then
        jq -L "$jqd" -f "$jqf" "$PLAN_TMP"
    else
        printf 'null\n' | jq -L "$jqd" -f "$jqf"
    fi
}

# --- report (P23): what the events add up to ------------------------------
# Two views over one file, because "tune the loop" and "diagnose this build"
# want the same events shaped differently. Neither reads anything but
# events.jsonl, so a report costs no tracker calls and works long after a build
# is over.

# Retro: the four things `report` deliberately does not compute, because each
# needs the snapshot record rather than the wave/lane totals (P26). Everything
# here is arithmetic over events — no interpretation, which is the verb's job.
cmd_retro() { # retro [--build <label>] [--vs <label>]
    local want="" vs=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --build) want="${2:-}"; [ -n "$want" ] || die "retro: --build needs a label"; shift 2 ;;
            --vs)    vs="${2:-}";   [ -n "$vs" ]   || die "retro: --vs needs a label";   shift 2 ;;
            *) die "retro: unknown argument '$1' (usage: retro [--build <label>] [--vs <label>])" ;;
        esac
    done
    [ -s "$EVENTS" ] || die "retro: no events recorded yet — $EVENTS is empty or missing"
    command -v jq >/dev/null 2>&1 || die "retro: jq is required"
    # P71: the retro program lives in retro.jq beside this script — moved out
    # of a single-quoted shell string, following snapshot.jq's own precedent.
    # Resolved here, after the jq check above, so a PATH missing `dirname`
    # dies as "jq is required" rather than aborting under `set -e`.
    local jqd; jqd="$(_jq_lib_dir "$(dirname "$SELF_PATH")")"   # P72: jq -L, the prelude hms/pct/usd live in
    RETRO_JQ="$jqd/retro.jq"
    [ -f "$RETRO_JQ" ] || die "retro: $RETRO_JQ is missing — it holds the retro program and ships beside tick.sh"
    [ -n "$want" ] || want=$(cat "$BUILD_LABEL_CACHE" 2>/dev/null || echo "")

    # report first: retro explains what report computes, and never recomputes it.
    if [ -n "$want" ]; then cmd_report --build "$want"; else cmd_report; fi
    echo
    local spend_json; spend_json=$(_spend_by_session)
    jq -L "$jqd" -rs --arg build_want "$want" --argjson spend "$spend_json" -f "$RETRO_JQ" "$EVENTS"
    if [ -n "$vs" ]; then
        printf '\n  ── baseline: %s ──\n\n' "$vs"
        { cmd_report --build "$vs"; echo; jq -L "$jqd" -rs --arg build_want "$vs" --argjson spend "$spend_json" -f "$RETRO_JQ" "$EVENTS"; } \
            | sed 's/^/  /'
    fi
}

cmd_report() { # report [--ticket <n>] [--build <label>]
    command -v jq >/dev/null 2>&1 || die "report: jq required"
    [ -s "$EVENTS" ] || { echo "report: no events recorded yet ($EVENTS)"; return 0; }
    local iid="" want=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --ticket) shift; iid="${1:-}"; shift ;;
            --build)  shift; want="${1:-}"; shift ;;
            *) die "report: unknown argument '$1'" ;;
        esac
    done
    if [ -n "$iid" ]; then
        # P71: the per-ticket report program lives in report-ticket.jq beside
        # this script — moved out of a single-quoted shell string, following
        # snapshot.jq's own precedent. Resolved here, after the jq check
        # above, for the same `set -e` reason as retro.jq.
        local jqd; jqd="$(_jq_lib_dir "$(dirname "$SELF_PATH")")"   # P72: jq -L, the prelude every program includes
        REPORT_TICKET_JQ="$jqd/report-ticket.jq"
        [ -f "$REPORT_TICKET_JQ" ] || die "report: $REPORT_TICKET_JQ is missing — it holds the per-ticket report program and ships beside tick.sh"
        jq -L "$jqd" -rs --arg iid "$iid" -f "$REPORT_TICKET_JQ" "$EVENTS"
    else
        # P71: the report program lives in report.jq beside this script —
        # moved out of a single-quoted shell string, following snapshot.jq's
        # own precedent.
        local jqd; jqd="$(_jq_lib_dir "$(dirname "$SELF_PATH")")"   # P72: jq -L, the prelude hms/pct live in
        REPORT_JQ="$jqd/report.jq"
        [ -f "$REPORT_JQ" ] || die "report: $REPORT_JQ is missing — it holds the report program and ships beside tick.sh"
        jq -L "$jqd" -rs --arg build_want "$want" -f "$REPORT_JQ" "$EVENTS"
    fi
}

# --- graph shape (P8): is there parallelism to exploit at all? -------------
# Build 2 had four lanes and, for its first hour, zero or one startable ticket;
# peak concurrency across the whole run was 2. That is decided when the tickets
# are written, not by the loop — and it was invisible until wave 1 said so.
# Reads a snapshot (stdin by default) so it costs no extra tracker calls.
#
# `widest_level` is the most tickets sharing a dependency depth. It is a LOWER
# bound on real concurrency, not the true maximum: once a depth-0 ticket merges,
# its dependent can run beside another depth-0 ticket. It is still the right
# alarm, because a build whose widest level is below `max_lanes` cannot fill
# them at the start, which is exactly when a build is most chain-bound.
cmd_graph() { # graph [<snapshot.json>]  (default: stdin) — rc 1 on an unwired epic
    command -v jq >/dev/null 2>&1 || die "graph: jq required"
    # P71: the graph program lives in graph.jq beside this script — moved out
    # of a single-quoted shell string, following snapshot.jq's own precedent.
    # Resolved here, after the jq check above, for the same `set -e` reason
    # as retro.jq.
    local jqd; jqd="$(_jq_lib_dir "$(dirname "$SELF_PATH")")"   # P72: jq -L, the prelude every program includes
    GRAPH_JQ="$jqd/graph.jq"
    [ -f "$GRAPH_JQ" ] || die "graph: $GRAPH_JQ is missing — it holds the graph program and ships beside tick.sh"
    local src="${1:--}" out
    if [ "$src" = "-" ]; then
        out=$(jq -L "$jqd" -f "$GRAPH_JQ") || return $?
    else
        [ -f "$src" ] || die "graph: no such snapshot file '$src'"
        out=$(jq -L "$jqd" -f "$GRAPH_JQ" "$src") || return $?
    fi
    printf '%s\n' "$out"
    # The shape verdicts above are advice; this one is a refusal (P64). The
    # document still prints — phase 5 reads it either way — and the non-zero
    # exit is what stops a build being defined over an epic nothing wires
    # together, instead of the probe discovering it hours later.
    if printf '%s' "$out" | jq -e '((.unwired_epics // []) | length) > 0' >/dev/null 2>&1; then
        echo "graph: refuse this build definition — each epic above needs a wiring ticket, blocked by the epic's other members, whose acceptance criteria are the epic's own, exercised against the running app (P64)." >&2
        return 1
    fi
    return 0
}

# --- launchd lifecycle (per-repo, self-installing) ------------------------
LOOM_LABEL="com.loom.$REPO_KEY"
PLIST_DIR="${LOOM_PLIST_DIR:-$HOME/Library/LaunchAgents}"
# 60s, because this ONE agent does both jobs: it watches on every firing
# (stamping lane progress, classifying quiet, notifying) and starts a wave only
# when the switch is on and `min_wave_gap_minutes` has passed. The old split was
# 900s for a scheduler that went blind whenever a wave held the lock, plus a
# separate 60s watcher to cover that blindness. One program watching first needs
# neither. Spending is paced by the gap, not by the timer, so the fast tick
# costs nothing.
HEARTBEAT_INTERVAL=60

_write_plist() {  # _write_plist <path> <interval>
    local path="$1" interval="$2" provider="${3:-${LOOM_PROVIDER:-}}" b d toolpath=""
    [ -n "$provider" ] || die "install: provider is required before writing the scheduler"
    "$AGENT_SH" detect --provider "$provider" >/dev/null \
      || die "install: no registered adapter for '$provider'"
    # launchd starts with a bare environment; bake a PATH covering the real
    # tool locations (the interactive provider may be a shell alias — resolve
    # its binary via PATH here, at install time).
    for b in "$provider" uv glab gh jq git node npm npx pnpm yarn bun corepack bash; do
        d="$(command -v "$b" 2>/dev/null)" && toolpath="$toolpath:$(dirname "$d")"
    done
    local pathval="${toolpath#:}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LOOM_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$SELF_PATH</string><string>tick</string><string>--auto</string><string>--provider</string><string>$provider</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LOOM_REPO</key><string>$REPO_ROOT</string>
        <key>LOOM_HOME</key><string>$LOOM_HOME</string>
        <key>LOOM_LANE_LAUNCHER</key><string>launchd</string>
        <key>HOME</key><string>$HOME</string>
        <key>PATH</key><string>$pathval</string>
    </dict>
    <key>WorkingDirectory</key><string>$REPO_ROOT</string>
    <key>StartInterval</key><integer>$interval</integer>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>$LOGS_DIR/launchd.tick.out.log</string>
    <key>StandardErrorPath</key><string>$LOGS_DIR/launchd.tick.err.log</string>
</dict>
</plist>
EOF
}

# Is launchd actually running this label RIGHT NOW? `print gui/<uid>/<label>`
# is the precise answer but it needs the caller to be inside that GUI domain,
# which a nohup'd lane is not: after the human armed build-1 at 09:54 launchd
# demonstrably fired wave-095403, and every self-triggered tick for the rest of
# the morning still warned "not installed". `list <label>` is domain-free and
# answers from anywhere, so it is the fallback, not the primary.
_agent_loaded() {
    "$LAUNCHCTL_CMD" print "gui/$(id -u)/$LOOM_LABEL" >/dev/null 2>&1 && return 0
    "$LAUNCHCTL_CMD" list "$LOOM_LABEL" >/dev/null 2>&1
}

# Is a heartbeat ARMED for this repo — readable from every context, including a
# detached lane's? The installed plist file is the arm record: `_arm_agent`
# writes it only after launchd accepted it, `uninstall` removes it, and a
# rejected one is moved aside. So its presence is a fact any process can read
# without a domain, and the launchd probe above is only the fallback for a
# plist living somewhere this process cannot see.
_agent_armed() {
    [ -f "$PLIST_DIR/$LOOM_LABEL.plist" ] && return 0
    _agent_loaded
}

_arm_agent() {  # _arm_agent <interval> — write + load the agent; rc 1 if launchd refused
    local interval="$1" plist="$PLIST_DIR/$LOOM_LABEL.plist"
    mkdir -p "$LOGS_DIR" "$PLIST_DIR"
    _write_plist "$plist" "$interval"
    "$LAUNCHCTL_CMD" bootout "gui/$(id -u)/$LOOM_LABEL" 2>/dev/null || true   # idempotent
    "$LAUNCHCTL_CMD" bootstrap "gui/$(id -u)" "$plist" || true
    # Retire this repo's old separate watcher, if one is still loaded from
    # before the merge. Left alone it would keep firing every 60s alongside
    # the new agent, doing the same work twice and notifying twice.
    _retire_watcher
    _agent_loaded && return 0
    # A plist launchd never loaded is worse than no plist: every later context
    # reads that file as "armed", so the build would believe it had a backstop
    # it does not have, and nothing would retry. Move it aside — it is the
    # evidence a human needs — and report the failure.
    mkdir -p "$LOOM_HOME"
    mv -f "$plist" "$LOOM_HOME/$LOOM_LABEL.plist.rejected" 2>/dev/null || rm -f "$plist"
    return 1
}

# A build with no heartbeat has no backstop: when a wave fizzles, nothing ever
# fires again. Build-1 2026-08-02 paid 2h08m of dead air for exactly that, and
# the stderr warning that shipped after crucible fired fifteen times into a log
# nobody was reading. So: arm one instead of advising about it, and when
# launchd refuses, push ONCE per state change rather than every tick. Skipped
# while the loop switch is off — a stopped build is not supposed to have a
# timer, and `start` is the only thing allowed to reverse that.
_ensure_armed() {
    _loop_stopped && return 0
    if _agent_armed; then rm -f "$UNARMED_STATE"; return 0; fi
    if _arm_agent "$HEARTBEAT_INTERVAL"; then
        rm -f "$UNARMED_STATE"
        _ev agent_armed by tick interval "$HEARTBEAT_INTERVAL"
        echo "tick: this build had no heartbeat agent — armed one (${HEARTBEAT_INTERVAL}s), so a fizzled wave can no longer stall it silently"
        return 0
    fi
    _once_per_state "$UNARMED_STATE" unarmed || return 0
    _ev agent_unarmed label "$LOOM_LABEL"
    cmd_notify build_unarmed "Build has no heartbeat — and could not arm one" \
        "launchd refused $LOOM_LABEL, so nothing restarts this build if a wave fizzles. Run /loom start from a logged-in terminal." >&2 || :
    return 0
}

# --- P22 layered config: repo > derived > global > built-in ---------------
# The human authors only what no detector can infer. Everything below is
# either a machine-level preference (global) or a fact readable off the repo
# (derived). Config at every scope stays read-only input — never build state.

GLOBAL_CONFIG="${LOOM_GLOBAL_CONFIG:-$HOME/.loom/config.yml}"
# P88: this repo's own config, in its state directory. Same keys as the global
# one and read ahead of it, so a machine that runs two repos against two
# workspaces needs no new mechanism — the directory is already per-repo and
# already outside every working tree.
REPO_STATE_CONFIG="$LOOM_HOME/config.yml"

# P88: the tracker credential, exported ONCE, here — after the config paths are
# known and before any verb runs, because every tracker call in a build descends
# from this process and environment only travels downward. `launchctl setenv`
# was the only other route: machine-wide, and no reboot survives it.
_refuse_repo_secrets "$CONFIG" "tick.sh"
_load_secrets repo-state "$REPO_STATE_CONFIG" global "$GLOBAL_CONFIG"

# This repo's ecosystem, off lib.sh's one toolchain table — the same table
# lane.sh's installer reads, so an ecosystem added there is detected here.
detect_stack() { _stack_for "$REPO_ROOT"; }

_node_runner() { case "$(detect_stack)" in pnpm) echo pnpm;; yarn) echo yarn;; *) echo npm;; esac; }

_has_npm_script() { # _has_npm_script <name>
    [ -f "$REPO_ROOT/package.json" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --arg s "$1" '.scripts[$s] // empty' "$REPO_ROOT/package.json" >/dev/null 2>&1
}

# Gate packs emit LITERAL commands, never abstract tokens — a token needs a
# resolver that does not exist (the openemr lesson, references/loom-config.md).
# Tiers escalate: docs=lint, logic=+unit, api=+integration, ui=+e2e. The extra
# suites are appended only when their conventional marker is actually present,
# so a derived tier never promises a command the repo cannot run.
_derive_gates_tsv() {
    local stack lint unit integration e2e nr
    stack=$(detect_stack)
    lint=""; unit=""; integration=""; e2e=""
    case "$stack" in
        uv)      lint="uv run ruff check ."; unit="uv run pytest -q"
                 [ -d "$REPO_ROOT/tests/integration" ] && integration="uv run pytest -q tests/integration" ;;
        poetry)  lint="poetry run ruff check ."; unit="poetry run pytest -q" ;;
        python)  lint="python -m ruff check ."; unit="python -m pytest -q" ;;
        pnpm|yarn|npm)
                 nr=$(_node_runner)
                 _has_npm_script lint && lint="$nr run lint"
                 _has_npm_script test && unit="$nr test"
                 _has_npm_script test:integration && integration="$nr run test:integration"
                 if _has_npm_script e2e; then e2e="$nr run e2e"
                 elif ls "$REPO_ROOT"/playwright.config.* >/dev/null 2>&1; then e2e="$nr exec playwright test"
                 elif ls "$REPO_ROOT"/cypress.config.*   >/dev/null 2>&1; then e2e="$nr exec cypress run"
                 fi ;;
        go)      lint="go vet ./..."; unit="go test ./..." ;;
        cargo)   lint="cargo clippy -- -D warnings"; unit="cargo test" ;;
    esac
    local tier
    for tier in docs logic api ui; do
        [ -n "$lint" ] && printf '%s\t%s\n' "$tier" "$lint"
        [ "$tier" = "docs" ] && continue
        [ -n "$unit" ] && printf '%s\t%s\n' "$tier" "$unit"
        [ "$tier" = "logic" ] && continue
        [ -n "$integration" ] && printf '%s\t%s\n' "$tier" "$integration"
        [ "$tier" = "api" ] && continue
        [ -n "$e2e" ] && printf '%s\t%s\n' "$tier" "$e2e"
    done
    # Explicit: under `set -e` a trailing false test would make this function
    # return 1, and `x=$(f)` with a nonzero f aborts the whole script. An
    # undetectable stack yielding no gates is a valid answer, not a failure.
    return 0
}

# A repo `gates:` block overrides the derived pack wholesale — the repo layer
# always wins, including for a suite a detector would have guessed differently.
_repo_gates_tsv() { # [<config-file>] — defaults to the repo's own .loom.yml
    local cfg="${1:-$CONFIG}"
    [ -f "$cfg" ] || return 0
    awk '
      { sub(/[[:space:]]*#.*$/, "") }
      /^gates:[[:space:]]*$/ { f=1; next }
      f && /^[^[:space:]]/   { f=0 }
      f && /^[[:space:]]+[a-z_]+:[[:space:]]*$/ { t=$0; gsub(/[[:space:]:]/,"",t); tier=t; next }
      f && /^[[:space:]]*-[[:space:]]*/ {
          line=$0
          sub(/^[[:space:]]*-[[:space:]]*/, "", line)
          sub(/[[:space:]]+$/, "", line)
          gsub(/^"|"$/, "", line)
          if (tier != "" && line != "") print tier "\t" line
      }' "$cfg"
}

# D-SKILL-16: which part of the tree a tier OWNS, the mechanical half of the
# scope question. `gates:` says what a tier runs; `trees:` says where its
# tickets are allowed to write, so "a `ui` ticket wrote `apps/api/src/**`" is
# decidable in shell rather than being noticed a merge lane too late.
# Absence is a complete configuration, wholly or per tier: a repo with no
# `trees:` block, or one that declares `api` and `ui` but not `docs`, gets no
# mechanical scope check for whatever it did not declare. Nothing derives a
# default layout — a guessed tree would reject correct branches in every repo
# that never opted in, which is the one failure this must not have.
# Both YAML list spellings are read — the block sequence `.loom.yml` files
# actually use, and the flow list `references/loom-config.md` documents — so a
# repo copying either out of the docs gets the block it wrote.
_repo_trees_tsv() { # [<config-file>] — tier <TAB> glob, one line per glob
    local cfg="${1:-$CONFIG}"
    [ -f "$cfg" ] || return 0
    awk '
      { sub(/[[:space:]]*#.*$/, "") }
      /^trees:[[:space:]]*$/ { f=1; next }
      f && /^[^[:space:]]/   { f=0 }
      f && /^[[:space:]]+[a-z_]+:[[:space:]]*$/ { t=$0; gsub(/[[:space:]:]/,"",t); tier=t; next }
      f && /^[[:space:]]+[a-z_]+:[[:space:]]*\[/ {
          line=$0
          t=line; sub(/:.*$/, "", t); gsub(/[[:space:]]/, "", t); tier=t
          sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
          n=split(line, item, ",")
          for (i = 1; i <= n; i++) {
              g=item[i]
              sub(/^[[:space:]]+/, "", g); sub(/[[:space:]]+$/, "", g)
              gsub(/^"|"$/, "", g)
              if (tier != "" && g != "") print tier "\t" g
          }
          next
      }
      f && /^[[:space:]]*-[[:space:]]*/ {
          line=$0
          sub(/^[[:space:]]*-[[:space:]]*/, "", line)
          sub(/[[:space:]]+$/, "", line)
          gsub(/^"|"$/, "", line)
          if (tier != "" && line != "") print tier "\t" line
      }' "$cfg"
}

# The ref a branch is measured against lives in lib.sh now, shared with
# lane.sh. Every call from this script passes $CONFIG explicitly: the git
# question may be asked of a lane worktree, but the REPO's declared base is
# what governs, so the config file must not follow the directory.
# P31: the mandatory adversarial test, made checkable. A ticket's
# `## Mandatory adversarial tests` section is enforced today in prose, one
# expensive review round at a time — seat-reservations build-1 spent 787s of
# review-session time on three rejections of one shape (absent, then not on the
# tier's command list, then skipped in CI). Whether the branch touches anything
# the tier actually runs is decidable in shell, so it costs an rc-7 spawn
# instead of a round.
# The paths are the path-shaped tokens the tier's own commands invoke, minus the
# gate runner: every tier invokes the runner and no ticket branch changes it, so
# counting it would reject every branch in a repo whose gates are one runner
# call. Same token filter as gate-deps — safe charset, at least one slash,
# relative — so flags, env words, URLs and $-words are skipped.
# The tier's commands are read from the BRANCH's `.loom.yml`, not the repo's —
# the one read in this file that deliberately follows the directory, and the
# opposite of `_base_ref` above for a reason. The base branch is a property of
# the REPO, so a branch must not get to redeclare it. The gate command list is
# a property of the CHECKOUT: `scripts/gate.sh` resolves `.loom.yml` from the
# root it runs in, so the branch's copy is literally the list the pregate is
# about to execute. Reading the repo's copy asked a question about a different
# file than the one that runs.
# ai-interpreter-workbench build-4, ticket #90: the branch wired a new
# mandatory test in by ADDING `node --test scripts/lib/latency_report.test.mjs`
# to the `logic` tier. That line exists only on the branch, so the derived path
# list came back as main's three paths, the branch touched none of them, and
# the ticket was rejected rc 7 for doing exactly what it was pinned to do —
# deterministically, on every respawn. Any ticket that adds a brand-new gate
# command hit this; none could ever pass. A branch can now name a path that
# suits it, which the one-directional design already tolerates: the check only
# ever declines to reject, and the runner still decides.
_adv_tier_paths() { # <tier> [<worktree>] → space-separated paths that tier's commands invoke
    local tier="$1" dir="${2:-}" cfg="$CONFIG" gates runner t cmdline tok out="" seen=" "
    local test_cmd cmd_has_path unknown=0
    [ -n "$dir" ] && [ -f "$dir/.loom.yml" ] && cfg="$dir/.loom.yml"
    runner=$(_yaml_scalar "$cfg" runner); [ -n "$runner" ] || runner="scripts/gate.sh"
    runner="${runner#./}"
    gates=$(_repo_gates_tsv "$cfg"); [ -n "$gates" ] || gates=$(_derive_gates_tsv)
    set -f  # a glob token must never expand against the caller's cwd
    while IFS="$(printf '\t')" read -r t cmdline; do
        [ "$t" = "$tier" ] || continue
        # A test runner with no literal path selects its suite through config,
        # package metadata, or convention. Sibling commands with explicit
        # paths do not make that selection known, so the tier as a whole is
        # unsafe for the one-directional mechanical rejection. This is only a
        # conservative runner heuristic: an unrecognised command retains the
        # old behaviour, while a recognised unknown merely reaches the real
        # gate and provider-neutral review path.
        test_cmd=0; cmd_has_path=0
        case " $cmdline " in
            *" pytest "*|*" py.test "*|*" vitest "*|*" jest "*|*" mocha "*|*" ava "*|*" tap "*|*" rspec "*|*" bats "*|\
            *" playwright test "*|*" node --test "*|*" go test "*|*" cargo test "*|*" dotnet test "*|*" mvn test "*|*" gradle test "*|\
            *" npm test "*|*" npm run test"*|*" pnpm test "*|*" pnpm run test"*|*" yarn test "*|*" yarn run test"*|*" bun test "*) test_cmd=1 ;;
        esac
        for tok in $cmdline; do
            case "$tok" in -*) continue ;; esac
            tok="${tok#./}"; tok="${tok%/}"
            case "$tok" in
                *[!A-Za-z0-9_./-]*) continue ;;
                /*) continue ;;
                "$runner") continue ;;
                */*) : ;;
                *) continue ;;
            esac
            cmd_has_path=1
            case "$seen" in *" $tok "*) continue ;; esac
            seen="$seen$tok "
            out="$out$tok "
        done
        [ "$test_cmd" -eq 0 ] || [ "$cmd_has_path" -eq 1 ] || unknown=1
    done < <(printf '%s\n' "$gates")
    set +f
    [ "$unknown" -eq 0 ] || return 1
    printf '%s' "${out% }"
    return 0
}

# Strictly one-directional, because a false rc 7 costs more than the round it
# saves (this proposal's own falsifier): it rejects ONLY a branch that changed
# nothing under those paths, on a ticket that demands adversarial tests. Every
# unknown skips and the runner decides as before — a tier with no path token, a
# worktree with no base ref, an empty or unreadable diff, an unreadable ticket,
# a ticket with no adversarial section. It says nothing about whether a test
# that IS there asserts what the bullet says; that stays a review job.
# The tracker read happens LAST, only once the local checks have found a
# candidate, so a branch that touches the suite never pays for it.
_adv_pregate_reject() { # <iid> <tier> <worktree> → prints the paths, 0 = reject
    local iid="$1" tier="$2" dir="$3" paths ref changed f p body sect cfg="$CONFIG" runner
    paths=$(_adv_tier_paths "$tier" "$dir") || return 1
    [ -n "$paths" ] || return 1
    ref=$(_base_ref "$dir" "$CONFIG"); [ "$ref" != HEAD ] || return 1
    changed=$(git -C "$dir" diff --name-only "$ref...HEAD" 2>/dev/null) || return 1
    [ -n "$changed" ] || return 1
    # A branch that changes how the gate selects or runs tests makes the
    # literal command-path approximation incomplete. Defer to the real runner
    # in that case: rejecting is unsafe because the configuration itself may
    # be the ticket's adversarial deliverable (patient-imaging-portal #280
    # split recursive certification specs out of the product project).
    [ -f "$dir/.loom.yml" ] && cfg="$dir/.loom.yml"
    runner=$(_yaml_scalar "$cfg" runner); [ -n "$runner" ] || runner="scripts/gate.sh"
    runner="${runner#./}"
    while IFS= read -r f; do
        case "$f" in
            "$runner"|playwright.config.*|vitest.config.*|vite.config.*|jest.config.*|pytest.ini|pyproject.toml|.github/workflows/*) return 1 ;;
        esac
    done <<EOF
$changed
EOF
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        for p in $paths; do
            case "$f" in "$p"|"$p"/*) return 1 ;; esac
        done
    done <<EOF
$changed
EOF
    body=$("$TRACKER_SH" issue "$iid" 2>/dev/null \
           | jq -r '.body // empty' 2>/dev/null) || return 1
    sect=$(printf '%s\n' "$body" | awk '
        tolower($0) ~ /^#+[[:space:]]*mandatory adversarial test/ { f=1; next }
        f && /^#/ { f=0 }
        f && NF   { print }')
    # A ticket that answers the template's question with prose ("None of its
    # own — this ticket verifies, it does not build") is not demanding tests;
    # it is declaring it has none, which the contract above already treats as
    # a skip. Only a bulleted line — the template's own "one per line" format
    # for the inputs that must be rejected — counts as a demand.
    printf '%s\n' "$sect" | grep -Eq '^[[:space:]]*[-*][[:space:]]' || return 1
    printf '%s' "$paths"
    return 0
}

# D-SKILL-16: the gate asks what a diff DOES — `/code-review` plus the
# PRD-faithfulness check — and never what it TOUCHES. triggers-api build-2:
# JOR-72 (`tier::ui`) satisfied all nine of its acceptance criteria and also
# shipped ~105 lines of new API routes, passed a clean gate on that basis,
# merged at 20:45, and made JOR-49 unmergeable. The gate is the last cheap
# place to catch it: past it the collision surfaces in a merge lane, where the
# skill forbids fixing anything.
# Same one-directional contract as `_adv_pregate_reject` above, for the same
# reason — a false rc 7 costs more than the round it saves. It rejects ONLY a
# branch whose diff leaves the tree its tier declares, and every unknown skips:
# no `trees:` entry for this tier, no base ref, an empty or unreadable diff, an
# unreadable or empty ticket body. It says nothing about whether work INSIDE
# the tree belongs to this ticket; that stays a review job.
# The escape valve is the ticket itself: a ticket whose body names a path is a
# ticket that was scoped to touch it, whatever tree it sits in. Cross-tree work
# stays possible, it just has to be written down first.
# The trees are read from the BRANCH's `.loom.yml` and the tracker LAST, both
# for the reasons written above `_adv_tier_paths` — the branch's own layout is
# the one its diff is about, and a branch that stays home never pays for a
# tracker round trip.
_scope_pregate_reject() { # <iid> <tier> <worktree> → "<offending paths>\t<tier's globs>", 0 = reject
    local iid="$1" tier="$2" dir="$3" cfg="$CONFIG" globs="" outside="" t g ref changed f body
    [ -f "$dir/.loom.yml" ] && cfg="$dir/.loom.yml"
    while IFS="$(printf '\t')" read -r t g; do
        [ "$t" = "$tier" ] || continue
        [ -n "$g" ] || continue
        globs="$globs$g "
    done < <(_repo_trees_tsv "$cfg")
    [ -n "$globs" ] || return 1
    ref=$(_base_ref "$dir" "$CONFIG"); [ "$ref" != HEAD ] || return 1
    changed=$(git -C "$dir" diff --name-only "$ref...HEAD" 2>/dev/null) || return 1
    [ -n "$changed" ] || return 1
    set -f  # a glob must be matched as a pattern, never expanded against a cwd
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        for g in $globs; do
            # `case` matches these as patterns with -f still in force, and its
            # `*` crosses `/` — so `apps/api/**` covers the whole subtree. The
            # bare-prefix form is honoured too, the same way `_adv_pregate_reject`
            # accepts a directory as well as a file.
            case "$f" in $g|$g/*) continue 2 ;; esac
        done
        outside="$outside$f "
    done <<EOF
$changed
EOF
    set +f
    [ -n "$outside" ] || return 1
    body=$("$TRACKER_SH" issue "$iid" 2>/dev/null \
           | jq -r '.body // empty' 2>/dev/null) || return 1
    [ -n "$body" ] || return 1
    local still=""
    set -f
    for f in $outside; do
        case "$body" in *"$f"*) continue ;; esac
        still="$still$f "
    done
    set +f
    [ -n "$still" ] || return 1
    printf '%s\t%s' "${still% }" "${globs% }"
    return 0
}

# P60: the ticket graph can be acyclic while the GATE graph is not — a tier's
# command invoking a file another ticket delivers is a dependency that runs
# through a shell command, so no link-based closure check can see it.
# ai-workout build-1: the tiers invoked `scripts/gate.sh` (#7's deliverable)
# and `scripts/gen_openapi_client.py` (#6's); merge lanes died on the missing
# files, a wave mass-blocked five tickets, and the build stalled ~1h for a
# human waiver. This verb is the definition-time half: resolve every file the
# gate commands invoke and check each against the base branch, so phase 5
# refuses a build definition (or amendment) before a merge lane dies on it.
# A missing file is acceptable ONLY when a ticket delivering it blocks every
# ticket carrying that tier — deliverables live in ticket bodies, so that half
# of the judgement stays with the phase-5 session; this verb names what is
# missing and which command needs it.
# Only path-shaped tokens are resolved — safe charset, at least one slash,
# relative — so flags, env words, URLs, globs and $-words are skipped. A false
# refusal at definition time is cheaper than an hour's stall, but not free.
cmd_gate_deps() { # gate-deps — exit 1 naming each gate command whose file is not on base
    local runner ref gates repo_gates explicit_runner
    explicit_runner=$(_yaml_scalar "$CONFIG" runner)
    runner="$explicit_runner"; [ -n "$runner" ] || runner="scripts/gate.sh"
    ref=$(_base_ref "$REPO_ROOT" "$CONFIG")
    repo_gates=$(_repo_gates_tsv)
    gates="$repo_gates"; [ -n "$gates" ] || gates=$(_derive_gates_tsv)
    # The runner is what the pregate and the merge re-gate execute, so it is a
    # dependency of every tier — but only for a repo that MEANS to have one (a
    # `gates:` block or an explicit `runner:`). Refusing a derived-gates repo
    # for lacking a file it never uses would be a standing false refusal.
    local all=""
    if [ -n "$repo_gates" ] || [ -n "$explicit_runner" ]; then
        all=$(printf '@runner\t%s' "$runner")
    fi
    [ -n "$gates" ] && all=$(printf '%s\n%s' "$all" "$gates")
    local missing=0 checked=0 seen=" " tier cmdline tok
    set -f  # a glob token must never expand against the caller's cwd
    while IFS="$(printf '\t')" read -r tier cmdline; do
        { [ -n "$tier" ] && [ -n "$cmdline" ]; } || continue
        for tok in $cmdline; do
            case "$tok" in -*) continue ;; esac
            tok="${tok#./}"; tok="${tok%/}"
            case "$tok" in
                *[!A-Za-z0-9_./-]*) continue ;;
                /*) continue ;;
                */*) : ;;
                *) continue ;;
            esac
            case "$seen" in *" $tier:$tok "*) continue ;; esac
            seen="$seen$tier:$tok "
            checked=$((checked+1))
            if ! git -C "$REPO_ROOT" cat-file -e "$ref:$tok" 2>/dev/null; then
                missing=$((missing+1))
                if [ "$tier" = "@runner" ]; then
                    echo "gate-deps: MISSING $tok — the gate runner; every tier's pregate and merge re-gate runs it, and it is not on $ref"
                else
                    echo "gate-deps: MISSING $tok — invoked by tier '$tier' gate \`$cmdline\`, and it is not on $ref"
                fi
            fi
        done
    done < <(printf '%s\n' "$all")
    set +f
    if [ "$missing" -gt 0 ]; then
        echo "gate-deps: refuse this build definition unless every missing file is delivered by a ticket that blocks every ticket carrying its tier (P60)."
        return 1
    fi
    echo "gate-deps: every file the gate commands invoke exists on $ref ($checked checked)"
    return 0
}

# The rule a command needs in permissions.allow. An `FOO=1 uv run ...` command
# does NOT match `Bash(uv *)` — that mismatch is P4, and it cost a completed
# gate review its verdict. Keep every leading VAR=VALUE word, then the command.
_rule_for_cmd() {
    local out="" w
    for w in $1; do
        case "$w" in *=*) out="$out$w ";; *) out="$out$w"; break;; esac
    done
    if [ -n "$out" ]; then printf 'Bash(%s *)\n' "$out"; fi
    return 0
}

# Generated, not validated: an allowlist derived from the same commands the
# gates and probes will run cannot drift from them, which dissolves P4 rather
# than detecting it. There is deliberately no `cd` rule: spawn-lane --cwd starts
# a lane inside its own worktree, so nothing has to cd there (P4/P16).
_derive_allow() {
    local runner cmds line
    runner=$(_yaml_scalar "$CONFIG" runner); [ -n "$runner" ] || runner="scripts/gate.sh"
    printf '%s\n' \
        'Bash(git *)' 'Bash(glab *)' 'Bash(gh *)' 'Bash(sleep *)' 'Bash(curl *)' \
        'Bash(*tick.sh *)' "Bash($runner *)" "Bash(bash $runner *)" \
        'Read' 'Write' 'Edit' 'Glob' 'Grep' \
        'BashOutput' 'KillShell' 'KillBash' \
        'Bash(ls*)' 'Bash(cat *)' 'Bash(head *)' 'Bash(tail *)' \
        'Bash(grep *)' 'Bash(find *)' 'Bash(wc *)' 'Bash(which *)' \
        'Bash(echo *)' 'Bash(pwd)' 'Bash(date*)' 'Bash(jq *)' 'Bash(mkdir *)' \
        'Bash(*lane.sh *)' 'Bash(printenv *)'
    # The read-only exploration surface. A compound command is denied if ANY
    # segment is unlisted, and a wave's natural first move is exactly such a
    # compound (`ls …; find …; which glab; glab …`) — build-1 2026-08-02 had
    # one denied wholesale, and the wave misread the denial as "repo never
    # bootstrapped" and quit. mkdir: worktree parent dirs.
    # P86 settled `Bash(glab *)` deliberately rather than dropping it with the
    # call sites: no wave or lane needs it to WRITE any more — every tracker
    # call is a subprocess of tick.sh or lane.sh, which the model already
    # invokes — but it is not here for writes. It is here so the exploration
    # compound above is not denied whole, which is the failure that cost a
    # build. The rule stays; the prose forbidding hand-rolled mutations is what
    # governs writes, and every verb a lane needs now exists.
    # P87 added `Bash(gh *)` on exactly that reading and no other: a GitHub
    # forge means a wave's exploration compound can name `gh`, and one unlisted
    # segment denies the whole command.
    # BashOutput/KillShell are how a probe runs a live stack without waiting on
    # anything: start the server as a background shell, POLL it, kill it before
    # exiting. A headless session gets no notifications, so polling is the only
    # shape that works (P16). KillBash is the legacy name, harmless to allow.
    # A non-git worktree mechanism is a repo fact the human declares, never a
    # PATH probe: `command -v openemr-cmd` is true on this whole machine and
    # would leak an openemr rule into every unrelated repo's allowlist.
    local wt; wt=$(_yaml_scalar "$CONFIG" worktree_cmd)
    if [ -n "$wt" ]; then printf 'Bash(%s *)\n' "$wt"; fi
    cmds=$(_repo_gates_tsv); [ -n "$cmds" ] || cmds=$(_derive_gates_tsv)
    printf '%s\n' "$cmds" | while IFS="$(printf '\t')" read -r _ line; do
        if [ -n "$line" ]; then _rule_for_cmd "$line"; fi
    done
    return 0
}

# Hard guardrails are global and non-negotiable — never derived, never
# overridable from a repo. dontAsk auto-approves `allow`; this is what stops it.
_derive_deny() {
    printf '%s\n' \
        'Bash(git push --force*)' 'Bash(git push -f*)' 'Bash(git reset --hard*)' \
        'Bash(git clean -f*)' 'Bash(rm -rf *)' 'Bash(rm -fr *)'
}

# The same question spawn-lane asks, as a verb — so bootstrap can ask it without
# duplicating the walk, and a human can ask it before a build rather than 77
# minutes into one (P30). Read-only against the trust file, which it never
# writes; --notify pushes once per state change.
cmd_trust_check() { # trust-check [--notify] [dir]
    local notify=0 dir="" a
    for a in "$@"; do
        case "$a" in
            --notify) notify=1 ;;
            -*) die "trust-check: unknown flag '$a'" ;;
            *)  dir="$a" ;;
        esac
    done
    dir="${dir:-$REPO_ROOT}"
    [ -d "$dir" ] || die "trust-check: '$dir' is not a directory"
    local abs bad="" rc=0
    abs=$(cd "$dir" && pwd)
    bad=$(_trust_check_dir "$abs") || rc=1
    [ "$rc" -eq 0 ] && bad=""
    if [ "$notify" -eq 1 ]; then _notify_trust "$bad"; fi
    if [ "$rc" -eq 0 ]; then
        echo "trust-check: '$abs' is trusted — lanes there load the repo allowlist"
        return 0
    fi
    echo "trust-check: '$bad' is not a trusted workspace, so .claude/settings.json
  is ignored there and lane commands fall to the classifier (P30). Run \`claude\`
  in '$bad' once and accept the trust prompt. Only a human can: a script must
  never write that flag." >&2
    return 1
}

_tsv_to_json() { jq -R -s 'split("\n") | map(select(length>0) | split("\t"))
                           | reduce .[] as $p ({}; .[$p[0]] += [$p[1]])'; }
_lines_to_json() { jq -R -s 'split("\n") | map(select(length>0)) | unique'; }

_refuse_legacy_runtime_config() {
    local key=""
    key=$(_legacy_runtime_config "$CONFIG" "$GLOBAL_CONFIG") || return 0
    case "$key" in
        wave_model) die "config migration: '$key' is provider-native; replace it with wave_tier: medium|high";;
        lane_model) die "config migration: '$key' is provider-native; replace it with lane_tier: medium|high";;
        rework_model) die "config migration: '$key' is provider-native; replace it with rework_tier: medium|high";;
        fallback_model) die "config migration: '$key' is removed; usage downshift is high → medium and provider profiles own model ids";;
        permission_mode) die "config migration: '$key' is provider-specific and now owned by the selected adapter";;
        usage_limit:downshift_model) die "config migration: usage_limit: downshift_model is now usage_limit: downshift_tier";;
    esac
}

_tier_cfg() { # <key> <default>
    local v; v="$(cfg "$1" "$2")"
    case "$v" in medium|high) printf '%s\n' "$v";; *) die "$1 must be medium or high, got '$v'";; esac
}

cmd_resolve_config() {
    command -v jq >/dev/null 2>&1 || die "resolve-config: jq required"
    _refuse_legacy_runtime_config
    local stack base gates_tsv gates_src runner
    stack=$(detect_stack)
    # `base` was never a real setting: SKILL.md already states the rule.
    base=$(_detect_base "$REPO_ROOT" "$CONFIG")
    gates_tsv=$(_repo_gates_tsv); gates_src=repo
    [ -n "$gates_tsv" ] || { gates_tsv=$(_derive_gates_tsv); gates_src=derived; }
    runner=$(_yaml_scalar "$CONFIG" runner); [ -n "$runner" ] || runner="scripts/gate.sh"

    jq -n \
        --arg repo "$REPO_ROOT" --arg stack "$stack" --arg base "$base" \
        --arg runner "$runner" --arg gsrc "$gates_src" \
        --argjson gates "$(printf '%s\n' "$gates_tsv" | _tsv_to_json)" \
        --argjson allow "$(_derive_allow | _lines_to_json)" \
        --argjson deny  "$(_derive_deny  | _lines_to_json)" \
        --arg lanes "$(cfg max_lanes 4)"           --arg lanes_s "$(cfg_source max_lanes)" \
        --arg aux   "$(cfg max_aux_lanes 4)"       --arg aux_s   "$(cfg_source max_aux_lanes)" \
        --arg stall "$(cfg stall_action resume)"   --arg stall_s "$(cfg_source stall_action)" \
        --arg rej   "$(cfg rejection_cap 2)"       --arg rej_s   "$(cfg_source rejection_cap)" \
        --arg crash "$(cfg crash_cap 2)"           --arg crash_s "$(cfg_source crash_cap)" \
        --arg mcap  "$(cfg merge_attempt_cap 2)"   --arg mcap_s  "$(cfg_source merge_attempt_cap)" \
        --arg tcap  "$(cfg lane_turn_cap 150)"     --arg tcap_s  "$(cfg_source lane_turn_cap)" \
        --arg stalem "$(cfg heartbeat_stale_minutes 30)" --arg stalem_s "$(cfg_source heartbeat_stale_minutes)" \
        --arg usage "$(cfg usage_limit pause_and_resume)" --arg usage_s "$(cfg_source usage_limit)" \
        --arg wgap "$(cfg min_wave_gap_minutes 10)"      --arg wgap_s  "$(cfg_source min_wave_gap_minutes)" \
        --arg wtier "$(_tier_cfg wave_tier medium)"       --arg wtier_s "$(cfg_source wave_tier)" \
        --arg ltier "$(_tier_cfg lane_tier medium)"       --arg ltier_s "$(cfg_source lane_tier)" \
        --arg rtier "$(_tier_cfg rework_tier high)"       --arg rtier_s "$(cfg_source rework_tier)" \
        --arg trk  "$(_tracker_declared "$REPO_ROOT")" \
        --arg frg  "$(_forge_declared "$REPO_ROOT")" \
        --arg frg_s "$(_forge_source "$REPO_ROOT")" \
        --arg cvar "$(_tracker_credential "$(_tracker_declared "$REPO_ROOT")")" \
        --arg csrc "$(_secret_source "$(_tracker_credential "$(_tracker_declared "$REPO_ROOT")")")" \
        '{repo: $repo, stack: $stack, base: $base, runner: $runner,
          gates: $gates, gates_source: $gsrc,
          guardrails: {allow: $allow, deny: $deny},
          scalars: {
            max_lanes:               {value: $lanes,  source: $lanes_s},
            max_aux_lanes:           {value: $aux,    source: $aux_s},
            stall_action:            {value: $stall,  source: $stall_s},
            rejection_cap:           {value: $rej,    source: $rej_s},
            crash_cap:               {value: $crash,  source: $crash_s},
            merge_attempt_cap:       {value: $mcap,   source: $mcap_s},
            lane_turn_cap:           {value: $tcap,   source: $tcap_s},
            heartbeat_stale_minutes: {value: $stalem, source: $stalem_s},
            min_wave_gap_minutes:    {value: $wgap,   source: $wgap_s},
            usage_limit:             {value: $usage,  source: $usage_s},
            wave_tier:               {value: $wtier,  source: $wtier_s},
            lane_tier:               {value: $ltier,  source: $ltier_s},
            rework_tier:             {value: $rtier,  source: $rtier_s},
            tracker:                 {value: $trk,    source: "derived"},
            forge:                   {value: $frg,    source: $frg_s}
          },
          credential: {name: $cvar, present: ($csrc != ""), source: $csrc}}'
}

cmd_install_settings() { # install-settings [--force]
    echo "install-settings: compatibility alias — use agent.sh sync-guardrails --provider claude" >&2
    [ -x "$AGENT_SH" ] || die "install-settings: missing $AGENT_SH"
    "$AGENT_SH" sync-guardrails --provider claude --repo "$REPO_ROOT"
}

# `start` opens the human's window on the build, rather than printing a command
# to paste. Both off-switches are CLEARED first, deliberately: they exist to
# stop a *running* viewer from reopening panes the human closed, and pressing
# `q` in one build's ticker must not leave the next build unwatched. `start` is
# a newer intent than either switch, and it is the only path that clears them —
# an automatic tick must never undo the human. Launch is a no-op when a viewer
# is already up (watch-panes is a singleton per repo) and outside herdr.
# (Asked for by the human, 2026-08-04.)
_raise_viewer() {
    [ "${HERDR_ENV:-}" = 1 ] || return 0
    [ -x "$WATCH_PANES_CMD" ] || return 0
    rm -f "$LOOM_HOME/ticker-off" "$LOOM_HOME/viewer-off"
    nohup "$WATCH_PANES_CMD" >>"$LOOM_HOME/watch-panes.out" 2>&1 &
    echo "loom: viewer raised — a pane per live worker, plus the build ticker."
}

# P88: arming a build that cannot read its own board is worse than refusing to
# arm it, because the refusal is visible and the stall is not. A missing
# credential fails the first snapshot, the board classifies `unknown`, and the
# timer's own allowlist skips every wave — the identical silent stall as a
# sleeping laptop, with a `tick_skipped` event naming the symptom.
_require_credential() { # <who is refusing>
    local trk var
    trk=$(_tracker_declared "$REPO_ROOT")
    var=$(_tracker_credential "$trk")
    [ -n "$var" ] || return 0            # a CLI-driven tracker owns its own auth
    [ -z "${!var:-}" ] || return 0
    die "${1:-loom}: this repo's tracker is '$trk', which authenticates over HTTP with
  \$$var — and nothing supplies one. Refusing to arm a build whose first wave
  cannot read the board: the failure would be a silent skip, not an error.
  Put it in $GLOBAL_CONFIG (machine-wide) or $REPO_STATE_CONFIG (this repo only):

    secrets:
      $var: <the key>

  Both sit outside every working tree. NEVER in .loom.yml, which is committed."
}

cmd_install() {  # install --provider <id> [--dry-run] [interval-seconds]
    local dry=0 provider="${LOOM_PROVIDER:-}" interval="$HEARTBEAT_INTERVAL"
    while [ $# -gt 0 ]; do case "$1" in
      --dry-run) dry=1; shift;;
      --provider) provider="${2:-}"; shift 2;;
      [0-9]*) interval="$1"; shift;;
      *) die "install: unknown argument '$1'";;
    esac; done
    [ -n "$provider" ] || die "install: --provider <id> is required"
    [ -x "$AGENT_SH" ] || die "install: provider runtime missing: $AGENT_SH"
    "$AGENT_SH" detect --provider "$provider" >/dev/null \
      || die "install: no registered adapter for '$provider'"
    export LOOM_PROVIDER="$provider"
    _require_tracker "$REPO_ROOT" "install" >/dev/null
    _require_credential "install"
    _assert_build_provider "$provider"
    [ -n "${LOOM_SKIP_AGENT_PREFLIGHT:-}" ] || \
      "$AGENT_SH" preflight --provider "$provider" --job wave --tier "$(_tier_cfg wave_tier medium)" --cwd "$REPO_ROOT" >/dev/null
    if [ "$dry" -eq 1 ]; then
        # A preview, written OUTSIDE the LaunchAgents directory. Written where
        # the real one goes, it would leave a plist launchd never loaded, and
        # the arm record every later context reads is that file's presence.
        local preview="$LOOM_HOME/$LOOM_LABEL.plist.preview"
        mkdir -p "$LOOM_HOME"
        _write_plist "$preview" "$interval" "$provider"
        echo "generated (dry-run): $preview"; return 0
    fi
    # `start` is the switch going ON, and it must clear a previous `stop` or
    # the agent would tick forever refusing to do anything.
    rm -f "$LOOP_STOPPED"
    # Write before bootstrap: launchd may execute RunAtLoad before bootstrap
    # returns, and that first firing is precisely the one this marker changes.
    : > "$START_KICK_FILE"
    # `start` verifies the load rather than assuming it. A `bootstrap` that
    # launchd refuses is silent from the human's side, and the whole point of
    # this command is that something is now watching the build.
    if ! _arm_agent "$interval"; then
        rm -f "$START_KICK_FILE"
        die "loom: launchd REFUSED the build agent ($LOOM_LABEL) — NOTHING is watching this build and no wave will start on its own.
  The plist it rejected: $LOOM_HOME/$LOOM_LABEL.plist.rejected
  Check it loads by hand:  launchctl bootstrap gui/$(id -u) $LOOM_HOME/$LOOM_LABEL.plist.rejected
  Then re-run /loom start. Until it loads, the build survives only on lane self-triggers."
    fi
    rm -f "$UNARMED_STATE"
    echo "loom: build agent LOADED ($LOOM_LABEL, provider $provider, ${interval}s — watches every tick, waves at most every $(cfg min_wave_gap_minutes 10)m) — repo $REPO_ROOT"
    _raise_viewer
}

cmd_uninstall() {  # uninstall [--now]
    # `stop` used to unload the timer and nothing else — which did not stop the
    # build at all: the lanes still running finished, chained to their
    # successors, and each fired a tick that scheduled more work, with no agent
    # installed and nothing watching. The switch below is what makes the word
    # honest. (Paid for: found 2026-08-04 while designing the merge.)
    local now=0; [ "${1:-}" = "--now" ] && now=1
    : > "$LOOP_STOPPED"
    rm -f "$START_KICK_FILE"
    local plist="$PLIST_DIR/$LOOM_LABEL.plist"
    "$LAUNCHCTL_CMD" bootout "gui/$(id -u)/$LOOM_LABEL" 2>/dev/null || true
    rm -f "$plist"
    _retire_watcher
    if [ "$now" -eq 1 ]; then
        # The emergency stop. Every kill goes through kill-lane, never a bare
        # kill: that leaves the agent session inside alive, and an orphan keeps
        # writing to the tracker (it once merged a ticket straight through a
        # human hold).
        local id killed=0
        for id in $(cmd_lane_status 2>/dev/null | awk '$3 != "dead" { print $1 }'); do
            cmd_kill_lane "$id" >/dev/null 2>&1 && killed=$((killed + 1))
        done
        _ev loop_stopped mode now killed "$killed"
        echo "loom: build STOPPED ($LOOM_LABEL) — killed $killed running worker(s)"
        echo "  Their worktrees and part-finished files survive; \`/loom start\` resumes each ticket from there."
        echo "  These kills are deliberate and do NOT count toward crash_cap."
        return 0
    fi
    _ev loop_stopped mode drain
    echo "loom: build STOPPED ($LOOM_LABEL) — repo $REPO_ROOT"
    echo "  Workers still running finish their current ticket, then nothing follows them."
    echo "  Use \`stop --now\` to kill them instead. \`/loom start\` resumes."
}

# --- the old separate watcher: retirement only ------------------------------
# There used to be a second launchd agent per repo, firing every 60s to watch
# while the 900s scheduler was blind (it went blind whenever a wave held the
# lock). `tick --auto` now watches BEFORE it touches the lock, on every
# firing, so the second agent has no job left — `cmd_tick` does the watching
# and `install` uses one agent for both. What survives here is the way OUT:
# a machine that still has the old agent loaded must be able to shed it.
WATCH_LABEL="$LOOM_LABEL.watch"

_retire_watcher() {  # unload the old watcher agent and forget it ever ran
    "$LAUNCHCTL_CMD" bootout "gui/$(id -u)/$WATCH_LABEL" 2>/dev/null || true
    rm -f "$PLIST_DIR/$WATCH_LABEL.plist"
    # A frozen progress stamp with nothing maintaining it would misread a
    # healthy long-running lane as stale — remove the stamps so lane-status
    # falls back to the stream-mtime clock until the next watch pass.
    rm -f "$LANES_DIR"/*.progress "$LOOM_HOME/wave.progress" 2>/dev/null || true
}

# P27: the progress stamp. A MODEL TURN is an `assistant` stream event — a new
# assistant message or tool call — and the count is of those alone; the stamp
# file is touched only when the count grows, so its mtime means "time of last
# real progress". That is the signal: a lane whose model has not moved in the
# staleness window is wedged, however busy its current tool looks. A genuinely
# slow foreground command is not a false positive here, because the lane still
# takes a turn when it returns; one that never returns is exactly what this
# must catch.
#
# Every wedge shape freezes it: a silent API gap adds no lines at all, a retry
# storm adds only `api_retry` lines, a lane blocked on a polling tool adds only
# `tool_progress`, and a thinking-heavy lane adds only `thinking_tokens` system
# events. (Paid for: build-1 2026-08-02 — gate-1-r2's retry chatter kept its
# mtime fresh through 2h40m of zero progress, and the 27–77-minute silent gaps
# in wave-015558 had no staleness signal at all. Then build-3 2026-08-03 —
# merge-50's `gate.sh` was auto-backgrounded by the harness, the lane blocked
# on `TaskOutput` to wait for it, pytest deadlocked at 0% CPU, and the poll's
# own tool_progress records kept the lane reading `running` for 33 minutes
# while the whole merge queue stood still behind it. Then P61, ai-workout
# build-1 2026-08-07 — the count was a NOT-chatter denylist, so `thinking_tokens`
# fell through it: impl-25's 23 real turns read as 162 against a 150 cap, and
# two healthy four-minute lanes were killed and blocked on the inflated number.
# An allowlist of one event type cannot be outgrown by a new event type.)
#
# Truncated trailing lines are normal in a stream being written to right now,
# so parse per line and drop what does not parse, rather than failing the count.
_turn_count() {
    jq -R -r 'fromjson? | select(.type == "assistant_progress") | 1' "$1" 2>/dev/null \
        | wc -l | tr -d ' '
}

_stamp_progress() {
    local id pid state type rc jsonl prog n prev
    cmd_lane_status 2>/dev/null | while read -r id pid state type rc; do
        case "$state" in running|stale) ;; *) continue ;; esac
        jsonl="$LOGS_DIR/lane-$id.jsonl"; [ -f "$jsonl" ] || continue
        n=$(_turn_count "$jsonl")
        prog="$LANES_DIR/$id.progress"
        prev=$(cat "$prog" 2>/dev/null || echo -1)
        [ "$n" = "$prev" ] || printf '%s\n' "$n" > "$prog"
    done
    # The running wave gets the same clock (waves had none): stamp the newest
    # wave stream while the tick lock is held; clear the stamp when it drops.
    if [ -d "$LOCK_DIR" ]; then
        local wj; wj=$(ls -t "$LOGS_DIR"/wave-*.jsonl 2>/dev/null | head -1)
        if [ -n "$wj" ]; then
            n=$(_turn_count "$wj")
            prev=$(cat "$LOOM_HOME/wave.progress" 2>/dev/null || echo -1)
            [ "$n" = "$prev" ] || printf '%s\n' "$n" > "$LOOM_HOME/wave.progress"
        fi
    else
        rm -f "$LOOM_HOME/wave.progress" "$LOOM_HOME/wave.stale-notified"
    fi
}

# Notify once per wedged session. Detection is the watcher's whole job here —
# KILLING stays with the waves (unattended: bounded by the heartbeat) or the
# human (manual-drive, per the fizzle protocol); the watcher observes and
# notifies, never acts, which is the covenant that lets it auto-arm.
_notify_stale() {
    local id pid state type rc stale_min
    stale_min=$(cfg heartbeat_stale_minutes 30)
    cmd_lane_status 2>/dev/null | while read -r id pid state type rc; do
        [ "$state" = stale ] || continue
        _once_per_state "$LANES_DIR/$id.stale-notified" stale || continue
        cmd_notify lane_stale "Lane $id is wedged" \
            "Alive but no real progress for ${stale_min}+ min (retry chatter excluded). Unattended: the next heartbeat wave harvests it. Manual: investigate, then kill + clear-lane + tick." \
            >/dev/null 2>&1 || :
    done
    # `_once_per_state` goes LAST in the chain because it writes: it must not
    # record a firing that the conditions above it did not actually earn.
    if [ -d "$LOCK_DIR" ] && [ -f "$LOOM_HOME/wave.progress" ] \
       && [ -n "$(find "$LOOM_HOME/wave.progress" -mmin +"$stale_min" 2>/dev/null)" ] \
       && _once_per_state "$LOOM_HOME/wave.stale-notified" stale; then
        cmd_notify wave_stale "The scheduling wave is wedged" \
            "A wave holds the tick lock but has made no real progress for ${stale_min}+ min. It blocks all ticks until it exits or is killed." \
            >/dev/null 2>&1 || :
    fi
}

# The old watcher agent's entry point, kept for exactly one firing: an agent
# still loaded from before the merge lands here, takes itself down, and is
# gone. Everything it used to do — stamping, stale flags, quiet
# classification — now happens in `_watch_pass`, before every tick considers
# the lock. Without this stub such an agent would spin on a usage error every
# 60s with nothing able to retire it.
cmd_quiet_tick() {
    _retire_watcher
    echo "loom: the separate watcher is retired — tick --auto watches on every firing now"
    return 0
}

cmd_agent_status() {
    # Reports the SWITCH as well as the agent. The old version printed only
    # whether the scheduler plist was loaded, so it said "not loaded" while a
    # separate watcher was running perfectly well — the one command meant to
    # answer "is anything keeping an eye on this build?" gave half the answer,
    # and the half it gave read as "no". (Paid for: 2026-08-04, exactly that
    # confusion.)
    local gap; gap=$(cfg min_wave_gap_minutes 10)
    if _agent_loaded; then
        echo "$LOOM_LABEL: loaded — watches every tick; starts a wave at most every ${gap}m"
    elif [ -f "$PLIST_DIR/$LOOM_LABEL.plist" ]; then
        # Armed, but launchd is not answering from here. Normal in a detached
        # lane, and the reason this used to read "not loaded" all morning on a
        # build launchd was demonstrably driving.
        echo "$LOOM_LABEL: armed — the agent plist is installed; launchd is not readable from this context"
    else
        echo "$LOOM_LABEL: not loaded — nothing is watching and no wave will start on its own"
    fi
    if _loop_stopped; then
        echo "loop switch: STOPPED — lanes will not chain, automatic ticks do nothing (/loom start resumes)"
    else
        echo "loop switch: running — lanes chain to their successor and start the next wave"
    fi
    if "$LAUNCHCTL_CMD" print "gui/$(id -u)/$WATCH_LABEL" >/dev/null 2>&1; then
        echo "$WATCH_LABEL: loaded — the OLD separate watcher, now redundant; \`/loom start\` retires it"
    fi
}

case "${1:-}" in
    tick)         shift; cmd_tick "$@" ;;
    spawn-lane)   shift; cmd_spawn_lane "$@" ;;
    drain-lane-cleanups) shift; cmd_drain_lane_cleanups "$@" ;;
    drain-lane-kills) shift; cmd_drain_lane_cleanups "$@" ;; # compatibility/readable operator alias
    drain-lane-launches) shift; cmd_drain_lane_launches "$@" ;;
    lane-status)  shift; cmd_lane_status "$@" ;;
    lanes-alive)  shift; _lanes_alive "$@" ;;
    orch-home)    echo "$LOOM_HOME" ;;   # the repo's state dir — for viewer accessories that need a pidfile home
    render-log)   shift; cmd_render_log "$@" ;;
    render-events) shift; cmd_render_events "$@" ;;
    event)        shift; cmd_event "$@" ;;
    report)       shift; cmd_report "$@" ;;
    retro)        shift; cmd_retro "$@" ;;
    resume)       shift; cmd_resume "$@" ;;
    clear-lane)   shift; cmd_clear_lane "$@" ;;
    kill-lane)    shift; cmd_kill_lane "$@" ;;
    snapshot)     shift; cmd_snapshot "$@" ;;
    plan)         shift; cmd_plan "$@" ;;
    graph)        shift; cmd_graph "$@" ;;
    gate-deps)    shift; cmd_gate_deps "$@" ;;
    resolve-config)   shift; cmd_resolve_config "$@" ;;
    trust-check)      shift; cmd_trust_check "$@" ;;
    install-settings) shift; cmd_install_settings "$@" ;;
    notify)       shift; cmd_notify "$@" ;;
    install)      shift; cmd_install "$@" ;;
    uninstall)    shift; cmd_uninstall "$@" ;;
    agent-status) shift; cmd_agent_status "$@" ;;
    sweep) shift; cmd_sweep "$@" ;;
    quiet-tick) shift; cmd_quiet_tick "$@" ;;
    chain-merge) shift; cmd_chain_merge "$@" ;;
    *) die "usage: tick.sh tick --provider <id> [--auto|--from-lane] | spawn-lane <id> [--provider <id> --job <kind> --tier <medium|high> --brief <file> | -- <custom-command...>] [--no-tick] [--merge-lock] [--cwd <dir>] | lane-status | render-log <id> [--follow] | resume | clear-lane <id> | snapshot [--brief|--merge-queue] | plan [<snapshot.json>] | graph [file] | gate-deps | report [--ticket <n>] [--build <l>] | retro [--build <l>] [--vs <l>] | resolve-config | trust-check [--notify] [dir] | install-settings [--force] | notify <event> <title> <body> [url] | install --provider <id> [interval] | uninstall | agent-status | chain-merge" ;;
esac
