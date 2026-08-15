#!/usr/bin/env bash
# Loom shared derivations (P73). Sourced by tick.sh, lane.sh and bootstrap.sh.
#
# ENTRY RULE — pure functions only. Nothing in this file runs at source time:
# no assignment, no mkdir, no probe, no exit path. That is the whole reason
# the read half and the write half can share it. tick.sh's read-only charter
# survives (nothing here mutates tracker state, ever) and lane.sh's standing
# rule survives too — lane.sh still never sources tick.sh, whose top level
# creates directories, resolves REPO_ROOT and can exit. Sourcing THIS file is
# provably a no-op until something calls a function in it, and the suite
# proves it: source it in a bare directory and no file appears, nothing is
# printed, rc 0.
#
# Anything added here must pass that same bar. A derivation two scripts both
# need belongs here; a side effect belongs at its call site.
#
# Callers set the ambient variables these functions read, and every one is
# read defensively so a script that never sets it can still source this file:
#   CONFIG, GLOBAL_CONFIG  the two config layers cfg/cfg_source read
#   TRACKER_CMD            the tracker DRIVER seam (default: the driver for
#                          the repo's declared tracker, under trackers/)
#   FORGE_CMD              the forge DRIVER seam (default: the driver for the
#                          repo's forge, under forges/)
#   DIE_RC                 exit code for die (tick.sh/bootstrap.sh 1, lane.sh 2)

# One die for three scripts. The prefix is the script's own name, so a message
# still says which binary refused; the rc stays the caller's, because lane.sh
# exits 2 by contract with the sessions that read it while tick.sh exits 1.
die() { echo "${0##*/}: $*" >&2; exit "${DIE_RC:-1}"; }

# P72: lib.jq — the jq half of this file — ships beside it, and every jq
# program in this skill opens with `include "lib";`. That include resolves off
# jq's `-L` path, so every caller has to say where the prelude is; this returns
# that directory, and refuses when the file is not in it. Unchecked, the
# failure is jq's own "module not found: lib", which names neither the file
# that went missing nor the script it ships beside — the same reason tick.sh
# names a missing snapshot.jq itself.
# Takes the directory rather than deriving it from ${BASH_SOURCE[0]}: callers
# resolve their own script directory ONCE, absolutely, before any `cd`, and
# tick.sh cds to the repo root mid-verb.
_jq_lib_dir() { # <dir the scripts ship in> → the same dir, prelude proven present
    local d="${1:-.}"
    [ -f "$d/lib.jq" ] \
        || die "$d/lib.jq is missing — it holds the shared jq prelude every jq program in this skill includes"
    printf '%s\n' "$d"
}

# P86: `_glab_list` used to live here — the one paginating tracker LIST read,
# with its handling of `glab issue list -F json` printing a human sentence on an
# empty board. Both facts are GitLab's, not loom's, so it moved into
# scripts/trackers/gitlab.sh as `_list`. What stays here is the resolver that
# says WHICH driver to call.

# --- the tracker declaration (P86) ----------------------------------------
# ONE place says which tracker a repo uses, and it is not this skill's file.
# Every lane is a provider job in a worktree, and Loom gives every provider the
# same committed `docs/agents/issue-tracker.md` declaration. A second answer
# kept in `.loom.yml` would not
# be a config key, it would be a way for tick.sh to read one board while the
# lanes it spawns write to another, with nothing in the design able to notice.
# So loom READS that file and never writes one of its own.
_tracker_decl_path() { printf 'docs/agents/issue-tracker.md\n'; }

_repo_toplevel() { # <dir> → the git worktree root, else <dir> unchanged
    local d="${1:-.}" top
    top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) && printf '%s\n' "$top" \
        || printf '%s\n' "$d"
}

