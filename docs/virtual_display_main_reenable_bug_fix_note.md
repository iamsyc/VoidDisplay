# A主+B扩展，停A后再启A 镜像/不可操作 BUG 说明

## 背景场景

复现路径（典型）：

1. `A` 是主虚拟显示器，`B` 是扩展虚拟显示器
2. 停用 `A`
3. 系统将 `B` 提升为主显示器
4. 再启用 `A`

历史异常表现：

- `A` 画面变成 `B` 的镜像
- `A` 屏幕不可操作（只能看）
- UI/拓扑日志有时显示为扩展正常，但实际画面/输入状态异常

## 最终根因（不是单一原因）

这次问题是“时序 + 引用持有 + 拓扑恢复策略”叠加导致的，核心链路如下。

### 1. macOS 虚拟显示销毁回调不稳定（termination callback 经常缺失）

在某些机器/版本上，停用虚拟显示后：

- `offline` 状态能观察到
- 但 `CGVirtualDisplay` termination callback 不一定会到达

如果代码只依赖 callback 判定“已完全销毁”，就会误判时序。

### 2. 主屏重启用时，单屏快速重建会进入底层异常状态

当 `A` 是主屏、停用后又快速重启：

- 即使 `CGDisplay` 拓扑层看起来已经 `nomir + bounds分离`
- 底层虚拟显示 surface / 输入状态仍可能异常（视觉镜像、不可操作）

也就是说：这不是纯拓扑判定问题，而是虚拟显示实例 teardown/create 编队时序问题。

### 3. 旧 `CGVirtualDisplay` 被强引用持有，导致 teardown 无法真正完成

发现过两类强引用持有：

- `VirtualDisplayService.enableDisplay()` 内部局部变量持有新建显示对象
- `VirtualDisplayController.displays` 缓存持有旧显示对象

结果：

- service 自己以为已经清理运行态
- 但对象没释放，系统侧仍认为对应 serial 在线
- 后续重建/等待 offline 可能超时，或进入异常状态

### 4. fast 路径早期快照不完整，导致主屏连续性丢失

在非主屏启用时（`fast` 模式）：

- 新显示器刚创建后，首个拓扑快照可能还看不到它
- 如果此时直接判定“拓扑无问题并结束”，可能错过主屏连续性修复

后果是：

- 后续停/启 `A` 时会错误走 `fast` 而不是 `aggressive`
- 问题被放大或滚动出现

## 修复方案（已落地）

### A. 启用流程分级恢复（fast / aggressive）

- 只有“被停用的是主屏”时，后续启用走 `aggressive`
- 普通非主屏启用走 `fast`，减少闪烁/耗时

## B. fast 模式补 deferred 校验与主屏连续性修复

- 如果初始快照不完整（应出现的托管屏还没出现），不提前结束
- 强制跑 deferred 复核
- 即使没有镜像/重叠，只要主屏从 `preferredMain` 漂移，也执行轻量连续性修复

### C. aggressive 模式在 callback 缺失时升级为“编队重建”

当满足以下条件：

- 主屏重启用（`aggressive`）
- 未观察到 termination callback
- 仍有多个托管虚拟屏参与

处理策略：

- 不再只重建目标屏 `A`
- 直接对托管显示器编队（如 `A+B`）统一 teardown/recreate

这样可以绕过“单屏重建后拓扑正常但画面状态异常”的底层状态残留。

### D. 修复强引用持有问题（关键）

- 释放 `VirtualDisplayService.enableDisplay()` 内的局部强引用
- 释放 `VirtualDisplayController.displays` 对旧 `CGVirtualDisplay` 的缓存引用

这是避免 teardown/offline 卡住的关键修复之一。

### E. callback 缺失场景下使用 `fleetOfflineOnly` 策略

在编队重建里：

- 跳过逐屏 teardown settlement（避免每屏长等待）
- 改为依赖整队 offline 确认

在 callback 不稳定机器上更稳、更快。

### F. 避免稳定拓扑下的无意义强制归一化

在 `aggressive` 拓扑恢复里，如果：

- `issue == none`
- 主屏连续性也无需修复

则跳过 `forceNormalization` 触发的额外 repair，减少闪烁和黑屏。

### G. 固定冷却改为“自适应等待 + 上限保护”

以前的问题：

- `0.35s / 0.15s / 0.6s` 写死对不同机器不合理

