#!/usr/bin/env bash
core_fail2ban() {
  cat > /etc/fail2ban/jail.d/vps-init-sshd.conf <<EOF2
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
findtime = 10m
maxretry = 15
bantime = 1h
EOF2
  fail2ban-client -t
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  log_ok "Fail2ban 已配置。"
}
