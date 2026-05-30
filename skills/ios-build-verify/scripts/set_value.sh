#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 2 ]] || { echo "usage: set_value.sh <accessibility-identifier> <text>" >&2; exit 2; }
ID="$1"; TEXT="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/_resolve_udid.sh"
source "$SCRIPT_DIR/_type_text.sh"

"$SCRIPT_DIR/read_value.sh" "$ID" >/dev/null
"$SCRIPT_DIR/tap_id.sh" "$ID" >/dev/null

axe key-combo --modifiers 227 --key 4 --udid "$UDID" >/dev/null  # Cmd+A: select all
# Routes ASCII through `axe type`, non-ASCII (accented/Unicode) through the
# simctl-pbcopy + Cmd+V pasteboard workaround. See _type_text.sh.
type_into_focused_field "$UDID" "$TEXT"

# Read-back-and-compare: HID dispatch (key-combo + type) returns success even
# when the widget's bound state didn't change — Toggles inside Form inside
# NavigationStack on iOS 26 are the canonical case. Without this loop, the
# silent failure propagates downstream as red assertions with no diagnostic
# trail. May 2026 Calculator2 validation, Friction 1 of the named-intent turn.
ACTUAL=$("$SCRIPT_DIR/read_value.sh" "$ID" 2>/dev/null || true)
if [[ "$ACTUAL" == "$TEXT" ]]; then
  echo "set: $ID = '$TEXT'"
  exit 0
fi

echo "error: set $ID failed read-back: expected '$TEXT', got '$ACTUAL'." >&2
echo "  hint: HID dispatch returns success even when a widget's bound state didn't change." >&2
echo "  Common causes (see SKILL.md → 'iOS 26 Form-in-NavigationStack' for #1 and #2):" >&2
echo "  1. Toggle inside Form inside NavigationStack on iOS 26 — read-back returns" >&2
echo "     the unchanged value (got='0' when expected='1', or vice versa)." >&2
echo "  2. Picker inside Form inside NavigationStack on iOS 26 — tapping presents a" >&2
echo "     popover that gates the entire AXTree (describe-ui returns 0 AXUniqueIds)," >&2
echo "     so read-back returns ''. Same simctl-launch workaround as Toggle." >&2
echo "  3. TextField/TextEditor input filter mutating the typed string — e.g.," >&2
echo "     smart dashes (... → …), smart quotes (' → '), autocapitalization. All" >&2
echo "     three apply on iOS 26 to both single-line TextField and multi-line" >&2
echo "     TextEditor. Fixes: .textInputAutocapitalization(.never) +" >&2
echo "     .autocorrectionDisabled() handle autocaps; smart-* require a" >&2
echo "     UIViewRepresentable wrapper (see 'Designing for verify ops')." >&2
echo "  4. Element exposes no AXValue (empty after write). For SwiftUI-native" >&2
echo "     elements, add .accessibilityValue(...) to the SwiftUI declaration." >&2
echo "     For UIViewRepresentable wrappers, set accessibilityValue on the" >&2
echo "     wrapped UIKit view inside updateUIView — SwiftUI modifiers don't" >&2
echo "     bridge through to the underlying view's accessibility surface." >&2
exit 6
