#!/usr/bin/env bash
# Red contract for the durable Herdr viewer controller.
#
# Intentionally excluded from tick-test.sh until the controller exists:
#   bash scripts/tests/pending/viewer-durability.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

WP="$(dirname "$TICK")/watch-panes.sh"
CALLS="$T/herdr-durable-calls"

cat > "$T/herdr-durable-stub" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${HERDR_CALLS:?}"
case "$1 $2" in
  "pane list")
    [ -n "${HERDR_TOUCH_ON_LIST:-}" ] && touch "$HERDR_TOUCH_ON_LIST"
    if [ -n "${HERDR_FIXTURE_LIST:-}" ]; then
      printf '%s\n' "$HERDR_FIXTURE_LIST"
    else
      printf '%s\n' '{"result":{"panes":[]}}'
    fi
    ;;
  "pane get")
    printf '%s\n' '{"result":{"pane":{"pane_id":"stub:missing","tokens":{}}}}'
    ;;
  "pane split")
    target=""; prev=""
    for arg in "$@"; do [ "$prev" = --pane ] && target="$arg"; prev="$arg"; done
    [ -n "${HERDR_FAIL_SPLIT_PANE:-}" ] && [ "$target" = "$HERDR_FAIL_SPLIT_PANE" ] && exit 1
    n=$(grep -c '^pane split ' "$HERDR_CALLS" || :)
    printf '{"result":{"pane":{"pane_id":"stub:new%s"}}}\n' "$n"
    ;;
  "pane layout")
    awk '
      /^pane split / { n++; ids[n] = "stub:new" n }
      END {
        printf "{\"result\":{\"layout\":{\"zoomed\":false,\"panes\":["
        printf "{\"pane_id\":\"stub:p0\",\"rect\":{\"x\":0,\"y\":0,\"width\":50,\"height\":1}}"
        y=1; h=40
        for (i=1; i<=n; i++) {
          printf ",{\"pane_id\":\"%s\",\"rect\":{\"x\":100,\"y\":%d,\"width\":50,\"height\":%d}}", ids[i], y, h
          y += h; h = (h >= 4 ? int(h / 2) : 2)
        }
        printf "]}}}\n"
      }' "$HERDR_CALLS"
    ;;
  "pane process-info") exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/herdr-durable-stub"

run_viewer() { # <home> [extra env args...]
    local home="$1"; shift
    mkdir -p "$home/lanes"
    HERDR_CALLS="$CALLS" HERDR_CMD="$T/herdr-durable-stub" \
      HERDR_ENV=1 HERDR_PANE_ID=stub:p0 HERDR_WORKSPACE_ID=stub \
      WATCH_TICKER=0 WATCH_MAX_PANES=9 WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
      LOOM_HOME="$home" env "$@" bash "$WP" supervise >/dev/null 2>&1 || :
}

# A live but unrelated reused PID must not hold singleton authority. The
# process-start identity is deliberately wrong; the new viewer must proceed.
H1="$T/pid-reuse-home"; mkdir -p "$H1/lanes"
printf '%s\n' "$$" > "$H1/watch-panes.pid"
printf '%s\n' 'not-the-current-process-start' > "$H1/watch-panes.pid.start"
: > "$CALLS"
run_viewer "$H1"
if grep -q '^pane list ' "$CALLS"; then
    ok "viewer durability: a reused live PID does not wedge the singleton"
else
    bad "viewer durability: kill -0 still mistakes a reused PID for the viewer"
fi

# The supervisor must replace a worker that exits unexpectedly. This seam is
# intentionally ignored by the current script, so the assertion starts red.
H2="$T/restart-home"; mkdir -p "$H2/lanes"
WORKER_CALLS="$T/worker-calls"
cat > "$T/crash-worker" <<'EOF'
#!/usr/bin/env bash
n=0; [ -f "${WORKER_CALLS:?}" ] && n=$(wc -l < "$WORKER_CALLS" | tr -d ' ')
echo worker >> "$WORKER_CALLS"
echo worker-start
[ "$n" -eq 0 ] && exit 23
touch "${LOOM_HOME:?}/viewer-off"
exit 0
EOF
chmod +x "$T/crash-worker"; : > "$WORKER_CALLS"; : > "$CALLS"
WORKER_CALLS="$WORKER_CALLS" WATCH_WORKER_CMD="$T/crash-worker" run_viewer "$H2"
if [ "$(wc -l < "$WORKER_CALLS" | tr -d ' ')" -ge 2 ]; then
    ok "viewer durability: controller restarts a crashed polling worker"
