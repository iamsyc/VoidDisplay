# FreelyDisplay UI/UX/功能优化执行计划

## 目标
- 建立一致、可复用、可回归的 UI/UX 基础。
- 在不牺牲稳定性的前提下提升关键流程效率（虚拟显示器、屏幕共享、屏幕监听）。
- 清理多语言、状态反馈、错误反馈中的不一致问题。

## 阶段划分

### 阶段 0：审计与问题清单（进行中）
交付物：
- 统一问题清单（按 P0/P1/P2 优先级）。
- 每项问题绑定页面/文件、影响范围、验收标准。

当前审计结论（首批）：
- P0：共享、监听、虚拟显示器页面的状态反馈样式不一致，用户难以快速识别“当前可执行动作”。
- P0：多语言存在遗漏，新增文案回归风险高。
- P1：同类交互（权限请求/刷新/重试）在不同页面表达不统一。
- P1：空状态和错误状态样式不统一，信息层级混乱。
- P2：页面间间距、圆角、卡片层级等视觉语言未统一，维护成本高。

### 阶段 1：Design System Lite（进行中）
交付物：
- 轻量 UI 基础层（间距、圆角、面板样式、状态徽章）。
- 可复用修饰器/组件，先在屏幕共享页落地。

验收标准：
- 新页面不再重复写散落的硬编码样式。
- 至少 1 个核心流程页面完整接入基础样式层并通过回归测试。

### 阶段 2：关键流程 UX 重构
范围：
- 虚拟显示器：列表信息层级、启停与编辑动作优先级、重建提示语义。
- 屏幕共享：状态区、共享中态、权限态、错误态统一。
- 屏幕监听：与屏幕共享保持一致的权限与错误反馈逻辑。

验收标准：
- 核心动作（启用/停止/共享/监听）路径清晰，状态可见。
- 主要页面空状态/错误状态统一。

### 阶段 3：功能优化
范围：
- 配置预设优化（常用分辨率/刷新率快捷）。
- 批量动作（按需引入，不增加主路径复杂度）。
- 共享会话诊断信息（连接数/最近错误摘要）。

### 阶段 4：多语言与可访问性治理
范围：
- 全量清理硬编码文案与缺失翻译。
- 统一术语字典（运行中/进行中/共享中等）。
- VoiceOver、键盘导航、对比度、点击热区检查。

### 阶段 5：质量护栏
范围：
- ViewModel 状态机测试补齐。
- 关键页面 UI smoke 测试。
- 发布前 UI/权限/共享流程检查清单。

## 本轮已落地
- 新增 `Shared/UI/AppUI.swift`：
  - 统一间距、圆角、描边厚度 Token。
  - `appPanelStyle()` 统一面板样式。
  - `AppStatusBadge` 状态徽章组件。
- `Features/Sharing/Views/ShareView.swift` 接入基础样式层（状态区与共享中卡片）。
- `Features/VirtualDisplay/Views/VirtualDisplayView.swift` 完成行布局重构：
  - 启停作为主操作按钮。
  - 排序/编辑/删除收敛到次操作菜单，降低页面拥挤度。
  - 卡片与状态展示接入统一样式层。
- `Features/VirtualDisplay/Views/DisplaysView.swift` 接入统一卡片样式与空状态展示。
- `Features/Capture/Views/CaptureChoose.swift` 与 `IsCapturing` 完成统一样式改造：
  - 监听目标列表/进行中会话列表使用同一视觉层级和状态徽章。
  - 停止监听动作语义化（`Stop Monitoring`）并补齐对应词条。
- 提取权限引导共享组件 `Shared/UI/ScreenCapturePermissionGuideView.swift`：
  - `CaptureChoose` 与 `ShareView` 共用同一权限引导 UI。
  - 统一按钮、提示文案、Debug 信息结构，避免双份实现漂移。
- 新增多语言审计脚本 `scripts/localization_audit.sh` 并输出最新报告 `docs/localization-audit-latest.md`：
  - `Missing zh-Hans keys = 0`
  - `Stale extraction keys = 0`
- 共享会话摘要首版落地：
  - `ShareView` 状态区新增“连接客户端”实时计数（1s 刷新）。
  - 数据链路从 `StreamHub` 透传至 `WebServer` / `SharingService` / `AppHelper`。
  - 为 `SharingService` 增加连接数透传单测。

## 下一轮执行项
1. 细化共享会话信息展示（最后错误摘要、连接波动提示）并补充对应测试。
2. 继续清理 `Potential hard-coded UI strings` 列表中的高频页面（`HomeView`、设置页、共享页提示文本）。
3. 补充关键页面的 UI smoke 检查清单，落入发布前自检流程。
