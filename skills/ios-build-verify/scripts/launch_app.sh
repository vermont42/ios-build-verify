#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

REUSE_INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reuse-install)
      REUSE_INSTALL=1; shift ;;
    -h|--help)
      cat <<'EOF'
usage: launch_app.sh [--reuse-install]
  --reuse-install   Skip the pre-launch terminate. By default, launch_app.sh
                    terminates any running instance of BUNDLE_ID before
                    installing — this rules out a class of stale-screenshot
                    incidents where the running process serves pre-edit UI
                    even after the binary was rebuilt. Pass --reuse-install
                    when warm-cache reuse is intentional (rare).
EOF
      exit 0 ;;
    *)
      echo "error: unknown flag: $1" >&2
      exit 2 ;;
  esac
done

# Resolve UDID for TARGET_SIM via grep/awk on simctl's text-table output.
# Format: "    <name> (<UDID>) (<state>)". The trailing " (" in the pattern
# disambiguates "iPhone 17" from "iPhone 17 Pro" (prefix collision).
# `tail -1` prefers the latest-runtime match: simctl lists runtimes in ascending
# order, so a device that exists under multiple runtimes (e.g., iPhone 17 under
# both iOS 26.0 and iOS 26.3) resolves to the newest one — which matches the
# app's deployment target in the common case.
UDID=$(xcrun simctl list devices available \
  | grep -E "^[[:space:]]+${TARGET_SIM} \(" \
  | grep -oE '[0-9A-F-]{36}' \
  | tail -1) || true
[[ -n "$UDID" ]] || { echo "error: simulator '$TARGET_SIM' not found." >&2; exit 3; }

if ! xcrun simctl list devices booted | grep -q "$UDID"; then
  echo "booting..."
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  open -a Simulator
fi

PRODUCTS_DIR=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$TARGET_SIM" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR/ {print $2; exit}')
[[ -n "$PRODUCTS_DIR" ]] || { echo "error: could not resolve BUILT_PRODUCTS_DIR for $PROJECT/$SCHEME." >&2; exit 4; }
APP_PATH="$PRODUCTS_DIR/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || { echo "error: $APP_PATH does not exist. Run build_app.sh first." >&2; exit 4; }

# Terminate first to rule out stale-process serving pre-edit UI: the May 1
# Calculator validation observed a screenshot reflecting pre-edit state after
# a rebuild + install — the freshly-rebuilt binary was on disk, but the
# running process kept serving the old UI. simctl terminate is no-op-safe
# when the bundle isn't running, so the cost is ~1s on every launch.
if [[ "$REUSE_INSTALL" -eq 0 ]]; then
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

xcrun simctl install "$UDID" "$APP_PATH"

# Bundle-id sanity check: read CFBundleIdentifier from the just-installed .app
# and compare against $BUNDLE_ID. Catches the case where setup_project.sh's
# colloquy accepted a wrong default (e.g., user said "com.acme.X" but pbxproj's
# PRODUCT_BUNDLE_IDENTIFIER is "biz.acme.X") — without this check, simctl
# launch produces a bare FBSOpenApplicationServiceErrorDomain error pointing at
# the requested-but-not-installed bundle, leaving the agent to chase the wrong
# fix. May 2026 Calculator3 validation, Q2.
INSTALLED_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Info.plist" 2>/dev/null || true)
if [[ -n "$INSTALLED_BUNDLE_ID" && "$INSTALLED_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "error: installed app bundle id '$INSTALLED_BUNDLE_ID' does not match BUNDLE_ID='$BUNDLE_ID' in .claude/ios-build-verify.config.sh." >&2
  echo "  fix: update BUNDLE_ID in the config to '$INSTALLED_BUNDLE_ID' (or change PRODUCT_BUNDLE_IDENTIFIER in $PROJECT to '$BUNDLE_ID')." >&2
  exit 4
fi

xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

BUDGET="${WAIT_FOR_RENDER_BUDGET_S:-10}"
DEADLINE=$(($(date +%s) + BUDGET))
DISMISSED_ONBOARDING=0
while (( $(date +%s) < DEADLINE )); do
  TREE=$(axe describe-ui --udid "$UDID" 2>/dev/null || true)
  if echo "$TREE" | grep -q "$FIRST_SCREEN_ID"; then
    echo "launched: $APP_NAME ($BUNDLE_ID) on $TARGET_SIM ($UDID)"
    exit 0
  fi
  # Onboarding-dismiss interleave: when ONBOARDING_DISMISS_LABEL is configured
  # and the labeled element appears in the current tree (typical: onboarding
  # gates the launch screen on first per-sim launch), tap it once and continue
  # polling for FIRST_SCREEN_ID. Idempotent — once dismissed, the label leaves
  # the tree and the branch becomes a no-op for the rest of this loop.
  if [[ -n "${ONBOARDING_DISMISS_LABEL:-}" && "$DISMISSED_ONBOARDING" -eq 0 && -n "$TREE" ]]; then
    LABEL_COUNT=$(echo "$TREE" | jq --arg l "$ONBOARDING_DISMISS_LABEL" '[.. | objects | select(.AXLabel? == $l)] | length' 2>/dev/null || echo "0")
    if [[ "$LABEL_COUNT" != "0" ]]; then
      axe tap --label "$ONBOARDING_DISMISS_LABEL" --udid "$UDID" >/dev/null 2>&1 || true
      DISMISSED_ONBOARDING=1
      echo "dismissed onboarding: tapped '$ONBOARDING_DISMISS_LABEL'"
    fi
  fi
  sleep 0.5
done

ERR_MSG="error: $APP_NAME launched but $FIRST_SCREEN_ID never appeared in describe-ui within ${BUDGET}s."
if [[ -n "${ONBOARDING_DISMISS_LABEL:-}" && "$DISMISSED_ONBOARDING" -eq 0 ]]; then
  ERR_MSG+=" Onboarding dismiss label '$ONBOARDING_DISMISS_LABEL' was also not seen — verify the AXLabel is correct (test by running dismiss_onboarding.sh manually after launch)."
fi
echo "$ERR_MSG" >&2
exit 5
