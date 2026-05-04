#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 1 ]] || { echo "usage: read_value.sh <accessibility-identifier>" >&2; exit 2; }
ID="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"
source "$SCRIPT_DIR/_classify_present_ids.sh"

TREE=$(axe describe-ui --udid "$UDID" 2>/dev/null)
COUNT=$(echo "$TREE" | jq --arg id "$ID" '[.. | objects | select(.AXUniqueId? == $id)] | length')

if [[ "$COUNT" == "0" ]]; then
  echo "error: no element with AXUniqueId '$ID'." >&2
  classify_present_ids "$TREE"
  exit 4
fi
[[ "$COUNT" -gt 1 ]] && { echo "error: ambiguous identifier: '$ID' matches $COUNT elements." >&2; exit 5; }

VALUE=$(echo "$TREE" | jq -r --arg id "$ID" '.. | objects | select(.AXUniqueId? == $id) | .AXValue // ""')

# AXValue presence vs emptiness: describe-ui emits the AXValue *key* even when
# the SwiftUI binding resolves to an empty string (e.g., a TextField bound to
# @State var s = ""). The earlier `if [[ -z "$VALUE" ]]` test conflated those
# two cases and fired the "no AXValue" hint on correctly-annotated elements
# (May 2026 Calculator3 validation, Q1). The probe shows AXValue: "" for the
# annotated-but-empty case and AXValue null/absent for the unannotated case;
# `null` is the right discriminator.
HAS_AXVALUE=$(echo "$TREE" | jq --arg id "$ID" '[.. | objects | select(.AXUniqueId? == $id) | .AXValue] | first != null')
if [[ "$HAS_AXVALUE" == "false" ]]; then
  echo "hint: element '$ID' exists but has no AXValue; if this element should expose state:" >&2
  echo "  - SwiftUI-native element: add .accessibilityValue(...) to the SwiftUI declaration." >&2
  echo "  - UIViewRepresentable wrapper: set accessibilityValue on the wrapped UIKit view" >&2
  echo "    inside updateUIView. SwiftUI modifiers don't bridge through to the underlying" >&2
  echo "    view's accessibility surface (May 2026 GenericApp validation, Q3)." >&2
fi
echo "$VALUE"
