# render.jq — the lane-log renderer: raw session JSONL down to the two things
# anyone reads a lane log for, assistant prose and the commands it ran.
#
# Lifted out of tick.sh (P71), where it lived as RENDER_JQ, a single-quoted
# shell string. In a file it is checkable with
# `jq -L . -n -f render.jq </dev/null`. Shared by the one-shot render
# (`render-log <id>`) and the follower (`render-log <id> --follow`) so a live
# view and the saved transcript can never disagree about what the lane said.
#
# No --arg/--argjson bindings; reads session records straight off stdin or a
# file, one JSON object per input line. The prelude include is uniform across
# every jq program here (P72), not a dependency this one has yet.
include "lib";
select((.schema // 0) == 1)
| if .type == "session_start" then
    "── provider \(.provider) · \(.job) · tier \(.requested_tier) · model \(.resolved_profile.model // "?")\(if .resolved_profile.reasoning_effort then " · reasoning " + .resolved_profile.reasoning_effort else "" end) ──"
  elif .type == "assistant_progress" then (.text // empty)
  elif .type == "tool_progress" then "  $ \(.tool // "tool"): \((.summary // "")[0:200])"
  elif .type == "error" then "\n[session error: \(.category // "error")] \(.message // "")"
  elif .type == "session_end" and .status != "success" then "\n[session ended: \(.status), rc \(.rc)]"
  else empty end
