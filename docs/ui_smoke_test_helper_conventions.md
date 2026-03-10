# UI Smoke Test Helper 约定

> 更新日期：2026-03-10  
> 适用范围：`VoidDisplayUITests/Smoke`

## 目标

- 固定当前已经验证过的快路径写法。
- 降低后续新增 UI smoke 时回退到慢等待、重复启动、硬编码时序的概率。
- 让测试代码优先表达业务流程，等待和点击细节沉到公共 helper。

## 默认 helper

当前默认 helper 定义在 [SmokeTestHelpers.swift](/Users/syc/Project/VoidDisplay/VoidDisplayUITests/Smoke/SmokeTestHelpers.swift)。

- `smokeElement(_:identifier:)`
  说明：先绑定元素引用，后续重复使用，减少重复查询。
- `assertAllExist(_:identifiers:timeout:)`
  说明：适合页面初次进入后的基础骨架校验。
- `assertElementsExist(_:timeout:)`
  说明：适合页面切换后校验一组目标元素是否都已出现。
- `waitForCondition(timeout:pollInterval:condition:)`
  说明：适合等待可观察状态变化。
- `waitForDisappearance(of:timeout:)`
  说明：适合等待 sheet、progress、toast 一类元素消失。
- `tapFast(_:in:confirmationTimeout:fallbackTimeout:confirmation:)`
  说明：默认用于表单控件。先走坐标快点，命中失败再回退到 `hittable` 点击。
- `tapWhenHittable(_:in:timeout:)`
  说明：只在没有更轻路径时使用。
- `tapByCoordinate(_:timeout:requireExistenceCheck:)`
  说明：只用于测试专用入口、命中区域稳定但 `hittable` 判定偏慢的控件。

## 默认写法

- 进入页面后，先用 `smokeElement` 绑定后续会反复访问的节点。
- 页面 ready 校验优先使用 `assertElementsExist`。
- 表单里的 toggle、save、cancel 优先使用 `tapFast`。
- 等待状态变化优先使用 `waitForCondition` 或 `waitForDisappearance`。
- 只有在确实需要单点阻断时，再使用 `assertExists`。

## 建议模式

- 页面骨架：
  先 `assertAllExist`，再进入具体业务流。
- 页面切换：
  点击侧边栏后，使用 `assertElementsExist` 等目标区域出现。
- 表单重开：
  先缓存 `form`、`toggle`、`button` 元素，再复用同一组引用。
- 测试专用入口：
  允许 `tapByCoordinate`，前提是该入口只在 UI Test 模式下注入。
- 状态断言：
  优先断言可观察结果，例如 sheet 消失、计数变化、按钮出现、错误态出现。

## 禁止回退的写法

- 不要重新引入固定 `sleep` 等待。
- 不要在同一条 smoke 里重复冷启动同一场景，除非场景隔离要求无法绕开。
- 不要对同一元素重复做 `smokeElement(...).waitForExistence(...)` 查询链。
- 不要在普通轮询里默认调用 `app.activate()`。
- 不要把坐标点击扩散到普通业务控件，只保留给测试专用入口和已确认的热点瓶颈。

## 推荐模板

```swift
@MainActor
func testExampleSmoke() throws {
    let app = launchAppForSmoke(scenario: .baseline)
    let sidebar = smokeElement(app, identifier: "sidebar_virtual_display")
    let detail = smokeElement(app, identifier: "detail_virtual_display")
    let action = smokeElement(app, identifier: "virtual_display_open_edit_test_button")
    let sheet = smokeElement(app, identifier: "edit_virtual_display_form")

    assertAllExist(
        app,
        identifiers: ["home_sidebar", "sidebar_virtual_display"],
        timeout: 3
    )

    sidebar.tap()
    assertElementsExist([("detail_virtual_display", detail)], timeout: 1.2)

    tapByCoordinate(action, timeout: 1, requireExistenceCheck: false)
    assertElementsExist([("edit_virtual_display_form", sheet)], timeout: 1.2)
}
```

## 当前参考实现

- [HomeSmokeTests.swift](/Users/syc/Project/VoidDisplay/VoidDisplayUITests/Smoke/HomeSmokeTests.swift)

这份文件现在就是默认参考实现。新增 smoke 优先对齐这里的 helper 组合和等待策略。
