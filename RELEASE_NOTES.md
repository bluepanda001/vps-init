# Release Notes

## v1.3.1

- 修复一键 DD 交互：正常 `vps-init wizard` 不再先询问是否重装，DD 改为独立 `vps-init reinstall` 和主菜单入口；DD 完重新进系统后直接看到安装方式 / Profile。
- DD 密码改为隐藏输入；即使上游 `bin456789/reinstall` 输出摘要，也会在 vps-init 层统一把 Password/密码字段脱敏为 `[hidden]`。请求 reboot 不再使用特殊非零返回码触发全局 ERR trap。
- SSH 公钥向导明确显示 VPS 端公钥位置 `/root/.ssh/authorized_keys`；首次创建主密钥时同时显示 Windows 公钥文件位置。
- 保留并明确显示 `Base Only`，新增 `Lucky Web Only` Profile：Base + Docker Engine/Compose + Lucky + Cloudflare DNS + wildcard SSL，不安装 3x-ui、Xray、Reality、订阅或 CDN 节点。
- `Lucky Web Only` 中 Lucky 直接监听公网 443，不安装 Nginx Stream；自动创建 `lucky.<ROOT_DOMAIN>` 和 wildcard DNS，申请 `ROOT_DOMAIN + *.ROOT_DOMAIN` 证书并同步到 Lucky。
- `Lucky Web Only` 默认安装 Docker，Lucky 管理用户名/密码支持向导自定义；`vps-init info`、`gateway`、`secrets` 和完整 verify 均识别该 Profile。
- 新增验收：Docker active、Lucky active、443 由 Lucky 持有、wildcard 证书有效、本地 Lucky API 可用、`https://lucky.<domain>` 可通过本机 443/SNI 正常访问，并确认 3x-ui/Nginx 未误启动。

## v1.3.0

- 明确 Web Gateway 分工：不引入 Nginx Proxy Manager，也不新增 vps-init 自己的反向代理中心；系统 Nginx 仅负责公网 443 / SNI Stream 基础入口，应用反向代理默认交给 Lucky 图形界面维护。
- 安装向导将 `Lucky + Reality` 标记为推荐的域名方案，并说明其用途是“图形化 Web Gateway + Reality，共用公网 443”；`Nginx + Reality` 保留为轻量/高级、配置文件管理方案。
- 新增 `vps-init gateway` 和主菜单 “Web Gateway / Lucky”，可快速查看当前 Gateway、服务状态、Lucky 本地管理地址以及推荐的访问方式。
- Lucky 管理后台继续只监听 `127.0.0.1:16601`，不直接暴露公网；部署时生成可复制的 SSH 隧道命令并写入 root-only secrets。
- `vps-init secrets` 的 Lucky 分组新增 SSH 隧道命令；连接隧道后在本机打开 `http://127.0.0.1:16601` 即可管理反向代理。
- 修正 `lucky-reality` 的部署信息/日志展示：明确系统 Nginx Stream 仍是外层 443 入口，Reality 走 `127.0.0.1:1443`，普通 HTTPS 走 Lucky `127.0.0.1:8443`。
- v1.3.0 不包含应用安装模板。Docker/Compose/应用由用户自行安装和自定义，之后直接在 Lucky Web 服务中配置反向代理。

## v1.2.8

- 新增 `vps-init passwd` 凭据管理入口，可交互修改 / 重置 3x-ui 与 Lucky 的管理用户名和密码。
- 3x-ui 修改完成后会立即重启并验证本地 API，同时把新用户名、密码和 API Token 同步写入 root-only state / secrets。
- Lucky 优先使用当前已保存凭据修改；如果用户曾在网页里手工改过导致保存凭据失效，会使用 Lucky 官方本机恢复命令重置管理入口，再写入用户新设置的凭据。
- 主菜单新增“修改管理账号 / 密码”。也支持 `vps-init passwd xui` 和 `vps-init passwd lucky` 直接进入指定面板。
- 密码输入不回显，至少 8 个字符并要求二次确认；修改后再运行 `vps-init secrets` 会显示同步后的新密码。

## v1.2.7

