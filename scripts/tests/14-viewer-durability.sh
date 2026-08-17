#!/usr/bin/env bash
# Durable Herdr viewer controller contract.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

WP="$(dirname "$TICK")/watch-panes.sh"
CALLS="$T/herdr-durable-calls"
export VIEWER_TICK="$TICK"

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
  "pane process-info")
    target=""; prev=""
    for arg in "$@"; do [ "$prev" = --pane ] && target="$arg"; prev="$arg"; done
    case " ${HERDR_UNKNOWN_PANES:-} " in *" $target "*) echo not-json; exit 0;; esac
    case " ${HERDR_DEAD_PANES:-} " in
      *" $target "*) printf '%s\n' '{"result":{"process_info":{"foreground_processes":[]}}}'; exit 0;;
    esac
    rec=$(printf '%s\n' "${HERDR_FIXTURE_LIST:-{}}" | jq -c --arg pane "$target" \
      '.result.panes[]? | select(.pane_id == $pane)' 2>/dev/null)
    role=$(printf '%s\n' "$rec" | jq -r '.tokens.loom_role // empty' 2>/dev/null)
    lane=$(printf '%s\n' "$rec" | jq -r '.tokens.loom_lane // empty' 2>/dev/null)
    case "$role" in
      controller) argv=$(printf '["bash","/fixture/%s","supervise"]' "${PROCESS_SCRIPT_NAME:-watch-panes.sh}") ;;
      worker) argv=$(printf '["bash","%s","render-log","%s","--follow"]' "${VIEWER_TICK:?}" "$lane") ;;
      ticker) argv=$(printf '["bash","%s","render-events","--follow"]' "${VIEWER_TICK:?}") ;;
      *) argv='["zsh"]' ;;
    esac
    printf '{"result":{"process_info":{"foreground_processes":[{"argv":%s}]}}}\n' "$argv"
    ;;
esac
exit 0
EOF
chmod +x "$T/herdr-durable-stub"

run_viewer() { # <home> [extra env args...] -- one bounded polling worker
    local home="$1"; shift
    mkdir -p "$home/lanes"
    HERDR_CALLS="$CALLS" HERDR_CMD="$T/herdr-durable-stub" \
      HERDR_ENV=1 HERDR_PANE_ID=stub:p0 HERDR_WORKSPACE_ID=stub \
      WATCH_TICKER=0 WATCH_MAX_PANES=9 WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
      LOOM_HOME="$home" env "$@" bash "$WP" worker >/dev/null 2>&1 || :
}

run_supervisor() { # <home> [extra env args...]
    local home="$1"; shift
    mkdir -p "$home/lanes"
    HERDR_CALLS="$CALLS" HERDR_CMD="$T/herdr-durable-stub" \
      HERDR_ENV=1 HERDR_PANE_ID=stub:c0 HERDR_WORKSPACE_ID=stub \
      WATCH_OWNER_TOKEN=repo-owner-123 WATCH_RESTART_SECONDS="${WATCH_RESTART_SECONDS:-0}" \
      WATCH_TICKER=0 WATCH_MAX_PANES=9 WATCH_POLL_SECONDS=0 \
      LOOM_HOME="$home" env "$@" bash "$WP" supervise >/dev/null 2>&1 || :
}

# A live but unrelated reused PID must not hold singleton authority. The
# process-start identity is deliberately wrong; the new viewer must proceed.
H1="$T/pid-reuse-home"; mkdir -p "$H1/lanes"
printf '%s\n' "$$" > "$H1/watch-panes.pid"
printf '%s\n' 'not-the-current-process-start' > "$H1/watch-panes.pid.start"
: > "$CALLS"; H1_WORKERS="$T/pid-reuse-workers"; : > "$H1_WORKERS"
cat > "$T/stop-worker" <<'EOF'
#!/usr/bin/env bash
echo worker >> "${WORKER_CALLS:?}"
touch "${LOOM_HOME:?}/viewer-off"
EOF
chmod +x "$T/stop-worker"
WORKER_CALLS="$H1_WORKERS" WATCH_WORKER_CMD="$T/stop-worker" run_supervisor "$H1"
if [ "$(wc -l < "$H1_WORKERS" | tr -d ' ')" -eq 1 ] \
   && [ ! -e "$H1/watch-panes.pid" ] && [ ! -e "$H1/watch-panes.pid.start" ]; then
    ok "viewer durability: PID plus start identity is diagnostic, not singleton authority"
