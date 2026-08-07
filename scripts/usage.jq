# usage.jq — the dollar cost of one session log (P55), priced by each
# assistant message's own model off `message.usage`. Source: claude-api skill
# pricing cache, read 2026-08-06 — $/MTok, cache write assumed at the 5m
# ephemeral default (the harness never requests a 1h breakpoint). Re-derive
# this table whenever pricing changes; nothing else in the skill depends on
# the literal numbers.
#
# Lifted out of tick.sh (P71), where it lived as USAGE_JQ, a single-quoted
# shell string. In a file it is checkable with `jq -n -f usage.jq </dev/null`.
#
# No --arg/--argjson bindings; reads a raw session log (jsonl, one record per
# line) off stdin via -R -s.
  def price_table:
    { "haiku-4-5": {input: 1.00,  output: 5.00,  cache_write: 1.25,  cache_read: 0.10},
      "sonnet-5":  {input: 3.00,  output: 15.00, cache_write: 3.75,  cache_read: 0.30},
      "opus-5":    {input: 5.00,  output: 25.00, cache_write: 6.25,  cache_read: 0.50},
      "fable-5":   {input: 10.00, output: 50.00, cache_write: 12.50, cache_read: 1.00} };
  # An unrecognised or missing model prices at zero rather than guessing —
  # a silently wrong non-zero number is worse than a visible gap.
  def price_for($model):
    (price_table | to_entries | map(select(.key as $k | $model | test($k))) | first | .value)
    // {input: 0, output: 0, cache_write: 0, cache_read: 0};
  def usage_cost($u; $model):
    price_for($model) as $p
    | ( ($u.input_tokens // 0) * $p.input
      + ($u.output_tokens // 0) * $p.output
      + (($u.cache_creation_input_tokens //
          (($u.cache_creation.ephemeral_5m_input_tokens // 0)
           + ($u.cache_creation.ephemeral_1h_input_tokens // 0))) // 0) * $p.cache_write
      + ($u.cache_read_input_tokens // 0) * $p.cache_read
      ) / 1000000;
  split("\n") | map(select(length > 0))
  | map(try fromjson catch empty) | map(select(. != null))
  | map(select(.type == "assistant") | .message | select(.usage != null))
  | map(usage_cost(.usage; (.model // "")))
  | add // 0
