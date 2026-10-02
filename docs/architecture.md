# VoidDisplay 当前架构

## 产品边界

VoidDisplay 在 macOS 上创建和管理 HiDPI 虚拟显示器，并为受管理的虚拟显示器提供本机 Preview 与可信局域网内的 LAN Web View。当前产品不提供公网中继、远程输入、剪贴板控制、账号体系或浏览器控制接口。

用户主界面包含 `Displays` 和 `Diagnostics` 两个入口。`Displays` 以已保存的虚拟显示器配置为主列表，承载启用、编辑、Preview 和 LAN Web View 操作。物理显示器状态可以进入内部运行时目录，但不会形成独立的用户管理主线。

## 组件职责

| 组件 | 职责 |
| --- | --- |
| `Apps/VoidDisplay` | Xcode App 入口、应用图标、Info.plist 文案和本地化资源 |
| `VoidDisplayApp` | SwiftUI 界面、应用装配、控制器和运行时适配 |
| `VoidDisplayRuntime` | 显示目录、事务、consumer lease、需求聚合、快照和 intent 分发 |
| `VoidDisplayVirtualDisplay` | 虚拟显示器领域模型、配置持久化、编排、拓扑等待、回滚和编辑界面 |
| `VoidDisplayCGVirtualDisplay` | 异步启动并持有每块虚拟屏的辅助进程，管理就绪、取消和退出通知 |
| `Apps/VoidDisplayHost` / `VoidDisplayVirtualDisplayHost` | 每进程创建一块原生虚拟屏，选择并核实实际模式，随父进程管道关闭退出 |
| `CGVirtualDisplayPrivate` | 私有 `CGVirtualDisplay` API 的 Objective-C 封装 |
| `VoidDisplayCapture` | `SCStream` 生命周期、帧分发、Preview 渲染和采集性能状态 |
| `VoidDisplaySharing` | HTTP、WebSocket、WebRTC、分享路由、viewer 会话和 relay 进程 |
| `Tools/VoidDisplayRelay` | 由 App 启动的本地 Go relay，负责 loopback 控制 API、WebRTC room 和媒体转发 |
| `VoidDisplayObservability` | 结构化诊断事件、快照收集和脱敏 |
| `VoidDisplaySupport` | 支持草稿、历史记录和支持包编排 |
| `VoidDisplayDesignSystem` | 跨功能界面的视觉 token、通用组件和展示模型 |
| `VoidDisplayFoundation` | 跨模块基础类型、权限与持久化支撑 |
| `WebRTC` | `stasel/WebRTC` M152 SwiftPM 二进制依赖 |

SwiftPM target 和依赖关系以 [Package.swift](../Package.swift) 为准。

## 控制平面

`DisplayRuntime` 是显示生命周期的控制平面，持有以下结构化事实：

- `DisplaySurface` 目录与当前显示标识。
- 虚拟显示器 create、edit、delete、rebuild 和 startup restore 事务。
- Preview 和 LAN Web View 的 consumer lease。
- 聚合后的采集需求、有效 capture intent、事务 trace 和运行时快照。

应用启动通过 `DisplayRuntime.restoreStartupVirtualDisplays(source: .startup)` 恢复期望启用的虚拟显示器。用户发起的虚拟显示器变更先进入运行时事务，再经 App adapter 调用 `VoidDisplayVirtualDisplay` 的底层命令。事务在拓扑收敛后更新目录，并对已有 consumer lease 执行恢复或失败收口。

## 原生虚拟屏进程

App 为每块运行中的虚拟屏启动 `Contents/MacOS/VoidDisplayHost`。该程序先接收一行 JSON 创建描述，在自身首次查询显示模式前创建原生显示器，再按逻辑尺寸、像素尺寸和刷新率选择模式并读回验证。HiDPI 的像素尺寸为逻辑尺寸的两倍，刷新率按 CoreGraphics 返回的整数 Hz 匹配。

这个进程边界处理了原生 API 的两个生命周期限制：进程先查询其他显示器时，新建虚拟屏的模式查询可能为空；主动切换模式后，释放 `CGVirtualDisplay` 对象可能无法回收显示器，退出创建进程才能完整释放。主应用持有辅助程序的标准输入管道，停用或重建时关闭管道；应用异常退出也产生 EOF。辅助程序异常退出通过现有 generation 机制回报，过期回调不能清除新实例。

创建过程异步等待 ready，失败、超时或取消会结束辅助程序并进入现有回滚流程。创建期间预留序列号和 generation，清理操作会取消未完成的创建，阻止迟到的 ready 恢复已清理状态。保存配置不直接修改运行中的原生对象，重建始终关闭旧进程后创建新实例。

