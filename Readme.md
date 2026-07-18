<div align="center">
  <img src="./docs/imgs/AppIcon.png" width="150" height="150"/>
  <h1>VoidDisplay</h1>
  <p>Create virtual displays, monitor screens, and share them over LAN from your Mac.</p>
  <a href="./docs/Readme_cn-zh.md">简体中文</a>
</div>

## ✨ Features

### 🖥️ Virtual Displays

Create virtual monitors with custom resolution and refresh rate.  
Perfect for headless Mac setups, display testing, or extending your workspace without a physical monitor.

### 👀 Screen Monitoring

Watch any connected display in its own dedicated floating window.  
Great for keeping an eye on a secondary screen without switching desktops.

### 📡 LAN Screen Sharing

Share any display over your local network through the built-in low-latency live page.  
Open the generated capability-protected `/display` URL in a modern browser on a trusted LAN. Playback uses WebRTC media streaming with WebSocket signaling.

## 📸 Screenshots

### Display Overview

View all active displays, including virtual displays and their resolutions.

![Display overview](./docs/imgs/display-overview.png)

### Virtual Display Management

Create, start, stop, reorder, edit, and remove virtual displays from one list.

![Virtual display management](./docs/imgs/virtual-display-management.png)

### Screen Monitoring

Start or stop monitoring for each display, with status shown directly in the list.

![Screen monitoring list](./docs/imgs/screen-monitoring-list.png)

### Live Monitor Window

Watch a display in a dedicated viewer with fit, 1:1, full screen, and cursor controls.

![Live monitor window](./docs/imgs/live-monitor-window.png)

### Screen Sharing Service

Start the local web service, choose sharing smoothness, and configure the port.

![Screen sharing service settings](./docs/imgs/sharing-service-settings.png)

### Sharing Links

Share individual displays and copy per-display LAN viewing links.

![Sharing display links](./docs/imgs/sharing-display-links.png)

### Browser Live View

Open the live page from another device to view the shared display in a browser.

![Browser live view](./docs/imgs/browser-live-view.png)

## 💻 System Requirements

- macOS 15.6 or later
- Intel or Apple Silicon Mac

## 📥 Installation

### Download

