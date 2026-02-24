# AppHelper 消除重构最终方案（GPT 单次执行版）

## 目标

彻底删除 `AppHelper`，将 `CaptureController`、`SharingController`、`VirtualDisplayController` 直接注入 SwiftUI Environment，并一次性完成相关 View / ViewModel / 测试迁移。

本方案是给 GPT 执行的终态方案，不以“人类渐进迁移”作为约束，不保留过渡兼容层。

---

## 执行原则（重要）

1. 一次性改到终态（single-shot refactor）
2. 不引入临时 wrapper / 兼容 API
3. 不为了“中间可编译”增加额外代码
4. 优先减少最终代码量和依赖复杂度

---

## 固定设计决策（已拍板）

1. `AppHelper.ScreenMonitoringSession` 提取为顶层类型 `ScreenMonitoringSession`
2. `isManagedVirtualDisplay(displayID:)` 归属到 `VirtualDisplayController`
3. `virtualSerialForManagedDisplay(_:)` 归属到 `VirtualDisplayController`（供 sharing 注册 resolver 使用）
4. `registerShareableDisplays` 不再走 `AppHelper` 包装，直接调用 `SharingController.registerShareableDisplays(_:virtualSerialResolver:)`
5. 第一版不引入 `AppCoordinator`
6. `StartupPlan` 保留在 `AppBootstrap`（composition root），不作为环境对象暴露
7. `AppHelper.VirtualDisplayError` / `AppHelper.SharePageURLFailure` 之类 typealias 全部移除，调用方直接使用真实类型

---

## 终态架构

### `VoidDisplayApp`

- 持有三个 `@State` 控制器：
  - `capture`
  - `sharing`
  - `virtualDisplay`
- `init()` 中通过 `AppBootstrap.makeEnvironment()` 完成构建与启动逻辑
- 所有 Scene 注入具体控制器，而不是注入 `AppHelper`

示意：

```swift
@State private var capture: CaptureController
@State private var sharing: SharingController
@State private var virtualDisplay: VirtualDisplayController

init() {
    let env = AppBootstrap.makeEnvironment()
    _capture = State(initialValue: env.capture)
    _sharing = State(initialValue: env.sharing)
    _virtualDisplay = State(initialValue: env.virtualDisplay)
}
```

所有窗口注入：

```swift
.environment(capture)
.environment(sharing)
.environment(virtualDisplay)
```

### Observation 环境注入兼容约束（硬性）

- 本方案默认 `CaptureController`、`SharingController`、`VirtualDisplayController` 均为 `@MainActor @Observable`，并统一采用 Observation typed environment：
  - `@Environment(Type.self)`
  - `.environment(instance)`
- 若在实施过程中发现需要注入的类型是 `ObservableObject`（含 `@Published`），不得混用 Observation typed environment 作为其主要注入路径；应使用 `@StateObject` + `.environmentObject(...)`（或保持原有注入方式）。
- 本轮重构不新增“兼容 Observation/ObservableObject 混用”的中间包装层；发现混用时按类型归属分别处理，避免生命周期与刷新行为不一致。

---

## 一次性改动清单（按终态）

## 1. 提取 `ScreenMonitoringSession`（必须先完成）

新建文件：

- `VoidDisplay/Features/Capture/Models/ScreenMonitoringSession.swift`

定义顶层类型：

```swift
import Foundation
import ScreenCaptureKit
import CoreGraphics

struct ScreenMonitoringSession: Identifiable {
    enum State {
        case starting
        case active
    }

    let id: UUID
    let displayID: CGDirectDisplayID
    let displayName: String
    let resolutionText: String
    let isVirtualDisplay: Bool
    let stream: SCStream
    let delegate: StreamDelegate
    var state: State
}
```

### `ScreenMonitoringSession` 并发/Actor 边界约束（硬性）

