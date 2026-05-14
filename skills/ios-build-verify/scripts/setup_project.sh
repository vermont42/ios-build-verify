#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: setup_project.sh \
  --app-name NAME --bundle-id ID --scheme NAME --target-sim NAME \
  --first-screen-id ID \
  [--main-tabs "tab1 tab2 tab3"] [--main-tabs-coords "x1,y1 x2,y2 ..."] \
  [--project FILE] \
  [--wait-for-render-budget-s SECONDS] \
  [--onboarding-dismiss-label LABEL] \
  [--gitignore-build-log] [--gitignore-config] [--gitignore-screenshots] \
  [--ack-tab-mismatch] [--force]

Writes .claude/ios-build-verify.config.sh in the current working directory.
Optionally updates .gitignore. Refuses on existing config unless --force.

--onboarding-dismiss-label LABEL is the AXLabel of the Skip / Dismiss / Get-Started
button shown by the app's first-launch onboarding view, if any. When set,
launch_app.sh auto-dismisses on the first per-simulator launch. Pass "" or omit
when the app has no onboarding view.

--force always rewrites the config from passed flags. Absent flags revert to
script defaults rather than preserving existing values; re-pass every flag
from the previous run to avoid surprise drift.
EOF
}

APP_NAME=""
BUNDLE_ID=""
PROJECT=""
SCHEME=""
TARGET_SIM=""
FIRST_SCREEN_ID=""
MAIN_TABS_INPUT=""
MAIN_TABS_COORDS_INPUT=""
WAIT_FOR_RENDER_BUDGET_S="10"
ONBOARDING_DISMISS_LABEL=""
GI_BUILD_LOG=0
GI_CONFIG=0
GI_SCREENSHOTS=0
ACK_TAB_MISMATCH=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name) APP_NAME="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --target-sim) TARGET_SIM="$2"; shift 2 ;;
    --first-screen-id) FIRST_SCREEN_ID="$2"; shift 2 ;;
    --main-tabs) MAIN_TABS_INPUT="$2"; shift 2 ;;
    --main-tabs-coords) MAIN_TABS_COORDS_INPUT="$2"; shift 2 ;;
    --wait-for-render-budget-s) WAIT_FOR_RENDER_BUDGET_S="$2"; shift 2 ;;
    --onboarding-dismiss-label) ONBOARDING_DISMISS_LABEL="$2"; shift 2 ;;
    --gitignore-build-log) GI_BUILD_LOG=1; shift ;;
    --gitignore-config) GI_CONFIG=1; shift ;;
    --gitignore-screenshots) GI_SCREENSHOTS=1; shift ;;
    --ack-tab-mismatch) ACK_TAB_MISMATCH=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

err()  { echo "error: $*" >&2; }
warn() { echo "warning: $*" >&2; }

# Harness check. ios-build-verify is validated only on Claude Code; warn on
# other harnesses but proceed. Model identity is not exposed via env var —
# SKILL.md's "Validated configuration" section instructs the agent to
# self-check its model from its system prompt before invoking this script.
if [[ "${CLAUDECODE:-}" != "1" ]]; then
  warn "ios-build-verify is validated only on Claude Code (env CLAUDECODE=1 not set). Agent-judgment flows may vary. See SKILL.md 'Validated configuration'."
fi

REQUIRED=(APP_NAME BUNDLE_ID SCHEME TARGET_SIM FIRST_SCREEN_ID)
MISSING=()
for v in "${REQUIRED[@]}"; do
  [[ -n "${!v}" ]] || MISSING+=("$v")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  err "missing required fields: ${MISSING[*]}"
  usage >&2
  exit 2
fi

CWD="$(pwd)"

