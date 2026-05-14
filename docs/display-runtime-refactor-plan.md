# DisplayRuntime 重构执行计划

状态：已完成路线图
依据：[产品定位与架构重构前置结论](./product-positioning.md)  
范围：新增 DisplayRuntime 架构底座、DisplaySurface 产品对象、只读运行时快照、后续事务和 UI 迁移顺序。  
完成说明：DisplayRuntime Phase 1 到 Phase 6 已完成。本文现在是主路线历史路线图和当前架构导航入口，不再作为当前待办清单。
最终收口提交范围：主路线从 `3ce2d9d6 docs(runtime): 固化 DisplayRuntime 重构执行计划` 建立路线，到 `65416583 refactor(app): 清理 Phase 6 旧入口与用户文案` 完成 Phase 1 到 Phase 6 实现收口；`8f36ff65 docs(runtime): 制定重构后收尾计划` 是主路线完成后的收尾入口提交。
导航：推荐阅读顺序见 [DisplayRuntime 文档索引](./display-runtime-index.md)。主路线完成后的整理工作见 [DisplayRuntime Post-Refactor Cleanup Plan](./display-runtime-post-refactor-cleanup-plan.md)，该收尾计划不使用新的阶段编号。

## Summary

本计划将 VoidDisplay 从现有的 `CaptureController`、`SharingController`、`VirtualDisplayController`、`ScreenCatalogOrchestrator` 分散协作，逐步收敛到以 `DisplaySurface` 为产品对象、以 `DisplayRuntime` 为控制平面的架构。

采用路线：

```text
新增 VoidDisplayRuntime target
DisplaySurface 作为产品聚合对象
DisplayRuntime 作为控制平面
CaptureEngine 和 StreamingEngine 保留高清高帧率数据路径
```

核心原则：

- `DisplayRuntime` 管状态、事件、事务、session lease、snapshot 和 intent dispatch。
- `DisplayRuntime` 不直接搬运视频帧，不拥有 `SCStream`、WebRTC session、虚拟屏 driver 或 SwiftUI view state。
- LAN Web View 的高清、高帧率、低延迟是主体验目标。
- `DisplaySurface` 是产品对象和聚合快照，不替代 CGDisplay、ScreenCaptureKit、虚拟屏 runtime、capture session、viewer session 等系统事实源。
- `DisplaySurfaceIdentity` 不替代 LAN Web View 的 `shareID` 路由身份。
- 先建立只读模型和 snapshot，再迁移事务和命令，最后调整 UI 信息架构。

## Target Architecture

新增 target：

```text
VoidDisplayRuntime
```

Phase 1 最小依赖关系：

```text
VoidDisplayRuntime
  VoidDisplayFoundation
  VoidDisplayObservability

VoidDisplayApp
  VoidDisplayRuntime
  VoidDisplayVirtualDisplay
  VoidDisplayCapture
  VoidDisplaySharing
  VoidDisplaySupport
  VoidDisplayObservability
  VoidDisplayFoundation
```

依赖边界：

- `VoidDisplayRuntime` 不能依赖 `VoidDisplayApp`。
- Phase 1 不让 `VoidDisplayRuntime` 直接依赖 `VoidDisplayVirtualDisplay`、`VoidDisplayCapture` 或 `VoidDisplaySharing`。
- 后续阶段如果确实需要直接依赖功能 target，必须只使用纯 service、model、protocol，记录理由和删除替代条件。
- 优先把跨模块契约表达为 runtime ports 和 DTO；不要为了复用现有 controller 或 view model 增加 target 依赖。
- `VoidDisplayRuntime` 不能导入 `SwiftUI`、`AppKit`、`Observation` 或 `VoidDisplayDesignSystem`。
- `VoidDisplayRuntime` 只消费 service、model、protocol 和 snapshot DTO，不消费 View、ViewModel 或 app controller 类型。
- 如果某个功能模块当前把 UI 类型和服务类型放在同一个 target，runtime 仍只能通过显式 runtime ports 读取状态或下发命令。
- `VoidDisplayApp` 负责把现有 app controller 适配成 runtime ports，并负责依赖装配。

新增测试 target：