# The heading form, which every seed template already carries
# (`# Issue tracker: GitHub` / `GitLab` / `Local Markdown`). Scanned over the
# opening lines rather than line 1 alone, so a file that grew a title above it
# still answers. Prints the name lowercased, or nothing.
_tracker_declared() { # <dir inside the repo> → tracker name, or empty
    local root f
    root=$(_repo_toplevel "${1:-.}")
    f="$root/$(_tracker_decl_path)"
    [ -f "$f" ] || return 0
    sed -nE '1,20s/^#[[:space:]]+Issue tracker:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$f" \
        | head -1 | tr 'A-Z' 'a-z'
}

# A coordinate the declaration carries beside the tracker's name, read as a
# `Field: value` line in the opening lines of the same file (P87). Linear needs
# one — its issues belong to a Team and, unlike a GitLab project, no git remote
# names it — and this is a second LINE in the one file rather than a second
# file, so P86's finding holds: there is still exactly one place a human writes
# down what tracker this repo uses and where in it the tickets live.
#
# P92: a human writes this as a markdown list item — `- Team: **Jordan** (key
# JOR)` — which the plain `Field:` match above used to read as empty. Accept an
# optional leading list marker, then strip a `**bold**` wrapper and a trailing
# ` (...)` parenthetical, so `- Team: **Jordan** (key JOR)` and the bare
# `Team: JOR` read the same value.
_tracker_decl_field() { # <dir inside the repo> <Field> → value, or empty
    local root f raw
    root=$(_repo_toplevel "${1:-.}")
    f="$root/$(_tracker_decl_path)"
    [ -f "$f" ] || return 0
    raw=$(sed -nE "1,20s/^[[:space:]]*([-*][[:space:]]+)?$2:[[:space:]]*([^[:space:]].*[^[:space:]]|[^[:space:]])[[:space:]]*\$/\\2/p" "$f" \
        | head -1)
    raw="${raw#\*\*}"
    raw="${raw%% \(*}"
    raw="${raw%\*\*}"
    printf '%s\n' "$raw"
}

# The drivers this build of loom actually has, one per line. A declared tracker
# outside this set is a HALT, never a fallback: resolving `linear` and then
# running the gitlab driver at it is precisely the failure the declaration
# exists to prevent.
_tracker_drivers() { printf 'gitlab\nlinear\n'; }

# The driver for this repo's declared tracker (P86 stage 2). Every tracker call
# in this skill goes through the returned script, so `glab` appears in exactly
# one file. `TRACKER_CMD` is the seam a test stubs to watch the CONTRACT being
# called; `GLAB_CMD` inside the driver is the seam for watching GitLab itself.
# Falls back to gitlab when nothing is declared, which only ever happens on a
# path `_require_tracker` has already refused — a resolver must not be the
# thing that reports a missing declaration.
_tracker_cmd() { # <dir the scripts ship in> [<dir inside the repo>]
    [ -z "${TRACKER_CMD:-}" ] || { printf '%s\n' "$TRACKER_CMD"; return 0; }
    local d="$1" name
    name=$(_tracker_declared "${2:-.}")
    [ -n "$name" ] || name=gitlab
    printf '%s/trackers/%s.sh\n' "$d" "$name"
}

