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

require_command git jq node swiftformat swiftlint xcrun rg awk diff wc tr

XCODE_PROJECT_DIR="VoidDisplay.xcodeproj"
XCODE_PROJECT_FILE="$XCODE_PROJECT_DIR/project.pbxproj"

fail_on_output() {
	local message="$1"
	local output="$2"

	if [[ -n "$output" ]]; then
		printf '%s\n' "$output" >&2
		die "$message"
	fi
}

assert_file_contains_all() {
	local file="$1"
	local message="$2"
	local required
	shift 2

	for required in "$@"; do
		rg -F -- "$required" "$file" >/dev/null || die "$message: $required"
	done
}

validate_xcode_project_layout() {
	local legacy_project_dir="Apps/VoidDisplay/""VoidDisplay.xcodeproj"
	local legacy_references
	local invalid_self_references

	[[ -d "$XCODE_PROJECT_DIR" ]] || die "Canonical Xcode project is missing: $XCODE_PROJECT_DIR"
	[[ -f "$XCODE_PROJECT_FILE" ]] || die "Canonical Xcode project file is missing: $XCODE_PROJECT_FILE"
	[[ ! -e "$legacy_project_dir" ]] || die "Xcode project must stay outside the synchronized app content directory."

	assert_file_contains_all "$XCODE_PROJECT_FILE" "Xcode synchronized roots do not match the repository layout" \
		'path = Apps/VoidDisplay;' \
		'path = UITests/VoidDisplayUITests;' \
		'path = Sources;' \
		'path = Tests;' \
		'relativePath = .;'

	invalid_self_references="$(
		rg -n '^[[:space:]]*(path = \.;|path = "?VoidDisplay\.xcodeproj"?;)' "$XCODE_PROJECT_FILE" || true
	)"
	fail_on_output \
		"Xcode project must not synchronize or reference its own project bundle." \
		"$invalid_self_references"

	legacy_references="$(git grep -n -F "$legacy_project_dir" -- . || true)"
	fail_on_output \
		"Repository still contains references to the former nested Xcode project path." \
		"$legacy_references"
}

validate_xcode_shell_build_phase() {
	local project_file="$XCODE_PROJECT_FILE"
	local -a expected_inputs=(
		'$(TOOL_ROOT)/mise.toml'
		'$(TOOL_ROOT)/mise.lock'
		'$(TOOL_ROOT)/scripts/build-relay.sh'
		'$(TOOL_ROOT)/scripts/lib/contract.sh'
		'$(TOOL_ROOT)/scripts/lib/common.sh'
		'$(TOOL_ROOT)/scripts/lib/architecture.sh'
		'$(TOOL_ROOT)/scripts/lib/release_binaries.sh'
	)
	local relay_file
	local relay_file_count=0
	local shell_phase_count
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
		'"cd \"$SRCROOT\"",'
	if rg -F 'alwaysOutOfDate = 1;' "$project_file" >/dev/null; then
		die "Build Relay must use declared input and output dependency analysis."
	fi

	while IFS= read -r relay_file; do
		expected_inputs+=('$(ROOT_DIR)/'"$relay_file")
		relay_file_count=$((relay_file_count + 1))
	done < <(
		{
			printf '%s\n' \
				Tools/VoidDisplayRelay/go.mod \
				Tools/VoidDisplayRelay/go.sum
			rg --files Tools/VoidDisplayRelay -g '*.go'
		} | LC_ALL=C sort -u
	)
	((relay_file_count > 0)) || die "Relay module has no tracked files to declare as Xcode build inputs."

	root_setting_count="$(rg -F 'ROOT_DIR = "$(SRCROOT)";' "$project_file" | wc -l | tr -d '[:space:]')"
	tool_setting_count="$(rg -F 'TOOL_ROOT = "$(ROOT_DIR)";' "$project_file" | wc -l | tr -d '[:space:]')"
	[[ "$root_setting_count" == "2" ]] || die "ROOT_DIR build setting must be present in Debug and Release."
	[[ "$tool_setting_count" == "2" ]] || die "TOOL_ROOT build setting must be present in Debug and Release."

	assert_pbx_array_exact shellScript "Build Relay shellScript" \
		'cd \"$SRCROOT\"' \
		'export ROOT_DIR=\"${ROOT_DIR:-$PWD}\"' \
		'export TOOL_ROOT=\"${TOOL_ROOT:-$ROOT_DIR}\"' \
		'\"$TOOL_ROOT/scripts/build-relay.sh\"' \
		''

	assert_pbx_array_exact outputPaths "Build Relay outputPaths" \
		'$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/voiddisplay-relay' \
		'$(DERIVED_FILE_DIR)/voiddisplay-relay-$(ARCHS).stamp'

	assert_pbx_array_exact inputPaths "Build Relay inputPaths" "${expected_inputs[@]}"
}

