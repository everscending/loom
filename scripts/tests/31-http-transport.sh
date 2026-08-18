#!/usr/bin/env bash
# P87 stage 2: the HTTP transport, shared
#
# Section 31 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
#
# The GitLab driver runs `glab`, which supplies auth and host resolution for
# free. Most trackers have no such tool — Linear is GraphQL over HTTPS and
# nothing else — so those drivers talk to `curl`, and four things that are easy
# to get wrong once each are done in one file instead. These are the four.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

SD="$(cd "$(dirname "$TICK")" && pwd)"
LIN="$SD/trackers/linear.sh"
TD="$T/p87http"; mkdir -p "$TD"

# A curl stub. It records every argument it was given, which is the whole point
# of the first assertion, and answers whatever the case below decides.
mkstub() { # mkstub <path> <http-code> <body-file-or-'-'>
    cat > "$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "\${CURL_LOG:-/dev/null}"
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --output) out="\$2"; shift 2 ;;
    --config) cp "\$2" "\${CFG_COPY:-/dev/null}" 2>/dev/null; shift 2 ;;
    *) shift ;;
  esac
done
[ "$3" = "-" ] || cat "$3" > "\$out"
[ "$2" = "000" ] && exit 7
echo "$2"
EOF
    chmod +x "$1"
}

RUN() { # RUN <curl-stub> [extra env assignments handled by caller] -- <verb...>
    local stub="$1"; shift
    LINEAR_API_KEY="$SECRET" CURL_CMD="$stub" CURL_LOG="$TD/curl.log" \
        CFG_COPY="$TD/cfg.copy" LOOM_REPO="$TD/repo" LOOM_HTTP_RETRIES=2 "$LIN" "$@"
}

SECRET='lin_api_THIS_MUST_NEVER_APPEAR_IN_ARGV'
mkdir -p "$TD/repo/docs/agents"
git -C "$TD/repo" init -q >/dev/null 2>&1
printf '# Issue tracker: Linear\nTeam: ENG\n' > "$TD/repo/docs/agents/issue-tracker.md"
git -C "$TD/repo" add -A >/dev/null 2>&1

# --- p87-h1. The credential never reaches argv -----------------------------
# `curl -H "Authorization: $TOKEN"` puts the token in the process table, where
# any user on the machine reads it with `ps`; in any shell trace; and in exactly
# the captured argv this suite writes to disk. It goes in a --config file
# instead, at mode 600.
printf '{"data":{"viewer":{"id":"u1","name":"n","displayName":"N"}}}' > "$TD/viewer.json"
mkstub "$TD/curl-ok" 200 "$TD/viewer.json"
: > "$TD/curl.log"; : > "$TD/cfg.copy"
RUN "$TD/curl-ok" whoami >/dev/null 2>&1 || true
[ -s "$TD/curl.log" ] \
    && ok "transport: the stub really was called — the scan below reads a non-empty argv log" \
    || bad "transport: curl was never invoked, so the secret scan proves nothing"
grep -q "$SECRET" "$TD/curl.log" \
    && bad "transport: the API key appeared in argv — it is readable by ps and it is now on disk in this log" \
    || ok "transport: the API key appears nowhere in argv"
grep -q "$SECRET" "$TD/cfg.copy" \
    && ok "transport: it travelled in the --config file instead, which is where it belongs" \
    || bad "transport: the key never reached the config file either, so the request would not authenticate"
# And the config file is not world-readable while it exists.
cat > "$TD/curl-perm" <<'EOF'
#!/usr/bin/env bash
out=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in --output) out="$2"; shift 2 ;; --config) cfg="$2"; shift 2 ;; *) shift ;; esac
done
ls -l "$cfg" | cut -c1-10 > "${PERM_OUT:?}"
printf '{"data":{"viewer":{"id":"u1","name":"n"}}}' > "$out"
echo 200
EOF
chmod +x "$TD/curl-perm"
PERM_OUT="$TD/perm.txt" LINEAR_API_KEY="$SECRET" CURL_CMD="$TD/curl-perm" \
    LOOM_REPO="$TD/repo" "$LIN" whoami >/dev/null 2>&1 || true
case "$(cat "$TD/perm.txt" 2>/dev/null)" in
    -rw-------*) ok "transport: the config file holding the key is mode 600 while it exists" ;;
    *)           bad "transport: the config file's mode is $(cat "$TD/perm.txt" 2>/dev/null) — the key is readable by others" ;;
esac
# It does not outlive the process.
LEFT=$(find "${TMPDIR:-/tmp}" -maxdepth 2 -name 'curl.cfg' -newer "$TD/perm.txt" 2>/dev/null | head -1)
[ -z "$LEFT" ] \
    && ok "transport: and it is gone when the driver exits — no credential left in a temp directory" \
    || bad "transport: a curl config file survived the run ($LEFT)"