# The halt. Four distinct refusals, because they need four different actions
# from the human, and a lane is headless — it cannot be asked which one applies.
# Prints the resolved tracker name on success.
_require_tracker() { # <dir inside the repo> <who is refusing> → tracker name
    local root what="${2:-loom}" rel name drivers
    root=$(_repo_toplevel "${1:-.}")
    rel=$(_tracker_decl_path)
    [ -f "$root/$rel" ] \
        || die "$what: '$root/$rel' is missing — nothing declares which issue tracker this
  repo uses. Loom scripts and every provider job read that file directly; without
  it a headless session has no canonical board. Run /setup-matt-pocock-skills in
  this repo to write it, then commit it."
    # Present is not enough. Worktrees sit BESIDE the repo and each is a
    # checkout, so an untracked or ignored declaration is visible to the human
    # in the primary clone and absent from every lane — the worst version of
    # this, because the file you are told is missing is one you can see.
    git -C "$root" ls-files --error-unmatch "$rel" >/dev/null 2>&1 \
        || die "$what: '$rel' exists but git does not track it, so it is in none of the
  worktrees the lanes run in — you can see the declaration and no lane ever will.
  Commit it:  git add $rel"
    name=$(_tracker_declared "$root")
    [ -n "$name" ] \
        || die "$what: '$rel' carries no '# Issue tracker: <Name>' heading in its opening
  lines, so nothing in it names a tracker. Add one as the file's first line, e.g.
  '# Issue tracker: GitLab'."
    drivers=$(_tracker_drivers | tr '\n' ' '); drivers="${drivers% }"
    local d have=0
    while IFS= read -r d; do [ "$d" = "$name" ] && have=1; done <<EOF
$(_tracker_drivers)
EOF
    [ "$have" = 1 ] \
        || die "$what: this repo declares '$name' in $rel, and loom has drivers for:
  $drivers. Refusing to drive a $name board with a $drivers driver — resolving the
  declaration and then ignoring it is the split brain the declaration exists to close."
    printf '%s\n' "$name"
}

# --- the forge (P87 stage 1) ----------------------------------------------
# A BOARD and a FORGE are two systems, and GitLab happens to be both. The board
# holds tickets, labels and epics; the forge holds branches and merge requests.
# P86 grouped the driver's verbs that way in comments, deliberately. This makes
# the grouping load-bearing, because Linear is a board and nothing else: it has
# no merge requests at all, so a Linear-tracked repo keeps its code on GitHub or
# GitLab and loom has to resolve two backends rather than one.
#
# The forge tries a BEST GUESS first, every time: a tracker that is itself a
# code host is its own forge, and otherwise the git remote is checked for a
# recognisable host. Neither costs a human anything. Only when both come up
# empty is a human asked (an interactive verb does the asking; a script only
# ever refuses), and that answer is recorded as `forge: gitlab` (or `github`)
# in `.loom.yml` rather than re-asked every run. The recorded key is checked
# BEFORE the guess, not after — a human's own answer is the one place someone
# can override the heuristic, and without checking it first the guess would
# fail identically on the very next run and the human would be asked forever.
# *(paid: a self-hosted GitLab whose own domain carries no `gitlab` substring —
# `labs.gauntletai.com` — had no way to answer this at all, since `.loom.yml`
# carried no key for it; every read-only verb refused the repo outright.)*
_forge_drivers() { printf 'gitlab\ngithub\n'; }

# The explicit override. Read straight off `.loom.yml` by path — not through
# the ambient `CONFIG` var `cfg`/`cfg_source` use — because `lane.sh` (unlike
# tick.sh) never sets `CONFIG`, and a forge answer that only tick.sh could see
# would make lanes and waves disagree about where their own merge requests go.
_forge_configured() { # <dir inside the repo> → forge name from .loom.yml, or empty
    local root
    root=$(_repo_toplevel "${1:-.}")
    _yaml_scalar "$root/.loom.yml" forge | tr 'A-Z' 'a-z'
}

# Beside `cfg_source`: not "repo | global | default" (this key is never
# global — a forge answer is per-repo by nature) but "config | derived | empty",
# so `resolve-config` can tell a human's recorded answer from a guess.
_forge_source() { # <dir inside the repo> → config | derived | empty
    local root
    root=$(_repo_toplevel "${1:-.}")
    [ -n "$(_forge_configured "$root")" ] && { echo config; return; }
    [ -n "$(_forge_declared "$root")" ] && { echo derived; return; }
    echo ""
}

# Trackers that are also code hosts. A repo declaring one of these needs no
# remote inspection at all, which is the whole reason resolution asks this
# FIRST: every GitLab repo keeps the forge it has always had, and a self-hosted
# instance on a domain with no `gitlab` in its name is answered correctly
# without anyone having to teach this file about hostnames.
_forge_capable_trackers() { printf 'gitlab\ngithub\n'; }

