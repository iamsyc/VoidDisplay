# Displays 首页最终产品化计划

状态：待执行
范围：规划 Displays 首页最终产品化实现。本计划只产出实现规格，不实现代码，不修改运行时、数据平面、README、公开截图或发布文档。
基线：DisplayRuntime 重构已完成，主导航已收敛为 `Displays / Diagnostics`。Displays 首页已经从 runtime 工程面板调整为行内状态和行内动作列表，但当前状态噪音、动作层级和技术详情露出仍未达到最终产品形态。

## 目标与原则

Displays 是主工作台，目标是让用户打开首页即可完成以下判断和操作：

1. 看清当前有哪些显示器。
2. 看清每个显示器是否启用。
3. 看清每个显示器是否正在监看。
4. 看清每个显示器是否正在 Web 查看。
5. 看清每个显示器有无观看者。
6. 发现需要处理的异常。
7. 对某一行启动或停止 Monitor / Web View。

产品原则：

1. 正常状态低噪音，异常状态高可见。
2. 虚拟显示器 create、edit、enable、disable、delete、order、primary 继续由 Virtual Display management page 负责。
3. Diagnostics 负责完整技术诊断，Displays 首页只保留必要高级入口。
4. 不为了 UI 便利扩展 runtime schema。
5. 不重新暴露 `displayName`。
6. 不修改数据平面。
7. 不恢复旧四入口主导航。

## 最终 UI 形态

主导航保持：

```text
Displays
Diagnostics
```

页面 header 使用以下结构：

1. 标题：`Displays / 显示器`。
2. 右侧全局动作：
   - `Manage Virtual Displays / 管理虚拟显示器`
   - `Open System Settings / 打开系统设置`
3. `Manage Virtual Displays` 是全局动作，只出现在 header 或等价 toolbar 中。
4. header 是推荐方案。它把页面身份、全局配置入口和系统配置入口集中在一个稳定区域，避免每行重复全局操作。

Display row 采用紧凑管理列表，不使用大字段表格。每行结构固定为：

1. 左侧身份组：显示器图标、名称、分辨率。
2. 中间状态组：按状态层级展示用户当下需要处理的信息。
3. 右侧动作组：只放当前 display 的 Monitor / Web View 动作。

布局要求：

1. 默认窗口下至少完整显示 3 个 display row。
2. 行高目标接近旧 Virtual Display 管理页。
3. 行内状态、动作和详情入口不得显著增加垂直占用。
4. 用户无需选中 display 才能看到核心状态和核心动作。

## 状态显示规则

状态组必须按权重收敛，避免把正常事实全部显示成同等 pill。

Virtual Display：

1. `Enabled / 已启用` 常显。
2. `Disabled / 已停用` 常显。
3. `Rebuilding / 重建中` 常显，权重高于 Enabled / Disabled。
4. `Needs attention / 需要处理` 常显，并使用异常权重。

Monitor：

1. `Off` 或 `Not Monitoring / 未监看` 可低权重显示。
2. `Monitoring / 监看中` 高权重显示。
3. 监看状态只表达当前 display 的监看事实，不承载诊断细节。

Web View：

1. `Off` 或 `Not Sharing / 未共享` 可低权重显示。
2. `Sharing / 共享中` 高权重显示。
3. `Route Ready / 路由就绪` 高权重显示。
4. Web View 状态只表达当前 display 的共享和路由事实。

Viewers：

1. `0 Viewers / 0 位观看者` 低权重显示，或合并进 Web View 低权重状态。
2. `>0 Viewers / 观看者 >0` 高权重显示。
3. 观看者数量不得挤占 Monitor / Web View 主动作区域。

Issue：

1. 正常时不显示 `Issue Normal` 或 `问题 正常`。
2. 有问题时显示 `Needs attention / 需要处理` 或具体短状态。
3. 异常状态应进入中间状态组，权重高于普通 Off、0 Viewers、Enabled。

技术状态：

1. 技术状态不在主状态组显示。
2. 技术状态只能进入低权重 details 区域。
3. 主状态组不得展示 raw identifier、诊断码堆叠、runtime attachment 细节或 capture internals。

## 行内动作规则

每行只放 per-display 动作：

1. `Monitor / 监看`
2. `Stop / 停止`
3. `Web View / Web 查看`
4. `Stop / 停止`

行内动作禁止放入：

1. `Manage Virtual Display`
2. `Open System Settings`
3. `Diagnostics`
4. `Stop Web Service` 全局服务动作

动作启用规则：

1. `Monitor` 启动当前 display 的监看需求。
2. `Web View` 启动当前 display 的 Web 查看需求。
3. Stop actions 仍只由 runtime lease demand 启用。
4. capture facts 不驱动 stop action。
5. sharing facts 不驱动 stop action。
6. 点击 `Monitor` 的测试路径不得触发真实 macOS privacy prompt。
7. 点击 `Web View` 不改变 LAN route、shareID、auth/security stance。

## 技术详情规则

技术详情默认不在每行显眼展示。推荐实现：

1. 行右侧保留低权重 secondary `Details / 详情` 按钮。
2. `Details` 的视觉权重必须低于主状态和主动作。
3. 如使用 disclosure，折叠态不得占用主状态组位置。
4. 技术详情展开后只展示必要字段。

允许展示字段：

1. `Display Identifier`
2. `Capture State`
3. `Runtime Attachment`
4. `Diagnostic Code`

禁止展示字段：

1. raw shareID
2. LAN URL / IP
3. 文件路径
4. 窗口标题
5. 用户文本
6. 桌面内容

