# DisplayRuntime Post-Refactor Cleanup Plan

状态：主路线完成后的收尾计划
依据：[产品定位与架构重构前置结论](./product-positioning.md)、[DisplayRuntime 重构执行计划](./display-runtime-refactor-plan.md)
范围：DisplayRuntime Phase 1 到 Phase 6 完成后的文档、复杂度、测试、文案、本地架构边界收尾。
说明：本文明确排除 `DisplayRuntime Phase 7` 定位，不使用新的 DisplayRuntime phase 编号，也不包含继续开发新能力。它是主路线关闭后的仓库整理计划，用于把项目从完成重构整理成长期可维护、文档清晰、复杂度可控的状态。
Stage 1 状态：已完成。文档状态收口和阅读导航见 [DisplayRuntime 文档索引](./display-runtime-index.md)。Stage 2 到 Stage 5 仍按本文分别进入独立执行窗口确认后推进。

## Baseline

DisplayRuntime refactor 主路线已经关闭：

- Phase 1 到 Phase 6 已完成并通过最终审计。
- `DisplayRuntime` 是控制平面，负责状态、事件、事务、consumer lease、snapshot 和 intent dispatch。
- `DisplaySurface` 是核心聚合对象，表达虚拟显示器、物理显示器、捕获状态、观看者、分享 URL、诊断状态和最近事务。
- Capture、WebRTC、WebSocket、HTTP 是数据平面，不进入 runtime。
- Virtual Display、Monitor、LAN Web View、Diagnostics 已按 `DisplaySurface` / Runtime 结构收敛。
- 主导航已收敛为 `Displays` 和 `Diagnostics`。
- 旧 `Support Center`、旧 `Virtual Displays` / `Screen Monitoring` / `Screen Sharing` 主入口已删除。
- LAN Web View 的安全立场不变：它是局域网观察能力，不加 token、密码、账号或 auth。
- VoidDisplay 不做远程控制、输入注入、剪贴板或 browser agent control。

收尾工作必须保护已经形成的结构。删除重复和迁移残留是目标，回滚架构边界、夹带新功能、为了行数好看而合并语义清晰的模块都不合格。

## Global Rules

- 本计划只指导后续收尾，不新增功能。
- 不重写 `DisplayRuntime`。
- 不修改 Capture / WebRTC frame pipeline。
- 不修改 LAN Web View auth / security stance。
- 不做远程控制、输入注入、剪贴板或 browser agent control。
- 不做大规模 UI 美化。
- 不追求机械减少行数。
- 不删除对架构边界有价值的测试。
- 不保留 legacy compatibility，除非明确写出调用方、保留原因、移除条件和验证影响。
- 任何代码变更都必须保持 zero compile errors 和 zero compile warnings。
- 每个执行窗口开始前先确认 `git status --short`，结束前确认 diff 只包含本窗口范围。

## Stage 1: Docs Closeout And Entry Alignment

状态：已完成。本文档和 Phase 1 到 Phase 6 历史文档已经标明归档语义；当前入口见 [DisplayRuntime 文档索引](./display-runtime-index.md)。

目标：

- 把 Phase 1 到 Phase 6 的历史计划归档为已完成事实。
- 避免未来执行窗口把历史计划误当待办。
- 梳理 docs 入口，让外部读者先看到产品定位，再看到架构路线和最终状态。

执行窗口与计划模式：

- 可在同一执行窗口继续，前提是只做 docs closeout 和入口说明。
- 不需要开启计划模式；如果准备改写公开产品叙事或重排多份 public docs，先切到全新窗口并重新制定 docs-only 计划。

允许改动范围：

- 给 `docs/display-runtime-phase-1-plan.md` 到 `docs/display-runtime-phase-6-plan.md` 增加 completed 状态或收口说明。
- 给 `docs/display-runtime-refactor-plan.md` 增加主路线完成说明和最终状态指针。
- 在 docs 入口或相关文档中建立推荐阅读顺序：产品定位、DisplayRuntime 主路线、主路线完成后的收尾计划。
- 用短收口段标明历史计划中的待办已经被后续阶段或最终实现吸收。

禁止范围：

- 不重写历史计划正文。
- 不修改已审计通过的技术结论。
- 不把 cleanup 任务塞回 Phase 1 到 Phase 6。
- 不新增功能规划。

验证门禁：

