#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"
# shellcheck source=scripts/lib/xcode.sh
source "$TOOL_ROOT/scripts/lib/xcode.sh"
# shellcheck source=scripts/lib/xcresult.sh
source "$TOOL_ROOT/scripts/lib/xcresult.sh"

require_command jq mktemp
mkdir -p "$AI_TMP_DIR"
fixture_root="$(mktemp -d "$AI_TMP_DIR/reuse-evidence.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

derived_data="$fixture_root/DerivedData"
products_path="$derived_data/Build/Products"
mkdir -p "$products_path"
xctestrun_path="$products_path/VoidDisplay_macosx-arm64.xctestrun"
manifest_path="$(xcode_test_products_manifest_path "$derived_data")"
source_fingerprint="fixture-source"
xcode_identity="xcode-26.6-fixture"
root_dir="$fixture_root/source"
project="VoidDisplay.xcodeproj"
scheme="VoidDisplay"
configuration="Debug"
destination="platform=macOS,arch=arm64"
mkdir -p "$root_dir"
printf 'fixture xctestrun\n' >"$xctestrun_path"
write_json_file "$manifest_path" \
	--arg configuration "$configuration" \
	--arg destination "$destination" \
	--arg source_fingerprint "$source_fingerprint" \
	--arg xcode_identity "$xcode_identity" \
	--arg root_dir "$root_dir" \
	--arg project "$project" \
	--arg scheme "$scheme" \
	'{version: 1, configuration: $configuration, destination: $destination, source_fingerprint: $source_fingerprint, xcode_identity: $xcode_identity, root_dir: $root_dir, project: $project, scheme: $scheme}'

products_args=(
	"$derived_data"
	"$configuration"
	"$destination"
	"$source_fingerprint"
	"$xcode_identity"
	"$root_dir"
	"$project"
	"$scheme"
)
xcode_test_products_exist "${products_args[@]}" ||
	die "Xcode product probe rejected matching build provenance."
if xcode_test_products_exist \
	"$derived_data" Release "$destination" "$source_fingerprint" "$xcode_identity" "$root_dir" "$project" "$scheme"; then
	die "Xcode product probe accepted the wrong configuration."
fi
if xcode_test_products_exist \
	"$derived_data" "$configuration" "$destination" changed-source "$xcode_identity" "$root_dir" "$project" "$scheme"; then
	die "Xcode product probe accepted products from different source."
fi

rm -f "$manifest_path"
if (require_xcode_test_products "${products_args[@]}") >/dev/null 2>&1; then
	die "Required Xcode product check accepted missing provenance."
fi

fixture_bin="$fixture_root/bin"
result_bundle="$fixture_root/Result.xcresult"
mkdir -p "$fixture_bin" "$result_bundle"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'[[ "${XCRESULT_FIXTURE_MODE:-valid}" != "broken" ]] || exit 2' \
	'case " $* " in' \
	'*" get test-results summary "*) exec /bin/cat "$XCRESULT_FIXTURE_ROOT/${XCRESULT_FIXTURE_MODE:-valid}.json" ;;' \
	'*" get test-results tests "*) exec /bin/cat "$XCRESULT_FIXTURE_ROOT/tests.json" ;;' \
	'*) exit 2 ;;' \
	'esac' \
	>"$fixture_bin/xcrun"
chmod +x "$fixture_bin/xcrun"

jq -n '{result: "Passed", totalTestCount: 3, passedTests: 3, skippedTests: 0, failedTests: 0}' >"$fixture_root/valid.json"
jq -n '{result: "Passed", totalTestCount: 0, passedTests: 0, skippedTests: 0, failedTests: 0}' >"$fixture_root/zero.json"
jq -n '{result: "Failed", totalTestCount: 3, passedTests: 2, skippedTests: 0, failedTests: 1}' >"$fixture_root/failed.json"
jq -n '{result: "Passed", totalTestCount: 3, passedTests: 0, skippedTests: 3, failedTests: 0}' >"$fixture_root/all-skipped.json"
jq -n '{testNodes: [{nodeIdentifierURL: "test://com.apple.xcode/VoidDisplay/VoidDisplayUITests"}, {nodeIdentifierURL: "test://com.apple.xcode/VoidDisplay/VoidDisplayUITests/HomeSmokeTests"}, {nodeIdentifierURL: "test://com.apple.xcode/VoidDisplay/VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney"}]}' >"$fixture_root/tests.json"

valid_evidence="$(
	PATH="$fixture_bin:$PATH" XCRESULT_FIXTURE_ROOT="$fixture_root" XCRESULT_FIXTURE_MODE=valid \
		xcresult_test_evidence_json \
		"$result_bundle" \
		"VoidDisplayUITests" \
		"VoidDisplayUITests/HomeSmokeTests" \
		"VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney"
)" ||
	die "xcresult evidence probe rejected a passing result."
jq -e \
	'.result_status == "Passed"
	and .total_tests == 3
	and .passed_tests == 3
	and .skipped_tests == 0
	and .failed_tests == 0
	and .requested_selectors == [
		"VoidDisplayUITests",
		"VoidDisplayUITests/HomeSmokeTests",
		"VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney"
	]' \
	<<<"$valid_evidence" >/dev/null ||
	die "xcresult evidence probe returned unexpected normalized evidence."
if PATH="$fixture_bin:$PATH" XCRESULT_FIXTURE_ROOT="$fixture_root" XCRESULT_FIXTURE_MODE=zero \
	xcresult_test_evidence_valid "$result_bundle"; then
	die "xcresult evidence probe accepted zero tests."
fi
if PATH="$fixture_bin:$PATH" XCRESULT_FIXTURE_ROOT="$fixture_root" XCRESULT_FIXTURE_MODE=failed \
	xcresult_test_evidence_valid "$result_bundle"; then
	die "xcresult evidence probe accepted failed tests."
fi
if PATH="$fixture_bin:$PATH" XCRESULT_FIXTURE_ROOT="$fixture_root" XCRESULT_FIXTURE_MODE=all-skipped \
	xcresult_test_evidence_valid "$result_bundle"; then
	die "xcresult evidence probe accepted an all-skipped test run."
fi
if PATH="$fixture_bin:$PATH" XCRESULT_FIXTURE_ROOT="$fixture_root" XCRESULT_FIXTURE_MODE=broken \
	xcresult_test_evidence_valid "$result_bundle"; then
	die "xcresult evidence probe accepted unreadable test results."
fi
if PATH="$fixture_bin:$PATH" XCRESULT_FIXTURE_ROOT="$fixture_root" \
	xcresult_test_evidence_valid \
	"$result_bundle" \
	"VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney" \
	"VoidDisplayUITests/HomeSmokeTests/testSelectorThatDoesNotExist"; then
	die "xcresult selector probe accepted one valid selector plus one missing selector."
fi

info "Reusable Xcode evidence contract passed."
