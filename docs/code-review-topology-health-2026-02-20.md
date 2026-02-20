# Code Review — Testability & Coverage Infrastructure

**日期**: 2026-02-20  
**范围**: 13 个已修改文件 + 9 个新文件 (433+/42-)

---

## 变更概览

本次变更的核心目标是**为服务层和 ViewModel 引入协议抽象与依赖注入，建立可测试的基础设施和 CI 覆盖率门禁**。

| 类别 | 涉及文件 |
|---|---|
| 协议提取 | `SharingService`, `CaptureMonitoringService`, `VirtualDisplayService`, `WebServiceController` |
| 依赖注入 | `AppHelper`, `CaptureChooseViewModel`, `ShareViewModel` |
| 共享 Mock | `TestServiceMocks.swift`, `AsyncTestHelpers.swift` |
| 新测试 | `AppHelperTests.swift`, `CaptureChooseViewModelTests` (3 新用例), `ShareViewModelTests` (4 新用例) |
| CI / 脚本 | `unit-tests.yml`, `ui-smoke-tests.yml`, `unit_gate.sh`, `coverage_report.sh`, `coverage_guard.sh` |
| 文档 | `coverage-baseline.json`, `refactor-readiness-checklist.md` |

---

## ✅ 做得好的地方

1. **协议设计干净** — 每个协议都是对现有 `class` 公共 API 的精确 1:1 映射，`extension SomeClass: SomeProtocol {}` 作为一致性声明，零行为变更。
2. **向后兼容** — `WebServiceControlling` 通过 `typealias WebServiceControlling = WebServiceControllerProtocol` 保留，避免了任何外部调用站点的断裂。
3. **DI 默认值策略** — `AppHelper.init` 和两个 ViewModel 的 `init` 都使用 `(any Protocol)? = nil`，生产代码路径零改动，只在测试中注入 mock。
4. **Mock 实现完整** — `MockSharingService` (118 行)、`MockVirtualDisplayService` (96 行)、`MockCaptureMonitoringService` (35 行) 都带有调用计数 (`callCount`) 和可配置返回值。
5. **异步测试模式** — `waitUntil(timeoutNanoseconds:pollNanoseconds:condition:)` 是一个简洁、可复用的轮询工具，比直接 `Task.sleep` 更健壮。
6. **CI 覆盖率棘轮 (ratchet)** — `coverage_guard.sh` + `coverage-baseline.json` 的设计可以防止覆盖率倒退，且支持按文件级别跟踪。
7. **测试用例覆盖了关键路径** — 包括权限拒绝时的状态清理、加载失败时的错误传播、服务启动失败的用户提示等。

---

## ⚠️ 需要关注的问题

### 1. `AppHelper.init` 中 `sharingService` 的 `onWebServiceRunningStateChanged` 赋值

```swift
self.sharingService.onWebServiceRunningStateChanged = { [weak self] _ in
    self?.syncSharingState()
}
```

`sharingService` 的类型是 `any SharingServiceProtocol`，这是一个 existential。对 existential 的 **属性赋值** (setter) 在 Swift 5.x 中需要 existential 的底层类型支持该操作。虽然协议已声明 `{ get set }` 并且当前代码在编译期可通过（因为底层类型确实是 `class`），但如果未来有人传入一个不支持 mutation 的 wrapper 类型，此处可能会出问题。

> [!TIP]
> 考虑在协议中将 `onWebServiceRunningStateChanged` 改为方法形式 `func setWebServiceRunningStateHandler(_ handler: ...)` 以更明确地表达 mutation 意图，或至少在协议文档中注明此属性可写。

**严重程度**: 低 — 当前可编译运行，仅是设计建议。

---

### 2. `MockVirtualDisplayService.createDisplay(...)` 无条件抛出异常

```swift
func createDisplay(...) throws -> CGVirtualDisplay {
    throw NSError(domain: "MockVirtualDisplayService", code: 1)
}
```

如果以后有测试需要验证 "成功创建虚拟显示" 的路径，当前 mock 无法支持。

> [!TIP]
> 建议改为使用可配置的 closure 或 result 属性：
> ```swift
> var createDisplayResult: Result<CGVirtualDisplay, Error> = .failure(...)
> func createDisplay(...) throws -> CGVirtualDisplay {
>     try createDisplayResult.get()
> }
> ```

**严重程度**: 低 — 目前的测试不需要成功路径。

---

### 3. `waitUntil` 的默认超时为 1 秒

在 CI 环境下（特别是 GitHub Actions），1 秒超时可能对 `await Task.sleep` 驱动的异步操作来说偏紧。`AppHelperTests.initNormalModeLoadsPersistedDataAndStartsWebService` 中的 `await waitUntil { sharing.startWebServiceCallCount == 1 }` 实际上是在等待一个内部的 `Task { @MainActor ... }` 完成，在负载较高的 runner 上可能 flaky。

> [!IMPORTANT]
> 建议为 CI 环境提供更宽松的超时，或者在特别依赖异步调度的测试中显式传入更大的 `timeoutNanoseconds`（例如 3-5 秒）。

**严重程度**: 中 — 可能导致 CI 偶发失败。

---

### 4. `coverage-baseline.json` 中的覆盖率基线偏低

```json
"app_helper": 0.1065,
"share_view_model": 0.0588,
"capture_choose_view_model": 0.0745
```

这些数字（5.9%–10.7%）作为 ratchet 基线虽然合理（代表当前实际水平），但意味着即使覆盖率只有 6% 也能通过门禁。

> [!NOTE]
> 这不是一个 bug，只是需要意识到这个基线的目的是"只涨不跌"。随着测试增加，记得定期用 `coverage_report.sh` 更新 `coverage-baseline.json`。

**严重程度**: 无 — 仅供注意。

---

### 5. `typealias WebServiceControlling = WebServiceControllerProtocol` 应标记 deprecated

```swift
typealias WebServiceControlling = WebServiceControllerProtocol
```

这个 typealias 保留了旧名称以保证向后兼容，但没有任何标注来提醒消费者迁移到新名称。

> [!TIP]
> 建议添加 `@available(*, deprecated, renamed: "WebServiceControllerProtocol")`。

**严重程度**: 低。

---

### 6. CI workflow 中 `upload-artifact` 条件变更

```yaml
# 之前
- name: Upload unit test result bundle
  if: failure()
# 之后
- name: Upload unit test result bundle
  if: always()
```

改为 `always()` 意味着即使测试全部通过，也会上传 `.xcresult` bundle。这会增加 artifact 存储成本，但也带来了更好的可追溯性。

**严重程度**: 无 — 仅需注意存储成本。

---

### 7. ~~Shell 脚本执行权限~~ ✅ 已确认

`scripts/test/` 下的三个脚本文件**已正确设置 `+x` 权限**，无需额外处理。

**严重程度**: 无。

---

## 总结

| 评级 | 说明 |
|---|---|
| 🟢 整体质量 | 代码质量高，架构决策正确，改动范围控制良好 |
| 🟡 需处理 | #3 (CI 超时风险) 建议在提交前确认 |
| 🔵 可选改进 | #1、#2、#5 属于设计层面的可选优化，不阻塞提交 |

**结论**: 此变更集是一次高质量的可测试性重构，引入了坚实的协议抽象和 CI 质量门禁。**建议确认 #3（`waitUntil` 超时）后即可提交**。
