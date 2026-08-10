#!/usr/bin/env bash
# P73 lib.sh: one copy of the facts both halves derive
#
# Section 25 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- P73 lib.sh: one copy of the facts both halves derive ------------------
# The base-branch rule — declared `base:`, else develop where the remote has
# it, else main — was written SIX times across tick.sh and lane.sh, and the
# sixth had already drifted: `submit` probed `ls-remote` for develop and never
# read the config key, so a repo declaring `base:` got its MRs targeted at a
# branch its own merges never reconciled against. lib.sh now holds that rule
# once, plus the config readers, the lockfile→toolchain table, the paginating
# list read and `die`, and tick.sh, lane.sh and bootstrap.sh all source it.
LIBSH="$(dirname "$TICK")/lib.sh"
BOOTSH="$(dirname "$TICK")/bootstrap.sh"
LB="$T/p73"; mkdir -p "$LB"

# lb1. The entry rule that lets the READ half and the WRITE half share one
#      file: pure functions, nothing runs at source time. Sourcing it in a
#      bare directory must print nothing, create nothing, exit 0. If it ever
#      did otherwise, lane.sh could not source it without inheriting exactly
#      the side effects that "lane.sh never sources tick.sh" exists to avoid —
#      tick.sh's top level makes directories, resolves REPO_ROOT and can exit.
mkdir -p "$LB/bare"
lb_out=$(cd "$LB/bare" && bash -c '. "$1"' _ "$LIBSH" 2>&1); lb_rc=$?
lb_n=$(ls -A "$LB/bare" | wc -l | tr -d ' ')
if [ "$lb_rc" = 0 ] && [ -z "$lb_out" ] && [ "$lb_n" = 0 ]; then
    ok "lib.sh: sourcing it in a bare directory prints nothing, creates nothing, rc 0"
else
    bad "lib.sh: source time is not inert (rc=$lb_rc, files=$lb_n, out=$(printf '%s' "$lb_out" | head -1))"
fi
# Planted violation: a lib carrying ONE line of source-time work — the very
# mkdir tick.sh does at its own top level — and the same check must catch it.
mkdir -p "$LB/dirty" "$LB/bare2"
{ cat "$LIBSH"; echo 'mkdir -p impure-dir'; echo 'echo loaded'; } > "$LB/dirty/lib.sh"
lb_out=$(cd "$LB/bare2" && bash -c '. "$1"' _ "$LB/dirty/lib.sh" 2>&1)
lb_n=$(ls -A "$LB/bare2" | wc -l | tr -d ' ')
if [ -n "$lb_out" ] && [ "$lb_n" != 0 ]; then
    ok "lib.sh: a lib that runs anything at source time is caught by that check"
else
    bad "lib.sh: source-time side effects went unnoticed (files=$lb_n, out=[$lb_out])"
fi

# lb2. A missing lib.sh is named as the missing file, in every script that
#      sources it — the same guard snapshot.jq gets, for the same reason:
#      unchecked, the failure is a stream of "command not found" from whichever
#      function ran first and never mentions the file that vanished. Each keeps
#      its own exit code, because briefs and the scheduler read those: lane.sh
#      refuses with 2, tick.sh and bootstrap.sh with 1.
lb_t0=$("$TICK" lane-status 2>&1)
lb_l0=$(GLAB_CMD=/usr/bin/true "$LANE" nosuchverb 2>&1)
lb_b0=$("$BOOTSH" nosuchverb 2>&1)
case "$lb_t0$lb_l0$lb_b0" in
    *lib.sh*) bad "lib.sh: a present lib is still being reported as missing" ;;
    *) ok "lib.sh: with the lib in place no script mentions it — the guard is quiet" ;;
esac
mv "$LIBSH" "$LB/lib.sh.hidden"
lb_t=$("$TICK" lane-status 2>&1); lb_trc=$?
lb_l=$(GLAB_CMD=/usr/bin/true "$LANE" nosuchverb 2>&1); lb_lrc=$?
lb_b=$("$BOOTSH" nosuchverb 2>&1); lb_brc=$?
mv "$LB/lib.sh.hidden" "$LIBSH"
if [ "$lb_trc" = 1 ] && printf '%s' "$lb_t" | grep -q 'lib.sh is missing'; then
    ok "lib.sh: tick.sh names the missing lib and exits 1"
else
    bad "lib.sh: tick.sh with no lib (rc=$lb_trc: $(printf '%s' "$lb_t" | head -1))"
