# DisplayRuntime Phase 3c: Runtime Internal Consolidation

状态：执行级计划
依据：[产品定位与架构重构前置结论](./product-positioning.md)、[DisplayRuntime 重构执行计划](./display-runtime-refactor-plan.md)、[DisplayRuntime Phase 1 执行计划](./display-runtime-phase-1-plan.md)、[DisplayRuntime Phase 2 执行记录](./display-runtime-phase-2-plan.md)、[DisplayRuntime Phase 3 计划与 Phase 3a rebuild transaction baseline](./display-runtime-phase-3-plan.md)、[DisplayRuntime Phase 3b 总计划](./display-runtime-phase-3b-plan.md)、[DisplayRuntime Phase 3b.2 Edit Rebuild Transaction](./display-runtime-phase-3b-2-plan.md)、[DisplayRuntime Phase 3b.3 Create / Delete Transaction](./display-runtime-phase-3b-3-plan.md)
基线：当前执行窗口必须基于包含 commit `802135000045303ff3e290b32486751aaca5bb4d` 的 HEAD。
范围：只规划 Phase 3c runtime internal consolidation。本文档不实现代码。

## Summary

Phase 3c 是 Phase 4 consumer lease 之前的结构收敛阶段。

目标是整理 Phase 3a / 3b 后集中在 `DisplayRuntime`、transaction model、runtime tests 和 App adapter 中的复杂度，给 Phase 4 留出清晰、可验证、可扩展的内部边界。

本阶段不改变产品行为。执行窗口只能做文件级、类型级、helper 级的结构拆分，保持现有 transaction 语义、错误语义、trace 语义、DTO 红线和 UI 结果映射不变。

Phase 3c 完成后再进入 Phase 4 planning。Phase 4 consumer lease 不得混入本阶段。

## Motivation

Phase 3a / 3b 已经把 rebuild、enable / disable、edit rebuild、create / delete 等 virtual display lifecycle command 迁入 runtime transaction。这个方向正确，但复杂度现在集中在少数巨型文件中：

- `DisplayRuntime.swift` 同时承载 catalog control、snapshot assembly、transaction queue、rebuild、create/delete、edit rebuild、lifecycle、topology wait、session quiesce、session restore、trace mutation 和 surface graph builder。
- `DisplayRuntimeTransaction.swift` 同时承载 transaction core、evidence、topology models、session models、lifecycle DTO、edit DTO、create/delete DTO、trace DTO 和 async gate。
- `DisplayRuntimeTests.swift` 同时覆盖 snapshot、catalog control、rebuild transaction、lifecycle transaction、edit rebuild、create/delete、queue、topology wait 和 observability provider。
- `DisplayRuntimeAdapters.swift` 同时包含 catalog、capture、sharing、virtual display、observability adapter，以及大量 runtime DTO 到 App / VirtualDisplay DTO 的 mapping。

如果 Phase 4 直接在这些文件上继续堆 consumer lease、demand aggregation、surface epoch 和 attach/detach 行为，runtime 会变成不可审计的巨型状态机。Phase 3c 的价值是先把已经成型的内部边界落到文件结构和 test support 结构上。

## Non-goals

- 不改变产品行为。
- 不实现代码功能增量。
- 不修改 UI。
- 不改 capture frame pipeline。
- 不改 WebRTC signaling、publisher session、RelaySessionHub、ICE、offer、answer 或 frame send。
- 不改 LAN Web View route、security、auth、shareID 或 viewer session。
- 不做 startup restore。
- 不实现 Phase 4 consumer lease。
- 不重写 VirtualDisplay lower layer。
- 不做大规模重命名式清理。
- 不为减少行数删除测试覆盖。
- 不保留长期兼容层。
- 不让 `VoidDisplayRuntime` 导入 App、VirtualDisplay、Capture、Sharing、ScreenCaptureKit、SwiftUI、AppKit、Observation 或 design system 类型。
- 不让 `VoidDisplayVirtualDisplay` import `VoidDisplayRuntime`。
- 不改变 App adapter owns mapping 的架构边界。

