#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SCHEME="${SCHEME:-VoidDisplay}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Apps/VoidDisplay/VoidDisplay.xcodeproj}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT_DIR/.ai-tmp/full-regression-gate}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ARTIFACT_ROOT/$TS"
DERIVED_DATA_PATH="$OUT_DIR/DerivedData"
mkdir -p "$OUT_DIR"

SWIFT_BUILD_LOG="$OUT_DIR/swift-build.log"
SWIFT_TEST_LOG="$OUT_DIR/swift-test.log"
XCODE_BUILD_LOG="$OUT_DIR/xcode-build-debug.log"
XCODE_TEST_LOG="$OUT_DIR/xcode-test-debug.log"
XCODE_TEST_RESULT="$OUT_DIR/xcode-test-debug.xcresult"

info() { printf '[INFO] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

extract_metric() {
    local key="$1"
    local fallback="$2"
    local line value
    line="$(printf '%s\n' "$SUMMARY" | rg "\"$key\"" | tail -n 1)" || true
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

scan_log() {
    local label="$1"
    local log_path="$2"
    local matches
    matches="$(rg -n 'error:|warning:|WARNING|\*\* TEST FAILED \*\*|\*\* BUILD FAILED \*\*' "$log_path" || true)"
    if [[ -n "$matches" ]]; then
        error "$label log contains warning or error markers."
        printf '%s\n' "$matches"
        exit 1
    fi
}

info "Workspace: $ROOT_DIR"
info "Artifacts: $OUT_DIR"

info "Step 1/4: SwiftPM build"
swift build >"$SWIFT_BUILD_LOG" 2>&1
scan_log "SwiftPM build" "$SWIFT_BUILD_LOG"

info "Step 2/4: SwiftPM test"
swift test >"$SWIFT_TEST_LOG" 2>&1
scan_log "SwiftPM test" "$SWIFT_TEST_LOG"

info "Step 3/4: Xcode Debug build"
xcodebuild build \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "$DESTINATION" \
    >"$XCODE_BUILD_LOG" 2>&1
scan_log "Xcode build" "$XCODE_BUILD_LOG"

info "Step 4/4: Xcode Debug test"
set +e
xcodebuild test \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "$DESTINATION" \
    -resultBundlePath "$XCODE_TEST_RESULT" \
    >"$XCODE_TEST_LOG" 2>&1
test_status=$?
set -e

if [[ ! -d "$XCODE_TEST_RESULT" ]]; then
    error "Missing xcresult bundle: $XCODE_TEST_RESULT"
    tail -n 120 "$XCODE_TEST_LOG" || true
    exit 1
fi

SUMMARY="$(xcrun xcresulttool get test-results summary --path "$XCODE_TEST_RESULT")"
TOTAL="$(extract_metric totalTestCount 0)"
PASSED="$(extract_metric passedTests 0)"
FAILED="$(extract_metric failedTests 0)"
SKIPPED="$(extract_metric skippedTests 0)"
RESULT="$(extract_metric result unknown)"

printf '\n=== Xcode Test Summary ===\n'
printf 'result: %s\n' "$RESULT"
printf 'totalTestCount: %s\n' "$TOTAL"
printf 'passedTests: %s\n' "$PASSED"
printf 'failedTests: %s\n' "$FAILED"
printf 'skippedTests: %s\n' "$SKIPPED"
printf 'xcresult: %s\n' "$XCODE_TEST_RESULT"
printf 'log: %s\n' "$XCODE_TEST_LOG"

if [[ "$TOTAL" == "0" ]]; then
    error "Invalid run: totalTestCount == 0."
    exit 1
fi

if [[ "$test_status" != "0" || "$FAILED" != "0" ]]; then
    error "Xcode test regression failed. Last log lines:"
    tail -n 120 "$XCODE_TEST_LOG" || true
    exit 1
fi

scan_log "Xcode test" "$XCODE_TEST_LOG"

printf '\nPASS: full regression gate succeeded.\n'
