# 测试分层约定

> 更新日期：2026-04-28
> 适用范围：`Tests/`、`UITests/VoidDisplayUITests`

## 目标

- 默认回归只保留对行为、状态、流程有约束力的测试。
- 纯渲染、不崩即通过的弱测试默认不新增。
- 真实环境依赖测试单独分层，避免污染默认回归。

## 分层规则

### 1. 默认回归测试

以下测试属于默认回归入口，可以稳定运行在普通开发机和 CI：

- 带明确行为断言的单元测试
- 带状态流转断言的集成测试
- 可控环境下的 UI smoke

当前代表实现：

- [HomeSmokeTests.swift](/Users/syc/Project/VoidDisplay/UITests/VoidDisplayUITests/Smoke/HomeSmokeTests.swift)
- [ShareViewBehaviorTests.swift](/Users/syc/Project/VoidDisplay/Tests/VoidDisplaySharingTests/Views/ShareViewBehaviorTests.swift)
- [EditVirtualDisplayWorkflowTests.swift](/Users/syc/Project/VoidDisplay/Tests/VoidDisplayVirtualDisplayTests/EditVirtualDisplayWorkflowTests.swift)
- [VirtualDisplayRowPresentationTests.swift](/Users/syc/Project/VoidDisplay/Tests/VoidDisplayVirtualDisplayTests/VirtualDisplayRowPresentationTests.swift)

### 2. 手工环境验证测试

依赖真实权限、真实网络、真实桌面环境的测试，不属于默认回归入口。

当前代表实现：

- [RealEnvironmentE2ETests.swift](/Users/syc/Project/VoidDisplay/UITests/VoidDisplayUITests/E2E/RealEnvironmentE2ETests.swift)

约定：

- 必须通过显式环境变量开启
- 默认 `xcodebuild test` 不应依赖它通过
- 失败时按环境问题或现场问题处理，不直接视为默认回归阻断

运行约定：

- `VOIDDISPLAY_RUN_REAL_ENV_E2E=1` 只负责开启 `RealEnvironmentE2ETests`，必须进入 UI test runner 进程。
- 直接在 shell 前缀设置 `VOIDDISPLAY_RUN_REAL_ENV_E2E=1 xcodebuild test ...` 可能只影响 `xcodebuild` 进程，不能作为可靠入口。
- 推荐先执行 `xcodebuild build-for-testing`，复制生成的 `.xctestrun`，再把 `VOIDDISPLAY_RUN_REAL_ENV_E2E=1` 写入 `VoidDisplayUITests` 的 `EnvironmentVariables` 与 `TestingEnvironmentVariables` 后使用 `xcodebuild test-without-building -xctestrun ...`。
- real E2E 启动 App 时使用 `VOIDDISPLAY_PERSISTENCE_MODE=test_isolated` 与 `VOIDDISPLAY_TEST_ISOLATION_ID` 做持久化隔离。
- real E2E 不设置 `VOIDDISPLAY_UI_TEST_MODE`，该变量只用于默认 UI smoke 的 fixture 场景。

推荐命令骨架：

```sh
DERIVED_DATA=.ai-tmp/real-e2e/DerivedData
PROJECT=Apps/VoidDisplay/VoidDisplay.xcodeproj

xcodebuild \
  -project "$PROJECT" \
  -scheme VoidDisplay \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  build-for-testing

cp "$DERIVED_DATA"/Build/Products/*.xctestrun \
  "$DERIVED_DATA"/Build/Products/VoidDisplay-real-e2e.xctestrun
```

然后编辑复制出的 `VoidDisplay-real-e2e.xctestrun`，在 `VoidDisplayUITests` 对应条目下同时写入：

```xml
<key>EnvironmentVariables</key>
<dict>
  <key>VOIDDISPLAY_RUN_REAL_ENV_E2E</key>
  <string>1</string>
</dict>
<key>TestingEnvironmentVariables</key>
<dict>
  <key>VOIDDISPLAY_RUN_REAL_ENV_E2E</key>
  <string>1</string>
</dict>
```

最后运行：

```sh
xcodebuild \
  test-without-building \
  -xctestrun "$DERIVED_DATA"/Build/Products/VoidDisplay-real-e2e.xctestrun \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:VoidDisplayUITests/RealEnvironmentE2ETests
```

## 弱测试判定标准

满足以下任一条件，默认视为低价值测试：

- 只有 `render(view)` 或 `render(row)`，没有任何行为、状态、文本、元素存在断言
- 只能证明 “body 不崩”
- 已经有更强的 workflow、behavior、integration、UI smoke 覆盖同一场景
- 与默认 UI smoke 的起始页检查高度重复，只提供更少信息

## 默认做法

- 优先保留强测试，删除弱测试
- 优先写业务断言，不写纯渲染断言
- UI smoke 默认使用 [ui_smoke_test_helper_conventions.md](/Users/syc/Project/VoidDisplay/docs/ui_smoke_test_helper_conventions.md) 里的 helper 组合
- 新增 UI smoke 时，优先复用已有测试专用入口和快路径 helper
- 视图层大文件默认通过 workflow、controller、behavior、UI smoke 保护，不把 render-only 覆盖率当硬门槛

## 不再新增的测试类型

- 纯 `render(view)` 的 view body smoke
- 纯 `render(row)` 的 row body smoke
- 与现有 `HomeSmokeTests` baseline 启动校验重复的模板启动测试

## 新增测试的推荐方向

- workflow 层：验证输入到输出、分支选择、错误态
- controller 层：验证状态同步、副作用、依赖协作
- integration 层：验证关键链路协作，不依赖真实环境
- UI smoke 层：验证用户可观察结果，不依赖硬编码延迟
