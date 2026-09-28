# Release Notes

## v1.2.4

- 一键 DD 固定向 `bin456789/reinstall` 传入 `--user root`，避免无交互执行时停在 Username 提示并因 EOF 退出。
- Lucky 不再假定 `666/666`。启动后从 root-only 的 `/opt/lucky/lucky.conf` 读取实际当前管理员凭据，通过 loopback API 认证后立即轮换/对齐到 vps-init 持久化的随机凭据。
- Lucky 管理凭据接管逻辑保持幂等：若项目凭据已经可登录则不改；否则才使用本地配置中的当前凭据完成一次安全接管。
- 新增相应 self-test，防止 DD 用户名交互和 Lucky 默认口令假设回归。

## v1.2.3

- Bootstrap 的 Release 探测改为 fail-closed：只有 GitHub 明确返回“没有正式 Release”时才允许首次发布前源码回退；网络/HTTP/重定向异常不再被误判为“无 Release”。
- 一键 DD 会保留 root 的全部唯一 ED25519 公钥，并把 `vps-main` 优先传给固定版本的 `bin456789/reinstall`。
- Reality Only 的 short-lived IP 证书续期从 best-effort 改为强校验：确保 `cron` active、`acme.sh --install-cronjob` 成功，并确认 root crontab 中存在 `acme.sh --cron`。
- Release 打包与持久化复制排除 `__pycache__`、`*.pyc`、`*.pyo`。
- 3x-ui v3.8.5 的安装器/仓库脚本固定到 commit `7ef22f94c950ff09f0870e2295fa65ad5968742c`，release archive 同时使用项目内置 SHA256 再校验一次。
- 增加对应 self-test 回归检查，防止这些部署安全路径以后退化。

## v1.2.2

- SSH 管理统一为一把 `vps-main`：Windows 私钥固定建议为 `vps-main-ed25519`，所有普通 VPS 复用同一个公钥。
- Netcatty 统一为“每台 VPS 一个 Identity”：Identity 名称使用 VPS 名称，Username=`root`，Key=`vps-main`；Host 绑定 Identity，不再依赖“本地密钥”路径。
- SSH 向导不再默认按服务商/IP为每台 VPS 生成不同私钥；只有第一次才提示生成 `vps-main`。
- Stage 1 会明确启用 root 公钥登录，再要求第二终端验证；最终保持 `PermitRootLogin prohibit-password` + `PubkeyAuthentication yes`。
- 项目 SSH drop-in 提前为 `00-00-vps-init.conf`，并验证 `sshd -T` 实际值，避免 `00-hardening.conf` 等云镜像规则把 root/public-key 登录覆盖为 `no`。
- 部署后直接打印 Netcatty Keychain / Identity 配置提示。

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
