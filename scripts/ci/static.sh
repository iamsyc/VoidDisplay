#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

require_command actionlint jq shellcheck shfmt shasum swift swiftformat swiftlint rg xcrun

validate_runner_labels() {
	assert_no_match "Workflow uses a non-macOS, paid, or larger runner label." \
		'(runs-on|runs_on):[[:space:]]*(ubuntu-|windows-|macos-latest-large|.*-large)' .github/workflows .github/actions
}

validate_action_pinning() {
	local failures=()
	local line
	local file
	local line_number
	local value
	local action_ref

	while IFS= read -r line; do
		file="${line%%:*}"
		line="${line#*:}"
		line_number="${line%%:*}"
		value="${line#*:}"
		value="${value#*uses:}"
		value="${value%%#*}"
		value="$(printf '%s' "$value" | tr -d "'\"" | xargs)"

		[[ -n "$value" ]] || continue
		[[ "$value" == ./* ]] && continue
		[[ "$value" == docker://* ]] && continue

		action_ref="${value##*@}"
		if [[ ! "$value" =~ @ || ! "$action_ref" =~ ^[0-9a-f]{40}$ ]]; then
			failures+=("$file:$line_number uses unpinned action reference: $value")
		fi
	done < <(rg -n '^[[:space:]]*uses:[[:space:]]*[^[:space:]]+' .github/workflows .github/actions)

	if [[ "${#failures[@]}" -gt 0 ]]; then
		printf '%s\n' "${failures[@]}" >&2
		die "All external GitHub Actions must be pinned to a 40-character commit SHA."
	fi
}

validate_shell_scripts() {
	local bash_scripts=()
	local zsh_scripts=()
	local script_path
	local first_line

	while IFS= read -r script_path; do
		[[ -f "$script_path" ]] || continue
		first_line="$(head -n 1 "$script_path" || true)"
		case "$first_line" in
		*zsh*) zsh_scripts+=("$script_path") ;;
		*bash* | *'/sh'* | *' sh') bash_scripts+=("$script_path") ;;
		*)
			case "$script_path" in
			*.sh) bash_scripts+=("$script_path") ;;
			esac
			;;
		esac
	done < <(find scripts -type f -not -name ".DS_Store" -print | sort)

	if [[ "${#bash_scripts[@]}" -gt 0 ]]; then
		shellcheck -x -e SC2016 "${bash_scripts[@]}"
		shfmt -d "${bash_scripts[@]}"
		bash -n "${bash_scripts[@]}"
	fi

	if [[ "${#zsh_scripts[@]}" -gt 0 ]]; then
		zsh -n "${zsh_scripts[@]}"
	fi
}

validate_script_contract() {
	local invalid

	assert_no_match "Scripts must use ROOT_DIR/TOOL_ROOT contract instead of SCRIPT_ROOT or SCRIPT_LIB_DIR." \
		'SCRIPT_ROOT=|SCRIPT_LIB_DIR=' scripts --glob '!scripts/ci/static.sh'

	invalid="$(
		rg -n 'source .*scripts/lib/(common|artifacts|xcode|xcresult|architecture|release|release_binaries)\.sh|source "\$[A-Z_]+/(common|artifacts|xcode|xcresult|architecture|release|release_binaries)\.sh' scripts --glob '!scripts/ci/static.sh' || true
	)"
	invalid="$(printf '%s\n' "$invalid" | rg -v 'source "\$TOOL_ROOT/scripts/lib/' || true)"
	fail_on_output "Helper source paths must use TOOL_ROOT." "$invalid"

	assert_no_match "Nested script calls must pass ROOT_DIR and TOOL_ROOT explicitly." \
		'ROOT_DIR="\$ROOT_DIR"(?!.*TOOL_ROOT=)|ROOT_DIR=\$\{ROOT_DIR:-' scripts --pcre2 --glob '!scripts/lib/contract.sh' --glob '!scripts/ci/static.sh'
}

fail_on_output() {
	local message="$1"
	local output="$2"

	if [[ -n "$output" ]]; then
		printf '%s\n' "$output" >&2
		die "$message"
	fi
}

assert_no_match() {
	local message="$1"
	shift

	fail_on_output "$message" "$(rg -n "$@" || true)"
}

assert_file_contains_all() {
	local file="$1"
	local message="$2"
	local required
	shift 2

	for required in "$@"; do
		rg -F "$required" "$file" >/dev/null || die "$message: $required"
	done
}

assert_paths_exist() {
	local message="$1"
	local path
	shift

	for path in "$@"; do
		[[ -e "$path" ]] || die "$message: $path"
	done
}

workflow_job_block() {
	local file="$1"
	local job="$2"

	awk -v job="$job" '
		$0 ~ "^[[:space:]]{2}" job ":" { inside = 1; print; next }
		inside && /^[[:space:]]{2}[[:alnum:]_-]+:/ { exit }
		inside { print }
	' "$file"
}

assert_job_contains() {
	local file="$1"
	local job="$2"
	local pattern="$3"
	local message="$4"
	local block

	block="$(workflow_job_block "$file" "$job")"
	[[ -n "$block" ]] || die "$message"
	if ! rg -n "$pattern" <<<"$block" >/dev/null; then
		die "$message"
	fi
}

assert_job_no_match() {
	local file="$1"
	local job="$2"
	local pattern="$3"
	local message="$4"
	local block

	block="$(workflow_job_block "$file" "$job")"
	[[ -n "$block" ]] || die "$message"
	fail_on_output "$message" "$(rg -n "$pattern" <<<"$block" || true)"
}

validate_workflow_script_contract() {
	local invalid
	local workflow_files=()
	local pr_ci_workflow_files=(
		.github/workflows/ci.yml
		.github/workflows/_reusable-unit-tests.yml
		.github/workflows/_reusable-ui-smoke-tests.yml
	)

	while IFS= read -r workflow_file; do
		workflow_files+=("$workflow_file")
	done < <(find .github/workflows .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort)

	assert_no_match "Trusted/base CI script model must be removed." \
		'\.ai-tmp/trusted-ci|head-script-self-test|requires_head_script_self_test|trusted_files|test_trusted_files|Checkout trusted' \
		.github/workflows .github/actions scripts --glob '!scripts/ci/static.sh'
	assert_no_match "Workflow script invocations must execute scripts through TOOL_ROOT." \
		'\$GITHUB_WORKSPACE/scripts/' .github/workflows .github/actions

	invalid="$(
		awk '
			/scripts\// {
				if ($0 ~ /^[[:space:]]*- '\''scripts\//) {
					next
				}
				if ($0 ~ /"\$tool_root\/scripts\//) {
					next
				}
				print FILENAME ":" FNR ":" $0
			}
		' "${workflow_files[@]}" || true
	)"
	fail_on_output "Workflow script references must be path filters or TOOL_ROOT executions." "$invalid"

	invalid="$(rg -n 'ROOT_DIR=.*scripts/' .github/workflows .github/actions | rg -v 'TOOL_ROOT=.*"\$tool_root/scripts/' || true)"
	fail_on_output "Workflow script invocations must pass ROOT_DIR and TOOL_ROOT and execute through TOOL_ROOT." "$invalid"
	assert_no_match "PR CI workflows must not expose GITHUB_TOKEN to checked-out repository scripts." \
		'GITHUB_TOKEN:[[:space:]]*\$\{\{[[:space:]]*github\.token[[:space:]]*\}\}' "${pr_ci_workflow_files[@]}"

	invalid="$(
		awk '
			function finish_checkout() {
				if (in_checkout && !saw_persist_credentials) {
					print current_file ":" checkout_line ":actions/checkout must set persist-credentials: false"
				}
			}
			FNR == 1 {
				finish_checkout()
				current_file = FILENAME
				in_checkout = 0
				saw_persist_credentials = 0
				checkout_line = 0
			}
			/^[[:space:]]*-[[:space:]]+name:/ {
				finish_checkout()
				in_checkout = 0
				saw_persist_credentials = 0
				checkout_line = 0
			}
			/uses:[[:space:]]*actions\/checkout@/ {
				in_checkout = 1
				saw_persist_credentials = 0
				checkout_line = FNR
			}
			in_checkout && /persist-credentials:[[:space:]]*false/ {
				saw_persist_credentials = 1
			}
			END {
				finish_checkout()
			}
		' "${pr_ci_workflow_files[@]}" || true
	)"
	fail_on_output "PR CI checkouts must disable persisted credentials." "$invalid"
	assert_no_match "Release smoke must stay split into arm64 and intel64 jobs." \
		'^[[:space:]]{2}release_build_check:' .github/workflows/ci.yml

	assert_job_contains .github/workflows/ci.yml release_build_check_arm64 \
		'if:.*requires_release_smoke.*true' \
		"arm64 release smoke must run whenever release smoke is required"
	assert_job_contains .github/workflows/ci.yml release_build_check_intel64 \
		'if:.*github\.event_name.*push.*requires_release_smoke.*true' \
		"intel64 release smoke must be push-only"

	assert_job_no_match .github/workflows/release.yml require_ci_gate \
		'actions\/checkout@|scripts\/release\/require_ci_gate\.sh|scripts\/dev\/bootstrap\.sh|prepare_release|needs\.prepare_release' \
		"Release ci-gate verification must stay workflow-owned and must not execute target checkout scripts."
	assert_job_no_match .github/workflows/release.yml resolve_release_target \
		'actions\/checkout@|scripts\/' \
		"resolve-release-target must not checkout or execute repository scripts"
	assert_job_contains .github/workflows/release.yml prepare_release \
		'^[[:space:]]*-[[:space:]]*require_ci_gate[[:space:]]*$' \
		"prepare-release must depend on require-ci-gate"
	assert_job_contains .github/workflows/release.yml prepare_release \
		'ref:[[:space:]]*\$\{\{[[:space:]]*needs\.resolve_release_target\.outputs\.target_sha[[:space:]]*\}\}' \
		"prepare-release must checkout the resolved target SHA"
}

validate_xcode_shell_build_phase() {
	local project_file="Apps/VoidDisplay/VoidDisplay.xcodeproj/project.pbxproj"
	local shell_phase_count
	local invalid_inputs
	local root_setting_count
	local tool_setting_count

	extract_pbx_array_values() {
		local key="$1"
		awk -v key="$key" '
			$0 ~ "^[[:space:]]*" key " = \\(" { inside = 1; next }
			inside && /^[[:space:]]*\);/ { inside = 0; next }
			inside {
				line = $0
				sub(/^[[:space:]]*"/, "", line)
				sub(/",[[:space:]]*$/, "", line)
				print line
			}
		' "$project_file"
	}

	assert_pbx_array_exact() {
		local key="$1"
		local label="$2"
		shift 2

		if ! diff -u <(printf '%s\n' "$@") <(extract_pbx_array_values "$key") >&2; then
			die "$label is not frozen to the expected values."
		fi
	}

	shell_phase_count="$(awk '/isa = PBXShellScriptBuildPhase;/{count += 1} END{print count + 0}' "$project_file")"
	[[ "$shell_phase_count" == "1" ]] || die "Xcode project must contain exactly one shell build phase."

	assert_file_contains_all "$project_file" "Build Relay phase is missing required line" \
		'name = "Build Relay";' \
		'shellPath = /bin/bash;' \
		'"cd \"$SRCROOT/../..\"",'

	assert_file_contains_all "$project_file" "Build Relay phase is missing required tool input or build setting" \
		'"$(TOOL_ROOT)/scripts/build-relay.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/contract.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/common.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/architecture.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/release_binaries.sh",'

	root_setting_count="$(rg -F 'ROOT_DIR = "$(SRCROOT)/../..";' "$project_file" | wc -l | tr -d '[:space:]')"
	tool_setting_count="$(rg -F 'TOOL_ROOT = "$(ROOT_DIR)";' "$project_file" | wc -l | tr -d '[:space:]')"
	[[ "$root_setting_count" == "2" ]] || die "ROOT_DIR build setting must be present in Debug and Release."
	[[ "$tool_setting_count" == "2" ]] || die "TOOL_ROOT build setting must be present in Debug and Release."

	assert_pbx_array_exact shellScript "Build Relay shellScript" \
		'cd \"$SRCROOT/../..\"' \
		'export ROOT_DIR=\"${ROOT_DIR:-$PWD}\"' \
		'export TOOL_ROOT=\"${TOOL_ROOT:-$ROOT_DIR}\"' \
		'\"$TOOL_ROOT/scripts/build-relay.sh\"' \
		''

	assert_pbx_array_exact outputPaths "Build Relay outputPaths" \
		'$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/voiddisplay-relay'

	invalid_inputs="$(
		extract_pbx_array_values inputPaths |
			rg -v '^\$\(TOOL_ROOT\)/scripts/(build-relay\.sh|lib/(contract|common|architecture|release_binaries)\.sh)$|^\$\(ROOT_DIR\)/Tools/VoidDisplayRelay/' || true
	)"
	fail_on_output "Build Relay input paths must stay under allowed prefixes." "$invalid_inputs"
}

validate_log_scanner() {
	local scanner="$1"
	local label="$2"
	local fixture_dir="$3"
	local positive_fixture

	for positive_fixture in "$fixture_dir"/positive-*.fixture; do
		if ("$scanner" "$label log fixture" "$positive_fixture" >/dev/null 2>&1); then
			die "$label log scanner missed fixture: $positive_fixture"
		fi
	done

	"$scanner" "$label negative log fixture" "$fixture_dir/negative-ordinary-text.fixture"
}

validate_xcode_log_scanner() {
	validate_log_scanner scan_xcode_log_for_diagnostics Xcode "$TOOL_ROOT/scripts/ci/fixtures/xcode-log-scanner"
}

validate_swiftpm_log_scanner() {
	validate_log_scanner scan_build_log_for_diagnostics SwiftPM "$TOOL_ROOT/scripts/ci/fixtures/swiftpm-log-scanner"
}

validate_classify_fixtures() {
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/test_classify.sh"
}

validate_webrtc_header_overlay() {
	local overlay_root="$ROOT_DIR/Vendor/WebRTCHeaders/M147"
	local include_dir="$overlay_root/include/WebRTC"
	local checksum_file="$overlay_root/SHA256SUMS"
	local forbidden_header
	local invalid
	local expected_paths
	local actual_paths
	local manifest_json

	if ! manifest_json="$(swift package dump-package 2>/dev/null)"; then
		die "Package.swift must be readable by SwiftPM."
	fi

	if ! jq -e \
		--arg url 'https://github.com/stasel/WebRTC/releases/download/147.0.0/WebRTC-M147.xcframework.zip' \
		--arg checksum '49f9b1713432c19f408e3218fc8526c7692fafca5869f7ec5f5991614276ed40' \
		'(
		  any(.targets[]; .name == "WebRTCBinary" and .type == "binary" and .url == $url and .checksum == $checksum) and
		  any(.targets[]; .name == "WebRTC" and .type == "regular" and .path == "Vendor/WebRTCHeaders/M147" and .publicHeadersPath == "include" and any(.dependencies[]?; .byName[0] == "WebRTCBinary")) and
		  any(.targets[]; .name == "VoidDisplaySharing" and any(.dependencies[]?; .byName[0] == "WebRTC")) and
		  ((.dependencies // []) | length == 0)
		)' \
		<<<"$manifest_json" >/dev/null; then
		die "Package.swift must use the local WebRTC M147 wrapper target and no remote source package dependencies."
	fi
	assert_no_match "Package.swift must use the local WebRTC wrapper target instead of the remote stasel package." \
		'https://github.com/stasel/WebRTC.git' "$ROOT_DIR/Package.swift"
	invalid="$(rg -n 'https://github.com/stasel/WebRTC.git|\"identity\"[[:space:]]*:[[:space:]]*\"webrtc\"' \
		"$ROOT_DIR/Package.resolved" \
		"$ROOT_DIR/Apps/VoidDisplay/VoidDisplay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
		"$ROOT_DIR/VoidDisplay.xcworkspace/xcshareddata/swiftpm/Package.resolved" || true)"
	fail_on_output "Package.resolved files must not retain stale stasel/WebRTC source pins." "$invalid"

	assert_paths_exist "WebRTC M147 header overlay is missing required file" \
		"$overlay_root/SOURCES.md" \
		"$checksum_file" \
		"$overlay_root/WebRTCHeaderOverlayAnchor.c" \
		"$include_dir/WebRTC.h" \
		"$include_dir/RTCMTLNSVideoView.h"

	assert_file_contains_all "$overlay_root/SOURCES.md" "WebRTC M147 SOURCES.md is missing required source detail" \
		'https://github.com/stasel/WebRTC/releases/download/147.0.0/WebRTC-M147.xcframework.zip' \
		'49f9b1713432c19f408e3218fc8526c7692fafca5869f7ec5f5991614276ed40' \
		'refs/branch-heads/7727' \
		'macos-x86_64_arm64/WebRTC.framework/Versions/A/Headers/WebRTC.h' \
		'RTCMTLNSVideoView.h'

	invalid="$(
		find "$overlay_root" -type f \
			! -path "$include_dir/*.h" \
			! -path "$overlay_root/SOURCES.md" \
			! -path "$overlay_root/SHA256SUMS" \
			! -path "$overlay_root/WebRTCHeaderOverlayAnchor.c" \
			-print
	)"
	fail_on_output "WebRTC M147 overlay may only contain headers, source metadata, checksums, and the anchor C file." "$invalid"

	assert_file_contains_all "$include_dir/RTCMTLNSVideoView.h" \
		"RTCMTLNSVideoView.h must import RTCVideoRenderer.h through the WebRTC framework path" \
		'#import <WebRTC/RTCVideoRenderer.h>'

	for forbidden_header in RTCEAGLVideoView.h RTCCameraPreviewView.h UIDevice+RTCDevice.h; do
		[[ ! -e "$include_dir/$forbidden_header" ]] || die "WebRTC M147 overlay must not include iOS-only header: $forbidden_header"
	done

	assert_no_match "WebRTC M147 overlay must not use WebRTC-local quoted imports." \
		'^[[:space:]]*#(import|include)[[:space:]]+"[^"]+"' "$include_dir"

	invalid="$(
		while IFS=: read -r file line_number import_path; do
			[[ -n "$import_path" ]] || continue
			import_path="${import_path#<WebRTC/}"
			import_path="${import_path%>}"
			[[ -f "$include_dir/$import_path" ]] || printf '%s:%s missing <%s>\n' "$file" "$line_number" "WebRTC/$import_path"
		done < <(rg -n -o '<WebRTC/[^>]+>' "$include_dir" || true)
	)"
	fail_on_output "WebRTC M147 overlay has unresolved recursive WebRTC imports." "$invalid"

	invalid="$(
		awk '
			FNR == 1 {
				depth = 0
				iphone_guard_depth = 0
			}
			/^[[:space:]]*#[[:space:]]*if/ {
				depth += 1
				if ($0 ~ /TARGET_OS_IPHONE/) {
					iphone_guard_depth = depth
				}
			}
			/UIKit/ && iphone_guard_depth == 0 {
				print FILENAME ":" FNR ":" $0
			}
			/^[[:space:]]*#[[:space:]]*endif/ {
				if (iphone_guard_depth == depth) {
					iphone_guard_depth = 0
				}
				if (depth > 0) {
					depth -= 1
				}
			}
		' "$include_dir"/*.h
	)"
	fail_on_output "WebRTC M147 overlay may only reference UIKit inside TARGET_OS_IPHONE guards." "$invalid"

	if ! (cd "$overlay_root" && shasum -a 256 -c SHA256SUMS >/dev/null); then
		(cd "$overlay_root" && shasum -a 256 -c SHA256SUMS) >&2 || true
		die "WebRTC M147 overlay checksums do not match."
	fi

	expected_paths="$(awk '{ print $2 }' "$checksum_file" | sort)"
	actual_paths="$(cd "$overlay_root" && find include/WebRTC -type f -name '*.h' -print | sort)"
	if ! diff -u <(printf '%s\n' "$expected_paths") <(printf '%s\n' "$actual_paths") >&2; then
		die "WebRTC M147 overlay SHA256SUMS must cover every header and only headers."
	fi
}

validate_swift_style() {
	swiftformat --lint --config "$ROOT_DIR/.swiftformat" Sources Tests UITests Apps Package.swift scripts/release/render_dmg_background.swift
	swiftlint lint --config "$ROOT_DIR/.swiftlint.yml" --quiet
}

validate_swift_scripts() {
	xcrun swiftc -typecheck "$ROOT_DIR/scripts/release/render_dmg_background.swift"
}

validate_create_dmg_failure_summary() {
	local out_dir
	local summary_path
	local missing_app_path

	out_dir="$AI_TMP_DIR/static-dmg-summary/$(timestamp)"
	summary_path="$out_dir/create-dmg-summary.json"
	missing_app_path="$out_dir/Missing.app"
	mkdir -p "$out_dir"

	if env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/release/create_dmg.sh" \
		--summary "$summary_path" \
		"$missing_app_path" \
		"$out_dir/Missing.dmg" \
		"VoidDisplay" >/dev/null 2>&1; then
		die "create_dmg missing-app fixture unexpectedly passed."
	fi
	jq -e '.status == "failed" and .reason == "missing_app" and .stage == "argument_validation"' "$summary_path" >/dev/null ||
		die "create_dmg missing-app fixture did not write the expected summary."
}

actionlint
validate_runner_labels
validate_action_pinning
validate_shell_scripts
validate_script_contract
validate_workflow_script_contract
validate_xcode_shell_build_phase
validate_xcode_log_scanner
validate_swiftpm_log_scanner
validate_classify_fixtures
validate_webrtc_header_overlay
validate_swift_style
validate_swift_scripts
validate_create_dmg_failure_summary

info "Static gate passed."
