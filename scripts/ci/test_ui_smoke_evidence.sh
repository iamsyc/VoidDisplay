#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

require_command git jq mktemp shasum
mkdir -p "$AI_TMP_DIR"
fixture_root="$(mktemp -d "$AI_TMP_DIR/ui-smoke-evidence.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

real_tool_root="$TOOL_ROOT"
fixture_repository="$fixture_root/repository"
fixture_tool_root="$fixture_repository"
fixture_bin="$fixture_root/bin"
fixture_counts="$fixture_root/counts"
fixture_evidence="$fixture_root/evidence"
mkdir -p "$fixture_repository/scripts/lib" "$fixture_repository/scripts/ci" "$fixture_bin" "$fixture_counts"

git -C "$fixture_repository" init -q
git -C "$fixture_repository" config user.email ui-smoke-fixture@example.invalid
git -C "$fixture_repository" config user.name ui-smoke-fixture
printf 'initial\n' >"$fixture_repository/tracked.txt"
git -C "$fixture_repository" add tracked.txt
git -C "$fixture_repository" commit -qm initial

for helper_name in common artifacts checkpoint; do
	cp "$real_tool_root/scripts/lib/$helper_name.sh" "$fixture_tool_root/scripts/lib/$helper_name.sh"
done
cp "$real_tool_root/scripts/lib/"{source_fingerprint,ui_test_report}.mjs "$fixture_tool_root/scripts/lib/"

printf '%s\n' \
	'#!/usr/bin/env bash' \
	'xcode_destination_for_arch() { printf '\''platform=macOS,arch=%s\n'\'' "$1"; }' \
	>"$fixture_tool_root/scripts/lib/architecture.sh"
cp "$real_tool_root/scripts/lib/xcode.sh" "$fixture_tool_root/scripts/lib/xcode.sh"
printf '%s\n' \
	'select_required_xcode() { :; }' \
	'xcode_test_products_exist() { [[ -f "$1/fixture-products-valid" && "$(cat "$1/fixture-products-valid")" == "$4" ]]; }' \
	>>"$fixture_tool_root/scripts/lib/xcode.sh"
cp "$real_tool_root/scripts/lib/xcresult.sh" "$fixture_tool_root/scripts/lib/xcresult.sh"

cat >"$fixture_tool_root/scripts/ci/xcode.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
action=""; derived_data=""; out_dir=""; selectors=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) action="$2"; shift 2 ;;
    --derived-data-path) derived_data="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --only-testing) selectors+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done
bump() { local path="$UI_FIXTURE_COUNTS/$1" count=0; [[ ! -f "$path" ]] || count="$(<"$path")"; printf '%s\n' "$((count + 1))" >"$path"; }
mkdir -p "$out_dir"
if [[ "$action" == "build-for-testing" ]]; then
  bump build.count
  if [[ "${UI_FIXTURE_BUILD_FAILURE:-false}" == "true" ]]; then
    printf 'fixture compilation failed\n' >"$out_dir/build.log"
    jq -n --arg log "$out_dir/build.log" '{status:"failed", reason:"xcodebuild_failed", log_path:$log}' >"$out_dir/xcode-summary.json"
    exit 65
  fi
  if [[ -n "${UI_FIXTURE_BUILD_STARTED:-}" ]]; then : >"$UI_FIXTURE_BUILD_STARTED"; while [[ ! -e "$UI_FIXTURE_BUILD_RELEASE" ]]; do sleep 0.02; done; fi
  mkdir -p "$derived_data"; node "$TOOL_ROOT/scripts/lib/source_fingerprint.mjs" "$ROOT_DIR" xcode >"$derived_data/fixture-products-valid"
  exit 0
fi
if [[ "${UI_FIXTURE_PREFLIGHT_FAILURE:-false}" == "true" ]]; then
  jq -n '{status:"failed",reason:"ui_session_acquire_failed",log_path:"",result_bundle:""}' >"$out_dir/xcode-summary.json"
  exit 1
