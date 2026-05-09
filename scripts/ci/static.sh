#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

require_command actionlint jq shellcheck shfmt shasum swift swiftformat swiftlint rg xcrun

validate_runner_labels() {
	local invalid
	invalid="$(rg -n '(runs-on|runs_on):[[:space:]]*(ubuntu-|windows-|macos-latest-large|.*-large)' .github/workflows .github/actions || true)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "Workflow uses a non-macOS, paid, or larger runner label."
	fi
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

	invalid="$(rg -n 'SCRIPT_ROOT=|SCRIPT_LIB_DIR=' scripts --glob '!scripts/ci/static.sh' || true)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "Scripts must use ROOT_DIR/TOOL_ROOT contract instead of SCRIPT_ROOT or SCRIPT_LIB_DIR."
	fi

	invalid="$(
		rg -n 'source .*scripts/lib/(common|artifacts|xcode|xcresult|architecture|release_binaries)\.sh|source "\$[A-Z_]+/(common|artifacts|xcode|xcresult|architecture|release_binaries)\.sh' scripts --glob '!scripts/ci/static.sh' || true
	)"
	invalid="$(printf '%s\n' "$invalid" | rg -v 'source "\$TOOL_ROOT/scripts/lib/' || true)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "Helper source paths must use TOOL_ROOT."
	fi

	invalid="$(rg -n 'ROOT_DIR="\$ROOT_DIR"(?!.*TOOL_ROOT=)|ROOT_DIR=\$\{ROOT_DIR:-' scripts --pcre2 --glob '!scripts/lib/contract.sh' --glob '!scripts/ci/static.sh' || true)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "Nested script calls must pass ROOT_DIR and TOOL_ROOT explicitly."
	fi
}

validate_workflow_script_contract() {
	local invalid
	local workflow_files=()

	while IFS= read -r workflow_file; do
		workflow_files+=("$workflow_file")
	done < <(find .github/workflows .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort)

	invalid="$(rg -n 'inline_first_rollout|static-validated head scripts|inline_name_status_fallback|first rollout|steps\.ci_scripts|ci_scripts\.outputs|using head scripts' .github/workflows .github/actions scripts --glob '!scripts/ci/static.sh' || true)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "Seed fallback workflow paths must be removed."
	fi

	invalid="$(rg -n '\.ai-tmp/trusted-ci/scripts/' .github/workflows .github/actions scripts --glob '!scripts/ci/static.sh' || true)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "Trusted CI scripts must be invoked through an absolute TOOL_ROOT."
	fi

	invalid="$(rg -n '\$GITHUB_WORKSPACE/scripts/' .github/workflows .github/actions || true)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "Workflow script invocations must execute scripts through TOOL_ROOT."
	fi

	invalid="$(
		awk '
			/for required in[[:space:]]*\\/ {
				in_required = 1
				next
			}
			in_required && /^[[:space:]]*scripts\/[^[:space:]]+([[:space:]]*\\|; do)[[:space:]]*$/ {
				if ($0 ~ /; do[[:space:]]*$/) {
					in_required = 0
				}
				next
			}
			in_required && /; do[[:space:]]*$/ {
				in_required = 0
			}
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
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "Workflow script references must be path filters, trusted-script checks, or TOOL_ROOT executions."
	fi

	invalid="$(rg -n 'ROOT_DIR=.*scripts/' .github/workflows .github/actions | rg -v 'TOOL_ROOT=.*"\$tool_root/scripts/' || true)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "Workflow script invocations must pass ROOT_DIR and TOOL_ROOT and execute through TOOL_ROOT."
	fi
}

