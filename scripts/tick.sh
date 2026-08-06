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
#                                single-writer merge lock for its lifetime
#   lane-status                  one line per lane: running | stale | dead
#   render-log <id> [--follow]   lane-<id>.jsonl stream → readable log, or stdout
#   retro [--build|--vs <l>]     capacity, rework, wait/work, critical chain
#                                (a lane calls this itself as it exits)
#   clear-lane <id>              forget a harvested lane (removes pid file)
#   snapshot                     the wave read set as one JSON document
#   graph [file]                 dependency shape of that snapshot: critical
#                                path, widest level, what can start now
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
# A tick that arrives while a wave holds the lock used to be discarded outright,
# and that is how build 2 ended: a gate exited at 23:36:03 during W13, the kick
# was dropped, and the loop never ran again — leaving a ticket in `merge-queue`,
# unmerged. The skipped tick now leaves this note instead, and the lock holder
# re-ticks once on its way out (P1). It is a single flag, not a queue, so a burst
# of finishing lanes costs one extra wave rather than one per lane.
PENDING_FILE="${LOOM_PENDING_FILE:-$LOOM_HOME/tick.pending}"
LANES_DIR="$LOOM_HOME/lanes"
LOGS_DIR="$LOOM_HOME/logs"
# Every session gets its own scratch directory here (P17). Fixed paths were the
# bug: a wave wrote /tmp/wave-note-16.md, a stale file of that name from an
# earlier wave won, and its content was posted as a comment on the wrong ticket.
SCRATCH_ROOT="$LOOM_HOME/scratch"
SCRATCH_KEEP_DAYS="${LOOM_SCRATCH_KEEP_DAYS:-7}"
NTFY_BASE="${NTFY_BASE:-https://ntfy.sh}"
NTFY_CMD="${NTFY_CMD:-curl}"
GLAB_CMD="${GLAB_CMD:-glab}"
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

mkdir -p "$LOOM_HOME" "$LANES_DIR" "$LOGS_DIR" "$SCRATCH_ROOT"

TRUST_FILE="${LOOM_TRUST_FILE:-$HOME/.claude.json}"

die() { echo "tick.sh: $*" >&2; exit 1; }

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
    case "$SCRATCH_ROOT" in ""|"/"|"$HOME") return 0 ;; esac
    [ -d "$SCRATCH_ROOT" ] || return 0
    find "$SCRATCH_ROOT" -mindepth 1 -maxdepth 1 -type d \
         -mtime +"$SCRATCH_KEEP_DAYS" -exec rm -rf {} + 2>/dev/null || true
}

# Worktree sweep — the build cleans up after itself, on the same trust model
# as _prune_scratch: deterministic plumbing with provable scope, approved by
# the human 2026-08-02. A candidate must be named exactly "<repo>-wt-<digits>"
# (this skill's own lane-worktree naming) AND either be a registered worktree
# of this repo whose branch is fully contained in origin/<base>, or an
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

