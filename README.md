# VPS Init

用于 **Ubuntu 24.04 LTS VPS 自动化初始化、配置与验收**。

V1.1 的目标是把使用体验做成常见 GitHub 一键脚本：第一次只执行一条命令，然后通过中文菜单选择 Profile 和必要参数；以后直接输入 `vps-init` 管理。

## 一键安装

仓库发布后使用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bluepanda001/vps-init/main/install.sh)
```

也兼容：

```bash
curl -fsSL https://raw.githubusercontent.com/bluepanda001/vps-init/main/install.sh | bash
```

Bootstrap 会优先下载 GitHub 最新 Release、校验 `SHA256SUMS`；如果仓库还没有 Release，则自动回退下载 `main` 源码归档。因此新仓库第一次发布后，一键命令也能立即使用。安装到 `/opt/vps-init`，并创建：

```text
/usr/local/bin/vps-init
```

首次没有配置时自动进入安装向导；以后直接：

```bash
vps-init
```

## 中文交互向导

首次向导先选择：

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

3x-ui V1.1 固定使用 `v3.8.5`，只使用 **3x-ui 自带 Xray**，不会安装第二套独立 Xray。

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

IP HTTPS 证书使用 3x-ui 自己的 `Get SSL for IP Address` / acme.sh 流程，80/tcp 用于 HTTP-01。证书失败会停止，不降级为 HTTP。

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

证书使用 Cloudflare DNS-01 + Certbot wildcard。

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

Lucky 固定使用已校验的 `2.27.2` release；证书由 Cloudflare DNS-01 + Certbot 获取后同步进 Lucky。

## Cloudflare Token

Token 不写进 `config.env`。域名 Profile 第一次部署时隐藏输入，保存到：

```text
/root/.secrets/cloudflare.ini
```

权限 `600`。建议 Token 只限制到目标 Zone，并至少具备 **Zone Read + DNS Write**。

## SSH

脚本只接受 ED25519 公钥。向导会优先检测现有 `/root/.ssh/authorized_keys`；如果没有，可选择粘贴公钥或让脚本显示 Windows PowerShell 生成命令。

SSH 加固分两阶段：先安装公钥并保留当前认证策略，再要求用第二个终端实际验证；只有确认成功后才关闭密码/KbdInteractive root 登录。

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

会根据 `/opt/vps-init/.source.env` 返回原 GitHub 仓库更新程序文件，同时保留本机 `config.env`、state 和凭据。

## 发布 Release

仓库包含 `.github/workflows/release.yml`。推送 `v1.1.0` 这样的 tag 后，GitHub Actions 会执行 self-test，生成：

```text
vps-init-1.1.0.tar.gz
SHA256SUMS
```

并创建 GitHub Release。Bootstrap 优先使用该 Release 和 SHA256 校验；没有 Release 时才回退到源码 tarball。

## 当前边界

- 正式支持 Ubuntu 24.04 LTS。
- 推荐在全新 VPS 使用。
- 同一 Profile 可以幂等重跑；不自动进行任意 Profile 之间的无损迁移。
- `ENABLE_CF_WS`、`ENABLE_CF_PREFERRED`、`ENABLE_CLOUDFLARESUB` 仍为预留扩展，默认关闭；误开会 fail-closed。
- 这是个人 VPS 实用安全基线，不是 CIS/企业合规基线。
