# VoidDisplay 产品定位与架构重构前置结论

状态：决策草案  
用途：作为后续架构重构规划、UI 信息架构调整、README 叙事更新的输入。  
范围：产品定位、核心对象、能力边界、技术模型命名、长期复杂度控制。  
说明：本文是项目定位和架构方向文档，不代表所有列出的能力都已在当前版本完整实现。

## 最终定位

VoidDisplay / 虚幕 的产品名保留。

推荐英文定位：

```text
VoidDisplay creates HiDPI virtual displays for headless Macs, making them usable by remote desktop apps and viewable from local-network browsers, including browser-based AI agents.
```

推荐中文定位：

```text
虚幕为无头 Mac 创建 HiDPI 虚拟显示器，让远程桌面软件使用这些显示器，并让同一局域网内的浏览器和 AI agent 查看显示内容。
```

更短的产品类别描述：

```text
Mac Remote Display Companion
```

中文可表达为：

```text
Mac 远程显示增强工具
```

核心边界：

```text
VoidDisplay 不做远程控制。RustDesk、ToDesk、VNC、AnyDesk、Parsec 等工具负责输入、控制、连接和账号体系。
VoidDisplay 负责创建高质量显示表面，并让这些显示表面被远程桌面软件使用，也能被局域网浏览器 viewer 查看。
```

## 产品主线

VoidDisplay 的产品定位是：

```text
以 HiDPI 虚拟显示器为根能力的 Mac 远程显示增强层。
```

它解决的原始问题是：

```text
无头 Mac mini 或无物理显示器的 Mac 在远程桌面软件中无法稳定获得高清 HiDPI 显示。
```

后续出现的本机监控、局域网 Web 查看、人类或 AI agent 通过浏览器观察桌面，都是同一条主线的扩展：

```text
创建一个稳定的显示表面，让同一局域网内的人、设备和 AI agent 通过浏览器看见它。
```

因此，虚拟显示器是产品根能力，局域网 Web View 是远端观察能力，监控窗口是本机观察能力，可观测与诊断是 AI agent 验证和故障排查能力。

## 核心对象

技术核心对象采用：

```text
DisplaySurface
```

命名决策：采用 `DisplaySurface`。不采用 `Workspace` 的原因：

- `Workspace` 语义过泛，容易被理解成协作空间、项目空间、云 IDE 或任务容器。
- `DisplaySurface` 更贴近产品事实，它是一块可被 macOS 排列、可被捕获、可被浏览器观看、可被远程桌面软件使用的显示表面。
- `DisplaySurface` 能自然承载虚拟显示器、物理显示器、捕获状态、观看者、分享 URL、可观测状态和诊断状态。

建议模型：

```text
DisplaySurface
  id
  kind: managedVirtualDisplay | physicalDisplay
  currentDisplayID
  identity
  resolution
  scale
  refreshRate
  health
  captureState
  viewerState
  shareURL
  lastTransaction
  lastFailure
```

其中 `managedVirtualDisplay` 是主路径。`physicalDisplay` 可以作为辅助类型存在，其能力范围受产品定位约束。

## UI 命名

主导航推荐使用：

```text
Displays
```

原因：

- 用户最容易理解。
- 不暴露工程概念。
- 能同时容纳虚拟显示器和有限范围内的物理显示器。

详情或状态中再区分：

```text
Virtual Display
Physical Display
Web View
Monitor
Share Link
```

当前不设置独立的 `Agent View` 入口。AI agent 通过 LAN Web View 访问显示内容。独立 `Agent View` 不属于当前产品范围。

## 功能层级

### 核心能力：Virtual Display

负责：

- 创建 HiDPI 虚拟显示器。
- 编辑分辨率、刷新率、排列相关配置。
- 启用、停用、删除虚拟显示器。
- 开机恢复虚拟显示器。
- 处理虚拟显示器残留、拓扑异常、主显示器异常切换。

这是产品主价值，所有长期规划都应优先保护这条主路径。

### 局域网 Web 观看：LAN Web View

负责：

- 在同一局域网内通过浏览器高清、高帧率、低延迟查看显示表面。
- 只提供局域网内访问，不提供互联网中继、NAT 穿透或公网远程访问。
- 让局域网中的其他用户或设备观看分享人的桌面内容。
- viewer 可以是人，也可以是通过浏览器读取画面的 AI agent。
- 提供稳定 URL、连接状态、viewer 数量、基础安全控制。
- 支持按 DisplaySurface 一键停止分享。

