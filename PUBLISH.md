# 发布信息

当前公开仓库：`bluepanda001/vps-init`。

一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bluepanda001/vps-init/main/install.sh)
```

仓库自带 `.github/workflows/release.yml`。正式发布有两种等价入口：

1. 推送标准 tag，例如 `v1.2.4`。
2. 创建发布分支，例如 `release/v1.2.4`。Workflow 会校验仓库 `VERSION` 必须等于 `1.2.4`，然后创建对应 `v1.2.4` tag 和 Release。

两种方式都会先运行 `verify/selftest.sh`。Self-test 产生的 Python bytecode 会清理掉，Release staging 还会再次排除 `__pycache__` / `*.pyc` / `*.pyo`，然后生成：

```text
vps-init-<版本>.tar.gz
SHA256SUMS
```

随后发布 GitHub Release。重复触发同一版本时，如果 Release 已存在会安全退出，不重复创建。

Bootstrap 会优先使用最新正式 Release 并校验 `SHA256SUMS`。只有 GitHub `/releases/latest` 明确返回 404 时才允许首次发布前回退到 `main` 源码归档；网络错误、403/429/5xx、异常重定向、Release 下载或校验失败都会直接停止。
