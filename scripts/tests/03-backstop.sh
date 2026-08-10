#!/usr/bin/env bash
# P3: the backstop is armed, its load verified, its absence pushed
#
# Section 03 of the tick.sh suite. Run it alone, or through
# scripts/tick-test.sh, which runs every section.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# --- 4j. P3: the backstop is armed, its load is verified, and its absence is
#      pushed once ---------------------------------------------------------
#      Build-1 2026-08-02 was kicked with a manual `tick` and left overnight
#      with nothing armed. Wave-074603 fizzled at 07:46 and NOTHING FIRED AGAIN
#      FOR 2h08m; #1 merged within 30 minutes of the human running `start` at
#      09:54. The stderr warning that shipped after crucible fired fifteen
#      times into a log nobody was reading. And after 09:54 — launchd
#      demonstrably firing the agent — every self-triggered tick still warned
#      "not installed", because `launchctl print gui/<uid>/<label>` fails from
#      a nohup'd lane's context.
#      The global stub cannot test any of this: it answers `print` 1 and
#      everything else 0, so nothing can ever be observed un-armed. This one
#      keeps a register of what it actually loaded, like launchd does.
P3T="$T/p3"; mkdir -p "$P3T/repo" "$P3T/home" "$P3T/agents"
seed_tracker_decl "$P3T/repo"
P3LOADED="$P3T/loaded"; P3REFUSE="$P3T/refuse"; P3STUB="$P3T/launchctl.sh"
P3NTFY="$P3T/pushes"
cat > "$P3STUB" <<'STUBEOF'
#!/bin/sh
lbl=$(printf '%s' "${2:-}" | sed 's|.*/||')
case "$1" in
  bootstrap) [ -f "$P3_REFUSE" ] && exit 5
             b=$(basename "$3"); printf '%s\n' "${b%.plist}" >> "$P3_LOADED"; exit 0 ;;
  bootout)   if [ -f "$P3_LOADED" ]; then
                 grep -vx "$lbl" "$P3_LOADED" > "$P3_LOADED.t" 2>/dev/null || :
                 mv "$P3_LOADED.t" "$P3_LOADED"
             fi
             exit 0 ;;
  print)     [ -n "${P3_DETACHED:-}" ] && exit 1
             grep -qx "$lbl" "$P3_LOADED" 2>/dev/null ;;
  list)      [ -n "${P3_DETACHED:-}" ] && exit 1
             grep -qx "${2:-}" "$P3_LOADED" 2>/dev/null ;;
  *)         exit 0 ;;
esac
STUBEOF
chmod +x "$P3STUB"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$P3NTFY" > "$P3T/ntfy.sh"; chmod +x "$P3T/ntfy.sh"
printf 'ntfy:\n  topic: "p3-topic"\n  push: [build_unarmed]\n' > "$P3T/repo/.loom.yml"
P3ENV() { LOOM_REPO="$P3T/repo" LOOM_HOME="$P3T/home" LOOM_PLIST_DIR="$P3T/agents" \
          LOOM_GLOBAL_CONFIG="$T/none.yml" LOOM_SKIP_BOOTSTRAP=1 LOOM_WAVE_CMD=true \
          LAUNCHCTL_CMD="$P3STUB" NTFY_CMD="$P3T/ntfy.sh" \
          P3_LOADED="$P3LOADED" P3_REFUSE="$P3REFUSE" "$@"; }
P3PLIST=$(P3ENV "$TICK" install --dry-run 2>&1 | sed -n 's/^generated (dry-run): //p')
P3LABEL=$(sed -n 's|.*<key>Label</key><string>\(.*\)</string>.*|\1|p' "$P3PLIST")
P3REAL="$P3T/agents/$P3LABEL.plist"

# A dry run must not leave a plist where the arm record lives, or a build that
# only ever previewed its agent would read itself as protected.
[ ! -f "$P3REAL" ] \
    && ok "start --dry-run: previews the plist without leaving an arm record behind" \
    || bad "start --dry-run: wrote the live plist, so an un-armed build reads as armed"

# (a) `start` arms it AND verifies the load.
: > "$P3LOADED"; rm -f "$P3REFUSE"
P3ENV "$TICK" install >/dev/null 2>&1
if [ -f "$P3REAL" ] && grep -qx "$P3LABEL" "$P3LOADED"; then
    ok "start: wrote the agent plist and launchd loaded it"
else
    bad "start: plist=$([ -f "$P3REAL" ] && echo yes || echo no) loaded=$(cat "$P3LOADED" 2>/dev/null)"
fi

# (b) Planted violation: launchd refuses the load. `start` must fail LOUDLY —
#     and leave no plist behind, because the plist file IS what every later
#     context reads as "armed". A rejected one turns the fix into a lie.
P3ENV "$TICK" uninstall >/dev/null 2>&1
: > "$P3LOADED"; : > "$P3REFUSE"
out=$(P3ENV "$TICK" install 2>&1); rc_code=$?
if [ "$rc_code" != 0 ] && printf '%s' "$out" | grep -qi "REFUSED" && [ ! -f "$P3REAL" ]; then
    ok "start: a refused load fails loudly and leaves no false arm record"
