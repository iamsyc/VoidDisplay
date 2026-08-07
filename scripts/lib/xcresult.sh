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

	xcresult_test_evidence_json() {
		local xcresult_path="$1"
		shift
		local summary
		local tests
		local selector
		local requested_selectors_json='[]'

		[[ -d "$xcresult_path" ]] || return 1
		summary="$(xcresult_summary_json "$xcresult_path" 2>/dev/null)" || return 1

		if [[ "$#" -gt 0 ]]; then
			requested_selectors_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)" || return 1
			tests="$(xcrun xcresulttool get test-results tests --path "$xcresult_path" 2>/dev/null)" || return 1
			for selector in "$@"; do
				[[ -n "$selector" ]] || return 1
				jq -e --arg suffix "/$selector" \
					'any(.. | objects | .nodeIdentifierURL?; type == "string" and endswith($suffix))' \
					<<<"$tests" >/dev/null || return 1
			done
		fi

		jq -ce \
			--argjson requested_selectors "$requested_selectors_json" \
			'(.totalTestCount // null) as $total
			| (.passedTests // null) as $passed
			| (.skippedTests // null) as $skipped
			| (.failedTests // null) as $failed
			| select([$total, $passed, $skipped, $failed] | all(.[]; type == "number"))
			| select(.result == "Passed" and $total > 0 and $passed == $total and $skipped == 0 and $failed == 0)
			| {result_status: .result, total_tests: $total, passed_tests: $passed, skipped_tests: $skipped, failed_tests: $failed, requested_selectors: $requested_selectors}' \
			<<<"$summary"
	}

	xcresult_test_evidence_valid() {
		xcresult_test_evidence_json "$@" >/dev/null
	}
fi