fi
bump test.count
if [[ "${UI_FIXTURE_RETRY_ONCE:-false}" == "true" && "$(cat "$UI_FIXTURE_COUNTS/test.count")" == "1" ]]; then
  log="$out_dir/test.log"
  printf '    t = 0.01s Launch com.developerchen.voiddisplay\nEarly unexpected exit, operation never finished bootstrapping\n' >"$log"
  jq -n --arg log "$log" '{status:"failed",reason:"xcodebuild_failed",log_path:$log,result_bundle:""}' >"$out_dir/xcode-summary.json"
  exit 65
fi
if [[ -n "${UI_FIXTURE_STARTED:-}" ]]; then : >"$UI_FIXTURE_STARTED"; while [[ ! -e "$UI_FIXTURE_RELEASE" ]]; do sleep 0.02; done; fi
result="$out_dir/Result.xcresult"; mkdir -p "$result"
count=1; [[ "${selectors[0]}" != "VoidDisplayUITests" ]] || count=12
jq -n --argjson count "$count" '{result:"Passed", totalTestCount:$count, passedTests:$count, skippedTests:0, failedTests:0}' >"$result/summary.json"
jq -n --arg selector "${selectors[0]}" '{testNodes:[{nodeIdentifierURL:"test://com.apple.xcode/VoidDisplay/VoidDisplayUITests"}, {nodeIdentifierURL:("test://com.apple.xcode/VoidDisplay/" + $selector),nodeType:"Test Case",result:"Passed",durationInSeconds:2}]}' >"$result/tests.json"
log="$out_dir/xcode-test-without-building-Debug.log"; printf '    t = 0.01s Launch com.developerchen.voiddisplay\npassed\n' >"$log"
jq -n --arg result "$result" --arg log "$log" --argjson count "$count" --argjson selectors "$(printf '%s\n' "${selectors[@]}" | jq -R . | jq -s .)" '{status:"passed", reason:"passed", log_path:$log, result_bundle:$result, only_testing:$selectors, total_tests:$count, passed_tests:$count, skipped_tests:0, failed_tests:0}' >"$out_dir/xcode-summary.json"
STUB

cat >"$fixture_bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-version" ]]; then printf 'Xcode 26.6\nBuild version Fixture\n'; fi
STUB
cat >"$fixture_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
case "$4" in
  summary) cat "$6/summary.json" ;;
  tests) cat "$6/tests.json" ;;
  *) exit 1 ;;
esac
STUB
real_node="$(command -v node)"
cat >"$fixture_bin/node" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
"$UI_FIXTURE_REAL_NODE" "$@"
if [[ "$1" == */ui_test_report.mjs && "${2:-}" == "--combine" && -n "${UI_FIXTURE_REPORT_STARTED:-}" ]]; then
  : >"$UI_FIXTURE_REPORT_STARTED"
  while [[ ! -e "$UI_FIXTURE_REPORT_RELEASE" ]]; do sleep 0.02; done
fi
STUB
chmod +x "$fixture_tool_root/scripts/ci/xcode.sh" "$fixture_bin/xcodebuild" "$fixture_bin/xcrun" "$fixture_bin/node"
export UI_FIXTURE_REAL_NODE="$real_node"

