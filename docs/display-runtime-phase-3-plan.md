# DisplayRuntime Phase 3: Virtual Display Transactions

状态：已完成历史记录
依据：[产品定位与架构重构前置结论](./product-positioning.md)、[DisplayRuntime 重构执行计划](./display-runtime-refactor-plan.md)、[DisplayRuntime Phase 1 执行计划](./display-runtime-phase-1-plan.md)、[DisplayRuntime Phase 2 执行记录](./display-runtime-phase-2-plan.md)
范围：在 `VoidDisplayRuntime` 中规划 Virtual Display Transactions。Phase 3a 只接管 rebuild transaction。
归档说明：Phase 3 已完成。本文保留为 Phase 3a 重建事务的历史计划，不再作为当前待办清单。
导航：当前阅读顺序见 [DisplayRuntime 文档索引](./display-runtime-index.md)。

## Summary

Phase 3 的第一步是把虚拟屏 rebuild 建模为 runtime transaction，由 `DisplayRuntime` 统一负责 rebuild 前快照、依附 session 暂停、调用现有 virtual display rebuild、等待 catalog 拓扑稳定、按必要性恢复 session、写 transaction trace。

Phase 3a 不接管这些命令：

- create
- edit
- delete
- enable
- disable
- restore

`EditVirtualDisplayConfigView` 的 Save and Rebuild 是一个组合动作。Phase 3a 只接管其中的 rebuild。`updateConfig` 仍保持现有行为：先持久化配置，再触发 rebuild。配置持久化回滚和 rebuild 合并事务属于 Phase 3b 的 edit transaction 范围。

Phase 3a 也不改这些路径：

- UI 信息架构
- capture frame pipeline
- LAN Web View 路由、安全模型、鉴权模型
- WebRTC signaling / publisher session
- ScreenCaptureKit 帧采集和 frame fanout
- `DisplayRebuildCoordinator` 内部的虚拟屏 teardown、recreate、topology repair 算法

`VoidDisplayRuntime` 继续保持控制平面边界：只通过 `Sendable` DTO 和 command ports 与 App adapters 交互，不导入 SwiftUI、AppKit、Observation、ScreenCaptureKit、VoidDisplayApp、VoidDisplayCapture、VoidDisplaySharing、VoidDisplayVirtualDisplay、VoidDisplayDesignSystem，不持有 `SCStream`、WebRTC session、virtual display driver handle、`CMSampleBuffer`、`CVPixelBuffer`。

## Current Rebuild Entry And Dependency Flow

### Entry Points

现有 rebuild 入口有两条，最后都进入 `VirtualDisplayController.startRebuildFromSavedConfig(configId:)`，Phase 3a 实现时需要显式保留 source：

- `Sources/VoidDisplayVirtualDisplay/Views/VirtualDisplayView.swift`：虚拟屏行上的 retry rebuild action 调用 `virtualDisplay.retryRebuild(configId:)`，再调用 `startRebuildFromSavedConfig`。Phase 3a source 应映射为 row retry。
- `Sources/VoidDisplayVirtualDisplay/Views/EditVirtualDisplayConfigView.swift`：Save and Rebuild 先 `updateConfig`，再调用 `virtualDisplay.startRebuildFromSavedConfig(configId:)`。Phase 3a source 应映射为 edit save-and-rebuild。

`VirtualDisplayController.startRebuildFromSavedConfig` 当前负责四件事，Phase 3a 必须把前两项迁给 runtime：

1. 拒绝同一 config 的并发 rebuild。
2. 找到 config 对应的 runtime display id。
3. 在 rebuild 前停止依附 sharing 和 monitoring。
4. 创建 `Task` 调用 `rebuildVirtualDisplay(configId:)`，维护 rebuilding、failure、recent success 这些 presentation state。

Phase 3a 后的职责必须改为：

- `VirtualDisplayController` 只接收 UI request source、维护 row presentation、等待 runtime executor terminal result。
- `VirtualDisplayController` 不再短路 missing config。
- `VirtualDisplayController` 不再用 `rebuildingConfigIds` 吞掉 duplicate rebuild request。duplicate request 必须进入 runtime，由 runtime queue/coalescing 写 transaction evidence。
- `DisplayRuntime` 是 rebuild transaction 的唯一事实源：config missing、duplicate request、queue/coalescing、affected scope、trace 都在 runtime 发生。

实际 rebuild 调用链：

```text
VirtualDisplayView / EditVirtualDisplayConfigView
  -> VirtualDisplayController.startRebuildFromSavedConfig
  -> VirtualDisplayController.rebuildVirtualDisplay
  -> VirtualDisplayFacade.rebuildVirtualDisplay
  -> VirtualDisplayOrchestrator.rebuildVirtualDisplay
  -> DisplayRebuildCoordinator.rebuildVirtualDisplay
```

`DisplayRebuildCoordinator` 继续负责现有底层行为：

- 读取 `VirtualDisplayConfigManager`、`VirtualDisplayRuntimeTracker` 和当前 `DisplayTopologySnapshot`。
- 判断目标是否为 managed main display。
- 单屏 rebuild 时清理目标 runtime tracking，等待 termination / offline settlement，重新创建 runtime display。
- 多 managed display 且目标为 main 时执行 coordinated fleet rebuild。
- 调用 `ensureHealthyTopologyAfterEnable` 等待稳定拓扑，必要时通过 `DisplayTopologyRepairing` 修复镜像折叠、重叠、主显示器漂移等问题。

### Current Stop Flow

当前依附 session 停止流在 App 装配层注入：

```text
AppBootstrap.makeEnvironment
  -> VirtualDisplayController(stopDependentStreamsBeforeRebuild:)
  -> CaptureController.stopDependentStreamsBeforeRebuild(displayID:sharingController:)
```

`VirtualDisplayController.startRebuildFromSavedConfig` 的停止规则：

- 如果 config 有 runtime display id，先停止该 display id 上的依附流。
- 如果该 runtime display id 是 `CGMainDisplayID()`，且当前有至少两个 managed display，则停止所有 managed display id 上的依附流，匹配 coordinated fleet rebuild 的实际风险面。

`CaptureController.stopDependentStreamsBeforeRebuild` 的具体行为：

```text
if sharingController.isSharing(displayID) {
  sharingController.stopSharing(displayID)
}
removeMonitoringSessions(displayID)
```

也就是：

- sharing：只在该 display 正在 sharing 时调用 `SharingController.stopSharing(displayID:)`。
- monitoring：无条件调用 `CaptureController.removeMonitoringSessions(displayID:)`，移除该 display 的所有本机监控 session。

### Current Resume Flow

当前没有 rebuild 后的 resume 逻辑。

停止 sharing 后，LAN viewer 会断开。停止 monitoring 后，本机 monitor session 被移除。现有 catalog convergence 只会在权限或拓扑刷新后注册可分享 display、停止 stale sharing、移除 stale monitoring，它不保存 rebuild 前 consumer 意图，也不自动重新开始 sharing 或 monitoring。

