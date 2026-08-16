#!/usr/bin/env bash
# Claude Code adapter. Sourced only by scripts/agent.sh.

agent_detect() {
    [ "${CLAUDECODE:-}" = 1 ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || [ -n "${CLAUDE_SESSION_ID:-}" ]
}

agent_default_profile() {
    case "$1" in
      medium) jq -nc '{model:"sonnet",reasoning_effort:null}';;
      high) jq -nc '{model:"opus",reasoning_effort:null}';;
      *) return 24;;
    esac
}

agent_preflight() { # <job> <tier> <cwd> <profile-json>
    local bin="${LOOM_CLAUDE_CMD:-claude}" cwd="$3"
    command -v "${bin%% *}" >/dev/null 2>&1 || { _agent_error executable "Claude executable not found: ${bin%% *}" claude; return 21; }
    "$bin" --version >/dev/null 2>&1 || { _agent_error executable "Claude executable did not report a version" claude; return 21; }
    if [ -z "${LOOM_AGENT_SKIP_AUTH:-}" ]; then
      "$bin" auth status --json >/dev/null 2>&1 || { _agent_error authentication "Claude authentication is unavailable; run 'claude auth login'" claude; return 22; }
    fi
    [ -f "$cwd/.claude/settings.json" ] || [ -n "${LOOM_AGENT_SKIP_POLICY:-}" ] \
      || { _agent_error policy "Claude guardrails missing at $cwd/.claude/settings.json; run agent.sh sync-guardrails" claude; return 23; }
    if [ -z "${LOOM_AGENT_SKIP_TRUST:-}" ]; then
      LOOM_REPO="$cwd" "$SELF_DIR/tick.sh" trust-check "$cwd" >/dev/null 2>&1 \
        || { _agent_error policy "Claude workspace trust is unavailable for $cwd; open it interactively and accept the trust prompt" claude; return 23; }
    fi
    return 0
}

agent_sync_guardrails() {
    local repo="$1" target="$1/.claude/settings.json" generated existing
    mkdir -p "$repo/.claude"
    generated=$(LOOM_REPO="$repo" "$SELF_DIR/tick.sh" resolve-config | jq '{permissions:{allow:.guardrails.allow,deny:.guardrails.deny}}')
    if [ -s "$target" ] && jq -e . "$target" >/dev/null 2>&1; then
      existing=$(cat "$target")
      jq -n --argjson old "$existing" --argjson new "$generated" \
        '$old * {permissions:{allow:((($old.permissions.allow//[])+($new.permissions.allow//[]))|unique),deny:((($old.permissions.deny//[])+($new.permissions.deny//[]))|unique)}}' > "$target.tmp"
    else
      printf '%s\n' "$generated" > "$target.tmp"
    fi
    mv "$target.tmp" "$target"
    echo "sync-guardrails: claude wrote $target"
}

agent_normalize() {
    jq --unbuffered -Rrc --arg provider claude --arg job "$1" --arg lane "$2" '
      (fromjson?) as $e | select($e != null)
      | if $e.type=="assistant" then
          {schema:1,type:"assistant_progress",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),text:([$e.message.content[]?|select(.type=="text")|.text]|join("\n"))},
          ($e.message.content[]? | select(.type=="tool_use")
            | {schema:1,type:"tool_progress",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),tool:(.name//"tool"),summary:((.input.command//.input.file_path//.input.pattern//"")|tostring)}),
          (if $e.message.usage then {schema:1,type:"usage",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),tokens:{input:($e.message.usage.input_tokens//0),output:($e.message.usage.output_tokens//0)},cost_usd:null} else empty end)
        elif $e.type=="rate_limit_event" then {schema:1,type:"limit",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),reset_at:($e.rate_limit_info.resetsAt//null),message:"rate limit"}
        elif $e.type=="result" then
          if (($e.is_error//false) or (($e.subtype//"success")!="success"))
          then {schema:1,type:"error",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),category:($e.subtype//"native_error"),message:($e.result//"")}
          elif $e.total_cost_usd != null
          then {schema:1,type:"usage",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),tokens:{input:0,output:0},cost_usd:$e.total_cost_usd}
          else empty end
        else empty end'
}

agent_run() { # <job> <tier> <cwd> <brief> <lane-id> <profile>
    local job="$1" cwd="$3" brief="$4" lane="$5" profile="$6" bin="${LOOM_CLAUDE_CMD:-claude}" model native rc=0
    model=$(printf '%s' "$profile" | jq -r .model)
    native="${LOOM_AGENT_NATIVE_LOG:-${TMPDIR:-/tmp}/loom-claude-native-$$.jsonl}"
    "$bin" -p "$(cat "$brief")" --permission-mode "${LOOM_CLAUDE_PERMISSION_MODE:-dontAsk}" \
      --model "$model" --output-format stream-json --verbose --disallowedTools ScheduleWakeup \
      2>"$native.stderr" | tee "$native" | agent_normalize "$job" "$lane" || rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || ! grep -qiE 'usage limit|session limit|rate limit|quota|limit reached' "$native" "$native.stderr" 2>/dev/null || return 42
    if ! jq -Rse 'split("\n") | map(select(length > 0) | fromjson) | length > 0' "$native" >/dev/null 2>&1; then
      jq -nc --arg provider claude --arg job "$job" --arg lane "$lane" \
        '{schema:1,type:"error",timestamp:(now|todateiso8601),provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),category:"malformed_native_output",message:"Claude emitted non-JSON output on its JSONL channel"}'
      return 25
    fi
    return "$rc"
}
