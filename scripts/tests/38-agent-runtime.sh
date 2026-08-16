#!/usr/bin/env bash
# Provider-neutral runtime, adapter mappings, policies, and deterministic worktrees.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

AGENT="$(dirname "$TICK")/agent.sh"
WORKTREE="$(dirname "$TICK")/worktree.sh"
AR="$T/agent-runtime"; mkdir -p "$AR/repo" "$AR/bin" "$LOOM_HOME"
git -C "$AR/repo" init -q
printf 'runtime brief\n' > "$AR/brief.md"

# Detection uses interactive identity, never whichever binaries happen to be installed.
out=$(CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT= CLAUDE_SESSION_ID= CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI= \
  "$AGENT" detect 2>/dev/null)
[ "$out" = claude ] && ok "agent: strong Claude identity selects Claude" || bad "agent: Claude detection returned '$out'"
out=$(CLAUDECODE= CLAUDE_CODE_ENTRYPOINT= CLAUDE_SESSION_ID= CODEX_THREAD_ID=t1 CODEX_SESSION_ID= CODEX_CI= \
  "$AGENT" detect 2>/dev/null)
[ "$out" = codex ] && ok "agent: strong Codex identity selects Codex" || bad "agent: Codex detection returned '$out'"
out=$(CLAUDECODE=1 CODEX_THREAD_ID=t1 "$AGENT" detect 2>&1); rc=$?
[ "$rc" -ne 0 ] && case "$out" in *multiple*) true;; *) false;; esac \
  && ok "agent: ambiguous identities fail closed" || bad "agent: ambiguity did not fail ($out)"
out=$(CLAUDECODE= CODEX_THREAD_ID= CODEX_SESSION_ID= CODEX_CI= CLAUDE_CODE_ENTRYPOINT= CLAUDE_SESSION_ID= \
  "$AGENT" detect 2>&1); rc=$?
[ "$rc" -ne 0 ] && case "$out" in *"no interactive provider"*) true;; *) false;; esac \
  && ok "agent: binary presence alone does not select a provider" || bad "agent: no-identity detection did not fail ($out)"
[ "$("$AGENT" detect --provider codex)" = codex ] \
  && ok "agent: one-time explicit provider override is accepted" || bad "agent: explicit override failed"

cat > "$AR/bin/codex" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${CAP:?}"
case "$1" in
  --version) echo 'codex-cli 99.0' ;;
  login) echo 'Logged in using test' ;;
  debug) printf '{"models":[{"slug":"gpt-5.6-terra"},{"slug":"gpt-5.6-sol"}]}\n' ;;
  exec)
    [ -z "${ENV_CAP:-}" ] || printf '%s\n' "${LOOM_DEFER_LANE_LAUNCH:-}" >> "$ENV_CAP"
    [ -z "${PATH_CAP:-}" ] || printf '%s\n' "$PATH" >> "$PATH_CAP"
    while IFS= read -r line; do printf '%s\n' "$line" >> "${STDIN_CAP:?}"; done
    case "${NATIVE_MODE:-success}" in
      success)
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}}' ;;
      limit) echo 'usage limit reached' >&2; exit 1 ;;
      malformed) echo 'not-json' ;;
    esac ;;
esac
EOF
chmod +x "$AR/bin/codex"
cat > "$AR/bin/node" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -p ] && { printf '/runtime/node/bin/node\n'; exit 0; }
exit 91
EOF
cat > "$AR/bin/pnpm" <<'EOF'
#!/usr/bin/env bash
exit 92
EOF
cat > "$AR/bin/volta" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "which pnpm" ] && { printf '/runtime/pnpm/bin/pnpm\n'; exit 0; }
exit 93
EOF
chmod +x "$AR/bin/node" "$AR/bin/pnpm" "$AR/bin/volta"
CAP="$AR/codex.argv"; STDIN_CAP="$AR/codex.stdin"; ENV_CAP="$AR/codex.env"; PATH_CAP="$AR/codex.path"
: > "$CAP"; : > "$STDIN_CAP"; : > "$ENV_CAP"; : > "$PATH_CAP"
out=$(CAP="$CAP" STDIN_CAP="$STDIN_CAP" ENV_CAP="$ENV_CAP" PATH_CAP="$PATH_CAP" \
  PATH="$AR/bin:$PATH" LOOM_CODEX_CMD="$AR/bin/codex" \
  LOOM_AGENT_NATIVE_LOG="$AR/codex.native" "$AGENT" run --provider codex --job implementation \
  --tier high --cwd "$AR/repo" --brief "$AR/brief.md" --lane-id impl-7)
