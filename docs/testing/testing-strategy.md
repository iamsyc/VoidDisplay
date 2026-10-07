# 测试策略

仓库的 Xcode 构建、UI 测试和完整回归入口不接受 `XCODE_XCCONFIG_FILE`。运行前需移除该环境变量；入口会在构建或复用成功证据前拒绝它，避免外部配置与已验证产物不一致。

## 分层

| 层级 | 覆盖内容 | 入口 |
| --- | --- | --- |
| 静态门禁 | Shell、workflow、格式、lint、工程结构和项目静态约束 | `scripts/ci/static.sh` |
| 单元与集成测试 | SwiftPM、浏览器 JavaScript、Go relay | `scripts/ci/unit.sh` |
| Xcode build | App target、资源、工程配置和编译诊断 | `scripts/ci/xcode.sh --action build` |
| UI smoke | 按职责组织关键用户旅程，用实测耗时和启动次数控制成本 | `scripts/ci/ui_smoke.sh` |
| 完整回归 | 静态、单元、Debug build、UI、稳定性和 arm64 release smoke | `scripts/ci/full_regression.sh --destination "platform=macOS,arch=$(uname -m)"` |

Xcode 的 `VoidDisplay` scheme 用于 App build 和 run。UI test 必须通过 `scripts/ci/ui_smoke.sh` 或 `scripts/ci/xcode.sh` 启动，以便 wrapper 在完整 `xcodebuild` 生命周期持有本用户的 UI session lock。Scheme 会拒绝没有 wrapper token 的 Cmd-U。完整单元与集成测试入口仍是 `scripts/ci/unit.sh`。

## 测试设计

默认自动化测试应满足以下约束：

- 断言行为、状态转换、输出或用户可观察结果。
- 使用可控 provider、fake、fixture 和临时目录隔离系统状态。
- 不依赖真实局域网、真实桌面内容、人工点击系统弹窗或固定端口。
- 不新增只有渲染或启动、没有行为断言的弱测试。
- 同一契约优先在最接近所有权的层级验证，避免在多个 target 重复覆盖实现细节。

Consumer 生命周期回归需要覆盖重复 attach/detach 后 lease、等待者与采集需求回到空状态，以及快照大小随历史轮数保持有界。使用可控异步挂起点验证启动、重试、重建期间关闭，重复关闭、等待取消和旧实例结果迟到；终态通知必须在 lease 移除前完成。失败排序测试需要交错事务、采集与独立 consumer 的失败，反转显示器排序，并确认取消、过期及重复通知不改变最近失败。

本机性能对照固定源码指纹、构建配置、浏览器版本、显示源、性能模式与合成画面。每个场景预热 30 秒后采样 90 秒，重复三轮，以三轮结果的中位数比较进程 CPU、RSS 和观看端分辨率、帧率、码率、掉帧及帧内时间标记延迟。必须先验证原始样本落盘和时间标记有效性；缺失或失效的样本不能计为通过。帧率下降超过 5%，或 CPU、RSS、延迟上升超过 10% 时，先查明可重复退化。临时显示器与共享状态在验收后恢复，结论限定为所测本机回环场景。

候选可先通过短测筛选；筛选用于淘汰方案，不能替代进入产品前的三轮正式对照。基线与候选交错运行，每轮记录实际启动的签名应用路径、二进制哈希与对应源码；测旧构建时不能用当前工作区指纹代替其构建来源。资源采样需覆盖预热结束后的完整测量窗口，核对首尾时间；采样缺段的轮次只保留为诊断资料。同机远控、合成画面与其他硬件编码会影响测量，必须记录其运行状态，避免拿不同负载下的旧基线宣称收益。

帧率调查同时核对原生显示模式、动态画面的实际呈现、有效采集帧、编码帧和浏览器解码帧。定时器或绘制回调执行 60 次不能证明显示源每秒呈现 60 个不同画面；基准优先使用随显示刷新提交的 Metal 动态画面，并验证帧内标记持续更新。采集 idle 回调不计作新帧。区分网络 RTT、帧组装与接收缓冲、解码和呈现等待，不能将 RTT 直接与画面端到端延迟比较。