run_ui() {
	local out_dir="$1"
	local evidence_root="${UI_RUN_EVIDENCE_ROOT:-$fixture_evidence}"
	local counts_root="${UI_RUN_COUNTS_ROOT:-$fixture_counts}"
	shift
	env \
		ROOT_DIR="$fixture_repository" \
		TOOL_ROOT="$fixture_tool_root" \
		AI_TMP_DIR="$fixture_root/ai-tmp" \
		UI_TEST_EVIDENCE_ROOT="$evidence_root" \
		UI_FIXTURE_COUNTS="$counts_root" \
		UI_FIXTURE_BUILD_FAILURE="${UI_FIXTURE_BUILD_FAILURE:-false}" \
		UI_FIXTURE_RETRY_ONCE="${UI_FIXTURE_RETRY_ONCE:-false}" \
		UI_FIXTURE_PREFLIGHT_FAILURE="${UI_FIXTURE_PREFLIGHT_FAILURE:-false}" \
		UI_FIXTURE_REPORT_STARTED="${UI_FIXTURE_REPORT_STARTED:-}" \
		UI_FIXTURE_REPORT_RELEASE="${UI_FIXTURE_REPORT_RELEASE:-}" \
		UI_FIXTURE_BUILD_STARTED="${UI_FIXTURE_BUILD_STARTED:-}" \
		UI_FIXTURE_BUILD_RELEASE="${UI_FIXTURE_BUILD_RELEASE:-}" \
		UI_FIXTURE_STARTED="${UI_FIXTURE_STARTED:-}" \
		UI_FIXTURE_RELEASE="${UI_FIXTURE_RELEASE:-}" \
		PATH="$fixture_bin:$PATH" \
		"$real_tool_root/scripts/ci/ui_smoke.sh" \
		--out-dir "$out_dir" \
		--destination "platform=macOS,arch=arm64" \
		--max-attempts 1 \
		"$@"
}

wait_for_path() {
	local path="$1"
	for _ in {1..100}; do
		[[ -e "$path" ]] && return 0
		sleep 0.02
	done
	die "Timed out waiting for fixture path: $path"
}

read_count() {
	local path="$1"
	local count
	if [[ -f "$path" ]]; then
		IFS= read -r count <"$path"
		printf '%s\n' "$count"
	else
		printf '0\n'
	fi
}

run_ui "$fixture_root/targeted-1" --only-testing VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney
run_ui "$fixture_root/targeted-2" --only-testing VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney
[[ "$(<"$fixture_counts/build.count")" == "1" ]] || die "Targeted UI run did not reuse its build."
[[ "$(<"$fixture_counts/test.count")" == "2" ]] || die "Targeted UI evidence was reused unexpectedly."
jq -e '.build_reused == true and .test_evidence_reused == false' "$fixture_root/targeted-2/ui-smoke-summary.json" >/dev/null

mkdir -p "$fixture_root/retry-counts"
UI_RUN_EVIDENCE_ROOT="$fixture_root/retry-evidence" UI_RUN_COUNTS_ROOT="$fixture_root/retry-counts" \
	UI_FIXTURE_RETRY_ONCE=true run_ui "$fixture_root/retry-report" --only-testing VoidDisplayUITests --max-attempts 2
jq -e '.attempts == 2 and .recorded_launches == 2 and .executed_launches == 2' \
	"$fixture_root/retry-report/ui-test-report.json" >/dev/null || die "Retry report lost bootstrap attempt cost."
UI_RUN_EVIDENCE_ROOT="$fixture_root/retry-evidence" UI_RUN_COUNTS_ROOT="$fixture_root/retry-counts" \
	run_ui "$fixture_root/retry-report-reused" --only-testing VoidDisplayUITests
jq -e '.attempts == 2 and .recorded_launches == 2 and .executed_launches == 0 and .evidence_reused == true' \
	"$fixture_root/retry-report-reused/ui-test-report.json" >/dev/null || die "Reused report lost retry history."

explicit_derived_data="$fixture_root/explicit-products/DerivedData"
mkdir -p "$explicit_derived_data"
node "$real_tool_root/scripts/lib/source_fingerprint.mjs" "$fixture_repository" xcode >"$explicit_derived_data/fixture-products-valid"
run_ui "$fixture_root/explicit-reuse" \
	--only-testing VoidDisplayUITests/HomeSmokeTests/testScreenRecordingRecoveryActionsFitAtNarrowWindowSize \
	--test-without-building \
	--derived-data-path "$explicit_derived_data"
[[ "$(<"$fixture_counts/build.count")" == "1" ]] || die "Explicit test products triggered a build."
[[ "$(<"$fixture_counts/test.count")" == "3" ]] || die "Explicit test products did not run the selector."
jq -e '.build_reused == true and .test_evidence_reused == false' \
	"$fixture_root/explicit-reuse/ui-smoke-summary.json" >/dev/null ||
	die "Explicit test product reuse was not reported."

