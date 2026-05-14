# DisplayRuntime Phase 3b.2: Edit Rebuild Transaction

状态：已完成历史记录
依据：[产品定位与架构重构前置结论](./product-positioning.md)、[DisplayRuntime 重构执行计划](./display-runtime-refactor-plan.md)、[DisplayRuntime Phase 1 执行计划](./display-runtime-phase-1-plan.md)、[DisplayRuntime Phase 2 执行记录](./display-runtime-phase-2-plan.md)、[DisplayRuntime Phase 3 计划与 Phase 3a rebuild transaction baseline](./display-runtime-phase-3-plan.md)、[DisplayRuntime Phase 3b 总计划](./display-runtime-phase-3b-plan.md)
基线：当前 HEAD `24adc46be5d942a65f82a5809a6c39a17ce268df`
范围：只规划 Phase 3b.2 edit with rebuild-required changes transaction。本文档不实现代码。
归档说明：Phase 3b.2 已完成，属于 Phase 3 的拆分历史记录。本文不再作为当前待办清单。
导航：当前阅读顺序见 [DisplayRuntime 文档索引](./display-runtime-index.md)。

## Summary

Phase 3b.2 只迁移 edit with rebuild-required changes，也就是 `VirtualDisplayEditSaveAnalyzer.requiresSaveAndRebuild == true` 的 Save and Rebuild。

本阶段目标：

- 新增 `virtualDisplayEditRebuild` transaction kind。
- 把 Save and Rebuild 从 UI 层的双调用改成单个 runtime request。
- 让 runtime 在一个 transaction 内编排 config save、rebuild、topology wait、sharing restore、monitoring deferred intent 和 compensation。
- 删除或改到不可达旧的 `updateConfig` then `startRebuildFromSavedConfig` 双路径。

本阶段明确不做：

- Save-only edit 继续留在现有低风险路径。
- Immediate mode apply 继续留在当前 presentation / virtual display target command 路径。
- 不实现 create / delete transaction。
- 不实现 startup restore transaction。
- 不修改 capture frame pipeline、WebRTC、LAN Web View、安全模型、鉴权模型、route、shareID 或 viewer session。

## Current State

`EditVirtualDisplayConfigView.performSaveAndRebuild(_:)` 当前是两段式命令：

```text
try virtualDisplay.updateConfig(analysis.updatedConfig)
loadedConfig = analysis.updatedConfig
dismiss()
virtualDisplay.startRebuildFromSavedConfig(configId: configId, source: .editSaveAndRebuild)
```

这意味着 config persistence 和 rebuild transaction 不是一个原子语义单元。`updateConfig` 成功后，如果 rebuild 失败，runtime 目前只知道一次 rebuild transaction，不知道旧 config，也没有机会执行 edit-specific persistence compensation。

`VirtualDisplayController.updateConfig(_:)` 当前职责：

- 通过 `performPersistenceAction` 设置 Save Failed presentation。
- 调用 `mutateAndSync { try virtualDisplayFacade.updateConfig(updated) }`。
- 同步 `virtualDisplaySnapshot`。
- 记录 `Update virtual display config` observability event。
- 该方法仍适合 save-only edit，因为它只处理持久化，不改变 runtime topology。

`VirtualDisplayController.startRebuildFromSavedConfig(configId:source:)` 当前职责：

- 增加 `rebuildRequestCount`。
- 维护 rebuild presentation waiter、row busy state、failure message、recent applied badge。
- 创建 MainActor task，调用已配置的 `rebuildExecutor(configId, source)`。
- executor 成功后标记 rebuild success，失败后标记 rebuild failure。

`VirtualDisplayController.retryRebuild(configId:)` 只是 presentation wrapper：

```text
retryRebuild(configId)
  -> startRebuildFromSavedConfig(configId:source:.rowRetry)
```

正式 App bootstrap 已经把 rebuild executor 接到 runtime：

```text
VirtualDisplayController.startRebuildFromSavedConfig
  -> configured rebuild executor
  -> DisplayRuntime.rebuildVirtualDisplay(configID:source:)
  -> DisplayRuntimeVirtualDisplayAdapter.rebuildVirtualDisplay(configID:)
  -> VirtualDisplayController.rebuildVirtualDisplay(configId:)
  -> VirtualDisplayFacade.rebuildVirtualDisplay(configId:)
  -> VirtualDisplayOrchestrator.rebuildVirtualDisplay(configId:)
  -> DisplayRebuildCoordinator.rebuildVirtualDisplay(configId:)
```

