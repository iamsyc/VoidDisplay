# 显示质量与编码延迟基准

这套基准直接使用 `ScreenVideoEncoder` 的产品实现，独立生成 CoreText / CoreGraphics 图案，不采集桌面，不申请屏幕录制权限，不启动 app、relay 或浏览器。只借鉴“先分阶段测量，再调整队列”的工程方向；代码与素材均由 VoidDisplay 独立实现。

## 执行

使用仓库现有 Swift / Xcode 工具链，不安装额外依赖。工具遵循当前进程的 `DEVELOPER_DIR`，不切换系统 Xcode 设置。

```sh
# 仪器校验及短测：默认每轮预热 3 秒、测量 10 秒，交错比较 2/1、1/2、2/1 槽。
scripts/dev/display_quality_benchmark.sh --size 4k \
  --output .ai-tmp/quality/4k-screening

# 编码阶段正式对照；仍然不是含采集与观看端的产品验收。
scripts/dev/display_quality_benchmark.sh --size 5k --fps 60 \
  --warmup 30 --seconds 90 --rounds 3 \
  --output .ai-tmp/quality/5k-comparison
```

参数范围：`--size 1080p|4k|5k`（1920×1080、3840×2160、5120×2880），`--fps 30|60`，`--warmup 0...30` 秒，`--seconds 1...120` 秒，`--rounds 1...5`。默认 4K60、3/10 秒、3 轮。输出目录应位于 `.ai-tmp/`，每组使用新目录，任何已有目录（包括失败的部分证据）都会被拒绝，避免重跑或并发运行混写。环境与构建日志在输出目录，逐帧 JSON、图片及 `benchmark.json` 在其 `results/` 子目录。

Release 构建与测量分开计时。入口记录源码指纹、二进制 SHA-256、OS、CPU、Xcode / Swift 版本和图片校验和，测量前后检查源码一致性。记录远控、其他硬件编码、温度/供电与后台负载；顺序交错只能减少顺序偏差，不能消除这些变量。

## 样本与指标契约

图案固定物理像素字体大小（8、10、12、16 px），覆盖黑白小字、RGB 彩色文字、水平/垂直单像素线、滚动文字与变化标记。相同分辨率的八张 NV12 输入在测量前生成，计时阶段不绘图。每轮采样依次为静止、滚动、变化后保持；这仍是固定节拍的合成输入，静止段持续投递，不等同于 ScreenCaptureKit 的 idle 行为。

| 输出 | 起点与终点 / 含义 |
| --- | --- |
| `inputToCallbackMs` | 同一进程的单调时钟，调用产品 `encode` 前到编码输出回调入口；包含输入复制/缩放、提交和硬件等待及 Annex B 转换 |
| `encoderReportedMs` | 产品已有 `encodeStartMs` → `encodeFinishMs`，从输入复制后开始（含待送队列等待），毫秒精度；不能替代前一项 |
| `submissionMs` | 调用 `encode` 的同步耗时；不等于完整编码耗时 |
| `latenessMs` / `schedulerMissedFrames` | 输入节拍迟到与未投递的计划帧；迟到不补发成突发，不归因于编码器丢帧 |
| `outputFPS` / `bitrateBps` | 采样窗口内输入帧的成功编码数/Annex B 字节数除以窗口长度，含这些帧的尾部排空；是编码吞吐，不是浏览器 FPS 或 RTP 线上码率 |
| `capacityDrops` | 最新输入替换了尚未提交的旧待送帧；不是新输入被拒绝 |
| `deferredFrames` / `resumedFrames` / `pendingFrames` | 满槽暂存次数、由完成回调推进的次数、当前待送帧（最多 1） |
| `hardwareDrops` | VideoToolbox 输出回调明确标记的丢帧 |
| `inputFailures` / `compressionFailures` / `outputFailures` | 输入准备、VideoToolbox 提交/回调、输出转换/无回调的失败；同步和异步失败共用现有帧身份，避免重复计数 |
| `callbackRejections` | WebRTC 回调返回 false；不能据此断言发送背压或网络丢包 |
| `inFlightFrames` / `peakInFlightFrames` / `releasedFrames` / `releasedPendingFrames` | 当前、峰值与释放时回收的在途/待送输入；计数按编码 session 重置 |

`round-*-slots-*.json` 保留全部逐帧记录，包括预热、无输出输入、迟到和异常值。失败轮次保留原始帧、诊断及 `failureReason`，退出非零且不参与比较；`results/status.json` 区分测量程序的完成与失败，外层 `validation.json` 在最终源码一致性检查后才发布整体通过状态，两者均须成功。P50/P95/P99 使用 nearest-rank，不剔除长尾；统计 count 为 0 时结果缺失，不输出虚构零。汇总比较每种槽位各轮 P95 / FPS / 码率的中位数，单轮短测只能用于筛选。出现节拍丢失、硬件丢帧或低样本量时，先调查原因，不因脚本成功退出就宣称性能通过。

画质在独立的串行解码阶段测量，避免图像读回污染编码计时。系统 VideoToolbox 解码的是产品回调实际发出的 Annex B 字节，输出第一帧、滚动、变化首帧和保持帧的参考/解码 PNG。各区域分别报告 RGB PSNR、平均绝对误差、任意颜色通道误差大于 16/255 的像素比例、相邻像素梯度误差。无误差时 `exact=true`、PSNR 缺省，表示数学上的无穷大，不把缺省误读为零。

