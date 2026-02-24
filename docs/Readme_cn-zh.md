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

### 👀 屏幕监视

在独立的浮动窗口中实时查看任意已连接的显示器。  
非常适合在不切换桌面的情况下关注副屏内容。

### 📡 局域网屏幕共享

通过 HTTP + MJPEG 将任意显示器共享到局域网。  
在同一网络的任何设备上——手机、平板或电脑——用浏览器打开链接即可观看，观看端无需安装任何应用。

## 📸 界面截图

![](./imgs/6.png)
![](./imgs/1.png)
![](./imgs/2.png)
![](./imgs/5.png)

## 💻 系统要求

- macOS（Apple Silicon，M1 或更新）

## 📥 安装

### 下载

前往 [Releases](../../releases) 页面获取最新版本。

### 从源码构建

1. 克隆本仓库。
2. 用 Xcode 26+ 打开 `VoidDisplay.xcodeproj`。
3. 构建并运行（⌘R）。

## 🚀 快速上手

### 创建虚拟显示器

1. 打开 VoidDisplay，进入 **虚拟显示器** 标签页。
2. 点击 **+** 按钮添加新的虚拟显示器。
3. 选择预设方案，或输入自定义的分辨率和刷新率。
4. 虚拟显示器会立即出现在 macOS 的显示器排列中。

### 监视屏幕

1. 进入 **屏幕监视** 标签页。
2. 选择你想要监视的显示器。
3. 系统会打开一个浮动窗口，实时显示该显示器的内容。

### 局域网共享屏幕

1. 进入 **屏幕共享** 标签页。
2. 点击想要共享的显示器旁边的 **共享** 按钮。
3. 应用会显示一个局域网地址（如 `http://192.168.x.x:8080/display`）。
4. 在同一网络的任何设备上，用浏览器打开该地址即可实时观看屏幕。

## ❓ 常见问题

**屏幕监视或屏幕共享中没有可选的显示器？**

> macOS 需要授予"屏幕录制"权限。前往 **系统设置 → 隐私与安全性 → 屏幕录制**，确保 VoidDisplay 已启用。如果在应用运行期间更改了权限，请完全退出应用后重新打开。

**从其他设备打不开共享页面？**

> 请确保你的 Mac 和观看设备在同一个局域网（Wi-Fi 或有线网络）。应用中显示的 URL 必须从其他设备可以访问。

**启动时虚拟显示器恢复失败？**

> 如果虚拟显示器恢复失败，虚拟显示器标签页会弹出提示。如果配置文件损坏，可以删除以下文件来重置：  
> `~/Library/Application Support/com.developerchen.voiddisplay/virtual-displays.json`

## 🛠️ 开发者

### 构建与测试

环境要求：Xcode 26+，macOS Apple Silicon。

```bash
# 运行单元测试（无需付费开发者证书）
xcodebuild -scheme VoidDisplay \
  -project VoidDisplay.xcodeproj \
  -configuration Debug test \
  -destination 'platform=macOS,arch=arm64'
```

### 调试入口

UI 入口：`HomeView` 包含四个标签页 — **显示器**、**虚拟显示器**、**屏幕监视**、**屏幕共享**。

常用调试文件：

| 功能区域 | 文件 |
|---------|------|
| 虚拟显示器 | `VirtualDisplayService.swift`、`CreateVirtualDisplayObjectView.swift`、`EditVirtualDisplayConfigView.swift` |
| 屏幕采集 | `CaptureChooseViewModel.swift`、`ScreenCaptureFunction.swift` |
| 局域网共享 | `ShareViewModel.swift`、`SharingService.swift`、`Features/Sharing/Web/WebServer.swift` |

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
