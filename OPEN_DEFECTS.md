# Loom — open defects

Confirmed defects found by the independent review round of **2026-08-06**, against a suite green
at 430 tests with `snapshot | graph`, `lane-status` and `report` all clean on a live tracker.
Eight reviewers, one per file, none told what the others found. Every entry below was reproduced
against the real lines before it was recorded; unverified claims were dropped.

Nothing here is fixed. `qa` reports and does not repair — on 2026-08-01, fixing six findings
introduced five new ones.

## How to use this file

**Keys are stable and never reused.** `D-<FILE>-<nn>`, where `<FILE>` is `TICK`, `SNAP`, `LANE`,
`BOOT`, `PANE`, `TEST`, `SKILL` or `REF`. Cite a key in a commit message, a proposal, or a ticket:
"fixes D-LANE-02". A fixed defect keeps its key and moves to the Closed section at the bottom with
the date and what shipped — never delete a row, and never renumber.

**Line numbers drift.** They were true on 2026-08-06. Locate by function name, not by line.

**`Covered by`** names the proposal that would resolve the defect as part of a larger change. A
defect with no proposal is a straight fix: the intended behaviour is already decided, the code
just disagrees with it.

**A fix is not done until a test fails without it.** Each entry records whether `tick-test.sh`
should have caught it; almost none of them could have.

A `tick-test.sh:<line>` citation below predates P76, which split the suite into
`scripts/tests/NN-<topic>.sh` over `scripts/test-lib.sh`. Those line numbers no longer resolve —
find the test by the string it asserts, which is what the citation was really pointing at.

---

## `scripts/tick.sh`

### D-TICK-03 · both locks stamp the owner pid after claiming the lock
`tick.sh:497-508`, `:517-524` — `lock_acquire` creates the dir at `:497` and writes the pid at
`:498`. A second tick whose `mkdir` fails in that window reads an empty pid at `:503`, fails
`[ -n "$owner" ]`, `rm -rf`s the lock at `:507` and recurses into it. `_merge_lock_reserve` has the
identical window at `:517-518`.
**Failure:** two lanes exit together and each fires `( "$SELF_PATH" tick --from-lane & )`
(`:1246`), or one does while the 60s launchd firing lands → both "hold" the lock, both run
`_run_wave` — two concurrent scheduler sessions on one board; the first to finish `rm -rf`s the
other's lock in `_tick_exit` (`:709`). On the merge lock, two `--merge-lock` lanes at once,
contradicting `:515`.
Related: the comment at `:1322-1324` claims the reserve→lane-stamp window is closed because
tick.sh stays alive throughout, but `cmd_spawn_lane` returns at `:1328` and may exit before the
lane's stamp at `:1314` lands.
**Test:** `tick-test.sh:97-100` covers only a lock whose pid file *exists* holding a dead pid.

### D-TICK-04 · spawn-lane's destructive work sits above the pregate validation
`tick.sh:1198`, `:1200`, `:1204`, `:1210` — log rotation, log truncation and `rm -f <id>.rc` all
run before the `--pregate` tier check that can still `die` at `:1290-1292`. This is the invariant
the block comment at `:1187-1191` asserts in capitals, with the pregate `die` as its counterexample.
It is also the class of defect a 2026-08-01 repair introduced.
**Failure:** `spawn-lane gate-42 --merge-lock --pregate integration -- claude …` against a
`.loom.yml` declaring only `docs/logic/api/ui`: merge lock reserved → logs rotated and truncated →
`lanes/gate-42.rc` deleted → tier rejected, `die`. No lane spawns, the previous round's exit code
is gone (so the harvesting wave cannot tell rc 7 from a crash), and the merge lock is left
reserved holding the pid of a process that just exited.
**Test:** `tick-test.sh:857-861`, `:884-890` assert only that a bad tier is refused. Nothing
asserts the prior `.rc`/transcript survive, or that the merge lock is not left held.

### D-TICK-05 · sweep runs above the quiescence gate
`tick.sh:807` — `cmd_sweep`, the only `rm -rf` path in the program, runs at `:806-807`, before the
quiescence gate at `:836-854`.
**Failure:** the darkwake sequence documented at `:820-826` — laptop wakes, launchd runs the missed
firing before WiFi returns, `_quiet_check` fails its `glab` call → `unreadable`. The wave is
correctly skipped at `:843`, but `_prune_scratch` and `cmd_sweep` already ran, with `git fetch
origin` having failed at `:161`, so D-TICK-02's merge judgement is made against stale on-disk refs.
**Test:** no case runs `tick --auto` in the `unreadable` state with a sweepable worktree present.

### D-TICK-08 · `--brief` copies the file into the worktree before the guard that refuses
`tick.sh:1094` — `cp` writes the brief at `:1094`; the guard at `:1105` can still die.
**Failure:** `spawn-lane impl-60 --brief /tmp/b.md --cwd …/repo-wt-60 -- claude -p "implement #60"`
(brief supplied, `@brief` placeholder forgotten — plausible, since the wave prompt at `:891`
documents both forms). `repo-wt-60/.lane-brief-impl-60.md` is written, then `:1105` dies and no
lane exists. The orphan brief stays at a fixed path, so a later round of the same ticket spawned
with `--brief` under the same id can read the previous round's brief — the fixed-path reuse class
the scratch design at `:77-79` exists to eliminate.
**Test:** the brief tests assert the refusal but not that the worktree is left untouched.

### D-TICK-09 · `runner` and `base` bypass the global config layer
`tick.sh:1293`, `:2480`, `:2565`, and `:157` for `base` — read with `_yaml_scalar "$CONFIG"`,
skipping the repo→global→default chain `cfg` promises at `:447-452`.
**Failure:** `~/.loom/config.yml` sets `runner: scripts/ci.sh`, repo `.loom.yml` says nothing.
`resolve-config`/`install-settings` still emit `Bash(scripts/gate.sh *)` and the pregate at `:1293`
still invokes `scripts/gate.sh`; on a repo holding only `scripts/ci.sh` the pregate hits the
missing-runner path at `:1299` and silently skips, so every gate spends the full review session
P12 exists to avoid — with no error printed anywhere. For `base`: the snapshot exports it via
`cfg base ''` (`:1919`) while sweep derives it at `:157` without the global layer, so the two can
disagree about which branch "merged into" means at `:190`.
**Test:** the layered-config section (`tick-test.sh:2252+`) never tests `runner` or `base` for
global-layer resolution.

### D-TICK-10 · bare `glab` instead of `"$GLAB_CMD"`
`tick.sh:246`, `:247`, `:306` — breaks the seam documented at `:36`. `tick-test.sh:1037`
acknowledges it and works around it via `PATH`.
**Failure:** a machine pointing `GLAB_CMD` at an auth or proxy wrapper gets its snapshot from the
wrapper (`:1734`, `:1775`) and its quiescence classification from bare `glab`, so the gate can
answer `unreadable` on a board the wave reads fine — and on `--auto` that silently suppresses
every wave (`:840-844`).

### D-TICK-11 · `render-events` drops any event with no `state`
`tick.sh:1508` — `({…} | .[$e.state])` errors with `Cannot index object with null`, jq skips that
input line and exits 0, so the ticker loses the line rather than failing loudly.
**Failure:** reachable through the public `event` verb (`:611`) that lanes call directly:
`tick.sh event ticket_transition ticket 5` renders nothing and leaves an error in the pane.
`lane.sh:472` always supplies `state`, so the in-tree caller is safe today.

### D-TICK-12 · retro's depth fixpoint is capped at 12
`tick.sh:2125` — `reduce range(0; 12)`, while `GRAPH_JQ` correctly uses `range(0; $n + 1)` at
`:2252`.
**Failure:** a dependency chain deeper than 12 makes retro's "deepest chain in the graph was N"
line (`:2167`) report too small a number, which can invert the conclusion printed at `:2168-2169`
on a build that really was graph-bound.

---

## `scripts/snapshot.jq`

### D-SNAP-01 · epic→milestone matching is looser than the rule that closes the milestone
`snapshot.jq:256-257` — bare `startswith` in both directions with no boundary, while `lane.sh:351`
matches `"$slug"|"$slug"-*` (exact, or prefix followed by a dash). `| first` at `:258` also makes
the winner depend on API payload order.
**Failure:** epic `E1` (all members closed); milestones `E11 Reporting` (active, first in payload)
and `E1` (active). The snapshot emits for `E1`: `milestone: "E11 Reporting"`, `accepted: false`,
`acceptance:` E11's criteria, `needs_probe: true`, and a warning to spawn `probe-e11-reporting`.
`lane.sh` then closes `E11 Reporting` and skips `E1`. Net: E1's milestone never closes (permanent
`needs_probe`, build can never complete), E11 is marked accepted with no probe ever run, and the
probe brief is written against the wrong epic's criteria.
**Test:** `tick-test.sh:1810-1838` uses two names with no prefix relationship, so only the
exact-match path is exercised.

