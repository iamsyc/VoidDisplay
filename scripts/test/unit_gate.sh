#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${LOG_PATH:-$ROOT_DIR/.ai-tmp/unit-gate/unit-tests.log}"
PACKAGE_PATH="${PACKAGE_PATH:-$ROOT_DIR}"
ENABLE_CODE_COVERAGE="${ENABLE_CODE_COVERAGE:-NO}"

FILTERS=()

normalize_filter() {
    local value="$1"
    value="${value#*:}"
    value="${value##*/}"
    printf '%s' "$value"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --package-path)
            PACKAGE_PATH="$2"
            shift 2
            ;;
        --log-path)
            LOG_PATH="$2"
            shift 2
            ;;
        --filter)
            FILTERS+=("$(normalize_filter "$2")")
            shift 2
            ;;
        --only-testing)
            FILTERS+=("$(normalize_filter "$2")")
            shift 2
            ;;
        --enable-code-coverage)
            ENABLE_CODE_COVERAGE="$2"
            shift 2
            ;;
        --project|--scheme|--destination|--derived-data-path|--result-bundle-path|--skip-testing)
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

mkdir -p "$(dirname "$LOG_PATH")"
rm -f "$LOG_PATH"

SWIFT_TEST_CMD=(swift test --package-path "$PACKAGE_PATH")
if [[ "$ENABLE_CODE_COVERAGE" == "YES" ]]; then
    SWIFT_TEST_CMD+=(--enable-code-coverage)
fi
if [[ "${#FILTERS[@]}" -gt 0 ]]; then
    for filter in "${FILTERS[@]}"; do
        if [[ -n "$filter" ]]; then
            SWIFT_TEST_CMD+=(--filter "$filter")
        fi
    done
fi

set +e
"${SWIFT_TEST_CMD[@]}" 2>&1 | tee "$LOG_PATH"
test_status=${PIPESTATUS[0]}
set -e

total_tests="$(
    awk '
        match($0, /Test run with [0-9]+ tests?/) {
            line = substr($0, RSTART, RLENGTH)
            sub("Test run with ", "", line)
            sub(" tests?", "", line)
            total = line
        }
        END {
            if (total == "") {
                print "0"
            } else {
                print total
            }
        }
    ' "$LOG_PATH"
)"

if [[ "$total_tests" == "0" ]]; then
    echo "Invalid SwiftPM test run: total test count is 0." >&2
    exit 1
fi

if [[ "$test_status" != "0" ]]; then
    echo "swift test exited with non-zero status: $test_status" >&2
    exit "$test_status"
fi

echo "SwiftPM unit gate passed."
echo "  total tests: $total_tests"
echo "  log: $LOG_PATH"