LAN Web View 是重要扩展能力，但它不负责远程输入，不负责远程控制。架构边界不代表降低 LAN Web View 的画质、帧率或实时性要求。

### 本机监控：Monitor

负责：

- 在本机窗口中查看显示表面。
- 适用于多虚拟屏场景下的总览和调试。
- 作为 capture pipeline 的本地 consumer。

Monitor 不应拥有显示拓扑判断权。它只消费 DisplaySurface 的快照和帧。

### 可观测与诊断：Observability & Diagnostics

负责：

- 输出 DisplaySurface 当前状态。
- 输出虚拟显示器 runtime identity。
- 输出 capture session、viewer session、last transaction、last failure。
- 输出 agent-readable runtime snapshot，供自动化工具和 AI agent 判断软件运行是否符合预期。
- 输出 transaction trace 和关键状态变更证据，供自动化工具和 AI agent 在修复问题后自行验证。
- 输出足够的结构化排查数据，减少依赖日志猜测。
- 导出 support bundle。

命名规则：

- 内部模块和底层数据能力叫 `Observability`。
- 用户可见主入口叫 `Diagnostics`。
- 中文用户可见主入口叫 `诊断`。
- 页面标题可用 `Health & Diagnostics` 或 `健康与诊断`，前提是页面同时展示健康状态和排查数据。
- `Support` / `支持` 只用于 support bundle、反馈包、导出给开发者的数据包，不作为这个能力的主入口名。
- `Observability` / `可观测` 只用于工程模块、agent-readable snapshot、开发者文档，不作为普通用户菜单名。
- 文档层合并称为 `Observability & Diagnostics`。

这一层的首要目标是提供稳定、结构化、可自动读取的运行时证据，使自动化工具和 AI agent 能参与验证。用户导出 support bundle 是同一套数据面向人工排查的出口。

可观测与诊断能力应内建于 DisplayRuntime 和 transaction，以结构化快照和事务记录为主，日志作为辅助材料。

菜单文案决策：

```text
Primary navigation: Diagnostics / 诊断
Page title, if health state is visible: Health & Diagnostics / 健康与诊断
Engineering module: Observability / 可观测
Export artifact: Support Bundle / 支持包
Feedback or help flow: Support / 支持
```

UI 迁移规则：现有 `Support Center` / `支持` 入口后续收敛为 `Diagnostics` / `诊断`。页面内保留 `Export Support Bundle` / `导出支持包`，表达这个动作是为了人工排查或向开发者提供数据。

## 明确不做

以下内容不进入产品主线：

- 远程鼠标键盘控制。
- NAT 穿透、账号体系、设备管理。
- 替代 RustDesk、ToDesk、VNC、AnyDesk、Parsec。
- 通用直播平台。
- 通用远程桌面平台。
- AI agent 执行平台。
- 多用户协作桌面。

这些方向超出当前产品边界，会影响项目维护焦点。

## 架构定位

产品定位围绕虚拟显示和远程显示增强。工程架构仍应采用统一显示运行时。

推荐架构底座：

```text
DisplayRuntime
```

`DisplayRuntime` 是控制平面，负责状态、事件、事务和快照。它不直接搬运视频帧。高清高帧率数据路径由 CaptureEngine 和 StreamingEngine 负责，并以局域网低延迟观看为优化目标。

推荐分层：

```text
AppShell
  SwiftUI
  navigation
  settings
  dependency assembly

DisplayRuntime
  DisplayGraph
  DisplaySurfaceStore
  SessionStore
  TransactionCoordinator
  PermissionStateMachine
  TopologyStateMachine
  DemandAggregator
  SnapshotPublisher

VirtualDisplayEngine
  create
  restore
  update
  destroy
  runtime handle management

CaptureEngine
  ScreenCaptureKit sessions
  per-display capture pipeline
  frame fanout
  preview consumer
  recording or diagnostics consumer

StreamingEngine
  WebRTC
  WebSocket
  HTTP routes
  viewer sessions

Observability
  event trace
  runtime snapshot
  agent-readable verification snapshot
  transaction trace
  support bundle
```

关键约束：

