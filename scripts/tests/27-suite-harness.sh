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

# --- D-TEST-15: the one thing sections share -------------------------------
# Each section gets its own process and its own $T, so the driver runs them at
# once. The single exception is the SHIPPED directory — scripts/ itself, where
# tick.sh, lane.sh, lib.sh and the nine jq programs live, and which every
# section resolves its subject out of. Three sections used to plant a "the file
# is missing" violation by moving the real file aside and back (`mv $LIBSH
# aside; run; mv back`). Run alone that is exactly right. Run beside twenty-nine
# others it takes the file away from all of them for the length of the window,
# and they fail on it: `module not found: lib` out of a tracker-driver snapshot,
# `lib.sh is missing` out of a gate-deps refusal, a wave that never launched.
# Five assertions in four files, none of them the one under test, and which ones
# is pure timing — the suite disagreed with itself run to run on unchanged code.
# The fix is `mirror_scripts` (test-lib.sh): plant it in a private copy. This is
# the check that keeps it fixed.
#
# `mv <shipped>` is the exact shape, so it is the exact thing scanned for —
# spelled inline, or through any variable the section assigned from the shipped
# directory. Sections read that directory constantly (`cp` out of it, `grep`
# over it); only taking a file OUT of it is the defect.
_shared_dir_moves() { # <section file> → its offending `mv` lines, if any
    local f="$1" names alt
    names=$(sed -n -E 's/^[[:space:]]*(local[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*dirname "\$TICK".*/\2/p' \
            "$f" | sort -u | tr '\n' '|')
    # The four the harness itself hands every section, plus the section's own.
    alt="TICK|SNAPJQ|LANE|LIBSH|${names}"; alt="${alt%|}"
    grep -nE "^[[:space:]]*mv[[:space:]]+\"(\\\$\{?($alt)\}?|\\\$\(dirname \"\\\$TICK\"\))" "$f"
}
h_shared=""
for f in "$SD"/*.sh; do
    hit=$(_shared_dir_moves "$f")
    [ -n "$hit" ] && h_shared="$h_shared $(basename "$f"):$(printf '%s' "$hit" | head -1 | cut -d: -f1)"
done
[ -z "$h_shared" ] \
    && ok "suite: no section moves a shipped file out of the directory every section shares" \
    || bad "suite: sections hide shipped files from each other —$h_shared"

# Planted violation: the same scan over a section that does it must find it, or
# the assertion above is reading nothing.
mkdir -p "$HP/shared"
# Assembled through printf rather than written out as a heredoc, so the
# offending line exists in the PLANTED file and nowhere in this one — a scan
# that ran over its own plant would report this section as an offender and
# there would be no way to tell that from a real one.
{ printf '#!/usr/bin/env bash\n'
  printf 'PLANTJQ="$(dirname "$TICK")/plan.jq"\n'
  printf 'mv "$%s" "$T/plan.jq.hidden"\n' PLANTJQ
  printf 'mv "$T/plan.jq.hidden" "$%s"\n' PLANTJQ
} > "$HP/shared/01-hides.sh"
# And the fixed shape must NOT trip it: a mirror is a directory of its own, so
# moving a file inside one is invisible to every other section.
cat > "$HP/shared/02-mirrors.sh" <<'EOF'
#!/usr/bin/env bash
MSCRIPTS="$(mirror_scripts "$T/mirror")"
cp "$(dirname "$TICK")"/*.jq "$MSCRIPTS/"
mv "$MSCRIPTS/plan.jq" "$T/plan.jq.hidden"
mv "$T/plan.jq.hidden" "$MSCRIPTS/plan.jq"
EOF
if [ -n "$(_shared_dir_moves "$HP/shared/01-hides.sh")" ] \
   && [ -z "$(_shared_dir_moves "$HP/shared/02-mirrors.sh")" ]; then
    ok "suite-violation: the scan catches a section hiding a shipped file, and passes a mirror"
else
    bad "suite-violation: the scan read the plant as clean or the mirror as dirty"
fi

test_finish
