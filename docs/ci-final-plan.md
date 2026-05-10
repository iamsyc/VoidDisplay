# VoidDisplay CI 与脚本体系最终设计

## 1. 约束

本方案只使用 GitHub hosted runner，不引入自托管 runner。CI 默认运行在 GitHub 提供的 macOS runner 上，架构覆盖 `macos-26` 和 `macos-26-intel`。

本方案不依赖 Apple Developer Program。Release 产物继续使用 ad hoc signed DMG，不做 Developer ID 签名、公证或 stapling。发布页必须清楚说明安装包仅使用 ad hoc signing，未经过 Apple Developer ID 签名或 Apple 认证，用户首次打开时可能需要手动确认。

自动发版继续由 Xcode project 中的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 驱动。合入 `main` 后，只要版本条件满足，Release workflow 自动生成 tag、构建产物、校验产物并发布 GitHub Release。

部署目标保持 macOS `15.6`。Swift 代码统一使用 Swift 6。

## 2. 目标

CI 和脚本体系的核心目标是可复现、可审计、低误报、低人工介入。

所有 CI job 只负责调度，真实逻辑收敛到 `scripts/`。本地命令和 CI 命令共用同一批脚本，避免本地通过而 CI 失败的分裂路径。

所有关键输出都要可机器解析。测试数量、失败分类、产物路径、checksum、SBOM、release verify 结果都生成 JSON summary，并上传 artifact。

所有关键门禁都要能解释失败原因。失败类型至少区分编译失败、warning 失败、0 测试失败、断言失败、runner 启动不稳定、权限环境问题、依赖安全问题、release 目标 `ci-gate` 未通过、release 校验失败。

## 3. 脚本入口

脚本分为四层。

第一层是开发入口。

`scripts/dev/bootstrap.sh` 安装和校验工具链。

`scripts/dev/doctor.sh` 检查本机是否具备构建和测试条件，包括 Xcode、Swift、Go、mise、必要命令、项目依赖、macOS UI test 环境提示。

第二层是 CI 入口。

`scripts/ci/classify.sh` 根据 changed files 输出改动范围。

`scripts/ci/static.sh` 运行 actionlint、shellcheck、shfmt、SwiftFormat、SwiftLint、workflow runner label 检查、外部 action SHA 固定检查。

`scripts/ci/unit.sh` 运行 SwiftPM unit 和 Go relay unit，强制校验 SwiftPM 测试数量大于 0，并把 SwiftPM build/test warning 或 error 视为失败。

`scripts/ci/xcode.sh` 统一封装 Xcode build、build for testing、test。`test` 动作必须显式传入 `--only-testing` 或 `--test-plan`。

`scripts/ci/ui_smoke.sh` 运行 UI smoke，输出失败分类，并只对 runner 启动类不稳定做有限重试。

`scripts/ci/release_smoke.sh` 构建发布候选 app，校验架构、bundle id、版本号、relay 二进制、资源完整性和 warning。

`scripts/ci/full_regression.sh` 运行完整回归，供 nightly 和人工调度使用。

`scripts/ci/coverage.sh` 生成 SwiftPM coverage summary。

第三层是 release 入口。

`scripts/release/prepare.sh` 根据事件、目标 checkout、版本字段和现有 tag 计算是否发布，并输出 `should_release`、`tag`、`target_sha`、`version`、`build_number`。

`scripts/release/build.sh` 构建指定 tag 和架构的 release assets，包括 DMG、SHA256、SBOM、summary。

`scripts/release/verify.sh` 校验 DMG 可挂载、app 存在、bundle id 正确、版本匹配、架构匹配、checksum 有效、SBOM 有效、ad hoc codesign 可验证、attestation 可选有效。

Release workflow 在发布前用内联 GitHub API 逻辑验证目标 commit 的 `ci-gate` 已成功，防止绕过分支保护或手动 dispatch 发布未验证 commit。该验证不执行目标 checkout 中的脚本。

`scripts/release/publish.sh` 只封装发布前最终校验和 GitHub Release 上传。本地默认不调用，CI release job 调用。

第四层是共享库。

`scripts/lib/common.sh` 提供日志、错误、路径、重试、artifact 目录、命令存在性检查。

`scripts/lib/xcode.sh` 提供 Xcode 选择、版本校验、cache key 后缀。

`scripts/lib/xcresult.sh` 提供 xcresult 测试数量解析、失败摘要提取。

`scripts/lib/artifacts.sh` 提供 JSON summary、artifact manifest、checksum helpers。

## 4. 工具链固定

`mise.toml` 是主工具链来源，固定 Go、actionlint、shellcheck、shfmt、SwiftFormat、SwiftLint、jq、ripgrep、syft、gh。

`Brewfile` 只作为本地 fallback。CI 以 `mise.toml` 为准。

Xcode 版本由 `.github/actions/xcode-select` 和 `scripts/lib/xcode.sh` 双重校验。默认期望 Xcode `26.4` 和 Swift `6.x`，临时切换必须显式设置 `EXPECTED_XCODE_VERSION_PREFIX`。

