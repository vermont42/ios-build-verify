#!/usr/bin/env bash
# Sourced helper. Defines check_pill_overlap_by_id() and check_pill_overlap_by_label().
# Each looks up the target's AXFrame, checks whether its y-center falls within
# the device's floating tab pill y-band (per data/coordinates.json), and exits 7
# with a warning if so. Otherwise returns silently.
#
# Why this exists: iOS 26's TabView { Tab(...) } DSL renders a centered floating
# pill that overlays content. Layouts that push interactables under the pill
# (e.g., a fixed-height List with too few rows) cause silent miss-taps — the HID
# dispatch returns success but the tap lands on the pill instead of the intended
# element, switching tabs and leaving the verify flow with a confusing trace.
# May 2026 GenericApp validation, prompt 6 saved-translations layout overlap.
#
# Requires $UDID and $TARGET_SIM in scope (typically sourced after _resolve_udid.sh).
# Silent no-op when:
#   - data/coordinates.json doesn't exist
#   - jq isn't available
#   - the device entry has no floating_tab_pill_y_band field
#   - the target isn't found in the AXTree (let the caller's tap fail loudly)
#   - the target has no AXFrame

_pill_overlap_check() {
  local mode="$1"  # "id" or "label"
  local value="$2"

  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local coords_file="$script_dir/../data/coordinates.json"
  [[ -f "$coords_file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local pill_y_band
  pill_y_band=$(jq -r --arg d "$TARGET_SIM" '.[$d].floating_tab_pill_y_band // empty | "\(.[0]) \(.[1])"' "$coords_file" 2>/dev/null || echo "")
  [[ -n "$pill_y_band" && "$pill_y_band" != "null null" && "$pill_y_band" != " " ]] || return 0

  local pill_y_top="${pill_y_band%% *}"
  local pill_y_bottom="${pill_y_band##* }"

  local tree
  tree=$(axe describe-ui --udid "$UDID" 2>/dev/null) || return 0
  [[ -n "$tree" ]] || return 0

  local axframe
  if [[ "$mode" == "id" ]]; then
    axframe=$(echo "$tree" | jq -r --arg v "$value" '.. | objects | select(.AXUniqueId? == $v) | .AXFrame // empty' 2>/dev/null | head -1)
  else
    axframe=$(echo "$tree" | jq -r --arg v "$value" '.. | objects | select(.AXLabel? == $v) | .AXFrame // empty' 2>/dev/null | head -1)
  fi
  [[ -n "$axframe" ]] || return 0

  # AXFrame format: "{{x, y}, {w, h}}"
  local y h
  y=$(echo "$axframe" | sed -E 's/^\{\{[^,]+, ([0-9.]+)\}.*/\1/')
  h=$(echo "$axframe" | sed -E 's/.*, ([0-9.]+)\}\}$/\1/')
  [[ -n "$y" && -n "$h" ]] || return 0

  local y_center
  y_center=$(awk "BEGIN { printf \"%.0f\", $y + $h / 2 }")

  if [[ "$y_center" -ge "$pill_y_top" && "$y_center" -le "$pill_y_bottom" ]]; then
    echo "warning: '$value' AXFrame y-center ($y_center) falls within floating tab pill y-band ($pill_y_top-$pill_y_bottom)." >&2
    echo "  HID tap will likely land on the pill instead (silent miss-tap — tab switches, target gets nothing)." >&2
    echo "  fix: shrink upstream layout so '$value' renders above y=$pill_y_top." >&2
    echo "  see SKILL.md → 'Designing for verify ops' → 'Adaptive list heights vs. the floating tab pill'." >&2
    exit 7
  fi
}

check_pill_overlap_by_id() {
  _pill_overlap_check "id" "$1"
}

check_pill_overlap_by_label() {
  _pill_overlap_check "label" "$1"
}