argv=$(tail -1 "$CAP")
git_common=$(git -C "$AR/repo" rev-parse --path-format=absolute --git-common-dir)
git_common=$(cd "$git_common" && pwd -P)
case "$argv" in *"exec --json --ephemeral --model gpt-5.6-sol"*"model_reasoning_effort=\"high\""*"approval_policy=\"never\""*"--sandbox workspace-write --add-dir $LOOM_HOME --add-dir $git_common"*)
  ok "codex adapter: high maps to Sol/high with explicit non-interactive safety flags";;
  *) bad "codex adapter: high argv wrong ($argv)";; esac
case "$argv" in *"--add-dir "*"/agent-runtime/repo/.git"*)
  ok "codex adapter: shared Git metadata is writable for fetch and merge";;
  *) bad "codex adapter: shared Git metadata missing from sandbox ($argv)";; esac
case "$argv" in *"shell_environment_policy.inherit=all"*)
  ok "codex adapter: nested headless shells inherit the scheduler toolchain PATH";;
  *) bad "codex adapter: full scheduler environment inheritance missing from Codex shell policy ($argv)";; esac
case "$argv" in *"shell_environment_policy.set.PATH="*)
  bad "codex adapter: ineffective PATH-only shell override remains ($argv)";;
  *) ok "codex adapter: does not rely on the ineffective PATH-only override";; esac
[ "$(cat "$STDIN_CAP")" = "runtime brief" ] \
  && ok "codex adapter: brief travels on stdin" || bad "codex adapter: stdin brief missing"
[ "$(tail -1 "$ENV_CAP")" = 1 ] \
  && ok "codex adapter: provider sessions defer lane launch to the host scheduler" \
  || bad "codex adapter: provider session did not carry the deferred-launch boundary"
case "$(tail -1 "$PATH_CAP")" in "/runtime/node/bin:"*)
  ok "codex adapter: real Node runtime precedes the Volta shim for nested tool shells";;
  *) bad "codex adapter: real Node runtime did not lead PATH ($(tail -1 "$PATH_CAP"))";; esac
case ":$(tail -1 "$PATH_CAP"):" in *":/runtime/pnpm/bin:"*)
  ok "codex adapter: actual pnpm runtime survives Volta removing its shim directory";;
  *) bad "codex adapter: actual pnpm runtime missing from inherited PATH ($(tail -1 "$PATH_CAP"))";; esac
printf '%s' "$out" | jq -se 'any(.type=="session_start" and .provider=="codex" and .requested_tier=="high" and .resolved_profile.model=="gpt-5.6-sol") and any(.type=="assistant_progress") and any(.type=="usage" and .cost_usd==null) and any(.type=="session_end" and .status=="success")' >/dev/null \
  && ok "codex adapter: native stream becomes canonical JSONL with unknown cost null" \
  || bad "codex adapter: canonical stream incomplete ($out)"

: > "$CAP"; : > "$STDIN_CAP"
CAP="$CAP" STDIN_CAP="$STDIN_CAP" LOOM_CODEX_CMD="$AR/bin/codex" LOOM_AGENT_NATIVE_LOG="$AR/codex-medium.native" \
  "$AGENT" run --provider codex --job wave --tier medium --cwd "$AR/repo" --brief "$AR/brief.md" >/dev/null
argv=$(tail -1 "$CAP")
case "$argv" in *"--model gpt-5.6-terra"*"model_reasoning_effort=\"medium\""*)
  ok "codex adapter: medium maps exactly to Terra/medium";; *) bad "codex adapter: medium argv wrong ($argv)";; esac
case "$argv" in *luna*|*xhigh*|*max*) bad "codex adapter: invented a forbidden fallback ($argv)";;
  *) ok "codex adapter: no Luna/xhigh/max fallback";; esac