else
    bad "viewer durability: worker death leaves no active viewer"
fi

# Recovery must adopt the exact active lane's tagged pane. It must neither
# split a duplicate nor start a second follower in the surviving pane.
H3="$T/adopt-home"; mkdir -p "$H3/lanes"
echo $$ > "$H3/lanes/impl-291.pid"
: > "$CALLS"
OWN=repo-owner-123
LIST='{"result":{"panes":[{"pane_id":"stub:p2","tokens":{"loom_viewer":"repo-owner-123","loom_role":"worker","loom_lane":"impl-291","loom_ticket":"291"}},{"pane_id":"stub:p9","tokens":{}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" run_viewer "$H3"
if ! grep -q '^pane split ' "$CALLS" && ! grep -q 'render-log impl-291' "$CALLS"; then
    ok "viewer durability: restart adopts the surviving active worker pane"
else
    bad "viewer durability: restart duplicated an already visible active lane"
fi
rm -f "$H3/lanes/impl-291.pid"

# Active-only reconciliation closes a token-matching inactive worker and must
# leave an untagged human pane untouched. Ownership and inactivity are both
# required; labels and location are not authority.
H4="$T/orphan-home"; mkdir -p "$H4/lanes"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:p2","label":"impl-292","tokens":{"loom_viewer":"repo-owner-123","loom_role":"worker","loom_lane":"impl-292","loom_ticket":"292"}},{"pane_id":"stub:p9","label":"impl-999","tokens":{}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" run_viewer "$H4"
if grep -q '^pane close stub:p2$' "$CALLS" \
   && ! grep -q '^pane close stub:p9$' "$CALLS"; then
    ok "viewer durability: restart closes only its inactive orphan pane"
else
    bad "viewer durability: orphan cleanup is absent or touched an unrelated pane"
fi

# A controller token, not a PID, is singleton authority. `raise` must adopt
# the exact repo controller and must create/tag/run one when none exists.
H5="$T/controller-home"; mkdir -p "$H5/lanes"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:c1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"controller"}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub LOOM_HOME="$H5" bash "$WP" raise >/dev/null 2>&1 || :
if ! grep -q '^pane split ' "$CALLS" && ! grep -q '^pane run ' "$CALLS"; then
    ok "viewer durability: tagged controller is the singleton authority"
else
    bad "viewer durability: raise duplicated an existing tagged controller"
fi
: > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:p9","tokens":{}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub LOOM_HOME="$H5" bash "$WP" raise >/dev/null 2>&1 || :
meta_ln=$(grep -n '^pane report-metadata stub:new[0-9][0-9]* .*loom_role=controller' "$CALLS" | cut -d: -f1)
run_ln=$(grep -n '^pane run stub:new[0-9][0-9]* ' "$CALLS" | cut -d: -f1)
if [ -n "$meta_ln" ] && [ -n "$run_ln" ] && [ "$meta_ln" -lt "$run_ln" ]; then
    ok "viewer durability: raise tags the Herdr controller before starting it"
else
    bad "viewer durability: controller was not tagged before its command"
fi

# Immediate stage handoff preserves ticket affinity without preserving an
# idle pane: retag the owned pane to the active lane and start exactly once.
H6="$T/retag-home"; mkdir -p "$H6/lanes"; echo $$ > "$H6/lanes/impl-300.pid"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:p3","tokens":{"loom_viewer":"repo-owner-123","loom_role":"worker","loom_lane":"gate-300","loom_ticket":"300"}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" run_viewer "$H6"
if grep -q '^pane report-metadata stub:p3 .*loom_lane=impl-300' "$CALLS" \
   && [ "$(grep -c 'render-log impl-300' "$CALLS" || :)" -eq 1 ] \
   && ! grep -q '^pane split ' "$CALLS"; then
    ok "viewer durability: same-ticket handoff retags one surviving pane"
else
    bad "viewer durability: stage handoff lost affinity or duplicated its pane"
fi
rm -f "$H6/lanes/impl-300.pid"

