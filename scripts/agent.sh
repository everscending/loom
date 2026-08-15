#!/usr/bin/env bash
# Loom's provider-neutral coding-agent runtime.
#
# Core callers know four verbs and five job kinds. Provider CLIs, native event
# shapes, authentication probes, model ids, reasoning controls and durable
# policy artifacts live under scripts/agents/.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${LOOM_REPO:-$PWD}"
CONFIG="${LOOM_CONFIG:-$REPO_ROOT/.loom.yml}"
GLOBAL_CONFIG="${LOOM_GLOBAL_CONFIG:-$HOME/.loom/config.yml}"
DIE_RC=1
. "$SELF_DIR/lib.sh"

_agent_error() { # <category> <message> [provider]
    jq -nc --arg category "$1" --arg message "$2" --arg provider "${3:-}" \
      '{schema:1, ok:false, category:$category, message:$message,
        provider:(if $provider=="" then null else $provider end)}' >&2
}

_registered() {
    local adapter
    for adapter in "$SELF_DIR"/agents/*.sh; do
      [ -f "$adapter" ] || continue
      basename "$adapter" .sh
    done
}
_is_registered() {
    case "$1" in ''|*[!A-Za-z0-9_-]*) return 1;; esac
    [ -f "$SELF_DIR/agents/$1.sh" ]
}
_adapter_path() { printf '%s/agents/%s.sh\n' "$SELF_DIR" "$1"; }

_load_adapter() {
    local provider="$1" adapter
    _is_registered "$provider" || { _agent_error detection "unknown provider '$provider' (registered: $(_registered | tr '\n' ' ' | sed 's/ $//'))" "$provider"; return 20; }
    adapter="$(_adapter_path "$provider")"
    [ -r "$adapter" ] || { _agent_error detection "registered adapter is missing: $adapter" "$provider"; return 20; }
    # shellcheck source=/dev/null
    . "$adapter"
}

_valid_job() { case "$1" in wave|implementation|gate|merge|probe) return 0;; *) return 1;; esac; }
_valid_tier() { case "$1" in medium|high) return 0;; *) return 1;; esac; }
_absolute_dir() { case "$1" in /*) [ -d "$1" ];; *) return 1;; esac; }

_refuse_legacy_profile() {
    local key=""
    key=$(_legacy_runtime_config "$REPO_ROOT/.loom.yml" "$GLOBAL_CONFIG") || return 0
    _agent_error config "legacy runtime config '$key' requires explicit migration to wave_tier/lane_tier/rework_tier, provider_profiles, or usage_limit: downshift_tier" "${provider:-}"
    return 27
}

# Read one field from the intentionally small provider_profiles YAML shape.
# Consumer: profile resolution below. This is configuration input, never
# selected-provider state.
_profile_field() { # <file> <provider> <tier> <field>
    local file="$1" provider="$2" tier="$3" field="$4"
    [ -f "$file" ] || return 0
    awk -v p="$provider" -v t="$tier" -v f="$field" '
      /^[^[:space:]#][^:]*:/ {top=$0; sub(/:.*/,"",top); inpp=(top=="provider_profiles"); inp=0; intier=0; next}
      inpp && /^  [^[:space:]#][^:]*:/ {x=$0; sub(/^  /,"",x); sub(/:.*/,"",x); inp=(x==p); intier=0; next}
      inpp && inp && /^    [^[:space:]#][^:]*:/ {
        x=$0; sub(/^    /,"",x); key=x; sub(/:.*/,"",key); intier=(key==t)
        if (intier && x ~ /\{/) {
          body=x; sub(/^[^{]*\{/,"",body); sub(/\}.*/,"",body)
          n=split(body,a,","); for(i=1;i<=n;i++){split(a[i],kv,":"); k=kv[1]; v=substr(a[i],index(a[i],":")+1); gsub(/^[ \t]+|[ \t]+$/,"",k); gsub(/^[ \t\"]+|[ \t\"]+$/,"",v); if(k==f){print v; exit}}
        }
        next
      }
      inpp && inp && intier && /^      [^[:space:]#][^:]*:/ {
        x=$0; sub(/^      /,"",x); key=x; sub(/:.*/,"",key); if(key==f){sub(/^[^:]*:[ \t]*/,"",x); gsub(/^[ \t\"]+|[ \t\"]+$/,"",x); print x; exit}
      }' "$file"
}

_resolved_profile() { # <provider> <tier>
    local provider="$1" tier="$2" repo="$REPO_ROOT/.loom.yml" model effort source="adapter-default" v
    local defaults; defaults=$(agent_default_profile "$tier") || return 24
    model=$(printf '%s' "$defaults" | jq -r '.model // empty')
    effort=$(printf '%s' "$defaults" | jq -r '.reasoning_effort // empty')
    v=$(_profile_field "$GLOBAL_CONFIG" "$provider" "$tier" model); [ -z "$v" ] || { model="$v"; source=global; }
    v=$(_profile_field "$GLOBAL_CONFIG" "$provider" "$tier" reasoning_effort); [ -z "$v" ] || { effort="$v"; source=global; }
    v=$(_profile_field "$repo" "$provider" "$tier" model); [ -z "$v" ] || { model="$v"; source=repo; }
    v=$(_profile_field "$repo" "$provider" "$tier" reasoning_effort); [ -z "$v" ] || { effort="$v"; source=repo; }
    [ -n "$model" ] || { _agent_error profile "provider '$provider' tier '$tier' has no model mapping" "$provider"; return 24; }
    jq -nc --arg model "$model" --arg effort "$effort" --arg source "$source" \
      '{model:$model, reasoning_effort:(if $effort=="" then null else $effort end), source:$source}'
}

cmd_detect() {
    local explicit="" p matches=""
    while [ $# -gt 0 ]; do case "$1" in
      --provider) explicit="${2:-}"; shift 2;;
      *) _agent_error detection "detect: unknown argument '$1'"; return 20;;
    esac; done
    if [ -n "$explicit" ]; then _load_adapter "$explicit" || return; printf '%s\n' "$explicit"; return 0; fi
    for p in $(_registered); do
        _load_adapter "$p" || return
        agent_detect && matches="${matches}${matches:+ }$p"
        unset -f agent_detect agent_default_profile agent_preflight agent_sync_guardrails agent_run agent_normalize 2>/dev/null || true
    done
    case "$matches" in
      "") _agent_error detection "no interactive provider identity matched; retry once with --provider <id>"; return 20;;
      *" "*) _agent_error detection "multiple provider identities matched ($matches); retry once with --provider <id>"; return 20;;
      *) printf '%s\n' "$matches";;
    esac
}

_parse_common() {
    provider="" job="" tier="" cwd="" brief="" lane_id="" repo=""
    while [ $# -gt 0 ]; do case "$1" in
      --provider) provider="${2:-}"; shift 2;; --job) job="${2:-}"; shift 2;;
      --tier) tier="${2:-}"; shift 2;; --cwd) cwd="${2:-}"; shift 2;;
      --brief) brief="${2:-}"; shift 2;; --lane-id) lane_id="${2:-}"; shift 2;;
      --repo) repo="${2:-}"; shift 2;;
      *) _agent_error arguments "unknown argument '$1'" "${provider:-}"; return 2;;
    esac; done
}