这意味着 Phase 3a 的核心增量应放在 rebuild 外围：补上可观测、可串行化、可恢复的 transaction envelope，底层虚拟屏 rebuild 算法保持现有实现。

## Phase 3a Target Shape

Phase 3a 新增一个 runtime transaction coordinator，只接管 rebuild 请求：

```text
DisplayRuntime
  DisplayTransactionCoordinator
    VirtualDisplayRebuildTransaction
```

推荐实施策略：

- `VirtualDisplayController.startRebuildFromSavedConfig` 暂时保留为 UI presentation adapter：它继续维护 rebuilding、failure、recent success 状态，但必须把 missing config 和 duplicate request 交给 runtime executor，不得在 controller 层吞掉。
- `VoidDisplayVirtualDisplay` 不依赖 `VoidDisplayRuntime`。App 层在 `AppBootstrap` 创建 `DisplayRuntime` 后，把 runtime-backed rebuild executor 配置给 `VirtualDisplayController`。
- `DisplayRuntime` 通过 `DisplayRuntimeVirtualDisplayCommanding` 调用现有 `VirtualDisplayController.rebuildVirtualDisplay(configId:)`，从而复用 `VirtualDisplayOrchestrator` 和 `DisplayRebuildCoordinator`。
- 原 `stopDependentStreamsBeforeRebuild` 闭包在 3a 中删除或停止使用，依附 session 的暂停和恢复统一进入 runtime transaction。
- `DisplayRuntimeVirtualDisplayAdapter` 从只读 provider 扩展为 provider + commander。它仍位于 `VoidDisplayApp/Composition`，负责调用 app controller，不把 app controller 类型暴露给 runtime。

这样做的原因很硬：底层 virtual display rebuild 已经有复杂的 teardown、fleet rebuild、topology repair、retry 和 rollback 语义。Phase 3a 的收敛点应放在 rebuild 外围 transaction，不在同一轮重写 driver 生命周期。

### Required App Wiring

Phase 3a 必须避免让 `VoidDisplayVirtualDisplay` 反向依赖 `VoidDisplayRuntime`。推荐 wiring：

```text
VirtualDisplayController
  owns rebuild presentation state
  calls target-local rebuild executor closure with target-local source enum

AppBootstrap
  creates VirtualDisplayController
  creates DisplayRuntime with DisplayRuntimeVirtualDisplayAdapter(controller:)
  configures VirtualDisplayController rebuild executor to call DisplayRuntime.rebuildVirtualDisplay
```

约束：

- `VoidDisplayVirtualDisplay` 只能知道 `@MainActor (UUID, VirtualDisplayRebuildRequestSource) async throws -> Void` 形状的 executor，不能知道 runtime DTO、runtime transaction id 或 `DisplayRuntime` 类型。
- `VirtualDisplayRebuildRequestSource` 定义在 `VoidDisplayVirtualDisplay` target，例如 `rowRetry`、`editSaveAndRebuild`、`unknown`。App adapter 负责把它映射到 `DisplayRuntimeTransactionSource`。
- `DisplayRuntimeVirtualDisplayAdapter` 调用 `VirtualDisplayController.rebuildVirtualDisplay(configId:)`，不能调用 `startRebuildFromSavedConfig`，避免递归进入 UI wrapper。
- previews 和 tests 必须显式注入 fake executor 或 direct facade executor；正式 App 环境必须注入 runtime executor。
- 如果 executor 缺失，controller 应把 rebuild 标记为失败并记录可观测事件；正式 App bootstrap tests 必须证明 executor 已配置。

## New Runtime DTOs

新增 DTO 均放在 `Sources/VoidDisplayRuntime/Models`，全部为 `nonisolated`、`Codable`、`Equatable`、`Sendable` 值类型。命名可以在实现时微调，但语义必须保留。

### Transaction Identity And State

```text
DisplayRuntimeTransactionID
  rawValue: UUID

DisplayRuntimeTransactionKind
  virtualDisplayRebuild

DisplayRuntimeTransactionSource
  virtualDisplayRowRetry
  editSaveAndRebuild
  diagnostics
  unknown

DisplayRuntimeTransactionPhase
  queued
  preparing
  quiescingSessions
  executingVirtualDisplayCommand
  waitingForTopology
  restoringSessions
  completed
  failed
  cancelled

DisplayRuntimeTransactionStatus
  active
  completed
  completedWithRecoveryFailures
  failed
  cancelled

DisplayRuntimeVirtualDisplayRebuildTransactionResult
  transactionID
  status
  virtualDisplayCommandSucceeded
  hasSessionRecoveryFailures
```

Phase 3a 只需要单一 transaction 状态机，不增加多层 guard、parallel lock、legacy queue。`DisplayRuntime` 当前运行在 `@MainActor`，Phase 3a 可以沿用该执行边界；如果后续改为 actor，必须先保留同一串行语义。

### Rebuild Request And Scope

```text
DisplayRuntimeVirtualDisplayRebuildRequest
  transactionID
  configID
  source

DisplayRuntimeAffectedSurface
  identity
  configID
  preDisplayID
  serialNumber
  reason

DisplayRuntimeAffectedSurfaceReason
  requestedConfig
  managedMainFleetPeer
```

影响范围的计算规则：

- 优先从 pre snapshot 找到 `DisplaySurfaceIdentity.managedVirtualDisplay(configID:)`。
- Pre snapshot 前必须先通过 catalog command 做一次 transaction-scoped topology refresh。affected scope 必须基于刷新后的 catalog DTO 和 virtual display DTO，而不是 stale UI state。
- 如果目标 config 对应 display id 在 catalog topology 中标记为 main display，且 pre snapshot 中 managed display 数量大于等于 2，affected surfaces 包含所有 running managed displays。
- 如果 target main 状态无法从 catalog DTO 证明，但目标 config 正在运行且 managed display 数量大于等于 2，affected surfaces 应保守包含所有 running managed displays；这是单一 scope 决策，不增加第二套 rebuild 防御。
- 如果 screen capture permission 不可用，catalog DTO 可能无法证明可见显示和 main display。此时不能阻塞 virtual display rebuild；runtime 只根据 virtual display DTO 推导 affected surfaces，并把 session restore 标记为需要 post 阶段重新解析。
- 其他情况只包含目标 config 对应 surface。
- 找不到 config 时，transaction 直接失败并写 trace，不调用 quiesce 和 rebuild。
- 找到 config 但没有 pre display id 时，transaction 不做 quiesce，仍调用现有 rebuild command。现有 `DisplayRebuildCoordinator` 支持非 running config 的 rebuild 路径，runtime 不能把 display id 缺失误判为失败。

### Session Pause And Restore Intent

```text
DisplayRuntimeSessionPauseIntent
  surfaceIdentity
  displayID
  pauseSharing
  pauseMonitoring

DisplayRuntimeSessionRestoreIntent
  surfaceIdentity
  previousDisplayID
  resolvedDisplayID
  restoreSharing
  restoreMonitoring
  monitoringCapturesCursor

DisplayRuntimeSessionRestoreResult
  kind
  status
  previousDisplayID
  resolvedDisplayID
  failureReason
```

