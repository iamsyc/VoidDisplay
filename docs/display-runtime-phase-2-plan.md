# DisplayRuntime Phase 2: Catalog Convergence Into Runtime

状态：已完成历史记录
依据：[DisplayRuntime 重构执行计划](./display-runtime-refactor-plan.md)、[DisplayRuntime Phase 1 执行计划](./display-runtime-phase-1-plan.md)、[产品定位与架构重构前置结论](./product-positioning.md)
范围：screen catalog permission、topology refresh、visible display convergence 控制面迁入 `VoidDisplayRuntime`。
归档说明：Phase 2 已完成。本文保留为当时的执行记录，不再作为当前待办清单。
导航：当前阅读顺序见 [DisplayRuntime 文档索引](./display-runtime-index.md)。

## Summary

Phase 2 将 `ScreenCatalogOrchestrator` 的控制流和收敛决策迁入 `DisplayRuntime`。`ScreenCaptureCatalogService` 继续作为 App/Foundation 侧 ScreenCaptureKit catalog 服务，`DisplayRuntime` 只通过 DTO 和 command ports 调用它。

Phase 2 保持这些边界：

- 不改 capture frame pipeline、WebRTC、virtual display driver、LAN route。
- 不改 Capture / Sharing 页面结构和 UI 信息架构。
- `DisplayRuntimeSnapshotProvider.makeSnapshot()` 继续同步读取 runtime snapshot。
- `VoidDisplayRuntime` 不导入 ScreenCaptureKit、AppKit、SwiftUI、Observation、App controller 或 design system 类型。

## Key Changes

- 给 `DisplayRuntime` 增加 catalog control APIs：appear、disappear、permission request/refresh、force refresh、topology changed、sharing service state changed。
- 新增 runtime catalog control DTO：source、refresh intent、refresh result、owner scope、visible display、shareable display registration。
- 新增 command ports：`DisplayRuntimeCatalogCommanding`、`DisplayRuntimeSharingCommanding`、`DisplayRuntimeCaptureCommanding`、`DisplayRuntimeObservabilityRecording`。
- Runtime 负责 permission refresh、denied clear、source-specific refresh/cancel、topology coalescing、visible display convergence、screen catalog observability event 和 snapshot refresh trigger。
- App adapters 负责把 runtime ports 映射到 `ScreenCaptureCatalogService`、`CaptureController`、`SharingController`、`VirtualDisplayController` 和 `ObservabilityCenter`。
- `ScreenCatalogOrchestrator` 变成 thin adapter，只保留现有 UI API 转发和 privacy settings 打开入口。

## Behavior Rules

- Permission denied 清空 catalog snapshot，记录 warning，使用空 visible display 列表收敛，停止 stale sharing，移除 stale monitoring。
- Capture source 使用 capture owner scope；Sharing source 使用 sharing owner scope。
- Sharing source 在 web service stopped 时只取消 sharing owner refresh，不清空已有 catalog snapshot。
- Sharing service start 即使复用 cached snapshot，也必须 replay shareable display registration。
- Topology changed 由 runtime coalesce，并持续 drain 到最后一次 pending refresh 完成。
- Catalog refresh failed 时不运行 convergence。
- Visible convergence 只在 sharing service 当前 running 时注册 shareable displays。
- Runtime 每次处理 sharing service state changed 时重新读取当前 sharing snapshot，不信任事件参数作为事实源。

## Deletion Conditions

- Runtime 行为测试覆盖原 `ScreenCatalogOrchestratorTests` 后，删除 orchestrator 的私有逻辑分支。
- `ScreenCatalogOrchestrator` Phase 2 仅临时作为 UI adapter 保留。
- 后续 UI wiring 阶段，当 `CaptureUIComposition` 和 `SharingUIComposition` 可直接绑定 runtime catalog actions 时删除 adapter。
- `ScreenCatalogSnapshotProvider` Phase 2 继续作为 parity 对照保留。Diagnostics 以 runtime snapshot 为主后，删除它或折叠为 runtime diagnostics 子 section。

## Test Plan

Runtime behavior tests：

- capture appear refreshes and converges visible displays。
- sharing appear with stopped service cancels refresh without clearing cached snapshot。
- sharing service start reuses snapshot and registers shareable displays。
- permission denied clears snapshot and stops invalid sharing/monitoring。
- topology changes coalesce and apply latest visible displays。
- failed refresh skips convergence。
- runtime re-reads current sharing state instead of trusting stale event parameters。
- runtime command ports never expose `SCDisplay`。

Thin adapter tests：

- `ScreenCatalogOrchestrator` public catalog actions forward to runtime。
- Privacy settings opening still works。
- Adapter has no topology queue, convergence logic, or controller mutation logic。

Verification：

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter ScreenCatalogOrchestratorTests
scripts/ci/unit.sh --filter ScreenCaptureCatalogServiceTests
scripts/ci/unit.sh --filter ObservabilitySnapshotProviderTests
if rg -n "import (SwiftUI|AppKit|Observation|VoidDisplayDesignSystem|VoidDisplayApp|ScreenCaptureKit)" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "\\b(SCDisplay|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession|DisplayCaptureSession)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "(CaptureController|SharingController|VirtualDisplayController|ScreenCaptureKit|SCDisplay|convergeToVisibleDisplays|topologyRefreshTask|hasPendingTopologyChange|recordPermissionEvent|submitRefresh|clearSnapshotForDeniedPermission)" Sources/VoidDisplayApp/AppState/ScreenCatalogOrchestrator.swift; then exit 1; fi
scripts/ci/xcode.sh --action build --configuration Debug
```

## Assumptions

- Swift 6 and macOS deployment target `15.6` remain unchanged。
- Phase 2 may add runtime command ports and App adapters。
- Runtime remains `@MainActor` in Phase 2 to match current catalog/controller isolation。
- `DisplayRuntime` remains control plane only and does not own frame, WebRTC, or virtual display driver handles。
