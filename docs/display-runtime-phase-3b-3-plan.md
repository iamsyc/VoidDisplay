# DisplayRuntime Phase 3b.3: Create / Delete Transaction

状态：执行级计划
依据：[产品定位与架构重构前置结论](./product-positioning.md)、[DisplayRuntime 重构执行计划](./display-runtime-refactor-plan.md)、[DisplayRuntime Phase 1 执行计划](./display-runtime-phase-1-plan.md)、[DisplayRuntime Phase 2 执行记录](./display-runtime-phase-2-plan.md)、[DisplayRuntime Phase 3 计划与 Phase 3a rebuild transaction baseline](./display-runtime-phase-3-plan.md)、[DisplayRuntime Phase 3b 总计划](./display-runtime-phase-3b-plan.md)、[DisplayRuntime Phase 3b.2 Edit Rebuild Transaction](./display-runtime-phase-3b-2-plan.md)
基线：当前 HEAD `b7077c1cdb87338cad8a2f1a888691bb09c91572`
范围：只规划 Phase 3b.3 create / delete transaction。本文档不实现代码。

## Summary

Phase 3b.3 只迁移 virtual display create / delete transaction。

本阶段目标：

- 新增 transaction kinds：`virtualDisplayCreate`、`virtualDisplayDelete`。
- 新增 runtime create / delete APIs。
- 新增 runtime command ports：`createVirtualDisplay(request)`、`deleteVirtualDisplay(request)`。
- Create sheet 改为发送单个 runtime-backed create request。
- Delete confirmation 改为等待 runtime-backed delete request terminal result。
- 删除或改到不可达旧 create / destroy direct path。
- Delete terminal success 后，通过 presentation adapter 清理 deleted config 的 rebuild presentation state。

本阶段明确不做：

- 不实现 startup restore。
- 不改 capture frame pipeline。
- 不改 WebRTC signaling、publisher session、RelaySessionHub、ICE / offer / answer flow。
- 不改 LAN Web View route、security、auth、shareID、viewer session。
- 不实现 Phase 4 consumer lease。
- 不恢复 monitor window、old monitoring session id、old viewer connection。
- 不引入长期兼容层、fallback branch 或双写路径。

## Current State

`CreateVirtualDisplayObjectView.createDisplayAction()` 当前执行 UI / workflow validation 后直接调用 presentation wrapper：

```text
createDisplayAction
  -> resolve maxPixelDimensions
  -> virtualDisplay.createDisplay(
       name,
       serialNum,
       physicalSize: CGSize,
       maxPixels,
       modes: [ResolutionSelection]
     )
  -> success closes sheet
  -> failure is swallowed locally because controller owns persistence presentation
```

代码位置：`Sources/VoidDisplayVirtualDisplay/Views/CreateVirtualDisplayObjectView.swift`。

`VirtualDisplayController.createDisplay(...)` 当前是 persistence presentation wrapper：

- 通过 `performPersistenceAction` 设置 `Create Failed` presentation。
- 在 `mutateAndSync` 内调用 `virtualDisplayFacade.createDisplay(...)`。
- 成功后同步 `virtualDisplaySnapshot`。
- 记录 `Create virtual display` observability event，metadata 只含 config id 和 serial number。
- 方法签名仍暴露 `CGSize` 和 `[ResolutionSelection]`，因此不能进入 `VoidDisplayRuntime` DTO。

`VirtualDisplayOrchestrator.createDisplay(...)` 当前顺序：

1. 检查 runtime active serial 和 persisted config serial，重复则抛出 `duplicateSerialNumber`。
2. 检查 modes 非空。
3. 构造 `VirtualDisplayConfig(displayName, serialNum, physicalWidth, physicalHeight, modes, desiredEnabled: true)`。
4. `configManager.appendConfig(config)`，先持久化新增 config。
5. `runtimeTracker.createRuntimeDisplay(from: config, maxPixels: maxPixels)`，再创建 runtime display。
6. 如果 runtime creation 失败，记录错误，然后调用 `configManager.rollbackAppendedConfig(config.id)`。
7. rollback 成功时重抛原始 creation error。
8. rollback 失败时抛出 `VirtualDisplayOperationError.persistenceRecoveryFailed(...)`。

这个顺序说明 create compensation 的底层事件顺序：persistence append 先发生，runtime creation 后发生，runtime creation 失败依赖现有 rollback behavior。当前公开 API 没有把这些事实作为 command result 暴露出来。

架构缺口：当前 `VirtualDisplayOrchestrator.createDisplay(...)` 成功只返回 UUID，失败只 throw。runtime creation failure 后 rollback success 会重抛原始 runtime creation error，rollback failure 会替换为 `persistenceRecoveryFailed`。因此 App adapter 不能可靠知道 persistence append、runtime creation、rollback outcome，也不能靠 catch error type 推导出完整 command result。

`VirtualDisplayListViewModel.confirmDelete()` 当前通过 dependency 同步调用 destroy：

```text
confirmDelete
  -> guard deleteCandidate
  -> dependencies.destroyDisplay(candidate.id)
  -> success clears deleteCandidate and closes confirmation
  -> failure keeps deleteCandidate, keeps confirmation open, shows Delete Failed alert
```

