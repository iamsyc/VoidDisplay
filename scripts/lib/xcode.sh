#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_XCODE_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_XCODE_SH_SOURCED=1

	# shellcheck source=scripts/lib/common.sh
	source "$TOOL_ROOT/scripts/lib/common.sh"

	select_required_xcode() {
		local expected_xcode_prefix="${EXPECTED_XCODE_VERSION_PREFIX:-26.6}"
		local expected_swift_prefix="${EXPECTED_SWIFT_VERSION_PREFIX:-6.3}"
		local candidates=()
		local candidate

		if [[ -n "${DEVELOPER_DIR:-}" ]]; then
			candidates+=("$DEVELOPER_DIR")
		fi
		candidates+=(
			"/Applications/Xcode-26.6.0.app/Contents/Developer"
			"/Applications/Xcode_26.6.app/Contents/Developer"
			"/Applications/Xcode_26.6.0.app/Contents/Developer"
			"/Applications/Xcode.app/Contents/Developer"
		)

		for candidate in "${candidates[@]}"; do
			[[ -d "$candidate" ]] || continue

			if [[ "$(xcode-select -p 2>/dev/null || true)" == "$candidate" ]]; then
				export DEVELOPER_DIR="$candidate"
			elif sudo -n xcode-select -s "$candidate" >/dev/null 2>&1; then
				export DEVELOPER_DIR="$candidate"
			else
				export DEVELOPER_DIR="$candidate"
				warn "Using DEVELOPER_DIR=$candidate because xcode-select could not switch without sudo."
			fi

			local xcode_version
			local swift_version
			xcode_version="$(xcodebuild -version | awk 'NR==1{print $2}')"
			swift_version="$(swift --version 2>&1 | awk 'match($0, /Swift version [0-9.]+/) { print substr($0, RSTART + 14, RLENGTH - 14); exit }')"

			if [[ "$xcode_version" == "$expected_xcode_prefix"* && "$swift_version" == "$expected_swift_prefix"* ]]; then
				info "Selected Xcode $xcode_version at $candidate"
				info "Swift version $swift_version"
				return 0
			fi

			warn "Rejected Xcode at $candidate: Xcode=$xcode_version Swift=$swift_version"
		done

		die "Required Xcode $expected_xcode_prefix with Swift $expected_swift_prefix was not found."
	}

	xcode_cache_suffix() {
		local xcode_version
		local xcode_build
		xcode_version="$(xcodebuild -version | awk 'NR==1{print $2}')"
		xcode_build="$(xcodebuild -version | awk 'NR==2{print $3}')"
		printf 'xcode-%s-%s\n' "$xcode_version" "$xcode_build"
	}

	xcode_test_products_manifest_path() {
		local derived_data_path="$1"
		printf '%s/Build/Products/voiddisplay-test-products.json\n' "$derived_data_path"
	}

	xcode_test_products_exist() {
		local derived_data_path="$1"
		local expected_configuration="$2"
		local expected_destination="$3"
		local expected_source_fingerprint="$4"
		local expected_xcode_identity="$5"
		local expected_root_dir="$6"
		local expected_project="$7"
		local expected_scheme="$8"
		local products_path="$derived_data_path/Build/Products"
		local manifest_path
		local xctestrun_path

		[[ -d "$products_path" ]] || return 1
		manifest_path="$(xcode_test_products_manifest_path "$derived_data_path")"
		[[ -s "$manifest_path" ]] || return 1
		jq -e \
			--arg configuration "$expected_configuration" \
			--arg destination "$expected_destination" \
			--arg source_fingerprint "$expected_source_fingerprint" \
			--arg xcode_identity "$expected_xcode_identity" \
			--arg root_dir "$expected_root_dir" \
			--arg project "$expected_project" \
			--arg scheme "$expected_scheme" \
			'.version == 1
			and .configuration == $configuration
			and .destination == $destination
			and .source_fingerprint == $source_fingerprint
			and .xcode_identity == $xcode_identity
			and .root_dir == $root_dir
			and .project == $project
			and .scheme == $scheme' \
			"$manifest_path" >/dev/null || return 1

		xctestrun_path="$(/usr/bin/find "$products_path" -type f -name '*.xctestrun' -size +0c -print -quit)"
		[[ -n "$xctestrun_path" ]]
	}

	require_xcode_test_products() {
		local derived_data_path="$1"

		xcode_test_products_exist "$@" ||
			die "Xcode test products are incomplete. Run build-for-testing first: $derived_data_path"
	}

	canonical_existing_path() {
		local path="$1"
		[[ -e "$path" ]] || die "Path does not exist: $path"
		if [[ -d "$path" ]]; then
			(cd "$path" && pwd -P)
			return
		fi
		local parent
		parent="$(cd "${path%/*}" && pwd -P)"
		printf '%s/%s\n' "$parent" "${path##*/}"
	}

	validate_development_project_path() {
		local project_path="$1"
		local expected_project_path="$2"
		local canonical_project_path
		local canonical_expected_project_path

		canonical_project_path="$(canonical_existing_path "$project_path")"
		canonical_expected_project_path="$(canonical_existing_path "$expected_project_path")"
		[[ "$canonical_project_path" == "$canonical_expected_project_path" ]] ||
			die "Development signing is limited to the repository VoidDisplay project: $canonical_expected_project_path"
	}

	development_requirement_expression() {
		local expected_identifier="$1"
		local expected_authority="$2"
		printf 'identifier "%s" and anchor apple generic and certificate leaf[subject.CN] = "%s" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */\n' \
			"$expected_identifier" \
			"$expected_authority"
	}

	development_signing_authority() {
		local app_path="$1"
		local metadata
		local authority

		metadata="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
		authority="$(
			awk '
				/^Authority=Apple Development:/ {
					sub(/^Authority=/, "")
					print
					exit
				}
			' <<<"$metadata"
		)"
		[[ "$authority" == "Apple Development: "* ]] ||
			die "Development-signed app does not use an Apple Development certificate."
		printf '%s\n' "$authority"
	}

	validate_development_signature_evidence() {
		local metadata="$1"
		local designated_requirement="$2"
		local expected_identifier="$3"
		local expected_team_identifier="$4"
		local expected_authority="$5"
		local actual_identifier
		local actual_team_identifier
		local authority
		local actual_designated_requirement
		local expected_designated_requirement

		actual_identifier="$(awk -F= '$1 == "Identifier" { print $2; exit }' <<<"$metadata")"
		actual_team_identifier="$(awk -F= '$1 == "TeamIdentifier" { print $2; exit }' <<<"$metadata")"
		authority="$(
			awk '
				/^Authority=Apple Development:/ {
					sub(/^Authority=/, "")
					print
					exit
				}
			' <<<"$metadata"
		)"

		[[ "$actual_identifier" == "$expected_identifier" ]] ||
			die "Development-signed app identifier mismatch: expected=$expected_identifier actual=${actual_identifier:-missing}"
		[[ "$actual_team_identifier" == "$expected_team_identifier" ]] ||
			die "Development-signed app team mismatch: expected=$expected_team_identifier actual=${actual_team_identifier:-missing}"
		[[ "$expected_authority" == "Apple Development: "* ]] ||
			die "Expected signing authority is not an Apple Development certificate: $expected_authority"
		[[ "$authority" == "$expected_authority" ]] ||
			die "Development-signed app authority mismatch: expected=$expected_authority actual=${authority:-missing}"
		! rg -q '(^Signature=adhoc$|CodeDirectory .*\badhoc\b|^TeamIdentifier=not set$)' <<<"$metadata" ||
			die "Development-signed app resolved to an ad hoc signature."
		rg -q '^CodeDirectory .*flags=.*\([^)]*\bruntime\b[^)]*\)' <<<"$metadata" ||
			die "Development-signed app does not enable Hardened Runtime."
		rg -q '^Info\.plist entries=[1-9][0-9]*$' <<<"$metadata" ||
			die "Development-signed app does not bind its Info.plist."
		rg -q '^Sealed Resources version=' <<<"$metadata" ||
			die "Development-signed app does not seal its resources."
		actual_designated_requirement="$(awk '/^designated => / { print; exit }' <<<"$designated_requirement")"
		expected_designated_requirement="designated => $(development_requirement_expression "$expected_identifier" "$expected_authority")"
		[[ "$actual_designated_requirement" == "$expected_designated_requirement" ]] ||
			die "Development-signed app designated requirement differs from the expected canonical requirement."
	}

	verify_development_signed_app() {
		local app_path="$1"
		local expected_identifier="$2"
		local expected_team_identifier="$3"
		local expected_authority="$4"
		local info_plist="$app_path/Contents/Info.plist"
		local bundle_identifier
		local metadata
		local designated_requirement
		local requirement_expression

		[[ -d "$app_path" ]] || die "Development-signed app is missing: $app_path"
		[[ -f "$info_plist" ]] || die "Development-signed app Info.plist is missing: $info_plist"

		bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
		[[ "$bundle_identifier" == "$expected_identifier" ]] ||
			die "Development-signed app bundle identifier mismatch: expected=$expected_identifier actual=$bundle_identifier"

		codesign --verify --deep --strict --verbose=2 "$app_path" ||
			die "Development-signed app failed strict code-signature verification."
		requirement_expression="$(development_requirement_expression "$expected_identifier" "$expected_authority")"
		codesign --verify --deep --strict --verbose=2 -R="$requirement_expression" "$app_path" ||
			die "Development-signed app failed the expected code requirement."
		metadata="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
		designated_requirement="$(codesign -dr - "$app_path" 2>&1)"
		validate_development_signature_evidence \
			"$metadata" \
			"$designated_requirement" \
			"$expected_identifier" \
			"$expected_team_identifier" \
			"$expected_authority"

		info "Verified Apple Development signature: $expected_authority"
		info "Verified signed app: $app_path"
	}
fi
