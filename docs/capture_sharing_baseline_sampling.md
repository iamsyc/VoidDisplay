# Capture Sharing Baseline Sampling

## 环境约束
- 固定一台代表机型，记录 CPU 型号、内存、macOS 版本、显示器规格。
- 使用 `Release` 构建与同一套网络环境。
- 每个场景预热 `10s` 后再采样 `60s`。
- 日志输出目录固定为 `.ai-tmp/perf-baseline/<timestamp>/`。

## 采样场景
- `previewOnly`，单预览窗口
- `shareOnly`，单分享目标与单 `streamingPeer`
- `mixed`，单预览窗口与两个 `streamingPeers`

## 记录项
- 进程 CPU 中位数
- `SCShareableContent` 加载次数
- `profileReconfigurationCount`
- `cursorOverrideReconfigurationCount`
- preview 渲染延迟 `p95`
- preview 丢帧率

## 验收门槛
- 权限状态与拓扑签名未变化、且没有 `userForcedRefresh` 时，`SCShareableContent` 加载次数不超过 `1` 次。
- 稳定状态下 `profileReconfigurationCount` 为 `0`；任意 `5s` 窗口内不超过 `1` 次。
- `streamingPeers` 在 `10s` 内从 `0 -> 3 -> 0` 波动时，`profileReconfigurationCount` 不超过 `1` 次。
- `previewOnly` 场景 preview 渲染延迟 `p95 <= 120ms`，`mixed` 场景 `p95 <= 180ms`。
- `previewOnly` 场景丢帧率不超过 `10%`，`mixed` 场景不超过 `20%`。
- `mixed` 场景进程 CPU 中位数不得高于基线 `5%`，目标下降 `10%`。
- `cursorOverrideReconfigurationCount` 单独记录，不计入 profile 频控门槛。
