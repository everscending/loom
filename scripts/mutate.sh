#!/usr/bin/env bash
# P45: "a test must prove it can fail." A green suite is a claim about the
# tests, not about the production line a test names — the only way to know a
# guard, a destructive path, or a cap is actually load-bearing is to remove it
# and watch something turn red. This is that removal, mechanized.
#
#   scripts/mutate.sh --list           registry entries, one per line
#   scripts/mutate.sh                  run every registered mutation
#   scripts/mutate.sh <name...>        run only the named mutation(s)
#
# Normally invoked as `tick-test.sh --mutate [name...]` (see tick-test.sh's
# own usage text). qa runs this by hand — it is NOT part of the normal suite:
# each entry re-runs the WHOLE suite once against a mutated scratch clone of
# scripts/, so the full registry is minutes, not seconds. `--mutate <name>`
# while iterating on one entry.
#
# == How a target is found ==
# Every registry entry names a MARKER, a comment of the form
# `# mutate:<name>` living at the end of the exact line it mutates — never a
# line number (this codebase's own rule: line numbers drift) and never
# verbatim text (a rewording of the surrounding comment would silently orphan
# the entry). `grep -F` finds the marker; sed acts on the physical line
# number that search returns, at run time, against a throwaway copy.
#
# == What "mutate" means ==
# `delete`   — the whole line (code and marker together) is removed. For a
#              guard written as one self-contained statement (a `case`, an
#              `if` that fits on its line), deleting it is the truest form of
#              "this guard did not exist."
# `sub`      — a literal substring on the marked line is replaced with
#              another, everything else on the line untouched. For a guard or
#              cap embedded in a larger expression (a jq pipe, a compound
#              `if`), deleting the line would break the syntax around it;
#              inverting the one comparison or destructive call in place does
#              not.
#
# == What "the suite goes red" means ==
# The WHOLE suite — every section in scripts/tests/, via a full copy of
# tick-test.sh — rather than a hand-picked "the section that should catch
# this." Mapping mutation -> section is itself something that drifts silently
# (a section renamed, a test moved) and the point of this tool is to stop
# trusting a human's belief about what covers what. Slower, but the only
# answer that is still true after the suite reorganizes around it.
#
# == Adding an entry ==
# 1. Put `# mutate:<name>` at the end of the production line to mutate (or,
#    for `delete`, the marker travels with the whole line — put it there even
#    if the line has no room for a human-readable comment already).
# 2. Add one line to REGISTRY below: name, the file relative to scripts/,
#    delete or a sub with its <from> and <to> (tab-separated; from/to must
#    not themselves contain a literal tab or an `@`, the sed delimiter used
#    to apply them).
# 3. Run `scripts/mutate.sh <name>` once by hand and read the verdict — a
#    fresh entry that reports CAUGHT proves the guard is watched; ESCAPED is
#    not a bug in this tool, it is the finding qa exists to surface.
set -uo pipefail

# LOOM_MUTATE_SRC is the seam the harness section (scripts/tests/) drives
# this against a throwaway fixture "scripts/" instead of the real one — the
# same trick tick-test.sh plays with LOOM_TEST_DIR. Real usage never sets it.
DIR="${LOOM_MUTATE_SRC:-$(cd "$(dirname "$0")" && pwd)}"

# name<TAB>relfile<TAB>kind<TAB>from<TAB>to
# kind=delete ignores from/to. kind=sub replaces the first match of <from>
# with <to> on the marked line only (sed address = the line's own number,
# found fresh against the copy being mutated — never the original's).
#
# LOOM_MUTATE_REGISTRY_FILE is the matching seam for the registry itself, so
# a test can prove CAUGHT/ESCAPED against a two-line fixture registry instead
# of waiting on a real one. Real usage never sets it.
if [ -n "${LOOM_MUTATE_REGISTRY_FILE:-}" ]; then
    REGISTRY=$(cat "$LOOM_MUTATE_REGISTRY_FILE")
else
REGISTRY=$(cat <<'EOF'
scratch-prune-guard	tick.sh	delete
sweep-merged-rmrf	tick.sh	sub	rm -rf "$dir"	true
merge-attempt-cap	plan.jq	sub	>= $merge_cap	< $merge_cap
merge-attempt-anchor	lib.jq	sub	<!-- orch-merge-attempt \\d+ -->	orch-merge-attempt
merge-reset-cutoff	lib.jq	sub	$reset == null	true
merge-hold-anchor	lib.jq	sub	<!-- orch-merge-attempt \\d+ base-red=(\\S+) fix=(\\d+) -->	orch-merge-attempt \\d+ base-red=(\\S+) fix=(\\d+)
rejection-total-cap	plan.jq	sub	.rejections.total	.rejections.same_class_tail
scope-reset-transport	snapshot.jq	delete
scope-extend-accumulate	lib.jq	sub	orch-scope-extend	orch-scope-reset
finished-lane-capacity	lib.jq	sub	== "-"	!= "-"
wave-prefix-strip	render-events.jq	sub	(?i)^	^
linear-label-payload	trackers/linear.sh	sub	== true	== false
EOF
)
fi

