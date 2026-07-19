<div align="center">
  <img src="./imgs/AppIcon.png" width="150" height="150"/>
  <h1>虚幕（VoidDisplay）</h1>
  <p>在 Mac 上创建虚拟显示器、监视屏幕、局域网共享屏幕。</p>
  <a href="../Readme.md">English</a>
</div>

## ✨ 功能特色

### 🖥️ 虚拟显示器

创建自定义分辨率和刷新率的虚拟显示器。
适用于无头 Mac 部署、显示器测试，或者在没有物理显示器的情况下扩展你的工作空间。

### 👀 屏幕监听

在独立的浮动窗口中预览已启用的虚拟显示器。
无需切换 macOS 空间即可检查受管理显示器的内容。

### 📡 局域网屏幕共享

通过内置低延迟实时页面将已启用的虚拟显示器共享到局域网。
在可信局域网的设备上，用现代浏览器打开应用生成的 capability 保护 `/display` 链接即可观看。播放链路使用 WebRTC 媒体流，并通过 WebSocket 传输信令。

## 📸 界面截图

### 实时监听窗口

在独立窗口中查看显示器画面，支持适应窗口、1:1、全屏和光标控制。

![实时监听窗口](./imgs/live-monitor-window.png)

### 浏览器实时画面

在其他设备的浏览器中打开实时页面，观看共享的显示器画面。

![浏览器实时画面](./imgs/browser-live-view.png)

## 💻 系统要求

- macOS 15.6 或更高版本
- Intel 或 Apple Silicon Mac

## 📥 安装

### 下载

