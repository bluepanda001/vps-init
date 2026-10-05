#!/usr/bin/env bash

ssh_socket_activation_in_use() {
  systemctl cat ssh.socket >/dev/null 2>&1 && {
    systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null
  }
}

reload_ssh_runtime() {
  sshd -t
  if ssh_socket_activation_in_use; then
    # StartLimitBurst counts socket restarts, not SIGHUP reloads. Restarting
    # an already-correct listener several times leaves new SSH sessions with
    # no banner. The generator binds Port= only after daemon-reload plus a
    # socket restart, so that path is reserved for a listener that is not
    # already on SSH_PORT. reset-failed first so an earlier start-limit does
    # not make the required restart fail immediately.
    if ss -H -ltn4 "sport = :${SSH_PORT}" 2>/dev/null | grep -q .; then
      systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service 2>/dev/null || true
    else
      systemctl daemon-reload
      systemctl reset-failed ssh.service ssh.socket >/dev/null 2>&1 || true
      systemctl restart ssh.socket
      systemctl reload ssh.service 2>/dev/null || true
    fi
  else
    systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
  fi
}

verify_ssh_listener() {
  if ! ss -H -ltn4 "sport = :${SSH_PORT}" 2>/dev/null | grep . >/dev/null; then
    die "SSH 配置已写入，但 IPv4 实际没有监听 ${SSH_PORT}/tcp。当前会话不要关闭；请检查 ssh.socket/ssh.service。"
  fi
}

verify_root_key_policy() {
  local effective
  effective="$(sshd -T)"
  grep -qi '^pubkeyauthentication yes$' <<<"$effective" || die "PubkeyAuthentication 未实际生效为 yes。"
  if ! grep -Eqi '^permitrootlogin (prohibit-password|without-password)$' <<<"$effective"; then
    echo "当前 PermitRootLogin 实际值未进入 key-only 模式。可能有更早加载的 hardening drop-in 覆盖配置：" >&2
    grep -RniE '^[[:space:]]*(PermitRootLogin|PubkeyAuthentication)[[:space:]]+' \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d /usr/lib/ssh/sshd_config.d 2>/dev/null >&2 || true
    die "PermitRootLogin 未进入 key-only 模式；当前会话不要关闭。"
  fi
}

capture_ssh_baseline() {
  # Read the provider/current policy without our managed drop-in. We only move
  # the file on disk while evaluating sshd -T; the running daemon is untouched.
  local dropin=/etc/ssh/sshd_config.d/00-00-vps-init.conf tmp effective
  tmp="$(mktemp)"
  if [[ -f "$dropin" ]]; then
    cp -a "$dropin" "$tmp"
    rm -f "$dropin"
    effective="$(sshd -T 2>/dev/null || true)"
    install -m 600 "$tmp" "$dropin"
  else
    effective="$(sshd -T 2>/dev/null || true)"
  fi
  rm -f "$tmp"
  [[ -n "$effective" ]] || die "无法读取 SSH 基线配置；不会修改 sshd。"

  SSH_BASE_PERMIT_ROOT="$(awk '$1=="permitrootlogin"{print $2; exit}' <<<"$effective")"
  SSH_BASE_PASSWORD_AUTH="$(awk '$1=="passwordauthentication"{print $2; exit}' <<<"$effective")"
  SSH_BASE_KBD_AUTH="$(awk '$1=="kbdinteractiveauthentication"{print $2; exit}' <<<"$effective")"
  SSH_BASE_PERMIT_ROOT="${SSH_BASE_PERMIT_ROOT:-prohibit-password}"
  SSH_BASE_PASSWORD_AUTH="${SSH_BASE_PASSWORD_AUTH:-no}"
  SSH_BASE_KBD_AUTH="${SSH_BASE_KBD_AUTH:-no}"

  case "$SSH_BASE_PERMIT_ROOT" in
    yes) SSH_STAGE_PERMIT_ROOT=yes ;;
    *) SSH_STAGE_PERMIT_ROOT=prohibit-password ;;
  esac
}

