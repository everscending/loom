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
      stream)
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"working"}}'
        : > "${STREAM_READY:?}"
        while [ ! -e "${STREAM_RELEASE:?}" ]; do sleep 0.05; done
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
# Live Codex failure (demand-letter-generator build 1, 2026-08-16): the
# workspace sandbox denied tsx IPC, local TCP listeners and Chromium Mach
# services. Keep that safer default, but make a human's explicit opt-in
# deterministic so repos whose gates require those primitives can run.
: > "$CAP"; : > "$STDIN_CAP"
CAP="$CAP" STDIN_CAP="$STDIN_CAP" LOOM_CODEX_CMD="$AR/bin/codex" \
  LOOM_CODEX_SANDBOX=danger-full-access LOOM_AGENT_NATIVE_LOG="$AR/codex-unsandboxed.native" \
  "$AGENT" run --provider codex --job gate --tier medium --cwd "$AR/repo" --brief "$AR/brief.md" >/dev/null
argv=$(tail -1 "$CAP")
case "$argv" in *"--sandbox danger-full-access"*)
  ok "codex adapter: explicit socket-capable sandbox opt-in reaches the CLI";;
  *) bad "codex adapter: explicit sandbox opt-in was ignored ($argv)";; esac
case "$argv" in *"sandbox_workspace_write.network_access"*|*"--add-dir"*)
  bad "codex adapter: danger-full-access opt-in retained contradictory workspace grants ($argv)";;
  *) ok "codex adapter: danger-full-access opt-in emits no contradictory workspace grants";; esac
printf '%s' "$out" | jq -se 'any(.type=="session_start" and .provider=="codex" and .requested_tier=="high" and .resolved_profile.model=="gpt-5.6-sol") and any(.type=="assistant_progress") and any(.type=="usage" and .cost_usd==null) and any(.type=="session_end" and .status=="success")' >/dev/null \
  && ok "codex adapter: native stream becomes canonical JSONL with unknown cost null" \
  || bad "codex adapter: canonical stream incomplete ($out)"

rm -f "$AR/codex.stream.ready" "$AR/codex.stream.release" "$AR/codex.stream.out"
CAP="$CAP" STDIN_CAP="$STDIN_CAP" NATIVE_MODE=stream \
  STREAM_READY="$AR/codex.stream.ready" STREAM_RELEASE="$AR/codex.stream.release" \
  LOOM_CODEX_CMD="$AR/bin/codex" LOOM_AGENT_NATIVE_LOG="$AR/codex-stream.native" \
  "$AGENT" run --provider codex --job implementation --tier high --cwd "$AR/repo" \
  --brief "$AR/brief.md" --lane-id impl-stream >"$AR/codex.stream.out" 2>&1 &
stream_pid=$!
for _ in {1..100}; do [ -e "$AR/codex.stream.ready" ] && break; sleep 0.02; done
if [ -e "$AR/codex.stream.ready" ]; then sleep 0.1; fi
if grep -q '"type":"assistant_progress"' "$AR/codex.stream.out"; then
  ok "codex adapter: canonical progress flushes before the native session exits"
else
  bad "codex adapter: canonical progress stayed buffered during a live native session"
fi
: > "$AR/codex.stream.release"
wait "$stream_pid" || true

: > "$CAP"; : > "$STDIN_CAP"
CAP="$CAP" STDIN_CAP="$STDIN_CAP" LOOM_CODEX_CMD="$AR/bin/codex" LOOM_AGENT_NATIVE_LOG="$AR/codex-medium.native" \
  "$AGENT" run --provider codex --job wave --tier medium --cwd "$AR/repo" --brief "$AR/brief.md" >/dev/null
argv=$(tail -1 "$CAP")
case "$argv" in *"--model gpt-5.6-terra"*"model_reasoning_effort=\"medium\""*)
  ok "codex adapter: medium maps exactly to Terra/medium";; *) bad "codex adapter: medium argv wrong ($argv)";; esac
case "$argv" in *"--sandbox workspace-write"*"--add-dir $LOOM_HOME"*)
  ok "codex adapter: scheduling waves retain the narrower workspace sandbox";;
  *) bad "codex adapter: scheduling wave lost its narrow sandbox ($argv)";; esac
