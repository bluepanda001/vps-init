#!/usr/bin/env bash
show_status_summary() {
  local cfg="$1"
  load_runtime_config "$cfg"
  echo "VPS Init ${VPSINIT_VERSION}"
  echo "Profile           : $PROFILE"
  echo "Verified Profile  : ${DEPLOYED_PROFILE:-尚未验收通过}"
  if [[ -f "$STATE_DIR/deployment.env" ]]; then
    echo "最近部署进度："
    cat "$STATE_DIR/deployment.env"
  fi
  echo "Server            : ${SERVER_NAME:-}"
  echo "IPv4              : ${SERVER_IP:-未部署/未知}"
  echo "SSH Port          : $SSH_PORT"
  if [[ "$PROFILE" == "lucky-reality" ]]; then
    echo "Lucky Domain       : https://${LUCKY_DOMAIN}/${LUCKY_SAFE_URL:-zhg}"
  fi
  if [[ "$PROFILE" == "lucky-web" ]]; then
    echo "Lucky Domain       : https://${LUCKY_DOMAIN}/${LUCKY_SAFE_URL:-zhg}"
    echo "Lucky Safe Entry   : ${LUCKY_SAFE_URL:-zhg}"
    echo "Web Gateway        : Lucky direct :443"
    echo "Docker             : ${ENABLE_DOCKER}"
  fi
  if profile_has_xui; then
    echo "3x-ui Panel Path  : ${XUI_WEB_BASE_PATH:-${XUI_PANEL_URI_PATH:-/zhg/}}"
    echo "Subscription Path : ${SUBSCRIPTION_PATH:-${XUI_SUB_URI_PATH:-/zhg/}}"
    echo "Subscription Port : ${SUBSCRIPTION_PORT_SELECTED:-$SUBSCRIPTION_PORT}"
    echo "Reality Target    : ${REALITY_TARGET_SELECTED:-${REALITY_TARGET_MODE}}"
  fi
  [[ -f "$REPORT_FILE" ]] && echo "Report            : $REPORT_FILE"
  [[ -f "$SECRETS_FILE" ]] && echo "Secrets           : $SECRETS_FILE (600)"
}