辅助程序通过 Xcode target dependency 和 copy phase 随 App 构建、嵌入。构建门禁检查它与 App 的架构一致，本机签名验收另行核对开发签名；发布打包对辅助程序执行相同架构校验与签名步骤。

## 数据平面

帧、像素缓冲区、`SCStream`、Preview 渲染、WebRTC peer、WebSocket 连接、HTTP 请求和编码流程留在 Capture 与 Sharing 模块。Runtime 只分发结构化 intent，不持有这些资源对象。

LAN Web View 的分享路由生命周期与帧需求分开管理。启用分享会建立受 capability 保护的页面与信令入口。零 viewer 时路由可以继续有效，采集流只在 Preview 或实际 viewer 产生帧需求时运行。

共享链路统一使用 H.265（HEVC）。应用通过公开的 RTCVideoEncoderFactory 与 RTCVideoEncoder 接口接入 VideoToolbox 硬件编码器，沿用原版 WebRTC SDK 负责协商和传输。编码器使用实时编码、禁止帧重排并将帧等待上限设为 0，异步提交帧。在途帧最多两个，硬件忙时丢弃新的输入，避免积累旧画面。编码器使用自身缓冲池并批量复制像素平面，避免硬件参考帧占满 ScreenCaptureKit 的采集缓冲区；关键帧携带 VPS、SPS、PPS，转换为 Annex B 后交给 WebRTC，关键帧间隔沿用 7,200 帧或 240 秒上限，并响应即时关键帧请求。

发送工厂声明 HEVC Main Level 6（profile-id=1、tier-flag=0、level-id=180、tx-mode=SRST），覆盖 3840×2400 的 HiDPI 预设及 5K60；relay 使用相同参数，浏览器只协商符合该格式的 H.265 及对应 RTX。观看端须声明 Main profile、main tier、SRST 与至少 Level 6，浏览器能力和 answer 校验、relay offer 校验共同执行该约束。仅有 H.265 名称不足以证明能够接收源端码流；不支持时显示明确提示。发送 peer 不配置接收解码器，观看端负责解码。

VideoToolbox 使用 HEVC Main AutoLevel。共享输出统一限制为每帧 35,651,584 个亮度像素、每秒 1,069,547,520 个亮度样本，并计入编码器按 16 像素对齐的尺寸填充。自动与流畅模式在该范围内保持源分辨率和帧率，超出时缩放画面；节能模式额外沿用 1080p30 像素预算。发送参数和带宽估计均按最终输出像素率乘以 0.05 计算码率，上限预算最低为 2 Mbps，下限为上限预算的四分之一且最低为 1.5 Mbps。更改输出边界须同步检查实际码流等级与 SDP 声明。发送端诊断保留实际编码器、是否节能、帧率及限速原因，本机硬件路径与性能须以真实运行结果验证。

VideoToolbox 的 AutoLevel 硬件输出会声明 High tier，公开配置未提供 tier 选择，而所测 Chrome 的 WebRTC 接收能力声明 Main tier。编码器通过 DataRateLimits 约束每秒最多 60 Mbps，并在已有 Annex B 输出边界将单时间层 Main profile 的 VPS/SPS 声明统一为 Main tier、Level 6；保留其余参数、图像载荷与防竞争字节。高于 Level 6 或不符合该编码配置的参数集禁止进入发送链路。该声明转换依赖前述尺寸、样本率及硬码率约束；若硬件 API 能直接生成所需声明，可移除转换，保留码流一致性回归。

交互式共享优先降低整链路延迟，持续帧率与呈现掉帧作为约束。更换编码格式须同时比较延迟 P50、P95、画面质量、实际码率及 App、relay、helper 的资源占用；硬件编码器单独耗时更短不能证明整链路更快。实验通路与未通过筛选的参数保存在验收资料中，不进入产品默认配置。

LAN Web View 当前传输无音频的交互式桌面画面。Relay 在 viewer 的 SDP 中协商 `playout-delay` RTP 扩展，并按每个 viewer 协商的扩展 ID 写入最小与最大播放延迟 `0/0 ms`，请求接收端即时解码。浏览器继续决定解码后的合成与实际呈现时间，该参数不等于端到端延迟。未协商该扩展的 viewer 不接收它；写入只修改转发副本，保留原始媒体时间戳和 payload。

完整访问和资源边界见 [LAN Web View 安全契约](./security/lan-web-view.md)。

## 依赖边界

以下约束需要长期保持：

