# VoidDisplay 当前架构

## 产品边界

VoidDisplay 在 macOS 上创建和管理 HiDPI 虚拟显示器，并为受管理的虚拟显示器提供本机 Preview 与可信局域网内的 LAN Web View。当前产品不提供公网中继、远程输入、剪贴板控制、账号体系或浏览器控制接口。

用户主界面包含 `Displays` 和 `Diagnostics` 两个入口。`Displays` 以已保存的虚拟显示器配置为主列表，承载启用、编辑、Preview 和 LAN Web View 操作。物理显示器状态可以进入内部运行时目录，但不会形成独立的用户管理主线。

## 组件职责

| 组件 | 职责 |
| --- | --- |
| `Apps/VoidDisplay` | Xcode App 入口、应用图标、Info.plist 文案和本地化资源 |
| `VoidDisplayApp` | SwiftUI 界面、应用装配、控制器和运行时适配 |
| `VoidDisplayRuntime` | 显示目录、事务、consumer lease、需求聚合、快照和 intent 分发 |
| `VoidDisplayVirtualDisplay` | 虚拟显示器领域模型、配置持久化、编排、拓扑等待、回滚和编辑界面 |
| `VoidDisplayCGVirtualDisplay` | 将运行时驱动接口映射到私有 `CGVirtualDisplay` 封装 |
| `CGVirtualDisplayPrivate` | 私有 `CGVirtualDisplay` API 的 Objective-C 封装 |
| `VoidDisplayCapture` | `SCStream` 生命周期、帧分发、Preview 渲染和采集性能状态 |
| `VoidDisplaySharing` | HTTP、WebSocket、WebRTC、分享路由、viewer 会话和 relay 进程 |
| `Tools/VoidDisplayRelay` | 由 App 启动的本地 Go relay，负责 loopback 控制 API、WebRTC room 和媒体转发 |
| `VoidDisplayObservability` | 结构化诊断事件、快照收集和脱敏 |
| `VoidDisplaySupport` | 支持草稿、历史记录和支持包编排 |
| `VoidDisplayDesignSystem` | 跨功能界面的视觉 token、通用组件和展示模型 |
| `VoidDisplayFoundation` | 跨模块基础类型、权限与持久化支撑 |
| `WebRTC` / `WebRTCBinary` | M147 二进制依赖与 macOS header overlay；来源记录见 [SOURCES.md](../Vendor/WebRTCHeaders/M147/SOURCES.md) |

SwiftPM target 和依赖关系以 [Package.swift](../Package.swift) 为准。

## 控制平面

`DisplayRuntime` 是显示生命周期的控制平面，持有以下结构化事实：

- `DisplaySurface` 目录与当前显示标识。
- 虚拟显示器 create、edit、delete、rebuild 和 startup restore 事务。
- Preview 和 LAN Web View 的 consumer lease。
- 聚合后的采集需求、有效 capture intent、事务 trace 和运行时快照。

应用启动通过 `DisplayRuntime.restoreStartupVirtualDisplays(source: .startup)` 恢复期望启用的虚拟显示器。用户发起的虚拟显示器变更先进入运行时事务，再经 App adapter 调用 `VoidDisplayVirtualDisplay` 的底层命令。事务在拓扑收敛后更新目录，并对已有 consumer lease 执行恢复或失败收口。

## 数据平面

帧、像素缓冲区、`SCStream`、Preview 渲染、WebRTC peer、WebSocket 连接、HTTP 请求和编码流程留在 Capture 与 Sharing 模块。Runtime 只分发结构化 intent，不持有这些资源对象。

LAN Web View 的分享路由生命周期与帧需求分开管理。启用分享会建立受 capability 保护的页面与信令入口。零 viewer 时路由可以继续有效，采集流只在 Preview 或实际 viewer 产生帧需求时运行。

完整访问和资源边界见 [LAN Web View 安全契约](./security/lan-web-view.md)。

## 依赖边界

以下约束需要长期保持：

1. `VoidDisplayRuntime` 不导入 SwiftUI、AppKit、ScreenCaptureKit、Capture、Sharing、VirtualDisplay 或 App target。
2. `VoidDisplayVirtualDisplay` 不依赖 `VoidDisplayRuntime`。App adapter 负责在两者之间映射命令和结果。
3. Runtime 不持有帧、session、peer、socket、listener 或 relay 进程。
4. UI 不直接执行底层虚拟显示器事务，也不绕过 consumer lease 启停 Preview 或 LAN Web View。
5. 用户可见文案使用 Displays、Preview、LAN Web View 和 Diagnostics，内部 `DisplaySurface`、lease、intent 等术语不进入产品界面。

`Package.swift` 的 target 依赖图与编译器约束直接模块依赖。跨层调用、资源所有权和运行时行为由代码审查与对应 SwiftPM 测试共同验证。

## 诊断与隐私

Diagnostics 以 runtime snapshot 作为主要结构化状态来源。支持包在落盘前经过最终脱敏边界，调用方提供的内容不会被默认视为已清洗。新增诊断字段或附件时，需要同时扩展脱敏测试和支持包测试。

## 验证入口

小范围架构改动先运行对应 target 测试和 Debug build：

```bash
scripts/ci/unit.sh --filter '<test-filter>'
scripts/ci/xcode.sh --action build --configuration Debug \
  --destination "platform=macOS,arch=$(uname -m)"
```

跨模块、并发、持久化、网络、安全或发布相关改动按照 [测试策略](./testing/testing-strategy.md) 和根目录 [AGENTS.md](../AGENTS.md) 提升验证范围。