else
    bad "start: rc=$rc_code plist=$([ -f "$P3REAL" ] && echo left-behind || echo gone) out=[$out]"
fi
[ -f "$P3T/home/$P3LABEL.plist.rejected" ] \
    && ok "start: the rejected plist is kept where a human can load it by hand" \
    || bad "start: threw away the evidence of what launchd refused"

# (c) A tick on an un-armed build ARMS one instead of advising about it. This
#     is the 2h08m: the build was running on lane self-triggers alone and the
#     only thing that could have restarted it was never installed.
rm -f "$P3REFUSE" "$P3REAL" "$P3T/home/loop.stopped" "$P3T/home/agent.unarmed"
: > "$P3LOADED"
out=$(P3ENV "$TICK" tick 2>&1)
if [ -f "$P3REAL" ] && grep -qx "$P3LABEL" "$P3LOADED" && printf '%s' "$out" | grep -qi "armed one"; then
    ok "tick: an un-armed build gets a heartbeat armed, not a warning"
else
    bad "tick: armed=$([ -f "$P3REAL" ] && echo yes || echo no) out=[$out]"
fi
# And it says it once: the next tick finds it armed and is silent about it.
out=$(P3ENV "$TICK" tick 2>&1)
printf '%s' "$out" | grep -qi "armed one" \
    && bad "tick: re-announced the arming on a build that was already armed" \
    || ok "tick: an already-armed build says nothing about it"

# (d) Planted violation on the notification: launchd refuses every attempt, so
#     the build really is unprotected. That is a push to the human — ONCE per
#     state change, not the fifteen stderr lines that went into an unread log.
P3ENV "$TICK" uninstall >/dev/null 2>&1
rm -f "$P3T/home/loop.stopped" "$P3T/home/agent.unarmed" "$P3REAL"
: > "$P3LOADED"; : > "$P3REFUSE"; : > "$P3NTFY"
P3ENV "$TICK" tick >/dev/null 2>&1
P3ENV "$TICK" tick >/dev/null 2>&1
P3ENV "$TICK" tick >/dev/null 2>&1
pushes=$(grep -c 'X-Orch-Event' "$P3NTFY" 2>/dev/null || true); pushes=${pushes:-0}
[ "$pushes" = 1 ] \
    && ok "un-armed: three ticks with launchd refusing push exactly one build_unarmed" \
    || bad "un-armed: $pushes pushes across three ticks (want exactly 1)"
[ ! -f "$P3REAL" ] \
    && ok "un-armed: a refused arm leaves no plist, so the next tick retries" \
    || bad "un-armed: left a plist launchd never loaded — the build would believe it is protected"

# (e) The armed-check must work from a DETACHED context. After the human armed
#     build-1 at 09:54 launchd was demonstrably firing the agent, and every
#     self-triggered tick still read "not installed" — because it asked
#     `launchctl print gui/<uid>/<label>`, which needs the caller to be inside
#     that GUI domain. Here P3_DETACHED makes both launchd probes fail while
#     the plist sits installed: the tick must read it as armed and say nothing.
rm -f "$P3REFUSE" "$P3T/home/agent.unarmed"; : > "$P3LOADED"; : > "$P3NTFY"
P3ENV "$TICK" install >/dev/null 2>&1
out=$(P3ENV env P3_DETACHED=1 "$TICK" tick 2>&1)
if [ ! -s "$P3NTFY" ] && ! printf '%s' "$out" | grep -qi "armed one"; then
    ok "armed-check: an installed plist reads as armed from a detached lane context"
else
    bad "armed-check: detached tick re-armed or pushed on a build launchd is running ($out)"
fi
# Planted violation: same detached blindness, plist gone. Now it IS un-armed,
# and the tick must notice — proving (e) passes on the plist, not on silence.
rm -f "$P3REAL" "$P3T/home/agent.unarmed"; : > "$P3NTFY"
out=$(P3ENV env P3_DETACHED=1 "$TICK" tick 2>&1)
if [ -s "$P3NTFY" ] || printf '%s' "$out" | grep -qi "armed one"; then
    ok "armed-check: with no plist and launchd unreadable, the tick acts"
else
    bad "armed-check: an un-armed build passed unnoticed ($out)"
fi

# (f) A stopped loop arms nothing. `start` is the only thing allowed to put a
#     timer back — a tick that armed one during a stop would tick a build the
#     human deliberately switched off.
P3ENV "$TICK" uninstall >/dev/null 2>&1
rm -f "$P3REAL" "$P3REFUSE" "$P3T/home/agent.unarmed"; : > "$P3LOADED"; : > "$P3NTFY"
: > "$P3T/home/loop.stopped"
P3ENV "$TICK" tick >/dev/null 2>&1
if [ ! -f "$P3REAL" ] && [ ! -s "$P3NTFY" ]; then
    ok "stop: a tick during a stop arms no timer and pushes nothing"
else
    bad "stop: a tick re-armed a deliberately stopped build"
fi
rm -f "$P3T/home/loop.stopped"

test_finish