Relay 低延迟播放回归覆盖真实 SDP offer/answer 协商、每个 viewer 的扩展 ID、未协商时省略扩展、`0/0 ms` 线上载荷，以及 publisher 原包与媒体时间戳不变。调整播放策略后需实际读取浏览器 WebRTC 统计和同帧时间标记，分别检查接收缓冲、解码后呈现等待及实际呈现帧数；WebRTC 的解码丢帧不能替代 video 元素的呈现丢帧统计。更小的合成队列仍须通过整链路实测，不能仅凭上游参数含义认定延迟会降低。

编码配置回归须检查原生工厂的实际能力、relay SDP 与浏览器统计共同指向 H.265，并保留 HEVC Main Level 6、SRST 和对应 RTX。覆盖关键帧 VPS、SPS、PPS 与每个 NAL 的 Annex B 转换，以及不支持所需 profile、tier、level 时的明确提示；默认 SDK 编解码器列表不代表应用注入编码器后的实际发送能力。真实签名应用验收核对 VideoToolbox、硬件编码标记、4K 与 3840×2400 HiDPI 首帧，持续采样确认没有编码 CPU 限速，并检查节能缩放与重连；只验证 SDP 中的编码名称不足以证明能够按源分辨率和帧率出画面。

等级边界回归同时检查每帧像素、每秒样本和最终码率预算，包含 8192×8192 自定义源、较高刷新率及编码尺寸填充。4222×4222@60 的可见像素处于 Level 6 上限内，但 VideoToolbox 填充后需要 Level 6.1；硬件探针须读取真实 VPS/SPS 或 hvcC 等级，确认缩放后的码流不高于 SDP 声明。观看端低等级、不同 profile 或 tier、缺省等级、混合能力及 RTX 关联均需回归，relay 不得仅凭 H.265 名称接受不满足约束的 offer。

使用真实硬件参数集回归 Main tier 与 Level 6 声明转换，验证防竞争字节往返、PPS 与图像载荷不变、带内参数集同样处理，以及超等级或不同 profile、时间层被拒绝。签名应用验收直接读取浏览器接收的 VPS/SPS，要求 profile=1、tier=0、level=180 与 SDP 一致，不能以浏览器成功解码推断码流声明合规。硬件编码器的软平均码率不足以证明 Main tier 上限，必须保留 60 Mbps 的 DataRateLimits 硬限制。

硬件编码队列验收需要主动制造繁忙状态，核对在途帧上限、被丢弃输入携带的关键帧请求在恢复后仍被执行，以及释放后待处理记录归零。像素缓冲所有权和降分辨率路径必须在真实硬件上验证。独立编码探针只用于定位编码耗时，不能替代含采集与观看端的整链路比较；不同编码格式的耗时和码率也不能直接解释为等画质优劣。

帧内时间标记测量必须明确终点。定时读取视频得到的帧年龄包含读取时机偏差，仅作为诊断指标；评估浏览器预计呈现延迟时，冻结读取帧并核对其 RTP 时间戳与回调元数据属于同一帧，使用 `performance.timeOrigin + expectedDisplayTime - sourceTimestamp`，单独记录读取耗时，及时释放冻结帧。跨设备测量还需校准时钟。记录有效样本、帧身份重试、丢帧和原始超阈值结果；修正仪器后按相同条件重跑修改前后三轮，并用受控实验验证偏差来源。浏览器预计呈现时间不等于屏幕实际发光时间，报告必须保留该限制。

拆分原生阶段时用帧内标记关联采集、编码与观看端。WebRTC 可平移采集时间戳并随机化 RTP 起点，不能直接按原始时间戳连接两端记录；先验证同一连接内的对应关系，再统计同帧阶段耗时。画面生成至采集回调之间还包含源画面的 GPU 提交与呈现，不能全部计作采集开销。合成图案的重建误差包含颜色转换、边缘采样及压缩损失，单次 RGB PSNR 不足以证明两种编码达到相同画质。

UI smoke 复用 [SmokeTestHelpers.swift](../../UITests/VoidDisplayUITests/Smoke/SmokeTestHelpers.swift)。共享端口通过 `-sharing.preferredPort <port>` launch arguments 注入，测试不直接写硬编码 suite。

