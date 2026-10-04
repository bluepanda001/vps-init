#!/usr/bin/env bash

mihomo_body_direct() {
  curl -fsS --max-time 12 \
    -A 'mihomo/vps-init-verify' \
    --connect-to "${SERVER_IP}:${SUBSCRIPTION_PORT}:127.0.0.1:${SUBSCRIPTION_PORT}" \
    "https://${SERVER_IP}:${SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}${SUB_ID}"
}

mihomo_body_domain() {
  curl -fsS --max-time 12 \
    -A 'mihomo/vps-init-verify' \
    --resolve "${NODE_DOMAIN}:443:127.0.0.1" \
    "https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}${SUB_ID}"
}

verify_mihomo_direct() {
  local body
  body="$(mihomo_body_direct)" || return 1
  grep -E '^(proxies|proxy-groups|rules):' <<<"$body" >/dev/null
}

verify_mihomo_domain() {
  local body
  body="$(mihomo_body_domain)" || return 1
  grep -E '^(proxies|proxy-groups|rules):' <<<"$body" >/dev/null
}


verify_explicit_clash_direct() {
  curl -fsS --max-time 12     --connect-to "${SERVER_IP}:${SUBSCRIPTION_PORT}:127.0.0.1:${SUBSCRIPTION_PORT}"     "https://${SERVER_IP}:${SUBSCRIPTION_PORT}/clash/${SUB_ID}" |
    grep -E '^(proxies|proxy-groups|rules):' >/dev/null
}

verify_explicit_clash_domain() {
  curl -fsS --max-time 12     --resolve "${NODE_DOMAIN}:443:127.0.0.1"     "https://${NODE_DOMAIN}/clash/${SUB_ID}" |
    grep -E '^(proxies|proxy-groups|rules):' >/dev/null
}

