#!/usr/bin/env bash
set -euo pipefail

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
webrtc_framework="${app_path}/Contents/Frameworks/WebRTC.framework"
root_webrtc_binary="${webrtc_framework}/WebRTC"
root_webrtc_was_symlink=false

if [ ! -d "${app_path}" ]; then
  echo "Expected app not found: ${app_path}" >&2
  exit 1
fi

if [ ! -d "${webrtc_framework}" ]; then
  echo "Expected WebRTC framework not found: ${webrtc_framework}" >&2
  exit 1
fi

if [ -L "${root_webrtc_binary}" ]; then
  root_webrtc_was_symlink=true
fi

resolve_webrtc_binary() {
  local framework_path="$1"
  local candidate=""

  for candidate in \
    "${framework_path}/Versions/Current/WebRTC" \
    "${framework_path}/Versions/A/WebRTC" \
    "${framework_path}/WebRTC"; do
    if [ -f "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  find "${framework_path}" -type f -name WebRTC | head -n 1 || true
}

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

codesign --force --sign - --timestamp=none "${webrtc_framework}"
codesign --force --sign - --timestamp=none --deep "${app_path}"
codesign --verify --deep --strict --verbose=2 "${app_path}"

if [ ! -f "${app_path}/Contents/Info.plist" ]; then
  echo "Expected Info.plist not found under app bundle: ${app_path}" >&2
  exit 1
fi

bundle_executable="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' \
    "${app_path}/Contents/Info.plist" \
    2>/dev/null || true
)"

if [ -z "${bundle_executable}" ]; then
  echo "Failed to read CFBundleExecutable from ${app_path}/Contents/Info.plist" >&2
  exit 1
fi

app_binary="${app_path}/Contents/MacOS/${bundle_executable}"
if [ ! -f "${app_binary}" ]; then
  echo "Expected app binary not found: ${app_binary}" >&2
  exit 1
fi

app_archs="$(lipo -archs "${app_binary}")"
webrtc_archs="$(lipo -archs "${webrtc_binary_real}")"
echo "App binary archs: ${app_archs}"
echo "WebRTC binary archs: ${webrtc_archs}"

if [ "${app_archs}" != "${target_arch}" ]; then
  echo "App binary arch mismatch. Expected ${target_arch}, got ${app_archs}" >&2
  exit 1
fi

if [ "${webrtc_archs}" != "${target_arch}" ]; then
  echo "WebRTC binary arch mismatch. Expected ${target_arch}, got ${webrtc_archs}" >&2
  exit 1
fi
