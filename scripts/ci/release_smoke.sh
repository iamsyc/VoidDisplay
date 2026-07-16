#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/xcode.sh
source "$TOOL_ROOT/scripts/lib/xcode.sh"
# shellcheck source=scripts/lib/architecture.sh
source "$TOOL_ROOT/scripts/lib/architecture.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"
# shellcheck source=scripts/lib/release_binaries.sh
source "$TOOL_ROOT/scripts/lib/release_binaries.sh"

cd "$ROOT_DIR"

ARCH=""
LABEL=""
OUT_DIR="$(make_artifact_dir ci-release-smoke)"
DERIVED_DATA_PATH=""
APP_OUTPUT_FILE=""
SUMMARY_PATH=""
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
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
		shift 2
		;;
	--derived-data-path)
		DERIVED_DATA_PATH="$(normalize_path "$2")"
		shift 2
		;;
	--app-output-file)
		APP_OUTPUT_FILE="$(normalize_path "$2")"
		shift 2
		;;
	--summary)
		SUMMARY_PATH="$(normalize_path "$2")"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

[[ -n "$ARCH" ]] || die "--arch is required."
validate_release_arch "$ARCH"
LABEL="${LABEL:-$(release_label_for_arch "$ARCH")}"
require_release_label_for_arch "$ARCH" "$LABEL"
require_command go jq rg xcodebuild lipo codesign
mkdir -p "$OUT_DIR"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$OUT_DIR/DerivedData}"
APP_OUTPUT_FILE="${APP_OUTPUT_FILE:-$OUT_DIR/app-path.txt}"
SUMMARY_PATH="${SUMMARY_PATH:-$OUT_DIR/release-smoke-summary.json}"
LOG_PATH="$OUT_DIR/xcode-release-build.log"

select_required_xcode
go_mod_download_with_retry "$ROOT_DIR/Tools/VoidDisplayRelay"

set +e
xcodebuild \
	-scheme VoidDisplay \
	-project VoidDisplay.xcodeproj \
	-configuration Release \
	-destination "$(xcode_destination_for_arch "$ARCH")" \
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

if [[ "$build_status" -ne 0 ]]; then
	die "xcodebuild Release exited with non-zero status: $build_status. Log: $LOG_PATH"
fi

scan_xcode_log_for_diagnostics "Xcode Release build" "$LOG_PATH"

app_path="${DERIVED_DATA_PATH}/Build/Products/Release/VoidDisplay.app"
[[ -d "$app_path" ]] || die "Expected app not found: $app_path"
thin_and_sign_release_app "$app_path" "$ARCH"

mkdir -p "$(dirname "$APP_OUTPUT_FILE")"
printf '%s\n' "$app_path" >"$APP_OUTPUT_FILE"
write_json_file "$SUMMARY_PATH" \
	--arg status "passed" \
	--arg arch "$ARCH" \
	--arg label "$LABEL" \
	--arg app_path "$app_path" \
	--arg log_path "$LOG_PATH" \
	'{status: $status, arch: $arch, label: $label, app_path: $app_path, log_path: $log_path}'

info "Release smoke passed for $LABEL."
info "App path: $app_path"
info "Summary: $SUMMARY_PATH"
