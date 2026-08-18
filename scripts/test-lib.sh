# Shared harness for the section files in scripts/tests/. Sourced, never run.
#
# Every section gets its OWN process and its own $T, so a section is a
# standalone suite: `bash scripts/tests/07-snapshot.sh` proves the snapshot
# without paying for the other twenty-six. scripts/tick-test.sh is the driver
# that runs them all.
#
# Everything below was the top of tick-test.sh when the suite was one file.
set -uo pipefail

TICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tick.sh"
T=$(mktemp -d)
export LOOM_HOME="$T/home" LOOM_REPO="$T/repo"
mkdir -p "$LOOM_REPO"

# P86: loom refuses to run in a repo that has not declared its issue tracker,
# and the declaration must be TRACKED BY GIT — a lane works in a worktree, and
# an untracked file is in none of them. Every fixture repo a halted verb runs
# against therefore needs one. It is a helper called from shared setup rather
# than seventy-five hand edits: the sections that build their own repos call it
# with their own root, and a section that WANTS the refusal simply does not.
# `git add` is enough; `ls-files --error-unmatch` asks the index, not HEAD, so
# no fixture has to pay for a commit.
seed_tracker_decl() { # <repo-root> [tracker name]
    local root="$1" name="${2:-GitLab}"
    mkdir -p "$root/docs/agents"
    printf '# Issue tracker: %s\n' "$name" > "$root/docs/agents/issue-tracker.md"
    if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$root" init -q >/dev/null 2>&1 || return 0
        git -C "$root" config user.email loom@test >/dev/null 2>&1 || true
        git -C "$root" config user.name loom >/dev/null 2>&1 || true
    fi
    git -C "$root" add docs/agents/issue-tracker.md >/dev/null 2>&1 || true
}
seed_tracker_decl "$LOOM_REPO"

