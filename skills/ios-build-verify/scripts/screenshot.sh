#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 1 ]] || { echo "usage: screenshot.sh <context-slug>" >&2; exit 2; }
CONTEXT="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

mkdir -p "$(pwd)/docs/screenshots"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$(pwd)/docs/screenshots/${TS}-${CONTEXT}.png"
axe screenshot --udid "$UDID" --output "$OUT" >/dev/null
echo "$OUT"
