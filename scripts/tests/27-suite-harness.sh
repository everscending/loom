#!/usr/bin/env bash
# the driver and the section contract that P76's split rests on
#
# Section 27 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- P76: the split itself ------------------------------------------------
# Splitting one 7,400-line file into twenty-seven processes moved the counting
# out of the shell that runs the tests and into a driver that reads it back.
# That is a new way for tests to disappear: a section that dies early, or one
# that never calls test_finish, used to be impossible and is now a silent
# green if nothing checks. These are the checks.
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$(dirname "$TICK")/tick-test.sh"

# p76a. The section contract: every section sources the harness and ends by
#       calling test_finish. Without the source it has no ok/bad; without the
#       call it reports no counts and every pass it printed is discarded.
h_bad=""
for f in "$SD"/*.sh; do
    grep -q '^\. "\$(cd "\$(dirname "\${BASH_SOURCE\[0\]}")/\.\." && pwd)/test-lib\.sh"$' "$f" \
        || h_bad="$h_bad $(basename "$f"):no-source"
    [ "$(tail -1 "$f")" = "test_finish" ] || h_bad="$h_bad $(basename "$f"):no-finish"
done
[ -z "$h_bad" ] \
    && ok "suite: every section sources the harness and ends at test_finish" \
    || bad "suite: sections break the contract —$h_bad"

# p76b. Planted violation: the same check against a section that forgot the
#       call must fail, or it is asserting nothing about the real ones.
HP="$T/harness"; mkdir -p "$HP/forgot"
printf '#!/usr/bin/env bash\n. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"\nok x\n' \
    > "$HP/forgot/01-forgot.sh"
[ "$(tail -1 "$HP/forgot/01-forgot.sh")" = "test_finish" ] \
    && bad "suite-violation: a section with no test_finish passed the contract check" \
    || ok "suite-violation: a section with no test_finish is caught by the same check"

# p76c. A section that dies before test_finish is a FAILURE, never a section
#       quietly worth zero. This is the whole risk of counting across
#       processes: the passes it printed before dying are not evidence, and the
#       tests after the death never ran at all.
mkdir -p "$HP/dies"
cat > "$HP/dies/01-dies.sh" <<EOF
#!/usr/bin/env bash
. "$(dirname "$TICK")/test-lib.sh"
ok "planted: a pass printed before the death"
echo "\$THIS_IS_NOT_SET"
test_finish
EOF
h_out=$(LOOM_TEST_DIR="$HP/dies" bash "$DRIVER" 2>&1); h_rc=$?
if [ "$h_rc" != 0 ] && printf '%s' "$h_out" | grep -q "without reporting counts" \
   && printf '%s' "$h_out" | grep -q "== 0 passed, 1 failed =="; then
    ok "suite: a section that dies early is reported as a failure, not counted as zero"
else
    bad "suite: the dying section was not caught (rc=$h_rc, $(printf '%s' "$h_out" | tail -1))"
fi

# p76d. A section that finishes reports its own counts, and the driver adds
#       them up rather than re-counting the printed lines.
mkdir -p "$HP/two"
for n in 1 2; do
    cat > "$HP/two/0$n-part.sh" <<EOF
#!/usr/bin/env bash
. "$(dirname "$TICK")/test-lib.sh"
ok "planted $n a"
ok "planted $n b"
test_finish
EOF
done
h_out=$(LOOM_TEST_DIR="$HP/two" bash "$DRIVER" 2>&1); h_rc=$?
# Four planted passes plus the pane guard each section runs for itself.
[ "$h_rc" = 0 ] && printf '%s' "$h_out" | grep -q "== 6 passed, 0 failed ==" \
    && ok "suite: the driver totals the sections' own counts" \
    || bad "suite: totals wrong (rc=$h_rc, $(printf '%s' "$h_out" | tail -1))"

# p76e. A filter that matches nothing is an error, never a silent green. The
#       failure mode it exists to stop is a typo that runs zero tests and
#       reports success — which reads exactly like a clean suite.
h_out=$(LOOM_TEST_DIR="$HP/two" bash "$DRIVER" nosuchsection 2>&1); h_rc=$?
[ "$h_rc" = 2 ] && printf '%s' "$h_out" | grep -q "no section matches" \
    && ok "suite: a filter matching nothing fails loudly instead of running nothing" \
    || bad "suite: an unmatched filter returned rc=$h_rc ($h_out)"

# p76f. And a filter that DOES match runs only what it names — otherwise the
#       whole point of the split, iterating on one section in seconds, is gone.
h_out=$(LOOM_TEST_DIR="$HP/two" bash "$DRIVER" 02 2>&1); h_rc=$?
[ "$h_rc" = 0 ] && printf '%s' "$h_out" | grep -q "== 3 passed, 0 failed ==" \
    && ! printf '%s' "$h_out" | grep -q "planted 1" \
    && ok "suite: a filter runs the section it names and no other" \
    || bad "suite: the filter ran the wrong set (rc=$h_rc, $(printf '%s' "$h_out" | tail -1))"

test_finish
