#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/architecture.sh
source "$TOOL_ROOT/scripts/lib/architecture.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"
# shellcheck source=scripts/lib/parallel.sh
source "$TOOL_ROOT/scripts/lib/parallel.sh"
# shellcheck source=scripts/lib/checkpoint.sh
source "$TOOL_ROOT/scripts/lib/checkpoint.sh"

cd "$ROOT_DIR"

OUT_DIR="${OUT_DIR:-$(make_artifact_dir local-validation)}"
UI_SELECTOR="VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline"
RUN_UI_SMOKE="true"

host_arch="$(uname -m)"
case "$host_arch" in
arm64 | x86_64) DESTINATION="$(xcode_destination_for_arch "$host_arch")" ;;
*) die "Unsupported host architecture for local validation: $host_arch" ;;
esac

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
	--skip-ui-smoke)
		RUN_UI_SMOKE="false"
		shift
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

mkdir -p "$OUT_DIR"
validation_started_at="$(date +%s)"
summary_path="$OUT_DIR/local-validation-summary.json"
summary_terminal="false"
failure_phase="initialization"
rm -f -- "$summary_path"

cleanup_local_validation() {
	local exit_status=$?
	local elapsed_seconds

	trap - EXIT INT TERM
	parallel_group_cancel
	if [[ "$exit_status" -ne 0 && "$summary_terminal" != "true" ]] && command -v jq >/dev/null 2>&1; then
		set +e
		elapsed_seconds="$(($(date +%s) - validation_started_at))"
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
trap cleanup_local_validation EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_command git jq shasum
source_fingerprint="$(source_tree_fingerprint)"
write_json_file "$summary_path" \
	--arg status "running" \
	--arg phase "$failure_phase" \
	--arg destination "$DESTINATION" \
	--arg ui_selector "$UI_SELECTOR" \
	'{status: $status, phase: $phase, destination: $destination, ui_selector: $ui_selector}'
shared_derived_data="$OUT_DIR/xcode-shared/DerivedData"
xcode_preflight_action="build"
if [[ "$RUN_UI_SMOKE" == "true" ]]; then
	xcode_preflight_action="build-for-testing"
fi

failure_phase="preflight"
preflight_started_at="$(date +%s)"
parallel_group_begin
parallel_group_start static "$OUT_DIR/lanes/static.log" \
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" AI_TMP_DIR="$OUT_DIR/static-workspace" \
	"$TOOL_ROOT/scripts/ci/static.sh"
parallel_group_start unit "$OUT_DIR/lanes/unit.log" \
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" \
	"$TOOL_ROOT/scripts/ci/unit.sh" --out-dir "$OUT_DIR/unit"
parallel_group_start xcode-preflight "$OUT_DIR/lanes/xcode-preflight.log" \
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" \
	"$TOOL_ROOT/scripts/ci/xcode.sh" \
	--action "$xcode_preflight_action" \
	--configuration Debug \
	--destination "$DESTINATION" \
	--derived-data-path "$shared_derived_data" \
	--out-dir "$OUT_DIR/xcode-build"
parallel_group_wait "local validation preflight"
preflight_duration_seconds="$(($(date +%s) - preflight_started_at))"
require_source_tree_unchanged "$source_fingerprint" "local validation preflight"

ui_duration_seconds=0
if [[ "$RUN_UI_SMOKE" == "true" ]]; then
	failure_phase="ui"
	ui_started_at="$(date +%s)"
	parallel_group_begin
	parallel_group_start_streamed ui-smoke "$OUT_DIR/lanes/ui-smoke.log" \
		env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/ui_smoke.sh" \
		--only-testing "$UI_SELECTOR" \
		--test-without-building \
		--derived-data-path "$shared_derived_data" \
		--destination "$DESTINATION" \
		--out-dir "$OUT_DIR/ui-smoke"
	parallel_group_wait "local validation UI smoke"
	ui_duration_seconds="$(($(date +%s) - ui_started_at))"
	require_source_tree_unchanged "$source_fingerprint" "local validation UI smoke"
fi

failure_phase="summary"
require_source_tree_unchanged "$source_fingerprint" "local validation summary generation"
total_duration_seconds="$(($(date +%s) - validation_started_at))"

write_json_file "$summary_path" \
	--arg status "passed" \
	--arg out_dir "$OUT_DIR" \
	--arg destination "$DESTINATION" \
	--arg ui_selector "$UI_SELECTOR" \
	--argjson ui_smoke_enabled "$([[ "$RUN_UI_SMOKE" == "true" ]] && printf true || printf false)" \
	--argjson preflight_duration_seconds "$preflight_duration_seconds" \
	--argjson ui_duration_seconds "$ui_duration_seconds" \
	--argjson total_duration_seconds "$total_duration_seconds" \
	'{status: $status, out_dir: $out_dir, destination: $destination, ui_selector: $ui_selector, ui_smoke_enabled: $ui_smoke_enabled, execution: {preflight_duration_seconds: $preflight_duration_seconds, ui_duration_seconds: $ui_duration_seconds, total_duration_seconds: $total_duration_seconds}}'
summary_terminal="true"

info "Local validation gate passed."
info "Summary: $summary_path"
