#!/usr/bin/env bash
# P87 stage 1: the board and the forge are two roles
#
# Section 30 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
#
# A board holds tickets; a forge holds branches and merge requests. GitLab is
# both, which is why loom never had to tell them apart. Linear is a board and
# nothing else — it has no merge requests at all — so a Linear-tracked repo
# keeps its code on GitHub or GitLab and loom resolves two backends. These tests
# are about that split staying honest: the forge derived rather than declared,
# the merge-request calls actually going to it, and the ticket link surviving a
# forge whose issues belong to somebody else.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

SD="$(cd "$(dirname "$TICK")" && pwd)"
TD="$T/p87"; mkdir -p "$TD"

mkrepo87() { # mkrepo87 <dir> [remote-url] — a git repo, optionally with an origin
    mkdir -p "$1"
    git -C "$1" init -q >/dev/null 2>&1
    git -C "$1" config user.email loom@test >/dev/null 2>&1
    git -C "$1" config user.name loom >/dev/null 2>&1
    [ -n "${2:-}" ] && git -C "$1" remote add origin "$2" >/dev/null 2>&1
    return 0
}
P87ENV() { # run a command against <repo>
    local repo="$1"; shift
    LOOM_REPO="$repo" LOOM_HOME="$TD/home-$(basename "$repo")" \
      LOOM_GLOBAL_CONFIG="$TD/g.yml" LOOM_SKIP_BOOTSTRAP= "$@"
}
# Resolution questions are asked of lib.sh directly. The alternative is to infer
# the answer from which stub got called, and an inference is not what these
# assertions are about.
ask() { # ask <fn> <repo> → the function's output, rc preserved
    local fn="$1" repo="$2"
    LOOM_REPO="$repo" bash -c '. "$1"; DIE_RC=1; '"$fn"' "$2" test' _ "$SD/lib.sh" "$repo" 2>&1
}

# --- p87-1. The forge is derived, and the board answers first --------------
# A tracker that is itself a code host needs no remote inspection at all. That
# ordering is deliberate: it means every GitLab repo keeps exactly the forge it
# has always had, including a self-hosted instance on a domain with no `gitlab`
# in its name, without this file having to learn any hostnames.
mkrepo87 "$TD/gl-nohost" "git@git.internal.example:team/app.git"
seed_tracker_decl "$TD/gl-nohost" GitLab
[ "$(ask _require_forge "$TD/gl-nohost")" = gitlab ] \
    && ok "forge: a GitLab board is its own forge, whatever its remote host is called" \
    || bad "forge: a GitLab repo on an unrecognisable host did not resolve to gitlab ($(ask _require_forge "$TD/gl-nohost"))"

# The remote is consulted only when the board cannot host code.
mkrepo87 "$TD/lin-gh" "https://github.com/acme/app.git"
seed_tracker_decl "$TD/lin-gh" Linear
[ "$(ask _require_forge "$TD/lin-gh")" = github ] \
    && ok "forge: a Linear board on a GitHub remote resolves its forge from the remote" \
    || bad "forge: a Linear repo with a github remote did not resolve to github ($(ask _require_forge "$TD/lin-gh"))"

mkrepo87 "$TD/bare"
[ "$(ask _forge_declared "$TD/bare")" = "" ] \
    && ok "forge: with no declaration and no remote it resolves to nothing, rather than guessing" \
    || bad "forge: a repo that answers neither question produced a forge anyway ($(ask _forge_declared "$TD/bare"))"

mkrepo87 "$TD/lin-gl" "git@gitlab.com:acme/app.git"
seed_tracker_decl "$TD/lin-gl" Linear
[ "$(ask _require_forge "$TD/lin-gl")" = gitlab ] \
    && ok "forge: a Linear board on a GitLab remote resolves to the gitlab forge" \
    || bad "forge: a Linear repo with a gitlab remote did not resolve to gitlab"

# --- p87-2. The fourth refusal --------------------------------------------
# A board with no merge requests and no forge-capable remote is half an answer,
# and the half that is missing is where a lane's work would have landed.
mkrepo87 "$TD/lin-none"
seed_tracker_decl "$TD/lin-none" Linear
out=$(ask _require_forge "$TD/lin-none")
if printf '%s' "$out" | grep -q "linear" && printf '%s' "$out" | grep -q "origin"; then
    ok "forge: a board that is not a code host, with no usable remote, is refused naming both facts"
