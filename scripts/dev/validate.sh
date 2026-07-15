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

OUT_DIR="${OUT_DIR:-$(make_artifact_dir local-validation)}"
UI_SELECTOR="VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline"
RUN_UI_SMOKE="true"

host_arch="$(uname -m)"
case "$host_arch" in
arm64 | x86_64) DESTINATION="$(xcode_destination_for_arch "$host_arch")" ;;
*) die "Unsupported host architecture for local validation: $host_arch" ;;
esac

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
	--skip-ui-smoke)
		RUN_UI_SMOKE="false"
		shift
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

if [[ "$RUN_UI_SMOKE" == "true" ]]; then
	env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/ui_smoke.sh" \
		--only-testing "$UI_SELECTOR" \
		--destination "$DESTINATION" \
		--out-dir "$OUT_DIR/ui-smoke"
fi

write_json_file "$OUT_DIR/local-validation-summary.json" \
	--arg status "passed" \
	--arg out_dir "$OUT_DIR" \
	--arg destination "$DESTINATION" \
	--arg ui_selector "$UI_SELECTOR" \
	--argjson ui_smoke_enabled "$([[ "$RUN_UI_SMOKE" == "true" ]] && printf true || printf false)" \
	'{status: $status, out_dir: $out_dir, destination: $destination, ui_selector: $ui_selector, ui_smoke_enabled: $ui_smoke_enabled}'

info "Local validation gate passed."
info "Summary: $OUT_DIR/local-validation-summary.json"