run_ui "$fixture_root/full-1" --only-testing VoidDisplayUITests
run_ui "$fixture_root/full-2" --only-testing VoidDisplayUITests
[[ "$(<"$fixture_counts/test.count")" == "4" ]] || die "Completed full UI evidence was not reused."
jq -e '.test_evidence_reused == true' "$fixture_root/full-2/ui-smoke-summary.json" >/dev/null

printf 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG EXTERNAL\n' >"$fixture_root/external.xcconfig"
if XCODE_XCCONFIG_FILE="$fixture_root/external.xcconfig" \
	run_ui "$fixture_root/full-2" --only-testing VoidDisplayUITests >"$fixture_root/xcconfig.log" 2>&1; then
	die "Full UI reused successful evidence with an external xcconfig."
fi
jq -e '.status == "failed" and .reason == "build_input_rejected"' \
	"$fixture_root/full-2/ui-smoke-summary.json" >/dev/null ||
	die "External xcconfig rejection left stale UI success evidence."
[[ "$(<"$fixture_counts/build.count")" == "1" && "$(<"$fixture_counts/test.count")" == "4" ]] ||
	die "Rejected xcconfig started a build or test."
run_ui "$fixture_root/full-after-rejection" --only-testing VoidDisplayUITests
jq -e '.test_evidence_reused == true' "$fixture_root/full-after-rejection/ui-smoke-summary.json" >/dev/null ||
	die "External xcconfig rejection discarded valid evidence for the normal environment."

run_ui "$fixture_root/build-only" --build-only
[[ "$(<"$fixture_counts/test.count")" == "4" ]] || die "Build-only preflight executed UI tests."
[[ "$(<"$fixture_counts/build.count")" == "1" ]] || die "Build-only preflight ignored shared products."
printf 'documentation\n' >"$fixture_repository/README.md"
git -C "$fixture_repository" add README.md tracked.txt
git -C "$fixture_repository" commit -qm documentation
run_ui "$fixture_root/after-commit" --only-testing VoidDisplayUITests
[[ "$(<"$fixture_counts/test.count")" == "4" ]] || die "A documentation commit discarded full UI evidence."

run_ui "$fixture_root/full-rerun" --only-testing VoidDisplayUITests --rerun
[[ "$(<"$fixture_counts/test.count")" == "5" ]] || die "--rerun did not execute the full target."

printf 'changed\n' >"$fixture_repository/tracked.txt"
run_ui "$fixture_root/source-change" --only-testing VoidDisplayUITests
[[ "$(<"$fixture_counts/build.count")" == "2" ]] || die "Source change reused stale test products."
[[ "$(<"$fixture_counts/test.count")" == "6" ]] || die "Source change reused stale UI evidence."
[[ "$(jq -r .derived_data_path "$fixture_root/source-change/ui-smoke-summary.json")" == "$(jq -r .derived_data_path "$fixture_root/full-1/ui-smoke-summary.json")" ]] || die "Source edits discarded incremental build products."

while IFS= read -r evidence_file; do
	printf 'invalid\n' >"$evidence_file"
done < <(find "$fixture_evidence/results" -type f -name '*.json' -print)
run_ui "$fixture_root/corrupt" --only-testing VoidDisplayUITests
[[ "$(<"$fixture_counts/test.count")" == "7" ]] || die "Corrupt full UI evidence was reused."

run_ui "$fixture_root/rebuild" --only-testing VoidDisplayUITests --rebuild
[[ "$(<"$fixture_counts/build.count")" == "3" ]] || die "--rebuild did not rebuild test products."
[[ "$(<"$fixture_counts/test.count")" == "8" ]] || die "--rebuild did not rerun tests."

