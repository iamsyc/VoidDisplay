#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"
# shellcheck source=scripts/lib/release.sh
source "$TOOL_ROOT/scripts/lib/release.sh"

EVENT_NAME=""
TARGET_REPO_DIR=""
BEFORE_SHA=""
INPUT_TAG=""
REF_NAME=""
REF_TYPE=""
GITHUB_OUTPUT_PATH="${GITHUB_OUTPUT:-}"
SUMMARY_PATH=""
CALLER_DIR="$PWD"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--event-name)
		EVENT_NAME="$2"
		shift 2
		;;
	--target-repo-dir)
		TARGET_REPO_DIR="$2"
		shift 2
		;;
	--before-sha)
		BEFORE_SHA="$2"
		shift 2
		;;
	--input-tag)
		INPUT_TAG="$2"
		shift 2
		;;
	--ref-name)
		REF_NAME="$2"
		shift 2
		;;
	--ref-type)
		REF_TYPE="$2"
		shift 2
		;;
	--github-output)
		GITHUB_OUTPUT_PATH="$2"
		shift 2
		;;
	--summary)
		SUMMARY_PATH="$2"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

[[ -n "$EVENT_NAME" ]] || die "--event-name is required."
[[ -n "$TARGET_REPO_DIR" ]] || die "--target-repo-dir is required."

normalize_caller_path() {
	local path="$1"
	case "$path" in
	/*) printf '%s\n' "$path" ;;
	*) printf '%s\n' "$CALLER_DIR/$path" ;;
	esac
}

if [[ -n "$GITHUB_OUTPUT_PATH" ]]; then
	GITHUB_OUTPUT_PATH="$(normalize_caller_path "$GITHUB_OUTPUT_PATH")"
fi

case "$TARGET_REPO_DIR" in
/*) ;;
*) TARGET_REPO_DIR="$CALLER_DIR/$TARGET_REPO_DIR" ;;
esac
[[ -d "$TARGET_REPO_DIR/.git" ]] || die "--target-repo-dir must point to a git checkout."

normalize_target_path() {
	local path="$1"
	case "$path" in
	/*) printf '%s\n' "$path" ;;
	*) printf '%s\n' "$TARGET_REPO_DIR/$path" ;;
	esac
}

SUMMARY_PATH="${SUMMARY_PATH:-$TARGET_REPO_DIR/.ai-tmp/release-prepare/prepare-summary.json}"
SUMMARY_PATH="$(normalize_target_path "$SUMMARY_PATH")"

cd "$TARGET_REPO_DIR"

project_file="VoidDisplay.xcodeproj/project.pbxproj"

find_existing_tag_sha() {
	local release_tag="$1"
	git fetch --tags --force >/dev/null 2>&1
	git rev-parse -q --verify "refs/tags/${release_tag}^{commit}" 2>/dev/null || true
}

ensure_tag_matches_target_if_present() {
	local release_tag="$1"
	local target_sha="$2"
	local existing_tag_sha
	existing_tag_sha="$(find_existing_tag_sha "$release_tag")"
	if [[ -n "$existing_tag_sha" && "$existing_tag_sha" != "$target_sha" ]]; then
		die "Tag $release_tag already points to $existing_tag_sha, expected $target_sha."
	fi
}

ensure_target_is_on_main() {
	local target_sha="$1"
	local main_ref="refs/remotes/origin/main"

	git fetch origin main --force >/dev/null 2>&1 || die "Unable to fetch origin/main for release target validation."
	git rev-parse -q --verify "${main_ref}^{commit}" >/dev/null ||
		die "Unable to resolve origin/main for release target validation."

	if ! git merge-base --is-ancestor "$target_sha" "$main_ref"; then
		die "Release target $target_sha is not reachable from origin/main."
	fi
}

emit_result() {
	local should_release="$1"
	local reason="$2"

	append_github_output should_release "$should_release" "$GITHUB_OUTPUT_PATH"
	append_github_output tag "$release_tag" "$GITHUB_OUTPUT_PATH"
	append_github_output target_sha "$target_sha" "$GITHUB_OUTPUT_PATH"
	append_github_output version "$version" "$GITHUB_OUTPUT_PATH"
	append_github_output build_number "$build_number" "$GITHUB_OUTPUT_PATH"

	write_json_file "$SUMMARY_PATH" \
		--arg status "passed" \
		--arg should_release "$should_release" \
		--arg reason "$reason" \
		--arg event_name "$EVENT_NAME" \
		--arg ref_name "$REF_NAME" \
		--arg ref_type "$REF_TYPE" \
		--arg tag "$release_tag" \
		--arg target_sha "$target_sha" \
		--arg version "$version" \
		--arg build_number "$build_number" \
		'{status: $status, should_release: ($should_release == "true"), reason: $reason, event_name: $event_name, ref_name: $ref_name, ref_type: $ref_type, tag: $tag, target_sha: $target_sha, version: $version, build_number: $build_number}'
}

target_sha="$(git rev-parse HEAD)"
version="$(release_read_project_value MARKETING_VERSION "$project_file")"
build_number="$(release_read_project_value CURRENT_PROJECT_VERSION "$project_file")"

release_require_semver "$version" "Invalid MARKETING_VERSION: $version. Expected MAJOR.MINOR.PATCH."
release_require_positive_integer "$build_number" "Invalid CURRENT_PROJECT_VERSION: $build_number. Expected a positive integer."

release_tag="v$version"

case "$EVENT_NAME" in
workflow_dispatch)
	release_require_tag "$INPUT_TAG" "Invalid input tag: $INPUT_TAG. Expected vMAJOR.MINOR.PATCH."
	[[ "$INPUT_TAG" == "$release_tag" ]] || die "Input tag $INPUT_TAG does not match MARKETING_VERSION $version."
	ensure_target_is_on_main "$target_sha"
	ensure_tag_matches_target_if_present "$release_tag" "$target_sha"
	emit_result true "manual_dispatch"
	;;
push)
	if [[ "$REF_TYPE" != "branch" || "$REF_NAME" != "main" ]]; then
		die "Unsupported push ref: $REF_TYPE/$REF_NAME"
	fi
	if [[ -z "$BEFORE_SHA" || "$BEFORE_SHA" =~ ^0+$ ]]; then
		die "Unable to compare against the previous main commit."
	fi
	previous_version="$(release_read_project_value_from_git MARKETING_VERSION "$BEFORE_SHA" "$project_file")"
	previous_build_number="$(release_read_project_value_from_git CURRENT_PROJECT_VERSION "$BEFORE_SHA" "$project_file")"
	release_require_positive_integer "$previous_build_number" "Previous CURRENT_PROJECT_VERSION is invalid: $previous_build_number."

	if [[ "$previous_version" == "$version" ]]; then
		existing_tag_sha="$(find_existing_tag_sha "$release_tag")"
		if [[ -n "$existing_tag_sha" ]]; then
			emit_result false "version_unchanged_existing_tag"
			info "MARKETING_VERSION is unchanged at $version; $release_tag already exists. Skipping release."
			exit 0
		fi
	elif [[ "$build_number" -le "$previous_build_number" ]]; then
		die "CURRENT_PROJECT_VERSION must increase when MARKETING_VERSION changes."
	fi

	ensure_tag_matches_target_if_present "$release_tag" "$target_sha"
	emit_result true "main_version_gate"
	;;
*)
	die "Unsupported event: $EVENT_NAME"
	;;
esac

info "Release prepare completed. should_release=$(jq -r '.should_release' "$SUMMARY_PATH") tag=$release_tag"
info "Summary: $SUMMARY_PATH"