```text
VoidDisplayRuntimeTests
```

第一阶段新增核心类型：

```text
DisplaySurface
DisplaySurfaceKind
DisplaySurfaceIdentity
DisplayRuntimeSnapshot
DisplayRuntime
DisplayRuntimeSnapshotProvider
```

`DisplaySurface` 初始身份规则：

- `managedVirtualDisplay` 以 virtual display config id 作为稳定主身份。
- `physicalDisplay` 作为辅助 surface，初期以当前 display id 和系统快照聚合。
- `currentDisplayID` 是当前系统绑定，不作为长期稳定身份。

`DisplayRuntime` 初始职责：

- 通过 runtime ports 聚合 capture、sharing、virtual display、screen catalog 状态。
- 输出 agent-readable runtime snapshot。
- 注册 Observability snapshot provider。
- 不迁移用户命令。
- 不改变 UI。
- 不改捕获、编码、WebRTC 或预览渲染数据路径。
- 不直接读取 `CaptureController`、`SharingController`、`VirtualDisplayController` 或 `ScreenCatalogOrchestrator`。

### Runtime Ports

Phase 1 必须先定义 runtime 输入端口和 DTO，再接入现有 controller。

初始端口：

- `DisplayRuntimeCatalogProviding`：提供权限状态、可见 display 摘要、拓扑签名和加载错误。
- `DisplayRuntimeCaptureProviding`：提供监控 session 摘要、starting display ids、capture metrics 摘要。
- `DisplayRuntimeSharingProviding`：提供 Web service lifecycle、active sharing display ids、viewer counts、share route 摘要。
- `DisplayRuntimeVirtualDisplayProviding`：提供 managed virtual display configs、runtime display id 映射、restore failure 摘要。
- Phase 2 之后逐步增加 command ports，例如 `DisplayRuntimeCaptureCommanding`、`DisplayRuntimeSharingCommanding`、`DisplayRuntimeVirtualDisplayCommanding`，用于事务和 intent dispatch。

端口约束：

- 端口返回 runtime DTO，不能返回 `SCDisplay`、`CMSampleBuffer`、`CVPixelBuffer`、`NSImage` 或 SwiftUI state。
- DTO 必须是 `Sendable`，需要进入 Observability 的 DTO 同时必须是 `Codable` 和 `Equatable`。
- App target 中的 adapters 可以读取现有 `@MainActor` controller，但 adapters 只做映射，不承载业务判断。
- Runtime target 的 tests 使用 fake ports，不实例化真实 macOS 权限、ScreenCaptureKit stream、WebRTC session 或虚拟屏 driver。
- Runtime command ports 只能表达命令意图和结果，不返回 engine handle、driver handle、WebRTC session 或 capture session。

### Identity And Route Boundaries

`DisplaySurfaceIdentity`、系统 display id、virtual display config id、capture session id、viewer session id、Web share id 必须保持边界清楚。

LAN Web View 路由规则：

- 真实分享目标继续使用 `shareID`：`/display/{shareID}`、`/signal/{shareID}`。
- `/display` 和 `/signal` 继续只作为当前系统主显示器别名。
- 当前系统主显示器变化时，别名跟随新的主显示器。
- 具体 `shareID` 路由保持稳定，不受 main display alias 变化影响。
- UI 默认继续展示以 `/display/{shareID}` 为目标 path 的具体分享 URL。
- Runtime snapshot 可以暴露 share route 状态，但不能把 `DisplaySurfaceIdentity` 作为 Web route identity。
- 当前阶段不引入随机 token、访问密码或鉴权机制。
- `shareID` 只表示显示目标身份，不作为安全承诺。

脱敏边界：

- Runtime 内部可以关联 raw `shareID`、display id、session id 和 consumer id。
- 默认 Observability snapshot 和 support bundle 不导出完整 LAN URL、LAN IP、用户路径、窗口标题、桌面内容或用户文本。
- 默认导出可以保留 route kind、是否存在 concrete route、viewer count、redacted id 或稳定 hash。
- raw `shareID` 和完整分享 URL 只允许出现在 app 内 UI 或用户显式开启的 enhanced diagnostics 中。

### Concurrency Boundaries

