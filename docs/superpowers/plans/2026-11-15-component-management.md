# Component Management Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 已部署系统可以按需增装、修复和恢复组件，无须重新初始化系统。
**Architecture:** 纯 Bash 组件计划器与独立执行器复用现有模块；Profile 保持兼容，操作状态位于 STATE_DIR。
**Tech Stack:** Bash、Python unittest、PTY、现有 ShellCheck/CI。
**Spec:** docs/superpowers/specs/2026-11-15-component-management.md

## Global Constraints

五种 Profile、已有入口与持久化配置保持兼容；不执行真实 VPS 操作；不新增框架依赖；不自动发布。

## Review Focus

外部服务不能被配置标记误接管；失败记录不能覆盖旧配置；网关迁移不改变已发布节点标识和地址；普通增装不调用 SSH/系统初始化；已确认计划与执行时配置不能发生竞争。

## Tasks

- [x] 1. lib/components.sh：组件查询、Profile 增量映射、依赖步骤计划；verify/tests/test_components.py 先验证失败，再实现所有 Profile 矩阵。
- [x] 2. lib/app/components.sh：锁、候选、确认、备份、执行/验收/恢复；行为测试模拟失败、重复执行、配置提交、外部服务和端口冲突。
- [x] 3. CLI、主菜单、完整部署互斥、兼容配置与节点地址；更新菜单 PTY 与安装入口检查。
- [ ] 4. 文档、完整自测和 ShellCheck；独立审查后修复，推送功能分支和 PR。

## Decisions / Results

- 使用当前 checkout 的独立分支 feat/component-management；无需另建 worktree。
- 使用已有模块的幂等性重试受影响步骤，不盲目跳过已完成但可能失效的依赖。

- 已独立审查并修复：公网地址验收、提交时配置竞争、混合监听归属、Docker 恢复切源。
- 补充防护：旧 Reality 独占方案不能把未知 1443 入站当作项目拥有；SQLite WAL 使用一致性快照。
