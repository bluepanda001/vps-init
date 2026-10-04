# VPS Init

用于 **Ubuntu 24.04 LTS VPS 自动化初始化、配置与验收**。

V1.3.6 是稳定性版本：优先修复 SSH 防锁机、Lucky 重跑保护、Docker 配置合并、Cloudflare Token/证书事务安全和 IP 证书身份校验；普通 `apply` 不再顺带执行完整系统升级。

## 一键安装

仓库发布后使用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bluepanda001/vps-init/main/install.sh)
```

也兼容：

```bash
curl -fsSL https://raw.githubusercontent.com/bluepanda001/vps-init/main/install.sh | bash
```

Bootstrap 会先通过 GitHub 的 `/releases/latest` 网页重定向判断是否存在正式 Release，再下载并校验 `SHA256SUMS`。**只有 GitHub 明确返回 404（仓库尚无正式 Release）时才允许首次发布前回退源码归档**；DNS/TLS/网络失败、403/429/5xx、异常重定向、Release 下载失败或 SHA256 校验失败都会直接停止，不会把“探测失败”误判成“没有 Release”。安装到 `/opt/vps-init`，并创建：

```text
/usr/local/bin/vps-init
```

首次没有配置时自动进入安装向导；以后直接：

```bash
vps-init
```

## 中文交互向导

正常运行 `vps-init wizard` **不再询问是否 DD**，直接进入安装方式和 Profile 选择。系统重装改为独立入口：

```bash
vps-init reinstall
```

主菜单也有“系统重装 / 一键 DD”。它使用固定提交的 `bin456789/reinstall`，真正清盘前必须输入大写 `DD`；DD 密码采用隐藏输入，并对上游输出再次统一脱敏，不在终端打印明文密码。若已有 ED25519 authorized key，会保留全部唯一公钥，并把 `vps-main` 优先传入。重启前仍可运行 `bash /root/reinstall.sh reset` 取消。

DD 完成重新 SSH 登录后，再执行 VPS Init 一键命令，会直接进入安装方式 / Profile，不会再次询问 DD。

安装方式与 Profile：

```text
安装方式：
  1. 快速安装（推荐）
  2. 自定义安装

部署模式：
  1. Base Only
  2. Lucky Web Only（Base + Docker + Lucky + 域名/SSL，无节点）
  3. Reality Only
  4. Lucky + Reality
  5. Nginx + Reality（轻量/高级）
```

快速安装只询问真正必要的信息；自定义安装才展开 URI Path、订阅端口、Reality Target、Docker 等参数。`Base Only` 仍然是纯基础初始化；如果完全不需要代理节点、只是想把 VPS 当 Docker/Web 服务器，则选 `Lucky Web Only`，Docker 默认开启，Lucky 用户名/密码可在部署阶段自定义。带 3x-ui 的 Profile 仍可自定义 3x-ui 管理凭据。所有密码输入均不回显。

### 重跑与已有配置保护

V1.3.6 起，普通 `vps-init apply` 以“尽量不破坏用户已有配置”为原则：

- SSH 第二终端验证前保留原有认证策略，并启用 10 分钟自动回滚；
- Lucky 只更新 vps-init 自己负责的子规则，用户自行添加的反代、Basic Auth、WAF 等保留；
- Docker `daemon.json` 使用 JSON 合并，不整份覆盖已有 `data-root`、镜像源、网络和 runtime；
- Cloudflare 旧 Token 在新 Token 验证成功前不会删除；
- Lucky 新证书先验证并成功上传，再清理旧证书；
- Reality Only 的旧 IP 证书必须同时匹配当前 IP 和私钥才会复用。

普通 `apply` 只确保依赖包存在，不再执行完整系统升级。需要完整升级时手动运行：

```bash
vps-init upgrade-system
```


## Profile

| Profile | 公网 443 | 域名 | 订阅 | Web 前端 |
|---|---|---|---|---|
| `base-only` | 不配置 | 不需要 | 无 | 无 |
| `lucky-web` | Lucky 直接监听 HTTPS :443 | 必须 | 无 | Lucky 图形化 Web Gateway + Docker；不安装节点 |
| `reality-only` | 3x-ui 自带 Xray Reality | 不需要 | IP HTTPS | 无 |
| `lucky-reality` | Nginx Stream SNI 分流 | 必须 | Lucky HTTPS 反代 | Nginx Stream → Reality :1443 / Lucky :8443（推荐 Web Gateway） |
| `nginx-reality` | Nginx Stream SNI 分流 | 必须 | Nginx HTTPS 反代 | Nginx 内部 TLS :8443（轻量/高级） |

3x-ui V1.2.3 固定使用 `v3.8.5`，安装器及随后下载的仓库脚本固定到该签名 tag 当前对应的 commit `7ef22f94c950ff09f0870e2295fa65ad5968742c`；release archive 除上游 sidecar 外还会再按项目内置 SHA256 校验。只使用 **3x-ui 自带 Xray**，不会安装第二套独立 Xray。

## 3x-ui / Subscription 默认值

面板与订阅 URI 是两个独立设置：

```text
Panel URI Path       /zhg/
Subscription URI    /zhg/（与 Panel URI 独立设置）
```

Clash/Mihomo 默认：

```text
Clash/Mihomo Subscription   ON
Routing                     ON
Auto Detect                 ON
User-Agent Regex            (?i)(clash|mihomo)
JSON Subscription           OFF
```

标准订阅 URL 遇到 Clash/Mihomo User-Agent 会自动返回 YAML；另外也会明确生成独立的 Clash/Mihomo 地址 `https://<host>/clash/<SubID>`，并保留 `/mihomo/<SubID>` 明确端点。`vps-init secrets` 会把标准订阅和这两条专用订阅分开显示。

