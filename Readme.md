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

### Live Monitor Window

Watch a display in a dedicated viewer with fit, 1:1, full screen, and cursor controls.

![Live monitor window](./docs/imgs/live-monitor-window.png)

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

1. Open VoidDisplay. The **Displays** page opens by default.
2. Click **Add Virtual Display**.
3. Choose a preset or configure a custom resolution and refresh rate.
4. The virtual display appears immediately in your macOS display arrangement.

### Monitor a Screen

1. On the **Displays** page, enable the virtual display you want to monitor.
2. Turn on **Preview** in that display's status row.
3. A floating window opens with the live content. Turn Preview off or close the window to stop it.

### Share a Screen over LAN

1. On the **Displays** page, open **Sharing Settings** to adjust performance mode or port when needed.
2. Enable the target virtual display, then turn on **LAN Web View** in its status row. The web service starts automatically.
3. Use **Copy Link**, or choose **Open Share Page** from the display's More menu.
4. Open the generated URL, such as `http://192.168.x.x:18090/display/1/{capability}`, in a modern browser on the same network.

Notes:
- `/display/{capability}` and `/display/{id}/{capability}` are the protected page routes.
- `/signal/{capability}` and `/signal/{id}/{capability}` are the protected WebSocket signaling routes.
- The capability rotates whenever sharing restarts. Old and credentialless links are rejected.
- HTTP and WebSocket traffic is not encrypted. Use LAN sharing only on a trusted network and do not expose it through public port forwarding or tunnels. See [LAN Web View security](./docs/lan-sharing-security.md).

## ❓ Troubleshooting

**Displays are missing, or Preview and LAN Web View are unavailable?**

> macOS requires Screen Recording permission. Go to **System Settings → Privacy & Security → Screen Recording** and make sure VoidDisplay is enabled. If you changed the permission while the app was running, fully quit and reopen it.

**The shared screen page won't open from another device?**

> Make sure your Mac and the viewing device are on the same local network (Wi-Fi or Ethernet). The URL shown in the app must be reachable from the other device.

**The browser opens but playback does not start?**

> The live page requires a modern browser with `WebSocket` and `RTCPeerConnection` support. Use a current Chromium-based browser or a recent Safari/WebKit build on the viewing device.

**Virtual display failed to restore on app launch?**

> If a virtual display fails to restore, you'll see an alert on the Displays page. If the configuration file is corrupted, you can reset it by deleting:
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

UI entry: `HomeView` contains the **Displays** and **Diagnostics** sidebar destinations. The Displays surface owns virtual-display creation and management, preview, and LAN sharing actions.

Key files for debugging:

| Area | Files |
|------|-------|
| Virtual Display | `Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayOrchestrator.swift`, `Sources/VoidDisplayVirtualDisplay/Views/CreateVirtualDisplayObjectView.swift`, `Sources/VoidDisplayVirtualDisplay/Views/EditVirtualDisplayConfigView.swift` |
| Screen Capture | `Sources/VoidDisplayApp/AppState/CaptureController.swift`, `Sources/VoidDisplayCapture/Services/DisplayCaptureRegistry.swift`, `Sources/VoidDisplayCapture/Services/DisplayCaptureSession.swift`, `Sources/VoidDisplayFoundation/RuntimeSupport/DisplayStartCoordinator.swift` |
| LAN Sharing | `Sources/VoidDisplayApp/AppState/SharingController.swift`, `Sources/VoidDisplaySharing/Services/DisplaySharingCoordinator.swift`, `Sources/VoidDisplaySharing/Services/SharingService.swift`, `Sources/VoidDisplaySharing/Web/WebServer.swift` |

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
