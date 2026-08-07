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

OUT_DIR="${OUT_DIR:-$(make_artifact_dir ci-stability)}"
ITERATIONS="${STABILITY_ITERATIONS:-20}"
SWIFT_FILTER="stability"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--iterations)
		ITERATIONS="$2"
		shift 2
		;;
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$ITERATIONS" -lt 1 ]] || [[ "$ITERATIONS" -gt 100 ]]; then
	die "--iterations must be an integer from 1 through 100."
fi

mkdir -p "$OUT_DIR/swift"
summary_path="$OUT_DIR/stability-summary.json"
go_log="$OUT_DIR/go-race.log"
rm -f -- "$summary_path" "$go_log"
while IFS= read -r -d '' stale_iteration_log; do
	rm -f -- "$stale_iteration_log"
done < <(/usr/bin/find "$OUT_DIR/swift" -type f -name 'iteration-*.log' -print0)

require_command awk go jq swift tee
select_required_xcode

swift_test_count=0

for iteration in $(seq 1 "$ITERATIONS"); do
	swift_log="$OUT_DIR/swift/iteration-$iteration.log"
	set +e
	swift test --filter "$SWIFT_FILTER" 2>&1 | tee "$swift_log"
	swift_status=${PIPESTATUS[0]}
	set -e

	iteration_test_count="$(
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
    ' "$swift_log"
	)"

	if [[ "$iteration_test_count" -eq 0 ]]; then
		die "Stability iteration $iteration ran zero Swift tests."
	fi
	if [[ "$swift_status" -ne 0 ]]; then
		die "Stability iteration $iteration failed with status $swift_status."
	fi
	scan_build_log_for_diagnostics "Stability iteration $iteration" "$swift_log"
	swift_test_count="$((swift_test_count + iteration_test_count))"
done

set +e
(
	cd "$ROOT_DIR/Tools/VoidDisplayRelay"
	env GOPROXY="${GOPROXY:-https://proxy.golang.org|https://goproxy.cn|direct}" \
		go test -race -count "$ITERATIONS" ./...
) 2>&1 | tee "$go_log"
go_status=${PIPESTATUS[0]}
set -e

if [[ "$go_status" -ne 0 ]]; then
	die "Relay race stability gate failed with status $go_status."
fi

go_package_count="$(awk '/^(ok|\?)[[:space:]]/ { count += 1 } END { print count + 0 }' "$go_log")"
if [[ "$go_package_count" -eq 0 ]]; then
	die "Relay race stability gate exercised zero Go packages."
fi

write_json_file "$summary_path" \
	--arg status "passed" \
	--argjson iterations "$ITERATIONS" \
	--argjson swift_test_count "$swift_test_count" \
	--argjson go_package_count "$go_package_count" \
	--arg go_log "$go_log" \
	'{status: $status, iterations: $iterations, swift_test_count: $swift_test_count, go_package_count: $go_package_count, go_log: $go_log}'

info "Stability gate passed."
info "Iterations: $ITERATIONS"
info "Swift test executions: $swift_test_count"
info "Go race packages: $go_package_count"
info "Summary: $summary_path"