cmd_sweep() {
    local base dir name branch st gd dir_p root_p
    # git always reports worktrees by their PHYSICAL path, so a REPO_ROOT
    # carrying a symlink (macOS /tmp -> private/tmp, /var -> private/var, or
    # any symlinked checkout) never matched below — and sweep silently swept
    # nothing, rc 0, no output. Same visible symptom as the pipefail crash,
    # different cause, so it has its own regression test.
    root_p=$(cd "$REPO_ROOT" 2>/dev/null && pwd -P) || root_p="$REPO_ROOT"
    base=$(_yaml_scalar "$CONFIG" base)
    if [ -n "$base" ]; then :
    elif git -C "$REPO_ROOT" show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then base=develop
    else base=main; fi
    git -C "$REPO_ROOT" fetch origin --quiet 2>/dev/null || true
    # cwd of every running lane — never sweep ground a live process stands on
    local live_cwds="" pid live_n=0
    for pid in $(cmd_lane_status 2>/dev/null | awk '$3=="running"{print $2}' || true); do
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
        return 0
    fi
    for dir in "$REPO_ROOT"-wt-*; do
        [ -e "$dir" ] || continue
        name="${dir##*-wt-}"
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
            if [ -n "$(git -C "$REPO_ROOT" log "origin/$base..$branch" --oneline 2>/dev/null | head -1)" ]; then
                continue                     # unmerged work — not ours to touch
            fi
            # `|| true` is load-bearing: under `set -euo pipefail`, a `grep -v`
            # that filters out every line exits 1, pipefail propagates it to the
            # assignment, and `set -e` killed the whole sweep silently with rc=1
            # before removing anything — including the `worktree prune` below.
            # Every merged worktree whose only leftovers were untracked files hit
            # this, i.e. the common case. (Paid for: build-1 2026-08-03 — sweep
            # had never once succeeded; a wave burned 80s under `bash -x` and
            # removed the worktree by hand.)
            st=$(git -C "$dir" status --porcelain 2>/dev/null | grep -v '^??' | head -1 || true)
            if [ -n "$st" ]; then
                echo "sweep: $dir merged but has modified tracked files — kept, needs a human"
                continue
            fi
            _sweep_env_backup "$dir"
            git -C "$REPO_ROOT" worktree remove --force "$dir_p" 2>/dev/null \
                || { echo "sweep: git refused to remove $dir — kept"; continue; }
            [ -d "$dir" ] && rm -rf "$dir"
            git -C "$REPO_ROOT" branch -d "$branch" >/dev/null 2>&1 || true
            echo "sweep: removed merged worktree $dir (branch $branch)"
        else
            gd=""
            [ -f "$dir/.git" ] && gd=$(sed -n 's/^gitdir: //p' "$dir/.git" 2>/dev/null)
            case "$gd" in
                "$REPO_ROOT/.git/worktrees/"*|"$root_p/.git/worktrees/"*)
                    [ -d "$gd" ] && continue # metadata still live — not a corpse
                    _sweep_env_backup "$dir"
                    rm -rf "$dir"
                    echo "sweep: removed orphaned worktree corpse $dir" ;;
                *) : ;;                      # not provably ours — never touch
            esac
        fi
    done
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
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
    closed=$(glab api "projects/:fullpath/issues?labels=$label&state=closed&per_page=100" 2>/dev/null) || return 1
    ms=$(glab api "projects/:fullpath/milestones?state=active&per_page=100" 2>/dev/null) || return 1
    printf '%s' "$closed" | jq -e --argjson ms "${ms:-[]}" '
        ([.[] | .milestone.title? // empty] | unique) as $mine
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
    if cmd_lane_status 2>/dev/null | awk '$3=="running"{f=1} END{exit !f}'; then
        echo active; return 0
    fi
    age=$(( $(date +%s) - $(_last_activity_ts) ))
    [ "$age" -lt "${LOOM_QUIET_SETTLE:-120}" ] && { echo active; return 0; }
    open=$(glab api "projects/:fullpath/issues?labels=$label&state=opened&per_page=100" 2>/dev/null) \
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

_notify_quiet() { # <state> — notify once per state change; activity re-arms
    local state="$1" sentinel="$LOOM_HOME/quiet.state" prev=""
    [ -f "$sentinel" ] && prev=$(cat "$sentinel" 2>/dev/null)
    # A failed read is not a state change and must not erase the memory of one.
    # Clearing the sentinel here re-arms whatever the build was already in, so
    # every network blip re-pushed the same "Build halted" banner — five of them
    # in one night, which is how the human noticed any of this. Say nothing,
    # remember nothing, wait for a firing that could actually see the board.
    [ "$state" = unreadable ] && return 0
    if [ "$state" = active ] || [ "$state" = unknown ]; then rm -f "$sentinel"; return 0; fi
    [ "$state" = "$prev" ] && return 0
    printf '%s\n' "$state" > "$sentinel"
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
    local bad="${1:-}" sentinel="$LOOM_HOME/trust.state" prev=""
    [ -f "$sentinel" ] && prev=$(cat "$sentinel" 2>/dev/null)
    if [ -z "$bad" ]; then rm -f "$sentinel"; return 0; fi
    [ "$bad" = "$prev" ] && return 0
    mkdir -p "$LOOM_HOME"
    printf '%s\n' "$bad" > "$sentinel"
    cmd_notify workspace_untrusted "Workspace not trusted — lanes will ignore the allowlist" \
        "$bad has not been trusted, so .claude/settings.json is ignored there and lane commands fall to the classifier. Run \`claude\` in it once and accept the trust prompt." >/dev/null 2>&1 || :
    return 0
}

# --- config readers (flat keys; ntfy block) -------------------------------
cfg() { # cfg <key> <default> — layered: repo > global > built-in (P22)
    local v
    v=$(_yaml_scalar "$CONFIG" "$1")
    [ -n "$v" ] || v=$(_yaml_scalar "$GLOBAL_CONFIG" "$1")
    printf '%s\n' "${v:-$2}"
}

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
lock_acquire() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        trap 'rm -rf "$LOCK_DIR"' EXIT
        return 0
    fi
    local owner
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        return 1                          # genuinely held — skip this tick
    fi
    rm -rf "$LOCK_DIR"                    # owner dead: break the stale lock
    lock_acquire
}

# Same rules, no EXIT trap: this lock outlives the process that takes it. It is
# reserved here, stamped with the LANE's pid once the lane exists, and released
# by the lane itself on exit. A lane killed outright leaves the directory
# behind, and the dead-owner check breaks it on the next attempt — the failure
# mode is one skipped merge, never two merges at once.
_merge_lock_reserve() { # → 0 reserved, 1 genuinely held
    if mkdir "$MERGE_LOCK_DIR" 2>/dev/null; then
        echo $$ > "$MERGE_LOCK_DIR/pid"; return 0
    fi
    local owner
    owner=$(cat "$MERGE_LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then return 1; fi
    rm -rf "$MERGE_LOCK_DIR"
    _merge_lock_reserve
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
    local owner
    owner=$(cat "$MERGE_LOCK_DIR/pid" 2>/dev/null || echo "")
    [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && printf '%s\n' "$owner"
    return 0
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

_is_claude_cmd() { case "${1%% *}" in claude|*/claude) return 0 ;; *) return 1 ;; esac; }

# Only ever consulted on a FAILED session. A `rate_limit_event` with status
# "allowed" appears in perfectly normal runs — treating one as a limit would
# stall a healthy build — so the failure is the trigger and the event only
# supplies the resume time.
_limit_reset_at() { # <jsonl> <log> <err> → epoch to resume after, or nothing
    local jsonl="$1" at=""
    shift
    # A limit must be named somewhere in what the session actually said.
    grep -qiE 'usage limit|session limit|rate limit|quota|limit reached|resets? (at|in) ' "$@" 2>/dev/null \
        || { [ -s "$jsonl" ] && grep -qiE '"(usage|rate)_limit|limit reached' "$jsonl" 2>/dev/null; } \
        || return 0
    if [ -s "$jsonl" ] && command -v jq >/dev/null 2>&1; then
        at=$(jq -r 'select(.type == "rate_limit_event") | .rate_limit_info.resetsAt // empty' \
                "$jsonl" 2>/dev/null | tail -1)
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
        ( "$SELF_PATH" tick --from-lane >>"$LOGS_DIR/self-trigger.log" 2>&1 & )
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

cmd_tick() {
    # Three callers, three contracts (see SKILL "one program, one switch"):
    #   tick            a human typed it — always runs one wave, ignores both
    #                   the switch and the gap. An explicit command is not
    #                   automatic continuation.
    #   tick --auto     the timer fired — respects the switch AND the gap.
    #   tick --from-lane a lane finished — respects the switch, ignores the
    #                   gap. A handoff is work already in progress, and making
    #                   it wait would idle the build for no reason.
    # A tick fired from a lane's epilogue inherits that lane's environment, but
    # the wave it launches is the scheduler, not a lane — and must not have its
    # own spawns read as chained handoffs.
    unset LOOM_LANE_ID
    local mode="manual"
    case "${1:-}" in
        --auto) mode="auto"; shift ;;
        --from-lane) mode="lane"; shift ;;
    esac
    # WATCH FIRST — before the lock, before every gate below. Nothing here
    # spends, and it must happen even on the firings that do nothing else.
    local quiet; quiet=$(_watch_pass)
    if [ "$mode" != manual ] && _loop_stopped; then
        echo "tick: the loop is stopped (\`/loom start\` resumes it) — watched, no wave"
        _ev tick_skipped reason loop_stopped
        return 0
    fi
    if [ "$mode" = auto ] && ! _wave_gap_ok; then
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
    # A manual or self-triggered loop with no launchd agent has no backstop:
    # when a wave fizzles, nothing ever fires again (build-1 2026-08-02 sat
    # stalled for hours after one bad wave). Warn every tick until it is armed.
    if ! "$LAUNCHCTL_CMD" print "gui/$(id -u)/$LOOM_LABEL" >/dev/null 2>&1; then
        echo "tick: warning — heartbeat agent not installed; if a wave fizzles the build stalls silently (arm it with /loom start)" >&2
    fi
    LOOM_SCRATCH=$(_new_scratch wave); export LOOM_SCRATCH
    # Sessions run under cfg permission_mode (see SKILL.md "Headless
    # permissions" and references/loom-config.md). Both values honor
    # the repo's allow/deny rules; the deny guardrails bind in every mode.
    # User-approved change 2026-08-02 after three dontAsk failures in one
    # morning; this machine's global config selects auto.
    local perm_mode; perm_mode="$(cfg permission_mode dontAsk)"
    # Model tiers for spawned sessions. Without an explicit --model, every
    # wave and lane inherits the human's saved interactive default — which on
    # 2026-08-02 was the top tier chosen for skill-repair work, silently
    # making every worker run at max cost. Empty = inherit, deliberately.
    local wave_model lane_model wm_flag="" lane_model_line=""
    wave_model="$(cfg wave_model "")"; lane_model="$(cfg lane_model "")"
    [ -n "$wave_model" ] && wm_flag=" --model $wave_model"
    [ -n "$lane_model" ] && lane_model_line=" --model $lane_model"
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
- FIRST action: run \"$SELF_PATH\" snapshot — it is the entire read step. Absence of .loom.yml is normal (config resolves from derived/global layers).
- Spawn every lane with: --permission-mode $perm_mode$lane_model_line
- Lanes make EVERY tracker write through the verb script $(dirname "$SELF_PATH")/lane.sh (verbs: claim, transition, note, mr-note, verdict, close, scratch; long bodies via stdin or --file; run it bare for usage). Merge lanes close tickets with 'lane.sh close <iid>' — it strips the state labels too.
- Long lane briefs travel as FILES: write the brief, then spawn-lane <id> --brief <file> --cwd <wt> -- claude -p @brief ... — spawn-lane copies it into the worktree and swaps @brief for a pointer prompt. Inline arguments over 1000 chars are refused. Never hand-roll glab mutations in a lane prompt: inline -m bodies are denied on length, and any \$VAR or \$(...) in a command defeats allowlist matching.
- You are headless: no human will ever read a question. If truly blocked, post a comment on the Build issue and exit. A wave that ends by asking questions is a failed wave."
    export LOOM_WAVE_PROMPT
    local wave_cmd="${LOOM_WAVE_CMD:-claude -p \"\$LOOM_WAVE_PROMPT\" --permission-mode $perm_mode$wm_flag}"
    local stem="wave-$(date +%Y%m%d-%H%M%S)" stream=0 fb="" rc=0
    if _is_claude_cmd "$wave_cmd"; then
        # The wave gets the same streaming treatment as a lane (P13): it is what
        # makes the usage-limit signal machine-readable, and it gives a crashed
        # wave a transcript instead of the 15 bytes P15 had to work from.
        case "$wave_cmd" in *--output-format*) ;; *) stream=1
            wave_cmd="$wave_cmd --output-format stream-json --verbose" ;; esac
        # Documented scope is "overloaded or not available" — see the note in
        # PROPOSALS_ARCHIVED.md P14. Wired because it is the right primitive
        # and costs nothing; the pause below does not lean on it working.
        if [ "$(cfg usage_limit pause_and_resume)" = "downshift_model" ]; then
            fb=$(cfg fallback_model sonnet)
            [ -n "$fb" ] && wave_cmd="$wave_cmd --fallback-model $fb"
        fi
    fi

    _run_wave "$stem" "$wave_cmd" "$stream" || rc=$?
    if [ "$rc" -eq 0 ]; then : > "$WAVE_FAILS"; return 0; fi

    # A usage limit is not a crash: retrying it immediately spends a session to
    # be told the same thing, which is exactly what the observed run did.
    local until_at
    until_at=$(_limit_reset_at "$LOGS_DIR/$stem.jsonl" "$LOGS_DIR/$stem.log" "$LOGS_DIR/$stem.err.log")
    if [ -n "$until_at" ]; then
        printf '%s\n' "$until_at" > "$USAGE_PAUSE"
        _ev usage_pause until "$until_at" source first
        echo "tick: usage limit hit — pausing until $(_stamp "$until_at")"
        cmd_notify usage_pause "Build paused — usage limit" \
            "No capacity until $(_stamp "$until_at"). The build resumes on the first tick after that." \
            >/dev/null 2>&1 || :
        return 0
    fi

    # P15: three wave logs in build 2 were exactly `Execution error`, 15 bytes,
    # and the wave simply set exit 1 and waited — a crashed LANE at least still
    # fired the next tick. One retry after a backoff covers the transient case;
    # what survives that is escalated to a human rather than silently repeated.
    echo "tick: wave failed (see $LOGS_DIR/$stem.err.log) — retrying once in ${RETRY_BACKOFF}s"
    sleep "$RETRY_BACKOFF"
    rc=0; _run_wave "$stem-retry" "$wave_cmd" "$stream" || rc=$?
    if [ "$rc" -eq 0 ]; then : > "$WAVE_FAILS"; return 0; fi

    # The retry needs the SAME limit check as the first attempt. Without it a
    # crash-then-limit sequence wrote no pause, exited nonzero and counted as a
    # crash — so every following tick burned a fresh session against the same
    # wall, which is exactly the behaviour P14 exists to stop.
    until_at=$(_limit_reset_at "$LOGS_DIR/$stem-retry.jsonl" \
                               "$LOGS_DIR/$stem-retry.log" "$LOGS_DIR/$stem-retry.err.log")
    if [ -n "$until_at" ]; then
        printf '%s\n' "$until_at" > "$USAGE_PAUSE"
        _ev usage_pause until "$until_at" source retry
        echo "tick: usage limit hit on the retry — pausing until $(_stamp "$until_at")"
        cmd_notify usage_pause "Build paused — usage limit" \
            "No capacity until $(_stamp "$until_at"). The build resumes on the first tick after that." \
            >/dev/null 2>&1 || :
        return 0
    fi

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
_run_wave() { # _run_wave <stem> <cmd> <stream?> → the wave's exit code
    local stem="$1" cmd="$2" stream="$3" rc=0 t0 retry=0
    t0=$(_now)
    case "$stem" in *-retry) retry=1 ;; esac
    _ev wave_start stem "$stem" retry "$retry"
    echo "tick: running wave (log: $LOGS_DIR/$stem.log)"
    if [ "$stream" -eq 1 ]; then
        ( cd "$REPO_ROOT" && eval "$cmd" ) >"$LOGS_DIR/$stem.jsonl" 2>"$LOGS_DIR/$stem.err.log" || rc=$?
        _render_stream "$LOGS_DIR/$stem.jsonl" "$LOGS_DIR/$stem.log"
    else
        ( cd "$REPO_ROOT" && eval "$cmd" ) >>"$LOGS_DIR/$stem.log" 2>"$LOGS_DIR/$stem.err.log" || rc=$?
    fi
    _ev wave_end stem "$stem" rc "$rc" secs "$(( $(_now) - t0 ))"
    return $rc
}

