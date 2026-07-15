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
# shellcheck source=scripts/lib/xcresult.sh
source "$TOOL_ROOT/scripts/lib/xcresult.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

cd "$ROOT_DIR"

require_command go jq rg xcodebuild xcrun awk tr tail

ACTION="build"
CONFIGURATION="Debug"
PROJECT_PATH="Apps/VoidDisplay/VoidDisplay.xcodeproj"
SCHEME="VoidDisplay"
DESTINATION="$(xcode_destination_for_arch arm64)"
OUT_DIR="$(make_artifact_dir ci-xcode)"
DERIVED_DATA_PATH=""
RESULT_BUNDLE_PATH=""
ONLY_TESTING=()
TEST_PLAN=""
SUMMARY_PATH=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--action)
		ACTION="$2"
		shift 2
		;;
	--configuration)
		CONFIGURATION="$2"
		shift 2
		;;
	--project)
		PROJECT_PATH="$2"
		shift 2
		;;
	--scheme)
		SCHEME="$2"
		shift 2
		;;
	--destination)
		DESTINATION="$2"
		shift 2
		;;
	--derived-data-path)
		DERIVED_DATA_PATH="$(normalize_path "$2")"
		shift 2
		;;
	--result-bundle-path)
		RESULT_BUNDLE_PATH="$(normalize_path "$2")"
		shift 2
		;;
	--only-testing)
		ONLY_TESTING+=("$2")
		shift 2
		;;
	--test-plan)
		TEST_PLAN="$2"
		shift 2
		;;
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
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

case "$ACTION" in
build | build-for-testing | test) ;;
*) die "Unsupported Xcode action: $ACTION" ;;
esac

if [[ "$ACTION" == "test" && "${#ONLY_TESTING[@]}" -eq 0 && -z "$TEST_PLAN" ]]; then
	die "xcode.sh --action test requires --only-testing or --test-plan."
fi

mkdir -p "$OUT_DIR"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$OUT_DIR/DerivedData}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-$OUT_DIR/XcodeTests.xcresult}"
LOG_PATH="$OUT_DIR/xcode-$ACTION-$CONFIGURATION.log"
SUMMARY_PATH="${SUMMARY_PATH:-$OUT_DIR/xcode-summary.json}"

select_required_xcode

xcode_cmd=(
	xcodebuild
	"-project" "$PROJECT_PATH"
	"-scheme" "$SCHEME"
	"-configuration" "$CONFIGURATION"
	"-derivedDataPath" "$DERIVED_DATA_PATH"
	"-skipPackageUpdates"
	"-onlyUsePackageVersionsFromResolvedFile"
	"-destination" "$DESTINATION"
	"ROOT_DIR=$ROOT_DIR"
	"TOOL_ROOT=$TOOL_ROOT"
	"CODE_SIGNING_ALLOWED=NO"
	"CODE_SIGNING_REQUIRED=NO"
)

if [[ "$ACTION" == "test" ]]; then
	xcode_cmd+=("-resultBundlePath" "$RESULT_BUNDLE_PATH")
	if [[ -n "$TEST_PLAN" ]]; then
		xcode_cmd+=("-testPlan" "$TEST_PLAN")
	fi
	for test_identifier in "${ONLY_TESTING[@]}"; do
		xcode_cmd+=("-only-testing:$test_identifier")
	done
fi

set +e
"${xcode_cmd[@]}" "$ACTION" 2>&1 | tee "$LOG_PATH"
xcode_status=${PIPESTATUS[0]}
set -e

if [[ "$xcode_status" != "0" ]]; then
	write_json_file "$SUMMARY_PATH" \
		--arg status "failed" \
		--arg reason "xcodebuild_failed" \
		--arg action "$ACTION" \
		--arg configuration "$CONFIGURATION" \
		--arg destination "$DESTINATION" \
		--arg log_path "$LOG_PATH" \
		'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, log_path: $log_path}'
	die "xcodebuild $ACTION exited with non-zero status: $xcode_status. Log: $LOG_PATH"
fi

total_tests="null"
failed_tests="null"
result_status="not_applicable"
if [[ "$ACTION" == "test" ]]; then
	guard_xcresult_test_count "$RESULT_BUNDLE_PATH" "Xcode test"
	summary="$(xcresult_summary_json "$RESULT_BUNDLE_PATH")"
	total_tests="$(xcresult_extract_metric "$summary" totalTestCount 0)"
	failed_tests="$(xcresult_extract_metric "$summary" failedTests 0)"
	result_status="$(xcresult_extract_metric "$summary" result unknown)"
fi

scan_xcode_log_for_diagnostics "Xcode $ACTION" "$LOG_PATH"

if [[ "$ACTION" == "test" ]]; then
	write_json_file "$SUMMARY_PATH" \
		--arg status "passed" \
		--arg reason "passed" \
		--arg action "$ACTION" \
		--arg configuration "$CONFIGURATION" \
		--arg destination "$DESTINATION" \
		--arg log_path "$LOG_PATH" \
		--arg result_bundle "$RESULT_BUNDLE_PATH" \
		--arg result_status "$result_status" \
		--argjson total_tests "$total_tests" \
		--argjson failed_tests "$failed_tests" \
		'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, log_path: $log_path, result_bundle: $result_bundle, result_status: $result_status, total_tests: $total_tests, failed_tests: $failed_tests}'
else
	write_json_file "$SUMMARY_PATH" \
		--arg status "passed" \
		--arg reason "passed" \
		--arg action "$ACTION" \
		--arg configuration "$CONFIGURATION" \
		--arg destination "$DESTINATION" \
		--arg log_path "$LOG_PATH" \
		'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, log_path: $log_path}'
fi

info "Xcode $ACTION gate passed."
info "Summary: $SUMMARY_PATH"
info "Artifacts: $OUT_DIR"
