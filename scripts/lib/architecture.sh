#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_ARCHITECTURE_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_ARCHITECTURE_SH_SOURCED=1

	# shellcheck source=scripts/lib/common.sh
	source "$TOOL_ROOT/scripts/lib/common.sh"

	validate_release_arch() {
		case "$1" in
		arm64 | x86_64) ;;
		*) die "Unsupported release architecture: $1" ;;
		esac
	}

	release_label_for_arch() {
		local arch="$1"
		validate_release_arch "$arch"
		case "$arch" in
		arm64) printf 'arm64\n' ;;
		x86_64) printf 'intel64\n' ;;
		esac
	}

	xcode_destination_for_arch() {
		local arch="$1"
		validate_release_arch "$arch"
		case "$arch" in
		arm64) printf 'platform=macOS,arch=arm64\n' ;;
		x86_64) printf 'platform=macOS,arch=x86_64\n' ;;
		esac
	}

	goarch_for_arch() {
		local arch="$1"
		validate_release_arch "$arch"
		case "$arch" in
		arm64) printf 'arm64\n' ;;
		x86_64) printf 'amd64\n' ;;
		esac
	}

	require_release_label_for_arch() {
		local arch="$1"
		local label="$2"
		local expected_label
		expected_label="$(release_label_for_arch "$arch")"
		[[ "$label" == "$expected_label" ]] || die "--label must be $expected_label for --arch $arch."
	}
fi