- REALITY 安全加固：不再把 Cloudflare 共享 CDN 域名作为自动/手动 target；旧版本若已经使用此类高风险 target，重跑时会自动迁移到扫描出的安全候选。
- 为 REALITY 鉴权失败后的 fallback 流量加入 Xray 原生限速：默认 1 MiB 后开始限速，上传 64 KiB/s、下载 128 KiB/s，并保留有限 burst；合法 REALITY 客户端不受影响。
- 新增独立的 Clash/Mihomo 订阅地址并写入 root-only secrets，同时保留标准订阅 URL 和 /mihomo/ 明确端点；验收会真实请求独立 Clash 路径并确认返回 YAML。
- 安装向导新增 3x-ui 管理用户名/密码输入；Lucky Profile 同时新增 Lucky 用户名/密码输入。密码输入不回显、不写入普通 config.env；留空时保持现有凭据，新部署则自动随机生成。
- `vps-init secrets` 改为中文分组输出，按当前 Profile 展示 3x-ui、Lucky、订阅、Reality、CDN WS 和 API 信息；长链接单独换行。原始 KEY=VALUE 输出保留为 `vps-init secrets --raw`。
- 默认 Reality 候选改为 `dl.google.com,www.apple.com,www.google.com,github.io`，并新增 fallback 安全参数校验和验收。

## v1.2.6

- 新增真正可用的 Cloudflare CDN 备用节点：3x-ui 自动创建独立的 `VLESS + WebSocket` loopback 入站，`edge.<domain>` 自动写入 Cloudflare 橙云 DNS，公网仍复用 443。
- Nginx Stream 的 SNI 分流新增可扩展映射：Reality 继续走 `127.0.0.1:1443`，普通面板/订阅继续走 `8443`，CDN SNI 单独进入 `127.0.0.1:8444`，再按随机 WS Path 转发到 3x-ui 自带 Xray。
- 3x-ui Host 自动为 CDN 入站登记 `TLS + SNI + Host Header + WS Path` 公网参数，并与 Reality 共用同一个 SubID；Clash/Mihomo 标准订阅会同时下发 Reality 和 CDN WS 两个节点。
- CDN 验收不是只测 HTTP：会启动临时 Xray 客户端，经 `edge.<domain>:443 -> Cloudflare -> Nginx -> VLESS/WS` 建立真实代理，再通过 SOCKS 请求 Google 204；同时检查橙云 DNS、订阅参数、loopback listener 和 Nginx 8444。
- 域名 Profile 的快速安装默认启用 CDN WS 备用节点；自定义安装可显式关闭。手工配置仍通过 `ENABLE_CF_WS=true/false` 控制。
- 保留 `edge.<domain>/zhg/` 面板代理与 `/sub/` 订阅别名，避免新增 CDN 节点后破坏此前的 Cloudflare 安全访问入口。

## v1.2.5

- 在真实 Ubuntu 24.04 RackNerd VPS 上完成四种 Profile 的完整回归：`base-only`、`reality-only`、`nginx-reality`、`lucky-reality` 均通过部署与验收，并覆盖幂等重跑；域名方案还完成了冷启动后的再次验收。
- Reality 验收升级为真实端到端握手，并验证公网订阅、Mihomo/Clash YAML、订阅中公布的公网 Reality 端点以及公网 3x-ui 面板。
- Reality 入站支持受控 Profile 迁移，并通过 3x-ui Host 显式登记真实公网端点，避免订阅泄露 loopback/内部监听地址。
- Cloudflare Token 录入改为先验证 Zone 再落盘，支持账号级 Token，输入失败可重试，不会保存未验证凭据。
- 向导和 Profile 切换改为事务式：配置只在完整验收成功后持久化；失败迁移会自动回滚并能识别/清理上次失败留下的拓扑残留。
- 修复多处 `set -o pipefail` 下的 SSH/预检误判，并改进 DD 重启交接、向导返回路径和部署信息展示。
- Lucky 2.27.2 不再按旧版明文配置处理管理员信息；使用官方运行时重置命令恢复本机管理入口，再通过 loopback API 立即轮换为项目随机凭据，并适配当前 nonce/token、证书和 WebService API。
- 修正 `lucky-reality` 的 443 拓扑：不能依赖 REALITY 自身把普通 HTTPS fallback 到 Lucky；现统一使用 Nginx Stream `ssl_preread` 做最外层 SNI 分流，Reality 监听 `127.0.0.1:1443`，Lucky HTTPS 监听 `127.0.0.1:8443`。

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
