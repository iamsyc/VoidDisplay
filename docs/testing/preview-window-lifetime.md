# 预览窗口释放调查与验收

更新：2026-10-12。修复分支 `codex/preview-window-lifetime`，基于 `32f7f57`。本次交付范围为内存修复、回归与本地验收记录。

## 已确认的原因与修复

预览视图将宿主 `NSWindow` 存入强引用 `@State`，形成窗口、HostingView、SwiftUI 状态、窗口之间的所有权环。`CaptureDisplayView` 改为通过 `CapturePreviewWindowCoordinator.window` 的弱引用访问窗口；协调器可观察，保留窗口解析后更新缩放比例的行为。`CapturePreviewWindowSizingHost` 复用该引用。等待身份解析的 `CaptureDisplayWindowRoot` 只保存辅助功能所需标题。

新增回归将真实 `CaptureDisplayView` 放入 `NSHostingView`，确认窗口协调器已经挂接，再关闭窗口，断言窗口和协调器释放；采集动作使用隔离 fixture。另一个回归用合成帧确认图层宿主关闭后渲染器释放。此前已完成该窗口回归的修改前失败、修改后通过对照。

同类检查覆盖 `Sources` 中的 `NSWindow` 状态、绑定与成员。两个视图强引用入口均已移除；剩余窗口成员为协调器弱引用，accessor 和 sizing 方法仅接收调用参数。原有 delegate 转发保持原职责。

## 残余对象的测量干扰

窗口循环修复后，部分采样仍显示渲染器、图层与协调器存活。完整创建、关闭周期的 Instruments Allocations 与只读内存图将强引用追到 AppKit 通知中心注册的 block，该 block 捕获关闭后的 HostingView。只读符号检查定位到 `-[NSView _commonAwake]` 的回调，通知为 `NSAntialiasThresholdChangedNotification`。

以下对照只使用普通 AppKit 窗口与 NSView，不链接产品、SwiftUI 或 ScreenCaptureKit，每轮关闭后等待两秒：

| 操作 | 轮数 | 窗口残留 | 视图残留 |
| --- | ---: | ---: | ---: |
| 程序自主打开、关闭，不采集子窗口 | 3 | 0 | 0 |
| CUA 快速 AX 操作，不截图 | 3 | 0 | 0 |
| CUA 获取窗口截图后关闭 | 3 | 0 | 3 |

这证明本机工具采集路径足以独立造成该残留。产品中选择预览窗口再停留五秒，即使没有显式请求截图，也曾五轮留下五组对象；后台采集参与的具体机制尚未确定。因此正式对象寿命验收完全避开工具选择、读取或截图预览窗口。不能将结论扩大为所有 macOS 版本的框架缺陷，也不能通过产品调用私有通知或强制拆除 SwiftUI 图来补偿工具干扰。

## 真实应用验收

环境：macOS 27.0.1（26A434）、Xcode 27.0、Swift 6.4，arm64 Debug；应用来自 `scripts/dev/build_signed_runtime.sh` 的 `signed-runtime-summary.json`。显示源为 1440×900 HiDPI，实际像素 2880×1800。

在新启动的签名进程中，以 Home 的预览开关打开窗口，停留五秒，从诊断文件确认真实采集活跃并收到帧；通过现有 Cmd+N 返回 Home，再关闭预览开关。整个循环不读取预览窗口的 AX 或图像。视觉验收使用独立进程，之后重新启动应用进行寿命测量。

| 检查点 | 渲染器 | AVSampleBufferDisplayLayer | 窗口协调器 |
| --- | ---: | ---: | ---: |
| 初始 | 0 | 0 | 0 |
| 5 轮后 | 0 | 0 | 0 |
| 13 轮后 | 0 | 0 | 0 |
| 21 轮后 | 0 | 0 | 0 |
| 30 轮后 | 0 | 0 | 0 |

最终 `DisplayCaptureSession`、`PreviewSinkMailbox`、`DisplaySampleFanout` 也均为零，预览会话和 consumer lease 归零。每轮静态桌面收到 3 至 7 帧，证明采集路径执行；本次数据只支持关闭后的对象释放结论，不用于宣称 FPS、CPU 或 RSS 收益。

## 验证与证据

- 本轮签名 Debug 构建通过，编译错误和警告均为零。
- 相同产品和测试源码此前已通过 17 项相关 Swift 测试、4 项 Preview UI 测试、12 项完整 UI 测试及静态门禁。本轮未修改产品和测试代码，复用这些结果；旧日志已被外部清理，现存构建与运行时证据列于下方。
- 应用文字内容未改变，无需更新本地化资源。
- 此项按用户确认的方案进行本地提交，未推送、发起 PR 或远端 CI。现有 CodeQL 工作区改动单独保留。

本地原始资料位于 `.ai-tmp/preview-root-cause-resume/`：