# OpenSSH sshd -T prints the deprecated alias "without-password" for a
# configured PermitRootLogin prohibit-password. Stage 1 still writes the
# current keyword; the check has to accept the alias or the first real
# verification aborts after the drop-in is already loaded.
permitrootlogin_matches_expected() {
  local expected="$1" effective="$2"
  case "$expected" in
    prohibit-password|without-password)
      grep -Eqi '^permitrootlogin (prohibit-password|without-password)$' <<<"$effective"
      ;;
    *)
      grep -qi "^permitrootlogin ${expected}$" <<<"$effective"
      ;;
  esac
}

verify_ssh_stage_policy() {
  local effective
  effective="$(sshd -T)"
  grep -qi '^pubkeyauthentication yes$' <<<"$effective" || die "Stage 1 未成功启用 PubkeyAuthentication。"
  permitrootlogin_matches_expected "$SSH_STAGE_PERMIT_ROOT" "$effective" ||
    die "Stage 1 未保持预期的 PermitRootLogin=${SSH_STAGE_PERMIT_ROOT}。"
  grep -qi "^passwordauthentication ${SSH_BASE_PASSWORD_AUTH}$" <<<"$effective" ||
    die "Stage 1 改变了原有 PasswordAuthentication；已停止。"
  grep -qi "^kbdinteractiveauthentication ${SSH_BASE_KBD_AUTH}$" <<<"$effective" ||
    die "Stage 1 改变了原有 KbdInteractiveAuthentication；已停止。"
}

render_ssh_stage_config() {
  cat <<EOF2
# Managed by vps-init. Stage 1: add root public-key access while preserving the
# pre-existing authentication policy until a second SSH session is verified.
Port ${SSH_PORT}
PermitRootLogin ${SSH_STAGE_PERMIT_ROOT}
PubkeyAuthentication yes
PasswordAuthentication ${SSH_BASE_PASSWORD_AUTH}
KbdInteractiveAuthentication ${SSH_BASE_KBD_AUTH}
EOF2
}

write_ssh_stage_config() {
  local dropin=/etc/ssh/sshd_config.d/00-00-vps-init.conf
  backup_file "$dropin"
  render_ssh_stage_config > "$dropin"
  reload_ssh_runtime
  verify_ssh_listener
  verify_ssh_stage_policy
}

write_ssh_final_config() {
  local dropin=/etc/ssh/sshd_config.d/00-00-vps-init.conf legacy
  for legacy in /etc/ssh/sshd_config.d/00-vps-init.conf /etc/ssh/sshd_config.d/99-vps-init.conf; do
    if [[ -f "$legacy" ]]; then backup_file "$legacy"; rm -f "$legacy"; fi
  done
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
  local effective
  effective="$(sshd -T)"
  grep -qi '^passwordauthentication no$' <<<"$effective" || die "PasswordAuthentication 未成功关闭。"
}

ssh_rollback_unit_name() {
  printf 'vps-init-ssh-rollback-%s-%s\n' "$(date +%s)" "$BASHPID"
}

clear_ssh_rollback_marker() {
  [[ -n "${SSH_ROLLBACK_MARKER:-}" ]] || return 0
  rm -f "$SSH_ROLLBACK_MARKER"
}

arm_ssh_stage_rollback() {
  local dropin=/etc/ssh/sshd_config.d/00-00-vps-init.conf dir script previous unit
  dir="${BACKUP_DIR}/ssh-stage-rollback"
  mkdir -p "$dir"
  previous="$dir/00-00-vps-init.conf.previous"
  script="$dir/rollback.sh"
  SSH_ROLLBACK_MARKER="$dir/fired"
  clear_ssh_rollback_marker
  unit="$(ssh_rollback_unit_name)"
  SSH_ROLLBACK_UNIT="$unit"

  if [[ -f "$dropin" ]] && ! { grep -q 'Managed by vps-init. Stage 1' "$dropin" && ! is_true "${SSH_KEY_VERIFIED:-false}"; }; then
    cp -a "$dropin" "$previous"
    printf 'present\n' > "$dir/mode"
  else
    rm -f "$previous"
    printf 'absent\n' > "$dir/mode"
  fi

  cat > "$script" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
dropin=/etc/ssh/sshd_config.d/00-00-vps-init.conf
if [[ "\$(cat "$dir/mode")" == present ]]; then
  install -m 600 "$previous" "\$dropin"
else
  rm -f "\$dropin"
fi
sshd -t
if systemctl cat ssh.socket >/dev/null 2>&1 &&
   { systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; }; then
  systemctl daemon-reload
  systemctl reset-failed ssh.service ssh.socket >/dev/null 2>&1 || true
  systemctl restart ssh.socket
  systemctl reload ssh.service 2>/dev/null || true
else
  systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
fi
touch "$SSH_ROLLBACK_MARKER"
EOF2
  chmod 700 "$script"
  systemd-run --quiet --unit="$unit" --on-active=10m /bin/bash "$script" >/dev/null ||
    die "无法创建 SSH 10 分钟自动回滚任务；为避免锁机，不继续修改 SSH。"
  log_warn "SSH Stage 1 已启用 10 分钟自动回滚保护；验证成功后会自动取消。"
}