else
    bad "forge: the no-forge case was not refused properly (out=$(printf '%s' "$out" | head -1))"
fi
mkrepo87 "$TD/lin-bb" "git@bitbucket.org:acme/app.git"
seed_tracker_decl "$TD/lin-bb" Linear
out=$(ask _require_forge "$TD/lin-bb")
printf '%s' "$out" | grep -q "origin" \
    && ok "forge: a remote on a host loom has no forge driver for is refused too" \
    || bad "forge: an undriven forge host was accepted ($(printf '%s' "$out" | head -1))"

# --- p87-3. resolve-config reports it, beside the tracker ------------------
mkrepo87 "$TD/cfg"
seed_tracker_decl "$TD/cfg" GitLab
rc_json=$(P87ENV "$TD/cfg" "$TICK" resolve-config 2>/dev/null)
if printf '%s' "$rc_json" | jq -e '.scalars.forge.value == "gitlab"
                                   and .scalars.forge.source == "derived"' >/dev/null 2>&1; then
    ok "resolve-config: forge resolves to gitlab, source derived"
else
    bad "resolve-config: forge missing or mis-sourced ($(printf '%s' "$rc_json" | jq -c '.scalars.forge' 2>/dev/null))"
fi
mkrepo87 "$TD/cfg-gh" "https://github.com/acme/app.git"
seed_tracker_decl "$TD/cfg-gh" Linear
rc_json=$(P87ENV "$TD/cfg-gh" "$TICK" resolve-config 2>/dev/null)
[ "$(printf '%s' "$rc_json" | jq -r '.scalars.forge.value' 2>/dev/null)" = github ] \
    && ok "resolve-config: it reports github for a Linear board on a GitHub remote" \
    || bad "resolve-config: forge did not follow the remote ($(printf '%s' "$rc_json" | jq -c '.scalars.forge' 2>/dev/null))"

# --- p87-4. The merge-request calls really do go to the forge --------------
# Two stubs, two logs. The split is only worth anything if the calls landed on
# different drivers, so assert which log each verb reached rather than that a
# call happened at all.
mkdir -p "$TD/two"
cat > "$TD/two/trk.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "${TRK_LOG:?}"
case "$1" in
  issues-open) cat <<'JSON'
[{"id":1,"title":"Build 7","state":"open","labels":[],"assignees":[],"epic":null,
  "url":"u","project":1,"body":"**Selected epics**\n- Ledger (#2)\n","updated_at":"2026-08-10T00:00:00Z"},
 {"id":2,"title":"Add the ledger","state":"open","labels":["build-7","in-progress"],"assignees":[],
  "epic":"Ledger","url":"u","project":1,"body":"## Risk tier\n\nlogic\n","updated_at":"2026-08-10T00:00:00Z"}]
JSON
  ;;
  *) echo '[]' ;;
esac
EOF
cat > "$TD/two/frg.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "${FRG_LOG:?}"
case "$1" in
  ticket-marker) echo "Closes #${2:-0}" ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$TD/two/trk.sh" "$TD/two/frg.sh"
mkrepo87 "$TD/split"
seed_tracker_decl "$TD/split" GitLab
: > "$TD/trk.log"; : > "$TD/frg.log"
TRK_LOG="$TD/trk.log" FRG_LOG="$TD/frg.log" \
  TRACKER_CMD="$TD/two/trk.sh" FORGE_CMD="$TD/two/frg.sh" \
  P87ENV "$TD/split" "$TICK" snapshot >/dev/null 2>&1 || true
grep -qx "issue-mrs" "$TD/frg.log" \
    && ok "split: the snapshot's merge-request read went to the FORGE driver" \
    || bad "split: issue-mrs never reached the forge ($(tr '\n' ' ' < "$TD/frg.log"))"
grep -qx "issue-mrs" "$TD/trk.log" \
    && bad "split: the tracker driver was asked for merge requests as well" \
    || ok "split: the tracker driver was never asked about merge requests"
grep -qx "issues-open" "$TD/trk.log" \
    && ok "split: and the board read went to the TRACKER driver — both stubs are live" \
    || bad "split: the tracker driver was never called at all, so the assertions above prove nothing"