因此 Phase 3a rebuild command 已经 runtime-backed，但 edit save 本身还不在 runtime transaction 内。

`VirtualDisplayEditSaveAnalyzer.requiresSaveAndRebuild` 当前判断规则：

- 只有 `isRunning == true` 才可能要求 Save and Rebuild。
- display name 变化要求 Save and Rebuild。
- serial number 变化要求 Save and Rebuild。
- physical width / height 变化要求 Save and Rebuild。
- max pixel width / height 增大要求 Save and Rebuild。
- running config 下不需要 rebuild 的 mode edit 设置 `shouldApplyModesImmediately == true`。
- stopped config edit 不要求 rebuild，属于 save-only。

Phase 3a 已提供的可复用能力：

- virtual display transaction queue。
- same config and same kind coalescing。
- transaction-scoped catalog refresh。
- pre / post snapshot evidence。
- affected surface scope。
- sharing / monitoring quiesce。
- rebuild command port。
- bounded topology stability wait。
- visible convergence。
- sharing restore。
- monitoring restore intent-only evidence。
- transaction trace 和 observability refresh。
- permission unavailable 时将 topology proof 标为 degraded / unprovable，不把它归类为 virtual display command failure。

Phase 3b.1 已提供的可复用能力：

- `virtualDisplayEnable` 和 `virtualDisplayDisable` transaction kinds。
- desired enabled persistence command pattern。
- lifecycle command request / result DTO pattern。
- persistence outcome、virtual display command outcome、scope escalation、restore result 等 trace 字段。
- command failure 与 recovery degradation 分离的 presentation 语义。
- enable / disable 复用同一 transaction queue 和 Phase 3a restore rules。

## Scope

本阶段只做 edit rebuild transaction。

Runtime model changes：

- 新增 `DisplayRuntimeTransactionKind.virtualDisplayEditRebuild`。
- 新增 runtime API，推荐命名：

```text
saveVirtualDisplayConfigAndRebuild(request: DisplayRuntimeVirtualDisplayEditRebuildRequest, source: DisplayRuntimeTransactionSource) async throws -> DisplayRuntimeVirtualDisplayEditRebuildTransactionHandle
```

- 新增 edit rebuild transaction handle。This handle is required for the phase-aware save gate UX contract:

```text
DisplayRuntimeVirtualDisplayEditRebuildTransactionHandle
  transactionID
  waitForSaveGate() async throws -> DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult
  waitForTerminalResult() async throws -> DisplayRuntimeVirtualDisplayRebuildTransactionResult
```

- 新增 save gate result：

```text
DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult
  transactionID
  configID
  persistenceOutcome
  savedConfigEvidence
```

- 新增 edit rebuild request DTO：

```text
DisplayRuntimeVirtualDisplayEditRebuildRequest
  transactionID
  editedConfig
  expectedConfigFingerprint
  source
```

UI request must not carry old config。`expectedConfigFingerprint` is the required stale-request guard derived from the complete persisted config loaded into the edit UI。The fingerprint must include `displayName` in its calculation, but the fingerprint value itself must not expose `displayName`。

- 新增 runtime config command DTO。它必须表达完整持久化配置，供保存新配置和补偿恢复使用：

```text
DisplayRuntimeVirtualDisplayConfigEditDTO
  id: UUID
  displayName: String
  serialNumber: UInt32
  desiredEnabled: Bool
  physicalWidthMillimeters: UInt32
  physicalHeightMillimeters: UInt32
  modes: [DisplayRuntimeVirtualDisplayModeDTO]
  maximumPixelWidth: UInt32
  maximumPixelHeight: UInt32
```

`editedConfig.displayName` is required so Save and Rebuild can save a renamed display。The old config used for compensation must come from the save command result, not from UI request state。

`maximumPixelWidth` and `maximumPixelHeight` may be derived by runtime from modes or supplied by adapter. The implementation must choose one source of truth and test it. If supplied, adapter owns exact parity with `VirtualDisplayConfig.maxPixelDimensions`。

- 新增 redacted evidence DTO：

```text
DisplayRuntimeVirtualDisplayConfigEvidence
  id
  serialNumber
  desiredEnabled
  physicalWidthMillimeters
  physicalHeightMillimeters
  modeCount
  maximumPixelWidth
  maximumPixelHeight
```