Reality UUID / SubID / Short ID / X25519 密钥都是**第一次随机生成**；重跑时读取现有状态并继续使用，不会每次变更。

REALITY 的 `target` 需要额外注意：鉴权失败的连接会被 Xray 转发到 `target`。因此 V1.2.7 起自动候选不再使用 Cloudflare 共享 CDN 域名，并拒绝手动把 `cloudflare.com`、`cloudflare.net`、`workers.dev`、`pages.dev` 作为 target；旧部署若仍使用这类 target，重跑时会自动迁移到扫描出的安全候选。同时默认启用 Xray 原生 fallback 限速：首 1 MiB 后，上传 64 KiB/s、下载 128 KiB/s，并允许有限 burst。该限速只针对鉴权失败后的 fallback，不限制合法 REALITY 客户端。

## Reality Only

不需要域名。默认拓扑：

```text
VPS_IP:443   -> 3x-ui bundled Xray Reality
VPS_IP:2096  -> HTTPS Subscription
```

如果 2096 在首次部署时已经被占用，脚本会自动选择一个空闲端口并持久保存。

IP HTTPS 证书沿用 3x-ui v3.8.5 的 acme.sh short-lived 方案，80/tcp 用于 HTTP-01，但脚本直接调用 acme.sh，不再靠向 3x-ui 交互菜单连续喂回车。证书失败会停止，不降级为 HTTP；部署还会确保 `cron` 已安装并运行、安装 acme.sh cronjob，并从 root crontab 中确认 `acme.sh --cron` 真实存在，之后才报告“自动续期已启用”。

## Nginx + Reality

需要 Cloudflare 域名：

```text
Internet :443
      ↓
Nginx Stream ssl_preread
 ├─ Reality SNI -> 127.0.0.1:1443
 └─ normal TLS  -> 127.0.0.1:8443
                    ├─ xui.<domain>  -> 3x-ui
                    └─ node.<domain> -> Subscription
```

证书使用 Cloudflare DNS-01 + Certbot wildcard。Ubuntu 24.04 使用 `nginx` + `libnginx-mod-stream`；部署前会显式确认当前 Nginx 构建包含 `stream_ssl_preread` 支持，并在启动前执行 `nginx -t`。

## Lucky Web Only

用于“只做服务器，不需要代理节点”的 VPS：

