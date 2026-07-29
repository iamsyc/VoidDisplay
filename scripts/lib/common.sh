#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_COMMON_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_COMMON_SH_SOURCED=1

	if [[ -z "${VOIDDISPLAY_CONTRACT_SH_SOURCED:-}" ]]; then
		printf '[ERROR] scripts/lib/contract.sh must be sourced before common.sh.\n' >&2
		exit 1
	fi

	info() {
		printf '[INFO] %s\n' "$*"
	}

	warn() {
		printf '[WARN] %s\n' "$*" >&2
	}

	die() {
		printf '[ERROR] %s\n' "$*" >&2
		exit 1
	}

	require_command() {
		local missing=()
		local command_name
		for command_name in "$@"; do
			if ! command -v "$command_name" >/dev/null 2>&1; then
				missing+=("$command_name")
			fi
		done

		if [[ "${#missing[@]}" -gt 0 ]]; then
			die "Missing required command(s): ${missing[*]}. Run scripts/dev/bootstrap.sh first."
		fi
	}

	resolve_trusted_go_binary() {
		local go_bin

		if command -v mise >/dev/null 2>&1; then
			go_bin="$(mise -C "$TOOL_ROOT" which go)" ||
				die "Unable to resolve Go from the trusted tool configuration."
		else
			go_bin="$(command -v go || true)"
		fi

		[[ -n "$go_bin" && -x "$go_bin" ]] || die "Go executable could not be resolved."
		printf '%s\n' "$go_bin"
	}

	timestamp() {
		date +%Y%m%d-%H%M%S
	}

	make_artifact_dir() {
		local name="$1"
		local output_dir
		output_dir="$AI_TMP_DIR/$name/$(timestamp)"
		mkdir -p "$output_dir"
		printf '%s\n' "$output_dir"
	}

	normalize_path() {
		local path="$1"
		case "$path" in
		/*) printf '%s\n' "$path" ;;
		*) printf '%s\n' "$ROOT_DIR/$path" ;;
		esac
	}

	run_with_retry() {
		local max_attempts="$1"
		shift

		if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || [[ "$max_attempts" -lt 1 ]]; then
			die "Invalid retry count: $max_attempts"
		fi

		local attempt
		for attempt in $(seq 1 "$max_attempts"); do
			if "$@"; then
				return 0
			fi
			if [[ "$attempt" -eq "$max_attempts" ]]; then
				return 1
			fi
			sleep "$((attempt * 10))"
		done
	}

	go_mod_download_with_retry() {
		local module_dir="$1"
		local goproxy_value="${GOPROXY:-https://proxy.golang.org|https://goproxy.cn|direct}"
		local go_bin="${GO_BIN:-go}"

		(cd "$module_dir" && run_with_retry 3 env GOPROXY="$goproxy_value" "$go_bin" mod download)
	}

	collect_build_log_diagnostics() {
		local log_path="$1"
		local matches
		local search_status=0

		if [[ ! -f "$log_path" ]]; then
			die "Build log not found: $log_path"
		fi

		matches="$(
			rg -n '([A-Za-z0-9_./ -]+\.(swift|m|mm|c|cc|cpp|h|hpp):[0-9]+:[0-9]+: (warning|error):|(^|[[:space:]])ld: (warning|error):|(^|[[:space:]])clang: (warning|error):|\*\* (BUILD|TEST) FAILED \*\*)' \
				"$log_path"
		)" || search_status=$?
		case "$search_status" in
		0) printf '%s\n' "$matches" ;;
		1) return 0 ;;
		*) die "Unable to scan build log: $log_path" ;;
		esac
	}

	scan_build_log_for_diagnostics() {
		local label="$1"
		local log_path="$2"
		local matches

		matches="$(collect_build_log_diagnostics "$log_path")"
		if [[ -n "$matches" ]]; then
			printf '%s\n' "$matches" >&2
			die "$label log contains compiler/linker diagnostic markers."
		fi
	}

	scan_xcode_log_for_diagnostics() {
		scan_build_log_for_diagnostics "$@"
	}
fi
