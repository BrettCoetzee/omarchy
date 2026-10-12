#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command jq
require_command script

tmpdir=$(mktemp -d)
cleanup() {
  [[ -n ${screensaver_pid:-} ]] && kill "$screensaver_pid" 2>/dev/null || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

mkdir -p "$tmpdir/bin"

cat >"$tmpdir/bin/hyprctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_DIR/hyprctl"
[[ $* == "activewindow -j" ]] && printf '{"class":"%s"}\n' "$(<"$TEST_DIR/active")"
exit 0
SH
cat >"$tmpdir/bin/socat" <<'SH'
#!/bin/bash
exec cat "$TEST_DIR/events"
SH
cat >"$tmpdir/bin/ttfx" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_DIR/ttfx"
printf 'ttfx\n' >>"$TEST_DIR/order"
printf '%s\n' "$$" >>"$TEST_DIR/ttfx.pids"
sleep "$(<"$TEST_DIR/effect-seconds")"
exit "$(<"$TEST_DIR/effect-exit")"
SH
# Ends the running effects the way the real pkill -x ttfx would, then gives a
# loop that is still running time to start another before the windows close.
cat >"$tmpdir/bin/pkill" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_DIR/pkill"
printf 'pkill %s\n' "$*" >>"$TEST_DIR/order"
if [[ $* == "-x ttfx" ]]; then
  xargs -r kill 2>/dev/null <"$TEST_DIR/ttfx.pids"
  sleep 0.5
fi
exit 0
SH
chmod +x "$tmpdir/bin/"*

# Start the screensaver in a pty, the way a terminal runs it. Keys go in
# through $keys and Hyprland events through $events.
start_screensaver() {
  printf '%s\n' "${2:-600}" >"$tmpdir/effect-seconds"
  printf '%s\n' "${3:-0}" >"$tmpdir/effect-exit"
  : >"$tmpdir/hyprctl"
  : >"$tmpdir/ttfx"
  : >"$tmpdir/ttfx.pids"
  : >"$tmpdir/order"
  : >"$tmpdir/pkill"
  printf '%s\n' "$1" >"$tmpdir/active"
  rm -f "$tmpdir/events" "$tmpdir/keys" "$tmpdir/done"
  mkfifo "$tmpdir/events" "$tmpdir/keys"
  # Read-write, so opening never waits for the other end.
  exec {keys}<>"$tmpdir/keys" {events}<>"$tmpdir/events"
  (
    # Only the test writes events, so closing its end ends the stream.
    exec {keys}>&- {events}>&-
    PATH="$tmpdir/bin:$PATH" TEST_DIR="$tmpdir" XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=test \
      timeout 15 script -qfec "$ROOT/bin/omarchy-screensaver" /dev/null <"$tmpdir/keys" >/dev/null 2>&1
    touch "$tmpdir/done"
  ) &
  screensaver_pid=$!
}

stop_screensaver() {
  exec {keys}>&- {events}>&-
  wait "$screensaver_pid" 2>/dev/null || true
  screensaver_pid=""
}

wait_for() {
  local attempt
  for (( attempt = 0; attempt < 100; attempt++ )); do
    [[ -e $1 ]] && return 0
    sleep 0.05
  done
  return 1
}

focus_checks() {
  grep -c '^activewindow -j$' "$tmpdir/hyprctl" || true
}

start_screensaver org.omarchy.screensaver
sleep 3.5
[[ -e $tmpdir/done ]] && fail "the screensaver keeps running while it has focus"
(( $(focus_checks) == 1 )) || fail "focus is checked once at start, not on a timer" "$(<"$tmpdir/hyprctl")"
pass "focus is checked once at start, not on a timer"

printf 'activewindow>>org.omarchy.screensaver,other monitor\n' >&"$events"
sleep 1.5
[[ -e $tmpdir/done ]] && fail "focus moving to another monitor's screensaver keeps it running"
(( $(focus_checks) == 1 )) || fail "focus moving to another screensaver needs no check" "$(<"$tmpdir/hyprctl")"
pass "focus moving to another monitor's screensaver keeps it running"

# Focus passing through another window and back, as the launcher moves it
# between monitors, is confirmed before anything closes.
printf 'activewindow>>firefox,Mozilla Firefox\n' >&"$events"
sleep 1.5
[[ -e $tmpdir/done ]] && fail "focus that comes back within a second keeps the screensaver"
pass "focus that comes back within a second keeps the screensaver"

printf 'firefox\n' >"$tmpdir/active"
printf 'activewindow>>firefox,Mozilla Firefox\n' >&"$events"
wait_for "$tmpdir/done" || fail "the screensaver exits once another window takes focus"
grep -qx -- '-f \[o\]rg.omarchy.screensaver' "$tmpdir/pkill" || fail "exiting closes every screensaver window" "$(<"$tmpdir/pkill")"
pass "the screensaver exits once another window takes focus"
stop_screensaver

start_screensaver org.omarchy.screensaver
sleep 0.5
printf 'x' >&"$keys"
wait_for "$tmpdir/done" || fail "a key press ends the screensaver"
pass "a key press ends the screensaver"
stop_screensaver

start_screensaver firefox
wait_for "$tmpdir/done" || fail "a screensaver that never had focus exits"
pass "a screensaver that never had focus exits"
stop_screensaver

# Effects follow one another, and none starts once the screensaver has ended.
start_screensaver org.omarchy.screensaver 0.2
sleep 1.5
effects=$(wc -l <"$tmpdir/ttfx")
(( effects >= 3 )) || fail "effects play one after another" "$effects effects in 1.5 s"
printf 'x' >&"$keys"
wait_for "$tmpdir/done" || fail "a key ends the screensaver between effects"
[[ $(sed -n '/^pkill -x ttfx$/,$p' "$tmpdir/order") != *ttfx$'\n'*ttfx* ]] ||
  fail "no effect starts once the screensaver is ending" "$(<"$tmpdir/order")"
effects=$(wc -l <"$tmpdir/ttfx")
sleep 1
(( $(wc -l <"$tmpdir/ttfx") == effects )) || fail "no effect starts after the screensaver ends"
pass "effects play one after another, and none starts after the screensaver ends"
stop_screensaver

# omarchy-system-lock stops ttfx and waits for it before closing the window;
# an effect ended that way starts no replacement.
# The effect runs until it is signalled, so the signal lands on a live one.
start_screensaver org.omarchy.screensaver
for (( attempt = 0; attempt < 100; attempt++ )); do
  [[ -s $tmpdir/ttfx.pids ]] && break
  sleep 0.05
done
[[ -s $tmpdir/ttfx.pids ]] || fail "the first effect starts"
effects=$(wc -l <"$tmpdir/ttfx")
xargs -r kill <"$tmpdir/ttfx.pids"
# Longer than the pause before retrying a failed effect.
sleep 2
(( $(wc -l <"$tmpdir/ttfx") == effects )) || fail "an effect stopped from outside starts no other" "$(<"$tmpdir/order")"
pass "an effect stopped from outside, as locking does, starts no other"
printf 'x' >&"$keys"
wait_for "$tmpdir/done" || fail "a key still ends the screensaver once its effects stop"
stop_screensaver

# Without Hyprland's event stream focus can't be followed, so it leaves.
start_screensaver org.omarchy.screensaver
sleep 1.5
exec {events}>&-
wait_for "$tmpdir/done" || fail "the screensaver exits when the event stream ends"
pass "the screensaver exits when the event stream ends"
stop_screensaver

# A failed effect is retried after a pause, not in a tight loop.
start_screensaver org.omarchy.screensaver 0 1
sleep 2.5
effects=$(wc -l <"$tmpdir/ttfx")
(( effects >= 2 && effects <= 4 )) || fail "a failed effect is retried after a pause" "$effects effects in 2.5 s"
pass "a failed effect is retried after a pause"
printf 'x' >&"$keys"
wait_for "$tmpdir/done" || fail "a key ends the screensaver while effects fail"
stop_screensaver
