#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/release.sh
source "$TOOL_ROOT/scripts/lib/release.sh"

require_command git

WORK_DIR="${WORK_DIR:-$(make_artifact_dir release-project-path-tests)}"
FIXTURE_REPO="$WORK_DIR/repo"
CURRENT_PROJECT_PATH="VoidDisplay.xcodeproj/project.pbxproj"
PREVIOUS_PROJECT_PATH="LegacyProject/VoidDisplay.xcodeproj/project.pbxproj"

mkdir -p "$(dirname "$FIXTURE_REPO/$PREVIOUS_PROJECT_PATH")"
git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.email "ci@example.invalid"
git -C "$FIXTURE_REPO" config user.name "CI Release Path Test"
printf 'MARKETING_VERSION = 1.2.3;\nCURRENT_PROJECT_VERSION = 7;\n' \
	>"$FIXTURE_REPO/$PREVIOUS_PROJECT_PATH"
git -C "$FIXTURE_REPO" add "$PREVIOUS_PROJECT_PATH"
git -C "$FIXTURE_REPO" commit -qm "add nested project"
PREVIOUS_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

mkdir -p "$(dirname "$FIXTURE_REPO/$CURRENT_PROJECT_PATH")"
git -C "$FIXTURE_REPO" mv "$PREVIOUS_PROJECT_PATH" "$CURRENT_PROJECT_PATH"
git -C "$FIXTURE_REPO" commit -qm "move project to repository root"
CURRENT_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

(
	cd "$FIXTURE_REPO"
	previous_version="$(release_read_project_value_from_git MARKETING_VERSION "$PREVIOUS_COMMIT" "$CURRENT_PROJECT_PATH")"
	current_build_number="$(release_read_project_value_from_git CURRENT_PROJECT_VERSION "$CURRENT_COMMIT" "$CURRENT_PROJECT_PATH")"
	[[ "$previous_version" == "1.2.3" ]] || die "Renamed project version lookup returned: $previous_version"
	[[ "$current_build_number" == "7" ]] || die "Current project build lookup returned: $current_build_number"
)

info "Release project path fixtures passed."
