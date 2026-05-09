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
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

ASSETS_DIR=""
TAG=""
LABEL=""
ARCH=""
REPOSITORY="${GITHUB_REPOSITORY:-iamsyc/VoidDisplay}"
REQUIRE_ATTESTATION="false"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--assets-dir)
		ASSETS_DIR="$(normalize_path "$2")"
		shift 2
		;;
	--tag)
		TAG="$2"
		shift 2
		;;
	--label)
		LABEL="$2"
		shift 2
		;;
	--arch)
		ARCH="$2"
		shift 2
		;;
	--repository)
		REPOSITORY="$2"
		shift 2
		;;
	--require-attestation)
		REQUIRE_ATTESTATION="$2"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

[[ -n "$ASSETS_DIR" ]] || die "--assets-dir is required."
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--tag must match vMAJOR.MINOR.PATCH."
[[ -n "$ARCH" ]] || die "--arch is required."
validate_release_arch "$ARCH"
LABEL="${LABEL:-$(release_label_for_arch "$ARCH")}"
require_release_label_for_arch "$ARCH" "$LABEL"

require_command jq

dmg_path="$ASSETS_DIR/VoidDisplay-${TAG}-${LABEL}.dmg"
sha_path="$dmg_path.sha256"
sbom_path="$dmg_path.spdx.json"
summary_path="$ASSETS_DIR/VoidDisplay-${TAG}-${LABEL}.verify-summary.json"
mount_path=""
device=""
bundle_id=""
version=""
verify_stage="input_validation"
verify_summary_written="false"

cleanup() {
	if [[ -n "$device" ]]; then
		hdiutil detach "$device" -quiet >/dev/null 2>&1 || hdiutil detach "$device" -force -quiet >/dev/null 2>&1 || true
	fi
}

write_verify_summary() {
	local status="$1"
	local reason="$2"
	local detail="$3"
	local dmg_name
	local sbom_name

	dmg_name="$(basename "$dmg_path")"
	sbom_name="$(basename "$sbom_path")"
	write_json_file "$summary_path" \
		--arg status "$status" \
		--arg reason "$reason" \
		--arg detail "$detail" \
		--arg tag "$TAG" \
		--arg label "$LABEL" \
		--arg arch "$ARCH" \
		--arg bundle_id "$bundle_id" \
		--arg version "$version" \
		--arg dmg "$dmg_name" \
		--arg sbom "$sbom_name" \
		--arg attestation_required "$REQUIRE_ATTESTATION" \
		--arg signing "ad_hoc" \
		'{
		  status: $status,
		  reason: $reason,
		  detail: $detail,
		  tag: $tag,
		  label: $label,
		  arch: $arch,
		  bundle_id: $bundle_id,
		  version: $version,
		  dmg: $dmg,
		  sbom: $sbom,
		  attestation_required: ($attestation_required == "true"),
		  signing: $signing
		}'
	verify_summary_written="true"
}

fail_verify() {
	local reason="$1"
	local detail="$2"

	write_verify_summary "failed" "$reason" "$detail"
	die "$detail"
}

handle_verify_exit() {
	local exit_code="$?"

	if [[ "$exit_code" -ne 0 && "$verify_summary_written" != "true" ]]; then
		write_verify_summary "failed" "${verify_stage}_failed" "Release verification failed in stage ${verify_stage}."
	fi
	cleanup
}
trap handle_verify_exit EXIT

[[ -f "$dmg_path" ]] || fail_verify "missing_dmg" "Missing DMG: $dmg_path"
[[ -f "$sha_path" ]] || fail_verify "missing_checksum" "Missing checksum: $sha_path"
[[ -f "$sbom_path" ]] || fail_verify "missing_sbom" "Missing SBOM: $sbom_path"

verify_stage="checksum"
if ! (
	cd "$(dirname "$dmg_path")"
	shasum -a 256 -c "$(basename "$sha_path")"
); then
	fail_verify "checksum_failed" "Checksum verification failed."
fi

verify_stage="hdiutil_attach"
set +e
attach_output="$(hdiutil attach -readonly -noverify -noautoopen "$dmg_path" 2>&1)"
attach_status="$?"
set -e
if [[ "$attach_status" -ne 0 ]]; then
	fail_verify "hdiutil_failed" "Failed to attach DMG: $attach_output"
fi
device="$(printf '%s\n' "$attach_output" | awk '/^\/dev\// {print $1; exit}')"
mount_path="$(printf '%s\n' "$attach_output" | sed -n 's#.*\(/Volumes/.*\)$#\1#p' | tail -n 1)"

[[ -n "$device" && -n "$mount_path" ]] || fail_verify "hdiutil_failed" "Failed to locate mounted DMG device or mount path."

app_path="$mount_path/VoidDisplay.app"
[[ -d "$app_path" ]] || fail_verify "missing_app" "DMG does not contain VoidDisplay.app."

verify_stage="bundle_metadata"
info_plist="$app_path/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
[[ "$bundle_id" == "com.developerchen.voiddisplay" ]] || fail_verify "bundle_id_mismatch" "Unexpected bundle id: $bundle_id"
[[ "v$version" == "$TAG" ]] || fail_verify "version_mismatch" "Version mismatch. Expected $TAG, got v$version"

verify_stage="binary_validation"
validate_release_app_binaries "$app_path" "$ARCH"

verify_stage="codesign"
if ! codesign --verify --deep --strict --verbose=2 "$app_path"; then
	fail_verify "codesign_failed" "codesign verification failed."
fi

verify_stage="sbom"
if ! jq -e . "$sbom_path" >/dev/null; then
	fail_verify "sbom_invalid" "SBOM is not valid JSON."
fi
if ! jq -e --arg name "VoidDisplay.app" 'tostring | contains($name)' "$sbom_path" >/dev/null; then
	fail_verify "sbom_missing_app" "SBOM does not reference VoidDisplay.app."
fi

if [[ "$REQUIRE_ATTESTATION" == "true" ]]; then
	require_command gh
	verify_stage="attestation"
	if ! gh attestation verify "$dmg_path" --repo "$REPOSITORY"; then
		fail_verify "attestation_failed" "DMG attestation verification failed."
	fi
	if ! gh attestation verify "$sha_path" --repo "$REPOSITORY"; then
		fail_verify "attestation_failed" "Checksum attestation verification failed."
	fi
	if ! gh attestation verify "$sbom_path" --repo "$REPOSITORY"; then
		fail_verify "attestation_failed" "SBOM attestation verification failed."
	fi
fi

write_verify_summary "passed" "passed" "Release asset verification passed."

info "Release asset verification passed for $LABEL."
info "Summary: $summary_path"