cat > "$AR/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${CLAUDE_CAP:?}"
case "$1" in
  --version) echo 'claude 99.0' ;;
  auth) echo '{"loggedIn":true}' ;;
  *) printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"reviewed"}],"usage":{"input_tokens":4,"output_tokens":2}}}' \
                   '{"type":"result","subtype":"success","is_error":false,"result":"PASS","total_cost_usd":0.01}' ;;
esac
EOF
chmod +x "$AR/bin/claude"; CLAUDE_CAP="$AR/claude.argv"; : > "$CLAUDE_CAP"
out=$(CLAUDE_CAP="$CLAUDE_CAP" LOOM_CLAUDE_CMD="$AR/bin/claude" LOOM_AGENT_NATIVE_LOG="$AR/claude.native" \
  "$AGENT" run --provider claude --job gate --tier high --cwd "$AR/repo" --brief "$AR/brief.md")
argv=$(tail -1 "$CLAUDE_CAP")
case "$argv" in *"--permission-mode dontAsk"*"--model opus"*"--output-format stream-json --verbose"*"--disallowedTools ScheduleWakeup"*)
  ok "claude adapter: legacy safe invocation is preserved behind the adapter";;
  *) bad "claude adapter: argv parity failed ($argv)";; esac
printf '%s' "$out" | jq -se 'any(.type=="session_start" and .provider=="claude" and .requested_tier=="high") and any(.type=="assistant_progress" and .text=="reviewed") and any(.type=="usage" and .cost_usd==0.01) and any(.type=="session_end" and .status=="success")' >/dev/null \
  && ok "claude adapter: native stream becomes the same canonical vocabulary" \
  || bad "claude adapter: canonical stream incomplete ($out)"

out=$(CAP="$CAP" STDIN_CAP="$STDIN_CAP" NATIVE_MODE=malformed LOOM_CODEX_CMD="$AR/bin/codex" \
  LOOM_AGENT_NATIVE_LOG="$AR/codex-bad.native" "$AGENT" run --provider codex --job gate --tier medium \
  --cwd "$AR/repo" --brief "$AR/brief.md" 2>&1); rc=$?
[ "$rc" -eq 25 ] && case "$out" in *malformed_native_output*) true;; *) false;; esac \
  && ok "codex adapter: malformed native JSON fails with a stable category" \
  || bad "codex adapter: malformed output rc=$rc ($out)"

# High usage-limit downshift resolves a fresh medium profile; medium limits remain limits.
printf 'usage_limit: downshift_tier\n' > "$AR/repo/.loom.yml"
cat > "$AR/bin/codex-limit" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  exec) n=$(cat "${COUNT:?}" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNT"
        echo "$@" >> "${CAP:?}"; if [ "$n" -eq 1 ]; then echo 'usage limit reached' >&2; exit 1
        else echo '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}'; fi ;;
  *) echo ok ;;
esac
EOF
chmod +x "$AR/bin/codex-limit"; : > "$CAP"; echo 0 > "$AR/count"
out=$(CAP="$CAP" COUNT="$AR/count" LOOM_REPO="$AR/repo" LOOM_CODEX_CMD="$AR/bin/codex-limit" \
  LOOM_AGENT_SKIP_AUTH=1 LOOM_AGENT_SKIP_POLICY=1 LOOM_AGENT_SKIP_TRUST=1 LOOM_AGENT_SKIP_MODEL_CHECK=1 \
  "$AGENT" run --provider codex --job implementation --tier high --cwd "$AR/repo" --brief "$AR/brief.md")
[ "$(cat "$AR/count")" = 2 ] && grep -q 'gpt-5.6-sol' "$CAP" && grep -q 'gpt-5.6-terra' "$CAP" \
  && printf '%s' "$out" | jq -se 'any(.type=="session_start" and .downshifted_from=="high")' >/dev/null \
  && ok "agent: high limit downshifts Sol/high to Terra/medium exactly once" \
  || bad "agent: high-tier downshift failed (count=$(cat "$AR/count") argv=$(cat "$CAP") output=$out)"