`DisplayRuntime` 是控制平面对象，不持有 SwiftUI view state。

并发约束：

- `DisplayRuntime` 首选实现为 `actor` 或等价单串行执行器，不实现为 SwiftUI `@Observable` 状态容器。
- 如果某个阶段必须让 runtime 的部分入口运行在 `@MainActor`，必须记录理由，并把高成本工作留在 engine 或 service 层。
- Runtime snapshot DTO 是不可变值，不持有 `SCDisplay` 等 ScreenCaptureKit 对象。
- App adapters 负责从 `@MainActor` controller 读取状态并转换成 `Sendable` DTO。
- Runtime 内部状态机和 transaction coordinator 必须串行化状态变更。
- 跨 actor 只传递 DTO、intent、transaction result 和 observability event。
- 高成本 IO、编码、帧分发和 WebRTC 发送不能在 runtime actor 内执行。

## Implementation Phases

### Phase 0: Preflight

目标：保证正式重构开始前的工作区、验证基线和性能基线清楚。

执行项：

- 先处理当前未提交的 `Apps/VoidDisplay/VoidDisplay.xcodeproj/project.pbxproj` 变更，避免和新增 target、Xcode 工程修改混在一起。
- 记录当前基线验证结果：SwiftPM targeted tests 和 Xcode Debug build。
- 为 LAN Web View 记录基线表现，输出到 `.ai-tmp/display-runtime-baseline/`。
- 基线记录包含目标分辨率、帧率、viewer 数、CPU、内存、明显延迟体感、测试设备和网络条件。
- LAN Web View 基线属于本机真实环境证据，不进入默认 CI regression gate。
- 基线验证输出保留机器可读摘要，至少记录命令、退出码、测试数量、失败分类和日志路径。

验证：

```sh
scripts/ci/unit.sh --filter ObservabilitySnapshotProviderTests
scripts/ci/xcode.sh --action build --configuration Debug
```

### Phase 1: Runtime Model And Read-Only Snapshot

目标：建立 `VoidDisplayRuntime` target、`DisplaySurface` 模型和只读 runtime snapshot，不改变现有行为。

执行项：

- 新增 `VoidDisplayRuntime` target 和 `VoidDisplayRuntimeTests`。
- 实现 `DisplaySurface`、`DisplaySurfaceKind`、`DisplaySurfaceIdentity`、`DisplayRuntimeSnapshot`。
- 实现 runtime ports 和只读 `DisplayRuntime`，从 port DTO 构建 snapshot。
- 在 `VoidDisplayApp` 中新增最小 adapters，把现有 controller 和 store 映射到 runtime ports。
- 实现 `DisplayRuntimeSnapshotProvider` 并注册到 `ObservabilityCenter`。
- 保留现有 `CaptureSnapshotProvider`、`SharingSnapshotProvider`、`VirtualDisplaySnapshotProvider`、`ScreenCatalogSnapshotProvider` 作为对照。
- 不迁移命令，不改变 UI，不改捕获或 WebRTC 数据路径。
- Runtime target 中禁止出现 UI import、app controller import、ScreenCaptureKit frame type 和 WebRTC session type。
- 旧 snapshot providers 的保留条件只限 Phase 1 到 Phase 5 的 parity 对照；Diagnostics 切到 runtime snapshot 后必须删除重复 provider 或降为明确的 runtime 子 section。

