# DisplayRuntime Phase 6: UI Information Architecture Migration

状态：执行级计划
范围：规划 UI Information Architecture 迁移。本文档不实现代码，不修改源码、UI、localization、测试或工程配置。
基线：Phase 1 到 Phase 5 已完成。`DisplayRuntime` 已成为控制平面。Phase 4 已接入 consumer lease、demand aggregation、monitor、LAN Web View、diagnostics recorder wiring。Phase 5 已让 support bundle 和 Support / Diagnostics 侧以 runtime snapshot 为默认诊断事实入口。

## Summary

Phase 6 目标是把 UI 从功能入口堆叠迁移到以 `Displays` 为主入口的信息架构。

核心结果：

1. `Displays` 成为主入口，组织 Virtual Display、Monitor、LAN Web View 的状态和动作。
2. Virtual Display 仍是 VoidDisplay / 虚幕的核心能力。
3. Monitor 和 LAN Web View 是 `DisplaySurface` 的扩展观察能力。
4. Support Center 后续收敛为 `Diagnostics` / `诊断`，入口迁移分阶段完成。
5. Phase 6 使用 Phase 5 Stage 5.3 的 `RuntimeDiagnosticsSummary` 和 `state.sections["runtime"]`，不重做诊断数据来源。

固定边界：

1. `DisplayRuntime` 继续只做控制平面，不搬运视频帧。
2. LAN Web View 继续是局域网观察能力，不加 token、密码、账号或 auth，不做互联网共享。
3. 不做远程控制、输入注入、剪贴板、浏览器 agent control。
4. 不重复迁移 Phase 4 / Phase 5 已完成的 consumer lease、demand aggregation、support bundle runtime source convergence。
5. 不引入长期兼容层。临时 adapter 必须有明确删除条件。

## Goals / Non-goals

Goals：

1. 让 `Displays` 承担主导航入口，降低 Virtual Displays、Screen Monitoring、Screen Sharing 三个入口并列造成的结构割裂。
2. 让每个 `DisplaySurface` 成为 UI 的组织单元，统一呈现虚拟显示器身份、监控状态、LAN Web View 状态、viewer count、分享状态和诊断入口。
3. 保持现有 Virtual Display、Monitor、LAN Web View、support bundle 导出行为可达。
4. 将用户可见的 Support Center 入口逐步迁移为 `Diagnostics` / `诊断`。
5. 同步完成 app-facing 文案和 `Localizable.xcstrings` 更新。
6. 保持 UI 测试使用 test provider、fixture、mock、stub，不触发真实 macOS privacy prompt。

Non-goals：

1. 不迁移或重写 Phase 4 的 consumer lease、demand aggregation、monitor wiring、LAN Web View wiring、diagnostics recorder wiring。
2. 不迁移或重写 Phase 5 的 runtime snapshot privacy contract、support bundle runtime source convergence、runtime diagnostics summary。
3. 不修改 WebRTC、WebSocket、HTTP、frame fanout、CaptureEngine session、ScreenCaptureKit frame pipeline 或 VirtualDisplay lower layer。
4. 不修改 LAN Web View route、`shareID` 语义、viewer session 或 security stance。
5. 不新增 token、密码、账号体系、auth、互联网 relay、NAT 穿透或公网发现。
6. 不新增远程鼠标键盘、输入注入、剪贴板读写或 browser agent control endpoint。

## Product IA Target

目标导航：

```text
Displays
Diagnostics
```

`Displays` 是主入口。它组织所有 DisplaySurface 相关体验：

1. Virtual Display：创建、编辑、启用、停用、删除、恢复和状态呈现。
2. Monitor：本机观察当前 `DisplaySurface` 的状态和打开本机预览窗口的动作。
3. LAN Web View：局域网浏览器观察当前 `DisplaySurface` 的分享状态、viewer count、URL / route 存在性和停止分享动作。
4. Surface diagnostics：进入当前 `DisplaySurface` 的诊断摘要或跳转到 Diagnostics 中对应上下文。

`Diagnostics` 是诊断主入口。它组织：

1. `RuntimeDiagnosticsSummary`。
2. health、issues、events。
3. support bundle 导出动作。
4. 增强诊断 consent 入口。