started="$fixture_root/duplicate.started"
release="$fixture_root/duplicate.release"
env UI_FIXTURE_STARTED="$started" UI_FIXTURE_RELEASE="$release" \
	ROOT_DIR="$fixture_repository" TOOL_ROOT="$fixture_tool_root" AI_TMP_DIR="$fixture_root/ai-tmp" \
	UI_TEST_EVIDENCE_ROOT="$fixture_evidence" UI_FIXTURE_COUNTS="$fixture_counts" PATH="$fixture_bin:$PATH" \
	"$real_tool_root/scripts/ci/ui_smoke.sh" --out-dir "$fixture_root/duplicate-holder" \
	--destination "platform=macOS,arch=arm64" --only-testing VoidDisplayUITests --rerun --max-attempts 1 &
holder_pid=$!
for _ in {1..100}; do
	[[ -e "$started" ]] && break
	sleep 0.02
done
[[ -e "$started" ]] || die "Duplicate-run fixture did not start."
if run_ui "$fixture_root/duplicate-contender" --only-testing VoidDisplayUITests --rerun >/dev/null 2>&1; then
	die "Duplicate source and selector run was accepted."
fi
: >"$release"
wait "$holder_pid"

concurrent_counts="$fixture_root/concurrent-counts"
concurrent_evidence="$fixture_root/concurrent-evidence"
mkdir -p "$concurrent_counts" "$concurrent_evidence"

cold_build_started="$fixture_root/cold-build.started"
cold_build_release="$fixture_root/cold-build.release"
cold_test_started="$fixture_root/cold-test.started"
cold_test_release="$fixture_root/cold-test.release"
UI_RUN_COUNTS_ROOT="$concurrent_counts" \
	UI_RUN_EVIDENCE_ROOT="$concurrent_evidence" \
	UI_FIXTURE_BUILD_STARTED="$cold_build_started" \
	UI_FIXTURE_BUILD_RELEASE="$cold_build_release" \
	UI_FIXTURE_STARTED="$cold_test_started" \
	UI_FIXTURE_RELEASE="$cold_test_release" \
	run_ui "$fixture_root/cold-holder" \
	--only-testing VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney --rerun &
cold_holder_pid=$!
wait_for_path "$cold_build_started"

UI_RUN_COUNTS_ROOT="$concurrent_counts" \
	UI_RUN_EVIDENCE_ROOT="$concurrent_evidence" \
	run_ui "$fixture_root/cold-contender" \
	--only-testing VoidDisplayUITests/HomeSmokeTests/testDisplayRescanJourney --rerun &
cold_contender_pid=$!
sleep 0.2
builds_during_cold_build="$(read_count "$concurrent_counts/build.count")"
: >"$cold_build_release"
wait_for_path "$cold_test_started"
sleep 0.2
tests_during_cold_holder="$(read_count "$concurrent_counts/test.count")"
: >"$cold_test_release"
wait "$cold_holder_pid"
wait "$cold_contender_pid"

[[ "$builds_during_cold_build" == "1" ]] ||
	die "Different selectors built the same cold test products concurrently."
[[ "$tests_during_cold_holder" == "1" ]] ||
	die "Different selectors bypassed the shared build lifecycle lock."
[[ "$(read_count "$concurrent_counts/build.count")" == "1" ]] ||
	die "Different selectors did not reuse the completed cold build."
[[ "$(read_count "$concurrent_counts/test.count")" == "2" ]] ||
	die "Different selectors did not both execute after serialization."

active_test_started="$fixture_root/active-test.started"
active_test_release="$fixture_root/active-test.release"
UI_RUN_COUNTS_ROOT="$concurrent_counts" \
	UI_RUN_EVIDENCE_ROOT="$concurrent_evidence" \
	UI_FIXTURE_STARTED="$active_test_started" \
	UI_FIXTURE_RELEASE="$active_test_release" \
	run_ui "$fixture_root/active-holder" \
	--only-testing VoidDisplayUITests/DiagnosticsSmokeTests/testDiagnosticsEvidenceJourney --rerun &
active_holder_pid=$!
wait_for_path "$active_test_started"

