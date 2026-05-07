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

cleanup() {
	if [[ -n "$device" ]]; then
		hdiutil detach "$device" -quiet >/dev/null 2>&1 || hdiutil detach "$device" -force -quiet >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

[[ -f "$dmg_path" ]] || die "Missing DMG: $dmg_path"
[[ -f "$sha_path" ]] || die "Missing checksum: $sha_path"
[[ -f "$sbom_path" ]] || die "Missing SBOM: $sbom_path"

(
	cd "$(dirname "$dmg_path")"
	shasum -a 256 -c "$(basename "$sha_path")"
)

attach_output="$(hdiutil attach -readonly -noverify -noautoopen "$dmg_path")"
device="$(printf '%s\n' "$attach_output" | awk '/^\/dev\// {print $1; exit}')"
mount_path="$(printf '%s\n' "$attach_output" | sed -n 's#.*\(/Volumes/.*\)$#\1#p' | tail -n 1)"

[[ -n "$device" && -n "$mount_path" ]] || die "Failed to mount DMG."

app_path="$mount_path/VoidDisplay.app"
[[ -d "$app_path" ]] || die "DMG does not contain VoidDisplay.app."

info_plist="$app_path/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
[[ "$bundle_id" == "com.developerchen.voiddisplay" ]] || die "Unexpected bundle id: $bundle_id"
[[ "v$version" == "$TAG" ]] || die "Version mismatch. Expected $TAG, got v$version"
validate_release_app_binaries "$app_path" "$ARCH"

codesign --verify --deep --strict --verbose=2 "$app_path"

jq -e . "$sbom_path" >/dev/null
if ! jq -e --arg name "VoidDisplay.app" 'tostring | contains($name)' "$sbom_path" >/dev/null; then
	die "SBOM does not reference VoidDisplay.app."
fi

if [[ "$REQUIRE_ATTESTATION" == "true" ]]; then
	require_command gh
	gh attestation verify "$dmg_path" --repo "$REPOSITORY"
	gh attestation verify "$sha_path" --repo "$REPOSITORY"
	gh attestation verify "$sbom_path" --repo "$REPOSITORY"
fi

dmg_name="$(basename "$dmg_path")"
sbom_name="$(basename "$sbom_path")"

jq -n \
	--arg status "passed" \
	--arg tag "$TAG" \
	--arg label "$LABEL" \
	--arg arch "$ARCH" \
	--arg bundle_id "$bundle_id" \
	--arg version "$version" \
	--arg dmg "$dmg_name" \
	--arg sbom "$sbom_name" \
	--arg attestation_required "$REQUIRE_ATTESTATION" \
	'{
    status: $status,
    tag: $tag,
    label: $label,
    arch: $arch,
    bundle_id: $bundle_id,
    version: $version,
    dmg: $dmg,
    sbom: $sbom,
    attestation_required: ($attestation_required == "true")
  }' >"$summary_path"

info "Release asset verification passed for $LABEL."
info "Summary: $summary_path"