```text
Base 初始化
├─ SSH / UFW / Fail2ban / BBR / Swap
├─ Docker Engine + Compose（默认）
├─ Cloudflare DNS
├─ Let's Encrypt wildcard SSL
│  ├─ <ROOT_DOMAIN>
│  └─ *.<ROOT_DOMAIN>
└─ Lucky
   ├─ 公网 HTTPS :443
   ├─ lucky.<ROOT_DOMAIN>/zhg 管理入口（默认安全入口 zhg）
   └─ 后续由用户自己添加 Docker/Web 服务反代

不会安装：
  3x-ui / Xray / Reality / Subscription / CDN WS
```

该 Profile 不需要 Nginx Stream，因为没有 Reality 与 HTTPS 争用 443；Lucky 直接监听公网 443。Cloudflare 会创建 `lucky.<ROOT_DOMAIN>` 以及 wildcard DNS 记录，证书自动同步进 Lucky。

Lucky 后台默认安全入口固定为：

```text
zhg
```

因此管理地址是：

```text
本地 / SSH 隧道：
http://127.0.0.1:16601/zhg

Lucky Web Only 公网管理：
https://lucky.<ROOT_DOMAIN>/zhg
```

脚本使用 Lucky 官方 `SetSafeURL` 写入该值，并在部署验收时读取 `BaseConfigure.SafeURL` 确认设置已真正生效。运行 `vps-init secrets`、`vps-init info` 或 `vps-init gateway` 都会显示这个安全入口和完整管理地址。

应用仍由用户自行安装。例如 Docker 端口建议只绑定 loopback：

```text
127.0.0.1:5700:5700
```

然后在 Lucky 中把 `ql.<domain>` 反代到 `http://127.0.0.1:5700`。

## Lucky + Reality

Lucky 负责 HTTPS/反代，Nginx 只作为最外层的轻量 Stream SNI 路由器：

```text
Internet :443
      ↓
Nginx Stream ssl_preread
 ├─ Reality SNI -> 127.0.0.1:1443  3x-ui bundled Xray Reality
 └─ normal TLS  -> 127.0.0.1:8443  Lucky
                    ├─ xui.<domain>  -> 3x-ui
                    └─ node.<domain> -> Subscription
```

这里不能依赖 REALITY 自己把普通 HTTPS 回落到 Lucky：REALITY 对未通过鉴权的连接会直接转发到它的 `target`，因此必须在 Xray 前面按 SNI 分流。Lucky 固定使用已校验的 `2.27.2` release；证书由 Cloudflare DNS-01 + Certbot 获取后同步进 Lucky。全新 Lucky 优先使用官方默认 `666/666` 完成首次本地登录，并立即通过 loopback API 轮换为 vps-init 持久化的管理账号；`-rResetUser` 仅作为旧安装凭据未知时的最后恢复手段。不会解析或修改加密的 `*.lkcf` 凭据字段。


### Lucky 作为默认 Web Gateway

V1.3.0 不再引入 Nginx Proxy Manager，也不再额外实现一套 vps-init 反向代理中心。职责固定为：

```text
公网 :443
   ↓
System Nginx Stream
   ├─ Reality SNI → Xray :1443
   └─ 普通 HTTPS  → Lucky :8443
                        ↓
                用户自己维护的 Web 反代
```

应用本身由用户自行安装，例如 Docker/Compose 可以完全自定义镜像、目录、环境变量和端口。推荐把应用宿主端口绑定到 loopback，例如：

```text
127.0.0.1:5700:5700
```

然后直接进入 Lucky 的 Web 服务页面，把域名反代到对应的本地端口。

Lucky 管理后台继续只监听本地端口，并默认使用安全入口：

```text
127.0.0.1:16601/zhg
```

不直接暴露公网。运行：

```bash
vps-init gateway
```

会显示可复制的 SSH 隧道命令；建立隧道后，本机浏览器访问：

```text
http://127.0.0.1:16601/zhg
```

用户名、密码以及隧道命令也会显示在：

```bash
vps-init secrets
```



## Cloudflare CDN WS 备用节点

