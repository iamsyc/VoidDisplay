#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

require_command jq mktemp swift
mkdir -p "$AI_TMP_DIR"
fixture="$(mktemp -d "$AI_TMP_DIR/unit-filters.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts/lib" "$fixture/Tests/FilterTests"
for helper in common artifacts parallel; do
	cp "$TOOL_ROOT/scripts/lib/$helper.sh" "$fixture/scripts/lib/$helper.sh"
done
printf 'select_required_xcode() { :; }\n' >"$fixture/scripts/lib/xcode.sh"
cat >"$fixture/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FilterFixture", platforms: [.macOS("15.6")], targets: [.testTarget(name: "FilterTests")])
SWIFT
cat >"$fixture/Tests/FilterTests/FilterTests.swift" <<'SWIFT'
import Testing
struct RequestedSuite {
    @Test func sharedName() { #expect(true) }
    @Test func secondName() { #expect(true) }
}
struct UnrelatedSuite {
    @Test func sharedName() { Issue.record("The filter selected the wrong suite.") }
}
SWIFT

run_unit() {
	env ROOT_DIR="$fixture" TOOL_ROOT="$fixture" \
		"$TOOL_ROOT/scripts/ci/unit.sh" --swift-only --out-dir "$fixture/output" "$@"
}

for filter in 'RequestedSuite/sharedName' '(?:RequestedSuite)/sharedName'; do
	if ! run_unit --filter "$filter" >"$fixture/run.log" 2>&1; then
		cat "$fixture/run.log" "$fixture/output/swift-test.log"
		die "The unit gate did not preserve filter: $filter"
	fi
	jq -e '.status == "passed" and .swift_test_count == 1' "$fixture/output/unit-summary.json" >/dev/null
done

if run_unit --filter 'MissingSuite/sharedName' >"$fixture/run.log" 2>&1; then
	die "A filter with a missing suite ran a different suite."
fi
jq -e '.status == "failed" and .reason == "swiftpm_zero_tests" and .swift_test_count == 0' \
	"$fixture/output/unit-summary.json" >/dev/null

run_unit --filter 'RequestedSuite/sharedName' --filter 'RequestedSuite/secondName' >"$fixture/run.log" 2>&1
jq -e '.status == "passed" and .swift_test_count == 2' "$fixture/output/unit-summary.json" >/dev/null
info "Unit filter fixtures passed."