case "$argv" in *luna*|*xhigh*|*max*) bad "codex adapter: invented a forbidden fallback ($argv)";;
  *) ok "codex adapter: no Luna/xhigh/max fallback";; esac

cat > "$AR/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${CLAUDE_CAP:?}"
case "$1" in
  --version) echo 'claude 99.0' ;;
  auth) echo '{"loggedIn":true}' ;;
  *) if [ "${CLAUDE_NATIVE_MODE:-success}" = stream ]; then
       printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}],"usage":{"input_tokens":4,"output_tokens":2}}}'
       : > "${STREAM_READY:?}"
       while [ ! -e "${STREAM_RELEASE:?}" ]; do sleep 0.05; done
       printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"PASS","total_cost_usd":0.01}'
     else
       printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"reviewed"}],"usage":{"input_tokens":4,"output_tokens":2}}}' \
                      '{"type":"result","subtype":"success","is_error":false,"result":"PASS","total_cost_usd":0.01}'
     fi ;;
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

rm -f "$AR/claude.stream.ready" "$AR/claude.stream.release" "$AR/claude.stream.out"
CLAUDE_CAP="$CLAUDE_CAP" CLAUDE_NATIVE_MODE=stream \
  STREAM_READY="$AR/claude.stream.ready" STREAM_RELEASE="$AR/claude.stream.release" \
  LOOM_CLAUDE_CMD="$AR/bin/claude" LOOM_AGENT_NATIVE_LOG="$AR/claude-stream.native" \
  "$AGENT" run --provider claude --job gate --tier high --cwd "$AR/repo" \
  --brief "$AR/brief.md" --lane-id gate-stream >"$AR/claude.stream.out" 2>&1 &
stream_pid=$!
for _ in {1..100}; do [ -e "$AR/claude.stream.ready" ] && break; sleep 0.02; done
if [ -e "$AR/claude.stream.ready" ]; then sleep 0.1; fi
if grep -q '"type":"assistant_progress"' "$AR/claude.stream.out"; then
  ok "claude adapter: canonical progress flushes before the native session exits"
else
  bad "claude adapter: canonical progress stayed buffered during a live native session"
fi
: > "$AR/claude.stream.release"
wait "$stream_pid" || true

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
jq -e '.hooks.keep and (.permissions.allow|index("Bash(handwritten *)")) and (.permissions.deny|index("Bash(git push --force*)")) and (.permissions.deny|index("Bash(git rebase*)"))' "$AR/repo/.claude/settings.json" >/dev/null \
  && ok "guardrails: Claude sync preserves unrelated user settings" \
  || bad "guardrails: Claude sync clobbered user settings"

if command -v codex >/dev/null 2>&1; then
  rules="$AR/repo/.codex/rules/loom.rules"; denied=0
  for cmd in 'git push --force origin x' 'git push --force-with-lease origin x' 'git rebase origin/main' 'git reset --hard HEAD' 'git clean -fdx' 'rm -rf /tmp/loom-test'; do
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
  issue-notes)
    if [ -n "${NOTES_JSON:-}" ] && [ "${2:-}" = "${FIXTURE_TICKET:-}" ]; then cat "$NOTES_JSON"
    else printf '[]\n'; fi ;;
  labels) printf '[{"name":"provider::claude"},{"name":"provider::codex"}]\n' ;;
  issue-relabel) echo "$*" >> "${MUTATIONS:?}"; printf '{}\n' ;;
  *) printf '[]\n' ;;
esac
EOF
cat > "$AR/bin/forge" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  issue-mrs)
    if [ -n "${FORGE_JSON:-}" ] && [ "${2:-}" = "${FIXTURE_TICKET:-}" ]; then cat "$FORGE_JSON"
    else printf '[]\n'; fi ;;
  *) printf '[]\n' ;;
esac
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

