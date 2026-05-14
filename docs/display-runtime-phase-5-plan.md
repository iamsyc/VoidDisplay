# DisplayRuntime Phase 5: Observability And Diagnostics Hardening

状态：执行级计划
范围：规划 runtime snapshot 脱敏契约、support bundle runtime 数据源收敛、Diagnostics 页面读取 runtime snapshot 的迁移边界。本文档不实现代码。
基线：Phase 4 consumer lease 已完成，runtime snapshot 已有 `runtime` section，support bundle 已导出 `state/current-state.json`，旧 controller snapshot providers 仍注册为并行状态来源。

## Summary

Phase 5 目标是让 runtime snapshot 成为 AI agent、自动化工具和用户诊断的结构化事实接口。

核心结果：

- `DisplayRuntimeSnapshot` 输出 agent-readable structured state。
- 默认 runtime snapshot 和默认 support bundle 必须脱敏。
- 默认导出不得包含桌面内容、窗口标题、用户文本、URL、路径明文、raw `shareID`、LAN IP、完整分享 URL、raw viewer id、SDP、ICE、sample buffer 或 pixel buffer。
- Support bundle 默认使用脱敏 runtime snapshot。
- Enhanced diagnostics 必须由用户显式开启。
- Diagnostics 页面后续读取 runtime snapshot，不再主要依赖分散 controller 状态。

固定边界：

- 不改 LAN Web View route、`shareID`、auth 或 security。
- 不改 WebRTC、WebSocket、HTTP 或 frame pipeline。
- 不改 VirtualDisplay lower layer。
- 不做 Phase 6 UI 信息架构迁移。
- 不引入远程控制。
- 不要求完整代码实现，本计划只定义后续 Phase 5 实施顺序、验收和验证门槛。

## Current Baseline

当前代码基线已经具备：

- `DisplayRuntimeSnapshot` 当前 `schemaVersion` 为 `3`。
- `DisplayRuntimeSnapshotProvider` 的 Observability provider key 为 `runtime`。
- `DisplayRuntimeSnapshot` 已包含 surfaces、catalog、capture、sharing、virtual display、transactions、consumer leases、aggregated demands、effective capture intents 和 consumer summary。
- `ObservabilityCenter` 会把 provider sections 写入 `ObservabilityStateSnapshot.sections`。
- `FeedbackBundleExporter` 会把当前 state 写入 support bundle 的 `state/current-state.json`。
- `FeedbackConsent()` 默认不包含 unified log、crash report excerpt 或 related config snapshots。
- `FeedbackConsent.hasEnhancedCollection` 已作为 enhanced attachments 的开关。
- `SupportCenterView` 当前仍是 Support Center 页面，内部通过 `ObservabilityDiagnosticsSnapshot` 读取 state、health、issues 和 events。
- `VoidDisplayApp` 启动时仍注册 runtime、capture、sharing、virtual display、screen catalog、system、persistence 等多个 snapshot providers。

Phase 5 的重点是把 default diagnostics 事实源收敛到 runtime snapshot，并把旧 provider 的存在降级为迁移期对照或明确的 runtime 子 section。

## Stage 5.1: Runtime Snapshot Privacy Contract

目标：固定 runtime snapshot 的默认脱敏契约，使它可以直接被 AI agent 和自动化工具读取。

执行项：

- 定义 runtime snapshot 默认导出的敏感数据禁区，覆盖桌面内容、窗口标题、用户文本、URL、路径明文、raw `shareID`、LAN IP、完整分享 URL、raw viewer id、SDP、ICE、sample buffer 和 pixel buffer。
- 保持 runtime snapshot 结构化、稳定、可 `Codable` 编解码，避免把隐私安全建立在自由文本过滤上。
- 对 `DisplayRuntimeSnapshot` 及其子 DTO 做字段审计，确认默认字段只表达状态、计数、布尔能力、短码 failure reason、redacted identity 或稳定聚合信息。
- Enhanced diagnostics 如需输出 raw identifier，必须在数据结构或输出说明中标明来源、用途和关闭方式。
- Runtime target 不引入 UI、App controller、ScreenCaptureKit frame type、WebRTC session type 或 frame pipeline type。
- 敏感 fixture 必须进入测试，覆盖 raw `shareID`、LAN URL、LAN IP、本地路径、窗口标题、用户输入文本、viewer id 和桌面内容描述。
- 隐私验证分为 source grep 和 encoded output assertions。source grep 主要限制产品源码和 runtime 源码，不把 `Tests` 中出现敏感 fixture 相关词视为失败。测试源码如出现敏感词，只能作为 fixture 或断言样本，handoff 必须明确分类。