现在的策略：

- 按拓扑状态轮询（目标托管屏是否已稳定离线）
- 满足条件立刻继续
- 固定值只作为最大等待上限（cap）

同时，拓扑稳定检测也改为自适应探测间隔：

- 初期快速探测（更快捕获稳定）
- 稳定后回退到常规间隔（降低抖动）

## 日志判定（当前符合预期的关键特征）

你最近日志中的以下特征均符合预期：

- `Disable-by-config ... disablingMain: true`
  - 说明主屏停用识别正确
- `Enable display requested ... recoveryMode: aggressive`
  - 说明主屏重启用走对了恢复级别
- `Enable did not observe termination callback ...`
  - callback 缺失仍然存在（机器/系统特性），已被代码兜底
- `Aggressive enable preemptively using coordinated fleet rebuild before creating target`
  - 说明已进入预判编队重建（避免无意义单屏创建）
- `Fleet rebuild skipping per-display teardown settlement ...`
  - 说明已启用快策略（`fleetOfflineOnly`）
- `Fleet rebuild creation cooldown ... waitedMs: XX, earlyExit: true`
  - 说明冷却是自适应提前退出，不再硬等满值
- `Topology force normalization skipped because topology is already stable ...`
  - 说明已避免稳定拓扑下的额外 repair
- `topologyRecovery:initialStable` / `deferredStable` 最终为 `nomir` 且 bounds 分离
  - 说明结果正确

## 日志中可接受但不作为故障判据的噪音

以下日志在当前机型/系统环境下可出现，不应单独作为故障判定：

- `invalid display identifier ...`
- `Invalid new timing data reported for display ...`
- `CALocalDisplayUpdateBlock returned NO`
- `Unable to obtain a task name port right for pid ...`
- `com.apple.Display.VirtualDisplayMetrics event not enabled ...`

只有当它们与以下错误同时出现时才需要重点排查：

- `Enable display failed`
- `Rebuild aborted because previous display with same serial is still online`
- `Topology repair failed`
- `Topology recovery failed to obtain initial stable snapshot`

## 快速回归排查指南（下次再出问题时）

### 1. 先看是否走对恢复模式

- 主屏场景必须看到：`recoveryMode: aggressive`
- 如果主屏场景走了 `fast`，优先排查“主屏识别/连续性修复”是否回归

### 2. 看 callback 缺失时是否升级编队重建

应看到：

- `Enable did not observe termination callback ...`
- `Aggressive enable preemptively using coordinated fleet rebuild before creating target`

如果没升级，优先排查 aggressive 分支条件是否被改坏。

### 3. 看编队重建是否仍在错误地逐屏等待

应看到：

- `Fleet rebuild skipping per-display teardown settlement ...`

如果出现逐屏 settlement 超长等待，检查 `teardownStrategy` 是否退回了 `perDisplaySettlement`。

### 4. 看是否再次出现旧强引用持有问题

典型故障日志：

- `Rebuild aborted because previous display with same serial is still online ...`

若再出现，优先排查：

- service 内局部强引用是否被重新引入
- controller 层缓存是否重新持有旧 `CGVirtualDisplay`

### 5. 看拓扑恢复是否做了无意义 repair

稳定拓扑时应看到：

- `Topology force normalization skipped because topology is already stable and no continuity repair is needed.`

如果稳定拓扑仍频繁 `Topology repair requested`，说明归一化/连续性判断逻辑可能回归。

## 相关实现位置（关键文件）

- `/Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/VirtualDisplayService.swift`
- `/Users/syc/Project/VoidDisplay/VoidDisplay/App/VirtualDisplayController.swift`
- `/Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Logic/TopologyHealthEvaluator.swift`
- `/Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/DisplayTeardownCoordinator.swift`
- `/Users/syc/Project/VoidDisplay/VoidDisplay/Features/VirtualDisplay/Services/DisplayReconfigurationMonitor.swift`

## 推荐回归测试入口（自动化）

- `/Users/syc/Project/VoidDisplay/scripts/test/virtual_display_regression_gate.sh`
- `/Users/syc/Project/VoidDisplay/VoidDisplayTests/Features/VirtualDisplay/VirtualDisplayTopologyRecoveryTests.swift`
- `/Users/syc/Project/VoidDisplay/VoidDisplayTests/Features/VirtualDisplay/VirtualDisplayServiceOfflineWaitTests.swift`

