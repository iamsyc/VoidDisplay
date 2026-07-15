# DisplayRuntime Phase 1 执行计划

状态：已完成历史记录
依据：[DisplayRuntime 重构执行计划](./display-runtime-refactor-plan.md)、[产品定位与架构重构前置结论](./product-positioning.md)
范围：新增 `VoidDisplayRuntime` target、只读 `DisplaySurface` / `DisplayRuntimeSnapshot` 模型、runtime ports、App adapters、Observability runtime snapshot provider。
归档说明：Phase 1 已完成。本文保留为当时的实施计划与验收记录，不再作为当前待办清单。
导航：当前阅读顺序见 [DisplayRuntime 文档索引](./display-runtime-index.md)。

## Summary

Phase 1 目标是新增 `VoidDisplayRuntime` target，建立只读 `DisplaySurface` / `DisplayRuntimeSnapshot` 模型，定义 runtime ports，接入 App adapters，并注册 runtime snapshot provider 到 Observability。

Phase 1 只建立模型、端口、只读快照和对照验证，不迁移命令，不改变 UI，不改 capture、sharing、virtual display 的数据路径。

## Key Changes

- 新增 SwiftPM target：`VoidDisplayRuntime`。
- `VoidDisplayRuntime` Phase 1 只依赖 `VoidDisplayFoundation` 和 `VoidDisplayObservability`。
- `VoidDisplayRuntime` 禁止依赖 `VoidDisplayApp`、`VoidDisplayCapture`、`VoidDisplaySharing`、`VoidDisplayVirtualDisplay`、`VoidDisplayDesignSystem`。
- `VoidDisplayRuntime` 禁止导入 `SwiftUI`、`AppKit`、`Observation`。
- 新增 test target：`VoidDisplayRuntimeTests`。
- 新增只读模型：
  - `DisplaySurface`
  - `DisplaySurfaceKind`
  - `DisplaySurfaceIdentity`
  - `DisplayRuntimeSnapshot`
  - `DisplayRuntime`
  - `DisplayRuntimeSnapshotProvider`
- 新增 runtime ports：
  - `DisplayRuntimeCatalogProviding`
  - `DisplayRuntimeCaptureProviding`
  - `DisplayRuntimeSharingProviding`
  - `DisplayRuntimeVirtualDisplayProviding`
- 在 `VoidDisplayApp` 中新增最小 adapters，把现有 app controller 和 store 映射成 runtime DTO。
- 在 `AppBootstrap.makeEnvironment` 中创建 `DisplayRuntime`，由 `AppEnvironment` 持有，并注册 `DisplayRuntimeSnapshotProvider` 到 `ObservabilityCenter`。
- 保留现有 `CaptureSnapshotProvider`、`SharingSnapshotProvider`、`VirtualDisplaySnapshotProvider`、`ScreenCatalogSnapshotProvider` 作为 Phase 1 parity 对照。
- 不处理 LAN Web View token、访问密码、账号体系或鉴权层。
- 不修改 `ObservabilitySnapshotProvider` 协议形状；Phase 1 runtime provider 必须适配现有 `@MainActor` 同步 `makeSnapshot()`。
- 不主动修改 `Apps/VoidDisplay/VoidDisplay.xcodeproj/project.pbxproj`；现有 app scheme 已通过 SwiftPM product `VoidDisplayApp` 消费 package。

## Implementation Plan

### 1. Preflight

- 先处理当前未提交的 `Apps/VoidDisplay/VoidDisplay.xcodeproj/project.pbxproj` 变更，避免和新增 target 修改混在一起。
- 确认 `docs/product-positioning.md` 和 `docs/display-runtime-refactor-plan.md` 已作为 Phase 1 依据提交或单独保留。
- 记录 Phase 1 开工前基线验证结果。
- 若 Phase 1 实现时 `project.pbxproj` 仍有未处理改动，停止实现并先处理该工作区状态。

### 2. SwiftPM Target

- 修改 `Package.swift`，新增 `VoidDisplayRuntime` target。
- 修改 `VoidDisplayApp` dependencies，加入 `VoidDisplayRuntime`。
- 新增 `VoidDisplayRuntimeTests`，依赖 `VoidDisplayRuntime`、`VoidDisplayFoundation`、`VoidDisplayObservability`、`VoidDisplayTestingSupport`。
- `VoidDisplayRuntime` 不新增 public product，所有跨 target API 使用 `package` 访问级别。
- 不修改 `Apps/VoidDisplay/VoidDisplay.xcodeproj/project.pbxproj`，除非 Xcode build 证明现有 local Swift package product 无法自动解析更新后的 `VoidDisplayApp` dependency graph。
- 不修改 app-facing localization。

### 3. Runtime Model

- 在 `Sources/VoidDisplayRuntime` 中实现纯值模型和 snapshot DTO。
- 因为 package 使用 `defaultIsolation(MainActor.self)`，runtime DTO 和纯模型需要显式使用 `nonisolated` 或等价方式避免意外 MainActor 隔离。
- managed virtual display 使用 config id 作为稳定主身份。
- physical display 作为 auxiliary surface，使用当前 display id 和系统快照聚合。
- `shareID` 只作为 LAN Web View route identity，不作为 `DisplaySurfaceIdentity`。
- 不复用 `VoidDisplayCapture`、`VoidDisplaySharing`、`VoidDisplayVirtualDisplay` 中的模型类型；App adapters 负责映射到 runtime DTO。

