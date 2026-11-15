# 架构重构验收记录（2026-11-15）

基线 `3c0a896`，分支 `refactor/reliable-deployment`。未修改 main，未发布 Release，未运行真实 VPS 系统操作。

## 目录与职责对比

```
之前                            之后
vps-init（635 行）               vps-init（119 行，装配/CLI）
lib/common.sh（387 行）          lib/common.sh（304 行，公共工具）
                                lib/config.sh（配置默认值、加载、原子提交）
                                lib/state.sh（状态与凭据原子写入）
                                lib/deployment.sh（阶段进度、互斥、恢复）
                                lib/app/deploy.sh（Profile 编排与拓扑）
                                lib/app/display.sh（状态/地址/凭据/日志）
                                lib/app/menu.sh（菜单/维护/配置编辑）
lib/wizard.sh                   lib/wizard.sh（兼容保留，修复输入/候选事务）
core/                          core/（保留系统组件；修复 UFW pipefail）
modules/                       modules/（保留全部服务与 helper 路径）
optional/                      optional/（保留；Docker 下载恢复提示）
profiles/                      profiles/（五个方案均保留）
verify/                        verify/ + tests/test_workflows.py
                                        + tests/test_bootstrap.py
install.sh                     install.sh（校验、保留 pending、可恢复切换）
```

选择保留组件目录，是因为证书续期 hook、安装器和旧部署依赖这些路径。没有删除功能或引入运行框架。
`lib/wizard.sh` 仍偏大：本轮优先消除入口混合职责与错误恢复缺陷，没有为了行数拆散现有向导协议。

## 菜单

- 安装与部署：1 应用/修复或首次安装；2 继续失败部署；3 重新选择方案。
- 系统与服务：4 验收；5 部署信息；6 状态；7 Web Gateway。
- 配置与凭据：8 显示凭据（再次确认）；9 修改账号密码；10 编辑并校验配置。
- 网络：11 TCPFit / TcpQuality。
- 更新维护：12 更新程序；13 服务日志；14 apt 完整升级。
- 系统重装：15 DD，仍需输入大写 DD；0 退出。

首次安装仍是 DD 可跳过 → 快速/自定义 → Profile → 相关组件/源 → 必要输入 → 摘要 → 确认 → 部署 → 自动验收与管理信息。
选择菜单支持 0 取消、错误重试、EOF 终止；配置表单没有新增复杂多层导航。失败后不重新收集配置。

## 修复与恢复语义

1. 将配置收集和首次 DD 放到独立进程，防止 `if`/`||` 关闭整个调用链的 errexit。
2. 修复取消返回码被清理命令覆盖；EOF 不再变成默认确认或无限重试。
3. 保留候选 `pending.env`，阶段记录独立于 `state.env`，以免创建进度即被误认为已有部署。
4. 部署使用 flock 互斥，锁冲突不替换正在执行的恢复配置。
5. 菜单操作失败回到菜单；含 exit 的操作不再关闭菜单主进程。
6. 状态/凭据/配置采用同目录临时文件 + rename；凭据保持 0600。
7. 错误提示记录文件/行号，不打印可能含 Token 的原始命令。
8. 配置编辑校验失败保留原文件；向导保留未知/高级字段、域名覆盖及 APT 配置。
9. 成功配置提交只移除五项临时凭据/迁移字段，保留合法 VPSINIT_* 高级设置。
10. 已安装 base-only 不停用用户服务；其他服务停用需要已有组件状态或项目配置标识。
11. UFW 检查避免 `grep -q` 提前关管道导致 pipefail 假失败。
12. 升级校验完整依赖入口，保留 config/pending；备份失败停止，切换失败恢复旧目录。
13. Lucky 下载增加连接/总超时；Docker 官方/阿里云选项保持，并提示如何修改候选配置后恢复。

恢复明确区分：`resume` 继续候选；`apply` 按现有配置重新收敛；`update` 仅更新程序；`edit-config` 只保存配置；Profile 切换由向导确认。
移除了失败后自动再部署旧 Profile 的行为：自动回滚会覆盖待恢复候选并在用户没有再次操作时改变服务。现在显式提示恢复旧配置的命令。
不依据阶段日志盲目跳步；重复检查安全前提，组件自身复用已安装版本、密钥、UUID、订阅 ID、证书和端口。

## 自动化证据

- `bash verify/selftest.sh`：完整通过，所有 Shell 语法检查、五种 Profile 校验、Docker 两种源选择、现有静态安全断言。
- 原有 Lucky 行为、Docker JSON 合并、3x-ui 设置、Shell/APT 锁、五种 Profile UFW 幂等测试：通过。
- 原有 SSH 回滚测试：11 个通过，无跳过（本机安装 flock 后重新执行；Linux CI 同样运行）。
- 新增工作流测试：17 个通过。涵盖 EOF/取消/重试、真实 PTY 菜单子操作失败返回、DD 下载失败禁止继续、端口重试、配置原子替换与兼容、失败候选保留、锁冲突、全部 Profile 重复编排。
- 新增 bootstrap 测试：3 个通过。真实本地压缩包和文件替换；重定向所有宿主路径；验证更新保留配置/候选、缺依赖拒绝升级、切换失败还原。
- ShellCheck 0.11.0：error 级别通过。完整 warning 扫描仍有共享全局变量、原有测试引号、Unicode 文案等告警，不能宣称零 warning。
- Linux CI：见分支的 Self Test workflow；首轮代码提交运行 [43587749102](https://github.com/bluepanda001/vps-init/actions/runs/43587749102) 成功。
- 独立只读审查发现的 DD 返回码、恢复文件竞争、过宽配置过滤、服务所有权、菜单失败及 bootstrap 校验问题已修复。

## 兼容性与未覆盖风险

五个 Profile 均通过模拟编排：base-only、lucky-web、reality-only、lucky-reality、nginx-reality。
DD、ED25519/SSH 二终端和回滚、UFW/Fail2ban/BBR/Swap、Docker/Compose、3x-ui/Xray、Lucky/Nginx/SNI、Cloudflare/证书、订阅/CF WS、网络工具、状态/凭据/日志入口均保留。
cf-preferred/cloudflaresub 原本就是拒绝自动部署的预留扩展，本次未把它们伪装成已实现功能。

自动化结果不代表真实 VPS 全栈安装成功。下列事项必须在一次性 Ubuntu 24.04 VPS 验收：

- SSH 第二终端、公钥登录、端口迁移、systemd socket 与失联回滚；云厂商安全组。
- 五种 Profile 真实下载、安装、跨 Profile 迁移、端口竞争、重启后服务与路由。
- Cloudflare Token 权限/DNS 生效、ACME 限流/签发/实际续期，Reality/WS 与 Mihomo 客户端联通。
- 官方源/阿里云真实访问质量、APT 锁和网络断连；Docker 网络与已有容器。
- DD 仅在明确授权的可销毁 VPS 检查，单独确认备份和远程控制台。

事务边界是单文件原子提交，不是跨系统服务、DNS、证书和多文件的全局事务。SIGKILL/断电可能留下 running 阶段或 0600 临时文件；可用候选重试，不能保证自动回滚全部系统变更。
bootstrap 和运行时配置操作没有统一跨命令锁；管理员不应同时更新程序与部署/修改凭据。已有状态不能可靠证明手工替换过的服务仍由项目独占管理，真实迁移前需检查。
向导快速安装仍使用默认拓扑选择；复杂自定义配置应通过安全编辑入口维护。完整 warning 清理和更细的向导拆分可后续处理。
