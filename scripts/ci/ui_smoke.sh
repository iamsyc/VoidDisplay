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
# shellcheck source=scripts/lib/checkpoint.sh
source "$TOOL_ROOT/scripts/lib/checkpoint.sh"
# shellcheck source=scripts/lib/xcode.sh
source "$TOOL_ROOT/scripts/lib/xcode.sh"
# shellcheck source=scripts/lib/xcresult.sh
source "$TOOL_ROOT/scripts/lib/xcresult.sh"

cd "$ROOT_DIR"

ONLY_TESTING=()
MAX_ATTEMPTS="${MAX_ATTEMPTS:-1}"
ENFORCE_FAILURE="true"
OUT_DIR="$(make_artifact_dir ci-ui-smoke)"
DERIVED_DATA_PATH=""
DESTINATION="$(xcode_destination_for_arch arm64)"
TEST_WITHOUT_BUILDING="false"
REBUILD="false"
RERUN="false"
BUILD_LOCK_WAIT_SECONDS="${VOIDDISPLAY_UI_SESSION_WAIT_SECONDS:-600}"
ACTIVE_XCODE_RUNNER_PID=""
ACTIVE_ATTEMPT=0
ACTIVE_LOG_FILE=""
STARTED_AT="$(date +%s)"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--only-testing)
		ONLY_TESTING+=("$2")
		shift 2
		;;
	--test-without-building)
		TEST_WITHOUT_BUILDING="true"
		shift
		;;
	--rebuild)
		REBUILD="true"
		RERUN="true"
		shift
		;;
	--rerun)
		RERUN="true"
		shift
		;;
	--max-attempts)
		MAX_ATTEMPTS="$2"
		shift 2
		;;
	--enforce-failure)
		ENFORCE_FAILURE="$2"
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
	--destination)
		DESTINATION="$2"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

if [[ "${#ONLY_TESTING[@]}" -eq 0 ]]; then
	ONLY_TESTING+=("VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney")
fi
for test_identifier in "${ONLY_TESTING[@]}"; do
	[[ -n "$test_identifier" ]] || die "--only-testing cannot be empty."
