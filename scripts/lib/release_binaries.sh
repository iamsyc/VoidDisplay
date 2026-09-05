#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_RELEASE_BINARIES_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_RELEASE_BINARIES_SH_SOURCED=1

	# shellcheck source=scripts/lib/common.sh
	source "$TOOL_ROOT/scripts/lib/common.sh"

	resolve_app_binary() {
		local app_path="$1"
		local info_plist="$app_path/Contents/Info.plist"
		local executable

		[[ -d "$app_path" ]] || die "Expected app not found: $app_path"
		[[ -f "$info_plist" ]] || die "Expected Info.plist not found: $info_plist"

		executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null || true)"
		[[ -n "$executable" ]] || die "Failed to read CFBundleExecutable from $info_plist"
		[[ -f "$app_path/Contents/MacOS/$executable" ]] || die "Expected app binary not found: $app_path/Contents/MacOS/$executable"
		printf '%s\n' "$app_path/Contents/MacOS/$executable"
	}

	resolve_webrtc_binary() {
		local framework_path="$1"
		local candidate
		local link_target

		[[ -d "$framework_path" ]] || die "Expected WebRTC framework not found: $framework_path"

		for candidate in \
			"$framework_path/Versions/Current/WebRTC" \
			"$framework_path/Versions/A/WebRTC" \
			"$framework_path/WebRTC"; do
			if [[ -f "$candidate" ]]; then
				if [[ -L "$candidate" ]]; then
					link_target="$(readlink "$candidate")"
					[[ -n "$link_target" ]] || die "Failed to resolve symlink target: $candidate"
					case "$link_target" in
					/*) printf '%s\n' "$link_target" ;;
					*) printf '%s\n' "$(cd "$(dirname "$candidate")" && pwd)/$link_target" ;;
					esac
				else
					printf '%s\n' "$candidate"
				fi
				return 0
			fi
		done

		candidate="$(find "$framework_path" -type f -name WebRTC | head -n 1 || true)"
		[[ -n "$candidate" ]] || die "Failed to locate WebRTC binary under: $framework_path"
		printf '%s\n' "$candidate"
	}

	require_binary_arch() {
		local label="$1"
		local binary_path="$2"
		local expected_arch="$3"
		local actual_archs

		[[ -f "$binary_path" ]] || die "$label binary not found: $binary_path"
		require_command lipo
		actual_archs="$(lipo -archs "$binary_path")"
		[[ "$actual_archs" == "$expected_arch" ]] || die "$label binary arch mismatch. Expected $expected_arch, got $actual_archs"
	}

	validate_release_app_binaries() {
		local app_path="$1"
		local expected_arch="$2"
		local app_binary
		local webrtc_binary
		local relay_binary="$app_path/Contents/Resources/voiddisplay-relay"
		local host_binary="$app_path/Contents/MacOS/VoidDisplayHost"

		app_binary="$(resolve_app_binary "$app_path")"
		webrtc_binary="$(resolve_webrtc_binary "$app_path/Contents/Frameworks/WebRTC.framework")"

		[[ -x "$host_binary" ]] || die "Expected display host to be executable: $host_binary"
		[[ -x "$relay_binary" ]] || die "Expected relay binary to be executable: $relay_binary"

		require_binary_arch "App" "$app_binary" "$expected_arch"
		require_binary_arch "WebRTC" "$webrtc_binary" "$expected_arch"
		require_binary_arch "Display host" "$host_binary" "$expected_arch"
		require_binary_arch "Relay" "$relay_binary" "$expected_arch"
	}

	thin_and_sign_release_app() {
		local app_path="$1"
		local expected_arch="$2"
		local webrtc_framework="$app_path/Contents/Frameworks/WebRTC.framework"
		local webrtc_binary
		local temp_binary
		local relay_binary="$app_path/Contents/Resources/voiddisplay-relay"
		local host_binary="$app_path/Contents/MacOS/VoidDisplayHost"

		[[ -d "$app_path" ]] || die "Expected app not found: $app_path"
		[[ -x "$host_binary" ]] || die "Expected display host to be executable: $host_binary"
		[[ -x "$relay_binary" ]] || die "Expected relay binary to be executable: $relay_binary"
		webrtc_binary="$(resolve_webrtc_binary "$webrtc_framework")"

		info "WebRTC binary before thin: $webrtc_binary"
		lipo -archs "$webrtc_binary"
		temp_binary="$webrtc_binary.thin"
		lipo -thin "$expected_arch" "$webrtc_binary" -output "$temp_binary"
		mv "$temp_binary" "$webrtc_binary"
		chmod +x "$webrtc_binary"
		info "WebRTC binary after thin:"
		lipo -archs "$webrtc_binary"

		require_binary_arch "Display host" "$host_binary" "$expected_arch"
		require_binary_arch "Relay" "$relay_binary" "$expected_arch"
		info "Applying ad hoc signature for local release packaging. Developer ID signing and notarization are not configured."
		codesign --force --sign - --timestamp=none "$host_binary"
		codesign --force --sign - --timestamp=none "$relay_binary"
		codesign --force --sign - --timestamp=none "$webrtc_framework"
		codesign --force --sign - --timestamp=none --deep "$app_path"
		codesign --verify --deep --strict --verbose=2 "$app_path"
		codesign --verify --strict --verbose=2 "$host_binary"
		codesign --verify --strict --verbose=2 "$relay_binary"

		validate_release_app_binaries "$app_path" "$expected_arch"
	}
fi