Redacted evidence must not include `displayName`。Default transaction trace、runtime snapshot、support bundle and diagnostics export must not write user-provided display names。

Command port changes：

```text
DisplayRuntimeVirtualDisplayCommanding.saveConfigForRebuild(request) async throws -> DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult
DisplayRuntimeVirtualDisplayCommanding.restoreConfigAfterFailedEdit(request) async throws -> DisplayRuntimeVirtualDisplayPersistenceCommandResult
```

Recommended save command result:

```text
DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult
  configID
  persistenceOutcome
  previousConfigForCompensation
  savedConfigEvidence
```

`previousConfigForCompensation` uses `DisplayRuntimeVirtualDisplayConfigEditDTO` and includes `displayName`。It is command data for bounded compensation only and must not be serialized into default diagnostics export。

Recommended restore command result:

```text
DisplayRuntimeVirtualDisplayPersistenceCommandResult
  configID
  persistenceOutcome
```

Implementation may reuse an existing result type if it preserves the same meaning and remains command-shaped。

Command-only save / restore constraints：

- `saveConfigForRebuild` and `restoreConfigAfterFailedEdit` must use command-only controller / facade / orchestrator paths。
- `DisplayRuntimeVirtualDisplayAdapter.saveConfigForRebuild` must not call `VirtualDisplayController.updateConfig`。
- `DisplayRuntimeVirtualDisplayAdapter.restoreConfigAfterFailedEdit` must not call `VirtualDisplayController.updateConfig`。
- `saveConfigForRebuild` must read the current complete persisted config from App / VirtualDisplay layer before saving。
- `saveConfigForRebuild` must return that current config as `previousConfigForCompensation` after a successful save。
- If the current complete config does not match `expectedConfigFingerprint`, save must fail with reason `edit_request_stale`。
- Command-only save / restore paths perform persistence and snapshot sync only。
- Command-only save / restore paths must not call `performPersistenceAction`。
- Command-only save / restore paths must not set `VirtualDisplayController.persistenceAlert`。
- Command-only save / restore paths must not create Save Failed presentation side effects。
- Edit save presentation belongs to the edit rebuild runtime result mapping or edit rebuild presentation adapter, not the command adapter。

UI changes：

- `EditVirtualDisplayConfigView` keeps validation and draft analysis。
- `requiresSaveAndRebuild == false` continues calling `performSaveOnly` and `VirtualDisplayController.updateConfig`。
- `requiresSaveAndRebuild == true` sends one runtime-backed edit rebuild request。
- The old `performSaveAndRebuild` sequence of `updateConfig` plus `startRebuildFromSavedConfig` must be deleted or unreachable。

Out of scope：

- No create / delete transaction。
- No startup restore transaction。
- No capture / WebRTC / LAN Web View / security changes。
- No new app-facing copy unless implementation proves existing failure presentation cannot represent the split save / rebuild failure states。
- No long-term compatibility layer。

## Queue / Coalescing Rules

`virtualDisplayEditRebuild` has stricter identity requirements than rebuild、enable and disable。

- `virtualDisplayEditRebuild` defaults to no active-task coalescing。
- Edit rebuild uses `configID` as a serial ordering key only。
- `configID` alone must not be used as an edit rebuild coalescing key。
- Existing `ActiveVirtualDisplayTransactionKey(kind, configID)` is insufficient for edit rebuild coalescing because two requests for the same config can carry different `editedConfig` or `expectedConfigFingerprint` values。
- Phase 3b.2 must either extend queue request identity or disable active-task coalescing for edit rebuild。
- The recommended Phase 3b.2 implementation is to disable edit rebuild active-task coalescing and keep all edit rebuild requests serialized through the existing virtual display transaction queue。
- If implementation adds edit rebuild coalescing, request identity must include at least `configID`, editedConfig fingerprint and `expectedConfigFingerprint`。
- A second edit rebuild request for the same config must not reuse the first request's transaction handle, save gate or terminal result unless the safe request identity fully matches。
- Enable、disable and rebuild existing coalescing semantics must not change。
- Rebuild duplicate request coalescing from Phase 3a remains `virtualDisplayRebuild` behavior only。
- Enable / disable duplicate request coalescing from Phase 3b.1 remains lifecycle behavior only。

