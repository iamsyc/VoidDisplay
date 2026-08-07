#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_UI_TEST_SESSION_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_UI_TEST_SESSION_SH_SOURCED=1

	UI_SESSION_BUSY_STATUS=75
	UI_SESSION_LOCK_HELD="false"
	UI_SESSION_ROOT=""
	UI_SESSION_LOCK_PATH=""
	UI_SESSION_TOKEN_PATH=""

	ui_session_info() {
		printf '[INFO] %s\n' "$*" >&2
	}

	ui_session_die() {
		printf '[ERROR] %s\n' "$*" >&2
		exit 1
	}

	ui_session_initialize_paths() {
		local user_temp_root
		local fixture_root="${VOIDDISPLAY_UI_SESSION_FIXTURE_ROOT:-}"

		if [[ -n "$UI_SESSION_ROOT" ]]; then
			return
		fi

		if [[ -n "$fixture_root" ]]; then
			[[ "${VOIDDISPLAY_UI_SESSION_FIXTURE_MODE:-}" == "1" ]] ||
				ui_session_die "VOIDDISPLAY_UI_SESSION_FIXTURE_ROOT is limited to the session fixture."
			UI_SESSION_ROOT="$fixture_root"
		else
			user_temp_root="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)" ||
				ui_session_die "Unable to resolve the macOS per-user temporary directory."
			UI_SESSION_ROOT="${user_temp_root%/}/com.syc.VoidDisplay"
		fi

		/bin/mkdir -p "$UI_SESSION_ROOT"
		/bin/chmod 700 "$UI_SESSION_ROOT"
		UI_SESSION_LOCK_PATH="$UI_SESSION_ROOT/ui-test.lock"
		UI_SESSION_TOKEN_PATH="$UI_SESSION_ROOT/ui-test.token"
	}

	ui_session_open_lock() {
		ui_session_initialize_paths
		exec 9>"$UI_SESSION_LOCK_PATH"
	}

	ui_session_close_lock() {
		exec 9>&-
	}

	ui_session_acquire() {
		local wait_seconds="${1:-0}"
		local token

		[[ "$wait_seconds" =~ ^[0-9]+$ ]] ||
			ui_session_die "UI session wait must be a non-negative integer: $wait_seconds"
		[[ "$UI_SESSION_LOCK_HELD" == "false" ]] ||
			ui_session_die "This process already holds the UI test session lock."

		ui_session_open_lock
		if ! /usr/bin/lockf -s -t 0 9; then
			if [[ "$wait_seconds" -eq 0 ]]; then
				ui_session_close_lock
				printf '[ERROR] Another UI test session is active.\n' >&2
				return "$UI_SESSION_BUSY_STATUS"
			fi
			ui_session_info "Another UI test session is active; waiting up to $wait_seconds seconds."
			if ! /usr/bin/lockf -s -t "$wait_seconds" 9; then
				ui_session_close_lock
				printf '[ERROR] Timed out waiting for the active UI test session.\n' >&2
				return "$UI_SESSION_BUSY_STATUS"
			fi
		fi

		token="voiddisplay-ui-$(/usr/bin/id -u)-$(/usr/bin/uuidgen)"
		printf '%s\n' "$token" >"$UI_SESSION_TOKEN_PATH"
		/bin/chmod 600 "$UI_SESSION_TOKEN_PATH"
		export VOIDDISPLAY_UI_SESSION_TOKEN="$token"
		UI_SESSION_LOCK_HELD="true"
	}

	ui_session_release() {
		local active_token=""

		[[ "$UI_SESSION_LOCK_HELD" == "true" ]] || return 0
		if [[ -f "$UI_SESSION_TOKEN_PATH" ]]; then
			IFS= read -r active_token <"$UI_SESSION_TOKEN_PATH" || true
			if [[ "$active_token" == "${VOIDDISPLAY_UI_SESSION_TOKEN:-}" ]]; then
				/bin/rm -f -- "$UI_SESSION_TOKEN_PATH"
			fi
		fi
		ui_session_close_lock
		UI_SESSION_LOCK_HELD="false"
	}

	ui_session_lock_is_busy() {
		ui_session_initialize_paths
		exec 8>"$UI_SESSION_LOCK_PATH"
		if /usr/bin/lockf -s -t 0 8; then
			exec 8>&-
			return 1
		fi
		exec 8>&-
		return 0
	}

	ui_session_validate_wrapper() {
		local active_token=""
		local requested_token="${VOIDDISPLAY_UI_SESSION_TOKEN:-}"

		[[ -n "$requested_token" ]] ||
			ui_session_die "Direct Xcode UI tests are disabled. Run scripts/ci/ui_smoke.sh or scripts/ci/xcode.sh."
		ui_session_initialize_paths
		ui_session_lock_is_busy ||
			ui_session_die "No wrapper-owned UI test session is active. Run the repository UI test script."
		[[ -f "$UI_SESSION_TOKEN_PATH" ]] ||
			ui_session_die "The active UI test session has no token."
		IFS= read -r active_token <"$UI_SESSION_TOKEN_PATH" || true
		[[ "$active_token" == "$requested_token" ]] ||
			ui_session_die "The UI test session token does not match the active wrapper."
	}

	ui_session_voiddisplay_pids() {
		/usr/bin/pgrep -f '/[V]oidDisplay.app/Contents/MacOS/VoidDisplay' 2>/dev/null || true
	}

	ui_session_terminate_voiddisplay() {
		local parent_command
		local parent_pid
		local pid
		local pids

		if [[ "${VOIDDISPLAY_UI_SESSION_FIXTURE_MODE:-}" == "1" ]]; then
			printf 'terminate-existing-voiddisplay\n' >>"$UI_SESSION_ROOT/termination-events.log"
			return
		fi

		pids="$(ui_session_voiddisplay_pids)"
		[[ -n "$pids" ]] || return 0
		while IFS= read -r pid; do
			[[ "$pid" =~ ^[0-9]+$ ]] || continue
			/bin/kill -TERM "$pid" >/dev/null 2>&1 || true
		done <<<"$pids"

		for _ in {1..20}; do
			[[ -z "$(ui_session_voiddisplay_pids)" ]] && return 0
			/bin/sleep 0.1
		done

		pids="$(ui_session_voiddisplay_pids)"
		while IFS= read -r pid; do
			[[ "$pid" =~ ^[0-9]+$ ]] || continue
			parent_pid="$(/bin/ps -o ppid= -p "$pid" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
			parent_command="$(/bin/ps -o comm= -p "$parent_pid" 2>/dev/null || true)"
			case "$parent_command" in
			*debugserver) /bin/kill -KILL "$parent_pid" >/dev/null 2>&1 || true ;;
			esac
			/bin/kill -KILL "$pid" >/dev/null 2>&1 || true
		done <<<"$pids"

		for _ in {1..20}; do
			[[ -z "$(ui_session_voiddisplay_pids)" ]] && return 0
			/bin/sleep 0.1
		done
		ui_session_die "VoidDisplay is still running after termination."
	}

	ui_session_scheme_test_pre() {
		ui_session_validate_wrapper
		ui_session_terminate_voiddisplay
	}

	ui_session_scheme_launch_pre() {
		ui_session_open_lock
		if ! /usr/bin/lockf -s -t 0 9; then
			ui_session_close_lock
			ui_session_die "An active UI test session prevents running VoidDisplay from Xcode."
		fi
		ui_session_terminate_voiddisplay
		ui_session_close_lock
	}
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -euo pipefail
	umask 077

	case "${1:-}" in
	scheme-test-pre)
		[[ "$#" -eq 1 ]] || ui_session_die "scheme-test-pre does not accept arguments."
		ui_session_scheme_test_pre
		;;
	scheme-launch-pre)
		[[ "$#" -eq 1 ]] || ui_session_die "scheme-launch-pre does not accept arguments."
		ui_session_scheme_launch_pre
		;;
	*)
		printf 'Usage: %s {scheme-test-pre|scheme-launch-pre}\n' "$0" >&2
		exit 2
		;;
	esac
fi