画质分为三组：`sourceToNV12` 衡量 sRGB → 4:2:0 输入转换损失，`sourceToDecoded` 衡量转换加压缩重建误差，`nv12ToDecoded` 单独观察压缩重建。该分解有助于发现彩色细字在 4:2:0 转换时已损失的细节。RGB 指标受色彩转换、字体和渲染版本影响，不是感知等价、可读性保证或不同编码器的等画质证明；必须结合区域 PNG 检查。画质通道使用默认 2 槽且串行输入，不用它宣称 1/2 槽在拥塞时画质相同。

## 静止末帧与诊断

基准另起编码 session 连续输入，直到观测到实际 `deferredFrames` 增加，然后立刻停止输入并排空在途和待送帧。`last-change-slots-*.json` 保存原始样本，报告区分“确实满槽暂存”“该次输入无需新输入自行恢复”“恢复帧执行关键帧请求”和“完全排空”。无法制造满槽时 `forcedDeferral=false`，恢复结论为 null，不能当作成功。该探针验证编码器边界，不代表真实桌面或网络不会丢帧。

生产默认仍为 2 个在途槽。满槽时最多保留 1 张自有 NV12 待送图像；新的输入替换它，并保留尚未执行的关键帧请求。完成回调驱动一次提交，没有定时重试或无限重试。停止时释放全部待送/在途记录；跨重启不复用帧 ID，旧回调和重复回调不改变新会话。编码 session、输入和完成处理共用串行执行器，原生回调只异步投递，避免失效 session 时反向等待。

图像被复制到编码器自有缓冲，不长期占用采集池。在途加待送最多 3 张图像；替换复制过程中可短暂再持有 1 张，VideoToolbox 自身参考帧由其管理。与直接丢弃新输入相比，持续过载会增加待送等待和复制成本，需要正式对照测量；恢复末帧不等于零延迟代价。

报告 schemaVersion 为 2。schema 1 的 `capacityDrops` 计数表示拒绝新输入，schema 2 表示替换旧待送帧，不能混作同一计数；延迟、图案和画质指标的测量边界保持不变。

浏览器已有状态采样增加数值诊断，可在观看页控制台读取：

```js
VoidDisplayBrowser.stats.getLatestDiagnostics()
```

该值是最近一条两秒采样，不积累历史、不上传，不包含地址、SDP 或访问凭证。`interval` 为 null 表示首次采样、报告/SSRC 更换、时间戳无推进或计数器复位。可选字段不支持时为 null；丢包计数的负增量保留，表示迟到包修正。当前画质状态按区间内丢包/解码丢帧判断，不再让历史累计值永久标记降级。

状态栏 FPS 与 `interval.framesPerSecond` 使用同一个完整采样区间。尚无完整区间或解码计数不可用时显示 `—fps`；`0fps` 表示完整区间内没有新增解码帧。连接启动时的浏览器瞬时估计可能反映短时解码突发，不能代表这段共享的持续帧率。

字段来自 [W3C WebRTC Stats](https://www.w3.org/TR/webrtc-stats/)：

- `packetsLost` 为区间丢包增量；`framesDropped` 为接收解码侧增量；`presentationDrops` 来自 video 元素 `getVideoPlaybackQuality()`，单独保留。
- `decodeMs` 是 `totalDecodeTime / framesDecoded` 的区间差分；`jitterBufferMs` 使用 `jitterBufferDelay / jitterBufferEmittedCount` 的区间差分。
- `receiveToDecodeMs` 使用 `totalProcessingDelay / framesDecoded` 的区间差分，包含接收到解码完成，不是显示等待。
- `roundTripTimeMs` 只取该 inbound transport 实际选择的 candidate pair，不混入未选中路径；RTT 不是单向画面延迟。

这些是不同阶段的观测，不相加成端到端延迟。当前没有完整的发送队列/网络丢帧因果归因；编码器统计和浏览器统计也没有跨进程同帧关联。

## 验证与边界

```sh
scripts/ci/unit.sh --filter 'BenchmarkMetricsTests|HEVCQualityDecoderTests|ScreenEncoderDiagnosticsTests'
scripts/dev/validate.sh --skip-ui-smoke
```

常规单元测试只验证纯指标、参数校验、NAL 边界、统计语义和不启动编码 session 的输入失败路径，不调用真实采集或硬件编解码。独立硬件回归需显式设置 `VOIDDISPLAY_ENCODER_HARDWARE_TESTS=1` 并运行 `scripts/ci/unit.sh --filter 'ScreenEncoder.*HardwareTests'`，覆盖最后输入、回调重入、停止/重启及在途销毁；仍不请求采集权限。性能实验需显式调用基准入口，其缺失不是自动化测试通过后的隐含证据。

本基准未覆盖 capture-to-photon、浏览器预计呈现、跨设备时钟同步、网络背压、CPU/RSS 正式采样和接收端能力预算。真实应用验收继续遵循[测试策略](./testing-strategy.md)：签名副本、30 秒预热与 90 秒采样的三轮交错比较、同帧身份和时间边界验证，以及独立的接收设备矩阵。