`VirtualDisplayListViewModel.Dependencies.live(controller:)` 当前把 delete 绑定为：

```text
destroyDisplay: { try controller.destroyDisplay($0) }
```

`VirtualDisplayController.destroyDisplay(_:)` 当前是 delete persistence presentation wrapper：

- 通过 `performPersistenceAction` 设置 `Delete Failed` presentation。
- 在 `mutateAndSync` 内调用 `virtualDisplayFacade.destroyDisplay(configId)`。
- 在同一个 successful mutation block 内调用 `clearRebuildPresentationState(configId:)`。
- 成功后记录 `Delete virtual display` observability event。

这意味着 deleted config 的 rebuild presentation state 当前在 lower direct destroy 成功时立即清理。Phase 3b.3 必须把这一步移到 runtime delete terminal success 之后，由 presentation adapter 执行。

`VirtualDisplayOrchestrator.destroyDisplay(_:)` 当前顺序：

1. 如果 config missing，直接 return。
2. `configManager.removeConfig(configId)`，先删除 persisted config。
3. `policyResolver.clearAggressiveRecoveryPending(configId:)`。
4. `runtimeTracker.clearRuntimeTracking(configId:keepGeneration:false)`。

`VirtualDisplayConfigManager.removeConfig(_:)` 在保存前用 candidate collection mutation，save 失败不会替换内存 configs。因此 delete persistence failure before runtime tracking clear 当前不会产生 runtime side effect。

架构缺口：当前 missing config 直接 return，与本计划选择的 missing config failed trace 语义冲突。Phase 3b.3 不能让 adapter 把 lower no-op missing 映射为 success。

架构缺口：`VirtualDisplayController.createDisplay(...)` 和 `VirtualDisplayController.destroyDisplay(_:)` 仍是可调用 presentation wrappers。迁移后它们必须删除或改到不可达，不能作为 production create / delete 的平行 direct path 保留。

Phase 3a rebuild 已提供的可复用 transaction 能力：

- virtual display transaction queue。
- transaction-scoped catalog refresh。
- pre / post snapshot evidence。
- affected surface scope。
- sharing / monitoring quiesce。
- rebuild command port。
- bounded topology stability wait。
- visible convergence after stable topology。
- sharing restore。
- monitoring restore intent-only evidence。
- transaction trace 和 observability refresh。
- permission unavailable 时把 topology proof 标为 `unprovableDueToPermission`，不把它归类为 virtual display command failure。

Phase 3b.1 enable / disable 已提供的可复用能力：

- `virtualDisplayEnable`、`virtualDisplayDisable` transaction kinds。
- desired enabled persistence command pattern。
- lifecycle command request / result DTO pattern。
- persistence outcome、virtual display command outcome、scope escalation、restore result 等 trace 字段。
- command failure 与 recovery degradation 分离。
- enable / disable 复用同一 transaction queue 和 Phase 3a restore rules。
- disabled target session restore skip reason pattern，目前为 `target_disabled`。

Phase 3b.2 edit rebuild 已提供的可复用能力：

- `virtualDisplayEditRebuild` transaction kind。
- command DTO 和 redacted evidence DTO pattern。
- `displayName` 只允许作为 transient command input，默认 trace / snapshot / support bundle 不写 display name。
- save gate 和 terminal result 分离。
- command-only save / restore paths，不调用 presentation wrappers。
- persistence compensation outcome：`saved`、`rolledBack`、`rollbackFailed`。
- edit rebuild active-task coalescing disabled，仍通过同一 virtual display transaction queue 串行。

## Scope

本阶段只做 create / delete transaction。

Runtime model changes：

- 新增 `DisplayRuntimeTransactionKind.virtualDisplayCreate`。
- 新增 `DisplayRuntimeTransactionKind.virtualDisplayDelete`。
- 新增 `DisplayRuntimeTransactionSource.createVirtualDisplaySheet`。
- 新增 `DisplayRuntimeTransactionSource.deleteVirtualDisplayConfirmation`。

新增 create runtime API，推荐命名：

```text
createVirtualDisplay(
  request: DisplayRuntimeVirtualDisplayCreateRequest,
  source: DisplayRuntimeTransactionSource
) async throws -> DisplayRuntimeVirtualDisplayCreateTransactionResult
```

新增 delete runtime API，推荐命名：

```text
deleteVirtualDisplay(
  configID: UUID,
  source: DisplayRuntimeTransactionSource
) async throws -> DisplayRuntimeVirtualDisplayDeleteTransactionResult
```

Delete 使用专用 result，不复用 `DisplayRuntimeVirtualDisplayRebuildTransactionResult`。原因：

- Delete 需要表达 `targetWasRunning`。
- Delete 需要表达 target restore skip reason `target_deleted`。
- Delete 需要表达 runtime tracking clear side effect。
- Delete 成功但 topology / peer restore degraded 时需要保留 delete command success，同时报告 degraded delete outcome。

新增 command ports：