## Transaction Flow

Runtime flow for `saveVirtualDisplayConfigAndRebuild`:

1. Enqueue `virtualDisplayEditRebuild` on the existing virtual display transaction queue using configID only as the serial ordering key, with edit rebuild active-task coalescing disabled unless safe request identity is implemented。
2. Return `DisplayRuntimeVirtualDisplayEditRebuildTransactionHandle` immediately after the transaction is enqueued and trace exists。
3. Every queued edit rebuild request must execute its own preflight sequence before save。
4. Append `preparing` phase。
5. Run transaction-scoped catalog refresh with `DisplayRuntimeCatalogRefreshIntent.topologyChanged` and no owner scope。
6. Capture a fresh `preSnapshot = makeSnapshot()` after refresh。
7. Read the current complete config fingerprint during `saveConfigForRebuild` before save。
8. Find old config evidence in `preSnapshot.virtualDisplay.configs` by edited config id。
9. If old config is missing, fail save gate and finalize failed with reason `config_not_found`, no save, no quiesce, no rebuild。
10. Write pre evidence:
   - redacted old config evidence。
   - redacted new config evidence。
   - pre display id from the managed virtual display surface。
   - pre sharing demand from surface sharing state。
   - pre monitoring demand from surface capture state。
   - existing transaction snapshot evidence without recursive transactions。
11. Append `persistingConfig` phase。
12. Call `saveConfigForRebuild(request)` with edited config DTO and `expectedConfigFingerprint`。
13. `saveConfigForRebuild` reads the current complete persisted config before saving。
14. If current config does not match `expectedConfigFingerprint`, resolve save gate as failure and finalize failed with reason `edit_request_stale`:
    - set `persistenceOutcome = .failed` or a stale-specific persistence outcome if implementation adds one。
    - set `virtualDisplayCommandOutcome = .notAttempted`。
    - do not quiesce。
    - do not call rebuild。
    - do not run compensation。
15. If save throws or returns non-saved outcome:
    - set `persistenceOutcome = .failed` or the returned outcome。
    - set `virtualDisplayCommandOutcome = .notAttempted`。
    - finalize failed with reason `config_save_failed`。
    - do not quiesce。
    - do not call rebuild。
16. On save success, store `saveResult.previousConfigForCompensation` for compensation only。
17. Resolve `handle.waitForSaveGate()` with success after persistence succeeds and before quiesce starts。
18. Derive affected surfaces from pre evidence and the edited config evidence。
19. Build pause intents from pre snapshot for affected display ids。
20. Write affected surfaces and pause intents to trace。
21. Append `quiescingSessions` phase。
22. Quiesce existing sharing and monitoring through the existing runtime command ports。
23. Append `executingVirtualDisplayCommand` phase。
24. Call existing `rebuildVirtualDisplay(configID:)` command port for the edited config id。
25. If rebuild succeeds:
    - set `virtualDisplayCommandOutcome = .succeeded`。
    - append `waitingForTopology`。
    - wait for post-command topology using the same Phase 3a policy。
    - if topology is stable, run visible convergence。
    - compute restore intents from pause intents, topology result, pre snapshot and post convergence snapshot。
    - restore sharing if safe under Phase 3a rules。
    - record monitoring restore as deferred intent-only。
    - finalize completed or completedWithRecoveryFailures according to topology and restore results。
26. If rebuild fails after save succeeded:
    - set `virtualDisplayCommandOutcome = .failed`。
    - run compensation semantics below。
    - finalize failed with trace evidence for persistence, command failure, compensation and post snapshot。
27. Resolve `handle.waitForTerminalResult()` with the terminal transaction result after rebuild success, rebuild failure, compensation completion, cancellation or terminal failure。

Affected scope rule:

- The target managed virtual display is always affected。
- If Phase 3a rebuild scope would expand because the target is managed main and running peers exist, reuse that affected-scope logic。
- If old config evidence and new config evidence differ in serial or max pixel dimensions, derive scope from pre evidence, not post-save snapshot, because post-save may no longer describe the live old display id。
- If pre display id is missing, runtime may skip quiesce for that target and still call rebuild, matching Phase 3a behavior for rebuildable configs without a currently resolved display id。

Topology rule:

- Topology unprovable due to permission is a topology result, not a rebuild command failure。
- Degraded topology may cause restore skip or completedWithRecoveryFailures after a successful rebuild。
- A rebuild command throw remains command failure and enters compensation if save already succeeded。

