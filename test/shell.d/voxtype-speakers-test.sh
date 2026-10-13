#!/bin/bash

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export SPEAKERS_LOG="$test_tmp/calls" VOXTYPE_PORTS="FL FR"
mkdir -p "$test_tmp/bin"
export PATH="$test_tmp/bin:$ROOT/bin:$PATH"

cat > "$test_tmp/bin/voxtype" <<'SH'
#!/bin/bash
printf 'voxtype %s\n' "$*" >> "$SPEAKERS_LOG"
if [[ $1 == "status" ]]; then echo recording; fi
SH
cat > "$test_tmp/bin/pactl" <<'SH'
#!/bin/bash
echo speakers
SH
cat > "$test_tmp/bin/pw-link" <<'SH'
#!/bin/bash
case "$1" in
  -i) for ch in $VOXTYPE_PORTS; do echo "alsa_capture.voxtype-avx512:input_$ch"; done ;;
  -o) for ch in FL FR; do echo "mic:capture_$ch"; echo "speakers:monitor_$ch"; done ;;
  -l)
    for ch in $VOXTYPE_PORTS; do
      echo "alsa_capture.voxtype-avx512:input_$ch"
      echo "  |<- mic:capture_$ch"
    done
    ;;
  *) printf 'pw-link %s\n' "$*" >> "$SPEAKERS_LOG" ;;
esac
SH
cat > "$test_tmp/bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf 'notify %s\n' "$*" >> "$SPEAKERS_LOG"
SH
chmod +x "$test_tmp/bin/"*

omarchy-voxtype-speakers start
expected="voxtype record start
pw-link -d mic:capture_FL alsa_capture.voxtype-avx512:input_FL
pw-link speakers:monitor_FL alsa_capture.voxtype-avx512:input_FL
pw-link -d mic:capture_FR alsa_capture.voxtype-avx512:input_FR
pw-link speakers:monitor_FR alsa_capture.voxtype-avx512:input_FR"
[[ $(cat "$SPEAKERS_LOG") == "$expected" ]] || fail "start swaps the microphone links for the matching speaker channels"
pass "speaker dictation relinks Voxtype from the microphone to the speaker monitor"

: > "$SPEAKERS_LOG"
VOXTYPE_PORTS=MONO omarchy-voxtype-speakers start
expected="voxtype record start
pw-link -d mic:capture_MONO alsa_capture.voxtype-avx512:input_MONO
pw-link speakers:monitor_FL alsa_capture.voxtype-avx512:input_MONO
pw-link speakers:monitor_FR alsa_capture.voxtype-avx512:input_MONO"
[[ $(cat "$SPEAKERS_LOG") == "$expected" ]] || fail "a mono capture stream mixes in every speaker channel"
pass "speaker dictation handles channel layouts that don't match"

: > "$SPEAKERS_LOG"
if VOXTYPE_PORTS="" omarchy-voxtype-speakers start; then fail "a missing capture stream must fail"; fi
grep -q '^voxtype record cancel$' "$SPEAKERS_LOG" || fail "a missing capture stream cancels the recording"
grep -q '^notify ' "$SPEAKERS_LOG" || fail "a missing capture stream is reported"
pass "speaker dictation cancels instead of recording the microphone"

: > "$SPEAKERS_LOG"
omarchy-voxtype-speakers stop
[[ $(cat "$SPEAKERS_LOG") == $'voxtype status\nvoxtype record stop' ]] || fail "stop finishes the Voxtype recording"
if omarchy-voxtype-speakers 2> /dev/null; then fail "missing action must fail"; fi
pass "speaker dictation stops through the Voxtype adapter"