## Current Complexity Baseline

当前基线文件规模：

```text
Sources/VoidDisplayRuntime/Runtime/DisplayRuntime.swift                 2813 lines
Sources/VoidDisplayRuntime/Models/DisplayRuntimeTransaction.swift       1299 lines
Sources/VoidDisplayRuntime/Ports/DisplayRuntimePorts.swift                81 lines
Sources/VoidDisplayApp/Composition/DisplayRuntimeAdapters.swift          825 lines
Tests/VoidDisplayRuntimeTests/DisplayRuntimeTests.swift                 3429 lines
```

`DisplayRuntime.swift` 当前职责分布：

- Public runtime API：catalog appear / disappear、permission、force refresh、topology changed、sharing service state changed、snapshot、virtual display transaction APIs。
- Queue：coalesced config transaction、uncoalesced config transaction、inventory transaction。
- Transaction executors：rebuild、create、delete、edit rebuild、enable / disable。
- Recovery helpers：edit compensation、session pause、sharing restore、monitoring deferred restore、target terminal skip reason。
- Topology helpers：transaction-scoped refresh、post-command stability wait、sample comparison、permission unavailable classification。
- Scope helpers：lifecycle affected scope、enable fleet risk、managed main fleet scope、pause intent construction。
- Trace helpers：initial trace、append phase、finalize transaction、failure mapping、observability event。
- Catalog control：permission refresh、sharing catalog refresh、topology refresh queue、visible convergence。
- Snapshot graph builder：surface assembly and sorting。

`DisplayRuntimeTransaction.swift` 当前职责分布：

- Core transaction identity、kind、source、phase、status。
- Rebuild request and result。
- Edit config DTO、fingerprint、redacted evidence、save gate、restore request、persistence command result。
- Async gate and edit rebuild handle。
- Affected surface、scope escalation、persistence outcome、command outcome、runtime tracking clear outcome。
- Session pause / restore intent and result。
- Rebuild / lifecycle / create / delete command request and result models。
- Snapshot evidence、topology stability sample and result。
- Failure、recoverability、compensation、trace、transaction snapshot。

`DisplayRuntimeTests.swift` 当前 coverage clusters：

- Snapshot model and surface graph behavior。
- Provider fallback and duplicate convergence behavior。
- Rebuild transaction queue、quiesce、affected scope、topology wait、restore and trace behavior。
- Edit rebuild save gate、stale request、compensation and redaction behavior。
- Enable / disable lifecycle transaction behavior。
- Create / delete transaction command facts、redaction、missing config and restore skip behavior。
- Observability snapshot provider behavior。
- Large fake provider / commander support block at the bottom of the same file。

`DisplayRuntimeAdapters.swift` 当前 responsibilities：

- Catalog adapter provider and commander。
- Capture adapter provider and commander。
- Sharing adapter provider and commander。
- VirtualDisplay adapter provider and commander。
- Observability adapter。
- Private mapping extensions for runtime DTOs, lower VirtualDisplay DTOs, persistence outcomes, command outcomes, tracking outcomes and sharing lifecycle。

The baseline is behaviorally useful but structurally saturated. Phase 3c must split along semantic seams that already exist in the code, not invent a new architecture.

## Target Structure

Target structure is a file and helper boundary change inside existing targets. Type names can be adjusted during implementation if they preserve these responsibilities and tests.

Recommended runtime split:

```text
Sources/VoidDisplayRuntime/Runtime/
  DisplayRuntime.swift
  DisplayRuntime+CatalogControl.swift
  DisplayRuntime+Snapshot.swift
  DisplayRuntime+VirtualDisplayQueue.swift
  DisplayRuntime+VirtualDisplayRebuild.swift
  DisplayRuntime+VirtualDisplayLifecycle.swift
  DisplayRuntime+VirtualDisplayEditRebuild.swift
  DisplayRuntime+VirtualDisplayCreateDelete.swift
  DisplayRuntime+TopologyWait.swift
  DisplayRuntime+SessionQuiesceRestore.swift
  DisplayRuntime+TransactionTrace.swift
  DisplaySurfaceGraphBuilder.swift
```

Candidate boundaries for `DisplayRuntime.swift`:

- Transaction queue：active key/context types, coalescing, inventory enqueue, serial tail management。
- Topology wait：transaction-scoped catalog refresh, bounded stability wait, sample comparison, permission unavailable classification。
- Session quiesce：pause intent construction, command ordering, display-level stop commands。
- Session restore：restore intent construction, sharing restore, monitoring deferred result, target skip reason handling。
- Session restore for delete / disable must keep `target_deleted` and `target_disabled` semantics distinct。
- Virtual display rebuild executor。
- Virtual display lifecycle executor for enable / disable。
- Edit rebuild executor and compensation。
- Create / delete executor and command fact recording。
- Lifecycle and trace helper functions。
- Snapshot and surface graph builder。

Recommended transaction model split:

```text
Sources/VoidDisplayRuntime/Models/
  DisplayRuntimeTransactionCore.swift
  DisplayRuntimeTransactionEvidence.swift
  DisplayRuntimeTransactionTopology.swift
  DisplayRuntimeTransactionSessions.swift
  DisplayRuntimeTransactionRebuildModels.swift
  DisplayRuntimeTransactionLifecycleModels.swift
  DisplayRuntimeTransactionEditModels.swift
  DisplayRuntimeTransactionCreateDeleteModels.swift
  DisplayRuntimeTransactionTrace.swift
```

Candidate boundaries for `DisplayRuntimeTransaction.swift`:

- Core：transaction id、kind、source、phase、status。
- Evidence：snapshot evidence, affected surface, scope escalation, failure, recoverability, compensation。
- Rebuild models：rebuild request, rebuild command result, rebuild transaction result。
- Lifecycle models：desired enabled command request/result, preflight, lifecycle command request/result。
- Edit models：edit config DTO, fingerprint, redacted config evidence, save gate, edit rebuild handle, save/restore command models。
- Create/delete models：create request/evidence/command result/error/transaction result, delete request/command result/error/transaction result, runtime tracking clear outcome。
- Topology models：stability sample, managed display sample, status, result。
- Session models：pause intent, restore intent, restore kind/status/result, sharing restore command result。

Recommended runtime test split:

```text
Tests/VoidDisplayRuntimeTests/
  DisplayRuntimeSnapshotTests.swift
  DisplayRuntimeCatalogControlTests.swift
  DisplayRuntimeRebuildTransactionTests.swift
  DisplayRuntimeLifecycleTransactionTests.swift
  DisplayRuntimeEditRebuildTransactionTests.swift
  DisplayRuntimeCreateDeleteTransactionTests.swift
  DisplayRuntimeQueueTests.swift
  DisplayRuntimeTopologyWaitTests.swift
  DisplayRuntimeObservabilityTests.swift
  TestSupport/
    DisplayRuntimeTestSupport.swift
    DisplayRuntimeFakePorts.swift
    DisplayRuntimeCommandResultFactory.swift
    DisplayRuntimeSnapshotFactory.swift
```

Candidate boundaries for `DisplayRuntimeTests.swift`:

- Snapshot：surface identity, physical auxiliary, share route identity, sorting, duplicate port convergence, unavailable providers。
- Catalog control：permission, refresh, sharing service state, visible convergence。
- Rebuild transaction：quiesce, missing config, fleet scope, recovery failures, restore skip, permission unprovable。
- Lifecycle transaction：enable/disable persistence, preflight, fleet risk, target skip, serialization and coalescing。
- Edit rebuild transaction：save gate, stale request, save failure, compensation, redaction, no coalescing。
- Create/delete transaction：create facts, rollback evidence, redaction, topology degradation, delete quiesce, missing config, `target_deleted`。
- Queue：same config coalescing, uncoalesced create/delete/edit behavior, cross-kind serialization, re-read state on turn start。
- Topology wait：sample stability, mapping changes, visible display changes, permission unavailable, timeout。
- Runtime test support：fake commander, fake ports, snapshot builders, command result construction。

Recommended adapter split:

```text
Sources/VoidDisplayApp/Composition/
  DisplayRuntimeCatalogAdapter.swift
  DisplayRuntimeCaptureAdapter.swift
  DisplayRuntimeSharingAdapter.swift
  DisplayRuntimeVirtualDisplayAdapter.swift
  DisplayRuntimeVirtualDisplayAdapter+Mapping.swift
  DisplayRuntimeObservabilityAdapter.swift
```

Adapter boundary rules:

- App adapter owns mapping between runtime DTOs and App / VirtualDisplay DTOs。
- `VoidDisplayRuntime` continues to know only ports and DTOs。
- `VoidDisplayVirtualDisplay` continues to be runtime-agnostic。
- Mapping helpers stay near App adapter code, not in runtime。
- Splitting adapters must not move business decisions from runtime into App composition。
- Splitting adapters must not introduce fallback direct paths around runtime transactions。

## Implementation Plan

Execute Phase 3c as structural checkpoints. Each checkpoint must preserve behavior and pass targeted verification before the next checkpoint starts.

### 1. Preflight

- Confirm HEAD contains `802135000045303ff3e290b32486751aaca5bb4d`。
- Record current `git status --short`。
- Run a starting targeted runtime verification only if the execution window has not already received a fresh baseline after the latest tracked change。
- Do not create product behavior changes in this step。

### 2. Split Runtime Snapshot And Catalog Control

- Move `DisplaySurfaceGraphBuilder` into its own runtime file。
- Move `makeSnapshot()` and current provider fallback helpers into snapshot-focused extension file if doing so keeps access simple。
- Move catalog appear / disappear、permission request / refresh、force refresh、topology changed、sharing service state changed、refresh queue and visible convergence helpers into catalog control file。
- Preserve Phase 2 catalog semantics exactly。
- After this checkpoint, run targeted catalog and snapshot runtime tests, Debug build, and warning scan。

### 3. Split Transaction Queue And Trace

- Move queue key/context types and enqueue helpers into transaction queue file。
- Keep coalesced rebuild / lifecycle behavior and uncoalesced create / delete / edit behavior unchanged。
- Move `makeInitialTrace`、`appendPhase`、`incrementCoalescedRequestCount`、`finalizeTransaction`、`updateTrace`、`transactionFailure` and phase event recording into trace file。
- Preserve recent transaction cap and active-to-recent transfer behavior。
- After this checkpoint, run queue-focused runtime tests, transaction trace tests, Debug build, and warning scan。

### 4. Split Topology Wait And Session Quiesce / Restore

- Move `refreshCatalogTopologyForTransaction` and `waitForPostCommandTopology` into topology wait file。
- Move topology sample comparison helpers with the topology wait implementation。
- Move affected surface construction and pause intent construction into a quiesce/scope helper file, unless implementation proves a separate scope file is cleaner。
- Move restore intent, sharing restore and monitoring deferred result construction into restore helper file。
- Preserve `target_disabled` and `target_deleted` terminal skip reason behavior。
- Preserve Phase 3b.3 rule that topology degradation after command success becomes recovery failure, not command failure。
- After this checkpoint, run rebuild transaction, lifecycle transaction, create/delete transaction, topology wait tests, Debug build, and warning scan。

### 5. Split Virtual Display Transaction Executors