if [[ -z "$PROJECT" ]]; then
  shopt -s nullglob
  CANDIDATES=("$CWD"/*.xcodeproj)
  shopt -u nullglob
  if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
    PROJECT="$(basename "${CANDIDATES[0]}")"
  elif [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    err "no .xcodeproj found in $CWD; pass --project explicitly."
    exit 2
  else
    err "multiple .xcodeproj files in $CWD; pass --project explicitly."
    printf '  candidate: %s\n' "${CANDIDATES[@]}" >&2
    exit 2
  fi
fi

if [[ ! -e "$CWD/$PROJECT" ]]; then
  err "project file not found: $CWD/$PROJECT"
  exit 2
fi

if ! [[ "$BUNDLE_ID" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z0-9.-]+$ ]]; then
  warn "BUNDLE_ID '$BUNDLE_ID' doesn't look like a reverse-domain identifier; proceeding anyway."
fi

if command -v xcrun >/dev/null 2>&1; then
  if ! xcrun simctl list devices available 2>/dev/null | grep -qF "$TARGET_SIM"; then
    warn "TARGET_SIM '$TARGET_SIM' not found in 'xcrun simctl list devices available'; Xcode may install on demand."
  fi
fi

MAIN_TABS_ARR=()
if [[ -n "$MAIN_TABS_INPUT" ]]; then
  read -r -a MAIN_TABS_ARR <<< "$MAIN_TABS_INPUT"
  for t in "${MAIN_TABS_ARR[@]}"; do
    if ! [[ "$t" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      err "MAIN_TABS entry '$t' contains characters that are unsafe in a bash array literal; use plain identifiers."
      exit 2
    fi
  done
fi

MAIN_TABS_COORDS_ARR=()
if [[ -n "$MAIN_TABS_COORDS_INPUT" ]]; then
  read -r -a MAIN_TABS_COORDS_ARR <<< "$MAIN_TABS_COORDS_INPUT"
  for c in "${MAIN_TABS_COORDS_ARR[@]}"; do
    if ! [[ "$c" =~ ^[0-9]+(\.[0-9]+)?,[0-9]+(\.[0-9]+)?$ ]]; then
      err "MAIN_TABS_COORDS entry '$c' must be x,y (numeric, comma-separated; e.g. '115,822')."
      exit 2
    fi
  done
  if [[ ${#MAIN_TABS_COORDS_ARR[@]} -ne ${#MAIN_TABS_ARR[@]} ]]; then
    err "MAIN_TABS_COORDS has ${#MAIN_TABS_COORDS_ARR[@]} entries but MAIN_TABS has ${#MAIN_TABS_ARR[@]}; counts must match."
    exit 2
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORDS="$SCRIPT_DIR/../data/coordinates.json"
COORDS_TAB_COUNT=0
if [[ -f "$COORDS" ]] && command -v jq >/dev/null 2>&1; then
  COORDS_TAB_COUNT=$(jq -r --arg d "$TARGET_SIM" '.[$d].tabs | length // 0' "$COORDS" 2>/dev/null || echo "0")
  [[ "$COORDS_TAB_COUNT" == "null" ]] && COORDS_TAB_COUNT=0
fi
CURRENT_PAIR="${#MAIN_TABS_ARR[@]}:${COORDS_TAB_COUNT}"

EXISTING_ACK=""
EXISTING_CONFIG_PATH="$CWD/.claude/ios-build-verify.config.sh"
if [[ -f "$EXISTING_CONFIG_PATH" ]]; then
  EXISTING_ACK=$(grep -E '^MAIN_TABS_COUNT_ACK=' "$EXISTING_CONFIG_PATH" 2>/dev/null \
    | head -1 \
    | sed -E 's/^MAIN_TABS_COUNT_ACK=//; s/^"//; s/"$//' || true)
fi

if [[ $ACK_TAB_MISMATCH -eq 1 ]]; then
  NEW_ACK="$CURRENT_PAIR"
else
  NEW_ACK="$EXISTING_ACK"
fi

# De-dupe the data/coords mismatch warning across the no-force probe and the
# --force rewrite (May 2026 Calculator2 validation, target-sim turn): emit only
# when actually writing — the no-force path's diff already conveys intent.
WILL_WRITE_CONFIG=1
[[ -f "$EXISTING_CONFIG_PATH" && "$FORCE" -eq 0 ]] && WILL_WRITE_CONFIG=0

if [[ ${#MAIN_TABS_ARR[@]} -gt 0 ]] && [[ "$WILL_WRITE_CONFIG" -eq 1 ]]; then
  if [[ ${#MAIN_TABS_COORDS_ARR[@]} -gt 0 ]]; then
    : # MAIN_TABS_COORDS is set; per-project coords win — no need to consult data/coordinates.json.
  elif [[ "$COORDS_TAB_COUNT" -eq 0 ]]; then
    warn "no tab coordinates registered for '$TARGET_SIM' in $COORDS; tap_tab.sh will fail until either per-project MAIN_TABS_COORDS is set (pass --main-tabs-coords \"x1,y1 x2,y2 ...\") or coords are added to $COORDS (cross-project — affects every app on this machine using '$TARGET_SIM')."
  elif [[ "$COORDS_TAB_COUNT" -ne "${#MAIN_TABS_ARR[@]}" ]] && [[ "$NEW_ACK" != "$CURRENT_PAIR" ]]; then
    warn "MAIN_TABS has ${#MAIN_TABS_ARR[@]} entries but $COORDS lists $COORDS_TAB_COUNT default tab coords for '$TARGET_SIM'; counts must match for tap_tab.sh. Best fix: run 'calibrate.sh' (auto-measures via Pillow centroid detection on a fresh screenshot and rewrites MAIN_TABS_COORDS in place). Manual alternative: pass --main-tabs-coords \"x1,y1 x2,y2 ...\" if you've measured by hand. Per-project coords don't affect other apps. Suppress the warning: --ack-tab-mismatch silences future runs with the same MAIN_TABS:coord-count pair."
  fi
fi

if ! [[ "$WAIT_FOR_RENDER_BUDGET_S" =~ ^[0-9]+$ ]] || [[ "$WAIT_FOR_RENDER_BUDGET_S" -lt 1 ]]; then
  err "WAIT_FOR_RENDER_BUDGET_S must be an integer >= 1 (got '$WAIT_FOR_RENDER_BUDGET_S')."
  exit 2
fi

CONFIG_DIR="$CWD/.claude"
CONFIG_PATH="$CONFIG_DIR/ios-build-verify.config.sh"

QUOTED_COORDS=""
for c in "${MAIN_TABS_COORDS_ARR[@]:-}"; do
  [[ -n "$c" ]] && QUOTED_COORDS+="\"$c\" "
done
QUOTED_COORDS="${QUOTED_COORDS% }"

NEW_CONFIG_CONTENT="$(cat <<EOF
#!/usr/bin/env bash
# Per-project configuration for ios-build-verify ($APP_NAME).
# Generated by setup_project.sh; safe to hand-edit.
APP_NAME='$APP_NAME'
BUNDLE_ID=$BUNDLE_ID
PROJECT='$PROJECT'
SCHEME='$SCHEME'
TARGET_SIM='$TARGET_SIM'
FIRST_SCREEN_ID='$FIRST_SCREEN_ID'
MAIN_TABS=(${MAIN_TABS_ARR[*]:-})
MAIN_TABS_COORDS=($QUOTED_COORDS)
WAIT_FOR_RENDER_BUDGET_S=$WAIT_FOR_RENDER_BUDGET_S
MAIN_TABS_COUNT_ACK="$NEW_ACK"
ONBOARDING_DISMISS_LABEL='$ONBOARDING_DISMISS_LABEL'
EOF
)"

if [[ -e "$CONFIG_PATH" && "$FORCE" -eq 0 ]]; then
  TMP_NEW="$(mktemp)"
  printf '%s\n' "$NEW_CONFIG_CONTENT" > "$TMP_NEW"
  echo "error: $CONFIG_PATH already exists. Re-run with --force to overwrite." >&2
  echo "diff (existing -> proposed):"
  diff -u "$CONFIG_PATH" "$TMP_NEW" || true
  rm -f "$TMP_NEW"
  exit 3
fi

mkdir -p "$CONFIG_DIR"
printf '%s\n' "$NEW_CONFIG_CONTENT" > "$CONFIG_PATH"
echo "wrote: $CONFIG_PATH"

GITIGNORE="$CWD/.gitignore"
GI_HEADER="# ios-build-verify"
GI_ENTRIES=()
[[ "$GI_BUILD_LOG"   -eq 1 ]] && GI_ENTRIES+=("build.log")
[[ "$GI_CONFIG"      -eq 1 ]] && GI_ENTRIES+=(".claude/ios-build-verify.*")
[[ "$GI_SCREENSHOTS" -eq 1 ]] && GI_ENTRIES+=("docs/screenshots/")

if [[ ${#GI_ENTRIES[@]} -gt 0 ]]; then
  if [[ ! -e "$GITIGNORE" ]]; then
    {
      echo "$GI_HEADER"
      printf '%s\n' "${GI_ENTRIES[@]}"
    } > "$GITIGNORE"
    echo "created: $GITIGNORE (with ${#GI_ENTRIES[@]} entries under '$GI_HEADER')"
  else
    HAS_HEADER=0
    grep -qxF "$GI_HEADER" "$GITIGNORE" && HAS_HEADER=1
    APPENDED=()
    for entry in "${GI_ENTRIES[@]}"; do
      if ! grep -qxF "$entry" "$GITIGNORE"; then
        APPENDED+=("$entry")
      fi
    done
    if [[ ${#APPENDED[@]} -gt 0 ]]; then
      {
        [[ -s "$GITIGNORE" && $(tail -c1 "$GITIGNORE") != "" ]] && echo ""
        [[ "$HAS_HEADER" -eq 0 ]] && echo "$GI_HEADER"
        printf '%s\n' "${APPENDED[@]}"
      } >> "$GITIGNORE"
      echo "updated: $GITIGNORE (appended ${#APPENDED[@]} entries${HAS_HEADER:+ under existing header})"
    else
      echo "unchanged: $GITIGNORE (all requested entries already present)"
    fi
  fi
fi

SOURCE_CHECK="$SCRIPT_DIR/find_id_in_source.sh"
if [[ -x "$SOURCE_CHECK" ]]; then
  set +e
  SOURCE_CHECK_OUT=$("$SOURCE_CHECK" "$FIRST_SCREEN_ID" 2>&1)
  SOURCE_CHECK_RC=$?
  set -e
  case "$SOURCE_CHECK_RC" in
    0)
      echo "source check: $FIRST_SCREEN_ID found in Swift source."
      [[ -n "$SOURCE_CHECK_OUT" ]] && echo "$SOURCE_CHECK_OUT" | sed 's/^/  /'
      ;;
    4)
      warn "FIRST_SCREEN_ID '$FIRST_SCREEN_ID' not found in Swift source; proceeding anyway. Verify the identifier is correct, or add .accessibilityIdentifier(\"$FIRST_SCREEN_ID\") to the relevant view before running launch_app.sh."
      ;;
    *)
      warn "find_id_in_source.sh exited $SOURCE_CHECK_RC (config write succeeded). Output:"
      [[ -n "$SOURCE_CHECK_OUT" ]] && echo "$SOURCE_CHECK_OUT" | sed 's/^/  /' >&2
      ;;
  esac
fi

echo "setup complete."

# Detect install kind so the emitted CLAUDE.md snippet uses a path that
# actually resolves on this machine. Marketplace installs land under
# ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/<skill>/scripts —
# the version directory changes on plugin update, so the cache path is unstable
# for hand-runnable terminal commands. Manual installs land under
# ~/.claude/skills/<skill>/scripts and are version-stable. Dev/repo installs
# (e.g., /Users/foo/code/ios-build-verify) are absolute paths.
RESOLVED_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVED_SKILL_DIR="$(cd "$RESOLVED_SCRIPTS_DIR/.." && pwd)"
if [[ "$RESOLVED_SCRIPTS_DIR" == "$HOME"/* ]]; then
  EMIT_SCRIPTS_DIR="~${RESOLVED_SCRIPTS_DIR#"$HOME"}"
  EMIT_SKILL_DIR="~${RESOLVED_SKILL_DIR#"$HOME"}"
else
  EMIT_SCRIPTS_DIR="$RESOLVED_SCRIPTS_DIR"
  EMIT_SKILL_DIR="$RESOLVED_SKILL_DIR"
fi

INSTALL_KIND_NOTE=""
case "$RESOLVED_SCRIPTS_DIR" in
  *"/.claude/plugins/cache/"*)
    INSTALL_KIND_NOTE="
Note: this skill is installed via Claude Code's plugin marketplace. The path
above includes a version directory (currently ${RESOLVED_SCRIPTS_DIR##*/skills/ios-build-verify}
under ${RESOLVED_SKILL_DIR%/skills/ios-build-verify}/<version>/) that changes on
plugin update, so the literal cache path drifts when the plugin upgrades.
For a stable terminal-runnable path, create a one-time symlink:

  ln -s '$RESOLVED_SKILL_DIR' ~/.claude/skills/ios-build-verify

