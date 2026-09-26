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
5. 使用已有 ED25519 key，或按提示生成并粘贴 `.pub`。
6. Reality Target 使用自动检测。
7. 面板路径默认 `/zhg/`。
8. Subscription URI Path 默认 `/zhg/`；它和 Panel URI Path 是独立设置，只是默认值相同。
9. Clash/Mihomo 默认开启 Routing + Auto Detect。
10. 第二终端验证 ED25519 SSH 后，确认关闭密码登录。

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