cp "$AR/repo/.loom.yml" "$AR/repo/.loom.saved"
printf 'wave_model: opus\n' > "$AR/repo/.loom.yml"
out=$(CAP="$CAP" STDIN_CAP="$STDIN_CAP" LOOM_REPO="$AR/repo" LOOM_CODEX_CMD="$AR/bin/codex" \
  "$AGENT" preflight --provider codex --job wave --tier medium --cwd "$AR/repo" 2>&1); rc=$?
mv "$AR/repo/.loom.saved" "$AR/repo/.loom.yml"
[ "$rc" -eq 27 ] && case "$out" in *"legacy runtime config 'wave_model'"*) true;; *) false;; esac \
  && ok "agent: chained jobs refuse legacy provider-native config instead of choosing silently" \
  || bad "agent: legacy model config did not fail at the runtime boundary ($out)"

# Guardrail sync owns only its provider artifact and is idempotent.
mkdir -p "$AR/repo/.codex/rules" "$AR/repo/.claude"
printf 'prefix_rule(pattern=["echo"], decision="allow")\n' > "$AR/repo/.codex/rules/user.rules"
printf '{"hooks":{"keep":true},"permissions":{"allow":["Bash(handwritten *)"],"deny":[]}}\n' > "$AR/repo/.claude/settings.json"
"$AGENT" sync-guardrails --provider codex --repo "$AR/repo" >/dev/null
cp "$AR/repo/.codex/rules/loom.rules" "$AR/codex.rules.before"
"$AGENT" sync-guardrails --provider codex --repo "$AR/repo" >/dev/null
cmp -s "$AR/codex.rules.before" "$AR/repo/.codex/rules/loom.rules" && grep -q 'echo' "$AR/repo/.codex/rules/user.rules" \
  && ok "guardrails: Codex sync is idempotent and preserves other rule files" \
  || bad "guardrails: Codex sync changed unrelated state"
LOOM_REPO="$AR/repo" "$AGENT" sync-guardrails --provider claude --repo "$AR/repo" >/dev/null
jq -e '.hooks.keep and (.permissions.allow|index("Bash(handwritten *)")) and (.permissions.deny|index("Bash(git push --force*)"))' "$AR/repo/.claude/settings.json" >/dev/null \
  && ok "guardrails: Claude sync preserves unrelated user settings" \
  || bad "guardrails: Claude sync clobbered user settings"

if command -v codex >/dev/null 2>&1; then
  rules="$AR/repo/.codex/rules/loom.rules"; denied=0
  for cmd in 'git push --force origin x' 'git reset --hard HEAD' 'git clean -fdx' 'rm -rf /tmp/loom-test'; do
    decision=$(codex execpolicy check --rules "$rules" $cmd 2>/dev/null | jq -r '.decision // empty')
    [ "$decision" = forbidden ] || denied=1
  done
  [ "$denied" -eq 0 ] && ok "guardrails: real Codex execpolicy denies every Loom hard-denial command" \
    || bad "guardrails: real Codex execpolicy allowed a hard-denial command"
  decision=$(codex execpolicy check --rules "$rules" lane.sh scratch 2>/dev/null | jq -r '.decision // empty')
  [ "$decision" != forbidden ] && ok "guardrails: the real Codex policy leaves the sanctioned lane.sh path available" \
    || bad "guardrails: Codex policy blocked lane.sh along with destructive commands"
else
  bad "guardrails: Codex CLI unavailable, so real policy conformance is unproven"
  bad "guardrails: Codex CLI unavailable, so the lane.sh policy path is unproven"
fi

# Linked worktrees live beneath the main clone so workspace-write covers both
# creation and lane execution without granting access to sibling repositories.
WT="$AR/worktrees"; mkdir -p "$WT"
git -c init.defaultBranch=main init -q --bare "$WT/origin.git"
git clone -q "$WT/origin.git" "$WT/repo" 2>/dev/null
git -C "$WT/repo" config user.email loom@test
git -C "$WT/repo" config user.name loom
printf 'base\n' > "$WT/repo/base.txt"
git -C "$WT/repo" add base.txt
git -C "$WT/repo" commit -qm base
git -C "$WT/repo" push -q origin main
mkdir -p "$WT/repo/.codex/rules"
printf 'prefix_rule(pattern=["git", "reset", "--hard"], decision="forbidden")\n' > "$WT/repo/.codex/rules/loom.rules"
wt_repo=$(cd "$WT/repo" && pwd -P)
made=$("$WORKTREE" prepare --repo "$WT/repo" --ticket 7 --branch ticket-7 --base main)
if [ "$made" = "$wt_repo/.worktrees/7" ] \
  && [ -f "$made/.codex/rules/loom.rules" ] \
  && grep -qxF '/.worktrees/' "$wt_repo/.git/info/exclude" \
  && grep -qxF '/.codex/rules/loom.rules' "$wt_repo/.git/info/exclude"; then
  ok "worktree: prepare creates ignored linked trees beneath the main clone with Codex guardrails"