## 文案规则

用户可见文案禁止使用：

```text
Managed virtual
Managed Virtual Display
托管虚拟
托管虚拟显示器
Physical auxiliary
Physical Auxiliary Display
物理辅助
DisplaySurface
Display Surface
Display Surfaces
Surface
Consumer
Lease
Intent
监听
未监听
```

推荐使用：

```text
Virtual Display / 虚拟显示器
Physical Display / 物理显示器
Monitor / 监看
Not Monitoring / 未监看
Monitoring / 监看中
Web View / Web 查看
Not Sharing / 未共享
Sharing / 共享中
Route Ready / 路由就绪
Viewers / 观看者
Needs attention / 需要处理
Details / 详情
Technical Details / 技术详情
```

文案实现要求：

1. App-facing 文案必须同步更新 `Localizable.xcstrings`。
2. copy guard 需要覆盖禁止词。
3. 允许在工程文档、测试 fixture 名称或内部类型中保留工程概念，前提是它们不会成为普通用户可见文案。

## 交互要求

1. 点击 `Manage Virtual Displays / 管理虚拟显示器` 进入虚拟显示器管理页。
2. 虚拟显示器管理页必须有清楚的 `Displays Overview / 显示器总览` 返回入口。
3. Displays 首页不提供虚拟显示器 create、edit、enable、disable、delete、order、primary 操作。
4. 点击 `Monitor` 不应在测试环境触发真实隐私授权弹窗。
5. 点击 `Web View` 不改变当前 LAN 路由、shareID、auth/security stance。
6. Stop actions 只跟随 runtime lease demand。
7. capture facts 和 sharing facts 不得驱动 stop action。

## 实现范围

允许修改：

```text
Sources/VoidDisplayApp/Navigation/HomeView.swift
Sources/VoidDisplayApp/Navigation/DisplaysView.swift
Sources/VoidDisplayApp/Navigation/DisplaySurfacePresentation.swift
Tests/VoidDisplayAppTests/DisplaySurfacePresentationMapperTests.swift
UITests/VoidDisplayUITests/Smoke/HomeSmokeTests.swift
Apps/VoidDisplay/Resources/Localizable.xcstrings
Tests/VoidDisplaySupportTests/DiagnosticsUserFacingCopyTests.swift
```

`Tests/VoidDisplaySupportTests/DiagnosticsUserFacingCopyTests.swift` 只在 copy guard 需要更新时修改。

禁止修改：

```text
Sources/VoidDisplayRuntime/**
DisplayRuntime DTO/schema/model
runtime transaction、consumer lease、demand aggregation
Capture/WebRTC/WebSocket/HTTP/frame pipeline
LAN route/shareID/auth/security stance
VirtualDisplay services/models/logic/lower layer
Diagnostics 数据来源
README / docs public screenshots
remote control、input injection、clipboard
```

边界要求：

1. 不新增 runtime compatibility layer。
2. 不新增 UI 专用 runtime DTO。
3. 不改变 Diagnostics 的事实来源。
4. 不把 Virtual Display 管理能力复制到 Displays row。
5. 不把技术诊断页复制到 Displays 首页。

## 测试计划

Presentation mapper tests 必须覆盖：

1. status groups follow visibility rules。
2. Issue normal hidden。
3. Needs attention visible。
4. Stop actions only enabled by runtime lease demand。
5. capture facts do not drive stop action。
6. sharing facts do not drive stop action。
7. no banned user-facing copy。

UI smoke 必须覆盖：

1. Displays page shows rows without selecting。
2. rows show compact status。
3. rows show Monitor / Web View actions。
4. Manage Virtual Displays is global。
5. Displays Overview returns from child page。

Localization / copy guard 必须覆盖：

1. 禁止词不出现在 `Localizable.xcstrings` 的用户可见值中。
2. 禁止词不出现在 Displays 首页 UI strings 中。
3. 新增或修改的 app-facing 文案有英文和中文资源。

Build 必须覆盖：

1. Debug build zero compile errors。
2. Debug build zero compile warnings。

## 验证门禁

实现窗口完成代码后必须运行：

```bash
jq empty Apps/VoidDisplay/Resources/Localizable.xcstrings
scripts/ci/static.sh
scripts/ci/unit.sh --filter DisplaySurfacePresentationMapperTests
scripts/ci/unit.sh --filter AppBootstrapTests
scripts/ci/unit.sh --filter VoidDisplaySupportTests
scripts/ci/ui_smoke.sh --only-testing VoidDisplayUITests/HomeSmokeTests/testDisplaysSurfaceConvergenceSmoke_baseline
scripts/ci/xcode.sh --action build --configuration Debug
git diff --check
```

还必须完成：

1. Xcode warning/error scan 结果为 0。
2. forbidden copy grep 无新增用户可见违规文案。
3. 若 UI test 因本机自动化授权缺失失败，按环境 setup failure 汇报，不归类为产品代码失败。

## 完成标准

1. Displays 首页最终产品形态优于旧四入口 UI，适合作为长期主工作台。
2. Displays 首页保留旧 UI 的扫描效率。
3. 主界面移除 runtime/debug vocabulary。
4. 正常状态噪音被压低，异常和正在发生的状态可见性提高。
5. 全局动作、行内动作、技术详情入口层级清楚。
6. 不新增架构变更。
7. 不新增数据平面变更。
8. 不扩大 runtime schema。
9. 本地验证通过。
10. 计划实现完成后提交。
