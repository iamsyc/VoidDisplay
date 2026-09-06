#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/architecture.sh
source "$TOOL_ROOT/scripts/lib/architecture.sh"
# shellcheck source=scripts/lib/xcode.sh
source "$TOOL_ROOT/scripts/lib/xcode.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"
# shellcheck source=scripts/lib/parallel.sh
source "$TOOL_ROOT/scripts/lib/parallel.sh"
# shellcheck source=scripts/lib/checkpoint.sh
source "$TOOL_ROOT/scripts/lib/checkpoint.sh"
# shellcheck source=scripts/lib/xcresult.sh
source "$TOOL_ROOT/scripts/lib/xcresult.sh"
# shellcheck source=scripts/lib/release_binaries.sh
source "$TOOL_ROOT/scripts/lib/release_binaries.sh"

cd "$ROOT_DIR"

OUT_DIR="${OUT_DIR:-$(make_artifact_dir full-regression)}"
DESTINATION="${DESTINATION:-$(xcode_destination_for_arch arm64)}"
UI_SELECTOR="${UI_SELECTOR:-VoidDisplayUITests}"
RUN_UI_TESTS="true"
RUN_RELEASE_SMOKE="true"
RUN_XCODE_PREFLIGHT="true"
RESTART="false"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
		shift 2
		;;
	--destination)
		DESTINATION="$2"
		shift 2
		;;
	--ui-selector)
		UI_SELECTOR="$2"
		shift 2
		;;
	--skip-ui-tests)
		RUN_UI_TESTS="false"
		shift
		;;
	--skip-release-smoke)
		RUN_RELEASE_SMOKE="false"
		shift
		;;
	--skip-xcode-preflight)
		RUN_XCODE_PREFLIGHT="false"
		shift
		;;
	--restart)
		RESTART="true"
		shift
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

require_repository_tool_root "Full regression resume"
mkdir -p "$OUT_DIR"
exec 8>>"$OUT_DIR/.full-regression.lock"
if ! /usr/bin/lockf -s -t 0 8; then
	die "Another full regression run is already using OUT_DIR: $OUT_DIR"
fi
regression_started_at="$(date +%s)"
summary_path="$OUT_DIR/full-regression-summary.json"
summary_terminal="false"
failure_phase="initialization"
rm -f -- "$summary_path"

cleanup_full_regression() {
	local exit_status=$?
	local elapsed_seconds

	trap - EXIT INT TERM
	parallel_group_cancel
	if [[ "$exit_status" -ne 0 && "$summary_terminal" != "true" ]] && command -v jq >/dev/null 2>&1; then
		set +e
		elapsed_seconds="$(($(date +%s) - regression_started_at))"
		write_json_file "$summary_path" \
			--arg status "failed" \
			--arg phase "$failure_phase" \
			--arg destination "$DESTINATION" \
			--arg ui_selector "$UI_SELECTOR" \
			--argjson elapsed_seconds "$elapsed_seconds" \
			'{status: $status, phase: $phase, destination: $destination, ui_selector: $ui_selector, elapsed_seconds: $elapsed_seconds}'
	fi
	exit "$exit_status"
}
trap cleanup_full_regression EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failure_phase="build_input_rejected"
require_xcode_build_environment
failure_phase="initialization"

require_command codesign git go jq lipo node rg shasum swift sw_vers tr wc xcodebuild xcrun
select_required_xcode
shared_derived_data="$OUT_DIR/xcode-shared/DerivedData"
checkpoint_path="$OUT_DIR/full-regression-checkpoint.json"
stability_iterations="${STABILITY_ITERATIONS:-20}"
xcode_preflight_action="build-for-testing"
if [[ "$RUN_XCODE_PREFLIGHT" != "true" ]]; then
	xcode_preflight_action="skipped"
elif [[ "$RUN_UI_TESTS" != "true" ]]; then
	xcode_preflight_action="build"
fi
if [[ "$RUN_UI_TESTS" == "true" && "$RUN_XCODE_PREFLIGHT" != "true" ]]; then
	die "--skip-xcode-preflight requires --skip-ui-tests because UI tests need build-for-testing products."
fi

if [[ "$RESTART" == "true" ]]; then
	rm -f "$checkpoint_path"
fi

source_fingerprint="$(source_tree_fingerprint)"
xcode_identity="$(xcodebuild -version)"
swift_identity="$(swift --version 2>&1)"
go_identity="$(go version)"
node_identity="$(node --version)"
platform_identity="macOS $(sw_vers -productVersion) $(uname -m)"
preflight_fingerprint="$(checkpoint_run_fingerprint \
	"preflight" \
	"$source_fingerprint" \
	"$xcode_identity" \
	"$swift_identity" \
	"$go_identity" \
	"$node_identity" \
	"$platform_identity" \
	"$DESTINATION" \
	"$xcode_preflight_action")"
