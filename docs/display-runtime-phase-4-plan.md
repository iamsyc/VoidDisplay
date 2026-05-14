# DisplayRuntime Phase 4: Consumer Lease And Demand Aggregation

状态：已完成历史记录
范围：规划 DisplaySurface consumer lease、demand aggregation、capture intent dispatch、observability、测试与迁移顺序。本文档不实现代码。
基线：Phase 3c final audit 已通过，runtime 已完成结构拆分，可以进入 Phase 4 planning。
归档说明：Phase 4 已完成。本文保留为使用方租约与需求聚合的历史计划，不再作为当前待办清单。
导航：当前阅读顺序见 [DisplayRuntime 文档索引](./display-runtime-index.md)。

## Summary

Phase 4 把 Monitor、LAN Web View、diagnostics recorder 统一建模为 `DisplaySurface` consumer lease，并由 `DisplayRuntime` 聚合这些 consumer 的 capture demand。

核心边界固定：

- `DisplayRuntime` 是控制平面，只保存 lease、aggregate demand、effective capture intent、状态和诊断证据。
- `DisplayRuntime` 不持有 `SCStream`、WebRTC session、`CMSampleBuffer`、`CVPixelBuffer` 或编码帧。
- `DisplayCaptureRegistry` / CaptureEngine 继续拥有 capture session、ScreenCaptureKit stream、preview fanout、draining 和帧路径。
- Sharing / StreamingEngine 继续拥有 LAN Web View route、viewer session、WebRTC、WebSocket、HTTP 和编码发送路径。
- LAN Web View 高清、高帧率、低延迟能力保持为主体验目标。

Phase 4 不修改 UI 信息架构。`Displays` / `Diagnostics` 的 UI 重组仍保留到 Phase 6。

## Current Architecture Constraints

现有 runtime 已经具备 `DisplaySurface` snapshot、catalog convergence、virtual display transaction trace、session quiesce / restore intent。Phase 3b / 3c 已经把 monitoring restore 留给 future consumer lease，当前 trace 使用 `monitoring_restore_deferred_until_consumer_lease` 作为显式缺口。

现有 capture 层已经有 engine-level token 与 demand 机制：

- `DisplayCaptureRegistry` 管 preview / share token、session creation、draining。
- `DisplayCaptureDemandSnapshot` 表达 preview sink、share token、cursor 和 `CapturePerformanceMode`。
- `DisplayCaptureConfigurationStateMachine` 已经保证 `automatic` / `smooth` 保持 source fps 和 source dimensions，`powerEfficient` 才使用降帧和像素预算。
- `RelaySessionHub` / `WebRTCStreamingProfile` 已经保证 LAN Web View 的 `automatic` / `smooth` 使用 source spec，`powerEfficient` 才降级编码输出。

Phase 4 的工作是把产品级 consumer lease 和 demand aggregation 移到 runtime control plane。Capture 层现有 token 可以保留为 CaptureEngine 内部资源句柄，但产品级 lease owner、优先级和聚合策略必须由 runtime 统一表达。

## Consumer Lease Model

新增 runtime-only lease model，建议类型：

```text
DisplayRuntimeConsumerLease
DisplayRuntimeConsumerLeaseID
DisplaySurfaceEpoch
DisplaySurfaceConsumerKind
DisplayRuntimeConsumerOwner
DisplayRuntimeConsumerDemand
DisplayRuntimeConsumerLeaseState
```

Lease 字段：

- `id`: stable UUID，attach 时生成。
- `surfaceIdentity`: `DisplaySurfaceIdentity`，不使用 `shareID`。
- `surfaceEpoch`: attach 时绑定的 surface epoch。
- `resolvedDisplayID`: attach 时 runtime 能证明的 current display id，可为空。
- `kind`: `monitor`、`lanWebView`、`diagnosticsRecorder`。
- `owner`: source / owner 摘要，例如 local UI、sharing service、diagnostics。
- `createdAt`、`updatedAt`: runtime 时间戳。
- `state`: `attaching`、`attached`、`restarting`、`draining`、`released`、`failed`。
- `demand`: consumer 的 declarative demand。
- `lastFailure`: 脱敏原因码。

