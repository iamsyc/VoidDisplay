#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

cd "$ROOT_DIR"

BASE_SHA=""
HEAD_SHA=""
GITHUB_OUTPUT_PATH="${GITHUB_OUTPUT:-}"
SUMMARY_PATH=""
EVENT_NAME="${EVENT_NAME:-}"
BASE_REF="${BASE_REF:-}"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--base)
		BASE_SHA="$2"
		shift 2
		;;
	--head)
		HEAD_SHA="$2"
		shift 2
		;;
	--github-output)
		GITHUB_OUTPUT_PATH="$2"
		shift 2
		;;
	--summary)
		SUMMARY_PATH="$(normalize_path "$2")"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

[[ -n "$BASE_SHA" ]] || die "--base is required."
[[ -n "$HEAD_SHA" ]] || die "--head is required."
SUMMARY_PATH="${SUMMARY_PATH:-$(make_artifact_dir classify)/classify-summary.json}"

legacy_code_prefixes=(
	Sources/
	Tests/
	UITests/
	Apps/VoidDisplay/
	Tools/VoidDisplayRelay/
	scripts/
	.github/workflows/
	.github/actions/
)
ui_prefixes=(
	UITests/
	Apps/VoidDisplay/
	Sources/VoidDisplayApp/
	Sources/VoidDisplayDesignSystem/
	Sources/VoidDisplayCapture/
	Sources/VoidDisplaySharing/
	Sources/VoidDisplaySupport/
	Sources/VoidDisplayVirtualDisplay/
)
legacy_script_prefixes=(
	scripts/
	.github/workflows/
	.github/actions/
)
legacy_exact_matches=(
	Package.swift
	Package.resolved
	mise.toml
	Brewfile
	.swiftformat
	.swiftlint.yml
	.github/dependabot.yml
)
legacy_script_exact_matches=(
	mise.toml
	Brewfile
	.swiftformat
	.swiftlint.yml
	.github/dependabot.yml
)
product_code_prefixes=(
	Sources/
	Apps/VoidDisplay/
	Tools/VoidDisplayRelay/
)
test_code_prefixes=(
	Tests/
	UITests/
)
ci_config_prefixes=(
	.github/workflows/
	.github/actions/
	scripts/ci/
	scripts/dev/
)
release_prefixes=(
	Apps/VoidDisplay/
	Tools/VoidDisplayRelay/
	scripts/release/
)
docs_prefixes=(
	docs/
	.github/PULL_REQUEST_TEMPLATE/
)
product_code_exact_matches=(
	Package.swift
	Package.resolved
)
ci_config_exact_matches=(
	.swiftformat
	.swiftlint.yml
	mise.toml
	Brewfile
	.github/dependabot.yml
)
release_exact_matches=(
	.github/workflows/release.yml
	scripts/lib/architecture.sh
	scripts/lib/release_binaries.sh
)
dependency_manifest_exact_matches=(
	Package.swift
	Package.resolved
	Tools/VoidDisplayRelay/go.mod
	Tools/VoidDisplayRelay/go.sum
)
tooling_config_exact_matches=(
	mise.toml
	Brewfile
	.swiftformat
	.swiftlint.yml
	.github/dependabot.yml
)
docs_exact_matches=(
	AGENTS.md
	LICENSE
	Readme.md
	README.md
)

is_zero_sha() {
	[[ "$1" =~ ^0+$ ]]
}

path_in_list() {
	local needle="$1"
	shift
	local value
	for value in "$@"; do
		if [[ "$needle" == "$value" ]]; then
			return 0
		fi
	done
	return 1
}

path_has_prefix() {
	local file_path="$1"
	shift
	local prefix
	for prefix in "$@"; do
		if [[ "$file_path" == "$prefix"* ]]; then
			return 0
		fi
	done
	return 1
}

is_code_path() {
	local file_path="$1"
	path_in_list "$file_path" "${legacy_exact_matches[@]}" && return 0
	path_has_prefix "$file_path" "${legacy_code_prefixes[@]}" && return 0
	[[ "$file_path" == */Package.resolved ]] && return 0
	return 1
}

is_ui_path() {
	local file_path="$1"
	path_has_prefix "$file_path" "${ui_prefixes[@]}"
}

