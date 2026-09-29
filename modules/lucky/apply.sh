#!/usr/bin/env bash
module_landing_service() {
  mkdir -p /var/www/vps-init
  install -m 644 "$ROOT_DIR/templates/index.html" /var/www/vps-init/index.html
  cat > /etc/systemd/system/vps-init-landing.service <<'UNIT'
[Unit]
Description=vps-init loopback landing page
After=network.target
[Service]
Type=simple
WorkingDirectory=/var/www/vps-init
ExecStart=/usr/bin/python3 -m http.server 18080 --bind 127.0.0.1
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable --now vps-init-landing
}

module_lucky() {
  [[ "$PROFILE" == "lucky-reality" ]] || return 0
  local ver=2.27.2 arch url expected tmp
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64; expected=78adf3fa5e8869be0b1510cb7bcc755d57dccb13252989c8394a7207a392fe66 ;;
    aarch64|arm64) arch=arm64; expected=eb3a095238595193dab1fb486eed2a19d46190f37d4efd6630cc53e97d853466 ;;
    *) die "Lucky V1 暂不支持架构 $(uname -m)" ;;
  esac
  if [[ ! -x /opt/lucky/lucky ]]; then
    log_info "安装 Lucky ${ver}（官方稳定 release，校验 SHA-256）..."
    tmp=$(mktemp -d); url="https://github.com/gdy666/lucky/releases/download/v${ver}/lucky_${ver}_Linux_${arch}.tar.gz"
    curl -fL --retry 3 -o "$tmp/lucky.tar.gz" "$url"
    echo "${expected}  $tmp/lucky.tar.gz" | sha256sum -c -
    mkdir -p /opt/lucky; tar -xzf "$tmp/lucky.tar.gz" -C /opt/lucky
    if [[ ! -x /opt/lucky/lucky ]]; then
      local bin; bin=$(find /opt/lucky -type f -name lucky -perm -111 | head -1 || true); [[ -n "$bin" ]] || die "Lucky 包内未找到二进制"; cp "$bin" /opt/lucky/lucky; chmod 755 /opt/lucky/lucky
    fi
    rm -rf "$tmp"
  fi
  cat > /etc/systemd/system/lucky.service <<'UNIT'
[Unit]
Description=Lucky
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/opt/lucky/lucky -cd /opt/lucky
Restart=on-failure
RestartSec=3
WorkingDirectory=/opt/lucky
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable --now lucky
  for _ in $(seq 1 20); do curl -fsS --max-time 2 http://127.0.0.1:16601/version >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS --max-time 3 http://127.0.0.1:16601/version >/dev/null || die "Lucky 后台未启动。"
  state_load
  if [[ -z "${LUCKY_USERNAME:-}" || -z "${LUCKY_PASSWORD:-}" ]]; then
    LUCKY_USERNAME="lucky_$(random_hex 3)"
    LUCKY_PASSWORD="$(random_b64url 36 28)"
    state_set LUCKY_USERNAME "$LUCKY_USERNAME"
    state_set LUCKY_PASSWORD "$LUCKY_PASSWORD"
  fi

  # Lucky 2.27.2 的新配置格式保存在配置目录内的 *.lkcf 文件中，不能再把
  # /opt/lucky/lucky.conf 当作可读 JSON。先尝试项目已持久化的随机凭据；
  # 如果不可用，使用 Lucky 官方 CLI 将本机管理账号临时重置为 666/666，
  # 随即通过 loopback API 旋转回项目随机凭据。16601 不会被 UFW 对公网放行。
  if ! python3 "$ROOT_DIR/modules/lucky/lucky_api.py" \
      --user "$LUCKY_USERNAME" --password "$LUCKY_PASSWORD" status >/dev/null 2>&1; then
    /opt/lucky/lucky -rResetUser -cd /opt/lucky >/dev/null 2>&1 || \
      die "Lucky 官方 CLI 无法重置本机管理账号。"
    sleep 1
    python3 "$ROOT_DIR/modules/lucky/lucky_api.py" \
      --user 666 --password 666 set-admin \
      --new-user "$LUCKY_USERNAME" --new-password "$LUCKY_PASSWORD" >/dev/null || \
      die "Lucky 默认账号重置后仍无法旋转为项目随机凭据。"
  fi
  secret_set LUCKY_USERNAME "$LUCKY_USERNAME"; secret_set LUCKY_PASSWORD "$LUCKY_PASSWORD"
  secret_set LUCKY_LOCAL_URL "http://127.0.0.1:16601"

  module_landing_service
  python3 "$ROOT_DIR/modules/lucky/lucky_api.py" --user "$LUCKY_USERNAME" --password "$LUCKY_PASSWORD" sync-cert --cert "$DOMAIN_CERT_FILE" --key "$DOMAIN_KEY_FILE" >/dev/null
  python3 "$ROOT_DIR/modules/lucky/lucky_api.py" --user "$LUCKY_USERNAME" --password "$LUCKY_PASSWORD" configure-web \
    --panel-domain "$PANEL_DOMAIN" --node-domain "$NODE_DOMAIN" --panel-port "$XUI_PANEL_PORT" --sub-port "$SUBSCRIPTION_PORT" --landing-port 18080 >/dev/null
  systemctl restart lucky; sleep 2

  if [[ "$(readlink -f "$ROOT_DIR/modules/lucky/sync-cert.sh")" != "$(readlink -f /opt/vps-init/modules/lucky/sync-cert.sh 2>/dev/null || printf /opt/vps-init/modules/lucky/sync-cert.sh)" ]]; then
    install -m 755 "$ROOT_DIR/modules/lucky/sync-cert.sh" /opt/vps-init/modules/lucky/sync-cert.sh
  else
    chmod 755 /opt/vps-init/modules/lucky/sync-cert.sh
  fi
  cat > /etc/letsencrypt/renewal-hooks/deploy/90-vps-init-lucky <<'HOOK'
#!/usr/bin/env bash
set -e
/opt/vps-init/modules/lucky/sync-cert.sh
HOOK
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/90-vps-init-lucky
  secret_set XUI_PUBLIC_URL "https://${PANEL_DOMAIN}${XUI_WEB_BASE_PATH}"
  secret_set SUBSCRIPTION_BASE_URL "https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}"
  log_ok "Lucky 8443 HTTPS 后端与两个域名反代已配置；公网 443 仍由 Reality 占用。"
}
