#!/usr/bin/env bash
# Pixel-level smoke test for kogi_webview under a real Wayland compositor.
#
# Runs the example (built with --dart-define=KOGI_SMOKE=true) inside headless
# Weston, screenshots it, and checks that the WebKit page shows through
# Flutter's hole while Flutter content (an opaque background and a floating
# toast) still draws where it should. This catches the failure that X11-only
# testing misses: Flutter's Wayland subsurface hiding the WebKit view.
#
# Usage: tool/wayland_smoke.sh <example binary> [screenshot out.png]
# Needs: weston (with weston-screenshooter), ImageMagick, python3.
set -euo pipefail

bin=${1:?usage: wayland_smoke.sh <example binary> [out.png]}
out=${2:-kogi-webview-smoke.png}
width=1100
height=760

# Wayland socket paths must stay under 108 bytes.
runtime=$(mktemp -d /tmp/kogi.XXXXXX)
chmod 700 "$runtime"
log="$runtime/app.log"
cleanup() {
  [[ -n ${app:-} ]] && kill "$app" 2>/dev/null || true
  [[ -n ${weston:-} ]] && kill "$weston" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$runtime"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR=$runtime
weston --backend=headless --renderer=gl --width=$width --height=$height \
  --socket=kogi --shell=kiosk --debug >"$runtime/weston.log" 2>&1 &
weston=$!
for _ in $(seq 50); do [[ -S $runtime/kogi ]] && break; sleep 0.2; done
[[ -S $runtime/kogi ]] || { cat "$runtime/weston.log"; echo "weston did not start"; exit 1; }

WAYLAND_DISPLAY=kogi GDK_BACKEND=wayland "$bin" >"$log" 2>&1 &
app=$!

ready=
for _ in $(seq 120); do
  ready=$(grep -m1 -o 'KOGI_SMOKE_READY .*' "$log" || true)
  [[ -n $ready ]] && break
  kill -0 "$app" 2>/dev/null || break
  sleep 0.5
done
if [[ -z $ready ]]; then
  cat "$log"
  echo "FAIL: the example never reported KOGI_SMOKE_READY"
  exit 1
fi
sleep 1  # let WebKit paint and Weston composite
if grep -q 'kogi_webview:' "$log"; then
  grep 'kogi_webview:' "$log"
  echo "FAIL: the plugin logged a warning (see above)"
  exit 1
fi

shot_dir=$(mktemp -d "$runtime/shot.XXXX")
(cd "$shot_dir" && WAYLAND_DISPLAY=kogi weston-screenshooter >/dev/null 2>&1)
shot=$(ls "$shot_dir"/*.png | head -1)
cp "$shot" "$out"

python3 - "$out" "${ready#KOGI_SMOKE_READY }" "$width" "$height" <<'PY'
import json, subprocess, sys

png, rect, width, height = sys.argv[1], json.loads(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
d = rect["dpr"]

def px(x, y):
    x, y = round(x * d), round(y * d)
    raw = subprocess.run(
        ["convert", png, "-crop", f"1x1+{x}+{y}", "+repage", "-depth", "8", "rgb:-"],
        check=True, capture_output=True).stdout
    return tuple(raw[:3])

def near(c, want, tol=40):
    return all(abs(a - b) <= tol for a, b in zip(c, want))

x, y, w = rect["x"], rect["y"], rect["w"]
checks = [
    ("WebKit red band shows through the hole", (x + 40, y + 40), (0xE0, 0x00, 0x00)),
    ("WebKit blue band shows through the hole", (x + 40, y + 340), (0x00, 0x44, 0xEE)),
    ("opaque Flutter background around the hole", (x - 12, y + 40), (0x15, 0x18, 0x1A)),
    # The toast is 260 wide, 24 from the right and bottom edges.
    ("Flutter toast draws above WebKit", (width / d - 24 - 230, height / d - 24 - 8), (0x00, 0xC8, 0x53)),
]
failed = 0
for name, (cx, cy), want in checks:
    got = px(cx, cy)
    ok = near(got, want)
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'}: {name} at {cx:.0f},{cy:.0f}: got #{got[0]:02x}{got[1]:02x}{got[2]:02x}, want #{want[0]:02x}{want[1]:02x}{want[2]:02x}")
sys.exit(1 if failed else 0)
PY
