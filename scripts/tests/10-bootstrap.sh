#!/usr/bin/env bash
# P22 bootstrap: the WRITE half, split from tick.sh's read-only charter
#
# Section 10 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 9. P22 bootstrap: the WRITE half, split from tick.sh's read-only charter
BOOT="$(cd "$(dirname "$TICK")" && pwd)/bootstrap.sh"
BT="$T/boot"; mkdir -p "$BT/repo" "$BT/fx"
# bootstrap.sh now refuses to write repo files into a directory that is not a
# repo — REPO_ROOT falls back to $PWD, and from $HOME that targeted the human's
# own ~/.claude/settings.json. The fixture has to be a real repo to exercise the
# write paths at all.
git -C "$BT/repo" init -q 2>/dev/null || git init -q "$BT/repo" 2>/dev/null || :
# P86: and it has to DECLARE its issue tracker, tracked by git, or every write
# path below is refused before it starts. Same reason the line above exists:
# the fixture must satisfy the guards it is not the subject of.
seed_tracker_decl "$BT/repo"
cat > "$BT/fx/glab" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"/labels"*)    [ -n "${STUB_LABEL_FAIL:-}" ] && { echo "401 unauthorized" >&2; exit 1; }
                  # Names come from the API now, not `label list` text: the text
                  # includes DESCRIPTIONS, and a label described as "waiting on
                  # review" made the `review` state label look present.
                  if [ -n "${STUB_LABELS_JSON:-}" ] && [ -s "${STUB_LABELS_JSON}" ]; then
                    cat "$STUB_LABELS_JSON"
                  else
                    printf '%s' '[{"name":"blocked"},{"name":"unrelated"}]'
                  fi ;;
  "label create"*) [ -n "${STUB_CREATE_FAIL:-}" ] && { echo "denied" >&2; exit 1; }; exit 0 ;;
  *) echo "[]" ;;
esac
EOF
chmod +x "$BT/fx/glab"
BCALLS="$BT/calls.log"; : > "$BCALLS"
# LOOM_SKIP_BOOTSTRAP is emptied here — this section is the one that tests
# bootstrap, and the file-wide default switches it off everywhere else.
BOOTENV() { LOOM_REPO="$BT/repo" LOOM_HOME="$BT/home" LOOM_GLOBAL_CONFIG="$BT/g.yml" \
            GLAB_CMD="$BT/fx/glab" STUB_LOG="$BCALLS" LOOM_SKIP_BOOTSTRAP= \
            LOOM_WAVE_CMD="${WAVE_CMD:-echo wave-ran}" "$@"; }

# 9a. Seeds the global layer once, then leaves it alone.
BOOTENV "$BOOT" global-config >/dev/null
[ -f "$BT/g.yml" ] && ok "bootstrap: seeds the global config" || bad "bootstrap: no global config written"
printf 'max_lanes: 6\n' >> "$BT/g.yml"
BOOTENV "$BOOT" global-config >/dev/null
grep -q "max_lanes: 6" "$BT/g.yml" \
    && ok "bootstrap: existing global config is never clobbered" || bad "bootstrap: clobbered global config"

# 9b. Idempotent labels: only the missing ones are created, and nothing is
#     ever deleted — the write half gets the same class of guard as 7k.
out=$(BOOTENV "$BOOT" labels 2>&1)
case "$out" in *"7 created, 1 already present"*) ok "bootstrap: creates only the missing labels";;
               *) bad "bootstrap: label run reported '$out'";; esac
# P31's escalation labels are GitLab SCOPED labels — the colon is part of the
# name. The label table was `:`-separated, so read that way `model::high`
# splits into name "model", no colour, and the rest as description: four
# labels created wrong and none of them ever matched.
grep -q -- "label create --name model::high --color #6C3483" "$BCALLS" \
    && ok "bootstrap: a scoped model:: label keeps its colon and its colour" \
    || bad "bootstrap: model:: label mangled ($(grep -c 'label create' "$BCALLS") creates: $(grep 'label create' "$BCALLS" | tr '\n' ';'))"
if grep -qE "label (delete|remove)" "$BCALLS"; then
    bad "bootstrap: a label-destroying call was issued"
