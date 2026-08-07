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

cd "$ROOT_DIR"

ONLY_TESTING=()
MAX_ATTEMPTS="${MAX_ATTEMPTS:-1}"
ENFORCE_FAILURE="true"
OUT_DIR="$(make_artifact_dir ci-ui-smoke)"
DERIVED_DATA_PATH=""
DESTINATION="$(xcode_destination_for_arch arm64)"
TEST_ACTION="test"
ACTIVE_XCODE_RUNNER_PID=""
ACTIVE_ATTEMPT=0
ACTIVE_LOG_FILE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--only-testing)
		ONLY_TESTING+=("$2")
		shift 2
		;;
	--test-without-building)
		TEST_ACTION="test-without-building"
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

mkdir -p "$OUT_DIR"
SUMMARY_FILE="$OUT_DIR/ui-smoke-summary.json"
rm -f -- "$SUMMARY_FILE"

if [[ "${#ONLY_TESTING[@]}" -eq 0 ]]; then
	ONLY_TESTING+=("VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline")
fi
for test_identifier in "${ONLY_TESTING[@]}"; do
	[[ -n "$test_identifier" ]] || die "--only-testing cannot be empty."
done
if [[ "$TEST_ACTION" == "test-without-building" && -z "$DERIVED_DATA_PATH" ]]; then
	die "--test-without-building requires --derived-data-path."
fi
if ! [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || [[ "$MAX_ATTEMPTS" -lt 1 || "$MAX_ATTEMPTS" -gt 5 ]]; then
	die "Invalid --max-attempts value: $MAX_ATTEMPTS"
fi

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$OUT_DIR/DerivedData}"
require_command grep jq
only_testing_json="$(printf '%s\n' "${ONLY_TESTING[@]}" | jq -R . | jq -s .)"

write_summary() {
	local status="$1"
	local reason="$2"
	local attempt="$3"
	local log_file="$4"

	write_json_file "$SUMMARY_FILE" \
		--arg status "$status" \
		--arg reason "$reason" \
		--argjson only_testing "$only_testing_json" \
		--argjson attempt "$attempt" \
		--argjson max_attempts "$MAX_ATTEMPTS" \
		--arg log_file "$log_file" \
		'{status: $status, reason: $reason, only_testing: $only_testing, attempt: $attempt, max_attempts: $max_attempts, log_file: $log_file}'
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
	write_summary "failed" "interrupted" "$ACTIVE_ATTEMPT" "$ACTIVE_LOG_FILE"
	exit "$exit_status"
}

write_summary "running" "in_progress" 0 ""
[[ -x "$TOOL_ROOT/scripts/ci/xcode.sh" ]] || finish_failure 0 "xcode_runner_missing" ""
trap 'forward_active_xcode_signal INT 130' INT
trap 'forward_active_xcode_signal TERM 143' TERM
trap 'forward_active_xcode_signal HUP 129' HUP

last_reason="not_run"
last_log_file=""
for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
	info "UI smoke attempt $attempt/$MAX_ATTEMPTS"
	attempt_dir="$OUT_DIR/attempt-$attempt"
	xcode_summary="$attempt_dir/xcode-summary.json"
	fallback_log="$attempt_dir/xcode-$TEST_ACTION-Debug.log"
	mkdir -p "$attempt_dir"

	xcode_args=(
		"$TOOL_ROOT/scripts/ci/xcode.sh"
		--action "$TEST_ACTION"
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
	if wait "$ACTIVE_XCODE_RUNNER_PID"; then
		xcode_status=0
	else
		xcode_status=$?
	fi
	ACTIVE_XCODE_RUNNER_PID=""
	summary_log=""
	if [[ -f "$xcode_summary" ]]; then
		summary_log="$(jq -r 'if type == "object" then (.log_path // "") else "" end' "$xcode_summary" 2>/dev/null || true)"
	fi
	log_file="${summary_log:-$fallback_log}"

	if [[ "$xcode_status" -eq 0 ]]; then
		write_summary "passed" "none" "$attempt" "$log_file"
		info "UI smoke passed."
		exit 0
	fi

	last_reason=""
	if [[ -f "$xcode_summary" ]]; then
		last_reason="$(jq -r 'if type == "object" then (.reason // "") else "" end' "$xcode_summary" 2>/dev/null || true)"
	fi
	case "$last_reason" in
	"" | in_progress | passed) last_reason="unknown_failure" ;;
	esac
	last_log_file="$log_file"
	if transient_reason="$(classify_transient_log "$log_file")"; then
		last_reason="$transient_reason"
		if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then
			warn "Retrying transient UI smoke failure. reason=$last_reason"
		fi
		continue
	fi
	finish_failure "$attempt" "$last_reason" "$last_log_file"
done

finish_failure "$MAX_ATTEMPTS" "$last_reason" "$last_log_file"