- 运行 markdown / diff 检查，确认变更只涉及 docs。
- 使用 `rg` 检查 Phase 1 到 Phase 6 文档都有 completed 状态或收口说明。
- 手工审计 docs 阅读路径，确认外部读者不会先落入过期待办。

完成标准：

- Phase 1 到 Phase 6 文档从执行待办语义降级为历史记录。
- `product-positioning.md`、`display-runtime-refactor-plan.md` 和本文之间的入口关系清楚。
- 后续执行窗口能直接判断哪些内容是历史事实，哪些内容是可执行 cleanup。

## Stage 2: Code Complexity Audit And Boundary-Preserving Cleanup

目标：

- 审计 Phase 1 到 Phase 6 期间产生的过细文件、重复 helper、测试 fixture 膨胀、临时注释、迁移残留。
- 删除重复和临时路径，同时保护 Runtime / Data Plane 边界。
- 降低维护成本，不改变产品行为。

执行窗口与计划模式：

- 必须使用全新执行窗口。
- 需要先进入计划模式完成审计清单、删除候选、边界影响和验证矩阵；只有单文件注释清理这类低风险 docs-adjacent 修正可以直接执行。

允许改动范围：

- 删除已经失去调用方的迁移桥接、临时注释、旧审计辅助路径。
- 合并真正等价的 helper、fixture、DTO factory 或 test support。
- 简化只为迁移期存在的重复分支。
- 保留已形成清晰边界的 Runtime 文件拆分，即使文件数量看起来偏多。
- 对任何删除或合并先做调用方审计，再做 targeted tests。

禁止范围：

- 不新增功能。
- 不改产品行为。
- 不重写 `DisplayRuntime`。
- 不修改 Capture / WebRTC / WebSocket / HTTP frame 或 transport pipeline。
- 不把数据平面对象搬进 runtime。
- 不把 Runtime 重新绑到 SwiftUI、AppKit、controller 或 view state。
- 不为了减少文件数而破坏命令、事务、consumer lease、snapshot、observability 的边界。

验证门禁：

- 根据改动范围运行 targeted tests。
- 改 Runtime 时至少运行 `scripts/ci/unit.sh --filter VoidDisplayRuntimeTests`。
- 改 App adapters 或 presentation mapping 时至少运行相关 App tests。
- 改 shared code、build settings、脚本或 static gate 时运行 full unit 和 Xcode Debug build。
- 所有代码变更必须通过 zero warnings gate。

完成标准：

- 删除项都有明确重复、临时或失效依据。
- 复杂度下降来自边界收敛或重复删除。
- Runtime boundary、data-plane boundary、LAN auth boundary、remote-control boundary 没有回退。
- 测试覆盖没有缩水。

## Stage 3: Test Suite Cleanup

目标：

- 收敛过度碎片化的测试文件和重复 fake / test support。
- 保留关键 contract tests。
- 让测试体系继续表达架构边界，而非只堆叠 smoke 覆盖。

执行窗口与计划模式：

- 必须使用全新执行窗口。
- 需要先进入计划模式列出每个被合并或删除测试的现有覆盖点、替代覆盖点和验证命令；纯只读审计可以不进入计划模式。

允许改动范围：

- 合并重复 smoke helper、fake port、snapshot factory、command result factory 和 UI test helper。
- 删除已经被更强 contract test 覆盖的等价测试。
- 整理 Runtime、App、Sharing、Capture、UI 测试支撑，使 fixture 所属层级更清楚。
- 将重复断言收敛到单一 helper，但保留测试名对行为的可读表达。

禁止范围：

- 不删除 runtime boundary tests。
- 不删除 transaction tests。
- 不删除 consumer lease tests。
- 不删除 diagnostics privacy tests。
- 不删除 UI IA tests。
- 不引入会触发 macOS 隐私授权弹窗的测试路径。
- 不依赖人工响应权限弹窗完成自动化测试。
- 不把 UI test port 注入写回硬编码 suite 名。

验证门禁：

- 改哪个测试层，就运行该层 targeted tests。
- 改 `Tests/VoidDisplayRuntimeTests/TestSupport` 后运行 Runtime tests。
- 改 App test support 后运行相关 App tests。
- 改 UI test helper 后运行最窄 UI smoke，若环境缺少 UI 自动化授权，把失败分类为环境 setup 失败。
- 改 shared test support 或 static gate 后运行 full unit 和 Xcode Debug build。

完成标准：

