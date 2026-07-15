# DisplayRuntime Phase 3b: Virtual Display Command Transactions

状态：已完成历史记录
依据：[产品定位与架构重构前置结论](./product-positioning.md)、[DisplayRuntime 重构执行计划](./display-runtime-refactor-plan.md)、[DisplayRuntime Phase 1 执行计划](./display-runtime-phase-1-plan.md)、[DisplayRuntime Phase 2 执行记录](./display-runtime-phase-2-plan.md)、[DisplayRuntime Phase 3 计划与 Phase 3a rebuild transaction baseline](./display-runtime-phase-3-plan.md)
基线：当前 HEAD `239c3733`
范围：只规划 Phase 3b 如何把更多 virtual display commands 迁入 `DisplayRuntime` transaction。本文档不实现代码。
归档说明：Phase 3b 已完成，属于 Phase 3 的拆分历史记录。本文不再作为当前待办清单。
导航：当前阅读顺序见 [DisplayRuntime 文档索引](./display-runtime-index.md)。

## Summary

Phase 3b 将 Phase 3a 的 rebuild transaction 扩展到更多会改变 virtual display 生命周期、配置持久化和拓扑事实的命令。迁移顺序固定为：

1. enable / disable transaction
2. edit with rebuild-required changes transaction
3. create / delete transaction
4. startup restore transaction

enable / disable 应先接管。它们直接改变 runtime display lifecycle，disable 会让现有 display id 失效，enable 会创建或重建 runtime display，并且两者都会影响 sharing、monitoring、catalog convergence 和 topology stability。继续让 row toggle 直接调用 `VirtualDisplayController` / `VirtualDisplayFacade` 会把 display lifecycle 的事实源留在 runtime transaction 外面。

Phase 3b 的核心目标：

- 将现有 rebuild-only queue 泛化成 virtual display transaction queue。
- 让 runtime 统一记录 pre evidence、affected surfaces、quiesce、virtual display command、post topology wait、restore / deferred restore、failure、compensation 和 observability trace。
- 把 UI controller 降为 presentation adapter，不再拥有 virtual display command 事实判断。
- 删除被迁移命令的旧直接入口，不留下长期兼容层或双路径。

## Current State

Phase 3a 后，`DisplayRuntime` 已经拥有 rebuild transaction 的主体能力：

- `DisplayRuntimeSnapshot.schemaVersion == 2`。
- snapshot 包含 `transactions.activeTransactions` 和 `transactions.recentTransactions`。
- `DisplayRuntimeTransactionKind` 当前只有 `virtualDisplayRebuild`。
- `DisplayRuntime.rebuildVirtualDisplay(configID:source:)` 已经负责 queue、same-config coalescing、trace、pre evidence、affected scope、quiesce、command、post topology wait、sharing restore、monitoring restore intent-only evidence。
- `DisplayRuntimeVirtualDisplayCommanding.rebuildVirtualDisplay(configID:)` 通过 App adapter 调用 `VirtualDisplayController.rebuildVirtualDisplay(configId:)`，避开 `startRebuildFromSavedConfig` presentation wrapper。
- `DisplayRuntimeSharingCommanding.restoreSharing(displayID:)` 已经在 App 层解析 `SCDisplay` 并调用 sharing controller。
- monitoring restore 默认只写 intent 和 skipped result，原因是 Phase 4 consumer lease 还没有接管 monitor demand。

仍在 runtime transaction 外的 virtual display command 入口：

- `VirtualDisplayListViewModel.toggleDisplayState(_:)` 直接通过 dependencies 调用 `disableDisplayByConfig` 或 `enableDisplay`。
- `VirtualDisplayController.disableDisplayByConfig(_:)` 直接调用 facade disable，并记录 presentation event。
- `VirtualDisplayController.enableDisplay(_:)` 直接调用 facade enable，并记录 presentation event。
- `EditVirtualDisplayConfigView.performSaveAndRebuild(_:)` 先调用 `virtualDisplay.updateConfig(...)`，再调用 `virtualDisplay.startRebuildFromSavedConfig(...)`。
- `CreateVirtualDisplay.createDisplayAction()` 直接调用 `virtualDisplay.createDisplay(...)`。
- `VirtualDisplayListViewModel.confirmDelete()` 直接调用 `destroyDisplay`。
- `AppBootstrap.makeEnvironment` 在 startup path 直接调用 `virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()`。

底层 ownership 当前仍然合理，Phase 3b 不移动这些底层能力：

