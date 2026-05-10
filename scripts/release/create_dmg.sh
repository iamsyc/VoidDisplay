#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/release.sh
source "$TOOL_ROOT/scripts/lib/release.sh"

usage() {
	cat <<'EOF'
Usage: create_dmg.sh <app-path> <output-dmg> <volume-name>
EOF
}

POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
	POSITIONAL_ARGS+=("$1")
	shift
done

if [ "${#POSITIONAL_ARGS[@]}" -ne 3 ]; then
	usage >&2
	exit 1
fi

app_path="${POSITIONAL_ARGS[0]}"
output_dmg="${POSITIONAL_ARGS[1]}"
volume_name="${POSITIONAL_ARGS[2]}"
stage="argument_validation"

fail_dmg() {
	die "$1"
}

handle_unexpected_dmg_error() {
	local exit_code="$1"
	local line_number="$2"

	trap - ERR
	printf '[ERROR] DMG creation failed in stage %s at line %s.\n' "$stage" "$line_number" >&2
	exit "$exit_code"
}

trap 'handle_unexpected_dmg_error $? $LINENO' ERR

if [ ! -d "${app_path}" ]; then
	fail_dmg "App bundle not found: ${app_path}"
fi

output_dir="$(dirname "${output_dmg}")"
app_name="$(basename "${app_path}")"

stage="prepare_output"
mkdir -p "${output_dir}"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/voiddisplay-dmg.XXXXXX")"
stage_dir="${work_dir}/stage"
background_dir="${stage_dir}/.background"
background_path="${background_dir}/background.png"
rw_dmg="${work_dir}/temp-rw.dmg"
mount_path=""
device=""

cleanup() {
	release_cleanup_device "$device"
	rm -rf "${work_dir}"
}

trap cleanup EXIT

mkdir -p "${background_dir}"
# Render the DMG background at build time from a fixed template.
stage="render_background"
if ! swift "$TOOL_ROOT/scripts/release/render_dmg_background.swift" "${background_path}"; then
	fail_dmg "Failed to render DMG background image."
fi

stage="stage_payload"
if ! cp -R "${app_path}" "${stage_dir}/"; then
	fail_dmg "Failed to copy app bundle into DMG staging directory."
fi
if ! ln -s /Applications "${stage_dir}/Applications"; then
	fail_dmg "Failed to create Applications symlink in DMG staging directory."
fi
if ! SetFile -a V "${background_dir}"; then
	fail_dmg "Failed to hide DMG background directory with SetFile."
fi

stage="dmg_size"
if ! app_kb="$(du -sk "${app_path}" | awk '{print $1}')"; then
	fail_dmg "Failed to measure app bundle size."
fi
if ! background_kb="$(du -sk "${background_path}" | awk '{print $1}')"; then
	fail_dmg "Failed to measure DMG background size."
fi
size_kb="$((app_kb + background_kb + 65536))"

stage="hdiutil_create"
if ! hdiutil create \
	-srcfolder "${stage_dir}" \
	-volname "${volume_name}" \
	-fs HFS+ \
	-fsargs "-c c=64,a=16,e=16" \
	-format UDRW \
	-size "${size_kb}k" \
	-ov \
	"${rw_dmg}"; then
	fail_dmg "Failed to create writable DMG."
fi

stage="hdiutil_attach"
set +e
attach_output="$(hdiutil attach -readwrite -noverify -noautoopen "${rw_dmg}" 2>&1)"
attach_status="$?"
set -e
if [ "$attach_status" -ne 0 ]; then
	fail_dmg "Failed to attach writable DMG: ${attach_output}"
fi
device="$(printf '%s\n' "${attach_output}" | release_parse_attach_device)"
mount_path="$(printf '%s\n' "${attach_output}" | release_parse_attach_mount_path)"

if [ -z "${device}" ] || [ -z "${mount_path}" ]; then
	fail_dmg "Failed to locate mounted DMG device or mount path: ${attach_output}"
fi

mounted_volume_name="$(basename "${mount_path}")"

stage="dmg_layout"
layout_exit_code=0
release_run_with_timeout 45 osascript "$TOOL_ROOT/scripts/release/apply_dmg_layout.applescript" "${mounted_volume_name}" "${app_name}" || layout_exit_code="$?"
if [ "${layout_exit_code}" -ne 0 ]; then
	if [ "${layout_exit_code}" -eq 124 ]; then
		printf '[ERROR] DMG layout timed out after 45 seconds.\n' >&2
		exit 124
	else
		printf '[ERROR] DMG layout failed with exit code %s.\n' "${layout_exit_code}" >&2
		exit "${layout_exit_code}"
	fi
fi

SetFile -a V "${mount_path}/.background" || true
bless --folder "${mount_path}" --openfolder "${mount_path}" >/dev/null 2>&1 || true

stage="hdiutil_detach"
release_detach_device "${device}"
device=""

rm -f "${output_dmg}"
stage="hdiutil_convert"
if ! hdiutil convert "${rw_dmg}" -format UDZO -imagekey zlib-level=9 -ov -o "${output_dmg}"; then
	fail_dmg "Failed to convert writable DMG to compressed DMG."
fi
