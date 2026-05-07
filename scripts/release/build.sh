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

app_output="$OUT_DIR/app-path.txt"
env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/release_smoke.sh" \
	--arch "$ARCH" \
	--label "$LABEL" \
	--out-dir "$OUT_DIR/smoke" \
	--app-output-file "$app_output"

app_path="$(cat "$app_output")"
[[ -d "$app_path" ]] || die "Expected app not found: $app_path"

dmg_name="VoidDisplay-${TAG}-${LABEL}.dmg"
dmg_path="$OUT_DIR/release-assets/$dmg_name"
sbom_path="$OUT_DIR/release-assets/$dmg_name.spdx.json"
summary_path="$OUT_DIR/release-assets/$dmg_name.summary.json"

env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/release/create_dmg.sh" "$app_path" "$dmg_path" "VoidDisplay"
(
	cd "$OUT_DIR/release-assets"
	shasum -a 256 "$dmg_name" >"$dmg_name.sha256"
)
checksum="$(sha256_digest "$dmg_path")"
SYFT_CHECK_FOR_APP_UPDATE=false syft "$app_path" \
	--source-name "VoidDisplay.app" \
	--source-version "${TAG#v}" \
	-o "spdx-json=$sbom_path"

jq -n \
	--arg tag "$TAG" \
	--arg arch "$ARCH" \
	--arg label "$LABEL" \
	--arg dmg "$dmg_name" \
	--arg checksum "$dmg_name.sha256" \
	--arg sha256 "$checksum" \
	--arg sbom "$(basename "$sbom_path")" \
	'{tag: $tag, arch: $arch, label: $label, dmg: $dmg, checksum: $checksum, sha256: $sha256, sbom: $sbom}' \
	>"$summary_path"

info "Release assets created under $OUT_DIR/release-assets."
