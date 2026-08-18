#!/usr/bin/env bash
# Immutable releases switch atomically while old work stays pinned.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

if [ "${LOOM_RUNTIME_VALIDATING:-}" = 1 ]; then
    ok "runtime release: nested publication test is skipped during release validation"
    test_finish
    exit
fi

RUNTIME="$(dirname "$TICK")/runtime.sh"
SRC="$T/source"
RT="$T/runtime"
SELECTOR="$RT/consumers/test.active"
CUTOVER_HOME="$T/cutover-home"
mkdir -p "$SRC/scripts" "$CUTOVER_HOME"
: > "$CUTOVER_HOME/loop.stopped"
cp "$RUNTIME" "$SRC/scripts/runtime.sh"
printf '# test skill\n' > "$SRC/SKILL.md"
for name in lane agent; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SRC/scripts/$name.sh"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$SRC/scripts/tick-test.sh"
printf '#!/usr/bin/env bash\nprintf "A:%%s:%%s\\n" "$LOOM_RUNTIME_RELEASE" "$0"\n' > "$SRC/scripts/tick.sh"
chmod +x "$SRC/scripts"/*.sh
git -C "$SRC" init -q
git -C "$SRC" config user.email loom@test
git -C "$SRC" config user.name loom
git -C "$SRC" add .
git -C "$SRC" commit -qm A
A=$(git -C "$SRC" rev-parse 'HEAD^{tree}')

run_runtime() {
    LOOM_RUNTIME_HOME="$RT" LOOM_RUNTIME_SELECTOR="$SELECTOR" \
      LOOM_RUNTIME_SOURCE="$SRC" LOOM_HOME="$CUTOVER_HOME" "$RUNTIME" "$@"
}

rm -f "$CUTOVER_HOME/loop.stopped"
boundary_out=$(run_runtime publish 2>&1); boundary_rc=$?
if [ "$boundary_rc" -ne 0 ] && [ ! -e "$SELECTOR" ] \
   && printf '%s' "$boundary_out" | grep -q 'requires a stopped build'; then
    ok "runtime release: first cutover refuses a running build before visibility"
else
    bad "runtime release: first cutover bypassed the stopped boundary"
fi
: > "$CUTOVER_HOME/loop.stopped"

out=$(run_runtime publish)
first=$(run_runtime run -- tick)
if printf '%s' "$out" | grep -q -- "-> $A" \
   && printf '%s' "$first" | grep -q "^A:$A:$RT/releases/$A/scripts/tick.sh$" \
   && [ "$(sed -n 's/^current //p' "$SELECTOR")" = "$A" ]; then
    ok "runtime release: publish exposes one validated committed tree and dispatches its physical path"
else
    bad "runtime release: first committed release was not selected safely"
fi

printf '#!/usr/bin/env bash\nprintf "B:%%s:%%s\\n" "$LOOM_RUNTIME_RELEASE" "$0"\n' > "$SRC/scripts/tick.sh"
git -C "$SRC" add scripts/tick.sh
git -C "$SRC" commit -qm B
B=$(git -C "$SRC" rev-parse 'HEAD^{tree}')
run_runtime publish >/dev/null
fresh=$(run_runtime run -- tick)
pinned=$(run_runtime run --release "$A" -- tick)
if printf '%s' "$fresh" | grep -q "^B:$B:" \
   && printf '%s' "$pinned" | grep -q "^A:$A:" \
   && [ "$(sed -n 's/^previous //p' "$SELECTOR")" = "$A" ]; then
    ok "runtime release: promotion changes fresh dispatch while explicit old work remains pinned"
else
    bad "runtime release: promotion mixed or lost the prior release"
fi

run_runtime rollback >/dev/null
rolled=$(run_runtime run -- tick)
if printf '%s' "$rolled" | grep -q "^A:$A:" \
   && [ "$(sed -n 's/^previous //p' "$SELECTOR")" = "$B" ]; then
    ok "runtime release: rollback atomically selects the previous release"
else
    bad "runtime release: rollback did not restore the previous release"
fi

printf '#!/usr/bin/env bash\nif then\n' > "$SRC/scripts/agent.sh"
git -C "$SRC" add scripts/agent.sh
git -C "$SRC" commit -qm broken-shell
broken_out=$(run_runtime publish 2>&1); broken_rc=$?
if [ "$broken_rc" -ne 0 ] \
   && [ "$(sed -n 's/^current //p' "$SELECTOR")" = "$A" ] \
   && printf '%s' "$broken_out" | grep -q 'shell syntax failed'; then
    ok "runtime release: failed validation leaves the selector byte-safe"
else
    bad "runtime release: malformed shell moved the active selector"
fi

git -C "$SRC" checkout -q HEAD^ -- scripts/agent.sh
printf '#!/usr/bin/env bash\nexit 1\n' > "$SRC/scripts/tick-test.sh"
git -C "$SRC" add scripts/agent.sh scripts/tick-test.sh
git -C "$SRC" commit -qm failing-suite
suite_out=$(run_runtime publish 2>&1); suite_rc=$?
if [ "$suite_rc" -ne 0 ] \
   && [ "$(sed -n 's/^current //p' "$SELECTOR")" = "$A" ] \
   && printf '%s' "$suite_out" | grep -q 'release test'; then
    ok "runtime release: a red full suite cannot become active"
else
    bad "runtime release: red suite changed the active release"
fi

printf 'schema 1\ncurrent ../../outside\n' > "$SELECTOR"
escape_out=$(run_runtime run -- tick 2>&1); escape_rc=$?
if [ "$escape_rc" -ne 0 ] && printf '%s' "$escape_out" | grep -q 'missing or incomplete'; then
    ok "runtime release: malformed selectors fail closed before code starts"
else
    bad "runtime release: malformed selector reached executable code"
fi

chmod -R u+w "$RT/releases" 2>/dev/null || true
test_finish