- Move rebuild executor to a rebuild transaction file。
- Move enable / disable executor to lifecycle transaction file。
- Move edit rebuild executor and compensation to edit rebuild transaction file。
- Move create / delete executors, create/delete result builders and command fact recording to create/delete transaction file。
- Keep runtime public API signatures stable unless a direct internal helper signature change is required。
- Do not introduce transitional adapters or duplicate execution paths。
- After this checkpoint, run all `VoidDisplayRuntimeTests`, adapter tests that touch runtime command results, Debug build, and warning scan。

### 6. Split Transaction Models

- Split `DisplayRuntimeTransaction.swift` into core, evidence, topology, session, rebuild, lifecycle, edit, create/delete and trace model files。
- Preserve access levels, `nonisolated`, `Codable`, `Equatable` and `Sendable` conformances。
- Preserve create display name redaction rules and edit display name transient command input rules。
- Keep public/package type names stable unless there is a local duplication that can be deleted without changing behavior。
- After this checkpoint, run `VoidDisplayRuntimeTests`, `ObservabilitySnapshotProviderTests`, Debug build and warning scan。

### 7. Split Runtime Tests And Test Support

- Move test clusters into focused files by behavior area。
- Extract reusable snapshot builders into `DisplayRuntimeSnapshotFactory` or equivalent。
- Extract fake providers and commanders into `DisplayRuntimeFakePorts` or equivalent。
- Extract command result builders for create/delete/lifecycle/edit/rebuild into a factory file。
- Delete duplicated command result construction inside individual tests after factory coverage exists。
- Do not reduce assertions, remove coverage, or collapse distinct failure cases just to reduce line count。
- After this checkpoint, run all split runtime tests, Debug build and warning scan。

### 8. Evaluate And Split DisplayRuntimeAdapters

- Split adapters by port family。
- Keep virtual display command mapping in App composition。
- Keep `VirtualDisplayConfig`、`ResolutionSelection`、lower command failures and lower command outcomes out of `VoidDisplayRuntime`。
- Verify create adapter still calls command-only create path and delete adapter still calls command-only delete path。
- Verify adapter unavailable remains explicit failure, not no-op。
- After this checkpoint, run adapter tests, `AppBootstrapTests`, runtime tests affected by command DTO mapping, Debug build and warning scan。

### 9. Final Boundary Audit

- Run static boundary checks and Phase 3b.3 old direct path grep gates。
- Run targeted tests for every touched area。
- Run full unit suite because Phase 3c is a broad structural refactor。
- Run Debug build。
- Scan build log for zero warnings and zero errors。
- Do not begin Phase 4 planning until Phase 3c passes all gates。

## Test Plan

Each code checkpoint must run targeted verification after the latest code change. A checkpoint cannot rely on pre-split test results after files or helpers are moved.

Phase 3c final closeout must additionally run the full unit suite after targeted tests:

```sh
scripts/ci/unit.sh
```

