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
