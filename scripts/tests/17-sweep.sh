#!/usr/bin/env bash
# the merged-worktree teardown that had never once succeeded
#
# Section 17 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- sweep: the merged-worktree teardown that had never once succeeded ------
# `st=$(git status --porcelain | grep -v '^??' | head -1)` exits 1 whenever the
# grep filters out every line, and under `set -euo pipefail` that killed the
# whole sweep silently (rc=1) before removing anything. A merged worktree whose
# only leftovers are untracked files is the COMMON case, so sweep never worked:
# merged worktrees accumulated and a wave removed one by hand (2026-08-03).
SW="$T/sweep"; mkdir -p "$SW"
# P83: sweep now asks the tracker whether THIS BRANCH's own MR merged, so the
# section needs a glab that answers without a network. Default: no branch has a
# merged MR, which drops every existing case back onto the commit-range test and
# is exactly the old behaviour. $SWEEP_MERGED names the branches that did merge.
cat > "$SW/glab-stub.sh" <<'GLABEOF'
#!/usr/bin/env bash
q=""; for a in "$@"; do case "$a" in *source_branch=*) q="$a" ;; esac; done
br="${q##*source_branch=}"; br="${br%%&*}"
if [ -n "${SWEEP_MERGED:-}" ] && printf '%s' " $SWEEP_MERGED " | grep -q " $br "; then
    printf '[{"iid":1,"state":"merged","source_branch":"%s"}]\n' "$br"
else
    printf '[]\n'
fi
GLABEOF
chmod +x "$SW/glab-stub.sh"
export GLAB_CMD="$SW/glab-stub.sh"
git -c init.defaultBranch=main init -q --bare "$SW/origin.git"
git clone -q "$SW/origin.git" "$SW/repo" 2>/dev/null
git -C "$SW/repo" config user.email t@t; git -C "$SW/repo" config user.name t
echo base > "$SW/repo/f"; git -C "$SW/repo" add f
# The debris the sweep is FOR is debris git already ignores — node_modules, a
# .venv, a build dir. Ignoring it here is what makes the untracked-work case
# below distinguishable from it (D-TICK-17).
printf 'dist/\nlocked/\n' > "$SW/repo/.gitignore"; git -C "$SW/repo" add .gitignore
git -C "$SW/repo" commit -qm base; git -C "$SW/repo" push -q origin main
# A ticket branch that IS merged into origin/main — i.e. genuinely sweepable.
git -C "$SW/repo" checkout -qb done-work
echo more > "$SW/repo/g"; git -C "$SW/repo" add g; git -C "$SW/repo" commit -qm work
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" merge -q --no-edit done-work; git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-7" done-work 2>/dev/null
# The trigger: leftovers that are ALL ignored (build artifacts, node_modules).
mkdir -p "$SW/repo-wt-7/dist"; echo junk > "$SW/repo-wt-7/dist/out.js"
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out" 2>&1; rc_sw=$?
if [ "$rc_sw" = 0 ] && [ ! -e "$SW/repo-wt-7" ]; then
    ok "sweep: removes a merged worktree whose only leftovers are ignored"
else
    bad "sweep: rc=$rc_sw, worktree still present=$([ -e "$SW/repo-wt-7" ] && echo yes || echo no) ($(head -1 "$SW/out"))"
fi

# New Loom worktrees are nested under the writable main clone. Sweep must own
# those paths while retaining compatibility with legacy sibling worktrees.
git -C "$SW/repo" checkout -qb done-work-nested main
echo nested > "$SW/repo/nested"; git -C "$SW/repo" add nested; git -C "$SW/repo" commit -qm nested
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" merge -q --no-edit done-work-nested; git -C "$SW/repo" push -q origin main
mkdir -p "$SW/repo/.worktrees"
git -C "$SW/repo" worktree add -q "$SW/repo/.worktrees/11" done-work-nested 2>/dev/null
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out-nested" 2>&1
if [ ! -e "$SW/repo/.worktrees/11" ]; then
    ok "sweep: removes a merged nested .worktrees lane"
else
    bad "sweep: left a merged nested .worktrees lane behind"
fi

# MEND-LIVE-01: a host pregate can update a tracked test artifact even when
# every assertion passes. That output is useful evidence, but it is not ticket
# work: leaving it in the checkout makes the later merged-worktree sweep hold
# the tree forever as `modified-tracked`. The host boundary must preserve the
# output outside the worktree, restore the clean pre-gate file, and let a green
# merged ticket sweep normally.
GA="$T/gate-artifact-sweep"; mkdir -p "$GA"
git -c init.defaultBranch=main init -q --bare "$GA/origin.git"
git clone -q "$GA/origin.git" "$GA/repo" 2>/dev/null
git -C "$GA/repo" config user.email t@t; git -C "$GA/repo" config user.name t
mkdir -p "$GA/repo/tests/artifacts" "$GA/repo/scripts" "$GA/repo/docs/agents"
printf '{"run":"baseline"}\n' > "$GA/repo/tests/artifacts/e8-run.json"
printf '{"note":"baseline"}\n' > "$GA/repo/tests/artifacts/user-note.json"
printf '{"deleted":"baseline"}\n' > "$GA/repo/tests/artifacts/deleted.json"
printf 'deployment baseline\n' > "$GA/repo/docs/deploy.md"
printf 'base\n' > "$GA/repo/f"
printf '# Issue tracker: GitLab\n' > "$GA/repo/docs/agents/issue-tracker.md"
cat > "$GA/repo/scripts/gate.sh" <<'GATEEOF'
#!/usr/bin/env bash
echo "gate evidence: deterministic outputs exercised"
printf '{"run":"gate-output"}\n' > tests/artifacts/e8-run.json
printf 'deployment gate output\n' > docs/deploy.md
[ "${GATE_WRITE_UNKNOWN:-0}" != 1 ] || printf 'unknown gate output\n' > f
[ "${GATE_COLLIDE_DELETED:-0}" != 1 ] || printf '{"deleted":"runner overwrite"}\n' > tests/artifacts/deleted.json
[ "${GATE_COLLIDE_UNTRACKED:-0}" != 1 ] || printf '{"untracked":"runner overwrite"}\n' > tests/artifacts/untracked.json
[ "${GATE_CREATE_UNTRACKED:-0}" != 1 ] || printf '{"generated":"runner"}\n' > tests/artifacts/generated.json
[ "${GATE_CREATE_STAGED:-0}" != 1 ] || { printf '{"staged":"runner"}\n' > tests/artifacts/staged.json; git add tests/artifacts/staged.json; }
[ "${GATE_FORCE_FAIL:-0}" != 1 ] || { echo "gate failed intentionally" >&2; exit 23; }
exit 0
GATEEOF
chmod +x "$GA/repo/scripts/gate.sh"
printf 'runner: scripts/gate.sh\n' > "$GA/repo/.loom.yml"
git -C "$GA/repo" add . && git -C "$GA/repo" commit -qm base
git -C "$GA/repo" push -q origin main
mkdir -p "$GA/repo/.worktrees"