else
    ok "bootstrap: no destructive label call in the captured argv"
fi

# 9c. A tracker failure must not be recorded as success.
out=$(STUB_CREATE_FAIL=1 BOOTENV "$BOOT" labels 2>&1); rc_code=$?
[ "$rc_code" -ne 0 ] && ok "bootstrap: failed label creation exits nonzero" \
                     || bad "bootstrap: swallowed a label failure"

# 9c2. A failed label READ must not read as an empty tracker. Swallowing it
#      (`2>/dev/null || echo ""`) meant an auth error produced "no labels
#      exist", so every create was attempted, the first failed against a tracker
#      that already had it, and bootstrap then died on every tick forever. The
#      fixture has always had a STUB_LABEL_FAIL hook and nothing ever used it.
out=$(STUB_LABEL_FAIL=1 BOOTENV "$BOOT" labels 2>&1); rc_code=$?
if [ "$rc_code" -ne 0 ] && ! printf '%s' "$out" | grep -q "0 created"; then
    ok "bootstrap: an unreadable label list fails loudly, it does not look empty"
else
    bad "bootstrap: label read failure was treated as an empty tracker ($out)"
fi
printf '%s' "$out" | grep -q "label create" && bad "bootstrap: created labels despite a failed read" \
                                            || ok "bootstrap-violation: no creates attempted on a failed read"

# 9c3. Existence is matched on the NAME, never on free text. `glab label list`
#      output includes descriptions, so a label described as "waiting on review"
#      made the `review` state label look present: never created, exit 0,
#      sentinel written, never retried.
DESCJSON="$BT/desc-labels.json"
printf '%s' '[{"name":"triage","description":"waiting on review before merge-queue"}]' > "$DESCJSON"
out=$(STUB_LABELS_JSON="$DESCJSON" BOOTENV "$BOOT" labels --dry-run 2>&1)
case "$out" in
    *"would create 8"*) ok "bootstrap: a description mentioning a label name does not fake its presence" ;;
    *) bad "bootstrap: description text matched as a label name ($out)" ;;
esac

# 9c4. `--dry-run` must write nothing and must not claim it did. It also has to
#      survive `all`, which used to discard its arguments entirely — so
#      `bootstrap.sh all --dry-run` really created labels and really wrote
#      settings, the exact opposite of the flag.
: > "$BCALLS"
out=$(BOOTENV "$BOOT" all --dry-run 2>&1)
if printf '%s' "$out" | grep -q "would create" && ! grep -q "label create" "$BCALLS"; then
    ok "bootstrap: 'all --dry-run' honours the flag and writes nothing"
else
    bad "bootstrap: 'all --dry-run' performed real work ($out)"
fi
printf '%s' "$out" | grep -qE "^labels: [0-9]+ created" \
    && bad "bootstrap-violation: a dry run reported work it did not do" \
    || ok "bootstrap-violation: a dry run does not report creations it never made"
BOOTENV "$BOOT" all --bogus-flag >/dev/null 2>&1 \
    && bad "bootstrap: an unknown flag to 'all' was silently ignored" \
    || ok "bootstrap: an unknown flag to 'all' is refused, not dropped"

# 9c5. REPO_ROOT falls back to $PWD, so a repo-scoped write outside a repo must
#      be refused. From $HOME this targeted the human's own
#      ~/.claude/settings.json — the git check ran after the write and warned.
NOTREPO="$BT/not-a-repo"; mkdir -p "$NOTREPO"
if LOOM_REPO="$NOTREPO" LOOM_GLOBAL_CONFIG="$BT/g.yml" GLAB_CMD="$BT/fx/glab" \
   "$BOOT" settings >/dev/null 2>&1; then
    bad "bootstrap: wrote settings into a directory that is not a repo"
else
    ok "bootstrap: refuses to write repo files outside a repo"
fi
[ -e "$NOTREPO/.claude" ] \
    && bad "bootstrap-violation: it created .claude/ outside a repo anyway" \
    || ok "bootstrap-violation: nothing at all was created outside the repo"