else
    bad "viewer durability: a reused PID wedged the controller or retained stale identity"
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
WORKER_CALLS="$WORKER_CALLS" WATCH_WORKER_CMD="$T/crash-worker" run_supervisor "$H2"
if [ "$(wc -l < "$WORKER_CALLS" | tr -d ' ')" -ge 2 ]; then
    ok "viewer durability: controller restarts a crashed polling worker"
else
    bad "viewer durability: worker death leaves no active viewer"
fi

# A clean child exit is still unexpected while the viewer is on. The first
# rc0 must restart; the second invocation plants the deliberate off marker.
H2A="$T/restart-zero-home"; mkdir -p "$H2A/lanes"
ZERO_CALLS="$T/zero-worker-calls"; : > "$ZERO_CALLS"
cat > "$T/zero-worker" <<'EOF'
#!/usr/bin/env bash
echo worker >> "${WORKER_CALLS:?}"
[ "$(wc -l < "$WORKER_CALLS" | tr -d ' ')" -ge 2 ] && touch "${LOOM_HOME:?}/viewer-off"
exit 0
EOF
chmod +x "$T/zero-worker"; : > "$CALLS"
WORKER_CALLS="$ZERO_CALLS" WATCH_WORKER_CMD="$T/zero-worker" run_supervisor "$H2A"
if [ "$(wc -l < "$ZERO_CALLS" | tr -d ' ')" -eq 2 ]; then
    ok "viewer durability: controller restarts a polling worker after rc0"
else
    bad "viewer durability: a clean unexpected worker exit stopped supervision"
fi

# Off can arrive while the controller is between children. It must suppress
# the pending restart, run the bounded owned-pane cleanup, and exit.
H2B="$T/off-backoff-home"; mkdir -p "$H2B/lanes"
OFF_CALLS="$T/off-backoff-worker-calls"; : > "$OFF_CALLS"
cat > "$T/always-crash-worker" <<'EOF'
#!/usr/bin/env bash
echo worker >> "${WORKER_CALLS:?}"
exit 23
EOF
chmod +x "$T/always-crash-worker"; : > "$CALLS"
( while [ ! -s "$OFF_CALLS" ]; do sleep 0.01; done
  sleep 0.05
  touch "$H2B/viewer-off" ) &
WORKER_CALLS="$OFF_CALLS" WATCH_WORKER_CMD="$T/always-crash-worker" \
  WATCH_RESTART_SECONDS=0.2 run_supervisor "$H2B"
wait
if [ "$(wc -l < "$OFF_CALLS" | tr -d ' ')" -eq 1 ]; then
    ok "viewer durability: off during restart prevents another child"
else
    bad "viewer durability: off during restart still launched another child"
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