# The lane side. `merge` asks which MR closes a ticket before it does anything.
: > "$TD/frg2.log"
FRG_LOG="$TD/frg2.log" TRK_LOG="$TD/trk2.log" \
  TRACKER_CMD="$TD/two/trk.sh" FORGE_CMD="$TD/two/frg.sh" \
  P87ENV "$TD/split" "$LANE" merge 2 >/dev/null 2>&1 || true
grep -qx "mr-for-ticket" "$TD/frg2.log" \
    && ok "split: lane.sh asks the FORGE which MR closes a ticket" \
    || bad "split: mr-for-ticket never reached the forge ($(tr '\n' ' ' < "$TD/frg2.log"))"

# --- p87-5. The read-only guarantee covers the forge too -------------------
# `tick.sh` mutates nothing. P86 re-pointed that scan at the contract's write
# verbs; half of those verbs now live on a second driver, and a scan that only
# watched the first would go quietly blind to `mr-merge`.
FRG_WRITES="mr-create mr-merge mr-note-add"
scan_forge_writes() { local log="$1" v hits=""
    for v in $FRG_WRITES; do grep -qx "$v" "$log" 2>/dev/null && hits="$hits $v"; done
    printf '%s' "${hits# }"; }
w=$(scan_forge_writes "$TD/frg.log")
[ -z "$w" ] \
    && ok "read-only: snapshot called no forge write verb" \
    || bad "read-only: snapshot issued forge write verb(s):$w"
