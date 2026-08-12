# merge-queue.jq — P93's narrow merge-queue read: which ticket merges next,
# and which branch its worktree is checked out on. Same ordering and
# eligibility as plan.jq's step 5 ($queue, $merge_head) — oldest
# `merge-queue` ticket whose merge_attempts is under the cap and whose
# merge_hold is null — computed from a fraction of a full snapshot's
# fan-out: no links, no non-queue MRs, no non-queue comment threads, no
# milestones. Called only from tick.sh's chain-merge, never by a wave and
# never in place of `plan`, which stays the source of truth when a wave
# does run.
#
# Inputs, bound by tick.sh's cmd_snapshot_merge_queue: --slurpfile open
# (this build's open issues, i.e. `issues-open` filtered to $label — the
# same universe snapshot.jq's $members is drawn from), --slurpfile mrs (a
# map iid -> its MRs, queue members only), --slurpfile notes (a map iid ->
# its comment thread, queue members only), --argjson merge_cap, --arg label.
#
# Output: a JSON array of {id, branch}, oldest first, cap-exhausted and
# held tickets already excluded — the head of this array, when non-empty,
# is exactly plan.jq's $merge_head.

include "lib";

($open[0] // []) as $all
| ($mrs[0] // {}) as $M
| ($notes[0] // {}) as $N
| ([$all[] | select((.labels // []) | index($label))]) as $members
| ([$members[] | .id]) as $open_iids
| ([$members[]
    | select(state_of(.labels // []) == "merge-queue")
    | . as $t
    | { id: $t.id,
        branch: ((($M[$t.id | tostring]) // [])
                 | map(select((.state // "") == "open")) | first | .branch // null),
        merge_attempts: merge_attempts_of(($N[$t.id | tostring]) // []),
        merge_hold: merge_hold_of(($N[$t.id | tostring]) // []; $open_iids) }]
   | sort_by(.id)) as $queue
| [$queue[] | select(.merge_attempts < $merge_cap and .merge_hold == null)
            | {id, branch}]