### D-SNAP-02 · an epic whose name is a substring of another is silently deleted
`snapshot.jq:244-246` — mutual `contains` with no boundary.
**Failure:** `$items = ["E1"]`, `$epics_open = [{name: "E10 Payments"}]` → `$epics_done == []`,
because `"e10 payments" | contains("e1")`. Completed epic `E1` appears in neither `epics[]` nor
`epics_awaiting_probe`, no warning fires, and `build_complete` closes the build over an unaccepted
epic — the build-2 failure recorded at `:233-240`.
**Test:** same non-colliding-names fixture as D-SNAP-01.

### D-SNAP-03 · the gate's MR can be one that merely mentions the ticket
`snapshot.jq:44` — `$M` is filled from `related_merge_requests` (`tick.sh:1860`), which
`lane.sh:491` documents as including any MR that mentions the issue; that is why `lane.sh
merge`/`close` use `closed_by` instead. `gate_of` takes `map(select(.state=="opened")) | first`
with no branch or authorship check.
**Failure:** #12's own MR merged; someone opens `!99 refactor (relates to #12)`. `$mr` = !99, so
the "no open merge request — merged or closed while queued" branch at `:70` never fires; `$head` is
!99's sha; no verdict matches → `gate.eligible: true`. A verifier runs the live suite against an
unrelated branch on already-shipped code — the P11 failure `:36-42` claims to have closed.
**Test:** no fixture puts a foreign MR in `related_merge_requests`.

### D-SNAP-04 · an open MR with no `sha` is gate-eligible forever
`snapshot.jq:45`, `:63`, `:83` — `($mr.sha // null) as $head`; when `$head == null`, `$judged`
short-circuits to `null` and control falls to the `else` at `:82`.
**Failure:** verified —
`gate_of(7; "review"; [{state:"opened",iid:1}]; [{body:"orch-verdict FAIL abc1234"}]; {})` →
`{"eligible": true, "reason": null, "head": null}`. No verdict can ever match a null head, so the
"already judged at this HEAD" guard is structurally unreachable and the ticket is re-gated every
wave — the duplicate-gate half of P11, unbounded. `eligible: true` with `head: null` also hands the
gate lane no commit to judge.
**Test:** every MR fixture carries `sha`.

### D-SNAP-05 · sha comparison is case-sensitive
`snapshot.jq:64-65` — MR sha `ABC1234DEF` vs trailer `abc1234` fails `startswith` both ways →
`eligible: true`, duplicate gate. The capture regex at `:59` explicitly admits `A-F`, so the
program accepts uppercase input it then cannot match.

### D-SNAP-06 · `### Acceptance criteria` reads as absent
`snapshot.jq:17`, `:272` — `section` requires exactly `##`.
**Failure:** `"### Acceptance criteria\n- a\n" | section("Acceptance criteria")` → `""` →
`acceptance: null`. For an epic at `needs_probe` this fires the loud warning at `:292-295` claiming
the milestone has no criteria when it plainly does, and the probe brief is written from defect
history alone — the P34 failure. Same applies to a `### Risk tier` ticket.
**Test:** `tick-test.sh:1837` tests only the genuinely-absent case.

### D-SNAP-07 · the trailer strip truncates any epic name containing " - "
`snapshot.jq:232` — `sub("\\s+[—–-]\\s+[^—–]*$"; "")` is leftmost-match and `[^—–]*` spans ASCII
hyphens, so it cuts from the *first* spaced hyphen to end. `"Ledger - core postings"` → `"Ledger"`;
`"Reporting - phase 2 - final"` → `"Reporting"`. The mangled name matches no milestone →
`accepted: null`, `needs_probe: false`, epic invisible. Em and en dashes are handled correctly.
**Test:** the fixture at `tick-test.sh:1371` uses an em dash only.

### D-SNAP-08 · the config-line filter deletes real epic names
`snapshot.jq:233` — `test("^[a-z_][a-z0-9_]*:")` is meant to drop `max_lanes: 4` but drops any
lowercase-leading epic containing a colon. `["auth: token rotation", "Reporting surface",
"max_lanes: 4"]` → `["Reporting surface"]`; epic `auth: token rotation` is never probed.
Asymmetric too — `Max lanes: 4` survives.

### D-SNAP-09 · the Risk tier is the first tier word anywhere in the prose
`snapshot.jq:33` — `scan("\\b(docs|logic|api|ui)\\b") | .[0] | first` over the whole section body.
Body `Not just docs — this is api work` yields `tier: "docs"`, so the gate picks the cheapest suite
for api-risk code, and no warning fires because `.tier != null`.
**Test:** fixtures at `:1498`, `:1575`, `:1623` use bare one-word sections.

