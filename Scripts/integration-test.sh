#!/bin/zsh
# End-to-end smoke test against the real emulator. Not run in CI.
#
# Invoke through run-ui-tests.py, which creates an isolated hidden Debug app
# and fresh guest data. No Accessibility or Screen Recording permissions needed.
set -euo pipefail

APP="${APP:-$(ls -d ~/Library/Developer/Xcode/DerivedData/Mandroid-*/Build/Products/Debug/Mandroid.app 2>/dev/null | head -1)}"
APK="${APK:-}"
PKG="${PKG:-com.github.shadowsocks}"
OUT="${OUT:-$(mktemp -d /tmp/aar-it.XXXXXX)}"
SCRIPT_DIR="${0:A:h}"
: "${UI_TEST_CONTROL:?Run through Scripts/run-ui-tests.py}"
: "${UI_TEST_DATA_ROOT:?Run through Scripts/run-ui-tests.py}"
AS="$UI_TEST_DATA_ROOT"
url() { python3 "$SCRIPT_DIR/ui-test-command.py" "$1"; }

fail() { echo "FAIL: $*" >&2; exit 1; }
snap() {
  rm -rf "$OUT/$1"; url "mandroid://debug/snapshot?dir=$OUT/$1"
  for i in $(seq 1 20); do sleep 0.5; [[ -f "$OUT/$1/state.txt" ]] && break; done
  grep -q '^offscreen=true' "$OUT/$1/state.txt" || fail "not offscreen"
  grep -q '^visibleWindows=0' "$OUT/$1/state.txt" || fail "test showed a window"
  cat "$OUT/$1/state.txt" 2>/dev/null; echo
}
hook() { url "mandroid://debug/$1"; }

[[ -d "$APP" ]] || fail "app not built: $APP"
echo "==> waiting for offscreen Mandroid"
T0=$(date +%s)
for i in $(seq 1 120); do
  sleep 5
  snap boot >/dev/null 2>&1 || true
  if grep -q '^state=ready' "$OUT/boot/state.txt" 2>/dev/null; then break; fi
  if grep -q '^state=failed' "$OUT/boot/state.txt" 2>/dev/null; then cat "$OUT/boot/state.txt"; fail "boot failed"; fi
done
grep -q '^state=ready' "$OUT/boot/state.txt" || fail "not ready after 10 minutes"
echo "==> ready after $(( $(date +%s) - T0 )) s"

ADB="$AS/sdk/platform-tools/adb"
PORT=$(grep -oE '^adbPort=[0-9]+' "$OUT/boot/state.txt" | cut -d= -f2)
export ANDROID_SERIAL=$(sed -n 's/^serial=//p' "$OUT/boot/state.txt")
[[ -n "$ANDROID_SERIAL" ]] || fail "missing test emulator serial"
export ANDROID_ADB_SERVER_PORT="$PORT"
export ANDROID_HOME="$AS/sdk" ANDROID_SDK_ROOT="$AS/sdk"
export ANDROID_AVD_HOME="$AS/avd" ANDROID_EMULATOR_HOME="$AS/emulator-home"
echo "==> adb server port $PORT"
"$ADB" shell wm size | grep -F 'Physical size: 2560x1600' >/dev/null || fail "tablet resolution not active"
"$ADB" shell wm density | grep -F 'Physical density: 320' >/dev/null || fail "tablet density not active"

if [[ -n "$APK" ]]; then
  echo "==> installing $APK"
  url "$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$APK")"
  for i in {1..60}; do
    sleep 2
    snap installed >/dev/null
    grep -qF "\"$PKG\"" "$OUT/installed/state.txt" && break
    if grep -q '^lastError=.' "$OUT/installed/state.txt"; then
      cat "$OUT/installed/state.txt"; fail "APK installation failed"
    fi
  done
fi
snap installed; grep -qF "\"$PKG\"" "$OUT/installed/state.txt" || fail "$PKG not installed"