UI 用例按用户旅程组织，分为 Home、VirtualDisplay、Preview、Diagnostics、MenuBar 和 Settings。独立前置条件保留独立启动；同一前置状态下的连续操作合并，并用 `performSmokeStep` 标记阶段。预览和设置使用真实窗口、控制器及运行时，模拟边界放在采集与系统 provider。纯文本映射、状态转换、按钮可用性和组件固有尺寸在 Swift 单元测试中验证；UI 层只保留真实窗口、布局、点击结果和关键辅助功能路径。UI 测试禁止使用 `.typeKey`、`.typeText`、`XCUIKeyboardKey`、`CGEvent` 或 System Events 合成键盘输入，焦点状态通过测试环境注入和 AppKit 焦点遍历验证。

## 本地验证

显示画质、编码槽位对照与分阶段指标的可执行入口见[显示质量与编码延迟基准](./display-quality-benchmark.md)。其合成硬件结果与真实采集/跨设备验收分开报告。

日常完整本地入口：

```bash
scripts/dev/validate.sh
```

小范围改动使用最窄的相关门禁：

```bash
scripts/ci/unit.sh --filter '<test-filter>'
scripts/ci/xcode.sh --action build --configuration Debug \
  --destination "platform=macOS,arch=$(uname -m)"
scripts/ci/ui_smoke.sh \
  --only-testing '<test-identifier>' \
  --destination "platform=macOS,arch=$(uname -m)"
```

`unit.sh --filter` 原样传递 SwiftPM 的筛选表达式，保留 suite、方法和正则语义，也支持多个 `--filter`。未命中测试时门禁失败，避免同名方法让错误的 suite 显示通过。`--only-testing` 用于 Xcode/UI 入口。

源码指纹使用各文件内容的定长摘要、路径、类型和可执行位，不包含提交哈希；二进制内容中的分隔符不会改变文件记录边界。Xcode 指纹排除文档、单元测试和 workflow；产品源码、UI 测试、资源、依赖与构建脚本变化会使构建失效。提交相同文件或只改文档不会导致 UI 重建。完整回归 checkpoint 仍使用全仓库内容指纹。

`validate.sh`、`full_regression.sh` 和 `ui_smoke.sh` 共用受管构建缓存。前置阶段调用 `ui_smoke.sh --build-only`，先检查完整证据，再校验或构建产物，随后直接复用。

DerivedData 按仓库、工具链、目的架构和配置保留，源码改变后仍使用 Xcode 增量编译；产物清单必须与当前源码匹配才可跳过构建。完整测试证据额外区分 macOS 版本。

`ui_smoke.sh` 默认按源码指纹、Xcode 版本、目标架构和配置复用 `build-for-testing` 产物，定向 selector 每次执行 `test-without-building`。完整 `VoidDisplayUITests` 通过后会复用有效结果；`--rerun` 强制重新执行，`--rebuild` 同时重建受管测试产物。相同源码和 selector 已在运行时会立即拒绝；共享同一构建键的其他 selector 通过生命周期锁串行执行完整性校验、重建、构建和测试，任何运行中的 selector 都不会被并发 `--rebuild` 删除测试产物。

每次运行的构建日志及测试结果写入独立的 `OUT_DIR/runs/<run_signature>/invocation.*/`，顶层 `ui-smoke-summary.json` 保留本次入口汇总。使用同一 `OUT_DIR` 的入口串行写入，定向运行和预构建不会覆盖完整测试证据或删除正在发布的报告。取得构建生命周期锁后及发布通过证据前，均验证源码未变化；发生变化时记录 `source_changed` 并废弃结果。预构建失败同样写入顶层失败汇总，保留实际原因，并遵循 `--enforce-failure` 的退出语义。Xcode 尚未启动时，失败汇总的日志和结果路径为空，不计入历史运行的用例或启动次数。

跨模块、并发、持久化、网络、安全、脚本、工程设置或发布改动需要扩大验证范围。本机支持对应 release target 时，完整回归入口是：

```bash
scripts/ci/full_regression.sh \
  --destination "platform=macOS,arch=$(uname -m)"
```

