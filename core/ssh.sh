#!/usr/bin/env bash

ssh_socket_activation_in_use() {
  systemctl cat ssh.socket >/dev/null 2>&1 && {
    systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null
  }
}

reload_ssh_runtime() {
  sshd -t
  if ssh_socket_activation_in_use; then
    # Ubuntu 24.04 uses systemd socket activation by default. The generator
    # reads Port= from sshd_config, so a daemon-reload + socket restart is
    # required before the new port is actually bound.
    systemctl daemon-reload
    systemctl restart ssh.socket
    # Reload the service as well so authentication policy changes affect
    # already spawned/new sshd instances without terminating this session.
    systemctl reload ssh.service 2>/dev/null || true
  else
    systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
  fi
}

verify_ssh_listener() {
  if ! ss -H -ltn4 "sport = :${SSH_PORT}" 2>/dev/null | grep -q .; then
    die "SSH 配置已写入，但 IPv4 实际没有监听 ${SSH_PORT}/tcp。当前会话不要关闭；请检查 ssh.socket/ssh.service。"
  fi
}

verify_root_key_policy() {
  sshd -T | grep -qi '^pubkeyauthentication yes$' || die "PubkeyAuthentication 未实际生效为 yes。"
  if ! sshd -T | grep -Eqi '^permitrootlogin (prohibit-password|without-password)$'; then
    echo "当前 PermitRootLogin 实际值未进入 key-only 模式。可能有更早加载的 hardening drop-in 覆盖配置：" >&2
    grep -RniE '^[[:space:]]*(PermitRootLogin|PubkeyAuthentication)[[:space:]]+' \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d /usr/lib/ssh/sshd_config.d 2>/dev/null >&2 || true
    die "PermitRootLogin 未进入 key-only 模式；当前会话不要关闭。"
  fi
}

write_ssh_stage_config() {
  # OpenSSH 对多数关键字采用 first-value-wins。00-00-vps-init.conf 必须排在
  # 常见的 00-hardening.conf / 00-cloud-init.conf 前面，否则它们的 no 会覆盖项目设置。
  local dropin=/etc/ssh/sshd_config.d/00-00-vps-init.conf legacy
  backup_file "$dropin"
  for legacy in /etc/ssh/sshd_config.d/00-vps-init.conf /etc/ssh/sshd_config.d/99-vps-init.conf; do
    if [[ -f "$legacy" ]]; then backup_file "$legacy"; rm -f "$legacy"; fi
  done
  cat > "$dropin" <<EOF2
# Managed by vps-init. Stage 1: enable direct root public-key login for the
# supplied key, but do not yet disable global PasswordAuthentication /
# KbdInteractiveAuthentication until a second SSH session is verified.
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF2
  reload_ssh_runtime
  verify_ssh_listener
  verify_root_key_policy
}

write_ssh_final_config() {
  local dropin=/etc/ssh/sshd_config.d/00-00-vps-init.conf
  cat > "$dropin" <<EOF2
# Managed by vps-init. Final key-only root SSH baseline.
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
EOF2
  reload_ssh_runtime
  verify_ssh_listener
  verify_root_key_policy
  sshd -T | grep -qi '^passwordauthentication no$' || die "PasswordAuthentication 未成功关闭。"
}

show_netcatty_identity_hint() {
  local identity_name
  identity_name="${SERVER_NAME:-${PROVIDER:-vps}-${SERVER_IP}}"
  cat >&2 <<EOF2

Netcatty 统一 SSH 规范：
  钥匙串 Key Label : vps-main
  Windows 私钥文件 : %USERPROFILE%\\.ssh\\vps-main-ed25519
  每台 VPS 单独 Identity：
    名称             : ${identity_name}
    用户名           : root
    密钥             : vps-main
  Host 登录方式      : 密钥，并选择上面的 Identity
  不再使用“本地密钥”路径；让 Netcatty Keychain/Cloud Sync 同步 vps-main。
EOF2
}

