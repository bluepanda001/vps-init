#!/usr/bin/env bash

ensure_acme_renewal() {
  local acme="$1" cron_dump

  [[ -x "$acme" ]] || die "acme.sh 不可用，无法配置 IP 短期证书续期：$acme"

  # Reality-only IP certificates are short-lived (~6 days), so renewal is a
  # deployment requirement rather than a best-effort convenience.
  wait_apt_lock 300
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron
  systemctl enable --now cron >/dev/null 2>&1 || die "无法启用 cron；IP 短期证书不能安全自动续期。"
  systemctl is-active --quiet cron || die "cron 未处于 active 状态；IP 短期证书不能安全自动续期。"

  # Auto-upgrade is helpful but is not required for certificate renewal.
  "$acme" --upgrade --auto-upgrade >/dev/null 2>&1 ||     log_warn "acme.sh 自动升级未启用；证书续期仍会继续配置。"

  "$acme" --install-cronjob >/dev/null 2>&1 ||     die "acme.sh 续期 cronjob 安装失败；不会把本次部署报告为续期已启用。"

  cron_dump="$(crontab -l 2>/dev/null || true)"
  # acme.sh commonly writes the path as "/root/.acme.sh"/acme.sh, so do not
  # require one contiguous literal pathname here.
  if ! printf '%s\n' "$cron_dump" | grep -Eq 'acme\.sh.*--cron'; then
    die "未在 root crontab 中确认 acme.sh --cron 任务；IP 短期证书续期未真正启用。"
  fi
}

module_ip_certificate() {
  local cert=/root/cert/ip/fullchain.pem key=/root/cert/ip/privkey.pem
  local acme=/root/.acme.sh/acme.sh cert_valid=false

  if [[ -s "$cert" && -s "$key" ]] &&      openssl x509 -checkend 172800 -noout -in "$cert" >/dev/null 2>&1; then
    cert_valid=true
  fi

  [[ -r /usr/bin/x-ui ]] || die "未找到 3x-ui 管理脚本 /usr/bin/x-ui，无法初始化其 acme.sh 环境。"

  # Keep the pinned 3x-ui certificate semantics, but call acme.sh directly
  # instead of feeding answers into an interactive prompt sequence.
  if [[ ! -x "$acme" ]]; then
    log_info "初始化 3x-ui 使用的 acme.sh..."
    bash -c 'source /usr/bin/x-ui status >/dev/null 2>&1; install_acme' >/dev/null 2>&1 ||       die "acme.sh 安装失败。"
  fi
  [[ -x "$acme" ]] || die "acme.sh 初始化后仍不可用：$acme"

  if [[ "$cert_valid" == true ]]; then
    ensure_acme_renewal "$acme"
    IP_CERT_FILE="$cert"
    IP_KEY_FILE="$key"
    export IP_CERT_FILE IP_KEY_FILE
    state_set IP_CERT_FILE "$IP_CERT_FILE"
    state_set IP_KEY_FILE "$IP_KEY_FILE"
    log_ok "现有 IP 短期证书仍有效，并已确认 acme.sh 自动续期任务。"
    return 0
  fi

  port_in_use 80 && die "3x-ui IP SSL 的 HTTP-01 需要 80 端口空闲，但当前已被占用。"

  wait_apt_lock 300
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat
  install -d -m 700 /root/cert/ip

  log_info "为公网 IPv4 ${SERVER_IP} 签发 Let's Encrypt short-lived IP 证书..."
  "$acme" --set-default-ca --server letsencrypt --force >/dev/null
  "$acme" --issue     -d "$SERVER_IP"     --standalone     --server letsencrypt     --certificate-profile shortlived     --days 6     --httpport 80     --force || die "3x-ui IP SSL 签发失败；不会降级为 HTTP。"

  # acme.sh can return non-zero here if the reload command has a transient
  # problem even though the certificate files were installed. Validate the
  # files below, but do not confuse that with renewal scheduling.
  if ! "$acme" --installcert --force -d "$SERVER_IP"       --key-file "$key"       --fullchain-file "$cert"       --reloadcmd "systemctl restart x-ui" >/dev/null 2>&1; then
    log_warn "acme.sh --installcert 返回非零；继续以证书文件/SAN/有效期检查为准。"
  fi

  [[ -s "$cert" && -s "$key" ]] || die "IP SSL 流程结束后未找到证书；不会降级为 HTTP。"
  openssl x509 -checkend 86400 -noout -in "$cert" >/dev/null 2>&1 || die "IP SSL 证书有效期异常。"
  openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null |     grep -Fq "IP Address:${SERVER_IP}" || die "IP SSL 证书 SAN 不包含当前公网 IPv4 ${SERVER_IP}。"

  ensure_acme_renewal "$acme"

  chmod 600 "$key"
  chmod 644 "$cert"

  IP_CERT_FILE="$cert"
  IP_KEY_FILE="$key"
  export IP_CERT_FILE IP_KEY_FILE
  state_set IP_CERT_FILE "$IP_CERT_FILE"
  state_set IP_KEY_FILE "$IP_KEY_FILE"
  log_ok "3x-ui IP 短期证书已签发，并已验证 acme.sh 自动续期 cronjob。"
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
  state_set SUBSCRIPTION_PATH "$SUBSCRIPTION_PATH"
  state_set SUB_ID "$SUB_ID"

  local sub_listen sub_uri cert_file key_file
  cert_file=""
  key_file=""
  case "$SUBSCRIPTION_EXPOSE_MODE_RESOLVED" in
    direct-ip-https)
      module_ip_certificate
      sub_listen=""
      sub_uri="https://${SERVER_IP}:${SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}"
      cert_file="$IP_CERT_FILE"
      key_file="$IP_KEY_FILE"
      ;;
    nginx-https|lucky-https)
      sub_listen="127.0.0.1"
      sub_uri="https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}"
      ;;
    *) die "未知订阅暴露模式: $SUBSCRIPTION_EXPOSE_MODE_RESOLVED" ;;
  esac

  local patch api
  patch=$(jq -cn     --arg listen "$sub_listen" --argjson port "$SUBSCRIPTION_PORT" --arg path "$SUBSCRIPTION_PATH"     --arg uri "$sub_uri" --arg cert "$cert_file" --arg key "$key_file"     '{subEnable:true,subListen:$listen,subPort:$port,subPath:$path,subURI:$uri,subCertFile:$cert,subKeyFile:$key,subJsonEnable:false,subClashEnable:true,subClashPath:"/clash/",subClashURI:"",subClashEnableRouting:true,subClashAutoDetect:true,subClashUserAgentRegex:"(?i)(clash|mihomo)"}')
  api="$(xui_base_url)"
  python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" patch-settings --json "$patch" >/dev/null
  systemctl restart x-ui
  sleep 2
  secret_set SUBSCRIPTION_BASE_URL "$sub_uri"
  log_ok "订阅服务已配置：$SUBSCRIPTION_EXPOSE_MODE_RESOLVED（公网只提供 HTTPS）。"
}