- `VirtualDisplayOrchestrator` 负责 config persistence、driver runtime handle、teardown settlement、enable create retries、main display policy、topology repair、restore desired configs。
- `VirtualDisplayConfigManager` 负责 config collection、save、load、reset、append、update、remove、desired enabled persistence。
- `VirtualDisplayRuntimeTracker` 负责 runtime handles、display id mapping、generation、active serials、runtime clear / rollback。
- `DisplayRebuildCoordinator` 负责 existing rebuild, fleet rebuild and topology repair algorithm。

## Phase 3a Baseline

Phase 3b 必须建立在这些 Phase 3a 事实之上，不能回退：

- Runtime transaction 是 virtual display lifecycle command 的事实源。
- Runtime pre snapshot 前运行 transaction-scoped catalog refresh。
- Runtime pre evidence 不能包含 recursive transaction section。
- Runtime affected scope 基于 `DisplaySurfaceIdentity.managedVirtualDisplay(configID:)` 和 DTO，不基于 SwiftUI state。
- Runtime 先 quiesce affected display-level sharing / monitoring，再调用 virtual display command。
- Runtime post-command 只等待 catalog DTO stability，不复制 `DisplayRebuildCoordinator` 内部 topology repair。
- Runtime restore sharing 前必须完成 shareable display registration convergence。
- Runtime 不恢复 viewer connection，不保存 WebRTC peer session。
- Runtime monitoring restore 仍然 intent-only，除非 Phase 4 consumer lease 已提供可证明 demand owner。
- `VoidDisplayRuntime` 不导入 SwiftUI、AppKit、Observation、ScreenCaptureKit、VoidDisplayApp、VoidDisplayCapture、VoidDisplaySharing、VoidDisplayVirtualDisplay、VoidDisplayDesignSystem。
- `VoidDisplayRuntime` 不持有 `SCDisplay`、`SCStream`、`CMSampleBuffer`、`CVPixelBuffer`、WebRTC session、driver handle、`VirtualDisplayRuntimeHandling`。
- `VoidDisplayVirtualDisplay` 不依赖 `VoidDisplayRuntime`。
- App adapters 位于 `VoidDisplayApp/Composition`，负责把 runtime ports 映射到 app controllers and services。

## Scope And Non-goals

Phase 3b 范围：

- enable / disable transaction。
- edit with rebuild-required changes transaction。
- create / delete transaction。
- startup restore transaction。
- Runtime transaction model and trace DTO expansion。
- Runtime virtual display command port expansion。
- App adapter expansion。
- UI command adapters that keep existing UI shape but forward migrated commands into runtime。
- Tests and boundary gates needed to prove no double path remains。

Phase 3b 非目标：

- 不改 capture frame pipeline。
- 不改 ScreenCaptureKit capture engine、preview sink、frame fanout、sample delivery。
- 不改 WebRTC signaling、publisher session、RelaySessionHub、ICE / offer / answer flow。
- 不改 LAN Web View route、shareID assignment、安全模型、鉴权模型。
- 不引入 token、password、account、remote auth。
- 不把 `SCDisplay`、`SCStream`、`CMSampleBuffer`、`CVPixelBuffer`、WebRTC session、driver handle 放进 `VoidDisplayRuntime`。
- 不让 `VoidDisplayVirtualDisplay` import `VoidDisplayRuntime`。
- 不重写 `DisplayRebuildCoordinator`、`VirtualDisplayRuntimeTracker` 或 CGVirtualDisplay driver layer。
- 不实现 Phase 4 consumer lease。
- 不恢复 monitor window、old monitoring session id、old viewer connection。
- 不保留长期兼容层。

## Proposed Slices

Slice 3b.1: enable / disable transaction。

