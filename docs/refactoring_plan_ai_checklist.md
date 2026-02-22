# VoidDisplay 重构执行指令清单（AI 版）

> 本文件是“可直接执行”的 AI 指令清单。  
> 原计划文件 `docs/refactoring_plan.md` 仅作为背景说明，不在本清单执行中直接改写。  
> 允许单个超大 PR，一次性完成全部阶段。

---

## 0. 执行总约束

1. 目标：功能行为不变，代码结构重构，清理屎山与冗余实现。
2. 非目标：向后兼容历史内部实现细节。
3. 允许：大规模文件移动、拆分、命名调整、内部可见性调整。
4. 必须：每个阶段完成后通过门禁再继续下一阶段。
5. 禁止：为了“省事”删除关键容错语义（例如 `reset -> fallback save([])`）。

---

## 1. 固定门禁命令（每阶段必跑）

```bash
# 编译检查
xcodebuild build \
  -project VoidDisplay.xcodeproj \
  -scheme VoidDisplay \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug

# 单元测试门禁
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

执行策略：
1. 每个阶段结束后完整执行以上三条。
2. 任一失败即停止进入下一阶段。
3. 失败时输出“失败阶段 + 失败命令 + 失败摘要 + 建议修复点”。

---

## 2. Phase 1 指令：AppHelper 拆分

输入范围：
1. `VoidDisplay/App/VoidDisplayApp.swift`

执行动作：
1. 新建 `VoidDisplay/App/VirtualDisplayController.swift`，迁移虚拟显示器域状态与方法。
2. 新建 `VoidDisplay/App/SharingController.swift`，迁移共享域状态与方法。
3. 新建 `VoidDisplay/App/CaptureController.swift`，迁移监控域状态与方法。
4. 新建 `VoidDisplay/App/UITestFixture.swift`，迁移 UI 测试 fixture 逻辑。
5. 将 `AppHelper` 缩减为外观协调器，仅负责初始化与环境注入。
6. 将 `AppSettingsView` 与 `CaptureDisplayWindowRoot` 从 `VoidDisplayApp.swift` 拆出独立文件（按上下文就近放置）。
7. 已知合法常量 UUID 使用 `UUID(uuidString: "...")!`。

验收标准：
1. `VoidDisplayApp.swift` 行数显著下降，且 `AppHelper` 不再承载三域业务细节。
2. UI 测试场景行为保持现状。
3. 阶段门禁通过。

---

## 3. Phase 2 指令：VirtualDisplayService 拆分

输入范围：
1. `VoidDisplay/Features/VirtualDisplay/Services/VirtualDisplayService.swift`

执行动作：
1. 新建 `DisplayTopology.swift`，提取拓扑模型/协议/系统实现。
2. 新建 `DisplayReconfigurationMonitor.swift`，提取回调监控协议与实现。
3. 新建 `VirtualDisplayServiceProtocol.swift`，迁移协议与一致性扩展。
4. 新建 `TopologyHealthEvaluator.swift`，提取拓扑健康评估逻辑。
5. 将 `bounds.width > 1 && bounds.height > 1` 抽成统一语义（例如 `isViable`）。
6. 清理 `VirtualDisplayService.swift`，仅保留服务编排核心。
7. 将 `#if DEBUG` 测试钩子改为可测试的 `internal` 结构或独立可注入依赖，不保留生产内联测试入口。

验收标准：
1. `VirtualDisplayService.swift` 下降至约 800 行目标区间（允许小幅偏差）。
2. 拓扑相关测试继续通过。
3. 阶段门禁通过。

---

## 4. Phase 3 指令：代码清理

执行动作：
1. 删除废弃别名：`WebServiceControlling`。
2. 修正 `HomeView.swift` 文件头注释名。
3. 清理无用 `import`（以编译器与静态检查为准）。
4. 保留 `VirtualDisplayPersistenceService.resetConfigs()` 的 fallback 容错语义；补全该分支测试与日志断言。
5. 简化 `VirtualDisplayService.enableDisplay()` 内重复赋值/分支。
6. 提取 `disableDisplay` 与 `disableDisplayByConfig` 的重复清理逻辑。

验收标准：
1. 无行为回归。
2. 无新增编译 warning（排除第三方或已知 deprecated）。
3. 阶段门禁通过。

---

## 5. Phase 4 指令：架构改进

执行动作：
1. 消除散落的手动 `syncXxxState()` 风险：
   1. 首选自动通知模型。
   2. 若不改通知机制，则统一使用 `defer { syncState() }` 集中化。
2. 消除生产代码中的 `isUITestMode` 业务分支渗透：
   1. 用测试注入对象替代生产分支判断。
3. 整理测试入口：
   1. 不依赖 `#if DEBUG` 公开测试入口。
   2. 优先依赖可注入依赖 + `internal` 可见性 + `@testable import`。

验收标准：
1. `AppHelper` 与服务层不再混杂 UI 测试专用分支。
2. 可测试性不下降（现有测试通过，关键新结构有对等测试）。
3. 阶段门禁通过。

---

## 6. Phase 5 指令：View 层精简

执行动作：
1. 拆分 `ShareView.swift` 为主骨架 + 列表 + 状态面板子视图。
2. 从 `VirtualDisplayView.swift` 提取 `VirtualDisplayRow.swift`。
3. 从 `CaptureChoose.swift` 提取行组件。
4. 保持现有 UI 行为、标识符和交互语义不变。

验收标准：
1. 大体量 View 文件显著瘦身。
2. UI smoke 不出现新增可复现 assertion failure。
3. 阶段门禁通过。

---

## 7. Phase 6 指令：测试与 CI 收口

执行动作：
1. 新增测试：
   1. `VirtualDisplayControllerTests.swift`
   2. `SharingControllerTests.swift`
   3. `TopologyHealthEvaluatorTests.swift`
   4. `DisplayTopologyTests.swift`
2. 更新受影响测试（`AppHelperTests`、拓扑恢复、offline wait 等）。
3. 校验覆盖率基线不回退，必要时仅在达标后更新 tracked minimum。
4. 连续执行 3 轮 `unit_gate` 验证稳定性。

验收标准：
1. Unit Tests 全绿。
2. Coverage guard 全绿。
3. 连续 3 轮无随机失败。
4. 输出重构后风险清单（已覆盖区域 / 未覆盖高风险区域）。

---

## 8. 最终交付格式（执行完成后）

1. 变更摘要：按模块列出“拆分了什么、为何不改行为”。
2. 风险摘要：列出仍高风险区域与后续建议。
3. 验证摘要：贴出三类门禁结果（build/unit/coverage）。
4. 如有提交：使用中文 commit message，标题一句话 + 分段正文。

---

## 9. 停止条件（必须中断执行）

1. 出现无法消除的行为变化且无业务确认。
2. 关键门禁连续失败且定位到架构方案本身冲突。
3. 出现与本计划无关但影响范围大的工作区异常改动，需先确认处理策略。
