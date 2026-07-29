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
PROJECT_PATH="VoidDisplay.xcodeproj"
SCHEME="VoidDisplay"
DESTINATION="$(xcode_destination_for_arch arm64)"
OUT_DIR="$(make_artifact_dir ci-xcode)"
DERIVED_DATA_PATH=""
RESULT_BUNDLE_PATH=""
ONLY_TESTING=()
TEST_PLAN=""
SUMMARY_PATH=""
LOG_PATH=""
SIGNING_MODE="disabled"
DEVELOPMENT_IDENTIFIER=""
DEVELOPMENT_TEAM_IDENTIFIER=""
SUMMARY_TERMINAL="false"
SUMMARY_FAILURE_REASON="argument_validation_failed"

write_failed_summary_on_exit() {
	local exit_status=$?
	local failure_summary_path="${SUMMARY_PATH:-$OUT_DIR/xcode-summary.json}"
	trap - EXIT
	if [[ "$exit_status" -ne 0 && "$SUMMARY_TERMINAL" != "true" ]]; then
		set +e
		write_json_file "$failure_summary_path" \
			--arg status "failed" \
			--arg reason "$SUMMARY_FAILURE_REASON" \
			--arg action "$ACTION" \
			--arg configuration "$CONFIGURATION" \
			--arg destination "$DESTINATION" \
			--arg signing_mode "$SIGNING_MODE" \
			--arg log_path "$LOG_PATH" \
			'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, signing_mode: $signing_mode, log_path: $log_path}'
	fi
	exit "$exit_status"
}
trap write_failed_summary_on_exit EXIT

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
	--signing)
		SIGNING_MODE="$2"
		shift 2
		;;
	--development-identifier)
		DEVELOPMENT_IDENTIFIER="$2"
		shift 2
		;;
	--development-team-identifier)
		DEVELOPMENT_TEAM_IDENTIFIER="$2"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

mkdir -p "$OUT_DIR"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$OUT_DIR/DerivedData}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-$OUT_DIR/XcodeTests.xcresult}"
LOG_PATH="$OUT_DIR/xcode-$ACTION-$CONFIGURATION.log"
SUMMARY_PATH="${SUMMARY_PATH:-$OUT_DIR/xcode-summary.json}"
write_json_file "$SUMMARY_PATH" \
	--arg status "running" \
	--arg reason "in_progress" \
	--arg action "$ACTION" \
	--arg configuration "$CONFIGURATION" \
	--arg destination "$DESTINATION" \
	--arg signing_mode "$SIGNING_MODE" \
	'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, signing_mode: $signing_mode}'

case "$ACTION" in
build | build-for-testing | test) ;;
*) die "Unsupported Xcode action: $ACTION" ;;
esac

case "$SIGNING_MODE" in
disabled | development) ;;
*) die "Unsupported Xcode signing mode: $SIGNING_MODE" ;;
esac

if [[ "$ACTION" == "test" && "${#ONLY_TESTING[@]}" -eq 0 && -z "$TEST_PLAN" ]]; then
	die "xcode.sh --action test requires --only-testing or --test-plan."
fi
if [[ "$SIGNING_MODE" == "development" ]]; then
	[[ "$ACTION" == "build" ]] || die "Development signing is limited to build actions."
	[[ "$SCHEME" == "VoidDisplay" ]] || die "Development signing is limited to the VoidDisplay scheme."
	[[ "$CONFIGURATION" == "Debug" ]] || die "Development signing is limited to Debug builds."
	[[ -n "$DEVELOPMENT_IDENTIFIER" ]] ||
		die "Development signing requires --development-identifier."
	[[ -n "$DEVELOPMENT_TEAM_IDENTIFIER" ]] ||
		die "Development signing requires --development-team-identifier."
	validate_development_project_path \
		"$(normalize_path "$PROJECT_PATH")" \
		"$ROOT_DIR/VoidDisplay.xcodeproj"
	require_command codesign security
	SUMMARY_FAILURE_REASON="signing_preflight_failed"
	available_signing_identities="$(security find-identity -v -p codesigning)"
	rg -q '"Apple Development:' <<<"$available_signing_identities" ||
		die "No Apple Development signing identity is available."
fi

SUMMARY_FAILURE_REASON="toolchain_selection_failed"
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
)

case "$SIGNING_MODE" in
disabled)
	xcode_cmd+=(
		"CODE_SIGNING_ALLOWED=NO"
		"CODE_SIGNING_REQUIRED=NO"
	)
	;;