```text
DisplayRuntimeVirtualDisplayCommanding.createVirtualDisplay(request) async throws -> DisplayRuntimeVirtualDisplayCreateCommandResult
DisplayRuntimeVirtualDisplayCommanding.deleteVirtualDisplay(request) async throws -> DisplayRuntimeVirtualDisplayDeleteCommandResult
```

Lower virtual display layer must expose command-shaped APIs for create / delete. Required shape:

```text
createDisplayCommand(...) throws -> VirtualDisplayCreateCommandResult
deleteDisplayCommand(...) throws -> VirtualDisplayDeleteCommandResult
```

Create lower API requirements:

- Success returns created config id、serial、persistence outcome、runtime creation outcome、rollback outcome、runtime display id evidence。
- Append failure returns or throws typed command failure with `persistenceOutcome: failed`, `runtimeCreationOutcome: notAttempted`, `rollbackOutcome: notAttempted`, `createdConfigID: nil`。
- Runtime creation failure after append returns or throws typed command failure with `createdConfigID`, `persistenceOutcome`, `runtimeCreationOutcome: failed`, `rollbackOutcome`, and underlying error。
- Runtime creation failure plus rollback success must preserve the rollback success fact even though the user-visible command failed。
- Runtime creation failure plus rollback failure must preserve `rollbackOutcome: rollbackFailed` and the persistence recovery failure fact。
- `DisplayRuntimeVirtualDisplayAdapter.createVirtualDisplay` must not infer append、runtime creation or rollback outcome from snapshot diff。

Delete lower API requirements:

- Success returns target config id、`targetWasRunning`、`preDisplayID`、`persistenceOutcome`、`runtimeTrackingClearOutcome` and post-command runtime evidence。
- Missing config must throw or return failed outcome with reason `config_not_found`。
- Persistence delete failure must return or throw `persistenceOutcome: failed` and must prove runtime tracking was not cleared。
- `DisplayRuntimeVirtualDisplayAdapter.deleteVirtualDisplay` must not map the current lower no-op missing behavior to success。

Create sheet migration：

- UI validation 可继续留在 `CreateVirtualDisplayObjectView` 或相邻 workflow object。
- Create action 发送一个 runtime-backed create request。
- Create success closes sheet。
- Create failure keeps sheet open and shows existing Create Failed presentation。
- Old direct call to `VirtualDisplayController.createDisplay(...)` must be deleted or unreachable from create sheet。

Delete confirmation migration：

- `VirtualDisplayListViewModel.confirmDelete()` sends one runtime-backed delete request。
- It waits for runtime terminal result。
- Delete success clears candidate and closes confirmation。
- Delete failure keeps candidate and confirmation open, matching current behavior。
- Old direct call to `VirtualDisplayController.destroyDisplay(_:)` must be deleted or unreachable from `confirmDelete()`。

Command-only path constraints：

- `DisplayRuntimeVirtualDisplayAdapter.createVirtualDisplay` must not call `VirtualDisplayController.createDisplay(...)`。
- `DisplayRuntimeVirtualDisplayAdapter.deleteVirtualDisplay` must not call `VirtualDisplayController.destroyDisplay(_:)`。
- Command-only create / delete controller methods may be added to `VirtualDisplayController`, but they must avoid `performPersistenceAction` and must not set `persistenceAlert`。
- Presentation failure mapping belongs to create/delete UI adapter, not command adapter side effects。
- Production create / delete paths must not call old presentation wrappers after migration。
- Old `VirtualDisplayController.createDisplay(...)` and `VirtualDisplayController.destroyDisplay(_:)` wrappers must be deleted by default。
- If a wrapper is kept temporarily during the same implementation branch for test migration, the implementation must document the sole caller, deletion condition and validation impact in the handoff。
- Retaining wrappers for unspecified non-migrated callers is not allowed as a long-term compatibility layer。

## Create Transaction Flow

Required order:

1. UI / workflow layer performs local input validation where it already exists。
2. Validation failure before runtime request does not enter runtime transaction。
3. If a runtime transaction is created and command DTO validation fails inside runtime, record a failed transaction with `phase: preparing` and no command side effect。
4. Runtime enqueues the request on an inventory-level serial key because config id does not exist yet。
5. Create active-task coalescing is disabled by default。
6. Runtime appends `.preparing` phase。
7. Runtime runs transaction-scoped catalog refresh。
8. Runtime captures pre inventory evidence。
9. Runtime stores only redacted create config evidence, never `displayName`。
10. Runtime appends `.executingVirtualDisplayCommand` or `.persistingConfig` then `.executingVirtualDisplayCommand` if implementation chooses to split command phases。
11. Runtime calls command port `createVirtualDisplay(request)`。
12. Command port uses command-only path and must not call presentation wrapper `VirtualDisplayController.createDisplay(...)`。
13. App adapter maps command DTO into `VirtualDisplayConfig` / `ResolutionSelection` / `CGSize` in App layer only。
14. Adapter calls lower command-shaped API `createDisplayCommand(...)` or catches a typed create command failure carrying the same facts。
15. Lower command-shaped API appends config, then creates runtime display。
16. Lower command-shaped API uses existing rollback behavior if runtime creation fails after config append。
17. Command result or typed command failure reports created config id, serial, persistence outcome, runtime creation outcome, rollback outcome if runtime creation failed, and redacted config evidence。
18. Adapter must forward these facts. It must not guess rollback outcome from snapshot diff。
19. If create command fails before runtime side effect, runtime finalizes failed with persistence / command outcome。
20. If create command succeeds, runtime derives the created managed surface from created config id。
21. Runtime appends `.waitingForTopology`。
22. Runtime waits bounded topology stability for the created managed surface。
23. If topology is stable, runtime runs visible convergence。
24. Create transaction normally does not restore pre-existing sessions, because no pre-existing target surface session exists before config id creation。
25. If a future implementation explicitly quiesces affected peers for a proven lower-layer create disturbance, only those peers may receive restore intents using existing Phase 3a rules。
26. Runtime finalizes completed or completedWithRecoveryFailures based on topology and restore outcomes。
27. Runtime writes trace and refreshes observability。

