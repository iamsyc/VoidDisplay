# 屏幕监听与屏幕共享优化方案

> 记录日期：2026-03-25  
> 适用范围：`VoidDisplay/Features/Capture`、`VoidDisplay/Features/Sharing`、`VoidDisplay/App`、`VoidDisplay/Shared/ScreenCapture`  
> 分析基线：当前工作区实现，包含本地未提交改动

## 1. 目标

这份文档解决两个问题：

1. 当前屏幕监听与屏幕共享已经在底层采集层合流，上层状态与目录管理仍然分裂，导致重复加载、状态分叉、恢复路径复杂。
2. 当前采集、预览、WebRTC 发送三段规格不一致，造成资源浪费与稳定性风险。

本轮优化目标如下：

1. 收敛屏幕目录、权限、拓扑状态，建立单一真相源。
2. 把采集配置变成按消费方动态决策的策略层。
3. 给本地预览链路补齐背压与丢帧控制，避免主线程被高频帧淹没。
4. 让共享连接状态改成事件驱动，去掉 UI 轮询。
5. 修正网页端 WebRTC 配置缺口，贯通服务端与浏览器端的 ICE/TURN 配置。
6. 补足监听与共享联合负载场景的测试覆盖。
7. 给关键指标补量化验收门槛，并保证自动化测试保持非交互执行。

## 2. 当前问题归因

### 2.1 目录与权限状态分裂

`CaptureController` 和 `SharingController` 各自持有一份 `ScreenCaptureDisplayCatalogState`。

相关位置：

1. `VoidDisplay/App/CaptureController.swift`
2. `VoidDisplay/App/SharingController.swift`
3. `VoidDisplay/Features/Capture/ViewModels/CaptureChooseViewModel.swift`
4. `VoidDisplay/Features/Sharing/ViewModels/ShareViewModel.swift`
5. `VoidDisplay/Shared/ScreenCapture/ScreenCaptureDisplayCatalogLoader.swift`

后果：

1. 监听页与共享页会分别触发 `SCShareableContent` 加载。
2. 权限状态与最近一次加载错误会分叉。
3. 页面切换后可能出现一边已刷新、一边仍持有旧目录的情况。

### 2.2 采集规格与发送规格失配

当前链路表现如下：

1. `DisplayCaptureSession` 采集帧率按显示器刷新率设置，最高到 `120fps`。
2. WebRTC media pipeline 适配输出格式时固定为 `60fps`。
3. RTP sender 编码参数又把最高帧率压到 `30fps`。

相关位置：

1. `VoidDisplay/Features/Capture/Services/DisplayCaptureSession.swift`
2. `VoidDisplay/Features/Capture/Services/DisplayCaptureRegistry.swift`
3. `VoidDisplay/Features/Sharing/Web/WebRTCSessionHub.swift`

后果：

1. 采集负载高于实际发送需要。
2. 编码端和采集端之间存在长期浪费。
3. 当监听和共享并存时，单一路径很难兼顾本地预览流畅度与网络稳定性。

### 2.3 本地预览链路没有背压

当前预览帧 fanout 方式是逐帧同步派发，`ZeroCopyPreviewRenderer` 对每一帧再创建一个 `Task` 切到 `MainActor`。

相关位置：

1. `VoidDisplay/Features/Capture/Services/DisplaySampleFanout.swift`
2. `VoidDisplay/Features/Capture/Services/DisplayCaptureSession.swift`
3. `VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift`

后果：

1. 高频帧输入时，主线程任务可能堆积。
2. 多个预览 sink 并存时，慢 sink 会拖累整条链路。
3. 监听窗口压力会反向影响共享稳定性。

### 2.4 共享状态传播仍是轮询模型

共享页通过每秒定时器刷新观看人数和 target 计数。

相关位置：

1. `VoidDisplay/Features/Sharing/Views/ShareView.swift`
2. `VoidDisplay/App/SharingController.swift`
3. `VoidDisplay/Features/Sharing/Web/WebServer.swift`
4. `VoidDisplay/Features/Sharing/Web/WebRTCSessionHub.swift`

后果：

1. UI 层存在固定频率的无效刷新。
2. 状态变化不能即时反馈。
3. target 客户端数与真实连接状态可能短时失真。

### 2.5 浏览器端 WebRTC 配置不完整

服务端已经预留 ICE server 配置扩展点，网页端仍然硬编码 `iceServers: []`。