该入口先并行运行静态门禁、全部单元与集成测试和 `build-for-testing`，随后复用同一 DerivedData 串行执行 UI target。UI 完成后，稳定性检查和 arm64 release smoke 并行执行。每个并行 lane 的完整输出保存在本次 `OUT_DIR/lanes`，最终 summary 记录前置、UI、后置和总耗时。Nightly core 使用 `--skip-ui-tests --skip-xcode-preflight --skip-release-smoke` 跳过已由独立 runner 承担的完整 UI target、Debug 预构建和双架构 Release dry run。完整命令选择规则见根目录 [AGENTS.md](../../AGENTS.md)。日常开发不得在源码未变化时重复运行完整 UI 目标。

完整回归会在指定 `OUT_DIR` 写入 `full-regression-checkpoint.json`。同一源码指纹、目的架构、UI selector 和稳定性迭代参数再次使用该目录时，已通过且产物仍完整的阶段会直接复用。失败后重新执行原命令即可从最近的完整阶段继续；需要强制重跑全部阶段时增加 `--restart`。

### 本机并发边界

- 同一用户 GUI 会话只允许一个 XCUITest wrapper 运行。`xcode.sh` 在启动 `xcodebuild` 前获取 `DARWIN_USER_TEMP_DIR` 下跨工作树共享的 `lockf`，并在 `xcodebuild` 及其子进程完全退出后释放。`ui_smoke.sh` 的每次 attempt 委托给该入口。
- 自动化脚本最多等待活动 UI session 10 分钟。Xcode 中直接执行 Test 会提示使用脚本入口；直接执行 Run 时会非阻塞检查锁，若测试正在运行，会在终止 App 之前拒绝本次动作。
- UI session 会结束当前运行的 VoidDisplay，以满足同 Bundle ID 和单实例锁下的干净启动要求。测试结束后不会自动恢复原调试会话。
- SwiftPM 单元测试保持一个进程，由 Swift Testing 在进程内并行未标记 `.serialized` 的 suite。SwiftPM、浏览器 JavaScript 和 Go 三条单元测试 lane 可并行执行。UI 运行期间不并发执行 stability 或其他 Xcode 重任务。
- static lane 使用本次验证目录下独立的 `AI_TMP_DIR`。默认 artifact 目录包含进程 ID，避免多个 Agent 在同一秒启动时共享输出目录。

### 隐私权限敏感的真实应用验收

屏幕录制等 macOS 隐私权限会识别应用的代码签名身份。需要验证真实权限状态时，使用 Xcode Personal Team 自动管理的本机 `Apple Development` 身份构建验收副本：

```bash
scripts/dev/build_signed_runtime.sh
```

默认输出目录固定为 `.ai-tmp/signed-runtime/current`。只启动该目录下 `signed-runtime-summary.json` 中 `app_path` 指向的应用，并在覆盖构建前退出上一实例。需要保留每轮证据时，复制日志与摘要到本轮验收目录，继续从固定位置启动应用。显式指定 `--out-dir` 时，也应持续复用同一目录。

该流程只用于当前 Mac 上的开发验收，不进入 CI、Release 或公开分发。普通自动化测试继续使用隔离 provider，普通 Xcode 门禁继续关闭签名。固定位置与签名有助于稳定系统对应用身份的识别；录屏预检通过仍可能出现直接访问屏幕的额外系统确认，应分别记录预检状态、弹窗类型和用户选择，不得据此宣称所有系统确认已消除。

免费 Apple Account 提供的 Xcode Personal Team 足以完成该流程，不要求 Developer ID、付费会员或公证。缺少可用 `Apple Development` 身份时，应在 Xcode 的 Accounts 设置中恢复 Personal Team 开发身份并重新构建；不得改用未签名或 ad hoc 副本声称权限验收通过。开发身份更新后，macOS 可能要求重新授予屏幕录制权限。

### 原生显示模式与进程回收验收

`VirtualDisplayModeSelectionTests` 覆盖尺寸、HiDPI 和刷新率选择；`VirtualDisplayProcessTests` 使用无显示器副作用的子进程覆盖 EOF、提前退出、无效响应、超时、取消和管道断开，并用模式提供者替身验证正常/意外退出只恢复存活屏幕、保留用户所选模式、恢复先于终止通知。`VirtualDisplayRuntimeTrackerTests` 覆盖创建中的序列号占用、取消、reset、配置删除和 generation 竞争。