else
  bad "worktree: nested prepare contract failed (made=$made)"
fi

# Codex trust is a repository decision: an explicitly trusted main clone also
# covers a linked worktree Git reports for that clone.
mkdir -p "$WT/codex-home"
cat > "$WT/codex-home/config.toml" <<EOF
[projects."$wt_repo"]
trust_level = "trusted"
EOF
out=$(CODEX_HOME="$WT/codex-home" CAP="$CAP" STDIN_CAP="$STDIN_CAP" LOOM_CODEX_CMD="$AR/bin/codex" \
  LOOM_AGENT_SKIP_AUTH=1 LOOM_AGENT_SKIP_MODEL_CHECK=1 \
  "$AGENT" preflight --provider codex --job implementation --tier medium --cwd "$made" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '.ok == true and .provider == "codex"' >/dev/null \
  && ok "codex adapter: a trusted main clone covers its linked worktrees" \
  || bad "codex adapter: linked worktree did not inherit main-clone trust (rc=$rc, $out)"

# Provider identity is tracker state, while each scheduler carries an explicit
# transport value. Invalid or stale transport must fail before the wave command.
cat > "$AR/bin/tracker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  issues-open) cat "${BUILD_JSON:?}" ;;
  labels) printf '[{"name":"provider::claude"},{"name":"provider::codex"}]\n' ;;
  issue-relabel) echo "$*" >> "${MUTATIONS:?}"; printf '{}\n' ;;
  *) printf '[]\n' ;;
esac
EOF
cat > "$AR/bin/forge" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
chmod +x "$AR/bin/tracker" "$AR/bin/forge"

_provider_repo() { # <root> <provider>
  local root="$1" provider="$2"
  mkdir -p "$root"; seed_tracker_decl "$root"
  printf '[{"id":1,"title":"Build 1","state":"open","labels":["provider::%s"],"assignees":[],"body":"","url":"https://x/build"}]\n' "$provider" > "$root/build.json"
  : > "$root/global.yml"; : > "$root/mutations"
}

PA="$AR/project-a"; PB="$AR/project-b"
_provider_repo "$PA" claude; _provider_repo "$PB" codex
printf '[{"id":1,"title":"Build 1","state":"open","labels":[],"assignees":[],"body":""}]\n' > "$AR/missing.json"
printf '[{"id":1,"title":"Build 1","state":"open","labels":["provider::claude","provider::codex"],"assignees":[],"body":""}]\n' > "$AR/duplicate.json"
printf '[{"id":1,"title":"Build 1","state":"open","labels":["provider::future"],"assignees":[],"body":""}]\n' > "$AR/unknown.json"
rm -f "$AR/should-not-run"
provider_refused=0
: > "$AR/refusal-results"
for spec in "$AR/missing.json:claude" "$AR/duplicate.json:claude" "$AR/unknown.json:claude" "$PA/build.json:codex"; do
  build_json="${spec%:*}"; transport="${spec##*:}"
  BUILD_JSON="$build_json" MUTATIONS="$PA/mutations" TRACKER_CMD="$AR/bin/tracker" FORGE_CMD="$AR/bin/forge" \
    LOOM_REPO="$PA" LOOM_HOME="$AR/refuse-home-$provider_refused" LOOM_GLOBAL_CONFIG="$PA/global.yml" \
    LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_AGENT_PREFLIGHT=1 LOOM_SKIP_PROVIDER_CHECK= LOOM_WAVE_CMD="touch $AR/should-not-run" \
    "$TICK" tick --provider "$transport" >"$AR/refusal.out" 2>&1
  rc=$?
  printf 'rc=%s %s with %s: %s\n' "$rc" "$build_json" "$transport" "$(cat "$AR/refusal.out")" >> "$AR/refusal-results"
  if [ "$rc" -eq 0 ]; then provider_refused=99; else provider_refused=$((provider_refused+1)); fi
