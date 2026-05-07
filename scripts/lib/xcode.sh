#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_XCODE_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_XCODE_SH_SOURCED=1

	# shellcheck source=scripts/lib/common.sh
	source "$TOOL_ROOT/scripts/lib/common.sh"

	select_required_xcode() {
		local expected_xcode_prefix="${EXPECTED_XCODE_VERSION_PREFIX:-26.4}"
		local expected_swift_prefix="${EXPECTED_SWIFT_VERSION_PREFIX:-6.}"
		local candidates=()
		local candidate

		if [[ -n "${DEVELOPER_DIR:-}" ]]; then
			candidates+=("$DEVELOPER_DIR")
		fi
		candidates+=(
			"/Applications/Xcode-26.4.0.app/Contents/Developer"
			"/Applications/Xcode_26.4.app/Contents/Developer"
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
fi