Check the [Releases](https://github.com/iamsyc/VoidDisplay/releases) page for the latest build.

### Unsigned Build Notice (First Launch)

Current release builds are ad hoc signed only. They are not Developer ID signed, notarized, or certified by Apple, so macOS may block first launch with messages like:
- "cannot be opened because Apple cannot check it for malicious software"
- "is damaged and can't be opened"

If this happens:
1. Try Finder right-click on `VoidDisplay.app` -> **Open**.
2. If still blocked, run:

```bash
xattr -dr com.apple.quarantine "/Applications/VoidDisplay.app"
```

### Build from Source

1. Clone this repository.
2. Open `VoidDisplay.xcworkspace` in Xcode 26+.
3. Build and run (⌘R).

## 🚀 Getting Started

### Create a Virtual Display

1. Open VoidDisplay and go to the **Virtual Display** tab.
2. Click the **+** button to add a new virtual display.
3. Choose a preset or configure a custom resolution and refresh rate.
4. The virtual display appears immediately in your macOS display arrangement.

### Monitor a Screen

1. Go to the **Screen Monitoring** tab.
2. Select the display you want to monitor.
3. A floating window opens showing the live content of that display.

### Share a Screen over LAN

1. Go to the **Screen Sharing** tab.
2. Start the web service and choose the sharing smoothness mode.
3. Click **Share** next to the display you want to broadcast.
4. Copy the generated LAN URL, such as `http://192.168.x.x:18090/display/1/{capability}`.
5. Open that URL in a modern browser on the same network to watch the screen in real time.

Notes:
- `/display/{capability}` and `/display/{id}/{capability}` are the protected page routes.
- `/signal/{capability}` and `/signal/{id}/{capability}` are the protected WebSocket signaling routes.
- The capability rotates whenever sharing restarts. Old and credentialless links are rejected.
- HTTP and WebSocket traffic is not encrypted. Use LAN sharing only on a trusted network and do not expose it through public port forwarding or tunnels. See [LAN Web View security](./docs/lan-sharing-security.md).

## ❓ Troubleshooting

**No displays appear in Screen Monitoring or Screen Sharing?**

> macOS requires Screen Recording permission. Go to **System Settings → Privacy & Security → Screen Recording** and make sure VoidDisplay is enabled. If you changed the permission while the app was running, fully quit and reopen it.

**The shared screen page won't open from another device?**

> Make sure your Mac and the viewing device are on the same local network (Wi-Fi or Ethernet). The URL shown in the app must be reachable from the other device.

**The browser opens but playback does not start?**

> The live page requires a modern browser with `WebSocket` and `RTCPeerConnection` support. Use a current Chromium-based browser or a recent Safari/WebKit build on the viewing device.

**Virtual display failed to restore on app launch?**

> If a virtual display fails to restore, you'll see an alert in the Virtual Display tab. If the configuration file is corrupted, you can reset it by deleting:  
> `~/Library/Application Support/com.developerchen.voiddisplay/virtual-displays.json`

## 🛠️ For Developers

### Build & Test

Requirements: Xcode 26+, macOS 15.6 or later on an Intel or Apple Silicon Mac.

```bash
# Install pinned local tooling with mise or Homebrew fallback
scripts/dev/bootstrap.sh
scripts/dev/doctor.sh

# Static checks, SwiftPM tests, Go tests, Xcode build, and UI smoke
scripts/dev/validate.sh
```

`VoidDisplay` in Xcode is the app build/run and UI test scheme. Cmd-U does not run the SwiftPM unit tests under `Tests/`; use `scripts/dev/validate.sh` or `scripts/ci/unit.sh` for unit coverage.

Full project regression gate (heavier release-oriented check before opening/merging PR):

```bash
scripts/ci/full_regression.sh
```

This script runs end-to-end test/build gates and fails fast when:
- tests were not actually executed (`totalTestCount == 0`)
- any test failed
- Debug/Release build has warnings
- Debug/Release build failed

CI workflow details and manual UI smoke dispatch are documented in `docs/testing/ci-workflows.md`.

Release assets include a DMG, SHA256 checksum, SPDX SBOM, and GitHub artifact attestation. To verify downloaded release assets:

```bash
scripts/release/verify.sh \
  --assets-dir release-assets \
  --tag vX.Y.Z \
  --label arm64 \
  --arch arm64 \
  --repository iamsyc/VoidDisplay \
  --require-attestation true
```

### Debug Entry Points

UI entry: `HomeView` contains four tabs: **Displays**, **Virtual Display**, **Screen Monitoring**, **Screen Sharing**.

Key files for debugging:

| Area | Files |
|------|-------|
| Virtual Display | `Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayOrchestrator.swift`, `Sources/VoidDisplayVirtualDisplay/Views/CreateVirtualDisplayObjectView.swift`, `Sources/VoidDisplayVirtualDisplay/Views/EditVirtualDisplayConfigView.swift` |
| Screen Capture | `Sources/VoidDisplayCapture/ViewModels/CaptureChooseViewModel.swift`, `Sources/VoidDisplayCapture/Services/DisplayCaptureRegistry.swift`, `Sources/VoidDisplayCapture/Services/DisplayCaptureSession.swift`, `Sources/VoidDisplayFoundation/RuntimeSupport/DisplayStartCoordinator.swift` |
| LAN Sharing | `Sources/VoidDisplaySharing/ViewModels/ShareViewModel.swift`, `Sources/VoidDisplaySharing/Services/SharingService.swift`, `Sources/VoidDisplaySharing/Web/WebServer.swift` |

Unified logs (`Logger`, subsystem `com.developerchen.voiddisplay`):

```bash
log stream --style compact --predicate 'subsystem == "com.developerchen.voiddisplay"'
```

## 📄 License

[Apache License 2.0](./LICENSE)

## 🤝 Project Lineage

VoidDisplay is a long-term maintained continuation of the original project by Phineas Guo:
[guoPhineas/FreelyDisplay](https://github.com/guoPhineas/FreelyDisplay).

The current repository is maintained at
[iamsyc/VoidDisplay](https://github.com/iamsyc/VoidDisplay), with upstream contribution history preserved in Git.

## 🙏 Acknowledgements

This project uses the private `CGVirtualDisplay` framework. See [LICENSE_CGVirtualDisplay](./LICENSE_CGVirtualDisplay) for details.
