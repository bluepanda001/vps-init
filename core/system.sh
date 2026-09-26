#!/usr/bin/env bash
core_system() {
  log_info "更新系统并安装基础工具..."
  wait_apt_lock 300
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade
  apt-get install -y ca-certificates curl wget jq unzip tar openssl socat ufw fail2ban unattended-upgrades python3 python3-venv gnupg lsb-release rsync dnsutils
  timedatectl set-timezone UTC
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
  systemctl enable --now unattended-upgrades.service 2>/dev/null || true
  copy_project_persistent
  log_ok "基础系统完成。"
}
