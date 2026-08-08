#!/usr/bin/env bash
# Planted-violation tests for tick.sh and lane.sh (ticket #88 acceptance).
# Every guard is shown BOTH holding and failing when its mechanism is
# removed — a guard you have never seen fail is not a guard.
#
# This file is the DRIVER. The tests live in scripts/tests/NN-<topic>.sh, one
# process each, over the shared harness in scripts/test-lib.sh. Running it with
# no arguments runs every section, exactly as the single-file suite did.
#
#   tick-test.sh                  every section, in order
#   tick-test.sh snapshot         only sections whose name matches `snapshot`
#   tick-test.sh 07 21            by number
#   tick-test.sh --list           what the sections are
#
# A section is standalone: `bash scripts/tests/07-snapshot.sh` works on its own
# and prints its own counts. That is the point of the split — the full run is
# minutes, one section is seconds.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# The section directory is a seam so the harness section can drive this file
# against planted sections instead of the real ones.
TESTS="${LOOM_TEST_DIR:-$DIR/tests}"

[ -d "$TESTS" ] || { echo "no section directory at $TESTS" >&2; exit 2; }

all=()
for f in "$TESTS"/*.sh; do [ -e "$f" ] && all+=("$f"); done
[ ${#all[@]} -gt 0 ] || { echo "no sections in $TESTS" >&2; exit 2; }

if [ "${1:-}" = "--list" ]; then
    for f in "${all[@]}"; do
        printf '%-30s %s\n' "$(basename "$f" .sh)" "$(sed -n '2s/^# //p' "$f")"
    done
    exit 0
fi

# Arguments select sections by substring of the file name; no arguments runs
# every one. An argument matching nothing is an error, never a silent no-op.
run=()
if [ $# -gt 0 ]; then
    for pat in "$@"; do
        hit=0
        for f in "${all[@]}"; do
            case "$(basename "$f")" in *"$pat"*) run+=("$f"); hit=1;; esac
        done
        [ "$hit" = 1 ] || { echo "no section matches '$pat' — try --list" >&2; exit 2; }
    done
else
    run=("${all[@]}")
fi

COUNTS=$(mktemp); trap 'rm -f "$COUNTS"' EXIT
PASS=0; FAIL=0; BROKE=0
for f in "${run[@]}"; do
    name=$(basename "$f" .sh)
    : > "$COUNTS"
    LOOM_TEST_COUNTS="$COUNTS" LOOM_TEST_QUIET=1 bash "$f"
    rc=$?
    # A section that never wrote its counts died before test_finish — an
    # unbound variable, a syntax error, a kill. Those tests did not run, so
    # they cannot be reported as passed: the driver counts the section itself
    # as one failure and says which.
    if [ ! -s "$COUNTS" ]; then
        echo "FAIL: $name: section exited (rc $rc) without reporting counts"
        BROKE=$((BROKE+1)); FAIL=$((FAIL+1)); continue
    fi
    read -r p f_ < "$COUNTS"
    PASS=$((PASS+p)); FAIL=$((FAIL+f_))
done

echo
[ "$BROKE" -gt 0 ] && echo "== $BROKE section(s) did not finish =="
echo "== $PASS passed, $FAIL failed =="
exit $((FAIL > 0))
