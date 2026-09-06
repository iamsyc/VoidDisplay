#!/usr/bin/env bash
# shellcheck disable=SC2016 # Inline fixture scripts expand variables in their child shells.
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

cd "$ROOT_DIR"

require_command bash jq lockf mktemp rg sleep

/bin/mkdir -p "$AI_TMP_DIR"
SESSION_SCRIPT="$TOOL_ROOT/scripts/lib/ui_test_session.sh"
FIXTURE_ROOT="$(mktemp -d "$AI_TMP_DIR/ui-test-session.XXXXXX")"
SESSION_ROOT="$FIXTURE_ROOT/session"
TOKEN_FILE="$SESSION_ROOT/ui-test.token"
TERMINATION_LOG="$SESSION_ROOT/termination-events.log"
SESSION_ENV=(
	"VOIDDISPLAY_UI_SESSION_FIXTURE_MODE=1"
	"VOIDDISPLAY_UI_SESSION_FIXTURE_ROOT=$SESSION_ROOT"
)
HOLDER_PID=""
SIGNAL_WRAPPER_PID=""
SIGNAL_CHILD_PID=""

process_is_active() {
	local pid="$1"
	local state

	/bin/kill -0 "$pid" >/dev/null 2>&1 || return 1
	state="$(/bin/ps -o state= -p "$pid" 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
	[[ -n "$state" && "$state" != "Z" ]]
}

cleanup() {
	local pid

	trap - EXIT
	for pid in "$HOLDER_PID" "$SIGNAL_WRAPPER_PID" "$SIGNAL_CHILD_PID"; do
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		/bin/kill -TERM "$pid" >/dev/null 2>&1 || true
	done
	/bin/sleep 0.1
	for pid in "$HOLDER_PID" "$SIGNAL_WRAPPER_PID" "$SIGNAL_CHILD_PID"; do
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		/bin/kill -KILL "$pid" >/dev/null 2>&1 || true
		wait "$pid" >/dev/null 2>&1 || true
	done
	/bin/rm -rf -- "$FIXTURE_ROOT"
}
trap cleanup EXIT

fail() {
	die "UI session fixture failed: $*"
}

wait_for_file() {
	local path="$1"
	local attempt

	for attempt in {1..100}; do
		[[ -s "$path" ]] && return 0
		/bin/sleep 0.02
	done
	fail "timed out waiting for $path"
}

assert_command_fails() {
	local description="$1"
	shift

	if "$@" >/dev/null 2>&1; then
		fail "$description"
	fi
}

acquire_once() {
	local wait_seconds="${1:-0}"

	env "${SESSION_ENV[@]}" \
		SESSION_SCRIPT="$SESSION_SCRIPT" \
		WAIT_SECONDS="$wait_seconds" \
		/bin/bash -c '
			set -euo pipefail
			source "$SESSION_SCRIPT"
			ui_session_acquire "$WAIT_SECONDS"
			ui_session_release
		'
}

start_holder() {
	local ready_file="$1"
	local release_file="$2"

	env "${SESSION_ENV[@]}" \
		SESSION_SCRIPT="$SESSION_SCRIPT" \
		READY_FILE="$ready_file" \
		RELEASE_FILE="$release_file" \
		/bin/bash -c '
			set -euo pipefail
			source "$SESSION_SCRIPT"
			ui_session_acquire 0
			trap ui_session_release EXIT
			printf "%s\n" "$VOIDDISPLAY_UI_SESSION_TOKEN" >"$READY_FILE"
			while [[ ! -e "$RELEASE_FILE" ]]; do
				/bin/sleep 0.02
			done
		' &
	HOLDER_PID=$!
	wait_for_file "$ready_file"
}

stop_holder() {
	local release_file="$1"

	: >"$release_file"
	wait "$HOLDER_PID"
	HOLDER_PID=""
}

# Winner/busy also covers non-blocking Cmd-R refusal.
winner_ready="$FIXTURE_ROOT/winner.ready"
winner_release="$FIXTURE_ROOT/winner.release"
start_holder "$winner_ready" "$winner_release"
set +e
acquire_once 0 >/dev/null 2>&1
busy_status=$?
set -e
[[ "$busy_status" -eq 75 ]] || fail "competing wrapper status was $busy_status"
assert_command_fails "Cmd-R entered while the UI test lock was held" \
	env "${SESSION_ENV[@]}" "$SESSION_SCRIPT" scheme-launch-pre
