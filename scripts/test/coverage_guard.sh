#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

XCRESULT_PATH=""
BASELINE_PATH="$ROOT_DIR/docs/testing/coverage-baseline.json"
REPORT_PATH="$ROOT_DIR/docs/testing/coverage-latest.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --xcresult)
            XCRESULT_PATH="$2"
            shift 2
            ;;
        --baseline)
            BASELINE_PATH="$2"
            shift 2
            ;;
        --report)
            REPORT_PATH="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$XCRESULT_PATH" ]]; then
    echo "--xcresult is required" >&2
    exit 1
fi

if [[ ! -f "$BASELINE_PATH" ]]; then
    echo "Coverage baseline not found: $BASELINE_PATH" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_name="$(jq -r '.target_name' "$BASELINE_PATH")"
if [[ -z "$target_name" || "$target_name" == "null" ]]; then
    echo "Invalid coverage target name in baseline: $BASELINE_PATH" >&2
    exit 1
fi

"$SCRIPT_DIR/coverage_report.sh" \
    --xcresult "$XCRESULT_PATH" \
    --target "$target_name" \
    --baseline "$BASELINE_PATH" \
    --output "$REPORT_PATH" >/dev/null

min_target="$(jq -r '.minimums.target_line_coverage' "$BASELINE_PATH")"
current_target="$(jq -r '.target_line_coverage' "$REPORT_PATH")"

compare_ge() {
    local current="$1"
    local minimum="$2"
    awk -v c="$current" -v m="$minimum" 'BEGIN { exit (c + 1e-12 >= m ? 0 : 1) }'
}

echo "Coverage guard target: $target_name"
echo "  current: $current_target"
echo "  minimum: $min_target"

if ! compare_ge "$current_target" "$min_target"; then
    echo "Target coverage regression detected." >&2
    exit 1
fi

failure_count=0
for key in $(jq -r '.minimums.tracked_files | keys[]' "$BASELINE_PATH"); do
    min_file_cov="$(jq -r --arg key "$key" '.minimums.tracked_files[$key]' "$BASELINE_PATH")"
    current_file_cov="$(jq -r --arg key "$key" '.tracked_files[$key].line_coverage' "$REPORT_PATH")"
    file_path="$(jq -r --arg key "$key" '.tracked_files[$key].path' "$REPORT_PATH")"

    if [[ "$current_file_cov" == "null" || -z "$current_file_cov" ]]; then
        echo "Missing tracked file coverage in report: $key ($file_path)" >&2
        failure_count=$((failure_count + 1))
        continue
    fi

    echo "  $key"
    echo "    path: $file_path"
    echo "    current: $current_file_cov"
    echo "    minimum: $min_file_cov"

    if ! compare_ge "$current_file_cov" "$min_file_cov"; then
        echo "Tracked file coverage regression: $key" >&2
        failure_count=$((failure_count + 1))
    fi
done

if [[ "$failure_count" -gt 0 ]]; then
    echo "Coverage guard failed with $failure_count regression(s)." >&2
    exit 1
fi

echo "Coverage guard passed."
