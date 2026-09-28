# RUNBOOK

## 第一次

推荐只执行一条命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bluepanda001/vps-init/main/install.sh)
```

首次自动进入中文向导。最前面会先问：

```text
1. 不重装，直接初始化当前系统
2. 一键 DD / 重装 Ubuntu 24.04 Minimal
```

如果 VPS 已经是干净 Ubuntu 24.04，选 1。需要从头清盘时选 2；脚本使用 `bin456789/reinstall`，真正继续前必须输入大写 `DD`。重启前可运行 `bash /root/reinstall.sh reset` 取消。

DD 完成并重新 SSH 登录后，再运行同一条一键安装命令，这次选 1，然后建议先选 `Reality Only` 测试。

## 以后管理

```bash
vps-init
```

直接从菜单选择部署、验收、状态、凭据、更新或日志。

## Reality Only 典型首次流程

1. 快速安装。
2. Reality Only。
3. 填服务商名。
4. 沿用当前 SSH 端口。
5. SSH 使用统一 `vps-main`：已有就粘贴同一个 `vps-main-ed25519.pub`；只有第一次才生成 `vps-main-ed25519`。
6. Netcatty 为这台 VPS 单独新建 Identity：名称使用 VPS 名称，Username=`root`，Key=`vps-main`；Host 绑定该 Identity，不用“本地密钥”。
7. Reality Target 使用自动检测。
8. 面板路径默认 `/zhg/`。
9. Subscription URI Path 默认 `/zhg/`；它和 Panel URI Path 是独立设置，只是默认值相同。
10. Clash/Mihomo 默认开启 Routing + Auto Detect。
11. 保持当前会话不关，用第二终端验证 `root + vps-main` 成功后，再确认关闭密码登录。


## Netcatty 多 VPS 规范

统一只维护一把 Keychain 密钥 `vps-main`。每台 VPS 单独建立一个 Identity，Identity 名称与 VPS 名称一致，用户名默认 `root`，底层都引用 `vps-main`。这样 Cloud Sync 只需同步一把私钥，但每台主机仍有独立身份配置。

新 VPS 如果云镜像自带 `PermitRootLogin no` 或 `PubkeyAuthentication no`，不要手工猜配置来源；让 vps-init 的 SSH 阶段写入优先级更高的项目 drop-in，并以 `sshd -T` 实际值为准。第二终端验证成功前，不关闭当前连接。

## Cloudflare 域名 Profile

提前完成：根域名加入 Cloudflare、注册商 NS 已切换、Zone Active，并准备仅限该 Zone 的 Zone Read + DNS Write API Token。

Token 首次运行时隐藏输入，保存：

```text
/root/.secrets/cloudflare.ini
```

## 验收

```bash
vps-init verify
```

报告：

```bash
less /root/vps-init-report.txt
```

## 凭据

菜单选“查看敏感凭据”，或：

```bash
vps-init secrets
```

文件：

```text
/root/vps-init-secrets.txt
```

不要对外分享。

## 重启后

```bash
reboot
# 重连后
vps-init verify
```

## 更新

```bash
vps-init update
```

只替换项目程序文件，保留 `/opt/vps-init/config.env`、`/var/lib/vps-init/state.env` 和 root-only secrets。

## 排障

```bash
vps-init logs
```

也可以单独：

```bash
systemctl status x-ui --no-pager
journalctl -u x-ui -n 100 --no-pager
ufw status verbose
fail2ban-client status sshd
```

Nginx Profile：

```bash
nginx -t
systemctl status nginx --no-pager
```

Lucky Profile：

```bash
systemctl status lucky --no-pager
ss -ltnp | grep ':8443'
```