# P86 stage 2: several sections mirror the scripts into a temp directory and
# mutate one of them, to prove a guard is what produces a refusal. Every tracker
# call now goes through `trackers/<name>.sh`, resolved beside the script that
# asks — so a mirror without that directory makes lane.sh and tick.sh die on a
# missing driver instead of exercising the mutation. One line per mirror,
# rather than each section growing its own copy of the path.
# P87 split the forge out, so a mirror needs both directories or it dies on a
# missing forge driver instead — same failure, one directory further along.
link_trackers() { # <mirror dir>
    ln -sfn "$(dirname "$TICK")/trackers" "$1/trackers" 2>/dev/null || true
    ln -sfn "$(dirname "$TICK")/forges"   "$1/forges"   2>/dev/null || true
}
# D-TEST-15: the whole mirror, in one call, for the sections that plant a
# MISSING FILE rather than a mutated one. Hiding the shipped file itself — `mv
# scripts/lib.jq aside; run; mv it back` — is the obvious way to prove "a
# missing prelude is named", and it was wrong the moment sections stopped
# running one at a time: scripts/ is the ONE directory every section shares, so
# for the length of that window every other section's tick.sh saw the file gone
# too. It cost five unrelated assertions across four files, none of them the one
# under test — `module not found: lib` out of a tracker-driver snapshot, `lib.sh
# is missing` out of a gate-deps refusal — and it cost them at random, because
# which section happened to be mid-verb in that window is timing. A mirror is
# private to the section, so deleting a file from it is invisible to every other
# one, and the guard under test is the same guard: tick.sh resolves its siblings
# off its own path.
mirror_scripts() { # <dir> → a private copy of the scripts directory, printed
    local d="$1" src; src="$(dirname "$TICK")"
    mkdir -p "$d"
    cp "$src"/*.sh "$src"/*.jq "$d/" 2>/dev/null || true
    chmod +x "$d"/*.sh 2>/dev/null || true
    link_trackers "$d"
    printf '%s\n' "$d"
}
# Workspace-trust fixture (P16). Trusting $T alone proves the cascade: every
# lane below it spawns without an entry of its own, exactly as a real worktree
# relies on its parent directory.
export LOOM_TRUST_FILE="$T/claude.json"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$T" > "$LOOM_TRUST_FILE"
# The GLOBAL config layer is a fixture too, and an empty one by default.
# Without this the suite fell through to the developer's own
# ~/.loom/config.yml: every `cfg` lookup in every section resolved
# against whatever that machine happened to say, so a run could pass here and
# fail on another laptop. Found by P31's chain test, which asserts the
# unconfigured case and got the human's `lane_model: sonnet` instead.
# Sections that need a global layer still point at their own file.
export LOOM_GLOBAL_CONFIG="$T/global.yml"
: > "$LOOM_GLOBAL_CONFIG"
# Self-trigger is the DEFAULT now (P2), so every lane below fires a tick when it
# exits. Two consequences this file must own rather than discover:
#   * a harmless default wave command, or those ticks would launch real `claude`
#     sessions — tests that care about the wave still override it inline;
#   * bootstrap off by default, since it is now paid on many more ticks. Section
#     9 tests bootstrap itself and switches it back on via BOOTENV.
export LOOM_WAVE_CMD="true"
export LOOM_SKIP_BOOTSTRAP=1
export LOOM_ALLOW_MUTABLE_RUNTIME=1
export LOOM_PROVIDER=claude LOOM_SKIP_PROVIDER_CHECK=1 LOOM_SKIP_SUPERVISION_CHECK=1 LOOM_SKIP_AGENT_PREFLIGHT=1
# Most fixture base-checks assert Git tree selection with tiny synthetic repos;
# they must not contact real package managers merely because a fixture happens
# to contain a manifest. Section 16 explicitly enables preparation for the
# dependency-reproduction contract.
export LANE_BASE_CHECK_PREPARE=0
# launchd is stubbed GLOBALLY, like glab: any test path that reaches
# watcher-arm or install must capture argv, never mutate real launchd.
# (Paid for: 2026-08-02 — the suite armed a real watcher agent per run;
# 26 zombie agents accumulated, firing exit-78 every 60s against deleted
# mktemp dirs.) `print` exits 1 (= not armed) so arm paths proceed to the
# stubbed bootstrap instead of short-circuiting on the idempotence check.
export LAUNCHCTL_CMD="$T/launchctl-stub.sh" LOOM_PLIST_DIR="$T/plists"
LCTL_CALLS="$T/launchctl-calls"
cat > "$LAUNCHCTL_CMD" <<STUBEOF
#!/bin/sh
echo "\$@" >> "$LCTL_CALLS"
[ "\$1" = print ] && exit 1
exit 0
STUBEOF
chmod +x "$LAUNCHCTL_CMD"
# The pane opener, stubbed GLOBALLY for the same reason and by the same
# lesson. `install` now raises the viewer, so every test path through it opens
# real herdr panes whenever the suite runs from inside the multiplexer — which
# is where it is always run, since HERDR_ENV is inherited. (Paid for:
# 2026-08-04 — four suite runs left four orphan viewers polling deleted mktemp
# dirs and eight stacked panes on the human's screen.) Belt and braces:
# HERDR_ENV is cleared too, so _raise_viewer returns before it reaches the
# stub. Tests that exercise the raise set both deliberately and RESTORE these
# afterwards — never `unset`, which would disarm the guard for every test after
# them.
export WATCH_PANES_CMD="$T/watch-panes-stub.sh"
WP_GLOBAL_CALLS="$T/watch-panes-calls"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$WP_GLOBAL_CALLS" > "$WATCH_PANES_CMD"
chmod +x "$WATCH_PANES_CMD"
WP_GLOBAL_STUB="$WATCH_PANES_CMD"
export HERDR_ENV=
# Provider identity is an input each adapter test sets deliberately. Letting
# the surrounding developer session leak Codex identity into every fixture
# makes host-boundary tests depend on which agent happened to run the suite.
export CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI=
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# P45 bullet 2: every planted-violation test that runs a mutated/stand-in copy
# and then asserts an ABSENCE (no call made, no file written, no pidfile
# left) has to prove the copy actually ran BEFORE trusting that absence — an
# absence proves nothing if the thing that would have produced it never
# reached the code under test. Generalizes the shape already in use at
# 14-follow-and-panes.sh ([ "$rc_n" = 0 ] && ok ... || bad ...). D-TEST-05
# demonstrated the failure this closes: three watch-panes planted violations
# asserted only "no herdr call happened" against a copy that was `exit 127`
# (missing sibling, a `sed` that stopped matching, a syntax error) — a dead
# copy reads exactly like a live one whose mechanism was removed, and all
# three PASSed.
#
#   assert_mutant_ran <rc> <combined-output> <label>
#
# <rc>/<combined-output> are whatever the caller already captured running the
# mutated/stand-in copy. Returns 1 (after calling `bad`) when rc is 126 or
# 127 — the two codes bash itself uses for "never even started" (not
# executable / not found) — or when the copy produced no output at all, which
# cannot be told apart from "ran and legitimately stayed silent" any other
# way. Returns 0 otherwise and calls neither `ok` nor `bad`: "the copy ran" is
# a precondition for the caller's real assertion, not itself a pass worth
# counting — every test that adopts this still owns exactly one ok/bad pair
# for the thing it actually names.
#
#   out=$(HERDR_CMD="$deadstub" bash "$WP" 2>&1); rc=$?
#   assert_mutant_ran "$rc" "$out" "watch-panes-violation" || continue
#   [ -z "$(grep herdr-call ...)" ] && bad "..." || ok "..."
assert_mutant_ran() { # <rc> <combined-output> <label>
    local rc="$1" out="$2" label="$3"
    case "$rc" in
        126|127)
            bad "$label: mutated/stand-in copy did not run (rc $rc — not executable or not found), so the absence below proves nothing"
            return 1 ;;
    esac
    if [ -z "$out" ]; then
        bad "$label: mutated/stand-in copy produced no output at all — cannot tell 'ran and stayed silent' from 'never started'"
        return 1
    fi
    return 0
}

cat > "$LOOM_REPO/.loom.yml" <<'EOF'
heartbeat_stale_minutes: 30
ntfy:
  topic: "test-topic"
  push: [build_complete, ticket_blocked]
EOF

# Paths every section resolves the same way. They lived mid-file when the suite
# was one process and the later sections inherited them by falling through.
SNAPJQ="$(dirname "$TICK")/snapshot.jq"
LANE="$(dirname "$TICK")/lane.sh"
LIBSH="$(dirname "$TICK")/lib.sh"

# The canned tracker every snapshot test reads through: a `glab` stub serving
# fixed JSON and logging every invocation, so both the CONTENT of the document
# and the SHAPE of the call pattern are assertable. Two sections need it — the
# snapshot section, which owns the fixtures, and the ticker section, whose P72
# test copies it to prove snapshot.jq and lane.sh slugify a milestone title the
# same way.
make_glab_fixture() { # <dir>
    local FX="$1"
    mkdir -p "$FX"
cat > "$FX/open.json" <<'EOF'
[
 {"iid":1,"title":"Build 2","project_id":1,"web_url":"https://x/1","labels":["provider::claude"],"assignees":[],
  "description":"**Selected epics** (4 tickets, ~6h):\n- Ledger core (#10, #11, #12) — 4h\n- Reporting surface (#13) — 2h\n\n**Deliberately dropped** (remain unlabeled):\n- Archive sweep\n\nConfig snapshot:\n\n- max_lanes: 4\n"},
 {"iid":10,"title":"Add ledger table","project_id":1,"web_url":"https://x/10",
  "labels":["build-2","ready-for-agent"],"assignees":[],"updated_at":"2026-07-28T10:00:00Z",
  "milestone":{"title":"Ledger core"},
  "description":"## Risk tier\n\napi\n\n## Blocked by\n\n- #7 schema groundwork\n"},
 {"iid":11,"title":"Wire ledger API","project_id":1,"web_url":"https://x/11",
  "labels":["build-2","ready-for-agent","fix"],"assignees":[],"updated_at":"2026-07-28T11:00:00Z",
  "milestone":{"title":"Ledger core"},
  "description":"## Risk tier\n\nlogic\n\n## Blocked by\n\n- #10 ledger table\n- #13 seed data\n"},
 {"iid":12,"title":"Ledger report view","project_id":1,"web_url":"https://x/12",
  "labels":["build-2","review"],"assignees":[{"username":"agent-a"}],"updated_at":"2026-07-28T12:00:00Z",
  "milestone":{"title":"Ledger core"},"description":"## Blocked by\n\nNone - can start immediately\n"},
 {"iid":20,"title":"Unrelated open issue","project_id":1,"labels":["chore"],"assignees":[],"description":"noise"}
]
EOF
echo '[]' > "$FX/links-10.json"
cat > "$FX/links-11.json" <<'EOF'
[{"iid":10,"state":"opened","project_id":1,"link_type":"is_blocked_by"},
 {"iid":14,"state":"closed","project_id":1,"link_type":"is_blocked_by"},
 {"iid":21,"state":"opened","project_id":1,"link_type":"relates_to"}]
EOF
cat > "$FX/links-12.json" <<'EOF'
[{"iid":500,"project_id":42,"link_type":"is_blocked_by"}]
EOF
cat > "$FX/mrs-12.json" <<'EOF'
[{"iid":77,"title":"Ledger report view","state":"opened","draft":false,"web_url":"https://x/mr/77","source_branch":"t12","sha":"e52b7c1000000000000000000000000000000000"}]
EOF
cat > "$FX/notes.json" <<'EOF'
[{"system":true,"created_at":"2026-07-28T09:00:00Z","author":{"username":"bot"},"body":"added ~in-progress label"},
 {"system":false,"created_at":"2026-07-28T09:05:00Z","author":{"username":"wave"},"body":"W3: ui gates need the stack up first."}]
EOF
# P30 fixtures: #12 rejected twice for the SAME class (newest first, as the
# API returns them); #11 rejected twice for DIFFERENT classes.
cat > "$FX/notes-12.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T09:20:00Z","author":{"username":"gate"},"body":"r2: same trap again\n\n<!-- orch-verdict FAIL bbbb2222 class=marks-attribution -->"},
 {"system":false,"created_at":"2026-07-28T09:10:00Z","author":{"username":"gate"},"body":"r1: FIFO pairing\n\n<!-- orch-verdict FAIL aaaa1111 class=marks-attribution -->"}]
EOF
cat > "$FX/notes-12-changed-class.json" <<'EOF'
[{"system":false,"created_at":"2026-07-28T09:20:00Z","author":{"username":"gate"},"body":"r2\n\n<!-- orch-verdict FAIL bbbb2222 class=missing-tests -->"},
 {"system":false,"created_at":"2026-07-28T09:10:00Z","author":{"username":"gate"},"body":"r1\n\n<!-- orch-verdict FAIL aaaa1111 class=marks-attribution -->"}]
EOF
cat > "$FX/glab-stub.sh" <<'EOF'
#!/usr/bin/env bash
FX="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "${STUB_LOG:-/dev/null}"
# D-TEST-12: peak concurrency, counted rather than timed. A marker file exists
# for exactly as long as this call is in flight, so the highest count any call
# sees IS the peak overlap. Serial runs can never see more than 1, however slow
# or fast the machine is — where `elapsed < 3` was a wall-clock guess whose
# window sat inside its own +/-1s measurement error and failed under load.
if [ -n "${STUB_INFLIGHT_DIR:-}" ]; then
    mkdir -p "$STUB_INFLIGHT_DIR"
    : > "$STUB_INFLIGHT_DIR/$$"
    [ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
    n=$(find "$STUB_INFLIGHT_DIR" -type f 2>/dev/null | wc -l | tr -d " ")
    echo "$n" >> "${STUB_PEAK_LOG:-/dev/null}"
    rm -f "$STUB_INFLIGHT_DIR/$$"
elif [ -n "${STUB_SLEEP:-}" ]; then sleep "$STUB_SLEEP"; fi
case "$*" in
  *"state=opened"*) [ -n "${STUB_FAIL_STAGE1:-}" ] && { echo "500 boom" >&2; exit 1; }
                    cat "${STUB_OPEN:-$FX/open.json}" ;;
  *"state=closed"*) cat "${STUB_CLOSED:-$FX/closed-none.json}" 2>/dev/null || echo '[]' ;;
  *"/links"*)       [ -n "${STUB_403_LINKS:-}" ] && { echo "403 Forbidden" >&2; exit 1; }
                    n=$(echo "$*" | sed -n 's#.*issues/\([0-9]*\)/links.*#\1#p')
                    cat "$FX/links-$n.json" 2>/dev/null || echo '[]' ;;
  *"related_merge_requests"*) n=$(echo "$*" | sed -n 's#.*issues/\([0-9]*\)/related.*#\1#p')
                    cat "$FX/mrs-$n.json" 2>/dev/null || echo '[]' ;;
  *"/notes"*)       n=$(echo "$*" | sed -n 's#.*issues/\([0-9]*\)/notes.*#\1#p')
                    if [ -f "$FX/notes-$n.json" ]; then cat "$FX/notes-$n.json"
                    else cat "$FX/notes.json"; fi ;;
  *"milestones"*)   cat "${STUB_MILESTONES:-$FX/milestones.json}" 2>/dev/null || echo '[]' ;;
  *) echo "[]" ;;
esac
EOF
chmod +x "$FX/glab-stub.sh"
echo '[]' > "$FX/closed-none.json"
}

# The fake wave command emits canonical runtime events. It counts its own
# invocations, which is how "retries
# exactly once" becomes observable. Two sections need it — the usage-limit
# section, which owns every mode, and P74's consolidation test, which reuses
# `crash_then_limit` — so it lives here rather than in whichever runs first.
make_wave_stub() { # <path>
cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
echo "$@" >> "${WAVE_ARGV:-/dev/null}"
n=$(cat "$WAVE_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$WAVE_COUNT"
DONE='{"schema":1,"type":"session_end","provider":"claude","job":"wave","status":"success","rc":0}'
case "${WAVE_MODE:-ok}" in
  ok)    printf '%s\n' "$DONE" ;;
  crash) echo "Execution error" >&2; exit 1 ;;
  flaky) if [ "$n" -ge 2 ]; then printf '%s\n' "$DONE"
         else echo "Execution error" >&2; exit 1; fi ;;
  limit) printf '%s\n' "{\"schema\":1,\"type\":\"limit\",\"provider\":\"claude\",\"job\":\"wave\",\"reset_at\":${WAVE_RESET:-0}}"
         echo "You've hit your session limit · resets 10pm" >&2; exit 1 ;;
  quiet_limit)                       # a limit with no resetsAt to read
         echo "You've hit your usage limit" >&2; exit 1 ;;
  crash_then_limit)                  # crashes once, then meets the wall
         if [ "$n" -ge 2 ]; then
           printf '%s\n' "{\"schema\":1,\"type\":\"limit\",\"provider\":\"claude\",\"job\":\"wave\",\"reset_at\":${WAVE_RESET:-0}}"
           echo "You have hit your session limit" >&2
         else echo "Execution error" >&2; fi
         exit 1 ;;
  healthy_limit_event)               # a NORMAL wave that merely reports capacity
         printf '%s\n' '{"schema":1,"type":"limit","provider":"claude","job":"wave","reset_at":1}'
         printf '%s\n' "$DONE" ;;
esac
STUBEOF
chmod +x "$1"
}

# Whole-section guard, checked last because it is a property of every test in
# the section: nothing may reach the pane opener. The global stub catches a
# test that sets HERDR_ENV=1 without its own stub; a test that `unset`s the
# seam instead of restoring it escapes to the real script, which is why the two
# blocks that touch it restore. (Paid for: 2026-08-04, eight orphan panes.)
# One process per section means this now names the section that escaped.
test_finish() {
    local sec; sec=$(basename "$0" .sh)
    if [ ! -s "$WP_GLOBAL_CALLS" ]; then
        ok "$sec: no test reached the pane opener — this section opens no real panes"
    else
        bad "$sec: $(wc -l < "$WP_GLOBAL_CALLS" | tr -d ' ') call(s) escaped to the pane opener"
    fi

    # The driver reads exact counts from here rather than parsing output.
    [ -n "${LOOM_TEST_COUNTS:-}" ] && printf '%s %s\n' "$PASS" "$FAIL" > "$LOOM_TEST_COUNTS"
    if [ -z "${LOOM_TEST_QUIET:-}" ]; then
        echo; echo "== $PASS passed, $FAIL failed =="
    fi
    rm -rf "$T"
    exit $((FAIL > 0))
}