需要实际创建原生显示器时，先完成上述开发签名构建，再单独运行：

```bash
scripts/dev/verify_display_host.sh \
  .ai-tmp/signed-runtime/current/signed-runtime-summary.json \
  .ai-tmp/display-host-acceptance
```

该验收创建序列号 `4000932`、`4000933` 的临时显示器。6 个宿主场景覆盖小尺寸普通模式、HiDPI、同序列号重复创建、59.94 Hz、120 Hz、进程终止和父进程退出，结果写入 `native-acceptance.json`。随后构建并运行 `DisplayHostAcceptance`，在 AppKit 事件循环中使用产品的 `CGVirtualDisplayRuntimeDriver`，启动同一签名 App 内的宿主；8 个双屏场景分别在 1080p 和 4K 下关闭先创建或后创建的屏幕，覆盖 EOF 和意外终止，结果写入 `native-driver-acceptance.json`。逐次核对实际逻辑尺寸、像素尺寸、其他屏幕模式和回收结果，任一测试序列号已在线时中止，失败时也等待原始显示列表恢复。测试不改应用保存配置。这个入口有真实显示副作用，不加入普通单元或 UI 自动化门禁；应用内的编辑、重建、预览和共享仍需通过签名 App 验收。

## 环境故障分类

测试宿主在 bootstrapping 前被 macOS 隐私自动化、Accessibility、Input Monitoring、Gatekeeper 或签名策略终止时，应记录为环境设置失败。先通过 `.xcresult` 和统一日志确认宿主未进入测试，再处理机器环境并复测最小目标。

产品代码或测试代码触发了本可避免的 Screen Recording、麦克风、摄像头、键盘输入等授权弹窗时，应视为测试隔离缺陷并修正 provider 或测试模式。任何 `totalTestCount == 0` 的结果都不能计为通过。

## 远程 CI

远程 runner、变更分类、job matrix 和 artifact 由 workflow 决定。PR 中，文档和明确列出的独立配置只运行静态检查，单元测试变更执行单元门禁，产品、依赖、构建与测试运行脚本变更执行相关构建及 UI 门禁；混合变更取所需门禁的并集。触发 CI 的 main push 保留完整门禁，为发布恢复提供完整目标验证。仓库分支保护或 ruleset 与实时 PR check suite 共同决定哪些 check 属于外部必需门禁。本地通过不能替代远程 CI 结果。详细说明见 [CI Workflows](./ci-workflows.md)。

CI 的完整 UI 旅程需要容纳 1180×720 窗口、菜单栏和 Dock。PR 与 Nightly 在运行前通过 `scripts/dev/prepare_ui_display.swift` 检查桌面，必要时选择至少 1280×900 的受支持显示模式，变更仅应用于当前登录会话。没有可用模式时明确报告环境准备失败，不启动会因窗口超出屏幕而误报的 UI 测试。菜单栏启停过程中控件会暂时呈现为进度指示器，交互测试等待按钮恢复可用后再读取终态。

## 耗时与覆盖率报告

`ui-test-report.json` 和 `ui-test-report.md` 从 xcresult 和执行日志提取每例耗时、启动次数、阶段及失败 selector 的复跑命令，重试保留每次尝试的成本和结果。缺失日志或耗时显示为不可用，复用历史证据时分别显示历史启动次数和本次零启动。新增旅程需说明独立启动原因，合并时保留原行为断言，评审实测总耗时及慢用例变化，不以固定用例数量限制覆盖。耗时比较需记录同一主机、Xcode、selector 和是否复用构建，编译与排队时间单列。

`scripts/ci/coverage.sh` 运行带插桩的 SwiftPM 测试并解析 LLVM JSON。解析入口把仓库根目录解析为真实路径，使符号链接入口与编译器记录的源码路径一致。`coverage-report.json` 保留各模块行、函数、区域覆盖率以及每个文件的未覆盖区域起始行，Markdown 列出模块变化和缺口最大的文件。这里只度量 SwiftPM 执行到的源码，UI、JavaScript、Go 属于独立证据。不存在统一百分比阈值。