# --- p87-h2. A missing key is a refusal, not a request ---------------------
out=$(CURL_CMD="$TD/curl-ok" LOOM_REPO="$TD/repo" LINEAR_API_KEY= "$LIN" whoami 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "LINEAR_API_KEY" \
    && ok "transport: with no key it refuses by name, rather than making an unauthenticated call" \
    || bad "transport: a missing API key was not refused (rc=$rc)"
# But the roster still prints: the one message explaining this driver must be
# reachable by someone who has not set the key up yet.
out=$(LOOM_REPO="$TD/repo" LINEAR_API_KEY= "$LIN" 2>&1 || true)
printf '%s' "$out" | grep -q "usage: linear.sh" \
    && ok "transport: and the usage roster still prints without a key" \
    || bad "transport: the usage path demanded a credential"

# --- p87-h3. A GraphQL error arrives with HTTP 200 -------------------------
# This is the one a driver reading the status code alone gets wrong every time:
# the request succeeded, the query did not.
printf '{"errors":[{"message":"Entity not found: Issue"}],"data":null}' > "$TD/err.json"
mkstub "$TD/curl-gqlerr" 200 "$TD/err.json"
out=$(RUN "$TD/curl-gqlerr" whoami 2>"$TD/e1"); rc=$?
if [ "$rc" != 0 ] && [ -z "$out" ]; then
    ok "transport: HTTP 200 with an errors array is a FAILURE — non-zero, and nothing on stdout"
else
    bad "transport: a GraphQL error read as success (rc=$rc, stdout=$(printf '%s' "$out" | head -c 60))"
fi
grep -q "Entity not found" "$TD/e1" \
    && ok "transport: and the API's own message is reported, not swallowed" \
    || bad "transport: the error message was lost ($(head -1 "$TD/e1"))"

# --- p87-h4. Transport failure is silent on stdout -------------------------
# Every caller in loom is fail-closed. A transport that printed a partial body,
# or an empty list, would take that decision away from them.
mkstub "$TD/curl-500" 500 "$TD/err.json"
out=$(RUN "$TD/curl-500" whoami 2>/dev/null); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] \
    && ok "transport: a 500 exits non-zero with nothing on stdout" \
    || bad "transport: a 500 produced output or succeeded (rc=$rc)"
mkstub "$TD/curl-dead" 000 -
out=$(RUN "$TD/curl-dead" whoami 2>/dev/null); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] \
    && ok "transport: curl never reaching the host is the same shape — non-zero, silent" \
    || bad "transport: an unreachable host produced output or succeeded (rc=$rc)"

# Retries are bounded, and only for the answers worth asking again.
: > "$TD/curl.log"
RUN "$TD/curl-500" whoami >/dev/null 2>&1 || true
n=$(grep -c -- '--config' "$TD/curl.log")
[ "$n" = 2 ] \
    && ok "transport: a 5xx is retried up to the cap and then stops (2 attempts at LOOM_HTTP_RETRIES=2)" \
    || bad "transport: a 5xx produced $n attempts, not the 2 the cap allows"
printf '{"errors":[{"message":"nope"}]}' > "$TD/e404.json"
mkstub "$TD/curl-404" 404 "$TD/e404.json"
: > "$TD/curl.log"
RUN "$TD/curl-404" whoami >/dev/null 2>&1 || true
n=$(grep -c -- '--config' "$TD/curl.log")
[ "$n" = 1 ] \
    && ok "transport: a 404 is an ANSWER and is not retried — asking again cannot change it" \
    || bad "transport: a 404 was retried $n times"

# --- p87-h5. A real caller's fail-closed path still fires ------------------
# Asserted against a caller rather than the helper in isolation: the guarantee
# is only worth anything where a decision gets made on it. `snapshot`'s stage-1
# read is foundational — an empty ticket list from a failed call reads exactly
# like a genuinely empty build, and launching a wave on that is how ghost gates
# happen — so it must die rather than degrade.
mkdir -p "$TD/lrepo/docs/agents"
git -C "$TD/lrepo" init -q >/dev/null 2>&1
git -C "$TD/lrepo" remote add origin https://github.com/acme/app.git >/dev/null 2>&1
printf '# Issue tracker: Linear\nTeam: ENG\n' > "$TD/lrepo/docs/agents/issue-tracker.md"
git -C "$TD/lrepo" add -A >/dev/null 2>&1
out=$(LINEAR_API_KEY="$SECRET" CURL_CMD="$TD/curl-500" LOOM_HTTP_RETRIES=1 \
      LOOM_REPO="$TD/lrepo" LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/g.yml" \
      "$TICK" snapshot 2>&1); rc=$?
if [ "$rc" != 0 ] && ! printf '%s' "$out" | jq -e 'has("tickets")' >/dev/null 2>&1; then
    ok "transport: a failing board read takes the snapshot down rather than producing an empty build"
else
    bad "transport: snapshot survived a dead tracker (rc=$rc)"
fi

test_finish
