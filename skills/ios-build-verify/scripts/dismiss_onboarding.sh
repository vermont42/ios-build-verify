#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

usage() {
  cat <<'EOF'
usage: dismiss_onboarding.sh [<axlabel>]

Tap the first-launch onboarding dismiss button (Skip / Continue / Get Started)
by AXLabel. With no argument, uses ONBOARDING_DISMISS_LABEL from the
per-project config. Idempotent: when the labeled element is not in the current
AXTree (already-dismissed onboarding, no onboarding view), exits 0 without
tapping.

This script is also called automatically by launch_app.sh inside the
wait-for-render loop when ONBOARDING_DISMISS_LABEL is set. Direct invocation
is useful for non-launch-time onboarding (e.g., a "what's new" sheet after a
version bump that gates a screen mid-session).

Exit codes: 0 dismissed or no-op (idempotent); 2 config missing or no label
configured; 3 no booted simulator.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

LABEL="${1:-${ONBOARDING_DISMISS_LABEL:-}}"
if [[ -z "$LABEL" ]]; then
  echo "error: no dismiss label provided. Pass as first argument, or set ONBOARDING_DISMISS_LABEL in $CONFIG." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

TREE=$(axe describe-ui --udid "$UDID" 2>/dev/null)
COUNT=$(echo "$TREE" | jq --arg l "$LABEL" '[.. | objects | select(.AXLabel? == $l)] | length' 2>/dev/null || echo "0")

if [[ "$COUNT" == "0" ]]; then
  echo "no element with AXLabel '$LABEL' in current tree; assuming onboarding already dismissed (no-op)."
  exit 0
fi

axe tap --label "$LABEL" --udid "$UDID" >/dev/null
echo "dismissed: tapped element with AXLabel '$LABEL'"
