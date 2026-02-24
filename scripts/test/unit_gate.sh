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

"${XCODEBUILD_CMD[@]}"