相关位置：

1. `VoidDisplay/Features/Sharing/Web/WebRTCSessionHub.swift`
2. `VoidDisplay/Features/Sharing/Web/displayPage.html`

后果：

1. 当前共享能力仍然依赖 host candidate 与局域网入口。
2. 配置扩展只到达服务端，没有贯通到浏览器端。

### 2.6 拓扑刷新路径两套实现

共享页有 `DisplayTopologyRefreshLifecycleController`、去抖回调注册与轮询回退；监听页也已经复用同一套拓扑监听机制。

相关位置：

1. `VoidDisplay/Shared/ScreenCapture/DisplayTopologyRefreshLifecycleController.swift`
2. `VoidDisplay/Features/Capture/Views/CaptureChoose.swift`
3. `VoidDisplay/Shared/Services/DebouncingDisplayReconfigurationMonitor.swift`

后果：

1. 同一类显示拓扑问题维护两套逻辑。
2. 监听页的恢复与去抖策略弱于共享页。

## 3. 设计原则

后续重构必须遵守下面几条：

1. 目录、权限、拓扑签名只保留一个 app 级真相源。
2. 采集配置由消费需求决定，不能写死在单一场景。
3. 预览链路必须允许丢帧，优先保留最新帧。
4. 共享状态必须事件驱动，避免 UI 自行轮询补状态。
5. 监听与共享可以共用底层采集，但上层读模型要继续隔离。
6. 每轮结构调整都要补联合场景测试，不能只测单一模块。
7. 自动化测试必须非交互，不能触发屏幕录制授权弹窗。
8. 关键路径要同时定义观测指标、验收门槛和回退条件。
9. 原始 display catalog snapshot 只表达权限、拓扑和显示器列表，不能承载页面 gating。
10. 性能型重配与光标显隐这类正确性配置要分层处理。
11. 共享统计必须明确口径，至少区分 signaling 连接数与稳定收流数。

## 4. 分阶段执行方案

### 阶段 1：收敛屏幕目录、权限、拓扑状态

新增 app 级 `ScreenCaptureCatalogService`，内部拆成 `CatalogStore` 与 `CatalogRefreshCoordinator`，统一管理：

1. 权限状态
2. `SCDisplay` 列表
3. 最近一次加载错误
4. 拓扑签名
5. in-flight load task
6. 刷新去抖与取消

执行约束：

1. service 使用 `actor` 串行化刷新请求。
2. 刷新入口只接受明确意图，例如 `permissionChanged`、`topologyChanged`、`serviceBecameRunning`、`userForcedRefresh`。
3. 主去重键只包含权限状态、当前拓扑签名和是否为强制刷新。
4. 只有当前 request 才能提交 display snapshot 与 load error，过期结果直接丢弃。
5. 新意图覆盖旧意图时取消旧 task；权限丢失时允许主动清空 snapshot；服务停止只取消共享页相关 refresh，不清空全局 snapshot。
6. `refresh intent` 只用于优先级、取消策略和日志，不作为是否复用 snapshot 的判定条件。
7. 每个 refresh intent 都必须产出一个结果事件，结果类型至少区分 `reloadedSnapshot`、`reusedSnapshot`、`clearedSnapshot`、`failed`。

调整方向：

1. `CaptureChooseViewModel` 改为订阅 store，并提交监听页自己的 refresh intent。
2. `ShareViewModel` 改为订阅 store，并只在服务可用时提交共享页自己的 refresh intent。
3. 共享页的 `serviceStopped` 等页面状态继续由共享页派生状态决定，不通过清空全局 catalog 实现。
4. 页面私有 lifecycle 只保留触发时机与 fallback 策略，不再持有独立 loader 状态。
5. 让监听页和共享页共享同一份原始 display snapshot。
6. 共享页在订阅建立、`serviceBecameRunning`、`reusedSnapshot` 命中时，都必须用当前 snapshot 重放一次 `registerShareableDisplays`。

预期收益：

1. 减少重复 `SCShareableContent` 调用。
2. 消除权限状态分叉。
3. 简化目录刷新后的状态收敛。

### 阶段 2：建立采集 profile 策略层

在 `DisplayCaptureRegistry` 之上增加 profile 决策，至少区分：

1. `previewOnly`
2. `shareOnly`
3. `mixed`

profile 输入建议包含：

