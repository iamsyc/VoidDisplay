#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_XCRESULT_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_XCRESULT_SH_SOURCED=1

	# shellcheck source=scripts/lib/common.sh
	source "$TOOL_ROOT/scripts/lib/common.sh"

	xcresult_summary_json() {
		local xcresult_path="$1"
		[[ -d "$xcresult_path" ]] || die "Missing xcresult bundle: $xcresult_path"
		xcrun xcresulttool get test-results summary --path "$xcresult_path"
	}

	xcresult_extract_metric() {
		local summary="$1"
		local key="$2"
		local fallback="$3"
		local line
		local value

		line="$(printf '%s\n' "$summary" | rg "\"$key\"" | tail -n 1)" || true
		if [[ -z "$line" ]]; then
			printf '%s' "$fallback"
			return 0
		fi

		value="$(printf '%s\n' "$line" | awk -F': ' '{print $2}' | tr -d ',\"')"
		if [[ -z "$value" ]]; then
			printf '%s' "$fallback"
		else
			printf '%s' "$value"
		fi
	}

	guard_xcresult_test_count() {
		local xcresult_path="$1"
		local label="$2"
		local summary
		local total_tests
		local failed_tests
		local result_status

		summary="$(xcresult_summary_json "$xcresult_path")"
		total_tests="$(xcresult_extract_metric "$summary" totalTestCount 0)"
		failed_tests="$(xcresult_extract_metric "$summary" failedTests 0)"
		result_status="$(xcresult_extract_metric "$summary" result unknown)"

		info "$label summary: result=$result_status totalTestCount=$total_tests failedTests=$failed_tests"

		if [[ "$total_tests" == "0" ]]; then
			die "$label invalid: totalTestCount == 0."
		fi
	}
fi