验收标准：

- 默认 runtime snapshot JSON 不包含敏感 fixture 原文。
- runtime snapshot 可被 `ObservabilityCodec` 编码后再解码为 `DisplayRuntimeSnapshot`。
- `schemaVersion` 只在 wire shape 发生实际兼容性变化时推进，并在测试中锁定。
- runtime snapshot 中 LAN Web View 只暴露 route existence、viewer count、lifecycle、consumer demand 等结构化状态。
- runtime snapshot 不导出 raw `shareID`、完整 LAN URL、LAN IP 或 raw viewer client id。
- runtime failure reason 使用稳定短码，不使用用户文本或原始错误全文作为默认导出事实。

测试范围：

```sh
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/unit.sh --filter ObservabilitySnapshotProviderTests
```

重点测试场景：

- Runtime provider key 仍为 `runtime`。
- Phase 4 consumer lease、aggregated demand、effective capture intent 在默认 JSON 中存在且可解码。
- owner redacted label、raw viewer id、LAN URL、home path、窗口标题、用户文本和桌面内容 fixture 不出现在默认 runtime section。
- `ObservabilityCodec` 编码后的 runtime JSON 不包含具体敏感 fixture 值。
- managed virtual display identity、surface epoch、consumer summary 和 transaction trace 可被 agent 稳定读取。

边界 grep：

```sh
if rg -n "import (ScreenCaptureKit|VoidDisplayCapture|VoidDisplaySharing|VoidDisplayVirtualDisplay|VoidDisplayApp|SwiftUI|AppKit|Observation|VoidDisplayDesignSystem)" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "\\b(SCStream|SCDisplay|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession|WebRTCPublisherSession|RelayPublisherSessioning|SignalSessionHub|SignalSocketConnection|WebRTCFrameMailbox|WebRTCMediaPipeline|DisplayCaptureSession|DisplayShareSubscription|DisplayPreviewSubscription)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "\\b(rawURL|rawViewerID|rawViewerClientID|sdp|iceCandidate|localPath|windowTitle|desktopContent|desktopFrame|windowTitles|fullShareURL|fullShareUrl|rawShareID|rawShareId|lanIPAddress|lanIpAddress)\\b" Sources/VoidDisplayRuntime; then exit 1; fi
```

## Stage 5.2: Support Bundle Runtime Source Convergence

目标：让 support bundle 默认导出脱敏 runtime snapshot，并把 runtime section 作为诊断事实主入口。

执行项：

- 确认 `state/current-state.json` 在默认 support bundle 中包含 `sections.runtime`。
- 默认 consent 下不写 `attachments/`，不采集 unified log summary、crash report excerpt 或 related config snapshots。
- Config、log、crash 等 enhanced 数据继续只在用户显式开启后进入附件，并继续通过 sanitizer。
- Support bundle 中旧 controller snapshot provider 不能继续承担 primary diagnostics source。保留时必须降级为迁移期对照，或收敛为 runtime 子 section。
- Bundle manifest 和 exported state 必须能证明当前导出使用默认脱敏路径，不能靠 UI 文案承诺替代数据验证。
- `FeedbackConsent()` 默认值必须保持全 false。
- 测试源码可以包含 LAN IP、完整 URL、路径、窗口标题、用户文本、raw viewer id 等敏感值作为 fixture。验证对象必须是编码后的 runtime JSON、support bundle 解压内容、`manifest.json` 和 `state/current-state.json`，handoff 必须把测试源码命中分类为 fixture，不得把 fixture 命中解释为产品泄漏。