`pauseSharing` 来自 pre snapshot 中对应 surface 的 `sharing.isActive`。
`pauseMonitoring` 来自 pre snapshot 中对应 surface 的 `capture.sessionIDs` 是否为空。
`monitoringCapturesCursor` 来自 pre snapshot 中对应 surface 的 `capture.capturesCursor`。

Phase 3a 恢复或记录的是 display-level session demand：

- sharing：如果 rebuild 前该 surface 正在 sharing，且 rebuild 后能解析到新的 visible display id，则重新 start sharing。
- monitoring：Phase 3a 默认只记录 restore intent，不实际 start monitoring。实际 monitoring restore 只能在 3a.4 明确证明有 UI consumer demand 绑定后启用。若启用，多个旧 session 也只能按 display 维度恢复一个 monitoring demand，session id 会变更。
- viewer 连接本身不恢复。viewer 可以重连到原 share route。WebRTC peer session 不在 transaction 内保存。
- monitor window 不在 3a 中强制重开。没有 consumer demand 绑定时，runtime 不得制造后台 monitoring session。后续 UI lease 阶段再处理 window/session identity 连续性。

### Topology Stability DTO

```text
DisplayRuntimeTopologyStabilitySample
  topologySignature
  visibleDisplayIDs

DisplayRuntimeTopologyStabilityResult
  status
  sampleCount
  failureReason

DisplayRuntimeTopologyStabilityStatus
  stable
  unprovableDueToPermission
  failed
  timedOut
```

runtime 的拓扑等待只比较 catalog DTO：

- `DisplayRuntimeCatalogSnapshot.topologySignature`
- `DisplayRuntimeCatalogSnapshot.loadedDisplays`
- `DisplayRuntimeVirtualDisplaySnapshot.managedDisplays`

虚拟屏底层拓扑健康和 repair 仍由 `DisplayRebuildCoordinator.ensureHealthyTopologyAfterEnable` 负责。runtime 不复制 `TopologyHealthEvaluator` 的显示修复判断。

拓扑稳定结果语义：

- `stable`：catalog refresh 成功，permission 可用，topology signature 达到稳定样本数，affected managed surfaces 能解析到 visible display ids。
- `unprovableDueToPermission`：ScreenCapture permission 不可用或 catalog 因权限不可用被清空。此状态不等待 visible display id 证明，不进入 topology timeout。
- `failed`：catalog refresh 明确失败，且失败不是 permission unavailable 降级。
- `timedOut`：permission 可用，但在 bounded wait 内无法获得稳定 DTO 或无法解析 required visible display ids。

### Transaction Trace

```text
DisplayRuntimeTransactionTrace
  id
  kind
  source
  status
  phases
  affectedSurfaces
  preSnapshotEvidence
  postSnapshotEvidence
  pauseIntents
  restoreIntents
  restoreResults
  failure
  compensation

DisplayRuntimeTransactionSnapshotEvidence
  surfaces
  catalogTopologySignature
  visibleDisplayIDs
  captureSessions
  sharingDisplayIDs
  managedVirtualDisplays
  runningConfigIDs

DisplayRuntimeTransactionFailure
  phase
  reason
  underlyingDomain
  underlyingCode
  recoverability

DisplayRuntimeCompensationResult
  status
  restoredSharingCount
  restoredMonitoringCount
  failedRestoreCount
```

Trace 存储策略：

- `DisplayRuntimeSnapshot` 增加 transaction section，schema version 升到 2。
- 保留 active transaction 和最近 N 条 completed traces，建议 N=20。
- `DisplayRuntimeObservabilityRecording` 增加 `displayRuntimeTransactionChanged` refresh reason。
- `ObservabilityDomain` 增加 `displayRuntime = "display_runtime"`，transaction event 使用 display runtime subsystem，不继续映射为 `screen_catalog`。
- 关键 phase 变化写 Observability event，默认脱敏，不写 LAN IP、完整 URL、桌面内容、窗口标题、用户路径、raw viewer client id。
- Trace 不能直接嵌套完整 `DisplayRuntimeSnapshot`，否则 schema v2 的 transaction section 会递归包含历史 transaction。Trace 只保存 `DisplayRuntimeTransactionSnapshotEvidence`，或保存明确剥离 transaction section 的 snapshot core。

## New Ports

### Virtual Display Command Port

```text
@MainActor
package protocol DisplayRuntimeVirtualDisplayCommanding {
    func rebuildVirtualDisplay(configID: UUID) async throws -> DisplayRuntimeVirtualDisplayRebuildCommandResult
}
```

`DisplayRuntimeVirtualDisplayRebuildCommandResult` 最少包含：

- `configID`
- `preDisplayID`
- `postDisplayID`
- `runningConfigIDsAfterCommand`
- `managedDisplaysAfterCommand`

`DisplayRuntime.rebuildVirtualDisplay(configID:source:)` 对 UI executor 的结果语义：

- 只有 virtual display command 自身失败时才 throw，让 `VirtualDisplayController` 标记 rebuild failure。
- 如果 virtual display command 成功，但 sharing 或 monitoring restore 失败，runtime 返回 `completedWithRecoveryFailures`，不 throw。Controller 仍可显示 recent apply success；恢复失败通过 transaction trace 和 Observability 暴露。
- 如果 transaction 在调用 virtual display command 前被取消，可以 throw `CancellationError`。
- 如果 transaction 在 command 后进入 partial recovery failure，不把它折叠成 UI rebuild failure。

App adapter 实现：

- 读取 command 前的 `VirtualDisplayController` snapshot。
- 调用 `VirtualDisplayController.rebuildVirtualDisplay(configId:)`，不要调用 `startRebuildFromSavedConfig`。
- command 完成后再读取 snapshot，映射为 runtime DTO。
- 如果 weak controller 已释放，command adapter 必须 throw 明确错误，例如 `adapter_unavailable`，不能静默 no-op。

### Capture Command Port Extension

3a.1 到 3a.3 只需要现有 `removeMonitoringSessions(displayID:)` 作为 quiesce 命令。下面的 restore commands 只允许在 3a.4 启用，且必须先证明有 consumer demand owner：

```text
func restoreMonitoringSession(
    _ intent: DisplayRuntimeSessionRestoreIntent
) async -> DisplayRuntimeSessionRestoreResult

func setRestoredMonitoringCursor(
    sessionID: UUID,
    capturesCursor: Bool
) async -> DisplayRuntimeSessionRestoreResult
```

App adapter 实现：

