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
		local temporary_path
		local write_status
		shift
		if [[ -d "$file_path" ]]; then
			warn "JSON artifact target must not be a directory: $file_path"
			return 1
		fi
		ensure_parent_dir "$file_path"
		temporary_path="$(mktemp "$(dirname "$file_path")/.$(basename "$file_path").XXXXXX")"
		write_status=0
		jq -n "$@" >"$temporary_path" || write_status=$?
		if [[ "$write_status" -ne 0 ]]; then
			rm -f "$temporary_path"
			return "$write_status"
		fi
		mv -f "$temporary_path" "$file_path"
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
