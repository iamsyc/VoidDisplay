# DisplayRuntime Startup Restore Transaction Plan

状态：待实现执行计划
范围：只规划 startup restore 进入 DisplayRuntime transaction。本文档不实现代码。

## 范围边界

本计划只处理 startup restore transaction。后续实现窗口只能把启动期 desired virtual display restore 收敛到 `DisplayRuntime` transaction control plane。

本计划明确不处理：

- README 更新或 public screenshots 更新。
- LAN route、shareID、auth/security。
- remote control、input injection、clipboard。
- Capture/WebRTC/WebSocket/HTTP/frame pipeline。
- LAN Web View 数据平面、Monitor 数据平面或 capture frame 数据平面。
- Phase 7 叙事。

任何实现批次只要需要触碰上述范围，就必须停止并重新开计划。不得把这些能力作为 startup restore transaction 的附带改动。

## 目标

Startup restore 必须进入 `DisplayRuntime` transaction control plane。应用启动时不再直接通过 `VirtualDisplayController` 或 lower virtual display facade 执行 restore desired displays。

本计划要求后续实现达到以下结果：

- Startup restore 复用现有 virtual display transaction queue。
- Startup restore 复用 transaction trace、pre/post snapshot、topology wait、quiesce / restore 语义。
- Startup restore 对 persisted desired virtual display configs 生成明确 restore intent。
- Startup restore 的结果进入 startup 专属 presentation，不能伪装成普通 rebuild/edit failure。
- Startup restore 只有 `DisplayRuntime` transaction path。
- 旧 direct restore desired virtual displays path 删除。
- `DisplayRuntime` 只通过 DTO / command ports 协调 startup restore。
- App adapter 负责桥接 lower virtual display capabilities。
- `VoidDisplayVirtualDisplay` lower layer 不 import `VoidDisplayRuntime`。
- `VoidDisplayRuntime` 不 import UI/App/Capture/Sharing/VirtualDisplay/ScreenCaptureKit。
- 用户可见功能不变。已设置为 desired-enabled 的虚拟显示仍在启动后恢复。
- 不改变 LAN Web View、Monitor、capture frame pipeline、WebRTC/WebSocket/HTTP、LAN route、shareID、认证、安全边界。
- 不引入旧 direct startup restore fallback。

## 当前问题

当前 direct startup restore 调用点：

- `Sources/VoidDisplayApp/Bootstrap/VoidDisplayApp.swift`
  - `makeEnvironment(...)` 创建 `AppEnvironment` 后，在非 preview 且 `resolvedStartupPlan.shouldRestoreVirtualDisplays` 为真时调用 `virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()`。
  - 随后调用 `resolvedStartupPlan.postRestoreConfiguration?(virtualDisplay)`，仍以 `VirtualDisplayController` 为 startup restore presentation 入口。
- `Sources/VoidDisplayVirtualDisplay/ViewModels/VirtualDisplayController.swift`
  - `loadPersistedConfigsAndRestoreDesiredVirtualDisplays()` 直接调用 `virtualDisplayFacade.loadPersistedConfigs()`。
  - 同一方法继续直接调用 `virtualDisplayFacade.restoreDesiredVirtualDisplays()`。
  - 之后只通过 `syncVirtualDisplayState()` 和 observability event/error presentation 反映结果。
- Lower facade/orchestrator 仍暴露 startup restore direct presentation path，App bootstrap 可以绕过 runtime 直接触发 desired virtual display restore。

这个路径是 Phase 3b 后残留的 parallel path。create/delete/edit/rebuild/enable/disable 已经通过 `DisplayRuntime` transaction 执行，统一经过 queue、trace、topology proof、session quiesce 与 restore evidence。startup restore 仍直接驱动 lower facade，导致启动恢复绕过以下 runtime 统一层：

- transaction serialization 和 active task 约束。
- transaction source 和 operation trace。
- pre/post snapshot evidence。
- topology stable / timedOut / unprovableDueToPermission 结果。
- sharing / monitoring quiesce 与 restore 结果归因。
- runtime observability snapshot refresh。

结果是同一类 virtual display runtime side effect 在启动期和运行期有两套控制路径。运行期 transaction 能解释操作、失败和恢复影响；启动期 direct path 只能解释 lower restore failure，无法提供同等级的 runtime evidence。