ui_fingerprint="$(checkpoint_run_fingerprint \
	"ui" \
	"$source_fingerprint" \
	"$xcode_identity" \
	"$platform_identity" \
	"$DESTINATION" \
	"$UI_SELECTOR")"
postflight_fingerprint="$(checkpoint_run_fingerprint \
	"postflight" \
	"$source_fingerprint" \
	"$xcode_identity" \
	"$swift_identity" \
	"$go_identity" \
	"$platform_identity" \
	"$stability_iterations" \
	"$RUN_RELEASE_SMOKE")"
resumed_stages=()

write_json_file "$summary_path" \
	--arg status "running" \
	--arg phase "$failure_phase" \
	--arg destination "$DESTINATION" \
	--arg ui_selector "$UI_SELECTOR" \
	'{status: $status, phase: $phase, destination: $destination, ui_selector: $ui_selector}'

summary_passed_for_action() {
	local summary_path="$1"
	local expected_action="$2"
	local expected_destination="$3"

	[[ -f "$summary_path" ]] &&
		jq -e \
			--arg action "$expected_action" \
			--arg destination "$expected_destination" \
			'.status == "passed" and .action == $action and .destination == $destination' \
			"$summary_path" >/dev/null 2>&1
}

summary_referenced_file_exists() {
	local summary_path="$1"
	local key="$2"
	local referenced_path

	referenced_path="$(jq -er --arg key "$key" '.[$key] | select(type == "string" and length > 0)' "$summary_path")" || return 1
	[[ -f "$referenced_path" ]]
}

static_evidence_valid() {
	[[ -f "$OUT_DIR/lanes/static.log" ]] || return 1
	rg -q 'Static gate passed\.' "$OUT_DIR/lanes/static.log"
}

unit_evidence_valid() {
	local unit_summary="$OUT_DIR/unit/unit-summary.json"

	jq -e '.status == "passed" and .swift_test_count > 0 and .javascript_test_count > 0 and .go_package_count > 0' \
		"$unit_summary" >/dev/null 2>&1 || return 1
	summary_referenced_file_exists "$unit_summary" swift_log || return 1
	summary_referenced_file_exists "$unit_summary" javascript_log || return 1
	summary_referenced_file_exists "$unit_summary" go_log
}

xcode_preflight_evidence_valid() {
	local xcode_summary="$OUT_DIR/xcode-build/xcode-summary.json"
	local ui_summary="$OUT_DIR/xcode-build/ui-smoke-summary.json"
	local products

	if [[ "$RUN_UI_TESTS" == "true" ]]; then
		jq -e '.status == "passed" and .build_only == true' "$ui_summary" >/dev/null 2>&1 || return 1
		if [[ "$(jq -r '.test_evidence_reused' "$ui_summary")" == "true" ]]; then
			xcresult_test_evidence_valid "$(jq -r '.result_bundle' "$ui_summary")" "$UI_SELECTOR"
			return
		fi
		products="$(jq -er '.derived_data_path' "$ui_summary")" || return 1
		xcode_test_products_exist "$products" Debug "$DESTINATION" \
			"$(source_tree_fingerprint xcode)" "$xcode_identity" "$ROOT_DIR" VoidDisplay.xcodeproj VoidDisplay
	else
		summary_passed_for_action "$xcode_summary" "$xcode_preflight_action" "$DESTINATION" || return 1
		summary_referenced_file_exists "$xcode_summary" log_path || return 1
		[[ -d "$shared_derived_data/Build/Products/Debug/VoidDisplay.app" ]]
	fi
}

preflight_can_resume() {
	checkpoint_stage_passed "$checkpoint_path" preflight "$preflight_fingerprint" || return 1
	static_evidence_valid || return 1
	unit_evidence_valid || return 1
	if [[ "$RUN_XCODE_PREFLIGHT" == "true" ]]; then
		xcode_preflight_evidence_valid
	fi
}

ui_can_resume() {
	local result_bundle

	checkpoint_stage_passed "$checkpoint_path" ui "$ui_fingerprint" || return 1
	jq -e --arg selector "$UI_SELECTOR" \
		'.status == "passed" and .build_only == false and .only_testing == [$selector]' \
		"$OUT_DIR/xcode-test/ui-smoke-summary.json" >/dev/null 2>&1 || return 1
	result_bundle="$(jq -er '.result_bundle | select(type == "string" and length > 0)' "$OUT_DIR/xcode-test/ui-smoke-summary.json")" || return 1
	xcresult_test_evidence_valid "$result_bundle" "$UI_SELECTOR"
}

