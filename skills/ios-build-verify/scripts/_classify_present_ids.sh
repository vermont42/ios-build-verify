#!/usr/bin/env bash
# Sourced helper. Defines classify_present_ids() — a shared classifier for the
# "present AXUniqueIds in the tree" hint emitted by named-intent ops on exit 4
# (no element with that identifier) and exit 5 (anchor never appeared).
#
# Implements the "errors as state probes" design principle (see SKILL.md):
# the same surface diagnoses identifier rollup, modal-popover gating, and
# unexpected app crash via SpringBoard recognition. New error paths should
# call this helper rather than inlining their own present-ids hint.
#
# Usage:
#   source "$SCRIPT_DIR/_classify_present_ids.sh"
#   classify_present_ids "$TREE_JSON"
#
# Emits to stderr: a `present AXUniqueIds in the tree: ...` line, a
# `classification: ...` line, and a `hint: ...` line. No-op when the tree is
# empty or has no AXUniqueIds at all.

classify_present_ids() {
  local TREE="$1"
  [[ -n "$TREE" ]] || return 0

  local PRESENT_IDS UNIQUE_COUNT
  PRESENT_IDS=$(echo "$TREE" | jq -r '[.. | objects | select(.AXUniqueId? != null) | .AXUniqueId] | unique | join(", ")' 2>/dev/null || echo "")
  UNIQUE_COUNT=$(echo "$TREE" | jq '[.. | objects | select(.AXUniqueId? != null) | .AXUniqueId] | unique | length' 2>/dev/null || echo "0")

  if [[ -z "$PRESENT_IDS" ]]; then
    echo "  no AXUniqueIds present in the current AXTree." >&2
    echo "  hint: this often means the tree is gated behind a modal whose contents have no AXUniqueIds (the canonical case is Form Picker popover on iOS 26 — see SKILL.md → 'iOS 26 Form-in-NavigationStack')." >&2
    return 0
  fi

  echo "  present AXUniqueIds in the tree: $PRESENT_IDS" >&2

  if echo "$PRESENT_IDS" | grep -qE '(^|[^A-Za-z])PopoverDismissRegion([^A-Za-z]|$)|(^|[^A-Za-z])xmark\.circle\.fill([^A-Za-z]|$)'; then
    echo "  classification: modal popover gating the parent AXTree (PopoverDismissRegion / xmark.circle.fill present)." >&2
    echo "  hint: dismiss the popover (tap_xy on a known-empty area outside it, or tap the dismiss region's label) before re-driving the verify op. See SKILL.md → 'Modal AXTree gating'. If this is a TipKit popover that appeared mid-flow, see the TipKit subsection there for SIMCTL_CHILD_DISABLE_TIPKIT=1 to suppress in verify-driven sessions." >&2
    return 0
  fi

  if echo "$PRESENT_IDS" | grep -qE '(^|[^A-Za-z])(Calculator|Files|Messages|Safari|Settings|Preview|Notes|Calendar|Reminders|Photos|Contacts|Maps|Camera|Mail|Clock|Weather|Fitness|Health|Music|Watch|Stocks|Tips|TV|Podcasts|Books|App Store|Find My|Home|Wallet|Shortcuts|FaceTime|Translate|Voice Memos|Magnifier|Compass|spotlight-pill)([^A-Za-z]|$)'; then
    echo "  classification: simulator home screen (SpringBoard) — your app crashed or was force-terminated." >&2
    echo "  hint: re-launch via launch_app.sh; the .app bundle on the simulator is unaffected by app-process death. If the crash was unexpected, check Console.app or the Xcode crash log for the underlying cause." >&2
    return 0
  fi

  if [[ "$UNIQUE_COUNT" -le 2 ]]; then
    echo "  classification: identifier rollup (only $UNIQUE_COUNT distinct identifier(s) present)." >&2
    echo "  hint: a parent container with .accessibilityIdentifier rolls it up over every descendant. Anchor on a stable LEAF element (title Text, header Image), not a root VStack/ZStack. See SKILL.md → 'Identifier rollup'." >&2
    return 0
  fi

  echo "  classification: target identifier missing from a normal-looking tree (no rollup, no popover, app still running)." >&2
  echo "  hint: the identifier may not be in the source yet — run find_id_in_source.sh to confirm, or audit_view.sh on the relevant view file to surface unannotated nearby elements." >&2
}