- `DisplayRuntime` 管生命周期，不处理视频帧。
- `CaptureEngine` 管 ScreenCaptureKit 和帧分发，不判断产品业务。
- `StreamingEngine` 管网络、WebRTC、WebSocket、HTTP，不判断虚拟显示器拓扑。
- `VirtualDisplayEngine` 管虚拟屏创建、销毁、恢复，不知道局域网 Web View 的 URL。
- `AppShell` 只渲染快照并提交 intent。

## DisplayGraph 的地位

`DisplayGraph` 仍然需要，但它不是产品对象。

它应作为系统事实快照：

```text
DisplayGraph
  physical displays
  managed virtual displays observed by system
  ScreenCaptureKit-visible displays
  permission state
  topology signatures
```

`DisplaySurface` 才是面向产品、UI、诊断和 session 的核心对象。

一个 DisplaySurface 可以引用 DisplayGraph 中的当前系统事实，也可以在拓扑变化时经历 offline、rebuilding、degraded、failed 等状态。

## 事务模型

虚拟显示器相关操作应采用显式事务：

```text
DisplayTransaction
```

短期重点事务：

- CreateVirtualDisplay
- EditVirtualDisplay
- DeleteVirtualDisplay
- RestoreVirtualDisplays
- RebuildVirtualDisplay
- RebuildVirtualDisplayFleet
- RecoverTopology

事务步骤应固定：

```text
1. 读取 DisplayGraph 和 DisplaySurface 快照
2. 计算受影响的 DisplaySurface
3. 暂停依附能力，例如 capture、Web View、Monitor
4. 调用 VirtualDisplayEngine 修改虚拟显示器
5. 等待拓扑稳定
6. 验证 managed identity 和当前 CGDisplayID
7. 恢复需要继续存在的 session
8. 写入 observability event 和 last transaction
9. 失败时执行补偿式恢复或降级
```

macOS 显示拓扑没有真正数据库事务。这里的回滚应被设计成补偿式恢复，依赖 generation、epoch、timeout 和 idempotent command。

## 捕获与观看模型

推荐模型：

```text
DisplaySurface -> CapturePipeline -> Consumers
```

Consumer 包括：

- local monitor window
- 局域网浏览器 viewer，包括人类观看者和 AI agent
- diagnostics recorder

每个 consumer 持有 session lease。最后一个 lease 释放后，capture pipeline 进入 draining。

Demand aggregation 由统一规则决定：

- 分辨率取满足当前消费者的目标值。
- 帧率按最高需求和性能模式裁剪。
- cursor 只要任一 consumer 需要则开启。
- WebRTC 编码需求由 StreamingEngine 提交，最终由 DisplayRuntime 聚合。

这能避免 monitoring、sharing、diagnostics 各自调节帧率和分辨率。

## 架构风险与约束

统一运行时的目标是统一控制平面，不是合并所有实现细节。

硬约束：

- `DisplayRuntime` 只做控制平面，负责状态、事件、事务、session lease、DisplaySurface snapshot 和 intent dispatch。
- `DisplayRuntime` 不直接拥有 ScreenCaptureKit stream、WebRTC session、虚拟屏 driver 细节或 SwiftUI view state。
- `DisplaySurface` 是产品对象和聚合快照，不替代系统事实源。
- 系统事实源包括 CGDisplay topology、ScreenCaptureKit visible displays、virtual display config、runtime handles、capture sessions、viewer sessions、permission state。
- `DisplayTransaction` 只串行化虚拟屏和拓扑变更，例如创建、删除、编辑、恢复、重建和拓扑修复。
- viewer 连接、monitor attach、WebRTC 帧发送、capture fanout 属于普通命令或数据平面，不进入同一个事务队列。
- LAN Web View 的高清、高帧率、低延迟是主体验目标，性能策略应默认偏向局域网高质量观看。
- Demand aggregation 不应过度降级 LAN Web View 画质。多 viewer、Monitor 和 LAN Web View 同时存在、低功耗模式等场景需要显式策略。
- Observability 默认输出脱敏结构化状态，供自动化工具和 AI agent 读取。
- support bundle 默认脱敏导出。enhanced diagnostics 需要用户显式开启。
- `physicalDisplay` 是辅助能力，其产品承诺低于 `managedVirtualDisplay` 主路径。

## 安全边界

局域网 Web View 即使只读，也会暴露桌面内容。短期安全要求：

- 默认只面向局域网。
- 当前阶段不引入随机 token、访问密码、账号体系或鉴权层。
- UI 明确显示正在分享的 DisplaySurface。
- UI 显示当前 viewer 数量。
- 支持按 DisplaySurface 一键停止分享。
- 支持关闭整个 Web 服务。

