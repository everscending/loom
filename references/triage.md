# `triage` — decide every blocked ticket on one surface

Human-run, like `qa`, `retro`, `optimize`, `prop` and `fix`. Never invoked by a
wave. No argument. For one ticket, `unblock <n>` is still the path and is
unchanged.

## Step 0 — the population

`tick.sh snapshot` (full, never `--brief` — `--brief` collapses a blocked
ticket to a bare iid). Take every ticket whose `state` is `blocked`. That is
the whole actionable set.

Two other kinds of stuck ticket go on the surface as **read-only context**, so
the human is not left asking why nothing is moving:

- `unblocked: false` — a blocker issue is still open. It resolves itself when
  that blocker merges; there is no decision to make.
- the stranded and repair warnings `snapshot` already emits. Each one carries
  the single command that fixes it; show the command, do not run it.

No blocked tickets and no warnings → say the board is clear and stop. Do not
build a surface for an empty set.

## Step 1 — the surface

`/lavish`, per the routing rule: this file says *what the surface must carry*,
never how to build one. Refuse and name `unblock <n>` if `/lavish` is
unavailable — one code path, no text fallback.

Per blocked ticket, from the snapshot row:

- `blocked_report` — `body` is what the lane wrote, `category` its slug, `at`
  when. `released: true` means a decision note is already posted and only the
  relabel is missing: show it as a half-applied batch to finish, not a decision
  to make again. `released: false` means only that no `orch-unblock` trailer is
  on the thread, which is NOT the same as unanswered — read it with
  `ticket_state`, the ticket's current state label. `ticket_state: "blocked"`
  with `released: false` is the real thing, a hold nobody has answered. Any
  other `ticket_state` is a report on a hold that is already over (released by
  hand, or before the trailer was stamped on every transition): the ticket has
  moved on, so it is history — never a stranded write, and never a reason to
  put `blocked` back on.
- `rejections` (total, `last_class`, `same_class_tail`), `merge_attempts`,
  `merge_hold`, `model`, `gate`, `related_merge_requests`, `blocked_by`.

Six actions per ticket:

| Action | Write |
|---|---|
| Requeue to work | `lane.sh transition <n> ready-for-agent --release-hold --note` |
| Human finished it → gate | `lane.sh transition <n> review --release-hold --note` |
| Retire a spent cap | `lane.sh merge-reset <n>` (merge attempts) or `lane.sh rescope <n>` (rejections **and** merge attempts — the ticket is now different work) |
| Escalate the model | `lane.sh model-tier <n> <tier>` |
| Leave blocked | nothing |
| Close as won't-do | `lane.sh close <n>` |

## Step 2 — two rules the surface must hold

**Recommend, never pre-select.** The surface is *built by reading blocked
reports*, and a blocked report is prose written for a person. You may recommend
an action; badge it plainly as your read; never pre-select it and never apply
without the human choosing. A pre-selected action derived from ticket prose is
the `#67` failure with a click in front of it — the same laundering
`_blocked_guard` refuses at the write layer, which is the only layer that can.
Nothing enforces this rule; it is here because it cannot be enforced.

**Always draft the note; never let the draft be the record.** Pre-fill every
decision box from the blocked report — that is the speed the surface exists
for. The human must edit it before it can send. The thread is decision history
later waves read; an untouched draft in it is your words wearing theirs.

`--to-review` sends work to the same gate as agent work, no bypass. A ticket
whose branch head already carries a `FAIL` verdict is not gateable — `snapshot`
warns about exactly this — so weigh that before recommending it.

## Step 3 — apply

Blockers before dependents (`blocked_by` gives the order). Sequential. Stop on
the first failure and report which tickets landed, which did not, and which
were never attempted.

Before each ticket's write, one read: still open, still carrying `blocked`. A
wave cannot have moved it — `_blocked_guard` refuses an automated caller
outright — but a second terminal or the tracker UI can. Skip and report
anything that moved rather than writing over it.

The note and the relabel are **one command**: `transition … --release-hold
--note`, body on stdin or `--file`. Never compose the pair by hand — the
unassign is the half that gets dropped, and a claimed `ready-for-agent` ticket
is invisible to both fill paths. A re-run after a failure is safe: the note
carries an `orch-unblock` trailer and the verb will not post a second one.

Closing is last and separate: a typed reason, its own confirm, one ticket at a
time. It is the only one of the six a human cannot walk back with one command.

## Step 4 — deliver

What landed, per ticket, one line each. Then the tickets skipped and why. Then
anything left blocked and what it is still waiting on. No surface screenshot,
no restatement of the decisions the human just made.
