#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/dev/bootstrap_profiles.sh
source "$TOOL_ROOT/scripts/dev/bootstrap_profiles.sh"

CI_REQUIRES_MISE="${CI_REQUIRES_MISE:-${GITHUB_ACTIONS:-false}}"
PROFILE="full"
PRINT_REQUIRED_COMMANDS="false"
PRINT_MISE_TARGETS="false"
required_commands=()
mise_targets=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--profile)
		[[ $# -ge 2 && -n "${2:-}" ]] || die "--profile requires a value."
		PROFILE="$2"
		shift 2
		;;
	--print-required-commands)
		PRINT_REQUIRED_COMMANDS="true"
		shift
		;;
	--print-mise-targets)
		PRINT_MISE_TARGETS="true"
		shift
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

if ! bootstrap_profile_exists "$PROFILE"; then
	die "Unsupported bootstrap profile: $PROFILE"
fi

while IFS= read -r command_name; do
	[[ -n "$command_name" ]] && required_commands+=("$command_name")
done < <(bootstrap_profile_commands "$PROFILE")

while IFS= read -r target_name; do
	[[ -n "$target_name" ]] && mise_targets+=("$target_name")
done < <(bootstrap_profile_mise_targets "$PROFILE")

if [[ "$PRINT_REQUIRED_COMMANDS" == "true" ]]; then
	printf '%s\n' "${required_commands[@]}"
	exit 0
fi

if [[ "$PRINT_MISE_TARGETS" == "true" ]]; then
	printf '%s\n' "${mise_targets[@]}"
	exit 0
fi

activate_mise_shims() {
	local mise_data_dir="${MISE_DATA_DIR:-$HOME/.local/share/mise}"
	local shims_dir="$mise_data_dir/shims"
	if [[ -d "$shims_dir" ]]; then
		export PATH="$shims_dir:$PATH"
		if [[ -n "${GITHUB_PATH:-}" ]]; then
			printf '%s\n' "$shims_dir" >>"$GITHUB_PATH"
		fi
	fi
}

install_pinned_tools_with_mise() {
	info "Installing pinned tools with mise."
	cd "$TOOL_ROOT"
	export MISE_YES=1
	if [[ "$CI_REQUIRES_MISE" == "true" ]]; then
		export MISE_LOCKED="${MISE_LOCKED:-1}"
		export MISE_LOCKED_VERIFY_PROVENANCE="${MISE_LOCKED_VERIFY_PROVENANCE:-0}"
		export MISE_AQUA_GITHUB_ATTESTATIONS="${MISE_AQUA_GITHUB_ATTESTATIONS:-0}"
		export MISE_AQUA_SLSA="${MISE_AQUA_SLSA:-0}"
		export MISE_GITHUB_GITHUB_ATTESTATIONS="${MISE_GITHUB_GITHUB_ATTESTATIONS:-0}"
		export MISE_GITHUB_SLSA="${MISE_GITHUB_SLSA:-0}"
	fi
	export MISE_TRUSTED_CONFIG_PATHS="$TOOL_ROOT"
	if ((${#mise_targets[@]})); then
		mise install "${mise_targets[@]}"
	else
		mise install
	fi
	mise reshim >/dev/null 2>&1 || true
	activate_mise_shims
}

if command -v mise >/dev/null 2>&1; then
	install_pinned_tools_with_mise
elif [[ "$CI_REQUIRES_MISE" == "true" ]]; then
	command -v brew >/dev/null 2>&1 || die "mise is required in CI, and Homebrew is unavailable to install it."
	info "mise not found. Installing mise for CI tool bootstrap."
	brew install mise
	install_pinned_tools_with_mise
elif command -v brew >/dev/null 2>&1; then
	info "mise not found. Installing fallback tools with Homebrew bundle."
	brew bundle --file "$TOOL_ROOT/Brewfile"
else
	die "Neither mise nor Homebrew is available. Install mise first."
fi

cd "$ROOT_DIR"
require_command "${required_commands[@]}"

info "Tool bootstrap completed."
