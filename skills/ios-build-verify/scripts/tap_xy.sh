#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 2 ]] || { echo "usage: tap_xy.sh <x> <y>" >&2; exit 2; }
X="$1"; Y="$2"

NUMERIC_RE='^-?[0-9]+(\.[0-9]+)?$'
[[ "$X" =~ $NUMERIC_RE ]] || { echo "error: x must be numeric, got '$X'." >&2; exit 2; }
[[ "$Y" =~ $NUMERIC_RE ]] || { echo "error: y must be numeric, got '$Y'." >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

axe tap -x "$X" -y "$Y" --udid "$UDID"
