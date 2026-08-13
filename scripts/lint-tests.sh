#!/usr/bin/env bash
# P45 bullet 3: a static scan for two `ok` shapes that cannot fail — found by
# hand on 2026-08-06, now mechanical so the next instance is a red run instead
# of a fourth review round.
#
#   scripts/lint-tests.sh [dir]        scan every *.sh in dir (default: tests/)
#
# Exits 1 and prints one line per violation, `<file>:<line>: <reason> — <text>`,
# when either shape is found; exits 0 and prints nothing otherwise. Normally
# invoked as `tick-test.sh --lint`.
#
# == What it bans ==
#
# 1. `ok` on BOTH sides of one &&/|| chain — `cond && ok "…" || ok "…"`. This
#    is the shape the suite's own comment records killing in the ntfy block on
#    2026-08-01 and that survived once more as D-TEST-04 (`… && ok
#    "violation absent" || ok "harmless if present"`): whichever way `cond`
#    goes, `ok` runs, so the line is a guaranteed +1 to the pass count no
#    matter what it claims to check.
#
#    JUDGMENT CALL: P45's prose says "banning `|| ok`" without qualification.
#    Taken literally that also matches this suite's single most common
#    assertion shape — `cond && bad "violation present" || ok "violation
#    absent"`, the planted-violation idiom used dozens of times per section —
#    because `bad()` always returns 0 (`FAIL=$((FAIL+1))`'s own exit status),
#    so `cond && bad … || ok …` is sound: `ok` only fires when `cond` itself
#    was false, `bad` only when it was true, never both. A literal `|| ok`
#    scan was tried first and flagged the majority of the suite's PASSING,
#    correct assertions — not the bug. What actually cannot fail is `ok`
#    reachable from BOTH arms, so that is what this scans for; a `bad` on the
#    `&&` side is always left alone.
#
# 2. An `ok` inside (or, since a `for` variable survives its loop, just after)
#    a `for VAR in …; do … done` whose guarding condition references `VAR`
#    exactly once, and only inside a `-n`/`-z` emptiness test. `VAR` is the
#    loop's OWN variable — testing that it is merely non-empty is testing
#    that the loop ran at all, not that iteration `VAR` was the case the test
#    means to check, and a condition with no OTHER reference to `VAR` never
#    varies with which item the loop was on. D-TEST-09 is this exact shape:
#    `[ -n "${bad_id:-}" ] && ! [ -f ".../12.pid" ] && ok …` after `for bad_id
#    in 12 gate12 lane_14 impl impl- xyz-1`, where the second conjunct
#    hardcodes `12` instead of reading `$bad_id` — the printed pass is silent
#    about five of the six ids in the list.
#    A guard that references `VAR` a second time (a real comparison against
#    the per-iteration value) is untouched — only the single, empty-test-only
#    reference is banned.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$DIR/tests}"
[ -d "$TARGET" ] || { echo "lint-tests: no such directory $TARGET" >&2; exit 2; }

violations=0

# Joins backslash-continued physical lines into one logical line, printing
# "<first-physical-line-number><TAB><logical line>" — this codebase's tests
# routinely split a `cond && ok … || bad …` chain across lines with a
# trailing `\`, and a per-physical-line scan would see three fragments, none
# of which contains the whole shape either check below looks for. A literal
# TAB is the delimiter (not e.g. \x01) because macOS's /usr/bin/awk — the
# non-gawk "one true awk" — does not interpret \xHH escapes the way gawk
# does; \t is portable to both.
_join_logical() { # <file>
    awk '
    {
        if (cont) { buf = buf " " $0 } else { buf = $0; startln = NR }
        if ($0 ~ /\\[[:space:]]*$/) {
            sub(/\\[[:space:]]*$/, "", buf); cont = 1; next
        }
        print startln "\t" buf
        buf = ""; cont = 0
    }
    END { if (cont) print startln "\t" buf }
    ' "$1"
}

for f in "$TARGET"/*.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    curvar=""
    while IFS=$'\t' read -r ln logical; do
        [ -n "$logical" ] || continue

        # --- Check 1: `ok` on both sides of one &&/|| chain -------------
        # `&& ok` reachable from a chain that ALSO reaches `|| ok` — see the
        # judgment-call note above for why this is narrower than "|| ok".
        both_ok_pat='&&[[:space:]]*ok([[:space:]]|\().*\|\|[[:space:]]*ok([[:space:]]|\()'
        if [[ "$logical" =~ $both_ok_pat ]]; then
            violations=$((violations+1))
            printf '%s:%s: ok on both sides of one &&/|| chain — always reached whichever way the check goes — %s\n' \
                "$base" "$ln" "$(printf '%s' "$logical" | sed 's/^[[:space:]]*//')"
        fi

        # --- track the most recent `for VAR in` --------------------------
        for_pat='(^|;)[[:space:]]*for[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+in([[:space:]]|$)'
        if [[ "$logical" =~ $for_pat ]]; then
            curvar="${BASH_REMATCH[2]}"
        fi

        # --- Check 2: ok guarded only by its own loop var's non-emptiness -
        guard_pat='^(.*)&&[[:space:]]*ok([[:space:]]|\()'
        if [ -n "$curvar" ] && [[ "$logical" =~ $guard_pat ]]; then
            guard="${BASH_REMATCH[1]}"
            var_re='\$\{?'"$curvar"'([^A-Za-z0-9_]|$)'
            cnt=$(grep -oE "$var_re" <<<"$guard" 2>/dev/null | wc -l | tr -d ' ')
            nz_re='-[nz][[:space:]]+"'"$var_re"
            if [ "$cnt" = 1 ] && grep -qE -- "$nz_re" <<<"$guard" 2>/dev/null; then
                violations=$((violations+1))
                printf '%s:%s: ok guarded only by loop variable `%s` being non-empty (no other reference to it in the condition) — %s\n' \
                    "$base" "$ln" "$curvar" "$(printf '%s' "$logical" | sed 's/^[[:space:]]*//')"
            fi
        fi
    done < <(_join_logical "$f")
done

exit $((violations > 0))
