#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ ${MAIN_TABS+x} && ${#MAIN_TABS[@]} -gt 0 ]] || {
  echo "error: no tabs configured for this project (MAIN_TABS is empty in $CONFIG). tap_tab.sh doesn't apply to apps without a TabView." >&2
  exit 2
}

TAB=""
VERIFY_ANCHOR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-anchor)
      [[ $# -ge 2 ]] || { echo "error: --verify-anchor requires an accessibility identifier." >&2; exit 2; }
      VERIFY_ANCHOR="$2"; shift 2 ;;
    -h|--help)
      echo "usage: tap_tab.sh <tab-name> [--verify-anchor <accessibility-identifier>]"
      exit 0 ;;
    *)
      [[ -z "$TAB" ]] || { echo "error: too many positional arguments (got '$TAB' and '$1')." >&2; exit 2; }
      TAB="$1"; shift ;;
  esac
done
[[ -n "$TAB" ]] || { echo "usage: tap_tab.sh <tab-name> [--verify-anchor <accessibility-identifier>]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INDEX=-1
for i in "${!MAIN_TABS[@]}"; do
  if [[ "${MAIN_TABS[$i]}" == "$TAB" ]]; then
    INDEX="$i"
    break
  fi
done
[[ "$INDEX" -ge 0 ]] || {
  echo "error: tab '$TAB' not in MAIN_TABS (declared: ${MAIN_TABS[*]})." >&2
  exit 4
}

# Coordinate-source resolution: MAIN_TABS_COORDS in the per-project config wins
# when present; data/coordinates.json is a per-device default, not authoritative.
# Per-project coords let 2-tab apps and 3-tab apps coexist on the same machine
# without a shared-file race (May 2026 Calculator2 validation, Friction 1 of the
# tab-bar turn).
X=""; Y=""
if [[ ${MAIN_TABS_COORDS+x} && ${#MAIN_TABS_COORDS[@]} -gt 0 ]]; then
  if [[ ${#MAIN_TABS_COORDS[@]} -ne ${#MAIN_TABS[@]} ]]; then
    echo "error: MAIN_TABS_COORDS has ${#MAIN_TABS_COORDS[@]} entries but MAIN_TABS has ${#MAIN_TABS[@]}; counts must match." >&2
    exit 4
  fi
  COORD="${MAIN_TABS_COORDS[$INDEX]}"
  if ! [[ "$COORD" =~ ^[0-9]+(\.[0-9]+)?,[0-9]+(\.[0-9]+)?$ ]]; then
    echo "error: MAIN_TABS_COORDS[$INDEX]='$COORD' is not in 'x,y' form." >&2
    exit 4
  fi
  X="${COORD%,*}"
  Y="${COORD#*,}"
else
  COORDS="$SCRIPT_DIR/../data/coordinates.json"
  [[ -f "$COORDS" ]] || { echo "error: $COORDS not found and MAIN_TABS_COORDS not set in $CONFIG." >&2; exit 2; }

  COORDS_TAB_COUNT=$(jq -r --arg d "$TARGET_SIM" '.[$d].tabs | length // 0' "$COORDS" 2>/dev/null || echo "0")
  if [[ "$COORDS_TAB_COUNT" -ne "${#MAIN_TABS[@]}" ]]; then
    echo "error: MAIN_TABS has ${#MAIN_TABS[@]} entries but $COORDS lists $COORDS_TAB_COUNT default tab coords for '$TARGET_SIM'; counts must match. Calibrate per-app coordinates and add a MAIN_TABS_COORDS=(\"x1,y1\" \"x2,y2\" ...) line to $CONFIG. See SKILL.md → 'iOS 26 Tab-bar coordinate fallback' for the screenshot-and-measure procedure. (Editing data/coordinates.json affects every project on this machine using '$TARGET_SIM' — prefer the per-project route.)" >&2
    exit 4
  fi

  X=$(jq -r --arg d "$TARGET_SIM" --argjson i "$INDEX" '.[$d].tabs[$i].x // empty' "$COORDS")
  Y=$(jq -r --arg d "$TARGET_SIM" --argjson i "$INDEX" '.[$d].tabs[$i].y // empty' "$COORDS")
  [[ -n "$X" && -n "$Y" ]] || {
    echo "error: no coordinates for tab '$TAB' (index $INDEX) on '$TARGET_SIM' in $COORDS." >&2
    exit 4
  }
fi

source "$SCRIPT_DIR/_resolve_udid.sh"

axe tap -x "$X" -y "$Y" --udid "$UDID"

if [[ -n "$VERIFY_ANCHOR" ]]; then
  BUDGET="${WAIT_FOR_RENDER_BUDGET_S:-10}"
  DEADLINE=$(($(date +%s) + BUDGET))
  while (( $(date +%s) < DEADLINE )); do
    COUNT=$(axe describe-ui --udid "$UDID" 2>/dev/null \
      | jq --arg id "$VERIFY_ANCHOR" '[.. | objects | select(.AXUniqueId? == $id)] | length')
    if [[ "$COUNT" -gt 0 ]]; then
      echo "rendered: $VERIFY_ANCHOR"
      exit 0
    fi
    sleep 0.5
  done
  echo "error: --verify-anchor '$VERIFY_ANCHOR' did not appear in describe-ui within ${BUDGET}s." >&2
  exit 5
fi
