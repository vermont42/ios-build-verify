#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 1 ]] || { echo "usage: verify_screen_loaded.sh <anchor-accessibility-identifier>" >&2; exit 2; }
ANCHOR="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"
source "$SCRIPT_DIR/_classify_present_ids.sh"

BUDGET="${WAIT_FOR_RENDER_BUDGET_S:-10}"
DEADLINE=$(($(date +%s) + BUDGET))
LAST_TREE=""
while (( $(date +%s) < DEADLINE )); do
  LAST_TREE=$(axe describe-ui --udid "$UDID" 2>/dev/null)
  COUNT=$(echo "$LAST_TREE" | jq --arg id "$ANCHOR" '[.. | objects | select(.AXUniqueId? == $id)] | length')
  if [[ "$COUNT" -gt 0 ]]; then
    echo "rendered: $ANCHOR"
    exit 0
  fi
  sleep 0.5
done

echo "error: $ANCHOR did not appear in describe-ui within ${BUDGET}s." >&2
classify_present_ids "$LAST_TREE"
exit 5
