# VPS Init 架构审查与实施方案

基线：1.3.24。目标：保留全部五个 Profile 和现有组件，实现轻量分层、可恢复部署和安全交互。

## 当前结构与调用链

```
install.sh -> /opt/vps-init/vps-init -> /usr/local/bin/vps-init
vps-init (635 行：菜单、信息、凭据、更新、部署)
  lib/common.sh (387 行：配置、状态、网络、APT、公共函数)
  lib/wizard.sh (666 行：输入、DD、配置、事务、安装)
  core/ -> 系统、SSH、UFW、Fail2ban、Swap、BBR
  optional/ -> Docker、CF WS、两个预留集成
  modules/ -> Cloudflare、证书、3x-ui、Reality、订阅、网关
  verify/ -> 真实验收、自测、模拟行为测试
```

部署顺序：配置/状态 -> 拓扑切换 -> 预检 -> SSH -> 系统依赖 -> 端口 -> Swap/BBR/UFW/Fail2ban -> 可选组件 -> 按 Profile 部署 -> 验收 -> 提交配置和 Profile。
依赖通过 source 和共享 shell 变量传递，没有发现 source 循环；但入口和 common 职责过多。profiles/*.env 是示例，不是执行注册表。

## 优先问题

- P1：wizard_run 的错误分支先清理备份再 return $?，吞掉取消/失败码；条件调用整个向导使 Bash errexit 失效。
- P1：失败后删除 pending 配置，使首次部署需要重新填写；缺少阶段进度和中断记录。
- P1：菜单直接调用含 die/exit 的函数，错误可能关闭整个菜单；EOF 可能造成循环或默认确认。
- P1：状态/凭据通过 install 覆写，进程中断可能截断；错误 trap 输出原始命令可能泄漏秘密。
- P1：bootstrap 忽略备份失败，删除当前安装后才移动新版本；缺少阶段完整性检查。
- P2：向导重建配置丢弃自定义字段；安装失败与已验证 Profile 缺少明确区分。
- P2：大部分架构回归测试依赖入口文件中的字符串，需要随移动更新并增加执行测试。
- P2：Lucky 下载缺少超时；Docker 国内网络失败缺少可执行恢复提示。

## 取舍与目标结构

选择渐进拆分，而非重命名全部目录或引入插件框架。core/ 系统基线、modules/ Profile 服务、optional/ 可选集成、verify/ 验收职责已基本合理，保持路径以兼容证书 hook 和旧安装。

```
vps-init                 CLI 调度与依赖装配
lib/app/deploy.sh         Profile 拓扑、阶段编排、验收提交
lib/app/menu.sh           菜单、配置编辑、更新
lib/app/display.sh        状态、信息、凭据与日志展示
lib/state.sh              原子状态/凭据写入
lib/config.sh             默认配置、加载、持久化
lib/deployment.sh         阶段日志与失败提示
lib/wizard.sh             保留兼容入口与向导
core/, modules/, optional/, profiles/, verify/ 保留
```

菜单保留快捷编号，按安装部署、系统服务、配置凭据、网络、维护、重装分组。操作运行在独立 Bash 进程，避免条件上下文关闭 errexit。恢复使用保存的候选配置和幂等模块；不盲目跳过服务/防火墙验证。成功的安装由组件现有检测复用。旧配置/状态文件不改格式，不生成新 UUID/订阅 ID。

## 验证与边界

语法、ShellCheck、原有自测、Python 行为测试、新增候选配置恢复/取消/阶段失败/原子状态/入口测试。危险命令模拟。macOS 本机不运行真实系统部署；Ubuntu 24.04 SSH 双终端、DD、ACME、systemd、真实下载及重启验收必须另行在一次性 VPS 完成。
