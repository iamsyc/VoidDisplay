# 测试策略

## 分层

| 层级 | 覆盖内容 | 入口 |
| --- | --- | --- |
| 静态门禁 | Shell、workflow、格式、lint、工程结构和项目静态约束 | `scripts/ci/static.sh` |
| 单元与集成测试 | SwiftPM、浏览器 JavaScript、Go relay | `scripts/ci/unit.sh` |
| Xcode build | App target、资源、工程配置和编译诊断 | `scripts/ci/xcode.sh --action build` |
| UI smoke | 少量关键用户可观察路径 | `scripts/ci/ui_smoke.sh` |
| 完整回归 | 静态、单元、Debug build、UI、稳定性和 arm64 release smoke | `scripts/ci/full_regression.sh --destination "platform=macOS,arch=$(uname -m)"` |

Xcode 的 `VoidDisplay` scheme 用于 App build、run 和 UI test。Cmd-U 不会执行 SwiftPM、浏览器 JavaScript 或 Go 测试，完整单元与集成测试入口仍是 `scripts/ci/unit.sh`。

## 测试设计

默认自动化测试应满足以下约束：

- 断言行为、状态转换、输出或用户可观察结果。
- 使用可控 provider、fake、fixture 和临时目录隔离系统状态。
- 不依赖真实局域网、真实桌面内容、人工点击系统弹窗或固定端口。
- 不新增只有渲染或启动、没有行为断言的弱测试。
- 同一契约优先在最接近所有权的层级验证，避免在多个 target 重复覆盖实现细节。

UI smoke 复用 [SmokeTestHelpers.swift](../../UITests/VoidDisplayUITests/Smoke/SmokeTestHelpers.swift)。共享端口通过 `-sharing.preferredPort <port>` launch arguments 注入，测试不直接写硬编码 suite。

## 本地验证

日常完整本地入口：

```bash
scripts/dev/validate.sh
```

小范围改动使用最窄的相关门禁：

```bash
scripts/ci/unit.sh --filter '<test-filter>'
scripts/ci/xcode.sh --action build --configuration Debug \
  --destination "platform=macOS,arch=$(uname -m)"
scripts/ci/ui_smoke.sh \
  --only-testing '<test-identifier>' \
  --destination "platform=macOS,arch=$(uname -m)"
```

跨模块、并发、持久化、网络、安全、脚本、工程设置或发布改动需要扩大验证范围。本机支持对应 release target 时，完整回归入口是：

```bash
scripts/ci/full_regression.sh \
  --destination "platform=macOS,arch=$(uname -m)"
```

该入口依次运行静态门禁、全部单元与集成测试、Debug build、UI 测试、稳定性检查和 arm64 release smoke。完整命令选择规则见根目录 [AGENTS.md](../../AGENTS.md)。

### 隐私权限敏感的真实应用验收

屏幕录制等 macOS 隐私权限会识别应用的代码签名身份。需要验证真实权限状态时，使用 Xcode Personal Team 自动管理的本机 `Apple Development` 身份构建验收副本：

```bash
scripts/dev/build_signed_runtime.sh \
  --out-dir .ai-tmp/signed-runtime-acceptance
```

只启动 `.ai-tmp/signed-runtime-acceptance/signed-runtime-summary.json` 中 `app_path` 指向的应用。该流程只用于当前 Mac 上的开发验收，不进入 CI、Release 或公开分发。普通自动化测试继续使用隔离 provider，普通 Xcode 门禁继续关闭签名。

免费 Apple Account 提供的 Xcode Personal Team 足以完成该流程，不要求 Developer ID、付费会员或公证。缺少可用 `Apple Development` 身份时，应在 Xcode 的 Accounts 设置中恢复 Personal Team 开发身份并重新构建；不得改用未签名或 ad hoc 副本声称权限验收通过。开发身份更新后，macOS 可能要求重新授予屏幕录制权限。

## 环境故障分类

测试宿主在 bootstrapping 前被 macOS 隐私自动化、Accessibility、Input Monitoring、Gatekeeper 或签名策略终止时，应记录为环境设置失败。先通过 `.xcresult` 和统一日志确认宿主未进入测试，再处理机器环境并复测最小目标。

产品代码或测试代码触发了本可避免的 Screen Recording、麦克风、摄像头、键盘输入等授权弹窗时，应视为测试隔离缺陷并修正 provider 或测试模式。任何 `totalTestCount == 0` 的结果都不能计为通过。

## 远程 CI

远程 runner、变更分类、job matrix 和 artifact 由 workflow 决定。仓库分支保护或 ruleset 与实时 PR check suite 共同决定哪些 check 属于外部必需门禁。本地通过不能替代远程 CI 结果。详细说明见 [CI Workflows](./ci-workflows.md)。
