#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

usage() {
  cat <<'EOF'
usage: measure_tab_pill.sh [--screenshot <path>] [--retina <scale>]
                           [--y-band-lo <fraction>] [--y-band-hi <fraction>]
                           [--min-gap-px <int>]

Measures the iOS 26 floating tab pill in a screenshot and emits a
MAIN_TABS_COORDS line ready to paste into .claude/ios-build-verify.config.sh.

By default takes a fresh screenshot via screenshot.sh. Pass --screenshot to
analyze an existing PNG (useful when re-measuring without driving the sim).
--retina overrides the simulator's retina scale (default 3, correct for
iPhone 17 / iPhone 17 Pro). --y-band-lo / --y-band-hi override the
fraction-of-image y-range searched (defaults 0.92 - 0.965, tight to the
icon row of the iOS 26 floating pill — labels live below 0.965 and bridge
inter-icon gaps for dense pills, so the band must exclude them).
--min-gap-px overrides the minimum zero-run width (default 20 image-pixels)
that splits adjacent tabs.

Algorithm: detects the pill background by 16-level color quantization of the
middle third of the y-band (most reliably inside the pill), picks the modal
bin — works for both light-mode (near-white pill bg) and dark-mode (dark
grey pill bg). Defines an "icon pixel" as one whose RGB differs from the
detected pill bg by more than 40 in any channel, then restricts to the tight
icon-row y-band, projects icon-pixel counts to a 1D x-histogram per column,
and splits clusters at zero-runs of at least --min-gap-px image pixels. Each
cluster's count-weighted centroid is a tab x-coordinate. Three filters drop
non-tab clusters: a 30%-of-peak fill threshold (drops pill-edge shadow), a
60%-of-peak cluster-peak filter (drops scrolling content showing through the
pill y-band), and a 10-pixel minimum cluster width (drops single-pixel noise
spikes). Validated against AztecCal's 3-tab pill (detected centers match
the canonical (115, 201, 287) shipped coords to within sub-pixel precision)
and Konjugieren's 5-tab dark-mode pill (~69pt even spacing — geometric
signature of a correct read).

Output: a comment summary on stderr followed by `MAIN_TABS_COORDS=(...)` on
stdout. The MAIN_TABS_COORDS line is the last line of stdout, so callers can
extract it via `tail -1`.

Dependencies: python3 (stock on macOS 12.3+) + Pillow. If Pillow is missing
the script prints an install command and exits 4.

Exit codes: 0 success; 2 config missing or bad arg; 3 pill not detected (try
re-screenshoting on the main TabView screen, or pass --screenshot manually);
4 Pillow not installed; 5 detected count differs from MAIN_TABS length
(emits the MAIN_TABS_COORDS line on stdout for inspection — the algorithm
may have over- or under-segmented; manual review needed; try
--y-band-lo/--y-band-hi or --min-gap-px overrides).
EOF
}

SCREENSHOT=""
RETINA="3"
Y_BAND_LO="0.92"
Y_BAND_HI="0.965"
MIN_GAP_PX="20"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --screenshot) SCREENSHOT="$2"; shift 2 ;;
    --retina) RETINA="$2"; shift 2 ;;
    --y-band-lo) Y_BAND_LO="$2"; shift 2 ;;
    --y-band-hi) Y_BAND_HI="$2"; shift 2 ;;
    --min-gap-px) MIN_GAP_PX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$SCREENSHOT" ]]; then
  echo "no --screenshot passed; taking fresh screenshot via screenshot.sh..." >&2
  SCREENSHOT=$("$SCRIPT_DIR/screenshot.sh" "tabbar-measure")
  echo "screenshot: $SCREENSHOT" >&2
fi

if [[ ! -f "$SCREENSHOT" ]]; then
  echo "error: screenshot file not found: $SCREENSHOT" >&2
  exit 2
fi

