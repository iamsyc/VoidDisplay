#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/checkpoint.sh
source "$TOOL_ROOT/scripts/lib/checkpoint.sh"

mkdir -p "$AI_TMP_DIR"
fixture_root="$(mktemp -d "$AI_TMP_DIR/source-fingerprint.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
git -C "$fixture_root" init -q
git -C "$fixture_root" config user.email fingerprint@example.invalid
git -C "$fixture_root" config user.name fingerprint
mkdir -p "$fixture_root/Sources" "$fixture_root/docs"
printf 'initial\n' >"$fixture_root/Sources/example.swift"
printf 'docs\n' >"$fixture_root/README.md"
git -C "$fixture_root" add Sources README.md
git -C "$fixture_root" commit -qm initial

fingerprint() { ROOT_DIR="$fixture_root" source_tree_fingerprint "${1:-all}"; }
before="$(fingerprint)"
printf 'changed\n' >"$fixture_root/Sources/example.swift"
edited="$(fingerprint)"
[[ "$before" != "$edited" ]] || die "Source edits did not invalidate the fingerprint."
git -C "$fixture_root" add Sources/example.swift
git -C "$fixture_root" commit -qm changed
[[ "$edited" == "$(fingerprint)" ]] || die "Committing identical file content invalidated test evidence."

before="$(fingerprint xcode)"
all_before="$(fingerprint)"
printf 'updated documentation\n' >"$fixture_root/README.md"
printf 'new documentation\n' >"$fixture_root/docs/testing.md"
[[ "$before" == "$(fingerprint xcode)" ]] || die "Documentation invalidated Xcode test inputs."
[[ "$all_before" != "$(fingerprint)" ]] || die "Static validation failed to observe documentation changes."

printf 'new source\n' >"$fixture_root/Sources/new file.swift"
added="$(fingerprint xcode)"
[[ "$before" != "$added" ]] || die "Untracked source was omitted from Xcode inputs."
chmod +x "$fixture_root/Sources/new file.swift"
[[ "$added" != "$(fingerprint xcode)" ]] || die "Executable mode was omitted from the fingerprint."
rm "$fixture_root/Sources/new file.swift"
[[ "$before" == "$(fingerprint xcode)" ]] || die "Removing an untracked input did not restore the fingerprint."
rm "$fixture_root/Sources/example.swift"
[[ "$before" != "$(fingerprint xcode)" ]] || die "Deleted source reused stale evidence."

# Binary content must not be interchangeable with another file's metadata record.
mkdir -p "$fixture_root/Sources/Example/Resources"
node - "$fixture_root" <<'NODE'
const { writeFileSync } = require("node:fs");
const root = process.argv[2];
writeFileSync(`${root}/Sources/Example/Resources/A.bin`, Buffer.from([
    "first", "Sources/Example/Resources/B.bin", "0", "file", "second"
].join("\0")));
NODE
binary_all="$(fingerprint)"
binary_xcode="$(fingerprint xcode)"
printf 'first' >"$fixture_root/Sources/Example/Resources/A.bin"
printf 'second' >"$fixture_root/Sources/Example/Resources/B.bin"
[[ "$binary_all" != "$(fingerprint)" ]] || die "Splitting binary content into a second file reused validation evidence."
[[ "$binary_xcode" != "$(fingerprint xcode)" ]] || die "Splitting binary content into a second file reused Xcode products."

info "Content and Xcode input fingerprint regressions passed."