# A killed implementation can be in-progress with a dirty surviving worktree
# and no MR yet. That is precisely the work a recovery wave must resume; an
# open-MR requirement belongs to gate/merge lanes, not stranded implementations.
stranded_cwd=$(LOOM_WORKTREE_INSTALL_CMD=true \
  "$WORKTREE" prepare --repo "$WT/repo" --ticket 120 --base main)
printf 'preserved\n' > "$stranded_cwd/unfinished.txt"
cat > "$WT/build-stranded.json" <<'EOF'
[
  {"id":1,"title":"Build 1","state":"open","labels":["provider::codex"],"assignees":[],"body":"","url":"https://x/build"},
  {"id":120,"title":"Stranded implementation","state":"open","labels":["build-1","in-progress","tier::logic"],"assignees":["agent"],"body":"Resume the work","url":"https://x/120"}
]
EOF
BUILD_JSON="$WT/build-stranded.json" MUTATIONS="$WT/mutations" \
  TRACKER_CMD="$AR/bin/tracker" FORGE_CMD="$AR/bin/forge" \
  LOOM_REPO="$WT/repo" LOOM_HOME="$WT/stranded-home" LOOM_GLOBAL_CONFIG="$WT/global.yml" \
  LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_AGENT_PREFLIGHT=1 LOOM_SKIP_PROVIDER_CHECK=1 \
  LOOM_PREPARE_PLAN_WITH_WAVE_CMD=1 LOOM_WAVE_CMD=true LOOM_WORKTREE_INSTALL_CMD=true \
  "$TICK" tick --provider codex >"$WT/stranded.out" 2>&1
stranded_rc=$?
stranded_plan=$(find "$WT/stranded-home/scratch" -name plan.json -print 2>/dev/null | head -1)
resolved_stranded=$([ -n "$stranded_plan" ] && jq -r '.actions[] | select(.lane == "impl-120") | .spawn.cwd // empty' "$stranded_plan")
if [ "$stranded_rc" -eq 0 ] && [ "$resolved_stranded" = "$stranded_cwd" ] \
   && [ -f "$stranded_cwd/unfinished.txt" ]; then
  ok "wave preparation: stranded implementation reuses its worktree without an open MR"
else
  bad "wave preparation: stranded no-MR implementation could not resume (rc=$stranded_rc cwd=[$resolved_stranded])"
fi

# Rework is also an implementation action, but its open MR makes the branch
# durable. If sweep removed only the linked checkout, resume must reconstruct
# that checkout from the MR branch instead of requiring uncommitted local state.
git -C "$WT/repo" switch -qc rework-121 main
printf 'rework\n' > "$WT/repo/rework.txt"
git -C "$WT/repo" add rework.txt
git -C "$WT/repo" commit -qm rework
git -C "$WT/repo" push -q -u origin rework-121
rework_head=$(git -C "$WT/repo" rev-parse HEAD)
git -C "$WT/repo" switch -q main
cat > "$WT/build-rework.json" <<'EOF'
[
  {"id":1,"title":"Build 1","state":"open","labels":["provider::codex"],"assignees":[],"body":"","url":"https://x/build"},
  {"id":121,"title":"Swept rework checkout","state":"open","labels":["build-1","in-progress","tier::logic"],"assignees":["agent"],"body":"Resume the rejected work","url":"https://x/121"}
]
EOF
printf '[{"id":77,"title":"Rework 121","state":"open","draft":false,"url":"https://x/pr/77","branch":"rework-121","sha":"%s","body":"Loom-Ticket: 121"}]\n' "$rework_head" > "$WT/rework-mrs.json"
printf '[{"body":"Gate rejected this head.\\n\\n<!-- orch-verdict FAIL %s class=fixture -->","created_at":"2026-08-16T00:00:00Z","system":false}]\n' "$rework_head" > "$WT/rework-notes.json"
BUILD_JSON="$WT/build-rework.json" MUTATIONS="$WT/mutations" \
  TRACKER_CMD="$AR/bin/tracker" FORGE_CMD="$AR/bin/forge" \
  FIXTURE_TICKET=121 FORGE_JSON="$WT/rework-mrs.json" NOTES_JSON="$WT/rework-notes.json" \
  LOOM_REPO="$WT/repo" LOOM_HOME="$WT/rework-home" LOOM_GLOBAL_CONFIG="$WT/global.yml" \
  LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_AGENT_PREFLIGHT=1 LOOM_SKIP_PROVIDER_CHECK=1 \
  LOOM_PREPARE_PLAN_WITH_WAVE_CMD=1 LOOM_WAVE_CMD=true LOOM_WORKTREE_INSTALL_CMD=true \
  "$TICK" tick --provider codex >"$WT/rework.out" 2>&1
