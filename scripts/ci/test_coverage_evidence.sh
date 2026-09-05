#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

require_command git jq node mktemp
mkdir -p "$AI_TMP_DIR"
fixture="$(mktemp -d "$AI_TMP_DIR/coverage-evidence.XXXXXX")"
fixture_alias="$fixture-alias"
trap 'rm -rf "$fixture"; rm -f "$fixture_alias"' EXIT
mkdir -p "$fixture/scripts/ci" "$fixture/scripts/lib" "$fixture/Sources/Example"
for helper in common artifacts checkpoint; do
	cp "$TOOL_ROOT/scripts/lib/$helper.sh" "$fixture/scripts/lib/$helper.sh"
done
cp "$TOOL_ROOT/scripts/lib/"{source_fingerprint,coverage_report}.mjs "$fixture/scripts/lib/"
printf '.ai-tmp/\n.build/\n' >"$fixture/.gitignore"
printf 'original\n' >"$fixture/Sources/Example/Example.swift"
cat >"$fixture/scripts/ci/unit.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$COVERAGE_FIXTURE_MODE" != "failed" ]] || exit 1
mkdir -p "$ROOT_DIR/.build/debug/codecov"
jq -n --arg filename "$(cd "$ROOT_DIR" && pwd -P)/Sources/Example/Example.swift" \
  '{type:"llvm.coverage.json.export",data:[{files:[{filename:$filename,summary:{lines:{count:2,covered:1},functions:{count:1,covered:1},regions:{count:2,covered:1}},segments:[]}]}]}' \
  >"$ROOT_DIR/.build/debug/codecov/VoidDisplay.json"
if [[ "$COVERAGE_FIXTURE_MODE" == "drift" ]]; then
  printf 'edited during coverage\n' >"$ROOT_DIR/Sources/Example/Example.swift"
fi
STUB
chmod +x "$fixture/scripts/ci/unit.sh"
git -C "$fixture" init -q
git -C "$fixture" add .
git -C "$fixture" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
run_coverage() {
	env -u TOOL_ROOT GITHUB_ACTIONS=false ROOT_DIR="${COVERAGE_FIXTURE_ROOT:-$fixture}" COVERAGE_FIXTURE_MODE="$1" \
		"$TOOL_ROOT/scripts/ci/coverage.sh" --out-dir "$fixture/.ai-tmp/output"
}
# The first invocation must generate a report through the default aliased TOOL_ROOT.
ln -s "$fixture" "$fixture_alias"
for node_options in "" "--preserve-symlinks-main"; do
	rm -rf "$fixture/.ai-tmp/output"
	NODE_OPTIONS="$node_options" COVERAGE_FIXTURE_ROOT="$fixture_alias" run_coverage passed
	jq -e '.modules.Example.lines.percent == 50 and .files[0].path == "Sources/Example/Example.swift"' \
		"$fixture/.ai-tmp/output/coverage-report.json" >/dev/null || die "Coverage omitted sources under a symlinked repository root."
done
run_coverage passed
baseline="$fixture/.ai-tmp/test-evidence/coverage/latest.json"
jq -e '.modules.Example.lines.percent == 50 and (.source_fingerprint | length > 0)' "$baseline" >/dev/null
cp "$baseline" "$fixture/.ai-tmp/baseline-before.json"
for failure in failed drift; do
	if run_coverage "$failure" >"$fixture/.ai-tmp/$failure.log" 2>&1; then
		die "Coverage gate accepted $failure evidence."
	fi
	jq -e '.status == "failed"' "$fixture/.ai-tmp/output/coverage-summary.json" >/dev/null ||
		die "Coverage failure left a passing summary."
	cmp -s "$baseline" "$fixture/.ai-tmp/baseline-before.json" ||
		die "Coverage failure replaced the previous baseline."
done
info "Coverage evidence lifecycle contract passed."