[[ ! -e "$TERMINATION_LOG" ]] || fail "busy Cmd-R terminated VoidDisplay"
stop_holder "$winner_release"
env "${SESSION_ENV[@]}" "$SESSION_SCRIPT" scheme-launch-pre
[[ "$(<"$TERMINATION_LOG")" == "terminate-existing-voiddisplay" ]] ||
	fail "idle Cmd-R did not run its termination precondition"
/bin/rm -f -- "$TERMINATION_LOG"

# A waiting wrapper takes the lock after the current holder exits.
handoff_ready="$FIXTURE_ROOT/handoff.ready"
handoff_release="$FIXTURE_ROOT/handoff.release"
handoff_acquired="$FIXTURE_ROOT/handoff.acquired"
start_holder "$handoff_ready" "$handoff_release"
env "${SESSION_ENV[@]}" \
	SESSION_SCRIPT="$SESSION_SCRIPT" \
	ACQUIRED_FILE="$handoff_acquired" \
	/bin/bash -c '
		set -euo pipefail
		source "$SESSION_SCRIPT"
		ui_session_acquire 5
		trap ui_session_release EXIT
		: >"$ACQUIRED_FILE"
	' >"$FIXTURE_ROOT/handoff.out" 2>"$FIXTURE_ROOT/handoff.err" &
handoff_pid=$!
/bin/sleep 0.2
[[ ! -e "$handoff_acquired" ]] || fail "waiting wrapper bypassed the active holder"
stop_holder "$handoff_release"
wait "$handoff_pid"
[[ -e "$handoff_acquired" ]] || fail "waiting wrapper did not acquire after handoff"

# Direct Cmd-U and a forged token fail before the app termination boundary.
token_ready="$FIXTURE_ROOT/token.ready"
token_release="$FIXTURE_ROOT/token.release"
start_holder "$token_ready" "$token_release"
active_token="$(<"$token_ready")"
direct_error="$FIXTURE_ROOT/direct-test.err"
set +e
env -u VOIDDISPLAY_UI_SESSION_TOKEN "${SESSION_ENV[@]}" \
	"$SESSION_SCRIPT" scheme-test-pre >/dev/null 2>"$direct_error"
direct_status=$?
set -e
[[ "$direct_status" -ne 0 ]] || fail "direct Cmd-U entered without a wrapper token"
rg -q 'Direct Xcode UI tests are disabled' "$direct_error" ||
	fail "direct Cmd-U did not explain the supported entrypoint"
assert_command_fails "forged wrapper token was accepted" \
	env "${SESSION_ENV[@]}" VOIDDISPLAY_UI_SESSION_TOKEN=wrong-token \
	"$SESSION_SCRIPT" scheme-test-pre
[[ ! -e "$TERMINATION_LOG" ]] || fail "invalid token terminated VoidDisplay"
env "${SESSION_ENV[@]}" VOIDDISPLAY_UI_SESSION_TOKEN="$active_token" \
	"$SESSION_SCRIPT" scheme-test-pre
[[ "$(<"$TERMINATION_LOG")" == "terminate-existing-voiddisplay" ]] ||
	fail "valid wrapper token did not reach the termination precondition"
stop_holder "$token_release"
/bin/rm -f -- "$TERMINATION_LOG"

# TERM keeps the lock until an uncooperative xcodebuild child is gone.
fixture_bin="$FIXTURE_ROOT/bin"
signal_root="$FIXTURE_ROOT/signal"
signal_out="$signal_root/out"
signal_log="$signal_root/wrapper.log"
/bin/mkdir -p "$fixture_bin" "$signal_out/DerivedData/Build/Products"
printf 'previous valid build\n' >"$signal_out/DerivedData/Build/Products/voiddisplay-test-products.json"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'exit 0' \
	>"$fixture_bin/go"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'if [[ "${1:-}" == "-version" ]]; then' \
	'  printf "Xcode 26.6\nBuild version 17F113\n"' \
	'  exit 0' \
	'fi' \
	'printf "%s\n" "$$" >"$SIGNAL_ROOT/xcodebuild.pid"' \
	'printf "fixture-xcodebuild-started\n"' \
	'trap "" TERM INT HUP' \
	'while true; do /bin/sleep 1; done' \
	>"$fixture_bin/xcodebuild"