core_ssh() {
  local key="$SSH_PUBLIC_KEY"
  if [[ -z "$key" ]]; then
    cat >&2 <<EOF2

SSH_PUBLIC_KEY 还是空的。以后所有普通 VPS 统一复用同一把 vps-main。
如果本机还没有这把密钥，请在 Windows PowerShell 运行：

ssh-keygen -t ed25519 -f "\$env:USERPROFILE\\.ssh\\vps-main-ed25519" -C "vps-main"
Get-Content "\$env:USERPROFILE\\.ssh\\vps-main-ed25519.pub" | Set-Clipboard

如果已经有 vps-main，只运行第二条。
然后把剪贴板中的 ssh-ed25519 公钥填到 config.env 的 SSH_PUBLIC_KEY，再重新执行：
  sudo ./vps-init apply

私钥只保存在 Windows / Netcatty Keychain，绝对不要上传到 VPS、GitHub 或聊天。
EOF2
    exit 20
  fi
  [[ "$key" == ssh-ed25519\ * ]] || die "SSH_PUBLIC_KEY 必须是 ssh-ed25519 公钥。"

  install -d -m 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  grep -qxF "$key" /root/.ssh/authorized_keys || printf '%s\n' "$key" >> /root/.ssh/authorized_keys

  # Verify the supplied public-key line is parseable before changing sshd.
  local kt
  kt="$(mktemp)"; printf '%s\n' "$key" > "$kt"
  ssh-keygen -l -f "$kt" >/dev/null || { rm -f "$kt"; die "SSH_PUBLIC_KEY 无法被 ssh-keygen 解析。"; }
  rm -f "$kt"

  # 如果服务器此前已经启用 UFW，先放行新 SSH 端口，再 reload sshd，避免把自己锁在门外。
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${SSH_PORT}/tcp" comment 'vps-init ssh' >/dev/null
  fi

  state_load
  if is_true "${SSH_KEY_VERIFIED:-false}" && [[ "${SSH_VERIFIED_PORT:-}" == "$SSH_PORT" ]]; then
    write_ssh_final_config
    log_ok "SSH 密钥与端口 ${SSH_PORT} 此前均已验证；保持 key-only root SSH。"
    show_netcatty_identity_hint
    return 0
  fi
  if is_true "${SSH_KEY_VERIFIED:-false}"; then
    log_warn "SSH 密钥此前已验证，但端口从 ${SSH_VERIFIED_PORT:-未知} 变为 ${SSH_PORT}；必须重新做第二终端登录验证。"
  fi

  # Stage 1 explicitly enables direct root key login so provider/cloud images
  # with PermitRootLogin no or PubkeyAuthentication no can be migrated safely.
  # The current session must remain open until the second-session test passes.
  write_ssh_stage_config

  log_warn "公钥已安装，并已启用 root 公钥登录；当前会话不要关闭。全局 PasswordAuthentication/KbdInteractive 尚未由项目关闭。"
  if [[ -t 0 ]]; then
    echo
    echo "请保持当前 SSH 会话不要关闭，再开一个新终端测试："
    if [[ -n "${SSH_IDENTITY_HINT:-}" ]]; then
      echo "  Windows PowerShell: ssh -i \"\$env:USERPROFILE\\.ssh\\${SSH_IDENTITY_HINT}\" -p ${SSH_PORT} root@${SERVER_IP}"
    else
      echo "  ssh -p ${SSH_PORT} root@${SERVER_IP}"
      echo "  如果密钥不是默认文件名，请额外加：-i <你的私钥路径>"
    fi
    echo "Netcatty 也可以新建该 VPS 的专属 Identity：root + vps-main，然后用新窗口测试。"
    echo "确认新会话可以用 ED25519 密钥登录后，再回来继续。"
    if ! confirm "新会话已经用密钥成功登录，是否切换为 key-only root SSH？" n; then
      die "尚未确认密钥登录。当前会话不要关闭；确认后重新运行即可。"
    fi
  else
    die "非交互执行无法确认第二个 SSH 会话。公钥已安装并启用 root 公钥登录，但不会自动关闭全局密码策略；请先测试密钥后在交互终端重跑。"
  fi

  write_ssh_final_config
  state_set SSH_KEY_VERIFIED true
  state_set SSH_VERIFIED_PORT "$SSH_PORT"
  log_ok "SSH 密钥登录与端口 ${SSH_PORT} 已验证，root 密码/键盘交互登录已关闭。"
  show_netcatty_identity_hint
}
