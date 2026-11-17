#!/usr/bin/env bash
# Pure capability queries and incremental plans. No system mutations here.
component_ids() { printf '%s\n' docker reality lucky nginx subscription cf-ws; }
component_label() {
  case "$1" in
    docker) echo 'Docker Engine / Compose' ;;
    reality) echo 'Reality / 3x-ui' ;;
    lucky) echo 'Lucky Web Gateway' ;;
    nginx) echo 'Nginx SNI 网关（需要 Reality）' ;;
    subscription) echo 'Clash / Mihomo 订阅' ;;
    cf-ws) echo 'Cloudflare CDN WS 节点' ;;
    *) die "未知组件：$1" ;;
  esac
}
component_enabled() {
  case "$1" in
    docker) is_true "${ENABLE_DOCKER:-false}" ;;
    reality) profile_has_xui ;;
    lucky) profile_has_lucky ;;
    nginx) [[ "$PROFILE" == nginx-reality || "$PROFILE" == lucky-reality ]] ;;
    subscription) profile_has_xui && is_true "$ENABLE_SUBSCRIPTION_RESOLVED" ;;
    cf-ws) is_true "${ENABLE_CF_WS:-false}" ;;
    *) return 1 ;;
  esac
}
component_service() {
  case "$1" in docker) echo docker ;; reality|subscription|cf-ws) echo x-ui ;; lucky) echo lucky ;; nginx) echo nginx ;; esac
}
component_present() {
  case "$1" in
    docker) command_exists docker || [[ -d /var/lib/docker ]] ;;
    reality|subscription|cf-ws) [[ -e /usr/local/x-ui/x-ui || -e /etc/x-ui/x-ui.db ]] ;;
    lucky) [[ -d /opt/lucky ]] ;;
    nginx) command_exists nginx || [[ -e /etc/nginx/nginx.conf ]] ;;
  esac
}
component_healthy() {
  systemctl is-active --quiet "$(component_service "$1")" 2>/dev/null || return 1
  case "$1" in
    docker) docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 ;;
    reality) verify_reality_handshake ;;
    lucky) verify_lucky_local_version && verify_lucky_public_domain ;;
    nginx) nginx -t >/dev/null 2>&1 ;;
    subscription) verify_mihomo_public_endpoint ;;
    cf-ws) verify_cf_ws_subscription && verify_cf_ws_handshake ;;
  esac
}
component_plan() {
  local action="$1" component="$2"
  component_label "$component" >/dev/null
  case "$action" in add|repair) ;; *) die "组件操作仅支持 add / repair。" ;; esac
  resolve_auto_settings
  if [[ "$action" == repair ]] && ! component_enabled "$component"; then
    die "该组件尚未启用，请先增装：$component"
  fi
  COMPONENT_TARGET_PROFILE="$PROFILE"
  COMPONENT_STEPS=()
  case "$component" in
    docker) COMPONENT_STEPS=(optional_docker) ;;
    reality)
      case "$PROFILE" in base-only) COMPONENT_TARGET_PROFILE=reality-only ;; lucky-web) COMPONENT_TARGET_PROFILE=lucky-reality ;; esac
      COMPONENT_STEPS=(module_xui resolve_runtime_ports component_firewall module_subscription module_reality)
      if [[ "$COMPONENT_TARGET_PROFILE" == lucky-reality ]]; then
        COMPONENT_STEPS=(module_cloudflare module_certbot_domain "${COMPONENT_STEPS[@]}" module_lucky module_nginx)
      elif [[ "$COMPONENT_TARGET_PROFILE" == nginx-reality ]]; then
        COMPONENT_STEPS=(module_cloudflare module_certbot_domain "${COMPONENT_STEPS[@]}" module_nginx)
      fi
      ;;
    lucky)
      case "$PROFILE" in base-only) COMPONENT_TARGET_PROFILE=lucky-web ;; reality-only|nginx-reality) COMPONENT_TARGET_PROFILE=lucky-reality ;; esac
      COMPONENT_STEPS=(module_cloudflare module_certbot_domain)
      if [[ "$PROFILE" == reality-only ]]; then COMPONENT_STEPS+=(module_reality); fi
      # nginx-reality -> lucky-reality must release its HTTPS backend :8443.
      if [[ "$PROFILE" == nginx-reality ]]; then COMPONENT_STEPS+=(component_release_nginx_backend); fi
      COMPONENT_STEPS+=(module_lucky)
      if [[ "$COMPONENT_TARGET_PROFILE" == lucky-reality ]]; then COMPONENT_STEPS+=(module_nginx); fi
      ;;
    nginx)
      profile_has_xui || die "Nginx SNI 网关需要 Reality；请先增装 Reality。"
      if [[ "$PROFILE" == reality-only ]]; then COMPONENT_TARGET_PROFILE=nginx-reality; fi
      COMPONENT_STEPS=(module_cloudflare module_certbot_domain)
      if [[ "$PROFILE" == reality-only ]]; then COMPONENT_STEPS+=(module_reality); fi
      COMPONENT_STEPS+=(module_nginx)
      ;;
    subscription)
      profile_has_xui || die "订阅需要 Reality / 3x-ui；请先增装 Reality。"
      COMPONENT_STEPS=(resolve_runtime_ports component_firewall module_subscription)
      ;;
    cf-ws)
      profile_has_xui && profile_has_domain || die "CDN WS 需要已有的域名 Reality 网关，请先增装 Lucky 或 Nginx。"
      is_true "$ENABLE_SUBSCRIPTION_RESOLVED" || die "CDN WS 需要订阅，请先增装订阅。"
      COMPONENT_STEPS=(module_cloudflare module_certbot_domain optional_cf_ws)
      ;;
  esac
  # Gateway changes must restore the optional SNI map too.
  if is_true "${ENABLE_CF_WS:-false}" && [[ " ${COMPONENT_STEPS[*]} " == *' module_nginx '* ]]; then
    COMPONENT_STEPS+=(optional_cf_ws)
  fi
}

# Persisted project identity survives disabling a component via Profile changes.
component_previously_managed() {
  case "$1" in
    reality) [[ -n "${XUI_PANEL_PORT:-}" && -n "${XUI_VERSION:-}" && -n "${XUI_API_TOKEN:-}" ]] ;;
    lucky) [[ -n "${LUCKY_SAFE_URL:-}" && -n "${LUCKY_USERNAME:-}" && -n "${LUCKY_PASSWORD:-}" ]] ;;
    nginx) [[ -f /etc/nginx/stream-conf.d/vps-init.conf ]] && grep -q '^# Managed by vps-init.' /etc/nginx/stream-conf.d/vps-init.conf ;;
    *) return 1 ;;
  esac
}
