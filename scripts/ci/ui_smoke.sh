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

ONLY_TESTING="VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
ENFORCE_FAILURE="true"
OUT_DIR="$(make_artifact_dir ci-ui-smoke)"
DERIVED_DATA_PATH=""
DESTINATION="$(xcode_destination_for_arch arm64)"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--only-testing)
		ONLY_TESTING="$2"
		shift 2
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

if [[ -z "$ONLY_TESTING" ]]; then
	die "--only-testing is required."
fi
if ! [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || [[ "$MAX_ATTEMPTS" -lt 1 || "$MAX_ATTEMPTS" -gt 5 ]]; then
	die "Invalid --max-attempts value: $MAX_ATTEMPTS"
fi

mkdir -p "$OUT_DIR"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$OUT_DIR/DerivedData}"
SUMMARY_FILE="$OUT_DIR/ui-smoke-summary.json"

classify_failure() {
	local log_file="$1"
	if grep -Eq "Early unexpected exit, operation never finished bootstrapping|Test crashed with signal kill before establishing connection" "$log_file"; then
		printf 'runner_bootstrap_failure\n'
		return
	fi
	if grep -Eq "Assertion Failure|XCTAssert|Test Case '.*' failed" "$log_file"; then
		printf 'assertion_failure\n'
		return
	fi
	if grep -Eq "XCTSkip|skip real-environment|environment not stable" "$log_file"; then
		printf 'environment_unstable\n'
		return
	fi
	printf 'unknown_failure\n'
}

write_summary() {
	local status="$1"
	local reason="$2"
	local attempt="$3"
	local log_file="$4"
	jq -n \
		--arg status "$status" \
		--arg reason "$reason" \
		--arg only_testing "$ONLY_TESTING" \
		--argjson attempt "$attempt" \
		--argjson max_attempts "$MAX_ATTEMPTS" \
		--arg log_file "$log_file" \
		'{status: $status, reason: $reason, only_testing: $only_testing, attempt: $attempt, max_attempts: $max_attempts, log_file: $log_file}' \
		>"$SUMMARY_FILE"
}

select_required_xcode
require_command jq go rg
go_mod_download_with_retry "$ROOT_DIR/Tools/VoidDisplayRelay"

last_reason="not_run"
last_log_file=""

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
	info "UI smoke attempt $attempt/$MAX_ATTEMPTS"
	log_file="$OUT_DIR/ui-smoke-attempt-$attempt.log"
	result_bundle="$OUT_DIR/UISmokeTests-attempt-$attempt.xcresult"
	rm -rf "$result_bundle"

	set +e
	xcodebuild \
		-scheme VoidDisplay \
		-project Apps/VoidDisplay/VoidDisplay.xcodeproj \
		-destination "$DESTINATION" \
		-derivedDataPath "$DERIVED_DATA_PATH" \
		-resultBundlePath "$result_bundle" \
		-skipPackageUpdates \
		-onlyUsePackageVersionsFromResolvedFile \
		ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		test \
		-only-testing:"$ONLY_TESTING" \
		2>&1 | tee "$log_file"
	status=${PIPESTATUS[0]}
	set -e

	if [[ "$status" -eq 0 ]]; then
		guard_xcresult_test_count "$result_bundle" "UI smoke attempt $attempt/$MAX_ATTEMPTS"
		write_summary "passed" "none" "$attempt" "$log_file"
		info "UI smoke passed."
		exit 0
	fi

	last_reason="$(classify_failure "$log_file")"
	last_log_file="$log_file"
	if [[ "$last_reason" == "assertion_failure" || "$last_reason" == "unknown_failure" ]]; then
		write_summary "failed" "$last_reason" "$attempt" "$log_file"
		die "UI smoke failed with deterministic reason: $last_reason"
	fi
done

write_summary "failed" "$last_reason" "$MAX_ATTEMPTS" "$last_log_file"

if [[ "$ENFORCE_FAILURE" != "true" ]]; then
	warn "UI smoke failed with enforcement disabled. reason=$last_reason"
	exit 0
fi

die "UI smoke failed after retries. reason=$last_reason"
