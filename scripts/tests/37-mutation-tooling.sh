#!/usr/bin/env bash
# P45: "a test must prove it can fail" — the suite's own tooling for proving
# it, and the tests that prove THAT tooling itself is not another instance of
# the thing it exists to catch.
#
# Section 37 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

LINT="$(dirname "$TICK")/lint-tests.sh"
MUTATE="$(dirname "$TICK")/mutate.sh"

# --- lint-tests.sh: the ok-in-both-branches and loop-var-only-ok scan ------
# Two fixture files, neither ever executed — the lint pass only reads text.
# `planted.sh` carries one instance of each banned shape; `legit.sh` carries
# the real idioms they must NOT be confused with — D-TEST-04's actual shape
# is `ok` reachable from BOTH the && and the || side, not `cond && bad || ok`
# (the suite's own dominant "planted violation absent" idiom, sound because
# `bad()` always returns 0 — see lint-tests.sh's judgment-call comment) — and
# a loop whose ok-guard checks the per-iteration value, not just that the
# variable survived the loop.
#
# Compose the banned tokens so the real-suite lint remains clean while the
# generated fixture still contains the literal shapes the isolated scan must
# catch.
LF="$T/lintfix"; mkdir -p "$LF"
AND_OK='&& ok'; OR_OK='|| ok'
cat > "$LF/planted.sh" <<EOF
#!/usr/bin/env bash
# planted: ok on both sides of one &&/|| chain — reached either way
[ -f "/nonexistent-for-lint-fixture" ] $AND_OK "still counted even if this branch is wrong" $OR_OK "always reached when the check is false"

# planted: ok guarded only by the loop variable's non-emptiness
for widget in a b c; do
    [ "\$widget" = "zzz-never" ] && bad "never happens in this fixture"
done
[ -n "\${widget:-}" ] && ! [ -f "/nonexistent-marker-for-lint-fixture" ] \
    $AND_OK "vacuous: widget is just the loop var, unrelated file never varies" \
    || bad "unreachable"
EOF
cat > "$LF/legit.sh" <<'EOF'
#!/usr/bin/env bash
# legit: the standard idiom used throughout this suite — ok on the && side,
# bad on the || side. Must never be flagged by either check.
[ -f "/nonexistent-for-lint-fixture-legit" ] \
    && ok "legit: file present" \
    || bad "legit: file missing"

# legit: this suite's OTHER dominant idiom — a planted-violation check with
# bad on the && side (the violation was found) and ok on the || side (it was
# absent). Sound because bad() always returns 0; must never be flagged.
[ -f "/nonexistent-for-lint-fixture-legit2" ] \
    && bad "legit: violation found" \
    || ok "legit: violation absent"

# legit: the loop variable is compared against a real per-iteration value,
# not merely tested for non-emptiness — must never be flagged.
for id in one two three; do
    [ "$id" = "two" ] && ok "legit: iteration reached the expected id ($id)"
done
EOF
lint_out=$("$LINT" "$LF" 2>&1); lint_rc=$?
if [ "$lint_rc" != 0 ] \
   && printf '%s\n' "$lint_out" | grep -q '^planted\.sh:.*ok on both sides' \
   && printf '%s\n' "$lint_out" | grep -q '^planted\.sh:.*loop variable `widget`'; then
    ok "lint-tests: both planted shapes are caught, by name and line"
else
    bad "lint-tests: planted shapes not caught (rc=$lint_rc): $lint_out"
fi
if printf '%s\n' "$lint_out" | grep -q '^legit\.sh:'; then
    bad "lint-tests: a legitimate cond && ok || bad, cond && bad || ok, or real-comparison loop was flagged — $(printf '%s\n' "$lint_out" | grep '^legit\.sh:')"
else
    ok "lint-tests: the standard && ok || bad idiom and a real per-iteration comparison are never flagged"
fi
# Planted violation of the lint tool itself: a directory with no offenders
# must report clean, rc 0, nothing printed — or the tool cannot be trusted
# when it says nothing is wrong.
LF2="$T/lintfix-clean"; mkdir -p "$LF2"; cp "$LF/legit.sh" "$LF2/"
clean_out=$("$LINT" "$LF2" 2>&1); clean_rc=$?
[ "$clean_rc" = 0 ] && [ -z "$clean_out" ] \
    && ok "lint-tests: a directory with no offenders reports clean — rc 0, nothing printed" \
    || bad "lint-tests: a clean directory was not reported clean (rc=$clean_rc, out=$clean_out)"

