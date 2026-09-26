# 发布信息

当前公开仓库：`bluepanda001/vps-init`。

一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bluepanda001/vps-init/main/install.sh)
```

仓库自带 `.github/workflows/release.yml`。以后推送类似 `v1.1.0` 的 tag 时，GitHub Actions 会运行 `verify/selftest.sh`，生成 `vps-init-<版本>.tar.gz` 与 `SHA256SUMS`，并创建 Release。

Bootstrap 会优先使用最新 Release；如果还没有 Release，会自动回退到 `main` 源码归档，因此不影响首次一键安装。