stability_evidence_valid() {
	local stability_summary="$OUT_DIR/stability/stability-summary.json"
	local stability_log_count

	jq -e --argjson iterations "$stability_iterations" \
		'.status == "passed" and .iterations == $iterations and .swift_test_count > 0 and .go_package_count > 0' \
		"$stability_summary" >/dev/null 2>&1 || return 1
	summary_referenced_file_exists "$stability_summary" go_log || return 1
	stability_log_count="$(/usr/bin/find "$OUT_DIR/stability/swift" -type f -name 'iteration-*.log' 2>/dev/null | wc -l | tr -d ' ')"
	[[ "$stability_log_count" == "$stability_iterations" ]]
}

release_smoke_evidence_valid() {
	local release_summary="$OUT_DIR/release-smoke-arm64/release-smoke-summary.json"
	local app_path
	local release_log

	jq -e '.status == "passed" and .arch == "arm64" and .label == "arm64"' \
		"$release_summary" >/dev/null 2>&1 || return 1
	app_path="$(jq -er '.app_path | select(type == "string" and length > 0)' "$release_summary")" || return 1
	release_log="$(jq -er '.log_path | select(type == "string" and length > 0)' "$release_summary")" || return 1
	[[ -f "$release_log" ]] || return 1
	(
		validate_release_app_binaries "$app_path" arm64
		codesign --verify --deep --strict "$app_path"
	) >/dev/null 2>&1
}

postflight_can_resume() {
	checkpoint_stage_passed "$checkpoint_path" postflight "$postflight_fingerprint" || return 1
	stability_evidence_valid || return 1
	if [[ "$RUN_RELEASE_SMOKE" == "true" ]]; then
		release_smoke_evidence_valid
	fi
}

failure_phase="preflight"
preflight_duration_seconds=0
preflight_reused_duration_seconds=0
if preflight_can_resume; then
	preflight_reused_duration_seconds="$(checkpoint_stage_duration "$checkpoint_path" preflight)"
	resumed_stages+=(preflight)
	info "Reusing completed full regression stage: preflight"
else
	checkpoint_invalidate_stage "$checkpoint_path" preflight
	preflight_started_at="$(date +%s)"
	parallel_group_begin
	parallel_group_start static "$OUT_DIR/lanes/static.log" \
		env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" AI_TMP_DIR="$OUT_DIR/static-workspace" \
		"$TOOL_ROOT/scripts/ci/static.sh"
	parallel_group_start unit "$OUT_DIR/lanes/unit.log" \
		env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" \
		"$TOOL_ROOT/scripts/ci/unit.sh" --out-dir "$OUT_DIR/unit"
	if [[ "$RUN_XCODE_PREFLIGHT" == "true" ]]; then
		xcode_preflight=("$TOOL_ROOT/scripts/ci/xcode.sh" --action build --configuration Debug --derived-data-path "$shared_derived_data")
		if [[ "$RUN_UI_TESTS" == "true" ]]; then
			xcode_preflight=("$TOOL_ROOT/scripts/ci/ui_smoke.sh" --build-only --only-testing "$UI_SELECTOR")
		fi
		parallel_group_start xcode-preflight "$OUT_DIR/lanes/xcode-preflight.log" \
			env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" \
			"${xcode_preflight[@]}" --destination "$DESTINATION" --out-dir "$OUT_DIR/xcode-build"
	fi
	parallel_group_wait "full regression preflight"
	preflight_duration_seconds="$(($(date +%s) - preflight_started_at))"
	require_source_tree_unchanged "$source_fingerprint" "full regression preflight"
	checkpoint_mark_stage_passed \
		"$checkpoint_path" preflight "$preflight_fingerprint" "$source_fingerprint" "$preflight_duration_seconds"
fi

ui_duration_seconds=0
ui_reused_duration_seconds=0
if [[ "$RUN_UI_TESTS" == "true" ]]; then
	failure_phase="ui"
	require_source_tree_unchanged "$source_fingerprint" "the transition to full regression UI tests"
	if ui_can_resume; then
		ui_reused_duration_seconds="$(checkpoint_stage_duration "$checkpoint_path" ui)"
		resumed_stages+=(ui)
		info "Reusing completed full regression stage: ui"
	else
		checkpoint_invalidate_stage "$checkpoint_path" ui
		ui_started_at="$(date +%s)"
		ui_command=("$TOOL_ROOT/scripts/ci/ui_smoke.sh")
		if [[ "$RESTART" == "true" ]]; then ui_command+=(--rerun); fi
		parallel_group_begin
		parallel_group_start_streamed ui "$OUT_DIR/lanes/ui.log" \
			env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "${ui_command[@]}" \
			--destination "$DESTINATION" \
			--only-testing "$UI_SELECTOR" \
			--out-dir "$OUT_DIR/xcode-test"
		parallel_group_wait "full regression UI"
		ui_duration_seconds="$(($(date +%s) - ui_started_at))"
		require_source_tree_unchanged "$source_fingerprint" "full regression UI tests"
		checkpoint_mark_stage_passed \
			"$checkpoint_path" ui "$ui_fingerprint" "$source_fingerprint" "$ui_duration_seconds"
	fi
