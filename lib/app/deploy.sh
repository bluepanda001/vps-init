#!/usr/bin/env bash
load_runtime_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || die "未找到配置：$cfg。请先运行 vps-init wizard。"
  load_config "$cfg"
  validate_config
  REQUESTED_PROFILE="$PROFILE"
  state_load
  PREVIOUS_DEPLOYED_PROFILE="${DEPLOYED_PROFILE:-}"
  PROFILE="$REQUESTED_PROFILE"
  resolve_auto_settings
  if [[ -n "$PREVIOUS_DEPLOYED_PROFILE" && "$PREVIOUS_DEPLOYED_PROFILE" != "$PROFILE" && "${VPSINIT_ALLOW_PROFILE_SWITCH:-0}" != "1" ]]; then
    die "该 VPS 已部署 Profile=${PREVIOUS_DEPLOYED_PROFILE}。如需切换到 ${PROFILE}，请运行交互向导确认迁移。"
  fi
}

managed_service_owned() {
  case "$1" in
    lucky) [[ -n "${LUCKY_SAFE_URL:-}" ]] ;;
    x-ui) [[ -n "${XUI_PANEL_PORT:-}" ]] ;;
    nginx) [[ -f /etc/nginx/stream-conf.d/vps-init.conf ]] ;;
    vps-init-landing) [[ -f /etc/systemd/system/vps-init-landing.service ]] ;;
    *) die "未知管理服务。" ;;
  esac
}

stop_managed_service() {
  managed_service_owned "$1" || return 0
  systemctl disable --now "$1"
}

prepare_profile_transition() {
  [[ -n "${PREVIOUS_DEPLOYED_PROFILE:-}" ]] || return 0
  # Ownership is checked per service, including components left by an
  # interrupted migration from base-only that need to be reconciled.

  if [[ "$PREVIOUS_DEPLOYED_PROFILE" != "$PROFILE" ]]; then
    [[ "${VPSINIT_ALLOW_PROFILE_SWITCH:-0}" == "1" ]] || die "Profile 切换未获确认。"
    log_warn "准备切换 Profile：${PREVIOUS_DEPLOYED_PROFILE} -> ${PROFILE}。仅停用/调整 vps-init 管理的冲突服务。"
  fi

  # Reconcile project-managed topology even when DEPLOYED_PROFILE already
  # matches the requested Profile. A failed migration can otherwise leave the
  # service graph half-switched while state/config still point at the last
  # verified Profile.
  case "$PROFILE" in
    nginx-reality)
      stop_managed_service lucky
      stop_managed_service vps-init-landing
      if ! systemctl is-active --quiet nginx 2>/dev/null &&
         systemctl is-active --quiet x-ui 2>/dev/null &&
         ss -H -ltnp 'sport = :443' 2>/dev/null | grep -qi xray; then
        log_warn "检测到失败迁移残留：443 当前由 Xray 占用；先停止 x-ui，随后恢复 Nginx Stream + Reality 1443。"
        systemctl stop x-ui >/dev/null 2>&1 || true
      fi
      ;;
    lucky-web)
      stop_managed_service nginx
      stop_managed_service x-ui
      ;;
    reality-only)
      stop_managed_service nginx
      stop_managed_service lucky
      stop_managed_service vps-init-landing
      ;;
    lucky-reality)
      if ! systemctl is-active --quiet nginx 2>/dev/null &&
         systemctl is-active --quiet x-ui 2>/dev/null &&
         ss -H -ltnp 'sport = :443' 2>/dev/null | grep -qi xray; then
        log_warn "检测到旧版/失败迁移残留：443 当前由 Xray 占用；先停止 x-ui，随后切换为 Nginx Stream + Reality 1443 + Lucky 8443。"
        systemctl stop x-ui >/dev/null 2>&1 || true
      fi
      ;;
    base-only)
      stop_managed_service x-ui
      stop_managed_service nginx
      stop_managed_service lucky
      stop_managed_service vps-init-landing
      ;;
  esac
}

deploy_apply() {
deployment_begin "$cfg"
log_info "开始部署 Profile: $PROFILE"
deployment_step prepare_profile_transition
deployment_step core_preflight
# SSH key is handled before package upgrades or other system mutations. If the
# public key is missing, the run stops here after printing copyable PowerShell.
deployment_step core_ssh
deployment_step core_system
deployment_step resolve_runtime_ports
deployment_step core_swap
deployment_step core_network
deployment_step core_firewall
deployment_step core_fail2ban
deployment_step optional_docker
deployment_step optional_cf_preferred
deployment_step optional_cloudflaresub

if [[ "$PROFILE" == "lucky-web" ]]; then
  deployment_step module_cloudflare
  deployment_step module_certbot_domain
  deployment_step module_lucky
elif profile_has_xui; then
  deployment_step module_xui
  if profile_has_domain; then
    deployment_step module_cloudflare
    deployment_step module_certbot_domain
  fi
  deployment_step module_subscription
  deployment_step module_reality
  case "$PROFILE" in
    nginx-reality) deployment_step module_nginx ;;
    lucky-reality)
      deployment_step module_lucky
      deployment_step module_nginx
      ;;
  esac
  deployment_step optional_cf_ws
fi

deployment_step copy_project_persistent

echo >> "$SECRETS_FILE" 2>/dev/null || true
chmod 600 "$SECRETS_FILE" 2>/dev/null || true

DEPLOYMENT_STEP=verify
deployment_record running verify
if verify_all; then
  persist_config "$cfg"
  state_set DEPLOYED_PROFILE "$PROFILE"
  state_set DEPLOYED_VERSION "$VPSINIT_VERSION"
  state_set DEPLOYMENT_VERIFIED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  DEPLOYMENT_FINISHED=true
  deployment_record verified complete
  rm -f "$PERSIST_DIR/pending.env"
  log_ok "全部阶段完成；Profile 已在验收通过后写入部署状态。"
else
  die "部署完成但验收存在失败项，请查看 $REPORT_FILE。"
fi

if [[ -f /var/run/reboot-required ]]; then
  log_warn "系统提示需要重启。建议执行 reboot，重新登录后运行：vps-init verify"
else
  log_info "可选的冷启动验收：reboot 后运行 vps-init verify"
fi
log_info "敏感凭据（root-only）：$SECRETS_FILE"
log_info "验收报告（不含密码/Token/私钥）：$REPORT_FILE"
show_info_summary "$PERSIST_DIR/config.env"

}

