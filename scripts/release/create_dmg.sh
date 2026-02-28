#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: create_dmg.sh <app-path> <output-dmg> <volume-name>
EOF
}

if [ "$#" -ne 3 ]; then
  usage >&2
  exit 1
fi

app_path="$1"
output_dmg="$2"
volume_name="$3"

if [ ! -d "${app_path}" ]; then
  echo "App bundle not found: ${app_path}" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="$(dirname "${output_dmg}")"
app_name="$(basename "${app_path}")"

mkdir -p "${output_dir}"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/voiddisplay-dmg.XXXXXX")"
stage_dir="${work_dir}/stage"
background_dir="${stage_dir}/.background"
background_path="${background_dir}/background.png"
rw_dmg="${work_dir}/temp-rw.dmg"
mount_path=""
device=""

cleanup() {
  if [ -n "${device}" ]; then
    hdiutil detach "${device}" -quiet >/dev/null 2>&1 || hdiutil detach "${device}" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "${work_dir}"
}

trap cleanup EXIT

detach_volume() {
  local target_device="$1"

  if [ -z "${target_device}" ]; then
    return
  fi

  for _ in 1 2 3 4 5; do
    if hdiutil detach "${target_device}" -quiet >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done

  hdiutil detach "${target_device}" -force -quiet >/dev/null 2>&1 || true
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]

try:
    completed = subprocess.run(command, check=False, timeout=timeout_seconds)
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
}

mkdir -p "${background_dir}"
# Render the DMG background at build time from a fixed template.
swift "${script_dir}/render_dmg_background.swift" "${background_path}"

cp -R "${app_path}" "${stage_dir}/"
ln -s /Applications "${stage_dir}/Applications"
SetFile -a V "${background_dir}"

app_kb="$(du -sk "${app_path}" | awk '{print $1}')"
background_kb="$(du -sk "${background_path}" | awk '{print $1}')"
size_kb="$((app_kb + background_kb + 65536))"

hdiutil create \
  -srcfolder "${stage_dir}" \
  -volname "${volume_name}" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size "${size_kb}k" \
  -ov \
  "${rw_dmg}"

attach_output="$(hdiutil attach -readwrite -noverify -noautoopen "${rw_dmg}")"
device="$(printf '%s\n' "${attach_output}" | awk '/^\/dev\// {print $1; exit}')"
mount_path="$(printf '%s\n' "${attach_output}" | sed -n 's#.*\(/Volumes/.*\)$#\1#p' | tail -n 1)"

if [ -z "${device}" ] || [ -z "${mount_path}" ]; then
  echo "Failed to mount DMG." >&2
  printf '%s\n' "${attach_output}" >&2
  exit 1
fi

layout_exit_code=0
run_with_timeout 45 osascript "${script_dir}/apply_dmg_layout.applescript" "${volume_name}" "${app_name}" || layout_exit_code="$?"
if [ "${layout_exit_code}" -ne 0 ]; then
  if [ "${layout_exit_code}" -eq 124 ]; then
    echo "DMG layout timed out after 45 seconds." >&2
  else
    echo "DMG layout failed with exit code ${layout_exit_code}." >&2
  fi
  exit 1
fi

SetFile -a V "${mount_path}/.background" || true
bless --folder "${mount_path}" --openfolder "${mount_path}" >/dev/null 2>&1 || true

detach_volume "${device}"
device=""

rm -f "${output_dmg}"
hdiutil convert "${rw_dmg}" -format UDZO -imagekey zlib-level=9 -ov -o "${output_dmg}"
