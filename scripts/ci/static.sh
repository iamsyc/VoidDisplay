#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

require_command actionlint jq shellcheck shfmt swiftformat swiftlint rg xcrun

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

	invalid="$(awk '/scripts\// && $0 !~ /^[[:space:]]*- '\''scripts\// && $0 !~ /"\$tool_root\/scripts\// { print FILENAME ":" FNR ":" $0 }' "${workflow_files[@]}" || true)"
	fail_on_output "Workflow script references must be path filters or TOOL_ROOT executions." "$invalid"

	invalid="$(rg -n 'ROOT_DIR=.*scripts/' .github/workflows .github/actions | rg -v 'TOOL_ROOT=.*"\$tool_root/scripts/' || true)"
	fail_on_output "Workflow script invocations must pass ROOT_DIR and TOOL_ROOT and execute through TOOL_ROOT." "$invalid"
	assert_no_match "PR CI workflows must not expose GITHUB_TOKEN to checked-out repository scripts." \
		'GITHUB_TOKEN:[[:space:]]*\$\{\{[[:space:]]*github\.token[[:space:]]*\}\}' "${pr_ci_workflow_files[@]}"

	invalid="$(
		awk '
			function finish_checkout() {
				if (checkout_line && !saw_persist_credentials) {
					print current_file ":" checkout_line ":actions/checkout must set persist-credentials: false"
				}
			}
			FNR == 1 {
				finish_checkout()
				current_file = FILENAME
				saw_persist_credentials = 0
				checkout_line = 0
			}
			/^[[:space:]]*-[[:space:]]+(name|uses):/ {
				finish_checkout()
				saw_persist_credentials = 0
				checkout_line = 0
			}
			/uses:[[:space:]]*actions\/checkout@/ {
				saw_persist_credentials = 0
				checkout_line = FNR
			}
			checkout_line && /persist-credentials:[[:space:]]*false/ {
				saw_persist_credentials = 1
			}
			END {
				finish_checkout()
			}
		' "${pr_ci_workflow_files[@]}" || true
	)"
	fail_on_output "PR CI checkouts must disable persisted credentials." "$invalid"
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

validate_swift_style() {
	swiftformat --lint --config "$ROOT_DIR/.swiftformat" Sources Tests UITests Apps Package.swift scripts/release/render_dmg_background.swift
	swiftlint lint --config "$ROOT_DIR/.swiftlint.yml" --quiet
}

validate_swift_scripts() {
	xcrun swiftc -typecheck "$ROOT_DIR/scripts/release/render_dmg_background.swift"
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
validate_swift_style
validate_swift_scripts

info "Static gate passed."
