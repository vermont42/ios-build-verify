#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 1 ]] || { echo "usage: audit_view.sh <swift-view-file>" >&2; exit 2; }
FILE="$1"
[[ -f "$FILE" ]] || { echo "error: $FILE not found." >&2; exit 4; }

INTERACTABLE_RE='(^|[^A-Za-z0-9_])(Button|TextField|Toggle|Picker|Slider|NavigationLink|Stepper|DatePicker|ColorPicker)[[:space:]]*[({]'
STATEFUL_RE='^(TextField|Toggle|Picker|Slider|Stepper|DatePicker|ColorPicker)$'
BRACKET_ONLY_RE='^[][(){},;[:space:]]*$'
# Recognize SwiftUI's two-trailing-closure separator (`} label: {`,
# `} content: {`, `} header: {`, etc.) as block continuation, not block end.
# Without this, Button { ... } label: { ... }.accessibilityIdentifier(...) audits
# as missing-identifier because the heuristic stops at the `} label: {` line
# before reading the identifier modifier (May 2026 Calculator3 validation).
TRAILING_CLOSURE_LABEL_RE='^\}[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*\{[[:space:]]*$'
ACCESSIBILITY_ID_RE='^\.accessibilityIdentifier[[:space:]]*\('
ACCESSIBILITY_VALUE_RE='^\.accessibilityValue[[:space:]]*\('

lines=()
while IFS= read -r line || [[ -n "$line" ]]; do
  lines+=("$line")
done < "$FILE"

block_line=0
block_indent=0
block_kind=""
has_id=0
has_value=0

emit() {
  if (( block_line == 0 )); then return; fi
  local missing=""
  if (( has_id == 0 )); then
    missing=".accessibilityIdentifier"
  fi
  if [[ "$block_kind" =~ $STATEFUL_RE ]] && (( has_value == 0 )); then
    if [[ -n "$missing" ]]; then
      missing="$missing, .accessibilityValue"
    else
      missing=".accessibilityValue"
    fi
  fi
  if [[ -n "$missing" ]]; then
    printf '%s:%d: %s missing %s\n' "$FILE" "$block_line" "$block_kind" "$missing"
  fi
  block_line=0
  has_id=0
  has_value=0
  block_kind=""
}

# Foot-gun scan: .pickerStyle(.inline) triggers identifier rollup AND breaks
# AXe's tap_id resolver session-wide via duplicate AXUniqueId. Flag separately
# from the missing-modifier heuristic so adopters see WHY the Picker is risky
# rather than just what modifiers it lacks. May 2026 GenericApp validation, Q1.
inline_picker_scan() {
  local lineno
  lineno=$(grep -nE '\.pickerStyle\([[:space:]]*\.inline[[:space:]]*\)' "$FILE" | head -100 | cut -d: -f1) || true
  for ln in $lineno; do
    [[ -z "$ln" ]] && continue
    printf '%s:%s: Picker uses .pickerStyle(.inline) — AXe tap_id resolver fails session-wide on this style (identifier rollup + duplicate AXUniqueIds). Prefer .menu or .segmented for verify-driven testing. See SKILL.md → "iOS 26 controls with empty AXTree children".\n' "$FILE" "$ln"
  done
}

# Foot-gun scan: SwiftUI Slider and Picker(.wheel) emit AXValue as a JSON Number
# (Float / Int), which trips AXe v1.6.0's hard-typed String? AXValue field and
# breaks tap_id resolution against EVERY identifier in the rendered AXTree.
# Flag bare declarations and suggest .accessibilityRepresentation { Text(...) }
# or .accessibilityHidden(true) as workarounds. Quiet when either workaround
# appears within a small window of the declaration. May 2026 GenericApp2
# investigation; see SKILL.md → "Slider AXTree".
slider_wheel_scan() {
  local total_lines=${#lines[@]}
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    local lineno="${match%%:*}"
    local content="${match#*:}"
    local kind=""
    if [[ "$content" =~ \.pickerStyle\([[:space:]]*\.wheel[[:space:]]*\) ]]; then
      kind="Picker(.wheel)"
    else
      kind="Slider"
    fi
    local start=$((lineno > 5 ? lineno - 5 : 1))
    local end=$((lineno + 10))
    (( end > total_lines )) && end=$total_lines
    local has_workaround=0
    local idx
    for ((idx=start-1; idx<end; idx++)); do
      local context_line="${lines[$idx]:-}"
      if [[ "$context_line" =~ \.accessibilityRepresentation[[:space:]]*\{ ]] \
         || [[ "$context_line" =~ \.accessibilityHidden\([[:space:]]*true[[:space:]]*\) ]]; then
        has_workaround=1
        break
      fi
    done
    if (( has_workaround == 0 )); then
      printf '%s:%s: %s — triggers AXe tap_id resolver poisoning when rendered (AXe v1.6.0 hard-types AXValue as String?, breaks on Float/Int from AXSlider). Wrap with .accessibilityRepresentation { Text(...) } or .accessibilityHidden(true). See SKILL.md → "Slider AXTree".\n' "$FILE" "$lineno" "$kind"
    fi
  done < <(grep -nE '(^|[^A-Za-z0-9_])Slider[[:space:]]*\(|\.pickerStyle\([[:space:]]*\.wheel[[:space:]]*\)' "$FILE" | head -100)
}

for i in "${!lines[@]}"; do
  line="${lines[$i]}"

  if [[ -z "${line//[[:space:]]/}" ]]; then continue; fi

  prefix="${line%%[![:space:]]*}"
  line_indent=${#prefix}
  trimmed="${line#"$prefix"}"

  if (( block_line > 0 )); then
    if (( line_indent <= block_indent )) \
       && [[ "$trimmed" != .* ]] \
       && ! [[ "$trimmed" =~ $BRACKET_ONLY_RE ]] \
       && ! [[ "$trimmed" =~ $TRAILING_CLOSURE_LABEL_RE ]]; then
      emit
    else
      if [[ "$trimmed" =~ $ACCESSIBILITY_ID_RE ]]; then has_id=1; fi
      if [[ "$trimmed" =~ $ACCESSIBILITY_VALUE_RE ]]; then has_value=1; fi
    fi
  fi

  if [[ "$line" =~ $INTERACTABLE_RE ]]; then
    kind="${BASH_REMATCH[2]}"
    if (( block_line == 0 )) || (( line_indent <= block_indent )); then
      emit
      block_line=$((i + 1))
      block_indent=$line_indent
      block_kind="$kind"
      has_id=0
      has_value=0
      if [[ "$line" =~ \.accessibilityIdentifier[[:space:]]*\( ]]; then has_id=1; fi
      if [[ "$line" =~ \.accessibilityValue[[:space:]]*\( ]]; then has_value=1; fi
    fi
  fi
done

emit
inline_picker_scan
slider_wheel_scan