迁移期允许旧入口暂时存在，但必须服务于分阶段迁移。任何旧入口、旧 enum case、旧 accessibility identifier、旧 view wrapper 或临时 adapter 都必须在 Phase 6.4 删除，或在 handoff 中写明保留原因、调用方、删除条件和验证影响。

## Migration Slices

采用 4 个执行 slice，不继续拆细。理由：当前 UI 迁移边界清楚，4 个阶段足够表达导航骨架、surface 聚合、diagnostics rename、删除审计；继续拆分会增加临时兼容路径和验证成本。

### Phase 6.1: Displays IA shell and navigation skeleton

目标：建立 `Displays` 主入口壳层和导航骨架，保留现有行为可达性。

执行项：

1. 调整 app navigation，使 `Displays` 成为承载 Virtual Display、Monitor、LAN Web View 的主入口。
2. 在 `Displays` 下建立清晰的 surface list、detail、status、action 区域。
3. 迁移时保留 Virtual Display、Monitor、LAN Web View 现有动作可达性，避免行为回退。
4. 不重写 capture、sharing、virtual display controller 的业务逻辑。
5. 如需临时路由 adapter，adapter 只能转接旧入口到新 `Displays` shell，并在 Phase 6.4 删除。

验收标准：

1. 主导航存在 `Displays`。
2. Virtual Display、Monitor、LAN Web View 的现有主流程仍可从 UI 到达。
3. UI smoke 能验证 `Displays` 入口和至少一个 surface 可见状态。
4. 未触碰 LAN Web View security、Web routes、frame pipeline、VirtualDisplay lower layer。

### Phase 6.2: DisplaySurface detail/status/action convergence

目标：围绕 `DisplaySurface` 收敛详情、状态和动作。

执行项：

1. 每个 surface detail 显示 `DisplaySurface` 身份、类型、Virtual Display 映射、Monitor 状态、LAN Web View 状态、viewer count、sharing 状态和最近失败码。
2. 状态数据优先来自 runtime snapshot 或现有 Phase 5 runtime summary 输入，不从分散 controller 重新拼装诊断事实。
3. Virtual Display 操作继续走现有 Virtual Display command / controller 路径。
4. Monitor 操作继续走现有 Capture UI composition 和 runtime consumer lease wiring。
5. LAN Web View 操作继续走现有 Sharing UI composition 和 runtime consumer lease wiring。
6. 停止分享支持按 `DisplaySurface` 作用域表达，但底层仍使用现有 sharing command 路径。

验收标准：

1. UI 明确显示正在 sharing 或 monitoring 的 `DisplaySurface`。
2. UI 显示当前 viewer count。
3. UI 支持按 `DisplaySurface` 停止分享。
4. UI 保留关闭整个 Web service 的动作。
5. `DisplayRuntime` 没有持有 frame、WebRTC session、SCStream、sample buffer 或 pixel buffer。

### Phase 6.3: Diagnostics entry rename and support flow cleanup

目标：将 `Support Center` 入口迁移为 `Diagnostics` / `诊断`，清理 support flow 命名。

执行项：

1. 用户可见主入口改为 `Diagnostics` / `诊断`。
2. 页面标题可使用 `Health & Diagnostics` / `健康与诊断`，前提是页面同时展示 health 和 diagnostics。
3. 页面内保留 `Export Support Bundle` / `导出支持包` 作为动作。
4. `Support` / `支持` 只用于 support bundle、反馈包、导出给开发者的数据包，不再作为诊断能力主入口名。
5. 继续使用 Phase 5 Stage 5.3 的 `RuntimeDiagnosticsSummary` 和 `state.sections["runtime"]` 作为 runtime diagnostics summary 来源。
6. 保留 support bundle 导出流程和 enhanced diagnostics consent 行为。

验收标准：

1. 主导航显示 `Diagnostics` / `诊断`。
2. 旧 `Support Center` 用户可见主入口删除或降级为迁移期跳转，并在 Phase 6.4 删除。
3. 页面仍可导出 support bundle。
4. runtime summary 仍来自 `state.sections["runtime"]`。
5. app-facing 文案和 localization 资源同步。