_is_forge_capable() { # <tracker name>
    local t
    while IFS= read -r t; do [ "$t" = "$1" ] && return 0; done <<EOF
$(_forge_capable_trackers)
EOF
    return 1
}

# The host half, consulted only when the board cannot host code. Matches on the
# remote URL rather than parsing it into pieces: `git@github.com:o/r.git` and
# `https://github.com/o/r` are the same answer, and a self-hosted GitLab is
# recognised by the name it almost always carries in its own domain.
_forge_from_remote() { # <dir inside the repo> → forge name, or empty
    local root url
    root=$(_repo_toplevel "${1:-.}")
    url=$(git -C "$root" remote get-url origin 2>/dev/null) || return 0
    case "$url" in
        *github.com*)  printf 'github\n' ;;
        *gitlab*)      printf 'gitlab\n' ;;
        *)             : ;;
    esac
}

_forge_declared() { # <dir inside the repo> → forge name, or empty
    local root cfg trk
    root=$(_repo_toplevel "${1:-.}")
    cfg=$(_forge_configured "$root")
    [ -n "$cfg" ] && { printf '%s\n' "$cfg"; return 0; }
    trk=$(_tracker_declared "$root")
    if [ -n "$trk" ] && _is_forge_capable "$trk"; then printf '%s\n' "$trk"; return 0; fi
    _forge_from_remote "$root"
}

# Same shape as `_tracker_cmd`, same reason for the fallback: a resolver must
# not be the thing that reports a missing answer. `_require_forge` does that.
_forge_cmd() { # <dir the scripts ship in> [<dir inside the repo>]
    [ -z "${FORGE_CMD:-}" ] || { printf '%s\n' "$FORGE_CMD"; return 0; }
    local d="$1" name
    name=$(_forge_declared "${2:-.}")
    [ -n "$name" ] || name=gitlab
    printf '%s/forges/%s.sh\n' "$d" "$name"
}

# The fourth refusal. It only ever fires for a board that is not also a code
# host, on a remote the heuristic could not read AND with no explicit answer
# recorded — every GitLab repo answers at the first line, and every repo that
# has already been asked once answers at the config line — so its message is
# written for exactly the leftover case and says both halves: what the repo
# declared, and why the remote could not supply the rest, plus the escape
# hatch a human (never a lane, never a wave — this halt is not theirs to
# resolve) can use to answer it once and for all.
_require_forge() { # <dir inside the repo> <who is refusing> → forge name
    local root cfg trk name drivers d have=0
    root=$(_repo_toplevel "${1:-.}")
    cfg=$(_forge_configured "$root")
    if [ -n "$cfg" ]; then
        name="$cfg"
    else
        trk=$(_tracker_declared "$root")
        if [ -n "$trk" ] && _is_forge_capable "$trk"; then printf '%s\n' "$trk"; return 0; fi
        name=$(_forge_from_remote "$root")
    fi
    drivers=$(_forge_drivers | tr '\n' ' '); drivers="${drivers% }"
    [ -n "$name" ] \
        || die "${2:-loom}: this repo declares '${trk:-nothing}' as its issue tracker, which is a
  board and not a code host — it has no merge requests — and its 'origin' remote
  does not name a forge loom drives ($drivers). Loom needs both: the board for
  tickets and the forge for the branches and merge requests a lane opens. Either
  point 'origin' at the repository the code actually lives in, or, once a human
  has confirmed which forge this is, record it once in .loom.yml:

    forge: gitlab   # or: github"
    while IFS= read -r d; do [ "$d" = "$name" ] && have=1; done <<EOF
$(_forge_drivers)
EOF
    local src=derived; [ -n "$cfg" ] && src=".loom.yml"
    [ "$have" = 1 ] \
        || die "${2:-loom}: this repo's forge resolves to '$name' (source: $src), and loom has forge drivers for: $drivers."
    printf '%s\n' "$name"
}