- 测试文件和 helper 重复减少。
- 必须保留的 contract tests 仍存在并能直接说明覆盖的架构边界。
- 覆盖不因合并 smoke 或 helper 而缩水。
- 测试不会引入新的可避免隐私权限提示。

## Stage 4: Localization, Copy, README And Public Docs Alignment

目标：

- 把用户文案和公开文档对齐最终产品定位。
- 确认工程概念不会泄漏成普通用户文案。
- 更新 README 和公开叙事，使它们匹配当前 `Displays` / `Diagnostics` 信息架构。

执行窗口与计划模式：

- localization 或 README 大改必须使用全新执行窗口。
- 需要先进入计划模式锁定用户可见命名、README 叙事和 localization diff 策略；只修本文或单处 docs typo 可以同窗口直接执行。

允许改动范围：

- 审计 app-facing copy，确认 `DisplaySurface`、`Surface`、`显示表面` 不作为普通用户文案出现。
- 统一 `Diagnostics`、`Displays`、`LAN Web View`、`Support Bundle` 的英文和中文命名。
- 清理 stale localization entries。
- 更新 README 和中文 README 中旧四入口叙事、旧 `Screen Monitoring` / `Screen Sharing` 主入口描述和旧调试入口。
- 公开定位采用：

```text
VoidDisplay creates HiDPI virtual displays for headless Macs and exposes them to remote desktop apps, browsers, and AI agents.
```

- 明确当前不售卖盈利，项目以开源为主，为爱发电。
- 明确 VoidDisplay 是 remote display companion，远程输入、连接、账号体系由 RustDesk、ToDesk、VNC、AnyDesk、Parsec 等远程桌面工具负责。
- 明确 LAN Web View 是局域网观察能力，人和 AI agent 都可以通过浏览器观察。

禁止范围：

- 不引入 Xcode 自动抽取噪音污染提交。
- 不改变 LAN Web View 安全立场。
- 不新增 token、密码、账号体系或 auth。
- 不把 VoidDisplay 写成远程控制软件。
- 不暗示支持输入注入、剪贴板同步或 browser agent control。
- 不做大规模 UI 美化。

验证门禁：

- docs-only 变更只做 markdown / diff 检查。
- localization 变更必须人工审计 `Localizable.xcstrings` diff，确认没有 Xcode 自动抽取噪音。
- 清理 `Localizable.xcstrings` 时必须运行 `jq empty Apps/VoidDisplay/Resources/Localizable.xcstrings`。
- 清理用户文案时必须用 `rg` 检查 `DisplaySurface`、`Surface`、`显示表面` 等 user-facing bad copy，并人工解释保留命中。
- app-facing copy 变更后运行相关 targeted UI / copy tests。
- README 变更后用 grep 扫描旧入口词，手工确认保留项只用于历史说明或开发者定位。

完成标准：

- 用户可见文案不暴露 `DisplaySurface` 这类工程核心对象。
- 公开文档先讲 headless Mac HiDPI virtual displays，再讲远程桌面工具、浏览器和 AI agent 观察。
- README 与当前主导航 `Displays` / `Diagnostics` 一致。
- LAN Web View 的局域网观察边界表达稳定，没有 auth 或远程控制漂移。

## Stage 5: Architecture Boundary Final Guards

目标：

- 把 Runtime boundary、LAN auth boundary、remote-control boundary、data-plane boundary 固化为可重复检查项。
- 评估是否把边界检查脚本化到现有 static gate。
- 只接受低噪音、低维护成本的自动化规则。

执行窗口与计划模式：

- 必须使用全新执行窗口。
- 需要先进入计划模式定义候选规则、误报样本、失败信息和回滚条件；只做人工审计报告可以不进入计划模式。

允许改动范围：

- 先执行人工或 agent 审计，列出需要守住的边界和当前证据。
- 对稳定、低误报规则加入现有 static gate。
- 可自动化检查包括 Runtime 禁止 import、Runtime 禁止数据帧类型、README 旧入口词扫描、用户文案敏感词扫描、LAN auth 关键词扫描。
- 对无法可靠自动化的边界保留为审计 checklist。

禁止范围：

- 不添加高误报 grep。
- 不添加脆弱脚本。
- 不建立重复防线。
- 不把所有语义判断硬塞进 static gate。
- 不修改 Capture / WebRTC frame pipeline。
- 不新增 auth、remote-control 或 browser agent control 相关实现。

验证门禁：

