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

[[ -d "$ASSETS_DIR" ]] || die "--assets-dir must point to an existing directory."
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--tag must match vMAJOR.MINOR.PATCH."
[[ -n "$TARGET_SHA" ]] || die "--target-sha is required."

require_command gh git jq
mkdir -p "$OUT_DIR"

project_file="Apps/VoidDisplay/VoidDisplay.xcodeproj/project.pbxproj"
version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$project_file" | sort -u)"
build_number="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' "$project_file" | sort -u)"
arm64_label="$(release_label_for_arch arm64)"
x86_64_label="$(release_label_for_arch x86_64)"

[[ "$TAG" == "v$version" ]] || die "Tag $TAG does not match MARKETING_VERSION $version."
[[ "$build_number" =~ ^[0-9]+$ ]] || die "Invalid CURRENT_PROJECT_VERSION: $build_number"

git fetch --tags --force
existing_tag_sha="$(git rev-parse -q --verify "refs/tags/${TAG}^{commit}" 2>/dev/null || true)"
if [[ -n "$existing_tag_sha" && "$existing_tag_sha" != "$TARGET_SHA" ]]; then
	die "Tag $TAG already points to $existing_tag_sha, expected $TARGET_SHA."
fi
if [[ -z "$existing_tag_sha" ]]; then
	git config user.name "github-actions[bot]"
	git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
	git tag -a "$TAG" "$TARGET_SHA" -m "Release $TAG"
	git push origin "refs/tags/${TAG}"
fi

notes_path="$OUT_DIR/release-notes.md"
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

This build is ad hoc signed. It is not Developer ID signed, notarized, or stapled. macOS may require manual confirmation the first time the app is opened.
NOTES

release_files=()
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
	die "No release files found in $ASSETS_DIR."
fi

gh release create "$TAG" "${release_files[@]}" \
	--repo "$REPOSITORY" \
	--target "$TARGET_SHA" \
	--title "VoidDisplay $TAG" \
	--notes-file "$notes_path" \
	--latest

write_json_file "$OUT_DIR/publish-summary.json" \
	--arg status "published" \
	--arg tag "$TAG" \
	--arg target_sha "$TARGET_SHA" \
	--arg repository "$REPOSITORY" \
	--arg version "$version" \
	--arg build_number "$build_number" \
	--argjson file_count "${#release_files[@]}" \
	'{status: $status, tag: $tag, target_sha: $target_sha, repository: $repository, version: $version, build_number: $build_number, file_count: $file_count}'

info "Release published: $TAG"
info "Summary: $OUT_DIR/publish-summary.json"
