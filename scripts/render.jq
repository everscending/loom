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
        select(.type == "assistant" or .type == "result"
               or (.type == "system" and (.subtype // "") == "init"))
        | if .type == "system" then
              "── model \(.model // "?") · permission \(.permissionMode // "?") ──"
          elif .type == "result" then
              (if (.is_error // false) or ((.subtype // "success") != "success")
               then "\n[lane failed: \(.subtype // "error")] \(.result // "")"
               else empty end)
          else
              (.message.content[]?
               | if .type == "text" then .text
                 elif .type == "tool_use" then
                     "  $ \(.name): \(((.input.command // .input.file_path // .input.pattern // "") | tostring)[0:200])"
                 else empty end)
          end
