#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

require_command shellcheck shfmt bash zsh rg

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
		'SCRIPT_ROOT=|SCRIPT_LIB_DIR=' scripts --glob '!scripts/ci/static_shell.sh'

	invalid="$(
		rg -n 'source .*scripts/lib/(common|artifacts|xcode|xcresult|architecture|release|release_binaries)\.sh|source "\$[A-Z_]+/(common|artifacts|xcode|xcresult|architecture|release|release_binaries)\.sh' scripts --glob '!scripts/ci/static_shell.sh' || true
	)"
	invalid="$(printf '%s\n' "$invalid" | rg -v 'source "\$TOOL_ROOT/scripts/lib/' || true)"
	fail_on_output "Helper source paths must use TOOL_ROOT." "$invalid"

	assert_no_match "Nested script calls must pass ROOT_DIR and TOOL_ROOT explicitly." \
		'ROOT_DIR="\$ROOT_DIR"(?!.*TOOL_ROOT=)|ROOT_DIR=\$\{ROOT_DIR:-' scripts --pcre2 --glob '!scripts/lib/contract.sh' --glob '!scripts/ci/static_shell.sh'
}

validate_shell_scripts
validate_script_contract

info "Static shell gate passed."
