# DisplayRuntime 文档索引

状态：当前架构索引
用途：给 DisplayRuntime 重构后的阅读入口、历史阶段文档状态和主路线收尾边界提供单一导航。

## 阅读顺序

1. [产品定位与架构重构前置结论](./product-positioning.md)：先确认 VoidDisplay 的产品边界、`DisplaySurface` 对象、`DisplayRuntime` 控制平面定位、LAN Web View 安全边界和远程控制边界。
2. [DisplayRuntime 重构执行计划](./display-runtime-refactor-plan.md)：再阅读主路线图。该路线已经完成，现作为 Phase 1 到 Phase 6 的历史总览和架构索引入口。
3. Phase 1 到 Phase 6 历史文档：按阶段阅读当时的目标、边界、验证门禁和实现记录。这些文件是历史计划或执行记录，不再作为当前待办清单。
4. [DisplayRuntime Post-Refactor Cleanup Plan](./display-runtime-post-refactor-cleanup-plan.md)：最后阅读主路线完成后的收尾计划。收尾计划不使用新的阶段编号。

## 当前架构状态

- Phase 1 到 Phase 6 已完成。
- `DisplayRuntime` 是控制平面，负责状态、事件、事务、使用方租约、快照和意图分发。
- `DisplaySurface` 是产品聚合对象，表达虚拟显示器、物理显示器、捕获状态、观看者、分享 URL、诊断状态和最近事务。
- Capture、WebRTC、WebSocket、HTTP 和编码帧路径属于数据平面，不进入 runtime。
- 主导航已经收敛为 `Displays` 和 `Diagnostics`。
- LAN Web View 仍是局域网观察能力，不引入 token、密码、账号体系或 auth。
- VoidDisplay 不做远程控制、输入注入、剪贴板或浏览器 agent 控制。

## Phase 文档

- [Phase 1: Runtime Model And Read-Only Snapshot](./display-runtime-phase-1-plan.md)：已完成历史记录。
- [Phase 2: Catalog Convergence Into Runtime](./display-runtime-phase-2-plan.md)：已完成历史记录。
- [Phase 3: Virtual Display Transactions](./display-runtime-phase-3-plan.md)：已完成历史记录。
- [Phase 3b: Virtual Display Command Transactions](./display-runtime-phase-3b-plan.md)：已完成历史记录，属于 Phase 3 拆分记录。
- [Phase 3b.2: Edit Rebuild Transaction](./display-runtime-phase-3b-2-plan.md)：已完成历史记录，属于 Phase 3 拆分记录。
- [Phase 3b.3: Create / Delete Transaction](./display-runtime-phase-3b-3-plan.md)：已完成历史记录，属于 Phase 3 拆分记录。
- [Phase 3c: Runtime Internal Consolidation](./display-runtime-phase-3c-plan.md)：已完成历史记录，属于 Phase 3 结构收敛记录。
- [Phase 4: Consumer Lease And Demand Aggregation](./display-runtime-phase-4-plan.md)：已完成历史记录。
- [Phase 5: Observability And Diagnostics Hardening](./display-runtime-phase-5-plan.md)：已完成历史记录。
- [Phase 6: UI Information Architecture Migration](./display-runtime-phase-6-plan.md)：已完成历史记录。

## 收尾边界

- [DisplayRuntime Post-Refactor Cleanup Plan](./display-runtime-post-refactor-cleanup-plan.md)：主路线完成后的整理计划。
- 收尾工作分为文档收口、代码复杂度审计、测试套件清理、文案与公开文档对齐、架构边界检查。
- Stage 1 已完成，只收口文档状态和导航。
- Stage 2 到 Stage 5 保持独立执行窗口，不回写为新的 DisplayRuntime 阶段。