Lifecycle：

1. `attachConsumer(surfaceIdentity, kind, owner, demand)` 只创建 runtime lease，绑定当前 `surfaceEpoch`，计算 aggregate demand。
2. Runtime 生成 `DisplayRuntimeCaptureIntent` 并通过 capture command port 下发。
3. App / Capture adapter 解析 `resolvedDisplayID` 到当前 `SCDisplay`，再调用 `DisplayCaptureRegistry` 或 CaptureEngine。
4. `detachConsumer(leaseID)` 移除该 demand，重新聚合。最后一个 lease 释放后，下发 draining intent。
5. surface epoch 变化时，旧 lease 进入 `restarting` 或 `failed`，不得继续驱动旧 display id 的 capture session。
6. transaction quiesce 期间的新 attach 必须等待、返回 restarting/degraded，或绑定新 epoch，不能复活旧 session。

Surface epoch 生成规则：

- Epoch 由 `DisplayRuntime` control plane 维护。
- 每个 `DisplaySurfaceIdentity` 有单调递增 epoch。
- resolved display id、managed virtual display live mapping、topology signature、surface availability 等会影响 capture target 的变化必须递增 epoch。
- 普通 snapshot rebuild 不递增 epoch。
- attach 绑定当前 epoch，capture intent apply 必须校验 epoch。
- stale epoch intent 只能 failed、restarting 或 ignored，不能继续驱动旧 display id。

## Demand Aggregation Policy

新增 runtime aggregate model：

```text
DisplayRuntimeAggregatedDemand
DisplayRuntimeCaptureIntent
DisplayRuntimeEffectiveCaptureIntent
```

Demand 维度：

- resolution: source / preferred pixel size / maximum pixel size。
- frame rate: preferred fps。
- cursor: include cursor when any active consumer requests it。
- quality profile: monitor-only、lan-view-only、diagnostics-only、mixed。
- power profile: automatic、smooth、powerEfficient。
- latency preference: realtime、balanced、recording。

聚合规则：

- Resolution 取满足最高质量 active consumer 的值。`automatic` 和 `smooth` 默认使用 source dimensions。
- Frame rate 取最高 active realtime demand。`automatic` 和 `smooth` 使用 source fps。
- Cursor 使用 OR 规则。任一 monitor 或 LAN Web View 需要 cursor，则 effective intent 开启 cursor。
- Quality profile 按 consumer 组合收敛到 previewOnly、shareOnly、mixed 或等价 runtime profile。
- Latency preference 中 realtime 优先于 diagnostics recording。
- Power profile 只有显式 `powerEfficient` 才允许降级。`automatic` 和 `smooth` 不能因为 preview pressure 或多 viewer 主动降画质。
- 多 viewer 只增加 viewer count 和 streaming fanout，不创建重复 capture session。
- Diagnostics recorder 优先级低于 LAN Web View，不能降低正在观看的 LAN quality。显式 high-fidelity diagnostics 可以要求 source quality。

优先级：

1. LAN Web View realtime viewing，最高保护级。
2. Monitor realtime local preview，和 LAN 同时存在时进入 mixed high quality。
3. Diagnostics recorder，默认复用既有 capture intent，不能拉低 LAN。
4. `powerEfficient` 是用户显式降级许可，降级必须进入 observable effective intent。

## Capture Intent Boundary

Runtime 下发的是 capture intent，不能进入数据路径。

Intent 可包含：

- `surfaceIdentity`
- `surfaceEpoch`
- `resolvedDisplayID`
- `aggregateDemand`
- `reason`: attach、detach、epochChanged、transactionQuiesce、performanceModeChanged
- `revision`
- `lastFailure`

