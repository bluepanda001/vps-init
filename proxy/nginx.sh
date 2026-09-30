#!/usr/bin/env bash

proxy_nginx_site() { printf '/etc/nginx/sites-available/vps-init-proxy-%s\n' "$1"; }
proxy_nginx_link() { printf '/etc/nginx/sites-enabled/vps-init-proxy-%s\n' "$1"; }

proxy_nginx_apply() {
  local id="$1" name="$2" domain="$3" scheme="$4" host="$5" port="$6" websocket="$7" host_header="$8" body_size="$9" timeout="${10}" tls_verify="${11}" health_path="${12}" cf_mode="${13}"
  [[ "$PROFILE" == "nginx-reality" ]] || die "v1.3.0 MVP 的 Web Gateway 先支持 nginx-reality；当前 Profile=${PROFILE}。"
  [[ -s "${DOMAIN_CERT_FILE:-}" && -s "${DOMAIN_KEY_FILE:-}" ]] || die "现有 wildcard 证书不可用。"
  systemctl is-active --quiet nginx || die "Nginx 未运行。"
  proxy_domain_allowed "$domain" "$ROOT_DOMAIN" || die "当前 wildcard 证书只支持 ${ROOT_DOMAIN} 或一级子域名 *.${ROOT_DOMAIN}。"
  proxy_upstream_reachable "$scheme" "$host" "$port" "$health_path" "$tls_verify" || die "上游不可访问：${scheme}://${host}:${port}${health_path}"

  local site link
  site="$(proxy_nginx_site "$id")"
  link="$(proxy_nginx_link "$id")"
  [[ -n "$host_header" ]] || host_header="$domain"

  cat > "$site" <<EOF2
# Managed by vps-init reverse proxy center: ${id}
# Name: ${name}
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
    client_max_body_size ${body_size};

    location / {
        proxy_pass ${scheme}://${host}:${port};
        proxy_http_version 1.1;
        proxy_set_header Host ${host_header};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout ${timeout}s;
        proxy_send_timeout ${timeout}s;
EOF2
  if is_true "$websocket"; then
    cat >> "$site" <<'EOF2'
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
EOF2
  fi
  if [[ "$scheme" == "https" ]]; then
    cat >> "$site" <<EOF2
        proxy_ssl_server_name on;
        proxy_ssl_name ${host};
        proxy_ssl_verify $(is_true "$tls_verify" && echo on || echo off);
EOF2
  fi
  cat >> "$site" <<'EOF2'
    }
}
EOF2

  ln -sfn "$site" "$link"
  nginx -t
  systemctl reload nginx

  case "$cf_mode" in
    proxied)
      python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" upsert --zone "$ROOT_DOMAIN" --name "$domain" --ip "$SERVER_IP" --proxied >/dev/null
      ;;
    dns-only)
      python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" upsert --zone "$ROOT_DOMAIN" --name "$domain" --ip "$SERVER_IP" >/dev/null
      ;;
    none) ;;
    *) die "未知 Cloudflare 模式：$cf_mode" ;;
  esac

  proxy_state_set "$id" PROXY_ID "$id"
  proxy_state_set "$id" PROXY_NAME "$name"
  proxy_state_set "$id" PROVIDER "nginx"
  proxy_state_set "$id" DOMAIN "$domain"
  proxy_state_set "$id" UPSTREAM_SCHEME "$scheme"
  proxy_state_set "$id" UPSTREAM_HOST "$host"
  proxy_state_set "$id" UPSTREAM_PORT "$port"
  proxy_state_set "$id" WEBSOCKET "$websocket"
  proxy_state_set "$id" HOST_HEADER "$host_header"
  proxy_state_set "$id" CLIENT_MAX_BODY_SIZE "$body_size"
  proxy_state_set "$id" TIMEOUT_SECONDS "$timeout"
  proxy_state_set "$id" UPSTREAM_TLS_VERIFY "$tls_verify"
  proxy_state_set "$id" HEALTH_PATH "$health_path"
  proxy_state_set "$id" CLOUDFLARE_MODE "$cf_mode"
  proxy_state_set "$id" PUBLIC_URL "https://${domain}"
  proxy_state_set "$id" UPDATED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

proxy_nginx_verify_local() {
  local id="$1"
  proxy_state_load "$id" || return 1
  nginx -t >/dev/null 2>&1 || return 1
  [[ -L "$(proxy_nginx_link "$id")" ]] || return 1
  proxy_upstream_reachable "$UPSTREAM_SCHEME" "$UPSTREAM_HOST" "$UPSTREAM_PORT" "$HEALTH_PATH" "$UPSTREAM_TLS_VERIFY" || return 1
  curl -kfsS -o /dev/null --max-time 10 --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}${HEALTH_PATH}"
}

proxy_nginx_verify_public() {
  local id="$1" i
  proxy_state_load "$id" || return 1
  for i in {1..20}; do
    if curl -fsS -o /dev/null --max-time 12 "https://${DOMAIN}${HEALTH_PATH}" 2>/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}

proxy_nginx_remove() {
  local id="$1"
  proxy_state_load "$id" || die "反代 ${id} 不存在。"
  rm -f "$(proxy_nginx_link "$id")" "$(proxy_nginx_site "$id")"
  nginx -t
  systemctl reload nginx
  rm -f "$(proxy_state_file "$id")"
}
