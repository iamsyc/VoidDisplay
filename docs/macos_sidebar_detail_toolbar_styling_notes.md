# macOS Sidebar / Detail / Toolbar 样式调整记录

> 适用范围：主窗口 `HomeView` 及其 detail 区域  
> Scope: Main app window `HomeView` and its detail area

## 1. 最终结论 / Final Takeaways

- 左侧 `sidebar` 继续使用系统标准实现：`NavigationSplitView + List(selection:) + .listStyle(.sidebar)`。  
  Keep the left `sidebar` on the system-standard path: `NavigationSplitView + List(selection:) + .listStyle(.sidebar)`.

- 主窗口 toolbar 使用系统 scene API：在 [VoidDisplayApp.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/App/VoidDisplayApp.swift#L31) 上配置 `.windowToolbarStyle(.unified(showsTitle: true))`。  
  Use the system scene API for the main window toolbar: configure `.windowToolbarStyle(.unified(showsTitle: true))` in [VoidDisplayApp.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/App/VoidDisplayApp.swift#L31).

- 右侧 `detail` 区不要再整块铺自定义背景。交给系统渲染时，toolbar 和内容区更容易看起来是一整块。  
  Do not paint a custom full-surface background over the right `detail` area. Letting the system render it makes the toolbar and content feel like one continuous surface.

- 当前可接受实现位于 [HomeView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/App/HomeView.swift#L24)。  
  The accepted implementation lives in [HomeView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/App/HomeView.swift#L24).

## 2. 这次踩到的坑 / Pitfalls We Hit

- 给 sidebar 手动加 `.scrollContentBackground(.hidden)` 和 `.background(.regularMaterial)` 会削弱系统原生侧栏观感。  
  Manually adding `.scrollContentBackground(.hidden)` and `.background(.regularMaterial)` to the sidebar weakens the native system sidebar look.

- `.windowToolbarStyle(.unified(showsTitle: false))` 会把当前激活 detail 的标题一起隐藏掉，左上角看不到当前页面名。  
  `.windowToolbarStyle(.unified(showsTitle: false))` hides the active detail title too, so the current page name disappears from the top-left.

- `.windowStyle(.hiddenTitleBar)` 在这个项目里会让 `HomeSmokeTests` 的可访问性稳定性变差，UI smoke 出现主入口 identifier 丢失。  
  `.windowStyle(.hiddenTitleBar)` reduced accessibility stability in this project and caused `HomeSmokeTests` to miss primary identifiers.

- 把自定义背景铺在 `NavigationStack` 或各个 detail 页根视图上，会让右侧 toolbar 和内容区看起来像两层不同表面，形成明显断层。  
  Painting a custom background on the `NavigationStack` or each detail root makes the right toolbar and content feel like two different surfaces, creating a visible seam.

- `.toolbarBackground(.clear, for: .windowToolbar)` 和 `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` 只能表达偏好，系统不一定完全按“同色整块”渲染。  
  `.toolbarBackground(.clear, for: .windowToolbar)` and `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` are only preferences. The system may still not render a perfectly unified surface.

- 想让主窗口材质和 titlebar 完全走系统行为时，额外的 `NSWindow` bridge、`NSVisualEffectView` 和自定义 window chrome 会偏离“通用做法”。  
  If the goal is to keep window material and titlebar fully system-driven, extra `NSWindow` bridges, `NSVisualEffectView`, and custom window chrome move away from the most general best-practice path.

- 2026-03 阶段 4 到 6 重构期间，曾把 `DisplayTopologyChangeCoordinator` 通过根层 `.environment(...)` 挂到主 `WindowGroup -> HomeView`。这没有直接改 toolbar 样式，却触发了 unified toolbar 下方分隔线回归。回退后横线消失。后续若要给主窗口根层追加 environment、scene modifier 或根容器装配改动，必须把它视为 toolbar/detail 样式风险项。  
  During the 2026-03 phase 4-6 refactor, `DisplayTopologyChangeCoordinator` was injected at the main `WindowGroup -> HomeView` root via `.environment(...)`. That did not directly change toolbar styling, but it brought back the separator under the unified toolbar. Removing that root injection cleared the line. Any future root-level environment, scene modifier, or root-container wiring change must be treated as a toolbar/detail styling risk.

## 3. 系统表现应该怎么理解 / How To Read the Native macOS Look

- `sidebar` 和 `detail` 有轻微材质差异是正常现象。  
  A subtle material difference between `sidebar` and `detail` is normal.

- 右侧 `toolbar` 和右侧内容区通常应该更接近同一整块表面。  
  The right `toolbar` and the right content area should usually feel like one continuous surface.

- System Settings 看起来更自然，是因为它把右侧标题区和内容区压成了同一个视觉表面；左侧 sidebar 依然有自己的层次。  
  System Settings looks more natural because the right title area and content area read as one visual surface; the left sidebar still keeps its own hierarchy.

- Apple 的一方应用会有更细的调校，但普通 SwiftUI App 依然可以通过系统 scene API 获得足够接近的结果。  
  Apple’s first-party apps likely have finer tuning, but a regular SwiftUI app can still get close by leaning on system scene APIs.

## 4. 当前推荐做法 / Recommended Pattern For Future Changes

- 保留 [HomeView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/App/HomeView.swift#L24) 里的 `NavigationSplitView` 和 `List.sidebar`。  
  Keep the `NavigationSplitView` and `List.sidebar` in [HomeView.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/App/HomeView.swift#L24).

- 保留 sidebar 宽度调整：`min: 180, ideal: 200, max: 240`。  
  Keep the sidebar width adjustment: `min: 180, ideal: 200, max: 240`.

- 保留主窗口 `.windowToolbarStyle(.unified(showsTitle: true))`。  
  Keep the main window `.windowToolbarStyle(.unified(showsTitle: true))`.

- 右侧 detail 顶层不要再使用统一的 `.appScreenBackground()` 一类修饰器。  
  Do not reintroduce a full-surface `.appScreenBackground()` style modifier at the top of the right detail area.

- 自定义背景只放在局部组件上，例如卡片、状态条、空状态面板。  
  Limit custom backgrounds to local components such as cards, status bars, and empty-state panels.

- 需要把额外协调器或服务传给 detail 页面时，优先使用显式参数传递，尽量不要给主 `WindowGroup` 或 `HomeView` 根层追加新的 `.environment(...)`。  
  When a coordinator or service must reach detail pages, prefer explicit parameter passing and avoid adding new `.environment(...)` injections at the main `WindowGroup` or `HomeView` root.

## 5. 这次最终保留和移除的内容 / What We Kept And Removed

- 保留：sidebar 结构、系统 sidebar toggle、detail 标题显示、统一 toolbar 风格。  
  Kept: sidebar structure, system sidebar toggle, detail title display, unified toolbar style.

- 移除：sidebar 手工材质背景、`showsTitle: false`、`hiddenTitleBar`、detail 根层自定义背景、window-level `NSWindow` bridge。  
  Removed: manual sidebar material background, `showsTitle: false`, `hiddenTitleBar`, detail-root custom background, window-level `NSWindow` bridge.

- `appScreenBackground()` 相关实现已经从 [AppUI.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Shared/UI/AppUI.swift) 清理掉，避免后续误用。  
  The `appScreenBackground()` implementation was removed from [AppUI.swift](/Users/syc/Project/VoidDisplay/VoidDisplay/Shared/UI/AppUI.swift) to prevent accidental reuse.

## 6. 验证方法 / Verification Checklist

- 构建：`xcodebuild -project VoidDisplay.xcodeproj -scheme VoidDisplay -configuration Debug -derivedDataPath .derivedData build`  
  Build: `xcodebuild -project VoidDisplay.xcodeproj -scheme VoidDisplay -configuration Debug -derivedDataPath .derivedData build`

- UI smoke：`xcodebuild -project VoidDisplay.xcodeproj -scheme VoidDisplay -configuration Debug -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:VoidDisplayUITests/HomeSmokeTests test`  
  UI smoke: `xcodebuild -project VoidDisplay.xcodeproj -scheme VoidDisplay -configuration Debug -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:VoidDisplayUITests/HomeSmokeTests test`

- 运行时 AX 树检查：确认 `AXToolbar` 下仍然存在系统的“隐藏边栏”按钮。  
  Runtime AX tree check: verify the system “hide sidebar” button still exists under `AXToolbar`.

- 人工视觉检查重点：  
  Manual visual review focus:
  - sidebar 和 detail 可以有轻微层次差  
    `sidebar` and `detail` may keep a subtle hierarchy difference
  - 右侧 toolbar 和右侧内容区不应再出现明显断层  
    the right toolbar and right content area should no longer show a strong seam
  - 左上角标题应显示当前激活页面名  
    the top-left title should show the active page name

## 7. 相关官方 API / Relevant Official APIs

- Apple: [windowToolbarStyle(_:)](https://developer.apple.com/documentation/swiftui/scene/windowtoolbarstyle(_:))
- Apple: [unified(showsTitle:)](https://developer.apple.com/documentation/swiftui/windowtoolbarstyle/unified(showstitle:)/)
- Apple: [hiddenTitleBar](https://developer.apple.com/documentation/swiftui/windowstyle/hiddentitlebar/)
- Apple: [toolbarBackground(_:for:)](https://developer.apple.com/documentation/swiftui/view/toolbarbackground(_:for:)-5ybst/)
- Apple: [toolbarBackgroundVisibility(_:for:)](https://developer.apple.com/documentation/swiftui/view/toolbarbackgroundvisibility(_:for:))

## 8. 后续再调 UI 时的快速判断规则 / Quick Rules For Future Iterations

- 如果问题出在 sidebar，先检查有没有手动覆盖系统 sidebar 背景。  
  If the issue is in the sidebar, first check whether the system sidebar background was manually overridden.

- 如果问题出在右侧标题消失，先检查 `showsTitle`。  
  If the issue is a missing right-side title, check `showsTitle` first.

- 如果问题出在右侧 toolbar 和内容区断层，先检查有没有给 detail 根层单独铺背景。  
  If the issue is a seam between the right toolbar and content, first check whether a custom background was added to the detail root.

- 如果某个窗口样式改动导致 UI smoke 主入口 identifier 消失，优先回退 scene-level 风格改动，再查业务视图。  
  If a window-style change causes UI smoke to lose primary identifiers, revert the scene-level styling first before debugging business views.

- 如果工具栏下方横线突然回归，优先检查最近是否给主 `WindowGroup`、`HomeView` 根层或 `NavigationSplitView` 外层追加了新的 environment 注入、scene modifier 或容器包装。  
  If the separator under the toolbar suddenly comes back, first inspect whether a new environment injection, scene modifier, or wrapper view was recently added around the main `WindowGroup`, the `HomeView` root, or the outer `NavigationSplitView`.
