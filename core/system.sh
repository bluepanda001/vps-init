#!/usr/bin/env bash
core_system() {
  log_info "更新软件索引并确保基础工具可用（普通 apply 不执行 full upgrade）..."
  wait_apt_lock 300
  export DEBIAN_FRONTEND=noninteractive
  apt_get_with_lock_retry update
  apt_get_with_lock_retry install -y ca-certificates curl wget jq unzip tar openssl socat ufw fail2ban unattended-upgrades python3 python3-venv gnupg lsb-release rsync dnsutils
  timedatectl set-timezone UTC
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
  systemctl enable --now unattended-upgrades.service 2>/dev/null || true
  copy_project_persistent
  log_ok "基础系统依赖已确保可用。"
}

core_system_upgrade() {
  require_root
  log_warn "即将执行 apt_get_with_lock_retry update + apt_get_with_lock_retry -y upgrade；这可能更新内核/系统组件并产生 reboot-required。"
  confirm "确认现在执行完整系统升级？" n || { echo "已取消系统升级。"; return 0; }
  wait_apt_lock 300
  export DEBIAN_FRONTEND=noninteractive
  apt_get_with_lock_retry update
  apt_get_with_lock_retry -y upgrade
  log_ok "系统升级完成。"
  [[ -f /var/run/reboot-required ]] && log_warn "系统提示需要重启。"
}
