#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$ROOT_DIR/.ai-tmp/capture-preview-check"
DERIVED_DATA_DIR="$ROOT_DIR/.ai-tmp/capture-preview-check/DerivedData"
BUILD_LOG="$ROOT_DIR/.ai-tmp/capture-preview-check/test.log"
ATTACHMENTS_DIR="$ROOT_DIR/.ai-tmp/capture-preview-check/attachments"

mkdir -p "$TMP_DIR"
find "$TMP_DIR" -maxdepth 1 -name '*.png' -delete
rm -rf "$ATTACHMENTS_DIR"

xcodebuild \
  -project "$ROOT_DIR/VoidDisplay.xcodeproj" \
  -scheme VoidDisplay \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination 'platform=macOS' \
  -only-testing:VoidDisplayUITests/CapturePreviewDiagnosticsTests/testCapturePreviewLayoutMatrix \
  test \
  > "$BUILD_LOG" 2>&1

RESULT_BUNDLE="$(find "$DERIVED_DATA_DIR/Logs/Test" -maxdepth 1 -name '*.xcresult' | sort | tail -n 1)"
if [[ -z "$RESULT_BUNDLE" ]]; then
  echo "No xcresult bundle was generated. See $BUILD_LOG" >&2
  exit 1
fi

xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$ATTACHMENTS_DIR" \
  > /dev/null 2>&1

typeset -a images
images=("$ATTACHMENTS_DIR"/*.png(N))

if (( ${#images[@]} == 0 )); then
  echo "No capture preview diagnostic screenshots were generated. See $BUILD_LOG and $RESULT_BUNDLE" >&2
  exit 1
fi

for image in "${images[@]}"; do
  swift "$ROOT_DIR/scripts/test/capture_preview_analyze.swift" "$image"
done
