# PR #23 发布前专项真机验收

测试日期：2026-10-05（UTC）

最终结论：**PR23_READY_FOR_RELEASE**

这次只验收 Codex 合并进 main 的 PR #23，不重跑五个 Profile。范围是两块高风险改动：SSH rollback transaction / stale timer / interrupted rerun，以及 IP 证书 SAN 精确匹配。没有创建 v1.3.14，没有修改 `VERSION`，没有发布 Release。

## 1. 被测版本与机器

| 项 | 值 |
| --- | --- |
| 仓库 | `bluepanda001/vps-init` |
| 被测 main | `4d02930a7ad94a2d2854f3fb101ae831240e168a` |
| 当时正式 Release | v1.3.13，`4728af5fc2c5f6a62d342af24080a1a068284519` |
| 测试机 | RackNerd `107.175.44.243`，仅此一台，用户 `root`，端口 22 |
| 登录 | Windows 密钥 `vps-main-ed25519`。直连可用，没有使用跳板 |
| 代码来源 | `/root/vps-init-pr23-test`，`git checkout` 到上面的 SHA。没有使用 `vps-init update` |
| 配置 | 现有 `/opt/vps-init/config.env`，`PROFILE=lucky-web`，`SSH_PORT=22` |
| `verify/selftest.sh` | 退出码 0，日志以 `SELFTEST_OK` 结束 |
| `VERSION` | 仍是 `1.3.13`。PR #23 放在 Unreleased，这是预期 |

`git rev-parse HEAD` 得到的就是 `4d02930a7ad94a2d2854f3fb101ae831240e168a`。

验收期间始终有一条主 SSH 会话（远端 pid 136667）保持到 reboot 之前。改 SSH 时另开控制会话。没有输出私钥或 Cloudflare Token，没有操作其他 VPS，没有 DD，没有为了让测试通过去改产品代码。

## 2. 测试前基线

把 `SSH_KEY_VERIFIED` 从 `true` 改成 `false` 时用的是仓库自己的 `state_set`。改完后这一行是 `SSH_KEY_VERIFIED=false`。其余 state 字段的内容哈希没有变化，键数量仍是 35，没有重复键。`/root/.ssh/authorized_keys` 还在。

| 项 | 基线 |
| --- | --- |
| `sshd -T` | `port 22`，`permitrootlogin without-password`，`pubkeyauthentication yes`，`passwordauthentication no`，`kbdinteractiveauthentication no` |
| drop-in | `# Managed by vps-init. Final key-only root SSH baseline.` |
| drop-in SHA256 | `006bae028015aeaee12d17642d9e3c681ff5a1b63c81f250adab4699bebe22a7` |
| `ssh.socket` | `Mon 2026-10-05 06:30:05 UTC`，`ActiveEnterTimestampMonotonic=7128538` |
| rollback unit | 没有 |
| `/var/lib/vps-init/ssh-stage-rollback` | 不存在 |

OpenSSH 9.x 把 drop-in 里的 `prohibit-password` 显示成 `without-password`。这和 v1.3.12 的口径一样，都算 key-only。

## 3. 事务编号

| 名称 | unit | rollback.sh | 计时器 |
| --- | --- | --- | --- |
| A | `vps-init-ssh-rollback-1791216383-139015` | `/var/lib/vps-init/ssh-stage-rollback/vps-init-ssh-rollback-1791216383-139015/rollback.sh` | 原定 `2026-10-05 16:16:23 UTC`。B 创建后于 `16:09:21 UTC` 被停掉，没有触发 |
| B | `vps-init-ssh-rollback-1791216561-140289` | `/var/lib/vps-init/ssh-stage-rollback/vps-init-ssh-rollback-1791216561-140289/rollback.sh` | `2026-10-05 16:19:21 UTC`。systemd 于 `16:19:23 UTC` 启动 service，`16:19:24 UTC` 成功退出 |
| C | `vps-init-ssh-rollback-1791217248-144891` | `/var/lib/vps-init/ssh-stage-rollback/vps-init-ssh-rollback-1791217248-144891/rollback.sh` | 原定 `2026-10-05 16:30:48 UTC`。成功提交后取消，没有触发 |

A、B、C 保存的 baseline 都是测试前那份 drop-in，SHA256 都是 `006bae028015aeaee12d17642d9e3c681ff5a1b63c81f250adab4699bebe22a7`。Stage 1 写到正在生效的文件后，哈希变成 `568b1862d64e8797abbdcb9b13bf70edce2c9583bcce8bf4e60033609d2b6b42`，注释是 Stage 1。B 没有把 A 的未验证 Stage 1 当成 baseline。

## 4. TEST A：Stage 1 中断后保护仍在

`./vps-init apply /opt/vps-init/config.env` 进入 Stage 1，timer 已创建，停在第二终端确认。没有选成功。