cmd_preflight() {
    _parse_common "$@" || return
    [ -n "$provider" ] && _valid_job "$job" && _valid_tier "$tier" && _absolute_dir "$cwd" \
      || { _agent_error arguments "preflight requires registered --provider, valid --job/--tier, and an absolute existing --cwd" "$provider"; return 2; }
    [ -r "$cwd" ] && [ -w "$cwd" ] && [ -x "$cwd" ] \
      || { _agent_error paths "preflight cwd must be readable, writable, and searchable: $cwd" "$provider"; return 26; }
    if [ -n "${LOOM_HOME:-}" ] && { [ ! -d "$LOOM_HOME" ] || [ ! -r "$LOOM_HOME" ] || [ ! -w "$LOOM_HOME" ] || [ ! -x "$LOOM_HOME" ]; }; then
      _agent_error paths "preflight Loom state directory must be readable, writable, and searchable: $LOOM_HOME" "$provider"
      return 26
    fi
    _refuse_legacy_profile || return
    _load_adapter "$provider" || return
    local profile; profile=$(_resolved_profile "$provider" "$tier") || return
    agent_preflight "$job" "$tier" "$cwd" "$profile" || return
    jq -nc --arg provider "$provider" --arg job "$job" --arg tier "$tier" --argjson profile "$profile" \
      '{schema:1,ok:true,provider:$provider,job:$job,requested_tier:$tier,resolved_profile:$profile}'
}