通过后的报告保存为 `.ai-tmp/test-evidence/coverage/latest.json`，下次与其比较；首次运行标记基线缺失，新增模块不伪造历史变化。Nightly 恢复同分支的上一份基线，并把覆盖率与 UI 报告写入 job summary。

覆盖缺口按业务风险处理。先从 JSON 的文件和区域定位控制器、状态机、持久化及模块适配边界，再检查现有断言。SwiftUI `body` 和窗口布局使用 UI 证据，不因整个模块的百分比偏低而重复启动页面，也不从原始覆盖率中移除这些文件。

| 关键风险 | 主要验证位置 |
| --- | --- |
| 无效端口、服务启动失败时不得创建共享会话 | `HomeVirtualDisplaySurfaceControllerTests` |
| 排序、重置失败保留配置并显示持久化错误，重试可完成 | `HomeVirtualDisplaySurfaceControllerTests`、`VirtualDisplayControllerTests` |
| 预览与共享的租约释放、显示器替换后身份连续性 | `DisplayRuntimeAdapterTests` 及 Runtime、Capture、Sharing 对应测试 |
| 反馈诊断授权、导出失败重试、历史恢复及复制状态 | `AppSettingsFeedbackControllerTests` |
| 菜单栏、编辑保存、窗口和布局的真实交互 | 对应 UI smoke 旅程 |

## 本地测试产物保留

日常验证使用默认受管 DerivedData，每个仓库、工具链和目标复用同一构建目录。一次性诊断指定独立 DerivedData 后，任务完成且构建进程退出时应删除该目录；保留所在运行目录中的汇总、日志、覆盖率和 `.xcresult`。不要为每次重跑复制整套构建产物。

保留当前受管 UI 构建、SwiftPM `.build`、覆盖率基线和最近一次完整回归证据。未解决失败的日志及结果保留到问题关闭；成功历史证据完成交接后保留 7 天。签名验收 app、发布包、截图和含源码的 worktree 按各自任务管理，不随构建缓存清理。

大范围回归前使用 `df -h .` 检查可用空间，使用 `du -hd 1 .ai-tmp` 定位旧运行。空间不足时先列出待清理目录，确认没有运行中的构建或测试、目标位于 `.ai-tmp` 内且属于可再生产物，再清理已结束运行的 DerivedData。清理清单及前后空间记录放在本次 `.ai-tmp` 任务目录；禁止整体删除 `.ai-tmp`。可用空间低于 10 GiB 时先处理旧产物，再开始完整回归。


## 创建与共享的验证

自动化覆盖模板像素尺寸、创建后按 ID 预览、预览失败保留配置、二维码解码、重连计时器与过期响应，以及单个显示器生命周期和消费者恢复。

UI 使用隔离 fixture 验证创建表单、更多菜单、菜单栏入口及宽窄布局。所有新增产品路径沿用权限隔离。完整 UI 与本机 Debug、全量单元、Release smoke 分别保留结果；界面截图及测试 URL 使用测试凭证。

真实验收独立记录，自动化通过不代表完成以下检查：

- 从隔离空配置创建并预览，将固定演示文档移入扩展虚拟屏，另一台设备看到文档更新，同时主屏可独立编辑工作文档。首次成功目标 2 分钟，外部准备单独计时。
- 接收端矩阵包含 Mac Chrome/Safari、Windows Chrome/Edge、iPad Safari、Android Chrome。至少一个真实接收端完成全流程，其余未测组合保持明确标记。
- 30 次访问首帧 P95、30 次生命周期、单屏及双屏双接收端各 30 分钟；启动恢复、睡眠唤醒、物理屏插拔、断线和撤销链接分别记录。
- 同一负载下 30 秒预热、90 秒采样，基线和变更交错比较三轮。FPS 下降超过 5% 或 CPU/RSS/延迟增加超过 10% 需要调查。
- 5 名独立参与者，至少 3 名新用户；4 人独立完成。5 类故障各 2 次，自助恢复目标 9/10。人工提示记为未独立完成。

缺少设备、参与者或环境时记录验收缺口，不能以本机打开共享页面代替跨设备证据。
