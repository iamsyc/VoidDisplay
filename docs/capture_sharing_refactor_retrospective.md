# 屏幕监听与共享重构复盘

## 1. 背景与结论

这份复盘文档对应的对象是未合并分支 `codex/capture-cursor-config-serialize`。  
`codex/extract-capture-cursor-config-serialize` 当前与 `main` 几乎没有实现差异，不能代表那次失败重构的主体。

这次重构最终放弃合并，核心原因很直接：结构风险大于可保留收益。分支试图同时重写屏幕监听、屏幕共享、Web 服务生命周期、共享注册、主屏别名路由、窗口预览几何、测试隔离与回退机制，变更面过大，耦合面过密，后续只能靠连续补丁维持稳定。

可以直接作为证据的时间线如下：

1. `7aed33c`：先把屏幕监听与屏幕共享结构一起收拢，并改写预览窗口支持。
2. `42ee1d7`：进一步引入 `ScreenPipelineRuntime`，统一接管监听、共享、Web 生命周期与观看人数。
3. `6e78b11`：开始修监听与共享状态一致性。
4. `6226ceb`：开始修主屏别名与共享注册真值源。
5. `7709f7a`：继续修并发收敛问题并补回归测试。
6. `cb00555`：最后又修虚拟 HiDPI 屏幕监听回归。

从这个顺序可以看出，问题集中在重构后的结构本身。初始重构完成后，分支很快进入长时间的稳定性补丁阶段。

对照当前主线，风险更容易看清：

1. 当前监听状态仍然由 [CaptureMonitoringService.swift](../VoidDisplay/Features/Capture/Services/CaptureMonitoringService.swift) 负责，职责边界单一。
2. 当前共享注册与共享会话仍然由 [DisplaySharingCoordinator.swift](../VoidDisplay/Features/Sharing/Services/DisplaySharingCoordinator.swift) 负责，主屏解析和 shareID 分配也留在同一模块。
3. 当前预览窗口几何问题已经沉淀为单独说明文档 [capture_preview_black_bar_fix_notes.md](capture_preview_black_bar_fix_notes.md)，说明主线最终选择了分问题修复，不再继续沿用那套大一统 runtime。

## 2. 这次重构做错了什么

### 2.1 一次性把四类运行时职责压进同一个总入口

结论分类：不应该做

`42ee1d7` 引入 `VoidDisplay/Features/ScreenPipeline/ScreenPipelineRuntime.swift`，同次提交又删除 `CaptureMonitoringService.swift`、`SharingService.swift`、`DisplaySharingCoordinator.swift`。  
证据很明确：`ScreenPipelineRuntime` 同时定义监听状态、共享状态、Web 服务状态、viewer 统计、注册更新、命令等待、错误语义和快照分发，文件体量与职责密度都明显过高。

后续修补模式也很明显：

1. `6e78b11` 修状态一致性。
2. `b175bf6` 修共享注册冲突与失效回写。
3. `6b66075` 修监听移除收敛与共享页拓扑误刷新。
4. `7709f7a` 修并发收敛。

这说明重构后新增的复杂度没有在统一入口内自然收敛，后续只能继续向同一个入口追加状态规则。

### 2.2 让监听链路与共享链路互相污染状态

结论分类：不应该做

分支里的 `ScreenPipelineSnapshot` 把监听会话、共享状态、共享失败、主屏、Web 服务端口、viewer 数都揉进同一个快照模型。  
`CaptureController.swift` 与 `SharingController.swift` 都改成订阅同一个 runtime 快照，再从中拆出自己关心的状态。

证据：

1. `42ee1d7` 的 `CaptureController.swift` 与 `SharingController.swift` 都新增 runtime 快照订阅。
2. `6e78b11` 与 `a086cbf` 的提交信息已经直接指向“状态一致性”“链路状态污染”。

这种结构会让监听与共享在读模型上失去隔离。一个链路的补丁很容易波及另一个链路的呈现与收敛。

### 2.3 把共享目录注册和权限回退做成持续摆动的协调层

