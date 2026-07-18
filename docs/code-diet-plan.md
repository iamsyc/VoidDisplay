# Code Diet 总审计与批量删减计划

后续覆盖说明：本文原始边界禁止在 Code Diet 中夹带安全能力扩张。当前 LAN Web View 已采用临时 capability URL，后续删减必须保护 [LAN Web View 安全契约](./lan-sharing-security.md)，不得移除或绕过准入和资源预算。

## 1. Summary

目标是在 DisplayRuntime 重构关闭后，执行一次边界保护型 Code Diet，删除旧路径、迁移残留、重复中间层、重复 mapper、重复 fake、重复 helper 和过度防御分支。删减目标是减少系统复杂度和净代码量，不能靠新增抽象、兼容层或临时胶水制造表面整洁。

总体判断：仓库存在大量可删旧复杂度，主要集中在 VirtualDisplay 命令路径重复表示、App composition 和 mapping 胶水、Capture/Sharing 状态重复表达、测试支撑膨胀、历史 docs 噪音。当前粗粒度审计未发现 `VoidDisplayVirtualDisplay` 反向导入 `VoidDisplayRuntime`，也未发现 `VoidDisplayRuntime` 持有指定数据平面类型。这个边界必须继续保护。

架构硬边界：

- `DisplayRuntime` 只做控制平面：状态、事件、transaction、consumer lease、aggregate demand、snapshot、intent dispatch。
- Capture、WebRTC、WebSocket、HTTP、frame、pixel buffer、viewer session 保持在数据平面。
- `VoidDisplayVirtualDisplay` 继续不依赖 `VoidDisplayRuntime`。
- 不新增 legacy compatibility alias、shim、fallback path。
- 不为了减少文件数合并 runtime transaction 文件边界。
- 不让 runtime 接管 frame/WebRTC/WebSocket/HTTP 数据平面。

执行方式：按 6 个大 batch 推进，每个 batch 一次性解决一类复杂度，避免拆成细碎小任务。

## 2. Current Size Baseline

只读基线来自本计划编写前的指定审计命令。

```text
Total selected files: 83,457 LOC
Sources: 38,618 LOC
Tests: 30,384 LOC
UITests: 2,349 LOC
Apps: 4,082 LOC
docs: 8,024 LOC
```

Top size hotspots:

```text
3986 Apps/VoidDisplay/Resources/Localizable.xcstrings
1526 Tests/VoidDisplayAppTests/DisplayRuntimeAdapterTests.swift
1509 Tests/VoidDisplaySharingTests/Integration/WebServerSocketIntegrationTests.swift
1103 UITests/VoidDisplayUITests/Smoke/HomeSmokeTests.swift
1060 Tests/VoidDisplayVirtualDisplayTests/VirtualDisplayControllerTests.swift
917 Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayOrchestrator.swift
868 Sources/VoidDisplayVirtualDisplay/ViewModels/VirtualDisplayController.swift
832 Sources/VoidDisplaySharing/Web/RelaySessionHub.swift
824 Sources/VoidDisplayCapture/Services/DisplayCaptureRegistry.swift
811 Sources/VoidDisplaySharing/Web/WebRTCSessionSupport.swift
810 Tests/VoidDisplayAppTests/TestSupport/TestServiceMocks.swift
697 Sources/VoidDisplaySharing/Web/WebServer.swift
626 Sources/VoidDisplayVirtualDisplay/Services/DisplayRebuildCoordinator.swift
600 Tests/VoidDisplayVirtualDisplayTests/TestSupport/VirtualDisplayTestSupport.swift
573 Tests/VoidDisplayRuntimeTests/TestSupport/DisplayRuntimeFakePorts.swift
573 Sources/VoidDisplayRuntime/Runtime/DisplayRuntime+VirtualDisplayCreateDelete.swift
562 Sources/VoidDisplayRuntime/Runtime/DisplayRuntime+StartupRestore.swift
548 Sources/VoidDisplayRuntime/Runtime/DisplayRuntime+ConsumerLeases.swift
517 Sources/VoidDisplayApp/Bootstrap/VoidDisplayApp.swift
516 Sources/VoidDisplayApp/Composition/DisplayRuntimeVirtualDisplayAdapter+Mapping.swift
500 Sources/VoidDisplayApp/Navigation/DisplaysView.swift
```