validate_release_smoke_pins_relay_go_binary() {
	local fixture_bin="$AI_TMP_DIR/release-go-resolution-fixture/bin"
	local fixture_go="$fixture_bin/go-real"
	local resolved_go

	assert_file_contains_all \
		"$TOOL_ROOT/scripts/ci/release_smoke.sh" \
		"Release smoke must resolve Go from trusted tool configuration before entering the Xcode script sandbox" \
		'GO_BIN="$(resolve_trusted_go_binary)"' \
		'GO_BIN="$GO_BIN"'
	assert_file_contains_all \
		"$TOOL_ROOT/scripts/lib/common.sh" \
		"Go module download must honor the resolved Go executable" \
		'mise -C "$TOOL_ROOT" which go' \
		'local go_bin="${GO_BIN:-go}"' \
		'"$go_bin" mod download'

	mkdir -p "$fixture_bin"
	printf '#!/usr/bin/env bash\n[[ "$1" == "-C" && "$2" == "$EXPECTED_TOOL_ROOT" && "$3" == "which" && "$4" == "go" ]] || exit 2\nprintf "%%s\\\\n" "$EXPECTED_GO_BIN"\n' \
		>"$fixture_bin/mise"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture_go"
	chmod +x "$fixture_bin/mise" "$fixture_go"

	resolved_go="$(
		PATH="$fixture_bin:$PATH" \
			EXPECTED_TOOL_ROOT="$TOOL_ROOT" \
			EXPECTED_GO_BIN="$fixture_go" \
			resolve_trusted_go_binary
	)"
	[[ "$resolved_go" == "$fixture_go" ]] ||
		die "Trusted Go resolution ignored the tool-root mise configuration."
}

validate_json_artifact_rejects_directory_target() {
	local fixture_root="$AI_TMP_DIR/json-artifact-directory-target"
	local directory_target="$fixture_root/summary.json"

	mkdir -p "$directory_target"
	if write_json_file "$directory_target" --arg status "passed" '{status: $status}' 2>/dev/null; then
		die "JSON artifact writer accepted a directory target."
	fi
}

