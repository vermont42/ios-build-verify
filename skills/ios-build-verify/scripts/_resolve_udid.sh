#!/usr/bin/env bash
# Sourced helper. Sets UDID to the booted simulator matching TARGET_SIM
# (latest-runtime preferred when the same name exists under multiple runtimes).
# Exits 3 if no booted simulator matches; exits 2 if TARGET_SIM is unset.
#
# Why this exists: the verify-half scripts used to grab the first booted UDID
# (head -1), which silently picked the wrong sim when more than one was booted.
# Session 6's smoke pass discovered the trap live; Session 7 fixes it once.

[[ -n "${TARGET_SIM:-}" ]] || {
  echo "error: TARGET_SIM unset; source the per-project config first." >&2
  exit 2
}

UDID=$(xcrun simctl list devices booted \
  | grep -E "^[[:space:]]+${TARGET_SIM} \(" \
  | grep -oE '[0-9A-F-]{36}' \
  | tail -1) || true

if [[ -z "$UDID" ]]; then
  echo "error: no booted simulator named '$TARGET_SIM'. Run launch_app.sh first, or check 'xcrun simctl list devices booted'." >&2
  exit 3
fi