## Compensation Semantics

Compensation begins only when the edited config save succeeded and the rebuild command failed。

Runtime steps:

1. Append a compensation phase. Use `compensatingPersistence` if the phase already exists; otherwise use `persistingConfig` with note `restore_old_config_after_failed_edit`。
2. Read `saveResult.previousConfigForCompensation` from the successful save command result。
3. Call `restoreConfigAfterFailedEdit(request)` with `previousConfigForCompensation`。
4. Never use a UI-provided old config as the compensation source。
5. If old config persistence restore fails:
   - set compensation status to degraded。
   - record failure reason `persistence_compensation_failed`。
   - keep transaction status failed。
   - do not claim old config restored。
   - do not run compensation rebuild。
6. If old config persistence restore succeeds:
   - set persistence compensation outcome to restored / rolledBack using the existing enum value if available。
   - try to resolve the affected surface from current snapshot plus old config evidence。
   - run one bounded compensation rebuild using the old config id only if the affected surface can be safely resolved or the same Phase 3a rebuild command can run without pre display id。
7. If compensation rebuild succeeds:
   - record compensation completed。
   - transaction still reports original edit rebuild as failed, because user-requested new config did not apply。
   - trace must show old config was restored and compensation rebuild ran。
8. If compensation rebuild fails:
   - keep restored old config if persistence restore already succeeded。
   - record compensation degraded。
   - record compensation rebuild failure separately from persistence restore。
   - transaction remains failed and retryable or degraded according to existing recoverability semantics。

Non-negotiable constraints：

- Runtime never promises full rollback of macOS topology。
- Runtime does not fake restored state when old config persistence restore fails。
- Runtime must not trust edit sheet state as rollback state。
- Compensation is bounded to one old-config persistence restore attempt and one old-config rebuild attempt。
- Compensation does not recurse into another edit rebuild transaction。
- Compensation rebuild should use a private helper or command call that avoids creating a second user-visible transaction trace unless implementation deliberately links parent and child traces and tests that shape。

## DTO And Boundary Rules

`VoidDisplayRuntime` DTOs must be value-only。

Allowed in runtime DTOs:

- `UUID`
- `Bool`
- integer and floating point primitives。
- `String` for non-sensitive enum raw values or sanitized failure reasons。
- `String` for transient command DTO field `displayName` only when required to persist or restore a virtual display config。
- arrays of runtime DTOs。
- runtime-local enums and structs that conform to `Codable`, `Equatable`, `Sendable` when stored in trace or snapshot。

`displayName` boundary rule：

- `DisplayRuntimeVirtualDisplayConfigEditDTO.displayName` is allowed because it is command input required for persistence。
- Redacted evidence DTOs must not include `displayName`。
- Default transaction trace must not include `displayName`。
- Runtime snapshot must not include `displayName`。
- Support bundle must not include `displayName` unless a future enhanced diagnostics mode explicitly defines a separate opt-in export。
- Diagnostics export must not include `displayName` by default。

Forbidden in runtime DTOs:

- `VirtualDisplayConfig`
- `ResolutionSelection`
- `CGSize`
- `SCDisplay`
- `SCStream`
- `CGVirtualDisplay`
- `CMSampleBuffer`
- `CVPixelBuffer`
- WebRTC objects。
- virtual display driver handles。
- `VirtualDisplayRuntimeHandling`
- controller references。
- closures。
- SwiftUI / Observation state。

Import boundary:

- `VoidDisplayRuntime` must not import SwiftUI。
- `VoidDisplayRuntime` must not import AppKit。
- `VoidDisplayRuntime` must not import Observation。
- `VoidDisplayRuntime` must not import ScreenCaptureKit。
- `VoidDisplayRuntime` must not import VoidDisplayApp。
- `VoidDisplayRuntime` must not import VoidDisplayCapture。
- `VoidDisplayRuntime` must not import VoidDisplaySharing。
- `VoidDisplayRuntime` must not import VoidDisplayVirtualDisplay。
- `VoidDisplayRuntime` must not import VoidDisplayDesignSystem。
- `VoidDisplayVirtualDisplay` must not import VoidDisplayRuntime。

Adapter rule:

- `DisplayRuntimeVirtualDisplayAdapter` in `VoidDisplayApp` maps runtime DTOs to `VirtualDisplayConfig`、`ResolutionSelection` and `CGSize`。
- Adapter may use target-local product types internally because it lives at the composition boundary。
- Adapter must not leak target-local product types back into `VoidDisplayRuntime`。
- Adapter must fail explicitly when its weak controller is unavailable。
- Adapter save / restore commands must use command-only paths, not `VirtualDisplayController.updateConfig`。
- Command-only paths may sync controller snapshots after persistence, but must not write `persistenceAlert` or any UI presentation state。
- UI failure presentation is produced by the edit rebuild presentation adapter from runtime result, never by command adapter side effects。

## UI Migration

Edit UI responsibilities that remain:

- Load existing config。
- Maintain draft state。
- Run validation。
- Call `VirtualDisplayEditSaveAnalyzer.analyze`。
- Choose save-only or save-and-rebuild flow from `requiresSaveAndRebuild`。
- Present existing local validation errors。

Save-only flow:

- `requiresSaveAndRebuild == false` keeps `performSaveOnly`。
- It may call `VirtualDisplayController.updateConfig`。
- If `shouldApplyModesImmediately == true`, it may continue calling `applyModes(configId:modes:)`。
- It must not create `virtualDisplayEditRebuild` transaction。

Save and Rebuild flow:

- `requiresSaveAndRebuild == true` must send exactly one runtime-backed edit rebuild request。
- It must not call `updateConfig` directly before the runtime request。
- It must not call `startRebuildFromSavedConfig` after the runtime request。
- Save and Rebuild must use `DisplayRuntimeVirtualDisplayEditRebuildTransactionHandle`。
- The edit sheet must not dismiss while save outcome is unknown。
- The Save and Rebuild button sends one runtime-backed edit rebuild request through an edit rebuild presentation adapter。
- The edit UI awaits `handle.waitForSaveGate()`。
- Save failure keeps the edit sheet open and shows edit save failure。
- Save gate success dismisses the edit sheet and starts existing rebuild presentation for the config。
- The rebuild presentation adapter awaits `handle.waitForTerminalResult()`。
- Terminal rebuild failure goes through rebuild failure presentation and must not be shown as save failure。
- Restore, sharing, monitoring and topology degradation stay in diagnostics / transaction trace。
- This intentionally preserves the current save-success dismiss UX while making save outcome known before dismiss。

Presentation failure mapping:

- Save failure from `saveConfigForRebuild` presents edit save failure。
- Rebuild command failure presents rebuild failure。
- Old config restore failure enters diagnostics / transaction trace。
- Compensation rebuild failure enters diagnostics / transaction trace。
- Sharing restore failure enters diagnostics / transaction trace。
- Monitoring deferred restore enters diagnostics / transaction trace。
- Topology unprovable / timed out enters diagnostics / transaction trace。
- Restore / monitoring / sharing degradation must not be disguised as save failure。

Localization:

- Do not change app-facing copy by default。
- If implementation needs new user-facing strings to distinguish save failure from rebuild failure, update localization resources in the same change。

## Observability

Transaction trace requirements:

- `kind == virtualDisplayEditRebuild`。
- `source == editSaveAndRebuild` for UI Save and Rebuild。
- queue / coalescing evidence。
- redacted old config evidence。
- redacted new config evidence。
- edited command DTO and `previousConfigForCompensation` may contain `displayName` while the transaction is executing, but trace stores only redacted config evidence。
- stale request failures record `edit_request_stale` without writing current or expected display names。
- affected surfaces。
- pre snapshot evidence。
- post snapshot evidence。
- persistence outcome for edited config save。
- rebuild command outcome。
- compensation outcome。
- topology stability result。
- quiesce intents。
- restore intents。
- restore results。
- failure reason and recoverability。

Default trace redaction:

- Do not write display name。
- Do not write `DisplayRuntimeVirtualDisplayConfigEditDTO.displayName`。
- Do not write LAN IP。
- Do not write full URL。
- Do not write window title。
- Do not write local user path。
- Do not write desktop content。
- Do not write raw viewer client id。
- Do not write WebRTC SDP。
- Do not write ICE candidates。
- Do not write sample buffers。
- Do not write pixel buffers。

Allowed default diagnostic identifiers:

- config id。
- serial number。
- display id。
- mode count。
- physical dimensions。
- max pixel dimensions。
- boolean demand flags。
- sanitized error domain / code through existing transaction failure shape。