验收标准：

- 默认 support bundle 包含 `state/current-state.json`、`state/health-summary.json`、`events/recent-events.ndjson`、`issues/recent-issues.json` 和 `manifest.json`。
- 默认 support bundle 的 `state/current-state.json` 包含 `runtime` section。
- 默认 support bundle 不包含 `attachments/`。
- 默认 support bundle 不包含 raw `shareID`、LAN IP、完整 URL、路径明文、窗口标题、用户文本、raw viewer id、SDP、ICE、sample buffer 或 pixel buffer。
- `manifest.json` 和 `state/current-state.json` 不包含具体敏感 fixture 值。
- Enhanced diagnostics 未开启时，不导出 config snapshots、unified log summary 或 crash report excerpt。
- Enhanced diagnostics 开启后，附件仍经 sanitizer，且测试中解压 bundle 验证敏感 fixture 被处理。

测试范围：

```sh
scripts/ci/unit.sh --filter VoidDisplayObservabilityTests
scripts/ci/unit.sh --filter VoidDisplaySupportTests
scripts/ci/unit.sh --filter ObservabilitySnapshotProviderTests
scripts/ci/unit.sh --filter AppBootstrapTests
```

重点测试场景：

- `FeedbackBundleExporterTests` 解压 bundle，验证 archive layout。
- `FeedbackBundleExporterTests` 验证默认 consent 不产生 enhanced attachments。
- `FeedbackBundleExporterTests` 使用包含 LAN IP、home path、完整 URL、raw `shareID` 的 fixture，验证默认 bundle 不泄漏。
- `FeedbackBundleExporterTests` 解压 support bundle 后检查所有默认导出文件，尤其是 `manifest.json` 和 `state/current-state.json`，确认不包含具体敏感 fixture 值。
- `ObservabilityCenter` refresh 后的 diagnostics snapshot 包含 runtime section。
- `FeedbackConsent()` 默认值锁定为全 false，`hasEnhancedCollection` 只在显式字段开启时为 true。

审计项：

```sh
git diff --name-only -- Sources/VoidDisplaySharing/Web Sources/VoidDisplaySharing/Resources Sources/VoidDisplayCapture/Services Sources/VoidDisplayCapture/Rendering Sources/VoidDisplayVirtualDisplay Sources/CGVirtualDisplayPrivate
if rg -n "\\b(rawShareID|rawShareId|fullShareURL|fullShareUrl|rawViewerID|rawViewerClientID|desktopContent|desktopFrame|windowTitle|windowTitles|localPath|sdp|iceCandidate)\\b" Sources/VoidDisplayObservability Sources/VoidDisplaySupport; then exit 1; fi
```

The `git diff --name-only` audit must be empty for Web routes, frame pipeline and VirtualDisplay lower layer unless a later approved task explicitly changes Phase 5 scope.
Tests are validated by encoded artifact assertions, not by banning fixture words from test source.

## Stage 5.3: Diagnostics Runtime Consumption And Boundary Audit

目标：让 Diagnostics 页面后续读取 runtime snapshot，降低对分散 controller 状态的依赖，并完成 Phase 5 边界审计。

执行项：

- Diagnostics 页面读取 `state.sections["runtime"]` 作为 runtime summary 的主数据源。
- 保留现有 Support Center 导出流程和入口命名，Phase 6 再做 `Diagnostics` / `诊断` 导航迁移。
- 页面内可继续展示 health、issues、events 和 support bundle 操作，但 runtime 状态摘要必须来自 runtime snapshot。
- 删除或降级重复 controller provider 在页面主诊断视图中的角色。
- 不调整 LAN Web View route、`shareID` 语义、auth/security、WebRTC、WebSocket、HTTP、frame fanout、CaptureEngine session 或 VirtualDisplay lower layer。
- 不新增 Web viewer diagnostics export endpoint。
- 不新增远程控制、输入注入、鼠标键盘、剪贴板或 browser agent control endpoint。
- Localization gate：若新增或修改 `SupportCenterView` 可见文案，必须同步更新 `Apps/VoidDisplay/Resources/Localizable.xcstrings`。若未改 app-facing 文案，handoff 必须明确说明无需 localization 更新。