1. `VoidDisplayRuntime` 不导入 SwiftUI、AppKit、ScreenCaptureKit、Capture、Sharing、VirtualDisplay 或 App target。
2. `VoidDisplayVirtualDisplay` 不依赖 `VoidDisplayRuntime`。App adapter 负责在两者之间映射命令和结果。
3. Runtime 不持有帧、session、peer、socket、listener 或 relay 进程。
4. UI 不直接执行底层虚拟显示器事务，也不绕过 consumer lease 启停 Preview 或 LAN Web View。
5. 用户可见文案使用 Displays、Preview、LAN Web View 和 Diagnostics，内部 `DisplaySurface`、lease、intent 等术语不进入产品界面。

`Package.swift` 的 target 依赖图与编译器约束直接模块依赖。跨层调用、资源所有权和运行时行为由代码审查与对应 SwiftPM 测试共同验证。

## 诊断与隐私

Diagnostics 以 runtime snapshot 作为主要结构化状态来源。支持包在落盘前经过最终脱敏边界，调用方提供的内容不会被默认视为已清洗。新增诊断字段或附件时，需要同时扩展脱敏测试和支持包测试。

Runtime 的 lease 集合只保存仍受管理的 consumer。释放时先生成终态结果并解除等待，再移除条目；失败且可重试的 Preview 保留到用户重试或关闭。只有 attach 可以创建 lease，其他状态更新只能修改现存 ID。关闭后返回的异步结果使用 `invalidated`，不能恢复旧窗口或采集需求。历史排障信息由现有事件与事务诊断记录承担。

Runtime snapshot 使用 schema 7，`latestFailure` 保存最近一次有效失败的代码与进程内递增序号。Runtime 在接受采集结果、独立 consumer 失败和事务终态时记录该值；过期结果、正常取消及同一失败的重复传播不推进序号，成功操作不清除最近失败。Diagnostics 直接读取该字段，禁止从显示器顺序或不同诊断集合的排列推断失败先后。

采集失败按当前 intent 内的失败码去重，其他 consumer 的成功或失败结果不会使旧通知重新计数。新 intent 替换旧 intent 时回收该显示源的去重记录，避免保存跨请求历史。

## 验证入口

小范围架构改动先运行对应 target 测试和 Debug build：

```bash
scripts/ci/unit.sh --filter '<test-filter>'
scripts/ci/xcode.sh --action build --configuration Debug \
  --destination "platform=macOS,arch=$(uname -m)"
```

跨模块、并发、持久化、网络、安全或发布相关改动按照 [测试策略](./testing/testing-strategy.md) 和根目录 [AGENTS.md](../AGENTS.md) 提升验证范围。


## 用途模板、共享窗口和场景

创建表单位于 VirtualDisplay，返回 `CreatedDisplayOutcome(configID, shouldOpenPreview)`。App 使用该 ID 调用现有预览入口；创建后的内容放置说明由主窗口和共享窗口共用。共享窗口使用 configID 标识，读取当前运行 displayID 与有效路由。Core Image 生成带留白的二维码，不引入编码依赖或第二份共享会话状态。

`DisplaySceneStore` 使用 PersistenceContext 的隔离目录与写入保护，在 `display-scenes.json` 保存 schema 1。每条记录只有 UUID、名称和启用配置 ID 集合。写入原子完成后发布内存值。加载失败阻止覆盖保存；重置只影响场景文件。删除显示器保留缺失引用，避免跨文件联动写入。

AppBootstrap 创建一份 `DisplaySceneController`，主窗口和菜单栏共用。控制器在创建异步任务前同步占用提交状态，重复申请不能覆盖有效批次的结果归属；结果发布后解除占用。匹配由有效引用、当前启用意图、运行集合及无活动事务派生，历史 `latestFailure` 不影响匹配。独立消费者故障保留其恢复入口。

Runtime 的 `prepareVirtualDisplayEnabledSet` 记录参数、启用意图、实例和受管理消费者身份；`applyVirtualDisplayEnabledSet` 占用单个事务队列位置，实际开始时重新比较计划。连接数不参与过期判断。子步骤调用现有生命周期执行体，先启用后停用，失败、取消或恢复失败停止剩余步骤，保留部分结果。每步返回或抛错后及批次终态解除忙状态前，同步 `onStateSettled` 回读 VirtualDisplayController 缓存。

schema 7 的 `enabledSetApplication` 记录活动批次进度，终态清除；父事务 `enabledSetResult` 保留子事务 ID、完整步骤结果、未执行项和最终显示器事实。场景诊断只输出数量、缺失引用数和错误类别，不输出名称、原始文件、二维码或访问凭证。
