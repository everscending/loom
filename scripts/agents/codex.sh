#!/usr/bin/env bash
# Codex adapter. Sourced only by scripts/agent.sh.

agent_detect() {
    [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SESSION_ID:-}" ] || [ "${CODEX_CI:-}" = 1 ]
}

agent_default_profile() {
    case "$1" in
      medium) jq -nc '{model:"gpt-5.6-terra",reasoning_effort:"medium"}';;
      high) jq -nc '{model:"gpt-5.6-sol",reasoning_effort:"high"}';;
      *) return 24;;
    esac
}

_codex_path_trusted() { # <config> <absolute-path>
    local cfg="$1" cwd="$2"
    awk -v p="$cwd" '
      $0=="[projects.\"" p "\"]" {inside=1; next}
      /^\[/ {inside=0}
      inside && /^[[:space:]]*trust_level[[:space:]]*=[[:space:]]*"trusted"/ {found=1}
      END {exit(found?0:1)}' "$cfg"
}

_codex_trusted() {
    [ -n "${LOOM_AGENT_SKIP_TRUST:-}" ] && return 0
    local cfg="${CODEX_HOME:-$HOME/.codex}/config.toml" cwd="$1" main=""
    [ -f "$cfg" ] || return 1
    _codex_path_trusted "$cfg" "$cwd" && return 0
    # Accept the main clone's explicit trust only when Git itself proves this
    # cwd is one of that clone's linked worktrees. Arbitrary descendants do not
    # inherit project trust.
    main=$(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
    [ -n "$main" ] && [ "$main" != "$cwd" ] && _codex_path_trusted "$cfg" "$main"
}

agent_preflight() {
    local bin="${LOOM_CODEX_CMD:-codex}" cwd="$3" profile="$4" model
    command -v "${bin%% *}" >/dev/null 2>&1 || { _agent_error executable "Codex executable not found: ${bin%% *}" codex; return 21; }
    "$bin" --version >/dev/null 2>&1 || { _agent_error executable "Codex executable did not report a version" codex; return 21; }
    if [ -z "${LOOM_AGENT_SKIP_AUTH:-}" ]; then
      "$bin" login status 2>&1 | grep -qi 'logged in' || { _agent_error authentication "Codex authentication is unavailable; run 'codex login'" codex; return 22; }
    fi
    [ -f "$cwd/.codex/rules/loom.rules" ] || [ -n "${LOOM_AGENT_SKIP_POLICY:-}" ] \
      || { _agent_error policy "Codex guardrails missing at $cwd/.codex/rules/loom.rules; run agent.sh sync-guardrails" codex; return 23; }
    _codex_trusted "$cwd" || { _agent_error policy "Codex project layer is not trusted for $cwd; project-local rules would be ignored" codex; return 23; }
    model=$(printf '%s' "$profile" | jq -r .model)
    if [ -z "${LOOM_AGENT_SKIP_MODEL_CHECK:-}" ]; then
      "$bin" debug models 2>/dev/null | jq -e --arg m "$model" '..|objects|select((.slug? // .id? // .model?)==$m)' >/dev/null 2>&1 \
        || { _agent_error profile "Codex profile model '$model' is unavailable; set provider_profiles.codex explicitly" codex; return 24; }
    fi
    return 0
}

agent_sync_guardrails() {
    local repo="$1" target="$1/.codex/rules/loom.rules"
    mkdir -p "$repo/.codex/rules"
    cat > "$target.tmp" <<'RULES'
# Managed by Loom. Consumer: Codex execpolicy.
prefix_rule(pattern=["git", "push", "--force"], decision="forbidden", justification="Loom never force-pushes; push the existing branch history.")
prefix_rule(pattern=["git", "push", "-f"], decision="forbidden", justification="Loom never force-pushes; push the existing branch history.")
prefix_rule(pattern=["git", "reset", "--hard"], decision="forbidden", justification="Loom preserves worktree state; use a non-destructive repair.")
prefix_rule(pattern=["git", "clean", ["-f", "-fd", "-fdx", "-fx"]], decision="forbidden", justification="Loom sweep owns cleanup and preserves unsaved work.")
prefix_rule(pattern=["rm", ["-rf", "-fr"]], decision="forbidden", justification="Loom denies unscoped recursive deletion; use the scoped Loom cleanup verb.")
RULES
    mv "$target.tmp" "$target"
    echo "sync-guardrails: codex wrote $target"
}

agent_normalize() {
    jq --unbuffered -Rrc --arg provider codex --arg job "$1" --arg lane "$2" '
      (fromjson?) as $e | select($e != null)
      | if ($e.type=="item.completed" and (($e.item.type//"")=="agent_message")) then
          {schema:1,type:"assistant_progress",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),text:($e.item.text//"")}
        elif (($e.type=="item.started" or $e.type=="item.completed") and (($e.item.type//"")=="command_execution")) then
          {schema:1,type:"tool_progress",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),tool:"shell",summary:($e.item.command//"")}
        elif $e.type=="turn.completed" then
          {schema:1,type:"usage",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),tokens:{input:($e.usage.input_tokens//0),output:($e.usage.output_tokens//0)},cost_usd:null}
        elif (($e.type//"")|test("rate_limit|usage_limit")) then
          {schema:1,type:"limit",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),reset_at:($e.reset_at//null),message:($e.message//"usage limit")}
        elif (($e.type//"")|test("error|failed")) then
          {schema:1,type:"error",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),category:"native_error",message:($e.message//$e.error.message//"Codex error")}
        else empty end'
}

agent_run() {
    local job="$1" cwd="$3" brief="$4" lane="$5" profile="$6" bin="${LOOM_CODEX_CMD:-codex}" model effort native rc=0 sandbox=""
    local state_dir="${LOOM_HOME:-${TMPDIR:-/tmp}}" git_common="" runtime_node="" runtime_node_dir=""
    local pnpm_runtime="" pnpm_runtime_dir=""
    local -a sandbox_args
    model=$(printf '%s' "$profile" | jq -r .model)
    effort=$(printf '%s' "$profile" | jq -r .reasoning_effort)
    # A linked worktree keeps FETCH_HEAD, refs, locks and its index beneath the
    # main clone's shared .git directory, outside Codex's `-C <worktree>`
    # workspace root. Without this narrow grant, ordinary fetch/reconcile fails
    # even though source edits in the worktree succeed. Grant Git metadata, not
    # the main clone's tracked files.
    git_common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    [ -n "$git_common" ] || { _agent_error policy "Cannot resolve shared Git metadata for $cwd" codex; return 23; }
    # Codex deliberately constructs a tool-shell environment of its own. Its
    # default PATH omits version-manager shims inherited by the launchd lane:
    # a direct command can work while gate.mjs -> /bin/sh cannot find pnpm.
    # Preserve the scheduler's validated environment at every subprocess depth
    # with the inheritance mode documented by `codex exec --help`.
    #
    # When `node` resolves through Volta's shim, Volta removes its own shim
    # directory from Node's child PATH to prevent recursion. A repo gate that
    # runs `node -> /bin/sh -> pnpm` then loses pnpm even though the outer zsh
    # found it. Resolve Node once through the manager and put the real runtime
    # directory first; Node no longer traverses the shim, so its children keep
    # the scheduler's pnpm shim available.
    runtime_node=$(node -p 'process.execPath' 2>/dev/null || true)
    case "$runtime_node" in
      /*) runtime_node_dir=$(dirname "$runtime_node") ;;
    esac
    if command -v pnpm >/dev/null 2>&1; then
        if command -v volta >/dev/null 2>&1; then
            pnpm_runtime=$(volta which pnpm 2>/dev/null || true)
        fi
        [ -n "$pnpm_runtime" ] || pnpm_runtime=$(command -v pnpm)
        case "$pnpm_runtime" in
          /*) pnpm_runtime_dir=$(dirname "$pnpm_runtime") ;;
        esac
    fi
    [ -z "$pnpm_runtime_dir" ] || export PATH="$pnpm_runtime_dir:$PATH"
    [ -z "$runtime_node_dir" ] || export PATH="$runtime_node_dir:$PATH"
    # workspace-write is the safe default. Some macOS repositories need local
    # Unix sockets, TCP listeners or Chromium Mach services in their tests;
    # Codex's workspace sandbox denies those even with network_access enabled.
    # A human can explicitly opt this build into the broader provider mode.
    sandbox="${LOOM_CODEX_SANDBOX:-workspace-write}"
    case "$sandbox" in
      workspace-write)
        sandbox_args=(--sandbox workspace-write --add-dir "$state_dir" --add-dir "$git_common" -c 'sandbox_workspace_write.network_access=true') ;;
      danger-full-access)
        sandbox_args=(--sandbox danger-full-access) ;;
      *)
        _agent_error policy "Invalid LOOM_CODEX_SANDBOX '$sandbox' (expected workspace-write or danger-full-access)" codex
        return 23 ;;
    esac
    native="${LOOM_AGENT_NATIVE_LOG:-${TMPDIR:-/tmp}/loom-codex-native-$$.jsonl}"
    LOOM_DEFER_LANE_LAUNCH=1 "$bin" exec --json --ephemeral --model "$model" -c "model_reasoning_effort=\"$effort\"" \
      -c 'approval_policy="never"' "${sandbox_args[@]}" \
      -c 'shell_environment_policy.inherit=all' \
      -C "$cwd" - < "$brief" 2>"$native.stderr" | tee "$native" | agent_normalize "$job" "$lane" || rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || ! grep -qiE 'usage limit|session limit|rate limit|quota|limit reached' "$native" "$native.stderr" 2>/dev/null || return 42
    if ! jq -Rse 'split("\n") | map(select(length > 0) | fromjson) | length > 0' "$native" >/dev/null 2>&1; then
      jq -nc --arg provider codex --arg job "$job" --arg lane "$lane" \
        '{schema:1,type:"error",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),category:"malformed_native_output",message:"Codex emitted non-JSON output on its JSONL channel"}'
      return 25
    fi
    return "$rc"
}