1. preview sink 数量
2. 当前 display 是否处于 `sharingActive`，定义为该 display 已建立 sharing session 且 session 尚未停止
3. 显示器分辨率与刷新率上限
4. 上一次稳定 profile 与最近一次切换时间

profile 输出建议包含：

1. 采集尺寸
2. 采集帧率
3. `queueDepth`
4. 本次是否允许调用 `updateConfiguration`

建议策略：

1. `previewOnly` 优先本地流畅度与低切换成本。
2. `shareOnly` 优先编码稳定性和带宽可控。
3. `mixed` 在可接受清晰度下限制帧率，避免高刷浪费。

约束：

1. profile 只允许在 `previewOnly`、`shareOnly`、`mixed` 三个稳定状态之间切换。
2. 切换规则必须同时定义进入阈值、退出阈值、最小驻留时间。
3. profile 型 `updateConfiguration` 最大重配频率限制为每 `5s` 不超过 `1` 次。
4. 光标显隐走独立的 cursor override 通道，允许即时生效，不受 profile 驻留时间与重配频率门槛限制。
5. `streamingPeers` 只作为观测指标，当前阶段不直接驱动 `updateConfiguration`。
6. `signalingConnections`、协商失败、重连抖动都不能单独驱动 profile 切换。

### 阶段 3：给预览链路加背压与观测

优化方向：

1. `DisplaySampleFanout` 为每个 sink 提供有界邮箱。
2. 默认容量建议 `1` 或 `2`。
3. 新帧到达时覆盖旧帧，保留最新帧。
4. `ZeroCopyPreviewRenderer` 改为“最新帧槽位 + 单 drain loop”模型。
5. 主线程只负责 dequeue 与 layer enqueue，不再为每一帧创建无界 `Task`。

新增指标：

1. 收到帧数
2. 渲染帧数
3. 丢弃帧数
4. 最近渲染延迟
5. renderer 待处理帧槽位占用情况

预期收益：

1. 高刷输入下不再无限堆积主线程任务。
2. 慢预览 sink 不再拖垮整体链路。

### 阶段 4：共享状态改为事件驱动

优化方向：

1. `WebServer` 只在 websocket upgrade 成功且连接通过容量校验后分配 `clientID`，并向服务层发出带 `target` 与 `clientID` 的 signaling 生命周期事件。
2. `WebRTCSessionHub` 只消费 `WebServer` 分配的 `clientID`，并向服务层发出同一 `clientID` 的 peer phase 事件。
3. `SharingService` 或 `WebServiceController` 暴露统一的共享统计快照订阅面。
4. 快照至少包含 `signalingConnections`、`streamingPeers`、`signalingConnectionsByTarget`、`streamingPeersByTarget` 与时间戳。
5. 原始事件载荷至少包含 `target`、`clientID`、`peerPhase`、事件来源、时间戳。
6. peer phase 至少定义 `signalingConnected`、`offerReceived`、`peerConnected`、`peerDisconnected`、`peerFailed`、`closed`。
7. 服务层必须维护以 `clientID` 为键的聚合状态，字段至少包含 `target`、`hasSignalingConnection`、`peerPhase`、最近更新时间戳。
8. `signalingConnections` 与 `streamingPeers` 只能由聚合状态投影得到，不能直接按原始事件做加减。
9. `streamingPeers` 只统计处于 `peerConnected` 的 client；进入 `peerDisconnected`、`peerFailed`、`closed` 时必须从聚合状态移出或降级。
10. 同一 websocket 断开后再次连接时必须分配新的 `clientID`；重复断连、失败、关闭事件必须按 `clientID` 幂等处理。
11. 被 `too_many_viewers` 或其他准入校验拒绝的连接不得分配 `clientID`，也不得计入 `signalingConnections`、`streamingPeers` 或其 per-target 计数；如需观测，单列 rejected attempt 指标。
12. 订阅建立时立即返回当前聚合快照，随后再接收增量事件。
13. `WebRTCSessionHub` 与 `WebServer` 只向服务层提供原始事件，不直接作为 UI 真相源。
14. `SharingController` 直接订阅服务快照；状态面板使用全局 `streamingPeers`，每个 display 行使用 `streamingPeersByTarget[target]`，诊断视图按需读取 `signalingConnections` 与 `signalingConnectionsByTarget`。
15. 去掉 `ShareView` 的每秒轮询定时器。

预期收益：

1. UI 状态更新更及时。
2. 共享统计口径更清楚，UI 可以区分信令连接与稳定收流。
3. 界面刷新频率下降。