- `creation-close-v4.trace`、`trace-events-v4.json`：完整创建关闭时序；早期不完整 trace 不计入验收。
- `real-long.memgraph`、`hosting-direct-refs.txt`、`observer-notification-name.txt`、`common-awake-disassembly.txt`：强引用与符号检查。
- `AppKitProbe.swift`、`AutonomousAppKitProbe.swift`、`appkit-results.txt`、`appkit-autonomous-results.txt`：独立框架对照。
- `final-clean-cycles.json`、`final-clean-summary.json`、`final-clean-*-heap.txt`：30 轮有效采集与对象释放。
- `lan-source-events.json`：共享期间预览开闭 UTC 时间及源端状态。

临时 trace 可能包含进程环境或桌面内容，分享前需要脱敏。仓库文档保留结论和方法；临时文件不进入提交。

## MacBook 连续接收

真实接收设备为 Intel MacBookPro15,2，macOS 15.8、Chrome 154.0.8037.98。源屏每 100 毫秒更新可见计数，每秒交替颜色。接收连接不刷新、不重连，UTC 2026-10-11 16:27:23.355 至 16:32:23.356 连续采样五分钟。

| 指标 | 结果 |
| --- | --- |
| 有效样本 | 301，间隔 0.997 至 1.002 秒 |
| video 总帧数 | 3505 → 12970，增加 9465 |
| video 丢帧数 | 56 → 75，增加 19 |
| 每秒新增帧 | 26 至 53，零增帧区间为 0 |
| 播放状态 | 全程 readyState=4、paused=false、error=null |
| currentTime | 增加 299.998648 秒 |

源端共执行四轮预览开闭，其中第 3、4 轮完整位于正式采样窗口内，覆盖对应开闭及关闭后检查的接收样本区间分别增加 790、808 帧。预览关闭后共享 lease 保持 1、viewer 保持 1。接收端截图的动态计数持续变化，未观察到持续黑屏；一秒采样不能排除更短的停顿。两台机器尚未做精确时钟校准，这些数据不用于端到端延迟计算。

源端已关闭测试共享并退出动态画面程序，预览、lease、连接数均归零；清理后的堆快照中上述六类对象仍全部为零。三份保存的虚拟显示配置与启用状态保留。接收端于北京时间 00:34:09.956 关闭测试标签页，并回读列表确认不存在。

MacBook 原始文件位于 `/Users/syc/project/z7z8/.ai-tmp/voiddisplay-receiver-20261012/`，当地重新计算统计并核验一致：

| 文件 | SHA256 |
| --- | --- |
| `receiver-report.json` | `6bc8f3f44f32de6c3835525cb7d5a80982e4cc85d373b400cf7f964d5788442c` |
| `continuous-samples.jsonl` | `e749712d836deadadc6de17e4b1cb8f2670b5a6c0af06559ee06dcc1a9c90d0e` |
| `source-events-reported.json` | `0dfe85c0ebeab2e05e3e75e31af13a018a1d5865d34a65b059eee1c629d9199c` |

本机 `.ai-tmp/preview-root-cause-resume/remote-receiver-verification.json` 保存 MacBook 返回的核验与清理记录；接收端原始文件保留在 MacBook。

## 五分钟定向恢复验收

同日按用户要求缩短排查窗口，正式窗口为北京时间 00:40:18.566 至 00:45:18.566。只执行一轮，覆盖动态画面基线、两轮预览开闭、接收页重连以及显示器停用再启用。

- 两轮预览分别在 UTC 16:41:25.609 至 16:41:45.554、16:42:03.699 至 16:42:19.131 开启。源端均进入 active，关闭后恢复为一个共享 lease。
- 接收页于 UTC 16:41:48.788 导航空白页，停留五秒；16:41:54.064 发起重连，16:41:56.710 首次采到恢复播放。此操作覆盖页面断开重连，不等同于物理网络故障。
- UTC 16:43:16.274 停用显示器，运行数、共享数、连接数归零。旧接收页明确显示共享结束，符合 `target_disabled` 终止语义。
- UTC 16:43:23.239 重新启用，约 16:43:28 界面显示运行中；16:43:31.322 重新开始共享。显示器运行 ID 从 401 变为 403，配置 ID 不变。重新启用后保存配置与开始前完全相同。
- 新会话于 UTC 16:44:02.421 导航，16:44:04.463 首次采到画面，随后持续增帧。最后一个样本时间为 16:45:18.567，截止误差为 1 毫秒；16:45:19.057 关闭接收页并核对列表。
- 本轮未复现非计划黑屏；源端测试共享及动态画面程序已停止，会话、lease、viewer 归零，保存配置已核对恢复。

本机逐秒诊断与操作时序保存于 `.ai-tmp/lan-targeted-20261012/source-samples.jsonl` 和 `source-events.json`。源端诊断提供会话、有效帧与 lease 状态，未提供每秒编码及发送帧统计；本轮不宣称完成所有管线阶段的定量归因。

## 后续验收边界

此前一次黑屏伴随解码帧数停滞的历史样本缺少同步源端证据，本次未复现，当前尚未建立原因。不得从本次对象释放和连续接收通过推断历史黑屏已经修复。

30 分钟稳定性、多屏多接收端、睡眠唤醒、物理屏插拔、浏览器矩阵及三轮性能对照仍按测试策略独立验收，本次没有覆盖这些门禁。
