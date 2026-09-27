#!/usr/bin/env bash

ssh_socket_activation_in_use() {
  systemctl cat ssh.socket >/dev/null 2>&1 && {
    systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null
  }
}

reload_ssh_runtime() {
  sshd -t
  if ssh_socket_activation_in_use; then
    # Ubuntu 24.04 uses systemd socket activation by default.  The generator
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

write_ssh_stage_config() {
  local dropin=/etc/ssh/sshd_config.d/00-vps-init.conf legacy=/etc/ssh/sshd_config.d/99-vps-init.conf
  backup_file "$dropin"
  if [[ -f "$legacy" ]]; then backup_file "$legacy"; rm -f "$legacy"; fi
  cat > "$dropin" <<EOF2
# Managed by vps-init. Stage 1: add the requested port and public-key auth,
# but keep the server's existing password/root-login policy unchanged until
# the user verifies a second SSH session.
Port ${SSH_PORT}
PubkeyAuthentication yes
EOF2
  reload_ssh_runtime
  verify_ssh_listener
}

write_ssh_final_config() {
  local dropin=/etc/ssh/sshd_config.d/00-vps-init.conf
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
  sshd -T | grep -qi '^passwordauthentication no$' || die "PasswordAuthentication 未成功关闭。"
  sshd -T | grep -Eqi '^permitrootlogin (prohibit-password|without-password)$' || die "PermitRootLogin 未进入 key-only 模式。"
}

core_ssh() {
  local key="$SSH_PUBLIC_KEY"
  if [[ -z "$key" ]]; then
    local provider ipcompact keyname
    provider="$(printf '%s' "${PROVIDER:-vps}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
    [[ -n "$provider" ]] || provider="vps"
    ipcompact="${SERVER_IP//./}"
    keyname="id_ed25519_${provider}_${ipcompact}"
    cat >&2 <<EOF2

SSH_PUBLIC_KEY 还是空的。请在 Windows PowerShell 运行：

ssh-keygen -t ed25519 -f "\$env:USERPROFILE\\.ssh\\${keyname}" -C "${provider}-${SERVER_IP}"
Get-Content "\$env:USERPROFILE\\.ssh\\${keyname}.pub" | Set-Clipboard

如果密钥已经存在，只运行第二条。
然后把剪贴板中的 ssh-ed25519 公钥填到 config.env 的 SSH_PUBLIC_KEY，再重新执行：
  sudo ./vps-init apply
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
    return 0
  fi
  if is_true "${SSH_KEY_VERIFIED:-false}"; then
    log_warn "SSH 密钥此前已验证，但端口从 ${SSH_VERIFIED_PORT:-未知} 变为 ${SSH_PORT}；必须重新做第二终端登录验证。"
  fi

  # Stage 1 deliberately does NOT set PermitRootLogin/PasswordAuthentication.
  # Therefore a failed second-session test does not change the server's previous
  # password/root-login policy.
  write_ssh_stage_config

  log_warn "公钥已安装；当前仍保留服务器原有的密码/root 登录策略。"
  if [[ -t 0 ]]; then
    echo
    echo "请保持当前 SSH 会话不要关闭，再开一个新终端测试："
    if [[ -n "${SSH_IDENTITY_HINT:-}" ]]; then
      echo "  Windows PowerShell: ssh -i \"\$env:USERPROFILE\\.ssh\\${SSH_IDENTITY_HINT}\" -p ${SSH_PORT} root@${SERVER_IP}"
    else
      echo "  ssh -p ${SSH_PORT} root@${SERVER_IP}"
      echo "  如果密钥不是默认文件名，请额外加：-i <你的私钥路径>"
    fi
    echo "确认新会话可以用 ED25519 密钥登录后，再回来继续。"
    if ! confirm "新会话已经用密钥成功登录，是否切换为 key-only root SSH？" n; then
      die "尚未确认密钥登录。旧 SSH 认证策略保持不变；确认后重新运行即可。"
    fi
  else
    die "非交互执行无法确认第二个 SSH 会话。公钥已安装，但不会自动关闭原有密码策略；请先测试密钥后在交互终端重跑。"
  fi

  write_ssh_final_config
  state_set SSH_KEY_VERIFIED true
  state_set SSH_VERIFIED_PORT "$SSH_PORT"
  log_ok "SSH 密钥登录与端口 ${SSH_PORT} 已验证，root 密码/键盘交互登录已关闭。"
}
