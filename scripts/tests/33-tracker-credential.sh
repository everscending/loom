#!/usr/bin/env bash
# P88: the tracker credential has somewhere durable to live
#
# Section 33 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
#
# A CLI-driven tracker owns its own auth and loom never sees a token. An
# HTTP-driven one has no such place, and the environment its key must appear in
# is the launchd agent's — every tracker call in a build descends from that one
# process, and environment only travels downward. The plist carries a fixed
# four-key dict, so the only route was `launchctl setenv`: machine-wide, and
# gone after a reboot. What follows a reboot is the silent skipped wave this
# skill has already paid for once. These tests are about the file that replaces
# it, and about the one rule that makes the file safe.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

SD="$(cd "$(dirname "$TICK")" && pwd)"
BOOT="$SD/bootstrap.sh"
TD="$T/p88"; mkdir -p "$TD"

mkrepo88() { # mkrepo88 <dir> <tracker> [remote]
    mkdir -p "$1"
    git -C "$1" init -q >/dev/null 2>&1
    git -C "$1" config user.email loom@test >/dev/null 2>&1
    git -C "$1" config user.name loom >/dev/null 2>&1
    [ -n "${3:-}" ] && git -C "$1" remote add origin "$3" >/dev/null 2>&1
    seed_tracker_decl "$1" "$2"
    return 0
}
SECRET='lin_api_D0_NOT_LEAK#42'
mkrepo88 "$TD/lin" Linear https://github.com/acme/app.git
mkrepo88 "$TD/gl" GitLab

# --- p88-1. The reader ------------------------------------------------------
# `#` is an ordinary character in a token, so unlike every other value this
# skill reads out of YAML, a secret is taken whole — truncating a credential at
# a `#` would be a failure nobody could read off the file.
printf 'max_lanes: 4\n\nsecrets:\n  LINEAR_API_KEY: "%s"\n  OTHER_KEY: plain\n\nntfy:\n  topic: t\n' \
    "$SECRET" > "$TD/global.yml"
got=$(bash -c '. "$1"; _load_secrets global "$2"; printf "%s" "$LINEAR_API_KEY"' _ "$SD/lib.sh" "$TD/global.yml")
[ "$got" = "$SECRET" ] \
    && ok "secrets: the value is read whole — quotes off, and a '#' inside it survives" \
    || bad "secrets: the value came back as '$got'"
got=$(bash -c '. "$1"; _load_secrets global "$2"; printf "%s" "$OTHER_KEY"' _ "$SD/lib.sh" "$TD/global.yml")
[ "$got" = plain ] \
    && ok "secrets: an unquoted value reads too, and the block is a map rather than one key" \
    || bad "secrets: the second key did not load ('$got')"
# Keys outside the block are not secrets, and the block ends where the
# indentation does.
got=$(bash -c '. "$1"; _load_secrets global "$2"; printf "[%s]" "${topic:-}"' _ "$SD/lib.sh" "$TD/global.yml")
[ "$got" = "[]" ] \
    && ok "secrets: the block ends at the next top-level key — 'ntfy:' below it exports nothing" \
    || bad "secrets: something outside the secrets block was exported ($got)"

# --- p88-2. The real environment wins ---------------------------------------
# So a one-off override still works, and CI — which supplies its own — is
# untouched by any of this.
got=$(LINEAR_API_KEY=from-env bash -c '. "$1"; _load_secrets global "$2"; printf "%s %s" "$LINEAR_API_KEY" "$(_secret_source LINEAR_API_KEY)"' \
        _ "$SD/lib.sh" "$TD/global.yml")
[ "$got" = "from-env environment" ] \
    && ok "secrets: a variable already set is left alone, and reported as coming from the environment" \
    || bad "secrets: the file overwrote a live environment variable ($got)"