Create command result should contain at minimum:

```text
DisplayRuntimeVirtualDisplayCreateCommandResult
  transactionID
  createdConfigID
  serialNumber
  targetWasRunningAfterCommand
  preDisplayID: nil
  postDisplayID
  persistenceOutcome
  runtimeCreationOutcome
  rollbackOutcome
  createdConfigEvidence
  runningConfigIDsAfterCommand
  managedDisplaysAfterCommand
```

Recommended create transaction result:

```text
DisplayRuntimeVirtualDisplayCreateTransactionResult
  transactionID
  status
  createdConfigID
  serialNumber
  persistenceOutcome
  runtimeCreationOutcome
  rollbackOutcome
  topologyStabilityResult
  hasRecoveryFailures
```

## Create Compensation And Failure Semantics

Validation failure:

- UI validation failure before runtime request does not create transaction evidence。
- Runtime DTO validation failure after request enters runtime creates a failed transaction with `persistenceOutcome: notAttempted` and `virtualDisplayCommandOutcome: notAttempted`。
- Runtime DTO validation must not log or trace `displayName`。

Persistence append failure:

- If append fails before runtime display creation, no runtime side effect happened。
- Transaction status is `failed`。
- `persistenceOutcome` is `failed`。
- `runtimeCreationOutcome` is `notAttempted`。
- Recoverability is `retryable` unless lower error is explicitly unrecoverable。

Runtime creation failure after config append:

- Command adapter relies on lower command-shaped API or typed command failure to report rollback facts。
- Command adapter must not infer rollback success or failure from post-command snapshots。
- Runtime does not attempt driver-handle rollback itself。
- Runtime never promises full macOS topology rollback。
- If rollback succeeds, trace records compensated persistence with `persistenceOutcome: rolledBack` or `rollbackOutcome: rolledBack`。
- If rollback fails, trace records `rollbackFailed` and failure reason `persistenceRecoveryFailed` or equivalent `rollback_failed_after_create_runtime_failure`。
- Rollback failure recoverability is `degraded` or `unrecoverable` because persisted config may remain after create failed。

Topology degradation after command success:

- Topology unprovable due to permission does not become command failure。
- Command remains succeeded。
- Transaction becomes `completedWithRecoveryFailures`。
- Trace records topology status and sample count。
- Create UI maps `completedWithRecoveryFailures` as create success. The sheet closes and degradation is left to diagnostics / transaction trace。
- `Create Failed` is only for command failure, validation failure after runtime entry, persistence failure or typed create command failure。It is not used for topology / recovery degradation after command success。

Privacy:

- Created display name must not appear in default trace。
- Created display name must not appear in runtime snapshot。
- Created display name must not appear in default support bundle。
- Created display name must not appear in diagnostics export。
- Create command DTO may carry `displayName` as transient command input only。

## Delete Transaction Flow

Required order:

1. Runtime enqueues delete on config id serial key。
2. Duplicate delete for same config does not coalesce in this slice。
3. Runtime appends `.preparing`。
4. Runtime runs transaction-scoped catalog refresh。
5. Runtime captures pre evidence。
6. Runtime resolves target surface and pre display id。
7. If target config is missing in pre snapshot, finalize failed trace with reason `config_not_found`。
8. Runtime derives affected scope。
9. Target is always affected。
10. Fleet peers are affected only if existing main policy / lower-layer behavior can disturb them。
11. Runtime creates pause intents for target and affected peer sharing / monitoring。
12. Runtime appends `.quiescingSessions`。
13. Runtime quiesces target and affected peer sharing / monitoring before command。
14. Runtime appends `.executingVirtualDisplayCommand`。
15. Runtime calls command port `deleteVirtualDisplay(request)`。
16. Command port uses command-only path and must not call presentation wrapper `VirtualDisplayController.destroyDisplay(_:)`。
17. Adapter calls lower command-shaped API `deleteDisplayCommand(...)`。
18. Lower command-shaped API must fail missing config with reason `config_not_found`; it must not use current no-op missing semantics。
19. Lower command-shaped API removes config, clears aggressive recovery and clears runtime tracking。
20. Command result reports target config id, target was running, pre display id, runtime tracking clear outcome, persistence outcome, running config ids after command and managed displays after command。
21. If target was running, runtime appends `.waitingForTopology` and waits bounded topology settlement。
22. If topology is stable, runtime runs visible convergence。
23. Runtime never restores deleted target sessions。
24. Runtime writes restore result for deleted target demand with reason `target_deleted`。
25. Runtime restores affected peer sharing only if topology is stable and peer still resolves to a running visible display。
26. Peer monitoring remains deferred until consumer lease exists。
27. Runtime finalizes completed or completedWithRecoveryFailures。
28. Presentation adapter clears rebuild presentation state for deleted config only after runtime delete terminal success。
29. Runtime writes trace and refreshes observability。