- 新增 runtime API：`setVirtualDisplayDesiredEnabled(configID:enabled:source:)` 或等价的 explicit enable / disable APIs。
- Add transaction kinds `virtualDisplayEnable` and `virtualDisplayDisable`。
- Runtime 使用同一 virtual display transaction queue。enable / disable、rebuild、edit rebuild、delete 对同一 config 串行。不同 config 在 Phase 3b 仍默认串行，因为 enable can create main display shifts and fleet repair。
- Enable command 必须有 preflight / command result DTO 明确报告 `mayPerformFleetRebuild` 和 `requiresFleetQuiesce`。Adapter 可以通过 lower-layer policy preflight、current runtime snapshot、pending aggressive recovery flag 或 command result 报告该风险；如果 adapter 无法证明 enable 只影响 target config，runtime 必须按 `requiresFleetQuiesce == true` 处理。
- disable flow：
  1. transaction-scoped catalog refresh。
  2. capture pre evidence。
  3. resolve affected target surface, fleet only if current main display policy proves target disable can disturb managed main ownership。
  4. quiesce sharing / monitoring for affected display ids。
  5. call virtual display command port disable。
  6. wait bounded topology DTO settlement。
  7. never restore the disabled target; write restore result `skipped` with reason `target_disabled` for any target demand。
  8. restore affected peer sharing only when topology is stable, the peer is still running, and the peer display id resolves after post-command convergence。
  9. keep affected peer monitoring restore intent-only with deferred reason until consumer lease exists。
  10. when topology is degraded, write peer restore skip reason `topology_<status>`。
  11. write trace and refresh observability。
- enable flow：
  1. transaction-scoped catalog refresh。
  2. capture pre evidence。
  3. run enable preflight through the virtual display command adapter before quiesce。
  4. if runtime cannot prove target-only impact, expand affected scope to all running managed virtual displays and record `scope_escalated_enable_may_perform_fleet_rebuild`。
  5. quiesce sharing / monitoring for every affected peer display id before calling enable。
  6. call virtual display command port enable。
  7. wait bounded topology DTO stability for target and affected peers。
  8. run visible convergence after stable DTO。
  9. restore peer sharing under the same Phase 3a rules when topology is stable and the peer still resolves to a running managed display。
  10. keep peer monitoring restore intent-only with deferred reason until consumer lease exists。
  11. write trace and refresh observability。
- Save failure before enable / disable command blocks runtime side effects and marks transaction failed。
- Enable failure after `desiredEnabled = true` keeps desired intent true, preserves current lower-layer semantics, and records runtime creation failure as degraded / retryable evidence。
- Disable success removes running runtime state and leaves desired intent false。
- Delete old direct row toggle path in this slice. `VirtualDisplayListViewModel` must no longer call facade-backed enable / disable directly。

Slice 3b.2: edit with rebuild-required changes transaction。

- Add transaction kind `virtualDisplayEditRebuild`。
- UI validation and draft analysis can stay in `VoidDisplayVirtualDisplay`, but the actual Save and Rebuild command becomes one runtime request。
- Replace current sequence:
  - `updateConfig(updatedConfig)`
  - `startRebuildFromSavedConfig(configID, .editSaveAndRebuild)`
- New transaction flow:
  1. capture pre evidence, including old config DTO and current display id。
  2. call command port to persist updated config。
  3. if save fails, stop immediately, no quiesce, no rebuild, trace `config_save_failed`。
  4. derive affected scope from pre evidence and updated config。
  5. quiesce existing sharing / monitoring for affected display ids。
  6. call existing rebuild command for config id。
  7. wait topology stability and visible convergence。
  8. restore sharing if safe; record monitoring intent only。
  9. write trace with persistence outcome and rebuild outcome。
- Rebuild failure after successful save requires explicit compensation:
  - Try to persist old config back through command port。
  - If old config restore succeeds and the affected surface can be safely resolved, run one bounded compensation rebuild using old config。
  - If compensation rebuild fails, keep the restored old config if it was saved successfully, mark transaction failed with degraded compensation。
  - If old config persistence fails, mark `persistence_compensation_failed` and do not fake restored state。
- Save-only edit remains outside this transaction when `VirtualDisplayEditSaveAnalyzer.requiresSaveAndRebuild == false`。
- Immediate mode apply for non-rebuild edits remains a presentation / virtual display target command path until a later phase; it is not a Phase 3b transaction unless it changes runtime display lifecycle。
- Delete old Save and Rebuild double path in this slice。

Slice 3b.3: create / delete transaction。

- Add transaction kinds `virtualDisplayCreate` and `virtualDisplayDelete`。
- Create transaction:
  1. use global inventory queue key until command returns a config id。
  2. validate request in UI target using existing validator before sending runtime command。
  3. runtime captures pre inventory evidence。
  4. command port calls existing create command, which appends config and creates runtime display。
  5. command result reports config id, serial, persistence outcome, runtime creation outcome, rollback outcome if used。
  6. runtime waits topology stability for created managed surface when creation succeeds。
  7. runtime writes trace with redacted display name and serial metadata。
