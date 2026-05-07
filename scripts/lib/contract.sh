#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_CONTRACT_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_CONTRACT_SH_SOURCED=1

	contract_die() {
		printf '[ERROR] %s\n' "$*" >&2
		exit 1
	}

	contract_default_root() {
		if command -v git >/dev/null 2>&1; then
			git rev-parse --show-toplevel 2>/dev/null && return 0
		fi
		pwd
	}

	contract_require_absolute_dir() {
		local name="$1"
		local value="$2"

		[[ -n "$value" ]] || contract_die "$name is required."
		case "$value" in
		/*) ;;
		*) contract_die "$name must be an absolute path: $value" ;;
		esac
		[[ -d "$value" ]] || contract_die "$name directory does not exist: $value"
	}

	if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
		[[ -n "${ROOT_DIR:-}" ]] || contract_die "ROOT_DIR is required in CI."
		[[ -n "${TOOL_ROOT:-}" ]] || contract_die "TOOL_ROOT is required in CI."
	else
		ROOT_DIR="${ROOT_DIR:-$(contract_default_root)}"
		TOOL_ROOT="${TOOL_ROOT:-$ROOT_DIR}"
	fi

	contract_require_absolute_dir ROOT_DIR "$ROOT_DIR"
	contract_require_absolute_dir TOOL_ROOT "$TOOL_ROOT"

	AI_TMP_DIR="${AI_TMP_DIR:-$ROOT_DIR/.ai-tmp}"
	case "$AI_TMP_DIR" in
	/*) ;;
	*) contract_die "AI_TMP_DIR must be an absolute path: $AI_TMP_DIR" ;;
	esac

	export ROOT_DIR
	export TOOL_ROOT
	export AI_TMP_DIR
fi