- `ScreenMonitoringSession` 持有 `SCStream` 与 `StreamDelegate` 等运行时资源句柄，仅允许在主线程 / `@MainActor` 上创建、读取、更新和销毁。
- 本轮不将 `ScreenMonitoringSession` 设计为 `Sendable`，也不允许跨 actor/线程传递（包括传入 `Task.detached` 或非 `@MainActor` 隔离上下文）。
- `CaptureController`、`CaptureMonitoringServiceProtocol`、`CaptureMonitoringService` 的 `@MainActor` 隔离必须保留，用于约束 `ScreenMonitoringSession` 的流转边界。
- 若未来需要跨 actor 传递，必须拆分为：
  - 轻量 `Sendable` 状态 DTO（仅元数据）
  - 主 actor 持有资源句柄的 manager/handle（管理 `SCStream` / `delegate` 生命周期）

全局替换（必须做完）：

- `AppHelper.ScreenMonitoringSession` -> `ScreenMonitoringSession`

受影响文件（当前已知）：

- `VoidDisplay/App/CaptureController.swift`
- `VoidDisplay/Features/Capture/Services/CaptureMonitoringService.swift`
- `VoidDisplay/Features/Capture/ViewModels/CaptureChooseViewModel.swift`
- `VoidDisplay/Features/Capture/Views/CaptureDisplayRow.swift`
- `VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift`
- `VoidDisplayTests/TestSupport/TestServiceMocks.swift`

---

## 2. 删除 `AppHelper` 并重写 `VoidDisplayApp.swift` 组合根

文件：

- `VoidDisplay/App/VoidDisplayApp.swift`

改动要求：

1. 删除 `AppHelper` class（完整删除）
2. 保留/重构 `AppBootstrap`，改为返回环境结构体（例如 `EnvironmentBundle`）
3. `AppBootstrap` 内部保留 `StartupPlan`
4. 在 bootstrap 阶段完成：
   - `CaptureController` / `SharingController` / `VirtualDisplayController` 实例化
   - `stopDependentStreamsBeforeRebuild` 闭包注入
   - Web service 启动（按 startup plan）
   - persisted config restore（按 startup plan）
   - UI Test scenario 注入逻辑（当前已有）

建议结构：

```swift
@MainActor
private enum AppBootstrap {
    struct EnvironmentBundle {
        let capture: CaptureController
        let sharing: SharingController
        let virtualDisplay: VirtualDisplayController
    }

    struct StartupPlan { ... }

    static func makeEnvironment() -> EnvironmentBundle { ... }
}
```

注意：

- 不要把 `AppHelper` 的职责平移成新的 God Object
- 不要新增 `AppCoordinator`（本轮不需要）

---

## 3. 将跨控制器查询下沉到 `VirtualDisplayController`

文件：

- `VoidDisplay/App/VirtualDisplayController.swift`（或其 extension 文件）

新增方法（名称可微调，但语义必须一致）：

```swift
func isManagedVirtualDisplay(displayID: CGDirectDisplayID) -> Bool
func virtualSerialForManagedDisplay(_ displayID: CGDirectDisplayID) -> UInt32?
```

用途：

- 取代原 `AppHelper.isManagedVirtualDisplay(displayID:)`
- 为 sharing 注册提供 `virtualSerialResolver`

---

## 4. 所有 View 改为注入具体 Controller（移除 `@Environment(AppHelper.self)`）

目标：每个 View 只注入它实际使用的控制器。

当前使用 `@Environment(AppHelper.self)` 的文件（全部迁移）：

- `VoidDisplay/App/AppSettingsView.swift`
- `VoidDisplay/Features/Capture/Views/CaptureChoose.swift`
- `VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift`
- `VoidDisplay/Features/Sharing/Views/ShareDisplayList.swift`
- `VoidDisplay/Features/Sharing/Views/ShareView.swift`
- `VoidDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift`
- `VoidDisplay/Features/VirtualDisplay/Views/DisplaysView.swift`
- `VoidDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift`
- `VoidDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift`
- `VoidDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift`