- 默认 Phase 3a path 不调用这些 restore commands，只记录 monitoring restore intent。
- 在 App 层通过 `ScreenCaptureCatalogService.store.displays` 解析 `resolvedDisplayID` 对应的 `SCDisplay`。
- 用现有 metadata 规则构造 `CaptureMonitoringDisplayMetadata`：display name、resolution text、is virtual display。
- 调用 `CaptureController.startMonitoring(display:metadata:)`。
- 如果 `startMonitoring` 返回 `.started(sessionID)` 且 intent 要求 `monitoringCapturesCursor == true`，随后调用 `CaptureController.setMonitoringSessionCapturesCursor(id:capturesCursor:)`。
- 如果 start outcome 是 `.invalidated`，restore result 必须标记为 invalidated，不能写成成功。
- 不把 `SCDisplay` 或 `CaptureMonitoringDisplayMetadata` 泄漏到 runtime target。
- 如果 weak controller 已释放，restore result 必须标记为 failed，不能静默 no-op。

现有 `removeMonitoringSessions(displayID:)` 继续作为 quiesce 命令使用。

### Sharing Command Port Extension

扩展现有 `DisplayRuntimeSharingCommanding`：

```text
func restoreSharing(
    _ intent: DisplayRuntimeSessionRestoreIntent
) async -> DisplayRuntimeSessionRestoreResult
```

App adapter 实现：

- 在 App 层通过 `ScreenCaptureCatalogService.store.displays` 解析 `resolvedDisplayID` 对应的 `SCDisplay`。
- 调用 `SharingController.beginSharing(display:)`。
- `beginSharing` 前必须已经通过 catalog convergence 更新 `registerShareableDisplays`，否则 `DisplaySharingCoordinator.startSharing` 会因为 display 未注册而失败。
- 如果 start outcome 是 `.invalidated`，restore result 必须标记为 invalidated，不能写成成功。
- 继续由 `SharingController` / `SharingService` / `DisplaySharingCoordinator` 维护 shareID、share route、WebRTC hub。
- 不新增 LAN Web View token、密码、账号或鉴权。
- 如果 weak controller 已释放，restore result 必须标记为 failed，不能静默 no-op。

现有 `stopSharing(displayID:)` 继续作为 quiesce 命令使用。

### Catalog Command Port Extension

扩展现有 catalog command 能力，不引入 ScreenCaptureKit 类型：

```text
func refreshTopologySnapshotForTransaction() async -> DisplayRuntimeCatalogRefreshResult
func convergeVisibleDisplaysForTransaction() async
```

实现规则：

- `refreshTopologySnapshotForTransaction` 可以复用 `submitRefresh(intent: .topologyChanged, ownerScope: nil)`，但不能在 pre snapshot 前运行 visible display convergence。
- `convergeVisibleDisplaysForTransaction` 复用 Phase 2 的 visible display convergence：注册 shareable displays、停止 stale sharing、移除 stale monitoring。
- Runtime 在 bounded loop 中读取 catalog snapshot，比较 DTO signature 是否稳定。

## Rebuild Transaction Flow

### Precise Flow

```text
1. enqueue rebuild request
2. refresh catalog topology for transaction scope
3. build pre snapshot evidence
4. resolve affected surfaces
5. derive pause and restore intents from pre snapshot evidence
6. mark transaction phase: quiescingSessions
7. stop sharing and monitoring for affected display ids
8. mark transaction phase: executingVirtualDisplayCommand
9. call DisplayRuntimeVirtualDisplayCommanding.rebuildVirtualDisplay
10. mark transaction phase: waitingForTopology
11. refresh catalog and wait for topology status
12. build post snapshot evidence
13. resolve new display ids for affected surfaces
14. mark transaction phase: restoringSessions
15. restore necessary sharing sessions and record monitoring restore intent
16. build final post snapshot evidence
17. write transaction trace
18. refresh observability snapshot
```

### Step Details

1. Enqueue

- Queue key is `DisplaySurfaceIdentity.managedVirtualDisplay(configID:)`.
- Same config rebuild requests are serialized.
- If a rebuild is already active for the same config, Phase 3a should coalesce duplicate requests into the active transaction and return the same transaction id or a duplicate-coalesced result.
- Different managed displays should still serialize in Phase 3a, because rebuild can escalate to fleet rebuild when the target is managed main display.

2. Pre snapshot

- Before building pre snapshot, run `refreshTopologySnapshotForTransaction`。This gives runtime a current DTO answer for main display and visible display ids without importing CoreGraphics or ScreenCaptureKit.
- Do not run visible display convergence before pre snapshot evidence is captured. Convergence can stop stale sessions and would destroy the transaction's evidence of pre-rebuild session demand.
- Call `DisplayRuntime.makeSnapshot()` before any stop command.
- Store this as `preSnapshotEvidence` in trace. Evidence must not include the transaction section of `DisplayRuntimeSnapshot`。
- Derive affected surfaces and session intents only from this immutable value.

3. Pause attached sessions

- For every affected surface with pre display id:
  - if `sharing.isActive == true`, call `sharingCommander.stopSharing(displayID:)`。
  - if `capture.sessionIDs` is non-empty or `capture.isStarting == true`, call `captureCommander.removeMonitoringSessions(displayID:)`。
- Stop order is deterministic: sort affected display ids, then for each display stop sharing before removing monitoring. This preserves the current per-display stop order and keeps tests stable.
- Do not touch capture frame fanout internals, RelaySessionHub internals, WebRTC publisher sessions, or preview sink internals.

4. Call existing rebuild

- Call `virtualDisplayCommander.rebuildVirtualDisplay(configID:)`。
- This command must invoke existing `VirtualDisplayController.rebuildVirtualDisplay(configId:)` or the facade method under it.
- It must not invoke `VirtualDisplayController.startRebuildFromSavedConfig` because that method is the UI presentation wrapper and would duplicate transaction logic.

5. Wait for topology stability

- After command returns, call catalog refresh through runtime catalog port.
- After the post-command refresh produces a stable DTO, run `convergeVisibleDisplaysForTransaction` before session restore. In practice this means shareable display registration is updated for the rebuilt display id before `restoreSharing` calls `SharingController.beginSharing(display:)`。
- Wait until topology DTO reaches `stable`, `unprovableDueToPermission`, `failed`, or `timedOut`。
- Stability criteria for Phase 3a:
  - `stable` requires topology signature unchanged between samples, affected managed surfaces resolved to visible display ids, and catalog refresh success.
  - `unprovableDueToPermission` must return immediately after permission unavailability is observed. It must not keep waiting for visible display ids that cannot be proven.
  - `failed` records catalog refresh failure unrelated to permission degradation.
  - `timedOut` records bounded wait exhaustion when permission is available but stability or display id resolution never becomes provable.
- If virtual display command succeeded and topology status is `unprovableDueToPermission`, build post evidence immediately, skip restore that requires `SCDisplay`, and mark transaction `completedWithRecoveryFailures`。
- No second topology repair in runtime. Repair remains inside `DisplayRebuildCoordinator`。

6. Restore necessary sessions