### 阶段 5：补齐浏览器端 WebRTC 配置

优化方向：

1. 用同一份 bootstrap 配置同时驱动服务端与网页端的 ICE server。
2. 网页端缺少该字段时默认回退到空数组，保持当前 host candidate 行为。
3. 当前阶段只处理可配置 ICE/TURN；公网入口、TLS、认证另开子计划。
4. 明确 `stopped`、`error`、`disconnected`、`failed` 的终态和重连边界。
5. 保持现有 signaling message type，不在本轮引入协议版本分叉。

可选增强：

1. 页面展示连接状态、分辨率、`signalingConnections` / `streamingPeers` 状态。
2. 页面区分“服务已停止”和“网络暂时断开”。

### 阶段 6：统一拓扑监听机制并补联合压测

优化方向：

1. 监听页复用共享页的拓扑监听与回退策略。
2. 统一拓扑变化后的执行顺序：
   1. catalog 刷新
   2. sharing registration 更新
   3. 已失效 session 收敛
   4. UI 读模型刷新

补测重点：

1. 监听已开，再开启共享。
2. 共享中增加多个 `streamingPeers`。
3. 拓扑变化时 registry 仍保持一致。
4. 服务重启后目录、sharing registration 与页面派生状态正确恢复，先前活跃 sharing session 保持停止态，不自动恢复。

## 5. 推荐实施顺序

推荐顺序如下：

1. `ScreenCaptureCatalogService`
2. 采集 profile 策略层
3. 预览背压
4. 共享状态事件化
5. ICE 与网页端策略
6. 联合压测与观测

原因：

1. 状态收敛是后续所有优化的基础。
2. 采集规格决策和预览背压直接决定性能上限。
3. 事件化与网页端调整建立在较稳定的服务层语义之上。
4. 量化验收要建立在可观测的稳定实现之上。

## 6. 风险评估

### 6.1 结构风险

1. catalog service 收敛后，页面级测试会有一批需要改写。
2. 采集 profile 动态切换会引入黑帧或短时抖动风险。
3. 共享状态事件化后，部分 UI 依赖的轮询时序会发生变化。
4. 如果把页面策略全部吞进全局 service，复杂度可能继续上升。

### 6.2 实现风险

1. `SCStream.updateConfiguration` 频繁调用可能带来额外不稳定性。
2. preview sink 丢帧策略若设计不当，可能出现“窗口卡住但后台仍在刷新”的假象。
3. ICE 配置下发涉及网页协议面，需防止旧页面行为退化。
4. catalog 刷新并发语义若定义不清，可能出现过期结果覆盖新结果。

## 7. 验证矩阵

### 7.1 单元测试

新增或补强以下测试：

1. catalog service 的去重、取消、过期结果丢弃测试
2. 服务停止不会清空全局 catalog snapshot，且共享页仍能进入 `serviceStopped` 派生状态测试
3. 监听页与共享页共享 snapshot 的状态收敛测试
4. `reusedSnapshot` 结果事件会触发共享注册重放测试
5. profile 状态机测试，覆盖进入阈值、退出阈值、最小驻留时间、最大重配频率
6. `streamingPeers` 突发变化不会直接触发配置抖动测试
7. signaling 已连通但协商失败、`streamingPeers = 0` 时不切换 profile 测试
8. cursor override 不受 profile 节流限制且仍能即时生效测试
9. preview 背压与 renderer 单消费者测试
10. 共享统计订阅“先给当前快照，再给增量事件”测试
11. 共享统计快照同时包含全局与 per-target 两组计数测试
12. 同一 target 断开后重连会生成新的 `clientID`，重复断连事件仍保持幂等测试
13. 超出 viewer 上限的连接会被拒绝，且不会生成 `clientID` 或进入共享统计快照测试
14. sharing 原始事件载荷包含 `target`、`clientID`、`peerPhase` 测试
15. ICE bootstrap 配置存在与缺失两种路径测试

### 7.2 集成测试

重点补以下组合场景：

1. 监听窗口已开，再开启共享
2. 共享中连接多个 `streamingPeers`
3. 共享中发生显示拓扑变化
4. 停止共享、停止服务、重新启动服务
5. 监听与共享共用同一 display catalog
6. 自动化测试必须使用测试权限 provider，执行期间不得触发系统屏幕录制授权弹窗
7. 两个 target 同时共享时，`streamingPeersByTarget` 与 `signalingConnectionsByTarget` 不串扰
8. 网页端收到 `stopped` 后进入终态且不再重连
9. 网页端遇到 `disconnected` 或 `failed` 时进入退避重连
10. 网页端收到 `error` 时 overlay 与连接清理行为符合文档约束
11. viewer 超限时连接请求被拒绝，`signalingConnections` 不增加