# --- the tracker credential (P88) -----------------------------------------
# A CLI-driven tracker owns its own auth: `glab` and `gh` keep a token where
# they keep it, and loom never sees one. An HTTP-driven tracker has no such
# place, so `linear.sh` reads `LINEAR_API_KEY` out of the process environment
# and dies without it — and the environment it must appear in is the launchd
# agent's, because every tracker call in a build descends from that one process
# and environment only travels downward. The plist carries a fixed four-key
# dict, so the only route was `launchctl setenv`: machine-wide, no reboot
# survives it, and the failure that follows is the silent `unknown`-board wave
# skip this skill has already paid for once.
#
# So the credential lives in a config file loom already reads, and is exported
# once, early, before any tracker call.
_tracker_credential() { # <tracker name> → the env var it needs, or empty
    case "${1:-}" in
        linear) printf 'LINEAR_API_KEY\n' ;;
        *)      : ;;   # gitlab, github: their CLI owns the token
    esac
}

_has_secrets_block() { # <config file>
    [ -f "${1:-}" ] && grep -qE '^secrets:[[:space:]]*$' "$1"
}

# The `secrets:` map, as NAME<TAB>VALUE. A value is taken WHOLE: no `#` comment
# stripping, unlike `_yaml_scalar`, because `#` is an ordinary character in a
# token and silently truncating a credential at one would be a failure nobody
# could read off the file. Surrounding quotes come off, since a human writing a
# token that starts with a digit will reach for them.
_secret_pairs() { # <config file> → NAME<TAB>VALUE lines
    [ -f "${1:-}" ] || return 0
    awk '
      /^secrets:[[:space:]]*$/ { s = 1; next }
      s && /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {
          k = $0; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]*:.*$/, "", k)
          v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
          if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
          if (v != "") print k "\t" v
          next }
      s && /^[^[:space:]#]/ { s = 0 }
    ' "$1"
}

# THE LOAD-BEARING REFUSAL. `.loom.yml` is committed, so a credential in it
# would be pushed to the forge — and this whole mechanism is only safe because
# the committed layer can never carry one. Loud, by name, everywhere.
_refuse_repo_secrets() { # <repo config path> <who is refusing>
    _has_secrets_block "${1:-}" || return 0
    die "${2:-loom}: '$1' contains a 'secrets:' block, and that file is COMMITTED — a
  credential in it goes to the forge on the next push. Move it to the global
  config (~/.loom/config.yml) or to this repo's own state directory
  (\$LOOM_HOME/config.yml); both sit outside every working tree. Then rotate the
  key, because it has already been written to a tracked file."
}

# The one function in this file that changes anything, and it changes only the
# environment of the process that calls it.
#
# THE REAL ENVIRONMENT ALWAYS WINS, and after it the most specific file does.
# Both fall out of one rule — a variable that already has a value is left
# alone — so the caller passes the files MOST SPECIFIC FIRST. That keeps a
# one-off override working, leaves CI (which supplies its own) untouched, and
# lets a repo's own state directory point at a different workspace from the
# machine-wide answer without a second mechanism.
_load_secrets() { # <source-label> <file> [<source-label> <file>]... — most specific first
    local lbl f k v
    while [ $# -ge 2 ]; do
        lbl="$1"; f="$2"; shift 2
        [ -n "$f" ] && [ -f "$f" ] || continue
        # A heredoc rather than a pipe: a `while read` on the right of a pipe
        # runs in a subshell, and every export would be lost on the way out.
        while IFS="$(printf '\t')" read -r k v; do
            [ -n "$k" ] || continue
            [ -z "${!k:-}" ] || continue
            export "$k=$v"
            LOOM_SECRET_SRC="${LOOM_SECRET_SRC:-} $k:$lbl"
        done <<EOF
$(_secret_pairs "$f")
EOF
    done
}

# Where a credential came from, for a human diagnosing its absence. NEVER the
# value: `resolve-config` prints this, and its output is pasted into every wave
# prompt, so a value here would land in every session transcript the build ever
# writes.
_secret_source() { # <var name> → global | repo-state | environment | empty
    local k="${1:-}" e
    [ -n "$k" ] || return 0
    for e in ${LOOM_SECRET_SRC:-}; do
        case "$e" in "$k":*) printf '%s\n' "${e#*:}"; return 0 ;; esac
    done
    # Set, but not by anything this process loaded — so it was already there.
    if [ -n "${!k:-}" ]; then printf 'environment\n'; return 0; fi
    printf '\n'
}

