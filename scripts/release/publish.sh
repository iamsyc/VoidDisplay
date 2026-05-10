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

cd "$ROOT_DIR"

ASSETS_DIR=""
TAG=""
TARGET_SHA=""
REPOSITORY="${GITHUB_REPOSITORY:-iamsyc/VoidDisplay}"
OUT_DIR="${OUT_DIR:-$(make_artifact_dir release-publish)}"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--assets-dir)
		ASSETS_DIR="$(normalize_path "$2")"
		shift 2
		;;
	--tag)
		TAG="$2"
		shift 2
		;;
	--target-sha)
		TARGET_SHA="$2"
		shift 2
		;;
	--repository)
		REPOSITORY="$2"
		shift 2
		;;
	--out-dir)
		OUT_DIR="$(normalize_path "$2")"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

require_command gh git jq
mkdir -p "$OUT_DIR"

publish_stage="input_validation"
publish_summary_written="false"
version=""
build_number=""
release_files=()

write_publish_summary() {
	local status="$1"
	local reason="$2"
	local detail="$3"
	local file_count="${4:-${#release_files[@]}}"

	write_json_file "$OUT_DIR/publish-summary.json" \
		--arg status "$status" \
		--arg reason "$reason" \
		--arg detail "$detail" \
		--arg tag "$TAG" \
		--arg target_sha "$TARGET_SHA" \
		--arg repository "$REPOSITORY" \
		--arg version "$version" \
		--arg build_number "$build_number" \
		--argjson file_count "$file_count" \
		'{status: $status, reason: $reason, detail: $detail, tag: $tag, target_sha: $target_sha, repository: $repository, version: $version, build_number: $build_number, file_count: $file_count}'
	publish_summary_written="true"
}

fail_publish() {
	local reason="$1"
	local detail="$2"

	release_fail write_publish_summary "$reason" "$detail"
}

handle_publish_exit() {
	local exit_code="$?"

	release_stage_failure_once "$exit_code" "$publish_summary_written" \
		write_publish_summary "$publish_stage" "Release publish failed in stage ${publish_stage}."
}
trap handle_publish_exit EXIT

[[ -d "$ASSETS_DIR" ]] || fail_publish "missing_assets_dir" "--assets-dir must point to an existing directory."
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail_publish "invalid_tag" "--tag must match vMAJOR.MINOR.PATCH."
[[ -n "$TARGET_SHA" ]] || fail_publish "missing_target_sha" "--target-sha is required."

publish_stage="version_metadata"
version="$(release_read_project_value MARKETING_VERSION)"
build_number="$(release_read_project_value CURRENT_PROJECT_VERSION)"
arm64_label="$(release_label_for_arch arm64)"
x86_64_label="$(release_label_for_arch x86_64)"

[[ "$TAG" == "v$version" ]] || fail_publish "version_mismatch" "Tag $TAG does not match MARKETING_VERSION $version."
[[ "$build_number" =~ ^[0-9]+$ ]] || fail_publish "invalid_build_number" "Invalid CURRENT_PROJECT_VERSION: $build_number"

publish_stage="git_tag"
git fetch --tags --force
existing_tag_sha="$(git rev-parse -q --verify "refs/tags/${TAG}^{commit}" 2>/dev/null || true)"
if [[ -n "$existing_tag_sha" && "$existing_tag_sha" != "$TARGET_SHA" ]]; then
	fail_publish "tag_conflict" "Tag $TAG already points to $existing_tag_sha, expected $TARGET_SHA."
fi
if [[ -z "$existing_tag_sha" ]]; then
	git config user.name "github-actions[bot]"
	git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
	git tag -a "$TAG" "$TARGET_SHA" -m "Release $TAG"
	git push origin "refs/tags/${TAG}"
fi

notes_path="$OUT_DIR/release-notes.md"
publish_stage="release_notes"
cat >"$notes_path" <<NOTES
VoidDisplay $TAG

Build number: $build_number
Target commit: $TARGET_SHA

Assets include arm64 and Intel DMG files, SHA256 checksums, SPDX SBOM files, and GitHub artifact attestations.

Verify checksum:

\`\`\`sh
shasum -a 256 -c VoidDisplay-$TAG-$arm64_label.dmg.sha256
shasum -a 256 -c VoidDisplay-$TAG-$x86_64_label.dmg.sha256
\`\`\`

Verify artifact attestation:

\`\`\`sh
gh attestation verify VoidDisplay-$TAG-$arm64_label.dmg --repo $REPOSITORY
gh attestation verify VoidDisplay-$TAG-$x86_64_label.dmg --repo $REPOSITORY
\`\`\`

This build is ad hoc signed only. It is not Developer ID signed, notarized, or stapled, and Apple has not certified it. macOS may require manual confirmation the first time the app is opened.
NOTES

publish_stage="collect_assets"
while IFS= read -r file_path; do
	[[ -n "$file_path" ]] && release_files+=("$file_path")
done < <(
	find "$ASSETS_DIR" -maxdepth 1 -type f \( \
		-name '*.dmg' -o \
		-name '*.sha256' -o \
		-name '*.spdx.json' -o \
		-name '*.summary.json' -o \
		-name '*.verify-summary.json' \
		\) | sort
)

if [[ "${#release_files[@]}" -eq 0 ]]; then
	fail_publish "missing_release_files" "No release files found in $ASSETS_DIR."
fi

publish_stage="gh_release_create"
if ! gh release create "$TAG" "${release_files[@]}" \
	--repo "$REPOSITORY" \
	--target "$TARGET_SHA" \
	--title "VoidDisplay $TAG" \
	--notes-file "$notes_path" \
	--latest; then
	fail_publish "gh_release_create_failed" "GitHub release creation failed."
fi

write_publish_summary "published" "published" "Release published." "${#release_files[@]}"

info "Release published: $TAG"
info "Summary: $OUT_DIR/publish-summary.json"