### 7.3 基线采样

只在固定基准机上记录当前基线，再做优化后对比：

环境约束：

1. 固定一台代表机型，记录 CPU 型号、内存、macOS 版本、显示器规格。
2. 使用 `Release` 构建与同一套网络环境。
3. 每个场景预热 `10s` 后再采样 `60s`。
4. 采样工具、日志路径与统计口径在实施前固定，后续对比沿用同一协议。

采样场景：

1. `previewOnly`，单预览窗口
2. `shareOnly`，单分享目标与单 `streamingPeer`
3. `mixed`，单预览窗口与两个 `streamingPeers`

记录项：

1. 进程 CPU 中位数
2. `SCShareableContent` 加载次数
3. `profileReconfigurationCount`
4. `cursorOverrideReconfigurationCount`
5. preview 渲染延迟 `p95`
6. preview 丢帧率

### 7.4 验收门槛

固定基准机上的通过条件建议写成硬门槛：

1. 在权限状态与拓扑签名均未变化、且没有 `userForcedRefresh` 的前提下，`SCShareableContent` 加载次数不超过 `1` 次。
2. 稳定状态下 `profileReconfigurationCount` 为 `0`；任意 `5s` 窗口内不超过 `1` 次。
3. `streamingPeers` 在 `10s` 内从 `0 -> 3 -> 0` 波动时，`profileReconfigurationCount` 不超过 `1` 次。
4. `previewOnly` 场景 preview 渲染延迟 `p95 <= 120ms`，`mixed` 场景 `p95 <= 180ms`。
5. `previewOnly` 场景丢帧率不超过 `10%`，`mixed` 场景不超过 `20%`。
6. `mixed` 场景进程 CPU 中位数不得高于基线 `5%`，目标下降 `10%`。
7. `cursorOverrideReconfigurationCount` 单独记录，不计入 profile 频控门槛。

CI 与常规本地验证只检查稳定不变量：

1. 去重、取消、过期结果丢弃语义正确。
2. `profileReconfigurationCount` 频率限制与 `cursorOverrideReconfigurationCount` 例外规则正确。
3. 共享统计快照包含 signaling 与 streaming 的全局计数和 per-target 计数。
4. 自动化测试全程不触发屏幕录制授权弹窗。

### 7.5 运行时观测与回退

建议新增日志或指标：

1. display catalog 加载次数
2. catalog 复用次数
3. `profileReconfigurationCount`
4. `cursorOverrideReconfigurationCount`
5. profile 切换次数
6. preview 丢帧数
7. 当前 `streamingPeers`
8. 当前 `signalingConnections`
9. 当前 session 采集规格

回退条件：

1. `previewOnly` 或 `mixed` 连续 `3` 个观测窗口超出延迟门槛时，自动降到更保守的 fps 档位。
2. 连续 `3` 个观测窗口超出丢帧率门槛时，记录告警并降级 profile。
3. 若 CPU 无法满足门槛，保留观测日志并暂停默认启用更激进的 profile 规则。

## 8. 建议的交付拆分

为了控制回归范围，建议拆成三批提交：

1. 状态收敛层
   - `ScreenCaptureCatalogService`
   - `CatalogStore` / `CatalogRefreshCoordinator`
   - 监听页与共享页目录状态统一
2. 采集与预览性能层
   - profile 状态机
   - preview 背压、renderer drain loop 与量化门槛
3. 共享协议与联合验证层
   - 快照驱动的共享状态传播
   - ICE bootstrap 配置下发与兼容
   - 联合测试、权限隔离与验收补齐

## 9. 当前结论

如果只选最值得优先落地的三项，建议先做：

1. `ScreenCaptureCatalogService`
2. 采集 profile 状态机
3. preview 背压与 renderer 单消费者模型

原因很直接：

1. 这三项决定后续重构是否能在更低复杂度下推进。
2. 它们能同时改善重复加载、资源浪费和界面稳定性。
3. 它们对监听与共享两条链路都会立刻产生收益。
4. 它们也是后续量化验收与回退策略的基础。
