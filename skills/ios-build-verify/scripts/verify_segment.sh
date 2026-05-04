#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

SEGMENTS=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --segments) SEGMENTS="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
usage: verify_segment.sh [--segments N] <picker-id> <segment-index> <expected-label>
  Verify that segment <segment-index> (0-based) of the composite control
  identified by <picker-id> carries AXLabel <expected-label> and is currently
  selected (AXValue == 1).

  --segments N  Number of equal-width segments. If omitted, the script tries to
                infer N from the parent's child-count metadata; if no metadata
                is available, the script exits 2 and asks for --segments.

Designed for the iOS 26 children-not-enumerated bug: segmented/menu/palette
Pickers and TabView render as a single AXTree element with empty children.
This script reaches the segment via `axe describe-ui --point <x>,<y>`,
which queries the element under the given screen coordinate directly.

Exit codes:
  0  segment matches expected label and is selected
  2  config missing, missing argument, or could not infer segment count
  3  no booted simulator
  4  parent control identifier not found in tree
  5  ambiguous parent identifier
  6  label mismatch
  7  segment not currently selected (AXValue != 1)
EOF
      exit 0 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

[[ $# -ge 3 ]] || { echo "usage: verify_segment.sh [--segments N] <picker-id> <segment-index> <expected-label>" >&2; exit 2; }
ID="$1"; INDEX="$2"; EXPECTED_LABEL="$3"

if ! [[ "$INDEX" =~ ^[0-9]+$ ]]; then
  echo "error: <segment-index> must be a non-negative integer (got '$INDEX')." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

TREE=$(axe describe-ui --udid "$UDID" 2>/dev/null)
COUNT=$(echo "$TREE" | jq --arg id "$ID" '[.. | objects | select(.AXUniqueId? == $id)] | length')

if [[ "$COUNT" == "0" ]]; then
  echo "error: no element with AXUniqueId '$ID'." >&2
  PRESENT_IDS=$(echo "$TREE" | jq -r '[.. | objects | select(.AXUniqueId? != null) | .AXUniqueId] | unique | join(", ")' 2>/dev/null || echo "")
  [[ -n "$PRESENT_IDS" ]] && echo "  present AXUniqueIds in the tree: $PRESENT_IDS" >&2
  exit 4
fi
[[ "$COUNT" -gt 1 ]] && { echo "error: ambiguous identifier: '$ID' matches $COUNT elements." >&2; exit 5; }

AXFRAME=$(echo "$TREE" | jq -r --arg id "$ID" '.. | objects | select(.AXUniqueId? == $id) | .AXFrame // empty' | head -1)
if [[ -z "$AXFRAME" ]]; then
  echo "error: '$ID' has no AXFrame; cannot compute segment center." >&2
  exit 4
fi

# AXFrame format: "{{x, y}, {w, h}}"
PARENT_X=$(echo "$AXFRAME" | sed -E 's/^\{\{([0-9.]+),.*$/\1/')
PARENT_Y=$(echo "$AXFRAME" | sed -E 's/^\{\{[^,]+, ([0-9.]+)\}.*/\1/')
PARENT_W=$(echo "$AXFRAME" | sed -E 's/.*\{([0-9.]+),[^}]+\}\}$/\1/')
PARENT_H=$(echo "$AXFRAME" | sed -E 's/.*, ([0-9.]+)\}\}$/\1/')

if [[ -z "$PARENT_X" || -z "$PARENT_Y" || -z "$PARENT_W" || -z "$PARENT_H" ]]; then
  echo "error: could not parse AXFrame '$AXFRAME' for '$ID'." >&2
  exit 4
fi

if [[ -z "$SEGMENTS" ]]; then
  # Try to infer from the parent's child-count metadata. Common shapes:
  # "AXChildren" (bare count), or counting "children" array length.
  CHILD_COUNT=$(echo "$TREE" | jq --arg id "$ID" '[.. | objects | select(.AXUniqueId? == $id) | .children // [] | length] | first // 0')
  if [[ "$CHILD_COUNT" -gt 0 ]]; then
    SEGMENTS="$CHILD_COUNT"
  else
    echo "error: cannot infer segment count for '$ID' (children: []). Pass --segments N explicitly." >&2
    exit 2
  fi
fi

if ! [[ "$SEGMENTS" =~ ^[0-9]+$ ]] || [[ "$SEGMENTS" -lt 1 ]]; then
  echo "error: --segments must be a positive integer (got '$SEGMENTS')." >&2
  exit 2
fi

if [[ "$INDEX" -ge "$SEGMENTS" ]]; then
  echo "error: <segment-index> $INDEX is out of range for $SEGMENTS segments (valid: 0..$((SEGMENTS - 1)))." >&2
  exit 2
fi

# Compute the Nth segment's center: x = parent_x + (parent_w / segments) * (index + 0.5); y = parent_y + parent_h / 2.
SEG_X=$(awk "BEGIN { printf \"%.0f\", $PARENT_X + ($PARENT_W / $SEGMENTS) * ($INDEX + 0.5) }")
SEG_Y=$(awk "BEGIN { printf \"%.0f\", $PARENT_Y + $PARENT_H / 2 }")

POINT_JSON=$(axe describe-ui --point "${SEG_X},${SEG_Y}" --udid "$UDID" 2>/dev/null || true)
if [[ -z "$POINT_JSON" ]]; then
  echo "error: 'axe describe-ui --point ${SEG_X},${SEG_Y}' returned no output. Is the parent control visible?" >&2
  exit 4
fi

ACTUAL_LABEL=$(echo "$POINT_JSON" | jq -r '.AXLabel // ""')
ACTUAL_VALUE=$(echo "$POINT_JSON" | jq -r '.AXValue // ""')

if [[ "$ACTUAL_LABEL" != "$EXPECTED_LABEL" ]]; then
  echo "error: segment $INDEX expected '$EXPECTED_LABEL', got '$ACTUAL_LABEL'." >&2
  exit 6
fi

if [[ "$ACTUAL_VALUE" != "1" ]]; then
  echo "error: segment $INDEX not selected (AXValue=$ACTUAL_VALUE)." >&2
  exit 7
fi

echo "segment $INDEX selected: '$ACTUAL_LABEL'"