verify_reality_abuse_protection() {
  local api rows
  api="$(xui_base_url)"
  rows="$(python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" list-inbounds)" || return 1
  jq -e     --argjson after "$REALITY_FALLBACK_AFTER_BYTES"     --argjson up "$REALITY_FALLBACK_UPLOAD_BPS"     --argjson down "$REALITY_FALLBACK_DOWNLOAD_BPS"     '
      [.[] | select(.remark=="VPSINIT-Reality")][0] as $i
      | ($i != null)
      and (($i.streamSettings.realitySettings.target // $i.streamSettings.realitySettings.dest // "") | ascii_downcase | test("(^|\\.)cloudflare\\.(com|net)(:|$)|(^|\\.)(workers|pages)\\.dev(:|$)") | not)
      and (($i.streamSettings.realitySettings.limitFallbackUpload.afterBytes // -1) == $after)
      and (($i.streamSettings.realitySettings.limitFallbackUpload.bytesPerSec // -1) == $up)
      and (($i.streamSettings.realitySettings.limitFallbackDownload.afterBytes // -1) == $after)
      and (($i.streamSettings.realitySettings.limitFallbackDownload.bytesPerSec // -1) == $down)
    ' <<<"$rows" >/dev/null
}


verify_lucky_safe_url() {
  local actual expected
  expected="${LUCKY_SAFE_URL:-zhg}"
  actual="$(/opt/lucky/lucky -baseConfInfo -cd /opt/lucky 2>/dev/null | jq -r '.BaseConfigure.SafeURL // empty' | sed 's#^/##' | tail -1)"
  [[ "$actual" == "$expected" ]]
}

verify_mihomo_public_endpoint() {
  local body expected_server
  if [[ "$SUBSCRIPTION_EXPOSE_MODE_RESOLVED" == direct-ip-https ]]; then
    body="$(mihomo_body_direct)" || return 1
  else
    body="$(mihomo_body_domain)" || return 1
  fi
  if [[ "$PROFILE" == "reality-only" ]]; then
    expected_server="$SERVER_IP"
  else
    expected_server="$NODE_DOMAIN"
  fi
  grep -F "  server: ${expected_server}" <<<"$body" >/dev/null &&
    grep -F '  port: 443' <<<"$body" >/dev/null
}

verify_reality_handshake() {
  [[ -x "${XUI_XRAY_BIN:-}" ]] || return 1
  [[ -n "${REALITY_UUID:-}" && -n "${REALITY_PUBLIC_KEY:-}" && -n "${REALITY_SHORT_ID:-}" && -n "${REALITY_SERVER_NAME:-}" ]] || return 1

  local td cfg logf pid rc=1 socks_port=19080 i
  td="$(mktemp -d)"
  cfg="$td/client.json"
  logf="$td/xray.log"
  chmod 700 "$td"

  jq -n \
    --arg uuid "$REALITY_UUID" \
    --arg pbk "$REALITY_PUBLIC_KEY" \
    --arg sid "$REALITY_SHORT_ID" \
    --arg sni "$REALITY_SERVER_NAME" \
    --argjson socks "$socks_port" \
    '{
      log:{loglevel:"warning"},
      inbounds:[{listen:"127.0.0.1",port:$socks,protocol:"socks",settings:{udp:false}}],
      outbounds:[{
        tag:"proxy",protocol:"vless",
        settings:{address:"127.0.0.1",port:443,id:$uuid,encryption:"none",flow:"xtls-rprx-vision"},
        streamSettings:{network:"tcp",security:"reality",realitySettings:{
          serverName:$sni,fingerprint:"chrome",publicKey:$pbk,shortId:$sid,spiderX:"/"
        }}
      }]
    }' > "$cfg" || { rm -rf "$td"; return 1; }
  chmod 600 "$cfg"

  "$XUI_XRAY_BIN" run -test -c "$cfg" >/dev/null 2>&1 || { rm -rf "$td"; return 1; }
  "$XUI_XRAY_BIN" run -c "$cfg" >"$logf" 2>&1 &
  pid=$!
  for i in {1..20}; do
    if ss -H -ltn "sport = :${socks_port}" 2>/dev/null | grep . >/dev/null; then break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.15
  done
  if curl --socks5-hostname "127.0.0.1:${socks_port}" -fsS -o /dev/null --max-time 15 https://www.google.com/generate_204; then
    rc=0
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$td"
  return "$rc"
}


verify_cf_ws_handshake() {
  is_true "${ENABLE_CF_WS:-false}" || return 0
  [[ -x "${XUI_XRAY_BIN:-}" ]] || return 1
  [[ -n "${CF_WS_UUID:-}" && -n "${CF_WS_DOMAIN:-}" && -n "${CF_WS_PATH:-}" ]] || return 1

  local td cfg logf pid rc=1 socks_port=19081 i
  td="$(mktemp -d)"
  cfg="$td/client.json"
  logf="$td/xray.log"
  chmod 700 "$td"

  jq -n \
    --arg uuid "$CF_WS_UUID" \
    --arg host "$CF_WS_DOMAIN" \
    --arg path "$CF_WS_PATH" \
    --argjson socks "$socks_port" \
    '{
      log:{loglevel:"warning"},
      inbounds:[{listen:"127.0.0.1",port:$socks,protocol:"socks",settings:{udp:false}}],
      outbounds:[{
        tag:"proxy",protocol:"vless",
        settings:{address:$host,port:443,id:$uuid,encryption:"none"},
        streamSettings:{
          network:"ws",security:"tls",
          tlsSettings:{serverName:$host,fingerprint:"chrome",allowInsecure:false},
          wsSettings:{path:$path,headers:{Host:$host}}
        }
      }]
    }' > "$cfg" || { rm -rf "$td"; return 1; }
  chmod 600 "$cfg"

  "$XUI_XRAY_BIN" run -test -c "$cfg" >/dev/null 2>&1 || { rm -rf "$td"; return 1; }
  "$XUI_XRAY_BIN" run -c "$cfg" >"$logf" 2>&1 &
  pid=$!
  for i in {1..20}; do
    if ss -H -ltn "sport = :${socks_port}" 2>/dev/null | grep . >/dev/null; then break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.15
  done
  if curl --socks5-hostname "127.0.0.1:${socks_port}" -fsS -o /dev/null --max-time 20 https://www.google.com/generate_204; then
    rc=0
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$td"
  return "$rc"
}

verify_cf_ws_subscription() {
  local body
  body="$(mihomo_body_domain)" || return 1
  grep -F "  server: ${CF_WS_DOMAIN}" <<<"$body" >/dev/null &&
    grep -F '  port: 443' <<<"$body" >/dev/null &&
    grep -F '  network: ws' <<<"$body" >/dev/null &&
    grep -F "    path: ${CF_WS_PATH}" <<<"$body" >/dev/null
}

verify_cf_ws_dns_is_proxied() {
  local ips
  ips="$(getent ahostsv4 "$CF_WS_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)"
  [[ -n "$ips" ]] || return 1
  ! grep -Fx "$SERVER_IP" <<<"$ips" >/dev/null
}

verify_all() {
  state_load
  local failed=0 out="" cc qdisc sshd_effective
  check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then printf '[OK]   %s\n' "$name"; else printf '[FAIL] %s\n' "$name"; failed=1; fi; }
  {
    echo "VPS Init Verification Report"
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Profile: $PROFILE"
    echo "Server: ${SERVER_NAME:-}"
    echo "IPv4: ${SERVER_IP:-unknown}"
    echo "Default interface: ${DEFAULT_INTERFACE:-unknown}"
    echo
    echo "== System =="
    echo "OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
    echo "Kernel: $(uname -r)"
    echo "Memory: $(awk '/MemTotal/{printf "%.0f MiB",$2/1024}' /proc/meminfo)"
    echo "Swap: $(swapon --show --bytes --noheadings | awk '{s+=$3} END{printf "%.0f MiB",s/1024/1024}')"
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true); qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    echo "TCP congestion: $cc"
    echo "Default qdisc: $qdisc"
    echo "Timezone: $(timedatectl show -p Timezone --value 2>/dev/null || true)"
    echo
    echo "== Checks =="
    check "sshd syntax" sshd -t
    check "SSH IPv4 listener on ${SSH_PORT}" bash -c "ss -H -ltn4 'sport = :${SSH_PORT}' | grep . >/dev/null"
    sshd_effective="$(sshd -T)"
    if grep -qi '^passwordauthentication no$' <<<"$sshd_effective"; then echo '[OK]   SSH password auth disabled'; else echo '[FAIL] SSH password auth still enabled'; failed=1; fi
    if grep -qi '^pubkeyauthentication yes$' <<<"$sshd_effective"; then echo '[OK]   SSH pubkey auth enabled'; else echo '[FAIL] SSH pubkey auth disabled'; failed=1; fi
    if grep -Eqi '^permitrootlogin (prohibit-password|without-password)$' <<<"$sshd_effective"; then echo '[OK]   root SSH is key-only'; else echo '[FAIL] root SSH policy is not key-only'; failed=1; fi
    check "UFW active" bash -c "ufw status | grep '^Status: active' >/dev/null"
    check "Fail2ban active" systemctl is-active --quiet fail2ban
    check "Unattended upgrades active" systemctl is-active --quiet unattended-upgrades
    [[ "$cc" == bbr ]] && echo '[OK]   BBR active' || echo '[WARN] BBR not active'
    [[ "$qdisc" == fq ]] && echo '[OK]   fq qdisc active' || echo '[WARN] fq qdisc not active'

    if profile_has_xui; then
      check "3x-ui service" systemctl is-active --quiet x-ui
      if [[ "${XUI_VERSION:-}" == "3.8.5" ]]; then echo '[OK]   3x-ui pinned version 3.8.5'; else echo "[FAIL] 3x-ui version state: ${XUI_VERSION:-unknown}"; failed=1; fi
      [[ -n "${XUI_XRAY_BIN:-}" && "$XUI_XRAY_BIN" == /usr/local/x-ui/bin/* ]] && echo '[OK]   Xray is bundled 3x-ui binary' || { echo '[FAIL] Xray binary is not recorded under 3x-ui'; failed=1; }
      echo "3x-ui panel listener: 127.0.0.1:${XUI_PANEL_PORT:-unknown}"
      echo "Reality target: ${REALITY_TARGET_SELECTED:-unknown}"
      echo "Reality SNI: ${REALITY_SERVER_NAME:-unknown}"
      if [[ "$PROFILE" == "nginx-reality" || "$PROFILE" == "lucky-reality" ]]; then
        check "443 owned by nginx" bash -c "ss -H -ltnp 'sport = :443' | grep -i nginx >/dev/null"
        check "Reality internal 1443 listening" bash -c "ss -H -ltnp 'sport = :1443' | grep -i xray >/dev/null"
      elif [[ "$PROFILE" == "reality-only" ]]; then
        check "443 owned by Xray" bash -c "ss -H -ltnp 'sport = :443' | grep -i xray >/dev/null"
      fi
      check "Reality end-to-end handshake" verify_reality_handshake
      check "Reality target / fallback abuse protection" verify_reality_abuse_protection
      if is_true "$ENABLE_SUBSCRIPTION_RESOLVED"; then
        if [[ "$SUBSCRIPTION_EXPOSE_MODE_RESOLVED" == direct-ip-https ]]; then
          check "IP certificate valid >24h" openssl x509 -checkend 86400 -noout -in "$IP_CERT_FILE"
          if [[ -n "${SUB_ID:-}" ]]; then
            check "public IP HTTPS subscription" curl -fsS --max-time 10 --connect-to "${SERVER_IP}:${SUBSCRIPTION_PORT}:127.0.0.1:${SUBSCRIPTION_PORT}" -o /dev/null "https://${SERVER_IP}:${SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}${SUB_ID}"
            check "Mihomo UA receives Clash YAML" verify_mihomo_direct
            check "explicit Clash/Mihomo subscription" verify_explicit_clash_direct
            check "Mihomo subscription advertises public Reality endpoint" verify_mihomo_public_endpoint
          fi
          echo "Subscription: https://${SERVER_IP}:${SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}<client-sub-id>"
        else
          check "Wildcard certificate valid >7d" openssl x509 -checkend 604800 -noout -in "$DOMAIN_CERT_FILE"
          check "subscription backend loopback HTTP" curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}${SUB_ID}"
          check "public HTTPS subscription through 443" curl -fsS --max-time 10 --resolve "${NODE_DOMAIN}:443:127.0.0.1" -o /dev/null "https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}${SUB_ID}"
          check "Mihomo UA receives Clash YAML" verify_mihomo_domain
          check "explicit Clash/Mihomo subscription" verify_explicit_clash_domain
          check "Mihomo subscription advertises public Reality endpoint" verify_mihomo_public_endpoint
          echo "Subscription: https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}<client-sub-id>"
        fi
      fi
    fi
    if profile_has_domain && profile_has_xui; then
      check "public HTTPS panel through 443" curl -fsS --max-time 10 --resolve "${PANEL_DOMAIN}:443:127.0.0.1" -o /dev/null "https://${PANEL_DOMAIN}${XUI_WEB_BASE_PATH}"
    fi
    if is_true "${ENABLE_CF_WS:-false}"; then
      echo "CDN WS endpoint: ${CF_WS_DOMAIN:-unknown}:443${CF_WS_PATH:-}"
      check "CDN WS Xray loopback listener" bash -c "ss -H -ltnp 'sport = :${CF_WS_INTERNAL_PORT}' | grep -i xray >/dev/null"
      check "CDN WS Nginx TLS frontend 8444" bash -c "ss -H -ltnp 'sport = :8444' | grep -i nginx >/dev/null"
      check "CDN WS SNI stream mapping" grep -F "${CF_WS_DOMAIN}" /etc/nginx/stream-conf.d/vps-init-extra-sni.map
      check "Cloudflare CDN DNS is proxied" verify_cf_ws_dns_is_proxied
      check "public Cloudflare HTTPS frontend" curl -fsS --max-time 15 -o /dev/null "https://${CF_WS_DOMAIN}${XUI_WEB_BASE_PATH}"
      check "Mihomo subscription advertises CDN WS endpoint" verify_cf_ws_subscription
      check "Cloudflare CDN WS end-to-end proxy" verify_cf_ws_handshake
    fi
    if [[ "$PROFILE" == nginx-reality || "$PROFILE" == lucky-reality ]]; then
      check "nginx stream ssl_preread support" bash -c "nginx -V 2>&1 | grep -- '--with-stream_ssl_preread_module' >/dev/null"
      check "nginx syntax" nginx -t
      check "nginx active" systemctl is-active --quiet nginx
    fi
    if [[ "$PROFILE" == lucky-reality ]]; then
      check "Lucky active" systemctl is-active --quiet lucky
      check "Lucky SafeURL" verify_lucky_safe_url
      check "Lucky HTTPS backend 8443 listening" bash -c "ss -H -ltn 'sport = :8443' | grep . >/dev/null"
    elif [[ "$PROFILE" == lucky-web ]]; then
      check "Wildcard certificate valid >7d" openssl x509 -checkend 604800 -noout -in "$DOMAIN_CERT_FILE"
      check "Lucky active" systemctl is-active --quiet lucky
      check "Lucky SafeURL" verify_lucky_safe_url
      check "Lucky owns public 443" bash -c "ss -H -ltnp 'sport = :443' | grep -i lucky >/dev/null"
      check "Lucky local admin API" curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:16601/version"
      check "Lucky safe local admin path" curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:16601/${LUCKY_SAFE_URL:-zhg}"
      check "Lucky public admin domain HTTPS" curl -fsS --max-time 10 --resolve "${LUCKY_DOMAIN}:443:127.0.0.1" -o /dev/null "https://${LUCKY_DOMAIN}/${LUCKY_SAFE_URL:-zhg}"
      check "3x-ui not active" bash -c "! systemctl is-active --quiet x-ui 2>/dev/null"
      check "Nginx not active" bash -c "! systemctl is-active --quiet nginx 2>/dev/null"
    fi
    if is_true "$ENABLE_DOCKER"; then check "Docker active" systemctl is-active --quiet docker; fi
    echo
    echo "== Listening TCP ports =="
    ss -ltnp 2>/dev/null || true
    echo
    echo "== UFW =="
    ufw status verbose || true
    echo
    echo "Secrets are intentionally excluded. See $SECRETS_FILE (root-only)."
  } > "$REPORT_FILE"
  chmod 600 "$REPORT_FILE"
  cat "$REPORT_FILE"
  if (( failed )); then log_warn "验收有失败项，报告：$REPORT_FILE"; return 1; fi
  log_ok "验收通过。报告：$REPORT_FILE"
}
