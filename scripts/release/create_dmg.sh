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
template_dmg="$TOOL_ROOT/scripts/release/assets/VoidDisplay-template.dmg"

if [[ "$app_name" != "VoidDisplay.app" ]]; then
	fail_dmg "DMG template requires VoidDisplay.app, received: ${app_name}"
fi
if [[ "$volume_name" != "VoidDisplay" ]]; then
	fail_dmg "DMG template requires volume name VoidDisplay, received: ${volume_name}"
fi
if [[ ! -f "$template_dmg" ]]; then
	fail_dmg "DMG template not found: ${template_dmg}"
fi

stage="prepare_output"
mkdir -p "${output_dir}"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/voiddisplay-dmg.XXXXXX")"
rw_dmg="${work_dir}/temp-rw.dmg"
mount_path=""
device=""

cleanup() {
	release_cleanup_device "$device"
	rm -rf "${work_dir}"
}

trap cleanup EXIT

stage="dmg_size"
if ! app_kb="$(du -sk "${app_path}" | awk '{print $1}')"; then
	fail_dmg "Failed to measure app bundle size."
fi
size_kb="$((app_kb + 65536))"

stage="prepare_template"
if ! run_with_retry 3 hdiutil convert \
	"${template_dmg}" \
	-format UDRW \
	-ov \
	-o "${rw_dmg}"; then
	fail_dmg "Failed to prepare writable DMG template."
fi

stage="hdiutil_resize"
if ! hdiutil resize -size "${size_kb}k" "${rw_dmg}"; then
	fail_dmg "Failed to resize writable DMG template."
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
if [[ "$mounted_volume_name" != "$volume_name" ]]; then
	fail_dmg "Mounted DMG volume name mismatch: ${mounted_volume_name}"
fi

stage="validate_template"
if [[ ! -f "${mount_path}/.DS_Store" ]]; then
	fail_dmg "DMG template is missing Finder layout metadata."
fi
if [[ ! -f "${mount_path}/.background/background.png" ]]; then
	fail_dmg "DMG template is missing its background image."
fi
if [[ ! -L "${mount_path}/Applications" || "$(readlink "${mount_path}/Applications")" != "/Applications" ]]; then
	fail_dmg "DMG template is missing the Applications symlink."
fi
if [[ ! -d "${mount_path}/${app_name}" ]]; then
	fail_dmg "DMG template is missing the app placeholder."
fi

stage="install_app"
if ! rmdir "${mount_path}/${app_name}"; then
	fail_dmg "DMG app placeholder is not empty."
fi
if ! cp -R "${app_path}" "${mount_path}/"; then
	fail_dmg "Failed to copy app bundle into DMG."
fi

stage="hdiutil_detach"
release_detach_device "${device}"
device=""

rm -f "${output_dmg}"
stage="hdiutil_convert"
if ! run_with_retry 3 hdiutil convert "${rw_dmg}" -format UDZO -imagekey zlib-level=9 -ov -o "${output_dmg}"; then
	fail_dmg "Failed to convert writable DMG to compressed DMG."
fi