### Phase 6.4: UI cleanup, legacy section deletion, final audit

目标：删除遗留 section、临时 adapter、重复入口和过渡测试路径，完成最终审计。

执行项：

1. 删除旧独立 `Virtual Displays`、`Screen Monitoring`、`Screen Sharing` 主导航 section，前提是对应行为已从 `Displays` 可达并被测试覆盖。
2. 删除 `Support Center` 用户可见主入口和过渡 accessibility identifier，前提是 `Diagnostics` tests 已覆盖。
3. 删除 Phase 6.1 / Phase 6.2 引入的临时 adapter、路由别名和重复状态聚合。
4. 删除只为旧 IA 服务的测试路径。
5. 完成 localization、privacy prompt、LAN stance、remote-control 边界、runtime source 边界的最终审计。

验收标准：

1. 主导航只保留目标 IA 入口和仍有产品必要性的辅助入口。
2. 没有长期兼容层。
3. 临时 adapter 全部删除，或 handoff 明确保留原因、调用方、删除条件和验证影响。
4. boundary grep / diff audit 通过。

## Runtime Snapshot Dependencies

Phase 6 的输入来自已完成的 runtime 和 diagnostics 工作：

1. `DisplayRuntimeSnapshotProvider` provider key 仍为 `runtime`。
2. `ObservabilityStateSnapshot.sections["runtime"]` 是 runtime diagnostics 主事实入口。
3. `RuntimeDiagnosticsSummary` 是 Support / Diagnostics UI 的 runtime summary 输入。
4. Phase 4 的 consumer lease、aggregated demand、effective capture intent 和 consumer summary 已进入 runtime snapshot。
5. Phase 5 已让 support bundle 默认包含脱敏 runtime section。

Phase 6 禁止重做：

1. runtime snapshot privacy contract。
2. support bundle runtime source convergence。
3. consumer lease attach / detach。
4. demand aggregation。
5. diagnostics recorder wiring。
6. LAN Web View route、viewer session、shareID 或 security。

Phase 6 默认只能消费现有 runtime snapshot 和 diagnostics summary。若 UI 发现现有 runtime 数据无法表达必须展示的用户可观察状态，本阶段应把缺口记录为单独 runtime contract 任务；该任务需要另行审批、独立验证，不能夹带在 Phase 6 UI IA 迁移中。

## UI Naming

产品名继续使用：

```text
VoidDisplay / 虚幕
```

主导航命名：

```text
Displays
Diagnostics
```

中文主导航命名：

```text
显示器
诊断
```

详情或状态命名：

```text
Virtual Display
Physical Display
DisplaySurface
Monitor
LAN Web View
Viewer Count
Share Link
Support Bundle
Health & Diagnostics
```

命名规则：

1. Virtual Display 是核心能力名，继续用于创建、编辑、启用、停用、删除和恢复流程。
2. `DisplaySurface` 可用于工程文档、diagnostics、agent-readable state，不作为普通用户主导航文案。
3. Monitor 表达本机观察能力。
4. LAN Web View 表达局域网浏览器观察能力。
5. `Support Center` 不再作为用户可见主入口。
6. `Support Bundle` 只表达导出给人工排查的数据包。
7. `Observability` 只用于工程模块、agent-readable snapshot 和开发者文档。

## Localization Plan

Phase 6 会修改 app-facing 文案，因此必须同步更新：

```text
Apps/VoidDisplay/Resources/Localizable.xcstrings
```

Localization 要求：

1. 新增或修改 `Displays`、`Diagnostics`、`Health & Diagnostics`、`Support Bundle`、`LAN Web View`、`Monitor`、viewer count、surface status 等可见文案时，同步英文和中文资源。
2. 删除旧 `Support Center`、`Screen Monitoring`、`Screen Sharing`、`Virtual Displays` 主入口文案时，同步清理无调用方的 localization entries。
3. 如果 Xcode 修改 `Localizable.xcstrings`，该文件视为同一任务的必需输出。
4. 每个 slice handoff 必须说明是否影响 app-facing 文案。
5. 未改 app-facing 文案时，handoff 必须明确说明无需 localization 更新。

Localization 验证：