- For each restore intent:
  - Resolve `surfaceIdentity` to new `currentDisplayID` from post snapshot.
  - Restore sharing only when it was active in pre snapshot and the sharing web service is running.
  - Record monitoring restore intent when monitoring existed in pre snapshot.
  - Do not start monitoring by default. Actual monitoring restore is only allowed in 3a.4 after consumer demand proof.
  - If 3a.4 enables actual monitoring restore and pre snapshot says monitoring captured cursor, restore monitoring first, then call capture command to set the new monitoring session cursor flag. Cursor restore failure marks partial recovery; it does not require tearing down the restored monitoring session.
  - Skip restore if no visible display id exists; trace the skip as degraded.
- Restore failures do not fake active state in runtime snapshot. Trace records partial recovery.

7. Trace

- Always write a trace for success, failure, cancellation, and partial restore.
- Trace must include pre and post snapshot evidence, but default observability export must keep existing redaction rules.

## Operations Explicitly Outside The Transaction Queue

These operations do not enter `DisplayTransactionCoordinator` in Phase 3a:

- Viewer HTTP requests to `/display`, `/display/{shareID}`, `/signal`, `/signal/{shareID}`。
- WebRTC signaling, offer / answer exchange, ICE handling, publisher session frame send。
- RelaySessionHub peer connect / disconnect / stream client counting。
- Capture frame receive, encode, sample fanout, preview sink delivery。
- Monitor attach from UI to an existing monitoring session。
- Preview sink attach / detach。
- LAN Web View route registration and shareID assignment, except when sharing restore starts a display after rebuild。
- User-driven start sharing and start monitoring outside rebuild restore。

The transaction may stop or restart display-level sharing / monitoring as rebuild compensation. It never queues per-frame or per-viewer work.

## Failure And Compensation Strategy

Phase 3a must use one bounded state machine. No extra fallback layers, no duplicated rebuild retry loops, no hidden compatibility path.

### Failure Classes

Config missing:

- Fail during preparing.
- Do not stop sessions.
- Write trace with `reason: config_not_found`。

Screen capture permission unavailable:

- Do not fail the virtual display rebuild because ScreenCapture permission is unavailable.
- Pre snapshot evidence records catalog permission state.
- Quiesce can still stop known pre display ids from virtual display/capture/sharing DTOs.
- Post-command topology result becomes `unprovableDueToPermission` instead of `timedOut`。
- Session restore that requires resolving `SCDisplay` must be skipped when permission remains unavailable or catalog display lookup fails; transaction status becomes `completedWithRecoveryFailures` if the rebuild command succeeded.

Affected surface cannot resolve pre display id:

- Do not fail solely because pre display id is unavailable.
- Build affected surface with `preDisplayID = nil`。
- Skip quiesce for that surface and call the existing rebuild command.
- Write trace metadata `pre_display_id_unavailable` so diagnostics can explain why no dependent session was paused.

Affected surface cannot resolve post display id:

- If rebuild command failed, attempt restore only for surfaces that still resolve to a visible display id.
- If rebuild command succeeded but post display id cannot be resolved before topology timeout, mark transaction `completedWithRecoveryFailures`。
- Do not fake restored sharing or monitoring state.

Session quiesce command cannot prove completion:

- Current stop commands are synchronous void APIs. Treat them as best-effort command dispatch.
- Immediately refresh snapshot after quiesce.
- If session still appears active, continue rebuild only when it is the same display-level session already scheduled for removal. Record `quiesce_unconfirmed` warning in trace.
- Do not add repeated stop loops.

Virtual display rebuild throws:

- Do not reimplement virtual display retries in runtime.
- Preserve existing `DisplayRebuildCoordinator` failure semantics: `configNotFound`、`teardownTimedOut`、`topologyRepairFailed`、`topologyUnstableAfterEnable`。
- Build post-failure snapshot evidence.
- Restore only sessions whose target surface can be resolved to a visible display id after failure.
- If no safe target exists, leave session stopped and record degraded compensation.

Topology wait times out after rebuild command succeeded:

- Mark transaction `completedWithRecoveryFailures` if the virtual display command succeeded but runtime cannot prove stable catalog DTO.
- Skip session restore for unresolved surfaces.
- Do not call topology repair again from runtime.

Restore sharing or monitoring fails:

- The rebuild portion remains completed.
- Transaction status becomes `completedWithRecoveryFailures`。
- Trace includes per-session restore failure.
- Runtime snapshot must reflect actual controller state after failure, not intended state.

Cancellation or app termination:

- Mark active transaction cancelled if the task is cancelled before command starts.
- If cancellation occurs after virtual display command starts, let the command finish or fail according to existing async behavior, then write trace when possible.
- No attempt to roll back virtual display driver handles from runtime.

### Compensation Boundary

Compensation means restoring or recording pre-existing display-level session demand when a new display id can be safely resolved. It does not mean full rollback of macOS display topology or virtual display driver state.

Runtime must not promise all failures can return the system to the exact pre-rebuild state. When compensation cannot be proven, it must leave a degraded trace with enough facts for diagnostics.

## Target Boundaries

### ScreenCatalog

ScreenCatalog remains the source for visible display DTOs, permission state, and topology signature. Runtime can request refresh and compare DTO stability. Runtime cannot import `ScreenCaptureKit` or hold `SCDisplay`。

App adapters may resolve a runtime display id to `SCDisplay` inside `VoidDisplayApp` because that is the existing composition boundary.

### Capture

Capture owns:

- `SCStream`
- capture session lifecycle
- preview subscription
- frame receive
- frame fanout
- cursor capture setting

Runtime can command:

- remove monitoring sessions by display id
- restore one monitoring demand by resolved display id only in 3a.4 after consumer demand proof

Runtime cannot hold `DisplayCaptureSession`、`CMSampleBuffer`、`CVPixelBuffer`、preview sinks, or frame consumers.

### Sharing

Sharing owns:

- web service lifecycle
- shareID mapping
- `/display/{shareID}` and `/signal/{shareID}` route semantics
- WebRTC and RelaySessionHub
- viewer counting

Runtime can command:

- stop sharing by display id
- restore sharing by resolved display id
- observe route existence and viewer counts through DTO

Runtime cannot treat `DisplaySurfaceIdentity` as route identity. LAN Web View keeps current local-network-only stance. Phase 3a must not add token、password、account、auth。

### VirtualDisplay

VirtualDisplay target owns:

- config persistence
- virtual display driver handles
- runtime generation
- teardown settlement
- create runtime display with retries
- main display policy
- topology repair

Runtime can command:

- rebuild config id

Runtime cannot hold virtual display driver handles or import `VoidDisplayVirtualDisplay`。

### DisplayRuntime

DisplayRuntime owns:

- transaction state machine
- transaction queue
- pre / post snapshot capture
- affected surface derivation
- pause / restore intent derivation
- trace storage
- observability refresh

DisplayRuntime remains control plane only.

## Adapter Deletion Conditions

Phase 3a should delete or retire existing temporary rebuild bridge points as soon as behavior is covered.

`stopDependentStreamsBeforeRebuild` closure:

- Delete after `VirtualDisplayController.startRebuildFromSavedConfig` delegates rebuild execution to `DisplayRuntime` and runtime tests prove quiesce happens through `DisplayRuntimeSharingCommanding` and `DisplayRuntimeCaptureCommanding`。
- Validation: existing `VirtualDisplayControllerTests.startRebuildStopsDependentSharingAndMonitoringForRuntimeDisplay` must be rewritten to assert runtime transaction command order, not the closure.

`VirtualDisplayController` rebuild task as presentation adapter:

- Retain only during Phase 3a to avoid UI information architecture churn.
- Delete when UI can bind to runtime transaction state directly, likely after Phase 3b or the first UI wiring phase.
- Removal condition: row rebuilding/failure/recent success presentation is fully derived from runtime transaction snapshot or an explicit app presentation adapter with no command ownership.

`VirtualDisplayController` runtime executor injection:

- Retain only while `VirtualDisplayController` owns rebuild presentation state.
- It must be a pure closure or target-local protocol so `VoidDisplayVirtualDisplay` does not import `VoidDisplayRuntime`。
- Delete when rebuild buttons and edit save-and-rebuild call App/runtime actions directly through view dependencies.

`DisplayRuntimeVirtualDisplayAdapter`:

- Keep as the App composition boundary while `VoidDisplayRuntime` cannot import `VoidDisplayVirtualDisplay`。
- It is not a legacy compatibility layer if it only maps runtime command ports to app services.
- Delete only if a future pure engine target exposes Sendable service protocols that `VoidDisplayRuntime` can legally depend on without importing UI or driver handles.

Old per-target snapshot providers:

- Phase 3a can keep them for parity.
- Delete or fold them into runtime diagnostics only when Diagnostics consumes runtime transaction snapshot as the primary source and parity tests no longer need duplicate sections.

## Phase 3b Expansion Conditions

Do not expand transactions to create/edit/delete/enable/disable/restore until all Phase 3a conditions are true:

- Rebuild transaction has deterministic tests for success, failure, partial restore, topology timeout, duplicate request coalescing, and fleet rebuild scope.
- `DisplayRuntimeSnapshot` exposes active and recent transaction traces.
- App adapters prove rebuild command calls `VirtualDisplayController.rebuildVirtualDisplay(configId:)` directly and never re-enters `startRebuildFromSavedConfig`。
- `stopDependentStreamsBeforeRebuild` has been removed or made unreachable.
- Runtime target import guard passes.
- Runtime target still has no driver handle, `SCStream`、WebRTC session、sample buffer、pixel buffer。
- Sharing restore commands work through App adapters with `SCDisplay` resolution contained in App.
- Capture restore commands are enabled only in 3a.4 after consumer demand proof, with `SCDisplay` resolution contained in App.
- UI behavior remains equivalent for rebuild button, retry failure, and recent success badge.
- Local build is clean with zero compile errors and zero compile warnings.

After those are proven, Phase 3b should migrate one command family at a time:

1. enable / disable, because they already alter runtime display lifecycle and session validity.
2. edit with rebuild-required changes, because config persistence and rebuild command must become one visible transaction.
3. create / delete, because they need explicit persistence compensation semantics.
4. restore, because startup restore has different timing and observability needs.

Each expansion must define rollback or degraded-state semantics before implementation. No temporary compatibility shims without a removal condition.

## Phase 3a Execution Slices

Phase 3a 必须拆成可提交 checkpoint。每个 slice 都要独立测试、独立 build gate、独立可回滚。不要把 transaction、executor wiring、restore、catalog split、schema、observability 一次性塞进一个提交。

### 3a.1 Transaction Envelope And Quiesce

范围：

- 新增 transaction DTO、trace snapshot evidence、schema v2。
- 新增 runtime rebuild API 和 transaction queue/coalescing。
- 新增 `DisplayRuntimeVirtualDisplayCommanding`。
- App bootstrap 注入 runtime-backed rebuild executor。
- `VirtualDisplayController` 改成 presentation adapter，不再吞 missing config 或 duplicate request。
- Runtime 做 pre evidence、affected scope、quiesce、调用 existing rebuild command、post evidence、trace。
- 不做 post topology wait。
- 不做 sharing restore。
- 不做 monitoring restore。

验收：

- missing config 由 runtime 写 failed trace。
- duplicate request 进入 runtime 并写 coalesced/serialized evidence。
- quiesce 顺序和现有 stop 行为一致。
- controller rebuilding presentation 等 runtime terminal。
- `VoidDisplayRuntime` 和 `VoidDisplayVirtualDisplay` import guards 通过。

验证：

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter VirtualDisplayControllerTests
scripts/ci/unit.sh --filter AppBootstrapTests
scripts/ci/xcode.sh --action build --configuration Debug
```

### 3a.2 Post Topology Wait And Visible Convergence

范围：

- 拆分 transaction 专用 catalog refresh DTO 与 post convergence。
- 新增 `DisplayRuntimeTopologyStabilityStatus`：`stable`、`unprovableDueToPermission`、`failed`、`timedOut`。
- post-command topology wait 只在 permission 可用时要求 affected managed surfaces resolve visible display ids。
- permission unavailable 直接进入 `unprovableDueToPermission`，不等待不可能证明的 visible id。
- post stable 后运行 visible convergence，更新 shareable display registration。

验收：

- Phase 2 普通 catalog refresh 行为不变。
- permission unavailable 下 rebuild command 成功后 transaction 为 `completedWithRecoveryFailures`，restore skipped/degraded。
- stable topology 下 post convergence 在 restore 之前发生。

验证：

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeCatalogControlTests
scripts/ci/unit.sh --filter ScreenCatalogOrchestratorTests
scripts/ci/xcode.sh --action build --configuration Debug
```

### 3a.3 Sharing Restore

范围：

- 新增 sharing restore command port。
- 只恢复 pre evidence 中 active sharing 的 display-level demand。
- 不恢复 viewer connection。
- 不改变 LAN Web View route、token、password、account、auth。
- restore 前必须已完成 shareable display registration convergence。

验收：

- sharing restore success、invalidated、catalog miss、permission unavailable 都有 trace。
- restore failure 不让 controller 显示 rebuild failure。
- WebRTC peer/session 不进入 transaction queue。

验证：

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter SharingControllerTests
scripts/ci/unit.sh --filter SharingServiceTests
scripts/ci/xcode.sh --action build --configuration Debug
```

### 3a.4 Monitoring Restore Decision

范围：

- 默认只记录 monitoring restore intent 和 degraded/skipped evidence。
- 不默认调用 `CaptureController.startMonitoring`，避免创建没有 UI consumer 的后台 capture session。
- 只有在实现方同时引入可证明的 consumer demand 绑定时，才允许实际 monitoring restore。
- 如果 3a.4 决定实际 restore monitoring，必须恢复 cursor capture，并证明不会产生不可见高耗资源。

验收：

- 默认路径不会创建无窗口、无 preview sink、无 consumer lease 的 capture session。
- monitoring intent 会进入 trace，便于 Phase 4 consumer lease 继续接管。
- 如果启用实际 restore，必须有测试证明 session 有明确 consumer owner，且最后 consumer 释放后可 draining。

验证：

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter CaptureControllerTests
scripts/ci/unit.sh --filter CaptureMonitoringLifecycleServiceTests
scripts/ci/xcode.sh --action build --configuration Debug
```