validate_xcode_runner_signing_modes() {
	local runner="$TOOL_ROOT/scripts/ci/xcode.sh"
	local signed_runtime_builder="$TOOL_ROOT/scripts/dev/build_signed_runtime.sh"
	local runner_failure_fixture="$AI_TMP_DIR/xcode-runner-failure-summary"
	local runner_failure_bin="$runner_failure_fixture/bin"
	local builder_failure_fixture="$AI_TMP_DIR/signed-runtime-failure-summary"
	local broken_jq_bin="$AI_TMP_DIR/summary-broken-jq/bin"
	local runner_broken_jq_fixture="$AI_TMP_DIR/xcode-runner-broken-jq"
	local builder_broken_jq_fixture="$AI_TMP_DIR/signed-runtime-broken-jq"
	local runner_xcconfig_fixture="$AI_TMP_DIR/xcode-runner-xcconfig"
	local runner_xcconfig_bin="$runner_xcconfig_fixture/bin"
	local runner_xcconfig_sentinel="$runner_xcconfig_fixture/xcodebuild-started"
	local runner_failure_summary
	local builder_failure_summary
	local positive_metadata
	local positive_requirement
	local adhoc_metadata
	local missing_runtime_metadata
	local weakened_requirement

	assert_file_contains_all "$runner" "Xcode runner signing modes are incomplete" \
		'SIGNING_MODE="disabled"' \
		'--signing)' \
		'disabled | development)' \
		'"CODE_SIGNING_ALLOWED=NO"' \
		'"CODE_SIGNING_REQUIRED=NO"' \
		'"CODE_SIGNING_ALLOWED=YES"' \
		'"CODE_SIGNING_REQUIRED=YES"' \
		'"CODE_SIGN_STYLE=Manual"' \
		'DEVELOPMENT_IDENTIFIER=""' \
		'DEVELOPMENT_TEAM_IDENTIFIER=""' \
		'--development-identifier)' \
		'--development-team-identifier)' \
		'"CODE_SIGN_IDENTITY=Apple Development"' \
		'"ENABLE_HARDENED_RUNTIME=YES"' \
		'SUMMARY_FAILURE_REASON="build_log_write_failed"' \
		'write_failed_summary_on_exit' \
		'validate_development_project_path' \
		'development_signing_authority' \
		'verify_development_signed_app'
	assert_file_contains_all "$signed_runtime_builder" "Signed runtime builder must own project signing inputs" \
		'VOIDDISPLAY_DEVELOPMENT_IDENTIFIER' \
		'VOIDDISPLAY_DEVELOPMENT_TEAM_IDENTIFIER' \
		'--development-identifier "$DEVELOPMENT_IDENTIFIER"' \
		'--development-team-identifier "$DEVELOPMENT_TEAM_IDENTIFIER"' \
		'write_failed_summary_on_exit'
	if rg -n -F 'sunyuchen1990@gmail.com' "$runner" >/dev/null; then
		die "Generic Xcode runner must not pin a developer-specific certificate identity."
	fi

	mkdir -p "$runner_failure_bin" "$builder_failure_fixture"
	ln -sf "$(command -v jq)" "$runner_failure_bin/jq"
	printf '{"status":"passed","reason":"stale"}\n' >"$runner_failure_fixture/xcode-summary.json"
	if PATH="$runner_failure_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$runner" \
		--out-dir "$runner_failure_fixture" \
		--action unsupported >/dev/null 2>&1; then
		die "Xcode runner accepted an unsupported action."
	fi
	runner_failure_summary="$(jq -c . "$runner_failure_fixture/xcode-summary.json" 2>&1 || true)"
	jq -e '
		.status == "failed"
			and .reason == "argument_validation_failed"
	' "$runner_failure_fixture/xcode-summary.json" >/dev/null ||
		die "Xcode runner left invalid evidence after a failed reused-output run: $runner_failure_summary"

	printf '{"status":"passed","reason":"stale"}\n' >"$builder_failure_fixture/signed-runtime-summary.json"
	if "$signed_runtime_builder" \
		--out-dir "$builder_failure_fixture" \
		--unsupported >/dev/null 2>&1; then
		die "Signed runtime builder accepted an unsupported argument."
	fi
	builder_failure_summary="$(jq -c . "$builder_failure_fixture/signed-runtime-summary.json" 2>&1 || true)"
	jq -e '
		.status == "failed"
			and .reason == "argument_validation_failed"
	' "$builder_failure_fixture/signed-runtime-summary.json" >/dev/null ||
		die "Signed runtime builder left invalid evidence after a failed reused-output run: $builder_failure_summary"

	mkdir -p "$broken_jq_bin" "$runner_broken_jq_fixture" "$builder_broken_jq_fixture"
	printf '#!/bin/bash\nexit 42\n' >"$broken_jq_bin/jq"
	chmod +x "$broken_jq_bin/jq"
	printf '{"status":"passed","reason":"stale"}\n' >"$runner_broken_jq_fixture/xcode-summary.json"
	if PATH="$broken_jq_bin:$PATH" "$runner" --out-dir "$runner_broken_jq_fixture" >/dev/null 2>&1; then
		die "Xcode runner passed with a broken JSON writer."
	fi
	[[ ! -e "$runner_broken_jq_fixture/xcode-summary.json" ]] ||
		die "Xcode runner retained stale success evidence after its JSON writer failed."

	printf '{"status":"passed","reason":"stale"}\n' >"$builder_broken_jq_fixture/signed-runtime-summary.json"
	if PATH="$broken_jq_bin:$PATH" OUT_DIR="$builder_broken_jq_fixture" "$signed_runtime_builder" >/dev/null 2>&1; then
		die "Signed runtime builder passed with a broken JSON writer."
	fi
	[[ ! -e "$builder_broken_jq_fixture/signed-runtime-summary.json" ]] ||
		die "Signed runtime builder retained stale success evidence after its JSON writer failed."

	mkdir -p "$runner_xcconfig_bin"
	printf '%s\n' \
		'#!/bin/bash' \
		'if [[ "${1:-}" == "-version" ]]; then printf "Xcode 26.6\nBuild version TEST\n"; exit 0; fi' \
		': >"$XCODEBUILD_SENTINEL"' \
		'exit 97' >"$runner_xcconfig_bin/xcodebuild"
	printf '#!/bin/bash\nprintf "  1) TESTHASH \\"Apple Development: Developer (TEAM)\\"\n"\n' >"$runner_xcconfig_bin/security"
	ln -sf /usr/bin/true "$runner_xcconfig_bin/codesign"
	chmod +x "$runner_xcconfig_bin/xcodebuild" "$runner_xcconfig_bin/security"
	local signing_mode
	for signing_mode in disabled development; do
		if env \
			PATH="$runner_xcconfig_bin:$PATH" \
			DEVELOPER_DIR="$TOOL_ROOT" \
			XCODE_XCCONFIG_FILE="$runner_xcconfig_fixture/ambient.xcconfig" \
			XCODEBUILD_SENTINEL="$runner_xcconfig_sentinel" \
			"$runner" \
			--out-dir "$runner_xcconfig_fixture" \
			--signing "$signing_mode" \
			--development-identifier com.developerchen.voiddisplay \
			--development-team-identifier 6HCGZ4HUVA >/dev/null 2>&1; then
			die "Xcode runner accepted an ambient xcconfig."
		fi
		[[ ! -e "$runner_xcconfig_sentinel" ]] ||
			die "Xcode runner started a development build with an ambient xcconfig."
		jq -e '.status == "failed" and .reason == "build_input_rejected"' \
			"$runner_xcconfig_fixture/xcode-summary.json" >/dev/null ||
			die "Xcode runner did not record the rejected ambient xcconfig."
	done

	positive_metadata=$'Identifier=com.developerchen.voiddisplay\nCodeDirectory v=20500 size=457 flags=0x10000(runtime)\nSignature size=4798\nAuthority=Apple Development: Developer (TEAM)\nInfo.plist entries=26\nTeamIdentifier=6HCGZ4HUVA\nSealed Resources version=2 rules=13 files=20'
	positive_requirement='designated => identifier "com.developerchen.voiddisplay" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Developer (TEAM)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */'
	validate_development_signature_evidence \
		"$positive_metadata" \
		"$positive_requirement" \
		"com.developerchen.voiddisplay" \
		"6HCGZ4HUVA" \
		"Apple Development: Developer (TEAM)"

	missing_runtime_metadata="${positive_metadata/flags=0x10000(runtime)/flags=0x0(none)}"
	if (
		validate_development_signature_evidence \
			"$missing_runtime_metadata" \
			"$positive_requirement" \
			"com.developerchen.voiddisplay" \
			"6HCGZ4HUVA" \
			"Apple Development: Developer (TEAM)"
	) >/dev/null 2>&1; then
		die "Development signature validation accepted an app without Hardened Runtime."
	fi

	weakened_requirement="($positive_requirement) or anchor apple generic"
	if (
		validate_development_signature_evidence \
			"$positive_metadata" \
			"$weakened_requirement" \
			"com.developerchen.voiddisplay" \
			"6HCGZ4HUVA" \
			"Apple Development: Developer (TEAM)"
	) >/dev/null 2>&1; then
		die "Development signature validation accepted a weakened designated requirement."
	fi

	validate_development_project_path \
		"$TOOL_ROOT/VoidDisplay.xcodeproj" \
		"$TOOL_ROOT/VoidDisplay.xcodeproj"
	if (
		validate_development_project_path \
			"$TOOL_ROOT/scripts" \
			"$TOOL_ROOT/VoidDisplay.xcodeproj"
	) >/dev/null 2>&1; then
		die "Development project validation accepted a project outside the repository target."
	fi

	if (
		validate_development_signature_evidence \
			"$positive_metadata" \
			"$positive_requirement" \
			"com.developerchen.voiddisplay" \
			"6HCGZ4HUVA" \
			"Apple Development: Another Developer (TEAM)"
	) >/dev/null 2>&1; then
		die "Development signature validation accepted a different certificate authority."
	fi

	adhoc_metadata=$'Identifier=VoidDisplay\nCodeDirectory v=20400 size=420 flags=0x20002(adhoc,linker-signed)\nSignature=adhoc\nInfo.plist=not bound\nTeamIdentifier=not set\nSealed Resources=none'
	if (
		validate_development_signature_evidence \
			"$adhoc_metadata" \
			'designated => cdhash H"0000000000000000000000000000000000000000"' \
			"com.developerchen.voiddisplay" \
			"6HCGZ4HUVA" \
			"Apple Development: Developer (TEAM)"
	) >/dev/null 2>&1; then
		die "Development signature validation accepted an ad hoc application."
	fi
}

