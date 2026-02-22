#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only supports macOS."
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode first."
  exit 1
fi

USER_NAME="${SUDO_USER:-$USER}"
DEVTOOLS="/usr/sbin/DevToolsSecurity"

if [[ ! -x "$DEVTOOLS" ]]; then
  echo "DevToolsSecurity tool not found at $DEVTOOLS."
  exit 1
fi

echo "==> Verifying sudo access (you may be prompted once)..."
sudo -v

echo "==> Enabling Developer Tools security policy..."
sudo "$DEVTOOLS" -enable

echo "==> Ensuring user is in _developer group: $USER_NAME"
if dseditgroup -o checkmember -m "$USER_NAME" _developer | grep -q "yes "; then
  echo "    already in _developer"
else
  sudo dseditgroup -o edit -a "$USER_NAME" -t user _developer
  echo "    added to _developer"
fi

echo "==> Running Xcode first-launch initialization..."
xcodebuild -runFirstLaunch

echo "==> Opening macOS Privacy panes for one-time manual approval..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_DeveloperTools" || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation" || true

cat <<'EOF'

Done.

To minimize future XCTest prompts:
1. In Privacy & Security -> Developer Tools, enable your test runner (Xcode / Terminal / iTerm).
2. In Accessibility and Automation, enable the same app(s) if your UI tests require interaction.
3. Log out and back in once (or reboot) after group membership changes.

Note:
- macOS may still ask again after major Xcode/macOS updates.
- This is expected system security behavior and cannot be fully bypassed safely.
EOF
