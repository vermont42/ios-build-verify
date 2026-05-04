#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 1 ]] || { echo "usage: find_id_in_source.sh <accessibility-identifier>" >&2; exit 2; }
ID="$1"

LITERAL_MATCHES=$(grep -rnF --include='*.swift' ".accessibilityIdentifier(\"$ID\")" "$(pwd)" 2>/dev/null || true)

INTERP_MATCHES=""
INTERP_PREFIX=""
TRY="${ID%_*}"
while [[ "$TRY" != "$ID" && -n "$TRY" ]]; do
  PREFIX="${TRY}_"
  INTERP_MATCHES=$(grep -rnF --include='*.swift' ".accessibilityIdentifier(\"${PREFIX}\\(" "$(pwd)" 2>/dev/null || true)
  if [[ -n "$INTERP_MATCHES" ]]; then
    INTERP_PREFIX="$PREFIX"
    break
  fi
  NEXT="${TRY%_*}"
  [[ "$NEXT" == "$TRY" ]] && break
  TRY="$NEXT"
done

if [[ -z "$LITERAL_MATCHES" && -z "$INTERP_MATCHES" ]]; then
  echo "error: no source match for accessibilityIdentifier('$ID')." >&2
  exit 4
fi

[[ -n "$LITERAL_MATCHES" ]] && echo "$LITERAL_MATCHES"
if [[ -n "$INTERP_MATCHES" ]]; then
  echo "# possible interpolation match (prefix '$INTERP_PREFIX'; verify runtime form produces '$ID'):"
  echo "$INTERP_MATCHES"
fi