validate_permission_sensitive_acceptance_contract() {
	local workflow_references

	assert_file_contains_all \
		"$TOOL_ROOT/docs/testing/testing-strategy.md" \
		"Testing strategy must document permission-sensitive signed acceptance" \
		'scripts/dev/build_signed_runtime.sh' \
		'signed-runtime-summary.json' \
		'Xcode Personal Team' \
		'不进入 CI、Release 或公开分发'
	assert_file_contains_all \
		"$TOOL_ROOT/AGENTS.md" \
		"Agent policy must preserve permission-sensitive signed acceptance" \
		'scripts/dev/build_signed_runtime.sh' \
		'signed-runtime-summary.json' \
		'Xcode Personal Team' \
		'Do not substitute an unsigned or ad hoc build'
	assert_file_contains_all \
		"$TOOL_ROOT/README.md" \
		"English development guide must expose the signed acceptance entry point" \
		'scripts/dev/build_signed_runtime.sh' \
		'signed-runtime-summary.json' \
		'Xcode Personal Team'
	assert_file_contains_all \
		"$TOOL_ROOT/README.zh-CN.md" \
		"Chinese development guide must expose the signed acceptance entry point" \
		'scripts/dev/build_signed_runtime.sh' \
		'signed-runtime-summary.json' \
		'Xcode Personal Team'

	workflow_references="$(
		rg -n -F 'build_signed_runtime.sh' "$TOOL_ROOT/.github" || true
	)"
	fail_on_output \
		"Permission-sensitive signed acceptance must remain outside remote CI and Release workflows." \
		"$workflow_references"
}