验收标准：

- Diagnostics 页面 runtime summary 来自 `state.sections["runtime"]`。
- 页面仍可导出 support bundle。
- 旧 controller provider 不再是 Diagnostics 页面主数据源。
- Phase 6 信息架构迁移未发生，Support Center 命名和导航可暂留。
- Debug build 零 compile errors、零 compile warnings。
- LAN Web View route、`shareID`、auth/security、WebRTC/WebSocket/HTTP/frame pipeline、VirtualDisplay lower layer 没有变更。
- 没有新增远程控制能力。

测试范围：

```sh
scripts/ci/unit.sh --filter VoidDisplaySupportTests
scripts/ci/unit.sh --filter VoidDisplayAppTests
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/xcode.sh --action build --configuration Debug
```

如果只改 support diagnostics presentation 且未触碰 runtime、sharing、capture、virtual display 或工程配置，可以把测试收敛到相关 support/app targeted tests 加 Debug build。若改到共享模型、Package、Xcode 工程、test infra 或 cross-module contracts，必须扩大到相关模块测试。

边界审计：

```sh
git diff --name-only -- Sources/VoidDisplaySharing/Web Sources/VoidDisplaySharing/Resources Sources/VoidDisplayCapture/Services Sources/VoidDisplayCapture/Rendering Sources/VoidDisplayVirtualDisplay Sources/CGVirtualDisplayPrivate
if rg -n "\\b(LANAuth|ViewerAuth|WebViewerAuth|ViewerAccessToken|viewerPassword|accessPassword|passwordHash|accountLogin|viewerAccount|authenticateViewer|requiresViewerAuth|requiresAuthentication|WWW-Authenticate|Authorization:|Bearer )\\b" Sources/VoidDisplayRuntime Sources/VoidDisplaySharing Tests/VoidDisplayRuntimeTests Tests/VoidDisplaySharingTests Tests/VoidDisplayAppTests; then exit 1; fi
if rg -n "\\b(RemoteControl|remoteControl|inputInjection|InputInjection|CGEventPost|AXUIElement|postKeyboardEvent|postMouseEvent|sendKeyboard|sendMouse|clipboardWrite|clipboardRead|browserAgentControl|agentControlEndpoint)\\b" Sources/VoidDisplayRuntime Sources/VoidDisplaySharing Sources/VoidDisplayCapture Sources/VoidDisplaySupport Tests; then exit 1; fi
```

If a future legitimate negative test or documentation fixture must mention one of these terms, the implementation handoff must classify the hit explicitly and prove no product behavior was added.

## Final Verification For This Docs Task

When creating this plan document, the execution window must run:

```sh
git diff --check -- docs/display-runtime-phase-5-plan.md
git status --short
```

This task is docs-only. Do not run Xcode build or unit tests by default for this documentation commit. If an execution window changes code, tests, Package files, Xcode project files, scripts or localization resources, it must run the related build/test gate required by repository policy.

## Commit

After `docs/display-runtime-phase-5-plan.md` is created and `git diff --check` passes, stage only this file and commit with:

```text
docs(runtime): 修订 phase 5 diagnostics hardening 计划
```

The commit must contain only:

```text
docs/display-runtime-phase-5-plan.md
```

## Assumptions

- Current branch is already an acceptable `codex/*` branch for this docs-only task.
- Phase 5 planning does not require a new branch unless the worktree becomes dirty with unrelated changes or the branch changes to an invalid target.
- Runtime snapshot remains the structured diagnostics contract; logs remain supporting evidence.
- Enhanced diagnostics means explicit user consent through existing or future user-visible toggles.
- Default export policy is privacy-first and agent-readable at the same time.
