# Swift Package 终极目标结构

## 目标定义

VoidDisplay 的最终源码组织目标是：Swift Package 承载业务源码、架构边界、模块依赖和单元测试；Xcode App target 只承载打包、签名、权限、启动入口、App 资源和系统集成配置。

这个目标用于指导迁移计划。中间阶段可以保留临时聚合 target，但最终结构不保留 `VoidDisplayCore` 这类边界模糊的模块名。

## 最终目录结构

```text
VoidDisplay/
  Package.swift
  Package.resolved

  Sources/
    VoidDisplayApp/
      Bootstrap/
      Composition/
      Navigation/
      AppState/

    VoidDisplayVirtualDisplay/
      Models/
      Runtime/
      Services/
      Logic/
      Views/
      ViewModels/

    VoidDisplayCGVirtualDisplay/
      Runtime/
      Services/

    VoidDisplayCapture/
      Models/
      Services/
      Rendering/
      Views/
      ViewModels/

    VoidDisplaySharing/
      Models/
      Services/
      Web/
      Views/
      ViewModels/
      Resources/

    VoidDisplayObservability/
      Events/
      Snapshots/
      Export/
      Diagnostics/

    VoidDisplaySupport/
      Models/
      Services/
      Views/
      ViewModels/

    VoidDisplayDesignSystem/
      Components/
      Styling/
      Presentation/

    VoidDisplayFoundation/
      Resolution/
      Persistence/
      Networking/
      Screen/
      Utilities/

    CGVirtualDisplayPrivate/
      include/
        CGVirtualDisplayPrivate.h
        module.modulemap

  Tests/
    VoidDisplayAppTests/
    VoidDisplayVirtualDisplayTests/
    VoidDisplayCGVirtualDisplayTests/
    VoidDisplayCaptureTests/
    VoidDisplaySharingTests/
    VoidDisplayObservabilityTests/
    VoidDisplaySupportTests/
    VoidDisplayDesignSystemTests/
    VoidDisplayFoundationTests/
    VoidDisplayTestingSupport/

  Apps/
    VoidDisplay/
      VoidDisplay.xcodeproj
      VoidDisplayApp.swift
      Assets.xcassets
      Resources/
        Localizable.xcstrings
        InfoPlist.xcstrings
      Entitlements/
      AppIcon.icon/

  UITests/
    VoidDisplayUITests/

  scripts/
    release/
    test/
    localization/

  docs/
    architecture/
    testing/
    release/

  .ai-tmp/
```

## 最终 Target 列表

1. `VoidDisplayApp`

   组合层。负责应用启动后的依赖装配、导航、全局状态连接、顶层窗口和功能入口。

2. `VoidDisplayVirtualDisplay`

   虚拟显示器领域。负责虚拟显示器配置、生命周期、拓扑、重建、主显示器策略、runtime driver 协议和相关界面。

3. `VoidDisplayCGVirtualDisplay`

   macOS CG 虚拟显示适配层。负责 `CGVirtualDisplayRuntimeDriver` 具体实现、私有 CG API 调用和系统显示创建销毁胶水代码。

4. `VoidDisplayCapture`

   采集领域。负责屏幕采集、采样分发、预览渲染、监控生命周期和采集相关界面。

5. `VoidDisplaySharing`

   分享领域。负责分享状态、端口偏好、HTTP 服务、WebRTC 会话、前端页面资源和分享相关界面。

6. `VoidDisplayObservability`

   可观测性领域。负责事件、诊断快照、问题记录、导出和支持数据的结构化采集。

7. `VoidDisplaySupport`

   支持流程领域。负责支持中心、反馈草稿、历史记录、问题类型和支持流程界面。

8. `VoidDisplayDesignSystem`

   跨功能 UI 基础层。只放多处复用的视觉组件、展示模型、控件样式和通用 SwiftUI 组件。

9. `VoidDisplayFoundation`

   基础能力层。只放无业务方向的基础类型和工具，例如分辨率、持久化抽象、网络工具、屏幕 ID 扩展和通用 utilities。

10. `CGVirtualDisplayPrivate`

   C target。封装私有显示接口头文件和模块映射，让 Swift 模块显式依赖它。

11. `VoidDisplayTestingSupport`

   测试支持 target。只放多个测试 target 共享的 mock、fixture、异步等待工具和端口分配工具，不进入产品依赖图。

## 依赖方向

