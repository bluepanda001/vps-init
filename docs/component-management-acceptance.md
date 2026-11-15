# 组件管理验收记录

## 实现范围

- 主菜单 4 进入组件管理；支持状态、只读计划、增装、修复和恢复。
- 支持 Docker、Reality/3x-ui、Lucky、Nginx SNI、订阅、CDN WS；不包含第三方应用和卸载。
- 五种 Profile 保留，初始方案另行记录。单独组件执行器仅调用依赖计划，不调用系统初始化、SSH 加固或 DD。
- 原子配置提交、执行前后冲突检查、完整部署/编辑配置互斥、独立恢复候选、root-only 备份与 SQLite WAL 一致性快照。
- 旧 IP Reality 地址和订阅保留；相关 Nginx/Lucky/CDN 反代与验收适配 HTTPS 订阅后端。

## 自动测试

本地 `verify/selftest.sh` 输出 SELFTEST_OK；ShellCheck `-S error` 通过。

新增 33 项组件测试，包括所有 Profile 的 Docker 独立计划、六条拓扑扩展路径的模拟执行、依赖过滤、失败/中断恢复、切源、重复增装、未知字段和 UUID 保留、配置竞争、进程混合监听、未知 1443 入站、取消/EOF、备份失败中止、锁冲突、真实 CLI 入口、PTY 子菜单、SQLite WAL 和 Lucky HTTPS 后端。

已有 18 项工作流测试（主菜单已更新为 1–16）、3 项安装器测试及 SSH/UFW/Docker/Lucky/3x-ui 等测试继续通过。安装器测试确认新模块随更新安装。

审查发现并修复：保留地址与订阅验收不一致；编辑配置与执行器竞争；IPv4/IPv6 混合归属漏检；Docker 组件恢复提示与切源参数不一致。

## 仍需真实 VPS 验收

- 五种已部署 Profile 的组件状态识别及权限、操作日志与备份可读性。
- Reality-only 增装 Lucky/Nginx 后，旧客户端、原 IP 订阅和新增域名管理入口继续可用。
- Lucky-web 增装 Reality，已有自定义反代规则、凭据和公网管理地址不变。
- Nginx-reality 增装 Lucky，8443 后端切换及回连；订阅和 CDN WS 继续工作。
- Cloudflare API、ACME 签发/续期、Docker 两个真实镜像源、断网重试和重启后恢复。

自动测试使用隔离模拟，不执行真实 VPS 的软件安装、防火墙、SSH 或磁盘操作。备份不代表自动回滚：DNS、软件包和证书签发不能宣称可撤销；部署期间可能存在短暂服务中断。
