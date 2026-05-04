#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 1 ]] || { echo "usage: tap_label.sh <accessibility-label>" >&2; exit 2; }
LABEL="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"
source "$SCRIPT_DIR/_check_pill_overlap.sh"

check_pill_overlap_by_label "$LABEL"

axe tap --label "$LABEL" --udid "$UDID"