is_script_path() {
	local file_path="$1"
	path_in_list "$file_path" "${legacy_script_exact_matches[@]}" && return 0
	path_has_prefix "$file_path" "${legacy_script_prefixes[@]}" && return 0
	return 1
}

is_product_code_path() {
	local file_path="$1"
	path_in_list "$file_path" "${product_code_exact_matches[@]}" && return 0
	path_has_prefix "$file_path" "${product_code_prefixes[@]}" && return 0
	[[ "$file_path" == */Package.resolved ]] && return 0
	return 1
}

is_test_code_path() {
	local file_path="$1"
	path_has_prefix "$file_path" "${test_code_prefixes[@]}"
}

is_ci_config_path() {
	local file_path="$1"
	path_in_list "$file_path" "${ci_config_exact_matches[@]}" && return 0
	path_has_prefix "$file_path" "${ci_config_prefixes[@]}" && return 0
	return 1
}

is_release_path() {
	local file_path="$1"
	path_in_list "$file_path" "${release_exact_matches[@]}" && return 0
	path_has_prefix "$file_path" "${release_prefixes[@]}" && return 0
	[[ "$file_path" == scripts/ci/release_*.sh ]] && return 0
	return 1
}

is_dependency_manifest_path() {
	local file_path="$1"
	path_in_list "$file_path" "${dependency_manifest_exact_matches[@]}" && return 0
	[[ "$file_path" == */Package.resolved ]] && return 0
	return 1
}

is_tooling_config_path() {
	local file_path="$1"
	path_in_list "$file_path" "${tooling_config_exact_matches[@]}"
}

is_docs_path() {
	local file_path="$1"
	path_in_list "$file_path" "${docs_exact_matches[@]}" && return 0
	path_has_prefix "$file_path" "${docs_prefixes[@]}" && return 0
	[[ "$file_path" == LICENSE_* ]] && return 0
	[[ "$file_path" == *.md ]] && return 0
	return 1
}

is_known_path() {
	local file_path="$1"
	is_code_path "$file_path" && return 0
	is_ui_path "$file_path" && return 0
	is_script_path "$file_path" && return 0
	is_product_code_path "$file_path" && return 0
	is_test_code_path "$file_path" && return 0
	is_ci_config_path "$file_path" && return 0
	is_release_path "$file_path" && return 0
	is_dependency_manifest_path "$file_path" && return 0
	is_tooling_config_path "$file_path" && return 0
	is_docs_path "$file_path" && return 0
	return 1
}

changed_files=()
changed_entry_status=()
changed_entry_old_path=()
changed_entry_new_path=()
classification_reason="diff"

append_changed_file() {
	local file_path="$1"
	if [[ -n "$file_path" ]]; then
		changed_files+=("$file_path")
	fi
}

append_changed_entry() {
	local status="$1"
	local old_path="$2"
	local new_path="${3:-}"

	changed_entry_status+=("$status")
	changed_entry_old_path+=("$old_path")
	changed_entry_new_path+=("$new_path")
	append_changed_file "$old_path"
	append_changed_file "$new_path"
}

collect_changed_entries() {
	local status
	local old_path
	local new_path

	while IFS= read -r -d '' status; do
		[[ -n "$status" ]] || continue
		case "$status" in
		R* | C*)
			IFS= read -r -d '' old_path || die "Malformed git diff name-status record for $status."
			IFS= read -r -d '' new_path || die "Malformed git diff name-status record for $status."
			append_changed_entry "$status" "$old_path" "$new_path"
			;;
		*)
			IFS= read -r -d '' old_path || die "Malformed git diff name-status record for $status."
			append_changed_entry "$status" "$old_path"
			;;
		esac
	done < <(git diff --name-status -z -M -C --find-copies-harder "$BASE_SHA" "$HEAD_SHA")
}

deduplicate_changed_files() {
	local unique_files=()
	local file_path

	if [[ "${#changed_files[@]}" -eq 0 ]]; then
		return 0
	fi

	while IFS= read -r file_path; do
		[[ -n "$file_path" ]] && unique_files+=("$file_path")
	done < <(printf '%s\n' "${changed_files[@]}" | sort -u)

	changed_files=("${unique_files[@]}")
}