# --- config readers (flat keys) -------------------------------------------
_yaml_scalar() { # _yaml_scalar <file> <key> -> value or empty
    local f="$1" k="$2" v=""
    [ -f "$f" ] && v=$(sed -nE "s/^${k}:[[:space:]]*([^#]*).*/\1/p" "$f" | head -1 | xargs) || true
    printf '%s' "$v"
}

cfg() { # cfg <key> <default> — layered: repo > global > built-in (P22)
    local v
    v=$(_yaml_scalar "${CONFIG:-}" "$1")
    [ -n "$v" ] || v=$(_yaml_scalar "${GLOBAL_CONFIG:-}" "$1")
    printf '%s\n' "${v:-$2}"
}

cfg_source() { # cfg_source <key> -> repo | global | default
    [ -n "$(_yaml_scalar "${CONFIG:-}" "$1")" ] && { echo repo; return; }
    [ -n "$(_yaml_scalar "${GLOBAL_CONFIG:-}" "$1")" ] && { echo global; return; }
    echo default
}

# --- the base branch, in one place ----------------------------------------
# The rule — declared `base:`, else develop where the remote has it, else main
# — used to be written six times across the two scripts, and the sixth had
# already drifted: `submit` probed with `ls-remote` and never read the config
# key at all, so a repo setting `base:` got its MRs targeted by a different
# rule than the one its merges reconciled against. One function now, and a
# repo that sets `base:` is answered the same way by every caller.
#
# <dir> is asked the git question so a lane worktree can answer for itself.
# The config file defaults to the one beside <dir>, which is what a lane
# reading its own worktree wants; tick.sh passes its resolved $CONFIG instead,
# because there the repo root's config governs even when the git question is
# being asked of some other worktree.
_detect_base() { # <dir> [config-file] → base branch NAME
    local dir="${1:-.}" cfgf="${2-${1:-.}/.loom.yml}" base
    base=$(_yaml_scalar "$cfgf" base)
    if [ -n "$base" ]; then :
    elif git -C "$dir" show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then base=develop
    else base=main; fi
    printf '%s\n' "$base"
}

# The ref a branch is MEASURED against — the name above, resolved to something
# git can diff: the remote ref first, then a local branch, then HEAD. HEAD
# means "no base here", and a caller measuring a diff must treat that as
# unknown rather than as an empty diff.
_base_ref() { # <dir> [config-file] → ref name
    local dir="${1:-.}" base
    base=$(_detect_base "$@")
    if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$base" 2>/dev/null; then printf 'origin/%s\n' "$base"
    elif git -C "$dir" show-ref --verify --quiet "refs/heads/$base" 2>/dev/null; then printf '%s\n' "$base"
    else printf 'HEAD\n'; fi
}

# --- the toolchain table --------------------------------------------------
# ONE table, three consumers: `_stack_for` (which tick.sh's detect_stack and
# through it _derive_gates_tsv are built on) and `_install_cmd_for`. It used to
# be two hand-kept copies — lane.sh's said so in its own comment, "kept as its
# own copy" — so an ecosystem added to one was silently absent from the other.
#
# Row order IS the probe order, and it is grouped by ecosystem with the
# lockfile ahead of the manifest: a lockfile names the toolchain actually in
# use, a manifest only the ecosystem. `kind` is what lets one order serve both
# questions — the installer walks lock rows up the tree first and only then
# falls back to the manifest in the directory that actually moved.
_toolchain_table() { # → marker <TAB> kind <TAB> stack <TAB> install command
    cat <<'EOF'
uv.lock	lock	uv	uv sync
poetry.lock	lock	poetry	poetry install
pyproject.toml	manifest	python	uv sync
pnpm-lock.yaml	lock	pnpm	pnpm install
yarn.lock	lock	yarn	yarn install
package-lock.json	lock	npm	npm ci
package.json	manifest	npm	npm install
go.sum	lock	go	go mod download
go.mod	manifest	go	go mod download
Cargo.lock	lock	cargo	cargo fetch
Cargo.toml	manifest	cargo	cargo fetch
EOF
}