rework_rc=$?
rework_plan=$(find "$WT/rework-home/scratch" -name plan.json -print 2>/dev/null | head -1)
resolved_rework=$([ -n "$rework_plan" ] && jq -r '.actions[] | select(.lane == "impl-121") | .spawn.cwd // empty' "$rework_plan")
if [ "$rework_rc" -eq 0 ] && [ "$resolved_rework" = "$(cd "$WT/repo" && pwd -P)/.worktrees/121" ] \
   && [ "$(git -C "$resolved_rework" rev-parse HEAD 2>/dev/null)" = "$rework_head" ]; then
  ok "wave preparation: swept rework worktree is reconstructed from its open MR branch"
else
  bad "wave preparation: open-MR rework could not reconstruct its swept worktree (rc=$rework_rc cwd=[$resolved_rework] $(tail -2 "$WT/rework.out" | tr '\n' ';'))"
fi

# A supervisor can finish and push from an isolated clone while Loom's
# standard ticket worktree still points at its original base commit. The
# tracker-derived MR head is the gate's immutable review target: host
# preparation must advance a clean stale checkout to exactly that commit
# before either provider can launch against it.
git -C "$WT/repo" branch gate-122 main
gate_cwd=$(LOOM_WORKTREE_INSTALL_CMD=true \
  "$WORKTREE" prepare --repo "$WT/repo" --ticket 122 --branch gate-122 --base main)
gate_stale_head=$(git -C "$gate_cwd" rev-parse HEAD)
git clone -q "$WT/origin.git" "$WT/gate-writer"
git -C "$WT/gate-writer" config user.email loom@test
git -C "$WT/gate-writer" config user.name Loom
git -C "$WT/gate-writer" switch -qc gate-122 origin/main
printf 'supervised\n' > "$WT/gate-writer/supervised.txt"
git -C "$WT/gate-writer" add supervised.txt
git -C "$WT/gate-writer" commit -qm 'supervised repair'
git -C "$WT/gate-writer" push -q origin gate-122
gate_mr_head=$(git -C "$WT/gate-writer" rev-parse HEAD)
cat > "$WT/build-gate.json" <<'EOF'
[
  {"id":1,"title":"Build 1","state":"open","labels":["provider::codex"],"assignees":[],"body":"","url":"https://x/build"},
  {"id":122,"title":"Supervised repair from another clone","state":"open","labels":["build-1","review","tier::logic"],"assignees":["human"],"body":"Review the pushed repair","url":"https://x/122"}
]
EOF
printf '[{"id":78,"title":"Gate 122","state":"open","draft":false,"url":"https://x/pr/78","branch":"gate-122","sha":"%s","body":"Loom-Ticket: 122"}]\n' \
  "$gate_mr_head" > "$WT/gate-mrs.json"
BUILD_JSON="$WT/build-gate.json" MUTATIONS="$WT/mutations" \
  TRACKER_CMD="$AR/bin/tracker" FORGE_CMD="$AR/bin/forge" \
  FIXTURE_TICKET=122 FORGE_JSON="$WT/gate-mrs.json" \
  LOOM_REPO="$WT/repo" LOOM_HOME="$WT/gate-home" LOOM_GLOBAL_CONFIG="$WT/global.yml" \
  LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_AGENT_PREFLIGHT=1 LOOM_SKIP_PROVIDER_CHECK=1 \
  LOOM_PREPARE_PLAN_WITH_WAVE_CMD=1 LOOM_WAVE_CMD=true LOOM_WORKTREE_INSTALL_CMD=true \
  "$TICK" tick --provider codex >"$WT/gate.out" 2>&1