## 设计方向

### Runtime command

在 `VoidDisplayRuntime` 增加 startup restore transaction 入口，推荐形状：

```text
restoreStartupVirtualDisplays(
    source: DisplayRuntimeTransactionSource
) async -> DisplayRuntimeStartupRestoreResult
```

新增 transaction kind/source/result DTO，命名由实现阶段按现有模型风格确定。最低要求：

- `DisplayRuntimeTransactionKind` 增加 startup restore 专用 kind。
- `DisplayRuntimeTransactionSource` 增加 app startup 专用 source，trace 中记录为 `source=startup`。
- Result 必须区分 overall status、per-config result、persistence read result、topology result、trace id。
- Result 必须能表达 no desired-enabled configs，这是 terminal success no-op。
- Result 必须能表达 duplicate request 是 coalesced、alreadyCompleted 或 serialized 后执行。

### Persistence and restore intents

Startup restore 由 runtime 通过 command port 读取 persisted desired virtual display configs。Runtime 不直接读取 App 或 VirtualDisplay persistence 类型。

新增或扩展 `DisplayRuntimeVirtualDisplayCommanding` 的 command-shaped API：

```text
loadPersistedVirtualDisplayConfigsForStartupRestore()
    async -> DisplayRuntimeStartupRestoreConfigLoadResult

restoreVirtualDisplayForStartup(
    request: DisplayRuntimeStartupRestoreCommandRequest
) async -> DisplayRuntimeStartupRestoreCommandResult
```

DTO 必须只包含 runtime 可拥有的数据：

- config id。
- redacted config evidence。
- desired-enabled flag。
- lower restore outcome。
- lower failure reason。
- post-command runtime display evidence。

读取成功后，runtime 对每个 desired-enabled config 生成 restore intent。desired-disabled config 只进入 read evidence，不生成 restore intent。

### Transaction granularity

Startup restore 采用 per-config serial transaction，不采用单个 batch transaction。单次 startup restore command 是一个 startup run，内部按 persisted order 或稳定排序生成 per-config restore transaction，并全部进入现有 virtual display transaction queue。

选择 per-config serial transaction 的原因：

- 单个 config 失败不阻断其他 desired-enabled config 的恢复。
- trace 能精确归因到 config id。
- 现有 create/delete/edit/rebuild/enable/disable 的 queue 和 topology wait 模型可以直接复用。
- duplicate request coalescing 可以发生在 startup run 层，避免同一进程启动期重复恢复。

实现阶段不得把多个 lower restore side effect 包进一个无边界 batch command 后只记录一个粗粒度结果。允许在最终 presentation 中汇总 per-config transaction results。

Per-config transaction 必须记录：

- transaction id。
- `source=startup`。
- affected config id。
- restore intent。
- pre snapshot。
- lower restore result。
- topology result。
- session restore result。
- post snapshot。
- failure evidence。
- compensation evidence。没有补偿动作时记录 `notAttempted` 或等价枚举，不能省略字段导致无法判断。

### Trace and observability

Startup restore 必须进入 existing runtime transaction trace / observability recorder，并至少记录：

- transaction id。
- startup source。
- startup run id。
- affected config ids。
- persisted config read result。
- restore intents。
- pre snapshot。
- lower restore command result。
- post snapshot。
- topology wait result。
- sharing / monitoring restore result。
- per-config failure reason。
- compensation evidence。
- aggregate startup restore result。

Trace 中不得写入 display name 等不必要的用户内容。默认不推进 runtime snapshot schema。若现有 trace schema 无法表达 startup run 和 per-config restore evidence，计划实施时必须先证明需要 schema bump，再修改 snapshot schema。没有证明时不得扩大 snapshot schema。

Trace 和 observability 不得新增敏感信息导出。禁止导出：

- displayName。
- 本地路径。
- LAN URL/IP。
- raw shareID。
- 窗口标题。
- 用户文本。
- 桌面内容。

Observability 需要能回答三个问题：

- 启动时尝试恢复了哪些 config。
- 每个 config 是否完成 lower restore、topology proof、session restore。
- 失败发生在 persistence read、lower driver restore、topology proof、session restore 或 presentation 汇总哪个阶段。