# 9c6. D-BOOT-01: `git rev-parse --git-dir` searches upward, so a REPO_ROOT
#      that is merely INSIDE a repo (a subdirectory, or a directory nested
#      under a $HOME versioning dotfiles) used to pass the same check as one
#      AT the repo's root. From a real project subdirectory this is D-BOOT-02
#      (writes an allowlist nothing reads); from under a $HOME repo it is
#      D-BOOT-01 itself (writes into the wrong tree's .claude/ entirely). Both
#      shapes must now be refused — only the toplevel may write.
SUBREPO="$BT/subrepo"; mkdir -p "$SUBREPO/nested/deeper"
git -C "$SUBREPO" init -q 2>/dev/null || git init -q "$SUBREPO" 2>/dev/null || :
if LOOM_REPO="$SUBREPO/nested/deeper" LOOM_GLOBAL_CONFIG="$BT/g.yml" GLAB_CMD="$BT/fx/glab" \
   "$BOOT" settings >/dev/null 2>&1; then
    bad "bootstrap-violation (D-BOOT-01): wrote settings from a subdirectory of a repo, not its root"
else
    ok "bootstrap (D-BOOT-01): refuses a REPO_ROOT that is a subdirectory of a repo"
fi
[ -e "$SUBREPO/nested/deeper/.claude" ] \
    && bad "bootstrap-violation (D-BOOT-01): created .claude/ off the repo root anyway" \
    || ok "bootstrap-violation (D-BOOT-01): nothing was created under the subdirectory"

FAKEHOME="$BT/fake-home"; mkdir -p "$FAKEHOME/projects/scratch"
git -C "$FAKEHOME" init -q 2>/dev/null || git init -q "$FAKEHOME" 2>/dev/null || :
if LOOM_REPO="$FAKEHOME/projects/scratch" LOOM_GLOBAL_CONFIG="$BT/g.yml" GLAB_CMD="$BT/fx/glab" \
   "$BOOT" settings >/dev/null 2>&1; then
    bad "bootstrap-violation (D-BOOT-01): wrote settings under a \$HOME-style dotfiles repo, not its root"
else
    ok "bootstrap (D-BOOT-01): a directory merely nested under a \$HOME repo is refused, not treated as the root"
fi
[ -e "$FAKEHOME/.claude" ] \
    && bad "bootstrap-violation (D-BOOT-01): installed loom's allowlist as the \$HOME-repo's own settings" \
    || ok "bootstrap-violation (D-BOOT-01): nothing was created at the \$HOME-style repo root either"
# The root itself must still work — this is what 9a/9b/9c already exercise
# against $BT/repo (a real, non-nested toplevel), so no separate positive
# assertion is needed here.

# 9d. First tick bootstraps; later ticks do not pay for it again.
rm -rf "$BT/home"
out=$(BOOTENV "$TICK" tick 2>&1)
case "$out" in *"one-time bootstrap"*) ok "tick: first tick runs bootstrap";;
               *) bad "tick: first tick skipped bootstrap ($out)";; esac
[ -f "$BT/home/.bootstrapped" ] && ok "tick: sentinel written after a clean bootstrap" \
                                || bad "tick: no sentinel after bootstrap"
out=$(BOOTENV "$TICK" tick 2>&1)
case "$out" in *"one-time bootstrap"*) bad "tick: bootstrap re-ran on a later tick";;
               *) ok "tick: later ticks skip bootstrap";; esac

# 9e. Planted violation: a bootstrap that fails must NOT leave a sentinel, or
#     an unreachable tracker would be recorded as set up forever.
rm -rf "$BT/home"
out=$(STUB_CREATE_FAIL=1 BOOTENV "$TICK" tick 2>&1)
[ -f "$BT/home/.bootstrapped" ] && bad "tick: sentinel written despite a failed bootstrap" \
                                || ok "tick-violation: failed bootstrap leaves no sentinel, so it retries"
# The wave's own output goes to its log, never to tick's stdout — assert there.
if grep -rq "wave-ran" "$BT/home/logs" 2>/dev/null; then
    ok "tick: a failed bootstrap still runs the wave"
else
    bad "tick: bootstrap failure blocked the wave"
fi

