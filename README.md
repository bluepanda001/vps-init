# VPS Init

用于 **Ubuntu 24.04 LTS VPS 自动化初始化、配置与验收**。

V1.2.4 的目标是把使用体验做成常见 GitHub 一键脚本：第一次只执行一条命令，然后通过中文菜单选择 Profile 和必要参数；以后直接输入 `vps-init` 管理。

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

首次进入向导时，最前面先询问是否重装系统：

```text
系统准备：
  1. 不重装，直接初始化当前系统
  2. 一键 DD / 重装 Ubuntu 24.04 Minimal（bin456789/reinstall）
```

选 2 时会调用我们之前使用过的 `bin456789/reinstall`，并固定到上游提交 `2bcbc96100fe733bf9a16d609f799246f62666e5`。DD 前会读取 root 的全部普通 ED25519 `authorized_keys`、去重，并把 `vps-main` 排在最前后通过重复的 `--ssh-key` 全部传给重装脚本，避免旧钥匙排在第一行时把统一主密钥丢掉；同时固定传入 `--user root`，避免上游脚本在无交互/管道执行时卡在用户名提示。它会在真正执行前再次要求输入大写 `DD`；重启前仍可用 `bash /root/reinstall.sh reset` 取消。OpenVZ/LXC 会直接拒绝执行。

如果执行 DD：当前系统只负责准备重装环境；`reboot` 后才开始清盘安装 Ubuntu 24.04 Minimal。安装完成重新 SSH 登录后，再运行同一条 VPS Init 一键命令，并选择“不重装”。

随后才进入安装方式与 Profile 选择：

```text
安装方式：
  1. 快速安装（推荐）
  2. 自定义安装

部署模式：
  1. Base Only
  2. Reality Only
  3. Nginx + Reality
  4. Lucky + Reality
```

快速安装只询问真正必要的信息；自定义安装才展开 URI Path、订阅端口、Reality Target、Docker 等参数。

## Profile

| Profile | 公网 443 | 域名 | 订阅 | Web 前端 |
|---|---|---|---|---|
| `base-only` | 不配置 | 不需要 | 无 | 无 |
| `reality-only` | 3x-ui 自带 Xray Reality | 不需要 | IP HTTPS | 无 |
| `nginx-reality` | Nginx Stream SNI 分流 | 必须 | Nginx HTTPS 反代 | Nginx 内部 TLS :8443 |
| `lucky-reality` | 3x-ui 自带 Xray Reality | 必须 | Lucky HTTPS 反代 | Reality fallback → Lucky :8443 |

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

标准订阅 URL 遇到 Clash/Mihomo User-Agent 会自动返回 YAML。3x-ui 的独立 Clash endpoint 保持 `/clash/`，避免与标准订阅路由发生冲突。

Reality UUID / SubID / Short ID / X25519 密钥都是**第一次随机生成**；重跑时读取现有状态并继续使用，不会每次变更。

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

## Lucky + Reality

不安装 Nginx：

```text
Internet :443
      ↓
3x-ui bundled Xray Reality
      ↓ unmatched normal HTTPS fallback
127.0.0.1:8443 Lucky
      ├─ xui.<domain>  -> 3x-ui
      └─ node.<domain> -> Subscription
```

Lucky 固定使用已校验的 `2.27.2` release；证书由 Cloudflare DNS-01 + Certbot 获取后同步进 Lucky。V1.2.4 起不再假定默认账号 `666/666`：服务启动后从 root-only 的 `/opt/lucky/lucky.conf` 读取当前实际管理账号，只在本机 loopback API 上完成认证并立即轮换/对齐到 vps-init 持久化的随机账号密码。

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

SSH 加固仍分两阶段：先把公钥安装到 `/root/.ssh/authorized_keys`，并启用 **root 公钥登录**，再要求保持当前会话、用第二个终端实际验证；确认成功后才关闭全局 PasswordAuthentication / KbdInteractive。最终基线是 `PermitRootLogin prohibit-password` + `PubkeyAuthentication yes`，即 root 可以用密钥直接登录，但不能用密码登录。

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
1. 一键部署 / 继续部署
2. 运行验收
3. 查看当前状态
4. 查看敏感凭据
5. 编辑配置
6. 更新 VPS Init
7. 查看服务日志
8. 重新运行安装向导
0. 退出
```

命令行也保留：

```bash
vps-init wizard
vps-init apply
vps-init verify
vps-init status
vps-init logs
vps-init update
```

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
- `ENABLE_CF_WS`、`ENABLE_CF_PREFERRED`、`ENABLE_CLOUDFLARESUB` 仍为预留扩展，默认关闭；误开会 fail-closed。
- 这是个人 VPS 实用安全基线，不是 CIS/企业合规基线。