cmd_sync_guardrails() {
    _parse_common "$@" || return
    [ -n "$provider" ] && _absolute_dir "$repo" \
      || { _agent_error arguments "sync-guardrails requires --provider and an absolute existing --repo" "$provider"; return 2; }
    _load_adapter "$provider" || return
    agent_sync_guardrails "$repo"
}

cmd_run() {
    _parse_common "$@" || return
    [ -n "$provider" ] && _valid_job "$job" && _valid_tier "$tier" && _absolute_dir "$cwd" \
      && case "$brief" in /*) [ -s "$brief" ] && [ -r "$brief" ];; *) false;; esac \
      || { _agent_error arguments "run requires --provider, valid --job/--tier, absolute --cwd, and an absolute non-empty --brief" "$provider"; return 2; }
    _refuse_legacy_profile || return
    _load_adapter "$provider" || return
    local profile rc=0 ts native_log="${LOOM_AGENT_NATIVE_LOG:-${TMPDIR:-/tmp}/loom-$provider-native-$$.jsonl}"
    export LOOM_AGENT_NATIVE_LOG="$native_log"
    profile=$(_resolved_profile "$provider" "$tier") || return
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -nc --arg ts "$ts" --arg provider "$provider" --arg job "$job" --arg lane "$lane_id" \
      --arg tier "$tier" --argjson profile "$profile" \
      '{schema:1,type:"session_start",timestamp:$ts,provider:$provider,job:$job,
        lane_id:(if $lane=="" then null else $lane end),requested_tier:$tier,resolved_profile:$profile}'
    agent_run "$job" "$tier" "$cwd" "$brief" "$lane_id" "$profile" || rc=$?
    if [ "$rc" -eq 42 ]; then
      jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg provider "$provider" --arg job "$job" --arg lane "$lane_id" \
        '{schema:1,type:"limit",timestamp:$ts,provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),reset_at:null,message:"provider usage limit",action:"downshift_or_pause"}'
      if [ "$tier" = high ] && [ "$(cfg usage_limit pause_and_resume)" = downshift_tier ]; then
        jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg provider "$provider" --arg job "$job" --arg lane "$lane_id" \
          '{schema:1,type:"session_end",timestamp:$ts,provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),status:"limit",rc:42}'
        tier=medium; profile=$(_resolved_profile "$provider" medium) || return
        agent_preflight "$job" medium "$cwd" "$profile" || return
        jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg provider "$provider" --arg job "$job" --arg lane "$lane_id" --argjson profile "$profile" \
          '{schema:1,type:"session_start",timestamp:$ts,provider:$provider,job:$job,lane_id:(if $lane=="" then null else $lane end),requested_tier:"medium",resolved_profile:$profile,downshifted_from:"high"}'
        rc=0; agent_run "$job" medium "$cwd" "$brief" "$lane_id" "$profile" || rc=$?
      fi
    fi
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 42 ] && [ "$rc" -ne 25 ]; then
      jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg provider "$provider" --arg job "$job" \
        --arg lane "$lane_id" --argjson rc "$rc" \
        '{schema:1,type:"error",timestamp:$ts,provider:$provider,job:$job,
          lane_id:(if $lane=="" then null else $lane end),category:"native_cli_crash",message:("provider exited rc " + ($rc|tostring))}'
    fi
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg provider "$provider" --arg job "$job" \
      --arg lane "$lane_id" --argjson rc "$rc" \
      '{schema:1,type:"session_end",timestamp:$ts,provider:$provider,job:$job,
        lane_id:(if $lane=="" then null else $lane end),status:(if $rc==0 then "success" elif $rc==42 then "limit" else "error" end),rc:$rc}'
    return "$rc"
}

case "${1:-}" in
  detect) shift; cmd_detect "$@";;
  preflight) shift; cmd_preflight "$@";;
  sync-guardrails) shift; cmd_sync_guardrails "$@";;
  run) shift; cmd_run "$@";;
  *) echo "usage: agent.sh detect [--provider <id>] | preflight --provider <id> --job <kind> --tier <medium|high> --cwd <abs> | sync-guardrails --provider <id> --repo <abs> | run --provider <id> --job <kind> --tier <medium|high> --cwd <abs> --brief <abs> [--lane-id <id>]" >&2; exit 2;;
esac
