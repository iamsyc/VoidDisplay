#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNIT_GATE="$ROOT_DIR/scripts/test/unit_gate.sh"

PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/VoidDisplay.xcodeproj}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.derivedData}"
ENABLE_CODE_COVERAGE="${ENABLE_CODE_COVERAGE:-NO}"
MAX_RETRIES="${MAX_RETRIES:-2}"

run_suite() {
    local suite="$1"
    local result_bundle="$ROOT_DIR/UnitTests-${suite##*/}.xcresult"
    local attempt=1
    while true; do
        echo
        echo "==> Running $suite (attempt $attempt/$MAX_RETRIES)"
        if "$UNIT_GATE" \
            --project "$PROJECT_PATH" \
            --destination "$DESTINATION" \
            --derived-data-path "$DERIVED_DATA_PATH" \
            --result-bundle-path "$result_bundle" \
            --enable-code-coverage "$ENABLE_CODE_COVERAGE" \
            --only-testing "$suite"; then
            return 0
        fi

        if (( attempt >= MAX_RETRIES )); then
            echo "Suite failed after $attempt attempt(s): $suite" >&2
            return 1
        fi

        echo "Retrying suite after failure: $suite" >&2
        attempt=$((attempt + 1))
    done
}

run_suite "VoidDisplayTests/VirtualDisplayTopologyRecoveryTests"
run_suite "VoidDisplayTests/VirtualDisplayServiceOfflineWaitTests"
run_suite "VoidDisplayTests/VirtualDisplayControllerTests"

echo
echo "Virtual display regression gate passed."
