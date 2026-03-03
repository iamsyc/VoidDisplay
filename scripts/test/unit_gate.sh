#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SCHEME="${SCHEME:-VoidDisplay}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/VoidDisplay.xcodeproj}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.derivedData}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-$ROOT_DIR/UnitTests.xcresult}"
ENABLE_CODE_COVERAGE="${ENABLE_CODE_COVERAGE:-YES}"
ONLY_TESTING="${ONLY_TESTING:-VoidDisplayTests}"
SKIP_TESTING="${SKIP_TESTING:-VoidDisplayUITests}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scheme)
            SCHEME="$2"
            shift 2
            ;;
        --project)
            PROJECT_PATH="$2"
            shift 2
            ;;
        --destination)
            DESTINATION="$2"
            shift 2
            ;;
        --derived-data-path)
            DERIVED_DATA_PATH="$2"
            shift 2
            ;;
        --result-bundle-path)
            RESULT_BUNDLE_PATH="$2"
            shift 2
            ;;
        --enable-code-coverage)
            ENABLE_CODE_COVERAGE="$2"
            shift 2
            ;;
        --only-testing)
            ONLY_TESTING="$2"
            shift 2
            ;;
        --skip-testing)
            SKIP_TESTING="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

rm -rf "$RESULT_BUNDLE_PATH"

XCODEBUILD_CMD=(
    xcodebuild
    -scheme "$SCHEME"
    -project "$PROJECT_PATH"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -resultBundlePath "$RESULT_BUNDLE_PATH"
    -enableCodeCoverage "$ENABLE_CODE_COVERAGE"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
)

if [[ -n "${EXTRA_OTHER_SWIFT_FLAGS:-}" ]]; then
    XCODEBUILD_CMD+=("OTHER_SWIFT_FLAGS=$(printf '%s' "$EXTRA_OTHER_SWIFT_FLAGS")")
fi

XCODEBUILD_CMD+=(
    test
    -only-testing:"$ONLY_TESTING"
    -skip-testing:"$SKIP_TESTING"
)

set +e
"${XCODEBUILD_CMD[@]}"
xcodebuild_exit_code=$?
set -e

if [[ ! -d "$RESULT_BUNDLE_PATH" ]]; then
    echo "Missing test result bundle: $RESULT_BUNDLE_PATH" >&2
    exit 1
fi

SUMMARY="$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE_PATH")"

extract_metric() {
    local key="$1"
    local fallback="$2"
    local line value
    if command -v rg >/dev/null 2>&1; then
        line="$(printf '%s\n' "$SUMMARY" | rg "\"$key\"" | tail -n 1)" || true
    else
        line="$(printf '%s\n' "$SUMMARY" | grep "\"$key\"" | tail -n 1)" || true
    fi
    if [[ -z "$line" ]]; then
        printf '%s' "$fallback"
        return 0
    fi
    value="$(printf '%s\n' "$line" | awk -F': ' '{print $2}' | tr -d ',\"')"
    if [[ -z "$value" ]]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$value"
    fi
}

TOTAL_TESTS="$(extract_metric totalTestCount 0)"
PASSED_TESTS="$(extract_metric passedTests 0)"
FAILED_TESTS="$(extract_metric failedTests 0)"
SKIPPED_TESTS="$(extract_metric skippedTests 0)"
RESULT_STATUS="$(extract_metric result unknown)"

echo "Unit test summary:"
echo "  result: $RESULT_STATUS"
echo "  totalTestCount: $TOTAL_TESTS"
echo "  passedTests: $PASSED_TESTS"
echo "  failedTests: $FAILED_TESTS"
echo "  skippedTests: $SKIPPED_TESTS"

if [[ "$TOTAL_TESTS" == "0" ]]; then
    echo "Invalid test run: totalTestCount == 0 (possible selector mismatch)." >&2
    exit 1
fi

if [[ "$FAILED_TESTS" != "0" ]]; then
    echo "Unit tests reported failures in xcresult summary." >&2
    exit 1
fi

if [[ "$xcodebuild_exit_code" != "0" ]]; then
    echo "xcodebuild exited with non-zero status: $xcodebuild_exit_code" >&2
    exit "$xcodebuild_exit_code"
fi