# 9e-2. P30: an untrusted repo root is an INCOMPLETE bootstrap, never a fatal
#     one. `.claude/settings.json` is an artifact whose whole effect depends on
#     that flag, so writing it into an untrusted repo produces an artifact with
#     no consumer — but everything up to the first merge really does work
#     untrusted (build-1 got 77 minutes in), so the wave must still run and the
#     retry must be the existing sentinel machinery, not a new mechanism.
printf '{"projects":{"%s":{"hasTrustDialogAccepted":false}}}\n' "$BT/repo" > "$BT/untrusted-root.json"
rm -rf "$BT/home"
out=$(LOOM_TRUST_FILE="$BT/untrusted-root.json" BOOTENV "$TICK" tick 2>&1) || true
[ -f "$BT/home/.bootstrapped" ] && bad "bootstrap-violation (P30): untrusted repo recorded as bootstrapped" \
    || ok "bootstrap-violation (P30): an untrusted repo leaves no sentinel, so it retries"
case "$out" in *"not a trusted"*|*"incomplete"*) ok "bootstrap (P30): says plainly that trust is what is missing";;
    *) bad "bootstrap (P30): untrusted bootstrap gave no actionable reason ($out)";; esac
if grep -rq "wave-ran" "$BT/home/logs" 2>/dev/null; then
    ok "bootstrap (P30): untrusted is incomplete, not fatal — the wave still ran"
else
    bad "bootstrap (P30): an untrusted repo blocked the wave"
fi
# And it clears itself: once the human accepts, the very next tick completes.
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$BT/repo" > "$BT/untrusted-root.json"
out=$(LOOM_TRUST_FILE="$BT/untrusted-root.json" BOOTENV "$TICK" tick 2>&1) || true
[ -f "$BT/home/.bootstrapped" ] \
    && ok "bootstrap (P30): the next tick after accepting trust completes the bootstrap" \
    || bad "bootstrap (P30): bootstrap never completed after trust was granted ($out)"

# 9f. ntfy topic is layered like every other key, and derives from one global
#     prefix so no per-repo topic is ever hand-written.
NT="$T/ntfy"; mkdir -p "$NT/repo"; : > "$NT/calls"
seed_tracker_decl "$NT/repo"
cat > "$NT/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in http*) echo "$a" >> "$STUB_URL";; esac; done
EOF
chmod +x "$NT/curl"
printf 'ntfy:\n  topic_prefix: "pre-fix-"\n  push: [build_complete]\n' > "$NT/g.yml"
NTFY() { LOOM_REPO="$NT/repo" LOOM_HOME="$NT/home" LOOM_GLOBAL_CONFIG="$NT/g.yml" \
         NTFY_CMD="$NT/curl" NTFY_BASE="https://n" STUB_URL="$NT/calls" \
         "$TICK" notify build_complete t b >/dev/null 2>&1; }
# Both branches used to call `ok`, so this assertion could not fail — and its
# planted-violation partner below greps for a pattern that also passes on an
# empty file, so the whole ntfy subsection went green with notify completely
# broken. A test that reports safety it never checked is worse than no test.
NTFY; grep -q "https://n/pre-fix-repo" "$NT/calls" \
    && ok "ntfy: topic derived as <global prefix><repo name>" \
    || bad "ntfy: derived topic not observed ($(tail -1 "$NT/calls" 2>/dev/null))"
[ -s "$NT/calls" ] \
    && ok "ntfy: the stub actually recorded a call, so the checks below mean something" \
    || bad "ntfy: nothing was posted at all — every assertion here is vacuous"
# Planted violation: `topic:` lookup must not match `topic_prefix:` — if it
# did, the prefix itself would be posted to as a topic.
grep -q "https://n/pre-fix-$" "$NT/calls" \
    && bad "ntfy: topic_prefix was matched as topic" \
    || ok "ntfy-violation: topic_prefix is not mistaken for topic"
: > "$NT/calls"
printf 'ntfy:\n  topic: "repo-wins"\n  push: [build_complete]\n' > "$NT/repo/.loom.yml"
NTFY; grep -q "https://n/repo-wins" "$NT/calls" \
    && ok "ntfy: repo topic overrides the derived one" || bad "ntfy: repo topic ignored"

test_finish
