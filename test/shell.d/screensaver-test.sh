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
exec sleep 600
SH
cat >"$tmpdir/bin/pkill" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_DIR/pkill"
SH
chmod +x "$tmpdir/bin/"*

# Start the screensaver in a pty, the way a terminal runs it. Keys go in
# through $keys and Hyprland events through $events.
start_screensaver() {
  : >"$tmpdir/hyprctl"
  : >"$tmpdir/ttfx"
  : >"$tmpdir/pkill"
  printf '%s\n' "$1" >"$tmpdir/active"
  rm -f "$tmpdir/events" "$tmpdir/keys" "$tmpdir/done"
  mkfifo "$tmpdir/events" "$tmpdir/keys"
  # Read-write, so opening never waits for the other end.
  exec {keys}<>"$tmpdir/keys" {events}<>"$tmpdir/events"
  (
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
[[ $(<"$tmpdir/ttfx") == *"--frame-rate 60 "* ]] || fail "effects play at 60 frames per second" "$(<"$tmpdir/ttfx")"
pass "effects play at 60 frames per second"
(( $(focus_checks) == 1 )) || fail "focus is checked once at start, not on a timer" "$(<"$tmpdir/hyprctl")"
pass "focus is checked once at start, not on a timer"

printf 'activewindow>>org.omarchy.screensaver,other monitor\n' >&"$events"
sleep 1.5
[[ -e $tmpdir/done ]] && fail "focus moving to another monitor's screensaver keeps it running"
(( $(focus_checks) == 1 )) || fail "focus moving to another screensaver needs no check" "$(<"$tmpdir/hyprctl")"
pass "focus moving to another monitor's screensaver keeps it running"

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