fi
if [ "$lb_lrc" = 2 ] && printf '%s' "$lb_l" | grep -q 'lib.sh is missing'; then
    ok "lib.sh: lane.sh names the missing lib and keeps its own exit code 2"
else
    bad "lib.sh: lane.sh with no lib (rc=$lb_lrc: $(printf '%s' "$lb_l" | head -1))"
fi
if [ "$lb_brc" = 1 ] && printf '%s' "$lb_b" | grep -q 'lib.sh is missing'; then
    ok "lib.sh: bootstrap.sh names the missing lib and exits 1"
else
    bad "lib.sh: bootstrap.sh with no lib (rc=$lb_brc: $(printf '%s' "$lb_b" | head -1))"
fi

# lb3. The base rule, asked at every migrated site, over one fixture whose
#      three possible answers are each provable by a file on the ground:
#      origin carries main, develop (holding `on-develop`) and trunk (holding
#      `on-trunk`).
LBB="$LB/baserule"; mkdir -p "$LBB"
git -c init.defaultBranch=main init -q --bare "$LBB/origin.git"
git clone -q "$LBB/origin.git" "$LBB/repo" 2>/dev/null
git -C "$LBB/repo" config user.email t@t; git -C "$LBB/repo" config user.name t
echo base > "$LBB/repo/f"; git -C "$LBB/repo" add f
git -C "$LBB/repo" commit -qm base; git -C "$LBB/repo" push -q origin main
git -C "$LBB/repo" checkout -qb develop
echo d > "$LBB/repo/on-develop"; git -C "$LBB/repo" add on-develop
git -C "$LBB/repo" commit -qm dev; git -C "$LBB/repo" push -q origin develop
git -C "$LBB/repo" checkout -qb trunk main
echo t > "$LBB/repo/on-trunk"; git -C "$LBB/repo" add on-trunk
git -C "$LBB/repo" commit -qm trunk; git -C "$LBB/repo" push -q origin trunk
git -C "$LBB/repo" checkout -q main
# A second repo whose origin has main and nothing else — the third answer.
LBM="$LB/mainonly"; mkdir -p "$LBM"
git -c init.defaultBranch=main init -q --bare "$LBM/origin.git"
git clone -q "$LBM/origin.git" "$LBM/repo" 2>/dev/null
git -C "$LBM/repo" config user.email t@t; git -C "$LBM/repo" config user.name t
echo base > "$LBM/repo/f"; git -C "$LBM/repo" add f
git -C "$LBM/repo" commit -qm base; git -C "$LBM/repo" push -q origin main

# (a) resolve-config publishes the base a wave composes spawn lines against.
rm -f "$LBB/repo/.loom.yml"
lb_b1=$(LOOM_REPO="$LBB/repo" "$TICK" resolve-config | jq -r .base)
printf 'base: trunk\n' > "$LBB/repo/.loom.yml"
lb_b2=$(LOOM_REPO="$LBB/repo" "$TICK" resolve-config | jq -r .base)
lb_b3=$(LOOM_REPO="$LBM/repo" "$TICK" resolve-config | jq -r .base)
if [ "$lb_b1" = develop ] && [ "$lb_b2" = trunk ] && [ "$lb_b3" = main ]; then
    ok "base rule: resolve-config answers develop / declared base / main, in that order of precedence"
else
    bad "base rule: resolve-config gave [$lb_b1] [$lb_b2] [$lb_b3], wanted develop/trunk/main"
fi

# (b) lane.sh base-check builds its clean-base worktree at the SAME base — it
#     used to consult no config at all, so a repo declaring `base:` had its
#     base-red evidence gathered on a branch nobody merges to.
lb_bc1=0; ( cd "$LBB/repo" && GLAB_CMD=/usr/bin/true "$LANE" base-check -- test -e on-trunk ) >/dev/null 2>&1 || lb_bc1=$?
lb_bc2=0; ( cd "$LBB/repo" && GLAB_CMD=/usr/bin/true "$LANE" base-check -- test -e on-develop ) >/dev/null 2>&1 || lb_bc2=$?
rm -f "$LBB/repo/.loom.yml"
lb_bc3=0; ( cd "$LBB/repo" && GLAB_CMD=/usr/bin/true "$LANE" base-check -- test -e on-develop ) >/dev/null 2>&1 || lb_bc3=$?
if [ "$lb_bc1" = 0 ] && [ "$lb_bc2" != 0 ] && [ "$lb_bc3" = 0 ]; then
    ok "base rule: base-check runs on the DECLARED base, and on develop when none is declared"
else
    bad "base rule: base-check rc trunk=$lb_bc1 develop-under-trunk=$lb_bc2 develop-undeclared=$lb_bc3"