# Two exact live followers for one active lane are a recoverable duplicate:
# adopt one without restarting it and close the other.
H4A="$T/duplicate-worker-home"; mkdir -p "$H4A/lanes"; echo $$ > "$H4A/lanes/impl-41.pid"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:w1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"worker","loom_lane":"impl-41","loom_ticket":"41"}},{"pane_id":"stub:w2","tokens":{"loom_viewer":"repo-owner-123","loom_role":"worker","loom_lane":"impl-41","loom_ticket":"41"}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" run_viewer "$H4A"
if grep -q '^pane close stub:w2$' "$CALLS" \
   && ! grep -q '^pane split ' "$CALLS" && ! grep -q 'render-log impl-41' "$CALLS"; then
    ok "viewer durability: duplicate exact workers collapse to one live follower"
else
    bad "viewer durability: duplicate exact workers were retained or restarted"
fi
rm -f "$H4A/lanes/impl-41.pid"

# A complete tag with the wrong ticket cannot be adopted by lane name alone.
# It is an owned orphan, so close it and create the correctly tagged follower.
H4B="$T/wrong-ticket-home"; mkdir -p "$H4B/lanes"; echo $$ > "$H4B/lanes/impl-42.pid"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:w1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"worker","loom_lane":"impl-42","loom_ticket":"999"}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" run_viewer "$H4B"
if grep -q '^pane close stub:w1$' "$CALLS" \
   && grep -q '^pane report-metadata stub:new[0-9][0-9]* .*loom_lane=impl-42 .*loom_ticket=42' "$CALLS"; then
    ok "viewer durability: exact-lane adoption also requires the exact ticket"
else
    bad "viewer durability: lane-only metadata was incorrectly adopted"
fi
rm -f "$H4B/lanes/impl-42.pid"

# Complete ownership without its expected follower is stale. Reconciliation
# closes the dead pane and creates a new owned follower for the active lane.
H4C="$T/dead-worker-home"; mkdir -p "$H4C/lanes"; echo $$ > "$H4C/lanes/impl-43.pid"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:w1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"worker","loom_lane":"impl-43","loom_ticket":"43"}}]}}'
HERDR_FIXTURE_LIST="$LIST" HERDR_DEAD_PANES=stub:w1 WATCH_OWNER_TOKEN="$OWN" run_viewer "$H4C"
if grep -q '^pane close stub:w1$' "$CALLS" \
   && grep -q '^pane report-metadata stub:new[0-9][0-9]* .*loom_lane=impl-43' "$CALLS" \
   && grep -q 'render-log impl-43 --follow' "$CALLS"; then
    ok "viewer durability: a dead worker follower is replaced"
else
    bad "viewer durability: dead worker metadata was mistaken for a live follower"
fi
rm -f "$H4C/lanes/impl-43.pid"

# Partial metadata never grants adoption, cleanup, or anchor authority. The
# active lane gets a fresh pane while the incomplete candidate is untouched.
H4D="$T/partial-home"; mkdir -p "$H4D/lanes"; echo $$ > "$H4D/lanes/impl-44.pid"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:partial","tokens":{"loom_viewer":"repo-owner-123","loom_role":"worker","loom_lane":"impl-44"}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" run_viewer "$H4D"
if ! grep -Eq '^pane (close|run|rename|resize) stub:partial' "$CALLS" \
   && ! grep -Eq '^pane split --pane stub:partial ' "$CALLS" \
   && grep -q '^pane report-metadata stub:new[0-9][0-9]* .*loom_lane=impl-44' "$CALLS"; then
    ok "viewer durability: partial metadata is inert"
else
    bad "viewer durability: partial metadata granted pane authority"
fi
rm -f "$H4D/lanes/impl-44.pid"

# Even a perfect lane/ticket match is not a candidate when another repo owns
# it. It stays untouched while this repo creates its own follower.
H4E="$T/foreign-home"; mkdir -p "$H4E/lanes"; echo $$ > "$H4E/lanes/impl-45.pid"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:foreign","tokens":{"loom_viewer":"another-repo","loom_role":"worker","loom_lane":"impl-45","loom_ticket":"45"}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" run_viewer "$H4E"
if ! grep -Eq '^pane (close|run|rename|resize) stub:foreign' "$CALLS" \
   && ! grep -Eq '^pane split --pane stub:foreign ' "$CALLS" \
   && grep -q '^pane report-metadata stub:new[0-9][0-9]* .*loom_lane=impl-45' "$CALLS"; then
    ok "viewer durability: foreign exact candidates are filtered"