# `off` closes only discovered panes bearing this repo's token. Plant the
# marker during discovery so this exercises a live worker, not startup refusal.
H7="$T/off-home"; mkdir -p "$H7/lanes"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:w1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"worker","loom_lane":"impl-7","loom_ticket":"7"}},{"pane_id":"stub:t1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"ticker"}},{"pane_id":"stub:human","tokens":{}}]}}'
HERDR_FIXTURE_LIST="$LIST" HERDR_TOUCH_ON_LIST="$H7/viewer-off" \
  WATCH_OWNER_TOKEN="$OWN" run_viewer "$H7"
if grep -q '^pane close stub:w1$' "$CALLS" \
   && grep -q '^pane close stub:t1$' "$CALLS" \
   && ! grep -q '^pane close stub:human$' "$CALLS"; then
    ok "viewer durability: off closes only owned worker and ticker panes"
else
    bad "viewer durability: off crossed its metadata ownership boundary"
fi

# Malformed discovery grants no cleanup or creation authority.
H8="$T/degraded-home"; mkdir -p "$H8/lanes"; echo $$ > "$H8/lanes/impl-8.pid"; : > "$CALLS"
HERDR_FIXTURE_LIST='not-json' WATCH_OWNER_TOKEN="$OWN" run_viewer "$H8"
if ! grep -q '^pane close ' "$CALLS" && ! grep -q '^pane split ' "$CALLS"; then
    ok "viewer durability: malformed discovery changes no panes"
else
    bad "viewer durability: malformed discovery still mutated pane state"
fi
rm -f "$H8/lanes/impl-8.pid"

# Ticker lifecycle keeps one exact-token pane, closes duplicates, and tags a
# replacement before starting the event follower.
H11="$T/ticker-home"; mkdir -p "$H11/lanes"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:t1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"ticker"}},{"pane_id":"stub:t2","tokens":{"loom_viewer":"repo-owner-123","loom_role":"ticker"}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub WATCH_TICKER=1 WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
  LOOM_HOME="$H11" bash "$WP" worker >/dev/null 2>&1 || :
if grep -q '^pane close stub:t2$' "$CALLS" \
   && ! grep -q 'render-events --follow' "$CALLS"; then
    ok "viewer durability: ticker reconciliation keeps one owned pane"
else
    bad "viewer durability: ticker reconciliation duplicated its follower"
fi
: > "$CALLS"
LIST='{"result":{"panes":[]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub WATCH_TICKER=1 WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
  LOOM_HOME="$H11" bash "$WP" worker >/dev/null 2>&1 || :
tmeta=$(grep -n '^pane report-metadata stub:new[0-9][0-9]* .*loom_role=ticker' "$CALLS" | cut -d: -f1)
trun=$(grep -n 'render-events --follow' "$CALLS" | cut -d: -f1)
if [ -n "$tmeta" ] && [ -n "$trun" ] && [ "$tmeta" -lt "$trun" ]; then
    ok "viewer durability: replacement ticker is owned before it runs"
else
    bad "viewer durability: replacement ticker ran without durable ownership"
fi

# The active width cap remains visible in the durable event stream.
H12="$T/cap-home"; mkdir -p "$H12/lanes"
echo $$ > "$H12/lanes/impl-12.pid"; echo $$ > "$H12/lanes/impl-13.pid"; : > "$CALLS"
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub WATCH_TICKER=0 WATCH_MAX_PANES=1 WATCH_POLLS=1 \
  WATCH_POLL_SECONDS=0 LOOM_HOME="$H12" bash "$WP" worker >/dev/null 2>&1 || :
if [ "$(grep -c 'render-log impl-1[23]' "$CALLS" || :)" -eq 1 ] \
   && grep -q 'viewer_note' "$H12/events.jsonl" 2>/dev/null; then
    ok "viewer durability: active pane cap leaves a visible wait event"
else
    bad "viewer durability: pane cap hid an active lane without a wait event"
fi
rm -f "$H12/lanes"/*.pid

# Preserve the right-column behavior: active panes stack downward, recover
# from a dead newest split using an already-owned pane, and rebalance only the
# owned worker column (never the human caller pane).
H13="$T/layout-home"; mkdir -p "$H13/lanes"
for n in 21 22 23; do echo $$ > "$H13/lanes/impl-$n.pid"; done
: > "$CALLS"
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub WATCH_TICKER=0 WATCH_MAX_PANES=9 WATCH_POLLS=1 \
  WATCH_POLL_SECONDS=0 LOOM_HOME="$H13" bash "$WP" worker >/dev/null 2>&1 || :
if [ "$(grep -c '^pane resize ' "$CALLS" || :)" -eq 2 ] \
   && ! grep -q '^pane resize --pane stub:p0 ' "$CALLS"; then
    ok "viewer durability: active worker column rebalances without touching the caller"
else
    bad "viewer durability: active worker column lost its layout boundary"
fi
: > "$CALLS"
HERDR_FIXTURE_LIST="$LIST" HERDR_FAIL_SPLIT_PANE=stub:new2 \
  WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" HERDR_CMD="$T/herdr-durable-stub" \
  HERDR_ENV=1 HERDR_PANE_ID=stub:p0 HERDR_WORKSPACE_ID=stub WATCH_TICKER=0 \
  WATCH_MAX_PANES=9 WATCH_POLLS=1 WATCH_POLL_SECONDS=0 LOOM_HOME="$H13" \
  bash "$WP" worker >/dev/null 2>&1 || :
if [ "$(grep -c -- '--direction right' "$CALLS" || :)" -eq 1 ] \
   && [ "$(grep -c -- 'split --pane stub:new1 --direction down' "$CALLS" || :)" -ge 2 ]; then
    ok "viewer durability: dead newest split reuses an owned column anchor"
else
    bad "viewer durability: dead split opened a second column or used an unowned anchor"
fi
rm -f "$H13/lanes"/*.pid

# Planted violation: removing exact-owner filtering lets this repo close a
# different viewer's pane. The fixed script above preserves it.
MUT=$(mirror_scripts "$T/viewer-token-mutant")
sed 's/select(.tokens.loom_viewer == $owner and .tokens.loom_role == $role)/select(.tokens.loom_role == $role)/' \
    "$WP" > "$MUT/watch-panes.sh"
chmod +x "$MUT/watch-panes.sh"
H9="$T/token-mut-home"; mkdir -p "$H9/lanes"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:foreign","tokens":{"loom_viewer":"some-other-repo","loom_role":"worker","loom_lane":"impl-9","loom_ticket":"9"}}]}}'
mut_out=$(HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub WATCH_TICKER=0 WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
  LOOM_HOME="$H9" bash "$MUT/watch-panes.sh" worker 2>&1); mut_rc=$?
if assert_mutant_ran "$mut_rc" "$mut_out" "viewer-token-violation"; then
    grep -q '^pane close stub:foreign$' "$CALLS" \
        && ok "viewer durability mutant: removing owner filter closes a foreign pane" \
        || bad "viewer durability mutant: owner-filter mutation did not expose cross-repo cleanup"
fi

# Planted violation: stop the supervisor after its first child exit. The
# crash then leaves exactly one worker start instead of the proven restart.
sed 's/        \[ "$rc" -eq 0 \] && break/        break/' "$WP" > "$MUT/watch-no-restart.sh"
chmod +x "$MUT/watch-no-restart.sh"
H10="$T/restart-mut-home"; mkdir -p "$H10/lanes"; : > "$WORKER_CALLS"; : > "$CALLS"
mut_out=$(WORKER_CALLS="$WORKER_CALLS" WATCH_WORKER_CMD="$T/crash-worker" \
  WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" HERDR_CMD="$T/herdr-durable-stub" \
  HERDR_ENV=1 HERDR_PANE_ID=stub:p0 HERDR_WORKSPACE_ID=stub WATCH_RESTART_SECONDS=0 \
  LOOM_HOME="$H10" bash "$MUT/watch-no-restart.sh" supervise 2>&1); mut_rc=$?
if assert_mutant_ran "$mut_rc" "$mut_out" "viewer-restart-violation"; then
    [ "$(wc -l < "$WORKER_CALLS" | tr -d ' ')" -eq 1 ] \
        && ok "viewer durability mutant: without restart a worker crash leaves no viewer" \
        || bad "viewer durability mutant: restart mutation did not recreate the dead viewer"
fi

test_finish