/bin/chmod +x "$fixture_bin/go" "$fixture_bin/xcodebuild"

# A preflight failure must preserve old artifacts without claiming they were produced now.
preflight_out="$FIXTURE_ROOT/preflight"
mkdir -p "$preflight_out/XcodeTests.xcresult"
printf 'old result\n' >"$preflight_out/XcodeTests.xcresult/old-result"
printf 'old launch\n' >"$preflight_out/xcode-test-Debug.log"
preflight_ready="$FIXTURE_ROOT/preflight.ready"
preflight_release="$FIXTURE_ROOT/preflight.release"
start_holder "$preflight_ready" "$preflight_release"
assert_command_fails "Xcode ran while the UI session was busy" \
	env "${SESSION_ENV[@]}" PATH="$fixture_bin:$PATH" \
	DEVELOPER_DIR="$(xcode-select -p)" VOIDDISPLAY_UI_SESSION_WAIT_SECONDS=0 SIGNAL_ROOT="$signal_root" \
	"$TOOL_ROOT/scripts/ci/xcode.sh" --action test --destination platform=macOS \
	--only-testing VoidDisplayUITests/SignalFixture --out-dir "$preflight_out"
stop_holder "$preflight_release"
[[ ! -e "$signal_root/xcodebuild.pid" ]] || fail "preflight failure invoked xcodebuild"
jq -e '.status == "failed" and .reason == "ui_session_acquire_failed" and .log_path == "" and .result_bundle == ""' \
	"$preflight_out/xcode-summary.json" >/dev/null || fail "preflight failure published previous run artifacts"
[[ "$(cat "$preflight_out/XcodeTests.xcresult/old-result")" == "old result" ]] || fail "preflight removed a historical result"
[[ "$(cat "$preflight_out/xcode-test-Debug.log")" == "old launch" ]] || fail "preflight replaced a historical log"

env "${SESSION_ENV[@]}" \
	PATH="$fixture_bin:$PATH" \
	DEVELOPER_DIR="$(xcode-select -p)" \
	AI_TMP_DIR="$AI_TMP_DIR" \
	VOIDDISPLAY_UI_SESSION_WAIT_SECONDS=0 \
	SIGNAL_ROOT="$signal_root" \
	"$TOOL_ROOT/scripts/ci/xcode.sh" \
	--action test \
	--destination platform=macOS \
	--only-testing VoidDisplayUITests/SignalFixture \
	--out-dir "$signal_out" \
	>"$signal_log" 2>&1 &
SIGNAL_WRAPPER_PID=$!
wait_for_file "$signal_root/xcodebuild.pid"
wait_for_file "$TOKEN_FILE"
SIGNAL_CHILD_PID="$(<"$signal_root/xcodebuild.pid")"
[[ ! -e "$signal_out/DerivedData/Build/Products/voiddisplay-test-products.json" ]] || fail "a rebuild retained the previous source manifest"
process_is_active "$SIGNAL_CHILD_PID" || fail "xcodebuild fixture child did not remain active"

/bin/kill -TERM "$SIGNAL_WRAPPER_PID"
/bin/sleep 0.2
process_is_active "$SIGNAL_CHILD_PID" || fail "xcodebuild child exited before TERM cleanup was exercised"
set +e
acquire_once 0 >/dev/null 2>&1
during_term_status=$?
set -e
[[ "$during_term_status" -eq 75 ]] || fail "wrapper released the lock before xcodebuild stopped"

for _ in {1..60}; do
	process_is_active "$SIGNAL_WRAPPER_PID" || break
	/bin/sleep 0.1
done
process_is_active "$SIGNAL_WRAPPER_PID" && fail "wrapper did not finish TERM cleanup"
set +e
wait "$SIGNAL_WRAPPER_PID"
signal_status=$?
set -e
SIGNAL_WRAPPER_PID=""
[[ "$signal_status" -eq 143 ]] || fail "wrapper TERM status was $signal_status"
process_is_active "$SIGNAL_CHILD_PID" && fail "xcodebuild child survived wrapper TERM"
SIGNAL_CHILD_PID=""
[[ ! -e "$TOKEN_FILE" ]] || fail "wrapper left its UI session token after TERM"
acquire_once 0 >/dev/null

info "UI session fixture passed."
