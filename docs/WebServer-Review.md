# WebServer.swift 代码评审

> 评审日期：2026-03-02  
> 文件路径：`VoidDisplay/Features/Sharing/Web/WebServer.swift`（535 行）

---

## ✅ 优点

### 1. 架构设计清晰
职责分离良好：HTTP 解析 (`HttpHelper`)、路由决策 (`WebRequestHandler`)、WebSocket 帧编解码 (`LiveSocketFrameCodec`)、连接错误分类 (`ConnectionErrorClassifier`)、请求累积 (`HTTPRequestAccumulator`) 各自独立。`WebServer` 本身只负责编排。

### 2. 并发安全
- `@MainActor` 隔离整个类，所有 `NWConnection` 回调通过 `Task { @MainActor in }` 跳回主 actor
- `activeConnections`、`signalBuffersByConnectionKey` 等可变状态访问线程安全

### 3. 生命周期管理完善
- `CheckedContinuation` + 超时的启动模式优雅
- `withTaskCancellationHandler` 正确处理外部取消
- `completeStartupWaiter` 有防重入保护
- `notifyListenerStoppedIfNeeded` 防止重复通知

### 4. 安全与健壮性
- `maxRequestBytes` / `maxSignalBufferBytes` 防止内存耗尽攻击
- WebSocket 升级严格校验 `Connection`、`Upgrade`、`Sec-WebSocket-Version`、`Sec-WebSocket-Key`
- 收到 binary 帧时主动拒绝并关闭

### 5. 内存管理
- 所有闭包使用 `[weak self]` 避免循环引用

---

## ⚠️ 可改进之处

### 1. `startSignalReceiveLoop` 递归存在竞态风险（中优先级）

```swift
// 当前代码：递归前未检查连接是否仍活跃
self.startSignalReceiveLoop(on: connection, target: target)
```

如果连接在 `Task { @MainActor }` 排队期间已被 `removeSignalClient` 移除，接收循环仍会重启。

**建议**：递归前增加 guard：
```swift
guard self.activeConnections[key] != nil else { return }
self.startSignalReceiveLoop(on: connection, target: target)
```

### 2. Close 帧处理未显式清理状态（中优先级）

收到 `.close` 帧后回发 Close 再 `cancel()`，但未调用 `removeSignalClient` 清理 `activeConnections`。虽然 `cancel()` 最终触发 `handleConnectionState(.cancelled)` 间接清理，但清理完成前 `activeStreamClientCount` 返回值不准确。

**建议**：与 oversized buffer 的处理保持一致，在 completion 中显式调用 `removeSignalClient`。

### 3. `newConnectionHandler` 闭包未标 `@Sendable`（低优先级）

闭包在 `networkQueue` 上调用，在 Swift 6 strict concurrency 下可能产生 warning。

### 4. Ping/Pong 应答无错误处理（低优先级）

```swift
case .ping(let payload):
    connection.send(content: encodeWebSocketPongFrame(payload),
                    completion: .contentProcessed { _ in })  // 错误被静默忽略
```

**建议**：至少记录一条 `.debug` 日志。

### 5. WebSocket 升级日志过于详细（低优先级）

第 370–381 行打印了完整的 key、accept value、response header，生产环境中可能冗长。建议降级为 `.debug`。

### 6. `init` 中进行 I/O 和副作用（可测试性）

构造函数中读文件、创建 `NWListener` 并设置 handlers，不利于单元测试。可考虑通过依赖注入传入 `displayPageTemplate` 和 listener。

### 7. 缺少 `deinit` 安全网（低优先级）

未显式调用 `stopListener()` 就释放实例时，`NWListener` 和活跃连接不会被主动清理。可在 `deinit` 中调用 `listener?.cancel()` 作为兜底。

---

## 📊 评分总结

| 维度 | 评分 | 说明 |
|------|------|------|
| **架构** | ⭐⭐⭐⭐⭐ | 职责分离清晰，模块化好 |
| **并发安全** | ⭐⭐⭐⭐ | `@MainActor` 策略正确，个别边界可强化 |
| **错误处理** | ⭐⭐⭐⭐ | 大部分路径覆盖，ping/pong 和 close 可完善 |
| **资源管理** | ⭐⭐⭐½ | 缺少 `deinit`，close 帧清理路径间接 |
| **可测试性** | ⭐⭐⭐ | init 中有 I/O 和副作用 |
| **日志** | ⭐⭐⭐⭐ | 全面，部分级别可调整 |
| **Swift 6 兼容** | ⭐⭐⭐⭐ | 基本兼容，个别闭包标注可完善 |

**总体：质量较高的生产级实现**。核心逻辑正确且健壮，改进点多属"从好到更好"的优化。最值得优先处理的是**第 1 点（接收循环 guard）**和**第 2 点（close 帧清理）**。
