#!/usr/bin/env bash

gateway_nginx_add() {
  local app_id="$1" domain="$2" port="$3" websocket="${4:-true}"
  [[ "$PROFILE" == "nginx-reality" ]] || die "当前 Profile=${PROFILE} 暂不使用 Nginx HTTP Gateway；v1.3.0 MVP 先支持 nginx-reality。"
  app_validate_domain "$domain" || die "应用域名无效：$domain"
  [[ -n "${DOMAIN_CERT_FILE:-}" && -s "$DOMAIN_CERT_FILE" ]] || die "缺少现有 wildcard 证书。"
  [[ -n "${DOMAIN_KEY_FILE:-}" && -s "$DOMAIN_KEY_FILE" ]] || die "缺少现有 wildcard 私钥。"
  systemctl is-active --quiet nginx || die "Nginx 未运行。"

  local site="/etc/nginx/sites-available/vps-init-app-${app_id}"
  local link="/etc/nginx/sites-enabled/vps-init-app-${app_id}"

  cat > "$site" <<EOF2
# Managed by vps-init app center: ${app_id}
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 308 https://\$host\$request_uri;
}
server {
    listen 127.0.0.1:8443 ssl;
    server_name ${domain};

    ssl_certificate ${DOMAIN_CERT_FILE};
    ssl_certificate_key ${DOMAIN_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
EOF2
  if is_true "$websocket"; then
    cat >> "$site" <<'EOF2'
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
EOF2
  fi
  cat >> "$site" <<'EOF2'
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF2

  ln -sfn "$site" "$link"
  nginx -t
  systemctl reload nginx

  python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" upsert \
    --zone "$ROOT_DOMAIN" --name "$domain" --ip "$SERVER_IP" --proxied >/dev/null

  app_state_set "$app_id" PROXY_PROVIDER "nginx"
  app_state_set "$app_id" PROXY_ENABLED "true"
  app_state_set "$app_id" DOMAIN "$domain"
  app_state_set "$app_id" CF_PROXY "true"
  app_state_set "$app_id" PUBLIC_URL "https://${domain}"
}

gateway_nginx_remove() {
  local app_id="$1"
  rm -f "/etc/nginx/sites-enabled/vps-init-app-${app_id}" \
        "/etc/nginx/sites-available/vps-init-app-${app_id}"
  if systemctl is-active --quiet nginx 2>/dev/null; then
    nginx -t && systemctl reload nginx
  fi
}

gateway_nginx_verify() {
  local app_id="$1" domain="$2" i
  [[ -L "/etc/nginx/sites-enabled/vps-init-app-${app_id}" ]] || return 1
  nginx -t >/dev/null 2>&1 || return 1
  for i in {1..20}; do
    if curl -fsS -o /dev/null --max-time 12 "https://${domain}/" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}
