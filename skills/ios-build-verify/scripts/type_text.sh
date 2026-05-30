#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

usage() {
  cat <<'EOF'
usage: type_text.sh --id <accessibility-identifier> <text>
       type_text.sh --xy <x>,<y> [--verify-target <axlabel>] [--verify-role <role>] <text>

Modes (mutually exclusive):
  --id   Thin alias for set_value.sh: focuses by identifier, clears via Cmd+A,
         types, and read-back-verifies. Use when the TextField has
         .accessibilityIdentifier().
  --xy   Coordinate-driven: taps (x,y) to focus, clears via Cmd+A, types. No
         read-back (the field has no identifier to read from); the caller
         must assert post-state via verify_label_visible.sh, screenshot, or
         a follow-up describe-ui inspection.

Options for --xy:
  --verify-target <axlabel>   Pre-tap guard: refuse to focus unless the
                              AXLabel under (x,y) matches. Threaded through
                              tap_xy.sh.
  --verify-role <role>        Pre-tap role check; requires --verify-target.
                              For unidentified TextFields, --verify-role
                              TextField is the typical guard.
EOF
}

MODE=""
SELECTOR=""
TEXT=""
VERIFY_TARGET=""
VERIFY_ROLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)
      [[ -z "$MODE" ]] || { echo "error: --id and --xy are mutually exclusive." >&2; exit 2; }
      [[ $# -ge 2 ]] || { echo "error: --id requires an identifier." >&2; exit 2; }
      MODE="id"; SELECTOR="$2"; shift 2 ;;
    --xy)
      [[ -z "$MODE" ]] || { echo "error: --id and --xy are mutually exclusive." >&2; exit 2; }
      [[ $# -ge 2 ]] || { echo "error: --xy requires x,y." >&2; exit 2; }
      MODE="xy"; SELECTOR="$2"; shift 2 ;;
    --verify-target)
      [[ $# -ge 2 ]] || { echo "error: --verify-target requires an AXLabel." >&2; exit 2; }
      VERIFY_TARGET="$2"; shift 2 ;;
    --verify-role)
      [[ $# -ge 2 ]] || { echo "error: --verify-role requires a role." >&2; exit 2; }
      VERIFY_ROLE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      [[ -z "$TEXT" ]] || { echo "error: too many positional arguments (got '$TEXT' and '$1')." >&2; exit 2; }
      TEXT="$1"; shift ;;
  esac
done

[[ -n "$MODE" ]] || { usage >&2; exit 2; }
[[ -n "$TEXT" ]] || { echo "error: missing <text> argument." >&2; exit 2; }

if [[ "$MODE" == "id" && (-n "$VERIFY_TARGET" || -n "$VERIFY_ROLE") ]]; then
  echo "error: --verify-target / --verify-role apply to --xy mode only." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$MODE" in
  id)
    exec "$SCRIPT_DIR/set_value.sh" "$SELECTOR" "$TEXT"
    ;;
  xy)
    if ! [[ "$SELECTOR" =~ ^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?$ ]]; then
      echo "error: --xy expected 'x,y' (numeric, comma-separated), got '$SELECTOR'." >&2
      exit 2
    fi
    X="${SELECTOR%,*}"
    Y="${SELECTOR#*,}"

    source "$SCRIPT_DIR/_resolve_udid.sh"
    source "$SCRIPT_DIR/_type_text.sh"

    TAP_ARGS=("$X" "$Y")
    [[ -n "$VERIFY_TARGET" ]] && TAP_ARGS+=("--verify-target" "$VERIFY_TARGET")
    [[ -n "$VERIFY_ROLE"   ]] && TAP_ARGS+=("--verify-role"   "$VERIFY_ROLE")
    "$SCRIPT_DIR/tap_xy.sh" "${TAP_ARGS[@]}" >/dev/null

    sleep 0.2  # let the keyboard settle before sending key events
    axe key-combo --modifiers 227 --key 4 --udid "$UDID" >/dev/null  # Cmd+A: select all
    # Routes ASCII through `axe type`, non-ASCII (accented/Unicode) through the
    # simctl-pbcopy + Cmd+V pasteboard workaround. See _type_text.sh.
    type_into_focused_field "$UDID" "$TEXT"
    echo "typed: '$TEXT' at ($X,$Y) — no read-back verification (assert post-state separately if needed)"
    ;;
esac
