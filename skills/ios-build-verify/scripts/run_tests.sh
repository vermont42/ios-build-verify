#!/usr/bin/env bash
# run_tests.sh — runs xcodebuild test through xcbeautify, with two augmentations
# the May 1 Calculator validation surfaced as friction:
#   1. Optional --only-testing <Target/Suite/method()> filter (chainable; each
#      flag becomes a separate -only-testing: arg). Saves running the full
#      scheme (including UI tests) for tight-loop unit-test iteration.
#   2. Swift Testing parameterized-test summary post-process. xcbeautify
#      collapses parameterized-test output to a single suite-pass line; the
#      raw "✔ Test \"<name>\" with N test cases passed" lines live in
#      build.log. After xcbeautify completes, this script scans build.log
#      and emits the per-@Test summary lines so a parameterized suite
#      doesn't look like it ran zero cases. The header is suppressed when
#      no parameterized lines are found.
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
if [[ ! -f "$CONFIG" ]]; then
  echo "error: $CONFIG not found. Run setup first (or hand-populate per the README)." >&2
  exit 2
fi
source "$CONFIG"

XCB_CMD=(xcodebuild
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination "platform=iOS Simulator,name=$TARGET_SIM"
  -parallel-testing-enabled NO)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only-testing)
      [[ $# -ge 2 ]] || { echo "error: --only-testing requires a value (e.g., AztecCalTests/ConverterTests/convert())." >&2; exit 2; }
      XCB_CMD+=( "-only-testing:$2" )
      shift 2 ;;
    -h|--help)
      cat <<'EOF'
usage: run_tests.sh [--only-testing <Target/Suite/method()>] ...
  Multiple --only-testing flags chain (each becomes a separate
  -only-testing: arg). Use the Swift Testing form Target/Suite/method() —
  note the trailing () on method names.
EOF
      exit 0 ;;
    *)
      echo "error: unknown flag: $1" >&2
      exit 2 ;;
  esac
done

XCB_CMD+=(test)

set +e
"${XCB_CMD[@]}" 2>&1 \
  | tee build.log \
  | xcbeautify --disable-logging
RC=${PIPESTATUS[0]}
set -e

if [[ -f build.log ]]; then
  # Two summary forms in Swift Testing depending on whether @Test has a quoted
  # display name:
  #   named:    Test "Display Name" with N test cases passed after S seconds.
  #   unnamed:  Test funcName(arg:) passed after S seconds with N arguments.
  # The original regex only caught the named form. Calculator2 (May 2026) used
  # unnamed @Test functions throughout and hit total surfacing failure.
  #
  # No `^` anchor: Swift Testing prefixes some lines with a U+200B zero-width
  # space, so anchor-based matching misses them.
  PARAM_LINES=$(grep -aE 'Test .*(with [0-9]+ test case|with [0-9]+ argument)' build.log || true)
  RUN_LINE=$(grep -aE 'Test run with [0-9]+ tests? in [0-9]+ suites?' build.log || true)
  if [[ -n "$PARAM_LINES" ]]; then
    echo
    echo "--- parameterized-test summary (from build.log) ---"
    echo "$PARAM_LINES"
    [[ -n "$RUN_LINE" ]] && echo "$RUN_LINE"
  elif [[ -n "$RUN_LINE" ]]; then
    # Surface the run line even when no parameterized cases match: xcbeautify
    # collapses test totals, so the agent loses the counts otherwise.
    echo
    echo "$RUN_LINE"
  fi
fi

exit "$RC"
