# 主屏分享链接规则

## 目标

这份文档定义屏幕共享链接的统一规则，尤其是主屏别名路由的语义边界。

## 统一规则

所有屏幕的真实共享目标都由 `shareID` 和当前分享会话的临时 `capability` 共同确定。

具体屏幕的标准地址格式：

- `/display/{shareID}/{capability}`
- `/signal/{shareID}/{capability}`

这条规则对主屏和非主屏完全一致。

## 主屏额外别名

主屏比其他屏幕多两个受保护的别名地址：

- `/display/{capability}`
- `/signal/{capability}`

这两个地址只表示“当前系统主屏”。

内部解析语义：

- `/display/{capability}` 映射到当前主屏对应的 `/display/{shareID}/{capability}`
- `/signal/{capability}` 映射到当前主屏对应的 `/signal/{shareID}/{capability}`

## 主屏切换语义

当系统当前主屏发生变化时：

- 受保护的主屏页面别名跟随新的主屏
- 受保护的主屏信令别名跟随新的主屏

具体屏幕地址不会因为主屏切换而变化：

- `/display/{shareID}/{capability}` 继续指向对应那块屏幕
- `/signal/{shareID}/{capability}` 继续指向对应那块屏幕

## 可用性边界

主屏别名只有在“当前系统主屏已存在于当前共享注册集”时才可用。

如果当前系统主屏不在注册集内：

- 主屏页面别名不可用
- 主屏信令别名不可用

此时具体屏幕地址是否可用，仍然只取决于对应 `shareID` 是否处于当前注册和路由状态。

## 前端展示规则

前端默认继续展示具体屏幕地址：

- `/display/{shareID}/{capability}`

主屏别名属于额外入口，不替代具体地址展示。无 capability 的旧地址不会解析到任何分享目标。

停止分享后，当前 capability 立即失效。再次开始分享会生成新 capability，因此同一 `shareID` 的旧链接也无法复用。

## 一句话总结

主屏没有单独的底层共享标识规则，只有额外的别名路由规则。