### D-SNAP-10 · `merge_attempts` ignores the scope-reset marker
`snapshot.jq:132-133` — `rejections_of` retires verdicts older than `orch-scope-reset` (`:105-115`);
`merge_attempts_of` is a bare `test("orch-merge-attempt")` over every note.
**Failure:** a ticket rescoped after two failed merges returns with `rejections.total: 0` but
`merge_attempts: 2` — at `merge_attempt_cap: 2` it is blocked from the merge queue on history the
rescope was meant to retire. Any note quoting the trailer name also inflates the count, and the
notes most likely to quote it are the machine's own reports about the cap (see D-SKILL-13).
**Confirmed live** (build-1 #26, 2026-08-07): two merge attempts failed on an unrelated defect on
the integration base (#65's over-broad model-literal regex, since fixed at `d85fac2`). Ticket #26's
own diff never failed a gate — a merge of `origin/main` into `loom/ticket-26` runs the `logic` tier
clean (ruff, mypy, 232 passed / 5 skipped) and MR !14 reports `detailed_merge_status: mergeable`.
The ticket is nonetheless unmergeable through the queue, and `rescope` cannot free it: the marker
`lane.sh rescope` writes is read by `rejections_of` only. Worse, the blocked report the wave wrote
at the cap names `orch-merge-attempt` in its prose, so the scan now returns **3** against a cap of
2 — the counter is above the cap by one attempt that never happened. The only exits left are a
hand-merge outside the queue, or raising `merge_attempt_cap` past the inflated count.
**Test:** `tick-test.sh:1547` tests rescope against `rejections` only. Nothing asserts that a note
merely *mentioning* the trailer is not counted, which is the case that bit #26.

### D-SNAP-11 · `impl_slots_free` can go negative
`snapshot.jq:364-366` — no clamp. `max_lanes: 2` with three alive impl lanes → `-1`. Reachable by
lowering `max_lanes` while lanes run, or by a stale lane a harvest missed. A consumer doing
arithmetic rather than `> 0` gets a nonsense budget.
**Test:** `tick-test.sh:1481` tests only the aux-lanes direction.

### D-SNAP-12 · `merge_in_flight` is the one summary field not derived from the document
`snapshot.jq:369` vs `:355-359` — it comes from `--arg merge_owner "$(_merge_lock_owner)"`
(`tick.sh:1943`), which reads `$MERGE_LOCK_DIR/pid` and `kill -0`s it, while
`lanes_running_by_type.merge` comes from `$lanes`. Nothing reconciles them.
**Failure:** `_merge_lock_reserve` stamps the *spawner's* `$$` (`tick.sh:518`) and the lane
restamps its own pid later (`:1314`); a snapshot taken between reads a dead pid →
`merge_in_flight: false` while `lanes_running_by_type.merge == 1`, so P5's "a second merge waits"
is off. Narrow window, but the only place two summary counts can contradict each other.
**Test:** `tick-test.sh:1704-1709` tests only the two agreeing cases.

### D-SNAP-13 · inconsistent null guarding on the slurpfiles
`snapshot.jq:164`, `:331` — `$closed[0] // []` (`:241`) and `$milestones[0] // []` (`:255`) are
guarded; `$open[0]` (`:165`) and `$notes[0]` (`:331`) are not. An empty slurped file makes `$x[0]`
null, and `null | map(f)` aborts the whole program with `Cannot iterate over null` instead of
degrading. Latent only because `tick.sh:1766` pre-seeds `notes.json` and `:1777` dies on a failed
open-issue fetch.

### D-SNAP-14 · the state check shadows the stale-gate reason
`snapshot.jq:68` — `$state != "review"` is tested before the `$gating` branch, so a ticket a wedged
verifier moved out of `review` reports `"not in review"` instead of the "STALE — harvest it
(kill-lane)" instruction `:73-78` exists to give. The operator loses the pointer to the one command
that fixes it.

### D-SNAP-15 · cross-project blockers fall back to the home open-set
`snapshot.jq:161` — `elif ($proj != null and $home != null and $proj != $home) then null`, where
`$home` is `$bi.project_id` (`:167`) and is null when no `Build N` issue is open. A native link to
issue #5 in another project then falls to `($open_iids | index(5)) == null`, so an *open* foreign
blocker whose iid does not exist locally reports `closed: true` → `unblocked: true` → the ticket is
scheduled. Body-sourced blockers (`:199`) take this path by design; this one is an accident of
`$bi` being absent.

---

## `scripts/lane.sh`

### D-LANE-01 · the closed-ticket guard is in `cmd_transition`, not in `_set_state`
`lane.sh:466-471` vs `:147` — `_set_state` is the shared write path and runs only `_blocked_guard`;
the `.state == "closed"` check is a local of `cmd_transition`.
**Failure:** verified with #51 closed — `lane.sh verdict 51 pass abcd1234` posted the note and
issued `add_labels=merge-queue`, rc 0; `lane.sh claim 51` issued `add_labels=in-progress -f
assignee_ids=5`, rc 0. This is the #23 stale-snapshot race the file documents at `:460-465`: the
wave photographs #23 as `merge-queue`, the merge lane lands and closes it 90s later, the gate lane
then stamps `merge-queue` on a closed ticket.
**Test:** `tick-test.sh:4360-4380` exercises `transition` on a closed ticket only; no
verdict-on-closed or claim-on-closed case exists.

### D-LANE-02 · `close` refuses on "no open MR", not on "a merged MR exists"
`lane.sh:529-532` — an abandoned MR (state `closed`, never merged) passes the guard.
**Failure:** verified — `closed_by` = `[{"iid":11,"state":"closed"}]` → `lane.sh close 60` printed
"closed, state labels stripped" and issued `state_event=close`, rc 0. The first MR is superseded
and closed by hand, the branch never lands, a lane runs `close` — the ticket leaves the scheduler's
universe, its dependents' blockers clear, and they branch off a base without the work in it. That
is the build-1 failure the comment at `:524-528` claims this guard prevents.
**Test:** `tick-test.sh:4308-4315`'s stub emits only `opened` or `[]`.

### D-LANE-03 · `merge` takes `.[0]` of the open MRs in unspecified API order
`lane.sh:498-499` — the comment at `:491-494` claims `closed_by` rules this out, but `closed_by`
only excludes MRs that *mention* the issue; two MRs that both say `Closes #N` is the normal shape
after an abandoned first attempt whose branch was never deleted.
**Failure:** verified in two steps. `closed_by` = `[{21,opened},{5,opened}]` → merged `!21`, then
`cmd_close` found `!5` open and died, leaving the ticket open and still `merge-queue` with the MR
already landed. On retry (`[{21,merged},{5,opened}]`) it merged `!5`, the stray.
**Test:** `tick-test.sh:4340-4348` covers "no open MR closes the issue" only; there is no
happy-path merge test at all.

### D-LANE-05 · `verdict` posts its note before the blocked guard runs
`lane.sh:190-192` — the note is posted, then `_set_state` runs `_blocked_guard`.
**Failure:** verified — on a `blocked` ticket, `verdict 80 fail deadbeef --class marks-attribution`
POSTed a body containing `<!-- orch-verdict FAIL deadbeef class=marks-attribution -->` and *then*
died rc 2. `rejections_of` / `same_class_tail` scan exactly that trailer, so a held ticket
accumulates rejections from lanes that were refused — two and the wave stops for a design decision
over verdicts that never landed.
**Test:** `tick-test.sh:3978-3982` greps the capture only for `add_labels\|state_event=close`; it
already captures the notes POST, so widening that grep would catch it.

### D-LANE-06 · a dirty worktree is reported as a merge conflict
`lane.sh:384-389` — `git merge` fails on uncommitted changes, and `reconcile` reports rc 3 with
recovery advice that does not work.
**Failure:** verified — uncommitted change to a file the base also touched → "merge conflict with
origin/main — resolve trivial conflicts and commit, or 'git merge --abort'", exit 3;
`git status --porcelain` showed ` M f` with no `UU`; `git merge --abort` returned
`fatal: There is no merge to abort (MERGE_HEAD missing)`. A headless lane is sent into conflict
resolution over a conflict that does not exist, and both escape hatches fail. Same class as the
`reconcile <iid>` trap already fixed at `:372-381`; a `git diff --quiet HEAD` precheck separates
the two.
**Test:** `tick-test.sh:4180-4197` reconciles a clean tree only.

### D-LANE-07 · a valueless trailing `--tier`/`--milestone` dies with no message
`lane.sh:286-287` — hits a bare `shift 2`, which fails under `set -e`: rc 1, silent. `--title` at
`:285` checks `${2:-}` and errors properly.

### D-LANE-08 · staged body temp files are never removed
`lane.sh:95`, `:329` — 3,053 `lane-body.*` files were sitting in this machine's `TMPDIR` at review
time.

---

## `scripts/bootstrap.sh`

### D-BOOT-03 · `cmd_settings || true` turns a settings refusal into "bootstrap: done"
`bootstrap.sh:198` — contradicts the P30 mechanism its own comment describes at `:149-153` ("no
`.bootstrapped` sentinel on failure, so the next tick retries for free").
**Failure:** verified — repo with a hand-edited `.claude/settings.json`, trust accepted →
`install-settings` prints "differs from generated", `all` prints `bootstrap: done`, rc 0, file
unchanged. The sentinel is then written and the allowlist is never installed, silently and
permanently. Untrusted-workspace incompleteness is surfaced; a settings refusal is not.
**Test:** section 9e (`tick-test.sh:2559`) plants a bootstrap failure via a stubbed bootstrap;
nothing asserts a real `install-settings` refusal propagates out of `all`.

### D-BOOT-04 · unknown flags are accepted and ignored
`bootstrap.sh:60`, `:94` — `[ "${1:-}" = "--dry-run" ] && dry=1` treats anything not an exact match
as "not a dry run". `cmd_all` (`:182-188`) refuses unknown flags correctly; the two subcommands it
delegates to do not.
**Failure:** `bootstrap.sh labels --dry-runn` (or `-n`, `--dryrun`) creates nine labels against the
live tracker — captured argv shows all nine `label create` calls. Same shape for
`global-config --dry-run`, which writes `~/.loom/config.yml`.
**Test:** `tick-test.sh:2530` asserts `all --bogus-flag` is refused; there is no equivalent for
`labels` or `global-config`.

---

## `scripts/watch-panes.sh`

### D-PANE-01 · the EXIT trap closes no panes, then releases the singleton
`watch-panes.sh:146-152` — `_wp_cleanup` removes `$MAP` and the pidfile only; the one
close-everything path is the `VIEWER_OFF` branch at `:397-405`.
**Failure:** verified with a stub herdr — viewer up with anchor, ticker and lane panes, then
killed → 0 `pane close` calls, pidfile removed. The orphaned ticker keeps running `render-events
--follow` forever; `$MAP` is gone, so the next opportunistic launch on a manual tick starts blank
and splits a second pane per running lane plus a second ticker. A later `watch-panes.sh ticker off`
then closes only the new viewer's ticker — the orphan strip stays, which reads exactly like the
switch being ignored. Same leak when `wp_blind` (`:325-329`) fires.
**Test:** 13l covers mid-run `off` only; the suite contains no `kill -INT`/`kill -TERM` at all.

### D-PANE-02 · `ensure_ticker` splits off raw `$ANCHOR`, so a dead anchor is never re-resolved
`watch-panes.sh:374` — `reanchor` (`:209`) is called only from `anchor_split` (`:230`), used at
startup (`:340`) and in the fresh-column path (`:530`). Lane panes stack off `STACK_LAST`, so
`ANCHOR` is never re-resolved after startup.
**Failure:** reproduced — the human closes the loom session pane; the ticker pane later dies (or
they press `q` then run `ticker on`) → every poll retries `pane split --pane stub:p0 …`, fails,
prints "could not open a ticker pane" to stderr, and calls `pane list` 0 times, with a live pane
available to re-anchor on. Lane panes keep working, so the viewer looks healthy. `raise` cannot fix
it: `on` (`:104-105`) sees a live pidfile and declines. The P39 shape with the ticker path left
out; produces the 2026-08-05 symptom described at `:73-75`.
**Test:** 13n exercises a dead anchor only at startup and only with `WATCH_TICKER=0`.

### D-PANE-04 · a partial `lane-status` read is discarded entirely
`watch-panes.sh:408` — `|| running=""` under `set -euo pipefail`.
**Failure:** verified — with one unreadable pid file, `tick.sh lane-status` prints 1 of 3 lanes and
exits 1; the assignment yields `running=[]`, throwing away even the lanes it did report.
`cmd_lane_status` (`tick.sh:1611`) does an unguarded `pid=$(cat "$pidfile")` under `set -e`, so a
pid file removed between the glob and the `cat` — which `cmd_clear_lane` (`tick.sh:1636-1639`) does
on every harvest — aborts it mid-output. One such poll runs D-PANE-03's blast radius against every
pane at once. Safe reading would keep the previous list.

### D-PANE-05 · the pidfile is claimed before the environment guards
`watch-panes.sh:134` vs `:154-160` — startup to the claim is two full `tick.sh` invocations
(`:38`, `:121`), measured ~120 ms.
**Failure:** demonstrated with three near-simultaneous launches, one doomed — run 2 printed "not
inside a herdr session"; runs 1 and 3 printed "already running (pid …) — nothing to do"; run 2 then
exited and its trap deleted the pidfile. Net: zero viewers, two legitimate launches turned away,
with those messages landing in `watch-panes.out` where nobody reads them. Claiming the pidfile
after the guards closes this.
**Test:** 13e is strictly sequential.
**Note:** the pure check-then-write TOCTOU at `:130-134` was *not* reproduced (0/20 trials); it is
recorded here as unproven, not as a defect.

### D-PANE-06 · the singleton is a bare pid with no identity check and no way to clear it
`watch-panes.sh:130` — if a viewer dies without its trap (SIGKILL, crash) and that pid is later
reused by any process the user owns, `kill -0` succeeds forever: the main path exits "already
running" (`:131`), `on` refuses to relaunch (`:104-105`), and neither `off` nor `raise` removes the
file. Recovery is deleting `watch-panes.pid` by hand — the "a command someone had to be told"
state `:82-88` was written to end. Mechanism is exercised by 13e; the trigger (pid reuse) is
inference, not reproduced.

### D-PANE-07 · MAP order stops matching screen order after the first pane reuse
`watch-panes.sh:510-513` — the "bottom-most live pane" fallback walks `$MAP` in insertion order,
but `:485-486`/`:547` remove and re-append a reused pane, so the re-anchor invariant at `:499-505`
splits off a middle pane. 13i passes only because its fixture never reuses a pane.

### D-PANE-08 · the pane cap counts panes a human already closed
`watch-panes.sh:488` — closed-but-still-stamped-idle entries count toward the cap and are
discovered only when a lane tries to reuse one and `pane run` fails (`:553`). Closing six idle
panes with `WATCH_MAX_PANES=6` costs one poll per lane to drain, with no `viewer_note` — the note
at `:493-496` fires only on the cap branch, taken while those entries still count.

### D-PANE-09 · the banner promises a gesture that cannot be delivered
`watch-panes.sh:331` — "Ctrl-C to stop" on a viewer the skill launches detached; `:85-87` already
concedes Ctrl-C is not deliverable there, as do SKILL.md:214 and :502.

---

## `scripts/tick-test.sh`

The suite is 4,435 lines and 430 green tests. These are tests that cannot fail, or prove something
other than what they name. All are covered by **P45**.

### D-TEST-01 · the `rm -rf` guard's test never invokes `tick.sh`
`tick-test.sh:394-397` — writes its own `case` statement inside a `bash -c` string and asserts on
that; it is testing the bash `case` builtin.
**Misses:** delete `tick.sh:124` (`case "$SCRATCH_ROOT" in ""|"/"|"$HOME") return 0 ;; esac`), the
line guarding the `find … -exec rm -rf {} +` two lines below it. Demonstrated: test still PASSes.

### D-TEST-02 · the event-log invariant test cannot see `tail`/`grep` readers
`tick-test.sh:2902-2906` — detector regex `(<|read|cat|jq[^|]*)[^|]*\$EVENTS`.
**Misses:** two production *decision* readers already escape it — `tick.sh:285`
(`tail -n 500 "$EVENTS"` in `_last_activity_ts` → the spend gate) and `tick.sh:731`
(`grep '"ev":"wave_start"' "$EVENTS"` in `_wave_gap_ok` → whether a wave runs). The invariant the
test names — constitution rule 1 — is already false in the code and the test is green.
Demonstrated against the shipping `tick.sh`.

### D-TEST-03 · "snapshot made no mutating call" denylists a form nothing uses
`tick-test.sh:2019-2023` — denylist is `issue (update|close|create|note)|mr (merge|create|update)|
label (create|delete)|-X *(POST|PUT|DELETE|PATCH)`, but every tracker mutation in this codebase is
`glab api --method` (`lane.sh:102, 152, 308, 352, 501, 534`).
**Misses:** `glab api --method PUT projects/:fullpath/issues/10 -f add_labels=blocked` in any
snapshot path. Demonstrated: no match, test PASSes.

### D-TEST-04 · `ok` called in both branches
`tick-test.sh:2361-2363` — `… && ok "P4-violation: bare Bash(uv *) is absent…" || ok "P4: bare rule
also present (harmless…)"`. Cannot fail; a guaranteed +1 to the pass count. The suite's own comment
at `:2609-2612` records finding and killing this exact pattern in the ntfy block; this instance
survived.

### D-TEST-05 · three watch-panes planted violations pass against a dead copy
`tick-test.sh:3654-3656`, `:3448-3450`, `:3538-3540` — each asserts only the *absence* of a herdr
call from a `sed`-mutated copy, with no check that the copy ran. Demonstrated with a stand-in that
is `exit 127`: all three PASS. A `sed` that stops matching after a refactor, a syntax error, or a
missing sibling all read as "mechanism proven". `:3538` also plants its pid in a background
subshell that silently no-ops when the copy writes no pidfile. The correct shape
(`[ "$rc_n" = 0 ] && ok`) is used at `:3498` and was not applied here.

### D-TEST-06 · the `--no-tick` test never checks the lane ran
`tick-test.sh:185-192` — asserts only that `$MARK_NO` is absent.
**Misses:** `tick.sh:1005` → `--no-tick) die "…" ;;`. Demonstrated: PASS, with "lane actually
spawned? NO". An off-switch that kills the whole spawn is indistinguishable from one that
suppresses only the trigger. One `[ -f "$LOOM_HOME/lanes/impl-16.pid" ]` closes it.

### D-TEST-07 · the ticker-marker tests assert on source text, not behaviour
`tick-test.sh:3395-3397` — assertion is `grep -q 'ticker-off' "$TICK"`. The `q` handler that writes
the marker (`tick.sh:1587`) sits behind `if [ -t 0 ]` and is unreachable from this suite, which
always redirects stdout; the grep is satisfied by `tick.sh:2638` (`rm -f …/ticker-off`) alone, so
deleting the write path entirely still passes. Same shape at `:3390-3392`, where
`grep -q "LOOM_TICKER_QUIT_HINT" "$WP"` passes on the name appearing in a comment.

### D-TEST-08 · the orphan-pipeline test is coupled to exact flag order
`tick-test.sh:4249-4258` — `pgrep -f "tail -n 100 -F $EVH/events.jsonl"`.
**Misses:** reorder `tick.sh:1569` to `tail -F -n 100 "$EVENTS"` — behaviour-neutral, orphan bug
intact — pgrep matches nothing and the test reports the orphan gone. Fails open on the one thing it
watches for.

### D-TEST-09 · the lane-id test's condition is always true
`tick-test.sh:221-228` — `[ -n "${bad_id:-}" ] && ! [ -f "$LOOM_HOME/lanes/12.pid" ] && ok …`.
`bad_id` is the loop variable and always survives non-empty; the second conjunct re-checks only the
first of six ids.
**Misses:** accepting `gate12`, `lane_14`, `impl`, `impl-` or `xyz-1` — this line still prints its
`ok`. The printed pass lies about five sixths of the fixture.

### D-TEST-10 · the allowlist-drift test passes vacuously on an empty gate set
`tick-test.sh:2366-2377` — `missing=0`, then a `while read` loop fed from a heredoc built by
`jq -r '.gates | to_entries[] | .value[]'`, with no non-emptiness guard.
**Misses:** `resolve-config` emitting `"gates": {}` — the loop body never runs, `missing` stays 0,
PASS prints.

### D-TEST-11 · the "arming wrote no plist" test asserts on an empty directory
`tick-test.sh:3704-3706` — `ls "$LOOM_PLIST_DIR"` where the directory is created empty at `:3689`
and never written by anything. It passes because the directory is empty, not because arming was
removed, and would pass identically if `watcher-arm` wrote a plist elsewhere.

### D-TEST-12 · the concurrency test's window is inside its own measurement error
`tick-test.sh:1750-1757` — `elapsed < 3` measured with integer `date +%s` (±1s truncation at each
end) against a claimed serial cost of "~4s" for what is actually 11 stub calls. A partially
serialised fan-out (two sequential concurrent stages) lands inside the window.

### D-TEST-13 · a false rule recorded in the suite
`tick-test.sh:594-595` — the comment states "a prefix on a function call is not passed through to
the command the function runs". Verified false in bash: `ZZZ=hello f` reaches a grandchild process.
Sections at `:1057`, `:1111`, `:1128`, `:1167` depend on the prefix form working, so the comment
invites a future "fix" that would rewrite working tests. Not a test defect; a trap for the next
maintainer.

---

## `SKILL.md`

### D-SKILL-01 · the injected wave prompt overrides the per-ticket model rule
`tick.sh:889` vs SKILL.md:159-166, :302-304 — the prompt says `- Spawn every lane with:
--permission-mode $perm_mode$lane_model_line`, where `lane_model_line` is `--model $(cfg
lane_model)` (`tick.sh:875`), while SKILL.md says an implementation lane spawns on
`.model.effective`, which resolves to `rework_model` on round 2+. The prompt is prefaced "trust it
over rediscovery" (`tick.sh:884`) and arrives inside the wave, so in practice it wins.
**Failure:** on a repo with `lane_model: sonnet`, `rework_model: opus`, every rework respawn goes
out on sonnet — the failure SKILL.md:303-305 exists to prevent, silently.
**Covered by:** P48.

### D-SKILL-02 · the injected prompt tells merge lanes to finish with `lane.sh close`
`tick.sh:890` vs SKILL.md:378-384 and `lane.sh:530-533` — injected text: "Merge lanes close tickets
with 'lane.sh close <iid>' — it strips the state labels too." `cmd_close` dies with `issue N still
has unmerged MR !M`. The same line's verb roster ("claim, transition, note, mr-note, verdict,
close, scratch") omits `merge`, `merge-failed`, `fix-ticket`, `reconcile` and `probe-result`.
**Failure:** a merge lane trusting the injected list has no verb that merges; it ends by calling
`close` and hard-errors — the build-1 merge-1 shape.
**Covered by:** P48.

### D-SKILL-03 · the quiet-state allowlist names the wrong state and the wrong set
SKILL.md:116-118 — prose: "`unknown` — the board could not be read at all — skips on the timer, and
only `active` and `complete` buy a wave." `_quiet_check` (`tick.sh:296`) emits
`active|stalled|halted|complete|unknown|unreadable`; the read-failure state is **`unreadable`**
(`tick.sh:840`), while `unknown` means "no build label yet, pre-plan" and *does* buy a wave
(`tick.sh:850`), as does `stalled` under the default `stall_action: resume` (`:845-849`).
**Failure:** four states can spend, not two. Anyone repairing the gate from this prose drops
`unknown`, and a never-planned repo never gets its first wave (`tick.sh:834-835`).

### D-SKILL-04 · `spawn-lane --model` is not a flag
SKILL.md:155 vs `tick.sh:997-1017` — the parser knows only `--on-done-tick`, `--no-tick`,
`--pregate`, `--merge-lock`, `--cwd`, `--brief`; anything else before `--` hits `tick.sh:1014`
`die "spawn-lane: unknown flag"`. The model is scraped from the post-`--` command (`:1168-1173`).
**Failure:** `spawn-lane impl-12 --model opus --cwd …` aborts. Only `-- claude --model opus …`
works, which the prose never shows.

### D-SKILL-05 · `fix-ticket` is shown without its required body
SKILL.md:428 — `lane.sh fix-ticket --title … --tier … --milestone …` reaches `_stage_body`, which
reads stdin and dies at `lane.sh:97` `empty body (pass --file or pipe stdin)`. A headless probe
lane has no stdin.
**Failure:** the fix ticket is never filed; the epic's defect goes unrecorded and its milestone can
close over it. `--tier` is also constrained to `docs|logic|api|ui` at `lane.sh:281`, which the
prose writes as an unqualified `<tier>`.

### D-SKILL-06 · `tick.sh notify` is shown with only an event name
SKILL.md:468 — `cmd_notify` is `local event="$1" title="$2" body="$3"` (`tick.sh:1674`) under
`set -euo pipefail` (`:41`).
**Failure:** `tick.sh notify build_complete` dies on an unbound variable — no push, no ticker line,
completion invisible. The correct form appears only in the usage string at `tick.sh:2848`.

### D-SKILL-07 · `transition <n> blocked` "with a report" has no body channel
SKILL.md:250 — `cmd_transition` accepts only `--release-hold` and dies on anything else
(`lane.sh:456`).
**Failure:** `transition 50 blocked --file report.md` aborts, the ticket is never blocked, and the
merge queue keeps feeding lanes into the same wall — the failure SKILL.md:251-252 cites. A separate
`lane.sh note` is required first; the prose says so at :587-588 but not here.

### D-SKILL-08 · the timer interval is stated two ways
SKILL.md:90 ("a slow heartbeat (~15 min)") vs SKILL.md:99 ("every **60s**") vs `cmd_install`
defaulting to 60 (`tick.sh:2652`) vs `references/loom-config.md:62` ("a fixed 900s backstop").
**Failure:** stall reasoning ("nothing fired for 15 minutes, therefore wedged") is off by 15× against
a 60s agent. See D-REF-05.

### D-SKILL-09 · "the ticker can say why nothing ran" holds for one reason in six
SKILL.md:116 — `render-events` renders `tick_skipped` only for `loop_stopped`, and for `lock_held`
only on the first (`tick.sh:1532-1541`); `wave_gap`, `halted`, `unreadable`, `stalled_notify_only`
and `unclassified` all fall to `else empty`.
**Failure:** a human watching a halted or unreadable board sees an unexplained silent strip and
reads it as a wedge.

### D-SKILL-10 · three read config keys are undocumented
SKILL.md:316 (`max_aux_lanes`), :249 (`merge_attempt_cap`), :107 (`min_wave_gap_minutes`) are named
to waves but absent from `references/loom-config.md`, which `setup.md:9-10` declares the canonical
key list. All three exist in `cmd_resolve_config` (`tick.sh:2574-2583`), defaults 4 / 2 / 10.
**Covered by:** P50. See D-REF-04.

### D-SKILL-11 · `references/loom-config.md:60` says the merge queue rebases
Contradicts SKILL.md:361-362 ("never rebase"), SKILL.md:200 and `lane.sh:359`.
**Failure:** the two-lane dead end SKILL.md:362-365 cites — force-push is denied, so rebased
history can never land.
**Covered by:** P50.

### D-SKILL-12 · `references/optimize.md:107` still carries the four-item fix-ticket list
"all **four** of: `build-N`, `fix`, a risk tier, and the defective epic's milestone" vs SKILL.md:429
**five** (adds `ready-for-agent`). `lane.sh:271-278` names this four-item enumeration as the cause
of #64 sitting stateless and unclaimed.
**Failure:** an `optimize` pass reads the five-item rule as bloat and compacts it back to the
broken four.

### D-SKILL-13 · the blocked report the cap mandates inflates the counter it reports on
SKILL.md:264-268 — at `merge_attempt_cap` recorded attempts the wave must stop retrying and
`transition <iid> blocked` "with a report", and the same passage names the counter's source as
`.merge_attempts`. But `merge_attempts_of` (`snapshot.jq:132-133`) counts every note whose body
matches `orch-merge-attempt`, with no check that the note is a real `lane.sh merge-failed` trailer.
A report explaining *why the cap was reached* has every reason to name the marker it is counting,
and the prose gives no warning not to.
**Failure:** build-1 #26 (2026-08-07). Two genuine attempts, then a blocked report quoting
`orch-merge-attempt` in a sentence — `merge_attempts` reads 3 against `merge_attempt_cap: 2`. The
step that exists to *stop* the queue burning lanes on one ticket instead pushed the ticket one
attempt further out of reach, so even raising the cap to 3 would not have released it. Any later
human or agent comment discussing the cap does the same.
**Fix shape:** either the scan anchors on the trailer's full form (`<!-- orch-merge-attempt <iid> -->`
as written at `lane.sh:240`) rather than a bare substring, or SKILL.md tells report writers to name
the marker only as prose (`merge-attempt trailer`) and never verbatim. The first is the real fix;
the second is a workaround that every writer must remember.
**Test:** none. `tick-test.sh:1724` asserts a count of 2 from two real trailers, and `:1730` guards
only against a *verdict* trailer leaking in — no fixture carries a note that merely mentions the
merge-attempt marker.
**Related:** D-SNAP-10 (same bare `test()`, reached from the rescope side).

---

## `references/*.md`

### D-REF-01 · `loom-config.md:35` claims the generated allowlist includes `cd`
It does not: `tick.sh:2476-2477` reads "There is deliberately no `cd` rule: spawn-lane --cwd starts
a lane inside its own worktree", and live `resolve-config` output contains no `Bash(cd *)`.
**Failure:** an agent debugging a denied lane command trusts the doc and writes briefs that `cd`
into a worktree — silently denied under `dontAsk`; a maintainer "restoring the missing `cd`" re-adds
a rule removed on purpose.
**Covered by:** P50.

### D-REF-02 · `loom-config.md:116` says "`tick.sh` reads no gate key"
False. `_repo_gates_tsv` (`tick.sh:2446-2459`) parses `gates:` out of `.loom.yml`, `_derive_allow`
(`:2504-2507`) turns those commands into allowlist rules, and `cmd_resolve_config` (`:2563`) emits
`gates`.
**Failure:** someone editing `gates:` believes only the repo's `scripts/gate.sh` is affected and
skips `tick.sh install-settings`; the allowlist no longer covers the new gate command — the P4
drift the same paragraph claims is "dissolved".
**Covered by:** P50.

### D-REF-03 · `retro.md:81` states an invariant the code already breaks
"`retro` reads `events.jsonl` and nothing else in the loop reads that file… a scheduling decision
that consulted it would make it shadow state." Two already do: `_wave_gap_ok` (`tick.sh:725-736`)
and `_last_activity_ts` (`:283-289`).
**Failure:** a `qa` or `prop` run takes the invariant at face value and either rips out the two
readers as shadow state, or treats a truncated `events.jsonl` as cosmetic when it actually lets
every tick start a wave (the gap check returns 0 on a missing file).

### D-REF-04 · three read keys are missing from the canonical schema
`references/loom-config.md` omits `max_aux_lanes` (`tick.sh:2574`, default 4), `merge_attempt_cap`
(`:2578`, default 2) and `min_wave_gap_minutes` (`:2582`, default 10).
**Failure:** no documented knob for aux-lane concurrency, merge retry cap, or wave pacing.
`min_wave_gap_minutes` is the primary spend control (`tick.sh:786`) and appears only as prose in
`phases-1-5.md:113`, so someone tuning cost edits `max_lanes` instead — not the binding constraint.
**Covered by:** P50.

### D-REF-05 · `loom-config.md:62` states a 900s heartbeat
It is 60s: `tick.sh:2652`, `local interval="${1:-60}"`, whose comment names 900s as "the old
split". Also contradicts `phases-1-5.md:112` inside the same skill, so whichever file is read first
wins. See D-SKILL-08.
**Covered by:** P50.

### D-REF-06 · `ticket-template.md` omits `## Blocked by`
The template mandates `## Risk tier` and `## PRD requirement` but never mentions `## Blocked by`,
which `snapshot.jq:192-193` parses to build `blocked_by`, and therefore `unblocked`, the ready set
and `graph`.
**Failure:** a ticket written strictly to this template carries no body-level blocking edges; absent
a native `is_blocked_by` link it reads unblocked and a lane claims it before its blocker merges.
The template documents the section that only *warns* (`snapshot.jq:285`) and omits the one that
decides scheduling.

### D-REF-07 · `loom-config.md:95` lists push events nothing emits
`ticket_done | ticket_review | mr_merged`. The only `cmd_notify` call sites are `build_complete`,
`build_halted`, `build_stalled`, `lane_stale`, `wave_stale`, `usage_pause`, `usage_resume`,
`workspace_untrusted`, plus `ticket_blocked` fired by the wave per SKILL.md:468.
**Failure:** a human adds them to `push:` and gets silence with no error — `cmd_notify`'s
"not-in-push-list" trace never appears either, so the misconfiguration is undiagnosable.
**Covered by:** P50.

### D-REF-08 · `loom-config.md:86` skips the middle ntfy layer
"No topic at all → local macOS banner via osascript instead" — but `cfg_ntfy_topic`
(`tick.sh:466-472`) falls back to global `ntfy.topic_prefix` + repo basename before the banner
path, and `bootstrap.sh:82` seeds `topic_prefix: ""` into every new global config. `topic_prefix`
is named nowhere in `loom-config.md`.
**Failure:** the human hand-writes a `topic:` per repo when one global prefix line covers all of
them, and pushes landing on an unexpected `<prefix><repo>` topic have no documented explanation.
**Covered by:** P50.

### D-REF-09 · `runner` is presented as derived-only but is a settable repo key
`loom-config.md:21` and the schema block (`:42-102`) — it is read at `tick.sh:2480` and `:2565`.
**Failure:** a repo whose gate runner sits elsewhere has no documented way to declare it, so the
human moves the runner to satisfy the doc or invents a key name — while the real override also
drives the generated `Bash(<runner> *)` rules at `tick.sh:2483`. See D-TICK-09.
**Covered by:** P50.

### D-REF-10 · `resolve-config` is sold as "the effective config" and omits ntfy entirely
`loom-config.md:11` and `setup.md:29-31` — it emits no `ntfy` block (`tick.sh:2587-2605`); ntfy
resolves through a separate reader (`:466-493`).
**Failure:** the command sold as "the effective config is one command away" cannot answer where
pushes go or which events are on, so notification bugs must be debugged by hand-reading two YAML
files — the failure `tick.sh:481-488` records as having cost a silent overnight build.
**Covered by:** P50.

### D-REF-11 · `## PRD requirement` is mandated and parsed by nothing
`ticket-template.md:40-44` and `phases-1-5.md:68-69` describe it as gate-checked. No script parses
it: no `section("PRD requirement")` and no `PRD` match in `snapshot.jq`, `lane.sh` or `tick.sh`.
**Failure:** unlike `## Risk tier`, a missing or misnamed section produces no snapshot warning, so
the faithfulness check degrades silently to whatever prose the gate agent happens to find.

### D-REF-12 · `setup.md` contradicts itself on who creates the labels
`:21` says the first tick's `bootstrap.sh all` creates the missing ticket-state labels (true:
`bootstrap.sh:48-57`); `:35` lists "tracker labels" among what still needs a repo-bootstrap epic.
**Failure:** the human tickets label creation that already happened, spending a ticket and a lane
on a no-op — or hand-creates labels `cmd_labels` then reports as skipped.

### D-REF-13 · `prop.md` omits `snapshot.jq` from the scripts layer and the test rule
`:42` lists `tick.sh, lane.sh, bootstrap.sh, watch-panes.sh`; `:73` binds the test rule to fixes
landing "in `tick.sh` or `lane.sh`".
**Failure:** a proposal implemented in `snapshot.jq` — 386 lines, the document every wave reads,
and the file `qa.md:56-63` names as home to the rebound-`.` defect that "shipped twice in one
day" — is treated as not requiring a `tick-test.sh` case.

### D-REF-14 · `max_lanes: 4 # 1-6` documents a range nothing enforces
`loom-config.md:43` — the value flows through `cfg max_lanes 4` into `tonumber? // 4`
(`tick.sh:1921`, `:2232`) unvalidated. `max_lanes: 12` is accepted silently and spawns twelve
worktrees, while a human trusting the documented bound assumes the loop would refuse.
**Covered by:** P50.

### D-REF-15 · the model-alias lists omit `fable`
`loom-config.md:59`, `:65` read `sonnet|opus|haiku`, while `bootstrap.sh:55` creates a
`model::fable` label as a first-class per-ticket tier. Lowest rank: the docs also say "or full id"
and the value passes straight to `claude --model`, so nothing breaks.
**Covered by:** P50.

---

## Closed

### D-BOOT-01 · `_require_repo` proves "inside a repo", not "at a repo root"
*Closed 2026-08-06.*

`bootstrap.sh:35` used `git rev-parse --git-dir`, which searches upward, so a `REPO_ROOT` merely
nested under any repo — including a `$HOME` versioning dotfiles — passed the same check as one at
the actual root, and a repo-scoped write went to whatever directory `REPO_ROOT` happened to be.

**Shipped:** `_require_repo` now resolves `git -C "$REPO_ROOT" rev-parse --show-toplevel` and
requires it to equal `$(cd "$REPO_ROOT" && pwd -P)`, refusing with a named reason when they differ.
`tick-test.sh` case 9c6 adds two fixtures: a `REPO_ROOT` nested inside an ordinary repo, and one
nested inside a repo standing in for a `$HOME` with its own `.git` — both refused, both confirmed
to create nothing at either candidate root.

### D-BOOT-02 · from a subdirectory the allowlist is written where nothing reads it, and reports success
*Closed 2026-08-06.*

`bootstrap.sh:161-172` — same root cause as D-BOOT-01: running `bootstrap.sh settings` (or `all`)
from `myrepo/src/deep` wrote the allowlist to `myrepo/src/deep/.claude/settings.json`, which Claude
Code never reads, then reported success and stamped the `.bootstrapped` sentinel so it was never
retried.

**Shipped:** no separate change — D-BOOT-01's fix to `_require_repo` (`git -C "$REPO_ROOT"
rev-parse --show-toplevel` must equal `$REPO_ROOT`) runs before `cmd_settings` and `cmd_labels`
write anything, so a `REPO_ROOT` that is a subdirectory of a repo is refused with a named reason
instead of silently writing where nothing reads it. `tick-test.sh` case 9c6, added for D-BOOT-01,
already plants exactly this shape — a `REPO_ROOT` nested under an ordinary repo — and asserts both
the refusal and that `.claude/` is created nowhere; no further fixture was needed.

### D-LANE-04 · every guard read fails open
*Closed 2026-08-06.*

`lane.sh:136`, `:221`, `:466`, `:529` were each `2>/dev/null … || true` or an `if`-condition
pipeline, so a transient API failure made the guard pass: a failed `closed_by` read let `close`
close a ticket without ever checking for an open MR; a failed issue read let `transition` stomp a
human `blocked` hold.

**Shipped:** `P47` — each of the four reads now captures its own exit status (`out=$(...) &&
rc=0 || rc=$?`, kept separate from `set -euo pipefail` aborting on the bare assignment) and `die`s
naming the failed read instead of falling through to "not blocked" / "not closed" / "no open MR".
`tick-test.sh` §23 adds one case per guard, each failing exactly the read it depends on and
asserting both a `die` and that nothing was written.

### D-PANE-03 · only `running` counts, so a stale lane's pane is closed or reused
*Closed 2026-08-06.*

`watch-panes.sh:408` — same root cause as D-TICK-01 and D-TICK-06: a `stale` (alive but silent)
lane dropped out of `$running`, so its pane was closed outright or marked idle and handed to
another ticket's lane while the original process still held it.

**Shipped:** `P46` — `watch-panes.sh`'s poll now reads the new `tick.sh lanes-alive` subcommand
(`running` and `stale`) instead of filtering `lane-status` on `running` by hand. `tick-test.sh`
case 13p2 forces a real background lane `stale` and asserts its pane stays live — no idle rename,
no close.

### D-TICK-01 · sweep can `rm -rf` a live lane's worktree
*Closed 2026-08-06.*

`tick.sh:164` — `cmd_sweep`'s live-cwd guard filtered `cmd_lane_status` on `running` alone, so a
`stale` (alive but silent past the heartbeat window) lane contributed no cwd and never tripped the
lsof bailout — a wedged-but-alive lane's uncommitted, untracked work was seconds from
`git worktree remove --force` + `rm -rf`.

**Shipped:** `P46` — `tick.sh` gains `_lanes_alive()` (`running` **or** `stale`), and `cmd_sweep`'s
live-cwd loop now calls it instead of hand-filtering on `running`. `tick-test.sh` spawns a real
background lane, backdates its log to force `stale`, and asserts the worktree survives a `sweep`.

### D-TICK-02 · a failed `git log` in the merge check reads as "merged"
*Closed 2026-08-06.*

`tick.sh:190` — `[ -n "$(git log "origin/$base..$branch" --oneline 2>/dev/null | head -1)" ]`
could not distinguish "no commits ahead" from "revision range does not resolve" (missing or
unfetched base ref); either way it read as "merged" and armed the delete path on a worktree
holding committed, unmerged work.

**Shipped:** `P47` — the `git log` read now captures its own exit status before the emptiness
check; a non-zero exit logs "cannot resolve … base ref missing or unfetched" and skips the
worktree instead of deleting it. `tick-test.sh` plants an unresolvable `base:` and asserts the
worktree survives with the reason logged.

### D-TICK-06 · `_quiet_check` counts only `running` lanes as activity
*Closed 2026-08-06.*

`tick.sh:301` — same root cause as D-TICK-01: `_quiet_check`'s early "is anything active" check
filtered on `running` alone, so a lane holding the build's last unblocked ticket but currently
`stale` fell through into `halted`/`complete` classification instead of the pointer that would
have kept the build alive.

**Shipped:** `P46` — `_quiet_check` now returns `active` on `[ -n "$(_lanes_alive)" ]`, before any
`halted`/`complete` classification runs. `tick-test.sh` forces a lane `stale` and asserts
`_quiet_check` returns `active` without ever touching the tracker (proven by absence: `glab` is
stubbed to leave a marker on any call, and the marker never appears).

### D-TICK-07 · acceptance and quiescence reads truncate at one page
*Closed 2026-08-07.*

`per_page=100` with no `--paginate` on the acceptance read, the quiescence read and the
snapshot's `closed.json`: past 100 closed members an epic whose tickets all closed early
contributed no milestone title, `_epics_unaccepted` answered false, `_quiet_check` printed
`complete`, and the completion wave tore the agent down with that epic never probed — the
build-2 failure the acceptance gate exists to prevent, reachable again by board size alone.

**Shipped:** P49 (archived) put every `per_page=` list read in `tick.sh` behind one helper,
`_glab_list`, which paginates and folds `--paginate`'s one-array-per-page output into a single
array; `--capped` stays explicit for the two newest-N notes reads that genuinely want one page.
P73 moved that helper into `scripts/lib.sh` and P70 routed `lane.sh`'s own four reads through it,
so no list read in this skill truncates at a page boundary now. `tick-test.sh` cases 4h5p and 7f2
carry over-100-item fixtures whose decisive item sits on page 2, each shown failing once
`--paginate` is stripped.

### D-TICK-13 · retro's spend report cannot see wave sessions
*Closed 2026-08-06.*

`tick.sh:1647` — `_spend_by_lane` globbed only `"$LOGS_DIR"/lane-*.jsonl`, so every wave session
(`wave-*.jsonl`) was skipped before pricing began, and the join at `:2188` — matched to the build
through `lane_exit`, which a wave never emits — would have dropped them again even if the glob had
been widened.

**Shipped:** `_spend_by_lane` renamed to `_spend_by_session` and widened to enumerate both
`lane-*.jsonl` and `wave-*.jsonl`. `RETRO_JQ` now joins wave costs on `stem` (the wave log's own
basename, present on every `wave_end` event) instead of `lane_exit.id`, and reports them as their
own `wave` row in the spend-by-kind breakdown and in the grand total — never folded into a lane's
total, since a wave is the one session kind that writes no code. `tick-test.sh` case 12a2b plants
one lane log and one wave log in a fixture build and asserts both are priced and the rows sum to
the total.

### D-TICK-14 · the adversarial pregate reads a declared "none" as a demand for tests
*Closed 2026-08-08.*

`_adv_pregate_reject` extracted every non-blank line under `## Mandatory adversarial tests` and
gated on `[ -n "$sect" ]` — a test for *text*, not for a *list*. A ticket answering the template's
question with "None of its own — this ticket verifies, it does not build" therefore read as a
ticket demanding adversarial tests, and was rejected at rc 7 with no review session on every
round, forever: the section lives in the ticket body, so no implementation branch could ever
satisfy it. It contradicted the function's own contract three lines above, which already treats a
ticket with no adversarial section as a skip. The check rewarded silence and punished the explicit
answer the template asks for.

**Shipped:** the guard in `scripts/tick.sh` now rejects only when the section contains at least one
bullet line — `printf '%s\n' "$sect" | grep -Eq '^[[:space:]]*[-*][[:space:]]'` — with a comment
tying it back to that contract. `references/ticket-template.md` mandates "one per line" and every
real section is bulleted, so this needs no keyword list and covers "N/A", "none required" and any
future phrasing; an absent section still skips, since the grep fails on empty input too. A
prose-formatted *real* section now skips the pregate, which is the cheap direction the contract
already chooses. Zero `SKILL.md` lines, no new machine contract. `tick-test.sh` section 4i9 gains
`ADV_NONE` beside `ADV_MANDATORY` and `ADV_SILENT`, plus a mutant case that runs a copy of
`tick.sh` with the old text-only guard restored against the same fixture and asserts it rejects at
rc 7 — the red proof lives inside the suite rather than needing a hand revert. That mutant needs
`lib.sh` and its sibling scripts linked beside the copy, or it dies at source time and proves
nothing.

### D-TICK-15 · `unblock --to-review` strands a ticket whose HEAD already carries a verdict
*Closed 2026-08-08.*

`gate_of` in `snapshot.jq` refuses any ticket whose current MR head already carries an
`orch-verdict` trailer. When that standing verdict is a **FAIL**, `unblock --to-review` moved the
ticket to `review` and no step would ever act on it again: `review` is invisible to the fill step
(needs `ready-for-agent` + unclaimed), invisible to `summary.stranded` (reads `in-progress`), and
has no lane for harvest to find. Unlike the assignee-held case, nothing warned — the board showed
a ticket progressing that was permanently parked. It bites hardest right after a pregate
rejection, because a rejection caused from outside the branch leaves nothing legitimate to commit,
so HEAD never moves and the human reaches for `--to-review` exactly when it is least safe.

**Shipped:** a new `snapshot` warning in `scripts/snapshot.jq`, immediately after the assignee-held
warning it mirrors: a ticket in `review` whose `.gate.last_verdict.verdict` is `FAIL` is named
along with its head, its `gate.reason`, and the command that recovers it —
`lane.sh transition <n> ready-for-agent`, since only an implementation lane moves HEAD and only a
moved HEAD restores gate eligibility. Chosen over a refusal inside `unblock`, which is prose with
no script behind it: the warning costs no tracker calls and also catches the same stall when a
gate lane dies between posting its FAIL and moving the label. Scoped to `FAIL` because a PASS at
HEAD is already named, with its own command, by the `pass-not-in-merge-queue` repair; a live or
stale gate lane is excluded for free, since `gate_of` answers the running-lane branch before the
already-judged one and so reports `last_verdict: null`. Zero `SKILL.md` lines. `tick-test.sh`
section 7f8 asserts the warning fires, and plants two violations beside it: a FAIL at an *older*
commit must stay gateable (or every rework round false-alarms), and a PASS at HEAD must keep only
its existing repair warning. Removing the new block alone turns the suite red on exactly that
case (633 passed, 1 failed).

### D-TICK-16 · the "poll, never await" rule is prose only, and lanes keep breaking it
*Closed 2026-08-08.*

The P68 headless rules appended to every lane brief forbade "I backgrounded it and will be
notified" in prose, and lanes did it anyway: a lane started a long-running job in the background,
called `ScheduleWakeup` — a main-loop tool with nothing behind it in a headless `claude -p` — and
exited. The session ended for good, the lane died **rc 0** (neither the crash path nor the
rejection path) with its ticket still holding a dead lane and never reaching `review`, and its
background children were left alive and unreaped. Paid for twice in one day, boostlingo build-4
2026-08-08: impl-96 dead rc 0 at 162 turns over a live 300s run, impl-98 dead rc 0 at 91 turns
over a background retry loop. Two waves independently proposed a third restatement of the same
prose rule; the prose never named the tool, so a lane thinking "I'll schedule a wakeup" sailed
past a rule it had technically read.

**Shipped:** the rule moved into the plumbing. `_spawn_build_epilogue` in `scripts/tick.sh` now
appends `--disallowedTools ScheduleWakeup` to a lane's command line, so the tool is denied where a
model cannot read past it. Gated on a new `is_claude` flag rather than `stream` — `stream` answers
"does stdout go to the .jsonl?" and is turned back off for a caller-set non-streaming
`--output-format`, while the lane is still a real session that can strand itself. Appended last,
because `--disallowedTools` is variadic and would otherwise eat the next injected flag as a second
tool name; skipped whole when the caller passed their own deny list, the same rule as
`--output-format` and `--fallback-model`. The P68 brief block also names `ScheduleWakeup`
explicitly on its first bullet now, as the cheap second half of the fix. Zero `SKILL.md` lines.
`tick-test.sh` adds four cases: the flag is injected on a claude lane, it ends the command line,
a caller's own deny list is left alone and not doubled, and the appended brief names the tool.
Reverting the fix turns three of the four red (671 passed, 0 failed with it in place).

**Not shipped:** the entry's "also worth catching" note — naming a lane that dies rc 0 before
`review` as its own shape instead of lumping it into "crash" — was left out deliberately. It is a
harvest-classification change costing `SKILL.md` prose, not part of the fix, and the plumbing deny
removes the failure that motivated it.

### D-TICK-17 · a refused `worktree remove` became a "corpse" the next pass deleted with no guards at all
*Closed 2026-08-08.*

`cmd_sweep` had two delete paths and only one of them checked anything. The merged path armed on
"no commits ahead of `origin/$base`" plus "no modified **tracked** files", and its status check
filtered `??` lines out — so a lane that had not committed yet looked exactly like an empty merged
worktree: zero commits ahead, and every file it had written invisible because untracked. When
`git worktree remove --force` then failed on a root-owned `node_modules` or `.venv`, sweep printed
"kept" — but `worktree remove` is not atomic, `.git/worktrees/<name>` was already gone, and the
trailing `worktree prune` finished the job. The next pass read its own leftover as an orphaned
corpse and `rm -rf`'d it down a path with no ahead check, no dirty check and no merged check, with
`rm`'s status thrown away so a partial delete announced itself as a completed one. Confirmed live,
boostlingo build-4 #98 2026-08-08: ~100 turns of uncommitted work and an in-flight gate run gone,
the ticket's third dead lane, with five `rm` failures printed immediately above "removed".

**Shipped:** three changes in `cmd_sweep`, one per link in that chain.

* The merged path no longer filters untracked files out of its status check. Untracked here means
  untracked **and not ignored** — `git status --porcelain` never lists ignored paths, so
  `node_modules`, `.venv` and `dist/` stay invisible and the common tidy case still sweeps, while a
  lane's unsaved work keeps the worktree. The message names which of the two it found.
* A refused removal writes a `.loom-sweep-hold` marker into the directory before printing "kept",
  and the corpse path refuses any directory carrying one. The corpse path cannot re-derive the
  merged path's guards — the gitdir it would need is exactly what is gone — so an earlier pass's
  promise is the only thing that can stand there. The marker is filtered out of the merged path's
  status check, so a later pass can still retry the removal it is holding.
* The corpse path's `rm -rf` is checked, and a directory that survives it is reported as partly
  removed rather than removed.

`SKILL.md`'s one-line description of what sweep never touches now says uncommitted work of any
kind rather than "modified tracked files". Section 17 of the suite gains four cases: untracked
non-ignored work is kept, a refused removal leaves the marker, the corpse path honours it, and a
partial corpse delete is reported as partial. Its existing "leftovers are all untracked" case now
gitignores its debris, which is what that case always meant. Reverting the fix turns all four red
(710 passed, 0 failed with it in place) — and the failure output reproduces the live log exactly,
down to the "removed merged worktree" line printed over a file that was still needed.

**Not shipped:** nothing further. The two unremovable-directory cases cannot be staged as root,
where permissions do not bind; the section says so rather than asserting something weaker.

### D-TICK-18 · `-p @brief` with no `--brief` was accepted, and the lane was handed the literal string
*Closed 2026-08-08.*

`_spawn_stage_brief` refused one direction of the brief-plumbing mistake — `--brief <file>` with no
`-p @brief` placeholder in the command — and nothing asked the mirror question, so a literal
`@brief` with no file behind it passed every guard and became the session's entire prompt: an
@-mention of a file that does not exist. The pregate runs to completion first, so the discovery
costs a whole gate. Confirmed live, boostlingo build-4 #98 2026-08-08: gate-98-r3 printed
`gate[ui]: PASS` over the full `ui` tier, then asked three times which of six brief-shaped files it
was meant to read and exited rc 0 with no verdict posted.

**Shipped:** the mirror guard, in the branch of `_spawn_stage_brief` that used to return
immediately when no `--brief` was given. Any argument equal to `@brief` with no brief file dies
before anything spawns, with a message that says what the placeholder is for and names both ways
out. It matches a bare `@brief` anywhere in the command rather than only after `-p`, because an
argument that is exactly the placeholder is never anything else. `SKILL.md`'s brief paragraph now
says the flag and the placeholder are a pair. Section 23 gains three cases: the new refusal, the
refusal it mirrors (which had no test of its own either), and an ordinary command carrying its own
prompt, which must still spawn. Reverting the fix turns the first red.

**Not shipped:** the orphan briefs that gave gate-98-r3 six files to be confused by are
D-TICK-08's subject and stay open there.