show_info_summary() {
  local cfg="$1" panel_url="" sub_base="" reality_public=""
  load_runtime_config "$cfg"
  state_load
  echo "============================================================"
  echo "                 VPS Init 部署信息"
  echo "============================================================"
  echo "VPS Init           : $VPSINIT_VERSION"
  echo "Deployed Version   : ${DEPLOYED_VERSION:-未记录}"
  echo "Profile            : $PROFILE"
  echo "Server             : ${SERVER_NAME:-}"
  echo "IPv4               : ${SERVER_IP:-unknown}"
  echo "SSH                : root@${SERVER_IP:-unknown}:${SSH_PORT}"
  echo "SSH Auth           : vps-main / key-only"
  echo
  echo "已安装/管理组件："
  printf '  %-18s %s\n' "Fail2ban" "$(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
  printf '  %-18s %s\n' "UFW" "$(ufw status 2>/dev/null | awk -F': ' '/^Status:/{print $2; exit}' || true)"
  if profile_has_xui; then
    printf '  %-18s %s\n' "3x-ui" "${XUI_VERSION:-unknown} ($(systemctl is-active x-ui 2>/dev/null || echo inactive))"
    printf '  %-18s %s\n' "Xray" "3x-ui bundled"
  fi
  if [[ "$PROFILE" == "nginx-reality" || "$PROFILE" == "lucky-reality" ]]; then
    printf '  %-18s %s\n' "Nginx Stream" "$(systemctl is-active nginx 2>/dev/null || echo inactive)"
  fi
  if profile_has_lucky; then
    printf '  %-18s %s\n' "Lucky" "$(systemctl is-active lucky 2>/dev/null || echo inactive)"
  fi
  if is_true "${ENABLE_DOCKER:-false}"; then
    printf '  %-18s %s\n' "Docker" "$(systemctl is-active docker 2>/dev/null || echo inactive)"
    printf '  %-18s %s\n' "Docker 安装源" "${DOCKER_INSTALL_SOURCE:-official}"
  else
    printf '  %-18s %s\n' "Docker" "未启用"
  fi

  if [[ "$PROFILE" == "lucky-web" ]]; then
    echo
    echo "Lucky Web Only："
    echo "  Public 443        : Lucky direct HTTPS"
    echo "  Lucky Domain      : https://${LUCKY_DOMAIN}/${LUCKY_SAFE_URL:-zhg}"
    echo "  Lucky Safe Entry  : ${LUCKY_SAFE_URL:-zhg}"
    echo "  Lucky Local UI    : http://127.0.0.1:16601/${LUCKY_SAFE_URL:-zhg}"
    echo "  Lucky SSH Tunnel  : ssh -L 16601:127.0.0.1:16601 -p ${SSH_PORT} root@${SERVER_IP}"
    echo "  Wildcard TLS      : ${ROOT_DOMAIN} + *.${ROOT_DOMAIN}"
    echo "  Node Components   : none"
  fi

  if profile_has_xui; then
    echo
    echo "3x-ui / Reality："
    echo "  Panel Listen      : 127.0.0.1:${XUI_PANEL_PORT:-unknown}"
    echo "  Panel Path        : ${XUI_WEB_BASE_PATH:-unknown}"
    echo "  Subscription      : 127.0.0.1:${SUBSCRIPTION_PORT_SELECTED:-${SUBSCRIPTION_PORT:-unknown}}${SUBSCRIPTION_PATH:-}"
    echo "  Reality Target    : ${REALITY_TARGET_SELECTED:-unknown}"
    echo "  Reality SNI       : ${REALITY_SERVER_NAME:-unknown}"
    case "$PROFILE" in
      nginx-reality)
        echo "  Public 443        : Nginx Stream"
        echo "  Reality Route     : 443 -> 127.0.0.1:1443"
        echo "  HTTPS Route       : 443 -> Nginx HTTPS 127.0.0.1:8443"
        echo "  Web Gateway       : System Nginx (config-file based)"
        ;;
      lucky-reality)
        echo "  Public 443        : Nginx Stream"
        echo "  Reality Route     : 443 -> 127.0.0.1:1443"
        echo "  HTTPS Route       : 443 -> Lucky HTTPS 127.0.0.1:8443"
        echo "  Web Gateway       : Lucky (graphical UI, recommended)"
        echo "  Lucky Public UI   : https://${LUCKY_DOMAIN}/${LUCKY_SAFE_URL:-zhg}"
        echo "  Lucky Safe Entry  : ${LUCKY_SAFE_URL:-zhg}"
        echo "  Lucky Local UI    : http://127.0.0.1:16601/${LUCKY_SAFE_URL:-zhg}"
        echo "  Lucky SSH Tunnel  : ssh -L 16601:127.0.0.1:16601 -p ${SSH_PORT} root@${SERVER_IP}"
        ;;
      reality-only)
        echo "  Public 443        : Xray Reality"
        echo "  Web Gateway       : none"
        ;;
    esac

    if profile_has_domain; then
      panel_url="https://${PANEL_DOMAIN}${XUI_WEB_BASE_PATH}"
      sub_base="https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}"
      reality_public="${NODE_DOMAIN}:443"
    else
      panel_url="SSH tunnel -> http://127.0.0.1:${XUI_PANEL_PORT}${XUI_WEB_BASE_PATH}"
      sub_base="https://${SERVER_IP}:${SUBSCRIPTION_PORT_SELECTED:-$SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}"
      reality_public="${SERVER_IP}:443"
    fi
    echo "  Reality Public    : $reality_public"
    echo "  Panel URL         : $panel_url"
    echo "  Subscription Base : $sub_base"
  fi

  echo
  echo "重要文件："
  echo "  Config             : $PERSIST_DIR/config.env"
  echo "  State              : $STATE_FILE"
  echo "  Report             : $REPORT_FILE"
  echo "  Secrets            : $SECRETS_FILE"
  echo
  echo "敏感内容默认不显示。管理账号、密码、订阅/节点参数等请运行："
  echo "  vps-init secrets"
  echo "============================================================"
}

