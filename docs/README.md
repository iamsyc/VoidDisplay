# 项目文档

`docs/` 只保留当前行为、稳定架构边界和可执行验证入口。已完成的实施计划、阶段记录、审计快照和一次性排障记录由 Git 历史保存，不继续作为现行文档维护。

## 用户文档

- [中文 README](../README.zh-CN.md)：安装、使用和常见问题。

## 安全文档

- [LAN Web View 安全契约](./security/lan-web-view.md)：访问凭证、路由、资源限制、诊断脱敏和威胁模型。

## 开发文档

- [当前架构](./architecture.md)：组件职责、控制平面、数据平面和依赖边界。
- [测试策略](./testing/testing-strategy.md)：测试分层、环境隔离和本地验证入口。
- [CI Workflows](./testing/ci-workflows.md)：远程门禁、工作流矩阵和发布验证。
- 根目录 [AGENTS.md](../AGENTS.md)：分支、交付、验证和自动化约束。

## 设计源文件

- [AppIcon PSD](./design/AppIcon/AppIcon_1024x1024.psd)：当前 Icon Composer 应用图标的可编辑源文件。运行时图标使用 `Apps/VoidDisplay/AppIcon.icon/Assets/AppIcon_1024x1024.png`。

## 依赖维护记录

- [WebRTC M147 Header Sources](../Vendor/WebRTCHeaders/M147/SOURCES.md)：二进制版本、校验值、头文件来源和重建步骤。该文件与 header overlay 放在一起，避免依赖升级时遗漏同步。

## 维护规则

1. 文档描述当前事实或长期约束，执行期进度放在 issue、PR 或任务工作区。
2. 路径、命令和工作流名称必须能在当前仓库中解析。
3. 验证日志、提交号、行数快照和阶段完成记录不作为长期文档正文。
4. 行为变化必须同步更新对应文档。安全边界、公开使用流程和验证入口需要在同一变更中保持一致。
5. 英文 README 与中文 README 共享同一套产品事实，功能、系统要求、安装流程和公开链接需要同步更新。
