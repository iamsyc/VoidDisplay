#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

XCRESULT_PATH=""
OUTPUT_PATH="$ROOT_DIR/docs/testing/coverage-latest.json"
BASELINE_PATH=""
TARGET_NAME="${TARGET_NAME:-VoidDisplay.app}"

DEFAULT_TRACKED_PATHS='{
  "app_helper": "VoidDisplay/App/VoidDisplayApp.swift",
  "share_view_model": "VoidDisplay/Features/Sharing/ViewModels/ShareViewModel.swift",
  "capture_choose_view_model": "VoidDisplay/Features/Capture/ViewModels/CaptureChooseViewModel.swift",
  "virtual_display_service": "VoidDisplay/Features/VirtualDisplay/Services/VirtualDisplayService.swift"
}'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --xcresult)
            XCRESULT_PATH="$2"
            shift 2
            ;;
        --output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --baseline)
            BASELINE_PATH="$2"
            shift 2
            ;;
        --target)
            TARGET_NAME="$2"
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

if [[ ! -d "$XCRESULT_PATH" ]]; then
    echo "xcresult not found: $XCRESULT_PATH" >&2
    exit 1
fi

tracked_paths_json="$DEFAULT_TRACKED_PATHS"
if [[ -n "$BASELINE_PATH" && -f "$BASELINE_PATH" ]]; then
    baseline_paths="$(jq -c '.tracked_file_paths // empty' "$BASELINE_PATH")"
    if [[ -n "$baseline_paths" && "$baseline_paths" != "null" ]]; then
        tracked_paths_json="$baseline_paths"
    fi
fi

report_json_file="$(mktemp)"
xcrun xccov view --report --json "$XCRESULT_PATH" 2>/dev/null > "$report_json_file"

target_coverage="$(
    jq -r --arg target "$TARGET_NAME" '
        .targets[] | select(.name == $target) | .lineCoverage
    ' "$report_json_file" | head -n 1
)"

if [[ -z "$target_coverage" ]]; then
    echo "Coverage target not found: $TARGET_NAME" >&2
    exit 1
fi

tracked_coverage='{}'
for key in $(jq -r 'keys[]' <<<"$tracked_paths_json"); do
    path_suffix="$(jq -r --arg key "$key" '.[$key]' <<<"$tracked_paths_json")"
    line_coverage="$(
        jq -r --arg target "$TARGET_NAME" --arg suffix "$path_suffix" '
            .targets[]
            | select(.name == $target)
            | .files[]
            | select(.path | endswith($suffix))
            | .lineCoverage
        ' "$report_json_file" | head -n 1
    )"

    if [[ -z "$line_coverage" ]]; then
        line_coverage="null"
    fi

    tracked_coverage="$(
        jq -c \
            --arg key "$key" \
            --arg path "$path_suffix" \
            --argjson coverage "$line_coverage" \
            '. + {($key): {path: $path, line_coverage: $coverage}}' \
            <<<"$tracked_coverage"
    )"
done

mkdir -p "$(dirname "$OUTPUT_PATH")"
jq -n \
    --arg target "$TARGET_NAME" \
    --argjson target_coverage "$target_coverage" \
    --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson tracked "$tracked_coverage" \
    '{
        target_name: $target,
        target_line_coverage: $target_coverage,
        generated_at: $generated_at,
        tracked_files: $tracked
    }' > "$OUTPUT_PATH"

cat "$OUTPUT_PATH"
