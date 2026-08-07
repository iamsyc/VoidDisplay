#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

require_command git jq mktemp rg shasum
mkdir -p "$AI_TMP_DIR"
fixture_root="$(mktemp -d "$AI_TMP_DIR/checkpoint.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

real_tool_root="$TOOL_ROOT"
fixture_repository="$fixture_root/repository"
fixture_tool_root="$fixture_repository"
split_tool_root="$fixture_root/split-tool-root"
fixture_out="$fixture_root/out"
fixture_counts="$fixture_root/counts"
fixture_bin="$fixture_root/bin"
mkdir -p \
	"$fixture_repository" \
	"$fixture_tool_root/scripts/lib" \
	"$fixture_tool_root/scripts/ci" \
	"$split_tool_root" \
	"$fixture_counts" \
	"$fixture_bin"

git -C "$fixture_repository" init -q
git -C "$fixture_repository" config user.email checkpoint-fixture@example.invalid
git -C "$fixture_repository" config user.name checkpoint-fixture
printf 'initial\n' >"$fixture_repository/tracked.txt"
git -C "$fixture_repository" add tracked.txt
git -C "$fixture_repository" commit -qm initial

write_fixture_executable() {
	local executable_path="$1"
	shift

	printf '%s\n' "$@" >"$executable_path"
	chmod +x "$executable_path"
}

for helper_name in common artifacts parallel checkpoint ui_test_session; do
	ln -s "$real_tool_root/scripts/lib/$helper_name.sh" "$fixture_tool_root/scripts/lib/$helper_name.sh"
done
ln -s "$fixture_tool_root/scripts" "$split_tool_root/scripts"

declare -F require_repository_tool_root >/dev/null ||
	die "Repository tool-root guard is missing."
if (
	ROOT_DIR="$fixture_repository"
	TOOL_ROOT="$split_tool_root"
	require_repository_tool_root "Fixture resume"
) >/dev/null 2>&1; then
	die "Repository tool-root guard accepted a split tool root."
fi

write_fixture_executable "$fixture_tool_root/scripts/lib/architecture.sh" \
	'#!/usr/bin/env bash' \
	'xcode_destination_for_arch() { printf '\''platform=macOS,arch=%s\n'\'' "$1"; }'
write_fixture_executable "$fixture_tool_root/scripts/lib/xcode.sh" \
	'#!/usr/bin/env bash' \
	'select_required_xcode() { :; }' \
	'xcode_test_products_exist() { return 0; }'
write_fixture_executable "$fixture_tool_root/scripts/lib/xcresult.sh" \
	'#!/usr/bin/env bash' \
	'xcresult_test_evidence_valid() { return 0; }'
write_fixture_executable "$fixture_tool_root/scripts/lib/release_binaries.sh" \
	'#!/usr/bin/env bash' \
	'validate_release_app_binaries() { return 0; }'

command_runner="$fixture_tool_root/scripts/ci/command-runner.sh"
write_fixture_executable "$command_runner" \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'script_name="${0##*/}"' \
	'bump_count() {' \
	'  local count_path="$FULL_REGRESSION_FIXTURE_COUNTS/$1.count"' \
	'  local count=0' \
	'  [[ ! -f "$count_path" ]] || count="$(<"$count_path")"' \
	'  printf '\''%s\n'\'' "$((count + 1))" >"$count_path"' \
	'}' \
	'case "$script_name" in' \
	'  static.sh)' \
	'    bump_count static' \
	'    printf '\''[INFO] Static gate passed.\n'\''' \
	'    ;;' \
	'  unit.sh)' \
	'    bump_count unit' \
	'    out_dir=""' \
	'    while [[ $# -gt 0 ]]; do case "$1" in --out-dir) out_dir="$2"; shift 2 ;; *) shift ;; esac; done' \
	'    mkdir -p "$out_dir"' \
	'    for log_name in swift javascript go; do printf '\''passed\n'\'' >"$out_dir/$log_name.log"; done' \
	'    jq -n --arg swift_log "$out_dir/swift.log" --arg javascript_log "$out_dir/javascript.log" --arg go_log "$out_dir/go.log" '\''{status: "passed", swift_test_count: 1, javascript_test_count: 1, go_package_count: 1, swift_log: $swift_log, javascript_log: $javascript_log, go_log: $go_log}'\'' >"$out_dir/unit-summary.json"' \
	'    ;;' \
	'  xcode.sh)' \
	'    action=""; destination=""; derived_data=""; out_dir=""; selector=""' \
	'    while [[ $# -gt 0 ]]; do' \
	'      case "$1" in' \
	'        --action) action="$2"; shift 2 ;;' \
	'        --destination) destination="$2"; shift 2 ;;' \
	'        --derived-data-path) derived_data="$2"; shift 2 ;;' \
	'        --out-dir) out_dir="$2"; shift 2 ;;' \
	'        --only-testing) selector="$2"; shift 2 ;;' \
	'        *) shift ;;' \
	'      esac' \
	'    done' \
	'    mkdir -p "$out_dir"' \
	'    printf '\''passed\n'\'' >"$out_dir/xcode.log"' \
	'    if [[ "$action" == "build-for-testing" ]]; then' \
	'      bump_count preflight-xcode' \
	'      mkdir -p "$derived_data/Build/Products/Debug/VoidDisplay.app"' \
	'      jq -n --arg action "$action" --arg destination "$destination" --arg log_path "$out_dir/xcode.log" '\''{status: "passed", action: $action, destination: $destination, log_path: $log_path}'\'' >"$out_dir/xcode-summary.json"' \
	'    else' \
	'      bump_count ui' \
	'      mkdir -p "$out_dir/Result.xcresult"' \
	'      jq -n --arg destination "$destination" --arg selector "$selector" --arg result_bundle "$out_dir/Result.xcresult" '\''{status: "passed", action: "test-without-building", destination: $destination, only_testing: [$selector], result_status: "Passed", total_tests: 1, passed_tests: 1, skipped_tests: 0, failed_tests: 0, result_bundle: $result_bundle}'\'' >"$out_dir/xcode-summary.json"' \
	'    fi' \
	'    ;;' \
	'  stability.sh)' \
	'    bump_count stability' \
	'    if [[ ! -f "$FULL_REGRESSION_FIXTURE_COUNTS/postflight-failure-consumed" ]]; then' \
	'      : >"$FULL_REGRESSION_FIXTURE_COUNTS/postflight-failure-consumed"' \
	'      exit 9' \
	'    fi' \
	'    iterations=""; out_dir=""' \
	'    while [[ $# -gt 0 ]]; do case "$1" in --iterations) iterations="$2"; shift 2 ;; --out-dir) out_dir="$2"; shift 2 ;; *) shift ;; esac; done' \
	'    mkdir -p "$out_dir/swift"' \
	'    for ((iteration = 1; iteration <= iterations; iteration++)); do printf '\''passed\n'\'' >"$out_dir/swift/iteration-$iteration.log"; done' \
	'    printf '\''passed\n'\'' >"$out_dir/go.log"' \
	'    jq -n --argjson iterations "$iterations" --arg go_log "$out_dir/go.log" '\''{status: "passed", iterations: $iterations, swift_test_count: 1, go_package_count: 1, go_log: $go_log}'\'' >"$out_dir/stability-summary.json"' \
	'    ;;' \
	'esac'
for script_name in static.sh unit.sh xcode.sh stability.sh; do
	ln -s "$command_runner" "$fixture_tool_root/scripts/ci/$script_name"
done

tool_runner="$fixture_bin/tool-runner"
write_fixture_executable "$tool_runner" \
	'#!/usr/bin/env bash' \
	'case "${0##*/}" in' \
	'  xcodebuild) printf '\''Xcode 26.6\nBuild version Fixture\n'\'' ;;' \
	'  swift) printf '\''Swift version 6.3\n'\'' ;;' \
	'  go) printf '\''go version go1.fixture darwin/arm64\n'\'' ;;' \
	'  node) printf '\''vfixture\n'\'' ;;' \
	'  sw_vers) printf '\''15.6\n'\'' ;;' \
	'  *) exit 0 ;;' \
	'esac'
