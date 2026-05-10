#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"
# shellcheck source=scripts/lib/release.sh
source "$TOOL_ROOT/scripts/lib/release.sh"

usage() {
	cat <<'EOF'
Usage: create_dmg.sh [--summary <summary-json>] <app-path> <output-dmg> <volume-name>
EOF
}

SUMMARY_PATH=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--summary)
		[[ $# -ge 2 && -n "${2:-}" ]] || die "--summary requires a path."
		SUMMARY_PATH="$(normalize_path "$2")"
		shift 2
		;;
	*)
		POSITIONAL_ARGS+=("$1")
		shift
		;;
	esac
done

if [ "${#POSITIONAL_ARGS[@]}" -ne 3 ]; then
	usage >&2
	exit 1
fi

app_path="${POSITIONAL_ARGS[0]}"
output_dmg="${POSITIONAL_ARGS[1]}"
volume_name="${POSITIONAL_ARGS[2]}"
stage="argument_validation"

if [[ -n "$SUMMARY_PATH" ]]; then
	require_command jq
fi

write_dmg_summary() {
	local status="$1"
	local reason="$2"
	local detail="$3"

	[[ -n "$SUMMARY_PATH" ]] || return 0
	write_json_file "$SUMMARY_PATH" \
		--arg status "$status" \
		--arg reason "$reason" \
		--arg detail "$detail" \
		--arg stage "$stage" \
		--arg app_path "$app_path" \
		--arg output_dmg "$output_dmg" \
		--arg volume_name "$volume_name" \
		'{status: $status, reason: $reason, detail: $detail, stage: $stage, app_path: $app_path, output_dmg: $output_dmg, volume_name: $volume_name}'
}

fail_dmg() {
	local reason="$1"
	local detail="$2"
	local exit_code="${3:-1}"

	write_dmg_summary "failed" "$reason" "$detail"
	echo "$detail" >&2
	exit "$exit_code"
}

handle_unexpected_dmg_error() {
	local exit_code="$1"
	local line_number="$2"

	trap - ERR
	write_dmg_summary "failed" "${stage}_failed" "DMG creation failed unexpectedly at line ${line_number}."
	exit "$exit_code"
}

trap 'handle_unexpected_dmg_error $? $LINENO' ERR

if [ ! -d "${app_path}" ]; then
	fail_dmg "missing_app" "App bundle not found: ${app_path}"
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
	fail_dmg "render_background_failed" "Failed to render DMG background image."
fi

stage="stage_payload"
if ! cp -R "${app_path}" "${stage_dir}/"; then
	fail_dmg "stage_payload_failed" "Failed to copy app bundle into DMG staging directory."
fi
if ! ln -s /Applications "${stage_dir}/Applications"; then
	fail_dmg "stage_payload_failed" "Failed to create Applications symlink in DMG staging directory."
fi
if ! SetFile -a V "${background_dir}"; then
	fail_dmg "dmg_metadata_failed" "Failed to hide DMG background directory with SetFile."
fi

stage="dmg_size"
if ! app_kb="$(du -sk "${app_path}" | awk '{print $1}')"; then
	fail_dmg "dmg_size_failed" "Failed to measure app bundle size."
fi
if ! background_kb="$(du -sk "${background_path}" | awk '{print $1}')"; then
	fail_dmg "dmg_size_failed" "Failed to measure DMG background size."
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
	fail_dmg "hdiutil_failed" "Failed to create writable DMG."
fi

stage="hdiutil_attach"
set +e
attach_output="$(hdiutil attach -readwrite -noverify -noautoopen "${rw_dmg}" 2>&1)"
attach_status="$?"
set -e
if [ "$attach_status" -ne 0 ]; then
	fail_dmg "hdiutil_failed" "Failed to attach writable DMG: ${attach_output}"
fi
device="$(printf '%s\n' "${attach_output}" | release_parse_attach_device)"
mount_path="$(printf '%s\n' "${attach_output}" | release_parse_attach_mount_path)"

if [ -z "${device}" ] || [ -z "${mount_path}" ]; then
	fail_dmg "hdiutil_failed" "Failed to locate mounted DMG device or mount path: ${attach_output}"
fi

mounted_volume_name="$(basename "${mount_path}")"

stage="dmg_layout"
layout_exit_code=0
release_run_with_timeout 45 osascript "$TOOL_ROOT/scripts/release/apply_dmg_layout.applescript" "${mounted_volume_name}" "${app_name}" || layout_exit_code="$?"
if [ "${layout_exit_code}" -ne 0 ]; then
	if [ "${layout_exit_code}" -eq 124 ]; then
		fail_dmg "dmg_layout_timeout" "DMG layout timed out after 45 seconds." 124
	else
		fail_dmg "dmg_layout_failed" "DMG layout failed with exit code ${layout_exit_code}." "${layout_exit_code}"
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
	fail_dmg "hdiutil_failed" "Failed to convert writable DMG to compressed DMG."
fi

stage="completed"
write_dmg_summary "passed" "passed" "DMG created successfully."