_wait_gate_artifact_lane() { # <home> <id>
    local home="$1" id="$2" i pid
    for i in $(seq 1 100); do [ -f "$home/lanes/$id.rc" ] && break; sleep 0.05; done
    pid=$(cat "$home/lanes/$id.pid" 2>/dev/null || true)
    for i in $(seq 1 100); do
        [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null && return 0
        sleep 0.05
    done
    return 0
}

git -C "$GA/repo" worktree add -q "$GA/repo/.worktrees/310" -b ticket-310-artifact origin/main 2>/dev/null
GA_HOME="$GA/home-green"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_HOME" \
  "$TICK" spawn-lane gate-310 --no-tick --pregate ui \
  --cwd "$GA/repo/.worktrees/310" -- touch "$GA/reviewed-310" >/dev/null
_wait_gate_artifact_lane "$GA_HOME" gate-310
if [ "$(cat "$GA_HOME/lanes/gate-310.rc" 2>/dev/null)" = 0 ] \
   && grep -q '"run":"baseline"' "$GA/repo/.worktrees/310/tests/artifacts/e8-run.json" \
   && grep -q 'deployment baseline' "$GA/repo/.worktrees/310/docs/deploy.md" \
   && grep -q 'gate evidence: deterministic outputs exercised' "$GA_HOME/logs/lane-gate-310.log" \
   && ! find "$GA_HOME/lanes" -name 'gate-310.pregate-artifacts*' -print -quit | grep -q .; then
    ok "pregate artifacts: a green gate keeps transcript evidence, restores outputs, and clears snapshot state"
else
    bad "pregate artifacts: green gate left output dirty, lost transcript evidence, or leaked snapshot state"
fi
SWEEP_MERGED="ticket-310-artifact" GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_HOME" \
  "$TICK" sweep >"$GA/sweep-green.out" 2>&1
if [ ! -e "$GA/repo/.worktrees/310" ]; then
    ok "pregate artifacts: a green merged ticket sweeps after its deterministic tracked output is restored"
else
    bad "pregate artifacts: gate-generated tracked output still holds a completed worktree ($(head -1 "$GA/sweep-green.out"))"
fi

# JOR-290 already carried a dirty generated artifact. Snapshot both its staged
# and unstaged bytes, let the runner overwrite that SAME path, then prove the
# exact pre-gate index/worktree state returns and keeps sweep fail-closed.
git -C "$GA/repo" worktree add -q "$GA/repo/.worktrees/311" -b ticket-311-user-edit origin/main 2>/dev/null
printf '{"run":"user staged"}\n' > "$GA/repo/.worktrees/311/tests/artifacts/e8-run.json"
git -C "$GA/repo/.worktrees/311" add tests/artifacts/e8-run.json
printf '{"run":"user unstaged"}\n' > "$GA/repo/.worktrees/311/tests/artifacts/e8-run.json"
GA_USER_HOME="$GA/home-user"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_USER_HOME" \
  "$TICK" spawn-lane gate-311 --no-tick --pregate ui \
  --cwd "$GA/repo/.worktrees/311" -- touch "$GA/reviewed-311" >/dev/null
_wait_gate_artifact_lane "$GA_USER_HOME" gate-311
SWEEP_MERGED="ticket-311-user-edit" GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_USER_HOME" \
  "$TICK" sweep >"$GA/sweep-user.out" 2>&1
if [ -e "$GA/repo/.worktrees/311" ] \
   && grep -q '"run":"user unstaged"' "$GA/repo/.worktrees/311/tests/artifacts/e8-run.json" \
   && git -C "$GA/repo/.worktrees/311" show :tests/artifacts/e8-run.json | grep -q '"run":"user staged"' \
   && grep -q 'modified tracked files' "$GA/sweep-user.out"; then
    ok "pregate artifacts: same-path staged and unstaged edits survive the runner and remain held"
else
    bad "pregate artifacts: same-path pre-gate bytes were erased or escaped sweep's hold"
fi

# A new modification outside the narrow deterministic-output allowlist is not
# inferred to be gate-owned. Preserve it in place and let sweep surface it.
git -C "$GA/repo" worktree add -q "$GA/repo/.worktrees/313" -b ticket-313-unknown-output origin/main 2>/dev/null
GA_UNKNOWN_HOME="$GA/home-unknown"
GATE_WRITE_UNKNOWN=1 GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_UNKNOWN_HOME" \
  "$TICK" spawn-lane gate-313 --no-tick --pregate ui \
  --cwd "$GA/repo/.worktrees/313" -- touch "$GA/reviewed-313" >/dev/null
_wait_gate_artifact_lane "$GA_UNKNOWN_HOME" gate-313
SWEEP_MERGED="ticket-313-unknown-output" GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_UNKNOWN_HOME" \
  "$TICK" sweep >"$GA/sweep-unknown.out" 2>&1
if [ "$(cat "$GA_UNKNOWN_HOME/lanes/gate-313.rc" 2>/dev/null)" = 7 ] \
   && [ ! -e "$GA/reviewed-313" ] \
   && [ -e "$GA/repo/.worktrees/313" ] \
   && grep -qxF 'unknown gate output' "$GA/repo/.worktrees/313/f" \
   && grep -q 'modified tracked files' "$GA/sweep-unknown.out"; then
    ok "pregate artifacts: an unknown tracked output remains dirty and suppresses review"
else
    bad "pregate artifacts: an unknown tracked output was erased, reviewed, or escaped sweep's hold"
fi

# A failing runner still owns cleanup before rc 7 is published: it leaves the
# exact pre-gate files, never starts review, retains stdout/stderr as evidence,
# and consumes the temporary snapshot state.
git -C "$GA/repo" worktree add -q "$GA/repo/.worktrees/314" -b ticket-314-red-runner origin/main 2>/dev/null
GA_RED_HOME="$GA/home-red"
GATE_FORCE_FAIL=1 GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_RED_HOME" \
  "$TICK" spawn-lane gate-314 --no-tick --pregate ui \
  --cwd "$GA/repo/.worktrees/314" -- touch "$GA/reviewed-314" >/dev/null
_wait_gate_artifact_lane "$GA_RED_HOME" gate-314
if [ "$(cat "$GA_RED_HOME/lanes/gate-314.rc" 2>/dev/null)" = 7 ] \
   && [ ! -e "$GA/reviewed-314" ] \
   && grep -q '"run":"baseline"' "$GA/repo/.worktrees/314/tests/artifacts/e8-run.json" \
   && grep -q 'deployment baseline' "$GA/repo/.worktrees/314/docs/deploy.md" \
   && grep -q 'gate failed intentionally' "$GA_RED_HOME/logs/lane-gate-314.log" \
   && ! find "$GA_RED_HOME/lanes" -name 'gate-314.pregate-artifacts*' -print -quit | grep -q .; then
    ok "pregate artifacts: a red runner restores exact state, keeps transcript evidence, and exits 7"
else
    bad "pregate artifacts: failed-runner cleanup lost state, evidence, or rejection semantics"
fi

# `git rm --cached` is both a staged deletion and an untracked worktree file.
# The tracked stash trees cannot encode those remaining bytes, so refuse before
# the runner overwrites them and preserve both index absence and file content.
git -C "$GA/repo" worktree add -q "$GA/repo/.worktrees/315" -b ticket-315-staged-delete origin/main 2>/dev/null
printf '{"deleted":"user worktree bytes"}\n' > "$GA/repo/.worktrees/315/tests/artifacts/deleted.json"
git -C "$GA/repo/.worktrees/315" rm -q --cached tests/artifacts/deleted.json
GA_DELETED_HOME="$GA/home-staged-delete"
GATE_COLLIDE_DELETED=1 GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_DELETED_HOME" \
  "$TICK" spawn-lane gate-315 --no-tick --pregate ui \
  --cwd "$GA/repo/.worktrees/315" -- touch "$GA/reviewed-315" >/dev/null
_wait_gate_artifact_lane "$GA_DELETED_HOME" gate-315
if [ "$(cat "$GA_DELETED_HOME/lanes/gate-315.rc" 2>/dev/null)" = 7 ] \
   && [ ! -e "$GA/reviewed-315" ] \
   && grep -q '"deleted":"user worktree bytes"' "$GA/repo/.worktrees/315/tests/artifacts/deleted.json" \
   && ! git -C "$GA/repo/.worktrees/315" ls-files --error-unmatch tests/artifacts/deleted.json >/dev/null 2>&1 \
   && grep -q 'refusing rather than overwrite pre-existing work' "$GA_DELETED_HOME/logs/lane-gate-315.log" \
   && ! find "$GA_DELETED_HOME/lanes" -name 'gate-315.pregate-artifacts*' -print -quit | grep -q .; then
    ok "pregate artifacts: staged-delete worktree bytes refuse before runner and remain exact"
else
    bad "pregate artifacts: staged-delete collision ran or lost index/worktree state"
fi

# A plain pre-existing untracked allowlisted file has the same unrepresentable
# ownership and must take the same pre-run refusal path.
git -C "$GA/repo" worktree add -q "$GA/repo/.worktrees/316" -b ticket-316-untracked origin/main 2>/dev/null
printf '{"untracked":"user bytes"}\n' > "$GA/repo/.worktrees/316/tests/artifacts/untracked.json"
GA_UNTRACKED_HOME="$GA/home-untracked"
GATE_COLLIDE_UNTRACKED=1 GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_UNTRACKED_HOME" \
  "$TICK" spawn-lane gate-316 --no-tick --pregate ui \
  --cwd "$GA/repo/.worktrees/316" -- touch "$GA/reviewed-316" >/dev/null
_wait_gate_artifact_lane "$GA_UNTRACKED_HOME" gate-316
if [ "$(cat "$GA_UNTRACKED_HOME/lanes/gate-316.rc" 2>/dev/null)" = 7 ] \
   && [ ! -e "$GA/reviewed-316" ] \
   && grep -q '"untracked":"user bytes"' "$GA/repo/.worktrees/316/tests/artifacts/untracked.json" \
   && ! git -C "$GA/repo/.worktrees/316" ls-files --error-unmatch tests/artifacts/untracked.json >/dev/null 2>&1; then
    ok "pregate artifacts: pre-existing untracked same-path collision refuses before runner"
else
    bad "pregate artifacts: pre-existing untracked collision was overwritten or admitted"
fi

# With no pre-run file, the same allowlisted untracked output is provably
# runner-owned and exact restoration means removing it before review starts.
git -C "$GA/repo" worktree add -q "$GA/repo/.worktrees/318" -b ticket-318-generated-untracked origin/main 2>/dev/null
GA_GENERATED_HOME="$GA/home-generated"
GATE_CREATE_UNTRACKED=1 GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_GENERATED_HOME" \
  "$TICK" spawn-lane gate-318 --no-tick --pregate ui \
  --cwd "$GA/repo/.worktrees/318" -- touch "$GA/reviewed-318" >/dev/null
_wait_gate_artifact_lane "$GA_GENERATED_HOME" gate-318
if [ "$(cat "$GA_GENERATED_HOME/lanes/gate-318.rc" 2>/dev/null)" = 0 ] \
   && [ -e "$GA/reviewed-318" ] \
   && [ ! -e "$GA/repo/.worktrees/318/tests/artifacts/generated.json" ]; then
    ok "pregate artifacts: runner-created untracked output returns to exact pre-run absence"
else
    bad "pregate artifacts: runner-created untracked output survived cleanup or blocked review"
fi

# A newly staged allowlisted output is absent from both pre-run trees. Restore
# its index absence, then remove the now-untracked worktree file before review.
git -C "$GA/repo" worktree add -q "$GA/repo/.worktrees/319" -b ticket-319-generated-staged origin/main 2>/dev/null
GA_STAGED_HOME="$GA/home-staged"
GATE_CREATE_STAGED=1 GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_STAGED_HOME" \
  "$TICK" spawn-lane gate-319 --no-tick --pregate ui \
  --cwd "$GA/repo/.worktrees/319" -- touch "$GA/reviewed-319" >/dev/null
_wait_gate_artifact_lane "$GA_STAGED_HOME" gate-319
if [ "$(cat "$GA_STAGED_HOME/lanes/gate-319.rc" 2>/dev/null)" = 0 ] \
   && [ -e "$GA/reviewed-319" ] \
   && [ ! -e "$GA/repo/.worktrees/319/tests/artifacts/staged.json" ] \
   && git -C "$GA/repo/.worktrees/319" diff --quiet \
   && git -C "$GA/repo/.worktrees/319" diff --cached --quiet; then
    ok "pregate artifacts: newly staged deterministic output returns to exact pre-run absence"
else
    bad "pregate artifacts: newly staged deterministic output survived cleanup or blocked review"
fi

# Planted collision violation: bypass only the pre-run untracked refusal. The
# runner overwrites the user's bytes, finish treats the file as generated and
# removes it, then sweep deletes the falsely clean worktree.
git -C "$GA/repo" worktree add -q "$GA/repo/.worktrees/317" -b ticket-317-untracked-mutant origin/main 2>/dev/null
printf '{"untracked":"user mutant bytes"}\n' > "$GA/repo/.worktrees/317/tests/artifacts/untracked.json"
MUT_UNTRACKED_ARTIFACT=$(mirror_scripts "$GA/mut-untracked-artifact")
sed -i.bak 's/if \[ -s "\$untracked" \]; then # mutate:pregate-refuse-untracked-collision/if false; then # mutate:pregate-refuse-untracked-collision/' \
  "$MUT_UNTRACKED_ARTIFACT/tick.sh"
if cmp -s "$MUT_UNTRACKED_ARTIFACT/tick.sh" "$TICK"; then
    bad "pregate-untracked-violation: sed did not match the pre-run collision guard"
else
    GA_UNTRACKED_MUT_HOME="$GA/home-untracked-mutant"
    mut_untracked_out=$(GATE_COLLIDE_UNTRACKED=1 GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_UNTRACKED_MUT_HOME" \
      "$MUT_UNTRACKED_ARTIFACT/tick.sh" spawn-lane gate-317 --no-tick --pregate ui \
      --cwd "$GA/repo/.worktrees/317" -- touch "$GA/reviewed-317" 2>&1); mut_untracked_rc=$?
    _wait_gate_artifact_lane "$GA_UNTRACKED_MUT_HOME" gate-317
    SWEEP_MERGED="ticket-317-untracked-mutant" GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_UNTRACKED_MUT_HOME" \
      "$MUT_UNTRACKED_ARTIFACT/tick.sh" sweep >"$GA/sweep-untracked-mutant.out" 2>&1
    if assert_mutant_ran "$mut_untracked_rc" "$mut_untracked_out" "pregate-untracked-violation"; then
        if [ ! -e "$GA/repo/.worktrees/317" ]; then
            ok "pregate-untracked-violation: bypassing collision refusal erases user bytes and sweeps"
        else
            bad "pregate-untracked-violation: planted guard bypass did not recreate user-byte loss"
        fi
    fi
fi

# Planted violation: replace both exact snapshot trees with HEAD. The public
# gate + sweep path then erases the same-path staged and unstaged edit and
# removes the tree, proving the stash-tree pair carries the safety property.
git -C "$GA/repo" worktree add -q "$GA/repo/.worktrees/312" -b ticket-312-user-edit-mutant origin/main 2>/dev/null
printf '{"run":"user staged mutant"}\n' > "$GA/repo/.worktrees/312/tests/artifacts/e8-run.json"
git -C "$GA/repo/.worktrees/312" add tests/artifacts/e8-run.json
printf '{"run":"user unstaged mutant"}\n' > "$GA/repo/.worktrees/312/tests/artifacts/e8-run.json"
MUT_GATE_ARTIFACT=$(mirror_scripts "$GA/mut-gate-artifact")
sed -i.bak 's@^        index_tree=.*# mutate:pregate-preserve-exact-state$@        worktree_tree="$head"; index_tree="$head" # mutate:pregate-preserve-exact-state@' \
  "$MUT_GATE_ARTIFACT/tick.sh"
if cmp -s "$MUT_GATE_ARTIFACT/tick.sh" "$TICK"; then
    bad "pregate-artifact-violation: sed did not match the exact-state snapshot, mutant is identical to the fix"
else
    GA_MUT_HOME="$GA/home-mutant"
    mut_gate_out=$(GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_MUT_HOME" \
      "$MUT_GATE_ARTIFACT/tick.sh" spawn-lane gate-312 --no-tick --pregate ui \
      --cwd "$GA/repo/.worktrees/312" -- touch "$GA/reviewed-312" 2>&1); mut_gate_rc=$?
    _wait_gate_artifact_lane "$GA_MUT_HOME" gate-312
    SWEEP_MERGED="ticket-312-user-edit-mutant" GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$GA/repo" LOOM_HOME="$GA_MUT_HOME" \
      "$MUT_GATE_ARTIFACT/tick.sh" sweep >>"$GA/sweep-mutant.out" 2>&1
    if assert_mutant_ran "$mut_gate_rc" "$mut_gate_out" "pregate-artifact-violation"; then
        if [ ! -e "$GA/repo/.worktrees/312" ]; then
            ok "pregate-artifact-violation: replacing exact snapshots with HEAD erases same-path edits and sweeps"
        else
            bad "pregate-artifact-violation: planted snapshot loss did not recreate same-path user-edit loss"
        fi
    fi
fi

# A provider-backed worker can be durably queued after its worktree is
# prepared but before any process exists there. The queued cwd is already
# committed launch ownership; sweep must preserve it through that host gap.
git -C "$SW/repo" worktree add -q "$SW/repo/.worktrees/240" -b loom-240 origin/main 2>/dev/null
printf 'queued implementation\n' > "$SW/queued-brief.md"
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/queued-home" LOOM_DEFER_LANE_LAUNCH=1 \
  "$TICK" spawn-lane impl-240 --no-tick --provider codex --job implementation \
  --tier medium --brief "$SW/queued-brief.md" --cwd "$SW/repo/.worktrees/240" >/dev/null
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/queued-home" "$TICK" sweep >"$SW/out-queued" 2>&1
if [ -d "$SW/repo/.worktrees/240" ] \
   && find "$SW/queued-home/lane-launch-queue" -name 'request-*impl-240' -type d 2>/dev/null | grep -q .; then
    ok "sweep: preserves a prepared worktree owned by a durable lane request"
else
    bad "sweep: deleted a queued lane's prepared worktree before the durable host launched it"
fi
# Planted violation: keep live-process protection but remove queued-cwd
# ownership from a private copy. The same public sweep must delete the clean
# prepared checkout again, proving the durable request guard carries the fix.
MUT_QUEUED_SWEEP=$(mirror_scripts "$SW/mut-queued-sweep")
sed -i.bak 's@protected_cwds="$protected_cwds $queued_cwd"@protected_cwds="$protected_cwds"@' \
  "$MUT_QUEUED_SWEEP/tick.sh"
mut_queued_out=$(LOOM_REPO="$SW/repo" LOOM_HOME="$SW/queued-home" \
  "$MUT_QUEUED_SWEEP/tick.sh" sweep 2>&1); mut_queued_rc=$?
if assert_mutant_ran "$mut_queued_rc" "$mut_queued_out" "queued-worktree-violation"; then
    if [ ! -e "$SW/repo/.worktrees/240" ] \
       && printf '%s' "$mut_queued_out" | grep -q 'removed merged worktree'; then
        ok "sweep-violation: dropping queued cwd ownership recreates the pre-launch deletion"
    else
        bad "sweep-violation: planted queued-cwd omission did not recreate deletion (rc=$mut_queued_rc)"
    fi
fi

# A supervised repair owns the matching ticket worktree even when no lane or
# durable launch request does. This is the exact dangerous shape: clean,
# zero-ahead work looks disposable to the ordinary sweep rules while a human
# is about to edit it. Acquire and release from the linked checkout so this
# also proves sweep consumes the canonical repository's lease state.
SUP="$T/sweep-supervised"; mkdir -p "$SUP"
git -c init.defaultBranch=main init -q --bare "$SUP/origin.git"
git clone -q "$SUP/origin.git" "$SUP/repo" 2>/dev/null
SUP_REPO=$(cd "$SUP/repo" && pwd -P)
git -C "$SUP/repo" config user.email t@t; git -C "$SUP/repo" config user.name t
echo base > "$SUP/repo/f"; git -C "$SUP/repo" add f
git -C "$SUP/repo" commit -qm base; git -C "$SUP/repo" push -q origin main
mkdir -p "$SUP/repo/.worktrees" "$SUP/operator-home"
git -C "$SUP/repo" worktree add -q "$SUP/repo/.worktrees/216" -b loom-216 origin/main 2>/dev/null

(cd "$SUP/repo/.worktrees/216" && env -u LOOM_HOME -u LOOM_REPO HOME="$SUP/operator-home" \
  "$TICK" supervise acquire 216 --owner root/resolve_206 --ttl-seconds 3600 >/dev/null)
GLAB_CMD="$SW/glab-stub.sh" env -u LOOM_HOME HOME="$SUP/operator-home" LOOM_REPO="$SUP_REPO" \
  "$TICK" sweep >"$SUP/active.out" 2>&1
if [ -d "$SUP/repo/.worktrees/216" ]; then
    ok "sweep: active canonical supervised lease preserves its ticket worktree"
else
    bad "sweep: deleted a clean ticket worktree under active supervised ownership"
fi

if [ -d "$SUP/repo/.worktrees/216" ]; then
    (cd "$SUP/repo/.worktrees/216" && env -u LOOM_HOME -u LOOM_REPO HOME="$SUP/operator-home" \
      "$TICK" supervise release 216 >/dev/null)
else
    env -u LOOM_HOME HOME="$SUP/operator-home" LOOM_REPO="$SUP_REPO" \
      "$TICK" supervise release 216 >/dev/null
fi
GLAB_CMD="$SW/glab-stub.sh" env -u LOOM_HOME HOME="$SUP/operator-home" LOOM_REPO="$SUP_REPO" \
  "$TICK" sweep >"$SUP/released.out" 2>&1
if [ ! -e "$SUP/repo/.worktrees/216" ]; then
    ok "sweep: released supervised worktree returns to ordinary cleanup"
else
    bad "sweep: released clean ticket worktree remained protected"
fi

# Expiry is intentionally fail-open for scheduling and cleanup. A stale lease
# file must not preserve a clean checkout forever after its supervisor dies.
git -C "$SUP/repo" worktree add -q "$SUP/repo/.worktrees/217" -b loom-217 origin/main 2>/dev/null
(cd "$SUP/repo/.worktrees/217" && env -u LOOM_HOME -u LOOM_REPO HOME="$SUP/operator-home" \
  "$TICK" supervise acquire 217 --owner root/expired --ttl-seconds 3600 >/dev/null)
lease217=$(find "$SUP/operator-home/.loom" -path '*/supervised-leases/217.json' -type f -print -quit)
jq '.expires_at = 1' "$lease217" > "$lease217.tmp" && mv "$lease217.tmp" "$lease217"
GLAB_CMD="$SW/glab-stub.sh" env -u LOOM_HOME HOME="$SUP/operator-home" LOOM_REPO="$SUP_REPO" \
  "$TICK" sweep >"$SUP/expired.out" 2>&1
if [ ! -e "$SUP/repo/.worktrees/217" ]; then
    ok "sweep: expired supervised lease does not retain stale worktree ownership"
else
    bad "sweep: expired supervised lease retained a clean ticket worktree"
fi

# Planted violation: keep canonical lease reads intact but drop only their cwd
# ownership from a private tick.sh. The same public sweep must delete the
# leased zero-ahead checkout again, proving the new ownership fold is causal.
git -C "$SUP/repo" worktree add -q "$SUP/repo/.worktrees/218" -b loom-218 origin/main 2>/dev/null
(cd "$SUP/repo/.worktrees/218" && env -u LOOM_HOME -u LOOM_REPO HOME="$SUP/operator-home" \
  "$TICK" supervise acquire 218 --owner root/mutant --ttl-seconds 3600 >/dev/null)
MUT_SUP_SWEEP=$(mirror_scripts "$SUP/mut-no-supervised-cwd")
sed -i.bak 's@protected_cwds="$protected_cwds $REPO_ROOT/.worktrees/$ticket $REPO_ROOT-wt-$ticket"@protected_cwds="$protected_cwds"@' \
  "$MUT_SUP_SWEEP/tick.sh"
mut_sup_out=$(GLAB_CMD="$SW/glab-stub.sh" env -u LOOM_HOME HOME="$SUP/operator-home" LOOM_REPO="$SUP_REPO" \
  "$MUT_SUP_SWEEP/tick.sh" sweep 2>&1); mut_sup_rc=$?
if assert_mutant_ran "$mut_sup_rc" "$mut_sup_out" "supervised-sweep-violation"; then
    if [ ! -e "$SUP/repo/.worktrees/218" ] \
       && printf '%s' "$mut_sup_out" | grep -q 'removed merged worktree'; then
        ok "sweep-violation: dropping supervised cwd ownership recreates deletion"
    else
        bad "sweep-violation: supervised-cwd omission did not recreate deletion (rc=$mut_sup_rc)"
    fi
fi
env -u LOOM_HOME HOME="$SUP/operator-home" LOOM_REPO="$SUP_REPO" \
  "$TICK" supervise release 218 >/dev/null

# The safety boundary: unmerged work is never ours to delete. Fixing the crash
# above ARMED a deletion path that had never executed, so prove it still stops.
git -C "$SW/repo" checkout -qb live-work origin/main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-8" -b wip origin/main 2>/dev/null
echo wip > "$SW/repo-wt-8/new.txt"
git -C "$SW/repo-wt-8" add new.txt
git -C "$SW/repo-wt-8" -c user.email=t@t -c user.name=t commit -qm wip
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
if [ -e "$SW/repo-wt-8" ]; then
    ok "sweep: keeps a worktree holding unmerged commits"
else
    bad "sweep: deleted a worktree with unmerged work"
fi

# P46: a `stale` lane is alive but silent, not gone — filtering the live-cwd
# guard on `running` alone let it fall through, and a lane that had not yet
# committed (indistinguishable from merged work, its new files untracked) was
# seconds from `rm -rf` under its own live process. Same merged-branch setup as
# repo-wt-7, but this worktree holds a REAL process the status reads `stale`.
git -C "$SW/repo" checkout -qb done-work-2 main
echo more2 > "$SW/repo/h"; git -C "$SW/repo" add h; git -C "$SW/repo" commit -qm work2
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" merge -q --no-edit done-work-2; git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-9" done-work-2 2>/dev/null
printf 'heartbeat_stale_minutes: 0\n' > "$SW/repo/.loom.yml"
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" spawn-lane impl-96 --cwd "$SW/repo-wt-9" -- sleep 20 >/dev/null
touch -t 202001010000 "$SW/home/logs/lane-impl-96.log"
st=$(LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" lane-status | awk '$1=="impl-96"{print $3}')
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out96" 2>&1
if [ "$st" = stale ] && [ -e "$SW/repo-wt-9" ]; then
    ok "sweep: a stale-but-alive lane's worktree survives (P46)"
else
    bad "sweep: stale lane's worktree mishandled (state=$st, present=$([ -e "$SW/repo-wt-9" ] && echo yes || echo no))"
fi
kill "$(cat "$SW/home/lanes/impl-96.pid" 2>/dev/null)" 2>/dev/null
rm -f "$SW/repo/.loom.yml"

# D-TICK-17: a lane's unsaved work is UNTRACKED work, and the merged path used
# to filter untracked files out before asking whether the worktree was empty.
# A lane that had not committed yet was therefore indistinguishable from a
# swept-clean merged worktree: zero commits ahead of the base, nothing modified
# among tracked files. boostlingo build-4 #98 lost ~100 turns of work that way.
# Ignored debris (dist/, above) is still debris; this file is not ignored.
git -C "$SW/repo" checkout -qb done-work-3 main
echo more3 > "$SW/repo/i"; git -C "$SW/repo" add i; git -C "$SW/repo" commit -qm work3
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" merge -q --no-edit done-work-3; git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-10" done-work-3 2>/dev/null
mkdir -p "$SW/repo-wt-10/scripts"; echo 'the instrument the ticket was built around' > "$SW/repo-wt-10/scripts/verify.mjs"
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out10" 2>&1
if [ -e "$SW/repo-wt-10/scripts/verify.mjs" ] && grep -q 'holds untracked work' "$SW/out10"; then
    ok "D-TICK-17: a merged worktree holding untracked, non-ignored work is kept"
else
    bad "D-TICK-17: untracked work swept (file present=$([ -e "$SW/repo-wt-10/scripts/verify.mjs" ] && echo yes || echo no)) — $(grep -c . "$SW/out10") line(s): $(head -2 "$SW/out10" | tr '\n' ' ')"
fi

# The two cases below need a directory git and `rm -rf` genuinely CANNOT
# remove. Permissions do not bind root, so as root there is no way to stage the
# failure at all — say so rather than assert something weaker.
if [ "$(id -u)" != 0 ]; then
    # D-TICK-17: "kept" was a promise sweep broke about sixty seconds later.
    # `worktree remove` is not atomic — it drops .git/worktrees/<name> before
    # it fails on the unreadable directory, `worktree prune` finishes that off,
    # and the next pass reads its own leftover as an orphaned corpse and
    # deletes it down a path with no ahead check and no dirty check.
    git -C "$SW/repo" checkout -qb done-work-4 main
    echo more4 > "$SW/repo/j"; git -C "$SW/repo" add j; git -C "$SW/repo" commit -qm work4
    git -C "$SW/repo" checkout -q main
    git -C "$SW/repo" merge -q --no-edit done-work-4; git -C "$SW/repo" push -q origin main
    git -C "$SW/repo" worktree add -q "$SW/repo-wt-11" done-work-4 2>/dev/null
    # Ignored, so the guard above does not fire — this worktree reaches the
    # removal exactly as wt-14 did, and the removal fails exactly as it did.
    mkdir -p "$SW/repo-wt-11/locked"; echo pinned > "$SW/repo-wt-11/locked/f"
    chmod 500 "$SW/repo-wt-11/locked"
    LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out11" 2>&1
    if [ -e "$SW/repo-wt-11" ] && [ -f "$SW/repo-wt-11/.loom-sweep-hold" ] && grep -q 'refused to remove' "$SW/out11"; then
        ok "D-TICK-17: a refused removal leaves the hold marker behind"
    else
        bad "D-TICK-17: no hold marker after a refused removal ($(head -3 "$SW/out11" | tr '\n' ' '))"
    fi
    # The corpse shape the live log showed, staged exactly: the gitdir pointer
    # still in the worktree, the metadata it points at already pruned away.
    printf 'gitdir: %s/.git/worktrees/repo-wt-11\n' "$SW/repo" > "$SW/repo-wt-11/.git"
    rm -rf "$SW/repo/.git/worktrees/repo-wt-11"
    LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out11b" 2>&1
    if [ -f "$SW/repo-wt-11/locked/f" ] && grep -q 'held from an earlier failed removal' "$SW/out11b"; then
        ok "D-TICK-17: the corpse path honours the earlier pass's 'kept' instead of deleting it"
    else
        bad "D-TICK-17: the corpse path deleted what the previous pass promised to keep ($(head -3 "$SW/out11b" | tr '\n' ' '))"
    fi
    chmod 700 "$SW/repo-wt-11/locked"

    # `rm -rf`'s status was thrown away, so a partial delete printed the same
    # line as a completed one — in the one place in the program that destroys
    # work. The live log showed five `rm` failures immediately above "removed".
    git -C "$SW/repo" worktree add -q "$SW/repo-wt-12" -b done-work-5 origin/main 2>/dev/null
    mkdir -p "$SW/repo-wt-12/locked"; echo pinned > "$SW/repo-wt-12/locked/f"
    chmod 500 "$SW/repo-wt-12/locked"
    printf 'gitdir: %s/.git/worktrees/repo-wt-12\n' "$SW/repo" > "$SW/repo-wt-12/.git"
    rm -rf "$SW/repo/.git/worktrees/repo-wt-12"
    LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out12" 2>&1
    if grep -q 'could not fully remove' "$SW/out12" && ! grep -q 'removed orphaned worktree corpse .*repo-wt-12' "$SW/out12"; then
        ok "D-TICK-17: a corpse only partly deleted is reported as partly deleted"
    else
        bad "D-TICK-17: a failed corpse removal read as success ($(grep 'repo-wt-12' "$SW/out12" | head -2 | tr '\n' ' '))"
    fi
    chmod 700 "$SW/repo-wt-12/locked"
else
    echo "note: running as root — the two unremovable-directory cases cannot be staged, so they did not run"
fi

# --- P83: "merged" is a tracker fact, not a commit-range guess -------------
# `lane.sh reconcile` merges origin/<base> into the branch. Run once more after
# the push whose MR merged, the local tip carries a merge commit that was never
# pushed, so origin/<base>..<branch> is non-empty FOREVER and the worktree is
# permanently unsweepable. Fifteen of build-5's thirty held worktrees were this,
# every one showing a single unpushed reconcile merge.
# The shape that produces it: GitLab merged the MR by squash, so main carries an
# EQUIVALENT commit with a different sha, and the branch's own commit is never an
# ancestor of main. The reconcile merge is then a real merge, not a fast-forward,
# and the range is non-empty forever. (Build-5's example named both shas:
# cd520f8 the pushed tip, e583729 what landed on main.)
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" checkout -qb ticket-96-reconciled
echo p83 > "$SW/repo/p83"; git -C "$SW/repo" add p83; git -C "$SW/repo" commit -qm p83
git -C "$SW/repo" checkout -q main
echo p83 > "$SW/repo/p83"; git -C "$SW/repo" add p83
git -C "$SW/repo" commit -qm 'p83 (squashed onto main, different sha)'
git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-96" ticket-96-reconciled 2>/dev/null
git -C "$SW/repo-wt-96" -c user.email=t@t -c user.name=t merge -q --no-edit origin/main 2>/dev/null
[ -n "$(git -C "$SW/repo" log "origin/main..ticket-96-reconciled" --oneline 2>/dev/null)" ] \
    && ok "P83-setup: the reconciled branch really is ahead of base — the old test would keep it" \
    || bad "P83-setup: fixture does not reproduce the unpushed reconcile merge"
SWEEP_MERGED="ticket-96-reconciled" LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >"$SW/out96" 2>&1
[ ! -e "$SW/repo-wt-96" ] \
    && ok "P83: a branch whose own MR merged is swept even with an unpushed reconcile merge on top" \
    || bad "P83: the reconciled worktree survived ($(head -1 "$SW/out96"))"

# Planted violation: the identical worktree, with the tracker answering "no
# merged MR" so the commit range decides as it used to. It must be kept — that
# is the failure this proposal is about, reproduced on demand.
git -C "$SW/repo" checkout -q main
git -C "$SW/repo" checkout -qb ticket-97-reconciled
echo p83b > "$SW/repo/p83b"; git -C "$SW/repo" add p83b; git -C "$SW/repo" commit -qm p83b
git -C "$SW/repo" checkout -q main
echo p83b > "$SW/repo/p83b"; git -C "$SW/repo" add p83b
git -C "$SW/repo" commit -qm 'p83b (squashed onto main, different sha)'
git -C "$SW/repo" push -q origin main
git -C "$SW/repo" worktree add -q "$SW/repo-wt-97" ticket-97-reconciled 2>/dev/null
git -C "$SW/repo-wt-97" -c user.email=t@t -c user.name=t merge -q --no-edit origin/main 2>/dev/null
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
[ -e "$SW/repo-wt-97" ] \
    && ok "P83-violation: with the range deciding, the reconciled worktree is kept — the old failure" \
    || bad "P83-violation: worktree removed with no merged MR to justify it"

# THE constraint. #67 shipped as bbac984 from ticket-67-pending-turn-bound;
# ticket-67-realtime-turn-mark-pairing sat beside it with three commits and a
# 238-line variant that merged in no form. The ticket was closed and the feature
# live, so any fix keyed on TICKET state deletes this worktree and those lines —
# D-TICK-17 through another door. Nothing at sweep time separates a discarded
# draft from live work; only the branch's own merged MR may decide.
git -C "$SW/repo" worktree add -q "$SW/repo-wt-67" -b ticket-67-abandoned origin/main 2>/dev/null
echo draft > "$SW/repo-wt-67/draft.txt"; git -C "$SW/repo-wt-67" add draft.txt
git -C "$SW/repo-wt-67" -c user.email=t@t -c user.name=t commit -qm 'rejected first draft'
# the ticket's OTHER branch is the one that merged — ticket state says "closed"
SWEEP_MERGED="ticket-67-shipped" LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
if [ -e "$SW/repo-wt-67" ] && [ -f "$SW/repo-wt-67/draft.txt" ]; then
    ok "P83: a branch whose ticket closed via a DIFFERENT branch's MR is not swept"
else
    bad "P83: the abandoned #67-shape branch was deleted — ticket state reached the delete path"
fi

# An MR that was closed UNMERGED is not a merge. The query asks state=merged, so
# this is the same "no" as never having opened one — assert it, or the cheap
# variant's gap would be implied rather than recorded.
git -C "$SW/repo" worktree add -q "$SW/repo-wt-68" -b ticket-68-rejected origin/main 2>/dev/null
echo rej > "$SW/repo-wt-68/rej.txt"; git -C "$SW/repo-wt-68" add rej.txt
git -C "$SW/repo-wt-68" -c user.email=t@t -c user.name=t commit -qm 'closed unmerged'
LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
[ -e "$SW/repo-wt-68" ] \
    && ok "P83: a branch whose MR was closed unmerged is not swept" \
    || bad "P83: a closed-unmerged branch was swept"

# The tracker being unreadable is not an answer. A glab that fails must drop
# sweep back to the conservative range test, never to "merged".
cat > "$SW/glab-dead.sh" <<'DEADEOF'
#!/usr/bin/env bash
echo "fatal: could not read the board" >&2; exit 1
DEADEOF
chmod +x "$SW/glab-dead.sh"
GLAB_CMD="$SW/glab-dead.sh" LOOM_REPO="$SW/repo" LOOM_HOME="$SW/home" "$TICK" sweep >/dev/null 2>&1
[ -e "$SW/repo-wt-67" ] \
    && ok "P83: an unreadable tracker falls back to the range test, and keeps the work" \
    || bad "P83: a failed board read reached the delete path"


# --- P85: sweep's decisions reach a human ----------------------------------
# For five builds sweep printed "kept, needs a human" for every worktree on
# every tick — into a wave's log file, which no human reads. It emitted no
# event, so nothing reached the ticker, the pushes or the completion report,
# and build-5 tore its agent down with thirty worktrees standing, silently.
P85="$T/p85"; mkdir -p "$P85"
git -c init.defaultBranch=main init -q --bare "$P85/origin.git"
git clone -q "$P85/origin.git" "$P85/repo" 2>/dev/null
git -C "$P85/repo" config user.email t@t; git -C "$P85/repo" config user.name t
echo base > "$P85/repo/f"; git -C "$P85/repo" add f; git -C "$P85/repo" commit -qm base
git -C "$P85/repo" push -q origin main
git -C "$P85/repo" worktree add -q "$P85/repo-wt-3" -b held-work origin/main 2>/dev/null
echo unsaved > "$P85/repo-wt-3/unsaved.txt"     # untracked, not ignored — the D-TICK-17 hold
EV="$P85/home/events.jsonl"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
if grep -q '"ev":"sweep_held"' "$EV" 2>/dev/null; then
    ok "P85: a pass that keeps a worktree emits sweep_held"
else
    bad "P85: sweep kept a worktree and emitted nothing ($(tail -1 "$EV" 2>/dev/null))"
fi
grep -q '"ev":"sweep_held".*"count":1' "$EV" \
    && ok "P85: the event carries the count" \
    || bad "P85: sweep_held has no usable count ($(grep sweep_held "$EV" | head -1))"
grep -q '"reason":"untracked-work"' "$EV" \
    && ok "P85: the event names the dominant reason" \
    || bad "P85: sweep_held does not name why"
# One event per PASS, not per worktree — thirty lines a tick is not a signal.
git -C "$P85/repo" worktree add -q "$P85/repo-wt-4" -b held-work-2 origin/main 2>/dev/null
echo unsaved > "$P85/repo-wt-4/unsaved.txt"
: > "$EV"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
n=$(grep -c '"ev":"sweep_held"' "$EV" 2>/dev/null || echo 0)
[ "$n" = 1 ] && grep -q '"count":2' "$EV" \
    && ok "P85: two held worktrees produce one event carrying 2, not two events" \
    || bad "P85: $n sweep_held events for two worktrees"
# Planted violation: with the emit removed, the pane learns nothing — which is
# exactly the five-build silence this proposal is about.
sed 's/_ev sweep_held /: sweep_held /' "$TICK" > "$P85/tick-mute.sh"; chmod +x "$P85/tick-mute.sh"
: > "$EV"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$P85/tick-mute.sh" sweep >/dev/null 2>&1
grep -q '"ev":"sweep_held"' "$EV" 2>/dev/null \
    && bad "P85-violation: the muted sweep still emitted" \
    || ok "P85-violation: with the emit removed the ticker hears nothing — the old behaviour"

# D-TICK-11 is OPEN: render-events indexes on .state and silently drops any
# event without one. A sweep event that omitted it would be invisible in the
# exact pane this proposal exists to reach — so assert the RENDERED line, not
# the log line.
: > "$EV"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
out=$(LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" render-events 2>&1)
case "$out" in
    *"sweep kept"*) ok "P85: the ticker renders the hold — it survives the D-TICK-11 .state drop" ;;
    *) bad "P85: sweep_held is logged but never rendered ($(printf '%s' "$out" | tail -1))" ;;
esac
# Removals are visible too, and a clean pass says nothing at all.
: > "$EV"
rm -rf "$P85/repo-wt-3/unsaved.txt" "$P85/repo-wt-4/unsaved.txt"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
grep -q '"ev":"sweep_removed"' "$EV" \
    && ok "P85: a pass that removes says so" \
    || bad "P85: removals are still silent"
: > "$EV"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
if grep -q '"ev":"sweep_held"' "$EV" || grep -q '"ev":"sweep_removed"' "$EV"; then
    bad "P85: a sweep with nothing to do still emitted"
else
    ok "P85: a clean pass emits nothing — the count is a signal, not a heartbeat"
fi

# The completion announcement carries the inventory, because a build that
# reports complete while leaving worktrees behind is reporting on part of its
# own work. Appended by cmd_notify rather than asked of the wave.
git -C "$P85/repo" worktree add -q "$P85/repo-wt-5" -b held-work-3 origin/main 2>/dev/null
echo unsaved > "$P85/repo-wt-5/unsaved.txt"
GLAB_CMD="$SW/glab-stub.sh" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" "$TICK" sweep >/dev/null 2>&1
# The body is only observable on the push path — the no-topic fallback hands it
# to osascript and prints nothing. Give the repo a topic and record the args.
printf 'ntfy:\n  topic: p85-topic\n  push: [build_complete]\n' > "$P85/repo/.loom.yml"
cat > "$P85/ntfy-stub.sh" <<'NTFYEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${NTFY_ARGS:-/dev/null}"
NTFYEOF
chmod +x "$P85/ntfy-stub.sh"
NTFY_ARGS="$P85/ntfy-args" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" \
    NTFY_CMD="$P85/ntfy-stub.sh" "$TICK" notify build_complete "Build complete" "every ticket merged" >/dev/null 2>&1
if grep -q 'kept by sweep' "$P85/ntfy-args" 2>/dev/null; then
    ok "P85: a completion announcement names the leftover inventory"
else
    bad "P85: build_complete said nothing about the worktrees it left standing"
fi
grep -q 'repo-wt-5' "$P85/ntfy-args" 2>/dev/null \
    && ok "P85: the inventory names the worktrees, not just a number" \
    || bad "P85: the inventory carries no worktree names ($(tr '\n' ' ' < "$P85/ntfy-args" | cut -c1-120))"
rm -f "$P85/home/sweep-held.txt"
NTFY_ARGS="$P85/ntfy-args2" LOOM_REPO="$P85/repo" LOOM_HOME="$P85/home" \
    NTFY_CMD="$P85/ntfy-stub.sh" "$TICK" notify build_complete "Build complete" "every ticket merged" >/dev/null 2>&1
grep -q 'kept by sweep' "$P85/ntfy-args2" 2>/dev/null \
    && bad "P85: a clean build still reported an inventory" \
    || ok "P85: with nothing held, the announcement stays quiet about it"


test_finish
