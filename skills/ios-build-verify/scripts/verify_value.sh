#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

AUDIT=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --audit) AUDIT=1; shift ;;
    -h|--help)
      cat <<'EOF'
usage: verify_value.sh [--audit] <accessibility-identifier> <expected-value>
  --audit   Before verifying, locate the identifier in Swift source via
            find_id_in_source.sh and run audit_view.sh on each matched file.
            Surfaces nearby unannotated elements alongside the verification
            result. Cheap proactive nudge for adopters who haven't reached
            for audit_view.sh on their own.
EOF
      exit 0 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

[[ $# -ge 2 ]] || { echo "usage: verify_value.sh [--audit] <accessibility-identifier> <expected-value>" >&2; exit 2; }
ID="$1"; EXPECTED="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$AUDIT" -eq 1 ]]; then
  set +e
  SOURCE_OUT=$("$SCRIPT_DIR/find_id_in_source.sh" "$ID" 2>/dev/null)
  SOURCE_RC=$?
  set -e
  if [[ "$SOURCE_RC" -eq 0 && -n "$SOURCE_OUT" ]]; then
    FILES=$(echo "$SOURCE_OUT" | grep -v '^#' | awk -F: '{print $1}' | sort -u)
    if [[ -n "$FILES" ]]; then
      echo "--- audit_view.sh (--audit) ---" >&2
      while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        AUDIT_OUT=$("$SCRIPT_DIR/audit_view.sh" "$file" 2>&1 || true)
        if [[ -n "$AUDIT_OUT" ]]; then
          echo "$AUDIT_OUT" >&2
        else
          echo "$file: no missing-modifier candidates." >&2
        fi
      done <<< "$FILES"
      echo "---" >&2
    fi
  else
    echo "note: --audit could not locate '$ID' in Swift source; skipping audit." >&2
  fi
fi

ACTUAL=$("$SCRIPT_DIR/read_value.sh" "$ID")

if [[ "$ACTUAL" == "$EXPECTED" ]]; then
  echo "$ACTUAL"
  exit 0
else
  echo "error: expected '$EXPECTED', got '$ACTUAL'." >&2
  exit 6
fi