所有外部 GitHub Actions 必须固定到 40 位 commit SHA，并在同一行保留来源版本注释。

## 5. PR CI

PR workflow 使用一个稳定的 required check：`ci-gate`。其他 job 都是输入信号，由 `ci-gate` 统一裁决。

`classify-changes` 首先计算改动范围。文档-only PR 走 fast path，只要求分类 job 和 summary 成功。代码相关 PR 进入完整 PR gate。

代码相关 PR 必跑：

1. `script-static-checks`
2. `dependency-review`
3. `unit-tests`
4. `xcode-build`
5. `ci-gate`
6. `ci-summary`

UI 相关 PR 额外运行 UI smoke matrix。初始矩阵覆盖首页导航、权限拒绝、虚拟显示 rebuild 失败行。后续可以按风险扩展。

目标分支是 `main` 的代码 PR 额外运行 arm64 release smoke。x86_64 release smoke 留给 main push、nightly 和 release workflow 承担。

PR CI 执行当前 checkout 的脚本。脚本和 workflow 完整性由 review 和 `script-static-checks` 承担，`ci-gate` 继续作为唯一 required check。PR CI checkout 不持久化凭据，bootstrap 不向已 checkout 的仓库脚本暴露 `GITHUB_TOKEN`。

## 6. Main CI

推送到 `main` 后运行比 PR 更完整的门禁。

必跑内容：

1. static
2. SwiftPM unit
3. Go unit
4. Xcode Debug build
5. UI smoke matrix
6. release smoke 双架构
7. CodeQL
8. artifact summary

Main CI 允许触发自动 release 检查。release 条件由 `release.yml` 内部判断，不由普通 CI job 决定。真正构建和发布前，release workflow 必须确认目标 commit 的 `ci-gate` 已成功。

## 7. Nightly CI

Nightly 用于承接高成本验证，避免 PR 反馈过慢。

Nightly 内容：

1. full regression
2. 完整 UI smoke matrix
3. coverage
4. release dry run 双架构
5. CodeQL
6. dependency freshness scan
7. flaky 分类 summary

Nightly 失败不应直接阻断普通 PR，但必须在仓库首页、issue 或通知渠道可见。连续失败需要归类到代码回归、测试不稳定、runner 环境、依赖环境四类。

## 8. Release 触发规则

Release workflow 支持两种入口。workflow 先不 checkout 目标代码，只用 GitHub API 解析目标 SHA，并用内联 GitHub API 逻辑验证目标 SHA 的 `ci-gate`。验证成功后，workflow 才 checkout 目标 commit 并执行 release 脚本。版本判断、tag 判断、build number 规则都由 `scripts/release/prepare.sh` 执行。`prepare` 输出 `should_release=true` 后才允许 build 和 publish。

第一种是 push 到 `main`。当 `Apps/VoidDisplay/VoidDisplay.xcodeproj/project.pbxproj` 中的版本字段变化时触发 release 判断。

第二种是 `workflow_dispatch`。人工输入 tag 和 target ref 后，workflow 校验输入 tag 是否等于 `v${MARKETING_VERSION}`。

自动发版规则如下：

1. 当前 `MARKETING_VERSION` 必须匹配 `MAJOR.MINOR.PATCH`。
2. 当前 `CURRENT_PROJECT_VERSION` 必须是正整数。
3. release tag 固定为 `v${MARKETING_VERSION}`。
4. 如果 `MARKETING_VERSION` 未变化，且对应 tag 已存在，跳过发布。
5. 如果 `MARKETING_VERSION` 变化，`CURRENT_PROJECT_VERSION` 必须大于上一个 `main` commit 中的值。
6. 如果目标 tag 已存在，tag 指向必须等于当前 release commit。
7. 如果目标 tag 已存在但指向其他 commit，立即失败。
8. 发布前必须构建并校验 `arm64` 和 `x86_64` 两套产物。

该规则让版本号成为唯一发布开关。合并只改 `CURRENT_PROJECT_VERSION` 不创建新 tag，除非对应 `MARKETING_VERSION` 的 tag 尚不存在。

## 9. Release 产物

每个架构生成以下文件：

1. `VoidDisplay-vX.Y.Z-arm64.dmg`
2. `VoidDisplay-vX.Y.Z-arm64.dmg.sha256`
3. `VoidDisplay-vX.Y.Z-arm64.dmg.spdx.json`
4. `VoidDisplay-vX.Y.Z-arm64.dmg.summary.json`
5. `VoidDisplay-vX.Y.Z-arm64.dmg.verify-summary.json`
6. `VoidDisplay-vX.Y.Z-intel64.dmg`
7. `VoidDisplay-vX.Y.Z-intel64.dmg.sha256`
8. `VoidDisplay-vX.Y.Z-intel64.dmg.spdx.json`
9. `VoidDisplay-vX.Y.Z-intel64.dmg.summary.json`
10. `VoidDisplay-vX.Y.Z-intel64.dmg.verify-summary.json`

