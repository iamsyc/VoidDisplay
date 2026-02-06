<div align="center">
  <img src="./docs/imgs/AppIcon.png" width="150" height="150"/>
  <h1>FreelyDisplay</h1>
  <a href="./docs/Readme_cn-zh.md">简体中文</a>
</div>

FreelyDisplay is a macOS app for:
- creating virtual displays,
- monitoring local displays in dedicated windows,
- sharing display frames over LAN (HTTP + MJPEG).

## Project Status

The project has completed a service-oriented refactor:
- large app state orchestration is centralized in `AppHelper`,
- domain logic is split into dedicated services and view models,
- unit tests can run locally without a paid Apple Developer certificate.

## Architecture Boundaries

Core composition:
- `FreelyDisplay/FreelyDisplayApp.swift`: App entry and `AppHelper` composition root.
- `FreelyDisplay/VirtualDisplayService.swift`: virtual display lifecycle and mode application.
- `FreelyDisplay/VirtualDisplayPersistenceService.swift`: persisted config load/save/restore boundary.
- `FreelyDisplay/CaptureMonitoringService.swift`: screen monitoring session registry.
- `FreelyDisplay/SharingService.swift`: sharing state machine.
- `FreelyDisplay/WebServiceController.swift`: web service lifecycle.
- `FreelyDisplay/WebShare/WebServer.swift`: HTTP connection and MJPEG stream transport.
- `FreelyDisplay/ShareViewModel.swift` and `FreelyDisplay/CaptureChooseViewModel.swift`: UI orchestration.
- `FreelyDisplay/AppObservability.swift`: unified logs and error mapping.

High-level flow:
- Virtual display: `VirtualDisplayView` -> `AppHelper` -> `VirtualDisplayService`.
- Monitoring: `CaptureChoose` -> `CaptureDisplayView` -> `ScreenCaptureFunction`.
- Sharing: `ShareView` -> `ShareViewModel` -> `SharingService` -> `WebServiceController` -> `WebServer`.

## Build And Test

Requirements:
- Xcode 26+ (project currently builds with Xcode 26.3 RC),
- macOS Apple Silicon (current local target: `platform=macOS,arch=arm64`).

Run tests:

```bash
xcodebuild -scheme FreelyDisplay -project /Users/syc/Project/FreelyDisplay/FreelyDisplay.xcodeproj -configuration Debug test -destination 'platform=macOS,arch=arm64'
```

No paid developer account is required for unit tests:
- project uses local signing (`Sign to Run Locally`) for test runs,
- `DEVELOPMENT_TEAM` is empty and tests run with ad-hoc local signing.

## Debug Entry Points

UI entry:
- `HomeView` has 4 sections: `Screen`, `Virtual Display`, `Monitor Screen`, `Screen Sharing`.

Useful files for debugging:
- virtual display creation/update issues:
  - `FreelyDisplay/CreateVirtualDisplayObjectView.swift`
  - `FreelyDisplay/EditVirtualDisplayConfigView.swift`
  - `FreelyDisplay/VirtualDisplayService.swift`
- screen capture / permission issues:
  - `FreelyDisplay/CaptureChooseViewModel.swift`
  - `FreelyDisplay/ScreenCaptureFunction.swift`
- web sharing / stream issues:
  - `FreelyDisplay/ShareViewModel.swift`
  - `FreelyDisplay/SharingService.swift`
  - `FreelyDisplay/WebShare/WebServer.swift`

Unified logs (`Logger`):
- subsystem: `phineas.mac.FreelyDisplay`
- categories: `virtual_display`, `capture`, `sharing`, `web`, `persistence`

Example:

```bash
log stream --style compact --predicate 'subsystem == "phineas.mac.FreelyDisplay"'
```

## Troubleshooting

1. No displays in Monitor/Share views
- Confirm Screen Recording permission in System Settings.
- Retry in app, then fully quit/reopen if permission was changed while app was running.

2. `/stream` returns 503
- Sharing is not active. Start sharing from `Screen Sharing` view first.

3. Local share page cannot be opened
- Ensure Mac is connected to LAN (Wi-Fi or Ethernet).
- App picks preferred interface in order: `en0`, `en1`, `en2`, `en3`, `bridge0`, `pdp_ip0`.

4. Virtual display restore failed on startup
- Check restore failures in `VirtualDisplayView` alert.
- Corrupted config can be reset by deleting:
  - `~/Library/Application Support/phineas.mac.FreelyDisplay/virtual-displays.json`

## Test Coverage Focus

Current unit tests in `FreelyDisplayTests` cover:
- config schema migration and sanitization,
- serial number conflict resolution,
- sharing/web state transitions,
- HTTP parsing + routing + response behavior,
- LAN IPv4 selection strategy.

## Screenshots

![](./docs/imgs/6.png)
![](./docs/imgs/1.png)
![](./docs/imgs/2.png)
![](./docs/imgs/5.png)
