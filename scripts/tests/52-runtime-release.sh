#!/usr/bin/env bash
# Immutable releases switch atomically while old work stays pinned.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

RUNTIME="$(dirname "$TICK")/runtime.sh"
SRC="$T/source"
RT="$T/runtime"
SELECTOR="$RT/consumers/test.active"
CUTOVER_HOME="$T/cutover-home"
mkdir -p "$SRC/scripts" "$CUTOVER_HOME"
: > "$CUTOVER_HOME/loop.stopped"
cp "$RUNTIME" "$SRC/scripts/runtime.sh"
printf '# test skill\n' > "$SRC/SKILL.md"
printf 'host_state_api 1\n' > "$SRC/runtime-abi"
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
      LOOM_RUNTIME_SOURCE="$SRC" LOOM_HOME="$CUTOVER_HOME" LOOM_RUNTIME_CUTOVER_UNARMED=1 \
      "$RUNTIME" "$@"
}

run_launcher() {
    LOOM_RUNTIME_HOME="$RT" LOOM_RUNTIME_SELECTOR="$SELECTOR" \
      LOOM_HOME="$CUTOVER_HOME" "$RT/bin/loom-runtime" "$@"
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
mkdir -p "$CUTOVER_HOME/tick.lock.d"
printf '%s\n' "$$" > "$CUTOVER_HOME/tick.lock.d/pid"
wave_out=$(run_runtime publish 2>&1); wave_rc=$?
if [ "$wave_rc" -ne 0 ] && [ ! -e "$SELECTOR" ] \
   && printf '%s' "$wave_out" | grep -q 'scheduling wave'; then
    ok "runtime release: first cutover refuses a live legacy wave"
else
    bad "runtime release: first cutover crossed a live legacy wave"
fi
rm -rf "$CUTOVER_HOME/tick.lock.d"

mkdir -p "$CUTOVER_HOME/lanes"
: > "$CUTOVER_HOME/lanes/legacy.pid"
lane_out=$(run_runtime publish 2>&1); lane_rc=$?
if [ "$lane_rc" -ne 0 ] && [ ! -e "$SELECTOR" ] \
   && printf '%s' "$lane_out" | grep -q 'lane metadata'; then
    ok "runtime release: first cutover refuses retained lane metadata"
else
    bad "runtime release: first cutover crossed retained lane metadata"
fi
rm -f "$CUTOVER_HOME/lanes/legacy.pid"
rmdir "$CUTOVER_HOME/lanes"
printf 'malformed\n' > "$CUTOVER_HOME/lanes"
malformed_out=$(run_runtime publish 2>&1); malformed_rc=$?
if [ "$malformed_rc" -ne 0 ] && [ ! -e "$SELECTOR" ] \
   && printf '%s' "$malformed_out" | grep -q 'cannot prove lane metadata'; then
    ok "runtime release: malformed lane state fails the drained proof closed"
else
    bad "runtime release: malformed lane state passed as drained"
fi
rm -f "$CUTOVER_HOME/lanes"

mkdir -p "$CUTOVER_HOME/lane-launch-queue/request-live" \
         "$CUTOVER_HOME/lane-launch-queue/launching-live"
queue_out=$(run_runtime publish 2>&1); queue_rc=$?
if [ "$queue_rc" -ne 0 ] && [ ! -e "$SELECTOR" ] \
   && printf '%s' "$queue_out" | grep -q 'deferred launches'; then
    ok "runtime release: first cutover refuses requested and launching handoffs"
else
    bad "runtime release: first cutover crossed durable handoff metadata"
fi
rm -rf "$CUTOVER_HOME/lane-launch-queue"

mkdir -p "$RT/bin"
printf '#!/bin/sh\nexit 0\n' > "$RT/bin/loom-runtime"; chmod +x "$RT/bin/loom-runtime"
launcher_out=$(run_runtime publish 2>&1); launcher_rc=$?
if [ "$launcher_rc" -ne 0 ] && [ ! -e "$SELECTOR" ] \
   && printf '%s' "$launcher_out" | grep -q 'stable launcher is missing, untrusted, or modified'; then
    ok "runtime release: first cutover rejects an untrusted pre-existing launcher"
else
    bad "runtime release: first cutover trusted an unknown launcher"
fi
rm -f "$RT/bin/loom-runtime"

out=$(run_runtime publish)
first=$(run_launcher run -- tick)
if printf '%s' "$out" | grep -q -- "-> $A" \
   && printf '%s' "$first" | grep -q "^A:$A:$RT/releases/$A/scripts/tick.sh$" \
   && [ "$(sed -n 's/^current //p' "$SELECTOR")" = "$A" ] \
   && [ -f "$RT/releases/$A/SKILL.md" ]; then
    ok "runtime release: publish exposes one validated committed tree and dispatches its physical path"
else
    bad "runtime release: first committed release was not selected safely"
fi
mv "$SRC" "$SRC.moved"
detached_source=$(run_launcher run -- tick)
mv "$SRC.moved" "$SRC"
if printf '%s' "$detached_source" | grep -q "^A:$A:$RT/releases/$A/scripts/tick.sh$"; then
    ok "runtime release: retained objects keep dispatch independent of the source worktree"
else
    bad "runtime release: dispatch still depends on the publishing worktree"
fi
LOADER_SUM=$(cksum "$RT/bin/loom-runtime")

printf '#!/usr/bin/env bash\nprintf "B:%%s:%%s\\n" "$LOOM_RUNTIME_RELEASE" "$0"\n' > "$SRC/scripts/tick.sh"
git -C "$SRC" add scripts/tick.sh
git -C "$SRC" commit -qm B
B_COMMIT=$(git -C "$SRC" rev-parse HEAD)
B=$(git -C "$SRC" rev-parse 'HEAD^{tree}')
run_runtime publish >/dev/null
fresh=$(run_launcher run -- tick)
pinned=$(run_launcher run --release "$A" -- tick)
if printf '%s' "$fresh" | grep -q "^B:$B:" \
   && printf '%s' "$pinned" | grep -q "^A:$A:" \
   && [ "$(sed -n 's/^previous //p' "$SELECTOR")" = "$A" ] \
   && [ "$(cksum "$RT/bin/loom-runtime")" = "$LOADER_SUM" ]; then
    ok "runtime release: promotion changes fresh dispatch while explicit old work remains pinned"
else
    bad "runtime release: promotion mixed or lost the prior release"
fi

run_runtime rollback >/dev/null
rolled=$(run_launcher run -- tick)
if printf '%s' "$rolled" | grep -q "^A:$A:" \
   && [ "$(sed -n 's/^previous //p' "$SELECTOR")" = "$B" ]; then
    ok "runtime release: rollback atomically selects the previous release"
else
    bad "runtime release: rollback did not restore the previous release"
fi

printf 'host_state_api 2\n' > "$SRC/runtime-abi"
git -C "$SRC" add runtime-abi
git -C "$SRC" commit -qm incompatible-api
INCOMPATIBLE=$(git -C "$SRC" rev-parse 'HEAD^{tree}')
compat_out=$(run_runtime publish 2>&1); compat_rc=$?
if [ "$compat_rc" -ne 0 ] && [ "$(sed -n 's/^current //p' "$SELECTOR")" = "$A" ] \
   && printf '%s' "$compat_out" | grep -q 'state API differs'; then
    ok "runtime release: committed incompatible APIs cannot be promoted"
else
    bad "runtime release: promotion trusted derived compatibility metadata"
fi
migrate_out=$(run_runtime publish --migrate 2>&1); migrate_rc=$?
if [ "$migrate_rc" -eq 0 ] \
   && [ "$(sed -n 's/^current //p' "$SELECTOR")" = "$INCOMPATIBLE" ]; then
    ok "runtime release: explicit stopped migration promotes a new state API"
else
    bad "runtime release: stopped state API migration was unavailable ($migrate_out)"
fi
printf 'current %s\nprevious %s\n' "$INCOMPATIBLE" "$A" > "$SELECTOR"
rollback_out=$(run_runtime rollback 2>&1); rollback_rc=$?
if [ "$rollback_rc" -ne 0 ] && [ "$(sed -n 's/^current //p' "$SELECTOR")" = "$INCOMPATIBLE" ] \
   && printf '%s' "$rollback_out" | grep -q 'state API differs'; then
    ok "runtime release: rollback refuses an incompatible state transition"
else
    bad "runtime release: rollback trusted derived compatibility metadata"
fi
printf 'current %s\nprevious %s\n' "$A" "$B" > "$SELECTOR"
git -C "$SRC" checkout -q "$B_COMMIT"

chmod u+w "$RT/releases/$B" "$RT/releases/$B/SKILL.md"
printf 'tampered\n' >> "$RT/releases/$B/SKILL.md"
chmod a-w "$RT/releases/$B/SKILL.md" "$RT/releases/$B"
tamper_out=$(run_runtime publish 2>&1); tamper_rc=$?
rollback_tamper_out=$(run_runtime rollback 2>&1); rollback_tamper_rc=$?
run_tamper_out=$(run_launcher run --release "$B" -- tick 2>&1); run_tamper_rc=$?
if [ "$tamper_rc" -ne 0 ] && [ "$rollback_tamper_rc" -ne 0 ] && [ "$run_tamper_rc" -ne 0 ] \
   && [ "$(sed -n 's/^current //p' "$SELECTOR")" = "$A" ] \
   && printf '%s' "$tamper_out" | grep -q "committed export transformed 'SKILL.md'"; then
    ok "runtime release: publish, rollback, and pinned dispatch reject modified cached bytes"
else
    bad "runtime release: a cached release bypassed committed-tree verification"
fi
chmod u+w "$RT/releases/$B" "$RT/releases/$B/SKILL.md"
cp "$SRC/SKILL.md" "$RT/releases/$B/SKILL.md"
chmod a-w "$RT/releases/$B/SKILL.md" "$RT/releases/$B"

chmod u+w "$RT/releases/$B" "$RT/releases/$B/SKILL.md"
mv "$RT/releases/$B/SKILL.md" "$RT/releases/$B/SKILL.real"
ln -s SKILL.real "$RT/releases/$B/SKILL.md"
chmod a-w "$RT/releases/$B/SKILL.real" "$RT/releases/$B"
symlink_out=$(run_runtime publish 2>&1); symlink_rc=$?
if [ "$symlink_rc" -ne 0 ] && [ "$(sed -n 's/^current //p' "$SELECTOR")" = "$A" ] \
   && printf '%s' "$symlink_out" | grep -q 'symbolic link'; then
    ok "runtime release: symlink substitution cannot preserve a cached release identity"
else
    bad "runtime release: cached symlink substitution bypassed exact verification"
fi
chmod u+w "$RT/releases/$B"
rm "$RT/releases/$B/SKILL.md"
mv "$RT/releases/$B/SKILL.real" "$RT/releases/$B/SKILL.md"
chmod a-w "$RT/releases/$B/SKILL.md" "$RT/releases/$B"

chmod u+w "$RT/releases/$B"
mkdir "$RT/releases/$B/unexpected-empty"
empty_out=$(run_runtime publish 2>&1); empty_rc=$?
rmdir "$RT/releases/$B/unexpected-empty"
mkfifo "$RT/releases/$B/unexpected-node"
node_out=$(run_runtime publish 2>&1); node_rc=$?
rm -f "$RT/releases/$B/unexpected-node"
chmod a-w "$RT/releases/$B"
if [ "$empty_rc" -ne 0 ] && [ "$node_rc" -ne 0 ] \
   && printf '%s' "$empty_out" | grep -q 'unexpected directory' \
   && printf '%s' "$node_out" | grep -q 'unexpected special node'; then
    ok "runtime release: exact verification rejects empty directories and special nodes"
else
    bad "runtime release: non-committed filesystem nodes survived exact verification"
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

git -C "$SRC" checkout -q HEAD^ -- scripts/tick-test.sh
printf 'SKILL.md export-ignore\n' > "$SRC/.gitattributes"
git -C "$SRC" add scripts/tick-test.sh .gitattributes
git -C "$SRC" commit -qm transformed-export
attribute_out=$(run_runtime publish 2>&1); attribute_rc=$?
C=$(git -C "$SRC" rev-parse 'HEAD^{tree}')
if [ "$attribute_rc" -eq 0 ] \
   && [ "$(sed -n 's/^current //p' "$SELECTOR")" = "$C" ] \
   && cmp -s "$SRC/SKILL.md" "$RT/releases/$C/SKILL.md"; then
    ok "runtime release: raw Git blobs ignore export and checkout transformations"
else
    bad "runtime release: attributes changed or omitted committed release bytes ($attribute_out)"
fi

EVIL_BLOB=$(printf 'escaped\n' | git -C "$SRC" hash-object -w --stdin)
EVIL_SUBTREE=$(printf '100644 blob %s\toutside-proof\n' "$EVIL_BLOB" | git -C "$SRC" mktree)
git -C "$SRC" ls-tree HEAD > "$T/evil-tree"
printf '040000 tree %s\t..\n' "$EVIL_SUBTREE" >> "$T/evil-tree"
EVIL_TREE=$(git -C "$SRC" mktree < "$T/evil-tree")
EVIL_COMMIT=$(printf 'unsafe tree\n' | git -C "$SRC" commit-tree "$EVIL_TREE" -p HEAD)
unsafe_out=$(run_runtime publish "$EVIL_COMMIT" 2>&1); unsafe_rc=$?
if [ "$unsafe_rc" -ne 0 ] && [ ! -e "$RT/releases/outside-proof" ] \
   && printf '%s' "$unsafe_out" | grep -q "unsafe path '../outside-proof'"; then
    ok "runtime release: crafted dot-dot trees cannot escape staging"
else
    bad "runtime release: crafted Git path escaped its release staging directory"
fi

printf 'schema 1\ncurrent ../../outside\n' > "$SELECTOR"
escape_out=$(run_launcher run -- tick 2>&1); escape_rc=$?
if [ "$escape_rc" -ne 0 ] && printf '%s' "$escape_out" | grep -q 'selected release'; then
    ok "runtime release: malformed selectors fail closed before code starts"
else
    bad "runtime release: malformed selector reached executable code"
fi

chmod -R u+w "$RT/releases" 2>/dev/null || true
test_finish
