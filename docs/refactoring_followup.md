# VoidDisplay 重构后续修复方案

## 更新摘要（2026-02-23）
- Monitor 去重已完成：统一使用 DebouncingDisplayReconfigurationMonitor，无需重复清理。
- 新增 DisplayRebuildCoordinator，重建/拓扑恢复从 VirtualDisplayService 拆出；服务层对外接口保持不变。
- UI 烟测工作流改为功能失败即阻断，runner 不稳时豁免。
- 覆盖率基线提升至 0.55，并新增 display_rebuild_coordinator 跟踪项。

# VoidDisplay 重构后续修复方案

> **执行者**: GPT / Codex 模型  
> **前置条件**: 基于 `codex/refactor-start` 分支当前未提交的修改  
> **目标**: 修复审查中发现的 3 个遗留问题

---

## 问题 1: 重复的 Display Reconfiguration Monitor 类

### 现状

以下 **3 个类** 结构几乎完全相同（仅类名不同），均为 `CGDisplayRegisterReconfigurationCallback` 的 debouncing 封装：

| 类名 | 文件 | 行范围 | 有 debounce |
|------|------|--------|-------------|
| `VirtualDisplayReconfigurationMonitor` | `Features/VirtualDisplay/Services/DisplayReconfigurationMonitor.swift` | 全文件 (66L) | ❌ 无 debounce |
| `ShareDisplayRefreshMonitor` | `Features/Sharing/Views/ShareDisplayRefreshMonitor.swift` | 全文件 (76L) | ✅ 300ms debounce |
| `PrimaryDisplayReconfigurationMonitor` | `Features/VirtualDisplay/Views/VirtualDisplayView.swift` | L221-L292 (72L, private) | ✅ 300ms debounce |

### 修改方案

#### Step 1: 创建通用 Monitor

#### [NEW] `Shared/Services/DebouncingDisplayReconfigurationMonitor.swift`

```swift
import CoreGraphics
import Foundation

@MainActor
final class DebouncingDisplayReconfigurationMonitor {
    private var handler: (@MainActor () -> Void)?
    private var debounceTask: Task<Void, Never>?
    private let debounceNanoseconds: UInt64
    nonisolated(unsafe) private var isRunning = false

    init(debounceNanoseconds: UInt64 = 300_000_000) {
        self.debounceNanoseconds = debounceNanoseconds
    }

    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        self.handler = handler
        guard !isRunning else { return true }

        let userInfo = Unmanaged.passRetained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            userInfo
        )
        guard result == .success else {
            Unmanaged<DebouncingDisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
            return false
        }
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else {
            handler = nil
            debounceTask?.cancel()
            debounceTask = nil
            return
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(
            Self.displayReconfigurationCallback,
            userInfo
        )
        isRunning = false
        handler = nil
        debounceTask?.cancel()
        debounceTask = nil
        Unmanaged<DebouncingDisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
    }

    deinit {
        assert(!isRunning, "DebouncingDisplayReconfigurationMonitor must be stopped before deallocation.")
    }

    private func handleDisplayChange() {
        debounceTask?.cancel()
        let ns = debounceNanoseconds
        if ns == 0 {
            handler?()
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled else { return }
            self.handler?()
        }
    }

    private nonisolated static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = {
        _,
        _,
        userInfo in
        guard let userInfo else { return }

        let monitor = Unmanaged<DebouncingDisplayReconfigurationMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        Task { @MainActor in
            monitor.handleDisplayChange()
        }
    }
}
```

#### Step 2: 替换使用方

##### [DELETE] `Features/Sharing/Views/ShareDisplayRefreshMonitor.swift`

删除整个文件。

##### [MODIFY] `Features/Sharing/Views/ShareView.swift`

```diff
-@State private var displayRefreshMonitor = ShareDisplayRefreshMonitor()
+@State private var displayRefreshMonitor = DebouncingDisplayReconfigurationMonitor()
```

##### [MODIFY] `Features/VirtualDisplay/Views/VirtualDisplayView.swift`

1. 将 `PrimaryDisplayReconfigurationMonitor` (L221-L292) 整个 `private final class` 删除
2. 将引用替换：