gate_rc=$?
gate_plan=$(find "$WT/gate-home/scratch" -name plan.json -print 2>/dev/null | head -1)
gate_plan_head=$([ -n "$gate_plan" ] && jq -r '.actions[] | select(.lane == "gate-122") | .spawn.expected_head // empty' "$gate_plan")
gate_prepared_head=$(git -C "$gate_cwd" rev-parse HEAD 2>/dev/null)
if [ "$gate_rc" -eq 0 ] && [ "$gate_stale_head" != "$gate_mr_head" ] \
   && [ "$gate_plan_head" = "$gate_mr_head" ] && [ "$gate_prepared_head" = "$gate_mr_head" ]; then
  ok "wave preparation: gate cwd resolves to the immutable MR head before provider launch"
else
  bad "wave preparation: gate kept stale cwd or lost immutable MR head (rc=$gate_rc stale=$gate_stale_head mr=$gate_mr_head planned=[$gate_plan_head] prepared=[$gate_prepared_head] $(tail -2 "$WT/gate.out" | tr '\n' ';'))"
fi

# Planted violation: preserve the planned expected_head but drop only the
# tick -> worktree handoff. A newer supervised push must then recreate the
# observed stale-cwd failure, proving the regression is sensitive to the
# production boundary rather than merely to the new JSON field.
printf 'newer supervised\n' >> "$WT/gate-writer/supervised.txt"
git -C "$WT/gate-writer" add supervised.txt
git -C "$WT/gate-writer" commit -qm 'newer supervised repair'
git -C "$WT/gate-writer" push -q origin gate-122
newer_gate_mr_head=$(git -C "$WT/gate-writer" rev-parse HEAD)
printf '[{"id":78,"title":"Gate 122","state":"open","draft":false,"url":"https://x/pr/78","branch":"gate-122","sha":"%s","body":"Loom-Ticket: 122"}]\n' \
  "$newer_gate_mr_head" > "$WT/gate-mrs-newer.json"
GATE_MUT=$(mirror_scripts "$WT/gate-head-mutant")
sed 's/ --head "$expected_head"//g' "$GATE_MUT/tick.sh" > "$GATE_MUT/tick-mutant.sh"
chmod +x "$GATE_MUT/tick-mutant.sh"
gate_mut_out=$(BUILD_JSON="$WT/build-gate.json" MUTATIONS="$WT/mutations" \
  TRACKER_CMD="$AR/bin/tracker" FORGE_CMD="$AR/bin/forge" \
  FIXTURE_TICKET=122 FORGE_JSON="$WT/gate-mrs-newer.json" \
  LOOM_REPO="$WT/repo" LOOM_HOME="$WT/gate-mutant-home" LOOM_GLOBAL_CONFIG="$WT/global.yml" \
  LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_AGENT_PREFLIGHT=1 LOOM_SKIP_PROVIDER_CHECK=1 \
  LOOM_PREPARE_PLAN_WITH_WAVE_CMD=1 LOOM_WAVE_CMD=true LOOM_WORKTREE_INSTALL_CMD=true \
  "$GATE_MUT/tick-mutant.sh" tick --provider codex 2>&1)
gate_mut_rc=$?
if assert_mutant_ran "$gate_mut_rc" "$gate_mut_out" "gate-head-handoff-violation"; then
  gate_mut_plan=$(find "$WT/gate-mutant-home/scratch" -name plan.json -print 2>/dev/null | head -1)
  gate_mut_planned=$([ -n "$gate_mut_plan" ] && jq -r '.actions[] | select(.lane == "gate-122") | .spawn.expected_head // empty' "$gate_mut_plan")
  gate_mut_prepared=$(git -C "$gate_cwd" rev-parse HEAD 2>/dev/null)
  if [ "$gate_mut_rc" -eq 0 ] && [ "$gate_mut_planned" = "$newer_gate_mr_head" ] \
     && [ "$gate_mut_prepared" != "$newer_gate_mr_head" ]; then
    ok "wave preparation violation: dropping immutable-head handoff recreates stale gate cwd"
  else
    bad "wave preparation violation: mutant did not isolate the stale-cwd failure (rc=$gate_mut_rc planned=[$gate_mut_planned] prepared=[$gate_mut_prepared] mr=$newer_gate_mr_head)"
  fi