Intent 不能包含：

- `SCStream`
- `SCDisplay`
- WebRTC session / publisher / peer connection
- `CMSampleBuffer`
- `CVPixelBuffer`
- encoded frames
- HTTP / WebSocket connection
- raw LAN URL or raw viewer id

Capture adapter 负责把 intent 映射到 CaptureEngine。Sharing adapter 负责把 LAN Web View viewer/session 状态映射成 runtime consumer demand。Runtime 只记录结果和 failure reason。

Capture intent revision 规则：

- capture intent revision 单调递增。
- adapter apply result 必须带回 revision。
- Runtime 只接受当前 revision 的 result。
- stale result 记录为 ignored，不覆盖 newer effective intent 或 last failure。
- detach / drain intent 同样必须带 revision。

## Consumer-Specific Behavior

Monitor：

- attach 一个 `monitor` lease。
- demand 默认 realtime、source resolution、source fps、cursor 按 monitor UI 设置。
- detach 后如果没有其他 lease，capture intent 进入 draining。
- Phase 3 transaction 中 deferred monitoring restore 由 Phase 4 lease attach 接管。

LAN Web View：

- shared surface 最多只能有一个 LAN capture lease。
- Phase 4 默认保持当前 eager sharing 行为：sharing start 创建 `lanWebView` capture lease。
- viewer attach 只更新 viewer count、latency evidence 和 fanout demand，不创建第二个 capture lease。
- viewer detach 只更新 viewer count、latency evidence 和 fanout demand，除非 sharing stop 释放 shared surface 的唯一 LAN capture lease。
- 多 viewer 不能创建多个 runtime capture intents。
- lazy first-viewer start 属于未来单独行为变更，不在 Phase 4 默认范围。
- `shareID` 继续只作为 route identity，`DisplaySurfaceIdentity` 只做 runtime 聚合和诊断关联。
- `/display`、`/signal` 保持 main display alias 语义。
- `/display/{shareID}`、`/signal/{shareID}` 保持具体 route 语义。
- 不新增 LAN token、password、account、auth。
- viewer endpoint 不暴露 diagnostics、support bundle 或 runtime snapshot。

Diagnostics recorder：

- attach 一个 `diagnosticsRecorder` lease。
- 默认不抢占 LAN Web View quality。
- 默认 observability 只记录 recorder lease state 和 failure reason，不记录桌面内容。
- 需要真实 sample 或 replay image 的测试继续使用 test-specific provider，避免权限弹窗。

Remote control：

- Phase 4 不做 remote control。
- 不新增鼠标、键盘、剪贴板、输入注入、browser agent control endpoint。
- LAN Web View 继续是只读观看能力。

## Observability And Privacy

Runtime snapshot 增加：

- active lease list。
- per-surface aggregated demand。
- effective capture intent。
- capture intent revision。
- last intent apply result。
- last failure reason。
- surface epoch。
- lease counts by consumer kind。
- viewer count summary。

默认输出必须脱敏：

- 不包含桌面内容。
- 不包含窗口标题。
- 不包含 URL 明文。
- 不包含本地路径明文。
- 不包含用户文本。
- 不包含 raw viewer client id。
- 不包含 WebRTC SDP、ICE candidate、sample buffer、pixel buffer。
- raw `shareID` 和完整分享 URL 只允许出现在 app UI 或显式 enhanced diagnostics。

Observability failure reason 使用稳定短码，例如：

```text
capture_intent_display_unavailable
capture_intent_epoch_mismatch
capture_intent_permission_unavailable
capture_intent_apply_failed
consumer_lease_surface_unavailable
consumer_lease_restarting
sharing_viewer_route_unavailable
```

## Migration Plan

1. Runtime model only
   新增 lease、consumer demand、aggregated demand、capture intent DTO 和 pure aggregator tests。不接真实 CaptureEngine，不改 UI。

2. Snapshot and observability
   把 lease state、aggregated demand、effective capture intent 加入 runtime snapshot。更新 redaction tests。