### Duplicate request semantics

Runtime 必须定义 duplicate startup restore 请求语义：

- 同一进程内 startup run 正在执行时，后续请求 coalesce 到 active run，不触发第二次 lower restore。
- 同一进程内 startup run 已 terminal 后，后续 app startup source 请求返回 already-completed no-op，并引用上一 run 的 result/trace id。
- 不允许 App adapter 或 `VirtualDisplayController` 以 fallback 方式再调用 old direct restore。

### UI / presentation

本阶段不改 UI IA，不改用户可见文案。实现只能调整 presentation 数据来源和失败归因。

Startup restore presentation 必须读取 runtime startup restore result、runtime transaction trace 或由 App adapter 从 runtime result 派生的 presentation state。失败展示必须满足：

- Startup restore failure 保持 startup restore 语义。
- Persistence read failure 不伪装成 rebuild/edit failure。
- Lower restore failure 不伪装成 rebuild/edit failure。
- Topology timedOut 或 unprovableDueToPermission 不伪装成 driver restore failure。
- Duplicate request no-op 不产生用户可见失败。
- No desired-enabled configs 不产生用户可见失败。

禁止保留旧 direct fallback。`VirtualDisplayController` 可以保留 presentation adapter 角色，但不能再作为 production startup restore executor。

### Failure semantics

Persistence read failure：

- Startup restore terminal status 为 failed。
- 不生成 per-config restore intent。
- 不调用 lower restore。
- Trace 记录 transaction id、`source=startup`、persistence read failure、failure evidence、可用的 pre/post snapshot。
- Compensation evidence 记录为 `notAttempted`。
- UI startup presentation 显示 startup restore 失败，不复用 rebuild/edit failure。

No desired-enabled configs：

- Startup restore terminal status 为 succeeded no-op。
- 不调用 lower restore。
- Trace 记录 transaction id、`source=startup`、config read success、affected configs 为空、intent count 为 0、pre/post snapshot、restore result 为空、failure 为空。

Missing config：

- 如果 persisted list 中的 config 在 per-config transaction 执行前已经不可用，该 config result 为 failed 或 skipped terminal，reason 为 `config_not_found`。
- 该结果不能映射为 success。
- Trace 记录 transaction id、`source=startup`、affected config id、missing config failure evidence、restore result 为 skipped 或 failed。
- Compensation evidence 记录为 `notAttempted`。
- 其他 per-config transactions 继续按 queue 串行执行。

Lower driver restore failure：

- 对应 config result 为 failed。
- Topology wait 只在 lower command 已产生可验证 side effect 时执行。
- Trace 记录 transaction id、`source=startup`、affected config id、lower failure reason、restore result、post snapshot、是否跳过 topology proof。
- 如果 lower layer 做过恢复或 rollback，App adapter 必须把 compensation outcome 映射到 runtime DTO；没有补偿动作时记录 `notAttempted`。
- UI startup presentation 使用 startup restore result，不显示普通 rebuild/edit 文案。

Topology stable：

- 对应 config result 可以成功，前提是 lower restore 成功且 topology proof 达到 stable。
- Trace 记录 topology result 为 `stable`、stable sample evidence、post snapshot 和 restore result。

Topology timedOut：

- 对应 config result 为 degraded 或 failed，由现有 transaction status 规则统一判定。
- Trace 记录 topology result 为 `timedOut`、timeout sample evidence、post snapshot 和 restore result。

Topology unprovableDueToPermission：

- 不归类为 lower restore failure。
- Trace 记录 topology result 为 `unprovableDueToPermission`、permission evidence、post snapshot 和 restore result。
- Presentation 明确这是 startup restore topology proof 不可证，不把它归入 ordinary rebuild/edit failure。

Session restore failure：

- sharing / monitoring restore 失败按现有 restore result 语义记录。
- 不改变 LAN Web View、Monitor、capture frame pipeline、WebRTC/WebSocket/HTTP 或 LAN route/shareID/认证/安全边界。

## 分层边界

`VoidDisplayRuntime`：

- 只依赖 runtime DTO、command ports、snapshot provider、observability recorder。
- 不 import App/UI/Capture/Sharing/VirtualDisplay/ScreenCaptureKit。
- 不读取 lower persistence concrete type。
- 不创建 UI presentation state。

