#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

require_command actionlint rg awk sort node

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

assert_match() {
	local message="$1"
	shift

	rg -q "$@" || die "$message"
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
	assert_no_match "Read-only dependency review must not request PR comments." \
		'comment-summary-in-pr:[[:space:]]*(always|on-failure)' .github/workflows/ci.yml

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

validate_xcode_metadata_cache_contract() {
	local ui_workflow_files=(
		.github/workflows/_reusable-ui-smoke-tests.yml
		.github/workflows/nightly.yml
	)

	assert_no_match "UI Xcode metadata caches must not persist SwiftPM package checkouts." \
		'DerivedData/SourcePackages' "${ui_workflow_files[@]}"
	assert_no_match "UI Xcode metadata caches must not restore across dependency lock states." \
		'^[[:space:]]*restore-keys:' "${ui_workflow_files[@]}"
}

validate_ci_summary_comment_policy() {
	node scripts/ci/test_ci_summary_comment_policy.mjs
}

validate_release_publish_credentials() {
	local invalid

	invalid="$(
		awk '
			/^  publish_release:/ {
				in_job = 1
				next
			}
			in_job && /^  [[:alnum:]_]+:/ {
				exit
			}
			in_job && /-[[:space:]]+name:[[:space:]]+Checkout trusted release tools/ {
				checkout_kind = "trusted"
			}
			in_job && /-[[:space:]]+name:[[:space:]]+Checkout release target/ {
				checkout_kind = "target"
			}
			in_job && checkout_kind == "trusted" && /persist-credentials:[[:space:]]*true/ {
				saw_trusted_credentials = 1
			}
			in_job && checkout_kind == "target" && /persist-credentials:[[:space:]]*false/ {
				saw_target_isolation = 1
			}
			in_job && checkout_kind == "target" && /persist-credentials:[[:space:]]*true/ {
				print FILENAME ":" FNR ": release target checkout must not retain credentials"
			}
			END {
				if (!saw_trusted_credentials) {
					print FILENAME ": trusted publish checkout must persist credentials for authenticated tag fetch and push"
				}
				if (!saw_target_isolation) {
					print FILENAME ": release target checkout must disable persisted credentials"
				}
			}
		' .github/workflows/release.yml
	)"
	fail_on_output "Release publishing must isolate credentials from target source." "$invalid"
}

