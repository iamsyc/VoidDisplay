# LAN Web View 安全契约

状态：当前实现契约

## 访问凭证与路由

每次显示器开始分享时，VoidDisplay 使用系统安全随机源生成一个 256 bit 的临时访问凭证，并将其编码为 64 位十六进制 path component。

具体显示器地址：

- 页面：`/display/{shareID}/{capability}`
- 信令：`/signal/{shareID}/{capability}`

当前系统主屏别名：

- 页面：`/display/{capability}`
- 信令：`/signal/{capability}`

UI 只展示具体显示器页面地址。停止分享会立即撤销该凭证。再次开始分享会生成新凭证，旧链接无法复用。无凭证旧路由和错误凭证统一返回 `404`，路由不会借此暴露目标是否存在或是否正在分享。

路由只接受应用生成的精确原始路径。查询参数、尾斜杠、重复斜杠和其他规范化变体均返回 `404`。

## 请求与资源边界

- HTTP 入口只接受带完整 `\r\n\r\n` 终止符的 `HTTP/1.1` 请求头。请求行必须包含 method、path 和 version 三个字段，header 名必须合法且非空。畸形请求返回 `400`，非 GET 返回 `405`，超出请求头上限的连接直接关闭。
- HTTP 层只建模 method、path 和 headers，不接收或转发请求体。
- 页面通过一次 MainActor 授权解析完成主屏别名解析、恒定时间 capability 比较和活动 SignalSessionHub 获取。WebSocket 在路由决策时执行相同授权，并在 `101 Switching Protocols` 发送完成后、注册客户端前重新验证 capability 和 SignalSessionHub identity，避免停止或重新分享期间的授权竞态。
- WebSocket upgrade 要求 `Origin` 与请求 `Host` 完全同源。
- 页面响应禁止缓存和 Referrer 传播，并启用 MIME sniffing 与 frame embedding 防护。
- 每个分享目标最多接纳 16 个信令客户端。
- 每个客户端最多提交 3 次 offer。单个 offer SDP 最大 128 KiB。
- 每个客户端最多提交 64 条 ICE candidate，累计最大 128 KiB。单条 candidate 最大 4 KiB。
- Swift 信令入口负责每个浏览器客户端的精确配额。Go relay 保留 HTTP 请求体、房间数和连接数等进程级硬上限，避免维护两套相同的每客户端预算状态。
- relay 控制密钥通过标准输入注入，不进入进程参数。relay 进程拒绝非 loopback HTTP 监听地址，App 也拒绝非 loopback ready URL。控制 API 只接受 `X-Control-Token`，空密钥启动会失败。

## 诊断与导出边界

- 诊断事件写入、快照生成和支持包落盘前都执行脱敏。支持包导出器是最后一道强制边界，不信任调用方已经完成清洗。
- 64 位十六进制 capability、Bearer credential、命名 token/secret/password/capability、relay 控制密钥、IPv4、IPv6 和用户主目录前缀不会以原值写入支持包。
- `displayName`、`windowTitle`、`desktopContent`、`userText`、`shareID`、`viewerID` 和 URL 凭证字段按字段名整体清除。单段诊断文本限制为 16,384 个字符。
- 支持草稿与导出历史在持久化前清洗，加载旧记录时会迁移并重写其中残留的 capability、LAN 地址和凭证。
- 配置附件最多读取 2 MiB。无效 JSON 或超限文件只导出包含来源类型、原始字节数和原因码的脱敏占位对象。
- 每个支持包使用独立 report ID 生成文件名，同一秒重复导出不会覆盖已有包。压缩失败会删除 staging 和半成品，成功归档权限固定为当前用户读写。
- 支持包直接导出到本地 ZIP，manifest 不包含恒定的传输 capability 字段。

## 威胁模型

临时 capability 用于阻止未获得分享链接的普通局域网设备直接枚举或打开共享内容。链接本身是 bearer credential，持有完整链接的设备具备观看权限，因此不要把链接发送给不受信任的人。

当前 LAN Web View 使用明文 HTTP 和 WebSocket。它不抵御能够被动监听局域网流量、控制网关或执行中间人攻击的对手。只应在可信局域网内使用，不应通过端口映射、反向代理或公网隧道暴露。需要对不可信网络提供传输保密时，必须另行引入浏览器可验证的 TLS 身份与 HTTPS/WSS 部署方案。

VoidDisplay 不提供观看账号、访问密码、互联网中继、NAT 穿透、远程输入、剪贴板或浏览器控制能力。