else
    bad "viewer durability: a foreign exact candidate entered reconciliation"
fi
rm -f "$H4E/lanes/impl-45.pid"

# A complete controller token plus the expected live command is singleton
# authority. A dead tagged controller is cleanup authority, never liveness.
H5="$T/controller-home"; mkdir -p "$H5/lanes" "$H5/watch-controller.lock"; : > "$CALLS"
printf '%s\n' "$$" > "$H5/watch-controller.lock/pid"
printf '%s\n' 'not-the-current-process-start' > "$H5/watch-controller.lock/start"
LIST='{"result":{"panes":[{"pane_id":"stub:c1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"controller"}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub LOOM_HOME="$H5" bash "$WP" raise >/dev/null 2>&1 || :
if ! grep -q '^pane split ' "$CALLS" && ! grep -q '^pane run ' "$CALLS" \
   && [ ! -e "$H5/watch-controller.lock" ]; then
    ok "viewer durability: live tagged controller wins after stale lock identity recovery"
else
    bad "viewer durability: stale PID identity wedged or duplicated the live controller"
fi
: > "$CALLS"
HERDR_FIXTURE_LIST="$LIST" HERDR_DEAD_PANES=stub:c1 WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub LOOM_HOME="$H5" bash "$WP" raise >/dev/null 2>&1 || :
meta_ln=$(grep -n '^pane report-metadata stub:new[0-9][0-9]* .*loom_role=controller' "$CALLS" | cut -d: -f1)
run_ln=$(grep -n '^pane run stub:new[0-9][0-9]* ' "$CALLS" | cut -d: -f1)
if grep -q '^pane close stub:c1$' "$CALLS" \
   && [ -n "$meta_ln" ] && [ -n "$run_ln" ] && [ "$meta_ln" -lt "$run_ln" ]; then
    ok "viewer durability: raise replaces a dead controller and tags before run"
else
    bad "viewer durability: stale tagged controller was accepted or replacement ran unowned"
fi

# Reconciliation also collapses durable duplicates. It keeps one verified
# controller and closes every other exact live controller under the repo lock.
: > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:c1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"controller"}},{"pane_id":"stub:c2","tokens":{"loom_viewer":"repo-owner-123","loom_role":"controller"}}]}}'
HERDR_FIXTURE_LIST="$LIST" WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub LOOM_HOME="$H5" bash "$WP" raise >/dev/null 2>&1 || :
if grep -q '^pane close stub:c2$' "$CALLS" && ! grep -q '^pane split ' "$CALLS"; then
    ok "viewer durability: controller reconciliation closes a durable duplicate"
else
    bad "viewer durability: duplicate live controllers survived reconciliation"
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

# A complete ownership record with unreadable process data is not permission
# to declare the follower dead. Degrade the whole poll without mutations.
H8A="$T/process-degraded-home"; mkdir -p "$H8A/lanes"; echo $$ > "$H8A/lanes/impl-81.pid"; : > "$CALLS"
LIST='{"result":{"panes":[{"pane_id":"stub:w1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"worker","loom_lane":"impl-81","loom_ticket":"81"}}]}}'
HERDR_FIXTURE_LIST="$LIST" HERDR_UNKNOWN_PANES=stub:w1 WATCH_OWNER_TOKEN="$OWN" run_viewer "$H8A"
if ! grep -Eq '^pane (close|split|run|rename|resize|report-metadata) ' "$CALLS"; then
    ok "viewer durability: unknown follower liveness changes no panes"
else
    bad "viewer durability: unreadable process state granted mutation authority"