- Create compensation:
  - If runtime creation fails after config append, command adapter must rely on existing rollback behavior and report rollback success / failure。
  - If rollback fails, transaction records `persistenceRecoveryFailed` and reports unrecoverable persistence compensation failure。
  - Runtime does not attempt driver-handle rollback itself。
- Delete transaction:
  1. refresh catalog and capture pre evidence。
  2. resolve target surface and display id。
  3. quiesce sharing / monitoring for target display id。
  4. call command port delete。
  5. command removes persisted config and clears runtime tracking through existing lower layer。
  6. wait bounded topology settlement if target was running。
  7. do not restore sessions for deleted surface。
  8. clear rebuild presentation state for deleted config through presentation adapter after transaction terminal result。
- Delete failure rules:
  - If persistence delete fails before runtime tracking is cleared, no runtime side effects should occur。
  - If runtime clear happens after successful persistence delete, deleted config remains deleted; failures are recorded as degraded side-effect evidence。
  - No legacy delete direct path may remain reachable from `VirtualDisplayListViewModel.confirmDelete()` after this slice。

Slice 3b.4: startup restore transaction。

- Add transaction kind `virtualDisplayStartupRestore`。
- Replace `AppBootstrap.makeEnvironment` direct call to `virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()` with runtime startup restore after adapters and snapshot providers are ready。
- Preserve existing XCTest skip behavior: default `isRunningUnderXCTest` startup plan still skips restore unless test explicitly opts in。
- Startup restore flow:
  1. runtime records startup transaction active。
  2. command port loads persisted configs。
  3. command port restores desired virtual displays through existing lower layer。
  4. runtime captures per-config restore success / failure evidence。
  5. runtime runs one catalog refresh and visible convergence after restore。
  6. runtime writes restore trace and refreshes observability。
- Startup restore should be later than create / delete because its timing is special:
  - It runs during app composition, before normal UI interaction。
  - It must not race snapshot provider registration。
  - It must preserve tests that skip restore under XCTest。
  - Its trace must represent a batch operation with per-config evidence, not a row command。

## Transaction Model Changes

Generalize rebuild-only transaction state into a command-family model:

```text
DisplayRuntimeTransactionKind
  virtualDisplayRebuild
  virtualDisplayEnable
  virtualDisplayDisable
  virtualDisplayEditRebuild
  virtualDisplayCreate
  virtualDisplayDelete
  virtualDisplayStartupRestore
```

Add or reuse sources:

```text
DisplayRuntimeTransactionSource
  virtualDisplayRowRetry
  editSaveAndRebuild
  virtualDisplayRowToggle
  createVirtualDisplaySheet
  deleteVirtualDisplayConfirmation
  appStartupRestore
  diagnostics
  unknown
```

Add phases only if existing phases cannot express the flow:

```text
DisplayRuntimeTransactionPhase
  queued
  preparing
  persistingConfig
  quiescingSessions
  executingVirtualDisplayCommand
  waitingForTopology
  restoringSessions
  compensatingPersistence
  completed
  failed
  cancelled
```

The implementer may keep `executingVirtualDisplayCommand` as the common command phase. Do not create one phase per command kind unless tests require more precise trace assertions.

Queue rules:

- Use one virtual display transaction queue in Phase 3b.
- Same config and same command kind can coalesce only for idempotent duplicate requests: rebuild while rebuild active, enable while already enabling, disable while already disabling。
- Opposite commands never coalesce. Enable followed by disable serializes and re-reads snapshot before executing。
- Create uses an inventory-level key until a config id exists。
- Startup restore uses an app-startup inventory-level key and blocks create / delete / enable / disable until complete。
- Viewer attach、monitor attach、frame fanout、WebRTC signaling never enter this queue。

Trace evidence additions:

- `persistenceOutcome`: notAttempted, saved, failed, rolledBack, rollbackFailed。
- `virtualDisplayCommandOutcome`: notAttempted, succeeded, failed, invalidated, partiallySucceeded。
- `topologyOutcome`: existing `DisplayRuntimeTopologyStabilityResult`。
- `compensation`: extend existing `DisplayRuntimeCompensationResult` with persistence compensation counts or add a sibling DTO。
- `scopeEscalationReason`: nil for target-only commands; values include `target_disabled`, `managed_main_policy_risk`, `enable_may_perform_fleet_rebuild`, and `scope_escalated_enable_may_perform_fleet_rebuild`。
- `redactedConfigEvidence`: config id, serial, desiredEnabled, mode count, max pixel dimensions, physical dimensions. Do not store display name in default trace export。