结论分类：不应该做

共享可注册显示器这件事，本来只需要明确“谁负责加载”“谁负责注册”“权限缺失时谁清空状态”。分支后来引入 `ShareableDisplayRegistrationCoordinator`，把权限检查、拓扑签名、回退轮询、恢复重试、同步串行化全部包进一个协调器。

证据：

1. `6226ceb` 新增 `VoidDisplay/App/ShareableDisplayRegistrationCoordinator.swift`。
2. 文件内同时存在 `fallbackPollingTask`、`recoveryRetryTask`、`pendingSync`、`lastAppliedTopologySignature`、`lastPermissionGranted`、`needsRetryAfterFailure`。
3. `acca06c`、`962a5d5`、`a086cbf` 又继续围绕目录权限、目录状态、链路污染补丁。

这类结构会把“注册逻辑”演变成一个长期运行的补偿系统，后续任何权限、拓扑、加载失败都可能落进协调状态机。

### 2.4 过早抽象主屏别名路由

结论分类：不应该做

主屏分享链接规则在用户价值上很轻，技术风险却不轻。分支在 `6226ceb` 里新增 `docs/main_display_share_link_rules.md`，并把 `/display` 与 `/signal` 的主屏别名语义纳入注册真值源与路由代理。

证据：

1. `6226ceb` 同时修改注册协调器、runtime、路由测试与文档。
2. `ScreenPipelineRuntimeTests.swift` 在这一阶段新增了主屏别名、shareID 保持、并发注册保序等大量测试。

这类抽象提高了共享路由层的状态耦合，却没有为监听或共享稳定性带来基础收益。

### 2.5 在并发命令问题上建立过重的串行语义

结论分类：不应该做

分支后期的核心修补几乎都在处理命令排队、取消、等待注册槽位、停止中禁止启动、共享开始与停止 FIFO 次序、移除中的 in flight 命令回滚。

证据：

1. `d3f81dd`、`7709f7a` 都集中修共享并发状态机与收敛。
2. `ScreenPipelineRuntimeTests.swift` 中后期新增了大量 `concurrent`、`cancelled`、`waitingForRegistrationSlot`、`webServiceStopping` 相关测试。

这说明抽象层级已经高到需要专门证明“命令之间不会互相踩踏”。此时重构已经偏离了“让代码更容易推断”的目标。

## 3. 哪些属于过度设计

### 3.1 `ScreenPipelineRuntime`

结论分类：过度设计

`ScreenPipelineRuntime` 在同一文件里承担了以下职责：

1. 显示器描述注册。
2. 监听会话生命周期。
3. 共享会话生命周期。
4. Web 服务生命周期。
5. viewer 指标聚合。
6. 路由代理回写。
7. 错误语义定义。
8. 快照流分发。
9. 并发命令顺序控制。

证据：`42ee1d7` 的 `VoidDisplay/Features/ScreenPipeline/ScreenPipelineRuntime.swift`。

这类“总 runtime”看起来统一，实际把多个变化频率不同的问题绑到同一次改动里。监听和共享的修补无法独立演进。

### 3.2 `ShareableDisplayRegistrationCoordinator`

结论分类：过度设计

显示器注册本质上是共享页的输入刷新逻辑。分支把它上升成跨权限、跨拓扑、跨失败恢复的协调器，包含轮询、恢复重试、状态签名缓存、同步去抖与串行化执行。

证据：`6226ceb` 的 `VoidDisplay/App/ShareableDisplayRegistrationCoordinator.swift`。

这会让一个本应短路径、短状态的输入同步问题，演变成新的长期运行状态机。

### 3.3 主屏别名规则

结论分类：过度设计

`/display` 和 `/signal` 的主屏别名本身是附加入口。分支围绕它新增了“当前主屏已存在于注册集时才可用”“主屏切换时别名跟随，具体地址不变”等规则，还同步修改路由解析与注册真值源。

证据：`6226ceb` 与 `docs/main_display_share_link_rules.md`。

这个规则复杂度与用户收益不对称，放在失败重构里只会继续放大状态耦合。