_entry() { # <name> → the matching registry line, or empty
    printf '%s\n' "$REGISTRY" | awk -F'\t' -v n="$1" '$1 == n { print; exit }'
}

if [ "${1:-}" = "--list" ]; then
    printf '%s\n' "$REGISTRY" | awk -F'\t' '{printf "%-28s %s (%s)\n", $1, $2, $3}'
    exit 0
fi

names=()
if [ $# -gt 0 ]; then
    for n in "$@"; do
        [ -n "$(_entry "$n")" ] || { echo "mutate: no registry entry named '$n' — try --list" >&2; exit 2; }
        names+=("$n")
    done
else
    while IFS=$'\t' read -r n _; do [ -n "$n" ] && names+=("$n"); done <<<"$REGISTRY"
fi

# A clone mirrors a REPO ROOT, not just scripts/: scripts/ lives one level
# down, siblings a section reads by relative path (`$(dirname "$TICK")/..`,
# today only PROPOSALS.md, in 15-proposals-hygiene.sh) come along too. A flat
# copy of scripts/ alone made that one check unconditionally fail — not
# because of any mutation, but because the file it looks for one directory up
# was never there. Copying it in is cheap insurance against the same drift
# happening again to a future section.
_make_clone() { # → prints the clone's repo-root directory
    local clone; clone=$(mktemp -d)
    mkdir -p "$clone/scripts"
    cp "$DIR"/*.sh "$DIR"/*.jq "$clone/scripts/" 2>/dev/null
    cp -R "$DIR/forges" "$DIR/trackers" "$clone/scripts/" 2>/dev/null
    cp -R "$DIR/tests" "$clone/scripts/"
    chmod +x "$clone/scripts"/*.sh 2>/dev/null
    cp "$DIR/../PROPOSALS.md" "$clone/PROPOSALS.md" 2>/dev/null || true
    printf '%s\n' "$clone"
}

# Runs the whole suite in <clone-root>/scripts and writes its FULL captured
# output (stdout+stderr) to <clone-root>/.mutate-out — a caller then pulls
# both the fail set and the verdict line out of that one file rather than
# juggling extra file descriptors.
_run_clone() { # <clone-root>
    local clone="$1"
    # Force cwd into the clone before running anything out of it — the exact
    # lesson D-TEST-14 paid for: jq resolves a relative `include` against the
    # CALLER's cwd before its own -L directory, so a mutated .jq file is only
    # guaranteed to be the one loaded when the whole run's cwd sits inside the
    # clone that holds it.
    (cd "$clone/scripts" && bash "$clone/scripts/tick-test.sh" > "$clone/.mutate-out" 2>&1)
}
_clone_fails()   { sed -n 's/^FAIL: //p' "$1/.mutate-out"; }
_clone_verdict() { grep -E '^== [0-9]+ passed, [0-9]+ failed ==' "$1/.mutate-out" | tail -1; }

# A suite this size carries a little of its own flakiness (lock's
# concurrent-tick test and a couple of watch-panes timing assertions, mainly)
# even unmutated, and the repo-root reshape above is new enough that a
# still-undiscovered relative-path dependency could exist beyond
# PROPOSALS.md. Rather than assume the clone is clean, run it ONCE with no
# mutation and treat every name that fails there as pre-existing — only a NEW
# failure name, absent from this baseline, counts as the mutation being
# caught. This is what keeps "escaped" honest: without it, a flaky or
# clone-sensitive test could masquerade as proof a mutation was caught.
#
# KNOWN LIMITATION: this baseline is ONE run, and lock/watch-panes carry
# genuine pre-existing timing flakiness (independent of this file — observed
# across repeated runs during this file's own development). It is possible,
# if uncommon, for the baseline run to get lucky and a mutated run to get
# unlucky, reporting a false CAUGHT whose "new" failure list is padded with
# that flake rather than anything the mutation touched. The CAUGHT output
# always names every new failure — when the list mixes a `lock:`/
# `watch-panes:` line with no obvious relation to the mutated target
# alongside others that DO name the mutated behaviour (a `plan:` failure for
# a `plan.jq` cap, say), the verdict is still trustworthy; treat a CAUGHT
# whose new-failure list is ONLY lock/watch-panes lines as worth a re-run.
# ESCAPED carries no such risk in the other direction: it requires the
# baseline's OWN failures to already cover everything the mutated run
# produced, which flakiness only ever shrinks, never manufactures.
echo "mutate: establishing a baseline (unmutated clone, full suite)..."
BASE_CLONE=$(_make_clone)
_run_clone "$BASE_CLONE"
BASELINE_FAILS=$(_clone_fails "$BASE_CLONE")
base_verdict=$(_clone_verdict "$BASE_CLONE")
rm -rf "$BASE_CLONE"
echo "mutate: baseline — $base_verdict"
[ -n "$BASELINE_FAILS" ] && printf 'mutate: baseline fail(s), excluded from every verdict below —\n%s\n' "$(printf '%s\n' "$BASELINE_FAILS" | sed 's/^/    /')"
echo

CAUGHT=() ESCAPED=() BROKEN=()

for name in "${names[@]}"; do
    entry="$(_entry "$name")"
    IFS=$'\t' read -r _ relfile kind from to <<<"$entry"
    marker="# mutate:$name"

    CLONE=$(_make_clone)
    target="$CLONE/scripts/$relfile"
    if [ ! -f "$target" ]; then
        echo "== $name: BROKEN — no such file $relfile =="
        BROKEN+=("$name")
        rm -rf "$CLONE"; continue
    fi
    lineno=$(grep -nF "$marker" "$target" | head -1 | cut -d: -f1)
    if [ -z "$lineno" ]; then
        echo "== $name: BROKEN — marker '$marker' not found in $relfile (drifted or removed) =="
        BROKEN+=("$name")
        rm -rf "$CLONE"; continue
    fi

    case "$kind" in
        delete)
            sed -i.bak "${lineno}d" "$target" ;;
        sub)
            # @ is the sed delimiter; registry entries are written to avoid it.
            sed -i.bak "${lineno}s@$(printf '%s' "$from" | sed 's/[&@\\]/\\&/g')@$(printf '%s' "$to" | sed 's/[&@\\]/\\&/g')@" "$target" ;;
        *)
            echo "== $name: BROKEN — unknown kind '$kind' =="
            BROKEN+=("$name")
            rm -rf "$CLONE"; continue ;;
    esac
    rm -f "$target.bak"

    # Sentinel (D-TEST-14's lesson): confirm the mutation actually landed in
    # the copy that is about to run, before trusting anything the suite says
    # about it. A no-op sed (typo'd <from>, marker moved since) must be a
    # loud BROKEN, not a silent "everything passed."
    applied=1
    case "$kind" in
        delete)
            grep -qF "$marker" "$target" && applied=0 ;;
        sub)
            marked_line=$(grep -F "$marker" "$target" | head -1)
            printf '%s\n' "$marked_line" | grep -qF "$to" || applied=0 ;;
    esac
    if [ "$applied" != 1 ]; then
        echo "== $name: BROKEN — mutation did not apply to the clone (sentinel check failed) =="
        BROKEN+=("$name")
        rm -rf "$CLONE"; continue
    fi

    _run_clone "$CLONE"
    fails=$(_clone_fails "$CLONE")
    verdict_line=$(_clone_verdict "$CLONE")
    new_fails=""
    [ -n "$fails" ] && new_fails=$(comm -23 <(printf '%s\n' "$fails" | sort -u) <(printf '%s\n' "$BASELINE_FAILS" | sort -u))

    if [ -n "$new_fails" ]; then
        echo "== $name: CAUGHT — mutated suite went red on a NEW failure ($verdict_line) =="
        printf '%s\n' "$new_fails" | sed 's/^/    FAIL: /'
        CAUGHT+=("$name")
    else
        echo "== $name: ESCAPED — mutated suite stayed green, or only the baseline's own fail(s) fired ($verdict_line) — no test caught the removal of '$name' =="
        ESCAPED+=("$name")
    fi
    rm -rf "$CLONE"
done

echo
echo "mutate: ${#CAUGHT[@]} caught, ${#ESCAPED[@]} escaped, ${#BROKEN[@]} broken"
[ "${#ESCAPED[@]}" -gt 0 ] && echo "mutate: escaped by name —${ESCAPED[*]/#/ }"
[ "${#BROKEN[@]}" -gt 0 ] && echo "mutate: broken by name —${BROKEN[*]/#/ }"

[ "${#ESCAPED[@]}" -eq 0 ] && [ "${#BROKEN[@]}" -eq 0 ]
