# VirtualDisplayService 终极拆分计划

## 问题分析

[VirtualDisplayService.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/VirtualDisplayService.swift) 目前 1229 行，承担了以下 **5 大职责**：

1. **配置管理** — CRUD、重排序、序列号分配、持久化委托
2. **运行时生命周期** — 创建/销毁 [CGVirtualDisplay](file:///Users/syc/Project/VoidDisplay/LICENSE_CGVirtualDisplay)、代数追踪 (generations)、display ID hints、termination 回调处理
3. **启用编排** — `enableDisplay()` 161行的复杂异步流程（settlement 等待 → cooldown → 重试创建 → 拓扑恢复 → 回滚）
4. **主显示器策略** — `resolveMainDisplayPolicy()` + `reconcileMainDisplayPolicyIfNeeded()` + 关联的 aggressive recovery 标记追踪
5. **基础设施** — 拓扑快照获取、自适应冷却等待、日志、诊断

## 设计原则

- **不做 Façade** — 每个新类必须完整拥有自己的状态和逻辑，不是纯转发
- **一步到位** — 不留过渡 API、不留兼容桥接
- **保持现有 Controller 层不变** — `VirtualDisplayController` 继续对 Service 整体做 `mutateAndSync`，只是 Protocol 接口可能微调
- **保持可测试性** — 每个新组件可独立注入 mock 测试

## 拆分方案

### 新的职责划分

```
VirtualDisplayService (瘦身后 ~400 行)
  ├─ owns: VirtualDisplayConfigManager (NEW, ~200 行)
  ├─ owns: VirtualDisplayRuntimeTracker (NEW, ~300 行)  
  ├─ owns: MainDisplayPolicyResolver (NEW, ~180 行)
  ├─ delegates to: DisplayRebuildCoordinator (已有, 629 行)
  └─ delegates to: DisplayTeardownCoordinator (已有, 400 行)
```

> [!IMPORTANT]
> `VirtualDisplayService` **不会变成 Façade**。拆分后它仍然是唯一拥有 `enableDisplay()` / `disableDisplay()` 这些需要跨组件协调的编排逻辑的地方。新提取的组件是它的内部实现细节（组合关系），不是平行服务。

---

### 组件 1: `VirtualDisplayConfigManager`

**职责**: 完全拥有配置集合的生命周期 — 增删改查、重排序、序列号分配、持久化委托

**从 VirtualDisplayService 迁出的状态**:
- `displayConfigs: [VirtualDisplayConfig]`

**从 VirtualDisplayService 迁出的方法**:
- `getConfig(_:)`, `getConfig(for:)`, `updateConfig(_:)`, `updateConfig(for:modes:)`
- `moveConfig(_:direction:)`, `moveConfigToFirstEnabledPosition(_:)`
- `nextAvailableSerialNumber()`
- `persistConfigs(reason:)` (变为内部实现)
- `replaceDisplayConfigs(_:)` (测试辅助)

**保留的外部依赖**:
- `VirtualDisplayConfigRepository` (注入)
- 需要知道当前 `activeDisplaysByConfigId` 的 serial 以计算 `nextAvailableSerialNumber` → 通过闭包或回调拿到

#### [NEW] [VirtualDisplayConfigManager.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/VirtualDisplayConfigManager.swift)

```swift
@MainActor
final class VirtualDisplayConfigManager {
    private(set) var configs: [VirtualDisplayConfig] = []
    let configRepository: VirtualDisplayConfigRepository
    private let activeSerialNumbersProvider: () -> Set<UInt32>

    // init, CRUD, reorder, persistence, nextAvailableSerialNumber
}
```

---

### 组件 2: `VirtualDisplayRuntimeTracker`

**职责**: 完全拥有运行时显示器实例的创建/追踪/清理 — [CGVirtualDisplay](file:///Users/syc/Project/VoidDisplay/LICENSE_CGVirtualDisplay) 对象引用、display ID hints、代数分配、termination 回调处理

**从 VirtualDisplayService 迁出的状态**:
- `displays: [CGVirtualDisplay]`
- `activeDisplaysByConfigId: [UUID: CGVirtualDisplay]`
- `runtimeDisplayIDHintsByConfigId: [UUID: CGDirectDisplayID]`
- `runtimeGenerationByConfigId: [UUID: UInt64]`
- `runningConfigIds: Set<UUID>`
- `nextRuntimeGeneration: UInt64`

**从 VirtualDisplayService 迁出的方法**:
- `createRuntimeDisplay(from:maxPixels:)` (核心创建逻辑)
- `createRuntimeDisplayWithRetries(from:terminationConfirmed:)`
- `handleVirtualDisplayTermination(configId:serialNum:generation:)`
- `allocateRuntimeGeneration()`
- `clearRuntimeTracking(configId:serialNum:keepGeneration:)`
- `clearRuntimeTrackingForSerialNum(_:keepGeneration:)`
- `runtimeDisplay(for:)`, `runtimeDisplayID(for:)`, `isVirtualDisplayRunning(configId:)`
- `runtimeDisplayIDForSerial(_:)`
- `applyModes(configId:modes:)` (直接操作 [CGVirtualDisplay](file:///Users/syc/Project/VoidDisplay/LICENSE_CGVirtualDisplay))
- `rollbackEnableRuntimeState(configId:serialNum:)`
- `seedRuntimeBookkeeping(...)`, `runtimeBookkeeping(...)` (测试辅助)

**保留的外部依赖**:
- `DisplayTeardownCoordinator` — termination 回调通知
- `VirtualDisplayConfig` — 由 ConfigManager 提供

#### [NEW] [VirtualDisplayRuntimeTracker.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/VirtualDisplayRuntimeTracker.swift)

```swift
@MainActor
final class VirtualDisplayRuntimeTracker {
    private(set) var displays: [CGVirtualDisplay] = []
    private(set) var activeDisplaysByConfigId: [UUID: CGVirtualDisplay] = [:]
    private(set) var runtimeDisplayIDHintsByConfigId: [UUID: CGDirectDisplayID] = [:]
    private(set) var runtimeGenerationByConfigId: [UUID: UInt64] = [:]
    private(set) var runningConfigIds: Set<UUID> = []
    
    let teardownCoordinator: DisplayTeardownCoordinator
    
    // create, track, clear, terminate, apply modes
}
```

---

### 组件 3: `MainDisplayPolicyResolver`

**职责**: 完全拥有主显示器策略解析逻辑 — 确定哪个虚拟显示器应该成为主显示器、aggressive recovery 状态追踪

**从 VirtualDisplayService 迁出的状态**:
- `aggressiveRecoveryPendingEnableConfigIDs: Set<UUID>`

**从 VirtualDisplayService 迁出的方法/类型**:
- `MainDisplayPolicySource` enum
- `MainDisplayPolicyResolution` struct
- `resolveMainDisplayPolicy(snapshot:emitLog:)` — 整个方法体
- `logMainDisplayPolicyResolution(_:)`
- `reconcileMainDisplayPolicyIfNeeded()` — 整个方法体
- `markAggressiveRecoveryPendingForSerial(_:)`
- `clearAggressiveRecoveryPendingForSerial(_:)`

**保留的外部依赖**:
- 需要查询配置列表 (`configs.filter(\.desiredEnabled)`) → 由外部提供闭包
- 需要查询 `runtimeDisplayID(for:)` → 由外部提供闭包
- 需要调用 `ensureHealthyTopologyAfterEnable` → 由外部提供闭包

#### [NEW] [MainDisplayPolicyResolver.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/MainDisplayPolicyResolver.swift)

```swift
@MainActor
final class MainDisplayPolicyResolver {
    private(set) var aggressiveRecoveryPendingEnableConfigIDs: Set<UUID> = []

    struct Dependencies {
        var enabledDesiredConfigs: () -> [VirtualDisplayConfig]
        var runtimeDisplayID: (UUID) -> CGDirectDisplayID?
        var allConfigs: () -> [VirtualDisplayConfig]
    }

    // resolve, reconcile, mark/clear aggressive recovery
}
```

---

### 组件 4: 瘦身后的 `VirtualDisplayService` (~400 行)

**保留的职责** — 这些逻辑 **需要协调多个组件**，是 Service 作为"编排层"的核心价值：

- `enableDisplay()` — 需要协调 ConfigManager（更新 desiredEnabled）+ RuntimeTracker（settlement 等待/创建）+ PolicyResolver（main policy 判断）+ RebuildCoordinator（topology 恢复）
- `disableDisplay()` / `disableDisplayByConfig()` — 需要协调 ConfigManager + RuntimeTracker + PolicyResolver
- `createDisplay()` — 需要协调 ConfigManager（添加 config）+ RuntimeTracker（创建运行时）
- `destroyDisplay()` — 需要协调 ConfigManager（删除 config）+ RuntimeTracker（清理运行时）+ PolicyResolver（清理标记）
- `loadPersistedConfigs()`, `restoreDesiredVirtualDisplays()`, `resetAllVirtualDisplayData()`
- `currentTopologySnapshot()` / 基础设施
- 各种诊断/日志辅助 (`describe(snapshot:)`, `logTopologySnapshot`)

**VirtualDisplayService 对外暴露的状态改为委托读取**:
```swift
var displays: [CGVirtualDisplay] { runtimeTracker.displays }
var displayConfigs: [VirtualDisplayConfig] { configManager.configs }
var runningConfigIds: Set<UUID> { runtimeTracker.runningConfigIds }
```

---

## Proposed Changes

### VirtualDisplay/Services

#### [NEW] [VirtualDisplayConfigManager.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/VirtualDisplayConfigManager.swift)

从 `VirtualDisplayService` 提取配置管理逻辑。

#### [NEW] [VirtualDisplayRuntimeTracker.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/VirtualDisplayRuntimeTracker.swift)

从 `VirtualDisplayService` 提取运行时生命周期追踪逻辑。

#### [NEW] [MainDisplayPolicyResolver.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/MainDisplayPolicyResolver.swift)

从 `VirtualDisplayService` 提取主显示器策略逻辑。

#### [MODIFY] [VirtualDisplayService.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/VirtualDisplayService.swift)

瘦身为编排层，组合使用上述三个组件。保留 `enableDisplay()`, `disableDisplay()`, `createDisplay()`, `destroyDisplay()` 等需要跨组件协调的编排方法。常量、错误类型、nested types 保留在此处。

#### [MODIFY] [VirtualDisplayServiceProtocol.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/VirtualDisplayServiceProtocol.swift)

Protocol 接口保持不变 — Controller 不需要知道内部拆分细节。

#### [MODIFY] [DisplayRebuildCoordinator.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/DisplayRebuildCoordinator.swift)

将 `unowned let service: VirtualDisplayService` 改为通过 protocol 或直接引用新的子组件（`runtimeTracker`, `configManager`），减少对 VirtualDisplayService 整体的直接依赖。

---

### VirtualDisplay/Tests

#### [MODIFY] [VirtualDisplayServiceLightTests.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplayTests/Features/VirtualDisplay/VirtualDisplayServiceLightTests.swift)

- 现有测试继续通过 `VirtualDisplayService` 调用保持不变（Service 仍对外暴露同样的 API）
- 新增针对 `VirtualDisplayConfigManager` 的独立单元测试（config CRUD、reorder、serial 分配）
- 新增针对 `MainDisplayPolicyResolver` 的独立单元测试（policy resolution 各分支）

#### [NEW] [VirtualDisplayConfigManagerTests.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplayTests/Features/VirtualDisplay/VirtualDisplayConfigManagerTests.swift)

独立测试 ConfigManager 的 CRUD、重排序、持久化委托逻辑。

#### [NEW] [MainDisplayPolicyResolverTests.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplayTests/Features/VirtualDisplay/MainDisplayPolicyResolverTests.swift)

独立测试 Policy 解析逻辑。现有 `VirtualDisplayServiceLightTests` 中的 `resolveMainDisplayPolicy*` 系列测试可以搬到这里。

#### [NEW] [VirtualDisplayRuntimeTrackerTests.swift](file:///Users/syc/Project/VoidDisplay/VoidDisplayTests/Features/VirtualDisplay/VirtualDisplayRuntimeTrackerTests.swift)

独立测试运行时追踪逻辑（代数分配、清理、display ID hint 管理）。

---

## User Review Required

> [!IMPORTANT]
> **关键设计决策：子组件的暴露方式**
>
> 方案 A: 子组件完全内部化 — 外部只通过 `VirtualDisplayService` 访问一切，Protocol 完全不变
>
> 方案 B: 子组件部分暴露 — `DisplayRebuildCoordinator` 直接引用 `runtimeTracker` 和 `configManager` 而不是 `service`
>
> **推荐方案 B** — 因为 `DisplayRebuildCoordinator` 现在通过 `unowned let service` 直接访问 Service 的内部状态字段（如 `service.displayConfigs`, `service.runningConfigIds`, `service.runtimeDisplayIDHintsByConfigId`），如果保持这种方式， Service 需要继续暴露这些字段。将 RebuildCoordinator 改为引用具体的子组件可以彻底消除这种跨层耦合。

> [!WARNING]
> **`DisplayRebuildCoordinator` 的改造范围**
>
> RebuildCoordinator (629行) 大量直接访问 `service.*` 字段。拆分后需要将所有这些访问改为对 `runtimeTracker.*` 和 `configManager.*` 的访问。一次性改完，不留中间态。

---

## Verification Plan

### Automated Tests

所有改动通过现有 CI 命令验证：

```bash
# 运行全部单元测试（与 CI 一致）
xcodebuild test \
  -project VoidDisplay.xcodeproj \
  -scheme VoidDisplay \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .derivedData \
  -resultBundlePath UnitTests-refactor.xcresult \
  -enableCodeCoverage YES \
  -only-testing VoidDisplayTests \
  -skip-testing VoidDisplayUITests
```

**验收标准**:
1. 所有 38 个现有测试文件 **全部通过**，零回归
2. 新增的 3 个测试文件全部通过
3. 代码覆盖率不低于重构前

### Manual Verification

无需额外手动测试 — 这是纯内部架构重构，不改变任何外部行为。所有现有单元测试+UI Smoke 测试覆盖了完整的功能路径。
