#!/usr/bin/env bash
# P48: the wave prompt is generated, not hand-maintained
#
# Section 22 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- P48: the wave prompt is generated, not hand-maintained ----------------
# The injected context is prefaced "trust it over rediscovery", so wherever it
# contradicts SKILL.md it wins, from inside the session. Hand-maintained, it
# went five verbs stale, told merge lanes to finish with `close` (the build-1
# merge-1 failure `cmd_merge` was written to end and `cmd_close` now refuses),
# and pinned every lane to a flat `--model <lane_model>` — outranking the
# per-ticket escalation `snapshot` resolves into `.model.effective`, so a
# rework round ran on the tier that had just failed it.
WP="$T/waveprompt"; mkdir -p "$WP/repo" "$WP/bin"
printf 'lane_model: sonnet\n' > "$WP/repo/.loom.yml"
wave_prompt() { # wave_prompt <tick.sh> → the context that tick injected
    : > "$WP/prompt.txt"
    LOOM_HOME="$WP/home" LOOM_REPO="$WP/repo" \
      LOOM_WAVE_CMD="sh -c 'printf %s \"\$LOOM_WAVE_PROMPT\" > $WP/prompt.txt'" \
      "$1" tick >/dev/null 2>&1
    cat "$WP/prompt.txt"
}
LANE_SH="$(cd "$(dirname "$TICK")" && pwd)/lane.sh"
WPROMPT=$(wave_prompt "$TICK")
# The roster is read out of lane.sh, so it equals what lane.sh actually
# dispatches. Compared as a SET: usage order and dispatch order differ and
# neither is a contract.
injected=$(printf '%s\n' "$WPROMPT" | sed -n 's/.*(verbs: \([^;]*\);.*/\1/p' \
           | tr ',' '\n' | tr -d ' ' | sort | tr '\n' ' ')
dispatched=$(grep -E '^[[:space:]]+[a-z][a-z-]*\)[[:space:]]*shift; cmd_' "$LANE_SH" \
             | sed 's/).*//' | tr -d ' ' | sort | tr '\n' ' ')
if [ -n "$dispatched" ] && [ "$injected" = "$dispatched" ]; then
    ok "P48: the injected verb roster equals lane.sh's own verb list"
else
    bad "P48: verb roster drifted — injected [$injected] vs dispatched [$dispatched]"
fi
# The model is per ticket. A configured lane_model must not reach the prompt as
# a flat flag, and the prompt must send the wave to the snapshot for it.
case "$WPROMPT" in
  *"--model sonnet"*) bad "P48: the flat lane_model flag is back in the wave prompt" ;;
  *".model.effective"*) ok "P48: the prompt derives the model per ticket, not one flag for all lanes" ;;
  *) bad "P48: the prompt names neither .model.effective nor a model at all" ;;
esac
# Which verb finishes a merge is a decision, and decisions live in SKILL.md.
case "$WPROMPT" in
  *"lane.sh close"*) bad "P48: the prompt still tells lanes how to finish a merge" ;;
  *) ok "P48: the prompt says nothing about which verb finishes a merge" ;;
esac
# The failing side: with the derivation removed the list could only be a
# restatement. A doctored lane.sh proves it is read — a verb this suite has
# never heard of reaches the prompt intact.
cp "$TICK" "$WP/bin/tick.sh"
cp "$(dirname "$TICK")/snapshot.jq" "$WP/bin/snapshot.jq" 2>/dev/null || :
cp "$(dirname "$TICK")/lib.sh" "$WP/bin/lib.sh" 2>/dev/null || :   # P73 sibling
cp "$(dirname "$TICK")/lib.jq" "$WP/bin/lib.jq" 2>/dev/null || :   # P72 sibling
cat > "$WP/bin/lane.sh" <<'EOF'
#!/usr/bin/env bash
echo "lane.sh: usage: lane.sh frobnicate <iid> | verdict <iid> pass|fail <sha> | wait-ready --timeout <secs> (--url <url> | -- <cmd...>)" >&2
exit 2
EOF
chmod +x "$WP/bin/lane.sh"
FAKEP=$(wave_prompt "$WP/bin/tick.sh")
fake=$(printf '%s\n' "$FAKEP" | sed -n 's/.*(verbs: \([^;]*\);.*/\1/p')
if [ "$fake" = "frobnicate, verdict, wait-ready" ]; then
    ok "P48: the roster follows lane.sh — a made-up verb list is injected verbatim"
else
    bad "P48: roster is not derived from lane.sh (got [$fake])"
fi

test_finish
