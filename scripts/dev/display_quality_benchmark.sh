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
# shellcheck source=scripts/lib/xcode.sh
source "$TOOL_ROOT/scripts/lib/xcode.sh"

cd "$ROOT_DIR"
if [[ "${1:-}" == "--help" ]]; then
	cat <<'USAGE'
Usage: scripts/dev/display_quality_benchmark.sh [options]
  --size 1080p|4k|5k  --fps 30|60  --warmup 0...30
  --seconds 1...120   --rounds 1...5  --output <fresh-directory>
Defaults: 4k, 60 FPS, 3 s warmup, 10 s samples, 3 rounds.
Synthetic encoder/quality experiment; does not measure capture-to-photon.
USAGE
	exit 0
fi
require_command swift git jq shasum rg node
require_xcode_build_environment
OUT_DIR="$AI_TMP_DIR/display-quality/$(timestamp)-$$"
arguments=()
while [[ $# -gt 0 ]]; do
	if [[ "$1" == "--output" ]]; then
		[[ $# -ge 2 ]] || die "--output requires a directory"
		OUT_DIR="$(normalize_path "$2")"
		shift 2
	else
		arguments+=("$1")
		shift
	fi
done
mkdir -p "$(dirname "$OUT_DIR")"
mkdir "$OUT_DIR" || die "Use a fresh output directory; partial evidence must also be preserved."
source_fingerprint="$(source_tree_fingerprint)"
validation_status="failed"
validation_phase="environment"
finish_validation() {
	local exit_status=$?
	trap - EXIT
	write_json_file "$OUT_DIR/validation.json" \
		--arg status "$validation_status" --arg phase "$validation_phase" \
		--arg source_fingerprint "$source_fingerprint" \
		'{status: $status, phase: $phase, source_fingerprint: $source_fingerprint}'
	exit "$exit_status"
}
trap finish_validation EXIT
{
	git rev-parse HEAD
	swift --version
	xcodebuild -version
	sw_vers
	uname -m
	sysctl -n machdep.cpu.brand_string
} >"$OUT_DIR/environment.txt"

validation_phase="build"
swift build -c release --product DisplayQualityBenchmark >"$OUT_DIR/build.log" 2>&1
diagnostics="$(collect_build_log_diagnostics "$OUT_DIR/build.log")"
[[ -z "$diagnostics" ]] || die "Benchmark compiler diagnostics: $diagnostics"
require_source_tree_unchanged "$source_fingerprint" "benchmark build"
bin_dir="$(swift build -c release --show-bin-path)"
export VOIDDISPLAY_BENCHMARK_SOURCE_FINGERPRINT="$source_fingerprint"
validation_phase="measurement"
"$bin_dir/DisplayQualityBenchmark" "${arguments[@]}" --output "$OUT_DIR/results" | tee "$OUT_DIR/run.log"
validation_phase="source_validation"
require_source_tree_unchanged "$source_fingerprint" "benchmark measurement"
validation_status="passed"
validation_phase="complete"
info "Encoder-only evidence: $OUT_DIR/results/benchmark.json"