Failure semantics:

- Persistence failure before command means no runtime side effect should happen。
- Runtime command failure after persistence success must record persistence result and compensation attempt。
- Topology unprovable due to permission never becomes virtual display command failure。
- Restore failure after successful command becomes `completedWithRecoveryFailures` unless the command itself failed。
- Runtime never promises full rollback of macOS display topology。

## Port / Adapter Changes

Extend `DisplayRuntimeVirtualDisplayCommanding` with command-shaped DTO APIs. Exact names can be adjusted during implementation, but command separation must remain clear:

```text
enableVirtualDisplay(request) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult
disableVirtualDisplay(request) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult
saveConfigForRebuild(request) async throws -> DisplayRuntimeVirtualDisplayPersistenceCommandResult
restoreConfigAfterFailedEdit(request) async throws -> DisplayRuntimeVirtualDisplayPersistenceCommandResult
createVirtualDisplay(request) async throws -> DisplayRuntimeVirtualDisplayCreateCommandResult
deleteVirtualDisplay(request) async throws -> DisplayRuntimeVirtualDisplayDeleteCommandResult
loadPersistedVirtualDisplayConfigs() async throws -> DisplayRuntimeVirtualDisplayLoadCommandResult
restoreDesiredVirtualDisplays() async throws -> DisplayRuntimeVirtualDisplayStartupRestoreCommandResult
```

Enable preflight and command result DTO constraints:

- `DisplayRuntimeVirtualDisplayEnablePreflight` must include `configID`, `targetPreDisplayID`, `mayPerformFleetRebuild`, `requiresFleetQuiesce`, and `scopeEscalationReason`。
- `DisplayRuntimeVirtualDisplayLifecycleCommandResult` for enable must repeat `mayPerformFleetRebuild` and `requiresFleetQuiesce` so trace can prove whether command behavior matched preflight。
- Runtime must treat missing or unknown fleet risk fields as `requiresFleetQuiesce == true`。
- Affected-scope evidence must include whether each surface is the target or a peer, plus the scope escalation reason that pulled the peer into the transaction。
- Adapter must not hide a lower-layer fleet rebuild behind a target-only result. If `VirtualDisplayOrchestrator.enableDisplay` may call `rebuildManagedDisplayFleet`, the adapter reports that as fleet risk before runtime quiesce。

DTO rules:

- Runtime DTOs can contain primitive config data: UUID, serial, desiredEnabled, physical width / height, max pixels, modes。
- Runtime DTOs must be `Codable`, `Equatable`, `Sendable` where stored in traces or snapshots。
- Runtime DTOs must not contain `VirtualDisplayConfig`, `ResolutionSelection`, `CGSize`, `SCDisplay`, `CGVirtualDisplay`, driver handles, controller references, closures, or target-local enums。
- App adapter maps between runtime DTOs and `VoidDisplayVirtualDisplay` models。
- App adapter may use `CGSize`, `VirtualDisplayConfig`, and `ResolutionSelection` internally because it lives in `VoidDisplayApp` and already imports both sides。

Adapter deletion conditions:

- `DisplayRuntimeVirtualDisplayAdapter` remains required as composition boundary. Delete only if a future pure virtual display engine target exposes legal Sendable service protocols that `VoidDisplayRuntime` can depend on without UI, driver handles, AppKit, ScreenCaptureKit, or `VoidDisplayVirtualDisplay`。
- Runtime-backed row toggle executor is temporary. Delete when `VirtualDisplayListViewModel` no longer owns command execution and row controls invoke App/runtime action dependencies directly。
- Runtime-backed edit rebuild executor is temporary. Delete when edit view actions use a runtime-backed command dependency instead of calling `VirtualDisplayController` command wrappers。
- Runtime-backed create/delete executors are temporary. Delete when create sheet and delete confirmation are wired to runtime action dependencies。
- Startup restore adapter is temporary only as a bootstrap bridge. Delete when App bootstrap can invoke runtime restore directly and no `VirtualDisplayController.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()` call remains。

Command adapter failure rules:

- Command adapters must never silently no-op when weak controller is unavailable。
- Adapter unavailable is a command failure and must enter transaction trace。
- Provider adapters may still return empty snapshots when unavailable, matching existing provider behavior。
- App adapter must not call presentation wrappers such as `startRebuildFromSavedConfig` for command execution。