Recommended delete command request:

```text
DisplayRuntimeVirtualDisplayDeleteCommandRequest
  transactionID
  configID
  targetPreDisplayID
  targetWasRunning
```

Recommended delete command result:

```text
DisplayRuntimeVirtualDisplayDeleteCommandResult
  transactionID
  configID
  targetWasRunning
  preDisplayID
  postDisplayID
  persistenceOutcome
  virtualDisplayCommandOutcome
  runtimeTrackingClearOutcome
  runningConfigIDsAfterCommand
  managedDisplaysAfterCommand
```

Recommended delete transaction result:

```text
DisplayRuntimeVirtualDisplayDeleteTransactionResult
  transactionID
  status
  configID
  targetWasRunning
  persistenceOutcome
  virtualDisplayCommandOutcome
  runtimeTrackingClearOutcome
  topologyStabilityResult
  hasRecoveryFailures
```

## Delete Compensation And Failure Semantics

Missing config semantics:

- Missing config is a failed trace, not an idempotent success。
- Reason: delete comes from user confirmation for a concrete config. Missing config means stale UI state or concurrent state drift. Treating it as success would hide a fact that matters to diagnostics。
- Duplicate delete for same config does not coalesce in this slice because failed-missing semantics make the second request observably different after the first delete succeeds。
- Runtime pre snapshot missing config finalizes failed trace with reason `config_not_found` before command。
- Lower `deleteDisplayCommand(...)` missing config must also fail with reason `config_not_found` if command is reached after a stale pre evidence race。
- Adapter must not translate lower missing no-op behavior into success。

Persistence delete failure:

- If persistence delete fails before runtime tracking clear, no runtime side effect should happen。
- Transaction status is `failed`。
- `persistenceOutcome` is `failed`。
- `virtualDisplayCommandOutcome` is `notAttempted` or `failed` according to command split。
- Runtime tracking must not be cleared。

Persistence success with later degradation:

- If persistence delete succeeds and runtime clear fails or topology degrades, config remains deleted。
- Runtime must not recreate the deleted config as compensation。
- Trace records degraded side effect。
- Transaction status is `completedWithRecoveryFailures` if command succeeded。
- Delete UI maps `completedWithRecoveryFailures` as delete success. The confirmation closes, `deleteCandidate` is cleared, and degradation is left to diagnostics / transaction trace。
- `Delete Failed` is only for command failure, persistence failure or typed delete command failure。It is not used for topology / peer restore degradation after command success。

Session restore:

- Delete target session restore never happens。
- Target sharing restore result is skipped with reason `target_deleted`。
- Target monitoring restore result is skipped with reason `target_deleted`。
- Peer restore degradation after command success becomes `completedWithRecoveryFailures`。
- Peer monitoring remains deferred with reason `monitoring_restore_deferred_until_consumer_lease` when topology is stable and peer resolves。

Old direct path:

- No legacy delete direct path may remain reachable from `VirtualDisplayListViewModel.confirmDelete()` after this slice。
- `VirtualDisplayController.createDisplay(...)` and `VirtualDisplayController.destroyDisplay(_:)` must be deleted or made unreachable from production paths after this slice。
- If either wrapper is temporarily retained for test migration inside the same implementation branch, the handoff must name its sole caller, deletion condition and validation impact。
- Do not retain either wrapper for unspecified non-migrated callers。
- Do not add a long-term compatibility layer around old create / destroy direct paths。

## DTO And Boundary Rules

Runtime create DTO may contain:

- `transactionID`
- `displayName` as transient command input
- `serialNumber`
- `physicalWidthMillimeters`
- `physicalHeightMillimeters`
- `maximumPixelWidth`
- `maximumPixelHeight`
- primitive mode DTOs with width, height, refreshRate, enableHiDPI

Runtime delete DTO may contain:

- `transactionID`
- `configID`
- `targetPreDisplayID`
- `targetWasRunning`

Redacted config evidence may contain:

- `id` if known
- `serialNumber`
- `desiredEnabled`
- `physicalWidthMillimeters`
- `physicalHeightMillimeters`
- `modeCount`
- `maximumPixelWidth`
- `maximumPixelHeight`

Redacted evidence must exclude:

- `displayName`
- raw driver handles
- controller references
- closures
- complete persisted config objects。

Default transaction trace、runtime snapshot、support bundle and diagnostics export must not write `displayName`。

`VoidDisplayRuntime` must not import:

- SwiftUI
- AppKit
- Observation
- ScreenCaptureKit
- VoidDisplayApp
- VoidDisplayCapture
- VoidDisplaySharing
- VoidDisplayVirtualDisplay
- VoidDisplayDesignSystem