```text
Apps/VoidDisplay Xcode App Target
  depends on
VoidDisplayApp
  depends on
VoidDisplayVirtualDisplay
VoidDisplayCGVirtualDisplay
VoidDisplayCapture
VoidDisplaySharing
VoidDisplaySupport
VoidDisplayObservability
VoidDisplayDesignSystem

VoidDisplayVirtualDisplay
VoidDisplayCapture
VoidDisplaySharing
VoidDisplaySupport
  depend on
VoidDisplayDesignSystem

VoidDisplayCGVirtualDisplay
  depends on
VoidDisplayVirtualDisplay
CGVirtualDisplayPrivate

VoidDisplayVirtualDisplay
VoidDisplayCapture
VoidDisplaySharing
VoidDisplaySupport
VoidDisplayObservability
VoidDisplayDesignSystem
  depend on
VoidDisplayFoundation

VoidDisplaySharing depends on WebRTC.
VoidDisplaySupport may depend on VoidDisplayObservability for support bundle export.
Feature modules may depend on VoidDisplayObservability only for neutral event and snapshot protocols.
VoidDisplayApp wires the VoidDisplayVirtualDisplay runtime driver protocol to the VoidDisplayCGVirtualDisplay implementation.
```

## 边界规则

1. App target 只保留启动入口、签名、权限、Info.plist、entitlements、App Icon、asset catalog 和 Xcode 工程配置。

2. 所有可测试的业务逻辑进入 Swift Package target。

3. `VoidDisplayApp` 可以依赖所有功能 target，功能 target 不能依赖 `VoidDisplayApp`。

4. 功能 target 默认不互相依赖。确实需要跨功能协作时，优先在 `VoidDisplayApp` 组合层完成装配，或通过稳定协议、轻量模型、`VoidDisplayFoundation` 中的基础抽象连接。

5. `VoidDisplayVirtualDisplay` 持有 runtime driver 协议和业务流程，不直接依赖 `CGVirtualDisplayPrivate`。

6. `VoidDisplayCGVirtualDisplay` 持有真实 `CGVirtualDisplayRuntimeDriver` 实现，依赖 `VoidDisplayVirtualDisplay` 的协议和 `CGVirtualDisplayPrivate` 的 C 接口。

7. `VoidDisplayApp` 负责把 runtime driver 协议绑定到真实 CG 实现，测试中使用 fake driver 覆盖虚拟显示器业务流程。

8. `VoidDisplayFoundation` 不能依赖任何功能 target。

9. `VoidDisplayDesignSystem` 只放跨功能 UI。某个功能独占的 view 留在该功能 target 内。

10. WebRTC 依赖只进入 `VoidDisplaySharing` 或明确需要实时分享能力的边界模块。

11. 私有显示接口只通过 `CGVirtualDisplayPrivate` 暴露，避免桥接头成为 App target 的隐性全局依赖。

12. 测试 target 与源码 target 一一对应。迁移、重构和验证都按 target 边界推进。

13. 资源放在所属 target 的 `Resources/` 下，并由 `Package.swift` 显式声明。

14. Feature 专属诊断 provider 放在对应 feature target 内，并依赖 `VoidDisplayObservability` 的中立协议。`VoidDisplayObservability` 不反向依赖任何 feature target。

## 命名规则

1. 不使用 `VoidDisplayCore`、`Common`、`Shared` 作为长期业务容器。

2. 模块名必须表达职责边界，例如 `VoidDisplayCapture`、`VoidDisplaySharing`、`VoidDisplayObservability`。

3. 只有真正无业务方向的代码可以进入 `VoidDisplayFoundation`。

4. 只有跨功能复用 UI 可以进入 `VoidDisplayDesignSystem`。

5. 平台适配模块必须带出平台或系统接口语义，例如 `VoidDisplayCGVirtualDisplay`。

## 迁移完成判定

1. `Package.swift` 中不存在 `VoidDisplayCore` target。

2. Xcode App target 的 Swift 源码只剩启动入口和系统集成胶水代码。

3. 每个功能模块都有对应测试 target。

4. `swift test` 可以覆盖 Swift Package 层的单元测试。

5. `xcodebuild` 可以完成 App target 构建，且无编译错误和编译警告。

6. UI 测试路径只依赖 App target 的运行结果，不承担业务模块单元验证职责。

7. app-facing 文案变更时，同步更新本地化资源。
