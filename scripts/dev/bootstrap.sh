#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

CI_REQUIRES_MISE="${CI_REQUIRES_MISE:-${GITHUB_ACTIONS:-false}}"
PROFILE="full"

required_commands=(
	actionlint
	shellcheck
	shfmt
	swiftformat
	swiftlint
	go
	jq
	rg
	syft
	gh
)
mise_targets=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--profile)
		[[ $# -ge 2 && -n "${2:-}" ]] || die "--profile requires a value."
		PROFILE="$2"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

case "$PROFILE" in
full) ;;
release-smoke)
	required_commands=(go jq rg)
	mise_targets=(go aqua:jqlang/jq aqua:BurntSushi/ripgrep)
	;;
*)
	die "Unsupported bootstrap profile: $PROFILE"
	;;
esac

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
