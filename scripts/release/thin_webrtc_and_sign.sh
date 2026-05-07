#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/architecture.sh
source "$TOOL_ROOT/scripts/lib/architecture.sh"
# shellcheck source=scripts/lib/release_binaries.sh
source "$TOOL_ROOT/scripts/lib/release_binaries.sh"

usage() {
	cat <<'EOF'
Usage: thin_webrtc_and_sign.sh <app-path> <target-arch>
EOF
}

if [ "$#" -ne 2 ]; then
	usage >&2
	exit 1
fi

app_path="$1"
target_arch="$2"
validate_release_arch "$target_arch"
webrtc_framework="${app_path}/Contents/Frameworks/WebRTC.framework"
root_webrtc_binary="${webrtc_framework}/WebRTC"
root_webrtc_was_symlink=false
relay_binary="${app_path}/Contents/Resources/voiddisplay-relay"

if [ ! -d "${app_path}" ]; then
	echo "Expected app not found: ${app_path}" >&2
	exit 1
fi

if [ ! -d "${webrtc_framework}" ]; then
	echo "Expected WebRTC framework not found: ${webrtc_framework}" >&2
	exit 1
fi

if [ ! -f "${relay_binary}" ]; then
	echo "Expected relay binary not found: ${relay_binary}" >&2
	exit 1
fi

if [ ! -x "${relay_binary}" ]; then
	echo "Expected relay binary to be executable: ${relay_binary}" >&2
	exit 1
fi

if [ -L "${root_webrtc_binary}" ]; then
	root_webrtc_was_symlink=true
fi

webrtc_binary="$(resolve_webrtc_binary "${webrtc_framework}")"
if [ -z "${webrtc_binary}" ] || [ ! -f "${webrtc_binary}" ]; then
	echo "Failed to locate WebRTC binary under: ${webrtc_framework}" >&2
	exit 1
fi

webrtc_binary_real="${webrtc_binary}"
if [ -L "${webrtc_binary}" ]; then
	link_target="$(readlink "${webrtc_binary}")"
	if [ -z "${link_target}" ]; then
		echo "Failed to resolve symlink target: ${webrtc_binary}" >&2
		exit 1
	fi

	if [[ "${link_target}" = /* ]]; then
		webrtc_binary_real="${link_target}"
	else
		webrtc_binary_real="$(cd "$(dirname "${webrtc_binary}")" && pwd)/${link_target}"
	fi
fi

if [ ! -f "${webrtc_binary_real}" ]; then
	echo "Resolved WebRTC binary does not exist: ${webrtc_binary_real}" >&2
	exit 1
fi

echo "WebRTC binary before thin: ${webrtc_binary_real}"
lipo -archs "${webrtc_binary_real}"
temp_binary="${webrtc_binary_real}.thin"
lipo -thin "${target_arch}" "${webrtc_binary_real}" -output "${temp_binary}"
mv "${temp_binary}" "${webrtc_binary_real}"
chmod +x "${webrtc_binary_real}"
echo "WebRTC binary after thin:"
lipo -archs "${webrtc_binary_real}"

if [ "${root_webrtc_was_symlink}" = true ] && [ ! -L "${root_webrtc_binary}" ]; then
	echo "Expected ${root_webrtc_binary} to remain a symlink after thinning." >&2
	exit 1
fi

require_binary_arch "Relay" "${relay_binary}" "${target_arch}"

echo "Applying ad hoc signature for local release packaging. Developer ID signing and notarization are not configured."
codesign --force --sign - --timestamp=none "${relay_binary}"
codesign --force --sign - --timestamp=none "${webrtc_framework}"
codesign --force --sign - --timestamp=none --deep "${app_path}"
codesign --verify --deep --strict --verbose=2 "${app_path}"
codesign --verify --strict --verbose=2 "${relay_binary}"

validate_release_app_binaries "${app_path}" "${target_arch}"
