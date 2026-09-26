# Release Notes

## v1.2.0

- 中文向导第一步新增“一键 DD / 重装 Ubuntu 24.04 Minimal”。
- 使用此前采用的 `bin456789/reinstall`，固定到当前审阅提交 `2bcbc96100fe733bf9a16d609f799246f62666e5`。
- DD 前要求输入大写 `DD` 二次确认；OpenVZ/LXC 自动拒绝。
- 如当前 root 已有 ED25519 authorized key，重装时自动带入并保持当前 SSH 端口。
- 上游重装准备完成后可在 reboot 前执行 `bash /root/reinstall.sh reset` 取消。
- DD 完成后重新运行同一条 VPS Init 命令即可继续。

## v1.1.0

- 新增 GitHub 风格的一键 `install.sh` Bootstrap。
- Bootstrap 优先下载最新 GitHub Release + `SHA256SUMS`，失败才回退源码 tarball。
- 安装后提供全局 `vps-init` 命令。
- 新增中文交互向导：快速安装 / 自定义安装。
- 新增交互管理菜单：部署、验收、状态、凭据、配置、更新、日志。
- Fresh install 的 3x-ui Panel URI 默认固定为 `/zhg/`。
- Panel URI 与 Subscription URI 为独立设置，V1.1 默认都为 `/zhg/`；SubID 仍首次随机生成并保持。
- Clash/Mihomo 默认开启：Subscription、Routing、Auto Detect，UA `(?i)(clash|mihomo)`；JSON Subscription 默认关闭。
- 独立 Clash endpoint 保持 `/clash/`，避免与标准订阅路径发生路由冲突；Mihomo 仍可用标准订阅 URL 的 UA 自动识别获得 YAML。
- 订阅端口首次冲突时自动选择空闲端口并持久化。
- SSH 向导可复用已有 ED25519 authorized key，并能打印 Windows PowerShell 生成命令。
- 新增 `.github/workflows/release.yml`，tag 自动 self-test、打包并发布 Release。
- 保留 v1.0 的四种 Profile、幂等 state、root-only secrets 和安全边界。
