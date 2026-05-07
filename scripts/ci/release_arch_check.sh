#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/architecture.sh
source "$TOOL_ROOT/scripts/lib/architecture.sh"
ARCH=""
LABEL=""
DERIVED_DATA_PATH=""
APP_OUTPUT_FILE=""
LOG_PATH=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--arch)
		ARCH="$2"
		shift 2
		;;
	--label)
		LABEL="$2"
		shift 2
		;;
	--derived-data-path)
		DERIVED_DATA_PATH="$2"
		shift 2
		;;
	--app-output-file)
		APP_OUTPUT_FILE="$2"
		shift 2
		;;
	--log-path)
		LOG_PATH="$2"
		shift 2
		;;
	*)
		echo "Unknown argument: $1" >&2
		exit 1
		;;
	esac
done

[[ -n "$ARCH" ]] || die "--arch is required."
validate_release_arch "$ARCH"
LABEL="${LABEL:-$(release_label_for_arch "$ARCH")}"
require_release_label_for_arch "$ARCH" "$LABEL"

if [ -z "$DERIVED_DATA_PATH" ]; then
	DERIVED_DATA_PATH=".ai-tmp/release-${LABEL}/DerivedData"
fi
DESTINATION="$(xcode_destination_for_arch "$ARCH")"

cd "$ROOT_DIR"

LOG_PATH="${LOG_PATH:-.ai-tmp/release-${LABEL}/xcode-release-build.log}"
mkdir -p "$(dirname "$LOG_PATH")"

env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" bash "$TOOL_ROOT/scripts/ci/download_relay_modules.sh"

set +e
xcodebuild \
	-scheme VoidDisplay \
	-project Apps/VoidDisplay/VoidDisplay.xcodeproj \
	-configuration Release \
	-destination "$DESTINATION" \
	-derivedDataPath "$DERIVED_DATA_PATH" \
	-skipPackageUpdates \
	-onlyUsePackageVersionsFromResolvedFile \
	ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO \
	ARCHS="$ARCH" \
	build \
	2>&1 | tee "$LOG_PATH"
build_status=${PIPESTATUS[0]}
set -e

if [ "$build_status" -ne 0 ]; then
	echo "xcodebuild Release exited with non-zero status: $build_status. Log: $LOG_PATH" >&2
	exit "$build_status"
fi

scan_xcode_log_for_diagnostics "Xcode Release build" "$LOG_PATH"

app_path="${DERIVED_DATA_PATH}/Build/Products/Release/VoidDisplay.app"
if [ ! -d "$app_path" ]; then
	echo "Expected app not found: $app_path" >&2
	exit 1
fi

env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" bash "$TOOL_ROOT/scripts/release/thin_webrtc_and_sign.sh" "$app_path" "$ARCH"

if [ -n "$APP_OUTPUT_FILE" ]; then
	mkdir -p "$(dirname "$APP_OUTPUT_FILE")"
	printf '%s\n' "$app_path" >"$APP_OUTPUT_FILE"
fi

echo "Release app path: $app_path"