### 4. Runtime Ports And Adapters

- Runtime ports 只返回 `Sendable` DTO。
- DTO 不能包含 `SCDisplay`、`CMSampleBuffer`、`CVPixelBuffer`、WebRTC session、capture session、SwiftUI state。
- App adapters 放在 `VoidDisplayApp`，只做 `@MainActor` controller / store 到 DTO 的映射。
- Adapters 不承载权限、拓扑、分享、捕获业务判断。
- Phase 1 ports 只读，不定义 command ports，不发起 capture、sharing 或 virtual display 操作。

### 5. Runtime Snapshot Provider

- `DisplayRuntime` 从 ports 构建只读 `DisplayRuntimeSnapshot`。
- Phase 1 的 `DisplayRuntime` 实现为同步只读 runtime facade，运行在 `@MainActor`，不实现为 SwiftUI `@Observable`，不启动后台任务。
- `DisplayRuntimeSnapshotProvider` 输出 key `runtime`。
- `DisplayRuntimeSnapshotProvider` 必须遵守现有 `ObservabilitySnapshotProvider`：`@MainActor func makeSnapshot() -> Snapshot`。
- `DisplayRuntimeSnapshotProvider.makeSnapshot()` 直接读取 `DisplayRuntime` 当前只读 snapshot，不执行 async wait，不创建 `Task`，不阻塞 MainActor。
- Phase 2 之后如果 `DisplayRuntime` 改为 actor 或异步状态机，必须先引入 cached snapshot 读取边界，不能在 provider 中等待 actor。
- Phase 1 不修改 `AnyObservabilitySnapshotProvider`、`ObservabilityCenter` 或现有 snapshot provider 协议。
- 默认 snapshot 脱敏，不导出 raw `shareID`、LAN IP、完整分享 URL、窗口标题、用户文本、路径明文、桌面内容。
- 在 `AppBootstrap.makeEnvironment` 中注册 runtime provider，并保留现有 providers。

### 6. Acceptance Criteria

- `VoidDisplayRuntime` target 不依赖 UI、App controller、Capture / Sharing / VirtualDisplay target。
- `DisplayRuntimeSnapshot` 能表达 managed virtual display、physical auxiliary surface、capture state、sharing state、virtual display state、screen catalog state。
- `DisplayRuntimeSnapshotProvider` 使用现有同步 Observability provider 协议，不引入 async provider migration。
- `AppEnvironment` 持有 `DisplayRuntime`，runtime 生命周期和 app environment 一致。
- Observability current state 出现 `runtime` section。
- Phase 1 不改变用户行为，不改变 UI，不改变 Web route，不改变 capture / WebRTC 数据路径。

## Test Plan

Targeted tests：

```sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter ObservabilitySnapshotProviderTests
```

Static boundary checks：

```sh
scripts/ci/static.sh
rg -n 'name: "VoidDisplayRuntime"|"VoidDisplayRuntime"' Package.swift
if rg -n "import (SwiftUI|AppKit|Observation|VoidDisplayDesignSystem|VoidDisplayApp)" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "\\b(SCDisplay|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession|DisplayCaptureSession)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
```

Manual `Package.swift` check：

- `VoidDisplayRuntime` dependencies are exactly `VoidDisplayFoundation` and `VoidDisplayObservability`.
- `VoidDisplayApp` depends on `VoidDisplayRuntime`.
- `VoidDisplayRuntimeTests` does not depend on `VoidDisplayApp`, `VoidDisplayCapture`, `VoidDisplaySharing`, `VoidDisplayVirtualDisplay`, or `VoidDisplayDesignSystem`.

Build gate：

```sh
scripts/ci/xcode.sh --action build --configuration Debug
```

Required test scenarios：

- managed virtual display identity uses config id.
- physical display is auxiliary surface.
- share route identity remains separate from surface identity.
- runtime snapshot aggregates fake port states deterministically.
- runtime snapshot provider registers and encodes a `runtime` section.
- runtime provider returns a current read-only snapshot through synchronous `makeSnapshot()`.
- nil or unavailable adapters produce empty or degraded snapshot states without crashing.
- no test triggers real screen recording, WebRTC, virtual display driver, or macOS privacy prompts.

## Assumptions

- `docs/display-runtime-phase-1-plan.md` is a Phase 1 implementation plan, while `docs/display-runtime-refactor-plan.md` remains the whole refactor roadmap.
- Phase 1 uses a new `VoidDisplayRuntime` target instead of placing runtime code in `VoidDisplayApp` or `VoidDisplayFoundation`.
- Swift 6 and macOS deployment target `15.6` remain unchanged.
- Xcode project changes are not expected in Phase 1 because the app target consumes the local SwiftPM product `VoidDisplayApp`; modify the project only if build verification proves it is required.
- Current LAN Web View security stance is intentionally unchanged: local network only, no random token, no password, no account system, no auth layer.
