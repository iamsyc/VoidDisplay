<div align="center">
  <img src="./docs/imgs/AppIcon.png" width="150" height="150"/>
  <h1>FreelyDisplay</h1>
  <p>Create virtual displays, monitor screens, and share them over LAN — all from your Mac.</p>
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

Share any display over your local network via HTTP + MJPEG.  
Open the provided URL in any browser on any device — phone, tablet, or another computer — no app needed on the viewing end.

## 📸 Screenshots

![](./docs/imgs/6.png)
![](./docs/imgs/1.png)
![](./docs/imgs/2.png)
![](./docs/imgs/5.png)

## 💻 System Requirements

- macOS on Apple Silicon (M1 or later)

## 📥 Installation

### Download

Check the [Releases](../../releases) page for the latest build.

### Build from Source

1. Clone this repository.
2. Open `FreelyDisplay.xcodeproj` in Xcode 26+.
3. Build and run (⌘R).

## 🚀 Getting Started

### Create a Virtual Display

1. Open FreelyDisplay and go to the **Virtual Display** tab.
2. Click the **+** button to add a new virtual display.
3. Choose a preset or configure a custom resolution and refresh rate.
4. The virtual display appears immediately in your macOS display arrangement.

### Monitor a Screen

1. Go to the **Screen Monitoring** tab.
2. Select the display you want to monitor.
3. A floating window opens showing the live content of that display.

### Share a Screen over LAN

1. Go to the **Screen Sharing** tab.
2. Click **Share** next to the display you want to broadcast.
3. The app shows a local URL (e.g. `http://192.168.x.x:8080/display`).
4. Open that URL in any browser on the same network to watch the screen in real time.

## ❓ Troubleshooting

**No displays appear in Screen Monitoring or Screen Sharing?**

> macOS requires Screen Recording permission. Go to **System Settings → Privacy & Security → Screen Recording** and make sure FreelyDisplay is enabled. If you changed the permission while the app was running, fully quit and reopen it.

**The shared screen page won't open from another device?**

> Make sure your Mac and the viewing device are on the same local network (Wi-Fi or Ethernet). The URL shown in the app must be reachable from the other device.

**Virtual display failed to restore on app launch?**

> If a virtual display fails to restore, you'll see an alert in the Virtual Display tab. If the configuration file is corrupted, you can reset it by deleting:  
> `~/Library/Application Support/phineas.mac.FreelyDisplay/virtual-displays.json`

## �️ For Developers

### Build & Test

Requirements: Xcode 26+, macOS Apple Silicon.

```bash
# Run unit tests (no paid developer certificate required)
xcodebuild -scheme FreelyDisplay \
  -project FreelyDisplay.xcodeproj \
  -configuration Debug test \
  -destination 'platform=macOS,arch=arm64'
```

### Debug Entry Points

UI entry: `HomeView` contains four tabs — **Displays**, **Virtual Display**, **Screen Monitoring**, **Screen Sharing**.

Key files for debugging:

| Area | Files |
|------|-------|
| Virtual Display | `VirtualDisplayService.swift`, `CreateVirtualDisplayObjectView.swift`, `EditVirtualDisplayConfigView.swift` |
| Screen Capture | `CaptureChooseViewModel.swift`, `ScreenCaptureFunction.swift` |
| LAN Sharing | `ShareViewModel.swift`, `SharingService.swift`, `WebShare/WebServer.swift` |

Unified logs (`Logger`, subsystem `phineas.mac.FreelyDisplay`):

```bash
log stream --style compact --predicate 'subsystem == "phineas.mac.FreelyDisplay"'
```

## �📄 License

[Apache License 2.0](./LICENSE)

## 🙏 Acknowledgements

This project uses the private `CGVirtualDisplay` framework. See [LICENSE_CGVirtualDisplay](./LICENSE_CGVirtualDisplay) for details.