推荐注入映射：

- `DisplaysView` -> `VirtualDisplayController`
- `VirtualDisplayView` -> `VirtualDisplayController`
- `CreateVirtualDisplayObjectView` -> `VirtualDisplayController`
- `EditVirtualDisplayConfigView` -> `VirtualDisplayController`
- `EditDisplaySettingsView` -> `VirtualDisplayController`
- `ShareView` -> `SharingController`（如需刷新注册显示器则再加 `VirtualDisplayController`）
- `ShareDisplayList` -> `SharingController` + `VirtualDisplayController`
- `CaptureChoose` -> `CaptureController` + `VirtualDisplayController`
- `CaptureDisplayView` -> `CaptureController`
- `AppSettingsView` -> `SharingController`（按实际使用补充）

要求：

- 全量替换 `appHelper.xxx` 为对应 controller 调用
- 不保留任何 `appHelper` 局部变量或桥接层

---

## 5. ViewModel 方法签名去 `AppHelper` 化

## 5.1 `ShareViewModel`

文件：

- `VoidDisplay/Features/Sharing/ViewModels/ShareViewModel.swift`

当前大量方法签名直接收 `AppHelper`，需要按实际依赖拆分为 `SharingController` / `VirtualDisplayController`。

建议签名方向（示意，不要求名称完全一致）：

- `syncForCurrentState(sharing:)`
- `startService(sharing:)`
- `stopService(sharing:)`
- `requestScreenCapturePermission(sharing:virtualDisplay:)`
- `refreshPermissionAndMaybeLoad(sharing:virtualDisplay:)`
- `loadDisplaysIfNeeded(sharing:virtualDisplay:)`
- `loadDisplays(sharing:virtualDisplay:)`
- `refreshDisplays(sharing:virtualDisplay:)`
- `startSharing(display:sharing:)`
- `stopSharing(displayID:sharing:)`
- `sharePageAddress(for:sharing:)`

关键点：

- `loadDisplays` 成功后调用：

```swift
sharing.registerShareableDisplays(shareableDisplays) { displayID in
    virtualDisplay.virtualSerialForManagedDisplay(displayID)
}
```

- 不再通过 `appHelper.registerShareableDisplays(...)`

### `virtualSerialResolver` 生命周期与引用约束（硬性）

- `virtualSerialResolver` 视为即时查询闭包：`SharingController` / `SharingService` / `DisplaySharingCoordinator` 不得将该闭包保存到属性、异步任务、定时器或长期回调中。
- 本轮实现要求 `registerShareableDisplays` 调用链同步消费 resolver（注册时立即求值），不得改为延迟执行模型。
- 若未来必须存储或异步使用 resolver，必须显式避免强引用环：
  - 使用弱捕获：`{ [weak virtualDisplay] displayID in virtualDisplay?.virtualSerialForManagedDisplay(displayID) }`
  - 或改为不捕获 controller 的桥接 API / 静态解析层
- 目的：避免潜在环路（例如 `sharing` 持有 resolver，resolver 再强持有 `virtualDisplay`，而 `virtualDisplay` 通过其他 wiring 间接关联 `sharing`）。

## 5.2 `CaptureChooseViewModel`

文件：

- `VoidDisplay/Features/Capture/ViewModels/CaptureChooseViewModel.swift`

替换方向：

- `isVirtualDisplay(_ display: SCDisplay, appHelper: AppHelper)` -> `isVirtualDisplay(_ display: SCDisplay, virtualDisplay: VirtualDisplayController)`
- `startMonitoring(display:appHelper:openWindow:)` -> `startMonitoring(display:capture:virtualDisplay:openWindow:)`

并将：

- `AppHelper.ScreenMonitoringSession(...)` -> `ScreenMonitoringSession(...)`

---

## 6. 清理 `AppHelper` typealias 依赖

典型替换：