### 3.4 围绕状态收敛建立补偿路径

结论分类：过度设计

从 `6e78b11` 到 `7709f7a`，提交标题已经反复出现“收敛”“一致性”“回写”“误刷新”“并发收敛”。  
这说明重构后的结构需要靠补偿路径维持一致性。补偿路径一旦成为常态，系统的真实语义就会越来越难推断。

证据：

1. `6e78b11`
2. `962a5d5`
3. `b175bf6`
4. `6b66075`
5. `7709f7a`

同一主题连续出现，本身就是过度设计的信号。

## 4. `1:1` 预览失稳专项复盘

这次 `1:1` 失稳问题，不能只归结为某一行计算错误。更关键的问题在于，分支把“真实窗口承载区几何”和“采集元数据推断”缠在了一起，导致窗口大小计算失去了单一可信几何事实。

### 4.1 问题是怎样形成的

分支里的 `CaptureDisplayView.swift` 同时引入了两层推断：

1. `nativeFrameSizeInPoints` 先走 `CapturePreviewNativeScaleResolver.resolve`，没有直接采用原始帧尺寸。
2. `preferredAspect()` 也优先采用 `resolutionText` 解析结果，再回退到首帧像素尺寸。

证据：

1. `codex/capture-cursor-config-serialize` 分支中的 `VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift` 第 41 行到第 56 行。
2. 同文件第 243 行到第 257 行。

窗口计算又被抽到 `CapturePreviewWindowSupport.swift`，这里的 `CapturePreviewWindowMetrics` 同时接受 `aspect`、`framePixelSize`、`targetContentWidth`、`shouldLockAspect`。  
初始窗口大小在 `applyInitialWindowSizeIfNeeded()` 中只应用一次，后续还要继续参与 `snapWindowToAspect()` 与 resize 过程。

证据：

1. 分支中的 `VoidDisplay/Features/Capture/Views/CapturePreviewWindowSupport.swift` 第 4 行到第 20 行。
2. 同文件第 68 行到第 135 行。
3. 同文件第 149 行到第 193 行。

### 4.2 为什么会失稳

`1:1` 模式真正需要的是一个稳定的几何基准：预览层承载区到底应该用哪组宽高。  
分支却把这个问题交给了“首帧像素尺寸”和“`resolutionText` 推断后的原生尺寸”共同决定。

这会带来三个后果：

1. 当 `resolutionText` 与首帧尺寸处于 HiDPI、虚拟显示器、异常首帧、元数据延迟到达等组合场景时，`resolve` 的结果可能变化。
2. `preferredAspect()` 与 `nativeFrameSizeInPoints` 的依据并不完全一致，一个偏向 `resolutionText`，一个偏向推断后的 native size。
3. `applyInitialWindowSizeIfNeeded()` 只在第一次满足条件时落地窗口大小，首次采用的推断如果偏了，后续很难自动回到正确几何。

所以这次 bug 的本质不只是“公式写错”。更深一层的问题，是“窗口几何”和“采集元数据解释”被耦合到了同一个决策层。

### 4.3 主线后来做对了什么

主线修复预览问题时，重点放回到真实内容承载区几何。  
[capture_preview_black_bar_fix_notes.md](capture_preview_black_bar_fix_notes.md) 已经明确记录了两个关键点：

1. 用 `contentRect` 与 `contentLayoutRect` 的差值计算真实布局 inset。
2. 用真实预览承载区去反推窗口 frame。

这条思路更稳，因为它把问题收回到了窗口几何本身。  
几何由几何事实决定，采集元数据只负责提供可信的宽高比输入，不再参与多轮推断。

### 4.4 这类问题后续应该怎样处理

结论分类：应该做

后续如果再动 `1:1` 预览，只能遵守下面四条：

1. 先固定几何真相，明确承载层的真实布局区域。
2. 把采集尺寸解析单独封装为输入归一化，不得和窗口 frame 决策混写在一起。
3. 当元数据存在多来源时，必须先定义单一真值源，再进入窗口 sizing。
4. 必须保留预览诊断链路与像素级自验证，不能退回人工截图反馈。

