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

require_command git jq

RULES_PATH="$TOOL_ROOT/scripts/ci/classification-rules.json"
classification_categories=(
	code
	ui
	script
	product_code
	test_code
	ci_config
	release
	dependency_manifest
	tooling_config
	docs
)

[[ -f "$RULES_PATH" ]] || die "Missing classification rules: $RULES_PATH"
jq -e '.categories | type == "object"' "$RULES_PATH" >/dev/null || die "Invalid classification rules: $RULES_PATH"

for category in "${classification_categories[@]}"; do
	for key in exact prefixes globs; do
		var_name="CLASSIFY_RULES_${category}_${key}"
		values="$(jq -r --arg category "$category" --arg key "$key" '.categories[$category][$key][]?' "$RULES_PATH")"
		printf -v "$var_name" '%s' "$values"
	done
done

is_zero_sha() {
	[[ "$1" =~ ^0+$ ]]
}

rule_values() {
	local category="$1"
	local key="$2"
	local var_name="CLASSIFY_RULES_${category}_${key}"

	[[ -n "${!var_name:-}" ]] || return 0
	printf '%s\n' "${!var_name}"
}

path_matches_category() {
	local category="$1"
	local file_path="$2"
	local value

	while IFS= read -r value; do
		if [[ "$file_path" == "$value" ]]; then
			return 0
		fi
	done < <(rule_values "$category" exact)

	while IFS= read -r value; do
		if [[ "$file_path" == "$value"* ]]; then
			return 0
		fi
	done < <(rule_values "$category" prefixes)

	while IFS= read -r value; do
		# shellcheck disable=SC2053
		if [[ "$file_path" == $value ]]; then
			return 0
		fi
	done < <(rule_values "$category" globs)

	return 1
}

is_code_path() {
	path_matches_category code "$1"
}

is_ui_path() {
	path_matches_category ui "$1"
}

is_script_path() {
	path_matches_category script "$1"
}

is_product_code_path() {
	path_matches_category product_code "$1"
}

is_test_code_path() {
	path_matches_category test_code "$1"
}

is_ci_config_path() {
	path_matches_category ci_config "$1"
}

is_release_path() {
	path_matches_category release "$1"
}

is_dependency_manifest_path() {
	path_matches_category dependency_manifest "$1"
}

is_tooling_config_path() {
	path_matches_category tooling_config "$1"
}

is_docs_path() {
	path_matches_category docs "$1"
}

is_known_path() {
	local file_path="$1"
	local category

	for category in "${classification_categories[@]}"; do
		path_matches_category "$category" "$file_path" && return 0
	done
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