前往 [Releases](https://github.com/iamsyc/VoidDisplay/releases) 页面获取最新版本。

### 无签名版本首次启动说明

当前 release 构建仅使用 ad hoc signing，未使用 Apple Developer ID 签名，未公证，也未经过 Apple 认证。macOS 首次启动时可能出现以下提示：
- “无法验证开发者”
- “已损坏，无法打开”

如果遇到拦截：
1. 先在 Finder 中右键 `VoidDisplay.app` -> **打开**。
2. 仍被拦截时，执行：

```bash
xattr -dr com.apple.quarantine "/Applications/VoidDisplay.app"
```

### 从源码构建

1. 克隆本仓库。
2. 用 Xcode 26+ 打开 `VoidDisplay.xcworkspace`。
3. 构建并运行（⌘R）。

## 🚀 快速上手

### 创建虚拟显示器

1. 打开 VoidDisplay，默认进入 **显示器** 页面。
2. 点击 **添加虚拟显示器**。
3. 选择预设方案，或输入自定义的分辨率和刷新率。
4. 虚拟显示器会立即出现在 macOS 的显示器排列中。

### 监视屏幕

1. 在 **显示器** 页面启用需要监视的虚拟显示器。
2. 打开该显示器状态栏中的 **预览**。
3. 系统会打开浮动窗口显示实时内容。关闭预览或浮动窗口即可停止。

### 局域网共享屏幕

1. 在 **显示器** 页面打开 **共享设置**，按需调整性能模式或端口。
2. 启用目标虚拟显示器，再打开其状态栏中的 **局域网 Web 视图**。Web 服务会自动启动。
3. 点击 **复制链接**，或在显示器的更多菜单中选择 **打开共享页面**。
4. 在同一网络的现代浏览器中打开生成的地址，例如 `http://192.168.x.x:18090/display/1/{capability}`。

说明：
- 受保护页面路由是 `/display/{capability}` 和 `/display/{id}/{capability}`。
- 受保护 WebSocket 信令路由是 `/signal/{capability}` 和 `/signal/{id}/{capability}`。
- 每次重新开始分享都会轮换 capability，旧链接和无凭证链接会被拒绝。
- HTTP 与 WebSocket 流量没有加密。局域网分享只应在可信网络内使用，不要通过公网端口映射或隧道暴露。详见 [LAN Web View 安全契约](./lan-sharing-security.md)。

## ❓ 常见问题

**显示器缺失，或预览和局域网 Web 视图不可用？**

> macOS 需要授予"屏幕录制"权限。前往 **系统设置 → 隐私与安全性 → 屏幕录制**，确保 VoidDisplay 已启用。如果在应用运行期间更改了权限，请完全退出应用后重新打开。

**从其他设备打不开共享页面？**

> 请确保你的 Mac 和观看设备在同一个局域网（Wi-Fi 或有线网络）。应用中显示的 URL 必须从其他设备可以访问。

**页面能打开但不播放？**

> 实时页面要求浏览器支持 `WebSocket` 和 `RTCPeerConnection`。请在观看端使用较新的 Chromium 内核浏览器，或较新的 Safari/WebKit 版本。

**启动时虚拟显示器恢复失败？**

> 如果虚拟显示器恢复失败，显示器页面会弹出提示。如果配置文件损坏，可以删除以下文件来重置：
> `~/Library/Application Support/com.developerchen.voiddisplay/virtual-displays.json`

## 🛠️ 开发者

### 构建与测试

环境要求：Xcode 26+，macOS 15.6 或更高版本，Intel 或 Apple Silicon Mac。

```bash
# 安装并检查本地工具
scripts/dev/bootstrap.sh
scripts/dev/doctor.sh

# 静态检查、SwiftPM/JavaScript/Go 测试、Xcode 构建和 UI smoke
scripts/dev/validate.sh
```

Xcode 里的 `VoidDisplay` scheme 是 app build/run 和 UI test 入口。Cmd-U 不会执行 SwiftPM、浏览器 JavaScript 和 Go 测试门禁；完整单测覆盖使用 `scripts/dev/validate.sh` 或 `scripts/ci/unit.sh`。

完整项目回归入口（打开或合并 PR 前的较重 release 取向检查）：

```bash
scripts/ci/full_regression.sh \
  --destination "platform=macOS,arch=$(uname -m)"
```

该脚本会执行静态检查、全部单测、Xcode Debug 构建、UI 测试、稳定性检查和 arm64 release smoke，并在 `.ai-tmp/full-regression/` 写入日志。

CI 工作流细节与手动 UI smoke dispatch 入口见 `docs/testing/ci-workflows.md`。
[项目文档索引](./README.md)汇总了当前架构、测试策略和 LAN 安全契约。

### 调试入口

UI 入口：`HomeView` 包含**显示器**和**诊断**两个侧边栏入口。显示器页面统一承载虚拟显示器创建与管理、预览和局域网共享操作。

常用调试文件：

| 功能区域 | 文件 |
|---------|------|
| 虚拟显示器 | `Sources/VoidDisplayVirtualDisplay/Services/VirtualDisplayOrchestrator.swift`、`Sources/VoidDisplayVirtualDisplay/Views/CreateVirtualDisplayObjectView.swift`、`Sources/VoidDisplayVirtualDisplay/Views/EditVirtualDisplayConfigView.swift` |
| 屏幕采集 | `Sources/VoidDisplayApp/AppState/CaptureController.swift`、`Sources/VoidDisplayCapture/Services/DisplayCaptureRegistry.swift`、`Sources/VoidDisplayCapture/Services/DisplayCaptureSession.swift`、`Sources/VoidDisplayFoundation/RuntimeSupport/DisplayStartCoordinator.swift` |
| 局域网共享 | `Sources/VoidDisplayApp/AppState/SharingController.swift`、`Sources/VoidDisplaySharing/Services/DisplaySharingCoordinator.swift`、`Sources/VoidDisplaySharing/Services/SharingService.swift`、`Sources/VoidDisplaySharing/Web/WebServer.swift` |

统一日志（`Logger`，subsystem `com.developerchen.voiddisplay`）：

```bash
log stream --style compact --predicate 'subsystem == "com.developerchen.voiddisplay"'
```

## 📄 许可证

[Apache License 2.0](../LICENSE)

## 🤝 项目来源

本仓库基于 Phineas Guo 的原始项目长期维护而来：
[guoPhineas/FreelyDisplay](https://github.com/guoPhineas/FreelyDisplay)。

当前版本维护仓库为
[iamsyc/VoidDisplay](https://github.com/iamsyc/VoidDisplay)，功能演进、架构调整、测试体系和持续重构均在此持续进行，同时通过 Git 历史保留上游贡献记录。

## 🙏 致谢

本项目使用了私有的 `CGVirtualDisplay` 框架，详见 [LICENSE_CGVirtualDisplay](../LICENSE_CGVirtualDisplay)。
