#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_ARTIFACTS_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_ARTIFACTS_SH_SOURCED=1

	# shellcheck source=scripts/lib/common.sh
	source "$TOOL_ROOT/scripts/lib/common.sh"

	artifact_timestamp_utc() {
		date -u +%Y-%m-%dT%H:%M:%SZ
	}

	ensure_parent_dir() {
		local file_path="$1"
		mkdir -p "$(dirname "$file_path")"
	}

	write_json_file() {
		local file_path="$1"
		shift
		ensure_parent_dir "$file_path"
		jq -n "$@" >"$file_path"
	}

	append_github_output() {
		local key="$1"
		local value="$2"
		local output_path="${3:-${GITHUB_OUTPUT:-}}"

		[[ -n "$output_path" ]] || return 0
		ensure_parent_dir "$output_path"
		printf '%s=%s\n' "$key" "$value" >>"$output_path"
	}

	sha256_digest() {
		local file_path="$1"
		shasum -a 256 "$file_path" | awk '{print $1}'
	}

	write_artifact_manifest() {
		local manifest_path="$1"
		local artifact_root="$2"
		shift 2

		local files_json
		files_json="$(
			for file_path in "$@"; do
				[[ -e "$file_path" ]] || continue
				printf '%s\n' "$file_path"
			done | jq -R . | jq -s .
		)"

		write_json_file "$manifest_path" \
			--arg generated_at "$(artifact_timestamp_utc)" \
			--arg artifact_root "$artifact_root" \
			--argjson files "$files_json" \
			'{generated_at: $generated_at, artifact_root: $artifact_root, files: $files}'
	}
fi
