#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/architecture.sh
source "$TOOL_ROOT/scripts/lib/architecture.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

cd "$ROOT_DIR"

require_command jq uname

OUT_DIR="${OUT_DIR:-$(make_artifact_dir signed-runtime)}"
DEVELOPMENT_IDENTIFIER="${VOIDDISPLAY_DEVELOPMENT_IDENTIFIER:-com.developerchen.voiddisplay}"
DEVELOPMENT_TEAM_IDENTIFIER="${VOIDDISPLAY_DEVELOPMENT_TEAM_IDENTIFIER:-6HCGZ4HUVA}"
DESTINATION=""
SUMMARY_PATH=""
SUMMARY_TERMINAL="false"
SUMMARY_FAILURE_REASON="argument_validation_failed"

write_failed_summary_on_exit() {
	local exit_status=$?
	local failure_summary_path="${SUMMARY_PATH:-$OUT_DIR/signed-runtime-summary.json}"
	trap - EXIT
	if [[ "$exit_status" -ne 0 && "$SUMMARY_TERMINAL" != "true" ]]; then
		set +e
		write_json_file "$failure_summary_path" \
			--arg status "failed" \
			--arg reason "$SUMMARY_FAILURE_REASON" \
			--arg destination "$DESTINATION" \
			--arg bundle_identifier "$DEVELOPMENT_IDENTIFIER" \
			--arg team_identifier "$DEVELOPMENT_TEAM_IDENTIFIER" \
			'{status: $status, reason: $reason, destination: $destination, bundle_identifier: $bundle_identifier, team_identifier: $team_identifier}'
	fi
	exit "$exit_status"
}
trap write_failed_summary_on_exit EXIT

host_arch="$(uname -m)"
case "$host_arch" in
arm64 | x86_64) DESTINATION="$(xcode_destination_for_arch "$host_arch")" ;;
*) die "Unsupported host architecture for signed runtime build: $host_arch" ;;
esac

while [[ $# -gt 0 ]]; do
	case "$1" in
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
		shift 2
		;;
	--destination)
		DESTINATION="$2"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

mkdir -p "$OUT_DIR"

XCODE_OUT_DIR="$OUT_DIR/xcode-build"
XCODE_SUMMARY="$XCODE_OUT_DIR/xcode-summary.json"
SUMMARY_PATH="$OUT_DIR/signed-runtime-summary.json"
write_json_file "$SUMMARY_PATH" \
	--arg status "running" \
	--arg reason "in_progress" \
	--arg destination "$DESTINATION" \
	--arg bundle_identifier "$DEVELOPMENT_IDENTIFIER" \
	--arg team_identifier "$DEVELOPMENT_TEAM_IDENTIFIER" \
	'{status: $status, reason: $reason, destination: $destination, bundle_identifier: $bundle_identifier, team_identifier: $team_identifier}'

SUMMARY_FAILURE_REASON="xcode_gate_failed"
env ROOT_DIR="$ROOT_DIR" TOOL_ROOT="$TOOL_ROOT" "$TOOL_ROOT/scripts/ci/xcode.sh" \
	--action build \
	--configuration Debug \
	--destination "$DESTINATION" \
	--signing development \
	--development-identifier "$DEVELOPMENT_IDENTIFIER" \
	--development-team-identifier "$DEVELOPMENT_TEAM_IDENTIFIER" \
	--out-dir "$XCODE_OUT_DIR"

SUMMARY_FAILURE_REASON="xcode_summary_invalid"
APP_PATH="$(
	jq -er \
		--arg bundle_identifier "$DEVELOPMENT_IDENTIFIER" \
		--arg team_identifier "$DEVELOPMENT_TEAM_IDENTIFIER" '
		select(
			.status == "passed"
			and .signing_mode == "development"
			and .bundle_identifier == $bundle_identifier
			and .team_identifier == $team_identifier
			and (.signing_authority | startswith("Apple Development: "))
			and .signature_verified == true
			and .hardened_runtime_verified == true
			and .designated_requirement_verified == true
		)
		| .app_path
	' "$XCODE_SUMMARY"
)"
[[ -d "$APP_PATH" ]] || die "Verified signed runtime app is missing: $APP_PATH"
SIGNING_AUTHORITY="$(jq -er '.signing_authority' "$XCODE_SUMMARY")"

SUMMARY_FAILURE_REASON="summary_write_failed"
write_json_file "$SUMMARY_PATH" \
	--arg status "passed" \
	--arg destination "$DESTINATION" \
	--arg app_path "$APP_PATH" \
	--arg bundle_identifier "$DEVELOPMENT_IDENTIFIER" \
	--arg team_identifier "$DEVELOPMENT_TEAM_IDENTIFIER" \
	--arg signing_authority "$SIGNING_AUTHORITY" \
	--arg xcode_summary "$XCODE_SUMMARY" \
	'{status: $status, destination: $destination, app_path: $app_path, bundle_identifier: $bundle_identifier, team_identifier: $team_identifier, signing_authority: $signing_authority, xcode_summary: $xcode_summary}'
SUMMARY_TERMINAL="true"

info "Signed runtime build passed."
info "Signing authority: $SIGNING_AUTHORITY"
info "Use this exact app path for permission-sensitive acceptance: $APP_PATH"
info "Summary: $SUMMARY_PATH"