Runtime DTOs must not contain:

- `VirtualDisplayConfig`
- `ResolutionSelection`
- `CGSize`
- `SCDisplay`
- `CGVirtualDisplay`
- driver handles
- controller references
- closures

Target dependency rules:

- `VoidDisplayVirtualDisplay` must not import `VoidDisplayRuntime`。
- App adapter owns mapping to `VirtualDisplayConfig` / `ResolutionSelection` / `CGSize`。
- `VoidDisplayRuntime` remains a control plane. It must not own ScreenCaptureKit streams, WebRTC sessions, virtual display driver handles or SwiftUI view state。

## Queue And Coalescing Rules

Queue rules:

- Create uses inventory-level serial key until config id exists。
- Create active-task coalescing is disabled by default because two create requests may differ only by displayName、serial、physical size or modes。
- Delete uses config id serial key。
- Duplicate delete for same config does not coalesce under failed-missing semantics。
- Create/delete must serialize with rebuild、enable、disable、edit rebuild through the same virtual display transaction queue。
- Opposite or adjacent lifecycle commands must re-read snapshot when their turn starts。
- Viewer attach、monitor attach、frame fanout、WebRTC signaling do not enter this queue。

Implementation notes:

- Existing `ActiveVirtualDisplayTransactionKey(kind, configID)` is insufficient for create because config id does not exist before command result。
- Add an inventory-level key representation or a separate enqueue helper for inventory transactions。
- Do not fake create key with a random UUID if that makes coalescing or ordering evidence ambiguous。
- If implementation later chooses idempotent delete semantics, duplicate delete coalescing may be added only with explicit tests. This slice chooses failed-missing semantics, so no delete coalescing。

## UI Migration

Create sheet:

- Keep existing field validation and resolution mode validation in UI/workflow layer。
- Build `DisplayRuntimeVirtualDisplayCreateRequest` after local validation succeeds。
- Send one runtime-backed create request。
- Success closes sheet。
- `completedWithRecoveryFailures` after create command success also closes sheet。
- Failure keeps sheet open。
- Failure shows existing Create Failed presentation。
- Create Failed presentation is only for command failure, persistence failure or runtime-entered validation failure. It must not be used for topology / recovery degradation after command success。
- Old create direct path from `CreateVirtualDisplayObjectView.createDisplayAction()` to `VirtualDisplayController.createDisplay(...)` must be unreachable。

Delete confirmation:

- `VirtualDisplayListViewModel.confirmDelete()` becomes async task-backed or otherwise waits runtime terminal result before mutating final UI state。
- Delete success clears `deleteCandidate` and closes confirmation。
- `completedWithRecoveryFailures` after delete command success also clears `deleteCandidate` and closes confirmation。
- Delete failure keeps `deleteCandidate` and keeps confirmation open。
- Delete failure shows existing Delete Failed alert。
- Delete Failed presentation is only for command failure or persistence failure. It must not be used for topology / peer restore degradation after command success。
- This preserves current user experience。
- Delete success clears rebuild presentation state only after runtime terminal success。
- Old destroy direct path from `VirtualDisplayListViewModel.confirmDelete()` to `VirtualDisplayController.destroyDisplay(_:)` must be unreachable。

Localization:

- Do not add app-facing copy unless implementation proves existing Create Failed / Delete Failed presentation cannot represent the runtime result。
- If app-facing text changes, update localization resources in the same implementation slice。
- If `Localizable.xcstrings` changes as an Xcode side effect, include it with the implementation change。

Unaffected UI paths:

- Save-only edit remains outside this transaction。
- Running non-rebuild mode edit remains on existing immediate apply path。
- Rebuild retry remains runtime-backed rebuild transaction。
- Enable / disable remain runtime-backed lifecycle transaction。

## Observability

New transaction kinds:

- `virtualDisplayCreate`
- `virtualDisplayDelete`

Create trace must record:

- transaction id。
- source `createVirtualDisplaySheet`。
- queue evidence and no active-task coalescing。
- pre inventory evidence。
- redacted config evidence。
- created config id。
- serial number。
- persistence outcome。
- runtime creation outcome。
- rollback outcome if runtime creation failed。
- virtual display command outcome。
- topology result。
- post evidence。
- failure reason and recoverability when failed。

Delete trace must record:

- transaction id。
- source `deleteVirtualDisplayConfirmation`。
- target config id。
- target pre display id。
- target was running。
- affected surfaces。
- pause intents。
- restore intents and results。
- persistence outcome。
- runtime command outcome。
- runtime tracking clear outcome if represented separately。
- topology result。
- post evidence。
- failure reason and recoverability when failed。

Redaction rules:

- Default trace must not write create `displayName`。
- Default trace must not write deleted `displayName`。
- Runtime snapshot must not write create or deleted `displayName`。
- Support bundle must not write create or deleted `displayName` by default。
- Diagnostics export must not write create or deleted `displayName` by default。
- Evidence must not recursively include `transactions` section。

Observability event rules:

