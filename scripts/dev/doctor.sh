#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

cd "$ROOT_DIR"

OUT_DIR="${OUT_DIR:-$(make_artifact_dir doctor)}"
SUMMARY_PATH="$OUT_DIR/doctor-summary.json"
EXPECTED_XCODE_PREFIX="${EXPECTED_XCODE_VERSION_PREFIX:-26.4}"
EXPECTED_SWIFT_PREFIX="${EXPECTED_SWIFT_VERSION_PREFIX:-6.}"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
		SUMMARY_PATH="$OUT_DIR/doctor-summary.json"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

mkdir -p "$OUT_DIR"

missing=()
for command_name in git xcodebuild swift go jq rg; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		missing+=("$command_name")
	fi
done

tool_manager="missing"
if command -v mise >/dev/null 2>&1; then
	tool_manager="mise"
elif command -v brew >/dev/null 2>&1; then
	tool_manager="homebrew"
fi

xcode_version="missing"
swift_version="missing"
go_version="missing"

if command -v xcodebuild >/dev/null 2>&1; then
	xcode_version="$(xcodebuild -version | awk 'NR==1{print $2}')"
fi
if command -v swift >/dev/null 2>&1; then
	swift_version="$(swift --version 2>&1 | awk 'match($0, /Swift version [0-9.]+/) { print substr($0, RSTART + 14, RLENGTH - 14); exit }')"
fi
if command -v go >/dev/null 2>&1; then
	go_version="$(go version | awk '{print $3}')"
fi

package_resolved_ok="true"
for resolved_path in \
	Package.resolved \
	Apps/VoidDisplay/VoidDisplay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
	VoidDisplay.xcworkspace/xcshareddata/swiftpm/Package.resolved; do
	if [[ ! -f "$resolved_path" ]]; then
		package_resolved_ok="false"
	fi
done

status="passed"
if [[ "${#missing[@]}" -gt 0 ]]; then
	status="failed"
fi
if [[ "$tool_manager" == "missing" ]]; then
	status="failed"
fi
if [[ "$xcode_version" != "$EXPECTED_XCODE_PREFIX"* ]]; then
	status="failed"
fi
if [[ "$swift_version" != "$EXPECTED_SWIFT_PREFIX"* ]]; then
	status="failed"
fi
if [[ "$package_resolved_ok" != "true" ]]; then
	status="failed"
fi

missing_json="$(printf '%s\n' "${missing[@]:-}" | sed '/^$/d' | jq -R . | jq -s .)"

write_json_file "$SUMMARY_PATH" \
	--arg status "$status" \
	--arg tool_manager "$tool_manager" \
	--arg xcode_version "$xcode_version" \
	--arg expected_xcode_prefix "$EXPECTED_XCODE_PREFIX" \
	--arg swift_version "$swift_version" \
	--arg expected_swift_prefix "$EXPECTED_SWIFT_PREFIX" \
	--arg go_version "$go_version" \
	--arg package_resolved_ok "$package_resolved_ok" \
	--arg ui_test_note "UI tests may require local Automation and Accessibility runner setup. This script does not request permissions." \
	--argjson missing_commands "$missing_json" \
	'{
	  status: $status,
	  tool_manager: $tool_manager,
	  xcode: {actual: $xcode_version, expected_prefix: $expected_xcode_prefix},
	  swift: {actual: $swift_version, expected_prefix: $expected_swift_prefix},
	  go: {actual: $go_version},
	  package_resolved_ok: ($package_resolved_ok == "true"),
	  missing_commands: $missing_commands,
	  ui_test_note: $ui_test_note
	}'

info "Doctor summary: $SUMMARY_PATH"
if [[ "$status" != "passed" ]]; then
	jq . "$SUMMARY_PATH" >&2
	die "Doctor checks failed."
fi

info "Doctor checks passed."
