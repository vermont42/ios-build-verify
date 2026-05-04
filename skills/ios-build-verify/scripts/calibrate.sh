#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: calibrate.sh [--skip-build] [--tab-anchors "anchor1 anchor2 ..."]

Composes build_app + launch_app + measure_tab_pill + (optional) tap-and-verify
each tab into a single end-to-end calibration command. After running, the
per-project config has MAIN_TABS_COORDS updated to measured values, and (if
--tab-anchors was passed) every tab has been confirmed to render the expected
screen on tap.

Without --tab-anchors, the script measures and writes coords but does not
drive tap-tests. Manually verify each tab afterwards via
`tap_tab.sh <name> --verify-anchor <id>` for each tab.

--skip-build skips build_app.sh; useful if you've already built and just want
to re-measure or re-verify without recompiling.

The agent-led setup colloquy may invoke this immediately after
setup_project.sh to give adopters end-to-end proof the skill works in their
app, not just proof the config file was written.

Exit codes: 0 calibration successful; 2 config missing, bad arg, or no
TabView (MAIN_TABS empty); 3 measure_tab_pill.sh did not emit a coords
line; 5 measure_tab_pill.sh detected a tab count that doesn't match
MAIN_TABS — config NOT modified, manual review needed; 6 one or more
--tab-anchors failed verify; non-zero propagated from any other composed
step (build, launch, measure).
EOF
}

SKIP_BUILD=0
TAB_ANCHORS_INPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --tab-anchors) TAB_ANCHORS_INPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || {
  echo "error: $CONFIG not found. Run setup_project.sh first to create the per-project config." >&2
  exit 2
}
source "$CONFIG"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ ${MAIN_TABS+x} && ${#MAIN_TABS[@]} -gt 0 ]] || {
  echo "error: MAIN_TABS is empty in $CONFIG; calibrate is only meaningful for apps with a TabView." >&2
  exit 2
}

TAB_ANCHORS_ARR=()
if [[ -n "$TAB_ANCHORS_INPUT" ]]; then
  read -r -a TAB_ANCHORS_ARR <<< "$TAB_ANCHORS_INPUT"
  if [[ ${#TAB_ANCHORS_ARR[@]} -ne ${#MAIN_TABS[@]} ]]; then
    echo "error: --tab-anchors has ${#TAB_ANCHORS_ARR[@]} entries but MAIN_TABS has ${#MAIN_TABS[@]} (${MAIN_TABS[*]}); counts must match." >&2
    exit 2
  fi
fi

echo "===== ios-build-verify calibrate for $APP_NAME on $TARGET_SIM ====="
echo

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "[1/4] Building app..."
  "$SCRIPT_DIR/build_app.sh" 2>&1 | grep -E "(Compiling|Build Succeeded|error:)" || {
    BUILD_RC=${PIPESTATUS[0]}
    if [[ "$BUILD_RC" -ne 0 ]]; then
      echo "error: build_app.sh failed with exit $BUILD_RC. Run build_app.sh directly to see full output." >&2
      exit "$BUILD_RC"
    fi
  }
else
  echo "[1/4] Skipping build (--skip-build)."
fi
echo

echo "[2/4] Launching app on $TARGET_SIM..."
"$SCRIPT_DIR/launch_app.sh"
echo

echo "[3/4] Measuring tab pill..."
set +e
MEASURE_OUT=$("$SCRIPT_DIR/measure_tab_pill.sh" 2>&1)
MEASURE_RC=$?
set -e
echo "$MEASURE_OUT"
NEW_COORDS_LINE=$(echo "$MEASURE_OUT" | grep -E '^MAIN_TABS_COORDS=' | tail -1)

# Validate before writing: a count mismatch (RC=5) means the algorithm under-
# or over-segmented. The detected MAIN_TABS_COORDS line is on stdout above for
# inspection, but we don't write it to the config — corrupting the config with
# wrong-shape coords would silently mis-tap on every subsequent tap_tab.sh
# invocation, and the agent might not notice until something downstream fails.
# Bail with the same exit code measure_tab_pill.sh used so callers can react.
if [[ "$MEASURE_RC" -eq 5 ]]; then
  echo
  echo "error: detected tab count differs from MAIN_TABS (${#MAIN_TABS[@]} configured: ${MAIN_TABS[*]})." >&2
  echo "  the detected MAIN_TABS_COORDS line is shown above for inspection but has NOT been written to" >&2
  echo "  $CONFIG — manual review required. Try a fresh screenshot on the main TabView with the FIRST" >&2
  echo "  tab selected, or pass --y-band-lo/--y-band-hi/--min-gap-px to measure_tab_pill.sh directly." >&2
  exit 5
fi
if [[ "$MEASURE_RC" -ne 0 ]]; then
  echo "error: measure_tab_pill.sh exited $MEASURE_RC; aborting calibration." >&2
  exit "$MEASURE_RC"
fi
if [[ -z "$NEW_COORDS_LINE" ]]; then
  echo "error: measure_tab_pill.sh did not emit a MAIN_TABS_COORDS line." >&2
  exit 3
fi

echo
echo "[3.5/4] Updating MAIN_TABS_COORDS in $CONFIG..."
TMP=$(mktemp)
if grep -qE '^MAIN_TABS_COORDS=' "$CONFIG"; then
  awk -v new="$NEW_COORDS_LINE" '/^MAIN_TABS_COORDS=/ {print new; next} {print}' "$CONFIG" > "$TMP"
else
  cat "$CONFIG" > "$TMP"
  echo "$NEW_COORDS_LINE" >> "$TMP"
fi
mv "$TMP" "$CONFIG"
echo "  $NEW_COORDS_LINE"
echo

echo "[4/4] Tap-and-verify per tab..."
if [[ ${#TAB_ANCHORS_ARR[@]} -gt 0 ]]; then
  source "$CONFIG"
  FAILED_TABS=()
  for i in "${!MAIN_TABS[@]}"; do
    TAB="${MAIN_TABS[$i]}"
    ANCHOR="${TAB_ANCHORS_ARR[$i]}"
    echo "  - tap_tab.sh $TAB --verify-anchor $ANCHOR"
    set +e
    "$SCRIPT_DIR/tap_tab.sh" "$TAB" --verify-anchor "$ANCHOR" 2>&1 | sed 's/^/      /'
    TAB_RC=${PIPESTATUS[0]}
    set -e
    if [[ "$TAB_RC" -ne 0 ]]; then
      FAILED_TABS+=("$TAB(exit $TAB_RC)")
    fi
  done
  if [[ ${#FAILED_TABS[@]} -gt 0 ]]; then
    echo
    echo "warning: ${#FAILED_TABS[@]} tab(s) failed verify-anchor: ${FAILED_TABS[*]}" >&2
    echo "  re-run individual tabs to debug: tap_tab.sh <name> --verify-anchor <id>" >&2
    exit 6
  fi
  echo "  all ${#MAIN_TABS[@]} tabs verified."
else
  echo "  (skipped — pass --tab-anchors \"id1 id2 ...\" parallel to MAIN_TABS to verify per-tab render)"
  echo "  manual verify: for each tab name in (${MAIN_TABS[*]}), run:"
  echo "      ~/.claude/skills/ios-build-verify/scripts/tap_tab.sh <name> --verify-anchor <known-anchor-id-on-that-tab>"
fi

echo
echo "===== calibration complete ====="