cmd_spawn_lane() {
    # Self-trigger is the DEFAULT (P2). It used to be opt-in, and a wave that
    # forgot the flag said so itself: "I spawned both without --on-done-tick… So
    # nothing advances on its own" — then the build sat 12m44s until a human
    # ticked it. A flag whose omission silently halts the build is the wrong
    # shape; `--no-tick` is the deliberate opt-out for a lane that must not
    # advance the loop. `--on-done-tick` is still accepted, now a no-op, so any
    # caller written against the old contract keeps working.
    local id="" on_done=1 cwd="" merge_lock=0 pregate="" brief=""
    # Accept the flags before OR after the id (order-tolerant), require a real
    # id, and fail LOUDLY on a missing id or command. A malformed spawn must
    # abort here, never produce a lane that reads as a normal dead one — that
    # silent-stall was the build-2 wave-1 bug.
    while [ $# -gt 0 ]; do
        case "$1" in
            --on-done-tick) on_done=1; shift ;;
            --no-tick) on_done=0; shift ;;
            --pregate) shift; [ $# -gt 0 ] || die "spawn-lane: --pregate needs a tier"
                       pregate="$1"; shift ;;
            --merge-lock) merge_lock=1; shift ;;
            --cwd) shift; [ $# -gt 0 ] || die "spawn-lane: --cwd needs a directory"
                   cwd="$1"; shift ;;
            --brief) shift; [ $# -gt 0 ] || die "spawn-lane: --brief needs a file"
                     brief="$1"; shift ;;
            --) shift; break ;;
            --*) die "spawn-lane: unknown flag '$1'" ;;
            *) if [ -z "$id" ]; then id="$1"; shift; else break; fi ;;
        esac
    done
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
    [ $# -gt 0 ] || die "spawn-lane: no command to run for lane '$id'"
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
    # Refuse the FIRST lane rather than the first merge (P30): the untrusted
    # path is usually the repo root, not this worktree, and nothing else looks
    # until a command finally needs the allowlist.
    local _bad=""
    if ! _bad=$(_trust_check_dir "$abs"); then
        _notify_trust "$_bad"
        die "spawn-lane: '$_bad' is not a trusted workspace, so a headless lane
  in '$abs' would ignore the repo allowlist and have nearly every command denied
  (P16, P30). Fix it once, by hand: run \`claude\` in '$_bad' and accept the
  trust prompt — trust cascades to every worktree beneath it. A script must
  never write that flag for you."
    fi
    _notify_trust ""
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
    if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
        die "spawn-lane: lane '$id' is already running as pid $_old — harvest or
  kill it first. Reusing a live lane id would overwrite its pid file and rotate
  its log away, losing the work in progress."
    fi
    # P28: long briefs travel as FILES, never inline prompt arguments — the
    # CLI/permission boundary mangles or denies them (8 dead impl-1 spawns in
    # four minutes, build-1 2026-08-01, before a wave hand-invented the brief
    # file). --brief copies the file into the lane's worktree and swaps the
    # literal `@brief` placeholder after -p for a one-line pointer prompt.
    local _brf=() _b=""
    if [ -n "$brief" ]; then
        [ -f "$brief" ] && [ -s "$brief" ] || die "spawn-lane: --brief '$brief' is not a readable, non-empty file"
        cp "$brief" "$abs/.lane-brief-$id.md" || die "spawn-lane: cannot copy brief into $abs"
        local _hit=0 _prev=""
        for _b in "$@"; do
            if [ "$_prev" = "-p" ] && [ "$_b" = "@brief" ]; then
                _brf+=("Read the file .lane-brief-$id.md in your working directory and execute it as your complete brief.")
                _hit=1
            else
                _brf+=("$_b")
            fi
            _prev="$_b"
        done
        [ "$_hit" -eq 1 ] || die "spawn-lane: --brief requires the command to carry '-p @brief' — the placeholder spawn-lane replaces with the pointer prompt"
        set -- "${_brf[@]}"
    fi
    # Refuse inline arguments near the boundary where they actually die. The
    # cap is 1000, not lower: the working short-prompt pattern runs 400–600
    # chars and has never been denied.
    local _maxlen="${LOOM_MAX_INLINE_ARG:-1000}"
    for _b in "$@"; do
        [ "${#_b}" -le "$_maxlen" ] || die "spawn-lane: an inline argument is ${#_b} chars (cap $_maxlen) —
  prompts this long die at the CLI/permission boundary (P28). Write the brief
  to a file and spawn with:  --brief <file> ... -- claude -p @brief ..."
    done
    local log="$LOGS_DIR/lane-$id.log" jsonl="$LOGS_DIR/lane-$id.jsonl" stream=0 _a=""
    # P13: liveness is judged by log mtime, and `claude -p` writes nothing until
    # it exits — so a healthy lane working past `heartbeat_stale_minutes` looks
    # silent, is classified wedged, and is killed with all its work. Streaming is
    # the only honest signal, because the session emits events as it works.
    # The stream lands in lane-<id>.jsonl (which `lane-status` reads for
    # liveness) and the readable transcript is rendered into lane-<id>.log when
    # the lane exits, so humans and waves keep reading plain text.
    # Injected here rather than asked of the caller: this is the same shape as
    # P2 — a flag whose omission silently breaks the loop must not be optional.
    # A command that only reaches claude indirectly (`bash -c "claude …"`) is not
    # detected, and does not need to be: SKILL.md spawns claude directly.
    case "$(basename "${1:-}")" in claude) stream=1 ;; esac
    # Two SEPARATE decisions, and conflating them cost a build day. `inject`
    # is "do I add the flags?" — no, if the caller already set
    # `--output-format`, or the lane would argue with itself over a flag set
    # on purpose. `stream` is "does stdout go to the .jsonl?" — which stays
    # YES whenever the output is a JSON stream, however it got that way.
    #
    # One variable meant both, so a wave that helpfully wrote out
    # `--output-format stream-json --verbose` itself (SKILL.md documents that
    # spawn-lane injects them, so writing them is a reasonable thing for a
    # wave to do) silently lost its stream file. That costs three things at
    # once, all of them quiet: `render-log --follow` tails a file that does
    # not exist, so the human's viewer pane stays blank; `_stamp_progress`
    # skips the lane, so staleness falls back to raw .log mtime — the weak
    # signal that counts any output as progress; and the exit epilogue never
    # renders, leaving the .log as raw JSON instead of a readable transcript.
    # (Paid for: build-3 2026-08-03 — probe-e4-realtime-mode ran 30 minutes
    # behind an empty pane. 4 of ~190 lanes hit it; the rare ones are the
    # long ones, which are exactly the ones somebody is watching.)
    local inject="$stream" fmt_next=0 fmt=""
    if [ "$stream" -eq 1 ]; then
        for _a in "$@"; do
            if [ "$fmt_next" -eq 1 ]; then fmt="$_a"; fmt_next=0; continue; fi
            case "$_a" in
                --output-format)   inject=0; fmt_next=1 ;;
                --output-format=*) inject=0; fmt="${_a#--output-format=}" ;;
            esac
        done
        # Only a stream-json format produces the line-per-event file every
        # reader here assumes. An explicit `--output-format json` emits one
        # blob at exit, which is the pre-P13 shape: no streaming liveness to
        # be had, so do not pretend otherwise by creating a stream file.
        [ "$inject" -eq 0 ] && [ "$fmt" != "stream-json" ] && stream=0
    fi
    # P31: record the model this lane actually runs on, read off the command
    # rather than asked for as a second flag — a self-reported model can differ
    # from the one spawned, the command line cannot. Empty means the lane
    # inherits the session default. Consumer: the ticker, so an escalation is
    # visibly taken ("#46 — implementation started (opus)"), and `retro`.
    local lane_model="" _mnext=0
    for _a in "$@"; do
        if [ "$_mnext" -eq 1 ]; then lane_model="$_a"; break; fi
        case "$_a" in
            --model)   _mnext=1 ;;
            --model=*) lane_model="${_a#--model=}"; break ;;
        esac
    done
    # Carry the loom's location to any child (the lane, and the
    # completion-triggered tick), so a self-trigger targets the right repo
    # even though the lane runs in a worktree cwd.
    export LOOM_REPO="$REPO_ROOT" LOOM_HOME="$LOOM_HOME"
    LOOM_SCRATCH=$(_new_scratch "lane-$id"); export LOOM_SCRATCH
    # Reserve the merge lock BEFORE spawning: a refusal must leave no lane and
    # no pid file behind, exactly like the other spawn guards.
    if [ "$merge_lock" -eq 1 ]; then
        _merge_lock_reserve || die "spawn-lane: merge lock held by pid $(_merge_lock_owner) — one merge at a time"
    fi

    # EVERYTHING DESTRUCTIVE HAPPENS BELOW THIS LINE, after the last guard that
    # can refuse. Rotating logs and clearing `<id>.rc` above the merge-lock
    # reservation meant a spawn that lost the lock had already destroyed the
    # previous run's transcript and exit code — harvest data for a lane that was
    # never replaced.
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
    rm -f "$LANES_DIR/$id.rc"
    # What the lane does after its command exits, in order: release the merge
    # lock first so the next merge can start, then fire the next wave.
    # Event-driven ticking means the loop advances at the speed of work, not a
    # fixed timer. A fire that lands during a running wave is no longer lost: it
    # leaves the pending note and that wave re-ticks once on exit (P1), so the
    # heartbeat is a true backstop for the initial kick and post-stall resume.
    # Render BEFORE the tick fires: the wave this lane wakes up reads lane logs
    # for verdicts and crash triage, and must not race the transcript.
    local epi="" redirect=""
    if [ "$stream" -eq 1 ]; then
        export LOOM_LANE_JSONL="$jsonl"
        redirect=' >"$LOOM_LANE_JSONL"'      # expanded inside the lane's shell
        # The redirect above is unconditional for a streaming lane; only the
        # FLAGS are conditional. A caller who already asked for stream-json
        # gets the stream file like everyone else — it just does not get the
        # flag twice.
        if [ "$inject" -eq 1 ]; then
            set -- "$@" --output-format stream-json --verbose
        fi
        # Lanes downshift on the same policy the wave does (P14) — a limit that
        # stops the scheduler stops the work it schedules just as hard. Skipped
        # when the caller set their own, for the same reason as the format.
        if [ "$(cfg usage_limit pause_and_resume)" = "downshift_model" ]; then
            local fb has_fb=0
            for _a in "$@"; do
                case "$_a" in --fallback-model|--fallback-model=*) has_fb=1; break ;; esac
            done
            fb=$(cfg fallback_model sonnet)
            if [ -n "$fb" ] && [ "$has_fb" -eq 0 ]; then
                set -- "$@" --fallback-model "$fb"
            fi
        fi
        epi="'$SELF_PATH' render-log '$id'; "
    fi
    [ "$merge_lock" -eq 1 ] && epi="$epi rm -rf '$MERGE_LOCK_DIR'; "
    [ "$on_done" -eq 1 ] && epi="$epi( '$SELF_PATH' tick --from-lane >>'$LOGS_DIR/self-trigger.log' 2>&1 & ); "
    # The exit code is recorded FIRST, before the tick fires, or the wave this
    # lane wakes would race the file it needs to read. It is how a wave tells a
    # mechanical gate failure (7) from a crashed session (anything else), which
    # is what makes the pregate below actionable.
    # The lane records its own exit — it is the only thing that knows the code
    # and the moment. `$LANES_DIR/<id>.start` carries the spawn time so the
    # duration is measured, not inferred from file mtimes the way build 2's was.
    # The event goes immediately after the rc write, BEFORE render-log: the
    # transcript render takes seconds, and stamping the exit after it pushed
    # `lane_exit` well past the chained successor's `lane_spawn` — a 17s skew
    # the ticker rendered as "gate started, then implementation ended"
    # (observed by the human, 2026-08-02).
    epi="printf '%s\\n' \"\$_rc\" > '$LANES_DIR/$id.rc'; '$SELF_PATH' event lane_exit id '$id' type '$(_lane_type "$id")' rc \"\$_rc\" secs \"\$(( \$(date +%s) - \$(cat '$LANES_DIR/$id.start' 2>/dev/null || date +%s) ))\" >/dev/null 2>&1 || true; $epi"

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
    local pre="" runner tiers
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
        pre='if [ -f "$LOOM_PREGATE_RUNNER" ]; then'
        pre="$pre"' echo "--- pregate: $LOOM_PREGATE_RUNNER $LOOM_PREGATE_TIER ---";'
        pre="$pre"' if ! bash "$LOOM_PREGATE_RUNNER" "$LOOM_PREGATE_TIER"; then'
        pre="$pre"' echo "--- pregate FAILED — rejecting with no review session (P12) ---"; _rc=7; fi;'
        pre="$pre"' else echo "--- pregate: no $LOOM_PREGATE_RUNNER here, skipping ---"; fi; '
    fi
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
    local stamp=""
    [ "$merge_lock" -eq 1 ] && stamp="printf '%s\\n' \$\$ > '$MERGE_LOCK_DIR/pid'; "
    ( cd "$dir" && exec nohup bash -c \
        '_rc=0; '"$stamp$pre"'if [ "$_rc" -eq 0 ]; then "$@"'"$redirect"'; _rc=$?; fi; '"$epi"' exit $_rc' \
        _lane "$@" ) >>"$log" 2>&1 &
    echo $! > "$LANES_DIR/$id.pid"
    _now > "$LANES_DIR/$id.start"
    _ev lane_spawn id "$id" type "$(_lane_type "$id")" \
        pregate "${pregate:-}" merge_lock "$merge_lock" model "$lane_model" log "$log"
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
_lane_type() { # <id> → impl | gate | probe | merge, or fails
    case "$1" in
        impl-[0-9]*)          echo impl  ;;
        gate-[0-9]*)          echo gate  ;;
        merge-[0-9]*)         echo merge ;;
        probe-[A-Za-z0-9]*)   echo probe ;;
        *) return 1 ;;
    esac
}

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
RENDER_JQ='
        select(.type == "assistant" or .type == "result"
               or (.type == "system" and (.subtype // "") == "init"))
        | if .type == "system" then
              "── model \(.model // "?") · permission \(.permissionMode // "?") ──"
          elif .type == "result" then
              (if (.is_error // false) or ((.subtype // "success") != "success")
               then "\n[lane failed: \(.subtype // "error")] \(.result // "")"
               else empty end)
          else
              (.message.content[]?
               | if .type == "text" then .text
                 elif .type == "tool_use" then
                     "  $ \(.name): \(((.input.command // .input.file_path // .input.pattern // "") | tostring)[0:200])"
                 else empty end)
          end'

_render_stream() { # _render_stream <jsonl> <log>
    local jsonl="$1" log="$2" tmp
    [ -s "$jsonl" ] || return 0
    if ! command -v jq >/dev/null 2>&1; then cat "$jsonl" >> "$log"; return 0; fi
    tmp="$jsonl.render"
    # A killed lane leaves a half-written final line, so jq's exit code is
    # ignored and the partial render is used when there is one.
    jq -r "$RENDER_JQ" "$jsonl" > "$tmp" 2>/dev/null || :
    if [ -s "$tmp" ]; then cat "$tmp" >> "$log"; else cat "$jsonl" >> "$log"; fi
    rm -f "$tmp"
    return 0
}

# Render new events to STDOUT as they arrive, and stop when the lane is gone.
# Read-only by construction, which is what makes it safe to run several at once
# against one lane: it never touches lane-<id>.log (the exit epilogue owns that
# file, and a follower appending to it would corrupt the artifact it is
# watching), takes no lock, writes no pid file and records no event (P24).
_follow_stream() { # _follow_stream <id>
    local id="$1"
    local jsonl="$LOGS_DIR/lane-$id.jsonl" pidfile="$LANES_DIR/$id.pid"
    local n=0 total pid gone=0
    command -v jq >/dev/null 2>&1 || die "render-log --follow: jq is required"
    [ -e "$pidfile" ] || [ -s "$jsonl" ] \
        || die "render-log --follow: no lane '$id' — nothing at $jsonl"
    printf -- '── lane %s ──\n' "$id"
    while :; do
        if [ -s "$jsonl" ]; then
            total=$(wc -l < "$jsonl" | tr -d ' ')
            if [ "$total" -gt "$n" ]; then
                sed -n "$((n + 1)),${total}p" "$jsonl" | jq -r "$RENDER_JQ" 2>/dev/null || :
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
    # strflocaltime falls back to the UTC stamp rather than dying.
    local when='((.ts // 0) | strflocaltime("%m-%d %H:%M:%S"))'
    jq -ne '0 | strflocaltime("%H")' >/dev/null 2>&1 || when='(.t // "")'
    # Failure lines wear a glyph always and color on a terminal (asked for by
    # the human, 2026-08-02: red/gate-fail and merge-conflict lines must stand
    # out in the strip). Glyphs are plain text so greps and tests see the same
    # bytes everywhere; color is auto on a tty, forced with LOOM_COLOR=1|0.
    local bad="" warn="" good="" rst=""
    local want_color="${LOOM_COLOR:-auto}"
    if [ "$want_color" = 1 ] || { [ "$want_color" = auto ] && [ -t 1 ]; }; then
        bad=$'\033[1;31m'; warn=$'\033[1;33m'; good=$'\033[1;32m'; rst=$'\033[0m'
    fi
    local prog='
def ref: if test("^[0-9]+$") then "#\(.)" else . end;
def stage($id):
  if   ($id | startswith("impl-"))  then {t: ($id | ltrimstr("impl-")  | ref), s: "implementation"}
  elif ($id | startswith("gate-"))  then {t: ($id | ltrimstr("gate-")  | sub("-r[0-9]+$"; "") | ref), s: "gate review"}
  elif ($id | startswith("merge-")) then {t: ($id | ltrimstr("merge-") | ref), s: "merge"}
  elif ($id | startswith("probe-")) then {t: "epic \($id | ltrimstr("probe-"))", s: "acceptance probe"}
  else {t: $id, s: "lane"} end;
def round($id): (($id | capture("-r(?<n>[0-9]+)$") | " (round \(.n))") // "");
# P31: an escalation the human asked for must be visibly taken. Empty model
# (the lane inherits the session default) renders nothing — the common case
# should stay quiet.
def model($e): (if ($e.model // "") == "" then "" else " (\($e.model))" end);
fromjson? // empty | . as $e
| (if $e.ev == "snapshot" then empty else . end)
| (
  if   $e.ev == "wave_start" then "wave started"
  elif $e.ev == "wave_end"  then
    (if ($e.rc | tostring) == "0" then "wave ended (rc \($e.rc), \($e.secs)s)"
     else $bad + "✗ wave ended (rc \($e.rc), \($e.secs)s)" + $rst end)
  elif $e.ev == "lane_spawn" then (stage($e.id) | "\(.t) — \(.s) started") + round($e.id) + model($e)
  elif $e.ev == "lane_exit" then
    # A clean exit is suppressed (except probes): its story is already told by
    # its outcome event (→ review / verdict / closed), and chained handoffs
    # stamp it after the successor spawned — rendered, that read backwards
    # ("gate started, then implementation ended"; human, 2026-08-02).
    stage($e.id) as $s
    | if ($e.rc | tostring) == "7"
      then $bad + "✗ \($s.t) — pregate REJECTED the branch (no review session spent)" + $rst
      elif ($e.rc | tostring) == "0" and (($e.id | startswith("probe-")) | not)
      then empty
      elif ($e.rc | tostring) == "0"
      then "\($s.t) — \($s.s) ended (rc \($e.rc), \($e.secs)s)"
      else $bad + "✗ \($s.t) — \($s.s) ended (rc \($e.rc), \($e.secs)s)" + $rst end
  elif $e.ev == "lane_kill" then
    stage($e.id) as $s | $warn + "⚠ \($s.t) — \($s.s) killed (whole tree)" + $rst
  elif $e.ev == "ticket_claim" then "#\($e.ticket) claimed — implementation begins"
  elif $e.ev == "ticket_transition" then
    (({"review": " (implementation complete, awaiting gate)",
       "merge-queue": " (gate passed)",
       "blocked": " — a human decision is needed",
       "ready-for-agent": " (requeued, unassigned)"} | .[$e.state]) // "") as $gloss
    | (if $e.state == "blocked"
       then $warn + "⚠ #\($e.ticket) → \($e.state)\($gloss)" + $rst
       else "#\($e.ticket) → \($e.state)\($gloss)" end)
  elif $e.ev == "gate_verdict" then
    (if $e.verdict == "PASS" then $good + "✓ " else $bad + "✗ " end)
    + "#\($e.ticket) gate verdict: \($e.verdict) @ \($e.sha | tostring | .[0:8])" + $rst
  elif $e.ev == "ticket_close" then "#\($e.ticket) merged and closed"
  elif $e.ev == "probe_result" then
    (if $e.result == "PASS"
     then $good + "✓ epic \($e.epic) — acceptance probe PASSED" + $rst
     else $bad + "✗ epic \($e.epic) — acceptance probe FAILED (fix tickets filed)" + $rst end)
  elif $e.ev == "usage_pause" then "usage limit — paused (until \($e.until))"
  elif $e.ev == "usage_resume" then "usage limit cleared — resuming"
  # Three unrelated outcomes shared one sentence (P42). Harmless while the
  # timer was a 15-minute backstop and a skip nearly always meant lock_held;
  # the merged 60s scheduler watches on every firing and spends on the gap, so
  # wave_gap became the routine outcome and printed an exceptional-case line
  # nine ticks in ten. Of 408 such lines in one day, 253 were wave_gap and
  # false: that path writes no pending file and no replay follows it. So
  # wave_gap stays in events.jsonl for retro and never reaches the ticker,
  # lock_held renders once per wave on the tick that raised the flag, and
  # loop_stopped keeps a line of its own because it is rare and specific.
  # (No apostrophes in this comment: the whole program is a single-quoted
  # shell string, and one would end it mid-word.)
  elif $e.ev == "tick_skipped" then
    (if $e.reason == "loop_stopped" then "the loop is stopped — this tick did nothing"
     elif $e.reason == "lock_held" then
       # Events written before P42 carry no "first" field; render those, so
       # replaying an old log still reads the way it did.
       (if (($e.first // "1") | tostring) == "1"
        then "a tick landed during a wave — the wave will re-tick on exit"
        else empty end)
     else empty end)
  elif $e.ev == "tick_replayed" then "pending tick replayed"
  # The renderer owns the "wave:" prefix, so a note that writes its own gets
  # it stripped rather than doubled ("wave: wave: only #47 is ready" —
  # observed by the human, 2026-08-03). A wave author naturally types the
  # prefix; deduping it here is plumbing, and cheaper than a rule telling
  # every wave not to.
  elif $e.ev == "wave_note" then
    "wave: " + (($e.note // "") | sub("(?i)^\\s*wave\\s*:\\s*"; ""))
  elif $e.ev == "viewer_note" then "viewer: \($e.note // "")"
  elif $e.ev == "notify" then
    (if (($e.event // "") | test("complete")) then $good else $warn end)
    + "⚑ \($e.title // $e.event)" + $rst
  else ([$e | del(.t, .ts, .ev, .build) | to_entries[] | "\(.key)=\(.value | tostring)"] | join(" ")) as $kv
       | "\($e.ev)\(if $kv == "" then "" else " " + $kv end)"
  end
) as $line
| "\('"$when"')  \($line)"'
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
        tail -n 100 -F "$EVENTS" 2>/dev/null | jq -R --unbuffered -r \
            --arg bad "$bad" --arg warn "$warn" --arg good "$good" --arg rst "$rst" \
            "$prog" &   # render-events: display-only reader
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
        jq -R -r --arg bad "$bad" --arg warn "$warn" --arg good "$good" --arg rst "$rst" \
            "$prog" < "$EVENTS"   # render-events: display-only reader
    fi
}

# P55: dollar cost of one session log, priced by each assistant message's own
# model off `message.usage`. Source: claude-api skill pricing cache, read
# 2026-08-06 — $/MTok, cache write assumed at the 5m ephemeral default (the
# harness never requests a 1h breakpoint). Re-derive this table whenever
# pricing changes; nothing else in the skill depends on the literal numbers.
USAGE_JQ='
  def price_table:
    { "haiku-4-5": {input: 1.00,  output: 5.00,  cache_write: 1.25,  cache_read: 0.10},
      "sonnet-5":  {input: 3.00,  output: 15.00, cache_write: 3.75,  cache_read: 0.30},
      "opus-5":    {input: 5.00,  output: 25.00, cache_write: 6.25,  cache_read: 0.50},
      "fable-5":   {input: 10.00, output: 50.00, cache_write: 12.50, cache_read: 1.00} };
  # An unrecognised or missing model prices at zero rather than guessing —
  # a silently wrong non-zero number is worse than a visible gap.
  def price_for($model):
    (price_table | to_entries | map(select(.key as $k | $model | test($k))) | first | .value)
    // {input: 0, output: 0, cache_write: 0, cache_read: 0};
  def usage_cost($u; $model):
    price_for($model) as $p
    | ( ($u.input_tokens // 0) * $p.input
      + ($u.output_tokens // 0) * $p.output
      + (($u.cache_creation_input_tokens //
          (($u.cache_creation.ephemeral_5m_input_tokens // 0)
           + ($u.cache_creation.ephemeral_1h_input_tokens // 0))) // 0) * $p.cache_write
      + ($u.cache_read_input_tokens // 0) * $p.cache_read
      ) / 1000000;
  split("\n") | map(select(length > 0))
  | map(try fromjson catch empty) | map(select(. != null))
  | map(select(.type == "assistant") | .message | select(.usage != null))
  | map(usage_cost(.usage; (.model // "")))
  | add // 0
'
_lane_cost() { # _lane_cost <jsonl-file> -> USD spent by that session, "0" if unreadable
    [ -f "$1" ] || { echo 0; return; }
    jq -R -s "$USAGE_JQ" < "$1" 2>/dev/null || echo 0
}

# P55: every lane log this repo has ever kept — `clear-lane` never removes the
# jsonl, only the pid/rc/progress state — so `retro` can price a build any
# time after the fact. One entry per lane id; `retro` filters to its own
# build by joining against `lane_exit` events, which are already build-scoped.
_spend_by_lane() { # -> JSON array [{id, cost}, ...]
    local f id
    for f in "$LOGS_DIR"/lane-*.jsonl; do
        [ -f "$f" ] || continue
        id=$(basename "$f" .jsonl); id=${id#lane-}
        printf '{"id":%s,"cost":%s}\n' "$(printf '%s' "$id" | jq -R .)" "$(_lane_cost "$f")"
    done | jq -s '.'
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
        # the filtered event count grows; when present it IS the clock.
        [ -f "$LANES_DIR/$id.progress" ] && log="$LANES_DIR/$id.progress"
        if ! kill -0 "$pid" 2>/dev/null; then
            state="dead"
        elif [ -f "$log" ] && [ -n "$(find "$log" -mmin +"$stale_min" 2>/dev/null)" ]; then
            state="stale"                 # alive but silent past the window —
        else                              # never an elapsed-total-time check
            state="running"
        fi
        # New columns go on the END: existing readers index state at $3, type
        # at $4. `rc` is `-` until the lane exits; 7 means its pregate rejected
        # the branch before any review session ran (P12). `turns` (P52) is the
        # same filtered event count `.progress` already stamps for staleness —
        # a spend signal, not a liveness one — `-` when no stamp exists yet.
        # `cost` (P55) is priced straight off the session log's own
        # `message.usage`, so a running build shows spend next to progress.
        echo "$id $pid $state $(_lane_type "$id" || echo unknown) $(cat "$LANES_DIR/$id.rc" 2>/dev/null || echo -) $(cat "$LANES_DIR/$id.progress" 2>/dev/null || echo -) $(_lane_cost "$LOGS_DIR/lane-$id.jsonl")"
    done
}

cmd_clear_lane() {
    rm -f "$LANES_DIR/$1.pid" "$LANES_DIR/$1.rc" "$LANES_DIR/$1.start" \
          "$LANES_DIR/$1.progress" "$LANES_DIR/$1.stale-notified"
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
    local pid; pid=$(cat "$LANES_DIR/$id.pid" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        _kill_tree "$pid"
        _ev lane_kill id "$id"
    fi
    cmd_clear_lane "$id"
}

cmd_notify() {
    local event="$1" title="$2" body="$3" click="${4:-}"
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
_snap_api() {  # _snap_api <out> <path> <what>
    local out="$1" path="$2" what="$3"
    if ! "$GLAB_CMD" api "$path" > "$out" 2>"$out.err"; then
        printf '[]\n' > "$out"
        _snap_warn "degraded: $what — $(head -1 "$out.err" 2>/dev/null | tr -d '\n')"
    elif ! jq -e 'type == "array"' "$out" >/dev/null 2>&1; then
        printf '[]\n' > "$out"
        _snap_warn "degraded: $what — non-array response"
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
    local brief=false
    case "${1:-}" in --brief) brief=true; shift ;; esac
    command -v jq >/dev/null 2>&1 || die "snapshot: jq required"
    # The document builder lives in snapshot.jq beside this script. Say so
    # here: without the check jq fails deep in stage 3 with its own message
    # about an unreadable -f argument, and the wave reads that as a tracker
    # problem rather than a missing file.
    SNAP_JQ="$(dirname "$SELF_PATH")/snapshot.jq"
    [ -f "$SNAP_JQ" ] || die "snapshot: $SNAP_JQ is missing — it holds the document builder and ships beside tick.sh"
    command -v "$GLAB_CMD" >/dev/null 2>&1 || die "snapshot: '$GLAB_CMD' not found"
    # glab api's projects/:id shorthand resolves from the cwd's git remote,
    # and a wave may invoke this from a lane worktree — never assume cwd.
    cd "$REPO_ROOT" || die "snapshot: cannot cd to $REPO_ROOT"
    SNAP_TMP=$(mktemp -d)
    # Safe only because cmd_tick never calls cmd_snapshot: an EXIT trap here
    # would clobber the lock's. The wave invokes `tick.sh snapshot` itself.
    trap 'rm -rf "$SNAP_TMP"' EXIT
    : > "$SNAP_TMP/warn.txt"; : > "$SNAP_TMP/lanes.txt"; printf '[]\n' > "$SNAP_TMP/notes.json"
    SNAP_JOBS=0

    # -- Stage 1: ONE call. Titles, iids, labels, assignees, milestone/epic
    # AND descriptions — so build discovery, membership, `## Blocked by`
    # parsing, tier and the epic rollup are all derived locally from here.
    # Foundational, so a failure DIES: an empty ticket list from a failed
    # call reads exactly like a genuinely empty build, and launching a wave
    # on a garbage universe is how you get ghost gates.
    "$GLAB_CMD" api --paginate "projects/:id/issues?state=opened&per_page=100" \
        > "$SNAP_TMP/raw.json" 2>"$SNAP_TMP/raw.err" \
        || die "snapshot: open-issue list failed — $(head -2 "$SNAP_TMP/raw.err" | tr '\n' ' ')"
    # --paginate may emit one array per page; fold them into one array.
    jq -s 'map(if type == "array" then . else [.] end) | add' "$SNAP_TMP/raw.json" \
        > "$SNAP_TMP/open.json" 2>/dev/null \
        || die "snapshot: open-issue list was not JSON"

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
    ( "$GLAB_CMD" api --paginate "projects/:id/milestones?per_page=100" \
        > "$SNAP_TMP/ms.raw" 2>/dev/null \
      && jq -s 'map(if type == "array" then . else [.] end) | add
                | map({title, state, description})' "$SNAP_TMP/ms.raw" \
         > "$SNAP_TMP/ms.json" 2>/dev/null \
      && mv "$SNAP_TMP/ms.json" "$SNAP_TMP/milestones.json" ) &

    local build_iid="" label="" nbuild
    nbuild=$(jq '[.[] | select((.title // "") | test("^Build [0-9]+$"))] | length' "$SNAP_TMP/open.json")
    if [ "$nbuild" -ge 1 ]; then
        build_iid=$(jq -r '[.[] | select((.title // "") | test("^Build [0-9]+$"))]
                           | sort_by(.iid) | last | .iid' "$SNAP_TMP/open.json")
        label="build-$(jq -r --argjson b "$build_iid" \
            '.[] | select(.iid == $b) | .title | capture("(?<n>[0-9]+)$").n' "$SNAP_TMP/open.json")"
        if [ "$nbuild" -gt 1 ]; then
            _snap_warn "$nbuild open \`Build N\` issues — took the highest (#$build_iid)"
        fi
    else
        # An empty universe is VALID (build complete, or not yet started):
        # emit a null-build document so a heartbeat wave no-ops cleanly.
        # Only tool or call failure dies.
        _snap_warn "no open \`Build N\` issue — empty universe"
    fi

    local member_iids="" active_iids="" review_iids="" iid
    if [ -n "$label" ]; then
        member_iids=$(jq -r --arg l "$label" \
            '.[] | select((.labels // []) | index($l)) | .iid' "$SNAP_TMP/open.json")
        # MRs exist only once work has started: a ready-for-agent ticket has
        # none by definition, so fetching one is waste.
        active_iids=$(jq -r --arg l "$label" \
            '.[] | select((.labels // []) | index($l))
                 | select((.labels // []) | (index("in-progress") or index("review") or index("merge-queue")))
                 | .iid' "$SNAP_TMP/open.json")
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

    # -- Stage 2: concurrent fan-out. Wall clock is the slowest single call.
    for iid in $member_iids; do
        ( _snap_api "$SNAP_TMP/links-$iid.json" \
            "projects/:id/issues/$iid/links?per_page=100" "issue #$iid links" ) &
        _snap_batch_gate
    done
    for iid in $active_iids; do
        ( _snap_api "$SNAP_TMP/mrs-$iid.json" \
            "projects/:id/issues/$iid/related_merge_requests?per_page=100" "issue #$iid merge requests" ) &
        _snap_batch_gate
    done
    for iid in $review_iids; do
        ( _snap_api "$SNAP_TMP/tnotes-$iid.json" \
            "projects/:id/issues/$iid/notes?sort=desc&order_by=created_at&per_page=30" \
            "issue #$iid comments" ) &
        _snap_batch_gate
    done
    if [ -n "$build_iid" ]; then
        ( _snap_api "$SNAP_TMP/notes.json" \
            "projects/:id/issues/$build_iid/notes?sort=desc&order_by=created_at&per_page=20" \
            "build lessons thread" ) &
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
        ( _snap_api "$SNAP_TMP/closed.json" \
            "projects/:id/issues?labels=$label&state=closed&per_page=100" \
            "closed build members" ) &
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
        --arg lane_model "$(cfg lane_model '')" --arg rework_model "$(cfg rework_model '')" \
        '{ max_lanes: ($max_lanes | tonumber? // $max_lanes),
           max_aux_lanes: ($max_aux | tonumber? // $max_aux),
           rejection_cap: ($rejection_cap | tonumber? // $rejection_cap),
           crash_cap: ($crash_cap | tonumber? // $crash_cap),
           merge_attempt_cap: ($merge_attempt_cap | tonumber? // $merge_attempt_cap),
           lane_turn_cap: ($lane_turn_cap | tonumber? // $lane_turn_cap),
           heartbeat_stale_minutes: ($stale | tonumber? // $stale),
           lane_model: (if $lane_model == "" then null else $lane_model end),
           rework_model: (if $rework_model == "" then null else $rework_model end),
           base: (if $base == "" then null else $base end) }')

    # -- Stage 3: assemble. Every derived field is a pure function of fields
    # already in this document — nothing independently sourced.
    jq -n > "$SNAP_TMP/snapshot.json" \
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
            tickets "$(jq -c '[.tickets[] | {(.iid | tostring): (.state // "none")}]
                              | add // {}' "$SNAP_TMP/snapshot.json")" \
            deps "$(jq -c '[.tickets[] | {(.iid | tostring):
                              [(.blocked_by // [])[] | .iid]}] | add // {}' \
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

# --- report (P23): what the events add up to ------------------------------
# Two views over one file, because "tune the loop" and "diagnose this build"
# want the same events shaped differently. Neither reads anything but
# events.jsonl, so a report costs no tracker calls and works long after a build
# is over.
REPORT_JQ='
  def hms($s): ($s // 0) as $x
    | if $x >= 3600 then "\($x / 3600 | floor)h\(($x % 3600) / 60 | floor)m"
      elif $x >= 60 then "\($x / 60 | floor)m\($x % 60)s" else "\($x)s" end;
  def pct($n; $d): if ($d // 0) == 0 then "  -  "
                   else "\(($n * 1000 / $d | round) / 10)%" end;
  ($build_want) as $bw
  | map(select($bw == "" or .build == $bw)) as $evs
  | if ($evs | length) == 0 then "no events recorded\($bw | if . == "" then "" else " for \(.)" end)"
    else
  ($evs | map(.build) | map(select(. != null)) | last // "(unlabelled)") as $blabel
  | ($evs | map(.ts) | min) as $t0 | ($evs | map(.ts) | max) as $t1
  | ($t1 - $t0) as $span
  | ($evs | map(select(.ev == "wave_end"))) as $waves
  | ($evs | map(select(.ev == "lane_exit"))) as $lanes
  | ($waves | map(.secs) | add // 0) as $wave_secs
  | ($lanes | map(.secs) | add // 0) as $lane_secs
  # Blackout: each pause runs to its own resume, or to the last event if the
  # build never resumed. Counted from the events, not from the clock.
  | ([$evs | to_entries[] | select(.value.ev == "usage_pause")
      | .key as $i | .value.ts as $pt
      | (($evs[$i+1:] | map(select(.ev == "usage_resume")) | first | .ts) // $t1) - $pt]
     | add // 0) as $black
  # Peak concurrency by sweep: +1 on spawn, -1 on exit, ordered by time.
  | ([$evs | map(select(.ev == "lane_spawn" or .ev == "lane_exit"))
      | sort_by(.ts)[] | if .ev == "lane_spawn" then 1 else -1 end]
     | reduce .[] as $d ({n: 0, peak: 0};
         (.n + $d) as $x | {n: $x, peak: (if $x > .peak then $x else .peak end)})
     | .peak) as $peak
  | ($evs | map(select(.ev == "snapshot"))) as $snaps
  | (($snaps | first | .tickets | keys?) // []) as $first_ids
  | (($snaps | last  | .tickets | keys?) // []) as $last_ids
  | ($first_ids | map(select(. as $i | ($last_ids | index($i)) == null)) | length) as $closed
  | [ "Build \($blabel)   span \(hms($span))   \($closed) ticket(s) closed",
      "",
      "  inside waves   \(hms($wave_secs))   \(pct($wave_secs; $span))   \($waves | length) wave(s), \($waves | map(select(.rc != 0)) | length) failed, \($evs | map(select(.ev == "wave_start" and .retry == 1)) | length) retried",
      "  lane-seconds   \(hms($lane_secs))   \(pct($lane_secs; $span))   \($lanes | length) lane(s), peak \($peak) concurrent",
      "  usage blackout \(hms($black))   \(pct($black; $span))   \($evs | map(select(.ev == "usage_pause")) | length) pause(s)",
      "",
      "  lanes by type  " + (if ($lanes | length) == 0 then "none"
                             else ($lanes | group_by(.type)
                                   | map("\(.[0].type // "?")=\(length)") | join("  ")) end),
      "  mechanical rejections (rc 7)   \($lanes | map(select(.rc == 7)) | length)",
      "  crashed lanes (rc not 0 or 7)  \($lanes | map(select(.rc != 0 and .rc != 7)) | length)",
      "  ticks skipped mid-wave \($evs | map(select(.ev == "tick_skipped")) | length), replayed \($evs | map(select(.ev == "tick_replayed")) | length)"
    ] | join("\n")
    end
'

# Per-ticket forensics: every lane that touched it, and the states it passed
# through, with the log path to read next.
REPORT_TICKET_JQ='
  ($iid) as $n
  | (map(select(.ev == "lane_spawn" or .ev == "lane_exit"))
     | map(select(.id | test("^(impl|gate|merge)-\($n)(-|$)")))) as $ls
  | (map(select(.ev == "snapshot"))
     | map({ts, t, state: (.tickets[$n] // null)})
     | map(select(.state != null))) as $st
  | if ($ls | length) == 0 and ($st | length) == 0
    then "ticket #\($n): nothing recorded"
    else
  ["ticket #\($n)", ""]
  + (if ($st | length) > 0 then
       ["  states:"] + ([$st[0]] + [$st[1:][] as $x | $x] | . as $all
        | [range(0; ($all | length)) | select(. == 0 or ($all[.].state != $all[.-1].state))
           | "    \($all[.].t)  \($all[.].state)"])
     else [] end)
  + (if ($ls | length) > 0 then
       ["", "  lanes:"]
       + ([$ls | group_by(.id)[]
           | (map(select(.ev == "lane_spawn")) | first) as $s
           | (map(select(.ev == "lane_exit")) | last) as $e
           | "    \($s.id // $e.id)  " +
             (if $e == null then "still running" else "\($e.secs)s  rc \($e.rc)" end) +
             (if $e.rc == 7 then "  (pregate rejection — no review session spent)" else "" end) +
             # P31: which model the round ran on, so an escalation can be
             # priced against its outcome (does the stronger tier actually
             # clear a ticket the base tier failed?). Blank = session default.
             (if ($s.model // "") == "" then "" else "  on \($s.model)" end) +
             "  \($s.log // "")"])
     else [] end)
  | join("\n") end
'

# Retro: the four things `report` deliberately does not compute, because each
# needs the snapshot record rather than the wave/lane totals (P26). Everything
# here is arithmetic over events — no interpretation, which is the verb's job.
RETRO_JQ='
  def hms($s): ($s // 0) as $x
    | if $x >= 3600 then "\($x / 3600 | floor)h\(($x % 3600) / 60 | floor)m"
      elif $x >= 60 then "\($x / 60 | floor)m\($x % 60)s" else "\($x)s" end;
  def pct($n; $d): if ($d // 0) == 0 then "  -  "
                   else "\(($n * 1000 / $d | round) / 10)%" end;
  def usd($n): "$\(($n * 100 | round) / 100)";
  # Seconds of [$a,$b) that fall inside any window in $ws.
  def ov($a; $b; $ws): [$ws[] | (([$b, .b] | min) - ([$a, .a] | max)) | select(. > 0)]
                       | add // 0;
  ($build_want) as $bw
  | map(select($bw == "" or .build == $bw)) as $evs
  | if ($evs | length) == 0
    then "no events recorded\($bw | if . == "" then "" else " for \(.)" end)"
    else
  ($evs | map(.ts) | min) as $t0 | ($evs | map(.ts) | max) as $t1
  | ($evs | map(select(.ev == "snapshot"))) as $snaps
  | ($evs | map(select(.ev == "lane_exit"))) as $lanes
  | ($lanes | map(.secs) | add // 0) as $lane_secs
  | ([$evs | to_entries[] | select(.value.ev == "usage_pause")
      | .key as $i | .value.ts as $pt
      | {a: $pt,
         b: (($evs[$i+1:] | map(select(.ev == "usage_resume")) | first | .ts) // $t1)}])
    as $pauses
  # Each snapshot describes the world until the next one. Blackout is carved out
  # of every interval it overlaps, so a pause cannot masquerade as starvation.
  # A snapshot written before this record existed carries no impl_free. Reading
  # that as zero would report a starved build as "at capacity" — the missing
  # field means UNKNOWN, and unknown time is shown as its own line rather than
  # silently distributed into a bucket.
  | ([range(0; ($snaps | length)) as $i
      | $snaps[$i] as $s
      | {a: $s.ts, b: (($snaps[$i + 1] | .ts) // $t1),
         free: $s.impl_free, ready: ($s.ready // 0),
         known: ($s.impl_free != null)}
      | . + {tot: (.b - .a)} | . + {paused: ov(.a; .b; $pauses)}
      | . + {act: (.tot - .paused)}]) as $ivs
  | ($ivs | map(.paused) | add // 0) as $paused
  | ($ivs | map(select(.known) | .act) | add // 0) as $covered
  | ($ivs | map(select(.known | not) | .act) | add // 0) as $unknown
  | ($ivs | map(select(.known and .free <= 0) | .act) | add // 0) as $atcap
  | ($ivs | map(select(.known and .free > 0 and .ready == 0) | .act) | add // 0) as $starved
  | ($ivs | map(select(.known and .free > 0 and .ready > 0) | .act) | add // 0) as $slack
  | ($lanes | map(select(.rc == 7))) as $rej
  | ($lanes | map(select(.rc != 0 and .rc != 7))) as $crash
  | ($lanes | map(select(.id | test("-r[0-9]+$")))) as $regate
  | (($rej + $crash + $regate) | unique_by(.id)) as $waste
  | ($waste | map(.secs) | add // 0) as $rework
  # Ticket spans, at wave resolution: first and last snapshot that named it.
  | ([$snaps[] | .ts as $ts | (.tickets // {}) | to_entries[]
      | {iid: .key, ts: $ts}]
     | group_by(.iid)
     | map({iid: .[0].iid, first: (map(.ts) | min), last: (map(.ts) | max)})) as $tk
  | ($tk | map(. as $t
      | . + {work: ($lanes
                    | map(select(.id | test("^(impl|gate|merge)-\($t.iid)(-|$)")))
                    | map(.secs) | add // 0)}
      | . + {open: (.last - .first)}
      | . + {wait: (.open - .work)})) as $tw
  # P55: priced per lane from its own session log, joined here by id. $spend
  # covers every lane log this repo has ever kept (clear-lane never removes
  # the jsonl), so joining against $lanes -- already scoped to $bw via $evs --
  # is what excludes lanes from any other build.
  | ($spend | map({key: .id, value: .cost}) | from_entries) as $spend_by_id
  | ($lanes | map(. + {cost: ($spend_by_id[.id] // 0)})) as $lanes_c
  | ($lanes_c | map(.cost) | add // 0) as $total_cost
  | ($lanes_c | group_by(.type)
     | map({type: .[0].type, cost: (map(.cost) | add // 0)})
     | sort_by(-.cost)) as $by_kind
  | ($tw | map(. as $t | . + {cost: ($lanes_c
       | map(select(.id | test("^(impl|gate|merge)-\($t.iid)(-|$)")))
       | map(.cost) | add // 0)})) as $twc
  | ($lanes_c | sort_by(-.cost) | [limit(5; .[])]) as $top
  | ($tk | map({key: .iid, value: .last}) | from_entries) as $closed_at
  | (($snaps | map(select((.deps // {}) | length > 0)) | first | .deps) // {}) as $deps
  # Longest dependency chain the graph allowed — what `graph` would have
  # predicted from the same edges, recomputed here so the two are comparable.
  | (reduce range(0; 12) as $_ ({};
       . as $d | reduce ($deps | keys[]) as $k ($d;
         .[$k] = (1 + ([($deps[$k] // [])[] | tostring | ($d[.] // 0)] | max // 0))))) as $depth
  | (($depth | to_entries | map(.value) | max) // 0) as $predicted
  # The chain that actually finished last: walk back from the latest-closing
  # ticket, each step taking the blocker that closed latest. limit() is a cycle
  # guard — a dependency cycle would otherwise recurse forever.
  | (($tw | sort_by(.last) | last) // null) as $tail
  | (if $tail == null then []
     else [limit(20; {iid: $tail.iid, last: $tail.last}
       | recurse(. as $c
           | [($deps[$c.iid] // [])[] | tostring | select($closed_at[.] != null)]
           | max_by($closed_at[.]) | select(. != null)
           | {iid: ., last: $closed_at[.]}))] end) as $chain
  | ["Where the capacity went   (sampled at wave cadence, so ±one wave)",
     "",
     "  at capacity    \(hms($atcap))  \(pct($atcap; $covered))   every impl slot busy",
     "  starved        \(hms($starved))  \(pct($starved; $covered))   slots free, nothing ready",
     "  slack          \(hms($slack))  \(pct($slack; $covered))   slots free AND work ready",
     "  blackout       \(hms($paused))  \(pct($paused; ($covered + $paused)))   usage limit"]
  + (if $unknown > 0 then
       ["  unrecorded     \(hms($unknown))          snapshots predating this record"]
     else [] end)
  + (if $slack > 0 then
       ["", "  → slack is capacity that existed, with work waiting for it. Start there."]
     elif $starved > $atcap then
       ["", "  → starvation dominates: the graph, not the lane cap, set the pace."]
     else [] end)
  + ["", "Rework — lane time that produced nothing",
     "",
     "  mechanical rejections  \($rej | length) lane(s)  \(hms($rej | map(.secs) | add // 0))",
     "  crashed lanes          \($crash | length) lane(s)  \(hms($crash | map(.secs) | add // 0))",
     "  re-gates               \($regate | length) lane(s)  \(hms($regate | map(.secs) | add // 0))",
     "  total                  \(hms($rework))  \(pct($rework; $lane_secs)) of all lane time"]
  + ["", "Wait vs work per ticket   (open span minus lane time)", ""]
  + (if ($tw | length) == 0 then ["  nothing recorded"]
     else [$tw | sort_by(-.wait) | limit(10; .[])
           | "  #\(.iid)   open \(hms(.open))   work \(hms(.work))   wait \(hms(.wait))"] end)
  + ["", "Spend   (priced from every lane session log)", ""]
  + (if ($lanes_c | length) == 0 then ["  nothing recorded"]
     else ["  total          \(usd($total_cost))"]
          + ($by_kind | map("  \(.type)  \(usd(.cost))"))
          + ["", "  top spenders", ""]
          + ($top | map("  \(.id)  \(usd(.cost))"))
          + (if ($twc | map(select(.cost > 0)) | length) == 0 then []
             else ["", "  by ticket"]
                  + [$twc | sort_by(-.cost) | limit(5; .[])
                     | select(.cost > 0) | "  #\(.iid)  \(usd(.cost))"] end) end)
  + ["", "The chain that set the length", ""]
  + (if ($chain | length) == 0 then ["  no ticket history recorded"]
     else [($chain | map("#\(.iid) at \(hms(.last - $t0))") | join("  ←  ") | "  " + .),
           "",
           "  actual chain \($chain | length) deep; deepest chain in the graph was \($predicted)"]
          + (if ($predicted > ($chain | length)) then
               ["  → the longest path was not what finished last; the schedule, not the graph, bound it."]
             else [] end) end)
  | join("\n")
    end
'

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
    [ -n "$want" ] || want=$(cat "$BUILD_LABEL_CACHE" 2>/dev/null || echo "")

    # report first: retro explains what report computes, and never recomputes it.
    if [ -n "$want" ]; then cmd_report --build "$want"; else cmd_report; fi
    echo
    local spend_json; spend_json=$(_spend_by_lane)
    jq -rs --arg build_want "$want" --argjson spend "$spend_json" "$RETRO_JQ" "$EVENTS"
    if [ -n "$vs" ]; then
        printf '\n  ── baseline: %s ──\n\n' "$vs"
        { cmd_report --build "$vs"; echo; jq -rs --arg build_want "$vs" --argjson spend "$spend_json" "$RETRO_JQ" "$EVENTS"; } \
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
        jq -rs --arg iid "$iid" "$REPORT_TICKET_JQ" "$EVENTS"
    else
        jq -rs --arg build_want "$want" "$REPORT_JQ" "$EVENTS"
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
GRAPH_JQ='
  (.tickets // []) as $ts
| ($ts | map(.iid)) as $ids
| ($ts | length) as $n
| ((.config.max_lanes // 4) | tonumber? // 4) as $max_lanes
# A blocker whose closed state is unknown (cross-project link) counts as
# blocking: the snapshot already warns about it and the pessimistic read is the
# safe one here.
# Blockers OUTSIDE this build still hold their dependent back, so they cannot
# simply be dropped — doing that made crucible report "opens 7 wide" when three
# of those seven were waiting on issues outside the build. They get no depth of
# their own (this graph cannot see them), but they do push their dependent off
# depth 0, which is the number that matters.
| ($ts | map({key: (.iid | tostring),
              value: [(.blocked_by // [])[]
                      | select((.closed // false) != true)
                      | .iid | select(. as $b | ($ids | index($b)) != null)]})
       | from_entries) as $preds
| ($ts | map({key: (.iid | tostring),
              value: ((.blocked_by // [])
                      | map(select((.closed // false) != true) | .iid)
                      | any(. as $b | ($ids | index($b)) == null))})
       | from_entries) as $ext
| (if $n == 0 then {} else
     reduce range(0; $n + 1) as $_ (
       ($ts | map({key: (.iid | tostring), value: 0}) | from_entries);
       reduce ($preds | keys_unsorted[]) as $k (
         .;
         .[$k] = ((([$preds[$k][] as $p | .[$p | tostring]]
                    + (if $ext[$k] then [0] else [] end)) | max // -1) + 1)))
   end) as $depth
| ($depth | to_entries | map({iid: (.key | tonumber), depth: .value})) as $dl
| ([$dl[].depth] | max // -1) as $maxdepth
| ($dl | group_by(.depth) | map({depth: .[0].depth, iids: (map(.iid) | sort)})
       | sort_by(.depth)) as $levels
| ($levels | map(.iids | length) | max // 0) as $widest
# How wide the build OPENS, which is a different question from how wide it ever
# gets and is the one build 2 actually lost an hour to: "frontier is 1 wide
# until #12 merges; it opens to 3 the moment it does". Both get reported.
# The level at DEPTH 0, not whatever sorts first. When every ticket is blocked
# by something outside the build there is no depth-0 level at all, and reading
# levels[0] then reported the depth-1 group as the frontier — "opens 3 wide"
# while nothing at all could start. Same false reassurance as the out-of-build
# edge bug, one layer up.
| ((($levels | map(select(.depth == 0)) | first | .iids) // []) | length) as $opening
# A DAG of n nodes cannot have depth n; if it does, the fixpoint never settled.
| ($n > 0 and $maxdepth >= $n) as $cycle
| (if $n == 0 then []
   else reduce range(0; $maxdepth) as $_
          ([$dl | map(select(.depth == $maxdepth)) | first | .iid];
           . as $path
           | ($path[0] | tostring) as $cur
           | ([$preds[$cur][] | select($depth[(. | tostring)] == ($depth[$cur] - 1))]
              | first) as $prev
           | if $prev == null then $path else [$prev] + $path end)
   end) as $cpath
| ($ts | map(select(.state == "ready-for-agent" and .unblocked == true
                    and (((.assignees // []) | length) == 0))) | length) as $startable
| {tickets: $n,
   max_lanes: $max_lanes,
   critical_path: {length: ($maxdepth + 1), iids: $cpath},
   widest_level: $widest,
   opening_width: $opening,
   startable_now: $startable,
   levels: $levels,
   cycle_suspected: $cycle,
   verdict:
     (($maxdepth + 1) as $len
      | (if $len == 1 then "1 merge cycle" else "\($len) merge cycles" end) as $cyc
      # The alarm is width against BOTH the lane count and the ticket count: a
      # build with fewer tickets than lanes is small, not chain-shaped, and
      # crying wolf there would train the human to ignore this line.
      | if $n == 0 then "no tickets in this build"
        elif $cycle then "dependency cycle — depths did not settle; fix the blocking edges"
        else
          (if $widest < $max_lanes and $widest < $n then "CHAIN-SHAPED — "
           elif $opening < $max_lanes and $opening < $widest then "NARROW START — "
           else "" end)
          + "opens \($opening) wide, widest level \($widest), against \($max_lanes) lanes; critical path \($cyc) through \($n) tickets"
        end)}
'

cmd_graph() { # graph [<snapshot.json>]  (default: stdin)
    command -v jq >/dev/null 2>&1 || die "graph: jq required"
    local src="${1:--}"
    if [ "$src" = "-" ]; then
        jq "$GRAPH_JQ"
    else
        [ -f "$src" ] || die "graph: no such snapshot file '$src'"
        jq "$GRAPH_JQ" "$src"
    fi
}

# --- launchd lifecycle (per-repo, self-installing) ------------------------
LOOM_LABEL="com.loom.$REPO_KEY"
PLIST_DIR="${LOOM_PLIST_DIR:-$HOME/Library/LaunchAgents}"

_write_plist() {  # _write_plist <path> <interval>
    local path="$1" interval="$2" b d toolpath=""
    # launchd starts with a bare environment; bake a PATH covering the real
    # tool locations (the interactive `claude` may be a shell alias — resolve
    # the binary via PATH here, at install time).
    for b in claude uv glab jq git node bash; do
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
    <array><string>$SELF_PATH</string><string>tick</string><string>--auto</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LOOM_REPO</key><string>$REPO_ROOT</string>
        <key>LOOM_HOME</key><string>$LOOM_HOME</string>
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

# --- P22 layered config: repo > derived > global > built-in ---------------
# The human authors only what no detector can infer. Everything below is
# either a machine-level preference (global) or a fact readable off the repo
# (derived). Config at every scope stays read-only input — never build state.

GLOBAL_CONFIG="${LOOM_GLOBAL_CONFIG:-$HOME/.loom/config.yml}"

_yaml_scalar() { # _yaml_scalar <file> <key> -> value or empty
    local f="$1" k="$2" v=""
    [ -f "$f" ] && v=$(sed -nE "s/^${k}:[[:space:]]*([^#]*).*/\1/p" "$f" | head -1 | xargs) || true
    printf '%s' "$v"
}

cfg_source() { # cfg_source <key> -> repo | global | default
    [ -n "$(_yaml_scalar "$CONFIG" "$1")" ] && { echo repo; return; }
    [ -n "$(_yaml_scalar "$GLOBAL_CONFIG" "$1")" ] && { echo global; return; }
    echo default
}

detect_stack() {
    local r="$REPO_ROOT"
    # Lockfile before manifest: a lockfile names the actual toolchain in use,
    # a manifest only names the ecosystem.
    if   [ -f "$r/uv.lock" ];         then echo uv
    elif [ -f "$r/poetry.lock" ];     then echo poetry
    elif [ -f "$r/pyproject.toml" ];  then echo python
    elif [ -f "$r/pnpm-lock.yaml" ];  then echo pnpm
    elif [ -f "$r/yarn.lock" ];       then echo yarn
    elif [ -f "$r/package.json" ];    then echo npm
    elif [ -f "$r/go.mod" ];          then echo go
    elif [ -f "$r/Cargo.toml" ];      then echo cargo
    else echo unknown; fi
}

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
_repo_gates_tsv() {
    [ -f "$CONFIG" ] || return 0
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
      }' "$CONFIG"
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
        'Bash(git *)' 'Bash(glab *)' 'Bash(sleep *)' 'Bash(curl *)' \
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

cmd_resolve_config() {
    command -v jq >/dev/null 2>&1 || die "resolve-config: jq required"
    local stack base gates_tsv gates_src runner
    stack=$(detect_stack)
    # `base` was never a real setting: SKILL.md already states the rule.
    base=$(_yaml_scalar "$CONFIG" base)
    if [ -n "$base" ]; then :
    elif git -C "$REPO_ROOT" show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then base=develop
    else base=main; fi
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
        --arg fbm  "$(cfg fallback_model sonnet)"        --arg fbm_s   "$(cfg_source fallback_model)" \
        --arg wgap "$(cfg min_wave_gap_minutes 10)"      --arg wgap_s  "$(cfg_source min_wave_gap_minutes)" \
        --arg pmode "$(cfg permission_mode dontAsk)"     --arg pmode_s "$(cfg_source permission_mode)" \
        --arg wmod "$(cfg wave_model '')"                --arg wmod_s  "$(cfg_source wave_model)" \
        --arg lmod "$(cfg lane_model '')"                --arg lmod_s  "$(cfg_source lane_model)" \
        --arg rmod "$(cfg rework_model '')"              --arg rmod_s  "$(cfg_source rework_model)" \
        '{repo: $repo, stack: $stack, base: $base, runner: $runner,
          gates: $gates, gates_source: $gsrc,
          settings: {permissions: {allow: $allow, deny: $deny}},
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
            fallback_model:          {value: $fbm,    source: $fbm_s},
            permission_mode:         {value: $pmode,  source: $pmode_s},
            wave_model:              {value: $wmod,   source: $wmod_s},
            lane_model:              {value: $lmod,   source: $lmod_s},
            rework_model:            {value: $rmod,   source: $rmod_s}
          }}'
}

cmd_install_settings() { # install-settings [--force]
    command -v jq >/dev/null 2>&1 || die "install-settings: jq required"
    local force=0; [ "${1:-}" = "--force" ] && force=1
    local target="$REPO_ROOT/.claude/settings.json"
    mkdir -p "$REPO_ROOT/.claude"
    local generated; generated=$(cmd_resolve_config | jq '.settings')
    if [ -f "$target" ] && [ "$force" -eq 0 ]; then
        if jq -e --argjson g "$generated" '. == $g' "$target" >/dev/null 2>&1; then
            echo "install-settings: already current — $target"; return 0
        fi
        # Never silently discard a hand-edited surface: an allowlist is a
        # security boundary, and the human may have added a rule on purpose.
        echo "install-settings: $target differs from generated; re-run with --force to overwrite" >&2
        return 1
    fi
    printf '%s\n' "$generated" > "$target"
    echo "install-settings: wrote $target"
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

cmd_install() {  # install [--dry-run] [interval-seconds]
    local dry=0; [ "${1:-}" = "--dry-run" ] && { dry=1; shift; }
    # 60s, because this ONE agent now does both jobs: it watches on every
    # firing (stamping lane progress, classifying quiet, notifying) and starts
    # a wave only when the switch is on and `min_wave_gap_minutes` has passed.
    # The old split was 900s for a scheduler that went blind whenever a wave
    # held the lock, plus a separate 60s watcher to cover that blindness. One
    # program watching first needs neither. Spending is paced by the gap, not
    # by the timer, so the fast tick costs nothing.
    local interval="${1:-60}"
    local plist="$PLIST_DIR/$LOOM_LABEL.plist"
    mkdir -p "$LOGS_DIR" "$PLIST_DIR"
    _write_plist "$plist" "$interval"
    if [ "$dry" -eq 1 ]; then echo "generated (dry-run): $plist"; return 0; fi
    # `start` is the switch going ON, and it must clear a previous `stop` or
    # the agent would tick forever refusing to do anything.
    rm -f "$LOOP_STOPPED"
    "$LAUNCHCTL_CMD" bootout "gui/$(id -u)/$LOOM_LABEL" 2>/dev/null || true   # idempotent
    "$LAUNCHCTL_CMD" bootstrap "gui/$(id -u)" "$plist"
    # Retire this repo's old separate watcher, if one is still loaded from
    # before the merge. Left alone it would keep firing every 60s alongside
    # the new agent, doing the same work twice and notifying twice.
    _retire_watcher
    echo "loom: build agent LOADED ($LOOM_LABEL, ${interval}s — watches every tick, waves at most every $(cfg min_wave_gap_minutes 10)m) — repo $REPO_ROOT"
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

# P27: the progress stamp. Filtered event count = lines that are NOT
# api_retry / rate_limit / tool_progress chatter; the stamp file is touched
# only when the count grows, so its mtime means "time of last real progress".
# All THREE wedge shapes freeze it: a silent API gap adds no lines at all, a
# retry storm adds only retry lines, and a lane blocked on a polling tool adds
# only tool_progress. (Paid for: build-1 2026-08-02 — gate-1-r2's retry
# chatter kept its mtime fresh through 2h40m of zero progress, and the
# 27–77-minute silent gaps in wave-015558 had no staleness signal at all.
# Then build-3 2026-08-03 — merge-50's `gate.sh` was auto-backgrounded by the
# harness, the lane blocked on `TaskOutput` to wait for it, pytest deadlocked
# at 0% CPU, and the poll's own tool_progress records kept the lane reading
# `running` for 33 minutes while the whole merge queue stood still behind it.)
#
# What survives the filter is a MODEL TURN — a new assistant message or tool
# call. That is the signal: a lane whose model has not moved in the staleness
# window is wedged, however busy its current tool looks. A genuinely slow
# foreground command is not a false positive here, because the lane still
# takes a turn when it returns; one that never returns is exactly what this
# must catch.
_stamp_progress() {
    local id pid state type rc jsonl prog n prev
    cmd_lane_status 2>/dev/null | while read -r id pid state type rc; do
        case "$state" in running|stale) ;; *) continue ;; esac
        jsonl="$LOGS_DIR/lane-$id.jsonl"; [ -f "$jsonl" ] || continue
        n=$(grep -cv '"subtype":"api_retry"\|"type":"rate_limit_event"\|"type":"tool_progress"' "$jsonl" 2>/dev/null || echo 0)
        prog="$LANES_DIR/$id.progress"
        prev=$(cat "$prog" 2>/dev/null || echo -1)
        [ "$n" = "$prev" ] || printf '%s\n' "$n" > "$prog"
    done
    # The running wave gets the same clock (waves had none): stamp the newest
    # wave stream while the tick lock is held; clear the stamp when it drops.
    if [ -d "$LOCK_DIR" ]; then
        local wj; wj=$(ls -t "$LOGS_DIR"/wave-*.jsonl 2>/dev/null | head -1)
        if [ -n "$wj" ]; then
            n=$(grep -cv '"subtype":"api_retry"\|"type":"rate_limit_event"\|"type":"tool_progress"' "$wj" 2>/dev/null || echo 0)
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
        [ -f "$LANES_DIR/$id.stale-notified" ] && continue
        : > "$LANES_DIR/$id.stale-notified"
        cmd_notify lane_stale "Lane $id is wedged" \
            "Alive but no real progress for ${stale_min}+ min (retry chatter excluded). Unattended: the next heartbeat wave harvests it. Manual: investigate, then kill + clear-lane + tick." \
            >/dev/null 2>&1 || :
    done
    if [ -d "$LOCK_DIR" ] && [ -f "$LOOM_HOME/wave.progress" ] \
       && [ ! -f "$LOOM_HOME/wave.stale-notified" ] \
       && [ -n "$(find "$LOOM_HOME/wave.progress" -mmin +"$stale_min" 2>/dev/null)" ]; then
        : > "$LOOM_HOME/wave.stale-notified"
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
    if "$LAUNCHCTL_CMD" print "gui/$(id -u)/$LOOM_LABEL" >/dev/null 2>&1; then
        echo "$LOOM_LABEL: loaded — watches every tick; starts a wave at most every ${gap}m"
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
    lane-status)  shift; cmd_lane_status "$@" ;;
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
    graph)        shift; cmd_graph "$@" ;;
    resolve-config)   shift; cmd_resolve_config "$@" ;;
    trust-check)      shift; cmd_trust_check "$@" ;;
    install-settings) shift; cmd_install_settings "$@" ;;
    notify)       shift; cmd_notify "$@" ;;
    install)      shift; cmd_install "$@" ;;
    uninstall)    shift; cmd_uninstall "$@" ;;
    agent-status) shift; cmd_agent_status "$@" ;;
    sweep) shift; cmd_sweep "$@" ;;
    quiet-tick) shift; cmd_quiet_tick "$@" ;;
    *) die "usage: tick.sh tick | spawn-lane <id> [--no-tick] [--merge-lock] [--cwd <dir>] -- <cmd...> | lane-status | render-log <id> [--follow] | resume | clear-lane <id> | snapshot [--brief] | graph [file] | report [--ticket <n>] [--build <l>] | retro [--build <l>] [--vs <l>] | resolve-config | trust-check [--notify] [dir] | install-settings [--force] | notify <event> <title> <body> [url] | install [interval] | uninstall | agent-status" ;;
esac