- Continue using display runtime transaction phase events for phase changes。
- Refresh observability snapshot on active trace creation, phase changes and terminal result。
- Topology unprovable due to permission is topology evidence, not command failure。

## Tests

Runtime tests:

- create success records `virtualDisplayCreate` trace。
- create command result includes created config id and redacted evidence。
- create persistence failure stops before runtime side effect。
- create append failure records command result facts with `persistenceOutcome: failed`, `runtimeCreationOutcome: notAttempted` and no created config id。
- create runtime failure with rollback success records compensated persistence。
- create runtime creation failure plus rollback success preserves created config id, failed runtime creation outcome and rolled-back persistence outcome in typed command failure / result。
- create runtime failure with rollback failure records `rollbackFailed` / `persistenceRecoveryFailed`。
- create runtime creation failure plus rollback failure preserves created config id, failed runtime creation outcome, rollbackFailed outcome and persistenceRecoveryFailed evidence。
- create topology unprovable due to permission does not become command failure。
- create does not leak displayName into default trace。
- create requests do not active-task coalesce by default。
- delete success quiesces before command。
- delete target never restores sessions and records `target_deleted`。
- delete affected peer sharing restores after stable topology。
- delete peer monitoring deferred。
- delete topology degraded records `completedWithRecoveryFailures` when command succeeds。
- delete missing config records failed trace with reason `config_not_found`。
- delete lower command missing config fails with reason `config_not_found`。
- runtime pre snapshot missing config fails before delete command。
- delete persistence failure does not clear runtime tracking。
- delete success clears rebuild presentation state only after terminal success。
- delete does not leak displayName into default trace。
- create/delete serialize with rebuild、enable、disable、edit rebuild。

Adapter tests:

- create adapter maps runtime DTO to `VirtualDisplayConfig` in App layer。
- create adapter uses command-only path, not `VirtualDisplayController.createDisplay(...)` presentation wrapper。
- create adapter reports rollback success/failure。
- create adapter does not infer rollback outcome from snapshot diff。
- delete adapter uses command-only path, not `VirtualDisplayController.destroyDisplay(_:)` presentation wrapper。
- delete adapter reports target was running and runtime side-effect result。
- delete adapter does not map lower no-op missing config behavior to success。
- adapter unavailable fails explicitly。
- adapters never expose forbidden types to runtime DTOs。

Lower-layer virtual display tests:

- `createDisplayCommand` success returns created config id, persistence success, runtime creation success and rollback notAttempted。
- `createDisplayCommand` append failure returns persistence failed, runtimeCreation notAttempted, rollback notAttempted and createdConfigID nil。
- `createDisplayCommand` runtime creation failure plus rollback success preserves created config id, runtime failed and rollback rolledBack。
- `createDisplayCommand` runtime creation failure plus rollback failure preserves rollbackFailed / persistenceRecoveryFailed evidence。
- `deleteDisplayCommand` missing config returns failed `config_not_found`。
- `deleteDisplayCommand` persistence failure proves runtime tracking was not cleared。
- `deleteDisplayCommand` success returns targetWasRunning, preDisplayID and runtimeTrackingClearOutcome。

UI / controller tests:

- create sheet sends single runtime request。
- create success closes sheet。
- create `completedWithRecoveryFailures` closes sheet。
- create failure keeps sheet open and shows create failure。
- old create direct path unreachable。
- delete confirmation sends runtime request。
- delete success clears candidate and closes confirmation。
- delete `completedWithRecoveryFailures` clears candidate and closes confirmation。
- delete failure keeps candidate and confirmation open, matching planned strategy。
- old destroy direct path unreachable。
- save-only/edit/rebuild paths unaffected。

Observability / support tests:

- default runtime snapshot does not include create displayName。
- support bundle does not include create displayName。
- observability export does not include create displayName。
- default runtime snapshot does not include deleted displayName。
- support bundle does not include deleted displayName。
- observability export does not include deleted displayName。
- trace evidence is redacted and non-recursive。

Create workflow test note:

- `CreateVirtualDisplayWorkflowTests` does not exist at this baseline。
- Implementation should add `CreateVirtualDisplayWorkflowTests` if the create sheet logic moves into a testable workflow object。
- If implementation keeps logic inside SwiftUI view and cannot directly unit test the view action, it must add an equivalent controller / workflow harness with a clear name and cover the same assertions: single runtime request, success closes sheet, failure keeps sheet open, old direct path unreachable。

## Verification Gates

