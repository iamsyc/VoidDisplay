#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

forbidden="$({
	rg -n '\.(typeKey|typeText)\(' UITests --glob '*.swift' || true
	rg -n 'XCUIKeyboardKey|CGEvent|System Events|key code|keystroke' UITests --glob '*.swift' || true
})"
if [[ -n "$forbidden" ]]; then
	printf '%s\n' "$forbidden" >&2
	die "UI tests must inject focus or state without synthesizing keyboard input."
fi

test_count="$(rg -n '^[[:space:]]*func test' UITests/VoidDisplayUITests --glob '*.swift' | wc -l | tr -d ' ')"
[[ "$test_count" -gt 0 ]] || die "The UI target contains no test journeys."

while IFS= read -r selector; do
	class_name="$(cut -d/ -f2 <<<"$selector")"
	test_name="$(cut -d/ -f3 <<<"$selector")"
	[[ -n "$class_name" && -n "$test_name" ]] || continue
	rg -q "final class ${class_name}: XCTestCase" UITests/VoidDisplayUITests --glob '*.swift' ||
		die "Workflow UI selector references missing class: $selector"
	rg -q "func ${test_name}\\(" UITests/VoidDisplayUITests --glob '*.swift' ||
		die "Workflow UI selector references missing test: $selector"
done < <(rg --no-filename -o 'VoidDisplayUITests/[[:alnum:]_]+/test[[:alnum:]_]+' .github/workflows | sort -u)

info "Static UI test gate passed."
info "UI journeys: $test_count"
node --test "$TOOL_ROOT/scripts/ci/test_test_quality.mjs"