secret_value() {
  local key="$1"
  [[ -f "$SECRETS_FILE" ]] || return 0
  awk -v k="$key" 'index($0,k"=")==1 {v=substr($0,length(k)+2)} END{print v}' "$SECRETS_FILE"
}

secret_line() {
  local label="$1" key="$2" value
  value="$(secret_value "$key")"
  [[ -n "$value" ]] || return 0
  printf '  %s： %s\n' "$label" "$value"
}

secret_block() {
  local label="$1" key="$2" value
  value="$(secret_value "$key")"
  [[ -n "$value" ]] || return 0
  printf '  %s：\n    %s\n' "$label" "$value"
}

show_secrets_pretty() {
  [[ -f "$SECRETS_FILE" ]] || die "尚未生成 $SECRETS_FILE"
  state_load
  local deployed="${DEPLOYED_PROFILE:-unknown}"

  echo "============================================================"
  echo "                 VPS Init 敏感信息"
  echo "============================================================"
  echo "当前 Profile      : $deployed"
  echo "提示              : 本页含密码、Token 和节点参数，请勿公开分享。"
  echo

  if [[ "$deployed" != "base-only" && "$deployed" != "lucky-web" ]]; then
    echo "【一、3x-ui 面板】"
    secret_line "用户名" XUI_USERNAME
    secret_line "密码" XUI_PASSWORD
    secret_line "公网地址" XUI_PUBLIC_URL
    secret_line "本地地址" XUI_PANEL_LOCAL_URL
    secret_block "SSH 隧道命令" XUI_PANEL_SSH_TUNNEL
    echo
  fi

  if [[ "$deployed" == "lucky-reality" || "$deployed" == "lucky-web" ]]; then
    if [[ "$deployed" == "lucky-web" ]]; then echo "【一、Lucky 面板】"; else echo "【二、Lucky 面板】"; fi
    secret_line "用户名" LUCKY_USERNAME
    secret_line "密码" LUCKY_PASSWORD
    secret_line "安全入口" LUCKY_SAFE_URL
    secret_line "本地地址" LUCKY_LOCAL_URL
    secret_line "公网管理地址" LUCKY_PUBLIC_URL
    secret_block "SSH 隧道命令" LUCKY_PANEL_SSH_TUNNEL
    echo
  fi

  if [[ "$deployed" != "base-only" && "$deployed" != "lucky-web" ]]; then
    echo "【三、订阅地址】"
    secret_block "标准订阅" SUBSCRIPTION_URL
    secret_block "Clash / Mihomo" SUBSCRIPTION_CLASH_URL
    secret_block "Mihomo 明确端点" SUBSCRIPTION_MIHOMO_URL
    echo

    echo "【四、Reality 节点】"
    secret_line "Target" REALITY_TARGET
    secret_line "回落限速" REALITY_FALLBACK_LIMIT
    secret_line "UUID" REALITY_UUID
    secret_line "Public Key" REALITY_PUBLIC_KEY
    secret_line "Short ID" REALITY_SHORT_ID
    secret_block "分享链接" REALITY_SHARE_LINK
    echo
  fi

  if [[ -n "$(secret_value CF_WS_DOMAIN)" || -n "$(secret_value CF_WS_SHARE_LINK)" ]]; then
    echo "【五、Cloudflare CDN WS 节点】"
    secret_line "CDN 域名" CF_WS_DOMAIN
    secret_block "分享链接" CF_WS_SHARE_LINK
    echo
  fi

  echo "【高级 / API】"
  secret_line "3x-ui API Token" XUI_API_TOKEN
  echo
  echo "原始 KEY=VALUE 输出：vps-init secrets --raw"
  echo "============================================================"
}