development)
	xcode_cmd+=(
		"CODE_SIGNING_ALLOWED=YES"
		"CODE_SIGNING_REQUIRED=YES"
		"CODE_SIGN_STYLE=Manual"
		"DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM_IDENTIFIER"
		"CODE_SIGN_IDENTITY=Apple Development"
		"ENABLE_HARDENED_RUNTIME=YES"
	)
	;;
esac

if [[ "$ACTION" == "test" ]]; then
	xcode_cmd+=("-resultBundlePath" "$RESULT_BUNDLE_PATH")
	if [[ -n "$TEST_PLAN" ]]; then
		xcode_cmd+=("-testPlan" "$TEST_PLAN")
	fi
	for test_identifier in "${ONLY_TESTING[@]}"; do
		xcode_cmd+=("-only-testing:$test_identifier")
	done
fi

SUMMARY_FAILURE_REASON="xcodebuild_failed"
set +e
"${xcode_cmd[@]}" "$ACTION" 2>&1 | tee "$LOG_PATH"
pipeline_statuses=("${PIPESTATUS[@]}")
set -e
xcode_status="${pipeline_statuses[0]}"
tee_status="${pipeline_statuses[1]}"

if [[ "$xcode_status" != "0" ]]; then
	die "xcodebuild $ACTION exited with non-zero status: $xcode_status. Log: $LOG_PATH"
fi
if [[ "$tee_status" != "0" ]]; then
	SUMMARY_FAILURE_REASON="build_log_write_failed"
	die "Unable to write the complete Xcode build log: $LOG_PATH"
fi

SUMMARY_FAILURE_REASON="xcresult_validation_failed"
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

SUMMARY_FAILURE_REASON="diagnostic_scan_failed"
scan_xcode_log_for_diagnostics "Xcode $ACTION" "$LOG_PATH"

app_path=""
signature_verified="false"
signing_authority=""
if [[ "$SIGNING_MODE" == "development" ]]; then
	app_path="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/VoidDisplay.app"
	SUMMARY_FAILURE_REASON="signature_verification_failed"
	signing_authority="$(development_signing_authority "$app_path")"
	verify_development_signed_app \
		"$app_path" \
		"$DEVELOPMENT_IDENTIFIER" \
		"$DEVELOPMENT_TEAM_IDENTIFIER" \
		"$signing_authority"
	signature_verified="true"
fi

SUMMARY_FAILURE_REASON="summary_write_failed"
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
		--arg signing_mode "$SIGNING_MODE" \
		--argjson total_tests "$total_tests" \
		--argjson failed_tests "$failed_tests" \
		'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, log_path: $log_path, result_bundle: $result_bundle, result_status: $result_status, signing_mode: $signing_mode, total_tests: $total_tests, failed_tests: $failed_tests}'
elif [[ "$SIGNING_MODE" == "development" ]]; then
	write_json_file "$SUMMARY_PATH" \
		--arg status "passed" \
		--arg reason "passed" \
		--arg action "$ACTION" \
		--arg configuration "$CONFIGURATION" \
		--arg destination "$DESTINATION" \
		--arg log_path "$LOG_PATH" \
		--arg signing_mode "$SIGNING_MODE" \
		--arg app_path "$app_path" \
		--arg bundle_identifier "$DEVELOPMENT_IDENTIFIER" \
		--arg team_identifier "$DEVELOPMENT_TEAM_IDENTIFIER" \
		--arg signing_authority "$signing_authority" \
		--arg project_path "$(canonical_existing_path "$(normalize_path "$PROJECT_PATH")")" \
		--argjson signature_verified "$signature_verified" \
		--argjson hardened_runtime_verified true \
		--argjson designated_requirement_verified true \
		'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, log_path: $log_path, signing_mode: $signing_mode, app_path: $app_path, bundle_identifier: $bundle_identifier, team_identifier: $team_identifier, signing_authority: $signing_authority, project_path: $project_path, signature_verified: $signature_verified, hardened_runtime_verified: $hardened_runtime_verified, designated_requirement_verified: $designated_requirement_verified}'
else
	write_json_file "$SUMMARY_PATH" \
		--arg status "passed" \
		--arg reason "passed" \
		--arg action "$ACTION" \
		--arg configuration "$CONFIGURATION" \
		--arg destination "$DESTINATION" \
		--arg log_path "$LOG_PATH" \
		--arg signing_mode "$SIGNING_MODE" \
		'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, log_path: $log_path, signing_mode: $signing_mode}'
fi
SUMMARY_TERMINAL="true"

info "Xcode $ACTION gate passed."
info "Summary: $SUMMARY_PATH"
info "Artifacts: $OUT_DIR"
