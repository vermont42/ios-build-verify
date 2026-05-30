#!/usr/bin/env bash
# Sourced helper. Provides type_into_focused_field(UDID, TEXT): sends TEXT to
# the already-focused field, picking the dispatch path by character set.
#
# Why this exists: `axe type` converts text to USB HID keyboard events through a
# fixed US-layout keycode table (cameroncooke/AXe Sources/AXe/Types/KeyCode.swift).
# It supports only A-Z a-z 0-9 and ASCII symbols and *rejects* anything else
# (accented letters éñü, currency £€¥, CJK, emoji) up front with
# "unsupportedCharacter" — it never types a partial string, and --stdin/--file
# don't help because all three input paths feed the same validator. The author
# documents this as an intentional HID-protocol limitation, not a bug; no
# upstream fix is tracked (AXe repo researched May 2026, no matching issue).
#
# Workaround for non-ASCII text: stage it on the target simulator's pasteboard
# with `simctl pbcopy` and paste it with Cmd+V, which bypasses HID entirely and
# inserts the string literally (also dodging smart-quote/smart-dash substitution
# that the HID path is subject to). Requires the field to already be focused,
# exactly like the HID path — callers tap/clear first. Pure-ASCII text keeps the
# original `axe type` path unchanged, so existing behavior and timing are
# untouched for the common case.
#
# Konjugieren's quiz (accented French conjugations: parlé, réussî, …) is the
# motivating case — the May 2026 UI audit found `axe type` couldn't enter them.

# _type_text_needs_paste TEXT
# Returns 0 (true) if TEXT contains any non-ASCII byte (>= 0x80) — i.e., anything
# the AXe HID keycode table can't emit (accented letters, currency, CJK, emoji,
# all of which are multi-byte UTF-8 with every byte >= 0x80). Pure-bash byte
# match under a function-local LC_ALL=C: that forces byte-wise collation so the
# range [\x80-\xff] is meaningful. Deliberately NOT grep — on this maintainer's
# box `grep` is ugrep, which classifies é as a printable Unicode char regardless
# of LC_ALL and would miss it; the bash glob has no such locale dependence and
# needs no external tool. Plain ASCII (incl. newline/tab whitespace) returns
# false and keeps the `axe type` path.
_type_text_needs_paste() {
  local LC_ALL=C
  case "$1" in
    *[$'\x80'-$'\xff']*) return 0 ;;
    *) return 1 ;;
  esac
}

# type_into_focused_field UDID TEXT
# Assumes the target field is already focused. Does not clear the field; callers
# send Cmd+A first when replace semantics are wanted (both paths then overwrite
# the selection — `axe type` replaces it, Cmd+V pastes over it).
type_into_focused_field() {
  local udid="$1" text="$2"
  if _type_text_needs_paste "$text"; then
    # Pasteboard route for non-ASCII: stage on the target sim, then Cmd+V.
    printf '%s' "$text" | xcrun simctl pbcopy "$udid"
    sleep 0.2  # let the pasteboard write land before the paste shortcut
    axe key-combo --modifiers 227 --key 25 --udid "$udid" >/dev/null  # Cmd+V: paste
  else
    axe type "$text" --udid "$udid" >/dev/null
  fi
}
