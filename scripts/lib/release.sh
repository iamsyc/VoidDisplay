#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_RELEASE_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_RELEASE_SH_SOURCED=1

	# shellcheck source=scripts/lib/common.sh
	source "$TOOL_ROOT/scripts/lib/common.sh"
	# shellcheck source=scripts/lib/architecture.sh
	source "$TOOL_ROOT/scripts/lib/architecture.sh"

	release_project_file() {
		printf '%s\n' "$ROOT_DIR/Apps/VoidDisplay/VoidDisplay.xcodeproj/project.pbxproj"
	}

	release_read_project_value_stream() {
		local key="$1"
		local context="${2:-}"
		local values
		local count
		values="$(awk -v key="$key" '$1 == key && $2 == "=" { value = $3; sub(/;$/, "", value); print value }' | sort -u)"
		count="$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')"
		if [[ "$count" -ne 1 ]]; then
			die "Expected exactly one unique $key${context:+ $context}; found: ${values:-<none>}"
		fi
		printf '%s\n' "$values"
	}

	release_read_project_value() {
		local key="$1"
		local source="${2:-$(release_project_file)}"
		release_read_project_value_stream "$key" <"$source"
	}

	release_read_project_value_from_git() {
		local key="$1"
		local commit="$2"
		local path="${3:-Apps/VoidDisplay/VoidDisplay.xcodeproj/project.pbxproj}"

		git cat-file -e "${commit}:${path}" 2>/dev/null || die "Unable to read $path at $commit."
		git show "${commit}:${path}" | release_read_project_value_stream "$key" "at $commit"
	}

	release_require_semver() {
		local version="$1"
		local detail="${2:-Invalid version: $version. Expected MAJOR.MINOR.PATCH.}"
		[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$detail"
	}

	release_require_tag() {
		local tag="$1"
		local detail="${2:---tag must match vMAJOR.MINOR.PATCH.}"
		[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$detail"
	}

	release_require_positive_integer() {
		local value="$1"
		local detail="${2:-Expected a positive integer: $value}"
		[[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$detail"
	}

	release_arch_label() {
		local arch="$1"
		local label="${2:-}"
		[[ -n "$arch" ]] || die "--arch is required."
		validate_release_arch "$arch"
		label="${label:-$(release_label_for_arch "$arch")}"
		require_release_label_for_arch "$arch" "$label"
		printf '%s\n' "$label"
	}

	release_dmg_name() {
		local tag="$1"
		local label="$2"
		printf 'VoidDisplay-%s-%s.dmg\n' "$tag" "$label"
	}

	release_stage_failure_once() {
		local exit_code="$1"
		local summary_written="$2"
		local writer="$3"
		local stage="$4"
		local detail="$5"

		if [[ "$exit_code" -ne 0 && "$summary_written" != "true" ]]; then
			"$writer" "failed" "${stage}_failed" "$detail"
		fi
	}

	release_fail() {
		local writer="$1"
		local reason="$2"
		local detail="$3"

		"$writer" "failed" "$reason" "$detail"
		die "$detail"
	}

	release_parse_attach_device() {
		awk '/^\/dev\// {print $1; exit}'
	}

	release_parse_attach_mount_path() {
		sed -n 's#.*\(/Volumes/.*\)$#\1#p' | tail -n 1
	}

	release_detach_device() {
		local target_device="$1"
		[[ -n "$target_device" ]] || return 0

		for _ in 1 2 3 4 5; do
			hdiutil detach "$target_device" -quiet >/dev/null 2>&1 && return 0
			sleep 1
		done
		hdiutil detach "$target_device" -force -quiet >/dev/null 2>&1 || true
	}

	release_cleanup_device() {
		local target_device="$1"
		[[ -n "$target_device" ]] || return 0
		hdiutil detach "$target_device" -quiet >/dev/null 2>&1 ||
			hdiutil detach "$target_device" -force -quiet >/dev/null 2>&1 ||
			true
	}

	release_run_with_timeout() {
		local timeout_seconds="$1"
		shift

		python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]

try:
    completed = subprocess.run(command, check=False, timeout=timeout_seconds)
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
	}
fi
