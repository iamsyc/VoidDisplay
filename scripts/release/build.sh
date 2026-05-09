#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/architecture.sh
source "$TOOL_ROOT/scripts/lib/architecture.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

cd "$ROOT_DIR"

TAG=""
ARCH=""
LABEL=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--tag)
		TAG="$2"
		shift 2
		;;
	--arch)
		ARCH="$2"
		shift 2
		;;
	--label)
		LABEL="$2"
		shift 2
		;;
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--tag must match vMAJOR.MINOR.PATCH."
[[ -n "$ARCH" ]] || die "--arch is required."
validate_release_arch "$ARCH"
LABEL="${LABEL:-$(release_label_for_arch "$ARCH")}"
require_release_label_for_arch "$ARCH" "$LABEL"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/.ai-tmp/release-$LABEL}"

require_command syft jq

mkdir -p "$OUT_DIR/release-assets"

dmg_name="VoidDisplay-${TAG}-${LABEL}.dmg"
dmg_path="$OUT_DIR/release-assets/$dmg_name"
sbom_path="$OUT_DIR/release-assets/$dmg_name.spdx.json"
summary_path="$OUT_DIR/release-assets/$dmg_name.summary.json"
dmg_summary_path="$OUT_DIR/release-assets/$dmg_name.create-dmg-summary.json"
release_stage="initialization"
checksum=""
release_summary_written="false"

write_release_build_summary() {
	local status="$1"
	local reason="$2"
	local detail="$3"

	write_json_file "$summary_path" \
		--arg status "$status" \
		--arg reason "$reason" \
		--arg detail "$detail" \
		--arg tag "$TAG" \
		--arg arch "$ARCH" \
		--arg label "$LABEL" \
		--arg dmg "$dmg_name" \
		--arg checksum "$dmg_name.sha256" \
		--arg sha256 "${checksum:-}" \
		--arg sbom "$(basename "$sbom_path")" \
		--arg signing "ad_hoc" \
		'{status: $status, reason: $reason, detail: $detail, tag: $tag, arch: $arch, label: $label, dmg: $dmg, checksum: $checksum, sha256: $sha256, sbom: $sbom, signing: $signing}'
	release_summary_written="true"
}

handle_unexpected_release_error() {
	local exit_code="$1"
	local line_number="$2"

	trap - ERR
	if [[ ! -f "$summary_path" ]]; then
		write_release_build_summary "failed" "${release_stage}_failed" "Release build failed unexpectedly at line ${line_number}."
	fi
	exit "$exit_code"
}

handle_release_exit() {
	local exit_code="$?"

	if [[ "$exit_code" -ne 0 && "$release_summary_written" != "true" ]]; then
		write_release_build_summary "failed" "${release_stage}_failed" "Release build failed in stage ${release_stage}."
	fi
}

trap 'handle_unexpected_release_error $? $LINENO' ERR
trap handle_release_exit EXIT

app_output="$OUT_DIR/app-path.txt"
release_stage="release_smoke"
env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/release_smoke.sh" \
	--arch "$ARCH" \
	--label "$LABEL" \
	--out-dir "$OUT_DIR/smoke" \
	--app-output-file "$app_output"

release_stage="locate_app"
app_path="$(cat "$app_output")"
[[ -d "$app_path" ]] || die "Expected app not found: $app_path"

release_stage="create_dmg"
if ! env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/release/create_dmg.sh" \
	--summary "$dmg_summary_path" \
	"$app_path" \
	"$dmg_path" \
	"VoidDisplay"; then
	dmg_reason="$(jq -r '.reason // "dmg_failed"' "$dmg_summary_path" 2>/dev/null || printf 'dmg_failed\n')"
	write_release_build_summary "failed" "$dmg_reason" "DMG creation failed. See $(basename "$dmg_summary_path")."
	die "DMG creation failed: $dmg_reason"
fi

release_stage="checksum"
if ! (
	cd "$OUT_DIR/release-assets"
	shasum -a 256 "$dmg_name" >"$dmg_name.sha256"
); then
	write_release_build_summary "failed" "checksum_failed" "Failed to write SHA256 checksum."
	die "Failed to write SHA256 checksum."
fi

if ! checksum="$(sha256_digest "$dmg_path")"; then
	write_release_build_summary "failed" "checksum_failed" "Failed to compute SHA256 checksum."
	die "Failed to compute SHA256 checksum."
fi

release_stage="sbom"
if ! SYFT_CHECK_FOR_APP_UPDATE=false syft "$app_path" \
	--source-name "VoidDisplay.app" \
	--source-version "${TAG#v}" \
	-o "spdx-json=$sbom_path"; then
	write_release_build_summary "failed" "sbom_failed" "Failed to generate SPDX SBOM."
	die "Failed to generate SPDX SBOM."
fi

jq -n \
	--arg status "passed" \
	--arg reason "passed" \
	--arg tag "$TAG" \
	--arg arch "$ARCH" \
	--arg label "$LABEL" \
	--arg dmg "$dmg_name" \
	--arg checksum "$dmg_name.sha256" \
	--arg sha256 "$checksum" \
	--arg sbom "$(basename "$sbom_path")" \
	--arg signing "ad_hoc" \
	'{status: $status, reason: $reason, tag: $tag, arch: $arch, label: $label, dmg: $dmg, checksum: $checksum, sha256: $sha256, sbom: $sbom, signing: $signing}' \
	>"$summary_path"

info "Release assets created under $OUT_DIR/release-assets."
