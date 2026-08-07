#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/ui_test_session.sh
source "$TOOL_ROOT/scripts/lib/ui_test_session.sh"
# shellcheck source=scripts/lib/checkpoint.sh
source "$TOOL_ROOT/scripts/lib/checkpoint.sh"
# shellcheck source=scripts/lib/xcode.sh
source "$TOOL_ROOT/scripts/lib/xcode.sh"
# shellcheck source=scripts/lib/architecture.sh
source "$TOOL_ROOT/scripts/lib/architecture.sh"
# shellcheck source=scripts/lib/xcresult.sh
source "$TOOL_ROOT/scripts/lib/xcresult.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"
# shellcheck source=scripts/lib/parallel.sh
source "$TOOL_ROOT/scripts/lib/parallel.sh"

cd "$ROOT_DIR"

ACTION="build"
CONFIGURATION="Debug"
PROJECT_PATH="VoidDisplay.xcodeproj"
SCHEME="VoidDisplay"
DESTINATION="$(xcode_destination_for_arch arm64)"
OUT_DIR="$(make_artifact_dir ci-xcode)"
DERIVED_DATA_PATH=""
RESULT_BUNDLE_PATH=""
RESULT_BUNDLE_PATH_EXPLICIT="false"
ONLY_TESTING=()
ONLY_TESTING_JSON='[]'
TEST_PLAN=""
SUMMARY_PATH=""
LOG_PATH=""
SIGNING_MODE="disabled"
DEVELOPMENT_IDENTIFIER=""
DEVELOPMENT_TEAM_IDENTIFIER=""
SUMMARY_TERMINAL="false"
SUMMARY_FAILURE_REASON="argument_validation_failed"
XCODEBUILD_PID=""
XCODEBUILD_TEE_PID=""
XCODEBUILD_LOG_FIFO=""

release_ui_test_session() {
	ui_session_release
}

write_failed_summary_on_exit() {
	local exit_status=$?
	local failure_summary_path="${SUMMARY_PATH:-$OUT_DIR/xcode-summary.json}"
	trap - EXIT
	if [[ -n "$XCODEBUILD_LOG_FIFO" ]]; then
		rm -f -- "$XCODEBUILD_LOG_FIFO"
	fi
	release_ui_test_session || true
	if [[ "$exit_status" -ne 0 && "$SUMMARY_TERMINAL" != "true" ]]; then
		set +e
		rm -f -- "$failure_summary_path"
		if command -v jq >/dev/null 2>&1; then
			write_json_file "$failure_summary_path" \
				--arg status "failed" \
				--arg reason "$SUMMARY_FAILURE_REASON" \
				--arg action "$ACTION" \
				--arg configuration "$CONFIGURATION" \
				--arg destination "$DESTINATION" \
				--arg signing_mode "$SIGNING_MODE" \
				--arg log_path "$LOG_PATH" \
				--arg test_plan "$TEST_PLAN" \
				--argjson only_testing "$ONLY_TESTING_JSON" \
				'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, signing_mode: $signing_mode, log_path: $log_path, test_plan: $test_plan, only_testing: $only_testing}'
		fi
	fi
	exit "$exit_status"
}
trap write_failed_summary_on_exit EXIT

stop_xcodebuild_after_signal() {
	local signal_name="$1"

	[[ -n "$XCODEBUILD_PID" ]] || return 0
	parallel_stop_process_tree "$XCODEBUILD_PID" "$signal_name"
	XCODEBUILD_PID=""
}

finish_xcodebuild_log_stream() {
	local tee_status=0

	if [[ -n "$XCODEBUILD_TEE_PID" ]]; then
		wait "$XCODEBUILD_TEE_PID" || tee_status=$?
		XCODEBUILD_TEE_PID=""
	fi
	if [[ -n "$XCODEBUILD_LOG_FIFO" ]]; then
		rm -f -- "$XCODEBUILD_LOG_FIFO"
		XCODEBUILD_LOG_FIFO=""
	fi
	return "$tee_status"
}

forward_xcodebuild_signal() {
	local signal_name="$1"
	local exit_status="$2"

	trap '' INT TERM HUP
	stop_xcodebuild_after_signal "$signal_name"
	finish_xcodebuild_log_stream || true
	exit "$exit_status"
}
trap 'forward_xcodebuild_signal INT 130' INT
trap 'forward_xcodebuild_signal TERM 143' TERM
trap 'forward_xcodebuild_signal HUP 129' HUP

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
		RESULT_BUNDLE_PATH_EXPLICIT="true"
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
rm -f -- "$SUMMARY_PATH"