验证：

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter ObservabilitySnapshotProviderTests
if rg -n "import (SwiftUI|AppKit|Observation|VoidDisplayDesignSystem|VoidDisplayApp)" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "\\b(SCDisplay|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession|DisplayCaptureSession)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
scripts/ci/xcode.sh --action build --configuration Debug
```

验收条件：

- `DisplayRuntimeSnapshot` 能同时表达 managed virtual display 和 physical auxiliary surface。
- managed virtual display 使用 config id 稳定身份。
- snapshot 中能看到 capture、sharing、virtual display、screen catalog 的关键状态。
- snapshot 中能表达 surface identity 和 LAN Web View share route 的关系，但不混用两类身份。
- Observability current state 中出现 runtime section。
- Runtime snapshot DTO 均为不可变、`Sendable`、可测试值。
- `Package.swift` 中 `VoidDisplayRuntime` Phase 1 只依赖 `VoidDisplayFoundation` 和 `VoidDisplayObservability`。
- Debug build 零 compile errors、零 compile warnings。

### Phase 2: Catalog Convergence Into Runtime

目标：把显示目录、权限、拓扑变化和 visible display convergence 从 `ScreenCatalogOrchestrator` 逐步迁入 `DisplayRuntime`。

执行项：

- 先抽取 catalog、capture、sharing、virtual display runtime ports，避免 runtime 直接引用 app controller。
- 在 `DisplayRuntime` 中承接 permission refresh、topology refresh、visible display convergence。
- `ScreenCatalogOrchestrator` 暂时变成 thin adapter，只做 app API 转发和 MainActor 装配。
- 行为保持一致：权限拒绝时清空可见显示，sharing service running 时注册可分享显示，不可见 display 停止 sharing 和 monitoring。
- 迁移完成后删除不再需要的 `ScreenCatalogOrchestrator` 逻辑分支。
- Runtime 不持有 `SCDisplay`；需要启动 sharing 或 monitor 时，通过 command port 使用当前 catalog provider 再解析。
- command ports 的 adapter 位于 `VoidDisplayApp` 或后续明确拆出的 engine target，不能把 app controller 类型暴露给 runtime。

验证：

```sh
scripts/ci/unit.sh --filter ScreenCatalogOrchestratorTests
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/xcode.sh --action build --configuration Debug
```

验收条件：

- permission denied 场景行为不变。
- topology changed 场景只触发一次收敛序列或等价去重行为。
- sharing service start 复用当前 catalog snapshot 时仍能注册可分享显示。
- display removed 后对应 sharing 和 monitoring 会停止。
- Runtime ports 覆盖现有 `ScreenCatalogOrchestratorTests` 中的权限、拓扑、sharing、monitoring 行为。

### Phase 3: Virtual Display Transactions

目标：把虚拟屏和拓扑变更建模为显式 `DisplayTransaction`，并写入 Observability。

执行项：

- 在 `VoidDisplayRuntime` 中新增 `DisplayTransactionCoordinator`。
- 先接管 rebuild 事务：暂停依附 session，调用虚拟屏重建，等待拓扑稳定，恢复需要继续存在的 session，写入 transaction trace。
- 再接管 enable、disable、create、edit、delete、restore。
- transaction trace 包含 transaction id、affected surfaces、pre snapshot、post snapshot、failure、compensation result。
- viewer 连接、monitor attach、WebRTC 帧发送、capture fanout 不进入同一个事务队列。
- 事务执行通过 command ports 调用 capture、sharing、virtual display 操作，不直接依赖 app controller 或 engine implementation。
- 每个 surface 维护 runtime epoch，拓扑重建、display id 变化和事务恢复都会推进 epoch。
- 事务期间 affected surfaces 进入 quiescing 状态，新 consumer lease attach 必须等待、返回 restarting/degraded，或绑定新 epoch，不能复活旧 session。
- 同一 surface 的事务请求串行执行，可合并等价 rebuild 请求；不同 surface 的事务只有在共享拓扑风险明确可控时才允许并行。
- compensation 是显式恢复动作，不承诺所有失败都能完整回滚；无法补偿时必须留下 degraded snapshot 和 failure reason。

验证：

```sh
scripts/ci/unit.sh --filter DisplayRebuildCoordinatorTests
scripts/ci/unit.sh --filter DisplayTeardownCoordinatorTests
scripts/ci/unit.sh --filter DisplayTeardownCoordinatorOfflineWaitTests
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/xcode.sh --action build --configuration Debug
```

验收条件：

- rebuild 成功、失败、补偿、并发请求串行化均有测试覆盖。
- transaction trace 能在 Observability snapshot 或 recent events 中定位。
- 事务失败不会留下伪 active 的 surface、capture session 或 sharing session。
- consumer attach 与 rebuild 并发时不会绑定旧 epoch。

### Phase 4: Consumer Lease And Demand Aggregation

目标：把 Monitor、LAN Web View、diagnostics recorder 建模为 `DisplaySurface` consumer lease，同时保留现有高性能数据路径。

执行项：

- 在 runtime 层新增 consumer lease 模型。
- `DisplayCaptureRegistry` 继续负责 capture session、帧分发和 draining。
- Runtime 只聚合需求并下发 intent。
- 默认策略偏向 LAN 高质量观看：smooth 和 automatic 不主动降画质，powerEfficient 才允许显式降级。
- 显式定义多 viewer、Monitor 和 LAN Web View 同时存在、低功耗模式的优先级。
- LAN Web View 继续以 `shareID` 作为具体路由身份；surface identity 只用于 runtime 聚合和诊断关联。
- `/display`、`/signal` 保持当前系统主显示器 alias 语义，不能替换具体 `/display/{shareID}`、`/signal/{shareID}`。
- 当前阶段不增加 LAN Web View 随机 token、访问密码、账号体系或鉴权层。
- consumer lease 必须绑定 surface epoch；epoch 变化时 lease 需要重新解析或进入 restarting。
- 多 viewer 不创建重复 capture session；viewer 增减只改变 demand 和 streaming fanout。
- smooth 和 automatic 优先保持源质量，但 encoder failure、内存压力、网络背压或系统低功耗必须进入 observable degraded state，不能静默反复重启。
- LAN Web View 不引入互联网 relay、隧道或公网发现；任何未来公网能力必须另立方案和安全模型。
- viewer endpoint 不能提供 diagnostics、support bundle 或 runtime snapshot 导出。

验证：

```sh
scripts/ci/unit.sh --filter VoidDisplayCaptureTests
scripts/ci/unit.sh --filter VoidDisplaySharingTests
scripts/ci/unit.sh --filter CaptureSharingIsolationTests
scripts/ci/unit.sh --filter DisplayShareIDStoreTests
scripts/ci/unit.sh --filter WebRoutingWorkflowSmokeTests
scripts/ci/unit.sh --filter SharingServiceTests
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/xcode.sh --action build --configuration Debug
```

验收条件：

- consumer lease attach、detach、最后 lease 释放后 draining 行为有测试覆盖。
- Monitor 和 LAN Web View 同时存在时 capture demand 为 mixed 或等价高质量需求。
- smooth 和 automatic 下 LAN Web View 不被过度降级。
- Runtime 不直接处理 `CMSampleBuffer`、`CVPixelBuffer` 或编码帧。
- main display alias 和具体 `shareID` route 的行为有测试覆盖。
- surface epoch 变化后旧 consumer lease 不再驱动旧 capture session。

### Phase 5: Observability And Diagnostics Hardening

目标：让 runtime snapshot 成为 AI agent、自动化工具和用户诊断的结构化事实接口。

执行项：

- Runtime snapshot 输出 agent-readable structured state。
- 默认 snapshot 脱敏，不包含桌面内容、窗口标题、用户文本、URL、路径明文。
- 默认 snapshot 不导出 raw `shareID`、LAN IP 或完整分享 URL。
- support bundle 默认使用脱敏 runtime snapshot。
- enhanced diagnostics 需要用户显式开启。
- Diagnostics 页面读取 runtime snapshot，不再主要依赖分散 controller 状态。
- enhanced diagnostics 的 raw identifier 输出必须标明来源、用途和关闭方式。

验证：

```sh
scripts/ci/unit.sh --filter VoidDisplayObservabilityTests
scripts/ci/unit.sh --filter VoidDisplaySupportTests
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/xcode.sh --action build --configuration Debug
```

验收条件：

- runtime snapshot 默认脱敏。
- support bundle 包含 runtime section。
- enhanced diagnostics 未开启时不导出高敏信息。
- raw `shareID`、LAN IP、完整分享 URL 默认不出现在 support bundle 中。
- Diagnostics 页面和 exported support bundle 使用同一套结构化数据源。

### Phase 6: UI Information Architecture

目标：在 runtime snapshot 稳定后调整 UI 信息架构和命名。

执行项：

- `Displays` 成为主入口，逐步承载 Virtual Display、Monitor、LAN Web View 状态与动作。
- `Support Center` 入口迁移为 `Diagnostics` / `诊断`。
- 页面内保留 `Export Support Bundle` / `导出支持包` 作为动作。
- 同步更新 `Localizable.xcstrings` 和相关 app-facing 文案。
- UI tests 继续使用 test provider、mock、stub，不触发真实隐私权限弹窗。
- 不新增纯 render/body smoke 测试；UI smoke 必须验证用户可观察行为或关键状态变化。

验证：

```sh
scripts/ci/ui_smoke.sh \
  --only-testing VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline
scripts/ci/xcode.sh --action build --configuration Debug
```

验收条件：

- 主导航符合 `Displays` 和 `Diagnostics` 命名。
- UI 明确显示正在分享的 DisplaySurface。
- UI 显示当前 viewer 数量。
- UI 支持按 DisplaySurface 停止分享。
- UI 保留关闭整个 Web service 的动作。
- UI smoke 通过。
- 相关 localization 已更新。
- UI 测试不触发真实屏幕录制、输入、摄像头、麦克风等隐私授权弹窗。

## Global Verification Rules

每个代码阶段完成后必须满足：

- 使用 `scripts/ci/*` 统一入口，避免本地命令和 CI 命令分叉。
- 相关 targeted tests 通过。
- Xcode Debug build 通过。
- 零 compile errors。
- 零 compile warnings。
- Observability snapshot 能反映该阶段新增 runtime 状态。
- 测试结果必须确认执行数量；0 tests 视为无效结果。
- Xcode test 必须使用 `--only-testing` 或 `--test-plan`，避免误跑或空跑。
- 失败摘要需要区分 compile failure、test failure、0 tests、runner instability、permission environment、syspolicy/Gatekeeper environment。

完整回归只在这些情况运行：

- target、Package、Xcode 工程或测试基础设施变更。
- 影响 capture、sharing、virtual display 共享路径的改动。
- UI 信息架构迁移完成。
- 变更风险无法通过 targeted tests 限定。

可选完整门槛：

```sh
scripts/ci/full_regression.sh --out-dir .ai-tmp/full-regression
```

真实环境验证规则：

- LAN Web View 性能基线、真实 viewer、多设备网络观看属于 opt-in 本机验证。
- 真实环境验证输出写入 `.ai-tmp/`，不作为默认 CI gate。
- 任何需要真实屏幕录制、输入、摄像头、麦克风、网络拓扑或人工授权的测试都不能进入默认 regression。
- 如果需要真实环境 E2E，必须显式使用隔离环境变量、独立 runner 标记和可跳过策略。

Xcode 启动失败分类：

- 如果 Xcode 测试在 app 或 test bootstrap 前失败，先检查 `.xcresult`、`totalTestCount` 和 system policy 相关信号。
- 出现 syspolicy、Gatekeeper、`OS_REASON_EXEC` 一类签名时，先按环境故障处理，再重跑最小 targeted command。
- 预启动失败、0 tests、runner 授权缺失不能直接归类为产品代码回归。

## Rollout And Cleanup Rules

- 不保留长期兼容层。
- 每个 adapter、bridge、thin wrapper 必须标注删除条件。
- App adapters 是 runtime 端口装配边界，可以长期保留；旧 controller adapter 和旧 snapshot provider 只有在迁移窗口内保留。
- 每个阶段结束时删除已经无调用方的旧路径。
- 不把 physical display 提升为和 managed virtual display 同级的产品承诺。
- 不迁移视频帧数据路径，除非该阶段明确处理 CaptureEngine 或 StreamingEngine。
- 所有 AI agent 可读数据默认脱敏。

## Assumptions

- 使用新增 `VoidDisplayRuntime` target，不把 runtime 放入 `VoidDisplayApp` 或 `VoidDisplayFoundation`。
- `VoidDisplayRuntime` Phase 1 只依赖 `VoidDisplayFoundation` 和 `VoidDisplayObservability`；跨功能模块状态通过 ports 接入。
- Swift 6 和 macOS deployment target `15.6` 保持不变。
- 当前 `docs/product-positioning.md` 是定位依据。
- 当前计划不执行具体重构，只定义后续实施顺序、边界和验证门槛。
- 当前计划不表示所有目标能力已经在当前版本实现。
