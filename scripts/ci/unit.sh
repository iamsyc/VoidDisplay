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

require_command go jq
select_required_xcode

OUT_DIR="${OUT_DIR:-$(make_artifact_dir ci-unit)}"
SWIFT_LOG="${SWIFT_LOG:-$OUT_DIR/swift-test.log}"
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

total_tests="$(
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

if [[ "$total_tests" == "0" ]]; then
	write_json_file "$SUMMARY_PATH" \
		--arg status "failed" \
		--arg reason "swiftpm_zero_tests" \
		--argjson swift_test_count 0 \
		--argjson go_package_count 0 \
		--arg swift_log "$SWIFT_LOG" \
		--arg go_log "$GO_LOG" \
		'{status: $status, reason: $reason, swift_test_count: $swift_test_count, go_package_count: $go_package_count, swift_log: $swift_log, go_log: $go_log}'
	die "Invalid SwiftPM test run: total test count is 0."
fi
if [[ "$swift_status" != "0" ]]; then
	write_json_file "$SUMMARY_PATH" \
		--arg status "failed" \
		--arg reason "swiftpm_failed" \
		--argjson swift_test_count "$total_tests" \
		--argjson go_package_count 0 \
		--arg swift_log "$SWIFT_LOG" \
		--arg go_log "$GO_LOG" \
		'{status: $status, reason: $reason, swift_test_count: $swift_test_count, go_package_count: $go_package_count, swift_log: $swift_log, go_log: $go_log}'
	die "swift test exited with non-zero status: $swift_status"
fi

swift_diagnostics="$(collect_build_log_diagnostics "$SWIFT_LOG")"
if [[ -n "$swift_diagnostics" ]]; then
	printf '%s\n' "$swift_diagnostics" >&2
	write_json_file "$SUMMARY_PATH" \
		--arg status "failed" \
		--arg reason "swiftpm_diagnostics" \
		--argjson swift_test_count "$total_tests" \
		--argjson go_package_count 0 \
		--arg swift_log "$SWIFT_LOG" \
		--arg go_log "$GO_LOG" \
		'{status: $status, reason: $reason, swift_test_count: $swift_test_count, go_package_count: $go_package_count, swift_log: $swift_log, go_log: $go_log}'
	die "swift test log contains compiler/linker diagnostic markers."
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
	write_json_file "$SUMMARY_PATH" \
		--arg status "failed" \
		--arg reason "go_test_failed" \
		--argjson swift_test_count "$total_tests" \
		--argjson go_package_count "$go_package_count" \
		--arg swift_log "$SWIFT_LOG" \
		--arg go_log "$GO_LOG" \
		'{status: $status, reason: $reason, swift_test_count: $swift_test_count, go_package_count: $go_package_count, swift_log: $swift_log, go_log: $go_log}'
	die "go test exited with non-zero status: $go_status"
fi

write_json_file "$SUMMARY_PATH" \
	--arg status "passed" \
	--arg reason "passed" \
	--argjson swift_test_count "$total_tests" \
	--argjson go_package_count "$go_package_count" \
	--arg swift_log "$SWIFT_LOG" \
	--arg go_log "$GO_LOG" \
	'{status: $status, reason: $reason, swift_test_count: $swift_test_count, go_package_count: $go_package_count, swift_log: $swift_log, go_log: $go_log}'

info "Unit gate passed."
info "Swift tests: $total_tests"
info "Go packages: $go_package_count"
info "Summary: $SUMMARY_PATH"
info "Artifacts: $OUT_DIR"
