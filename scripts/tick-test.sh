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
#   tick-test.sh --lint           scripts/lint-tests.sh: bans two `ok` shapes
#                                 that cannot fail (P45) — seconds, safe to
#                                 run every time
#   tick-test.sh --mutate [name..] scripts/mutate.sh: for each named guard /
#                                 destructive path / cap (every one, if no
#                                 name given), deletes or inverts it in a
#                                 scratch clone and asserts the suite goes
#                                 red — minutes, a `qa` check, not a suite one
#
# A section is standalone: `bash scripts/tests/07-snapshot.sh` works on its own
# and prints its own counts. That is the point of the split — the full run is
# minutes, one section is seconds.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
JOBS_DIR=""

_suite_cleanup() {
    command -v host_admission_maintenance_release >/dev/null 2>&1 \
      && host_admission_maintenance_release >/dev/null 2>&1 || true
    [ -z "$JOBS_DIR" ] || rm -rf "$JOBS_DIR"
}

# Only the real no-argument suite is heavyweight maintenance. Focused sections,
# lint, and fixture drivers with their own LOOM_TEST_DIR stay concurrent.
if [ $# -eq 0 ] && [ -z "${LOOM_TEST_DIR:-}" ]; then
    . "$DIR/host-admission.sh"
    HOST_ADMISSION_ROOT=$(host_admission_home)
    trap _suite_cleanup EXIT
    host_admission_maintenance_acquire "$HOST_ADMISSION_ROOT" \
      || { echo "tick-test: heavyweight host admission is unreadable" >&2; exit 1; }
fi

case "${1:-}" in
    --lint)   shift; exec "$DIR/lint-tests.sh" "$@" ;;
    --mutate) shift; exec "$DIR/mutate.sh" "$@" ;;
esac

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

# Sections are independent processes, each in its own mktemp sandbox (see
# test-lib.sh) — nothing shared, so nothing stops them running at once. The
# cap avoids thrashing a machine already busy running each section's own
# subprocesses (spawn-lane, git, jq); override with LOOM_TEST_JOBS.
ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)
MAXJOBS="${LOOM_TEST_JOBS:-$ncpu}"
case "$MAXJOBS" in *[!0-9]*) MAXJOBS=4;; esac
[ "$MAXJOBS" -gt 8 ] && MAXJOBS=8
[ "$MAXJOBS" -lt 1 ] && MAXJOBS=1

JOBS_DIR=$(mktemp -d); trap _suite_cleanup EXIT
names=(); logs=(); counts=()
i=0
for f in "${run[@]}"; do
    name=$(basename "$f" .sh)
    log="$JOBS_DIR/$name.log"; cnt="$JOBS_DIR/$name.counts"
    : > "$cnt"
    names[i]=$name; logs[i]=$log; counts[i]=$cnt
    # Poll for a free slot rather than `wait -n` — stock macOS bash (3.2) has
    # no `wait -n`; this works on anything with the `jobs` builtin.
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$MAXJOBS" ]; do sleep 0.05; done
    ( LOOM_TEST_COUNTS="$cnt" LOOM_TEST_QUIET=1 bash "$f" > "$log" 2>&1 ) &
    i=$((i+1))
done
wait

PASS=0; FAIL=0; BROKE=0
for ((j=0; j<i; j++)); do
    name="${names[j]}"; log="${logs[j]}"; cnt="${counts[j]}"
    cat "$log"
    # A section that never wrote its counts died before test_finish — an
    # unbound variable, a syntax error, a kill. Those tests did not run, so
    # they cannot be reported as passed: the driver counts the section itself
    # as one failure and says which.
    if [ ! -s "$cnt" ]; then
        echo "FAIL: $name: section exited without reporting counts"
        BROKE=$((BROKE+1)); FAIL=$((FAIL+1)); continue
    fi
    read -r p f_ < "$cnt"
    PASS=$((PASS+p)); FAIL=$((FAIL+f_))
done

echo
[ "$BROKE" -gt 0 ] && echo "== $BROKE section(s) did not finish =="
echo "== $PASS passed, $FAIL failed =="
exit $((FAIL > 0))