UI_RUN_COUNTS_ROOT="$concurrent_counts" \
	UI_RUN_EVIDENCE_ROOT="$concurrent_evidence" \
	run_ui "$fixture_root/rebuild-contender" \
	--only-testing VoidDisplayUITests/DiagnosticsSmokeTests/testDiagnosticsEmptyExportFocusesVisibleValidation \
	--rebuild &
rebuild_contender_pid=$!
sleep 0.2
builds_during_active_test="$(read_count "$concurrent_counts/build.count")"
: >"$active_test_release"
wait "$active_holder_pid"
wait "$rebuild_contender_pid"

[[ "$builds_during_active_test" == "1" ]] ||
	die "--rebuild modified shared test products while another selector was active."
[[ "$(read_count "$concurrent_counts/build.count")" == "2" ]] ||
	die "Serialized --rebuild did not rebuild exactly once."
[[ "$(read_count "$concurrent_counts/test.count")" == "4" ]] ||
	die "Serialized --rebuild did not preserve both selector executions."

regression_failures=0
check_regression() {
	local description="$1"
	shift
	if "$@"; then
		info "Regression passed: $description"
	else
		warn "Regression failed: $description"
		regression_failures=$((regression_failures + 1))
	fi
}

shared_out="$fixture_root/shared-output"
shared_evidence="$fixture_root/shared-evidence"
UI_RUN_EVIDENCE_ROOT="$shared_evidence" run_ui "$shared_out" --only-testing VoidDisplayUITests --rerun
full_bundle="$(jq -r '.result_bundle' "$shared_evidence"/results/*.json)"
UI_RUN_EVIDENCE_ROOT="$shared_evidence" run_ui "$shared_out" --only-testing VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney
UI_RUN_EVIDENCE_ROOT="$shared_evidence" run_ui "$shared_out" --only-testing VoidDisplayUITests
check_regression "targeted output must preserve the full result" \
	jq -e '.totalTestCount == 12' "$full_bundle/summary.json"
check_regression "preserved full evidence is reusable" \
	jq -e '.test_evidence_reused == true' "$shared_out/ui-smoke-summary.json"

# Pause after report generation while another selector uses the same output directory.
report_started="$fixture_root/report.started"
report_release="$fixture_root/report.release"
UI_RUN_EVIDENCE_ROOT="$shared_evidence" UI_FIXTURE_REPORT_STARTED="$report_started" \
	UI_FIXTURE_REPORT_RELEASE="$report_release" run_ui "$shared_out" \
	--only-testing VoidDisplayUITests --rerun >"$fixture_root/report-holder.log" 2>&1 &
report_holder_pid=$!
wait_for_path "$report_started"
UI_RUN_EVIDENCE_ROOT="$shared_evidence" run_ui "$shared_out" --build-only \
	>"$fixture_root/report-contender.log" 2>&1 &
report_contender_pid=$!
for _ in {1..200}; do
	if grep -q 'waiting up to' "$fixture_root/report-contender.log"; then break; fi
	sleep 0.02
done
check_regression "shared output contender reached its lock" grep -q 'waiting up to' "$fixture_root/report-contender.log"
: >"$report_release"
if wait "$report_holder_pid"; then report_holder_status=0; else report_holder_status=$?; fi
if wait "$report_contender_pid"; then report_contender_status=0; else report_contender_status=$?; fi
check_regression "concurrent build-only did not remove the full run report" test "$report_holder_status" -eq 0
check_regression "shared output build-only completed" test "$report_contender_status" -eq 0
UI_RUN_EVIDENCE_ROOT="$shared_evidence" run_ui "$fixture_root/report-reused" --only-testing VoidDisplayUITests
check_regression "concurrent full evidence remains reusable" \
	jq -e '.test_evidence_reused == true' "$fixture_root/report-reused/ui-smoke-summary.json"