证据：

1. 主线的 [capture_preview_black_bar_fix_notes.md](capture_preview_black_bar_fix_notes.md)。
2. `cb00555` 又一次修虚拟 HiDPI 回归，说明这块没有资格靠肉眼试错。

## 5. 后续重构应该怎么做

### 5.1 监听、共享、Web 服务、窗口 sizing 四块分治

结论分类：应该做

后续重构必须拆成四块独立问题：

1. 监听内部状态与会话管理。
2. 共享注册、shareID、共享会话管理。
3. Web 服务启动停止与路由绑定。
4. 预览窗口 sizing 与渲染诊断。

任何一个阶段都不能同时改这四块。

### 5.2 共享只抽共享，监听只抽监听

结论分类：应该做

监听和共享都依赖显示器输入，但它们的运行语义不同：

1. 监听关心预览订阅、窗口、cursor、会话移除。
2. 共享关心 shareID、路由、sessionHub、viewer 统计、服务启动状态。

公共层只应保留低层原语，例如显示器描述、底层采集句柄、可测试的 registry 能力。  
禁止再引入一个同时替代监听服务和共享服务的总 runtime。

### 5.3 目录注册逻辑保持短路径

结论分类：应该做

共享目录注册只保留三步：

1. 读权限状态。
2. 读取当前可共享显示器集合。
3. 用单次结果刷新共享注册。

如果需要失败重试，重试逻辑必须留在调用层或测试层，不能升级为新的长期运行协调器。

### 5.4 主屏别名规则延后

结论分类：应该做

`/display`、`/signal` 这类主屏别名只在共享主链路稳定后才有资格进入。  
下一轮重构的第一批目标里不应包含这类语义扩展。

## 6. 重构重启门槛

### 6.1 分阶段顺序

下一轮重构执行顺序固定如下：

1. 先收口监听内部实现，不动共享路由、不动 Web 服务、不动主屏别名。
2. 再收口共享内部实现，不碰监听窗口几何。
3. 再抽监听和共享都确实需要的低层原语。
4. 最后才考虑跨模块统一状态接口。

这个顺序不能倒置。尤其不能一上来先做大一统 runtime。

### 6.2 每阶段验收项

每个阶段都要满足以下门槛后才能继续：

1. 当前阶段改动只落在单条链路，另一条链路只允许适配型最小改动。
2. 相关回归测试先补齐，再做结构调整。
3. 编译零错误、零警告。
4. 新增状态语义必须能用一句话描述清楚真值源和更新时机。

### 6.3 必须先补的回归测试

下次重构前，至少要保留并优先补齐以下测试能力：

1. 监听会话添加、激活、移除、cursor 状态回写。
2. 共享注册刷新、shareID 稳定、主屏切换、显示器移除。
3. Web 服务启动、停止、端口冲突、停止中拒绝新共享。
4. 共享并发场景，包括同屏重复启动、停止中启动、取消中的回滚。
5. 虚拟 HiDPI 与 `1:1` 预览链路。

### 6.4 必须保留的本地自验证链路

以下链路不得删除：

1. 预览诊断 runtime。
2. 预览录制 sink。
3. UI 诊断测试。
4. `scripts/test/capture_preview_self_check.sh`
5. `scripts/test/capture_preview_analyze.swift`

这套链路已经证明，屏幕预览问题需要可重复、可量化的本地验证。

### 6.5 最终约束清单

为了避免 `main` 的下一轮重构重蹈覆辙，执行前必须先确认下面三类结论：

1. 不应该做：一次性统一监听、共享、Web 生命周期、共享注册、窗口几何。
2. 应该做：按链路分治，先补测试，再做结构调整，公共层只保留稳定原语。
3. 过度设计：总 runtime、长期运行注册协调器、主屏别名规则、围绕收敛建立的大量补偿路径。

只要重构方案重新出现这些特征，就应该立刻停下，重新拆分范围。