```diff
-@State private var primaryDisplayMonitor = PrimaryDisplayReconfigurationMonitor()
+@State private var primaryDisplayMonitor = DebouncingDisplayReconfigurationMonitor()
```

##### [MODIFY] `Features/VirtualDisplay/Services/DisplayReconfigurationMonitor.swift`

`VirtualDisplayReconfigurationMonitor` 不使用 debounce（VirtualDisplayService 需要即时回调来完成 offline waiter），保留但让它也实现同一个协议：

```diff
-protocol DisplayReconfigurationMonitoring {
+protocol DisplayReconfigurationMonitoring: AnyObject {
     @discardableResult
     func start(handler: @escaping @MainActor () -> Void) -> Bool
     func stop()
 }
+
+extension DebouncingDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {}
```

这样 `VirtualDisplayService` 如果未来想换用 debouncing 版本也可以直接注入。

##### [MODIFY] `VoidDisplay.xcodeproj`

确保新文件 `Shared/Services/DebouncingDisplayReconfigurationMonitor.swift` 被添加到 Xcode target。

---

## 问题 2: AppHelper Facade 转发方法过多

### 现状

`AppHelper` (378L) 约 200 行是纯转发方法，View 层仍通过 `AppHelper` 间接访问三个 Controller。

### 修改方案

将三个 Controller 暴露为 `AppHelper` 的公开属性，让 View 层可以直接访问 Controller，逐步消除转发方法。

#### [MODIFY] `App/VoidDisplayApp.swift`

**Step 1**: 将三个 Controller 改为公开属性：

```diff
-    @ObservationIgnored private let captureController: CaptureController
-    @ObservationIgnored private let sharingController: SharingController
-    @ObservationIgnored private let virtualDisplayController: VirtualDisplayController
+    let capture: CaptureController
+    let sharing: SharingController
+    let virtualDisplay: VirtualDisplayController
```

**Step 2**: 调整 `init` 中的赋值：

```diff
-        self.captureController = captureController
-        self.sharingController = sharingController
-        self.virtualDisplayController = VirtualDisplayController(
+        let captureCtrl = CaptureController(captureMonitoringService: resolvedCaptureMonitoringService)
+        let sharingCtrl = SharingController(sharingService: resolvedSharingService)
+        self.capture = captureCtrl
+        self.sharing = sharingCtrl
+        self.virtualDisplay = VirtualDisplayController(
             virtualDisplayService: resolvedVirtualDisplayService,
             appliedBadgeDisplayDurationNanoseconds: appliedBadgeDisplayDurationNanoseconds,
             stopDependentStreamsBeforeRebuild: { displayID in
-                captureController.stopDependentStreamsBeforeRebuild(
+                captureCtrl.stopDependentStreamsBeforeRebuild(
                     displayID: displayID,
-                    sharingController: sharingController
+                    sharingController: sharingCtrl
                 )
             }
         )
```

**Step 3**: 删除所有纯转发的计算属性和方法（约 200 行）。保留以下方法（有额外逻辑的）：

保留的方法（非纯转发）：
- `isManagedVirtualDisplay(displayID:)` — 查 `displays` 数组
- `registerShareableDisplays(_:)` — 内部闭包引用 `virtualSerialForManagedDisplay`
- `virtualSerialForManagedDisplay(_:)` — 跨 Controller 查询

其他所有纯转发方法删除。

**Step 4**: `AppHelper` init 内部引用也要对应修改（如 `virtualDisplayController.loadPersistedConfigs...` → `virtualDisplay.loadPersistedConfigs...`）

#### 批量 View 层修改

所有 View 文件中的调用从 `appHelper.xxx` 改为 `appHelper.virtualDisplay.xxx` / `appHelper.sharing.xxx` / `appHelper.capture.xxx`。

以下是需要修改的文件和对应的映射规则：