fi

# (c) reconcile merges the same base, so a lane's branch is measured against
#     the branch it will actually be merged into.
git -C "$LBB/repo" checkout -q -b feat-undeclared main
( cd "$LBB/repo" && GLAB_CMD=/usr/bin/true "$LANE" reconcile ) >/dev/null 2>&1
lb_r1=$([ -e "$LBB/repo/on-develop" ] && echo develop || echo other)
printf 'base: trunk\n' > "$LBB/repo/.loom.yml"
git -C "$LBB/repo" checkout -q -b feat-declared main
( cd "$LBB/repo" && GLAB_CMD=/usr/bin/true "$LANE" reconcile ) >/dev/null 2>&1
lb_r2=$([ -e "$LBB/repo/on-trunk" ] && [ ! -e "$LBB/repo/on-develop" ] && echo trunk || echo other)
git -C "$LBB/repo" checkout -q main
if [ "$lb_r1" = develop ] && [ "$lb_r2" = trunk ]; then
    ok "base rule: reconcile merges the declared base, and develop when none is declared"
else
    bad "base rule: reconcile merged [$lb_r1] undeclared and [$lb_r2] declared"
fi

# (d) sweep decides whether a worktree's work has landed by asking `git log
#     origin/<base>..<branch>` — so the base it picks is the difference
#     between deleting a merged worktree and deleting unmerged work. This
#     branch is contained in origin/develop and NOT in origin/main.
LBS="$LB/sweepbase"; mkdir -p "$LBS"
git -c init.defaultBranch=main init -q --bare "$LBS/origin.git"
git clone -q "$LBS/origin.git" "$LBS/repo" 2>/dev/null
git -C "$LBS/repo" config user.email t@t; git -C "$LBS/repo" config user.name t
echo base > "$LBS/repo/f"; git -C "$LBS/repo" add f
git -C "$LBS/repo" commit -qm base; git -C "$LBS/repo" push -q origin main
git -C "$LBS/repo" checkout -qb done-work
echo w > "$LBS/repo/g"; git -C "$LBS/repo" add g; git -C "$LBS/repo" commit -qm work
git -C "$LBS/repo" checkout -qb develop main
git -C "$LBS/repo" merge -q --no-edit done-work; git -C "$LBS/repo" push -q origin develop
git -C "$LBS/repo" checkout -q main
git -C "$LBS/repo" worktree add -q "$LBS/repo-wt-7" done-work 2>/dev/null
printf 'base: main\n' > "$LBS/repo/.loom.yml"
LOOM_REPO="$LBS/repo" LOOM_HOME="$LBS/home" "$TICK" sweep >/dev/null 2>&1
lb_sw1=$([ -e "$LBS/repo-wt-7" ] && echo kept || echo removed)
rm -f "$LBS/repo/.loom.yml"
LOOM_REPO="$LBS/repo" LOOM_HOME="$LBS/home" "$TICK" sweep >/dev/null 2>&1
lb_sw2=$([ -e "$LBS/repo-wt-7" ] && echo kept || echo removed)
if [ "$lb_sw1" = kept ] && [ "$lb_sw2" = removed ]; then
    ok "base rule: sweep measures containment against the declared base — work unmerged there is kept"
else
    bad "base rule: sweep under base:main=$lb_sw1, undeclared=$lb_sw2 (wanted kept/removed)"
fi

# (e) Planted violation: one lib whose `_detect_base` no longer reads the
#     config key — the drift this proposal names, reintroduced in the single
#     place it can now live. Both halves must flip together, which is the
#     whole claim: one rule, one landing site.
mkdir -p "$LB/nocfg"
for jf in snapshot.jq render.jq render-events.jq usage.jq report.jq report-ticket.jq retro.jq graph.jq lib.jq; do
    ln -sf "$(dirname "$TICK")/$jf" "$LB/nocfg/$jf"
done
link_trackers "$LB/nocfg"
cp "$TICK" "$LB/nocfg/tick.sh"; chmod +x "$LB/nocfg/tick.sh"
cp "$LANE" "$LB/nocfg/lane.sh"; chmod +x "$LB/nocfg/lane.sh"
sed 's/^    base=\$(_yaml_scalar "\$cfgf" base)$/    base=""/' "$LIBSH" > "$LB/nocfg/lib.sh"
printf 'base: trunk\n' > "$LBB/repo/.loom.yml"
lb_v1=$(LOOM_REPO="$LBB/repo" "$LB/nocfg/tick.sh" resolve-config | jq -r .base)
lb_v2=0; ( cd "$LBB/repo" && GLAB_CMD=/usr/bin/true "$LB/nocfg/lane.sh" base-check -- test -e on-trunk ) >/dev/null 2>&1 || lb_v2=$?
if [ "$lb_v1" = develop ] && [ "$lb_v2" != 0 ]; then
    ok "base rule: with the config read removed BOTH halves fall back to develop — one rule, one landing site"
