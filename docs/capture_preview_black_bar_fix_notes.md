# 屏幕监听预览左右黑边问题修复记录

## 背景

屏幕监听预览窗口长期存在一个顽固问题：

- 预览内容左右会出现黑边
- 调整后经常变成左右黑边消失，但上下内容被裁掉
- 仅靠人工截图反馈，调试回路很慢

这次修复的目标有两个：

1. 解决预览窗口左右黑边
2. 建立一套可重复、自验证的本地检查方法，避免后续继续靠人工截图来回试错

## 现象与误区

### 现象

预览窗口里使用的是 `AVSampleBufferDisplayLayer`，视频内容按原始比例显示。窗口开启“适应”模式时，理想效果应当是：

- 保持完整画面
- 不拉伸
- 不裁切
- 不出现左右黑边

实际却出现了左右黑边。

### 常见误判

这个问题很容易被误判成以下几类：

- 采集帧本身有黑边
- `AVSampleBufferDisplayLayer.videoGravity` 选错
- 只要切到“填充”或强行拉伸就能解决
- 只要写几组常见分辨率预设就能解决

这些方向都不对，或者只能暂时掩盖问题。

## 根因

根因在预览窗口初始 sizing 逻辑，位置见 [CaptureDisplayView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift#L144)。

旧逻辑的关键问题：

- 用采集源宽高比计算窗口大小
- 计算时只考虑 `window.contentRect(forFrameRect:)`
- 预览窗口又使用了系统 unified toolbar/titlebar
- 真正承载预览层的区域实际是 `window.contentLayoutRect`

这两者并不相同。

`contentRect` 表示窗口内容区域。  
`contentLayoutRect` 才是系统 toolbar/titlebar 扣除后，真正适合承载内容布局的区域。

旧逻辑的问题可以表达成：

```text
代码以为：
窗口内容区宽高比 == 采集源宽高比

实际发生：
真实预览承载区宽高比 != 采集源宽高比
```

结果就是：

- 对窗口尺寸来说，看起来像是按正确比例设置了
- 对 `AVSampleBufferDisplayLayer` 来说，实际显示区域偏宽
- 在 `resizeAspect` 下，左右自然会留黑边

## 这次修复的原理

修复点仍在 [CaptureDisplayView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift#L144)。

核心思路：

1. 先拿到采集源真实宽高比
2. 同时拿到窗口 `contentRect` 与 `contentLayoutRect`
3. 计算两者之间的 `layout inset`
4. 用“真实预览尺寸 + layout inset”反推窗口应该有的内容尺寸
5. 再用这组尺寸设置 `window.contentAspectRatio` 和最终 window frame

关键代码思路如下：

```text
layoutInsetWidth = contentRect.width - contentLayoutRect.width
layoutInsetHeight = contentRect.height - contentLayoutRect.height

targetContentSize =
    previewRenderableSize + layoutInsets

window.contentAspectRatio = targetContentSize
window.frameRect(forContentRect: targetContentSize)
```

修复后的目标关系：

```text
真实预览承载区宽高比 == 采集源宽高比
```

这就是左右黑边消失的原因。

## 这次不是靠预设修复

这次修复不依赖固定分辨率表，也不依赖一批写死的宽高比预设。

生效条件只有两个：

- 上游能提供正确的采集源宽高比
- 当前窗口的 `contentLayoutRect` 能正确反映 toolbar/titlebar 对内容区的占用

因此它是公式化、自适应的做法，适用于：

- 16:10
- 16:9
- 21:9
- 竖屏
- 其他非标比例

只要源宽高比是准确的，窗口都会按同一套规则计算，不需要为每种屏幕写一套特殊分支。

## 为什么以前容易修歪

### 误把“消黑边”做成“裁内容”

如果直接朝“黑边消失”这个目标调，很容易滑向下面两种做法：

- 改成类似 `aspectFill`
- 强行把窗口高度压小或宽度拉满

这样视觉上左右黑边确实会没掉，但代价是：

- 上下内容被裁掉
- 或者画面发生非等比拉伸

这类修法属于错方向。

### 只看整窗截图，不看真实内容区

另一个常见坑是看整窗截图判断。整窗会包含：

- 标题栏
- toolbar
- 圆角
- 阴影
- 黑色背景层

这些因素会干扰判断，导致很难确认问题是在：

- 预览层本身
- 窗口尺寸
- 还是分析方法

正确做法是只看预览内容区。

## 这次新增的自验证链路

为避免后续继续靠人工截图反馈，这次加了一套专门的自验证工具链。

相关文件：

- [CapturePreviewDiagnosticsRuntime.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Shared/Testing/CapturePreviewDiagnosticsRuntime.swift)
- [CapturePreviewDiagnosticsSession.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Shared/Testing/CapturePreviewDiagnosticsSession.swift)
- [CapturePreviewRecordingSink.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Shared/Testing/CapturePreviewRecordingSink.swift)
- [CapturePreviewDiagnosticsTests.swift](/Users/syc/Project/VoidDisplay/VoidDisplayUITests/Diagnostics/CapturePreviewDiagnosticsTests.swift)
- [capture_preview_self_check.sh](/Users/syc/Project/VoidDisplay/scripts/test/capture_preview_self_check.sh)
- [capture_preview_analyze.swift](/Users/syc/Project/VoidDisplay/scripts/test/capture_preview_analyze.swift)

### 诊断环境变量说明

以下环境变量仅用于预览诊断与 UI 测试场景：

| 变量名 | 取值示例 | 含义 |
| --- | --- | --- |
| `VOIDDISPLAY_CAPTURE_PREVIEW_SOURCE_SIZE` | `3008x1692` | 注入的诊断画面像素尺寸。 |
| `VOIDDISPLAY_CAPTURE_PREVIEW_TARGET_CONTENT_WIDTH` | `1180` | 初始窗口目标内容宽度覆盖值（point）。 |
| `VOIDDISPLAY_CAPTURE_PREVIEW_REPLAY_IMAGE_PATH` | `/abs/path/frame.png` | 用指定图片替代内置诊断图。 |
| `VOIDDISPLAY_CAPTURE_PREVIEW_RECORD_DIRECTORY` | `/abs/path/recordings` | 预览录制输出目录。 |
| `VOIDDISPLAY_CAPTURE_PREVIEW_SCALE_MODE` | `fit` 或 `native` | 预览缩放模式。`fit` 表示适应模式，`native` 表示 `1:1` 模式。 |

使用建议：

1. 常规自检直接运行 `zsh scripts/test/capture_preview_self_check.sh`，脚本会自动跑 `fit` 与 `native` 两轮。
2. 手动跑单轮 UI 诊断时，通过 app launch environment 设置 `VOIDDISPLAY_CAPTURE_PREVIEW_SCALE_MODE`。

### 自验证思路

1. UI test 场景下注入假的监听会话
2. 用诊断图代替真实桌面
3. 诊断图包含四边彩色边框、四角标记、中心圆与网格
4. 自动打开预览窗口
5. 只截取预览内容区
6. 用脚本做像素判定

### 这套方法能回答什么问题

- 左右是否还存在黑边
- 上下是否被裁掉
- 四角标记是否完整可见
- 中心圆是否被拉伸成椭圆

### 当前诊断矩阵

已覆盖以下场景：

- `macbook-16x10-compact`
- `macbook-16x10-wide`
- `desktop-16x9-medium`
- `ultrawide-21x9-medium`
- `portrait-tall`

这些场景足以覆盖绝大部分常见与非常见比例。

## 这次分析脚本踩过的坑

分析脚本最初也踩了几个坑，位置在 [capture_preview_analyze.swift](/Users/syc/Project/VoidDisplay/scripts/test/capture_preview_analyze.swift#L57)。

### 1. 边缘取样点过死

最早是用固定点取样，例如左边取 `x=0.02, y=0.5`。  
问题在于超宽图、圆角、边框厚度、抗锯齿都会让固定点落在非目标区域，导致误判。

后面改成：

- 在边缘窄条区域内搜索最接近目标色的像素

这样对不同宽高比更稳。

### 2. 角标检测不能只看单点

四角角标本身面积不大，抗锯齿明显。  
如果只看某一个点，很容易碰到边缘半透明像素。

后面改成：

- 在对应象限搜索最接近角标色的像素

### 3. 圆形检测范围不能过大

如果中心圆检测范围太大，网格线和其他颜色会干扰边界推断。

后面改成：

- 只在中心区域搜索圆形颜色

### 4. 相对路径在脚本里不够稳

分析脚本直接接收路径时，若路径未标准化，批处理和不同调用目录下可能出现加载失败。

后面改成：

- 先把输入路径转成标准化绝对路径再加载

## 推荐的后续排查顺序

以后如果再碰到预览显示异常，建议按这个顺序查：

1. 先跑自验证脚本  
   `zsh scripts/test/capture_preview_self_check.sh`

2. 先看诊断图结果，再看真实桌面效果  
   这样可以先排除布局算法问题

3. 如果诊断图正常、真实桌面异常，优先查上游元数据  
   重点看：
   - `renderer.framePixelSize`
   - `session.resolutionText`
   - 首帧 `CMVideoFormatDescriptionGetDimensions`

4. 如果诊断图也异常，优先查窗口 sizing  
   重点看：
   - `contentRect`
   - `contentLayoutRect`
   - `contentAspectRatio`
   - 预览层所在视图实际 bounds

## UI 测试授权排查

预览诊断链路依赖 macOS 的自动化与截图能力。

如果在运行 [CapturePreviewDiagnosticsTests.swift](/Users/syc/Project/VoidDisplay/VoidDisplayUITests/Diagnostics/CapturePreviewDiagnosticsTests.swift) 或 `scripts/test/capture_preview_self_check.sh` 时，系统弹出与以下能力相关的授权窗口：

- 屏幕录制
- 辅助功能
- 自动化控制

必须先完成授权，再判断是不是代码问题。

### 常见现象

如果授权弹窗出现但没有及时允许，常见现象包括：

- `XCUIElement.screenshot()` 失败
- 诊断矩阵只在截图步骤失败
- 日志里出现 “Failed to create screenshot” 一类错误
- UI 元素存在性检查正常，但 attachment 生成失败

### 排查顺序

遇到这类失败时，先按下面顺序检查：

1. 是否有未处理的系统授权弹窗
2. `Xcode`、测试 Runner、目标应用是否已经被授予需要的权限
3. 重新运行同一条测试，确认失败是否可复现
4. 权限与弹窗都确认无误后，再继续怀疑代码实现

### 结论

这类失败经常来自权限与弹窗环境，不应直接判定为代码回归。

## 额外排查信号

除了左右黑边和裁切问题，这条链路还积累过两类很容易混淆的现象。它们适合保留为排查信号，不适合把旧实现里的修法直接当成当前结论。

### 1. `适应` 正常，但 `1:1` 明显偏小

这类回归的识别信号通常是：

- `适应` 铺满逻辑正常
- 切到 `1:1` 后内容缩成居中的小画面
- 工具栏、滚动宿主、窗口外观都正常
- 预期应当能看到滚动条，实际没有出现

出现这种组合时，优先怀疑尺寸语义链路，不要先去改 `ScrollView`、`videoGravity` 或窗口约束。

建议按这个顺序查：

1. `session.resolutionText` 是否表达原生像素尺寸
2. `renderer.framePixelSize` 是否更接近逻辑尺寸
3. 首帧 `CMVideoFormatDescriptionGetDimensions` 是否和前两者一致
4. `SCStreamConfiguration.width/height` 是否已经在上游偏小
5. 虚拟 HiDPI 场景下，`CGDisplayMode`、`CGDisplayPixelsWide`、`CGDisplayPixelsHigh` 是否互相矛盾

这类问题的核心不是视图层观感，关键在于“当前拿来喂给 `1:1` 的尺寸语义到底是什么”。

### 2. `1:1` 尺寸看起来对，但画面仍然发糊

这类问题要区分两件事：

1. 预览窗口按多大尺寸显示一帧
2. `SCStream` 实际交付的这一帧有多少有效像素

如果第 1 项正确、第 2 项偏低，最终效果仍然会糊。

建议按这个顺序查：

1. `SCStreamConfiguration.width/height`
2. `SCContentFilter.pointPixelScale`
3. 首帧 `CMVideoFormatDescriptionGetDimensions`
4. 首帧 `SCStreamFrameInfo.scaleFactor`
5. 首帧 `SCStreamFrameInfo.contentScale`
6. 预览窗口的 `resolutionText`
7. 预览窗口的 `renderer.framePixelSize`

如果看到下面这种组合：

- `SCStreamConfiguration.width/height` 很大
- `resolutionText` 也很大
- 首帧 `dimensions` 仍然偏小

优先查采集链路本身。

如果看到下面这种组合：

- 首帧 `dimensions` 已经接近原生像素尺寸
- 预览尺寸也匹配
- 视觉上仍然发糊

优先查被监听的源内容是否本身就没有以 HiDPI 方式渲染。

## 这轮新增经验

这轮又补了三个和预览窗口观感直接相关的问题：

- `适应` 和 `1:1` 时 toolbar 颜色不一致
- 进入全屏后 toolbar 仍然显示，顶部是一整条白色区域
- 拖动窗口边缘改变尺寸时，`适应` 模式重新出现左右白边

### 1. toolbar 颜色不一致的真正影响项

现象是：

- `适应` 模式下 toolbar 更偏灰
- `1:1` 模式下 toolbar 更接近灰白

这次确认后，影响项主要有两个：

- `适应` 和 `1:1` 的宿主结构不同
- `1:1` 的底层 `NSScrollView` 自带背景参与了系统 toolbar 的材质取样

曾经试过的几个方向都不理想：

- 直接给 `.windowToolbar` 强制固定 `.regularMaterial`
- 让 `适应` 也套一层伪 `ScrollView` 宿主
- 直接把内容顶到 toolbar 后面

这些方案会带来新的副作用，例如：

- toolbar 变成偏灰的固定材质，看起来和常见 macOS 应用不一致
- 全屏时黑屏或白边
- 内容跑到标题栏后方

这次最终保留的做法：

- `适应` 模式恢复成普通预览层
- `1:1` 模式继续使用真实 `ScrollView`
- 给 `1:1` 的底层滚动宿主做透明化处理

相关代码位置：

- [CaptureDisplayView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift#L45)
- [CaptureDisplayView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift#L55)
- [CaptureDisplayView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift#L272)

透明化处理的核心是：

- `NSScrollView.drawsBackground = false`
- `NSClipView.drawsBackground = false`
- 去掉滚动视图边框

这样系统 toolbar 仍然使用自己的灰白材质，`1:1` 又不会多出一层背景去污染取样。

### 2. 全屏时 toolbar 不隐藏的处理方式

预览窗口进入全屏后，如果 toolbar 继续常驻，效果会非常差：

- 顶部会出现一整条白色区域
- 预览内容观感被破坏
- 和系统常见的媒体、预览类窗口表现不一致

这次采用的是系统级做法，在窗口 delegate 里返回全屏展示选项：

```text
proposedOptions.union(.autoHideToolbar)
```

对应代码位置：

- [CaptureDisplayView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift#L241)

这样进入全屏后，toolbar 会自动隐藏。  
这个方案优先级高于在 SwiftUI 视图层硬做显隐控制，因为它直接走 `NSWindow` 的系统行为。

### 3. `适应` 模式拖拽 resize 后白边回来的根因

这次确认了一个之前没有补上的问题：

- 初始窗口创建时已经按真实内容区宽高比设置了尺寸
- 用户后续手动拖动窗口边缘时，这个比例约束没有继续生效
- 窗口一旦被拖成偏宽或偏高，`AVSampleBufferDisplayLayer` 在 `resizeAspect` 下就会重新留白边

所以“初始尺寸算对”还不够，拖拽过程也要继续维持内容区比例。

最终做法：

- 在窗口 delegate 里实现 `windowWillResize`
- 只在 `适应` 模式下启用
- 使用当前窗口真实的 `contentRect` 与 `contentLayoutRect` 差值，推导可用预览承载区
- 按采集源宽高比修正用户即将拖出的目标尺寸

对应代码位置：

- [CaptureDisplayView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Features/Capture/Views/CaptureDisplayView.swift#L258)

这样有几个好处：

- `适应` 模式下拖拽窗口不会再重新出现左右白边
- `1:1` 模式仍然保留自由窗口尺寸，不会被强行锁比例
- 逻辑和初始 sizing 使用同一套内容区修正思路，行为更一致

### 4. 这轮明确排除掉的错误方向

这轮调试里已经证明以下方向不适合作为最终方案：

- 给 toolbar 强制固定 `.regularMaterial`
- 让 `适应` 模式借一个禁用滚动的伪 `ScrollView` 来模拟 `1:1`
- 用 `ignoresSafeArea(.container, edges: .top)` 把内容直接推进标题栏

这些尝试虽然能短暂改变 toolbar 颜色，但会带来更坏的问题：

- 全屏黑屏
- 顶部白边
- 内容跑进标题栏
- resize 行为变差

后续如果再遇到 toolbar 材质和内容区相互影响的问题，优先顺序应该是：

1. 先检查不同模式下的宿主结构是否一致
2. 再检查 `NSScrollView` / `NSClipView` 是否自带背景
3. 最后才考虑是否需要改 toolbar 材质

不要先用强制材质去压问题。

5. 不要先改 `videoGravity`

6. 不要先改成 fill 或手工裁切

## 当前结论

这次问题的本质不是渲染层不会铺满，也不是缺少几组分辨率预设。  
问题在于窗口真实可用内容区的宽高比计算错了。

这次修复后：

- 左右黑边问题已通过自验证矩阵消除
- 没有引入上下裁切
- 没有引入非等比拉伸
- 方法对非标比例也成立

## 维护建议

后续如果再调整以下内容，要优先回归这套自验证链路：

- 预览窗口 toolbar 样式
- 预览窗口 titlebar 布局
- `CaptureDisplayView` 初始尺寸逻辑
- 预览层宿主视图层级
- 采集会话首帧尺寸来源

建议原则：

- 先确认真实内容承载区比例
- 再调整窗口尺寸
- 最后再看视觉效果

顺序不要反过来。