apply 被终止后：

- 主 SSH 会话仍在，新的 SSH 会话可以登录（`16:09:18Z`）。
- `current` 仍指向 A。
- A 的 timer 仍是 `active/waiting`。
- 没有手工清理 A。

结论：中断后的回滚保护还在。

补充：测试驱动把 apply 放进了非交互 shell 的后台，bash 因此让这个进程忽略 `SIGINT` 和 `SIGQUIT`。`/proc/<pid>/status` 里的 `SigIgn` 含有这两个信号。所以向进程发 `SIGINT` 不会结束它；A 和后来的 B 都是用 `SIGKILL` 停掉的。产品脚本本身没有 `SIGINT` 陷阱。单独用伪终端跑一段前台 `read` 时，写入 Ctrl+C、`kill -INT` 和 `killpg` 都会让它退出。这是测试驱动的进程信号屏蔽，不是这次要验的回滚缺陷。

## 5. TEST B：A 还活着时立刻重跑

`16:09:17Z` 再次 apply，重新进入 Stage 1。

- A 与 B 的 unit 不同。
- 重新列出 unit 时只剩 B 的 timer。A 的 timer 是 `inactive/dead`，journal 写着 `16:09:21` `Stopped` 和 `Deactivated successfully`。
- B 的 `00-00-vps-init.conf.previous` 与 A 的 previous、以及测试前 drop-in 哈希一致，不是 Stage 1 的哈希。

## 6. TEST C：B 自然等待约 10 分钟

没有选成功，没有手工执行 rollback.sh。主会话保持在线。

systemd 自己触发了 B：

- 预定时间 `16:19:21 UTC`。
- `16:19:23` `Started vps-init-ssh-rollback-1791216561-140289.service`。
- `16:19:24` service 和 timer 都 `Deactivated successfully`。
- `fired` 文件时间是 `Oct 5 16:19`。A 没有 `fired` 文件。
- `/var/lib/vps-init/ssh-stage-rollback/current` 已删除。
- drop-in 回到测试前的哈希和 “Final key-only” 注释。
- `sshd -T` 回到基线的 key-only。
- `ssh.socket` 被回滚脚本重启：`ActiveEnterTimestamp=Mon 2026-10-05 16:19:24 UTC`，monotonic `35365953505`。
- 主会话仍在。`16:19:50Z` 的新 SSH 会话登录成功。

timer 消失之后，journal 里有几行 `Failed to open /run/systemd/transient/... No such file or directory`。这是 transient unit 已经删除后再次查询造成的，service 本身已经成功退出。它没有改回配置，也不算回滚失败。

结论：**SSH_TRANSACTION_TIMEOUT_PASS**

## 7. TEST D：第三次进入 Stage 1 并成功提交

TRANSACTION C 于 `16:20:49Z` 进入 Stage 1。baseline 仍是测试前的原始 drop-in。

`16:21:15Z` 从 Windows 新开第二个 SSH 会话，登录成功。记为 **SECOND_SSH_OK**。主会话当时也还在。

随后在原来的 apply 里选择 “1. 新会话已经用密钥登录成功”。`16:21:36Z` 日志出现 “SSH 密钥登录与端口 22 已验证”。apply 在 `16:22:26Z` 退出码 0，产品自带验收通过。

提交后：

- `PubkeyAuthentication yes`
- `PasswordAuthentication no`
- `KbdInteractiveAuthentication no`
- `PermitRootLogin` 的 `sshd -T` 值是 `without-password`
- `SSH_KEY_VERIFIED=true`
- `SSH_VERIFIED_PORT=22`
- `current` 不存在
- 没有 rollback timer
- drop-in 回到最终配置哈希 `006bae02...`
- 成功提交没有再次重启 `ssh.socket`，monotonic 仍是回滚时的 `35365953505`

这次 apply 按产品路径继续跑完了 lucky-web 的后续阶段。没有手工改 Cloudflare、Lucky、Nginx 或 Reality。

## 8. TEST E：手工模拟已经排队的旧 callback

C 成功之后先保存最终配置，再依次执行 A 和 B 的 `rollback.sh`。

| 检查 | 结果 |
| --- | --- |
| A 退出码 | 0 |
| B 退出码 | 0 |
| drop-in SHA256 | 与 `final-before-stale.sha256` 相同，仍是 `006bae028015aeaee12d17642d9e3c681ff5a1b63c81f250adab4699bebe22a7` |
| 端口和认证策略 | 没变，仍是 22 和 key-only |
| `ssh.socket` monotonic | 没变，仍是 `35365953505` |
| `current` | 仍然不存在 |
| 新 SSH | `16:22:52Z` 登录成功 |

结论：**STALE_CALLBACK_NOOP_PASS**

## 9. TEST F：已经 verified 的普通重跑