后续可评估：

- 随机 token 或等价访问凭证。
- 访问密码。
- 仅本机访问模式。
- 指定网段允许列表。
- HTTPS 或自签证书。
- 临时 URL 过期。

## 开源定位

当前项目以开源为主，不以售卖盈利为短期目标。

这个策略与产品方向兼容，也符合个人维护和社区反馈驱动的开发方式。

开源的价值：

- macOS 显示、ScreenCaptureKit、权限、虚拟屏和远程桌面组合依赖真实机器反馈。
- 用户更容易信任一个会读取和分享桌面内容的工具。
- 社区能提供不同 macOS 版本、不同远程桌面软件、不同硬件组合下的问题报告。

需要控制的风险：

- 开源项目容易被 issue 拉成通用屏幕分享工具。
- 贡献者可能倾向增加远程控制、账号、云服务、AI 平台能力。
- Apache-2.0 是宽松开源许可证，允许商业使用和再分发。若未来项目目标发生变化，需要重新评估许可证策略。

项目应在 README 和贡献文档中明确：

```text
VoidDisplay is a remote display companion, not a remote control system.
```

## 相邻项目边界

对照项目用于确认边界，不作为直接竞品路线：

- [BetterDisplay](https://github.com/waydabber/BetterDisplay)：覆盖广泛的 macOS 显示增强能力，包括虚拟屏、HiDPI、headless Mac remote access、PIP/streaming 等。VoidDisplay 不应追求同类大而全显示管理器。
- [DeskPad](https://github.com/Stengo/DeskPad)：定位是用于 screen sharing 的 virtual monitor。VoidDisplay 可借鉴其清晰边界，但应保留 headless Mac、HiDPI remote desktop、局域网 Web View 这条主线。
- [RustDesk](https://rustdesk.com/open-source.html)：远程桌面软件，负责连接与控制。VoidDisplay 应作为这类工具的显示增强 companion。

## 长期维护判断

最稳路线：

```text
产品定位：Mac Remote Display Companion
核心对象：DisplaySurface
核心功能：HiDPI Virtual Display
扩展能力：LAN Web View, Monitor
架构底座：DisplayRuntime
```

非目标路线：

- 远程控制软件路线。
- 通用屏幕分享软件路线。
- AI agent 平台路线。
- 仅以虚拟显示器工具为边界，同时让虚拟显示器模块承载 Web View、Monitor、Diagnostics 等跨域能力。
- 以泛化 DisplayRuntime 作为唯一锚点，缺少 DisplaySurface 作为产品对象。

## 后续重构规划输入

下一阶段重构规划应围绕这些问题展开：

1. `DisplaySurface` domain model 放在哪个 target。
2. `DisplayRuntime` 是新增 target，还是从现有 AppState、Capture、Sharing、VirtualDisplay 中逐步抽取。
3. 当前 `ScreenCatalogOrchestrator`、`CaptureController`、`SharingController`、`VirtualDisplayController` 的责任如何迁移。
4. `DisplayTransaction` 如何串行化虚拟显示器变更和拓扑恢复。
5. Capture fanout 如何从功能页驱动改成 DisplaySurface consumer lease 驱动。
6. UI 如何从功能标签页逐步调整为 `Displays` 主入口。
7. 现有 README 如何改写为 headless Mac、HiDPI remote desktop、LAN browser viewing 主线。
8. 局域网 Web View 的安全策略和 viewer state 如何进入 snapshot。
9. 可观测与诊断如何提供 agent-readable runtime snapshot 和事务验证证据。

## 决策摘要

保留：

- 产品名 `VoidDisplay / 虚幕`。
- 虚拟显示器作为根能力。
- 局域网 Web View 作为核心扩展能力。
- 局域网 Web 观看和本机监控作为 DisplaySurface consumer。
- 可观测与诊断作为 AI agent 自验证和用户故障排查的数据底座。
- 开源优先。

采用：

- 技术核心对象 `DisplaySurface`。
- UI 主入口 `Displays`。
- 架构底座 `DisplayRuntime`。
- 显式 `DisplayTransaction`。
- consumer lease 驱动的 capture pipeline。

不采用：

- `Workspace` 作为核心命名。
- 独立 `Agent View` 产品入口。
- 远程控制路线。
- 通用屏幕分享平台路线。
- 泛 AI agent 平台路线。