After the symlink, ~/.claude/skills/ios-build-verify/scripts/build_app.sh works
across plugin updates. Future Claude Code sessions resolve the skill via plugin
metadata (no symlink needed for in-session invocation)."
    ;;
  *"/.claude/skills/"*)
    : # Manual install: emitted path is already stable, no note needed.
    ;;
  *)
    INSTALL_KIND_NOTE="
Note: this skill is being run from a development / non-standard location
($RESOLVED_SKILL_DIR). The emitted path above is absolute and machine-specific
— if you commit the snippet to a repo that other developers will clone, switch
to ~/.claude/skills/ios-build-verify/scripts/... after they install the skill."
    ;;
esac

cat <<EOF

----- Suggested CLAUDE.md update (copy the block between the BEGIN/END markers) -----
Add or update a "Build and Test Commands" section in $CWD/CLAUDE.md with the
snippet below. If CLAUDE.md already documents raw \`xcodebuild\` invocations,
demote them to a "Diagnostic fallback" subsection — they remain useful when
xcbeautify's lossy filter drops an early-stage error, but the skill scripts
should be the default path so future sessions exercise the skill.

----- BEGIN CLAUDE.md snippet -----

## Build and Test Commands

This project uses the \`ios-build-verify\` Claude Code skill for build and test
operations. Both scripts pipe \`xcodebuild\` through \`xcbeautify\` for concise
output and tee raw output to \`build.log\` as a fallback.

\`\`\`bash
# Build the app
$EMIT_SCRIPTS_DIR/build_app.sh

# Run all tests
$EMIT_SCRIPTS_DIR/run_tests.sh

# Run a single test (Swift Testing form: Target/Suite/method())
$EMIT_SCRIPTS_DIR/run_tests.sh --only-testing "${APP_NAME}Tests/SuiteName/method()"
\`\`\`

The per-project config lives at \`.claude/ios-build-verify.config.sh\` and is
sourced by every script. See \`$EMIT_SKILL_DIR/SKILL.md\` for the full operation
surface (verify ops, named-intent ops, annotation-check).

----- END CLAUDE.md snippet -----$INSTALL_KIND_NOTE
EOF