if ! python3 -c 'import PIL' 2>/dev/null; then
  echo "error: Pillow (Python PIL image library) is required but not installed." >&2
  echo "install via either:" >&2
  echo "  python3 -m pip install --user --break-system-packages Pillow   # pip path (recommended)" >&2
  echo "  brew install pillow                                            # Homebrew path (heavier; pulls in image-codec deps)" >&2
  exit 4
fi

EXPECTED_COUNT=0
[[ ${MAIN_TABS+x} ]] && EXPECTED_COUNT="${#MAIN_TABS[@]}"

set +e
OUTPUT=$(python3 - "$SCREENSHOT" "$RETINA" "$Y_BAND_LO" "$Y_BAND_HI" "$MIN_GAP_PX" <<'PYEOF'
import collections
import sys
from PIL import Image

PATH = sys.argv[1]
RETINA = float(sys.argv[2])
Y_BAND_LO = float(sys.argv[3])
Y_BAND_HI = float(sys.argv[4])
MIN_GAP_PX = int(sys.argv[5])
MIN_CLUSTER_PX = 10  # narrower clusters are noise spikes (e.g. shadow artifacts)
ICON_DELTA = 40  # per-channel distance from pill bg that defines an icon pixel

try:
    img = Image.open(PATH).convert("RGB")
except Exception as e:
    print(f"error: failed to read screenshot: {e}", file=sys.stderr)
    sys.exit(3)

W, H = img.size
pixels = img.load()
y_lo, y_hi = int(H * Y_BAND_LO), int(H * Y_BAND_HI)

# Detect the pill background color from the middle third of the y-band, where
# the pill is most reliably present (above and below this stripe the y-band
# may straddle the view background showing through). Quantize to 16-level bins
# and pick the most common — works for both light-mode (near-white pill bg)
# and dark-mode (dark grey pill bg) without a hand-coded heuristic. Earlier
# light-mode-only `is_icon_pixel = max < 200 or sat > 30` failed in dark mode
# because every dark-mode pixel has max < 200, so the entire y-band classified
# as icon and zero-gap clustering merged everything.
y_mid_lo = y_lo + (y_hi - y_lo) // 3
y_mid_hi = y_lo + 2 * (y_hi - y_lo) // 3
bg_counter = collections.Counter()
for y in range(y_mid_lo, y_mid_hi):
    for x in range(0, W, 4):
        p = pixels[x, y]
        bg_counter[(p[0] // 16, p[1] // 16, p[2] // 16)] += 1
bg_q = bg_counter.most_common(1)[0][0]
bg_R, bg_G, bg_B = bg_q[0] * 16 + 8, bg_q[1] * 16 + 8, bg_q[2] * 16 + 8

def is_icon_pixel(p):
    # Icon = pixel that differs from the detected pill background by more than
    # ICON_DELTA in any RGB channel. Color-agnostic: dark icons in light-mode,
    # bright icons in dark-mode, and saturated/tinted selected icons all
    # qualify. The view background showing through (above/below the pill) is
    # close to the pill bg in mode-coordinated apps and stays below threshold.
    return (abs(p[0] - bg_R) > ICON_DELTA or
            abs(p[1] - bg_G) > ICON_DELTA or
            abs(p[2] - bg_B) > ICON_DELTA)

col_counts = [sum(1 for y in range(y_lo, y_hi) if is_icon_pixel(pixels[x, y])) for x in range(W)]

peak_max = max(col_counts, default=0)
if peak_max == 0:
    print(f"error: no icon content found in y-band {y_lo}-{y_hi}px. Verify the screenshot shows the floating tab pill.", file=sys.stderr)
    sys.exit(3)

# Three-step clustering: (1) threshold at 30% of the global peak column-count
# to drop pill-edge shadow and low-density artifacts; (2) split the
# thresholded mask at zero-runs of at least MIN_GAP_PX so dense pills
# separate cleanly; (3) drop clusters whose own peak column-count is below
# 60% of the global peak — this filters non-pill content showing through the
# bottom of the screen (e.g. a Picker wheel or scrolling list whose pixels
# overlap the pill y-band but are visually outside the pill itself). The
# three together are robust against both failure modes seen in the wild:
# (a) a global threshold alone sees one merged region spanning the entire
# pill when label/background pixels bridge inter-icon columns (Konjugieren
# 5-tab), and (b) zero-gap splitting on raw counts over-segments because
# pill-edge shadow and underlying-view content register as low-density
# columns (AztecCal Convert tab, where date-picker wheel rows extend into
# the pill y-band).
fill_threshold = max(3, peak_max * 0.3)
cluster_peak_min = peak_max * 0.6

peaks = []
i = 0
while i < W:
    if col_counts[i] >= fill_threshold:
        cluster_start = i
        last_filled = i
        zero_run = 0
        while i < W:
            if col_counts[i] >= fill_threshold:
                last_filled = i
                zero_run = 0
            else:
                zero_run += 1
                if zero_run >= MIN_GAP_PX:
                    break
            i += 1
        cluster_end = last_filled + 1
        if cluster_end - cluster_start >= MIN_CLUSTER_PX:
            cluster_peak = max(col_counts[k] for k in range(cluster_start, cluster_end))
            if cluster_peak >= cluster_peak_min:
                total = sum(col_counts[k] for k in range(cluster_start, cluster_end))
                cx = (sum(k * col_counts[k] for k in range(cluster_start, cluster_end)) / total
                      if total > 0 else (cluster_start + cluster_end) / 2)
                peaks.append(cx)
    else:
        i += 1

if not peaks:
    print("error: no tab clusters found (all column counts below noise floor).", file=sys.stderr)
    sys.exit(3)

# Estimate y-center: for each peak x, find the median y of icon pixels in a
# narrow column around the peak. This gives the visual icon center, not the
# midpoint of the search band (which can be off when the search band is
# generous around a tighter actual icon row).
def y_center_at_x(cx):
    cx_i = int(round(cx))
    icon_ys = []
    for dx in range(-3, 4):
        x = cx_i + dx
        if 0 <= x < W:
            for y in range(y_lo, y_hi):
                if is_icon_pixel(pixels[x, y]):
                    icon_ys.append(y)
    if not icon_ys:
        return (y_lo + y_hi) // 2
    icon_ys.sort()
    return icon_ys[len(icon_ys) // 2]

y_centers_px = [y_center_at_x(cx) for cx in peaks]
# Use the median y across all peaks for the canonical pill y (icons share the
# same row in iOS 26's pill layout).
y_centers_px.sort()
pill_y_center_px = y_centers_px[len(y_centers_px) // 2]

points = [round(p / RETINA, 1) for p in peaks]
y_pt = round(pill_y_center_px / RETINA, 1)
coord_pairs = [f'"{x:g},{y_pt:g}"' for x in points]
print(f"# detected {len(peaks)} tab(s) in y-band {y_lo}-{y_hi}px (retina={RETINA})", file=sys.stderr)
print(f"# raw centroids (px): {[round(p, 1) for p in peaks]}", file=sys.stderr)
print(f"MAIN_TABS_COORDS=({' '.join(coord_pairs)})")
PYEOF
)
PY_RC=$?
set -e

echo "$OUTPUT"
[[ $PY_RC -eq 0 ]] || exit $PY_RC

if [[ "$EXPECTED_COUNT" -gt 0 ]]; then
  DETECTED=$(echo "$OUTPUT" | grep -oE 'MAIN_TABS_COORDS=\([^)]*\)' | grep -oE '"[0-9.]+,[0-9.]+"' | wc -l | tr -d ' ')
  if [[ "$DETECTED" -ne "$EXPECTED_COUNT" ]]; then
    echo "warning: detected $DETECTED tab(s) but MAIN_TABS has $EXPECTED_COUNT entries (${MAIN_TABS[*]}); the algorithm may have over- or under-segmented. Manual review or a fresh screenshot may help." >&2
    exit 5
  fi
fi