## Implementation Constraint Clarifications

这些约束是 Phase 3a 实施门槛，不是建议项。

### Catalog Split

Phase 3a 必须把 transaction 内部 catalog 操作分成两个语义：

- pre 阶段只刷新 catalog DTO，用于判断当前 display id、main display、visible display 和 topology signature。
- post 阶段在 rebuild command 完成并取得稳定 DTO 后，才运行 visible display convergence，用于注册 shareable displays、停止 stale sharing、移除 stale monitoring。

不能复用一个“刷新并立刻收敛”的 helper 贯穿 pre 和 post。pre 阶段提前 convergence 会破坏 transaction pre evidence，因为它可能先停掉原本应由 transaction 记录和恢复的 sharing / monitoring。

普通 Phase 2 catalog refresh 行为必须保持不变。拆 helper 时只能新增 transaction 专用入口或拆出内部 primitive，不得改变 `handleCatalogTopologyChanged`、`handleCatalogAppear`、`forceRefreshCatalog` 的现有收敛语义。

### UI And Runtime State

Phase 3a 会短期存在两层状态：

- `VirtualDisplayController` presentation state：row rebuilding、failure、recent success。
- `DisplayRuntime` transaction state：phase、trace、partial recovery。

Controller 的 rebuilding 状态必须等 runtime transaction 到达 terminal state 后才能结束。不能在 virtual display command 一返回就结束，否则 UI 会显示 rebuild 完成，但 runtime 还在 restore sharing / monitoring。

Controller 不能继续作为 transaction fact filter：

- missing config 不在 controller 层 return。
- duplicate rebuild request 不在 controller 层 return。
- controller 可以更新 presentation state，但必须调用 executor，让 runtime 写 config missing trace 或 duplicate coalescing trace。
- 如果 UI 不希望重复显示多个 spinner，由 controller presentation 合并显示；事实层仍以 runtime trace 为准。

结果映射必须固定：

- virtual display command 失败：controller 显示 rebuild failure。
- virtual display command 成功但 restore 失败：controller 显示 rebuild success，runtime trace 标记 `completedWithRecoveryFailures`。
- transaction pre-command cancellation：controller 不显示 success。

### Restore Semantics

Phase 3a 只恢复 display-level demand：

- sharing restore 重新 start sharing display，不恢复旧 viewer connection。
- monitoring restore 默认只记录 intent，不启动 capture。
- 如果 3a.4 选择实际 restore monitoring，必须有明确 UI consumer demand owner，且只能重新 start one monitoring demand，不恢复旧 monitor window、旧 session id、旧 preview sink。
- cursor capture 是 monitoring demand 的一部分。只有实际创建新 monitoring session 时，才在新 session 创建后恢复。

禁止为了伪装旧 session 连续性而引入 one-off shim、旧 session id adapter、window rebinding hack。Monitor window 连续性必须留给后续 consumer lease / UI wiring 阶段。

### Permission Degradation

ScreenCapture permission unavailable 不阻塞 virtual display rebuild。

它只能影响这些能力：

- catalog DTO 证明能力下降。
- App adapter 无法把 display id 解析成 `SCDisplay` 时，sharing / monitoring restore 降级。

实现必须把这类结果写入 transaction trace，不能把 permission 问题伪装成 virtual display rebuild failure。

### Fleet Scope

当 target 可能是 managed main display 且 managed display 数量大于等于 2 时，affected scope 必须保守覆盖所有 running managed displays。这个策略会扩大 stop / restore 范围，但比残留旧 display id session 更安全。

这只能作为一个 scope 决策实现。不要在 capture、sharing、virtual display 三层各自再加一套 fleet 防御。

### Command Adapter Failure

Provider adapter 可以在 controller 不可用时返回 empty snapshot。Command adapter 不允许静默 no-op。

必须显式失败的情况：

- virtual display commander 的 weak controller 已释放。
- capture restore commander 的 weak controller 已释放。
- sharing restore commander 的 weak controller 已释放。
- catalog lookup 找不到目标 `SCDisplay`。
- start outcome 是 `.invalidated`。

这些失败必须进入 transaction trace。不能写成 success，不能只打日志。

## Test Plan

### Runtime Tests

Add or extend `VoidDisplayRuntimeTests`:

- rebuild transaction success pauses sharing and monitoring before virtual display command.
- rebuild transaction writes pre snapshot evidence and post snapshot evidence.
- duplicate rebuild requests for same config coalesce or serialize without double command execution.
- different rebuild requests serialize in Phase 3a.
- target managed main display marks all running managed displays as affected.
- rebuild command failure writes failed trace and attempts only safe session restore.
- topology wait timeout records degraded transaction and skips unsafe restore.
- topology stability status returns `unprovableDueToPermission` instead of timing out when ScreenCapture permission is unavailable.
- sharing restore failure produces `completedWithRecoveryFailures` and no fake active state.
- monitoring restore intent is recorded without starting capture by default.
- actual monitoring restore, if enabled in 3a.4, requires consumer demand proof and no invisible capture session.
- partial restore failure does not throw through the UI rebuild executor when virtual display rebuild succeeded.
- virtual display command failure does throw through the UI rebuild executor and marks controller rebuild failure.
- transaction trace appears in runtime snapshot.
- transaction trace stores snapshot evidence without recursive transaction nesting.
- `DisplayRuntimeSnapshot.empty.schemaVersion` is 2.
- `DisplayRuntimeSnapshotProvider` encodes and decodes schema v2 transaction section.
- Existing schemaVersion assertions must be updated to fixed v2, not loose `>= 2` checks.
- viewer connection and frame fanout DTO changes never enqueue transactions.
- config with no pre display id still calls virtual display rebuild command and skips quiesce.
- missing config reaches runtime and writes failed trace instead of being swallowed by controller.
- duplicate rebuild request reaches runtime and writes coalescing/serialization evidence instead of being swallowed by controller.
- transaction-scoped catalog refresh runs before affected scope derivation.
- pre catalog refresh does not run visible convergence or stop pre-existing sessions.
- post catalog convergence runs before sharing restore.
- controller rebuilding presentation remains active until runtime transaction reaches terminal state.
- permission-denied catalog state allows rebuild command and degrades only restore.
- fleet scope uses one runtime-level affected-surface decision, not duplicated stop logic in capture/sharing fakes.

### App Adapter Tests

Extend `DisplayRuntimeAdapterTests`:

- virtual display command adapter calls `VirtualDisplayController.rebuildVirtualDisplay(configId:)` or facade rebuild directly.
- adapter does not call `startRebuildFromSavedConfig`。
- sharing restore resolves `SCDisplay` in App layer and calls `SharingController.beginSharing(display:)`。
- actual monitoring restore, if enabled in 3a.4, resolves `SCDisplay` in App layer and calls `CaptureController.startMonitoring(display:metadata:)`。
- restore returns failed result when display id is absent from catalog.
- restore metadata uses existing display name、resolution text、virtual display status mapping.
- actual monitoring restore, if enabled in 3a.4, reapplies cursor capture when pre snapshot had cursor capture enabled.
- default monitoring restore path records intent only and does not call `CaptureController.startMonitoring`。
- sharing restore proves shareable registration happened before `beginSharing`。
- App bootstrap configures the runtime-backed rebuild executor before UI can issue rebuild.
- `AppBootstrapTests.initRegistersRuntimeSnapshotProvider` expects runtime snapshot schema v2.
- `VoidDisplayVirtualDisplay` target does not import `VoidDisplayRuntime` after Phase 3a.
- command adapters fail explicitly when weak controller references are unavailable.
- catalog lookup miss returns restore failure and writes transaction evidence.
- `.invalidated` start outcomes are treated as restore failures, not success.

### Existing Behavior Tests To Update

Update these tests to the new ownership:

- `VirtualDisplayControllerTests.startRebuildStopsDependentSharingAndMonitoringForRuntimeDisplay`
- `VirtualDisplayControllerTests.startRebuildIgnoresConcurrentDuplicateRequests`
- `VirtualDisplayControllerTests.rebuildFailureRetryAndAppliedBadgeLifecycle`
- `CaptureControllerTests.stopDependentStreamsBeforeRebuildStopsSharingAndMonitoring`

`CaptureController.stopDependentStreamsBeforeRebuild` tests should disappear with the method. Equivalent behavior must live in runtime transaction tests and adapter tests.

### Existing Tests To Keep

Keep these as lower-layer guarantees:

- `DisplayRebuildCoordinatorTests`
- `DisplayTeardownCoordinatorTests`
- `DisplayTeardownCoordinatorOfflineWaitTests`
- `VirtualDisplayTopologyRecoveryTests`
- `VirtualDisplayRuntimeTrackerTests`
- `ScreenCatalogOrchestratorTests`
- `DisplayRuntimeCatalogControlTests`
- `ObservabilitySnapshotProviderTests`
- `AppBootstrapTests`

## Verification Commands

Per-slice targeted verification is listed in the execution slice section. Final Phase 3a verification must run targeted tests, full unit, Xcode Debug build, and warning scan.

Targeted verification:

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter VirtualDisplayControllerTests
scripts/ci/unit.sh --filter DisplayRebuildCoordinatorTests
scripts/ci/unit.sh --filter DisplayTeardownCoordinatorTests
scripts/ci/unit.sh --filter DisplayTeardownCoordinatorOfflineWaitTests
scripts/ci/unit.sh --filter ScreenCatalogOrchestratorTests
scripts/ci/unit.sh --filter ObservabilitySnapshotProviderTests
scripts/ci/unit.sh --filter AppBootstrapTests
```

Final full unit gate:

```sh
scripts/ci/unit.sh --out-dir .ai-tmp/display-runtime-phase-3/full-unit-final
```

Boundary verification:

```sh
if rg -n "import (SwiftUI|AppKit|Observation|VoidDisplayDesignSystem|VoidDisplayApp|VoidDisplayCapture|VoidDisplaySharing|VoidDisplayVirtualDisplay|ScreenCaptureKit)" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "\\b(SCStream|SCDisplay|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession|DisplayCaptureSession|VirtualDisplayRuntimeHandling)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "import VoidDisplayRuntime" Sources/VoidDisplayVirtualDisplay; then exit 1; fi
```

Build gate:

```sh
scripts/ci/xcode.sh --action build --configuration Debug
```

Warning scan:

```sh
scripts/ci/xcode.sh --action build --configuration Debug 2>&1 | tee .ai-tmp/display-runtime-phase-3/xcode-build-final.log
if rg -n "warning:" .ai-tmp/display-runtime-phase-3/xcode-build-final.log; then exit 1; fi
```

`full_regression.sh` remains optional heavier E2E/regression. It does not replace the final full unit gate:

```sh
scripts/ci/full_regression.sh --out-dir .ai-tmp/full-regression
```

## Acceptance Criteria

- Rebuild transaction is initiated through `DisplayRuntime`。
- Runtime trace includes transaction id、kind、source、affected surfaces、pre snapshot evidence、post snapshot evidence、phase list、failure、compensation result。
- Runtime trace cannot recursively include transaction history inside pre/post evidence。
- Current rebuild behavior still uses existing `DisplayRebuildCoordinator`。
- Rebuild pre-quiesce stops the same dependent display ids as today, including fleet case when the target managed display is main。
- Rebuild post-restore restarts sharing demand that existed in pre snapshot and can be safely resolved after topology stabilizes。
- Monitoring restore does not start capture by default; actual monitoring restart requires 3a.4 consumer demand proof。
- Sharing restore happens only after shareable display registration has converged for the rebuilt display id。
- If actual monitoring restore is enabled in 3a.4, it reapplies cursor capture when the old monitoring session captured cursor。
- Viewer connections、monitor attach、WebRTC frame send、capture fanout stay outside transaction queue。
- Runtime target import and forbidden type guards pass。
- `VoidDisplayVirtualDisplay` still does not import `VoidDisplayRuntime`。
- No LAN Web View token、password、account、auth introduced。
- No long-term compatibility layer added。
- Final full unit gate passes.
- Build completes with zero compile errors and zero compile warnings。

## Remaining Unprovable Items

The default automated test plan cannot prove these real-environment behaviors:

- Real macOS display topology behavior across hardware, display arrangement, mirroring, sleep/wake, and primary display transitions。
- Real virtual display driver behavior under teardown, recreate, delayed termination callback, and stale display id conditions。
- Real remote desktop software interaction with RustDesk、ToDesk、VNC、AnyDesk、Parsec or similar apps while VoidDisplay rebuilds managed virtual displays。

These need opt-in local E2E runs with real hardware and real remote desktop software. Results should go under `.ai-tmp/` and stay out of the default regression gate unless a dedicated environment exists.

## Risk Notes

- The highest-risk point is monitor restoration. Current monitoring sessions have session IDs and windows tied to old display IDs. Phase 3a therefore records monitoring restore intent by default and does not start capture unless 3a.4 proves a real consumer demand owner.
- The second-risk point is topology stability. `DisplayRebuildCoordinator` already waits and repairs system topology. Runtime should only wait for catalog DTO convergence. Adding another repair layer would increase complexity and create conflicting authority.
- The third-risk point is fleet rebuild scope. Current code stops all managed displays when rebuilding the managed main display. Runtime must preserve this behavior exactly, or sharing/monitoring sessions can survive on display ids that are about to disappear.
