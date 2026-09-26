# PLAN.md — VPS Init V1.1

用途：用于 VPS 自动化初始化、配置与验收。

## V1.1 范围

目标系统为 Ubuntu 24.04 LTS。默认假设是全新 VPS；如果目标 Profile 所需的 3x-ui、Nginx 或 Lucky 已经存在，但 `/var/lib/vps-init/state.env` 不存在，脚本要求交互确认接管，非交互场景 fail-closed。

项目只使用 3x-ui 自带 Xray，不单独安装 Xray。公开订阅只允许 HTTPS。核心 Profile 不依赖 Docker、Cloudflare CDN/WS、优选 IP/域名或 CloudflareSub。

## Phase -10 — Bootstrap / Wizard

GitHub `install.sh` 负责从最新 Release 下载归档并校验 `SHA256SUMS`，安装到 `/opt/vps-init`，创建 `/usr/local/bin/vps-init`。首次进入中文向导；后续直接 `vps-init` 打开管理菜单。向导支持快速安装与自定义安装。

## Phase 00 — Preflight

检查 root、Ubuntu 24.04、公网 IPv4/IPv6、默认网卡、CPU/内存/磁盘、当前监听端口、已有关键服务与端口冲突。默认网卡从路由自动识别，不写死 `eth0`。创建时间戳备份目录，但不修改 netplan/interfaces。

## Phase 10 — System Base

等待 apt/dpkg 锁，执行更新，安装基础工具，设置 UTC，启用 unattended-upgrades。Swap 根据内存自动创建；小内存 VPS 默认 2 GiB。通过独立 sysctl drop-in 设置 `fq + bbr` 与 `vm.swappiness=20`。

## Phase 20 — SSH Transaction

只接受 `ssh-ed25519` 公钥。若未提供，打印 Windows PowerShell 生成/复制公钥命令并退出。写入 `/root/.ssh/authorized_keys` 后，先保持密码登录；用户在第二个终端验证密钥成功后，才把 `PasswordAuthentication` 改为 `no`。如果 SSH 端口变化且现有 UFW 已开启，先放行新端口再 reload sshd。

## Phase 30 — Firewall / Fail2ban

UFW 默认 deny incoming / allow outgoing。按 Profile 放行最小端口。Fail2ban SSH 参数固定为 `findtime=10m`、`maxretry=15`、`bantime=1h`。

## Phase 40 — 3x-ui

除 `base-only` 外安装官方 3x-ui v3.8.5，使用官方非交互安装路径，不安装独立 Xray。管理面板固定 loopback；端口、账号、密码随机生成。Fresh install 的 Base Path 默认 `/zhg/`，已有 state 则保持原值。创建 root-only API Token 供本机自动化使用，并确认 Xray 二进制来自 `/usr/local/x-ui/bin/`。

## Phase 50 — DNS / TLS

`reality-only` 直接调用 3x-ui 管理脚本自带的 IP short-lived certificate 流程：Let's Encrypt + HTTP-01 + 80/tcp，证书安装到 `/root/cert/ip`，续期 reload x-ui。失败时停止，不降级 HTTP。

`nginx-reality` / `lucky-reality` 验证 Cloudflare Token，找到 Active Zone，upsert 面板域名与节点域名 DNS-only A 记录；Certbot 使用 Cloudflare DNS-01 签发根域名 + wildcard 证书。`LE_EMAIL` 留空时使用无邮箱 ACME 注册，不伪造邮箱。

## Phase 60 — Subscription / Reality

订阅默认开启。`reality-only` 默认公开 2096 + IP TLS；端口首次冲突会自动换到空闲端口并持久化。域名 Profile 的订阅后端只绑定 loopback，公网 TLS 由 Nginx/Lucky 终止。标准订阅 Path 与 Panel Path 独立配置，V1.1 默认同为 `/zhg/`；Clash/Mihomo Subscription、Routing、Auto Detect 默认开启，UA regex 固定 `(?i)(clash|mihomo)`，JSON Subscription 默认关闭。独立 Clash path 保持 `/clash/`，避免与标准订阅路由冲突。

Reality Target `auto` 调 3x-ui `/panel/api/server/scanRealityTargets` 检测小候选列表；不做大范围扫描。首次部署生成 UUID、SubID、X25519、Short ID，后续重跑从现有入站恢复并保持这些标识不变；创建 VLESS TCP/Reality + `xtls-rprx-vision`。`nginx-reality` 监听 `127.0.0.1:1443`；其他 Reality Profile 监听 `0.0.0.0:443`。`lucky-reality` 为 Reality 配置 fallback `127.0.0.1:8443`。

## Phase 70 — Frontend

`nginx-reality`：Nginx Stream 公开 443，按 Reality SNI 转发到 1443，其他 TLS 转发到 8443；8443 上分别按 `xui.<domain>` 与 `node.<domain>` 反代面板和订阅，未知 Host 显示最小 landing page。

`lucky-reality`：不安装 Nginx。Lucky v2.27.2 监听 `127.0.0.1:8443` TLS，wildcard 证书由项目导入；两个 Host 规则分别反代 3x-ui 和订阅，默认反代本机 landing page。公网普通 HTTPS 先进入 Reality 443，再通过 VLESS fallback 进入 Lucky 8443。

## Phase 80 — Certificate Renewal

Nginx Profile 的 Certbot deploy hook 执行 `nginx -t && systemctl reload nginx`。Lucky Profile 的 hook 重新把 Certbot 证书导入 Lucky 并重启 Lucky，使 TLS listener 使用新证书。

## Phase 90 — Optional

Docker 使用官方仓库，开启有界 json-file 日志。CF WS/CDN、优选、CloudflareSub 在 V1 中保留模块位置但默认不自动部署；打开时 fail-closed，避免未经验证的功能混入核心链。

## Phase 99 — Verify

检查 sshd 有效配置、UFW、Fail2ban、unattended-upgrades、BBR/fq、Swap、关键服务、监听端口、证书有效期、3x-ui/Xray 来源、Nginx syntax 或 Lucky 8443。生成 `/root/vps-init-report.txt`，不记录密码、Token 或 Reality 私钥。

敏感凭据统一保存在 `/root/vps-init-secrets.txt`（600）。运行状态保存在 `/var/lib/vps-init/state.env`（600）。修改前的文件进入 `/var/backups/vps-init/<UTC时间戳>/`。

## 错误策略

任何核心步骤失败立即退出；不通过 `|| true` 掩盖关键错误。SSH 密钥未验证不关闭密码登录；公网 TLS 签发失败不开放 HTTP 订阅；未知现有服务不自动覆盖；Cloudflare Token 不写进用户配置；不会自动修复 `systemd-networkd-wait-online` 之类与业务无关的告警。