done
if ! [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || [[ "$MAX_ATTEMPTS" -lt 1 || "$MAX_ATTEMPTS" -gt 5 ]]; then
	die "Invalid --max-attempts value: $MAX_ATTEMPTS"
fi
if ! [[ "$BUILD_LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
	die "Invalid UI build lifecycle wait: $BUILD_LOCK_WAIT_SECONDS"
fi

require_command git grep jq lockf shasum xcodebuild xcrun
select_required_xcode
source_fingerprint="$(source_tree_fingerprint)"
xcode_identity="$(xcodebuild -version)"
evidence_root="$(normalize_path "${UI_TEST_EVIDENCE_ROOT:-$ROOT_DIR/.ai-tmp/test-evidence/ui}")"
build_key="$(checkpoint_run_fingerprint "$source_fingerprint" "$xcode_identity" "$DESTINATION" Debug)"
explicit_derived_data="false"
if [[ -n "$DERIVED_DATA_PATH" ]]; then
	explicit_derived_data="true"
elif [[ "$TEST_WITHOUT_BUILDING" == "true" ]]; then
	die "--test-without-building requires --derived-data-path."
else
	DERIVED_DATA_PATH="$evidence_root/builds/$build_key/DerivedData"
fi
if [[ "$REBUILD" == "true" && "$explicit_derived_data" == "true" ]]; then
	die "--rebuild cannot remove a caller-owned --derived-data-path."
fi

mkdir -p "$OUT_DIR" "$evidence_root/locks" "$evidence_root/results"
SUMMARY_FILE="$OUT_DIR/ui-smoke-summary.json"
rm -f -- "$SUMMARY_FILE"
only_testing_json="$(printf '%s\n' "${ONLY_TESTING[@]}" | jq -R . | jq -s .)"
selector_key="$(printf '%s\0' "${ONLY_TESTING[@]}" | shasum -a 256 | awk '{print $1}')"
run_signature="$(checkpoint_run_fingerprint "$build_key" "$selector_key")"
run_lock="$evidence_root/locks/$run_signature.lock"
exec 8>"$run_lock"
if ! /usr/bin/lockf -s -t 0 8; then
	die "The same UI source and selector set is already running."
fi

is_full_target="false"
if [[ "${#ONLY_TESTING[@]}" -eq 1 && "${ONLY_TESTING[0]}" == "VoidDisplayUITests" ]]; then
	is_full_target="true"
fi
evidence_path="$evidence_root/results/$run_signature.json"
build_reused="false"
test_evidence_reused="false"

write_summary() {
	local status="$1"
	local reason="$2"
	local attempt="$3"
	local log_file="$4"
	local duration_seconds="$(($(date +%s) - STARTED_AT))"

	write_json_file "$SUMMARY_FILE" \
		--arg status "$status" \
		--arg reason "$reason" \
		--argjson only_testing "$only_testing_json" \
		--argjson attempt "$attempt" \
		--argjson max_attempts "$MAX_ATTEMPTS" \
		--arg log_file "$log_file" \
		--arg source_fingerprint "$source_fingerprint" \
		--argjson build_reused "$build_reused" \
		--argjson test_evidence_reused "$test_evidence_reused" \
		--argjson execution_duration_seconds "$duration_seconds" \
		'{status: $status, reason: $reason, only_testing: $only_testing, attempt: $attempt, max_attempts: $max_attempts, log_file: $log_file, source_fingerprint: $source_fingerprint, build_reused: $build_reused, test_evidence_reused: $test_evidence_reused, execution_duration_seconds: $execution_duration_seconds}'
}

full_evidence_valid() {
	local result_bundle

	[[ -f "$evidence_path" ]] || return 1
	jq -e \
		--arg source_fingerprint "$source_fingerprint" \
		--arg run_signature "$run_signature" \
		--argjson only_testing "$only_testing_json" \
		'.status == "passed" and .source_fingerprint == $source_fingerprint and .run_signature == $run_signature and .only_testing == $only_testing and .total_tests > 0 and .failed_tests == 0' \
		"$evidence_path" >/dev/null 2>&1 || return 1
	result_bundle="$(jq -er '.result_bundle | select(type == "string" and length > 0)' "$evidence_path")" || return 1
	xcresult_test_evidence_valid "$result_bundle" "VoidDisplayUITests"
}

classify_transient_log() {
	local log_file="$1"
	[[ -f "$log_file" ]] || return 1
	if grep -Eq "Early unexpected exit, operation never finished bootstrapping|Test crashed with signal kill before establishing connection" "$log_file"; then
		printf 'runner_bootstrap_failure\n'
	elif grep -Eq "Failed to activate application .*\(current state: Running Background\)" "$log_file"; then
		printf 'environment_automation_failure\n'
	elif grep -Eq "XCTSkip|skip real-environment|environment not stable" "$log_file"; then
		printf 'environment_unstable\n'
	else
		return 1
	fi
}

finish_failure() {
	local attempt="$1"
	local reason="$2"
	local log_file="$3"
	rm -f -- "$evidence_path"
	write_summary "failed" "$reason" "$attempt" "$log_file"
	if [[ "$ENFORCE_FAILURE" != "true" ]]; then
		warn "UI smoke failed with enforcement disabled. reason=$reason"
		exit 0
	fi
	die "UI smoke failed. reason=$reason"
}

forward_active_xcode_signal() {
	local signal_name="$1"
	local exit_status="$2"
	trap '' INT TERM HUP
	if [[ -n "$ACTIVE_XCODE_RUNNER_PID" ]] && /bin/kill -0 "$ACTIVE_XCODE_RUNNER_PID" >/dev/null 2>&1; then
		/bin/kill -"$signal_name" "$ACTIVE_XCODE_RUNNER_PID" >/dev/null 2>&1 || true
		wait "$ACTIVE_XCODE_RUNNER_PID" >/dev/null 2>&1 || true
	fi
	rm -f -- "$evidence_path"
	write_summary "failed" "interrupted" "$ACTIVE_ATTEMPT" "$ACTIVE_LOG_FILE"
	exit "$exit_status"
}

ensure_source_unchanged() {
	if ! (require_source_tree_unchanged "$source_fingerprint" "UI smoke $1"); then
		finish_failure "$ACTIVE_ATTEMPT" "source_changed" "$ACTIVE_LOG_FILE"
	fi
}

write_summary "running" "in_progress" 0 ""
[[ -x "$TOOL_ROOT/scripts/ci/xcode.sh" ]] || finish_failure 0 "xcode_runner_missing" ""
trap 'forward_active_xcode_signal INT 130' INT
trap 'forward_active_xcode_signal TERM 143' TERM
trap 'forward_active_xcode_signal HUP 129' HUP

if [[ "$is_full_target" == "true" && "$RERUN" != "true" ]] && full_evidence_valid; then
	ensure_source_unchanged "evidence reuse"
	test_evidence_reused="true"
	build_reused="true"
	write_summary "passed" "reused_test_evidence" 0 "$(jq -r '.log_file // ""' "$evidence_path")"
	info "Reusing completed full UI target evidence."
	exit 0
fi

build_lock="$evidence_root/locks/build-$build_key.lock"
exec 7>"$build_lock"
if ! /usr/bin/lockf -s -t 0 7; then
	info "Another UI selector is using these test products; waiting up to $BUILD_LOCK_WAIT_SECONDS seconds."
	if ! /usr/bin/lockf -s -t "$BUILD_LOCK_WAIT_SECONDS" 7; then
		finish_failure 0 "build_lock_timeout" ""
	fi
fi

ensure_source_unchanged "build lifecycle lock acquisition"

if [[ "$REBUILD" == "true" ]]; then
	case "$DERIVED_DATA_PATH" in
	"$evidence_root"/builds/*/DerivedData) /bin/rm -rf -- "$DERIVED_DATA_PATH" ;;
	*) die "Refusing to rebuild outside the managed UI evidence directory." ;;
	esac
fi

if [[ "$TEST_WITHOUT_BUILDING" == "true" ]]; then
	if xcode_test_products_exist \
		"$DERIVED_DATA_PATH" Debug "$DESTINATION" "$source_fingerprint" "$xcode_identity" \
		"$ROOT_DIR" VoidDisplay.xcodeproj VoidDisplay; then
		build_reused="true"
	else
		finish_failure 0 "test_products_validation_failed" ""
	fi
else
	if xcode_test_products_exist \
		"$DERIVED_DATA_PATH" Debug "$DESTINATION" "$source_fingerprint" "$xcode_identity" \
		"$ROOT_DIR" VoidDisplay.xcodeproj VoidDisplay; then
		build_reused="true"
	else
		info "Building UI test products for source fingerprint $source_fingerprint."
		build_dir="$OUT_DIR/runs/$run_signature/build"
		ACTIVE_LOG_FILE="$build_dir/xcode-build-for-testing-Debug.log"
		"$TOOL_ROOT/scripts/ci/xcode.sh" \
			--action build-for-testing \
			--configuration Debug \
			--destination "$DESTINATION" \
			--derived-data-path "$DERIVED_DATA_PATH" \
			--out-dir "$build_dir" &
		ACTIVE_XCODE_RUNNER_PID=$!
		if wait "$ACTIVE_XCODE_RUNNER_PID"; then build_status=0; else build_status=$?; fi
		ACTIVE_XCODE_RUNNER_PID=""
		if [[ "$build_status" -ne 0 ]]; then
			build_reason="build_for_testing_failed"
			if [[ -f "$build_dir/xcode-summary.json" ]]; then
				build_reason="$(jq -r '.reason // "build_for_testing_failed"' "$build_dir/xcode-summary.json")"
				ACTIVE_LOG_FILE="$(jq -r '.log_path // ""' "$build_dir/xcode-summary.json")"
			fi
			finish_failure 0 "$build_reason" "$ACTIVE_LOG_FILE"
		fi
	fi
fi

last_reason="not_run"
last_log_file=""
for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
	info "UI smoke attempt $attempt/$MAX_ATTEMPTS"
	attempt_dir="$OUT_DIR/runs/$run_signature/attempt-$attempt"
	xcode_summary="$attempt_dir/xcode-summary.json"
	fallback_log="$attempt_dir/xcode-test-without-building-Debug.log"
	mkdir -p "$attempt_dir"
	xcode_args=(
		"$TOOL_ROOT/scripts/ci/xcode.sh"
		--action test-without-building
		--configuration Debug
		--destination "$DESTINATION"
		--derived-data-path "$DERIVED_DATA_PATH"
		--out-dir "$attempt_dir"
	)
	for test_identifier in "${ONLY_TESTING[@]}"; do
		xcode_args+=(--only-testing "$test_identifier")
	done

	ACTIVE_ATTEMPT="$attempt"
	ACTIVE_LOG_FILE="$fallback_log"
	"${xcode_args[@]}" &
	ACTIVE_XCODE_RUNNER_PID=$!
	if wait "$ACTIVE_XCODE_RUNNER_PID"; then xcode_status=0; else xcode_status=$?; fi
	ACTIVE_XCODE_RUNNER_PID=""
	summary_log=""
	if [[ -f "$xcode_summary" ]]; then
		summary_log="$(jq -r 'if type == "object" then (.log_path // "") else "" end' "$xcode_summary" 2>/dev/null || true)"
	fi
	log_file="${summary_log:-$fallback_log}"

	if [[ "$xcode_status" -eq 0 ]]; then
		ensure_source_unchanged "test completion"
		if [[ "$is_full_target" == "true" ]]; then
			result_bundle="$(jq -er '.result_bundle' "$xcode_summary")"
			write_json_file "$evidence_path" \
				--arg source_fingerprint "$source_fingerprint" \
				--arg run_signature "$run_signature" \
				--argjson only_testing "$only_testing_json" \
				--arg result_bundle "$result_bundle" \
				--arg log_file "$log_file" \
				--argjson total_tests "$(jq '.total_tests' "$xcode_summary")" \
				--argjson failed_tests "$(jq '.failed_tests' "$xcode_summary")" \
				'{status: "passed", source_fingerprint: $source_fingerprint, run_signature: $run_signature, only_testing: $only_testing, result_bundle: $result_bundle, log_file: $log_file, total_tests: $total_tests, failed_tests: $failed_tests}'
		fi
		write_summary "passed" "none" "$attempt" "$log_file"
		info "UI smoke passed."
		exit 0
	fi

	last_reason=""
	if [[ -f "$xcode_summary" ]]; then
		last_reason="$(jq -r 'if type == "object" then (.reason // "") else "" end' "$xcode_summary" 2>/dev/null || true)"
	fi
	case "$last_reason" in "" | in_progress | passed) last_reason="unknown_failure" ;; esac
	last_log_file="$log_file"
	if transient_reason="$(classify_transient_log "$log_file")"; then
		last_reason="$transient_reason"
		if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then warn "Retrying transient UI smoke failure. reason=$last_reason"; fi
		continue
	fi
	finish_failure "$attempt" "$last_reason" "$last_log_file"
done

finish_failure "$MAX_ATTEMPTS" "$last_reason" "$last_log_file"