else
    bad "base rule: violation not detected (resolve-config=[$lb_v1], base-check rc=$lb_v2)"
fi

# lb4. The drift itself. `submit` opened its MR against a base derived by a
#      DIFFERENT rule from the one `reconcile` and the merge lane use: an
#      `ls-remote` probe for develop, config key never consulted. A repo that
#      declares `base:` therefore got MRs pointed somewhere its own merges
#      never reconcile against, and nothing said so.
LBU="$LB/submitbase"; mkdir -p "$LBU"
git -c init.defaultBranch=main init -q --bare "$LBU/origin.git"
git clone -q "$LBU/origin.git" "$LBU/repo" 2>/dev/null
git -C "$LBU/repo" config user.email t@t; git -C "$LBU/repo" config user.name t
echo base > "$LBU/repo/f"; git -C "$LBU/repo" add f
git -C "$LBU/repo" commit -qm base; git -C "$LBU/repo" push -q origin main
git -C "$LBU/repo" checkout -qb trunk; git -C "$LBU/repo" push -q origin trunk
git -C "$LBU/repo" checkout -q main
printf 'base: trunk\n' > "$LBU/repo/.loom.yml"
cat > "$LBU/glab-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"POST projects/:fullpath/merge_requests"*) echo '{"iid":4}' ;;
  *"closed_by"*)  echo '[]' ;;
  *"issues/"*)    echo '{"state":"opened","title":"Add ledger table","labels":["build-9","in-progress"]}' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$LBU/glab-stub.sh"
git -C "$LBU/repo" checkout -qb ticket-51
echo w > "$LBU/repo/g"; git -C "$LBU/repo" add g; git -C "$LBU/repo" commit -qm work
git -C "$LBU/repo" push -q -u origin ticket-51
: > "$LBU/calls"
( cd "$LBU/repo" && GLAB_CMD="$LBU/glab-stub.sh" STUB_LOG="$LBU/calls" "$LANE" submit 51 <<'EOB'
Implements the ledger table.
EOB
) >"$LBU/out" 2>&1; lb_src=$?
if [ "$lb_src" = 0 ] && grep -q 'target_branch=trunk' "$LBU/calls"; then
    ok "submit: the MR targets the DECLARED base, the same one reconcile merges"
else
    bad "submit: rc=$lb_src, target was $(sed -n 's/.*\(target_branch=[^ ]*\).*/\1/p' "$LBU/calls" | head -1) ($(head -1 "$LBU/out"))"
fi
# Planted violation: submit's own probe put back exactly as it stood — the
# ls-remote question, config key unread. This is what today's code did, and it
# targets main while every merge in the repo reconciles against trunk.
mkdir -p "$LB/olddrift"; ln -sf "$LIBSH" "$LB/olddrift/lib.sh"; ln -sf "$TICK" "$LB/olddrift/tick.sh"
link_trackers "$LB/olddrift"
sed '/^cmd_submit()/,/^}/s|base=\$(_detect_base \.)|if git ls-remote --exit-code --heads origin develop >/dev/null 2>\&1; then base=develop; else base=main; fi|' \
    "$LANE" > "$LB/olddrift/lane.sh"; chmod +x "$LB/olddrift/lane.sh"
git -C "$LBU/repo" checkout -qb ticket-52 main
echo x > "$LBU/repo/h"; git -C "$LBU/repo" add h; git -C "$LBU/repo" commit -qm work52
git -C "$LBU/repo" push -q -u origin ticket-52
: > "$LBU/calls2"
( cd "$LBU/repo" && GLAB_CMD="$LBU/glab-stub.sh" STUB_LOG="$LBU/calls2" "$LB/olddrift/lane.sh" submit 52 <<'EOB'
body
EOB
) >/dev/null 2>&1
if grep -q 'target_branch=main' "$LBU/calls2"; then
    ok "submit: with the old ls-remote probe back, the MR targets main and the declared base is ignored"
else
    bad "submit: the restored drift did not reproduce ($(sed -n 's/.*\(target_branch=[^ ]*\).*/\1/p' "$LBU/calls2" | head -1))"
fi

test_finish