if is_zero_sha "$BASE_SHA" || ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null || ! git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
	classification_reason="full_scan"
	code_relevant="true"
	ui_relevant="true"
	script_relevant="true"
	product_code_relevant="true"
	test_code_relevant="true"
	ci_config_relevant="true"
	release_relevant="true"
	dependency_manifest_relevant="true"
	tooling_config_relevant="true"
	docs_only="false"
	unknown_relevant="false"
else
	collect_changed_entries
	deduplicate_changed_files
	code_relevant="false"
	ui_relevant="false"
	script_relevant="false"
	product_code_relevant="false"
	test_code_relevant="false"
	ci_config_relevant="false"
	release_relevant="false"
	dependency_manifest_relevant="false"
	tooling_config_relevant="false"
	docs_only="false"
	unknown_relevant="false"
	if [[ "${#changed_files[@]}" -gt 0 ]]; then
		all_docs="true"
		for file_path in "${changed_files[@]}"; do
			if is_code_path "$file_path"; then
				code_relevant="true"
			fi
			if is_ui_path "$file_path"; then
				ui_relevant="true"
			fi
			if is_script_path "$file_path"; then
				script_relevant="true"
			fi
			if is_product_code_path "$file_path"; then
				product_code_relevant="true"
			fi
			if is_test_code_path "$file_path"; then
				test_code_relevant="true"
			fi
			if is_ci_config_path "$file_path"; then
				ci_config_relevant="true"
			fi
			if is_release_path "$file_path"; then
				release_relevant="true"
			fi
			if is_dependency_manifest_path "$file_path"; then
				dependency_manifest_relevant="true"
			fi
			if is_tooling_config_path "$file_path"; then
				tooling_config_relevant="true"
			fi
			if ! is_docs_path "$file_path"; then
				all_docs="false"
			fi
			if ! is_known_path "$file_path"; then
				unknown_relevant="true"
			fi
		done
		if [[ "$all_docs" == "true" ]]; then
			docs_only="true"
		fi
	fi
fi

change_scope="non_code"
if [[ "$code_relevant" == "true" && "$ui_relevant" == "true" ]]; then
	change_scope="ui_code"
elif [[ "$code_relevant" == "true" ]]; then
	change_scope="code"
fi

requires_static="false"
requires_head_script_self_test="false"
requires_dependency_review="false"
requires_unit="false"
requires_xcode_build="false"
requires_ui_smoke="false"
requires_release_smoke="false"

if [[ "$EVENT_NAME" == "push" ]]; then
	requires_static="true"
	requires_unit="true"
	requires_xcode_build="true"
	requires_ui_smoke="true"
	requires_release_smoke="true"
elif [[ "$docs_only" != "true" ]]; then
	if [[ "$code_relevant" == "true" || "$unknown_relevant" == "true" ]]; then
		requires_static="true"
	fi
	if [[ "$script_relevant" == "true" ]]; then
		requires_head_script_self_test="true"
	fi
	if [[ "$dependency_manifest_relevant" == "true" ]]; then
		requires_dependency_review="true"
	fi
	if [[ "$product_code_relevant" == "true" ||
		"$test_code_relevant" == "true" ||
		"$dependency_manifest_relevant" == "true" ||
		"$unknown_relevant" == "true" ]]; then
		requires_unit="true"
		requires_xcode_build="true"
	fi
	if [[ "$ui_relevant" == "true" ]]; then
		requires_ui_smoke="true"
	fi
	if [[ "$release_relevant" == "true" && "$BASE_REF" == "main" ]]; then
		requires_release_smoke="true"
	fi
fi

append_github_output code_relevant "$code_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output ui_relevant "$ui_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output script_relevant "$script_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output change_scope "$change_scope" "$GITHUB_OUTPUT_PATH"
append_github_output product_code_relevant "$product_code_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output test_code_relevant "$test_code_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output ci_config_relevant "$ci_config_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output release_relevant "$release_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output dependency_manifest_relevant "$dependency_manifest_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output tooling_config_relevant "$tooling_config_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output docs_only "$docs_only" "$GITHUB_OUTPUT_PATH"
append_github_output unknown_relevant "$unknown_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output requires_static "$requires_static" "$GITHUB_OUTPUT_PATH"
append_github_output requires_head_script_self_test "$requires_head_script_self_test" "$GITHUB_OUTPUT_PATH"
append_github_output requires_dependency_review "$requires_dependency_review" "$GITHUB_OUTPUT_PATH"
append_github_output requires_unit "$requires_unit" "$GITHUB_OUTPUT_PATH"
append_github_output requires_xcode_build "$requires_xcode_build" "$GITHUB_OUTPUT_PATH"
append_github_output requires_ui_smoke "$requires_ui_smoke" "$GITHUB_OUTPUT_PATH"
append_github_output requires_release_smoke "$requires_release_smoke" "$GITHUB_OUTPUT_PATH"