validate_home_popover_uses_system_focus() {
	local source="$TOOL_ROOT/Sources/VoidDisplayApp/Navigation/HomeLayouts/HomeSharingSettingsPanel.swift"
	local violations

	violations="$(
		rg -n 'NSApp\.keyWindow|makeFirstResponder' "$source" || true
	)"
	fail_on_output \
		"Sharing Settings must leave focus ownership to SwiftUI and NavigationSplitView." \
		"$violations"
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

validate_log_scanner_propagates_search_errors() {
	local fixture_root="$AI_TMP_DIR/log-scanner-search-error"
	local fixture_bin="$fixture_root/bin"
	local fixture_log="$fixture_root/build.log"

	mkdir -p "$fixture_bin"
	printf '#!/usr/bin/env bash\nexit 2\n' >"$fixture_bin/rg"
	printf 'ordinary build output\n' >"$fixture_log"
	chmod +x "$fixture_bin/rg"

	if (
		PATH="$fixture_bin:$PATH"
		collect_build_log_diagnostics "$fixture_log" >/dev/null 2>&1
	); then
		die "Build log scanner accepted an rg I/O failure as an empty diagnostic result."
	fi
}

validate_swiftpm_log_scanner() {
	validate_log_scanner scan_build_log_for_diagnostics SwiftPM "$TOOL_ROOT/scripts/ci/fixtures/swiftpm-log-scanner"
}