Required read-only audit results:

- `git status --short --branch --untracked-files=all`: branch was `codex/product-positioning-doc`; no tracked or untracked changes before creating this document.
- LOC hotspot command: total 83,457 lines across selected files; hotspots listed above.
- Directory totals command: `Sources 38,618`, `Tests 30,384`, `UITests 2,349`, `Apps 4,082`, `docs 8,024`.
- Legacy/fallback keyword scan: produced real candidates in `ScreenCatalogOrchestrator`, `VirtualDisplayController`, `CaptureUIComposition`, `SharingUIComposition`, `VoidDisplayApp`, `DisplayRuntimeVirtualDisplayAdapter+Mapping`, test support, UI smoke helpers, sharing integration tests, capture registry tests, and historical docs. Some hits are valid product fallback, such as macOS display callback polling fallback and reduce-transparency UI fallback, so each hit needs classification before deletion.
- `rg -n "import VoidDisplayRuntime" Sources/VoidDisplayVirtualDisplay Tests/VoidDisplayVirtualDisplayTests`: no matches.
- `rg -n "SCStream|SCDisplay|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession|DisplayCaptureSession" Sources/VoidDisplayRuntime`: no matches.

## 3. What Not To Delete

Necessary complexity to keep:

- Runtime transaction files for rebuild, create/delete, startup restore, queueing, topology wait, affected surface scope, consumer leases, demand aggregation, snapshot, observability.
- Runtime contract tests covering transaction ordering, trace evidence, startup restore outcomes, consumer lease lifecycle, demand aggregation, capture intent revisioning, diagnostics privacy, support bundle redaction, and boundary imports.
- Data-plane session state in `DisplayCaptureRegistry`, `DisplayCaptureSession`, `RelaySessionHub`, `WebRTCSessionSupport`, `WebServer`, `DisplaySharingCoordinator`, and `SharingService` when it represents real capture sessions, WebRTC peers, WebSocket connections, HTTP listener lifecycle, frame mailbox, codec state, route resolution, or viewer count.
- VirtualDisplay lower-layer driver, topology, persistence, rollback, and display policy logic needed by `VoidDisplayVirtualDisplay` without importing runtime.
- UI-facing Displays and Diagnostics presentation logic that hides runtime internals and preserves user-facing product language.
- macOS callback polling fallbacks that compensate for real platform callback unreliability, unless a targeted audit proves the caller and state machine no longer need them.
- Localization keys that are still referenced by product code or needed for current app-facing text.
- `product-positioning.md`, `display-runtime-index.md`, final closeout documents, and current architecture boundary statements.

## 4. Code Smell Taxonomy

Deletion categories:

- Legacy path: old direct controller execution, old restore path, old provider registration, old navigation route, stale Support Center path, old catalog path.
- Migration bridge: adapter or facade method retained only to keep both pre-runtime and runtime paths alive.
- Duplicate middle layer: same command/result/evidence represented in lower VirtualDisplay command, runtime transaction, app adapter, controller presentation, and test facade.
- Over-defense: duplicated missing-display checks, duplicated no-op fallback, duplicated topology recovery branch, defensive nil branch that cannot be reached after runtime owns the decision.
- State shadowing: Runtime lease/demand/effective intent and Capture/Sharing service state both claim ownership of the same lifecycle fact.
- Mapper duplication: App presentation mapper translates runtime DTO into intermediate DTO, then another mapper translates into UI row state.
- Test support bloat: fake ports, mocks, fixtures, factories, snapshot builders, temporary directory helpers, and UI smoke helpers repeating the same setup.
- Historical docs noise: completed phase docs, closeouts, old plans, or localization stale keys treated as current backlog.

Classification rule: delete only when owner, caller graph, replacement coverage, and validation path are known. Do not keep compatibility branches without naming caller, reason, deletion condition, and validation impact.

## 5. Batch Plan