3. Capture command port
   扩展 `DisplayRuntimeCaptureCommanding` 或新增 capture intent port。Fake port 先覆盖 attach/detach 和 intent revision。

4. Monitor wiring
   Monitor start/stop 先 attach/detach runtime lease，再经 App adapter 使用现有 `DisplayCaptureRegistry.acquirePreview`。现有 preview frame path 不动。

5. LAN Web View wiring
   Sharing start attach shared surface 的唯一 `lanWebView` capture lease，保持当前 eager sharing 行为。viewer attach / detach 只更新 viewer count、latency evidence 和 fanout demand，不创建第二个 capture lease，不生成额外 runtime capture intent。lazy first-viewer start 属于未来单独行为变更，不在 Phase 4 默认范围。Web route、`shareID`、WebRTC/WebSocket/HTTP 处理保持在 Sharing/StreamingEngine。

6. Diagnostics recorder wiring
   Diagnostics recorder attach `diagnosticsRecorder` lease。默认复用 existing capture path，测试使用 fake/test provider。

7. Remove duplicate product policy
   Capture 层保留必要 token/session resource tracking。产品级 demand priority、owner、lease state 从 Capture 层移到 runtime 后，删除重复 policy 分支。

每一步都必须保持 capture pipeline 可验证，禁止一次性改 ScreenCaptureKit session、WebRTC publisher、frame fanout 和 Web routing。

## Test Plan

Runtime tests：

- attach creates lease with id、surface id、consumer kind、owner、timestamps、state。
- detach removes demand and updates aggregate demand。
- last lease release emits draining capture intent。
- stale epoch lease cannot drive old display id。
- monitor + LAN Web View aggregates to mixed high quality。
- multiple LAN viewers do not create multiple capture intents for the same surface。
- diagnostics recorder cannot downgrade active LAN Web View。
- `automatic` and `smooth` preserve source resolution and source fps。
- `powerEfficient` allows explicit frame-rate and pixel-budget downgrade。
- cursor demand uses OR semantics。
- observability snapshot redacts URLs、paths、window titles、user text、raw viewer ids。

Capture tests：

- `DisplayCaptureRegistry` still owns session creation and draining。
- intent apply maps to existing preview/share token behavior。
- last runtime lease release drains through CaptureEngine。
- no test path creates real privacy prompts。

Sharing tests：

- `/display` and `/signal` alias behavior remains。
- `/display/{shareID}` and `/signal/{shareID}` concrete route behavior remains。
- viewer session attach/detach updates viewer-count and fanout evidence on the existing lanWebView lease; it does not create or release an additional capture lease.
- WebRTC/WebSocket/HTTP code remains outside runtime。

App adapter tests：

- App adapter resolves display id to `SCDisplay` before capture acquisition。
- unavailable adapter returns explicit failure。
- weak owner release produces empty or failed snapshot state without crash。
- no app-facing text or UI information architecture changes are required。

Verification commands for implementation windows:

```sh
scripts/ci/static.sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter VoidDisplayCaptureTests
scripts/ci/unit.sh --filter VoidDisplaySharingTests
scripts/ci/unit.sh --filter DisplayRuntimeAdapterTests
scripts/ci/unit.sh --filter CaptureSharingIsolationTests
scripts/ci/xcode.sh --action build --configuration Debug
```

Final Phase 4 closeout should run the full unit suite and warning gate because runtime, capture, sharing and app adapters all participate.

## Boundary Checks

Boundary checks must be runnable on the current baseline after this docs-only plan lands. If a check is only a future planning guard, label it clearly and keep patterns narrow enough to avoid existing capture/sharing token and test stub terminology.

Runtime import boundary:

```sh
if rg -n "import (ScreenCaptureKit|VoidDisplayCapture|VoidDisplaySharing|VoidDisplayVirtualDisplay|VoidDisplayApp|SwiftUI|AppKit|Observation|VoidDisplayDesignSystem)" Sources/VoidDisplayRuntime; then exit 1; fi
```

