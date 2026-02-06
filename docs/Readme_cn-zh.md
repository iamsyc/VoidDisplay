<div align="center">
  <img src="./imgs/AppIcon.png" width="150" height="150"/>
  <h1>随显（FreelyDisplay）</h1>
</div>

FreelyDisplay 是一个 macOS 应用，支持：
- 创建虚拟显示器，
- 在独立窗口监听本机屏幕，
- 通过局域网进行屏幕帧共享（HTTP + MJPEG）。

## 当前工程状态

项目已完成一轮服务化重构：
- `AppHelper` 作为组装与状态桥接层，
- 业务逻辑按领域拆分为独立 Service/ViewModel，
- 在无付费开发者证书环境下可稳定执行 `xcodebuild test`（单元测试）。

## 架构边界

核心模块：
- `FreelyDisplay/FreelyDisplayApp.swift`：应用入口与 `AppHelper` 组装。
- `FreelyDisplay/VirtualDisplayService.swift`：虚拟显示器生命周期、模式应用。
- `FreelyDisplay/VirtualDisplayPersistenceService.swift`：配置持久化与恢复边界。
- `FreelyDisplay/CaptureMonitoringService.swift`：屏幕监听会话管理。
- `FreelyDisplay/SharingService.swift`：共享状态机。
- `FreelyDisplay/WebServiceController.swift`：Web 服务启停管理。
- `FreelyDisplay/WebShare/WebServer.swift`：HTTP 连接与 MJPEG 推流。
- `FreelyDisplay/ShareViewModel.swift`、`FreelyDisplay/CaptureChooseViewModel.swift`：UI 编排层。
- `FreelyDisplay/AppObservability.swift`：统一日志与错误映射。

主要链路：
- 虚拟显示器：`VirtualDisplayView` -> `AppHelper` -> `VirtualDisplayService`
- 屏幕监听：`CaptureChoose` -> `CaptureDisplayView` -> `ScreenCaptureFunction`
- 局域网共享：`ShareView` -> `ShareViewModel` -> `SharingService` -> `WebServiceController` -> `WebServer`

## 构建与测试

环境要求：
- Xcode 26+（当前已在 Xcode 26.3 RC 验证），
- macOS Apple Silicon（当前本地目标：`platform=macOS,arch=arm64`）。

测试命令：

```bash
xcodebuild -scheme FreelyDisplay -project /Users/syc/Project/FreelyDisplay/FreelyDisplay.xcodeproj -configuration Debug test -destination 'platform=macOS,arch=arm64'
```

无付费证书说明：
- 单测流程不依赖付费 Apple Developer 账号；
- 使用本地签名（`Sign to Run Locally`）即可运行测试。

## 调试入口

UI 入口：
- `HomeView` 分为 `Screen`、`Virtual Display`、`Monitor Screen`、`Screen Sharing` 四块。

常用调试文件：
- 虚拟显示器创建/编辑问题：
  - `FreelyDisplay/CreatVirtualDisplayObjectView.swift`
  - `FreelyDisplay/EditVirtualDisplayConfigView.swift`
  - `FreelyDisplay/VirtualDisplayService.swift`
- 屏幕权限/采集问题：
  - `FreelyDisplay/CaptureChooseViewModel.swift`
  - `FreelyDisplay/ScreenCaptureFunction.swift`
- Web 共享/推流问题：
  - `FreelyDisplay/ShareViewModel.swift`
  - `FreelyDisplay/SharingService.swift`
  - `FreelyDisplay/WebShare/WebServer.swift`

日志体系：
- subsystem：`phineas.mac.FreelyDisplay`
- category：`virtual_display`、`capture`、`sharing`、`web`、`persistence`

示例命令：

```bash
log stream --style compact --predicate 'subsystem == "phineas.mac.FreelyDisplay"'
```

## 常见故障定位

1. 监听/共享列表没有可选屏幕
- 检查“屏幕录制权限”是否已授权；
- 权限变更后建议退出应用再重开。

2. `/stream` 返回 503
- 当前没有处于“正在共享”状态；
- 先在 `Screen Sharing` 页启动共享。

3. 打不开本机共享页面
- 确认 Mac 已连接局域网（Wi-Fi 或有线）；
- 当前接口优先级：`en0` -> `en1` -> `en2` -> `en3` -> `bridge0` -> `pdp_ip0`。

4. 启动时虚拟显示器恢复失败
- 在 `VirtualDisplayView` 的恢复失败提示中查看失败项；
- 如配置损坏，可删除：
  - `~/Library/Application Support/phineas.mac.FreelyDisplay/virtual-displays.json`

## 单测覆盖重点

`FreelyDisplayTests` 当前覆盖：
- 配置迁移与清洗，
- 串号冲突处理，
- 共享服务状态机行为，
- HTTP 解析与路由响应，
- LAN IPv4 选择策略。

## 界面截图

![](./imgs/6.png)
![](./imgs/1.png)
![](./imgs/2.png)
![](./imgs/5.png)
