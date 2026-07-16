#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

require_command git jq

WORK_DIR="${WORK_DIR:-$(make_artifact_dir classify-tests)}"
FIXTURE_REPO="$WORK_DIR/repo"
mkdir -p "$FIXTURE_REPO"

git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.email "ci@example.invalid"
git -C "$FIXTURE_REPO" config user.name "CI Classify Test"
printf 'base\n' >"$FIXTURE_REPO/.fixture-base"
git -C "$FIXTURE_REPO" add .fixture-base
git -C "$FIXTURE_REPO" commit -qm "base"
BASE_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

write_fixture_file() {
	local file_path="$1"
	local full_path="$FIXTURE_REPO/$file_path"
	mkdir -p "$(dirname "$full_path")"
	case "$file_path" in
	mise.toml | mise.lock)
		printf '[tools]\n' >"$full_path"
		;;
	*)
		printf 'fixture: %s\n' "$file_path" >"$full_path"
		;;
	esac
}

assert_summary_fields() {
	local summary_path="$1"
	local spec
	local field
	local expected
	local actual
	shift

	for spec in "$@"; do
		field="${spec%%=*}"
		expected="${spec#*=}"
		actual="$(jq -r ".$field" "$summary_path")"
		if [[ "$actual" != "$expected" ]]; then
			die "$(basename "$summary_path" .json) expected $field=$expected, got $actual"
		fi
	done
}

run_classify() {
	local name="$1"
	local event_name="$2"
	local base_ref="$3"
	local base_sha="$4"
	local head_sha="$5"
	local summary_path="$WORK_DIR/$name.json"
	shift 5

	env EVENT_NAME="$event_name" BASE_REF="$base_ref" ROOT_DIR="$FIXTURE_REPO" TOOL_ROOT="$TOOL_ROOT" \
		"$TOOL_ROOT/scripts/ci/classify.sh" \
		--base "$base_sha" \
		--head "$head_sha" \
		--summary "$summary_path" >/dev/null

	assert_summary_fields "$summary_path" "$@"
}

run_file_case() {
	local name="$1"
	local event_name="$2"
	local base_ref="$3"
	local specs="$4"
	local head_sha
	shift 4

	git -C "$FIXTURE_REPO" checkout -q -B "case-$name" "$BASE_COMMIT"
	git -C "$FIXTURE_REPO" clean -fdq
	for file_path in "$@"; do
		write_fixture_file "$file_path"
	done
	git -C "$FIXTURE_REPO" add -A
	git -C "$FIXTURE_REPO" commit -qm "$name"
	head_sha="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

	# shellcheck disable=SC2086
	run_classify "$name" "$event_name" "$base_ref" "$BASE_COMMIT" "$head_sha" $specs
}

run_rename_case() {
	local name="$1"
	local old_path="$2"
	local new_path="$3"
	local specs="$4"
	local case_base
	local head_sha

	git -C "$FIXTURE_REPO" checkout -q -B "base-$name" "$BASE_COMMIT"
	git -C "$FIXTURE_REPO" clean -fdq
	write_fixture_file "$old_path"
	git -C "$FIXTURE_REPO" add -A
	git -C "$FIXTURE_REPO" commit -qm "$name base"
	case_base="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

	mkdir -p "$(dirname "$FIXTURE_REPO/$new_path")"
	git -C "$FIXTURE_REPO" mv "$old_path" "$new_path"
	git -C "$FIXTURE_REPO" commit -qm "$name head"
	head_sha="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

	# shellcheck disable=SC2086
	run_classify "$name" "pull_request" "main" "$case_base" "$head_sha" $specs
}

run_file_case docs_only pull_request main \
	"docs_only=true code_relevant=false requires_static=true requires_unit=true requires_xcode_build=true unknown_relevant=false" \
	docs/change.md
run_file_case codeql_workflow pull_request main \
	"ci_config_relevant=true script_relevant=true code_relevant=true requires_static=true requires_unit=true requires_xcode_build=true" \
	.github/workflows/codeql.yml
