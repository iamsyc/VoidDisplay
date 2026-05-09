#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

cd "$ROOT_DIR"

REPOSITORY="${GITHUB_REPOSITORY:-}"
TARGET_SHA=""
CHECK_NAME="ci-gate"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-20}"
SUMMARY_PATH=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--repository)
		REPOSITORY="$2"
		shift 2
		;;
	--sha)
		TARGET_SHA="$2"
		shift 2
		;;
	--check-name)
		CHECK_NAME="$2"
		shift 2
		;;
	--timeout-seconds)
		TIMEOUT_SECONDS="$2"
		shift 2
		;;
	--poll-interval-seconds)
		POLL_INTERVAL_SECONDS="$2"
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

[[ -n "$REPOSITORY" ]] || die "--repository is required."
[[ -n "$TARGET_SHA" ]] || die "--sha is required."
[[ -n "$CHECK_NAME" ]] || die "--check-name is required."
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--timeout-seconds must be numeric."
[[ "$POLL_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || die "--poll-interval-seconds must be numeric."
[[ "$POLL_INTERVAL_SECONDS" -gt 0 ]] || die "--poll-interval-seconds must be greater than 0."

SUMMARY_PATH="${SUMMARY_PATH:-$(make_artifact_dir release-ci-gate)/require-ci-gate-summary.json}"
require_command gh jq

snapshot_state="missing"
snapshot_source="none"
snapshot_detail=""

write_gate_summary() {
	local status="$1"
	local reason="$2"
	local elapsed_seconds="$3"

	write_json_file "$SUMMARY_PATH" \
		--arg status "$status" \
		--arg reason "$reason" \
		--arg repository "$REPOSITORY" \
		--arg target_sha "$TARGET_SHA" \
		--arg check_name "$CHECK_NAME" \
		--arg gate_state "$snapshot_state" \
		--arg source "$snapshot_source" \
		--arg detail "$snapshot_detail" \
		--argjson elapsed_seconds "$elapsed_seconds" \
		'{
		  status: $status,
		  reason: $reason,
		  repository: $repository,
		  target_sha: $target_sha,
		  check_name: $check_name,
		  gate_state: $gate_state,
		  source: $source,
		  detail: $detail,
		  elapsed_seconds: $elapsed_seconds
		}'
}

load_gate_snapshot() {
	local response
	local latest
	local check_status
	local check_conclusion
	local status_state

	snapshot_state="missing"
	snapshot_source="checks"
	snapshot_detail="No matching check run found."

	if ! response="$(gh api -X GET "repos/$REPOSITORY/commits/$TARGET_SHA/check-runs" -f "check_name=$CHECK_NAME" -f "per_page=100" 2>&1)"; then
		snapshot_state="api_error"
		snapshot_detail="$response"
		return
	fi

	latest="$(
		jq -c --arg name "$CHECK_NAME" '
		  [.check_runs[]? | select(.name == $name)]
		  | sort_by(.started_at // .completed_at // .created_at // "")
		  | last // empty
		' <<<"$response"
	)"
	if [[ -n "$latest" ]]; then
		check_status="$(jq -r '.status // "unknown"' <<<"$latest")"
		check_conclusion="$(jq -r '.conclusion // ""' <<<"$latest")"
		snapshot_detail="check_status=$check_status conclusion=${check_conclusion:-none}"
		if [[ "$check_status" == "completed" && "$check_conclusion" == "success" ]]; then
			snapshot_state="success"
		elif [[ "$check_status" == "completed" ]]; then
			snapshot_state="failure"
		else
			snapshot_state="pending"
		fi
		return
	fi

	snapshot_source="statuses"
	if ! response="$(gh api -X GET "repos/$REPOSITORY/commits/$TARGET_SHA/status" -f "per_page=100" 2>&1)"; then
		snapshot_state="api_error"
		snapshot_detail="$response"
		return
	fi

	latest="$(
		jq -c --arg name "$CHECK_NAME" '
		  [.statuses[]? | select(.context == $name)]
		  | sort_by(.created_at // "")
		  | last // empty
		' <<<"$response"
	)"
	if [[ -z "$latest" ]]; then
		snapshot_state="missing"
		snapshot_detail="No matching commit status found."
		return
	fi

	status_state="$(jq -r '.state // "unknown"' <<<"$latest")"
	snapshot_detail="status_state=$status_state"
	case "$status_state" in
	success) snapshot_state="success" ;;
	pending) snapshot_state="pending" ;;
	*) snapshot_state="failure" ;;
	esac
}

start_seconds="$(date +%s)"

while true; do
	load_gate_snapshot
	now_seconds="$(date +%s)"
	elapsed_seconds="$((now_seconds - start_seconds))"

	case "$snapshot_state" in
	success)
		write_gate_summary "passed" "ci_gate_success" "$elapsed_seconds"
		info "Required target check passed: $CHECK_NAME on $TARGET_SHA"
		info "Summary: $SUMMARY_PATH"
		exit 0
		;;
	failure | api_error)
		write_gate_summary "failed" "ci_gate_${snapshot_state}" "$elapsed_seconds"
		die "Required target check $CHECK_NAME is $snapshot_state for $TARGET_SHA. $snapshot_detail"
		;;
	esac

	if [[ "$elapsed_seconds" -ge "$TIMEOUT_SECONDS" ]]; then
		write_gate_summary "failed" "ci_gate_${snapshot_state}" "$elapsed_seconds"
		die "Timed out waiting for target check $CHECK_NAME on $TARGET_SHA. state=$snapshot_state detail=$snapshot_detail"
	fi

	info "Waiting for $CHECK_NAME on $TARGET_SHA. state=$snapshot_state detail=$snapshot_detail"
	sleep "$POLL_INTERVAL_SECONDS"
done