域名 Profile 可启用 `ENABLE_CF_WS=true`。安装向导的快速模式默认开启，自定义模式可选择关闭。脚本会创建第二个 3x-ui 入站，使用 **VLESS + WebSocket**，仅监听 loopback；公网入口默认是 `edge.<ROOT_DOMAIN>`，Cloudflare DNS 会设置为橙云代理。

```text
Client
  ↓ TLS + WebSocket
edge.<domain>:443  (Cloudflare proxied)
  ↓
Cloudflare
  ↓
VPS public :443
  ↓ Nginx Stream SNI
127.0.0.1:8444  Nginx TLS
  ↓ random WS path
127.0.0.1:<random>  3x-ui bundled Xray VLESS/WS
```

Reality 节点仍使用 `node.<domain>:443` 的 DNS-only 入口，两者不会混淆：

```text
node.<domain>:443 -> Reality 直连（DNS only）
edge.<domain>:443 -> VLESS/WS/TLS via Cloudflare（橙云）
```

两个入站共用同一个 SubID。3x-ui Host 会为 CDN 入站写入公网 `TLS / SNI / Host Header / WS Path`，因此 Clash/Mihomo 的标准订阅会同时下发 Reality 和 CDN WS 两个节点。随机 WS Path 与 UUID 首次生成后持久化，幂等重跑不会无故改变。

验收会启动临时 Xray 客户端，通过 `edge.<domain>:443 -> Cloudflare -> Nginx -> VLESS/WS` 建立真实代理，并经本地 SOCKS 请求外网；不是只检查 DNS、端口或 HTTP 状态。


## Cloudflare Token

Token 不写进 `config.env`。域名 Profile 第一次部署时隐藏输入，保存到：

```text
/root/.secrets/cloudflare.ini
```

权限 `600`。建议 Token 只限制到目标 Zone，并至少具备 **Zone Read + DNS Write**。

## SSH / Netcatty 统一规范

脚本只接受 ED25519 公钥。V1.2.2 起默认采用“一把主密钥 + 每台 VPS 一个 Identity”的管理方式：

```text
Windows / Netcatty Keychain
└─ vps-main
   └─ 私钥文件：%USERPROFILE%\.ssh\vps-main-ed25519

Netcatty Identities
├─ RackNerd        -> root + vps-main
├─ DC2.LA.TRI      -> root + vps-main
├─ US.LA.TRI.Basic -> root + vps-main
└─ 新 VPS          -> root + vps-main
```