## UI Adapter Migration Strategy

Phase 3b keeps UI information architecture but moves command ownership.

Methods that become presentation adapters:

- `VirtualDisplayController.enableDisplay(_:)`
- `VirtualDisplayController.disableDisplayByConfig(_:)`
- `VirtualDisplayController.createDisplay(...)`
- `VirtualDisplayController.destroyDisplay(_:)`
- `VirtualDisplayController.startRebuildFromSavedConfig(configId:source:)`
- `VirtualDisplayController.retryRebuild(configId:)`
- `VirtualDisplayController.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()`

Methods that may remain as non-transaction presentation or low-risk actions:

- `VirtualDisplayController.updateConfig(_:)` for save-only edits that do not require rebuild。
- `VirtualDisplayController.applyModes(configId:modes:)` for immediate mode updates that do not rebuild or recreate display lifecycle。
- reorder / set primary methods until a later phase decides whether main policy reconcile should become a transaction。
- reset all virtual display data remains outside Phase 3b unless explicitly scoped later。

Old entries to delete or make unreachable:

- `VirtualDisplayListViewModel.Dependencies.disableDisplayByConfig` direct facade command after 3b.1。
- `VirtualDisplayListViewModel.Dependencies.enableDisplay` direct facade command after 3b.1。
- `EditVirtualDisplayConfigView.performSaveAndRebuild` sequence of `updateConfig` then `startRebuildFromSavedConfig` after 3b.2。
- `CreateVirtualDisplay.createDisplayAction` direct call to `virtualDisplay.createDisplay` after 3b.3。
- `VirtualDisplayListViewModel.Dependencies.destroyDisplay` direct facade command after 3b.3。
- `AppBootstrap` direct call to `virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()` after 3b.4。

Presentation rules:

- UI loading / spinner state may still live in `VirtualDisplayController` and `VirtualDisplayListViewModel` during Phase 3b, but terminal state must wait for runtime transaction result。
- UI should map command failure to existing user-facing alerts。
- Partial recovery failure after successful virtual display command should not be shown as the same failure class as command failure. It belongs in diagnostics / transaction trace unless product UI explicitly exposes it。
- For delete success, clear rebuild presentation state only after runtime delete transaction reaches terminal success。
- For edit rebuild failure, keep edit failure presentation tied to command failure, not restore degradation。

## Observability / Diagnostics Changes

Transaction trace must be the primary diagnostics record for Phase 3b commands.

Required trace facts:

- transaction id。
- transaction kind。
- source。
- queue / coalescing evidence。
- affected surfaces。
- pre evidence。
- post evidence。
- persistence outcome。
- virtual display command outcome。
- topology stability result。
- quiesce intents。
- restore intents and restore results。
- compensation outcome。
- failure reason and recoverability。

Redaction rules:

- Do not write display name into default trace metadata。
- Do not write LAN IP, full URL, desktop contents, window titles, local user paths, raw viewer client ids, WebRTC SDP, ICE candidates, sample buffers, or pixel buffers。
- Serial number and config id may be included because they are already used for diagnostics and do not expose content。

Observability event rules:

- Use `display_runtime` domain for transaction phase changes。
- Keep existing `screen_catalog` events for catalog permission and catalog refresh behavior。
- Emit snapshot refresh reason `displayRuntimeTransactionChanged` for transaction phase and terminal result。
- Startup restore transaction must be visible in the startup observability snapshot. Register runtime snapshot provider before running restore transaction, or explicitly run a final snapshot refresh after restore completes。

Diagnostics shape:

- Recent transaction list remains bounded, default N=20 unless implementation has a proven reason to change it。
- Evidence must stay value-only and transaction-section-free to avoid recursive snapshots。
- Create / edit trace should include config shape summary: serial, desiredEnabled, mode count, max pixel dimensions, physical dimensions。
- Startup restore trace should include per-config restore result summary, not one opaque batch status。

## Test Plan

Runtime tests:

- enable transaction success records pre evidence, command success, topology wait, post evidence, and trace kind。
- enable transaction save failure records failed persistence outcome and does not call runtime creation command。
- enable transaction command failure after desired intent is saved keeps desired enabled intent in command result and marks degraded / retryable。
- enable transaction preflight with `mayPerformFleetRebuild` or `requiresFleetQuiesce` expands affected scope to all running managed virtual displays。
- enable transaction with unknown fleet risk conservatively quiesces all running managed virtual display peers。
- enable transaction restores peer sharing after stable topology when the peer is still running and display id resolves。
- enable transaction records peer monitoring restore as deferred intent-only evidence。
- enable transaction trace records scope escalation reason `scope_escalated_enable_may_perform_fleet_rebuild`。
- disable transaction quiesces sharing and monitoring before command。
- disable transaction never restores sessions for disabled target and records `target_disabled`。
- disable transaction restores affected peer sharing after stable topology when the peer still runs and resolves。
- disable transaction records peer monitoring restore as deferred until consumer lease。
- disable transaction writes peer restore skip reason `topology_<status>` under degraded topology。
- disable transaction handles missing config as failed trace without command。
- enable then disable for same config serializes and re-reads state。
- duplicate enable while active coalesces only when command kind and config match。
- edit rebuild transaction saves config before quiesce and rebuild。
- edit save failure does not quiesce and does not rebuild。
- edit rebuild command failure attempts old config persistence compensation。
- edit compensation save failure records `persistence_compensation_failed`。
- edit compensation rebuild failure records degraded compensation。
- edit success follows Phase 3a sharing restore and monitoring intent-only rules。
- create transaction records config creation and runtime side-effect result。
- create runtime creation failure with rollback success records failed command and compensated persistence。
- create runtime creation failure with rollback failure records `persistenceRecoveryFailed`。
- delete transaction quiesces before command and never restores deleted surface sessions。
- delete persistence failure does not clear runtime tracking。
- startup restore loads persisted configs and records per-config restore evidence。
- startup restore does not run when XCTest startup plan skips restore。
- startup restore runs after runtime snapshot provider registration in App bootstrap tests。
- no transaction stores forbidden runtime types。
- transaction evidence does not recursively include transactions。

Adapter tests:

- enable adapter calls command-only controller/facade path, not row toggle presentation wrapper。
- disable adapter calls command-only controller/facade path。
- edit save adapter maps runtime DTO to `VirtualDisplayConfig` in App layer。
- edit restore-old-config adapter maps old config DTO and reports persistence failure。
- create adapter maps primitive DTO into existing create command and reports created config id。
- delete adapter calls command-only delete path and reports whether the target was running。
- startup restore adapter calls load and restore commands and reports restore failures。
- all command adapters fail explicitly when weak controller is unavailable。
- adapters never expose `SCDisplay` or `VirtualDisplayRuntimeHandling` to runtime DTOs。

UI tests / controller tests:

- row toggle loading state waits for runtime transaction terminal result。
- row enable failure shows existing Enable Failed alert。
- row disable failure shows existing Disable Failed alert。
- Save and Rebuild no longer calls `updateConfig` followed by `startRebuildFromSavedConfig`。
- Save and Rebuild uses runtime-backed edit rebuild executor。
- create sheet closes only after create transaction succeeds。
- delete confirmation clears candidate only after delete transaction succeeds。
- startup restore alert for restore failures still appears when restore transaction records failures。

Existing lower-layer tests to keep:

- `VirtualDisplayOrchestratorLightTests`
- `VirtualDisplayConfigManagerTests`
- `VirtualDisplayRuntimeTrackerTests`
- `DisplayRebuildCoordinatorTests`
- `DisplayTeardownCoordinatorTests`
- `DisplayTeardownCoordinatorOfflineWaitTests`
- `VirtualDisplayTopologyRecoveryTests`
- `DisplayRuntimeCatalogControlTests`
- `ObservabilitySnapshotProviderTests`
- `AppBootstrapTests`

## Build / Boundary Gates

3b.1 targeted verification:

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter VirtualDisplayControllerTests
scripts/ci/unit.sh --filter VirtualDisplayListViewModelTests
scripts/ci/unit.sh --filter SharingControllerTests
scripts/ci/unit.sh --filter SharingServiceTests
scripts/ci/unit.sh --filter CaptureControllerTests
scripts/ci/unit.sh --filter CaptureMonitoringLifecycleServiceTests
scripts/ci/unit.sh --filter AppBootstrapTests
scripts/ci/xcode.sh --action build --configuration Debug
```

Final Phase 3b verification:

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter VirtualDisplayControllerTests
scripts/ci/unit.sh --filter VirtualDisplayListViewModelTests
scripts/ci/unit.sh --filter SharingControllerTests
scripts/ci/unit.sh --filter SharingServiceTests
scripts/ci/unit.sh --filter CaptureControllerTests
scripts/ci/unit.sh --filter CaptureMonitoringLifecycleServiceTests
scripts/ci/unit.sh --filter VirtualDisplayOrchestratorLightTests
scripts/ci/unit.sh --filter VirtualDisplayConfigManagerTests
scripts/ci/unit.sh --filter VirtualDisplayRuntimeTrackerTests
scripts/ci/unit.sh --filter DisplayRebuildCoordinatorTests
scripts/ci/unit.sh --filter DisplayTeardownCoordinatorTests
scripts/ci/unit.sh --filter DisplayTeardownCoordinatorOfflineWaitTests
scripts/ci/unit.sh --filter DisplayRuntimeCatalogControlTests
scripts/ci/unit.sh --filter ObservabilitySnapshotProviderTests
scripts/ci/unit.sh --filter AppBootstrapTests
scripts/ci/xcode.sh --action build --configuration Debug
```