- `AppHelper.VirtualDisplayError` -> `VirtualDisplayService.VirtualDisplayError`
- `AppHelper.SharePageURLFailure` -> `SharingController.SharePageURLFailure`

说明：

- 不要为了兼容旧调用新增新的公共 typealias 中转层

---

## 7. 测试迁移（一次性）

重点文件：

- `VoidDisplayTests/App/AppHelperTests.swift`

处理方式（二选一，优先 A）：

1. A: 重命名并重写为 `AppBootstrapTests.swift`
2. B: 保持文件名不变，但测试对象改为 bootstrap / controllers（不推荐，语义不准确）

测试目标从“AppHelper 行为”改为：

- bootstrap 在 preview 模式跳过启动逻辑
- UI test scenario 注入逻辑仍生效
- xctest 环境下 startup plan 跳过逻辑仍生效
- 普通模式会启动 web service + restore virtual display
- `VirtualDisplayController` rebuild 回调仍会触发 `Capture` / `Sharing` 停止依赖流

说明：

- 由于回调 wiring 已下沉到 composition root，测试应直接验证 wiring 结果，而不是依赖 `AppHelper` 包装类存在

---

## 执行后必须满足的检查（硬性）

1. `VoidDisplay` 与 `VoidDisplayTests` 中不再存在 `AppHelper` 类型引用（文档除外）
2. 不再存在 `@Environment(AppHelper.self)`
3. 不新增替代性的 God Object（例如 `AppEnvironmentObject` 持有全部 controller 且被所有 view 注入）
4. `ScreenMonitoringSession` 已成为顶层类型并替换完成
5. 现有功能路径保持：
   - Virtual Display 管理
   - Screen Sharing
   - Screen Monitoring
   - App 启动恢复逻辑
6. `registerShareableDisplays` 的 `virtualSerialResolver` 仍为同步、非持久化使用（不得在 sharing 层保存闭包）
7. `ScreenMonitoringSession` 未被声明为 `Sendable`，且未被用于跨 actor/线程传递

---

## 建议执行顺序（给 GPT 的内部操作顺序）

这是“单次终态重构”的编辑顺序，不是提交/阶段拆分顺序：

1. 创建 `ScreenMonitoringSession.swift`
2. 全局替换 `AppHelper.ScreenMonitoringSession`
3. 在 `VirtualDisplayController` 增加查询方法
4. 重写 `VoidDisplayApp.swift`（删 `AppHelper`、改 bootstrap、改环境注入）
5. 全量修改 10 个 View 的 `@Environment` 和调用点
6. 修改 `ShareViewModel` / `CaptureChooseViewModel` 方法签名及调用
7. 清理 typealias 引用
8. 重写/迁移 `AppHelperTests`
9. 全局搜索收尾（`AppHelper` / `@Environment(AppHelper.self)`）

---

## 验证命令（执行后）

```bash
rg -n "\\bAppHelper\\b" VoidDisplay VoidDisplayTests
rg -n "@Environment\\(AppHelper\\.self\\)" VoidDisplay

xcodebuild build \
  -project VoidDisplay.xcodeproj \
  -scheme VoidDisplay \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug

scripts/test/unit_gate.sh \
  --project /Users/syc/Project/VoidDisplay/VoidDisplay.xcodeproj \
  --destination "platform=macOS,arch=arm64" \
  --derived-data-path .derivedData \
  --result-bundle-path UnitTests.xcresult \
  --enable-code-coverage YES \
  --only-testing VoidDisplayTests \
  --skip-testing VoidDisplayUITests
```

期望结果：

- 两条 `rg` 搜索无业务代码命中
- 构建通过
- 单测门禁通过

---

## 备注（避免走偏）

- 本方案追求终态整洁，不追求过程可编译
- 不要为了“分步安全”留下临时 API、桥接方法或过渡对象
- 如果实现中发现某个 View 同时依赖多个 Controller，这是可接受的，优先保持依赖显式