echo "==> opening $PKG"
url "mandroid://launch/$PKG"
url "mandroid://launch/$PKG"
url "mandroid://launch/$PKG"; sleep 8
snap opened; grep -qF "sessions=[\"$PKG\"]" "$OUT/opened/state.txt" || fail "no session for $PKG"
secondaries() { "$ADB" shell dumpsys display | grep -oE 'uniqueId="virtual:com.android.emulator.multidisplay:[0-9]+"' | sort -u | wc -l | tr -d ' '; }
[[ $(secondaries) == 1 ]] || fail "expected one secondary display, got $(secondaries)"
python3 - "$OUT/opened/$(ls "$OUT/opened" | grep -v -e state.txt -e Library -e Device | head -1)" <<'PY' || fail "frame is blank"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
lo, hi = im.getextrema()[0]
assert hi - lo > 40, f"flat image {im.getextrema()}"
print("frame ok", im.size)
PY

echo "==> input: click, type, scroll, resize, back"
hook "click?pkg=$PKG&x=210&y=450"; sleep 1
hook "type?pkg=$PKG&text=abc"; sleep 1
hook "scroll?pkg=$PKG&x=210&y=600&dy=-300"; sleep 1
hook "scroll?pkg=$PKG&x=210&y=600&lines=-1"; sleep 1
# Match on captured output: grep -q under pipefail can fail adb with SIGPIPE.
[[ "$("$ADB" shell ps -A -o ARGS)" == *'app_process / ScrollInjector'* ]] || fail "scroll helper not running"
# Send several sizes without waiting for Android to finish each update.
# Verify the final guest resolution AND the actual streamed frame/input size.
for size in '480&h=700' '800&h=420' '420&h=800' '1280&h=800'; do
  hook "resize?pkg=$PKG&w=$size"
  sleep 0.2
done
W=0 H=0
for i in $(seq 1 20); do
  snap resized >/dev/null
  SCALE=$(sed -n "s/^rendered=$PKG .* scale=//p" "$OUT/resized/state.txt")
  if [[ -n "$SCALE" ]]; then
    W=$(awk "BEGIN {print int(1280 * $SCALE)}")
    H=$(awk "BEGIN {print int(800 * $SCALE)}")
    if grep -qF "rendered=$PKG pixels=${W}x${H} input=${W}x${H}" "$OUT/resized/state.txt" &&
       "$ADB" shell dumpsys display | grep -E "multidisplay:1234562\", $W x $H" >/dev/null; then
      break
    fi
  fi
  sleep 0.5
done
grep -qF "rendered=$PKG pixels=${W}x${H} input=${W}x${H}" "$OUT/resized/state.txt" || fail "frame/input did not adopt final resolution"
"$ADB" shell dumpsys display | grep -E "multidisplay:1234562\", $W x $H" >/dev/null || fail "display was not resized in place"
snap after_input >/dev/null

echo "==> closing a parked window after its slot is reused"
hook "park?pkg=$PKG"; sleep 3
[[ $(secondaries) == 0 ]] || fail "parking did not release display"
url 'mandroid://launch/com.android.settings'; sleep 8
[[ $(secondaries) == 1 ]] || fail "replacement display not allocated"
hook "close?pkg=$PKG"; sleep 3
[[ $(secondaries) == 1 ]] || fail "parked close removed another app's display"
snap parked_closed >/dev/null
grep -qF 'sessions=["com.android.settings"]' "$OUT/parked_closed/state.txt" || fail "replacement session was lost"
hook 'close?pkg=com.android.settings'; sleep 3
[[ $(secondaries) == 0 ]] || fail "secondary display not released"
"$ADB" shell pidof "$PKG" >/dev/null && fail "$PKG still running after close" || true

snap final >/dev/null
grep -q '^offscreen=true' "$OUT/final/state.txt" || fail "not an offscreen test instance"
grep -q '^visibleWindows=0' "$OUT/final/state.txt" || fail "test showed a window"
echo "==> native media volume and Settings"
mkdir -p "$OUT/volume"
OUT="$OUT/volume" zsh "$SCRIPT_DIR/volume-test.sh"
echo "PASS (artifacts in $OUT)"
