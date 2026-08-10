#!/usr/bin/env bash
# P86: the tracker is declared once, and every tracker call goes through one driver
#
# Section 29 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- P86 stage 1: the declaration, and the halt ----------------------------
# Loom never read the file its own lanes follow. A lane is a `claude -p`
# session in a worktree, so it loads that repo's CLAUDE.md, whose `## Agent
# skills` block points at `docs/agents/issue-tracker.md` — where the sibling
# skills record which tracker this repo uses and how to work it. Without that
# file a headless lane infers a tracker from the git remote and guesses; with a
# second copy of the answer inside loom, `tick.sh` could read one board while
# the lanes it spawns write to another. So loom reads that one file, and
# refuses when it cannot.
BOOT="$(cd "$(dirname "$TICK")" && pwd)/bootstrap.sh"
TD="$T/p86"; mkdir -p "$TD"

# A tracker stub shared by every case below. It logs argv, so "no call was
# made" is assertable rather than assumed.
mkdir -p "$TD/fx"
cat > "$TD/fx/glab" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"/labels"*) printf '%s' '[{"name":"blocked"}]' ;;
  *)           echo "[]" ;;
esac
EOF
chmod +x "$TD/fx/glab"

mkrepo() { # mkrepo <dir> — a git repo with NO declaration in it
    mkdir -p "$1"
    git -C "$1" init -q >/dev/null 2>&1
    git -C "$1" config user.email loom@test >/dev/null 2>&1
    git -C "$1" config user.name loom >/dev/null 2>&1
}
P86ENV() { # run a command against <repo> with the stub tracker
    local repo="$1"; shift
    LOOM_REPO="$repo" LOOM_HOME="$TD/home-$(basename "$repo")" \
      LOOM_GLOBAL_CONFIG="$TD/g.yml" GLAB_CMD="$TD/fx/glab" \
      STUB_LOG="$TD/calls-$(basename "$repo").log" LOOM_SKIP_BOOTSTRAP= \
      LOOM_WAVE_CMD="sh -c 'echo wave-ran >> $TD/waves.log'" "$@"
}