### Batch 1: Dead Path And Legacy Fallback Removal

Goal: delete old controller direct path, legacy fallback, compatibility branches, and migration-era comments.

Audit focus:

- `ScreenCatalogOrchestrator`: determine if it is still a real catalog convergence owner or only a thin adapter around runtime/app state. Delete if it only forwards snapshot/catalog actions already owned elsewhere.
- `VirtualDisplayController`: remove runtime-owned business decisions from the controller. Controller should keep UI presentation state, user alerts, and action dispatch only.
- `CaptureUIComposition` and `SharingUIComposition`: remove fallback branches that bypass runtime-owned lease/intent decisions.
- `VoidDisplayApp`: remove old startup restore/provider/task barrier paths if runtime startup restore and current observability registration already cover them.
- Docs and comments: delete migration-era wording that implies closed DisplayRuntime work is active.

Delete candidates:

- Old startup restore direct calls through `VirtualDisplayController` or facade, if any remain.
- Controller executor availability branches that only protect against an impossible unconfigured runtime command path.
- Screen catalog adapter methods that only re-expose runtime snapshot facts with no policy.
- App bootstrap barriers whose only job was sequencing old providers before runtime existed.
- Tests asserting absence of old fallback implementation details after replacement contract tests exist.

Must retain:

- Runtime startup restore call from app bootstrap.
- Observability snapshot provider registration for runtime/system/persistence.
- Real macOS callback polling fallback.
- Screen catalog code only if still required to resolve concrete `SCDisplay` or physical catalog facts outside runtime.

Batch 1 completion result:

- Deleted `ScreenCatalogOrchestrator` because it only forwarded catalog actions to `DisplayRuntime` and owned no catalog policy.
- Rewired Capture and Sharing catalog UI actions directly to `DisplayRuntime`, with privacy-settings opening kept as the only app-composition callback.
- Removed the test that proved a runtime-bypassing preview session could survive `closePreviewSession`; retained tests now verify runtime consumer leases drive Screen Preview and LAN Web View start/stop.
- Renamed the app startup task handoff so startup restore remains only `DisplayRuntime.restoreStartupVirtualDisplays(source: .startup)` without old startup-runtime task naming.
- Retained VirtualDisplay lower-layer fallback hits that represent macOS callback polling, main-display policy continuity, serial-number continuity, diagnostics defaulting, or default user-facing error messages. These are not controller direct paths.

### Batch 2: VirtualDisplay Layer Collapse

Goal: collapse duplicated responsibilities across `VirtualDisplayOrchestrator`, `VirtualDisplayController`, `DisplayRebuildCoordinator`, facade protocols, UI test facade, and test support.

Audit focus:

- `VirtualDisplayOrchestrator` currently spans driver command, persistence, topology wait, rollback, create/delete/edit/startup restore evidence, and rebuild delegation. Delete duplicate API surface rather than add abstraction.
- `VirtualDisplayController` should stop duplicating lower-layer business judgment. It can own in-flight UI state, alerts, applied badges, and row presentation feedback.
- Typed result families for rebuild/create/delete/edit/startup restore should have one lower-layer command representation and one runtime transaction representation. Remove app/test-only mirrors.
- Test facade must not copy production command logic. It should script outcomes and verify calls.

Delete candidates:

- Redundant `hasConfigured*Executor` probes if only tests consume them and direct behavior tests cover configuration.
- Duplicate command result factories in app tests and virtual display tests.
- Duplicate evidence mapping where `VirtualDisplayCommandConfigEvidence` and runtime evidence are translated more than once.
- Test facade production-like implementations for create/delete/restore that can be replaced by scripted result builders.
- Controller methods that wrap a runtime transaction with no UI-specific behavior.

Move to single owner:

- Topology wait, rollback, driver lifecycle: `VoidDisplayVirtualDisplay`.
- Transaction ordering, affected surface scope, trace evidence: `DisplayRuntime`.
- User-visible progress/failure presentation: controller/App presentation layer.
- Redacted command evidence mapping: one adapter mapping layer only.

Must retain:

- `VoidDisplayVirtualDisplay` direction with no `VoidDisplayRuntime` import.
- Runtime transaction contract tests.
- Lower-layer command tests for actual driver/persistence/topology behavior.
- `DisplayRebuildCoordinator` if it remains the only owner of fleet rebuild and topology health semantics.

Batch 2 completion result:

- Collapsed lower create/delete/startup restore command results so they no longer carry post-command running-config and managed-display snapshots that the app adapter can read from the single lower snapshot boundary.
- Removed lower create-result config evidence and serial echo; runtime create evidence is now derived once from the runtime request plus returned config id.
- Moved the duplicated `MockVirtualDisplayFacade` from App and VirtualDisplay test targets into `VoidDisplayVirtualDisplayTestingSupport`.
- Kept lower driver/topology/persistence outcomes because runtime transactions still consume those command outcomes to distinguish append failure, runtime creation failure, rollback failure, delete missing-config, and startup restore failure.
- Net Sources+Tests deletion exceeded the 1,000-line Batch 2 target without touching Runtime, Capture data-plane, LAN security, Diagnostics, app-facing copy, or localization.

### Batch 3: Capture And Sharing Resource Model Simplification

Goal: simplify resource tracking across capture and sharing without moving data plane into runtime.

Audit focus:

- `DisplayCaptureRegistry`, `DisplayCaptureSession`, `CapturePreviewLifecycleService`: identify whether registry tokens duplicate runtime lease identity or whether they represent actual session resources.
- `SharingService`, `DisplaySharingCoordinator`, `WebServer`, `RelaySessionHub`, `WebRTCSessionSupport`: separate route/shareID/viewer/session facts from runtime demand.
- Screen Preview, LAN Web View, diagnostics recorder: remove repeated attach/detach branches where runtime lease already drives intent.
- Sharing route/shareID stays data-plane ownership. Runtime may expose facts in snapshot, but does not own session lifecycle.

Delete candidates:

- Duplicate active sharing or active preview state derived only from runtime leases.
- Duplicate demand aggregation in App adapters or sharing state when runtime aggregate demand already exists.
- Extra lifecycle token layers that never guard real capture/WebRTC/WebSocket resources.
- Repeated preview/LAN/diagnostics attach helpers if they differ only by hard-coded consumer kind and can be table-driven.
- Integration tests that separately assert the same attach/detach lifecycle at registry, service, adapter, and runtime levels.

Must retain:

- Capture registry session resource state for real `DisplayCaptureSessioning` objects.
- WebSocket active connection tracking in `WebServer`.
- WebRTC peer, codec, frame mailbox, timestamp sequencer, and relay publisher state in `RelaySessionHub` and `WebRTCSessionSupport`.
- Share route/shareID ownership in sharing data plane.
- Runtime intent dispatch only as control-plane signal.

### Batch 4: App Composition And Mapping Reduction

Goal: reduce adapter/mapping/bootstrap/presentation glue.

Audit focus:

- `DisplayRuntimeVirtualDisplayAdapter+Mapping.swift`: shrink repeated DTO/evidence/result mapping. Keep only one explicit mapping boundary from lower VirtualDisplay command results to runtime command results.
- `DisplayRuntimeAdapterTests.swift`: split or table-drive large repeated setup; remove tests that exist only because mapping is duplicated.
- `DisplaySurfacePresentation.swift`: keep user-facing UI policy, delete raw DTO translation and runtime terminology formatting that can be resolved before presentation.
- `DisplaysView.swift`: remove UI state that duplicates presentation model state or runtime facts.
- `VoidDisplayApp`: reduce bootstrap glue after old providers and old task ordering are removed.

Delete candidates:

- Repeated `make*Evidence`, `make*Request`, `make*Snapshot` helpers in app adapter tests.
- Presentation mapper branches that expose raw runtime terms then hide them again.
- UI row state stored in `DisplaysView` when `DisplaySurfacePresentation` already computes it.
- Composition methods that only pass through services without policy.

Must retain:

- User-facing Displays UX rules from `docs/displays-ux-finalization-plan.md`.
- Copy guard coverage preventing `DisplaySurface`, `Surface`, `Consumer`, `Lease`, `Intent` from leaking to users.
- Runtime adapter boundary tests that prove no generic capture intent path starts real capture.
- App bootstrap runtime startup restore and observability registration.

### Batch 5: Test Support And Fixture Diet

Goal: aggressively reduce test support volume while preserving contract tests.

Audit focus:

- `Tests/VoidDisplayAppTests/TestSupport/TestServiceMocks.swift`
- `Tests/VoidDisplayRuntimeTests/TestSupport/DisplayRuntimeFakePorts.swift`
- `Tests/VoidDisplayVirtualDisplayTests/TestSupport/VirtualDisplayTestSupport.swift`
- Sharing/Capture test support and repeated temporary store helpers.
- UI smoke helper and repeated navigation/assertion wrappers.

Delete or merge:

- Duplicate `MockVirtualDisplayFacade` implementations between App and VirtualDisplay tests. Replace with one minimal scripted fake per module boundary, or move shared fixture to a proper test-support target if dependency direction permits.
- Repeated temporary directory helpers in individual tests where `VoidDisplayTestingSupport.makeTemporaryDirectory` exists.
- Repeated sharing store URL helpers.
- Repeated snapshot builders for DisplayRuntime surfaces, leases, aggregate demand, and effective intents.
- Tests that assert the same mapper behavior through several near-identical examples. Convert to table-driven cases.
- UI smoke helper branches that cover obsolete navigation or coordinate fallback paths after current accessibility identifiers are reliable.

Must retain core contract tests:

- Runtime transaction tests: rebuild, create/delete, edit rebuild, startup restore.
- Consumer lease and demand aggregation tests.
- Capture intent revision/apply-result tests.
- Runtime snapshot and observability tests.
- Diagnostics privacy and support bundle redaction tests.
- Boundary tests for runtime imports and data-plane exclusion.
- UI IA smoke for Displays and Diagnostics.
- Tests preventing privacy prompt paths in automated environments.
- UI test preferred port injection through `-sharing.preferredPort`.

### Batch 6: Docs And Localization Hygiene

Goal: reduce history and localization noise without treating docs/localization as source diet KPI.

Audit focus:

- `docs/display-runtime-phase-*`: historical records, not active backlog.
- `docs/display-runtime-post-refactor-cleanup-plan.md`, final closeouts, startup restore closeout, UX finalization plan.
- `Apps/VoidDisplay/Resources/Localizable.xcstrings`: stale keys, old Support Center keys, old Surface copy, unused migration keys.

Docs strategy:

- Keep final index and closeout documents as current architecture references.
- Move completed detailed phase plans to `docs/archive/display-runtime/` only if links are updated in `docs/display-runtime-index.md`.
- Compress or archive old implementation plans whose state wording can be mistaken for current work, unless they remain active product plans with a clear owner and current scope.
- Do not touch README or public screenshots in this batch.

Localization strategy:

- Use static key reference audit before deleting keys.
- Delete stale app-facing keys only when no Swift/resource reference remains.
- Preserve current Displays/Diagnostics/LAN Web View/Support Bundle terminology.
- Do not accept Xcode-generated churn. Diff must be manually reviewed.

Must retain:

- `product-positioning.md`
- `display-runtime-index.md`
- `display-runtime-final-closeout.md`
- Current architecture boundary statements.
- Current active UX plan if still intentionally pending.

## 6. Per-batch Allowed Scope

Batch 1 allowed:

```text
Sources/VoidDisplayApp/AppState/**
Sources/VoidDisplayApp/Bootstrap/**
Sources/VoidDisplayApp/Composition/CaptureUIComposition.swift
Sources/VoidDisplayApp/Composition/SharingUIComposition.swift
Sources/VoidDisplayVirtualDisplay/ViewModels/VirtualDisplayController.swift
Tests/VoidDisplayAppTests/**
Tests/VoidDisplayVirtualDisplayTests/**
docs/**
```

Batch 2 allowed:

```text
Sources/VoidDisplayVirtualDisplay/**
Sources/VoidDisplayApp/Composition/DisplayRuntimeVirtualDisplayAdapter+Mapping.swift
Sources/VoidDisplayRuntime/Ports/DisplayRuntimePorts.swift only for deleting unused port surface
Tests/VoidDisplayVirtualDisplayTests/**
Tests/VoidDisplayAppTests/DisplayRuntimeAdapterTests.swift
Tests/VoidDisplayAppTests/TestSupport/**
```

Batch 3 allowed:

```text
Sources/VoidDisplayCapture/**
Sources/VoidDisplaySharing/**
Sources/VoidDisplayApp/Composition/DisplayRuntimeCaptureAdapter.swift
Sources/VoidDisplayApp/Composition/DisplayRuntimeSharingAdapter.swift
Sources/VoidDisplayApp/Composition/CaptureUIComposition.swift
Sources/VoidDisplayApp/Composition/SharingUIComposition.swift
Tests/VoidDisplayCaptureTests/**
Tests/VoidDisplaySharingTests/**
Tests/VoidDisplayAppTests/*Capture*
Tests/VoidDisplayAppTests/*Sharing*
```

Batch 4 allowed:

```text
Sources/VoidDisplayApp/Composition/**
Sources/VoidDisplayApp/Navigation/DisplaySurfacePresentation.swift
Sources/VoidDisplayApp/Navigation/DisplaysView.swift
Sources/VoidDisplayApp/Bootstrap/VoidDisplayApp.swift
Tests/VoidDisplayAppTests/**
UITests/VoidDisplayUITests/Smoke/**
Apps/VoidDisplay/Resources/Localizable.xcstrings only when app-facing copy changes
```

Batch 5 allowed:

```text
Tests/**
UITests/**
Sources/VoidDisplayTestingSupport/**
```

Batch 6 allowed:

```text
docs/**
Apps/VoidDisplay/Resources/Localizable.xcstrings
Tests/VoidDisplaySupportTests/DiagnosticsUserFacingCopyTests.swift only if localization/copy guards need update
```

## 7. Per-batch Forbidden Scope

Global forbidden scope:

```text
Sources/VoidDisplayRuntime importing App/UI/Capture/Sharing/VirtualDisplay/AppKit/SwiftUI/Observation/ScreenCaptureKit
Sources/VoidDisplayRuntime owning frame/WebRTC/WebSocket/HTTP/session/pixel-buffer objects
Sources/VoidDisplayVirtualDisplay importing VoidDisplayRuntime
New compatibility aliases
New legacy fallback paths
Remote control, input injection, clipboard, browser agent control
Bypassing the current LAN capability gate, or adding account/password/public relay expansion
```

Batch-specific forbidden scope:

- Batch 1: do not remove real platform callback polling fallback without proving current owner and replacement. Do not delete startup restore through runtime.
- Batch 2: do not merge runtime transaction files just to reduce file count. Do not make VirtualDisplay depend on runtime.
- Batch 3: do not move capture frames, viewer sessions, WebRTC peers, WebSocket connections, HTTP listener lifecycle, or shareID ownership into runtime.
- Batch 4: do not expose runtime terms in user UI. Do not add UI-specific runtime DTOs.
- Batch 5: do not delete core contract tests. Do not introduce tests that trigger avoidable macOS privacy prompts.
- Batch 6: do not rewrite public README/screenshots. Do not convert historical docs into a new numbered DisplayRuntime phase.

## 8. Verification Gates

Plan-doc creation gate:

```text
git diff --check -- docs/code-diet-plan.md
run the active-work keyword scan specified by this task against docs/code-diet-plan.md
```

The second command may return no matches. If it returns matches, every match must be explicit prohibition or historical explanation. It must not define a new DisplayRuntime numbered phase or active DisplayRuntime backlog.

Per-code-batch gates:

- Always start with `git status --short --branch --untracked-files=all`.
- Always end with `git diff --check`.
- After any Swift code change, run local build verification and require zero compile errors and zero compile warnings.
- Batch 1: targeted App and VirtualDisplay tests covering bootstrap, controller, ScreenCatalog, CaptureUI/SharingUI composition.
- Batch 2: `VoidDisplayVirtualDisplayTests`, `DisplayRuntimeAdapterTests`, and affected runtime transaction tests if port surface changes.
- Batch 3: `VoidDisplayCaptureTests`, `VoidDisplaySharingTests`, and App adapter tests for capture/sharing intent.
- Batch 4: `VoidDisplayAppTests`, presentation mapper tests, narrow UI smoke for Displays if UI changes.
- Batch 5: targeted tests for every support layer changed. Full unit only if shared test support or static gate changes broadly.
- Batch 6: docs diff check; `jq empty Apps/VoidDisplay/Resources/Localizable.xcstrings` if localization changes; copy guard tests if app-facing copy changes.

Do not run high-cost Xcode or UI suites during this planning task. For implementation batches, use the narrowest validation that proves the changed contract, then run Xcode Debug build when product Swift changes require the build gate.

## 9. Risk Controls

- Delete in one batch at a time. Do not mix VirtualDisplay collapse with Capture/Sharing resource cleanup.
- Before deleting any public/package symbol, run `rg` for all callers in `Sources`, `Tests`, `UITests`, `Apps`, and `docs`.
- For every removed test, name the surviving stronger contract test.
- For every retained legacy-looking branch, document caller, reason, deletion condition, and validation impact in that batch handoff.
- Keep runtime boundary grep in every batch touching App, Capture, Sharing, or VirtualDisplay.
- Keep privacy-prompt isolation for tests. UI test failures from missing automation authorization must be reported as environment setup failure.
- Do not chase LOC at the expense of contract coverage or boundary clarity.
- Stop and re-plan if deletion requires a new abstraction larger than the code being removed.

## 10. Expected LOC Reduction Range

Realistic reduction target:

```text
Sources: 3,000 to 8,000 LOC reduction
Tests: 2,000 to 6,000 LOC reduction
UITests: 200 to 800 LOC reduction
docs/localization: excluded from source diet KPI
```

Likely distribution:

- Batch 1: 400 to 1,200 Sources, 300 to 900 Tests.
- Batch 2: 900 to 2,500 Sources, 700 to 1,800 Tests.
- Batch 3: 600 to 1,800 Sources, 400 to 1,200 Tests.
- Batch 4: 600 to 1,500 Sources, 400 to 1,400 Tests.
- Batch 5: 0 to 400 Sources, 1,000 to 2,500 Tests/UITests.
- Batch 6: docs/localization cleanup only, not counted as source KPI.

Do not claim 20,000 product-source LOC reduction without new audit evidence. Current evidence supports a large cleanup, not a product rewrite.

## 11. Stop Conditions

Stop the current batch and re-plan if any of these occurs:

- A proposed deletion forces `VoidDisplayVirtualDisplay` to import `VoidDisplayRuntime`.
- Runtime needs to import or own data-plane types.
- A legacy branch has an active caller that cannot be removed in the same batch.
- Deleting a test removes the only coverage for a runtime transaction, lease, demand, privacy, diagnostics, or UI IA contract.
- A cleanup requires deviating from the current LAN Web View security contract.
- A cleanup requires product behavior changes outside deletion/simplification.
- Targeted tests reveal behavior drift rather than stale test assumptions.
- Build produces compile warnings after code changes.
- Localization diff contains Xcode extraction churn unrelated to intended app-facing copy cleanup.

## 12. Execution Mode Guidance

Recommended execution after this plan is approved: direct execution, one batch per working window, starting with Batch 1 because the affected scope is bounded and it removes stale paths before deeper VirtualDisplay/test-support consolidation.

For each batch handoff, report:

- Changed files.
- Deleted code category and deletion rationale.
- Preserved contract tests.
- Targeted verification commands and results.
- Boundary grep results.
- Any retained legacy-looking branch with caller, reason, deletion condition, and validation impact.

For this plan-document commit, validation is limited to:

```text
git diff --check -- docs/code-diet-plan.md
run the active-work keyword scan specified by this task against docs/code-diet-plan.md
```

No Xcode build, unit test, UI test, source deletion, or localization mutation is part of this plan-document commit.
