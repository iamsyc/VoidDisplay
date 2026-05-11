#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

require_command awk grep sort

profile_commands() {
	local profile="$1"

	"$TOOL_ROOT/scripts/dev/bootstrap.sh" --profile "$profile" --print-required-commands | sort -u
}

script_required_commands() {
	local script_path="$1"

	awk '
		/^[[:space:]]*require_command[[:space:]]/ {
			for (i = 2; i <= NF; i += 1) {
				value = $i
				gsub(/["'\'';]/, "", value)
				if (value != "" && value !~ /\$/) {
					print value
				}
			}
		}
	' "$script_path" | sort -u
}

doctor_required_commands() {
	local script_path="$1"

	awk '
		/^[[:space:]]*DOCTOR_REQUIRED_COMMANDS=\(/ { inside = 1 }
		inside { line = line " " $0 }
		inside && /\)/ {
			gsub(/.*DOCTOR_REQUIRED_COMMANDS=\(/, "", line)
			gsub(/\).*/, "", line)
			gsub(/["'\'';]/, "", line)
			split(line, values, /[[:space:]]+/)
			for (i in values) {
				if (values[i] != "") {
					print values[i]
				}
			}
			inside = 0
			line = ""
		}
	' "$script_path" | sort -u
}

script_command_contract() {
	local script_path="$1"

	{
		script_required_commands "$script_path"
		doctor_required_commands "$script_path"
	} | sort -u
}

assert_profile_covers_scripts() {
	local profile="$1"
	local profile_command_file="$WORK_DIR/$profile.commands"
	local script_path
	local command_name
	shift

	profile_commands "$profile" >"$profile_command_file"

	for script_path in "$@"; do
		while IFS= read -r command_name; do
			[[ -n "$command_name" ]] || continue
			if ! grep -Fx "$command_name" "$profile_command_file" >/dev/null; then
				die "$profile profile does not cover $command_name required by $script_path."
			fi
		done < <(script_command_contract "$script_path")
	done
}

WORK_DIR="${WORK_DIR:-$(make_artifact_dir bootstrap-profile-tests)}"
mkdir -p "$WORK_DIR"

assert_profile_covers_scripts static \
	scripts/ci/static_shell.sh \
	scripts/ci/static_workflows.sh \
	scripts/ci/static_project.sh \
	scripts/ci/test_bootstrap_profiles.sh \
	scripts/ci/test_classify.sh

assert_profile_covers_scripts unit scripts/ci/unit.sh
assert_profile_covers_scripts xcode scripts/dev/doctor.sh scripts/ci/xcode.sh
assert_profile_covers_scripts ui-smoke scripts/ci/ui_smoke.sh
assert_profile_covers_scripts release-smoke scripts/ci/release_smoke.sh

info "Bootstrap profile fixtures passed."