fi

# Host preflight is per spawn, not an all-or-nothing wave gate. A dirty gate
# checkout cannot safely advance to a newer immutable MR head, but that one
# local problem must not suppress unrelated runnable work (or harvest actions
# already present in the same plan). Defer it explicitly and launch the rest.
printf 'local diagnosis\n' >> "$gate_cwd/supervised.txt"
cat > "$WT/build-mixed-preflight.json" <<'EOF'
[
  {"id":1,"title":"Build 1","state":"open","labels":["provider::codex"],"assignees":[],"body":"","url":"https://x/build"},
  {"id":122,"title":"Dirty gate checkout","state":"open","labels":["build-1","review","tier::logic"],"assignees":["human"],"body":"Review the pushed repair","url":"https://x/122"},
  {"id":123,"title":"Independent ready work","state":"open","labels":["build-1","ready-for-agent","tier::logic"],"assignees":[],"body":"Do independent work","url":"https://x/123"}
]
EOF
mixed_plan_cap="$WT/mixed-preflight-plan.json"
mixed_wave_ran="$WT/mixed-preflight-wave-ran"
mixed_cmd='cp "$LOOM_WAVE_PLAN" "$MIXED_PLAN_CAP"; : > "$MIXED_WAVE_RAN"'
BUILD_JSON="$WT/build-mixed-preflight.json" MUTATIONS="$WT/mutations" \
  TRACKER_CMD="$AR/bin/tracker" FORGE_CMD="$AR/bin/forge" \
  FIXTURE_TICKET=122 FORGE_JSON="$WT/gate-mrs-newer.json" \
  LOOM_REPO="$WT/repo" LOOM_HOME="$WT/mixed-preflight-home" LOOM_GLOBAL_CONFIG="$WT/global.yml" \
  LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_AGENT_PREFLIGHT=1 LOOM_SKIP_PROVIDER_CHECK=1 \
  LOOM_PREPARE_PLAN_WITH_WAVE_CMD=1 LOOM_WAVE_CMD="$mixed_cmd" LOOM_WORKTREE_INSTALL_CMD=true \
  MIXED_PLAN_CAP="$mixed_plan_cap" MIXED_WAVE_RAN="$mixed_wave_ran" \
  "$TICK" tick --provider codex >"$WT/mixed-preflight.out" 2>&1
mixed_rc=$?
if [ "$mixed_rc" -eq 0 ] && [ -f "$mixed_wave_ran" ] \
   && jq -e 'any(.actions[]; .lane == "impl-123" and .spawn.cwd != null)
             and (any(.actions[]; .lane == "gate-122") | not)
             and any(.deferred[]; .lane == "gate-122" and .ticket == 122
                       and .kind == "host-preflight-failed"
                       and (.why | contains("tracked changes")))' "$mixed_plan_cap" >/dev/null \
   && jq -e 'select(.ev == "wave_spawn_deferred" and .lane == "gate-122" and .ticket == 122)' \
        "$WT/mixed-preflight-home/events.jsonl" >/dev/null; then
  ok "wave preparation: one unsafe spawn is deferred without suppressing the valid wave"
else
  bad "wave preparation: one dirty spawn suppressed unrelated work or vanished (rc=$mixed_rc ran=$([ -f "$mixed_wave_ran" ] && echo yes || echo no) plan=[$mixed_plan_cap] $(tail -3 "$WT/mixed-preflight.out" | tr '\n' ';'))"
fi

# Planted violation: restore the old all-or-nothing return at the exact public
# boundary. The same dirty gate must now prevent the provider from seeing the
# independent action, proving the mixed-plan regression pays for the fix.
PREFLIGHT_MUT=$(mirror_scripts "$WT/spawn-preflight-mutant")
sed 's/_defer_wave_spawn "$plan" "$lane" "$ticket" "$error_log" || exit 1/exit 1 # mutate:abort-wave-on-spawn-preflight/' \
  "$PREFLIGHT_MUT/tick.sh" > "$PREFLIGHT_MUT/tick-mutant.sh"