| 原调用 | 新调用 |
|--------|--------|
| `appHelper.displays` | `appHelper.virtualDisplay.displays` |
| `appHelper.displayConfigs` | `appHelper.virtualDisplay.displayConfigs` |
| `appHelper.runningConfigIds` | `appHelper.virtualDisplay.runningConfigIds` |
| `appHelper.restoreFailures` | `appHelper.virtualDisplay.restoreFailures` |
| `appHelper.rebuildingConfigIds` | `appHelper.virtualDisplay.rebuildingConfigIds` |
| `appHelper.rebuildFailureMessageByConfigId` | `appHelper.virtualDisplay.rebuildFailureMessageByConfigId` |
| `appHelper.recentlyAppliedConfigIds` | `appHelper.virtualDisplay.recentlyAppliedConfigIds` |
| `appHelper.isVirtualDisplayRunning(...)` | `appHelper.virtualDisplay.isVirtualDisplayRunning(...)` |
| `appHelper.runtimeDisplay(for:)` | `appHelper.virtualDisplay.runtimeDisplay(for:)` |
| `appHelper.clearRestoreFailures()` | `appHelper.virtualDisplay.clearRestoreFailures()` |
| `appHelper.startRebuildFromSavedConfig(...)` | `appHelper.virtualDisplay.startRebuildFromSavedConfig(...)` |
| `appHelper.retryRebuild(...)` | `appHelper.virtualDisplay.retryRebuild(...)` |
| `appHelper.isRebuilding(...)` | `appHelper.virtualDisplay.isRebuilding(...)` |
| `appHelper.rebuildFailureMessage(...)` | `appHelper.virtualDisplay.rebuildFailureMessage(...)` |
| `appHelper.hasRecentApplySuccess(...)` | `appHelper.virtualDisplay.hasRecentApplySuccess(...)` |
| `appHelper.clearRebuildPresentationState(...)` | `appHelper.virtualDisplay.clearRebuildPresentationState(...)` |
| `appHelper.createDisplay(...)` | `appHelper.virtualDisplay.createDisplay(...)` |
| `appHelper.createDisplayFromConfig(...)` | `appHelper.virtualDisplay.createDisplayFromConfig(...)` |
| `appHelper.disableDisplay(...)` | `appHelper.virtualDisplay.disableDisplay(...)` |
| `appHelper.disableDisplayByConfig(...)` | `appHelper.virtualDisplay.disableDisplayByConfig(...)` |
| `appHelper.enableDisplay(...)` | `appHelper.virtualDisplay.enableDisplay(...)` |
| `appHelper.destroyDisplay(...)` | `appHelper.virtualDisplay.destroyDisplay(...)` |
| `appHelper.getConfig(...)` | `appHelper.virtualDisplay.getConfig(...)` |
| `appHelper.updateConfig(...)` | `appHelper.virtualDisplay.updateConfig(...)` |
| `appHelper.moveDisplayConfig(...)` | `appHelper.virtualDisplay.moveDisplayConfig(...)` |
| `appHelper.applyModes(...)` | `appHelper.virtualDisplay.applyModes(...)` |
| `appHelper.rebuildVirtualDisplay(...)` | `appHelper.virtualDisplay.rebuildVirtualDisplay(...)` |
| `appHelper.nextAvailableSerialNumber()` | `appHelper.virtualDisplay.nextAvailableSerialNumber()` |
| `appHelper.resetVirtualDisplayData()` | `appHelper.virtualDisplay.resetVirtualDisplayData()` |
| `appHelper.screenCaptureSessions` | `appHelper.capture.screenCaptureSessions` |
| `appHelper.monitoringSession(for:)` | `appHelper.capture.monitoringSession(for:)` |
| `appHelper.addMonitoringSession(...)` | `appHelper.capture.addMonitoringSession(...)` |
| `appHelper.markMonitoringSessionActive(...)` | `appHelper.capture.markMonitoringSessionActive(...)` |
| `appHelper.removeMonitoringSession(...)` | `appHelper.capture.removeMonitoringSession(...)` |
| `appHelper.activeSharingDisplayIDs` | `appHelper.sharing.activeSharingDisplayIDs` |
| `appHelper.sharingClientCount` | `appHelper.sharing.sharingClientCount` |
| `appHelper.sharingClientCounts` | `appHelper.sharing.sharingClientCounts` |
| `appHelper.isSharing` | `appHelper.sharing.isSharing` |
| `appHelper.isWebServiceRunning` | `appHelper.sharing.isWebServiceRunning` |
| `appHelper.webServer` | `appHelper.sharing.webServer` |
| `appHelper.startWebService()` | `appHelper.sharing.startWebService()` |
| `appHelper.stopWebService()` | `appHelper.sharing.stopWebService()` |
| `appHelper.webServicePortValue` | `appHelper.sharing.webServicePortValue` |
| `appHelper.refreshSharingClientCount()` | `appHelper.sharing.refreshSharingClientCount()` |
| `appHelper.isDisplaySharing(...)` | `appHelper.sharing.isDisplaySharing(...)` |
| `appHelper.sharePagePath(...)` | `appHelper.sharing.sharePagePath(...)` |
| `appHelper.sharePageURLResolution(...)` | `appHelper.sharing.sharePageURLResolution(...)` |
| `appHelper.sharePageURL(...)` | `appHelper.sharing.sharePageURL(...)` |
| `appHelper.sharePageAddress(...)` | `appHelper.sharing.sharePageAddress(...)` |
| `appHelper.beginSharing(...)` | `appHelper.sharing.beginSharing(...)` |
| `appHelper.stopSharing(...)` | `appHelper.sharing.stopSharing(...)` |
| `appHelper.stopAllSharing()` | `appHelper.sharing.stopAllSharing()` |

