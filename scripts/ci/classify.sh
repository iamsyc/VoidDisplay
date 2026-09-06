#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
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
classification_categories=(code ui script product_code test_code ci_config release dependency_manifest tooling_config docs)
relevant_flags=()
for category in "${classification_categories[@]}"; do
	[[ "$category" == "docs" ]] || relevant_flags+=("${category}_relevant")
done
classification_flags=("${relevant_flags[@]}" docs_only unknown_relevant)
requirement_flags=(
	requires_static
	requires_dependency_review
	requires_unit
	requires_xcode_build
	requires_ui_smoke
	requires_release_smoke
)
push_required_flags=(
	requires_static
	requires_unit
	requires_xcode_build
	requires_ui_smoke
	requires_release_smoke
)
output_fields=("${classification_flags[@]:0:3}" change_scope "${classification_flags[@]:3}" "${requirement_flags[@]}")

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

changed_files=()
changed_entry_json_items=()
classification_reason="diff"

set_flags() {
	local value="$1"
	local flag
	shift

	for flag in "$@"; do
		printf -v "$flag" '%s' "$value"
	done
}

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

	changed_entry_json_items+=("$(jq -cn \
		--arg status "$status" \
		--arg old_path "$old_path" \
		--arg new_path "$new_path" \
		'{status: $status, old_path: $old_path, new_path: (if $new_path == "" then null else $new_path end)}')")
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
	set_flags true "${relevant_flags[@]}"
	docs_only="false"
	unknown_relevant="false"
else
	collect_changed_entries
	deduplicate_changed_files
	set_flags false "${classification_flags[@]}"
	if [[ "${#changed_files[@]}" -gt 0 ]]; then
		all_docs="true"
		for file_path in "${changed_files[@]}"; do
			matched_any="false"
			file_docs="false"
			for category in "${classification_categories[@]}"; do
				if path_matches_category "$category" "$file_path"; then
					matched_any="true"
					if [[ "$category" == "docs" ]]; then
						file_docs="true"
					else
						printf -v "${category}_relevant" '%s' true
					fi
				fi
			done
			if [[ "$file_docs" != "true" ]]; then
				all_docs="false"
			fi
			if [[ "$matched_any" != "true" ]]; then
				unknown_relevant="true"
			fi
		done
		[[ "$all_docs" == "true" ]] && docs_only="true"
	fi
fi

change_scope="non_code"
if [[ "$code_relevant" == "true" && "$ui_relevant" == "true" ]]; then
	change_scope="ui_code"
elif [[ "$code_relevant" == "true" ]]; then
	change_scope="code"
fi

set_flags false "${requirement_flags[@]}"

if [[ "$EVENT_NAME" == "push" ]]; then
	set_flags true "${push_required_flags[@]}"
elif [[ "$EVENT_NAME" == "pull_request" ]]; then
	requires_static="true"
	requires_unit="true"
	requires_xcode_build="true"
	if [[ "$dependency_manifest_relevant" == "true" ]]; then
		requires_dependency_review="true"
	fi
	if [[ "$ui_relevant" == "true" || "$unknown_relevant" == "true" || "$script_relevant" == "true" || "$dependency_manifest_relevant" == "true" ]]; then
		requires_ui_smoke="true"
	fi
	if [[ "$release_relevant" == "true" && "$BASE_REF" == "main" ]]; then
		requires_release_smoke="true"
	fi
elif [[ "$docs_only" != "true" ]]; then
	requires_static="true"
	requires_unit="true"
	requires_xcode_build="true"
fi

for field in "${output_fields[@]}"; do
	append_github_output "$field" "${!field}" "$GITHUB_OUTPUT_PATH"
done

if [[ "${#changed_files[@]}" -gt 0 ]]; then
	changed_files_json="$(printf '%s\n' "${changed_files[@]}" | jq -R . | jq -s .)"
else
	changed_files_json="[]"
fi

if [[ "${#changed_entry_json_items[@]}" -gt 0 ]]; then
	changed_entries_json="$(printf '%s\n' "${changed_entry_json_items[@]}" | jq -s .)"
else
	changed_entries_json="[]"
fi

summary_flags_json="$(
	for field in "${classification_flags[@]}" "${requirement_flags[@]}"; do
		jq -n --arg field "$field" --arg value "${!field}" '{($field): ($value == "true")}'
	done | jq -s add
)"

ui_selectors_json='[]'
if [[ "$requires_ui_smoke" == "true" ]]; then
	ui_selectors_json="$(node "$TOOL_ROOT/scripts/lib/ui_test_selection.mjs" "$ROOT_DIR" "$changed_files_json")"
fi
append_github_output ui_selectors_json "$ui_selectors_json" "$GITHUB_OUTPUT_PATH"

write_json_file "$SUMMARY_PATH" \
	--arg base "$BASE_SHA" \
	--arg head "$HEAD_SHA" \
	--arg change_scope "$change_scope" \
	--arg reason "$classification_reason" \
	--argjson flags "$summary_flags_json" \
	--argjson changed_files "$changed_files_json" \
	--argjson changed_entries "$changed_entries_json" \
	--argjson ui_selectors "$ui_selectors_json" \
	'{
	  base: $base,
	  head: $head,
	  change_scope: $change_scope,
	  reason: $reason,
	  changed_files: $changed_files,
	  changed_entries: $changed_entries,
	  ui_selectors: $ui_selectors
	} + $flags'

info "Change scope: $change_scope code_relevant=$code_relevant ui_relevant=$ui_relevant requires_unit=$requires_unit requires_xcode_build=$requires_xcode_build"
info "Classification summary: $SUMMARY_PATH"