done
[ "$provider_refused" -eq 4 ] && [ ! -e "$AR/should-not-run" ] \
  && ok "provider state: missing, duplicate, unknown, and mismatched labels fail before a wave" \
  || bad "provider state: an invalid scheduler/build pairing reached the wave (refused=$provider_refused wave_file=$([ -e "$AR/should-not-run" ] && echo yes || echo no) $(cat "$AR/refusal-results"))"

# Same-provider resumes are repeatable, and two repos can run different
# providers concurrently without sharing locks, logs, or selected state.
: > "$AR/a-waves"; : > "$AR/b-waves"
_run_project_tick() { # <repo> <home> <provider> <counter>
  BUILD_JSON="$1/build.json" MUTATIONS="$1/mutations" TRACKER_CMD="$AR/bin/tracker" FORGE_CMD="$AR/bin/forge" \
    LOOM_REPO="$1" LOOM_HOME="$2" LOOM_GLOBAL_CONFIG="$1/global.yml" \
    LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_AGENT_PREFLIGHT=1 LOOM_SKIP_PROVIDER_CHECK= LOOM_WAVE_CMD="echo $3 >> $4" \
    "$TICK" tick --provider "$3" >/dev/null 2>&1
}
_run_project_tick "$PA" "$AR/home-a" claude "$AR/a-waves" & pa=$!
_run_project_tick "$PB" "$AR/home-b" codex "$AR/b-waves" & pb=$!
wait "$pa"; rca=$?; wait "$pb"; rcb=$?
_run_project_tick "$PA" "$AR/home-a" claude "$AR/a-waves"; rcr=$?
if [ "$rca" -eq 0 ] && [ "$rcb" -eq 0 ] && [ "$rcr" -eq 0 ] \
   && [ "$(wc -l < "$AR/a-waves" | tr -d ' ')" -eq 2 ] \
   && [ "$(wc -l < "$AR/b-waves" | tr -d ' ')" -eq 1 ] \
   && grep -q '"provider":"claude"' "$AR/home-a/events.jsonl" \
   && grep -q '"provider":"codex"' "$AR/home-b/events.jsonl" \
   && [ ! -e "$AR/home-a/provider" ] && [ ! -e "$AR/home-b/provider" ]; then
  ok "provider state: same-provider resume and concurrent two-repo isolation hold"
else
  bad "provider state: concurrent schedulers collided or same-provider resume failed"
fi

