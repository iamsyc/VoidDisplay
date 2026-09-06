#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"
# shellcheck source=scripts/lib/checkpoint.sh
source "$TOOL_ROOT/scripts/lib/checkpoint.sh"

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
require_command node git
source_fingerprint="$(source_tree_fingerprint)"
coverage_complete="false"
coverage_failed() {
	local status=$?
	trap - EXIT
	if [[ "$coverage_complete" != "true" ]]; then
		write_json_file "$OUT_DIR/coverage-summary.json" '{status: "failed", reason: "coverage_gate_failed"}' || true
	fi
	exit "$status"
}
trap coverage_failed EXIT
write_json_file "$OUT_DIR/coverage-summary.json" '{status: "running", reason: "in_progress"}'
coverage_dir="$ROOT_DIR/.build/debug/codecov"
rm -rf "$coverage_dir"
env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/unit.sh" \
	--enable-code-coverage YES \
	--swift-only \
	--out-dir "$OUT_DIR/unit"

require_source_tree_unchanged "$source_fingerprint" "coverage tests"
coverage_export="$coverage_dir/VoidDisplay.json"
baseline_dir="$ROOT_DIR/.ai-tmp/test-evidence/coverage"
mkdir -p "$baseline_dir"
if [[ ! -s "$coverage_export" ]] || ! node "$TOOL_ROOT/scripts/lib/coverage_report.mjs" \
	"$coverage_export" "$ROOT_DIR" "$baseline_dir/latest.json" "$OUT_DIR/coverage-report" "$(git rev-parse HEAD)" "$source_fingerprint"; then
	write_json_file "$OUT_DIR/coverage-summary.json" \
		'{status: "failed", reason: "coverage_report_failed"}'
	die "Coverage output is missing or invalid."
fi
require_source_tree_unchanged "$source_fingerprint" "coverage report"
write_json_file "$OUT_DIR/coverage-summary.json" \
	--arg coverage_dir "$coverage_dir" \
	--arg report_path "$OUT_DIR/coverage-report.json" \
	--arg baseline_revision "$(jq -r '.baseline_revision // ""' "$OUT_DIR/coverage-report.json")" \
	'{status: "passed", reason: "passed", coverage_dir: $coverage_dir, report_path: $report_path, baseline_revision: $baseline_revision}'
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	cat "$OUT_DIR/coverage-report.md" >>"$GITHUB_STEP_SUMMARY"
fi
cp "$OUT_DIR/coverage-report.json" "$baseline_dir/latest.$$.json"
mv "$baseline_dir/latest.$$.json" "$baseline_dir/latest.json"
coverage_complete="true"
info "Coverage gate passed."
info "Report: $OUT_DIR/coverage-report.md"
