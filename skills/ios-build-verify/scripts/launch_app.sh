#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

REUSE_INSTALL=0
REQUIRE_FRESH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reuse-install)
      REUSE_INSTALL=1; shift ;;
    --require-fresh)
      REQUIRE_FRESH=1; shift ;;
    -h|--help)
      cat <<'EOF'
usage: launch_app.sh [--reuse-install] [--require-fresh]

  launch_app.sh installs and launches the LAST build_app.sh output. It does
  NOT compile. After editing source, run build_app.sh first
  (build_app.sh && launch_app.sh) — a bare launch_app.sh reinstalls the
  previous build and serves pre-edit UI.

  --reuse-install   Skip the pre-launch terminate. By default, launch_app.sh
                    terminates any running instance of BUNDLE_ID before
                    installing — this rules out a class of stale-screenshot
                    incidents where the running process serves pre-edit UI
                    even after the binary was rebuilt. Pass --reuse-install
                    when warm-cache reuse is intentional (rare).
  --require-fresh   Make a stale build a hard error (exit 6) instead of a
                    non-fatal warning. When source files are newer than the
                    installed .app, exit before install/launch so a stale
                    binary is never served. Opt-in; the default stays
                    non-fatal because reinstall-without-rebuild is legitimate.
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

# Stale-binary guard. launch_app.sh installs the .app already in DerivedData; it
# does NOT compile. If source files were edited since that .app was built, the
# install serves pre-edit UI — the exact stale-screenshot incident that costs
# an agent a debugging loop when it reads "launch" as "rebuild" and treats a
# bare launch_app.sh as a rebuild. (Distinct from the stale-*process* guard
# below, which handles a fresh binary served by a still-running old process;
# this is the stale-*binary* case, where build_app.sh was never re-run.) Warn,
# non-fatally, when the working tree is newer than the build product so the
# operator knows to run build_app.sh first. Non-fatal because reinstall-without-
# rebuild is a legitimate (if rare) flow; --reuse-install does not suppress it,
# since staleness is orthogonal to warm-cache reuse. Heavy/derived dirs are
# pruned to bound the scan and avoid false positives.
STALE_REF="$APP_PATH"
[[ -f "$APP_PATH/$APP_NAME" ]] && STALE_REF="$APP_PATH/$APP_NAME"
# Detector scope: common edit-then-launch source globs, kept tight by design (the
# goal is the everyday edit case, not exhaustive coverage). Two subtleties:
#   - .xcassets is a *directory*; its own mtime bumps only when entries are added
#     or removed, NOT when a file inside an existing image/color set is edited. So
#     we also match nested catalog contents via -path '*.xcassets/*' — otherwise
#     editing an existing asset would be a silent false negative (the worst failure
#     mode for a guard).
#   - .xcstrings (String Catalogs, the current default for localized strings) and
#     .entitlements are included so a localization or capability edit also trips it.
NEWER_SRC=$(find "$(pwd)" \
  \( -path '*/.git' -o -path '*/.build' -o -path '*/Pods' -o -path '*/DerivedData' -o -path '*/build' \) -prune -o \
  \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.h' \
     -o -name '*.storyboard' -o -name '*.xib' -o -name '*.strings' -o -name '*.xcstrings' \
     -o -name '*.plist' -o -name '*.entitlements' \
     -o -name '*.xcassets' -o -path '*.xcassets/*' \) \
  -newer "$STALE_REF" -print 2>/dev/null | head -1 || true)
# Capture staleness as a flag + example so it can ride the FINAL output line too
# (see the launched:/ERR_MSG paths below). The early stderr warning here is the
# right behavior when output isn't filtered, but agents routinely pipe launch
# output through `| tail -N`, which drops these lines; the result-line echo is
# what survives that filtering.
STALE_BUILD=0
STALE_EXAMPLE=""
if [[ -n "$NEWER_SRC" ]]; then
  STALE_BUILD=1
  STALE_EXAMPLE="${NEWER_SRC#"$(pwd)/"}"
  echo "warning: source files are newer than the built .app — this install will serve pre-edit UI." >&2
  echo "  launch_app.sh installs the last build and does NOT compile. e.g. modified since build: $STALE_EXAMPLE" >&2
  echo "  fix: run build_app.sh first (build_app.sh && launch_app.sh) to pick up source edits." >&2
fi

# --require-fresh: opt-in hard stop. Fail before install/launch so a stale binary
# is never served. Default path stays non-fatal (reinstall-without-rebuild is a
# legitimate flow; --reuse-install is orthogonal to staleness).
if [[ "$STALE_BUILD" -eq 1 && "$REQUIRE_FRESH" -eq 1 ]]; then
  echo "error: --require-fresh set but the installed .app is older than your source (e.g. $STALE_EXAMPLE)." >&2
  echo "  fix: run build_app.sh first, then launch_app.sh." >&2
  exit 6
fi

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
    if [[ "$STALE_BUILD" -eq 1 ]]; then
      echo "launched (STALE BUILD): $APP_NAME ($BUNDLE_ID) on $TARGET_SIM ($UDID) — installed .app is older than your source (e.g. $STALE_EXAMPLE); this UI is PRE-EDIT. Run build_app.sh, then launch_app.sh."
    else
      echo "launched: $APP_NAME ($BUNDLE_ID) on $TARGET_SIM ($UDID)"
    fi
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
# Errors-as-state-probes: classify the final tree to guide diagnosis. A populated
# tree without FIRST_SCREEN_ID is a different bug from an empty tree (modal-gated).
if [[ -n "${TREE:-}" ]]; then
  CHILD_COUNT=$(echo "$TREE" | jq -r '[.. | objects | select(.children? | type == "array") | .children[]] | length' 2>/dev/null || echo "?")
  if [[ "$CHILD_COUNT" == "0" ]]; then
    ERR_MSG+=$'\n  hint: final AXTree had children:[] — the launch screen is likely gated by an auto-presented modal (review prompt, alert, sheet, fullScreenCover). See SKILL.md "Common first-real-app friction" #6 and "Modal AXTree gating".'
    ERR_MSG+=$'\n  diagnose: screenshot.sh launch-fail (to see the modal), then: describe_ui.sh --point <x>,<y> — full-tree describe will be empty while the modal is up; --point reaches the dismiss button directly.'
  fi
fi
# Stale-build note rides the failing output too: a slow or modal-gated launch off
# a stale binary is still polling pre-edit UI, and this is the last line the reader
# (or `| tail -N`) keeps.
if [[ "$STALE_BUILD" -eq 1 ]]; then
  ERR_MSG+=$'\n  note: this install is STALE — source is newer than the .app (e.g. '"$STALE_EXAMPLE"$'). The screen being polled may be pre-edit UI. Run build_app.sh first, then launch_app.sh.'
fi
echo "$ERR_MSG" >&2
exit 5
