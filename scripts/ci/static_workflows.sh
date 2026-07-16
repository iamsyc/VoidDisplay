#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

require_command actionlint rg awk sort

fail_on_output() {
	local message="$1"
	local output="$2"

	if [[ -n "$output" ]]; then
		printf '%s\n' "$output" >&2
		die "$message"
	fi
}

assert_no_match() {
	local message="$1"
	shift

	fail_on_output "$message" "$(rg -n "$@" || true)"
}

validate_runner_labels() {
	assert_no_match "Workflow uses a non-macOS, paid, or larger runner label." \
		'(runs-on|runs_on):[[:space:]]*(ubuntu-|windows-|macos-latest-large|.*-large)' .github/workflows .github/actions
}

validate_action_pinning() {
	local failures=()
	local line
	local file
	local line_number
	local value
	local action_ref

	while IFS= read -r line; do
		file="${line%%:*}"
		line="${line#*:}"
		line_number="${line%%:*}"
		value="${line#*:}"
		value="${value#*uses:}"
		value="${value%%#*}"
		value="$(printf '%s' "$value" | tr -d "'\"" | xargs)"

		[[ -n "$value" ]] || continue
		[[ "$value" == ./* ]] && continue
		[[ "$value" == docker://* ]] && continue

		action_ref="${value##*@}"
		if [[ ! "$value" =~ @ || ! "$action_ref" =~ ^[0-9a-f]{40}$ ]]; then
			failures+=("$file:$line_number uses unpinned action reference: $value")
		fi
	done < <(rg -n '^[[:space:]]*uses:[[:space:]]*[^[:space:]]+' .github/workflows .github/actions)

	if [[ "${#failures[@]}" -gt 0 ]]; then
		printf '%s\n' "${failures[@]}" >&2
		die "All external GitHub Actions must be pinned to a 40-character commit SHA."
	fi
}

validate_workflow_script_contract() {
	local invalid
	local workflow_files=()
	local pr_ci_workflow_files=(
		.github/workflows/ci.yml
		.github/workflows/_reusable-unit-tests.yml
		.github/workflows/_reusable-ui-smoke-tests.yml
	)

	while IFS= read -r workflow_file; do
		workflow_files+=("$workflow_file")
	done < <(find .github/workflows .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort)

	assert_no_match "Workflow script invocations must execute scripts through TOOL_ROOT." \
		'\$GITHUB_WORKSPACE/scripts/' .github/workflows .github/actions

	invalid="$(awk '/scripts\// && $0 !~ /^[[:space:]]*- '\''scripts\// && $0 !~ /"\$tool_root\/scripts\// { print FILENAME ":" FNR ":" $0 }' "${workflow_files[@]}" || true)"
	fail_on_output "Workflow script references must be path filters or TOOL_ROOT executions." "$invalid"

	invalid="$(rg -n 'ROOT_DIR=.*scripts/' .github/workflows .github/actions | rg -v 'TOOL_ROOT=.*"\$tool_root/scripts/' || true)"
	fail_on_output "Workflow script invocations must pass ROOT_DIR and TOOL_ROOT and execute through TOOL_ROOT." "$invalid"
	assert_no_match "PR CI workflows must not expose GITHUB_TOKEN to checked-out repository scripts." \
		'GITHUB_TOKEN:[[:space:]]*\$\{\{[[:space:]]*github\.token[[:space:]]*\}\}' "${pr_ci_workflow_files[@]}"

	invalid="$(
		awk '
			function finish_checkout() {
				if (checkout_line && !saw_persist_credentials) {
					print current_file ":" checkout_line ":actions/checkout must set persist-credentials: false"
				}
			}
			FNR == 1 {
				finish_checkout()
				current_file = FILENAME
				saw_persist_credentials = 0
				checkout_line = 0
			}
			/^[[:space:]]*-[[:space:]]+(name|uses):/ {
				finish_checkout()
				saw_persist_credentials = 0
				checkout_line = 0
			}
			/uses:[[:space:]]*actions\/checkout@/ {
				saw_persist_credentials = 0
				checkout_line = FNR
			}
			checkout_line && /persist-credentials:[[:space:]]*false/ {
				saw_persist_credentials = 1
			}
			END {
				finish_checkout()
			}
		' "${pr_ci_workflow_files[@]}" || true
	)"
	fail_on_output "PR CI checkouts must disable persisted credentials." "$invalid"
}

validate_ui_smoke_artifact_summary() {
	local actual
	local expected

	expected="$(
		awk '
			/^  ui_smoke_tests:/ { in_job = 1; next }
			in_job && /^  [[:alnum:]_]+:/ { exit }
			in_job && /-[[:space:]]+case_name:/ { print "ui-smoke-" $3 }
		' .github/workflows/ci.yml | sort
	)"
	actual="$(
		rg 'Artifacts: ui-smoke-' .github/workflows/ci.yml |
			rg -o 'ui-smoke-[[:alnum:]_-]+' |
			sort
	)"

	if [[ "$actual" != "$expected" ]]; then
		printf 'Expected UI smoke artifacts:\n%s\n' "$expected" >&2
		printf 'Declared UI smoke artifacts:\n%s\n' "$actual" >&2
		die "PR UI smoke matrix and artifact summary must stay synchronized."
	fi
}

actionlint
validate_runner_labels
validate_action_pinning
validate_workflow_script_contract
validate_ui_smoke_artifact_summary

info "Static workflow gate passed."