Evidence recursion rule:

- `DisplayRuntimeTransactionSnapshotEvidence` must continue excluding transaction sections。
- Edit config evidence must be a sibling field or nested trace value, not a full snapshot that includes `transactions`。
- Edit config evidence must be built from redacted evidence DTOs, not by serializing command DTOs。
- Support bundle export must serialize runtime trace and runtime snapshot through redacted evidence only。

Observability refresh:

- Refresh snapshot on transaction phase changes。
- Refresh snapshot on terminal result。
- Refresh `screenCatalogStateChanged` after stable visible convergence, following existing Phase 3a behavior。

## Tests

Runtime tests in `VoidDisplayRuntimeTests`:

- edit rebuild save success then rebuild success records `virtualDisplayEditRebuild` trace。
- edit rebuild API returns `DisplayRuntimeVirtualDisplayEditRebuildTransactionHandle`。
- save gate success resolves before terminal rebuild result。
- save gate failure resolves without waiting for terminal rebuild work。
- edit rebuild request DTO includes `displayName` for edited config and does not include old config。
- edit rebuild request DTO carries `expectedConfigFingerprint`。
- stale request fails with reason `edit_request_stale`。
- stale request does not quiesce, does not rebuild and does not compensate。
- save command result returns `previousConfigForCompensation`。
- `previousConfigForCompensation` includes old `displayName`。
- compensation restore uses `previousConfigForCompensation` after edited config save succeeds and rebuild fails。
- redacted evidence and default transaction trace do not include `displayName`。
- save failure stops before quiesce and rebuild。
- save failure writes failure reason `config_save_failed`。
- save failure leaves `virtualDisplayCommandOutcome == .notAttempted`。
- rebuild failure after successful save attempts old config restore。
- old config restore success then compensation rebuild success records completed compensation while transaction remains failed for the requested edit。
- old config restore success but compensation rebuild failure records degraded compensation。
- old config restore failure records `persistence_compensation_failed`。
- sharing restore follows Phase 3a rules after successful edit rebuild。
- monitoring remains deferred intent-only。
- topology unprovable due to permission does not become command failure。
- missing old config fails before save, quiesce and rebuild。
- edit rebuild uses pre evidence for affected scope when serial or max pixels change。
- same config plus different `editedConfig` serializes and re-reads state。
- same config plus different `expectedConfigFingerprint` serializes or stale-fails independently。
- duplicate same config plus same edited DTO may coalesce only after implementation adds safe request identity; otherwise it must serialize。
- edit rebuild coalescing changes do not affect enable / disable / rebuild existing coalescing tests。

Adapter tests in `DisplayRuntimeAdapterTests`:

- `saveConfigForRebuild` maps runtime DTO to `VirtualDisplayConfig` in App layer。
- `saveConfigForRebuild` reads current complete config before saving。
- `saveConfigForRebuild` returns current complete config as `previousConfigForCompensation` after successful save。
- `saveConfigForRebuild` detects `expectedConfigFingerprint` mismatch and reports `edit_request_stale`。
- `restoreConfigAfterFailedEdit` maps `previousConfigForCompensation` to `VirtualDisplayConfig` in App layer。
- `saveConfigForRebuild` uses command-only path, not `VirtualDisplayController.updateConfig`。
- `restoreConfigAfterFailedEdit` uses command-only path, not `VirtualDisplayController.updateConfig`。
- save failure through command-only path does not set `VirtualDisplayController.persistenceAlert`。
- save failure through command-only path does not create duplicate UI side effects。
- adapter reports `.saved` when controller update succeeds。
- adapter throws and runtime records save failure when controller update fails。
- adapter unavailable fails explicitly。
- adapter never exposes `SCDisplay` or `VirtualDisplayRuntimeHandling` in runtime DTOs。

UI / controller tests:

- Save and Rebuild UI sends a single runtime request。
- old `updateConfig` plus `startRebuildFromSavedConfig` double path is unreachable。
- save-only edit still calls existing save-only path and does not create edit rebuild transaction。
- running non-rebuild mode edit still applies modes immediately through existing path。
- Save and Rebuild save failure does not dismiss the edit sheet。
- Save and Rebuild save gate success dismisses the edit sheet and starts rebuild presentation。
- edit UI waits for `handle.waitForSaveGate()` before dismissing。
- rebuild presentation waits for `handle.waitForTerminalResult()`。
- rebuild command failure shows rebuild failure presentation。
- save failure shows edit save failure presentation。
- rebuild failure is not presented as save failure。
- degradation from restore / topology / sharing / monitoring is not presented as save failure。
- default runtime snapshot, Observability export and support bundle tests must prove `displayName` is absent from default diagnostics export when edit rebuild trace is present。