# Planted violation, on a tick.sh read path, through the forge.
mkdir -p "$TD/writey"
cp "$SD"/*.sh "$SD"/*.jq "$TD/writey/" 2>/dev/null
link_trackers "$TD/writey"
awk '{ print }
     /^    SNAP_TMP=\$\(mktemp -d\)$/ { print "    \"$FORGE_SH\" mr-merge 1 >/dev/null 2>&1 || true" }
' "$TICK" > "$TD/writey/tick.sh"
chmod +x "$TD/writey"/*.sh
grep -q 'FORGE_SH" mr-merge 1' "$TD/writey/tick.sh" \
    && ok "read-only-violation: the planted forge write really is in the mutant" \
    || bad "read-only-violation: the plant failed — the assertion below proves nothing"
: > "$TD/frg-planted.log"
FRG_LOG="$TD/frg-planted.log" TRK_LOG="$TD/trk-planted.log" \
  TRACKER_CMD="$TD/two/trk.sh" FORGE_CMD="$TD/two/frg.sh" \
  P87ENV "$TD/split" "$TD/writey/tick.sh" snapshot >/dev/null 2>&1 || true
w=$(scan_forge_writes "$TD/frg-planted.log")
[ -n "$w" ] \
    && ok "read-only-violation: the scan catches a forge write planted on a read path ($w)" \
    || bad "read-only-violation: a planted forge write went unnoticed — the guarantee is unchecked"

# --- p87-6. The ticket link ------------------------------------------------
# GitLab answers "which MR closes issue 41" natively because it parses
# `Closes #41`. GitHub does the same — for GITHUB issues. With a Linear board
# that is a trap, not a feature: `Closes #41` would close an unrelated GitHub
# issue on merge. So the marker depends on whose issues the board holds.
GLF="$SD/forges/gitlab.sh"; GHF="$SD/forges/github.sh"
[ "$("$GLF" ticket-marker 41)" = "Closes #41" ] \
    && ok "marker: the GitLab forge keeps GitLab's own closing syntax — nothing about a GitLab build changes" \
    || bad "marker: the gitlab forge's marker changed ($("$GLF" ticket-marker 41))"
[ "$(LOOM_REPO="$TD/lin-gh" "$GHF" ticket-marker 41)" = "Loom-Ticket: 41" ] \
    && ok "marker: on a GitHub forge with a Linear board it is loom's own trailer, which GitHub closes nothing for" \
    || bad "marker: the github forge would have written a GitHub closing keyword for a Linear ticket ($(LOOM_REPO="$TD/lin-gh" "$GHF" ticket-marker 41))"
mkrepo87 "$TD/gh-board" "https://github.com/acme/app.git"
seed_tracker_decl "$TD/gh-board" GitHub
[ "$(LOOM_REPO="$TD/gh-board" "$GHF" ticket-marker 41)" = "Closes #41" ] \
    && ok "marker: when the board IS GitHub the native syntax comes back — the platform links it itself" \
    || bad "marker: a GitHub board did not get GitHub's closing syntax"
# The boundary that keeps ticket 41 out of ticket 410's merge request.
GH_STUB="$TD/gh-stub.sh"
cat > "$GH_STUB" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[{"number":9,"title":"t","state":"open","merged_at":null,"draft":false,"html_url":"u",
  "head":{"ref":"ticket-410","sha":"abc"},"body":"work\n\nLoom-Ticket: 410\n"}]
JSON
EOF
chmod +x "$GH_STUB"
n=$(LOOM_REPO="$TD/lin-gh" GH_CMD="$GH_STUB" "$GHF" mr-for-ticket 41 | jq 'length')
[ "$n" = 0 ] \
    && ok "marker: ticket 41 does not match the MR of ticket 410 — the digit boundary holds" \
    || bad "marker: a neighbouring ticket's MR matched ($n found), which is how the wrong branch gets merged"
n=$(LOOM_REPO="$TD/lin-gh" GH_CMD="$GH_STUB" "$GHF" mr-for-ticket 410 | jq 'length')
[ "$n" = 1 ] \
    && ok "marker: and its own MR is found — the boundary is not simply refusing everything" \
    || bad "marker: ticket 410 could not find its own MR"

# --- p87-7. lane.sh writes the marker the forge asked for ------------------
# The link is one loom WRITES, not one it hopes the forge inferred, so the verb
# that opens an MR has to take the marker from the driver rather than from a
# literal in its own source.
grep -q 'ticket-marker' "$SD/lane.sh" \
    && ok "marker: lane.sh asks the forge what to write, instead of hard-coding a closing keyword" \
    || bad "marker: lane.sh still composes the ticket link itself"
lit=$(grep -n 'Closes #\$iid\|Closes #%s' "$SD/lane.sh" | grep -v '^ *#' | grep -v '^\s*[0-9]*:#' || true)
[ -z "$lit" ] \
    && ok "marker: and no GitLab closing keyword survives as a literal in lane.sh" \
    || bad "marker: lane.sh still writes a hard-coded closing keyword — $(printf '%s' "$lit" | head -1)"

# --- p87-8. The guard is doing the work ------------------------------------
# Every refusal above is asserted against a copy of lib.sh whose `_require_forge`
# has been reduced to a no-op.
mkdir -p "$TD/noforge"
cp "$SD"/*.sh "$SD"/*.jq "$TD/noforge/" 2>/dev/null
awk '
  /^_require_forge\(\) \{/ { print "_require_forge() { printf '\''gitlab\\n'\''; return 0; }"; skip=1; next }
  skip && /^\}$/ { skip=0; next }
  skip { next }
  { print }
' "$SD/lib.sh" > "$TD/noforge/lib.sh"
chmod +x "$TD/noforge"/*.sh
link_trackers "$TD/noforge"
grep -q "_require_forge() { printf" "$TD/noforge/lib.sh" \
    && ok "guard-violation: the planted lib.sh really did lose its forge check" \
    || bad "guard-violation: the plant failed — the assertion below proves nothing"
out=$(LOOM_REPO="$TD/lin-none" bash -c '. "$1"; DIE_RC=1; _require_forge "$2" test' _ "$TD/noforge/lib.sh" "$TD/lin-none" 2>&1)
[ "$out" = gitlab ] \
    && ok "guard-violation: without the check the forgeless repo resolves anyway — the halt is what refused it" \
    || bad "guard-violation: it refused even with the guard gone, so the refusal came from somewhere else ($out)"

# --- p87-9. The CLI literals stay inside their own drivers -----------------
# P86 bought the property that `glab` is named in one file. Splitting that file
# in two must not spend it, and adding a GitHub forge must not start a second
# leak — so the scan covers subdirectories now, and excludes exactly the two
# directories a driver may live in.
stray=$(grep -rl '^[^#]*\("\$GLAB"\|"\$GH"\|glab api \|gh api \)' "$SD" --include='*.sh' 2>/dev/null \
        | grep -v '/trackers/' | grep -v '/forges/' | grep -v '/tests/' || true)
[ -z "$stray" ] \
    && ok "containment: no script outside trackers/ and forges/ runs a glab or gh command" \
    || bad "containment: a CLI is still called directly in $(printf '%s' "$stray" | tr '\n' ' ')"

test_finish
