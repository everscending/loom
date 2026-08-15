# usage.jq — the provider-reported dollar cost of one canonical session log.
# Unknown cost stays null; Loom never estimates from model names.
#
# Lifted out of tick.sh (P71), where it lived as USAGE_JQ, a single-quoted
# shell string. In a file it is checkable with
# `jq -L . -n -f usage.jq </dev/null`.
#
# No --arg/--argjson bindings; reads a raw session log (jsonl, one record per
# line) off stdin via -R -s. The prelude include is uniform across every jq
# program here (P72), not a dependency this one has yet.
include "lib";
split("\n") | map(select(length > 0) | (try fromjson catch empty))
| map(select(.type == "usage" and .cost_usd != null) | .cost_usd)
| if length == 0 then null else add end