for command_name in xcodebuild swift go node sw_vers codesign lipo xcrun; do
	ln -s "$tool_runner" "$fixture_bin/$command_name"
done

run_env=(
	env
	ROOT_DIR="$fixture_repository"
	TOOL_ROOT="$fixture_tool_root"
	AI_TMP_DIR="$fixture_root/ai-tmp"
	FULL_REGRESSION_FIXTURE_COUNTS="$fixture_counts"
	STABILITY_ITERATIONS=1
	PATH="$fixture_bin:$PATH"
)
run_args=(
	--out-dir "$fixture_out"
	--destination "platform=macOS,arch=arm64"
	--skip-release-smoke
)
full_regression_script="$real_tool_root/scripts/ci/full_regression.sh"

if "${run_env[@]}" "$full_regression_script" "${run_args[@]}" >"$fixture_root/first.log" 2>&1; then
	die "Fixture expected postflight to fail after UI completed."
fi
jq -e \
	'.stages.preflight.status == "passed"
	and .stages.ui.status == "passed"
	and (.stages.postflight // null) == null' \
	"$fixture_out/full-regression-checkpoint.json" >/dev/null ||
	die "Postflight failure did not preserve completed preflight and UI markers."

"${run_env[@]}" "$full_regression_script" "${run_args[@]}" >"$fixture_root/resume.log" 2>&1 ||
	die "Fixture did not recover from the postflight failure."
[[ "$(<"$fixture_counts/ui.count")" == "1" ]] ||
	die "UI reran after only postflight failed."
jq -e '.status == "passed" and .resumed_stages == ["preflight", "ui"]' \
	"$fixture_out/full-regression-summary.json" >/dev/null ||
	die "Resume summary did not identify the reused preflight and UI stages."

printf 'changed\n' >"$fixture_repository/tracked.txt"
"${run_env[@]}" "$full_regression_script" "${run_args[@]}" >"$fixture_root/source-change.log" 2>&1 ||
	die "Fixture failed after a source change."
[[ "$(<"$fixture_counts/ui.count")" == "2" ]] ||
	die "Source change reused stale UI evidence."

"${run_env[@]}" "$full_regression_script" "${run_args[@]}" --restart >"$fixture_root/restart.log" 2>&1 ||
	die "Fixture restart failed."
[[ "$(<"$fixture_counts/ui.count")" == "3" ]] ||
	die "Restart did not discard completed stage markers."

printf 'invalid checkpoint\n' >"$fixture_out/full-regression-checkpoint.json"
"${run_env[@]}" "$full_regression_script" "${run_args[@]}" >"$fixture_root/corrupt.log" 2>&1 ||
	die "Fixture did not recover from a corrupt checkpoint."
[[ "$(<"$fixture_counts/ui.count")" == "4" ]] ||
	die "Corrupt checkpoint reused completed UI evidence."
jq -e '.stages.preflight.status == "passed" and .stages.ui.status == "passed" and .stages.postflight.status == "passed"' \
	"$fixture_out/full-regression-checkpoint.json" >/dev/null ||
	die "Checkpoint was not rebuilt after corruption."

info "Checkpoint contract passed."