validate_bootstrap_profile_fixtures() {
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/test_bootstrap_profiles.sh"
}

validate_classify_fixtures() {
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/test_classify.sh"
}

validate_swift_style() {
	mkdir -p "$AI_TMP_DIR"
	swiftformat --lint --cache "$AI_TMP_DIR/swiftformat.cache" --config "$ROOT_DIR/.swiftformat" Sources Tests UITests Apps Package.swift
	swiftlint lint --config "$ROOT_DIR/.swiftlint.yml" --quiet --cache-path "$AI_TMP_DIR/swiftlint-cache"
}

validate_display_page_javascript() {
	local javascript_file
	local javascript_file_count=0

	while IFS= read -r javascript_file; do
		node --check "$ROOT_DIR/$javascript_file"
		javascript_file_count=$((javascript_file_count + 1))
	done < <(rg --files Sources/VoidDisplaySharing/Resources Tests/BrowserRuntimeTests -g '*.js' | sort)

	((javascript_file_count > 0)) || die "Display page JavaScript sources and tests are missing."
}

validate_product_source_file_sizes() {
	local maximum_lines=900
	local source_file
	local line_count
	local violations=""

	while IFS= read -r source_file; do
		[[ "$source_file" != *_test.go ]] || continue
		line_count="$(wc -l <"$ROOT_DIR/$source_file" | tr -d '[:space:]')"
		if ((line_count > maximum_lines)); then
			violations+="$source_file:$line_count lines (limit: $maximum_lines)"$'\n'
		fi
	done < <(
		rg --files Sources Tools/VoidDisplayRelay/internal/relay \
			-g '*.swift' -g '*.go' -g '*.js' | sort
	)

	fail_on_output \
		"Product source files must be split before they exceed the structural size limit." \
		"${violations%$'\n'}"
}

validate_ui_tests_do_not_synthesize_keyboard_input() {
	local violations
	violations="$(
		rg -n '\.(typeKey|typeText)\b|XCUIKeyboardKey' \
			"$ROOT_DIR/UITests" "$ROOT_DIR/Tests" || true
	)"
	fail_on_output \
		"UI tests must not synthesize keyboard input because it can trigger input-method authorization prompts." \
		"$violations"
}

validate_xcode_project_layout
validate_xcode_shell_build_phase
validate_release_smoke_pins_relay_go_binary
validate_json_artifact_rejects_directory_target
validate_xcode_runner_signing_modes
validate_permission_sensitive_acceptance_contract
validate_home_popover_uses_system_focus
validate_xcode_log_scanner
validate_log_scanner_propagates_search_errors
validate_swiftpm_log_scanner
validate_bootstrap_profile_fixtures
validate_classify_fixtures
validate_swift_style
validate_display_page_javascript
validate_product_source_file_sizes
validate_ui_tests_do_not_synthesize_keyboard_input

info "Static project gate passed."
