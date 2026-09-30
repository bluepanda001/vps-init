#!/usr/bin/env bash

optional_cf_ws() {
  local enabled="${ENABLE_CF_WS:-false}"
  local map_file="/etc/nginx/stream-conf.d/vps-init-extra-sni.map"
  local site_file="/etc/nginx/sites-available/vps-init-cf-ws"
  local site_link="/etc/nginx/sites-enabled/vps-init-cf-ws"

  if ! is_true "$enabled"; then
    # Remove only resources owned by this optional module. Keep core
    # Reality/Nginx/Lucky topology untouched.
    if [[ -f "$map_file" ]]; then : > "$map_file"; fi
    rm -f "$site_link" "$site_file"
    # Migration cleanup from the early live-test alias.
    rm -f /etc/nginx/sites-enabled/vps-init-cdn /etc/nginx/sites-available/vps-init-cdn
    if systemctl is-active --quiet nginx 2>/dev/null; then
      nginx -t >/dev/null && systemctl reload nginx
    fi
    return 0
  fi

  profile_has_domain || die "Cloudflare CDN WS 节点只支持带域名的 nginx-reality / lucky-reality Profile。"
  command_exists jq || die "Cloudflare CDN WS 节点需要 jq。"
  systemctl is-active --quiet x-ui || die "3x-ui 未运行，无法创建 CDN WS 入站。"
  systemctl is-active --quiet nginx || die "Nginx 未运行，无法创建 CDN WS 前端。"
  [[ -n "${SUB_ID:-}" ]] || die "SUB_ID 为空，无法把 CDN WS 节点加入同一订阅。"

  state_load
  CF_WS_DOMAIN="${CF_WS_DOMAIN:-${CF_WS_DOMAIN_OVERRIDE:-edge.${ROOT_DOMAIN}}}"
  CF_WS_PATH="${CF_WS_PATH:-}"
  CF_WS_INTERNAL_PORT="${CF_WS_INTERNAL_PORT:-}"
  if [[ -z "$CF_WS_PATH" ]]; then
    CF_WS_PATH="/cdn-$(random_b64url 12 10)/"
  fi
  CF_WS_PATH="$(normalize_path "$CF_WS_PATH")"
  if [[ -z "$CF_WS_INTERNAL_PORT" ]]; then
    CF_WS_INTERNAL_PORT="$(random_port)"
  fi

  local api out inbound_id email
  api="$(xui_base_url)"
  email="vpsinit-cdn-$(random_hex 4)"
  out="$(python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" create-ws \
    --remark VPSINIT-CDN-WS --listen 127.0.0.1 --port "$CF_WS_INTERNAL_PORT" \
    --email "$email" --sub-id "$SUB_ID" --path "$CF_WS_PATH")"
  inbound_id="$(jq -r '.id // empty' <<<"$out")"
  CF_WS_UUID="$(jq -r '.uuid // empty' <<<"$out")"
  [[ "$inbound_id" =~ ^[0-9]+$ ]] || die "CDN WS 入站 ID 未能读取。"
  [[ -n "$CF_WS_UUID" ]] || die "CDN WS UUID 未能读取。"

  python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" ensure-host \
    --inbound-id "$inbound_id" --remark VPSINIT-CDN-Endpoint \
    --address "$CF_WS_DOMAIN" --port 443 --security tls --sni "$CF_WS_DOMAIN" \
    --host-header "$CF_WS_DOMAIN" --path "$CF_WS_PATH" --fingerprint chrome --tags CDN >/dev/null

  python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" upsert \
    --zone "$ROOT_DOMAIN" --name "$CF_WS_DOMAIN" --ip "$SERVER_IP" --proxied >/dev/null

  mkdir -p /etc/nginx/stream-conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled
  printf '"%s" 127.0.0.1:8444; # vps-init cf-ws\n' "$CF_WS_DOMAIN" > "$map_file"

  cat > "$site_file" <<EOF2
# Managed by vps-init optional cf-ws.
# Cloudflare orange-cloud -> public 443 -> Nginx Stream -> loopback TLS 8444
# -> WebSocket path -> 3x-ui bundled Xray VLESS/WS inbound.
server {
    listen 127.0.0.1:8444 ssl;
    server_name ${CF_WS_DOMAIN};

    ssl_certificate ${DOMAIN_CERT_FILE};
    ssl_certificate_key ${DOMAIN_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ ${CF_WS_PATH} {
        proxy_pass http://127.0.0.1:${CF_WS_INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    # Keep the existing Cloudflare-safe panel alias.
    location ^~ ${XUI_WEB_BASE_PATH} {
        proxy_pass http://127.0.0.1:${XUI_PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Separate alias because panel/subscription currently both default to /zhg/.
    location ^~ /sub/ {
        rewrite ^/sub/(.*)$ ${SUBSCRIPTION_PATH}\$1 break;
        proxy_pass http://127.0.0.1:${SUBSCRIPTION_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    root /var/www/vps-init;
    location / { try_files /index.html =404; }
}
EOF2

  ln -sfn "$site_file" "$site_link"
  # Remove the one-off alias from the pre-module live test; its functions are
  # now provided by the managed 8444 server above.
  rm -f /etc/nginx/sites-enabled/vps-init-cdn /etc/nginx/sites-available/vps-init-cdn

  nginx -t
  systemctl reload nginx

  state_set CF_WS_DOMAIN "$CF_WS_DOMAIN"
  state_set CF_WS_PATH "$CF_WS_PATH"
  state_set CF_WS_INTERNAL_PORT "$CF_WS_INTERNAL_PORT"
  state_set CF_WS_UUID "$CF_WS_UUID"
  state_set CF_WS_INBOUND_ID "$inbound_id"

  local path_enc name_enc share_link
  path_enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CF_WS_PATH")"
  name_enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${SERVER_NAME:-VPSINIT}-CDN")"
  share_link="vless://${CF_WS_UUID}@${CF_WS_DOMAIN}:443?type=ws&security=tls&sni=${CF_WS_DOMAIN}&fp=chrome&host=${CF_WS_DOMAIN}&path=${path_enc}#${name_enc}"
  secret_set CF_WS_SHARE_LINK "$share_link"
  secret_set CF_WS_DOMAIN "$CF_WS_DOMAIN"
  log_ok "Cloudflare CDN WS 节点已就绪：${CF_WS_DOMAIN}:443 -> Nginx 8444 -> Xray ${CF_WS_INTERNAL_PORT}${CF_WS_PATH}"
}