validate_xcode_shell_build_phase() {
	local project_file="Apps/VoidDisplay/VoidDisplay.xcodeproj/project.pbxproj"
	local shell_phase_count
	local invalid_inputs
	local required
	local root_setting_count
	local tool_setting_count
	local tool_build_input='$(TOOL_ROOT)/scripts/build-relay.sh'
	local tool_contract_input='$(TOOL_ROOT)/scripts/lib/contract.sh'
	local tool_common_input='$(TOOL_ROOT)/scripts/lib/common.sh'
	local tool_architecture_input='$(TOOL_ROOT)/scripts/lib/architecture.sh'
	local tool_release_binaries_input='$(TOOL_ROOT)/scripts/lib/release_binaries.sh'
	local root_relay_input_prefix='$(ROOT_DIR)/Tools/VoidDisplayRelay/'

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

	for required in \
		'name = "Build Relay";' \
		'shellPath = /bin/bash;' \
		'"cd \"$SRCROOT/../..\"",'; do
		if ! rg -F "$required" "$project_file" >/dev/null; then
			die "Build Relay phase is missing required line: $required"
		fi
	done

	for required in \
		'"$(TOOL_ROOT)/scripts/build-relay.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/contract.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/common.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/architecture.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/release_binaries.sh",'; do
		if ! rg -F "$required" "$project_file" >/dev/null; then
			die "Build Relay phase is missing required trusted tool input or build setting: $required"
		fi
	done

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
			while IFS= read -r input_path; do
				if [[ "$input_path" == "$tool_build_input" ||
					"$input_path" == "$tool_contract_input" ||
					"$input_path" == "$tool_common_input" ||
					"$input_path" == "$tool_architecture_input" ||
					"$input_path" == "$tool_release_binaries_input" ||
					"$input_path" == "$root_relay_input_prefix"* ]]; then
					continue
				fi
				printf '%s\n' "$input_path"
			done
	)"
	if [[ -n "$invalid_inputs" ]]; then
		printf '%s\n' "$invalid_inputs" >&2
		die "Build Relay input paths must stay under allowed prefixes."
	fi
}

validate_xcode_log_scanner() {
	local fixture_dir="$TOOL_ROOT/scripts/ci/fixtures/xcode-log-scanner"
	local positive_fixture

	for positive_fixture in "$fixture_dir"/positive-*.fixture; do
		if (scan_xcode_log_for_diagnostics "Xcode log fixture" "$positive_fixture" >/dev/null 2>&1); then
			die "Xcode log scanner missed fixture: $positive_fixture"
		fi
	done

	scan_xcode_log_for_diagnostics "Xcode negative log fixture" "$fixture_dir/negative-ordinary-text.fixture"
}

validate_swiftpm_log_scanner() {
	local fixture_dir="$TOOL_ROOT/scripts/ci/fixtures/swiftpm-log-scanner"
	local positive_fixture

	for positive_fixture in "$fixture_dir"/positive-*.fixture; do
		if (scan_build_log_for_diagnostics "SwiftPM log fixture" "$positive_fixture" >/dev/null 2>&1); then
			die "SwiftPM log scanner missed fixture: $positive_fixture"
		fi
	done

	scan_build_log_for_diagnostics "SwiftPM negative log fixture" "$fixture_dir/negative-ordinary-text.fixture"
}

