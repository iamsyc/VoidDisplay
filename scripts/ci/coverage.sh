#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

cd "$ROOT_DIR"

OUT_DIR="${OUT_DIR:-$(make_artifact_dir ci-coverage)}"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

mkdir -p "$OUT_DIR"
coverage_dir="$ROOT_DIR/.build/debug/codecov"
rm -rf "$coverage_dir"
env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/unit.sh" --enable-code-coverage YES --out-dir "$OUT_DIR/unit"

coverage_exists="false"
coverage_file_count="0"
if [[ -d "$coverage_dir" ]]; then
	coverage_exists="true"
	coverage_file_count="$(find "$coverage_dir" -type f | wc -l | tr -d ' ')"
fi

if [[ "$coverage_exists" != "true" || "$coverage_file_count" -eq 0 ]]; then
	write_json_file "$OUT_DIR/coverage-summary.json" \
		--arg status "failed" \
		--arg reason "coverage_output_missing" \
		--arg coverage_dir "$coverage_dir" \
		--arg coverage_exists "$coverage_exists" \
		--argjson coverage_file_count "$coverage_file_count" \
		'{status: $status, reason: $reason, coverage_dir: $coverage_dir, coverage_exists: ($coverage_exists == "true"), coverage_file_count: $coverage_file_count}'
	die "Coverage output was not produced."
fi

write_json_file "$OUT_DIR/coverage-summary.json" \
	--arg status "passed" \
	--arg reason "passed" \
	--arg coverage_dir "$coverage_dir" \
	--arg coverage_exists "$coverage_exists" \
	--argjson coverage_file_count "$coverage_file_count" \
	'{status: $status, reason: $reason, coverage_dir: $coverage_dir, coverage_exists: ($coverage_exists == "true"), coverage_file_count: $coverage_file_count}'

info "Coverage gate passed."
info "Summary: $OUT_DIR/coverage-summary.json"