chmod +x "$PREFLIGHT_MUT/tick-mutant.sh"
rm -f "$WT/mixed-preflight-mutant-wave-ran"
mixed_mut_out=$(BUILD_JSON="$WT/build-mixed-preflight.json" MUTATIONS="$WT/mutations" \
  TRACKER_CMD="$AR/bin/tracker" FORGE_CMD="$AR/bin/forge" \
  FIXTURE_TICKET=122 FORGE_JSON="$WT/gate-mrs-newer.json" \
  LOOM_REPO="$WT/repo" LOOM_HOME="$WT/mixed-preflight-mutant-home" LOOM_GLOBAL_CONFIG="$WT/global.yml" \
  LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_AGENT_PREFLIGHT=1 LOOM_SKIP_PROVIDER_CHECK=1 \
  LOOM_PREPARE_PLAN_WITH_WAVE_CMD=1 LOOM_WAVE_CMD="$mixed_cmd" LOOM_WORKTREE_INSTALL_CMD=true \
  MIXED_PLAN_CAP="$WT/mixed-preflight-mutant-plan.json" MIXED_WAVE_RAN="$WT/mixed-preflight-mutant-wave-ran" \
  "$PREFLIGHT_MUT/tick-mutant.sh" tick --provider codex 2>&1)
mixed_mut_rc=$?
if assert_mutant_ran "$mixed_mut_rc" "$mixed_mut_out" "abort-wave-on-spawn-preflight"; then
  if [ "$mixed_mut_rc" -ne 0 ] && [ ! -e "$WT/mixed-preflight-mutant-wave-ran" ]; then
    ok "wave preparation violation: all-or-nothing preflight recreates the build gap"
  else
    bad "wave preparation violation: abort mutant did not suppress the wave (rc=$mixed_mut_rc ran=$([ -e "$WT/mixed-preflight-mutant-wave-ran" ] && echo yes || echo no))"
  fi
fi

# If that PR lands outside Loom while its tracker ticket remains open, the
# branch is no longer rework. Preserve a post-merge FAIL as explicit residue
# and let other ready work proceed; never recreate and edit shipped code under
# the old ticket.
sed 's/"state":"open"/"state":"merged"/' "$WT/rework-mrs.json" > "$WT/merged-mrs.json"
BUILD_JSON="$WT/build-rework.json" MUTATIONS="$WT/mutations" \
  TRACKER_CMD="$AR/bin/tracker" FORGE_CMD="$AR/bin/forge" \
  FIXTURE_TICKET=121 FORGE_JSON="$WT/merged-mrs.json" NOTES_JSON="$WT/rework-notes.json" \
  LOOM_REPO="$WT/repo" LOOM_HOME="$WT/merged-home" LOOM_GLOBAL_CONFIG="$WT/global.yml" \
  LOOM_SKIP_BOOTSTRAP=1 LOOM_SKIP_AGENT_PREFLIGHT=1 LOOM_SKIP_PROVIDER_CHECK=1 \
  LOOM_PREPARE_PLAN_WITH_WAVE_CMD=1 LOOM_WAVE_CMD=true LOOM_WORKTREE_INSTALL_CMD=true \
  "$TICK" tick --provider codex >"$WT/merged.out" 2>&1
merged_rc=$?
merged_plan=$(find "$WT/merged-home/scratch" -name plan.json -print 2>/dev/null | head -1)
if [ "$merged_rc" -eq 0 ] && [ -n "$merged_plan" ] \
   && jq -e 'any(.residue[]; .kind == "merged-ticket-open" and .ticket == 121 and (.why | contains("file a fix ticket")))
             and (any(.actions[]; .ticket == 121 and .kind == "spawn") | not)' "$merged_plan" >/dev/null; then
  ok "wave preparation: merged PR with a standing FAIL becomes follow-up residue, never rework"
else
  bad "wave preparation: merged failing PR was respawned or lost (rc=$merged_rc plan=[$merged_plan] $(tail -2 "$WT/merged.out" | tr '\n' ';'))"
fi

test_finish