run_file_case mise_config pull_request main \
	"tooling_config_relevant=true ci_config_relevant=true requires_static=true requires_dependency_review=false requires_unit=true requires_xcode_build=true" \
	mise.toml
run_file_case mise_lock pull_request main \
	"tooling_config_relevant=true ci_config_relevant=true requires_static=true requires_dependency_review=false requires_unit=true requires_xcode_build=true" \
	mise.lock
run_file_case package_manifest pull_request main \
	"product_code_relevant=true dependency_manifest_relevant=true requires_dependency_review=true requires_unit=true requires_xcode_build=true" \
	Package.swift
run_file_case xcode_project pull_request main \
	"code_relevant=true product_code_relevant=true ui_relevant=true release_relevant=true requires_release_smoke=true requires_ui_smoke=true requires_unit=true requires_xcode_build=true unknown_relevant=false" \
	VoidDisplay.xcodeproj/project.pbxproj
run_file_case nested_package_resolved pull_request main \
	"code_relevant=true product_code_relevant=true dependency_manifest_relevant=true requires_dependency_review=true requires_unit=true requires_xcode_build=true unknown_relevant=false" \
	VoidDisplay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
run_file_case go_manifest pull_request main \
	"product_code_relevant=true dependency_manifest_relevant=true release_relevant=true requires_release_smoke=true requires_unit=true requires_xcode_build=true" \
	Tools/VoidDisplayRelay/go.mod
run_file_case swift_tests pull_request main \
	"test_code_relevant=true requires_unit=true requires_xcode_build=true requires_ui_smoke=false" \
	Tests/VoidDisplayFoundationTests/FooTests.swift
run_file_case ui_tests pull_request main \
	"test_code_relevant=true ui_relevant=true requires_unit=true requires_xcode_build=true requires_ui_smoke=true" \
	UITests/VoidDisplayUITests/FooUITests.swift
run_file_case foundation_source pull_request main \
	"product_code_relevant=true ui_relevant=false release_relevant=false requires_unit=true requires_xcode_build=true" \
	Sources/VoidDisplayFoundation/Foo.swift
run_file_case app_source pull_request main \
	"product_code_relevant=true ui_relevant=true requires_ui_smoke=true requires_unit=true" \
	Sources/VoidDisplayApp/Foo.swift
run_file_case app_resource pull_request main \
	"product_code_relevant=true ui_relevant=true release_relevant=true requires_release_smoke=true requires_ui_smoke=true" \
	Apps/VoidDisplay/Resources/Localizable.xcstrings
run_file_case release_script pull_request main \
	"ci_config_relevant=true script_relevant=true release_relevant=true requires_static=true requires_release_smoke=true requires_unit=true requires_xcode_build=true" \
	scripts/ci/release_smoke.sh
run_file_case unknown_path pull_request main \
	"unknown_relevant=true docs_only=false code_relevant=false requires_static=true requires_unit=true requires_xcode_build=true requires_ui_smoke=true" \
	Config/new.yml
run_file_case main_push_docs push "" \
	"docs_only=true requires_static=true requires_unit=true requires_xcode_build=true requires_ui_smoke=true requires_release_smoke=true" \
	docs/push.md
run_file_case license_variant_docs pull_request main \
	"docs_only=true code_relevant=false requires_static=true requires_unit=true requires_xcode_build=true unknown_relevant=false" \
	LICENSE_THIRD_PARTY

run_rename_case rename_docs_to_code docs/old.md Sources/VoidDisplayFoundation/Renamed.swift \
	"docs_only=false product_code_relevant=true code_relevant=true requires_unit=true requires_xcode_build=true"
run_rename_case rename_code_to_docs Sources/VoidDisplayFoundation/Old.swift docs/new.md \
	"docs_only=false product_code_relevant=true code_relevant=true requires_unit=true requires_xcode_build=true"

run_classify full_scan pull_request main 0000000000000000000000000000000000000000 "$BASE_COMMIT" \
	reason=full_scan \
	code_relevant=true \
	ui_relevant=true \
	requires_unit=true \
	requires_xcode_build=true

info "Classify fixtures passed."