`SSH_KEY_VERIFIED=true` 时再次 apply，`16:23:06Z` 到 `16:23:54Z`，退出码 0。

日志先出现 “SSH 配置已启用 10 分钟自动回滚保护”，紧接着是 “SSH 密钥与端口 22 此前均已验证；保持 key-only root SSH。” 没有进入第二终端确认。

| 项 | apply 前 | apply 后 |
| --- | --- | --- |
| `ssh.socket` monotonic | `35365953505` | `35365953505` |
| `ActiveEnterTimestamp` | `Mon 2026-10-05 16:19:24 UTC` | 相同 |

端口没有变化，socket 没有被无意义重启。完成后 `current` 不存在，没有残留 timer，key-only 仍在，`16:24:15Z` 的新 SSH 登录成功。产品验收再次通过。

## 10. TEST G：final config 失败保护

没有破坏真正的 sshd。在被测 main 上执行：

`python3 verify/tests/test_ssh_rollback.py -v`

11 项全部通过，耗时 0.802 秒，退出码 0。点名的几项都是 `ok`：

- `test_failed_final_config_keeps_rollback_available`
- `test_timer_cannot_interrupt_final_config_commit`
- `test_old_process_cannot_cancel_newer_rollback`
- `test_failed_rearm_keeps_previous_timer_valid`
- `test_killed_rearm_keeps_previous_timer_valid`
- `test_completed_timeout_cannot_be_committed_as_verified`

## 11. IP SAN 精确比较

`bash verify/tests/test_shell_behaviors.sh` 输出 `SHELL_BEHAVIORS_OK`，退出码 0。里面的 apt lock 和 `definitely-not-a-package` 是脚本自己的反例，不是部署失败。

用临时证书 `IP:203.0.113.100` 调用当前 main 的 `cert_has_ip_san`：

| IP | 结果 |
| --- | --- |
| `203.0.113.100` | 通过，`EXACT_RC=0` |
| `203.0.113.10` | 拒绝，`PREFIX_REJECTED_OK` |
| `203.0.113.1` | 拒绝，`SHORT_PREFIX_REJECTED_OK` |

线上证书没有修改。`/root/cert/ip/fullchain.pem` 存在。用户点名的 `/root/cert/ip/key.pem` 不存在；实际私钥是 `/root/cert/ip/privkey.pem`。SAN 文本只有 `IP Address:107.175.44.243`。

| 检查 | 结果 |
| --- | --- |
| `cert_has_ip_san` 对 `107.175.44.243` | 通过 |
| `107.175.44.24` | 拒绝 |
| `107.175.44.2` | 拒绝 |
| `cert_key_match` fullchain 与 `privkey.pem` | 匹配 |

## 12. reboot

| 项 | 值 |
| --- | --- |
| reboot 前 boot id | `c7cafe5a-9902-45f3-8647-2f84b89c272d`，记录于 `16:24:49Z` |
| reboot 后 boot id | `86911666-f20d-42c7-9388-2e1a26d44847` |
| 重启后 `sshd -T` | 仍是端口 22 和 key-only |
| `current` | 不存在 |
| rollback unit / timer | 没有 |
| 新的 SSH 会话 | 成功 |
| `SSH_KEY_VERIFIED` | `true`，`SSH_VERIFIED_PORT=22` |

`systemctl --failed` 只有 `systemd-networkd-wait-online.service`。它在等 `-i eth0:degraded`，两分钟后超时。这次 apply 日志里的默认网卡是 `ens3`。这不是 rollback unit，也不属于 PR #23。

## 13. rollback 历史目录

reboot 之后：

- `du -sh`：`68K`
- 一级目录：4 个
- 没有 `current`
- 只有 B 有 `fired`
- 另外一个目录 `vps-init-ssh-rollback-1791217389-149420` 是已验证重跑时创建、提交后留下的 rollback.sh / mode / previous
- 还有一个 `lock` 文件

这些是少量历史文件，没有活跃事务。按本次规则只记录，不因此判失败。

## 14. 有没有新 bug

没有发现需要挡住发布的新 bug。

测试机上的 `/opt/vps-init` 在这次 apply 之后与被测 checkout 的 `core/ssh.sh` 哈希一致，`/opt/vps-init/VERSION` 和 `DEPLOYED_VERSION` 都变成了 `1.3.13`。这是从该 checkout 执行 apply 的结果，不是发布出去的 v1.3.14，仓库里的 `VERSION` 也没有被手改。正式 Release 仍然是 v1.3.13。

## 15. 结论

**PR23_READY_FOR_RELEASE**

SSH 中断重跑、10 分钟自然回滚、成功提交、旧 callback 空操作、已验证重跑，以及 IP SAN 精确匹配，在这台机器上都按预期发生。本报告只记录验收，不发布新版本。
