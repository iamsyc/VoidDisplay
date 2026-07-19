<div align="center">
  <img src="./docs/imgs/AppIcon.png" width="150" height="150"/>
  <h1>虚幕（VoidDisplay）</h1>
  <p>在 Mac 上创建和预览虚拟显示器，并通过局域网共享画面。</p>
  <a href="./Readme.md">English</a>
</div>

## ✨ 功能特色

### 🖥️ 虚拟显示器

创建自定义分辨率和刷新率的虚拟显示器。
适用于无头 Mac 部署、显示器测试，或者在没有物理显示器的情况下扩展你的工作空间。

### 👀 预览

在独立的浮动窗口中预览已启用的虚拟显示器。
无需切换 macOS 空间即可检查受管理显示器的内容。

### 📡 局域网屏幕共享

通过内置低延迟实时页面将已启用的虚拟显示器共享到局域网。
在可信局域网的设备上，用现代浏览器打开应用生成且受 capability 保护的 `/display` 链接即可观看。播放链路使用 WebRTC 媒体流，并通过 WebSocket 传输信令。

## 💻 系统要求

- macOS 15.6 或更高版本
- Intel 或 Apple Silicon Mac

## 📥 安装

### 下载

前往 [Releases](https://github.com/iamsyc/VoidDisplay/releases) 页面获取最新版本。

### Ad Hoc 签名版本首次启动说明

当前 release 构建仅使用 ad hoc signing，未使用 Apple Developer ID 签名，未公证，也未经过 Apple 认证。macOS 首次启动时可能出现以下提示：

- “无法验证开发者”
- “已损坏，无法打开”

如果遇到拦截：

1. 在 Finder 中右键 `VoidDisplay.app`，选择**打开**。
2. 仍被拦截时，执行：

```bash
xattr -dr com.apple.quarantine "/Applications/VoidDisplay.app"
```

### 从源码构建

1. 克隆本仓库。
2. 用 Xcode 26.5 打开 `VoidDisplay.xcworkspace`。
3. 构建并运行（⌘R）。

## 🚀 快速上手

### 创建虚拟显示器

1. 打开 VoidDisplay，默认进入 **显示器** 页面。
2. 点击 **添加虚拟显示器**。
3. 选择预设方案，或输入自定义的分辨率和刷新率。
4. 虚拟显示器会立即出现在 macOS 的显示器排列中。

### 预览虚拟显示器

1. 在 **显示器** 页面启用需要预览的虚拟显示器。
2. 打开该显示器状态栏中的 **预览**。
3. 系统会打开浮动窗口显示实时内容。关闭预览或浮动窗口即可停止。

### 局域网共享屏幕

1. 在 **显示器** 页面打开 **共享设置**，按需调整性能模式或端口。
2. 启用目标虚拟显示器，再打开其状态栏中的 **局域网 Web 视图**。Web 服务会自动启动。
3. 点击 **复制链接**，或在显示器的更多菜单中选择 **打开共享页面**。
4. 在同一网络的现代浏览器中打开生成的地址，例如 `http://192.168.x.x:8089/display/1/{capability}`。

说明：

- 受保护页面路由是 `/display/{capability}` 和 `/display/{id}/{capability}`。
- 受保护 WebSocket 信令路由是 `/signal/{capability}` 和 `/signal/{id}/{capability}`。
- 每次重新开始分享都会轮换 capability，旧链接和无凭证链接会被拒绝。
- HTTP 与 WebSocket 流量没有加密。局域网分享只应在可信网络内使用，不要通过公网端口映射或隧道暴露。详见 [LAN Web View 安全契约](./docs/security/lan-web-view.md)。

## ❓ 常见问题

**显示器缺失，或预览和局域网 Web 视图不可用？**

> macOS 需要授予屏幕录制权限。前往 **系统设置 → 隐私与安全性 → 屏幕录制**，确保 VoidDisplay 已启用。如果在应用运行期间更改了权限，请完全退出应用后重新打开。

**从其他设备打不开共享页面？**

> 请确保你的 Mac 和观看设备在同一个局域网（Wi-Fi 或有线网络）。应用中显示的 URL 必须从其他设备可以访问。

**页面能打开但不播放？**

> 实时页面要求浏览器支持 `WebSocket` 和 `RTCPeerConnection`。请在观看端使用较新的 Chromium 内核浏览器，或较新的 Safari/WebKit 版本。

**启动时虚拟显示器恢复失败？**

> 如果虚拟显示器恢复失败，显示器页面会弹出提示。如果配置文件损坏，可以删除以下文件来重置：
> `~/Library/Application Support/com.developerchen.voiddisplay/virtual-displays.json`

## 🛠️ 开发

### 构建与测试

环境要求：Xcode 26.5、macOS 15.6 或更高版本，以及 Intel 或 Apple Silicon Mac。

```bash
# 安装并检查本地工具
scripts/dev/bootstrap.sh
scripts/dev/doctor.sh

# 运行标准本地验证门禁
scripts/dev/validate.sh
```

[项目文档索引](./docs/README.md)汇总了当前架构、测试策略、CI 与发布流程，以及 LAN 安全契约。

## 📄 许可证

[Apache License 2.0](./LICENSE)

## 🤝 项目来源

本仓库基于 Phineas Guo 的原始项目长期维护而来：
[guoPhineas/FreelyDisplay](https://github.com/guoPhineas/FreelyDisplay)。

当前版本维护仓库为
[iamsyc/VoidDisplay](https://github.com/iamsyc/VoidDisplay)，功能演进、架构调整、测试体系和持续重构均在此持续进行，同时通过 Git 历史保留上游贡献记录。

## 🙏 致谢

本项目使用了私有的 `CGVirtualDisplay` 框架，详见 [LICENSE_CGVirtualDisplay](./LICENSE_CGVirtualDisplay)。