第一次没有主密钥时，在 Windows PowerShell 生成一次：

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\vps-main-ed25519" -C "vps-main"
Get-Content "$env:USERPROFILE\.ssh\vps-main-ed25519.pub" | Set-Clipboard
```

以后新 VPS **不再重新生成私钥**，始终粘贴同一个 `vps-main-ed25519.pub`。Netcatty 中把无 `.pub` 后缀的私钥导入 Keychain，Label 固定为 `vps-main`；然后每台 VPS 新建一个独立 Identity，Identity 名称建议直接使用 `SERVER_NAME`，用户名 `root`，密钥选择 `vps-main`。主机认证选择该 Identity，不再使用依赖 Windows 用户目录路径的“本地密钥”。

SSH 加固仍分两阶段：先把公钥安装到 `/root/.ssh/authorized_keys`，并启用 **root 公钥登录**，再要求保持当前会话、用第二个终端实际验证。V1.3.2 起这一步采用编号式原地循环：尚未测试、测试失败或输错选项都只停留在当前步骤，不会退出整个部署；只有明确选择“验证成功”后才关闭全局 PasswordAuthentication / KbdInteractive。最终基线是 `PermitRootLogin prohibit-password` + `PubkeyAuthentication yes`，即 root 可以用密钥直接登录，但不能用密码登录。

Ubuntu 24.04 的 `ssh.socket` 在修改端口时会执行 `daemon-reload` + 重启 socket，并用 `ss` 验证目标端口真的在监听。项目 SSH drop-in 使用 `00-00-vps-init.conf`，并验证 `sshd -T` 的实际值，避免云镜像里的 `00-hardening.conf` 等更早规则把 `PermitRootLogin` 或 `PubkeyAuthentication` 覆盖成 `no`。只要 SSH 端口和上次验证值不同，就强制重新做第二终端登录验证。

## 状态与防火墙安全

- `DEPLOYED_PROFILE` 只会在完整 `verify` 通过后写入；单独运行 preflight 或中途失败不会占住 Profile。
- `apply` 不再执行 `ufw --force reset`。项目只删除/重建带 `vps-init` 注释的规则，管理员手工添加的其他 UFW 放行规则会保留；默认入站/出站策略仍由项目设置。
- Reality API helper 不会把服务端 X25519 私钥写到 JSON 输出。

## 安装后的菜单

```bash
vps-init
```

```text
1. 核心部署 / 继续部署
2. 运行核心验收
3. 查看部署信息
4. 查看当前状态
5. 查看敏感凭据
6. 修改管理账号 / 密码
7. Web Gateway / Lucky
8. 编辑配置
9. 更新 VPS Init
10. 查看服务日志
11. 重新运行核心安装向导
0. 退出
```

命令行也保留：

```bash
vps-init wizard
vps-init apply
vps-init verify
vps-init status
vps-init secrets
vps-init secrets --raw
vps-init passwd
vps-init passwd xui
vps-init passwd lucky
vps-init gateway
vps-init logs
vps-init update
```

其中 `vps-init secrets` 默认按中文标题分组展示当前 Profile 相关的 3x-ui / Lucky、订阅、Reality、CDN WS 和 API 信息；长链接独立换行。需要兼容脚本处理时使用 `vps-init secrets --raw` 查看原始 `KEY=VALUE`。

如果之后需要修改管理账号/密码，推荐不要直接在网页里改，而是运行 `vps-init passwd`。3x-ui / Lucky 修改成功后会同时更新实际服务、`state.env` 和 `vps-init-secrets.txt`，因此随后再次执行 `vps-init secrets` 会显示新的同步值。即使 Lucky 网页密码已被手工改过而与保存状态不一致，`vps-init passwd lucky` 也可以通过官方本机恢复流程重新对齐。

## 重要文件

配置：

```text
/opt/vps-init/config.env      600
```

状态：

```text
/var/lib/vps-init/state.env  600
```

敏感凭据：

```text
/root/vps-init-secrets.txt   600
```

验收报告：

```text
/root/vps-init-report.txt
```

Cloudflare Token：

```text
/root/.secrets/cloudflare.ini 600
```

不要把 `vps-init-secrets.txt`、Cloudflare Token、私钥上传到 GitHub 或聊天。

## 更新

```bash
vps-init update
```

会根据 `/opt/vps-init/.source.env` 返回原 GitHub 仓库更新程序文件，同时保留本机 `config.env`、state 和凭据。更新时复用本机已经安装的 bootstrap；若仓库存在正式 Release，则 payload 必须通过 `SHA256SUMS` 校验。

## 发布 Release

仓库包含 `.github/workflows/release.yml`。推送标准 tag，或创建与 `VERSION` 一致的 `release/vX.Y.Z` 分支后，GitHub Actions 会执行 self-test，生成：

```text
vps-init-X.Y.Z.tar.gz
SHA256SUMS
```

并创建 GitHub Release。打包时显式排除 `__pycache__`、`*.pyc`、`*.pyo`。Bootstrap 优先使用该 Release 和 SHA256 校验；只有 GitHub 明确确认仓库没有任何正式 Release 时才允许首次发布前回退源码 tarball。

## 当前边界

- 正式支持 Ubuntu 24.04 LTS。
- 推荐在全新 VPS 使用。
- 同一 Profile 可以幂等重跑；不自动进行任意 Profile 之间的无损迁移。
- `ENABLE_CF_WS` 已正式支持域名 Profile；`ENABLE_CF_PREFERRED`、`ENABLE_CLOUDFLARESUB` 仍为预留扩展并保持 fail-closed。
- V1.3.0 不内置 NPM 或应用安装模板；Web/Docker 应用由用户自行安装，`lucky-reality` 作为推荐的图形化 Web Gateway。
- 这是个人 VPS 实用安全基线，不是 CIS/企业合规基线。
