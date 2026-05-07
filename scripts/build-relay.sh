#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/architecture.sh
source "$TOOL_ROOT/scripts/lib/architecture.sh"
# shellcheck source=scripts/lib/release_binaries.sh
source "$TOOL_ROOT/scripts/lib/release_binaries.sh"

RELAY_DIR="$ROOT_DIR/Tools/VoidDisplayRelay"
TARGET_DIR="${TARGET_BUILD_DIR:-$ROOT_DIR/.build/debug}"
case "$TARGET_DIR" in
/*) ;;
*) TARGET_DIR="$ROOT_DIR/$TARGET_DIR" ;;
esac
OUTPUT_DIR="$TARGET_DIR/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}"
OUTPUT_PATH="$OUTPUT_DIR/voiddisplay-relay"
GOPROXY_VALUE="${GOPROXY:-https://proxy.golang.org|https://goproxy.cn|direct}"

resolve_target_arch() {
	local arch="${CURRENT_ARCH:-}"
	local arch_values=()

	if [[ -z "$arch" || "$arch" == "undefined_arch" ]]; then
		if [[ -n "${ARCHS:-}" ]]; then
			read -r -a arch_values <<<"$ARCHS"
			arch="${arch_values[0]:-}"
		fi
	fi

	if [[ -z "$arch" || "$arch" == "undefined_arch" ]]; then
		arch="$(uname -m)"
	fi

	case "$arch" in
	arm64e) arch="arm64" ;;
	esac

	validate_release_arch "$arch"
	printf '%s\n' "$arch"
}

if [[ -z "${GO_BIN:-}" ]]; then
	for candidate in "$(command -v go || true)" /opt/homebrew/bin/go /usr/local/bin/go; do
		if [[ -n "$candidate" && -x "$candidate" ]]; then
			GO_BIN="$candidate"
			break
		fi
	done
fi

[[ -n "${GO_BIN:-}" ]] || die "go executable not found. Install Go or set GO_BIN."
[[ -d "$RELAY_DIR" ]] || die "Relay source directory not found: $RELAY_DIR"

TARGET_ARCH="$(resolve_target_arch)"
GOARCH_VALUE="$(goarch_for_arch "$TARGET_ARCH")"

mkdir -p "$OUTPUT_DIR"
cd "$RELAY_DIR"

env GOPROXY="$GOPROXY_VALUE" "$GO_BIN" test ./...
env GOPROXY="$GOPROXY_VALUE" GOOS=darwin GOARCH="$GOARCH_VALUE" "$GO_BIN" build -trimpath -o "$OUTPUT_PATH" ./cmd/voiddisplay-relay
chmod +x "$OUTPUT_PATH"
require_binary_arch "Relay" "$OUTPUT_PATH" "$TARGET_ARCH"