**涉及的 View 文件**（用全局搜索替换）：

- `Features/VirtualDisplay/Views/VirtualDisplayView.swift`
- `Features/VirtualDisplay/Views/CreateVirtualDisplay.swift`
- `Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift`
- `Features/Sharing/Views/ShareView.swift`
- `Features/Sharing/Views/ShareDisplayList.swift`
- `Features/Sharing/ViewModels/ShareViewModel.swift`
- `Features/Capture/Views/CaptureChoose.swift`
- `Features/Capture/Views/CaptureDisplayView.swift`
- `Features/Capture/ViewModels/CaptureChooseViewModel.swift`
- `App/AppSettingsView.swift`

**涉及的测试文件**：

- `VoidDisplayTests/App/AppHelperTests.swift` — 更新所有 `sut.xxx` 调用

> [!IMPORTANT]
> 保留 `isManagedVirtualDisplay(displayID:)` 和 `registerShareableDisplays(_:)` 在 `AppHelper` 上，因为它们有跨 Controller 的逻辑。

---

## 问题 3: VirtualDisplayService 进一步拆分

### 现状

`VirtualDisplayService.swift` 仍有 1300 行。Rebuild/teardown 相关方法（L450-L800）和 waiter 基础设施（L840-L1300）可提取。

### 修改方案

#### [NEW] `Features/VirtualDisplay/Services/DisplayTeardownCoordinator.swift`

提取 teardown/offline wait 基础设施逻辑：

**从 `VirtualDisplayService.swift` 提取的方法**：

| 方法 | 行范围 |
|------|--------|
| `waitForTermination(configId:expectedGeneration:timeout:)` | L948-L990 |
| `cancelTerminationWaiter(configId:expectedGeneration:)` | 约 L995-L1020 |
| `completeTerminationWaitersIfPossible()` | 约 L1020-L1040 |
| `cancelAllTerminationWaiters()` | 约 L1040-L1060 |
| `waitForManagedDisplayOffline(serialNum:timeout:)` | L992-L1080 |
| `cancelAllOfflineWaiters()` | 约 L1090-L1110 |
| `completeOfflineWaitersIfPossible()` | 约 L1110-L1140 |
| `waitForTeardownSettlement(configId:serialNum:...)` | 约 L1140-L1200 |
| `waitForManagedDisplaysOffline(serialNumbers:timeout:)` | L683-L700 |
| `settleRebuildTeardown(configId:serialNum:generationToWaitFor:)` | L642-L681 |
| `isManagedDisplayOnline(serialNum:)` | 约 L1200+ |

**新类签名**：

