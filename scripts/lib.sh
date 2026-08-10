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
#   GLAB_CMD               the tracker binary seam (default `glab`)
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

# P49: the one tracker LIST read. Every `per_page=` GET in this skill goes
# through here and PAGINATES — `per_page=100` alone silently returns page 1 and
# nothing says so. Past 100 closed members an epic whose tickets all closed
# early contributes no milestone title, `_epics_unaccepted` answers false,
# `_quiet_check` prints `complete`, and the completion wave tears the agent
# down with that epic never probed: the build-2 failure the acceptance gate
# exists to prevent, reachable again by size alone. The open read truncates the
# same way, so `blocked == count` gets compared over a partial board.
# `--paginate` emits one array PER PAGE, so the fold is part of the read, not a
# nicety. Prints one JSON array; returns non-zero when the call failed or the
# result was not an array, so every caller's existing failure path still fires.
# `--capped` is the deliberate opposite and stays explicit: a `sort=desc` notes
# read wants the newest N, and paginating it would pull the whole thread.
_glab_list() { # [--capped] <api-path> → one JSON array on stdout
    local capped=false glab="${GLAB_CMD:-glab}"
    case "${1:-}" in --capped) capped=true; shift ;; esac
    if $capped; then "$glab" api "$1"; else "$glab" api --paginate "$1"; fi \
        | jq -s 'if (length > 0) and all(type == "array") then add
                 else error("not a JSON array") end' 2>/dev/null
}

# --- the tracker declaration (P86) ----------------------------------------
# ONE place says which tracker a repo uses, and it is not this skill's file.
# Every lane is a `claude -p` session in a worktree, so it loads that repo's
# CLAUDE.md, whose `## Agent skills` block points at
# `docs/agents/issue-tracker.md` — the sibling skills' declaration of the
# tracker and its whole workflow. A second answer kept in `.loom.yml` would not
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

# The drivers this build of loom actually has, one per line. A declared tracker
# outside this set is a HALT, never a fallback: resolving `linear` and then
# running the gitlab driver at it is precisely the failure the declaration
# exists to prevent.
_tracker_drivers() { printf 'gitlab\n'; }

# The halt. Four distinct refusals, because they need four different actions
# from the human, and a lane is headless — it cannot be asked which one applies.
# Prints the resolved tracker name on success.
_require_tracker() { # <dir inside the repo> <who is refusing> → tracker name
    local root what="${2:-loom}" rel name drivers
    root=$(_repo_toplevel "${1:-.}")
    rel=$(_tracker_decl_path)
    [ -f "$root/$rel" ] \
        || die "$what: '$root/$rel' is missing — nothing declares which issue tracker this
  repo uses. Every lane loom spawns reads that file through the repo's CLAUDE.md,
  so without it a headless session infers a tracker from the git remote and
  guesses. Run /setup-matt-pocock-skills in this repo to write it, then commit it."
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
