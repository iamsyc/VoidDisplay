# DMG 背景图调优：技巧与踩坑总结

本文总结了本次 `VoidDisplay` 拖拽安装页（DMG）背景与 Finder 布局调优过程中的可复用经验。

涉及脚本：
- `scripts/release/render_dmg_background.swift`
- `scripts/release/apply_dmg_layout.applescript`
- `scripts/release/create_dmg.sh`

## 实用技巧

### 1) 统一使用 Finder 坐标语义
- Finder 图标位置是以内容区域左上角为参考点，`set position of item ... to {x, y}` 使用的是 Finder 坐标。
- 背景图是 AppKit 坐标（原点在左下），绘制时需要做坐标转换。
- 推荐同时保留：
- `rectFromFinder(x:y:width:height)`：画框时转换矩形。
- `pointFromFinder(x:y:)`：画箭头中心点时转换点。
- 好处是：虚线框中心点和 Finder 实际图标点可直接对齐，减少“看起来居中，实际偏移”的问题。

### 2) 背景简化优先，强调信息层级
- DMG 背景的核心任务是引导拖拽，不是视觉堆叠。
- 实践上保留三类元素足够：
- 轻微灰阶渐变背景（低对比）。
- 两个放置槽虚线框（承载对位）。
- 中间细箭头（方向引导）。
- 结果是兼容不同 Finder 外观，同时减少视觉噪音。

### 3) 虚线框要比图标占位稍大
- Finder 在某些状态下会给 `Applications` 显示占位轮廓。
- 如果背景虚线框尺寸和 Finder 占位接近，会出现重叠干扰。
- 经验值：背景槽位框适当放大（例如 `132 -> 150`）并降低填充透明度，可显著缓解重叠感。

### 4) 先确认“脚本生成图”，再看“真实 DMG”
- 建议先单独执行背景渲染脚本：
- `swift scripts/release/render_dmg_background.swift .ai-tmp/.../background.png`
- 再走完整打包链路并挂载验证，避免把“绘图问题”和“Finder 布局问题”混在一起排查。

## 关键踩坑

### 坑 1：同名卷导致布局脚本打到错误磁盘
- 现象：
- 已经挂载了 `VoidDisplay` 时，新挂载卷会变成 `VoidDisplay 1`。
- 布局脚本如果仍用固定卷名 `VoidDisplay`，会作用到旧卷，导致新 DMG 出现：
- 图标位置未生效。
- `arranged by name` 被重置。
- `Applications` 显示异常（看起来像没加载图标）。
- 根因：
- `create_dmg.sh` 传给 AppleScript 的是输入 `volume_name`，不是实际挂载卷名。
- 修复：
- 挂载后用 `mount_path` 推导 `mounted_volume_name`，把它传给 `apply_dmg_layout.applescript`。

### 坑 2：底部白条
- 现象：
- Finder 窗口底部出现一条无背景覆盖的亮色区域。
- 根因：
- 背景图尺寸与窗口内容显示区域高度不匹配。
- 修复思路：
- 同时调整两端：
- 背景图高度（如 `420 -> 460`）。
- AppleScript 中窗口 bounds 高度（使内容区域更贴合背景图）。

### 坑 3：读取图标坐标返回 `-1, -1`
- 现象：
- `osascript` 读取 `position of item ...` 偶尔得到 `-1, -1`。
- 常见原因：
- Finder 视图未稳定。
- 当前窗口排列模式不是 `not arranged`。
- 排查要点：
- 先检查 `current view` 和 `arrangement`。
- 必要时 `open` 后 `delay` 再读坐标。

## 本次验证过的检查项

- `Applications` 在 DMG 内是有效别名：
- `kind` 为 `替身`，`class` 为 `alias file`。
- 布局模式是 `not arranged`。
- 图标坐标与目标点一致：
- `VoidDisplay.app = (170, 160)`
- `Applications = (490, 160)`
- 背景文件存在：
- `/Volumes/<卷名>/.background/background.png`

## 推荐的发布前检查清单

- 执行 `xcodebuild`（Release）并确认 `0 warning / 0 error`。
- 重新打包 DMG 并挂载，确认：
- 视图模式为 `icon view`。
- 排列模式为 `not arranged`。
- 两个图标坐标正确。
- `Applications` 为 alias file。
- 在“已存在同名卷”的情况下再跑一次，验证卷名冲突场景仍正确。