- static gate 变更必须运行 static gate 自测。
- static gate 或 shared script 改动后运行 full unit 和 Xcode Debug build。
- 所有脚本输出必须低噪音，失败信息能直接定位违规文件和规则。
- 所有代码路径保持 zero warnings。

完成标准：

- Runtime boundary、LAN auth boundary、remote-control boundary、data-plane boundary 有明确可重复检查方式。
- 自动化规则只覆盖稳定模式。
- 人工或 agent 审计项清楚标明为什么不脚本化。
- 后续 PR 能靠 static gate 和 review checklist 同时防止边界漂移。

## Automation And Audit Split

可以自动化：

- 阶段文档状态或收口段检查。
- README 旧入口词扫描。
- 用户文案敏感词扫描。
- Runtime 禁止 import 和禁止数据帧类型扫描。
- LAN auth 关键词扫描。
- static gate 中低噪音、低维护成本的边界规则。

只做人工或 agent 审计：

- 复杂度是否真实下降。
- 测试覆盖是否缩水。
- README 产品叙事是否准确。
- LAN 安全边界是否被误写成 auth 需求。
- 文件合并是否破坏架构边界。
- 某个 legacy 兼容是否有保留必要。

## Window And Commit Strategy

同窗口可以继续：

- 只创建或更新本文。
- 只做小范围 docs closeout。
- 只做 docs-only markdown 修正。

必须使用全新执行窗口：

- 任何代码清理。
- 任何测试支撑重组。
- 任何 localization 变更。
- 任何 static gate 变更。
- README 大改。
- 涉及多个 stage 的混合变更。

提交策略：

- 创建本文不提交，除非用户明确要求。
- 后续每个 cleanup stage 独立确认后再改文件。
- 每个 stage 默认独立提交。
- 不把 docs closeout、code cleanup、test cleanup、localization、static gate 混在一个提交里。
- 提交前必须复用或刷新最新验证结果，验证结果必须覆盖提交内容。

## Verification Strategy

docs-only 阶段：

- 检查 diff 只包含预期 Markdown 文件。
- 用 `rg` 确认本文未使用新的 DisplayRuntime phase 编号。
- 检查每个 stage 都包含目标、允许改动范围、禁止范围、验证门禁、完成标准。
- 检查 non-goals、LAN security stance、remote-control boundary 完整保留。

code cleanup 阶段：

- 按影响范围运行 targeted tests。
- 改 Runtime 时跑 Runtime tests。
- 改 App adapters 时跑相关 App tests。
- 改 Capture、Sharing 或 VirtualDisplay 时跑对应模块 tests。
- 改 shared code、build settings、脚本或 static gate 时跑 full unit 和 Xcode Debug build。
- 每个 code cleanup 阶段必须保持 zero compile errors 和 zero compile warnings。

test cleanup 阶段：

- 先列出被合并或删除测试的现有覆盖点。
- 合并后运行对应 targeted tests。
- 对关键 contract tests 做存在性检查。
- UI test 因 harness 授权失败时按环境 setup failure 报告。

localization / copy 阶段：

- 人工审计 localization diff。
- 避免 Xcode 自动抽取噪音。
- 清理 `Localizable.xcstrings` 时运行 `jq empty Apps/VoidDisplay/Resources/Localizable.xcstrings`。
- 用 `rg` 扫描 `DisplaySurface`、`Surface`、`显示表面` 等 user-facing bad copy，人工解释保留命中。
- app-facing copy 改动后运行相关 targeted tests。
- README 改动后做旧入口词扫描和人工叙事审计。

static gate 阶段：

- 先用 fixtures 或 dry-run 证明规则不会明显误报。
- 运行 `scripts/ci/static.sh`。
- 改 shared gate 后运行 full unit 和 Xcode Debug build。

## Final Acceptance Criteria

整个 cleanup 计划执行完毕后，必须同时满足：

- Phase 1 到 Phase 6 文档已经归档为已完成历史。
- docs 入口顺序清楚，公开读者能先看到产品定位，再看到架构路线和最终状态。
- README 和用户文案与当前 `Displays` / `Diagnostics` IA 一致。
- Runtime / Data Plane 边界没有回退。
- LAN Web View 仍是局域网观察能力，没有 token、密码、账号、auth 或远程控制漂移。
- 重复 helper、临时路径、迁移残留得到清理。
- 测试 suite 更清楚，关键 contract coverage 没有缩水。
- static gate 只加入低噪音、可维护的边界检查。
- 最终验证保持 zero compile errors 和 zero compile warnings。