fi
rm -f "$H8A/lanes/impl-81.pid"

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
LIST='{"result":{"panes":[{"pane_id":"stub:t1","tokens":{"loom_viewer":"repo-owner-123","loom_role":"ticker"}}]}}'
HERDR_FIXTURE_LIST="$LIST" HERDR_DEAD_PANES=stub:t1 WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" \
  HERDR_CMD="$T/herdr-durable-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub WATCH_TICKER=1 WATCH_POLLS=1 WATCH_POLL_SECONDS=0 \
  LOOM_HOME="$H11" bash "$WP" worker >/dev/null 2>&1 || :
if grep -q '^pane close stub:t1$' "$CALLS" && grep -q 'render-events --follow' "$CALLS"; then
    ok "viewer durability: a dead ticker follower is replaced"
else
    bad "viewer durability: dead ticker metadata was mistaken for liveness"
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

# Controller creation is a per-repo transaction, not a read-then-create race.
# This stateful stub makes a successful metadata report visible to the next
# discovery and delays the empty read so two unguarded raises overlap.
ATOMIC_CALLS="$T/herdr-atomic-calls"; ATOMIC_STATE="$T/herdr-atomic-state"
cat > "$T/herdr-atomic-stub" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${HERDR_CALLS:?}"
state=${HERDR_ATOMIC_STATE:?}
case "$1 $2" in
  "pane list")
    sleep "${HERDR_LIST_DELAY:-0}"
    if [ -s "$state.controller" ]; then
      pane=$(cat "$state.controller")
      printf '{"result":{"panes":[{"pane_id":"%s","tokens":{"loom_viewer":"repo-owner-123","loom_role":"controller"}}]}}\n' "$pane"
    else
      printf '%s\n' '{"result":{"panes":[]}}'
    fi
    ;;
  "pane split")
    while ! mkdir "$state.counter-lock" 2>/dev/null; do sleep 0.01; done
    n=$(cat "$state.counter" 2>/dev/null || echo 0); n=$((n + 1))
    printf '%s\n' "$n" > "$state.counter"
    rmdir "$state.counter-lock"
    printf '{"result":{"pane":{"pane_id":"stub:atomic%s"}}}\n' "$n"
    ;;
  "pane report-metadata")
    case " $* " in *" loom_role=controller "*) printf '%s\n' "$3" > "$state.controller";; esac
    ;;
  "pane process-info")
    printf '{"result":{"process_info":{"foreground_processes":[{"argv":["bash","/fixture/%s","supervise"]}]}}}\n' "${PROCESS_SCRIPT_NAME:-watch-panes.sh}"
    ;;
esac
exit 0
EOF
chmod +x "$T/herdr-atomic-stub"

H14="$T/atomic-home"; mkdir -p "$H14/lanes"; : > "$ATOMIC_CALLS"
HERDR_CALLS="$ATOMIC_CALLS" HERDR_ATOMIC_STATE="$ATOMIC_STATE" HERDR_LIST_DELAY=0.1 \
  HERDR_CMD="$T/herdr-atomic-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub WATCH_OWNER_TOKEN="$OWN" LOOM_HOME="$H14" bash "$WP" raise >/dev/null 2>&1 &
raise_a=$!
HERDR_CALLS="$ATOMIC_CALLS" HERDR_ATOMIC_STATE="$ATOMIC_STATE" HERDR_LIST_DELAY=0.1 \
  HERDR_CMD="$T/herdr-atomic-stub" HERDR_ENV=1 HERDR_PANE_ID=stub:p0 \
  HERDR_WORKSPACE_ID=stub WATCH_OWNER_TOKEN="$OWN" LOOM_HOME="$H14" bash "$WP" raise >/dev/null 2>&1 &
raise_b=$!
wait "$raise_a"; rc_a=$?; wait "$raise_b"; rc_b=$?
if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ] \
   && [ "$(grep -c '^pane split ' "$ATOMIC_CALLS" || :)" -eq 1 ] \
   && [ "$(grep -c '^pane run ' "$ATOMIC_CALLS" || :)" -eq 1 ]; then
    ok "viewer durability: simultaneous raises atomically create one controller"