Recommended per-checkpoint commands:

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter AppBootstrapTests
scripts/ci/unit.sh --filter ObservabilitySnapshotProviderTests
scripts/ci/xcode.sh --action build --configuration Debug
```

If test files are split into narrower filters, use the narrow filters first, then run the aggregate `VoidDisplayRuntimeTests` target before handoff.

Required behavior coverage after split:

- Snapshot tests still prove managed virtual display identity uses config id。
- Physical display remains auxiliary。
- LAN Web View route identity and `DisplaySurfaceIdentity` remain separate。
- Catalog control tests still cover permission, topology and visible convergence behavior。
- Rebuild tests still prove quiesce before command, missing config trace, fleet scope, topology degradation and session restore behavior。
- Lifecycle tests still prove enable / disable persistence, fleet risk, peer restore, target skip and coalescing behavior。
- Edit rebuild tests still prove save gate, stale request, compensation and redaction behavior。
- Create/delete tests still prove create rollback facts, create display name redaction, delete `config_not_found`, delete target restore skip, and lower missing no-op is not mapped to success。
- Queue tests still prove cross-kind serialization and required coalescing / non-coalescing behavior。
- Topology wait tests still prove stable sample, permission unprovable, refresh failure and timeout behavior。
- Adapter tests still prove App adapter owns mapping and command-only paths are used。

Xcode warning / error gate for every code checkpoint:

```sh
scripts/ci/xcode.sh --action build --configuration Debug 2>&1 | tee .ai-tmp/display-runtime-phase-3c/xcode-build.log
if rg -n "warning:" .ai-tmp/display-runtime-phase-3c/xcode-build.log; then exit 1; fi
if rg -n "error:" .ai-tmp/display-runtime-phase-3c/xcode-build.log; then exit 1; fi
```

Docs-only changes to this plan do not require Xcode build. Any code implementation of Phase 3c must pass targeted tests, Debug build, zero warning gate and boundary checks before handoff.

## Boundary Checks

Runtime import boundary:

```sh
if rg -n "import (SwiftUI|AppKit|Observation|ScreenCaptureKit|VoidDisplayApp|VoidDisplayCapture|VoidDisplaySharing|VoidDisplayVirtualDisplay|VoidDisplayDesignSystem)" Sources/VoidDisplayRuntime; then exit 1; fi
```

Runtime forbidden type boundary:

```sh
if rg -n "\\b(VirtualDisplayConfig|ResolutionSelection|CGSize|SCDisplay|CGVirtualDisplay|VirtualDisplayRuntimeHandling|SCStream|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
```

Target dependency boundary:

```sh
if rg -n "import VoidDisplayRuntime" Sources/VoidDisplayVirtualDisplay; then exit 1; fi
```

Phase 3b.3 old direct path audit must remain active after structural moves:

```sh
if rg -n "virtualDisplay\\.createDisplay\\(" Sources/VoidDisplayVirtualDisplay/Views/CreateVirtualDisplayObjectView.swift; then exit 1; fi
if rg -n "controller\\.destroyDisplay\\(|dependencies\\.destroyDisplay\\(|destroyDisplay:\\s*\\{\\s*try controller\\.destroyDisplay" Sources/VoidDisplayVirtualDisplay/ViewModels/VirtualDisplayListViewModel.swift; then exit 1; fi
if rg -n "func createDisplay\\s*\\(" Sources/VoidDisplayVirtualDisplay/ViewModels/VirtualDisplayController.swift Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayFacadeProtocols.swift Sources/VoidDisplayVirtualDisplay/Services/UITestVirtualDisplayFacade.swift Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayOrchestrator.swift Tests/VoidDisplayVirtualDisplayTests/TestSupport/VirtualDisplayTestSupport.swift; then exit 1; fi
if rg -n "func destroyDisplay\\s*\\(" Sources/VoidDisplayVirtualDisplay/ViewModels/VirtualDisplayController.swift Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayFacadeProtocols.swift Sources/VoidDisplayVirtualDisplay/Services/UITestVirtualDisplayFacade.swift Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayOrchestrator.swift Tests/VoidDisplayVirtualDisplayTests/TestSupport/VirtualDisplayTestSupport.swift; then exit 1; fi
```

Create / delete command-only adapter audit:

```sh
if rg -n "DisplayRuntimeVirtualDisplayAdapter.*createDisplay\\(|DisplayRuntimeVirtualDisplayAdapter.*destroyDisplay\\(" Sources/VoidDisplayApp/Composition; then exit 1; fi
if rg -n "createDisplayCommand|deleteDisplayCommand" Sources/VoidDisplayApp/Composition; then true; else exit 1; fi
```

Phase 3c-specific boundary:

```sh
if rg -n "consumer lease|consumerLease|DisplayRuntimeConsumerLease|DisplaySurfaceLease|startup restore|startupRestore|DemandAggregation|DisplayRuntimeDemand|DisplaySurfaceEpoch|surface epoch|attachConsumer|detachConsumer|consumerDemand" Sources Tests; then exit 1; fi
```

This last grep is a planning guard. If a later implementation legitimately touches existing prose or test names containing those words, the handoff must classify it explicitly. Phase 3c must not implement those concepts.

## Acceptance Criteria

- `docs/display-runtime-phase-3c-plan.md` exists。
- The plan identifies Phase 3c as structural consolidation before Phase 4 consumer lease。
- The plan states Phase 3c does not change product behavior。
- The plan covers splitting `DisplayRuntime.swift` across transaction queue、topology wait、session quiesce、session restore、virtual display rebuild、lifecycle、edit rebuild and create/delete boundaries。
- The plan covers splitting `DisplayRuntimeTransaction.swift` across core、evidence、rebuild、lifecycle、edit、create/delete、topology、session and trace models。
- The plan covers splitting `Tests/VoidDisplayRuntimeTests/DisplayRuntimeTests.swift` across snapshot、catalog control、rebuild transaction、lifecycle transaction、edit rebuild transaction、create/delete transaction、queue and topology wait tests。
- The plan requires runtime test support consolidation for fake commander、fake ports、snapshot factories and command result construction。
- The plan requires evaluating and splitting `DisplayRuntimeAdapters.swift` while preserving App adapter owns mapping。
- The plan requires targeted tests, Debug build and zero warning gate after every code checkpoint。
- The plan preserves Phase 3b.3 boundary grep gates against old direct create/delete paths。
- The plan explicitly blocks startup restore and Phase 4 consumer lease。
- The plan does not preserve long-term compatibility layers。
- Phase 3c completion is required before Phase 4 planning starts。

## Risks And Fix Strategy

Risk: File splits accidentally change transaction ordering.
Fix strategy: Isolate queue extraction first, keep public runtime entry points stable, run queue and transaction tests immediately after the move。

Risk: Trace helpers moved out of the main runtime file silently drop fields.
Fix strategy: Keep `DisplayRuntimeTransactionTrace.replacing` behavior intact, run encoded snapshot and redaction tests after trace extraction。

Risk: Topology wait extraction changes permission-unavailable classification.
Fix strategy: Keep `unprovableDueToPermission` branch in the same helper as catalog permission detection, run topology wait and create/rebuild degradation tests。

Risk: Session restore extraction merges delete and disable target skip reasons.
Fix strategy: Keep `target_deleted` and `target_disabled` as explicit call-site inputs with tests for both。

Risk: Model splitting causes access-level churn.
Fix strategy: Preserve `package`, `private`, `nonisolated`, `Codable`, `Equatable` and `Sendable` exactly unless the compiler proves a narrower scope is possible。

Risk: Test support extraction hides coverage loss.
Fix strategy: Move helper construction first, then move tests without changing assertions. Any deleted assertion must be replaced by an equivalent assertion in the same checkpoint。

Risk: Adapter split leaks lower VirtualDisplay types into runtime.
Fix strategy: Keep all lower mapping extensions in `VoidDisplayApp/Composition`, rerun runtime forbidden type grep after adapter split。

Risk: Structural cleanup drifts into Phase 4.
Fix strategy: Reject any new consumer lease, surface epoch, demand aggregation, startup restore or attach/detach behavior in Phase 3c branches。

## Handoff Notes

This document is a planning artifact only. It does not implement Phase 3c.

The next execution window should treat this as the Phase 3c entry plan and start with the preflight gate. If current HEAD no longer contains `802135000045303ff3e290b32486751aaca5bb4d`, it must stop before modifying files。

Phase 3c is complete only when structural splits land, behavior-equivalent tests pass, Debug build has zero compile errors and zero compile warnings, and boundary grep gates still block old direct paths。

After Phase 3c completion, create a separate Phase 4 planning document for consumer lease and demand aggregation. Do not extend this plan into Phase 4 implementation。
