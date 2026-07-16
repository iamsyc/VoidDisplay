#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

require_command git jq swiftformat swiftlint xcrun rg awk diff wc tr

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
		rg -F "$required" "$file" >/dev/null || die "$message: $required"
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
		'"cd \"$SRCROOT\"",'

	assert_file_contains_all "$project_file" "Build Relay phase is missing required tool input or build setting" \
		'"$(TOOL_ROOT)/scripts/build-relay.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/contract.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/common.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/architecture.sh",' \
		'"$(TOOL_ROOT)/scripts/lib/release_binaries.sh",'

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
		'$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/voiddisplay-relay'

	invalid_inputs="$(
		extract_pbx_array_values inputPaths |
			rg -v '^\$\(TOOL_ROOT\)/scripts/(build-relay\.sh|lib/(contract|common|architecture|release_binaries)\.sh)$|^\$\(ROOT_DIR\)/Tools/VoidDisplayRelay/' || true
	)"
	fail_on_output "Build Relay input paths must stay under allowed prefixes." "$invalid_inputs"
}

validate_relay_build_is_script_sandbox_compatible() {
	assert_file_contains_all \
		"$TOOL_ROOT/scripts/build-relay.sh" \
		"Relay build must not inspect undeclared Git metadata inside the Xcode user script sandbox" \
		'build -buildvcs=false -trimpath'
}

validate_xcode_runner_disables_signing() {
	local runner="$TOOL_ROOT/scripts/ci/xcode.sh"
	local base_command
	local match_count
	local setting

	base_command="$(
		awk '
			/^[[:space:]]*xcode_cmd=\([[:space:]]*$/ { inside = 1 }
			inside { print }
			inside && /^[[:space:]]*\)[[:space:]]*$/ { exit }
		' "$runner"
	)"
	[[ -n "$base_command" ]] || die "Xcode runner base command could not be resolved."

	for setting in CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO; do
		match_count="$(rg -c "^[[:space:]]*\"$setting\"[[:space:]]*$" <<<"$base_command" || true)"
		[[ "$match_count" == "1" ]] ||
			die "Xcode runner base command must contain exactly one setting for every action: $setting"
	done
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

validate_bootstrap_profile_fixtures() {
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/test_bootstrap_profiles.sh"
}

validate_classify_fixtures() {
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/test_classify.sh"
}

validate_release_project_path_fixtures() {
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/test_release_project_paths.sh"
}

validate_swift_style() {
	swiftformat --lint --config "$ROOT_DIR/.swiftformat" Sources Tests UITests Apps Package.swift scripts/release/render_dmg_background.swift
	swiftlint lint --config "$ROOT_DIR/.swiftlint.yml" --quiet
}

validate_swift_scripts() {
	xcrun swiftc -typecheck "$ROOT_DIR/scripts/release/render_dmg_background.swift"
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
validate_relay_build_is_script_sandbox_compatible
validate_xcode_runner_disables_signing
validate_xcode_log_scanner
validate_swiftpm_log_scanner
validate_bootstrap_profile_fixtures
validate_classify_fixtures
validate_release_project_path_fixtures
validate_swift_style
validate_swift_scripts
validate_ui_tests_do_not_synthesize_keyboard_input

info "Static project gate passed."