Current edit-related test targets:

- `EditVirtualDisplayWorkflowTests`
- `VirtualDisplayEditSaveAnalyzerTests`
- `VirtualDisplayControllerTests`

If these cannot prove the UI sends one runtime request, add `EditVirtualDisplayConfigViewTests` or extract a testable edit action coordinator / workflow object and test it directly。

Boundary tests:

- Static grep forbids target-local imports in `Sources/VoidDisplayRuntime`。
- Static grep forbids target-local config and runtime driver types in `Sources/VoidDisplayRuntime`。
- Static grep forbids `import VoidDisplayRuntime` in `Sources/VoidDisplayVirtualDisplay`。

## Verification Gates

Run after implementation:

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter VirtualDisplayControllerTests
scripts/ci/unit.sh --filter EditVirtualDisplayWorkflowTests
scripts/ci/unit.sh --filter VirtualDisplayEditSaveAnalyzerTests
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

The implementation may keep most edit rebuild behavior tests in `VoidDisplayRuntimeTests`, but it must retain at least one observability export related test from the gates above that proves default support bundle export does not contain `DisplayRuntimeVirtualDisplayConfigEditDTO.displayName`。

Boundary grep:

```sh
if rg -n "import (SwiftUI|AppKit|Observation|VoidDisplayDesignSystem|VoidDisplayApp|VoidDisplayCapture|VoidDisplaySharing|VoidDisplayVirtualDisplay|ScreenCaptureKit)" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "\\b(VirtualDisplayConfig|ResolutionSelection|CGSize|SCDisplay|CGVirtualDisplay|VirtualDisplayRuntimeHandling|SCStream|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "import VoidDisplayRuntime" Sources/VoidDisplayVirtualDisplay; then exit 1; fi
```

Warning / error scan:

```sh
mkdir -p .ai-tmp/display-runtime-phase-3b-2
scripts/ci/xcode.sh --action build --configuration Debug 2>&1 | tee .ai-tmp/display-runtime-phase-3b-2/xcode-build.log
if rg -n "warning:" .ai-tmp/display-runtime-phase-3b-2/xcode-build.log; then exit 1; fi
```

Docs-only verification for this planning task:

```sh
test -f docs/display-runtime-phase-3b-2-plan.md
git diff --check
git diff -- docs/display-runtime-phase-3b-2-plan.md
```

## Acceptance Criteria

Planning task acceptance:

- `docs/display-runtime-phase-3b-2-plan.md` exists。
- The document covers only Phase 3b.2。
- The task changes documentation only。
- No product code changes。
- The plan can be handed directly to an implementation window。
- No long-term compatibility layer is introduced。
- Frame pipeline, LAN security, create / delete and startup restore are not included in this phase。

Implementation acceptance for the later code task:

- Save and Rebuild for rebuild-required edits is a single runtime request。
- Save-only edit still uses the existing save-only path。
- Immediate mode apply remains outside this transaction。
- Runtime trace records `virtualDisplayEditRebuild` with redacted old and new config evidence。
- Save failure stops before quiesce and rebuild。
- Rebuild failure after save attempts bounded old-config compensation。
- Compensation never claims full macOS topology rollback。
- `VoidDisplayRuntime` boundary greps pass。
- Targeted tests and Xcode Debug build pass with zero warnings。

## Notes For Phase 3b Master Plan

`docs/display-runtime-phase-3b-plan.md` already contains the correct high-level Phase 3b.2 direction: edit rebuild saves config before quiesce, save failure stops, rebuild command failure attempts old config compensation, save-only edit remains outside transaction, and the old Save and Rebuild double path must be deleted。

Recommended later sync:

- Add a link from `docs/display-runtime-phase-3b-plan.md` to this detailed Phase 3b.2 plan。
- Mark Phase 3b.1 enable / disable as completed if the project wants the master plan to track slice status。
- Do not duplicate the full details from this file into the master plan。