fi

failure_phase="postflight"
postflight_duration_seconds=0
postflight_reused_duration_seconds=0
require_source_tree_unchanged "$source_fingerprint" "the transition to full regression postflight"
if postflight_can_resume; then
	postflight_reused_duration_seconds="$(checkpoint_stage_duration "$checkpoint_path" postflight)"
	resumed_stages+=(postflight)
	info "Reusing completed full regression stage: postflight"
else
	checkpoint_invalidate_stage "$checkpoint_path" postflight
	postflight_started_at="$(date +%s)"
	parallel_group_begin
	parallel_group_start stability "$OUT_DIR/lanes/stability.log" \
		env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" \
		"$TOOL_ROOT/scripts/ci/stability.sh" \
		--iterations "$stability_iterations" \
		--out-dir "$OUT_DIR/stability"
	if [[ "$RUN_RELEASE_SMOKE" == "true" ]]; then
		parallel_group_start release-smoke-arm64 "$OUT_DIR/lanes/release-smoke-arm64.log" \
			env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" \
			"$TOOL_ROOT/scripts/ci/release_smoke.sh" \
			--arch arm64 \
			--label arm64 \
			--out-dir "$OUT_DIR/release-smoke-arm64"
	fi
	parallel_group_wait "full regression postflight"
	postflight_duration_seconds="$(($(date +%s) - postflight_started_at))"
	require_source_tree_unchanged "$source_fingerprint" "full regression postflight"
	checkpoint_mark_stage_passed \
		"$checkpoint_path" postflight "$postflight_fingerprint" "$source_fingerprint" "$postflight_duration_seconds"
fi
failure_phase="summary"
require_source_tree_unchanged "$source_fingerprint" "full regression summary generation"
total_duration_seconds="$(($(date +%s) - regression_started_at))"
resumed_stages_json='[]'
if [[ "${#resumed_stages[@]}" -gt 0 ]]; then
	resumed_stages_json="$(printf '%s\n' "${resumed_stages[@]}" | jq -R . | jq -s .)"
fi

write_json_file "$summary_path" \
	--arg status "passed" \
	--arg destination "$DESTINATION" \
	--arg ui_selector "$UI_SELECTOR" \
	--arg out_dir "$OUT_DIR" \
	--arg checkpoint_path "$checkpoint_path" \
	--argjson ui_tests_enabled "$([[ "$RUN_UI_TESTS" == "true" ]] && printf true || printf false)" \
	--argjson release_smoke_enabled "$([[ "$RUN_RELEASE_SMOKE" == "true" ]] && printf true || printf false)" \
	--argjson xcode_preflight_enabled "$([[ "$RUN_XCODE_PREFLIGHT" == "true" ]] && printf true || printf false)" \
	--argjson resumed_stages "$resumed_stages_json" \
	--argjson preflight_duration_seconds "$preflight_duration_seconds" \
	--argjson ui_duration_seconds "$ui_duration_seconds" \
	--argjson postflight_duration_seconds "$postflight_duration_seconds" \
	--argjson preflight_reused_duration_seconds "$preflight_reused_duration_seconds" \
	--argjson ui_reused_duration_seconds "$ui_reused_duration_seconds" \
	--argjson postflight_reused_duration_seconds "$postflight_reused_duration_seconds" \
	--argjson total_duration_seconds "$total_duration_seconds" \
	'{status: $status, destination: $destination, ui_selector: $ui_selector, out_dir: $out_dir, checkpoint_path: $checkpoint_path, ui_tests_enabled: $ui_tests_enabled, release_smoke_enabled: $release_smoke_enabled, xcode_preflight_enabled: $xcode_preflight_enabled, resumed_stages: $resumed_stages, execution: {preflight_duration_seconds: $preflight_duration_seconds, ui_duration_seconds: $ui_duration_seconds, postflight_duration_seconds: $postflight_duration_seconds, total_duration_seconds: $total_duration_seconds}, reused_evidence: {preflight_duration_seconds: $preflight_reused_duration_seconds, ui_duration_seconds: $ui_reused_duration_seconds, postflight_duration_seconds: $postflight_reused_duration_seconds}}'
summary_terminal="true"

info "Full regression gate passed."
info "Summary: $summary_path"
