#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/xcode.sh
source "$TOOL_ROOT/scripts/lib/xcode.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

cd "$ROOT_DIR"

require_command go jq node rg xcodebuild swift awk
select_required_xcode

OUT_DIR="${OUT_DIR:-$(make_artifact_dir ci-unit)}"
SWIFT_LOG="${SWIFT_LOG:-$OUT_DIR/swift-test.log}"
JAVASCRIPT_LOG="${JAVASCRIPT_LOG:-$OUT_DIR/javascript-test.log}"
GO_LOG="${GO_LOG:-$OUT_DIR/go-test.log}"
SUMMARY_PATH="$OUT_DIR/unit-summary.json"
ENABLE_CODE_COVERAGE="${ENABLE_CODE_COVERAGE:-NO}"
SWIFT_FILTERS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--filter | --only-testing)
		SWIFT_FILTERS+=("${2#*:}")
		shift 2
		;;
	--enable-code-coverage)
		ENABLE_CODE_COVERAGE="$2"
		shift 2
		;;
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
		SWIFT_LOG="$OUT_DIR/swift-test.log"
		JAVASCRIPT_LOG="$OUT_DIR/javascript-test.log"
		GO_LOG="$OUT_DIR/go-test.log"
		SUMMARY_PATH="$OUT_DIR/unit-summary.json"
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

mkdir -p "$OUT_DIR"
swift_test_count=0
javascript_test_count=0
go_package_count=0

write_unit_summary() {
	local status="$1"
	local reason="$2"

	write_json_file "$SUMMARY_PATH" \
		--arg status "$status" \
		--arg reason "$reason" \
		--argjson swift_test_count "$swift_test_count" \
		--argjson javascript_test_count "$javascript_test_count" \
		--argjson go_package_count "$go_package_count" \
		--arg swift_log "$SWIFT_LOG" \
		--arg javascript_log "$JAVASCRIPT_LOG" \
		--arg go_log "$GO_LOG" \
		'{status: $status, reason: $reason, swift_test_count: $swift_test_count, javascript_test_count: $javascript_test_count, go_package_count: $go_package_count, swift_log: $swift_log, javascript_log: $javascript_log, go_log: $go_log}'
}

swift_test_cmd=(swift test)
if [[ "$ENABLE_CODE_COVERAGE" == "YES" ]]; then
	swift_test_cmd+=(--enable-code-coverage)
fi
if [[ "${#SWIFT_FILTERS[@]}" -gt 0 ]]; then
	for filter in "${SWIFT_FILTERS[@]}"; do
		[[ -n "$filter" ]] && swift_test_cmd+=(--filter "${filter##*/}")
	done
fi

set +e
"${swift_test_cmd[@]}" 2>&1 | tee "$SWIFT_LOG"
swift_status=${PIPESTATUS[0]}
set -e

swift_test_count="$(
	awk '
    match($0, /Test run with [0-9]+ tests?/) {
      line = substr($0, RSTART, RLENGTH)
      sub("Test run with ", "", line)
      sub(" tests?", "", line)
      total = line
    }
    END {
      if (total == "") {
        print "0"
      } else {
        print total
      }
    }
  ' "$SWIFT_LOG"
)"

if [[ "$swift_test_count" == "0" ]]; then
	write_unit_summary failed swiftpm_zero_tests
	die "Invalid SwiftPM test run: total test count is 0."
fi
if [[ "$swift_status" != "0" ]]; then
	write_unit_summary failed swiftpm_failed
	die "swift test exited with non-zero status: $swift_status"
fi

swift_diagnostics="$(collect_build_log_diagnostics "$SWIFT_LOG")"
if [[ -n "$swift_diagnostics" ]]; then
	printf '%s\n' "$swift_diagnostics" >&2
	write_unit_summary failed swiftpm_diagnostics
	die "swift test log contains compiler/linker diagnostic markers."
fi

set +e
node --test --test-reporter=tap "$ROOT_DIR"/Tests/BrowserRuntimeTests/*.test.js 2>&1 | tee "$JAVASCRIPT_LOG"
javascript_status=${PIPESTATUS[0]}
set -e

javascript_test_count="$(
	awk '/^# tests [0-9]+$/ { total = $3 } END { print total + 0 }' "$JAVASCRIPT_LOG"
)"
if [[ "$javascript_test_count" == "0" ]]; then
	write_unit_summary failed javascript_zero_tests
	die "Invalid JavaScript test run: total test count is 0."
fi
if [[ "$javascript_status" != "0" ]]; then
	write_unit_summary failed javascript_tests_failed
	die "JavaScript tests exited with non-zero status: $javascript_status"
fi

set +e
(
	cd "$ROOT_DIR/Tools/VoidDisplayRelay"
	env GOPROXY="${GOPROXY:-https://proxy.golang.org|https://goproxy.cn|direct}" go test ./...
) 2>&1 | tee "$GO_LOG"
go_status=${PIPESTATUS[0]}
set -e

go_package_count="$(
	awk '/^(ok|\?)[[:space:]]/ { count += 1 } END { print count + 0 }' "$GO_LOG"
)"

if [[ "$go_status" != "0" ]]; then
	write_unit_summary failed go_test_failed
	die "go test exited with non-zero status: $go_status"
fi

write_unit_summary passed passed

info "Unit gate passed."
info "Swift tests: $swift_test_count"
info "JavaScript tests: $javascript_test_count"
info "Go packages: $go_package_count"
info "Summary: $SUMMARY_PATH"
info "Artifacts: $OUT_DIR"