validate_release_automation_contract() {
	assert_no_match "Release recovery must not accept an arbitrary target ref." \
		'target_ref|TARGET_REF' .github/workflows/release.yml
	assert_match "Release recovery must accept only a semantic version tag." \
		'workflow_dispatch:' .github/workflows/release.yml
	assert_match "Release jobs must check out target source into an isolated directory." \
		'path:[[:space:]]*release-target' .github/workflows/release.yml
	assert_match "Release target resolution must enforce main ancestry." \
		'merge_base_commit.*targetSha' .github/workflows/release.yml
	assert_match "Release publishing must include generated change notes." \
		'releases/generate-notes' scripts/release/publish.sh
	assert_no_match "DMG creation must not depend on Finder automation or fixed layout waits." \
		'osascript|apply_dmg_layout|release_run_with_timeout' scripts/release/create_dmg.sh
	[[ -f scripts/release/assets/VoidDisplay-template.dmg ]] ||
		die "Deterministic DMG layout template is missing."
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

validate_release_ci_gate_timeout() {
	local classify_timeout_minutes
	local dependency_review_timeout_minutes
	local downstream_timeout_minutes=0
	local ci_gate_timeout_minutes
	local gate_job_timeout_minutes
	local gate_timeout_minutes
	local gate_timeout_seconds
	local job_timeout_minutes
	local post_classify_timeout_minutes
	local required_gate_timeout_minutes
	local script_static_timeout_minutes

	workflow_job_timeout_minutes() {
		local workflow_file="$1"
		local job_name="$2"

		awk -v job_name="$job_name" '
			$0 == "  " job_name ":" { inside = 1; next }
			inside && /^  [[:alnum:]_]+:/ { exit }
			inside && /timeout-minutes:/ { print $2; exit }
		' "$workflow_file"
	}

	classify_timeout_minutes="$(workflow_job_timeout_minutes .github/workflows/ci.yml classify_changes)"
	dependency_review_timeout_minutes="$(workflow_job_timeout_minutes .github/workflows/ci.yml dependency_review)"
	script_static_timeout_minutes="$(workflow_job_timeout_minutes .github/workflows/ci.yml script_static_checks)"
	ci_gate_timeout_minutes="$(workflow_job_timeout_minutes .github/workflows/ci.yml ci_gate)"
	for job_timeout_minutes in \
		"$(workflow_job_timeout_minutes .github/workflows/_reusable-unit-tests.yml unit_tests)" \
		"$(workflow_job_timeout_minutes .github/workflows/ci.yml xcode_build)" \
		"$(workflow_job_timeout_minutes .github/workflows/_reusable-ui-smoke-tests.yml ui_smoke_tests)" \
		"$(workflow_job_timeout_minutes .github/workflows/ci.yml release_build_check_arm64)" \
		"$(workflow_job_timeout_minutes .github/workflows/ci.yml release_build_check_intel64)"; do
		[[ "$job_timeout_minutes" =~ ^[0-9]+$ ]] || die "Every CI job on the ci-gate critical path must declare a positive integer timeout."
		((job_timeout_minutes > downstream_timeout_minutes)) && downstream_timeout_minutes="$job_timeout_minutes"
	done

	gate_job_timeout_minutes="$(
		awk '
			/^  require_ci_gate:/ { inside = 1; next }
			inside && /^  [[:alnum:]_]+:/ { exit }
			inside && /timeout-minutes:/ { print $2; exit }
		' .github/workflows/release.yml
	)"
	gate_timeout_seconds="$(
		awk '
			/^  require_ci_gate:/ { inside = 1; next }
			inside && /^  [[:alnum:]_]+:/ { exit }
			inside && /TIMEOUT_SECONDS:/ {
				value = $2
				gsub(/'\''/, "", value)
				print value
				exit
			}
		' .github/workflows/release.yml
	)"

	[[ "$classify_timeout_minutes" =~ ^[0-9]+$ ]] || die "CI classify job timeout must be a positive integer."
	[[ "$dependency_review_timeout_minutes" =~ ^[0-9]+$ ]] || die "CI dependency review timeout must be a positive integer."
	[[ "$script_static_timeout_minutes" =~ ^[0-9]+$ ]] || die "CI static job timeout must be a positive integer."
	[[ "$ci_gate_timeout_minutes" =~ ^[0-9]+$ ]] || die "CI gate timeout must be a positive integer."
	[[ "$gate_job_timeout_minutes" =~ ^[0-9]+$ ]] || die "Release ci-gate job timeout must be a positive integer."
	[[ "$gate_timeout_seconds" =~ ^[0-9]+$ ]] || die "Release ci-gate polling timeout must be a positive integer."
	((classify_timeout_minutes > 0)) || die "CI classify job timeout must be positive."
	((dependency_review_timeout_minutes > 0)) || die "CI dependency review timeout must be positive."
	((script_static_timeout_minutes > 0)) || die "CI static job timeout must be positive."
	((ci_gate_timeout_minutes > 0)) || die "CI gate timeout must be positive."
	((gate_job_timeout_minutes > 0)) || die "Release ci-gate job timeout must be positive."
	((gate_timeout_seconds > 0)) || die "Release ci-gate polling timeout must be positive."
	((gate_timeout_seconds % 60 == 0)) || die "Release ci-gate polling timeout must use whole minutes."

	gate_timeout_minutes=$((gate_timeout_seconds / 60))
	post_classify_timeout_minutes=$((script_static_timeout_minutes + downstream_timeout_minutes))
	if ((dependency_review_timeout_minutes > post_classify_timeout_minutes)); then
		post_classify_timeout_minutes="$dependency_review_timeout_minutes"
	fi
	required_gate_timeout_minutes=$((classify_timeout_minutes + post_classify_timeout_minutes + ci_gate_timeout_minutes + 15))
	((gate_timeout_minutes >= required_gate_timeout_minutes)) ||
		die "Release ci-gate polling timeout must cover the full CI critical path plus a 15-minute queue margin."
	((gate_job_timeout_minutes >= gate_timeout_minutes + 5)) ||
		die "Release ci-gate job timeout must leave at least 5 minutes for setup and summary upload."
}

actionlint
validate_runner_labels
validate_action_pinning
validate_workflow_script_contract
validate_xcode_metadata_cache_contract
validate_ci_summary_comment_policy
validate_release_publish_credentials
validate_release_automation_contract
validate_ui_smoke_artifact_summary
validate_release_ci_gate_timeout

info "Static workflow gate passed."
