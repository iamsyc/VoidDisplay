#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$ROOT_DIR/.ai-tmp/capture-preview-check"

mkdir -p "$TMP_DIR"

# This self-check always runs both diagnostics scale modes:
# - fit: adaptive scaling
# - native: 1:1 scaling
# If you need a single mode for debugging, run `run_mode <fit|native>` manually.

run_mode() {
  local mode="$1"
  local test_name
  if [[ "$mode" == "fit" ]]; then
    test_name="testCapturePreviewLayoutMatrixFit"
  elif [[ "$mode" == "native" ]]; then
    test_name="testCapturePreviewLayoutMatrixNative"
  else
    echo "Unsupported mode: $mode" >&2
    exit 1
  fi

  local mode_dir="$TMP_DIR/$mode"
  local derived_data_dir="$mode_dir/DerivedData"
  local build_log="$mode_dir/test.log"
  local attachments_dir="$mode_dir/attachments"

  rm -rf "$mode_dir"
  mkdir -p "$mode_dir"

  xcodebuild \
    -project "$ROOT_DIR/Apps/VoidDisplay/VoidDisplay.xcodeproj" \
    -scheme VoidDisplay \
    -configuration Debug \
    -derivedDataPath "$derived_data_dir" \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:VoidDisplayUITests/CapturePreviewDiagnosticsTests/$test_name \
    test \
    > "$build_log" 2>&1

  local result_bundle
  result_bundle="$(find "$derived_data_dir/Logs/Test" -maxdepth 1 -name '*.xcresult' | sort | tail -n 1)"
  if [[ -z "$result_bundle" ]]; then
    echo "No xcresult bundle for mode=$mode. See $build_log" >&2
    exit 1
  fi

  bash "$ROOT_DIR/scripts/test/xcresult_test_count_guard.sh" \
    --xcresult "$result_bundle" \
    --label "Capture preview diagnostics ($mode)"

  xcrun xcresulttool export attachments \
    --path "$result_bundle" \
    --output-path "$attachments_dir" \
    > /dev/null 2>&1

  typeset -a images
  images=("$attachments_dir"/*.png(N))

  if (( ${#images[@]} == 0 )); then
    echo "No capture preview screenshots for mode=$mode. See $build_log and $result_bundle" >&2
    exit 1
  fi

  for image in "${images[@]}"; do
    swift "$ROOT_DIR/scripts/test/capture_preview_analyze.swift" --mode "$mode" "$image"
  done
}

run_mode fit
run_mode native
