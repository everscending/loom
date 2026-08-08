#!/usr/bin/env bash
# PROPOSALS.md holds only open work, and the old watcher is retired
#
# Section 15 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# 14. Proposals hygiene: PROPOSALS.md holds ONLY open / in progress / deferred
#     rows — implemented and dropped ones move to PROPOSALS_ARCHIVED.md, per
#     the file's own "Archive on implementation" rule. That rule is prose at
#     the top of a file that gets edited surgically, so twice in one day an
#     editor changed a row without ever reading it (retro session and the
#     interactive session, 2026-08-02). A prose rule partial readers skip
#     must be a failing test instead.
PROPOSALS="$(dirname "$TICK")/../PROPOSALS.md"
if [ -f "$PROPOSALS" ]; then
    stray=$(awk -F'|' '/^\| P[0-9]+/ {
        s=$4; gsub(/^[ \t]+|[ \t]+$/, "", s)
        if (s !~ /^(open|in progress|deferred)/) print $2 ": " s
    }' "$PROPOSALS")
    if [ -n "$stray" ]; then
        bad "proposals-hygiene: non-open rows squatting in PROPOSALS.md → $stray"
    else
        ok "proposals-hygiene: every PROPOSALS.md row is open/in progress/deferred"
    fi
else
    bad "proposals-hygiene: PROPOSALS.md not found next to scripts/"
fi

# 15. Retiring the old separate watcher. There used to be a second launchd
#     agent per repo, and `tick --auto` watching before the lock made it
#     redundant. The way OUT is what has to keep working: a machine with the
#     old agent still loaded lands on `quiet-tick` once, sheds it, and is
#     done. Without that the stale agent would spin on a usage error every
#     60s with nothing able to unload it. (Paid for: 2026-08-02 — 26 zombie
#     launchd agents from earlier suite runs.)
export LOOM_PLIST_DIR="$T/plists15"
mkdir -p "$LOOM_PLIST_DIR"
: > "$LCTL_CALLS"
out=$("$TICK" quiet-tick 2>&1); rc=$?
[ "$rc" = 0 ] && case "$out" in *retired*) true ;; *) false ;; esac \
    && ok "watcher: the old entry point retires itself and exits clean" \
    || bad "watcher: quiet-tick rc=$rc, said: $out"
grep -q '^bootout ' "$LCTL_CALLS" \
    && ok "watcher: retirement booted the old agent out through the seam" \
    || bad "watcher: retirement never reached the launchctl stub"
# Planted violation: arming is GONE, not merely discouraged. A verb still able
# to write a watcher plist would let the retired agent come back.
: > "$LCTL_CALLS"
"$TICK" watcher-arm >/dev/null 2>&1 \
    && bad "watcher: watcher-arm still exists — the second agent can be resurrected" \
    || ok "watcher: no verb can arm a second agent any more"
ls "$LOOM_PLIST_DIR" 2>/dev/null | grep -q '\.watch\.plist$' \
    && bad "watcher: a .watch plist was written after arm was removed" \
    || ok "watcher: arming wrote no plist, because there is nothing left to arm"

test_finish
