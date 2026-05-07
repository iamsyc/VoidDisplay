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

code_prefixes=(
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
exact_matches=(
	Package.swift
	Package.resolved
	mise.toml
	Brewfile
	.swiftformat
	.swiftlint.yml
	.github/dependabot.yml
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
	path_in_list "$file_path" "${exact_matches[@]}" && return 0
	path_has_prefix "$file_path" "${code_prefixes[@]}" && return 0
	[[ "$file_path" == */Package.resolved ]] && return 0
	return 1
}

is_ui_path() {
	local file_path="$1"
	path_has_prefix "$file_path" "${ui_prefixes[@]}"
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
else
	collect_changed_entries
	deduplicate_changed_files
	code_relevant="false"
	ui_relevant="false"
	if [[ "${#changed_files[@]}" -gt 0 ]]; then
		for file_path in "${changed_files[@]}"; do
			if is_code_path "$file_path"; then
				code_relevant="true"
			fi
			if is_ui_path "$file_path"; then
				ui_relevant="true"
			fi
		done
	fi
fi

change_scope="non_code"
if [[ "$code_relevant" == "true" && "$ui_relevant" == "true" ]]; then
	change_scope="ui_code"
elif [[ "$code_relevant" == "true" ]]; then
	change_scope="code"
fi

append_github_output code_relevant "$code_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output ui_relevant "$ui_relevant" "$GITHUB_OUTPUT_PATH"
append_github_output change_scope "$change_scope" "$GITHUB_OUTPUT_PATH"

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
	--arg change_scope "$change_scope" \
	--arg reason "$classification_reason" \
	--argjson changed_files "$changed_files_json" \
	--argjson changed_entries "$changed_entries_json" \
	'{
	  base: $base,
	  head: $head,
	  code_relevant: ($code_relevant == "true"),
	  ui_relevant: ($ui_relevant == "true"),
	  change_scope: $change_scope,
	  reason: $reason,
	  changed_files: $changed_files,
	  changed_entries: $changed_entries
	}'

info "Change scope: $change_scope code_relevant=$code_relevant ui_relevant=$ui_relevant"
info "Classification summary: $SUMMARY_PATH"
