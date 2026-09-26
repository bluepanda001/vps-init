#!/usr/bin/env bash
core_firewall() {
  log_info "配置 UFW..."
  mkdir -p "$BACKUP_DIR/ufw"
  ufw status numbered > "$BACKUP_DIR/ufw/status-before.txt" 2>&1 || true
  [[ -f /etc/ufw/user.rules ]] && cp -a /etc/ufw/user.rules "$BACKUP_DIR/ufw/user.rules" || true
  [[ -f /etc/ufw/user6.rules ]] && cp -a /etc/ufw/user6.rules "$BACKUP_DIR/ufw/user6.rules" || true
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment 'vps-init ssh'

  case "$PROFILE" in
    base-only) ;;
    reality-only)
      ufw allow 80/tcp comment 'vps-init ip-acme'
      ufw allow 443/tcp comment 'vps-init reality'
      if is_true "$ENABLE_SUBSCRIPTION_RESOLVED"; then ufw allow "${SUBSCRIPTION_PORT}/tcp" comment 'vps-init subscription'; fi
      ;;
    nginx-reality|lucky-reality)
      ufw allow 80/tcp comment 'vps-init http'
      ufw allow 443/tcp comment 'vps-init https-reality'
      if [[ "$SUBSCRIPTION_EXPOSE_MODE_RESOLVED" == "direct-ip-https" ]] && is_true "$ENABLE_SUBSCRIPTION_RESOLVED"; then
        ufw allow "${SUBSCRIPTION_PORT}/tcp" comment 'vps-init subscription'
      fi
      ;;
  esac
  ufw --force enable
  log_ok "UFW 已启用。"
}
