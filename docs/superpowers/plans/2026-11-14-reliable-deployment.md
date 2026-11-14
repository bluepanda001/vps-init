# Reliable deployment implementation plan

**Goal:** 保留功能与路径兼容性，拆分入口并修复恢复与交互缺陷。
**Architecture:** 保留组件目录，抽取 application orchestration、状态和配置；不增加运行框架。
**Tech Stack:** Bash + 现有 Python helpers。
**Spec:** ../../architecture-review.md

## Constraints / review focus

保持五个 Profile、SSH 防锁死、DD 显式确认、配置与节点身份。重点检查条件调用导致 errexit 失效、EOF、失败候选丢失、升级文件迁移、状态写入中断。

## Tasks

- [x] 拆分 app/display、app/menu、app/deploy 与 state/config；更新静态测试位置；运行原有测试。
- [x] 原子状态和配置、阶段记录、pending 恢复、菜单进程隔离；增加失败/取消/重复执行测试。
- [x] 更新安全替换、下载超时、输入校验；增加入口和升级模拟测试。
- [x] 完整自测、ShellCheck、独立审查、修复、提交与验收文档。

执行裁定：用户已明确持续实施，采用本会话直接实现；不额外等待设计确认。不跳过安全关键阶段，以模块幂等性复用已安装软件。此选择意味着恢复时仍会重新检查系统和服务。