SUMMARY_FAILURE_REASON="dependency_preflight_failed"
require_command jq
if [[ "${#ONLY_TESTING[@]}" -gt 0 ]]; then
	ONLY_TESTING_JSON="$(printf '%s\n' "${ONLY_TESTING[@]}" | jq -R . | jq -s .)"
fi

write_json_file "$SUMMARY_PATH" \
	--arg status "running" \
	--arg reason "in_progress" \
	--arg action "$ACTION" \
	--arg configuration "$CONFIGURATION" \
	--arg destination "$DESTINATION" \
	--arg signing_mode "$SIGNING_MODE" \
	'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, signing_mode: $signing_mode}'

SUMMARY_FAILURE_REASON="argument_validation_failed"
case "$ACTION" in
build | build-for-testing | test | test-without-building) ;;
*) die "Unsupported Xcode action: $ACTION" ;;
esac
if [[ "$ACTION" == "build-for-testing" || "$ACTION" == "test-without-building" ]]; then
	require_repository_tool_root "Xcode test product reuse"
fi

is_test_action="false"
case "$ACTION" in
test | test-without-building) is_test_action="true" ;;
esac

case "$SIGNING_MODE" in
disabled | development) ;;
*) die "Unsupported Xcode signing mode: $SIGNING_MODE" ;;
esac

if [[ "$is_test_action" == "true" && "${#ONLY_TESTING[@]}" -eq 0 && -z "$TEST_PLAN" ]]; then
	die "xcode.sh --action $ACTION requires --only-testing or --test-plan."
fi
if [[ "$SIGNING_MODE" == "development" ]]; then
	if [[ -n "${XCODE_XCCONFIG_FILE:-}" ]]; then
		SUMMARY_FAILURE_REASON="signing_input_rejected"
		die "Development signing does not accept XCODE_XCCONFIG_FILE."
	fi
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
	SUMMARY_FAILURE_REASON="signing_preflight_failed"
	require_command codesign security
	available_signing_identities="$(security find-identity -v -p codesigning)"
	rg -q '"Apple Development:' <<<"$available_signing_identities" ||
		die "No Apple Development signing identity is available."
fi

SUMMARY_FAILURE_REASON="dependency_preflight_failed"
require_command rg xcodebuild xcrun awk tr tail

case "$ACTION" in
build | build-for-testing | test)
	require_command go
	go_mod_download_with_retry "$ROOT_DIR/Tools/VoidDisplayRelay"
	;;
esac

SUMMARY_FAILURE_REASON="toolchain_selection_failed"
select_required_xcode

if [[ "$ACTION" == "build-for-testing" || "$ACTION" == "test-without-building" ]]; then
	source_fingerprint="$(source_tree_fingerprint)"
	xcode_identity="$(xcodebuild -version)"
fi
if [[ "$ACTION" == "test-without-building" ]]; then
	SUMMARY_FAILURE_REASON="test_products_validation_failed"
	require_xcode_test_products \
		"$DERIVED_DATA_PATH" \
		"$CONFIGURATION" \
		"$DESTINATION" \
		"$source_fingerprint" \
		"$xcode_identity" \
		"$ROOT_DIR" \
		"$PROJECT_PATH" \
		"$SCHEME"
fi

if [[ "$is_test_action" == "true" ]]; then
	SUMMARY_FAILURE_REASON="ui_session_acquire_failed"
	if ! ui_session_acquire "${VOIDDISPLAY_UI_SESSION_WAIT_SECONDS:-600}"; then
		die "Unable to acquire the UI test session."
	fi
	SUMMARY_FAILURE_REASON="test_preflight_failed"
fi

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

if [[ "$is_test_action" == "true" ]]; then
	xcode_cmd+=(
		"VOIDDISPLAY_UI_SESSION_TOKEN=$VOIDDISPLAY_UI_SESSION_TOKEN"
	)
fi

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

if [[ "$is_test_action" == "true" ]]; then
	if [[ -e "$RESULT_BUNDLE_PATH" ]]; then
		if [[ "$RESULT_BUNDLE_PATH_EXPLICIT" == "true" ]]; then
			die "Explicit Xcode result bundle already exists: $RESULT_BUNDLE_PATH"
		fi
		rm -rf -- "$RESULT_BUNDLE_PATH"
	fi
	xcode_cmd+=("-resultBundlePath" "$RESULT_BUNDLE_PATH")
	if [[ -n "$TEST_PLAN" ]]; then
		xcode_cmd+=("-testPlan" "$TEST_PLAN")
	fi
	for test_identifier in "${ONLY_TESTING[@]}"; do
		xcode_cmd+=("-only-testing:$test_identifier")
	done