1. `rg -n "Support Center|Screen Monitoring|Screen Sharing|Virtual Displays" Sources Apps` 只允许命中文档、测试 fixture、迁移期 adapter 或明确保留的非用户主入口调用方。
2. `Localizable.xcstrings` 必须包含新增可见文案的英文和中文条目。
3. UI smoke 必须在目标入口命名下通过。

## Test Plan

未来 Phase 6 代码阶段至少运行：

```sh
scripts/ci/unit.sh --filter VoidDisplayAppTests
scripts/ci/unit.sh --filter VoidDisplaySupportTests
scripts/ci/unit.sh --filter VoidDisplayRuntimeTests
scripts/ci/ui_smoke.sh --only-testing VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline
scripts/ci/xcode.sh --action build --configuration Debug
```

Targeted unit tests：

1. App navigation tests 覆盖 `Displays` 和 `Diagnostics` sidebar selection。
2. UI composition tests 覆盖 `DisplaySurface` status/action convergence。
3. Support tests 覆盖 `RuntimeDiagnosticsSummary` 继续从 `state.sections["runtime"]` 读取。
4. Runtime tests 作为既有 contract guard，验证 Phase 6 没有破坏 `DisplayRuntimeSnapshotProvider`、`RuntimeDiagnosticsSummary` 和 `state.sections["runtime"]` 读取路径。

UI navigation smoke：

1. 使用 `VOIDDISPLAY_UI_TEST_MODE=1`。
2. 使用 fixture、mock、stub，禁止依赖真实 ScreenCaptureKit permission prompt。
3. 使用 `-sharing.preferredPort <port>` 注入端口，不写硬编码 suite name。
4. 覆盖 `Displays` 主入口、surface list、Virtual Display 动作入口、Monitor 动作入口、LAN Web View 状态入口、`Diagnostics` 入口、support bundle 导出入口。

Build gate：

1. `scripts/ci/xcode.sh --action build --configuration Debug` 必须通过。
2. 零 compile errors。
3. 零 compile warnings。

Privacy prompt isolation：

1. UI tests 不触发真实屏幕录制、麦克风、摄像头、键盘输入、输入法或类似 privacy authorization dialogs。
2. 产品中可能请求隐私权限的路径，在 test scenario 下必须使用 test provider、mock、stub 或等价隔离层。
3. 测试 harness 自身缺少 Automation、Accessibility、Input Monitoring 等授权时，归类为环境 setup failure，不归类为产品或测试代码失败。

Docs task verification for this file：

```sh
git diff --check -- docs/display-runtime-phase-6-plan.md
git status --short
```

本 docs-only 任务不运行 Xcode build 或 unit tests。若执行窗口改到源码、UI、localization、测试、脚本或工程配置，则必须运行相关 build / test gate。

## Boundary Checks

LAN security stance audit：

```sh
if rg -n "\b(LANAuth|ViewerAuth|WebViewerAuth|ViewerAccessToken|viewerPassword|accessPassword|passwordHash|accountLogin|viewerAccount|authenticateViewer|requiresViewerAuth|requiresAuthentication|WWW-Authenticate|Authorization:|Bearer )\b" Sources/VoidDisplayRuntime Sources/VoidDisplaySharing Tests/VoidDisplayRuntimeTests Tests/VoidDisplaySharingTests Tests/VoidDisplayAppTests; then exit 1; fi
```

Remote control audit：

```sh
if rg -n "\b(RemoteControl|remoteControl|inputInjection|InputInjection|CGEventPost|AXUIElement|postKeyboardEvent|postMouseEvent|sendKeyboard|sendMouse|clipboardWrite|clipboardRead|browserAgentControl|agentControlEndpoint)\b" Sources/VoidDisplayRuntime Sources/VoidDisplaySharing Sources/VoidDisplayCapture Sources/VoidDisplaySupport Tests; then exit 1; fi
```

Runtime control-plane audit：

