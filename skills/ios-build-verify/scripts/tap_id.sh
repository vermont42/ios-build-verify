#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 1 ]] || { echo "usage: tap_id.sh <accessibility-identifier>" >&2; exit 2; }
ID="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"
source "$SCRIPT_DIR/_check_pill_overlap.sh"

check_pill_overlap_by_id "$ID"

axe tap --id "$ID" --udid "$UDID"