fi

SUMMARY_FAILURE_REASON="xcodebuild_failed"
if ! : >"$LOG_PATH"; then
	SUMMARY_FAILURE_REASON="build_log_write_failed"
	die "Unable to create the Xcode build log: $LOG_PATH"
fi
XCODEBUILD_LOG_FIFO="$OUT_DIR/xcodebuild-output.$$.fifo"
/usr/bin/mkfifo "$XCODEBUILD_LOG_FIFO" || die "Unable to create the Xcode build log stream: $XCODEBUILD_LOG_FIFO"
tee "$LOG_PATH" <"$XCODEBUILD_LOG_FIFO" &
XCODEBUILD_TEE_PID=$!
set +e
"${xcode_cmd[@]}" "$ACTION" >"$XCODEBUILD_LOG_FIFO" 2>&1 &
XCODEBUILD_PID=$!
wait "$XCODEBUILD_PID"
xcode_status=$?
XCODEBUILD_PID=""
finish_xcodebuild_log_stream
tee_status=$?
set -e

if [[ "$tee_status" != "0" ]]; then
	SUMMARY_FAILURE_REASON="build_log_write_failed"
	die "Unable to stream the Xcode build log: $LOG_PATH"
fi
if [[ "$xcode_status" != "0" ]]; then
	die "xcodebuild $ACTION exited with non-zero status: $xcode_status. Log: $LOG_PATH"
fi

SUMMARY_FAILURE_REASON="xcresult_validation_failed"
total_tests="null"
passed_tests="null"
skipped_tests="null"
failed_tests="null"
result_status="not_applicable"
if [[ "$is_test_action" == "true" ]]; then
	test_evidence="$(xcresult_test_evidence_json "$RESULT_BUNDLE_PATH" "${ONLY_TESTING[@]}")" ||
		die "Xcode test result is not a passing, non-empty run with all requested tests: $RESULT_BUNDLE_PATH"
	test_metrics="$(jq -r '[.total_tests, .passed_tests, .skipped_tests, .failed_tests, .result_status] | @tsv' <<<"$test_evidence")"
	IFS=$'\t' read -r total_tests passed_tests skipped_tests failed_tests result_status <<<"$test_metrics"
fi

SUMMARY_FAILURE_REASON="diagnostic_scan_failed"
scan_xcode_log_for_diagnostics "Xcode $ACTION" "$LOG_PATH"

if [[ "$ACTION" == "build-for-testing" ]]; then
	SUMMARY_FAILURE_REASON="test_products_manifest_failed"
	require_source_tree_unchanged "$source_fingerprint" "Xcode build-for-testing"
	write_json_file "$(xcode_test_products_manifest_path "$DERIVED_DATA_PATH")" \
		--arg configuration "$CONFIGURATION" \
		--arg destination "$DESTINATION" \
		--arg source_fingerprint "$source_fingerprint" \
		--arg xcode_identity "$xcode_identity" \
		--arg root_dir "$ROOT_DIR" \
		--arg project "$PROJECT_PATH" \
		--arg scheme "$SCHEME" \
		'{version: 1, configuration: $configuration, destination: $destination, source_fingerprint: $source_fingerprint, xcode_identity: $xcode_identity, root_dir: $root_dir, project: $project, scheme: $scheme}'
fi

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
if [[ "$is_test_action" == "true" ]]; then
	release_ui_test_session
	SUMMARY_FAILURE_REASON="summary_write_failed"
fi
if [[ "$is_test_action" == "true" ]]; then
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
		--arg test_plan "$TEST_PLAN" \
		--argjson only_testing "$ONLY_TESTING_JSON" \
		--argjson total_tests "$total_tests" \
		--argjson passed_tests "$passed_tests" \
		--argjson skipped_tests "$skipped_tests" \
		--argjson failed_tests "$failed_tests" \
		'{status: $status, reason: $reason, action: $action, configuration: $configuration, destination: $destination, log_path: $log_path, result_bundle: $result_bundle, result_status: $result_status, signing_mode: $signing_mode, test_plan: $test_plan, only_testing: $only_testing, total_tests: $total_tests, passed_tests: $passed_tests, skipped_tests: $skipped_tests, failed_tests: $failed_tests}'
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
