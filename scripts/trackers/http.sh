#!/usr/bin/env bash
# The HTTP transport, shared by every driver that talks to an API rather than a
# CLI (P87 stage 2). Sourced, never executed.
#
# WHY THIS EXISTS. The GitLab driver runs `glab`, which supplies auth, host
# resolution and project resolution for free. Most trackers have no such tool:
# Linear is GraphQL over HTTPS and nothing else, and every driver after it will
# be the same. That leaves four jobs which are easy to get wrong once each and
# catastrophic to get wrong in several files, so they are done here.
#
#   1. THE CREDENTIAL NEVER REACHES ARGV. `curl -H "Authorization: $TOKEN"`
#      puts the token in the process table, where any user on the machine can
#      read it with `ps`; in any shell trace; and — the one that matters most
#      here — in the captured argv this skill's own test suite writes to disk
#      and greps. The token goes into a `curl --config` file created at mode
#      600 and deleted on exit. Everything below reads it from there.
#   2. FAILURE IS NON-ZERO AND SILENT ON STDOUT. Every caller in loom is
#      fail-closed: `snapshot` degrades deliberately at its own call site, and
#      the lane guards refuse rather than guess. A transport that printed a
#      partial body, or an empty list, would take those decisions away from
#      them.
#   3. GRAPHQL ERRORS ARE NOT STATUS CODES. A GraphQL endpoint answers a failed
#      query with HTTP 200 and an `errors` array. A driver that reads the status
#      code alone reports success on failure, every time.
#   4. RETRIES AND RATE LIMITS IN ONE PLACE. An API-backed board has an hourly
#      cap where a CLI-backed one had wall clock. Backoff belongs with the
#      request, not scattered through twenty verbs.
#
# Test seam: CURL_CMD.

CURL="${CURL_CMD:-curl}"
HTTP_RETRIES="${LOOM_HTTP_RETRIES:-3}"

# Called once by a driver, before any request. Explicitly, rather than at source
# time: this creates a file and installs a trap, and a sourced file that does
# either is a file no other script can safely share.
_http_init() { # <token-env-var-name> <header-name> <who is asking>
    local var="$1" hdr="$2" who="${3:-loom}" tok
    eval "tok=\${$var:-}"
    [ -n "$tok" ] \
        || die "$who: \$$var is not set — this driver authenticates with a personal
  API key held in that environment variable, and there is no CLI to fall back on.
  Export it in the environment the loop runs in (a launchd agent does not read
  your shell profile)."
    HTTP_TMP=$(mktemp -d)
    trap 'rm -rf "$HTTP_TMP"' EXIT
    HTTP_CFG="$HTTP_TMP/curl.cfg"
    ( umask 077; : > "$HTTP_CFG" )
    # A heredoc, so the token is never an argument to anything. `printf` is a
    # bash builtin and would also be safe, but "never an argument" is a rule
    # that survives someone changing the tool; "safe because this one is a
    # builtin" is not.
    cat >> "$HTTP_CFG" <<EOF
header = "$hdr: $tok"
silent
show-error
EOF
}

# One request. The body goes to stdout only on success; on failure stdout is
# empty and the reason is on stderr, which is what every caller's `2>/dev/null`
# plus rc check is already written against.
_http_request() { # <method> <url> [--data-file F] → response body
    local method="$1" url="$2" data="" attempt=0 code body_f err_f
    shift 2
    case "${1:-}" in --data-file) data="${2:-}"; shift 2 ;; esac
    [ -n "${HTTP_CFG:-}" ] || die "http: _http_init was never called"
    body_f="$HTTP_TMP/body"; err_f="$HTTP_TMP/err"
    while :; do
        attempt=$((attempt + 1))
        code=$("$CURL" --config "$HTTP_CFG" --request "$method" \
                   ${data:+--data-binary "@$data"} \
                   --header 'Content-Type: application/json' \
                   --output "$body_f" --write-out '%{http_code}' \
                   "$url" 2>"$err_f") || code=000
        case "$code" in
            2*) cat "$body_f"; return 0 ;;
            # 429 is the rate limit and 5xx is the server having a moment;
            # `000` is curl never getting an answer at all. All three are worth
            # asking again. Everything else — 401, 403, 404, 422 — is an answer,
            # and repeating the question will not change it.
            429|5*|000)
                [ "$attempt" -lt "$HTTP_RETRIES" ] || break
                sleep $((attempt * attempt)) ;;
            *)  break ;;
        esac
    done
    echo "http: $method $url failed (HTTP $code)$(
        [ -s "$err_f" ] && printf ' — %s' "$(head -1 "$err_f")"
        [ -s "$body_f" ] && printf ' — %s' "$(head -c 300 "$body_f" | tr '\n' ' ')"
    )" >&2
    return 1
}

# A GraphQL call. Returns `.data`, or fails — there is no third outcome, which
# is the whole point of routing every query through here.
_graphql() { # <query> [<variables-json>] → the `data` object
    local q="$1" vars="${2:-}" req resp msg
    [ -n "$vars" ] || vars='{}'
    [ -n "${GRAPHQL_URL:-}" ] || die "http: GRAPHQL_URL is not set"
    req="$HTTP_TMP/req.json"
    jq -n --arg q "$q" --argjson v "$vars" '{query: $q, variables: $v}' > "$req" \
        || { echo "graphql: could not build the request body" >&2; return 1; }
    resp=$(_http_request POST "$GRAPHQL_URL" --data-file "$req") || return 1
    # HTTP 200 with a non-empty `errors` array is a FAILURE. Reported by name,
    # because the messages are the only thing that distinguishes a bad query
    # from a missing permission from a deleted issue.
    if printf '%s' "$resp" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
        msg=$(printf '%s' "$resp" | jq -r '[.errors[].message] | join("; ")' 2>/dev/null)
        echo "graphql: ${msg:-the API returned errors}" >&2
        return 1
    fi
    printf '%s' "$resp" | jq -e '.data != null' >/dev/null 2>&1 \
        || { echo "graphql: the response carried no data" >&2; return 1; }
    printf '%s' "$resp" | jq '.data'
}