Required targeted verification:

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter VirtualDisplayControllerTests
scripts/ci/unit.sh --filter VirtualDisplayListViewModelTests
scripts/ci/unit.sh --filter VirtualDisplayOrchestratorLightTests
scripts/ci/unit.sh --filter CreateVirtualDisplayWorkflowTests
scripts/ci/unit.sh --filter SharingControllerTests
scripts/ci/unit.sh --filter SharingServiceTests
scripts/ci/unit.sh --filter CaptureControllerTests
scripts/ci/unit.sh --filter CaptureMonitoringLifecycleServiceTests
scripts/ci/unit.sh --filter ObservabilitySnapshotProviderTests
scripts/ci/unit.sh --filter ObservabilityCenterTests
scripts/ci/unit.sh --filter FeedbackBundleExporterTests
scripts/ci/unit.sh --filter AppBootstrapTests
scripts/ci/xcode.sh --action build --configuration Debug
git diff --check
```

If `CreateVirtualDisplayWorkflowTests` is not added under that exact name, the implementation handoff must name the equivalent create workflow test and justify the substitution。

Boundary grep gates:

```sh
if rg -n "import (SwiftUI|AppKit|Observation|ScreenCaptureKit|VoidDisplayApp|VoidDisplayCapture|VoidDisplaySharing|VoidDisplayVirtualDisplay|VoidDisplayDesignSystem)" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "\\b(VirtualDisplayConfig|ResolutionSelection|CGSize|SCDisplay|CGVirtualDisplay|VirtualDisplayRuntimeHandling|SCStream|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "import VoidDisplayRuntime" Sources/VoidDisplayVirtualDisplay; then exit 1; fi
```

Old create / destroy direct path audit:

```sh
if rg -n "virtualDisplay\\.createDisplay\\(" Sources/VoidDisplayVirtualDisplay/Views/CreateVirtualDisplayObjectView.swift; then exit 1; fi
if rg -n "controller\\.destroyDisplay\\(|dependencies\\.destroyDisplay\\(|destroyDisplay:\\s*\\{\\s*try controller\\.destroyDisplay" Sources/VoidDisplayVirtualDisplay/ViewModels/VirtualDisplayListViewModel.swift; then exit 1; fi
if rg -n "func createDisplay\\s*\\(" Sources/VoidDisplayVirtualDisplay/ViewModels/VirtualDisplayController.swift Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayFacadeProtocols.swift Sources/VoidDisplayVirtualDisplay/Services/UITestVirtualDisplayFacade.swift Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayOrchestrator.swift Tests/VoidDisplayVirtualDisplayTests/TestSupport/VirtualDisplayTestSupport.swift; then exit 1; fi
if rg -n "func destroyDisplay\\s*\\(" Sources/VoidDisplayVirtualDisplay/ViewModels/VirtualDisplayController.swift Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayFacadeProtocols.swift Sources/VoidDisplayVirtualDisplay/Services/UITestVirtualDisplayFacade.swift Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayOrchestrator.swift Tests/VoidDisplayVirtualDisplayTests/TestSupport/VirtualDisplayTestSupport.swift; then exit 1; fi
```

The declaration audit intentionally targets controller wrappers, facade protocols, UI test facade, lower orchestrator and test support. Old `func createDisplay(` / `func destroyDisplay(` declarations must not remain after implementation. The allowed replacement names are command-shaped APIs such as `createDisplayCommand` and `deleteDisplayCommand`。If implementation temporarily retains a wrapper during the same branch, the handoff must state the sole caller, deletion condition and validation impact. The default requirement is deletion。

Xcode warning / error scan:

```sh
scripts/ci/xcode.sh --action build --configuration Debug 2>&1 | tee .ai-tmp/display-runtime-phase-3b-3/xcode-build.log
if rg -n "warning:" .ai-tmp/display-runtime-phase-3b-3/xcode-build.log; then exit 1; fi
if rg -n "error:" .ai-tmp/display-runtime-phase-3b-3/xcode-build.log; then exit 1; fi
```

Handoff requires zero compile errors and zero compile warnings after implementation changes。

Docs-only changes to this plan do not require Xcode build. Any code implementation of Phase 3b.3 must pass the build and warning gates before handoff。

## Acceptance Criteria

- `docs/display-runtime-phase-3b-3-plan.md` exists。
- The plan only covers Phase 3b.3 create / delete transaction。
- The planning task does not change product code。
- The plan can be handed directly to an execution window for implementation。
- The plan does not introduce long-term compatibility layers。
- The plan does not preserve legacy direct create / destroy paths after migration。
- The plan does not smuggle startup restore into this stage。
- The plan does not smuggle capture frame pipeline changes into this stage。
- The plan does not smuggle WebRTC or LAN security changes into this stage。
- The plan does not smuggle Phase 4 consumer lease into this stage。
- The plan explicitly chooses failed trace for missing delete config。
- The plan explicitly chooses no default create coalescing。
- The plan explicitly keeps target delete session restore disabled with reason `target_deleted`。
- The plan explicitly bans displayName from default trace、snapshot、support bundle and diagnostics export。
- The plan requires command-shaped lower create / delete APIs or typed command failures carrying equivalent facts。
- The plan forbids adapter snapshot diff guessing for create rollback outcome。
- The plan forbids mapping lower delete missing no-op behavior to success。
- The plan maps `completedWithRecoveryFailures` after command success to UI success for create and delete。

## Handoff Notes

`docs/display-runtime-phase-3b-plan.md` needs a follow-up sync after this document lands:

- Mark Phase 3b.1 enable / disable as completed if the project wants slice status in the master plan。
- Mark Phase 3b.2 edit rebuild as completed if the project wants slice status in the master plan。
- Link this Phase 3b.3 execution plan from the master plan。
- Update stale baseline wording in the master plan, which currently predates this HEAD and still describes some now-completed work as future work。

No code implementation is included in this planning slice。