preflight_out="$fixture_root/preflight-output"
run_ui "$preflight_out" --only-testing VoidDisplayUITests --rerun
tests_before_preflight="$(read_count "$fixture_counts/test.count")"
if UI_FIXTURE_PREFLIGHT_FAILURE=true run_ui "$preflight_out" --only-testing VoidDisplayUITests --rerun; then
	die "Preflight failure passed the UI gate."
fi
check_regression "preflight failure did not launch tests" test "$(read_count "$fixture_counts/test.count")" = "$tests_before_preflight"
check_regression "preflight failure did not republish previous test cost" \
	jq -e '.total_tests == 0 and .recorded_launches == null and .test_duration_seconds == null and .cases == []' \
	"$preflight_out/ui-test-report.json"

for enforce in true false; do
	failure_out="$fixture_root/build-failure-$enforce"
	run_ui "$failure_out" --only-testing VoidDisplayUITests --rerun
	[[ -s "$failure_out/ui-test-report.md" ]] || die "Successful UI fixture did not publish a report."
	if UI_FIXTURE_BUILD_FAILURE=true run_ui "$failure_out" \
		--only-testing VoidDisplayUITests --rebuild --enforce-failure "$enforce"; then
		failure_status=0
	else
		failure_status=$?
	fi
	check_regression "build failure has a failed aggregate summary ($enforce)" \
		jq -e '.status == "failed" and .reason == "xcodebuild_failed" and (.log_file | endswith("build.log"))' \
		"$failure_out/ui-smoke-summary.json"
	check_regression "build failure removes the previous invocation report ($enforce)" \
		test ! -e "$failure_out/ui-test-report.md"
	if [[ "$enforce" == "true" ]]; then
		check_regression "enforced build failure returns nonzero" test "$failure_status" -ne 0
	else
		check_regression "non-enforced build failure returns zero" test "$failure_status" -eq 0
	fi
done

# Hold a targeted run while the full --rebuild waits for its product lock.
# Changing the source must invalidate both the completed test and the waiter.
drift_evidence="$fixture_root/drift-evidence"
drift_started="$fixture_root/drift.started"
drift_release="$fixture_root/drift.release"
UI_RUN_EVIDENCE_ROOT="$drift_evidence" \
	UI_FIXTURE_STARTED="$drift_started" UI_FIXTURE_RELEASE="$drift_release" \
	run_ui "$fixture_root/drift-holder" \
	--only-testing VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney \
	>"$fixture_root/drift-holder.log" 2>&1 &
drift_holder_pid=$!
wait_for_path "$drift_started"
UI_RUN_EVIDENCE_ROOT="$drift_evidence" run_ui "$fixture_root/drift-waiter" \
	--only-testing VoidDisplayUITests --rebuild >"$fixture_root/drift-waiter.log" 2>&1 &
drift_waiter_pid=$!
for _ in {1..200}; do
	if grep -q 'waiting up to' "$fixture_root/drift-waiter.log"; then break; fi
	sleep 0.02
done
grep -q 'waiting up to' "$fixture_root/drift-waiter.log" || die "Source drift fixture did not acquire the test lock."
cp "$fixture_repository/tracked.txt" "$fixture_root/tracked-before-drift.txt"
printf 'changed during test and lock wait\n' >"$fixture_repository/tracked.txt"
: >"$drift_release"
if wait "$drift_holder_pid"; then drift_holder_status=0; else drift_holder_status=$?; fi
if wait "$drift_waiter_pid"; then drift_waiter_status=0; else drift_waiter_status=$?; fi
cp "$fixture_root/tracked-before-drift.txt" "$fixture_repository/tracked.txt"
check_regression "source drift during a test is rejected" test "$drift_holder_status" -ne 0
check_regression "source drift during lock wait is rejected" test "$drift_waiter_status" -ne 0
check_regression "source drift records its failure reason" \
	jq -e '.status == "failed" and .reason == "source_changed"' "$fixture_root/drift-waiter/ui-smoke-summary.json"
[[ "$regression_failures" -eq 0 ]] || die "$regression_failures UI smoke evidence regression(s) failed."
info "UI smoke evidence contract passed."
