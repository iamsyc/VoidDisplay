#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/parallel.sh
source "$TOOL_ROOT/scripts/lib/parallel.sh"

mkdir -p "$AI_TMP_DIR"
fixture_root="$(mktemp -d "$AI_TMP_DIR/parallel-runner.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

parallel_group_begin
parallel_group_start first "$fixture_root/first.log" /bin/sh -c 'printf "first passed\n"'
parallel_group_start second "$fixture_root/second.log" /bin/sh -c 'printf "second passed\n"'
parallel_group_wait "success fixture"

[[ "$(parallel_job_status first)" == "0" ]] || die "Parallel runner lost the first success status."
[[ "$(parallel_job_status second)" == "0" ]] || die "Parallel runner lost the second success status."

rg -q '^first passed$' "$fixture_root/first.log" || die "Parallel runner did not capture the first job log."
rg -q '^second passed$' "$fixture_root/second.log" || die "Parallel runner did not capture the second job log."

streamed_console="$fixture_root/streamed-console.log"
{
	parallel_group_begin
	parallel_group_start_streamed streamed "$fixture_root/streamed.log" \
		/bin/sh -c 'printf "streamed passed\n"'
	parallel_group_wait "streamed fixture"
} >"$streamed_console"
[[ "$(parallel_job_status streamed)" == "0" ]] || die "Parallel runner lost the streamed job status."
rg -q '^streamed passed$' "$fixture_root/streamed.log" || die "Streamed job output was not captured in its lane log."
rg -q '^streamed passed$' "$streamed_console" || die "Streamed job output was not forwarded to the caller."

parallel_group_begin
parallel_group_start passing "$fixture_root/passing.log" /usr/bin/true
parallel_group_start failing "$fixture_root/failing.log" /bin/sh -c 'printf "expected failure\n"; exit 7'
if parallel_group_wait "failure fixture" >/dev/null 2>&1; then
	die "Parallel runner accepted a failed job."
fi
[[ "$(parallel_job_status passing)" == "0" ]] || die "Parallel runner lost the passing job status."
[[ "$(parallel_job_status failing)" == "7" ]] || die "Parallel runner lost the failing job status."

child_pid_file="$fixture_root/cancel-child.pid"
parallel_group_begin
parallel_group_start cancellable "$fixture_root/cancellable.log" \
	/bin/sh -c 'sleep 120 & child_pid=$!; printf "%s\n" "$child_pid" >"$1"; wait "$child_pid"' fixture "$child_pid_file"
for _ in $(seq 1 50); do
	[[ -s "$child_pid_file" ]] && break
	/bin/sleep 0.1
done
[[ -s "$child_pid_file" ]] || die "Parallel cancellation fixture did not start its child process."
cancellable_child_pid="$(<"$child_pid_file")"
parallel_group_cancel >/dev/null 2>&1
if /bin/kill -0 "$cancellable_child_pid" >/dev/null 2>&1; then
	die "Parallel cancellation left a descendant process running."
fi

info "Parallel runner contract passed."