if [[ "${#changed_files[@]}" -gt 0 ]]; then
	changed_files_json="$(printf '%s\n' "${changed_files[@]}" | jq -R . | jq -s .)"
else
	changed_files_json="[]"
fi

if [[ "${#changed_entry_status[@]}" -gt 0 ]]; then
	changed_entries_json="$(
		for index in "${!changed_entry_status[@]}"; do
			jq -n \
				--arg status "${changed_entry_status[$index]}" \
				--arg old_path "${changed_entry_old_path[$index]}" \
				--arg new_path "${changed_entry_new_path[$index]}" \
				'{status: $status, old_path: $old_path, new_path: (if $new_path == "" then null else $new_path end)}'
		done | jq -s .
	)"
else
	changed_entries_json="[]"
fi

write_json_file "$SUMMARY_PATH" \
	--arg base "$BASE_SHA" \
	--arg head "$HEAD_SHA" \
	--arg code_relevant "$code_relevant" \
	--arg ui_relevant "$ui_relevant" \
	--arg script_relevant "$script_relevant" \
	--arg product_code_relevant "$product_code_relevant" \
	--arg test_code_relevant "$test_code_relevant" \
	--arg ci_config_relevant "$ci_config_relevant" \
	--arg release_relevant "$release_relevant" \
	--arg dependency_manifest_relevant "$dependency_manifest_relevant" \
	--arg tooling_config_relevant "$tooling_config_relevant" \
	--arg docs_only "$docs_only" \
	--arg unknown_relevant "$unknown_relevant" \
	--arg requires_static "$requires_static" \
	--arg requires_head_script_self_test "$requires_head_script_self_test" \
	--arg requires_dependency_review "$requires_dependency_review" \
	--arg requires_unit "$requires_unit" \
	--arg requires_xcode_build "$requires_xcode_build" \
	--arg requires_ui_smoke "$requires_ui_smoke" \
	--arg requires_release_smoke "$requires_release_smoke" \
	--arg change_scope "$change_scope" \
	--arg reason "$classification_reason" \
	--argjson changed_files "$changed_files_json" \
	--argjson changed_entries "$changed_entries_json" \
	'{
	  base: $base,
	  head: $head,
		  code_relevant: ($code_relevant == "true"),
		  ui_relevant: ($ui_relevant == "true"),
		  script_relevant: ($script_relevant == "true"),
		  product_code_relevant: ($product_code_relevant == "true"),
		  test_code_relevant: ($test_code_relevant == "true"),
		  ci_config_relevant: ($ci_config_relevant == "true"),
		  release_relevant: ($release_relevant == "true"),
		  dependency_manifest_relevant: ($dependency_manifest_relevant == "true"),
		  tooling_config_relevant: ($tooling_config_relevant == "true"),
		  docs_only: ($docs_only == "true"),
		  unknown_relevant: ($unknown_relevant == "true"),
		  requires_static: ($requires_static == "true"),
		  requires_head_script_self_test: ($requires_head_script_self_test == "true"),
		  requires_dependency_review: ($requires_dependency_review == "true"),
		  requires_unit: ($requires_unit == "true"),
		  requires_xcode_build: ($requires_xcode_build == "true"),
		  requires_ui_smoke: ($requires_ui_smoke == "true"),
		  requires_release_smoke: ($requires_release_smoke == "true"),
		  change_scope: $change_scope,
	  reason: $reason,
	  changed_files: $changed_files,
	  changed_entries: $changed_entries
	}'

info "Change scope: $change_scope code_relevant=$code_relevant ui_relevant=$ui_relevant requires_unit=$requires_unit requires_xcode_build=$requires_xcode_build"
info "Classification summary: $SUMMARY_PATH"