_stack_for() { # <dir> → uv | poetry | python | pnpm | yarn | npm | go | cargo | unknown
    local d="${1:-.}" marker kind stack cmd
    while IFS=$'\t' read -r marker kind stack cmd; do
        [ -n "$marker" ] || continue
        if [ -f "$d/$marker" ]; then printf '%s\n' "$stack"; return 0; fi
    done <<EOF
$(_toolchain_table)
EOF
    printf 'unknown\n'
}

# The installer for one directory. A manifest with no lockfile beside it is
# usually a workspace member (a pnpm/yarn monorepo keeps one lockfile at the
# root), so the search walks UP to the nearest ancestor that has one and
# installs there. Guessing `npm install` inside a pnpm workspace package would
# write a second, wrong node_modules.
_install_cmd_for() { # <dir> → "<install dir>\t<command>", or empty
    local d="${1:-.}" probe marker kind stack cmd
    probe="$d"
    while :; do
        while IFS=$'\t' read -r marker kind stack cmd; do
            [ "$kind" = lock ] || continue
            if [ -f "$probe/$marker" ]; then printf '%s\t%s\n' "$probe" "$cmd"; return 0; fi
        done <<EOF
$(_toolchain_table)
EOF
        [ "$probe" != "." ] || break
        probe=$(dirname "$probe")
    done
    # No lockfile anywhere above it — fall back to the manifest in the
    # directory that actually moved.
    while IFS=$'\t' read -r marker kind stack cmd; do
        [ "$kind" = manifest ] || continue
        if [ -f "$d/$marker" ]; then printf '%s\t%s\n' "$d" "$cmd"; return 0; fi
    done <<EOF
$(_toolchain_table)
EOF
    # Explicit: nothing to install is not an error, and under `set -e` a
    # falling-through test would take the whole reconcile down with it.
    return 0
}

# The lane-id split, bash side. Its jq mirror is `stage` in lib.jq (which also
# names this one): the ticker has to split the same ids to render them, and jq
# is the wrong tool to reach for from bash on a hot-path string. A NEW LANE
# KIND HAS TO BE ADDED IN BOTH PLACES — that is the whole reason each names the
# other, since a kind added here alone renders as a bare "lane" in the ticker.
_lane_type() { # <id> → impl | gate | probe | merge, or fails
    case "$1" in
        impl-[0-9]*)          echo impl  ;;
        gate-[0-9]*)          echo gate  ;;
        merge-[0-9]*)         echo merge ;;
        probe-[A-Za-z0-9]*)   echo probe ;;
        *) return 1 ;;
    esac
}

# Provider-native runtime keys are not safe to translate implicitly. Returns
# the first legacy key/value form found across the supplied config files.
# Consumers: tick.sh and agent.sh, so both scheduler and chained jobs fail at
# the same migration boundary.
_legacy_runtime_config() { # <config-file>...
    local f key
    for f in "$@"; do
      [ -f "$f" ] || continue
      key=$(sed -nE 's/^[[:space:]]*(wave_model|lane_model|rework_model|fallback_model|permission_mode):.*/\1/p' "$f" | head -1)
      [ -z "$key" ] || { printf '%s\n' "$key"; return 0; }
      grep -qE '^[[:space:]]*usage_limit:[[:space:]]*downshift_model' "$f" \
        && { printf '%s\n' usage_limit:downshift_model; return 0; }
    done
    return 1
}
