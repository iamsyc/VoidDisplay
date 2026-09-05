#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_CHECKPOINT_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_CHECKPOINT_SH_SOURCED=1

	# shellcheck source=scripts/lib/common.sh
	source "$TOOL_ROOT/scripts/lib/common.sh"

	source_tree_fingerprint() {
		node "$TOOL_ROOT/scripts/lib/source_fingerprint.mjs" "$ROOT_DIR" "${1:-all}"
	}

	checkpoint_run_fingerprint() {
		printf '%s\0' "$@" | shasum -a 256 | awk '{print $1}'
	}

	checkpoint_stage_passed() {
		local checkpoint_path="$1"
		local stage="$2"
		local stage_fingerprint="$3"

		[[ -f "$checkpoint_path" ]] || return 1
		jq -e \
			--arg stage "$stage" \
			--arg stage_fingerprint "$stage_fingerprint" \
			'.stages[$stage].status == "passed" and .stages[$stage].fingerprint == $stage_fingerprint' \
			"$checkpoint_path" >/dev/null
	}

	checkpoint_stage_duration() {
		local checkpoint_path="$1"
		local stage="$2"

		jq -r --arg stage "$stage" '.stages[$stage].duration_seconds // 0' "$checkpoint_path"
	}

	checkpoint_invalidate_stage() {
		local checkpoint_path="$1"
		local stage="$2"
		local temporary_path

		[[ -f "$checkpoint_path" ]] || return 0
		if ! jq -e 'type == "object"' "$checkpoint_path" >/dev/null 2>&1; then
			rm -f -- "$checkpoint_path"
			return 0
		fi

		temporary_path="$(mktemp "$(dirname "$checkpoint_path")/.$(basename "$checkpoint_path").XXXXXX")"
		if ! jq \
			--arg stage "$stage" \
			--arg invalidated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			'.updated_at = $invalidated_at
			| .stages = (.stages // {})
			| del(.stages[$stage])' \
			"$checkpoint_path" >"$temporary_path"; then
			rm -f -- "$temporary_path"
			return 1
		fi
		mv -f "$temporary_path" "$checkpoint_path"
	}

	checkpoint_mark_stage_passed() {
		local checkpoint_path="$1"
		local stage="$2"
		local stage_fingerprint="$3"
		local source_fingerprint="$4"
		local duration_seconds="$5"
		local existing='{}'
		local temporary_path

		if [[ -f "$checkpoint_path" ]] && jq -e 'type == "object"' "$checkpoint_path" >/dev/null 2>&1; then
			existing="$(<"$checkpoint_path")"
		fi

		mkdir -p "$(dirname "$checkpoint_path")"
		temporary_path="$(mktemp "$(dirname "$checkpoint_path")/.$(basename "$checkpoint_path").XXXXXX")"
		jq \
			--arg source_fingerprint "$source_fingerprint" \
			--arg stage "$stage" \
			--arg stage_fingerprint "$stage_fingerprint" \
			--arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			--argjson duration_seconds "$duration_seconds" \
			'.source_fingerprint = $source_fingerprint
			| .updated_at = $completed_at
			| .stages = (.stages // {})
			| .stages[$stage] = {status: "passed", fingerprint: $stage_fingerprint, completed_at: $completed_at, duration_seconds: $duration_seconds}' \
			<<<"$existing" >"$temporary_path"
		mv -f "$temporary_path" "$checkpoint_path"
	}

	require_source_tree_unchanged() {
		local expected_fingerprint="$1"
		local context="$2"
		local actual_fingerprint

		actual_fingerprint="$(source_tree_fingerprint "${3:-all}")"
		[[ "$actual_fingerprint" == "$expected_fingerprint" ]] ||
			die "Repository source changed during $context. Discard this mixed-source result and rerun the gate."
	}
fi