Runtime forbidden type boundary:

```sh
if rg -n "\\b(SCStream|SCDisplay|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession|WebRTCPublisherSession|RelayPublisherSessioning|SignalSessionHub|SignalSocketConnection|WebRTCFrameMailbox|WebRTCMediaPipeline|DisplayCaptureSession|DisplayShareSubscription|DisplayPreviewSubscription)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
```

VirtualDisplay dependency boundary:

```sh
if rg -n "import VoidDisplayRuntime" Sources/VoidDisplayVirtualDisplay; then exit 1; fi
```

LAN security scope boundary:

```sh
if rg -n "\\b(LANAuth|ViewerAuth|WebViewerAuth|ViewerAccessToken|viewerPassword|accessPassword|passwordHash|accountLogin|viewerAccount|authenticateViewer|requiresViewerAuth|requiresAuthentication|WWW-Authenticate|Authorization:|Bearer )\\b" Sources/VoidDisplayRuntime Sources/VoidDisplaySharing Tests/VoidDisplayRuntimeTests Tests/VoidDisplaySharingTests Tests/VoidDisplayAppTests; then exit 1; fi
```

Existing capture/share tokens and relay control tokens are resource/session implementation details and are not LAN viewer auth.

Remote-control boundary:

```sh
if rg -n "\\b(RemoteControl|remoteControl|inputInjection|InputInjection|CGEventPost|AXUIElement|postKeyboardEvent|postMouseEvent|sendKeyboard|sendMouse|clipboardWrite|clipboardRead)\\b" Sources/VoidDisplayRuntime Sources/VoidDisplaySharing Sources/VoidDisplayCapture Tests; then exit 1; fi
```

Runtime snapshot privacy boundary:

```sh
if rg -n "\\b(rawURL|rawViewerID|rawViewerClientID|sdp|iceCandidate|localPath|windowTitle|desktopContent|desktopFrame|windowTitles|fullShareURL)\\b" Sources/VoidDisplayRuntime Tests/VoidDisplayRuntimeTests Tests/VoidDisplayAppTests; then exit 1; fi
```

The LAN security, remote-control and runtime snapshot privacy greps are future planning guards. If a future legitimate implementation must mention one of these strings in a negative test or documentation line, the handoff must classify it explicitly and prove no product behavior was added.

## Out Of Scope

- UI information architecture changes。
- Phase 6 `Displays` / `Diagnostics` navigation migration。
- LAN auth、token、password、account、permission system。
- Internet relay、NAT traversal、公网发现。
- Remote control。
- Web viewer diagnostics export endpoint。
- Rewriting ScreenCaptureKit capture pipeline。
- Rewriting WebRTC publisher, WebSocket signaling, HTTP routing or frame fanout。
- Preserving duplicate product demand policy after runtime owns aggregation。

## Acceptance Criteria

- Runtime exposes consumer lease state and aggregated demand in snapshot。
- Runtime emits effective capture intent without owning frame/session objects。
- Monitor、LAN Web View、diagnostics recorder are represented as DisplaySurface consumers。
- Last lease release leads to capture draining through CaptureEngine。
- Multiple viewers share one capture intent for the same surface。
- Monitor + LAN Web View keeps high quality mixed demand。
- `automatic` and `smooth` do not actively degrade LAN Web View quality。
- `powerEfficient` downgrade is explicit and observable。
- `DisplayCaptureRegistry` continues to own capture session and frame path。
- Sharing/StreamingEngine continues to own route, viewer session, WebRTC, WebSocket and HTTP。
- No LAN auth or remote-control behavior is added。
- Default observability is privacy-safe。
- Tests cover attach/detach、draining、多 consumer aggregation、power profile、monitor + LAN Web View、no privacy prompt。
- Debug build has zero compile errors and zero compile warnings。
