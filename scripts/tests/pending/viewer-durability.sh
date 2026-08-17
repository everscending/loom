#!/usr/bin/env bash
# Red contract for the durable Herdr viewer controller.
#
# Intentionally excluded from tick-test.sh until the controller exists:
#   bash scripts/tests/pending/viewer-durability.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/test-lib.sh"

WP="$(dirname "$TICK")/watch-panes.sh"
CALLS="$T/herdr-durable-calls"

cat > "$T/herdr-durable-stub" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${HERDR_CALLS:?}"
case "$1 $2" in
  "pane list")
    printf '%s\n' "${HERDR_FIXTURE_LIST:-{\"result\":{\"panes\":[]}}}"
    ;;
  "pane get")
    printf '%s\n' '{"result":{"pane":{"pane_id":"stub:missing","tokens":{}}}}'
    ;;
  "pane split")
    printf '%s\n' '{"result":{"pane":{"pane_id":"stub:new"}}}'
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
if grep -q '^pane split ' "$CALLS"; then
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

test_finish