# --- p86-1. The file is absent --------------------------------------------
# The write half must refuse BEFORE it writes anything. bootstrap's order is
# global config, then the allowlist, then the labels — so "no label call" alone
# would not prove it stopped early enough; the settings file is the earlier
# write and has to be absent too.
mkrepo "$TD/none"
: > "$TD/calls-none.log"
out=$(P86ENV "$TD/none" "$BOOT" all 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "docs/agents/issue-tracker.md"; then
    ok "halt: bootstrap refuses a repo with no tracker declaration, naming the file"
else
    bad "halt: bootstrap did not refuse an undeclared repo (rc=$rc, out=$(printf '%s' "$out" | head -1))"
fi
if [ ! -s "$TD/calls-none.log" ] && [ ! -e "$TD/none/.claude/settings.json" ]; then
    ok "halt: it refused before ANY write — no tracker call, no allowlist on disk"
else
    bad "halt: bootstrap wrote something before refusing (calls=$(wc -l < "$TD/calls-none.log" | tr -d ' '), settings=$([ -e "$TD/none/.claude/settings.json" ] && echo yes || echo no))"
fi
# `--dry-run` is refused too: a preview of the labels for a tracker nobody
# named is not a preview of anything.
out=$(P86ENV "$TD/none" "$BOOT" all --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] \
    && ok "halt: 'bootstrap all --dry-run' is refused as well, not previewed" \
    || bad "halt: --dry-run previewed a build for an undeclared tracker"

# The read half, at the one board read every other read verb funnels through.
out=$(P86ENV "$TD/none" "$TICK" snapshot 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "issue-tracker.md" \
    && ok "halt: 'tick.sh snapshot' refuses, so watch/graph/plan inherit it" \
    || bad "halt: snapshot ran against an undeclared repo (rc=$rc)"

# And no wave is launched. `snapshot` alone would not be enough: a wave calls
# it from inside a model session, so the halt would cost a whole session to
# discover.
: > "$TD/waves.log"
P86ENV "$TD/none" "$TICK" tick >/dev/null 2>&1 || true
[ ! -s "$TD/waves.log" ] \
    && ok "halt: 'tick' launches no wave — the session is never paid for" \
    || bad "halt: tick launched a wave in a repo with no tracker declaration"

# The headless case, and the sharpest one: a lane cannot be asked.
out=$(P86ENV "$TD/none" "$LANE" transition 7 review 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q "issue-tracker.md" \
    && ok "halt: a lane.sh verb refuses in an undeclared repo, rc 2 as briefs expect" \
    || bad "halt: lane.sh ran a verb against an undeclared repo (rc=$rc)"

# The usage path is deliberately NOT halted: `lane.sh` with no verb prints the
# roster, and tick.sh reads that roster to build every wave prompt (P48). A
# halt above it empties the verb list in every repo.
vout=$(P86ENV "$TD/none" "$LANE" 2>&1 || true)
printf '%s' "$vout" | grep -q "usage: lane.sh scratch" \
    && ok "halt: the verb roster still prints undeclared — the wave prompt keeps its verbs" \
    || bad "halt: the usage path was halted too, so _lane_verbs sees nothing"

# --- p86-2. Present, but not tracked by git -------------------------------
# The worst shape, and its own refusal: worktrees sit BESIDE the repo and each
# is a checkout, so an untracked declaration is visible to the human in the
# primary clone and in none of the lanes. The message must say "commit it",
# not "it is missing" — the human can see the file.
mkrepo "$TD/untracked"
mkdir -p "$TD/untracked/docs/agents"
printf '# Issue tracker: GitLab\n' > "$TD/untracked/docs/agents/issue-tracker.md"
out=$(P86ENV "$TD/untracked" "$TICK" snapshot 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "git does not track it"; then
    ok "halt: an untracked declaration gets its own refusal, not the missing-file one"
else
    bad "halt: untracked declaration was accepted or mis-reported (rc=$rc, out=$(printf '%s' "$out" | head -1))"
fi
# Staging is enough — the check asks the index, not HEAD — and that is the
# fix the message names.
git -C "$TD/untracked" add docs/agents/issue-tracker.md >/dev/null 2>&1
out=$(P86ENV "$TD/untracked" "$TICK" snapshot 2>&1); rc=$?
[ "$rc" = 0 ] \
    && ok "halt: git add clears it — the refusal named a fix that works" \
    || bad "halt: a tracked declaration still refused (rc=$rc, out=$(printf '%s' "$out" | head -1))"

# --- p86-3. Present and tracked, but naming nothing -----------------------
mkrepo "$TD/noheading"
mkdir -p "$TD/noheading/docs/agents"
printf 'Issues live somewhere. Ask around.\n' > "$TD/noheading/docs/agents/issue-tracker.md"
git -C "$TD/noheading" add docs/agents/issue-tracker.md >/dev/null 2>&1
out=$(P86ENV "$TD/noheading" "$TICK" snapshot 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "Issue tracker: <Name>" \
    && ok "halt: a declaration with no heading is refused, naming the heading form needed" \
    || bad "halt: a headingless declaration was accepted (rc=$rc)"

# --- p86-4. A tracker loom has no driver for ------------------------------
# The honest half of the derivation. Resolving `linear` and then running the
# gitlab driver at it is exactly the failure the declaration exists to prevent,
# so an undriven tracker halts and NO tracker call is made.
mkrepo "$TD/linear"
mkdir -p "$TD/linear/docs/agents"
printf '# Issue tracker: Linear\n' > "$TD/linear/docs/agents/issue-tracker.md"
git -C "$TD/linear" add docs/agents/issue-tracker.md >/dev/null 2>&1
: > "$TD/calls-linear.log"
out=$(P86ENV "$TD/linear" "$TICK" snapshot 2>&1); rc=$?
if [ "$rc" != 0 ] \
   && printf '%s' "$out" | grep -q "linear" \
   && printf '%s' "$out" | grep -q "gitlab"; then
    ok "halt: an undriven tracker is refused, naming both what was declared and what loom drives"
else
    bad "halt: 'Linear' was not refused by name (rc=$rc, out=$(printf '%s' "$out" | head -1))"
fi
[ ! -s "$TD/calls-linear.log" ] \
    && ok "halt: not one tracker call was made against the undriven board" \
    || bad "halt: loom called the tracker anyway ($(head -1 "$TD/calls-linear.log"))"

# --- p86-5. The regression guard ------------------------------------------
# A repo that declares GitLab behaves exactly as it did before any of this.
# Every other green test in this suite rests on that, and the shared fixture in
# test-lib.sh is what supplies it — so this asserts the case directly rather
# than leaving it implied.
mkrepo "$TD/gitlab"
seed_tracker_decl "$TD/gitlab" GitLab
: > "$TD/calls-gitlab.log"
out=$(P86ENV "$TD/gitlab" "$TICK" snapshot 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e 'has("tickets")' >/dev/null 2>&1; then
    ok "regression: a GitLab-declaring repo snapshots exactly as before"
else
    bad "regression: a declared GitLab repo failed to snapshot (rc=$rc, out=$(printf '%s' "$out" | head -1))"
fi
[ -s "$TD/calls-gitlab.log" ] \
    && ok "regression: it really did read the tracker — the empty logs above mean silence, not a broken stub" \
    || bad "regression: no tracker call was made even with a valid declaration"
# Case is not significant: the templates write `GitLab`, and a human editing
# the file by hand writes whatever they write.
mkrepo "$TD/case"
seed_tracker_decl "$TD/case" "GITLAB"
P86ENV "$TD/case" "$TICK" snapshot >/dev/null 2>&1 \
    && ok "regression: the declared name is matched case-insensitively" \
    || bad "regression: 'GITLAB' was not recognised as gitlab"

# --- p86-6. resolve-config reports it as derived --------------------------
# Layer 2 of references/loom-config.md is "anything readable off the repo".
# `.loom.yml` deliberately gets no `tracker:` key: a second place to say it is
# the split brain this whole proposal exists to close.
rc_json=$(P86ENV "$TD/gitlab" "$TICK" resolve-config 2>/dev/null)
if printf '%s' "$rc_json" | jq -e '.scalars.tracker.value == "gitlab"
                                   and .scalars.tracker.source == "derived"' >/dev/null 2>&1; then
    ok "resolve-config: tracker resolves to gitlab, source derived"
else
    bad "resolve-config: tracker missing or mis-sourced ($(printf '%s' "$rc_json" | jq -c '.scalars.tracker' 2>/dev/null))"
fi
# And it must NOT halt: resolve-config is how a human diagnoses the halt, so a
# repo with no declaration still gets a document, with the value empty.
rc_json=$(P86ENV "$TD/none" "$TICK" resolve-config 2>/dev/null)
printf '%s' "$rc_json" | jq -e '.scalars.tracker.value == ""' >/dev/null 2>&1 \
    && ok "resolve-config: an undeclared repo still resolves, reporting an empty tracker" \
    || bad "resolve-config: it halted or hid the empty case — the one verb that must always answer"

# --- p86-7. The guard is doing the work -----------------------------------
# Every refusal above is asserted against a copy of the scripts whose
# `_require_tracker` has been reduced to a no-op. If the suite still passed
# there, the guard would not be what produced the refusals.
mkdir -p "$TD/nolib"
cp "$(dirname "$TICK")"/*.sh "$(dirname "$TICK")"/*.jq "$TD/nolib/" 2>/dev/null
# Replace the function body with one that answers and returns, leaving every
# other line of the three scripts untouched.
awk '
  /^_require_tracker\(\) \{/ { print "_require_tracker() { printf '\''gitlab\\n'\''; return 0; }"; skip=1; next }
  skip && /^\}$/ { skip=0; next }
  skip { next }
  { print }
' "$(dirname "$TICK")/lib.sh" > "$TD/nolib/lib.sh"
chmod +x "$TD/nolib"/*.sh
grep -q "printf 'gitlab" "$TD/nolib/lib.sh" \
    && ok "guard-violation: the planted lib.sh really did lose its check" \
    || bad "guard-violation: the plant failed — the rest of this block proves nothing"
out=$(P86ENV "$TD/none" "$TD/nolib/tick.sh" snapshot 2>&1); rc=$?
[ "$rc" = 0 ] \
    && ok "guard-violation: without _require_tracker the undeclared repo snapshots — the halt is what stopped it" \
    || bad "guard-violation: it refused even with the guard removed, so the refusal came from somewhere else (rc=$rc)"
out=$(P86ENV "$TD/none" "$TD/nolib/lane.sh" transition 7 review 2>&1); rc=$?
printf '%s' "$out" | grep -q "issue-tracker.md" \
    && bad "guard-violation: lane.sh still refused on the declaration with the guard gone" \
    || ok "guard-violation: with the guard gone lane.sh proceeds to its own verb — the halt was the cause"
out=$(P86ENV "$TD/linear" "$TD/nolib/tick.sh" snapshot 2>&1); rc=$?
[ "$rc" = 0 ] \
    && ok "guard-violation: the undriven-tracker refusal is the guard's too, not a coincidence" \
    || bad "guard-violation: 'Linear' still refused without the driver check (rc=$rc)"

test_finish