`VoidDisplayVirtualDisplay` lower layer：

- 不 import `VoidDisplayRuntime`。
- 可以新增 command-shaped lower API，暴露 load persisted configs 和 restore config 的结构化结果。
- 保留 lower domain error，但由 App adapter 映射为 runtime DTO。
- 删除或收敛 old direct startup restore presentation path。

`VoidDisplayApp` adapter：

- 负责把 runtime startup restore command 映射到 existing lower virtual display capabilities。
- 负责把 lower startup restore result 映射为 runtime DTO。
- 负责 bootstrap wiring，让 app startup 调用 `DisplayRuntime` startup restore API。
- 负责 startup presentation adapter，展示 startup restore aggregate result。

禁止保留：

- `VoidDisplayApp.swift` 直接调用 `VirtualDisplayController.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()`。
- `VirtualDisplayController` 直接作为 production startup restore executor。
- Runtime path 失败后 fallback 到 old direct restore。

## 迁移范围

允许修改：

- `Sources/VoidDisplayRuntime/**`
- `Sources/VoidDisplayApp/Bootstrap/VoidDisplayApp.swift`
- `Sources/VoidDisplayApp/Composition/DisplayRuntimeVirtualDisplayAdapter*`
- `Sources/VoidDisplayVirtualDisplay/ViewModels/VirtualDisplayController.swift`，仅用于删除旧 direct startup restore presentation path 或改成 runtime-backed presentation adapter
- `Sources/VoidDisplayVirtualDisplay/Services/*`，仅在需要 command-shaped lower API 时可改
- `Tests/VoidDisplayRuntimeTests/**`
- `Tests/VoidDisplayAppTests/**`
- `Tests/VoidDisplayVirtualDisplayTests/**`

禁止修改：

- Capture/WebRTC/WebSocket/HTTP/frame pipeline。
- LAN route/shareID/认证/安全边界。
- UI IA / Displays / Diagnostics 文案。
- README / docs public screenshots。
- `DisplayRuntime` snapshot schema，除非计划实施时明确证明 startup trace 需要 schema bump。

任何超出允许范围的改动都必须停止并重新评估。不得用兼容层、双写、隐藏 fallback 或一次性 shim 保留旧 direct startup restore path。

## 实施批次

Batch 1：Runtime transaction model / ports / tests

- 审计当前 startup restore direct path，确认 bootstrap、controller、lower facade/orchestrator 的生产调用链。
- 新增 startup restore transaction kind/source/result DTO。
- 新增或扩展 virtual display command port，支持 startup config load 和 per-config restore command。
- 实现 startup run coalescing/already-completed 语义。
- 实现 per-config serial transaction，接入现有 queue、trace、snapshot、topology wait、session restore。
- 添加 `VoidDisplayRuntimeTests` 覆盖 success、read failure、empty intents、missing config、lower restore failure、topology variants、duplicate request。

Batch 2：App adapter + bootstrap wiring + remove old direct path

- 在 `DisplayRuntimeVirtualDisplayAdapter*` 中映射 lower load/restore command 到 runtime DTO。
- 将 `VoidDisplayApp.swift` startup restore 调用改为 `DisplayRuntime` startup restore API。
- 保留 `StartupPlan.shouldRestoreVirtualDisplays` 作为是否触发 runtime startup restore 的开关。
- 将 `postRestoreConfiguration` 改为接收 runtime-backed presentation result，或删除旧 controller restore hook。
- 删除 production 对 `loadPersistedConfigsAndRestoreDesiredVirtualDisplays()` 的调用。
- 删除该方法，或改为只消费 runtime-backed startup restore result 的 presentation adapter。
- 删除 lower facade 的 direct restore desired displays production 入口，或降级为仅被 command-shaped adapter 使用的内部能力。
- Grep 确认 old direct startup restore path 无 production 命中。

Batch 3：observability / verification / final audit

- 验证 startup restore trace 能定位 persistence read、lower restore、topology、session restore failure。
- 验证 startup presentation 不复用 rebuild/edit failure。
- 验证 no desired-enabled configs 不产生错误事件。
- 验证 unprovableDueToPermission topology proof 不被误报为 driver restore failure。
- 执行 targeted tests、boundary grep、Xcode Debug build、warning/error scan。
- 确认没有用户可见行为回归，确认工作区 clean 并提交实现。