```sh
if rg -n "import (ScreenCaptureKit|VoidDisplayCapture|VoidDisplaySharing|VoidDisplayVirtualDisplay|VoidDisplayApp|SwiftUI|AppKit|Observation|VoidDisplayDesignSystem)" Sources/VoidDisplayRuntime; then exit 1; fi
if rg -n "\b(SCStream|SCDisplay|CMSampleBuffer|CVPixelBuffer|RTCPeerConnection|WebRTCSession|WebRTCPublisherSession|RelayPublisherSessioning|SignalSessionHub|SignalSocketConnection|WebRTCFrameMailbox|WebRTCMediaPipeline|DisplayCaptureSession|DisplayShareSubscription|DisplayPreviewSubscription)\b" Sources/VoidDisplayRuntime; then exit 1; fi
```

Diff boundary audit：

```sh
git diff --name-only -- Sources/VoidDisplaySharing/Web Sources/VoidDisplaySharing/Resources Sources/VoidDisplayCapture/Services Sources/VoidDisplayCapture/Rendering Sources/VoidDisplayVirtualDisplay/Services Sources/VoidDisplayVirtualDisplay/Models Sources/VoidDisplayVirtualDisplay/Logic Sources/CGVirtualDisplayPrivate
```

The diff boundary audit must be empty unless a separate approved non-UI task explicitly changes that scope. UI view and navigation changes are allowed only outside these lower-layer paths.

Runtime diagnostics source audit：

```sh
rg -n "RuntimeDiagnosticsSummary|sections\[\"runtime\"\]|support_center_runtime_panel|diagnostics" Sources/VoidDisplaySupport Sources/VoidDisplayApp Tests/VoidDisplaySupportTests Tests/VoidDisplayAppTests
```

Audit result must prove Diagnostics UI still consumes Phase 5 runtime summary input rather than rebuilding diagnostics facts from scattered controller state.

## Rollback / Deletion Criteria

Rollback criteria：

1. If `Displays` shell causes navigation regressions, revert the slice to the last passing navigation state and keep old entrypoints until the IA shell is corrected.
2. If surface detail convergence breaks Virtual Display create / edit / enable / disable / delete, roll back that slice and keep the existing Virtual Display flow as the protected core path.
3. If Diagnostics rename breaks support bundle export, roll back the rename slice and keep export flow functional.
4. If UI smoke triggers a real privacy prompt, reject the test or product path change and restore test isolation before continuing.
5. If boundary grep finds LAN auth, remote control, input injection, clipboard, browser agent control or frame pipeline drift, reject the slice unless a separate approved task changed scope.

Deletion criteria：

1. Delete old navigation section after equivalent `Displays` path is available and covered by UI smoke.
2. Delete old `Support Center` visible entry after `Diagnostics` path is available, localized and covered by tests.
3. Delete temporary adapter after all callers route through the new IA path.
4. Delete old accessibility identifiers only after UI tests use the target `Displays` / `Diagnostics` identifiers.
5. Delete duplicate status aggregation once `DisplaySurface` detail reads the chosen runtime snapshot or diagnostics summary source.

No compatibility layer may survive Phase 6.4 without a documented caller, removal condition and validation impact.

## Acceptance Criteria

Phase 6 is accepted when all conditions hold:

1. `Displays` is the primary UI entry for DisplaySurface work.
2. Virtual Display remains the protected core capability and all existing core actions remain reachable.
3. Monitor and LAN Web View are presented as `DisplaySurface` observation capabilities.
4. UI clearly shows active sharing, active monitoring and viewer count for relevant surfaces.
5. UI supports stopping sharing by `DisplaySurface`.
6. UI preserves the action to stop the whole Web service.
7. `Diagnostics` / `诊断` replaces `Support Center` as the user-visible diagnostics entry.
8. support bundle export remains available from Diagnostics.
9. runtime diagnostics summary comes from `RuntimeDiagnosticsSummary` and `state.sections["runtime"]`.
10. app-facing text is localized in `Localizable.xcstrings`.
11. Targeted unit tests pass.
12. UI navigation smoke passes.
13. Xcode Debug build passes with zero compile errors and zero compile warnings.
14. UI tests do not trigger real macOS privacy prompts.
15. LAN Web View security stance is unchanged.
16. No remote control, input injection, clipboard or browser agent control capability is added.
17. No Phase 4 / Phase 5 capability is duplicated or re-migrated.
18. No long-term compatibility layer remains.