out=$(BUILD_JSON="$PA/build.json" MUTATIONS="$PA/mutations" TRACKER_CMD="$AR/bin/tracker" \
  LOOM_REPO="$PA" LOOM_HOME="$AR/home-a" LOOM_GLOBAL_CONFIG="$PA/global.yml" \
  "$LANE" build-provider codex 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$PA/mutations" ] && case "$out" in *"silent switch"*) true;; *) false;; esac \
  && ok "provider state: human mutation refuses a silent provider switch" \
  || bad "provider state: build-provider silently switched the active build ($out)"

# Deterministic worktree preparation starts at remote base and preserves reuse.
WT="$T/worktree-case"; mkdir -p "$WT"; git init -q --bare "$WT/origin.git"; git init -q "$WT/repo"
git -C "$WT/repo" config user.email loom@test; git -C "$WT/repo" config user.name Loom
printf 'base\n' > "$WT/repo/readme"; git -C "$WT/repo" add readme; git -C "$WT/repo" commit -qm base
git -C "$WT/repo" branch -M main; git -C "$WT/repo" remote add origin "$WT/origin.git"; git -C "$WT/repo" push -q -u origin main
printf 'secret=test\n' > "$WT/repo/.env"
out=$("$WORKTREE" prepare --repo "$WT/repo" --ticket 7 --base main)
[ -d "$out" ] && [ "$(cat "$out/.env")" = secret=test ] && [ "$(git -C "$out" rev-parse HEAD)" = "$(git -C "$WT/repo" rev-parse origin/main)" ] \
  && ok "worktree: deterministic prepare uses remote base and copies root .env" \
  || bad "worktree: prepare output wrong ($out)"
printf 'dirty\n' > "$out/local.txt"
out2=$("$WORKTREE" prepare --repo "$WT/repo" --ticket 7 --base main)
[ "$out2" = "$out" ] && [ -f "$out/local.txt" ] \
  && ok "worktree: repeat preparation reuses dirty work without overwriting it" \
  || bad "worktree: repeat preparation did not preserve reuse"
"$WORKTREE" prepare --repo "$WT/repo" --key '../escape' --base main >/dev/null 2>&1 \
  && bad "worktree: path traversal key was accepted" || ok "worktree: path traversal key is refused"

# A new lane must receive a runnable checkout, not merely a Git checkout.
# Keep the package-manager call deterministic here; the production command is
# derived from the same shared lockfile table used by reconcile/base-check.
printf 'lockfileVersion: 9.0\n' > "$WT/repo/pnpm-lock.yaml"
printf '{"private":true}\n' > "$WT/repo/package.json"
git -C "$WT/repo" add pnpm-lock.yaml package.json
git -C "$WT/repo" commit -qm 'add package contract'
git -C "$WT/repo" push -q origin main
install_mark="$WT/worktree-install-ran"
made8=$(LOOM_WORKTREE_INSTALL_CMD="touch $install_mark" \
  "$WORKTREE" prepare --repo "$WT/repo" --ticket 8 --base main)
if [ -f "$install_mark" ] && [ -d "$made8" ]; then
  ok "worktree: prepare installs lockfile dependencies before returning the lane cwd"
else
  bad "worktree: prepare returned an unrunnable checkout without installing dependencies"
fi

# A plan deliberately carries <base> when no base is configured: that token
# means "apply the shared base rule on the host", not a branch literally named
# <base>. Exercise the production preparation path so a provider can never be
# handed a plan whose worktree failed before the session even started.
seed_tracker_decl "$WT/repo"
git -C "$WT/repo" commit -qm 'declare tracker'
git -C "$WT/repo" push -q origin main
cat > "$WT/build-ready.json" <<'EOF'
[
  {"id":1,"title":"Build 1","state":"open","labels":["provider::codex"],"assignees":[],"body":"","url":"https://x/build"},
  {"id":119,"title":"Ready work","state":"open","labels":["build-1","ready-for-agent","tier::logic"],"assignees":[],"body":"Do the work","url":"https://x/119"}
]
EOF
rm -f "$WT/repo/.loom.yml"
BUILD_JSON="$WT/build-ready.json" MUTATIONS="$WT/mutations" \
  TRACKER_CMD="$AR/bin/tracker" FORGE_CMD="$AR/bin/forge" \
  LOOM_REPO="$WT/repo" LOOM_HOME="$WT/tick-home" LOOM_GLOBAL_CONFIG="$WT/global.yml" \
  LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_AGENT_PREFLIGHT=1 LOOM_SKIP_PROVIDER_CHECK=1 \
  LOOM_PREPARE_PLAN_WITH_WAVE_CMD=1 LOOM_WAVE_CMD=true LOOM_WORKTREE_INSTALL_CMD=true \
  "$TICK" tick --provider codex >"$WT/tick.out" 2>&1
rc=$?
prepared_plan=$(find "$WT/tick-home/scratch" -name plan.json -print 2>/dev/null | head -1)
prepared_cwd=$([ -n "$prepared_plan" ] && jq -r '.actions[] | select(.lane == "impl-119") | .spawn.cwd // empty' "$prepared_plan")
if [ "$rc" -eq 0 ] && [ "$prepared_cwd" = "$(cd "$WT/repo" && pwd -P)/.worktrees/119" ]; then
  ok "wave preparation: <base> resolves through the shared base rule before worktree creation"
else
  bad "wave preparation: unresolved <base> stopped the host scheduler (rc=$rc cwd=[$prepared_cwd] $(head -1 "$WT/tick.out"))"
fi

test_finish
