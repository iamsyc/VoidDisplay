# FreelyDisplay 重构执行计划（AI落实版）

## 执行状态（截至 2026-02-06）

- 已完成：阶段 1 -> 10（当前进行收口与一致性修订）
- 当前基线：
  - `xcodebuild test`（无付费证书）可稳定通过
  - 核心链路已拆分为可维护服务层 + ViewModel
  - Web 路由、配置迁移、LAN IP 策略、共享状态机已有单测覆盖
  - 统一日志与错误映射已落地

> 说明：这是给执行者（AI）使用的落地计划，不按固定时间排期，以“持续推进直到完成”为原则。

## 1. 建立可重构基线与回归护栏

目标：
- 先补最小可用测试和可重复命令，让后续每一步重构都可验证。

执行：
- 在 `/Users/syc/Project/FreelyDisplay/FreelyDisplayTests/FreelyDisplayTests.swift` 补纯模型与纯函数测试。
- 覆盖分辨率计算、物理尺寸换算、配置序列化/反序列化等稳定逻辑。
- 固化验证命令：
  - `xcodebuild -scheme FreelyDisplay -project /Users/syc/Project/FreelyDisplay/FreelyDisplay.xcodeproj -configuration Debug test -destination 'platform=macOS,arch=arm64'`

验收：
- 命令稳定通过，且可用于每次重构后回归。

## 2. 拆分 AppHelper 巨型职责

目标：
- 将 `AppHelper` 从单体状态类拆成可维护领域服务。

执行：
- 以 `/Users/syc/Project/FreelyDisplay/FreelyDisplay/FreelyDisplayApp.swift` 为入口。
- 拆分为：
  - `VirtualDisplayService`
  - `CaptureMonitoringService`
  - `SharingService`
  - `WebServiceController`
- `AppHelper` 仅负责组装、依赖注入与状态桥接。

验收：
- 现有 UI 功能行为不变。
- 业务代码跨域依赖显著减少。

## 3. 强化虚拟显示配置与持久化边界

目标：
- 明确“持久化配置”和“运行时状态”的边界，并具备迁移能力。

执行：
- 重构：
  - `/Users/syc/Project/FreelyDisplay/FreelyDisplay/VirtualDisplayConfig.swift`
  - `/Users/syc/Project/FreelyDisplay/FreelyDisplay/VirtualDisplayStore.swift`
- 增加 schema migration 路径，提升损坏文件/缺失字段时的恢复能力。

验收：
- 旧配置可平滑读取。
- 存储异常不会导致 UI 崩溃。

## 4. 重构屏幕采集并发边界

目标：
- 解决采集、编码、发布阶段的并发与生命周期风险。

执行：
- 重构 `/Users/syc/Project/FreelyDisplay/FreelyDisplay/ScreenCaptureFunction.swift`。
- 明确 actor/queue 所属，避免跨线程共享可变状态。
- 统一帧数据流向：采集 -> 编码 -> 主线程发布。

验收：
- 长时间运行无崩溃、无明显资源泄漏。
- 采集帧率与延迟波动可控。

## 5. 将 Web 共享服务改为可测试协议层

目标：
- 把网络分享从“面向实现”改为“面向协议行为”。

执行：
- 重构：
  - `/Users/syc/Project/FreelyDisplay/FreelyDisplay/WebShare/WebServer.swift`
  - `/Users/syc/Project/FreelyDisplay/FreelyDisplay/WebShare/HttpHelper.swift`
- 分层为：
  - HTTP 解析
  - 路由决策
  - MJPEG 流输出

验收：
- `/`、`/stream`、错误路径行为可预测且可单测。

## 6. 收敛 UI 状态流，减轻 View 业务负担

目标：
- 让 View 聚焦渲染，业务决策下沉至状态对象/服务层。

执行：
- 逐步重构：
  - `/Users/syc/Project/FreelyDisplay/FreelyDisplay/VirtualDisplayView.swift`
  - `/Users/syc/Project/FreelyDisplay/FreelyDisplay/ShareView.swift`
  - `/Users/syc/Project/FreelyDisplay/FreelyDisplay/CaptureChoose.swift`
- 引入轻量 ViewModel/State 对象承接事件编排。

验收：
- View 内复杂逻辑显著减少。
- 状态变更路径可追踪。

## 7. 统一错误处理与可观测性

目标：
- 避免零散 `print/NSLog`，形成统一错误语义与日志策略。

执行：
- 抽象错误分层：用户可读错误、开发诊断错误、系统异常错误。
- 统一关键路径日志：创建失败、权限拒绝、流中断、网络断开。

验收：
- 出错后可快速定位到模块与上下文。
- 用户提示与开发日志解耦。

## 8. 补齐核心行为测试矩阵（无付费证书可运行）

目标：
- 让关键功能由自动化测试守护，减少人工回归负担。

执行：
- 单元测试重点覆盖：
  - 配置迁移
  - 串号冲突
  - 启停状态机
  - 模式应用
  - HTTP 解析与路由
  - LAN IP 选择策略
- UI 测试保留最小冒烟且默认可跳过。

验收：
- `xcodebuild test` 在本地无付费证书环境可稳定运行。

## 9. 清理结构与文档

目标：
- 去除历史负担，形成当前实现的一致性文档。

执行：
- 清理废弃代码、重复逻辑、命名不一致项。
- 更新：
  - `/Users/syc/Project/FreelyDisplay/Readme.md`
  - `/Users/syc/Project/FreelyDisplay/docs/Readme_cn-zh.md`
- 补充“架构边界、调试入口、常见故障定位”说明。

验收：
- 新接手者可按文档快速理解和调试项目。

## 10. 执行策略（持续落实）

执行原则：
- 按顺序推进：先可测、再拆分、后优化。
- 每一步保持：
  - 可编译
  - 可测试
  - 可回退
- 仅在影响功能边界或设计取舍时中断并请求决策，其余默认直接落地。