cancel_ssh_stage_rollback() {
  [[ -n "${SSH_ROLLBACK_UNIT:-}" ]] || return 0
  systemctl stop "${SSH_ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl stop "${SSH_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "${SSH_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
}

ssh_stage_rollback_fired() {
  [[ -n "${SSH_ROLLBACK_MARKER:-}" && -e "$SSH_ROLLBACK_MARKER" ]]
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
  if command_exists ufw && ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then
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

  # Preserve the provider/current authentication policy until the second
  # session proves that the new key works. A transient systemd timer rolls
  # Stage 1 back automatically if verification never completes.
  capture_ssh_baseline
  arm_ssh_stage_rollback
  write_ssh_stage_config

  log_warn "公钥已安装，并已启用 root 公钥登录；当前会话不要关闭。验证前会保留原有 PasswordAuthentication/KbdInteractiveAuthentication 策略。"
  log_warn "如果当前会话意外中断，Stage 1 会在 10 分钟后自动恢复到修改前的 SSH 配置。"
  if [[ -t 0 ]]; then
    local verify_choice=""
    while true; do
      echo
      echo "请保持当前 SSH 会话不要关闭，再开一个新终端测试："
      if [[ -n "${SSH_IDENTITY_HINT:-}" ]]; then
        echo "  Windows PowerShell: ssh -i \"\$env:USERPROFILE\\.ssh\\${SSH_IDENTITY_HINT}\" -p ${SSH_PORT} root@${SERVER_IP}"
      else
        echo "  ssh -p ${SSH_PORT} root@${SERVER_IP}"
        echo "  如果密钥不是默认文件名，请额外加：-i <你的私钥路径>"
      fi
      echo "Netcatty 也可以新建该 VPS 的专属 Identity：root + vps-main，然后用新窗口测试。"
      echo
      echo "SSH 密钥验证："
      echo "  1. 新会话已经用密钥登录成功 → 继续并切换为 key-only"
      echo "  2. 还没测试 / 测试失败       → 保持当前状态，继续等待"
      echo "  3. 重新显示测试说明"
      echo "  Ctrl+C                       → 主动中止本次部署"
      read -r -p "请选择 [1-3]: " verify_choice
      case "$verify_choice" in
        1)
          if ssh_stage_rollback_fired; then
            log_warn "10 分钟自动回滚已经执行；重新进入 Stage 1 后请再测试一次新 SSH 会话。"
            arm_ssh_stage_rollback
            write_ssh_stage_config
            continue
          fi
          break
          ;;
        2)
          echo "好的，当前会话和密码登录策略都保持不变。请在另一个窗口继续测试；这里不会退出部署。"
          ;;
        3)
          echo "已重新显示测试命令；测试成功后选 1。"
          ;;
        *)
          echo "输入无效，请输入 1、2 或 3；不会退出当前部署。"
          ;;
      esac
    done
  else
    die "非交互执行无法确认第二个 SSH 会话。公钥已安装并启用 root 公钥登录，但不会自动关闭全局密码策略；请先测试密钥后在交互终端重跑。"
  fi

  write_ssh_final_config
  cancel_ssh_stage_rollback
  state_set SSH_KEY_VERIFIED true
  state_set SSH_VERIFIED_PORT "$SSH_PORT"
  log_ok "SSH 密钥登录与端口 ${SSH_PORT} 已验证，root 密码/键盘交互登录已关闭。"
  show_netcatty_identity_hint
}