```swift
@MainActor
final class DisplayTeardownCoordinator {
    init(
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool,
        isReconfigurationMonitorAvailable: Bool
    )
    
    func waitForTermination(configId: UUID, expectedGeneration: UInt64, timeout: TimeInterval) async -> Bool
    func waitForManagedDisplayOffline(serialNum: UInt32, timeout: TimeInterval) async -> Bool
    func waitForTeardownSettlement(...) async -> TeardownSettlement
    func settleRebuildTeardown(...) async throws -> Bool
    func completeOfflineWaitersIfPossible()
    func completeTerminationWaitersIfPossible()
    func cancelAllTerminationWaiters()
    func cancelAllOfflineWaiters()
    // ... 其他 waiter 管理方法
}
```

`VirtualDisplayService` 持有 `DisplayTeardownCoordinator` 实例，将 waiter 调用委托给它。

#### [MODIFY] `VirtualDisplayService.swift`

- 删除所有已提取的 waiter 方法和相关 state（`terminationWaitersByConfigId`, `offlineWaitersByToken`）
- 新增 `private let teardownCoordinator: DisplayTeardownCoordinator` 属性
- 在 `init` 中创建 coordinator 并传入依赖
- 所有 `waitForTermination`/`waitForManagedDisplayOffline` 调用改为 `teardownCoordinator.xxx`

**预期效果**: `VirtualDisplayService.swift` 降至 ~800 行

---

## 验证计划

每个问题修完后：

```bash
# 编译检查
xcodebuild build \
  -project VoidDisplay.xcodeproj \
  -scheme VoidDisplay \
  -destination 'platform=macOS' \
  -configuration Debug \
  2>&1 | tail -20

# 全部单元测试
xcodebuild test \
  -project VoidDisplay.xcodeproj \
  -scheme VoidDisplay \
  -destination 'platform=macOS' \
  -only-testing:VoidDisplayTests \
  2>&1 | tail -50
```

---

## AI 执行约束（补充）

为避免大规模重构出现隐性回归，执行时必须额外满足以下约束：

1. 使用项目固定门禁链路，不以 `xcodebuild test` 代替：

```bash
# 编译检查
xcodebuild build \
  -project VoidDisplay.xcodeproj \
  -scheme VoidDisplay \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug

# 单测门禁
scripts/test/unit_gate.sh \
  --project /Users/syc/Project/VoidDisplay/VoidDisplay.xcodeproj \
  --destination "platform=macOS,arch=arm64" \
  --derived-data-path .derivedData \
  --result-bundle-path UnitTests.xcresult \
  --enable-code-coverage YES \
  --only-testing VoidDisplayTests \
  --skip-testing VoidDisplayUITests

# 覆盖率门禁
scripts/test/coverage_guard.sh --xcresult UnitTests.xcresult
```

2. 问题 3（`DisplayTeardownCoordinator`）执行时，waiter 相关状态必须单点持有：
   - `terminationWaitersByConfigId`、`offlineWaitersByToken`、offline polling fallback 状态只允许存在于 coordinator
   - `VirtualDisplayService` 不再维护同名状态，避免双写与竞态

3. 问题 3 的迁移顺序必须是：
   1. 先迁移 low-level waiter 方法与状态
   2. 再迁移 `waitForTeardownSettlement` / `settleRebuildTeardown` / `waitForManagedDisplaysOffline`
   3. 每一步都执行完整门禁

4. 全部改动完成后，必须额外连续执行 3 轮 `unit_gate`，确认无随机失败。

5. 覆盖率基线更新规则：
   - 新增 tracked 文件时，初始 minimum 不得设为 `0.00`（除非无可测试路径并在文档中说明）
   - 若已新增测试且覆盖率明显提升，应同步提升 minimum 到合理阈值。

## 执行顺序

```
问题 1（Monitor 合并）→ 问题 2（AppHelper 瘦身）→ 问题 3（VDS 拆分）
```

问题 1 和 3 互相独立，但问题 2 依赖问题 1 和 3 都完成后再最终验证（因为 AppHelper 的转发方法引用了 Controller 方法签名）。