validate_webrtc_header_overlay() {
	local overlay_root="$ROOT_DIR/Vendor/WebRTCHeaders/M147"
	local include_dir="$overlay_root/include/WebRTC"
	local checksum_file="$overlay_root/SHA256SUMS"
	local forbidden_header
	local invalid
	local expected_paths
	local actual_paths
	local required_source
	local manifest_json

	if ! manifest_json="$(swift package dump-package 2>/dev/null)"; then
		die "Package.swift must be readable by SwiftPM."
	fi

	if ! jq -e \
		--arg url 'https://github.com/stasel/WebRTC/releases/download/147.0.0/WebRTC-M147.xcframework.zip' \
		--arg checksum '49f9b1713432c19f408e3218fc8526c7692fafca5869f7ec5f5991614276ed40' \
		'.targets[] | select(.name == "WebRTCBinary" and .type == "binary" and .url == $url and .checksum == $checksum)' \
		<<<"$manifest_json" >/dev/null; then
		die "Package.swift must define WebRTCBinary from the stasel/WebRTC 147.0.0 asset."
	fi
	if ! jq -e \
		'.targets[] | select(.name == "WebRTC" and .type == "regular" and .path == "Vendor/WebRTCHeaders/M147" and .publicHeadersPath == "include" and any(.dependencies[]?; .byName[0] == "WebRTCBinary"))' \
		<<<"$manifest_json" >/dev/null; then
		die "Package.swift must expose the WebRTC M147 overlay through the local WebRTC target."
	fi
	if ! jq -e \
		'.targets[] | select(.name == "VoidDisplaySharing" and any(.dependencies[]?; .byName[0] == "WebRTC"))' \
		<<<"$manifest_json" >/dev/null; then
		die "VoidDisplaySharing must depend on the local WebRTC wrapper target."
	fi
	if ! jq -e '(.dependencies // []) | length == 0' <<<"$manifest_json" >/dev/null; then
		die "Package.swift must not retain remote source package dependencies."
	fi
	if rg -F 'https://github.com/stasel/WebRTC.git' "$ROOT_DIR/Package.swift" >/dev/null; then
		die "Package.swift must use the local WebRTC wrapper target instead of the remote stasel package."
	fi
	invalid="$(rg -n 'https://github.com/stasel/WebRTC.git|\"identity\"[[:space:]]*:[[:space:]]*\"webrtc\"' \
		"$ROOT_DIR/Package.resolved" \
		"$ROOT_DIR/Apps/VoidDisplay/VoidDisplay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
		"$ROOT_DIR/VoidDisplay.xcworkspace/xcshareddata/swiftpm/Package.resolved" || true)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "Package.resolved files must not retain stale stasel/WebRTC source pins."
	fi

	[[ -f "$overlay_root/SOURCES.md" ]] || die "WebRTC M147 header overlay must document sources."
	[[ -f "$checksum_file" ]] || die "WebRTC M147 header overlay must include SHA256SUMS."
	[[ -f "$overlay_root/WebRTCHeaderOverlayAnchor.c" ]] || die "WebRTC M147 header overlay target must include its anchor C file."
	[[ -f "$include_dir/WebRTC.h" ]] || die "WebRTC M147 header overlay must include WebRTC.h."
	[[ -f "$include_dir/RTCMTLNSVideoView.h" ]] || die "WebRTC M147 header overlay must include RTCMTLNSVideoView.h."

	for required_source in \
		'https://github.com/stasel/WebRTC/releases/download/147.0.0/WebRTC-M147.xcframework.zip' \
		'49f9b1713432c19f408e3218fc8526c7692fafca5869f7ec5f5991614276ed40' \
		'refs/branch-heads/7727' \
		'macos-x86_64_arm64/WebRTC.framework/Versions/A/Headers/WebRTC.h' \
		'RTCMTLNSVideoView.h'; do
		if ! rg -F "$required_source" "$overlay_root/SOURCES.md" >/dev/null; then
			die "WebRTC M147 SOURCES.md is missing required source detail: $required_source"
		fi
	done

	invalid="$(
		find "$overlay_root" -type f \
			! -path "$include_dir/*.h" \
			! -path "$overlay_root/SOURCES.md" \
			! -path "$overlay_root/SHA256SUMS" \
			! -path "$overlay_root/WebRTCHeaderOverlayAnchor.c" \
			-print
	)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "WebRTC M147 overlay may only contain headers, source metadata, checksums, and the anchor C file."
	fi

	if ! rg -F '#import <WebRTC/RTCVideoRenderer.h>' "$include_dir/RTCMTLNSVideoView.h" >/dev/null; then
		die "RTCMTLNSVideoView.h must import RTCVideoRenderer.h through the WebRTC framework path."
	fi

	for forbidden_header in RTCEAGLVideoView.h RTCCameraPreviewView.h UIDevice+RTCDevice.h; do
		[[ ! -e "$include_dir/$forbidden_header" ]] || die "WebRTC M147 overlay must not include iOS-only header: $forbidden_header"
	done

	invalid="$(rg -n '^[[:space:]]*#(import|include)[[:space:]]+"[^"]+"' "$include_dir" || true)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "WebRTC M147 overlay must not use WebRTC-local quoted imports."
	fi

	invalid="$(
		while IFS=: read -r file line_number import_path; do
			[[ -n "$import_path" ]] || continue
			import_path="${import_path#<WebRTC/}"
			import_path="${import_path%>}"
			[[ -f "$include_dir/$import_path" ]] || printf '%s:%s missing <%s>\n' "$file" "$line_number" "WebRTC/$import_path"
		done < <(rg -n -o '<WebRTC/[^>]+>' "$include_dir" || true)
	)"
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "WebRTC M147 overlay has unresolved recursive WebRTC imports."
	fi

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
	if [[ -n "$invalid" ]]; then
		printf '%s\n' "$invalid" >&2
		die "WebRTC M147 overlay may only reference UIKit inside TARGET_OS_IPHONE guards."
	fi

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
	local status

	out_dir="$AI_TMP_DIR/static-dmg-summary/$(timestamp)"
	summary_path="$out_dir/create-dmg-summary.json"
	missing_app_path="$out_dir/Missing.app"
	mkdir -p "$out_dir"

	set +e
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/release/create_dmg.sh" \
		--summary "$summary_path" \
		"$missing_app_path" \
		"$out_dir/Missing.dmg" \
		"VoidDisplay" >/dev/null 2>&1
	status="$?"
	set -e

	[[ "$status" -ne 0 ]] || die "create_dmg missing-app fixture unexpectedly passed."
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
validate_webrtc_header_overlay
validate_swift_style
validate_swift_scripts
validate_create_dmg_failure_summary

info "Static gate passed."
