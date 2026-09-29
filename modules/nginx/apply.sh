#!/usr/bin/env bash
module_nginx() {
  [[ "$PROFILE" == "nginx-reality" || "$PROFILE" == "lucky-reality" ]] || return 0
  apt-get install -y nginx libnginx-mod-stream
  nginx -V 2>&1 | grep -q -- '--with-stream_ssl_preread_module' || \
    die "当前 Nginx 构建不支持 stream ssl_preread，拒绝继续域名 443 分流。"
  mkdir -p /etc/nginx/stream-conf.d /var/www/vps-init
  install -m 644 "$ROOT_DIR/templates/index.html" /var/www/vps-init/index.html
  backup_file /etc/nginx/nginx.conf
  if ! grep -q 'vps-init stream include' /etc/nginx/nginx.conf; then
    cat >> /etc/nginx/nginx.conf <<'NGINX'

# vps-init stream include
stream {
    include /etc/nginx/stream-conf.d/*.conf;
}
NGINX
  fi

  cat > /etc/nginx/stream-conf.d/vps-init.conf <<EOF2
# Managed by vps-init.
# REALITY uses its camouflage SNI; all other TLS goes to the HTTPS backend.
map \$ssl_preread_server_name \$vpsinit_backend {
    "${REALITY_SERVER_NAME}" 127.0.0.1:1443;
    default 127.0.0.1:8443;
}
server {
    listen 443;
    listen [::]:443;
    proxy_pass \$vpsinit_backend;
    ssl_preread on;
    proxy_connect_timeout 5s;
    proxy_timeout 300s;
}
EOF2

  rm -f /etc/nginx/sites-enabled/default
  if [[ "$PROFILE" == "nginx-reality" ]]; then
    cat > /etc/nginx/sites-available/vps-init <<EOF2
# Managed by vps-init. TLS terminates here after Stream routes normal HTTPS to 8443.
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN} ${NODE_DOMAIN};
    return 308 https://\$host\$request_uri;
}
server {
    listen 127.0.0.1:8443 ssl default_server;
    server_name _;
    ssl_certificate ${DOMAIN_CERT_FILE};
    ssl_certificate_key ${DOMAIN_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/vps-init;
    location / { try_files /index.html =404; }
}
server {
    listen 127.0.0.1:8443 ssl;
    server_name ${PANEL_DOMAIN};
    ssl_certificate ${DOMAIN_CERT_FILE};
    ssl_certificate_key ${DOMAIN_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:${XUI_PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
server {
    listen 127.0.0.1:8443 ssl;
    server_name ${NODE_DOMAIN};
    ssl_certificate ${DOMAIN_CERT_FILE};
    ssl_certificate_key ${DOMAIN_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:${SUBSCRIPTION_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF2
  else
    cat > /etc/nginx/sites-available/vps-init <<EOF2
# Managed by vps-init. Lucky terminates HTTPS on loopback :8443.
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN} ${NODE_DOMAIN};
    return 308 https://\$host\$request_uri;
}
EOF2
  fi

  ln -sfn /etc/nginx/sites-available/vps-init /etc/nginx/sites-enabled/vps-init
  nginx -t
  systemctl enable nginx
  systemctl restart nginx

  cat > /etc/letsencrypt/renewal-hooks/deploy/90-vps-init-nginx <<'HOOK'
#!/usr/bin/env bash
set -e
nginx -t && systemctl reload nginx
HOOK
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/90-vps-init-nginx
  secret_set XUI_PUBLIC_URL "https://${PANEL_DOMAIN}${XUI_WEB_BASE_PATH}"
  secret_set SUBSCRIPTION_BASE_URL "https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}"
  if [[ "$PROFILE" == "lucky-reality" ]]; then
    log_ok "Nginx Stream 443 SNI 分流已配置：Reality -> 1443，普通 HTTPS -> Lucky 8443。"
  else
    log_ok "Nginx Stream 443 SNI 分流已配置。"
  fi
}
