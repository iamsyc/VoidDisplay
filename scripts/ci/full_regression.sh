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

OUT_DIR="${OUT_DIR:-$(make_artifact_dir full-regression)}"
DESTINATION="${DESTINATION:-$(xcode_destination_for_arch arm64)}"
UI_SELECTOR="${UI_SELECTOR:-VoidDisplayUITests}"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
		shift 2
		;;
	--destination)
		DESTINATION="$2"
		shift 2
		;;
	--ui-selector)
		UI_SELECTOR="$2"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

mkdir -p "$OUT_DIR"

env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/static.sh"
env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/unit.sh" --out-dir "$OUT_DIR/unit"
env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/xcode.sh" \
	--action build \
	--configuration Debug \
	--destination "$DESTINATION" \
	--out-dir "$OUT_DIR/xcode-build"
env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/xcode.sh" \
	--action test \
	--configuration Debug \
	--destination "$DESTINATION" \
	--only-testing "$UI_SELECTOR" \
	--out-dir "$OUT_DIR/xcode-test"
env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/stability.sh" \
	--iterations "${STABILITY_ITERATIONS:-20}" \
	--out-dir "$OUT_DIR/stability"
env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/release_smoke.sh" \
	--arch arm64 \
	--label arm64 \
	--out-dir "$OUT_DIR/release-smoke-arm64"

write_json_file "$OUT_DIR/full-regression-summary.json" \
	--arg status "passed" \
	--arg destination "$DESTINATION" \
	--arg ui_selector "$UI_SELECTOR" \
	--arg out_dir "$OUT_DIR" \
	'{status: $status, destination: $destination, ui_selector: $ui_selector, out_dir: $out_dir}'

info "Full regression gate passed."
info "Summary: $OUT_DIR/full-regression-summary.json"