Release job 对 DMG、checksum、SBOM 分别生成 GitHub artifact attestation。发布前下载 artifact 后再次运行 `scripts/release/verify.sh`，并用 `gh attestation verify` 验证 provenance。

GitHub Release body 必须包含：

1. 版本号
2. build number
3. target commit
4. 两个架构安装包
5. SHA256 校验方式
6. attestation 验证命令
7. 仅 ad hoc signing、非 Developer ID 签名、未公证、未 Apple 认证说明
8. 用户首次打开 app 的安全提示

## 10. 安全与供应链

Dependency Review 阻断 high 和 critical 漏洞。

Dependabot 覆盖 GitHub Actions、SwiftPM、Go modules。

CodeQL 覆盖 Swift 和 Go。

所有 workflow 使用最小权限。默认 `contents: read`，release 发布 job 才允许 `contents: write`。attestation job 才允许 `id-token: write` 和 `attestations: write`。release 前置 gate 只允许 `checks: read` 和 `statuses: read`。

所有 release 资产必须有 checksum、SBOM 和 attestation。

Secret scanning 和 push protection 通过仓库设置启用。workflow 不模拟 secret scanning。

## 11. 测试策略

PR 默认不跑完整 UI 和完整回归。PR 追求快速反馈和高信噪比。

SwiftPM unit 覆盖业务逻辑、数据模型、服务协调器、纯函数、状态机、持久化边界。

Xcode build 覆盖 app target、资源、SwiftPM 集成、project 设置、编译 warning。

UI smoke 覆盖关键用户路径和权限降级路径，必须使用 test mode、fixture、launch argument 注入，禁止引入会阻塞自动化的 macOS 隐私弹窗。

Full regression 放到 nightly 和人工调度。高风险改动可以由 PR 手动触发。

Release smoke 只验证发布链路必要条件，不承担完整产品行为验证。

## 12. Artifact 与 Summary

所有 CI job 都上传 `.ai-tmp/` 下的日志和 summary。

Unit summary 包含 Swift 测试数量、Go package 数量、失败分类。

Xcode summary 包含 action、configuration、destination、warning 扫描结果、result bundle 路径。

UI summary 包含 case name、attempt、status、reason、log file、xcresult。

Release summary 包含 tag、arch、label、bundle id、version、checksum、SBOM 路径、verify 结果。

CI summary 在 PR 上维护 sticky comment，并在 workflow summary 中显示相同信息。

## 13. Branch Protection

Branch protection 只要求 `ci-gate`。由于管理员可以绕过分支保护，release workflow 不信任分支保护本身，必须独立验证目标 SHA 的 `ci-gate` 状态。

`ci-gate` 根据改动范围解释哪些 job 必须成功。这样 workflow 内部可以扩展矩阵和拆分 job，同时保护规则保持稳定。

`ci-summary` 不参与阻断。summary 失败不应影响已通过的代码门禁，但需要在 workflow 日志中记录。

## 14. 本地命令

常用本地命令如下：

```bash
scripts/dev/bootstrap.sh
scripts/dev/doctor.sh
scripts/ci/static.sh
scripts/ci/unit.sh
scripts/ci/xcode.sh --action build --configuration Debug
scripts/ci/ui_smoke.sh --only-testing VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline
scripts/ci/release_smoke.sh --arch arm64 --label arm64
scripts/release/build.sh --tag vX.Y.Z --arch arm64 --label arm64
scripts/release/verify.sh --assets-dir .ai-tmp/release-arm64/release-assets --tag vX.Y.Z --label arm64 --arch arm64
```

本地命令和 CI 命令必须保持等价。新增 CI 能力时，优先新增或扩展脚本，再改 workflow 调度。

## 15. 推进顺序

第一阶段收敛脚本入口，完成 bootstrap、static、unit、xcode、ui smoke、release smoke、release build、release verify。

第二阶段改造 PR CI，建立 `ci-gate`、artifact summary、docs-only fast path。

第三阶段改造 release workflow，完成版本号触发、双架构 ad hoc DMG、checksum、SBOM、attestation、下载后 verify、GitHub Release 发布。

第四阶段补齐 nightly，加入 full regression、coverage、扩展 UI matrix、双架构 release dry run。

第五阶段补齐安全和维护机制，加入 Dependabot、CodeQL、dependency review、action pinning gate、文档和本地 doctor。

## 16. 完成标准

代码相关 PR 在 `ci-gate` 上稳定给出通过或失败结论。

文档-only PR 能快速完成。

UI 相关 PR 能跑最小 smoke matrix。

目标 `main` 的代码 PR 能覆盖 arm64 release smoke；main push、nightly 和 release workflow 能覆盖双架构 release smoke。

推送到 `main` 后，`MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION` 能自动驱动 release 判断。

Release 产物可通过 checksum、SBOM、attestation 和下载后 verify 追溯。

整个体系不依赖自托管 runner，不依赖 Apple Developer Program，不要求 Developer ID 签名或公证。