else
    bad "viewer durability: concurrent raises created duplicate controllers"
fi

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

# Planted violation: remove the atomic controller lock. Both delayed empty
# reads then create a controller, demonstrating that discovery alone is not a
# compare-and-swap boundary.
sed 's/    controller_lock_acquire || return 1/    : # MUTATION: no atomic controller lock/' \
    "$WP" > "$MUT/watch-no-controller-lock.sh"
chmod +x "$MUT/watch-no-controller-lock.sh"
if cmp -s "$WP" "$MUT/watch-no-controller-lock.sh"; then
    bad "viewer durability mutant: controller-lock mutation did not modify the script"
else
    rm -f "$ATOMIC_STATE.controller" "$ATOMIC_STATE.counter"
    : > "$ATOMIC_CALLS"
    for n in 1 2; do
      HERDR_CALLS="$ATOMIC_CALLS" HERDR_ATOMIC_STATE="$ATOMIC_STATE" HERDR_LIST_DELAY=0.1 \
        PROCESS_SCRIPT_NAME=watch-no-controller-lock.sh HERDR_CMD="$T/herdr-atomic-stub" \
        HERDR_ENV=1 HERDR_PANE_ID=stub:p0 HERDR_WORKSPACE_ID=stub WATCH_OWNER_TOKEN="$OWN" \
        LOOM_HOME="$T/atomic-mut-home" bash "$MUT/watch-no-controller-lock.sh" raise \
        >"$T/atomic-mut-$n.out" 2>&1 &
      eval "mut_pid_$n=$!"
    done
    wait "$mut_pid_1"; mut_a=$?; wait "$mut_pid_2"; mut_b=$?
    mut_out=$(cat "$T/atomic-mut-1.out" "$T/atomic-mut-2.out")
    if assert_mutant_ran "$mut_a" "$mut_out" "viewer-controller-lock-violation" \
       && [ "$mut_b" -ne 126 ] && [ "$mut_b" -ne 127 ]; then
        [ "$(grep -c '^pane split ' "$ATOMIC_CALLS" || :)" -ge 2 ] \
            && ok "viewer durability mutant: without the repo lock concurrent raises duplicate" \
            || bad "viewer durability mutant: lock mutation did not expose the raise race"
    fi
fi

# Planted violation: stop the supervisor after its first child exit. The
# crash then leaves exactly one worker start instead of the proven restart.
sed '/        viewer_note "viewer polling worker exited rc \$rc; controller restarting it"/i\
        break # MUTATION: unexpected child exit stops supervision' "$WP" > "$MUT/watch-no-restart.sh"
chmod +x "$MUT/watch-no-restart.sh"
H10="$T/restart-mut-home"; mkdir -p "$H10/lanes"; : > "$WORKER_CALLS"; : > "$CALLS"
mut_out=$(WORKER_CALLS="$WORKER_CALLS" WATCH_WORKER_CMD="$T/crash-worker" \
  WATCH_OWNER_TOKEN="$OWN" HERDR_CALLS="$CALLS" HERDR_CMD="$T/herdr-durable-stub" \
  HERDR_ENV=1 HERDR_PANE_ID=stub:p0 HERDR_WORKSPACE_ID=stub WATCH_RESTART_SECONDS=0 \
  LOOM_HOME="$H10" bash "$MUT/watch-no-restart.sh" supervise 2>&1); mut_rc=$?
if cmp -s "$WP" "$MUT/watch-no-restart.sh"; then
    bad "viewer durability mutant: restart mutation did not modify the script"
elif assert_mutant_ran "$mut_rc" "$mut_out" "viewer-restart-violation"; then
    [ "$(wc -l < "$WORKER_CALLS" | tr -d ' ')" -eq 1 ] \
        && ok "viewer durability mutant: without restart a worker crash leaves no viewer" \
        || bad "viewer durability mutant: restart mutation did not recreate the dead viewer"
fi

test_finish
