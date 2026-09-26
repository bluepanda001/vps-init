#!/usr/bin/env bash
module_ip_certificate() {
  local cert=/root/cert/ip/fullchain.pem key=/root/cert/ip/privkey.pem
  if [[ -s "$cert" && -s "$key" ]] && openssl x509 -checkend 172800 -noout -in "$cert" >/dev/null 2>&1; then
    IP_CERT_FILE="$cert"; IP_KEY_FILE="$key"; export IP_CERT_FILE IP_KEY_FILE
    state_set IP_CERT_FILE "$IP_CERT_FILE"; state_set IP_KEY_FILE "$IP_KEY_FILE"
    return 0
  fi
  port_in_use 80 && die "3x-ui IP SSL 的 HTTP-01 需要 80 端口空闲，但当前已被占用。"
  [[ -r /usr/bin/x-ui ]] || die "未找到 3x-ui 管理脚本 /usr/bin/x-ui，无法使用其 IP SSL 功能。"

  log_info "直接调用 3x-ui 自带的 Get SSL for IP Address 流程（Let's Encrypt short-lived certificate）..."
  # 3x-ui 当前流程的交互顺序：确认自动检测 IPv4(默认 y)、IPv6(留空)、HTTP-01 端口(默认 80)、
  # 是否把证书设为面板证书(n)。这里只给订阅服务使用，所以最后选择 n。
  if ! printf '\n\n\nn\n' | bash -c 'source /usr/bin/x-ui status >/dev/null 2>&1; ssl_cert_issue_for_ip'; then
    die "3x-ui IP SSL 签发失败；不会降级为 HTTP。"
  fi
  [[ -s "$cert" && -s "$key" ]] || die "3x-ui IP SSL 流程结束后未找到证书；不会降级为 HTTP。"
  openssl x509 -checkend 86400 -noout -in "$cert" >/dev/null 2>&1 || die "IP SSL 证书有效期异常。"
  chmod 600 "$key"; chmod 644 "$cert"
  IP_CERT_FILE="$cert"; IP_KEY_FILE="$key"; export IP_CERT_FILE IP_KEY_FILE
  state_set IP_CERT_FILE "$IP_CERT_FILE"; state_set IP_KEY_FILE "$IP_KEY_FILE"
  log_ok "3x-ui IP 短期证书已签发；acme.sh 自动续期由 3x-ui 官方流程负责。"
}

module_subscription() {
  is_true "$ENABLE_SUBSCRIPTION_RESOLVED" || return 0
  state_load
  # Existing state wins. On a fresh VPS use the configured global subscription
  # URI path. Panel URI and subscription URI are independent settings even when
  # both default to /zhg/. Per-client SubID remains randomly generated.
  if [[ -z "${SUBSCRIPTION_PATH:-}" ]]; then
    SUBSCRIPTION_PATH="${XUI_SUB_URI_PATH:-/zhg/}"
  fi
  SUBSCRIPTION_PATH="$(normalize_path "$SUBSCRIPTION_PATH")"
  SUB_ID="${SUB_ID:-$(random_b64url 18 16)}"
  state_set SUBSCRIPTION_PATH "$SUBSCRIPTION_PATH"; state_set SUB_ID "$SUB_ID"

  local sub_listen sub_uri cert_file key_file
  cert_file=""; key_file=""
  case "$SUBSCRIPTION_EXPOSE_MODE_RESOLVED" in
    direct-ip-https)
      module_ip_certificate
      sub_listen=""
      sub_uri="https://${SERVER_IP}:${SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}"
      cert_file="$IP_CERT_FILE"; key_file="$IP_KEY_FILE"
      ;;
    nginx-https|lucky-https)
      sub_listen="127.0.0.1"
      sub_uri="https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}"
      ;;
    *) die "未知订阅暴露模式: $SUBSCRIPTION_EXPOSE_MODE_RESOLVED" ;;
  esac

  local patch api
  patch=$(jq -cn \
    --arg listen "$sub_listen" --argjson port "$SUBSCRIPTION_PORT" --arg path "$SUBSCRIPTION_PATH" \
    --arg uri "$sub_uri" --arg cert "$cert_file" --arg key "$key_file" \
    '{subEnable:true,subListen:$listen,subPort:$port,subPath:$path,subURI:$uri,subCertFile:$cert,subKeyFile:$key,subJsonEnable:false,subClashEnable:true,subClashPath:"/clash/",subClashURI:"",subClashEnableRouting:true,subClashAutoDetect:true,subClashUserAgentRegex:"(?i)(clash|mihomo)"}')
  api="$(xui_base_url)"
  python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" patch-settings --json "$patch" >/dev/null
  systemctl restart x-ui; sleep 2
  secret_set SUBSCRIPTION_BASE_URL "$sub_uri"
  log_ok "订阅服务已配置：$SUBSCRIPTION_EXPOSE_MODE_RESOLVED（公网只提供 HTTPS）。"
}