# --- p88-3. The most specific file wins -------------------------------------
# Which is what lets two repos on one machine reach two different workspaces,
# with no second mechanism: the state directory is already per-repo and already
# outside every working tree.
printf 'secrets:\n  LINEAR_API_KEY: from-repo-state\n' > "$TD/repo-state.yml"
got=$(bash -c '. "$1"; _load_secrets repo-state "$3" global "$2"; printf "%s %s" "$LINEAR_API_KEY" "$(_secret_source LINEAR_API_KEY)"' \
        _ "$SD/lib.sh" "$TD/global.yml" "$TD/repo-state.yml")
[ "$got" = "from-repo-state repo-state" ] \
    && ok "secrets: this repo's own config beats the machine-wide one, and says so" \
    || bad "secrets: the global config won over the repo's own ($got)"

# --- p88-4. The load-bearing refusal ----------------------------------------
# `.loom.yml` is COMMITTED. This whole mechanism is only safe because the
# committed layer can never carry a credential, so the refusal is loud, by name,
# and in every one of the three scripts — a lane that accepted what tick.sh
# refused would be the hole.
printf 'max_lanes: 2\nsecrets:\n  LINEAR_API_KEY: %s\n' "$SECRET" > "$TD/lin/.loom.yml"
E88() { LOOM_REPO="$TD/lin" LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/global.yml" "$@"; }
for who in "$TICK:snapshot" "$LANE:transition 7 review" "$BOOT:all"; do
    bin="${who%%:*}"; args="${who#*:}"
    out=$(E88 "$bin" $args 2>&1); rc=$?
    if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "COMMITTED"; then
        ok "committed-secret: $(basename "$bin") refuses a 'secrets:' block in .loom.yml"
    else
        bad "committed-secret: $(basename "$bin") accepted a committed credential (rc=$rc, out=$(printf '%s' "$out" | head -1))"
    fi
done
# And it says to rotate the key, because it has already been written to a
# tracked file — removing it from the working copy does not unwrite it.
out=$(E88 "$TICK" snapshot 2>&1 || true)
printf '%s' "$out" | grep -q "rotate" \
    && ok "committed-secret: the refusal says to rotate the key, not merely to move it" \
    || bad "committed-secret: the refusal treats a leaked key as recoverable by moving it"
# The refusal is what produced that, not some unrelated failure: the same repo
# with the block removed proceeds.
printf 'max_lanes: 2\n' > "$TD/lin/.loom.yml"
out=$(E88 "$TICK" snapshot 2>&1 || true)
printf '%s' "$out" | grep -q "COMMITTED" \
    && bad "guard-violation: the refusal fires even without a secrets block" \
    || ok "guard-violation: with the block gone the refusal stops — it is the block that caused it"

# --- p88-5. `install` refuses to arm a build that cannot read its board -----
# The whole point. A missing key fails the first snapshot, the board classifies
# `unknown`, and the timer's own allowlist skips every wave — the identical
# silent stall as a sleeping laptop, with a `tick_skipped` event naming the
# symptom rather than the cause. A refusal is visible; that stall is not.
printf 'max_lanes: 4\n' > "$TD/nokey.yml"
out=$(LOOM_REPO="$TD/lin" LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/nokey.yml" \
      LINEAR_API_KEY= LOOM_PLIST_DIR="$TD/agents" "$TICK" install 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "LINEAR_API_KEY"; then
    ok "install: refuses to arm a Linear build with no credential, naming the variable"
else
    bad "install: armed a build that cannot read its own board (rc=$rc, out=$(printf '%s' "$out" | head -1))"
fi
n=$(ls "$TD/agents" 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 0 ] \
    && ok "install: and it wrote no plist — nothing is armed, so nothing stalls silently" \
    || bad "install: $n file(s) landed in the agents directory despite the refusal"
# It names both places the key may live, and neither of them is .loom.yml.
out=$(LOOM_REPO="$TD/lin" LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/nokey.yml" \
      LINEAR_API_KEY= LOOM_PLIST_DIR="$TD/agents" "$TICK" install 2>&1 || true)
if printf '%s' "$out" | grep -q "secrets:" && printf '%s' "$out" | grep -q ".loom.yml"; then
    ok "install: the refusal shows the exact block to write, and warns off the committed file"
else
    bad "install: the refusal does not say what to do about it"
fi
# A GitLab repo needs no credential at all — `glab` owns its own token — so the
# preflight must not invent a requirement for it.
out=$(LOOM_REPO="$TD/gl" LOOM_HOME="$TD/home-gl" LOOM_GLOBAL_CONFIG="$TD/nokey.yml" \
      LOOM_PLIST_DIR="$TD/agents-gl" LAUNCHCTL_CMD=true "$TICK" install 2>&1); rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q "LINEAR_API_KEY"; then
    ok "install: a CLI-driven tracker arms without one — its own tool owns the token"
else
    bad "install: a GitLab repo did not arm cleanly (rc=$rc, out=$(printf '%s' "$out" | head -1))"
fi
# The counterfactual for the refusal above: the SAME Linear repo, with the key
# supplied, gets past the credential check. Otherwise "it refused" would only
# prove that arming a Linear repo fails for some other reason.
out=$(LOOM_REPO="$TD/lin" LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/global.yml" \
      LOOM_PLIST_DIR="$TD/agents-lin" LAUNCHCTL_CMD=true "$TICK" install 2>&1); rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q "LINEAR_API_KEY"; then
    ok "install: with the key in the config file the same repo arms — the credential is what refused it"
else
    bad "install: it refused even with a credential supplied (rc=$rc, out=$(printf '%s' "$out" | head -1))"
fi

# --- p88-6. The value never reaches a wave prompt ---------------------------
# `resolve-config` output is pasted into every session prompt, so it reports
# presence and origin and nothing else.
rc_json=$(LOOM_REPO="$TD/lin" LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/global.yml" \
          "$TICK" resolve-config 2>/dev/null)
if printf '%s' "$rc_json" | jq -e '.credential.name == "LINEAR_API_KEY"
                                   and .credential.present == true
                                   and .credential.source == "global"' >/dev/null 2>&1; then
    ok "resolve-config: it reports the credential's name, presence and origin"
else
    bad "resolve-config: credential missing or wrong ($(printf '%s' "$rc_json" | jq -c '.credential' 2>/dev/null))"
fi
printf '%s' "$rc_json" | grep -q "$SECRET" \
    && bad "resolve-config: THE KEY ITSELF is in the output, which is pasted into every wave prompt" \
    || ok "resolve-config: the value appears nowhere in the output"
# Absent is reported honestly rather than as an error: this verb is how the
# install refusal gets diagnosed.
rc_json=$(LOOM_REPO="$TD/lin" LOOM_HOME="$TD/home" LOOM_GLOBAL_CONFIG="$TD/nokey.yml" \
          LINEAR_API_KEY= "$TICK" resolve-config 2>/dev/null)
printf '%s' "$rc_json" | jq -e '.credential.present == false and .credential.name == "LINEAR_API_KEY"' >/dev/null 2>&1 \
    && ok "resolve-config: a missing credential is reported, not hidden — this is how the refusal is diagnosed" \
    || bad "resolve-config: the absent case was not reported ($(printf '%s' "$rc_json" | jq -c '.credential' 2>/dev/null))"
# A GitLab repo has no credential to report, and says so with an empty name
# rather than a false alarm.
rc_json=$(LOOM_REPO="$TD/gl" LOOM_HOME="$TD/home-gl" LOOM_GLOBAL_CONFIG="$TD/nokey.yml" \
          "$TICK" resolve-config 2>/dev/null)
printf '%s' "$rc_json" | jq -e '.credential.name == ""' >/dev/null 2>&1 \
    && ok "resolve-config: a CLI-driven tracker reports no credential rather than a missing one" \
    || bad "resolve-config: a GitLab repo was reported as needing a key"

# --- p88-7. The key reaches the driver, and only through the file ----------
# End to end, and the assertion the rest of this section exists to support: a
# key written ONLY to the global config authenticates a real driver call, with
# nothing exported by hand anywhere.
cat > "$TD/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --config) cp "$2" "${CFG_COPY:?}"; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"data":{"viewer":{"id":"u","name":"n","displayName":"N"}}}' > "$out"
echo 200
EOF
chmod +x "$TD/curl"
: > "$TD/cfg.copy"
env -u LINEAR_API_KEY LOOM_REPO="$TD/lin" LOOM_HOME="$TD/home" \
    LOOM_GLOBAL_CONFIG="$TD/global.yml" CURL_CMD="$TD/curl" CFG_COPY="$TD/cfg.copy" \
    "$LANE" claim 7 >/dev/null 2>&1 || true
if grep -qF "$SECRET" "$TD/cfg.copy"; then
    ok "end to end: a key written only to the config file reaches the driver's authenticated call"
else
    bad "end to end: the credential never reached the driver (cfg=$(head -c 60 "$TD/cfg.copy"))"
fi
# The counterfactual: with the config file empty of secrets, the same call fails
# for want of a key. Without this, the assertion above could be passing on a
# credential that arrived some other way.
: > "$TD/cfg.copy"
# Asserted at `snapshot` rather than at the lane verb above, because this is
# the exact chain P88 is about: the board read fails, and what a human sees has
# to name the credential rather than the symptom.
out=$(env -u LINEAR_API_KEY LOOM_REPO="$TD/lin" LOOM_HOME="$TD/home" \
      LOOM_GLOBAL_CONFIG="$TD/nokey.yml" CURL_CMD="$TD/curl" \
      "$TICK" snapshot 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "LINEAR_API_KEY"; then
    ok "end to end: and with the file emptied the board read fails naming the variable — the file is the source"
else
    bad "end to end: the board was read with no key anywhere (rc=$rc, out=$(printf '%s' "$out" | head -1))"
fi

# --- p88-8. bootstrap warns about a readable credential store --------------
# The mechanism is only better than `launchctl setenv` if the file is not
# readable by everyone. A warning rather than a silent chmod: the file is the
# human's, and quietly changing its mode teaches nobody anything.
cp "$TD/global.yml" "$TD/loose.yml"; chmod 644 "$TD/loose.yml"
out=$(LOOM_REPO="$TD/gl" LOOM_HOME="$TD/home-gl" LOOM_GLOBAL_CONFIG="$TD/loose.yml" \
      TRACKER_CMD=/usr/bin/true "$BOOT" global-config 2>&1 || true)
printf '%s' "$out" | grep -q "chmod 600" \
    && ok "permissions: a world-readable secrets file is warned about, with the fix in the message" \
    || bad "permissions: a 644 credential store passed unremarked"
chmod 600 "$TD/loose.yml"
out=$(LOOM_REPO="$TD/gl" LOOM_HOME="$TD/home-gl" LOOM_GLOBAL_CONFIG="$TD/loose.yml" \
      TRACKER_CMD=/usr/bin/true "$BOOT" global-config 2>&1 || true)
printf '%s' "$out" | grep -q "chmod 600" \
    && bad "permissions: it warns even at 600 — the check is not reading the mode" \
    || ok "permissions: at 600 it says nothing, so the warning tracks the mode rather than the block"
# And the file bootstrap seeds itself is created at 600, because it is exactly
# where the human is then told to put the key.
rm -f "$TD/fresh.yml"
LOOM_REPO="$TD/gl" LOOM_HOME="$TD/home-gl" LOOM_GLOBAL_CONFIG="$TD/fresh.yml" \
    TRACKER_CMD=/usr/bin/true "$BOOT" global-config >/dev/null 2>&1 || true
case "$(ls -l "$TD/fresh.yml" 2>/dev/null | cut -c1-10)" in
    -rw-------) ok "permissions: the config bootstrap seeds is created at 600" ;;
    *)          bad "permissions: the seeded config is $(ls -l "$TD/fresh.yml" 2>/dev/null | cut -c1-10)" ;;
esac

test_finish