## 测试计划

必须新增或更新 targeted tests：

- Startup restore success：persisted desired-enabled config 被恢复，trace 记录 pre/post snapshot、restore intent、topology result、restore result。
- Persistence read failure：不生成 restore intent，不调用 lower restore，startup presentation 记录 read failure。
- No desired-enabled configs：返回 success no-op，不调用 lower restore，不产生失败 presentation。
- Missing config：per-config result 为 `config_not_found`，不能映射为 success。
- Lower restore failure：记录 lower failure，结果归入 startup restore failure，不复用 rebuild/edit failure。
- Topology stable：lower restore 后 stable proof 成功。
- Topology timedOut：记录 timeout evidence，status 按 transaction 规则降级或失败。
- Topology unprovableDueToPermission：记录 permission evidence，不归类为 lower restore failure。
- Duplicate startup restore：active run coalescing 或 terminal already-completed no-op，证明 lower restore 没有重复调用。
- Old direct startup restore path grep 无命中：production 代码不再调用 `loadPersistedConfigsAndRestoreDesiredVirtualDisplays()` 或 direct `restoreDesiredVirtualDisplays()` startup path。
- AppBootstrap 不再直接调用 `VirtualDisplayController` restore。
- No privacy prompt：自动化测试不引入 screen recording、microphone、camera、keyboard input、input method 等产品权限弹窗。

推荐测试落点：

- `Tests/VoidDisplayRuntimeTests/**` 覆盖 transaction model、queue、trace、topology、duplicate request。
- `Tests/VoidDisplayAppTests/DisplayRuntimeAdapterTests.swift` 覆盖 App adapter DTO mapping。
- `Tests/VoidDisplayAppTests/AppBootstrapTests.swift` 覆盖 bootstrap wiring。
- `Tests/VoidDisplayVirtualDisplayTests/VirtualDisplayControllerTests.swift` 覆盖旧 presentation path 删除或 runtime-backed presentation。
- `Tests/VoidDisplayVirtualDisplayTests/**` 覆盖 command-shaped lower API。

## 验证门禁

后续实现完成后必须运行：

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter AppBootstrapTests
scripts/ci/unit.sh --filter VirtualDisplayControllerTests
scripts/ci/unit.sh --filter VoidDisplayVirtualDisplayTests
scripts/ci/xcode.sh --action build --configuration Debug
git diff --check
```

如 `VoidDisplayVirtualDisplayTests` 范围过宽，可使用更窄相关 filters，但必须覆盖 command-shaped lower API、controller startup presentation、old direct path deletion。

必须执行 boundary grep：

```sh
rg -n "import VoidDisplay(App|Capture|Sharing|VirtualDisplay)|ScreenCaptureKit|VirtualDisplayController|VirtualDisplayFacade" Sources/VoidDisplayRuntime
rg -n "import VoidDisplayRuntime" Sources/VoidDisplayVirtualDisplay
rg -n "loadPersistedConfigsAndRestoreDesiredVirtualDisplays|restoreDesiredVirtualDisplays\\(" Sources Tests
```

期望结果：

- Runtime forbidden imports/types 无命中。
- `VoidDisplayVirtualDisplay` import `VoidDisplayRuntime` 无命中。
- 旧 direct startup restore production path 无命中。
- 允许 lower command implementation 内部调用 restore capability，但不得保留 App startup 直达 lower facade 的调用链。
- Xcode warning / error scan 为 0。

## 完成标准

后续实现完成时必须同时满足：

- Startup restore 只有 `DisplayRuntime` transaction path。
- 旧 direct startup restore path 已删除。
- Trace / observability 能说明 startup restore 做了什么、失败在哪里。
- Startup presentation 能区分 startup restore failure 与普通 rebuild/edit failure。
- 用户可见功能无回归。
- 未修改 Capture/WebRTC/WebSocket/HTTP/frame pipeline。
- 未修改 LAN route/shareID/认证/安全边界。
- 未修改 README 或 docs public screenshots。
- 自动化验证无产品权限弹窗。
- 本地 build/test warning 和 error 均为 0。
- 工作区 clean，相关文档和实现已提交。