Boundary guards:

```sh
if rg -n "import (SwiftUI|AppKit|Observation|VoidDisplayDesignSystem|VoidDisplayApp|VoidDisplayCapture|VoidDisplaySharing|VoidDisplayVirtualDisplay|ScreenCaptureKit)" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "\\b(SCStream|SCDisplay|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession|DisplayCaptureSession|VirtualDisplayRuntimeHandling)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "import VoidDisplayRuntime" Sources/VoidDisplayVirtualDisplay; then exit 1; fi
```

Warning gate:

```sh
scripts/ci/xcode.sh --action build --configuration Debug 2>&1 | tee .ai-tmp/display-runtime-phase-3b/xcode-build-final.log
if rg -n "warning:" .ai-tmp/display-runtime-phase-3b/xcode-build-final.log; then exit 1; fi
```

Docs-only changes to this plan do not require running Xcode build. Any code implementation of Phase 3b must pass the build and warning gates before handoff。

## Risks And Constraints

- Enable / disable are the right first migration target because they directly mutate runtime display lifecycle. Delaying them would keep the largest lifecycle mutation outside the transaction model。
- Edit rollback can restore persisted config but cannot guarantee macOS topology returns to the exact old state. The trace must say this clearly through compensation status。
- Create / delete are not atomic across persistence and runtime side effects. Compensation must be explicit, bounded, and observable。
- Startup restore has unique timing. Running it before observability provider registration can make the most important startup failure invisible to diagnostics。
- Startup restore must preserve XCTest skip behavior. Breaking this will make tests slow, flaky, or hardware-dependent。
- Old direct UI command paths are dangerous after migration because they create two facts sources. Each migrated command slice must delete or make unreachable its old path。
- Adapter sprawl is acceptable only as a composition boundary. Every temporary executor adapter needs a deletion condition。
- Runtime must not import target-local product model types just to reduce mapping code. DTO mapping in App composition is the cost of keeping the boundary correct。
- Permission-denied catalog state must degrade topology proof and restore, not block virtual display lifecycle commands that do not require ScreenCaptureKit proof。
- Monitoring restore remains intent-only until consumer lease exists. Starting invisible capture sessions in Phase 3b would violate the test permission and resource-use constraints。

## Acceptance Criteria

- `docs/display-runtime-phase-3b-plan.md` exists and contains all required sections。
- The plan states that enable / disable should migrate first and explains that they directly mutate runtime display lifecycle。
- The plan preserves the Phase 3 priority order: enable / disable, edit with rebuild-required changes, create / delete, startup restore。
- The plan defines edit persistence, save failure, rebuild failure, rollback, and compensation semantics。
- The plan defines create / delete persistence compensation and runtime side-effect evidence。
- The plan defers startup restore until after create / delete and explains timing / observability risk。
- The plan names controller methods that become presentation adapters。
- The plan names old direct entries that must be deleted or made unreachable。
- Every adapter described in the plan has a deletion condition。
- The plan explicitly keeps capture/WebRTC/frame pipeline out of scope。
- The plan explicitly keeps LAN Web View security model out of scope。
- The plan explicitly forbids `SCDisplay`、`SCStream`、`CMSampleBuffer`、`CVPixelBuffer`、WebRTC session、driver handle and `VirtualDisplayRuntimeHandling` in `VoidDisplayRuntime`。
- The plan keeps `DisplayRuntime` as control plane only。
- The plan keeps `VoidDisplayVirtualDisplay` independent from `VoidDisplayRuntime`。
- No product code is changed by this planning task。
- No commit is created unless explicitly requested。
