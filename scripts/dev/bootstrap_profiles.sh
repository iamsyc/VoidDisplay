#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_BOOTSTRAP_PROFILES_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_BOOTSTRAP_PROFILES_SH_SOURCED=1

	bootstrap_profile_exists() {
		case "$1" in
		full | static | unit | ui-smoke | xcode | release-smoke) return 0 ;;
		*) return 1 ;;
		esac
	}

	bootstrap_profile_commands() {
		case "$1" in
		full)
			printf '%s\n' actionlint shellcheck shfmt swiftformat swiftlint go jq rg syft gh git xcrun xcodebuild swift bash zsh awk diff lipo codesign
			;;
		static)
			printf '%s\n' actionlint shellcheck shfmt swiftformat swiftlint jq rg git xcrun bash zsh awk diff grep sort wc tr
			;;
		unit)
			printf '%s\n' git go jq rg xcodebuild swift awk
			;;
		ui-smoke)
			printf '%s\n' go jq rg xcodebuild grep xcrun awk tr tail
			;;
		xcode)
			printf '%s\n' git go jq rg xcodebuild swift xcrun awk tr tail
			;;
		release-smoke)
			printf '%s\n' go jq rg xcodebuild lipo codesign xcrun
			;;
		*)
			return 1
			;;
		esac
	}

	bootstrap_profile_mise_targets() {
		case "$1" in
		full)
			return 0
			;;
		static)
			printf '%s\n' \
				aqua:rhysd/actionlint \
				aqua:koalaman/shellcheck \
				aqua:mvdan/sh \
				swiftformat \
				aqua:realm/SwiftLint \
				aqua:jqlang/jq \
				aqua:BurntSushi/ripgrep
			;;
		unit | ui-smoke | xcode | release-smoke)
			printf '%s\n' go aqua:jqlang/jq aqua:BurntSushi/ripgrep
			;;
		*)
			return 1
			;;
		esac
	}
fi
