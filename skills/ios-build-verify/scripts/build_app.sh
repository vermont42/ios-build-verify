#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
if [[ ! -f "$CONFIG" ]]; then
  echo "error: $CONFIG not found. Run setup first (or hand-populate per the README)." >&2
  exit 2
fi
source "$CONFIG"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$TARGET_SIM" \
  build 2>&1 \
  | tee build.log \
  | xcbeautify --disable-logging
