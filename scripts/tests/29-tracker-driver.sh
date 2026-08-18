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
# The honest half of the derivation. Resolving a tracker and then running some
# other driver at it is exactly the failure the declaration exists to prevent,
# so an undriven tracker halts and NO tracker call is made.
# Jira, not Linear: P87 shipped a Linear driver, so Linear is no longer an
# example of an undriven tracker and using it here would leave this assertion
# passing for a different reason than the one it is written about.
mkrepo "$TD/jira"
mkdir -p "$TD/jira/docs/agents"
printf '# Issue tracker: Jira\n' > "$TD/jira/docs/agents/issue-tracker.md"
git -C "$TD/jira" add docs/agents/issue-tracker.md >/dev/null 2>&1
: > "$TD/calls-jira.log"
out=$(P86ENV "$TD/jira" "$TICK" snapshot 2>&1); rc=$?
if [ "$rc" != 0 ] \
   && printf '%s' "$out" | grep -q "jira" \
   && printf '%s' "$out" | grep -q "gitlab"; then
    ok "halt: an undriven tracker is refused, naming both what was declared and what loom drives"
else
    bad "halt: 'Jira' was not refused by name (rc=$rc, out=$(printf '%s' "$out" | head -1))"
fi
[ ! -s "$TD/calls-jira.log" ] \
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
# P87 added a second halt beside it — the forge — and the plant has to remove
# both, or "it still refused" would only prove the OTHER guard fired.
awk '
  /^_require_tracker\(\) \{/ { print "_require_tracker() { printf '\''gitlab\\n'\''; return 0; }"; skip=1; next }
  /^_require_forge\(\) \{/   { print "_require_forge() { printf '\''gitlab\\n'\''; return 0; }"; skip=1; next }
  skip && /^\}$/ { skip=0; next }
  skip { next }
  { print }
' "$(dirname "$TICK")/lib.sh" > "$TD/nolib/lib.sh"
chmod +x "$TD/nolib"/*.sh
link_trackers "$TD/nolib"
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
# The undriven-tracker case is the one that degrades most usefully. With the
# guard gone the resolver still points at `trackers/jira.sh`, so the run
# still fails — but on a missing FILE, saying nothing about what the repo
# declared or what loom drives. That difference is the guard's whole value:
# it turns "some file is not there" into an answer a human can act on.
out=$(P86ENV "$TD/jira" "$TD/nolib/tick.sh" snapshot 2>&1); rc=$?
if [ "$rc" != 0 ] && ! printf '%s' "$out" | grep -q "loom has drivers for"; then
    ok "guard-violation: without the check, 'Linear' fails on a missing driver file and explains nothing"
else
    bad "guard-violation: the named refusal survived the guard's removal, so the guard is not what produced it"
fi

# --- P86 stage 2: one driver contract, and GitLab implements it -----------
# `glab api "projects/:fullpath/issues/$iid"` was written out at ~28 call sites
# across three scripts. It is now written in one file, and these are the two
# properties that keep it that way.

# p86-8. The literal lives in exactly one place.
# Code lines only: lane.sh's header quotes the hand-rolled `glab api` calls
# that paid for its existence, and history is not a call site.
stray=$(grep -l '^[^#]*\("\$GLAB"\|\$GLAB_CMD" api\|glab api \)' "$(dirname "$TICK")"/*.sh 2>/dev/null \
        | grep -v '/trackers/' || true)
[ -z "$stray" ] \
    && ok "driver: no script outside trackers/ issues a glab call of its own" \
    || bad "driver: glab is still called directly in $(printf '%s' "$stray" | tr '\n' ' ')"

# p86-9. The read-only guarantee, re-pointed. `07-snapshot.sh` proves tick.sh
# makes no MUTATING call by scanning captured argv — but it scans GLAB verbs,
# and with the calls now going through the driver that scan would keep passing
# while checking a condition that can no longer arise. So the same guarantee is
# asserted one layer up, against the CONTRACT's own write verbs, where a future
# driver that never runs `glab` is still covered.
DRV="$TD/drv-stub.sh"
cat > "$DRV" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "${DRV_LOG:?}"
echo "[]"
EOF
chmod +x "$DRV"
# The contract's write half, named here so the assertion is a list and not a
# regex anyone can read two ways.
DRV_WRITES="issue-create issue-relabel issue-close note-add label-create milestone-close mr-create mr-merge"
scan_writes() { # <log> → the write verbs it contains, if any
    local log="$1" v hits=""
    for v in $DRV_WRITES; do grep -qx "$v" "$log" 2>/dev/null && hits="$hits $v"; done
    printf '%s' "${hits# }"
}
: > "$TD/drv-snapshot.log"
DRV_LOG="$TD/drv-snapshot.log" TRACKER_CMD="$DRV" P86ENV "$TD/gitlab" "$TICK" snapshot >/dev/null 2>&1 || true
[ -s "$TD/drv-snapshot.log" ] \
    && ok "driver: snapshot really did call the contract — the scan below reads a non-empty log" \
    || bad "driver: snapshot made no driver call at all, so the scan proves nothing"
w=$(scan_writes "$TD/drv-snapshot.log")
[ -z "$w" ] \
    && ok "read-only: snapshot called no write verb of the contract" \
    || bad "read-only: snapshot issued write verb(s):$w"
# P81: `plan` is the newest path under this guarantee and makes no tracker call
# AT ALL — it derives from a document handed to it.
: > "$TD/drv-plan.log"
printf '{"tickets":[]}' | DRV_LOG="$TD/drv-plan.log" TRACKER_CMD="$DRV" \
    P86ENV "$TD/gitlab" "$TICK" plan >/dev/null 2>&1 || true
[ ! -s "$TD/drv-plan.log" ] \
    && ok "read-only: plan called the driver not at all — P81's guarantee holds through the seam" \
    || bad "read-only: plan reached the tracker ($(head -1 "$TD/drv-plan.log"))"
# Planted violation: a write verb on a tick.sh read path. The scan must catch
# it, or it is checking nothing.
mkdir -p "$TD/writey"
cp "$(dirname "$TICK")"/*.sh "$(dirname "$TICK")"/*.jq "$TD/writey/" 2>/dev/null
link_trackers "$TD/writey"
awk '{ print }
     /^    SNAP_TMP=\$\(mktemp -d\)$/ { print "    \"$TRACKER_SH\" issue-relabel 1 --add planted >/dev/null 2>&1 || true" }
' "$TICK" > "$TD/writey/tick.sh"
chmod +x "$TD/writey"/*.sh
grep -q 'issue-relabel 1 --add planted' "$TD/writey/tick.sh" \
    && ok "read-only-violation: the planted write really is in the mutant" \
    || bad "read-only-violation: the plant failed — the assertion below proves nothing"
: > "$TD/drv-planted.log"
DRV_LOG="$TD/drv-planted.log" TRACKER_CMD="$DRV" P86ENV "$TD/gitlab" "$TD/writey/tick.sh" snapshot >/dev/null 2>&1 || true
w=$(scan_writes "$TD/drv-planted.log")
[ -n "$w" ] \
    && ok "read-only-violation: the scan catches a write planted on a read path ($w)" \
    || bad "read-only-violation: a planted write went unnoticed — the guarantee is unchecked"

# --- P86 stage 3: the contract carries a loom document, not GitLab's ------
# A driver that emitted raw GitLab JSON would not be a contract, it would be a
# passthrough: the next driver would have to FABRICATE `iid`, `opened` and
# `milestone.title` to satisfy readers that were never told what they actually
# need. These two assertions are what stop that.

# p86-10. The jq layer speaks loom, not GitLab.
gl=$(grep -nE '\.(iid|web_url|project_id|link_type|source_branch)\b|"opened"|\.milestone\.title|\.author\.username' \
     "$(dirname "$TICK")"/*.jq 2>/dev/null || true)
[ -z "$gl" ] \
    && ok "document: no GitLab payload field name survives in the jq layer" \
    || bad "document: GitLab field names still read in jq — $(printf '%s' "$gl" | head -2 | tr '\n' ' ')"

# p86-11. The real proof, and the one that could not be faked: a driver whose
# output contains no GitLab field ANYWHERE drives a full snapshot, and the
# planner reads it. This passes without GitLab existing.
LOOMD="$TD/loom-driver.sh"
cat > "$LOOMD" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  issues-open)
    cat <<'JSON'
[{"id":1,"title":"Build 7","state":"open","labels":[],"assignees":[],"epic":null,
  "url":"https://tracker/1","project":1,"body":"**Selected epics**\n- Ledger (#2)\n","updated_at":"2026-08-10T00:00:00Z"},
 {"id":2,"title":"Add the ledger","state":"open","labels":["build-7","ready-for-agent"],"assignees":[],
  "epic":"Ledger","url":"https://tracker/2","project":1,
  "body":"## Risk tier\n\nlogic\n\n## Blocked by\n\nNone - can start immediately\n","updated_at":"2026-08-10T00:00:00Z"}]
JSON
    ;;
  milestones) echo '[{"id":5,"title":"Ledger","state":"open","description":"## Acceptance criteria\n\n- [ ] it balances\n"}]' ;;
  *)          echo '[]' ;;
esac
EOF
chmod +x "$LOOMD"
grep -qE '"iid"|"web_url"|"project_id"|"link_type"|"milestone"|"opened"' "$LOOMD" \
    && bad "document: the loom-shaped fixture driver still contains a GitLab field — it proves nothing" \
    || ok "document: the fixture driver contains no GitLab field at all"
TRACKER_CMD="$LOOMD" P86ENV "$TD/gitlab" "$TICK" snapshot > "$TD/loom-snap.json" 2>"$TD/loom-snap.err"; rc=$?
if [ "$rc" = 0 ] \
   && [ "$(jq -r '.build.label' "$TD/loom-snap.json" 2>/dev/null)" = "build-7" ] \
   && [ "$(jq -r '.tickets[0].id' "$TD/loom-snap.json" 2>/dev/null)" = "2" ] \
   && [ "$(jq -r '.tickets[0].tier' "$TD/loom-snap.json" 2>/dev/null)" = "logic" ] \
   && [ "$(jq -r '.tickets[0].epic' "$TD/loom-snap.json" 2>/dev/null)" = "Ledger" ]; then
    ok "document: a driver emitting only loom fields builds the whole snapshot — GitLab is not required"
else
    bad "document: the loom-only driver could not drive a snapshot (rc=$rc, $(head -1 "$TD/loom-snap.err"))"
fi
if jq -e '.actions | type == "array"' \
     <(P86ENV "$TD/gitlab" "$TICK" plan "$TD/loom-snap.json" 2>/dev/null) >/dev/null 2>&1; then
    ok "document: the planner reads that snapshot too — the contract carries end to end"
else
    bad "document: plan could not read a snapshot built from the loom-only driver"
fi

test_finish