# --- assert_mutant_ran (P45 bullet 2) ---------------------------------------
# The helper itself must fail loudly on exactly the shape D-TEST-05
# demonstrated (a stand-in that never ran — `exit 127`) and on the case that
# shape generalizes to (rc 126, or output empty even at rc 0), and must NOT
# call `bad` when the copy plainly ran. Each probe runs in an explicit
# subshell with its OWN PASS/FAIL so calling the real `bad` inside it never
# touches this section's own counts — only the probe's rc/PASS/FAIL, printed
# out and captured, are asserted on here.
_probe() { # <rc> <output> → prints "rc:pass:fail" from an isolated subshell
    ( PASS=0; FAIL=0
      assert_mutant_ran "$1" "$2" "probe" >/dev/null; r=$?
      printf '%s:%s:%s\n' "$r" "$PASS" "$FAIL" )
}
p=$(_probe 127 "some output")
[ "$p" = "1:0:1" ] && ok "assert_mutant_ran: rc 127 (not found) is caught and calls bad, not the caller's real check" \
    || bad "assert_mutant_ran: rc 127 not handled ($p)"
p=$(_probe 126 "some output")
[ "$p" = "1:0:1" ] && ok "assert_mutant_ran: rc 126 (not executable) is caught the same way" \
    || bad "assert_mutant_ran: rc 126 not handled ($p)"
p=$(_probe 0 "")
[ "$p" = "1:0:1" ] && ok "assert_mutant_ran: rc 0 with empty output is caught — 'ran silently' is not provable from nothing" \
    || bad "assert_mutant_ran: empty output at rc 0 not handled ($p)"
p=$(_probe 0 "the copy's real stdout")
[ "$p" = "0:0:0" ] && ok "assert_mutant_ran: a copy that plainly ran is passed through — no bad call, nothing counted" \
    || bad "assert_mutant_ran: a normal run was wrongly flagged ($p)"

# --- mutate.sh (P45 bullet 1): CAUGHT and ESCAPED, proven against a fixture -
# Reusing the real tick-test.sh/test-lib.sh (generic drivers, no dependency on
# tick.sh's actual content) with a two-line stand-in "tick.sh" and a single
# fixture section, so this proves the CLONE → MUTATE → RERUN → VERDICT
# pipeline itself rather than depending on any real registry entry's fate —
# the real entries are proven separately, by hand, and reported in the round
# that adds this file (mutate.sh's own comment 3 says why: a fresh entry's
# verdict is read once, not re-asserted here on every run).
MF="$T/mutfix"; mkdir -p "$MF/src/tests"
cp "$(dirname "$TICK")/tick-test.sh" "$(dirname "$TICK")/test-lib.sh" \
   "$(dirname "$TICK")/host-admission.sh" "$MF/src/"
printf '#!/usr/bin/env bash\nGUARD_OK=1  # mutate:demo-guard\n' > "$MF/src/tick.sh"
chmod +x "$MF/src/tick.sh"
printf 'demo-guard\ttick.sh\tdelete\n' > "$MF/registry.tsv"
# A real check: the guard line must still be there.
cat > "$MF/src/tests/01-check.sh" <<'EOF'
#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"
grep -q 'GUARD_OK=1' "$TICK" \
    && ok "fixture: guard line present in tick.sh" \
    || bad "fixture: guard line missing from tick.sh"
test_finish
EOF
mut_caught_out=$(LOOM_MUTATE_SRC="$MF/src" LOOM_MUTATE_REGISTRY_FILE="$MF/registry.tsv" "$MUTATE" demo-guard 2>&1)
mut_caught_rc=$?
if [ "$mut_caught_rc" = 0 ] && printf '%s\n' "$mut_caught_out" | grep -q 'demo-guard: CAUGHT'; then
    ok "mutate: a target whose guard is checked by a real test is reported CAUGHT, not falsely ESCAPED"
else
    bad "mutate: an intact-guard target was not reported CAUGHT (rc=$mut_caught_rc): $mut_caught_out"
fi
# A vacuous check standing in for "a test that can't fail" — the exact
# D-TEST-05 shape: it never reads $TICK at all, so removing the guard changes
# nothing it looks at.
cat > "$MF/src/tests/01-check.sh" <<'EOF'
#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"
ok "fixture: always passes, checks nothing about tick.sh"
test_finish
EOF
mut_escaped_out=$(LOOM_MUTATE_SRC="$MF/src" LOOM_MUTATE_REGISTRY_FILE="$MF/registry.tsv" "$MUTATE" demo-guard 2>&1)
mut_escaped_rc=$?
if [ "$mut_escaped_rc" = 1 ] && printf '%s\n' "$mut_escaped_out" | grep -q 'demo-guard: ESCAPED'; then
    ok "mutate: a target guarded only by a no-op stand-in is reported ESCAPED — the mechanism proves it can fail"
else
    bad "mutate: a no-op-guarded target was not reported ESCAPED (rc=$mut_escaped_rc): $mut_escaped_out"
fi
# --list must work against the fixture registry too — the seam is meant to
# be a full stand-in, not a partial one.
mut_list_out=$(LOOM_MUTATE_REGISTRY_FILE="$MF/registry.tsv" "$MUTATE" --list 2>&1)
printf '%s\n' "$mut_list_out" | grep -q '^demo-guard' \
    && ok "mutate: --list reads LOOM_MUTATE_REGISTRY_FILE like every other invocation" \
    || bad "mutate: --list ignored the registry override ($mut_list_out)"

test_finish