show_gateway_summary() {
  local cfg="$1"
  load_runtime_config "$cfg"
  state_load

  echo "============================================================"
  echo "                 Web Gateway / 反向代理"
  echo "============================================================"
  case "$PROFILE" in
    lucky-web)
      echo "当前 Gateway： Lucky Web Only（无节点）"
      echo "服务状态：     $(systemctl is-active lucky 2>/dev/null || echo inactive)"
      echo "公网 HTTPS：   Lucky 直接监听 :443"
      echo "安全入口：     ${LUCKY_SAFE_URL:-zhg}"
      echo "管理地址：     https://${LUCKY_DOMAIN}/${LUCKY_SAFE_URL:-zhg}"
      echo "Docker：       $(systemctl is-active docker 2>/dev/null || echo inactive)"
      echo "节点组件：     未安装 3x-ui / Xray / Reality / Subscription"
      echo
      echo "以后自行安装 Docker 服务后，直接在 Lucky Web 服务里添加域名反代。"
      ;;
    lucky-reality)
      echo "当前 Gateway： Lucky（推荐）"
      echo "服务状态：     $(systemctl is-active lucky 2>/dev/null || echo inactive)"
      echo "HTTPS 后端：   127.0.0.1:8443"
      echo "公网管理地址： https://${LUCKY_DOMAIN}/${LUCKY_SAFE_URL:-zhg}"
      echo "安全入口：     ${LUCKY_SAFE_URL:-zhg}"
      echo "本地管理地址： http://127.0.0.1:16601/${LUCKY_SAFE_URL:-zhg}"
      echo
      echo "SSH 隧道："
      echo "  ssh -L 16601:127.0.0.1:16601 -p ${SSH_PORT} root@${SERVER_IP}"
      echo
      echo "连接隧道后，在本机浏览器打开："
      echo "  http://127.0.0.1:16601/${LUCKY_SAFE_URL:-zhg}"
      echo
      echo "Lucky 用户名/密码："
      echo "  vps-init secrets"
      echo
      echo "以后你自己安装 Docker/服务后，直接在 Lucky Web 服务里添加反向代理即可。"
      ;;
    nginx-reality)
      echo "当前 Gateway： System Nginx"
      echo "特点：         轻量、配置文件管理、无 Lucky 图形界面"
      echo
      echo "如果这台 VPS 后续要挂较多 Web/Docker 服务，建议重新运行："
      echo "  vps-init wizard"
      echo "并迁移到 Lucky + Reality。"
      ;;
    reality-only)
      echo "当前 Gateway： 无"
      echo "Reality 独占公网 443。若要挂多个 Web 服务，建议迁移到 Lucky + Reality。"
      ;;
    base-only)
      echo "当前 Gateway： 无"
      echo "Base Only 不配置公网 Web Gateway。"
      ;;
  esac
  echo "============================================================"
}

show_logs() {
  state_load
  echo "===== x-ui ====="
  systemctl status x-ui --no-pager 2>/dev/null || true
  journalctl -u x-ui -n 80 --no-pager 2>/dev/null || true
  if [[ "${DEPLOYED_PROFILE:-}" == "nginx-reality" || "${DEPLOYED_PROFILE:-}" == "lucky-reality" ]]; then
    echo "===== nginx stream ====="
    systemctl status nginx --no-pager 2>/dev/null || true
    journalctl -u nginx -n 80 --no-pager 2>/dev/null || true
  fi
  if [[ "${DEPLOYED_PROFILE:-}" == "lucky-reality" || "${DEPLOYED_PROFILE:-}" == "lucky-web" ]]; then
    echo "===== lucky ====="
    systemctl status lucky --no-pager 2>/dev/null || true
    journalctl -u lucky -n 80 --no-pager 2>/dev/null || true
  fi
  echo "===== fail2ban ====="
  systemctl status fail2ban --no-pager 2>/dev/null || true
}

