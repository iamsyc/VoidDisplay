#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

require_command actionlint shellcheck shfmt swiftformat swiftlint rg

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

	for positive_fixture in "$fixture_dir"/positive-*.log; do
		if (scan_xcode_log_for_diagnostics "Xcode log fixture" "$positive_fixture" >/dev/null 2>&1); then
			die "Xcode log scanner missed fixture: $positive_fixture"
		fi
	done

	scan_xcode_log_for_diagnostics "Xcode negative log fixture" "$fixture_dir/negative-ordinary-text.log"
}

validate_swift_style() {
	swiftformat --lint --config "$ROOT_DIR/.swiftformat" Sources Tests UITests Package.swift
	swiftlint lint --config "$ROOT_DIR/.swiftlint.yml" --quiet
}

actionlint
validate_runner_labels
validate_action_pinning
validate_shell_scripts
validate_script_contract
validate_workflow_script_contract
validate_xcode_shell_build_phase
validate_xcode_log_scanner
validate_swift_style

info "Static gate passed."
