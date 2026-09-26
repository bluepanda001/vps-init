#!/usr/bin/env bash
verify_mihomo_direct() {
  curl -fsS --max-time 12 \
    -A 'mihomo/vps-init-verify' \
    --connect-to "${SERVER_IP}:${SUBSCRIPTION_PORT}:127.0.0.1:${SUBSCRIPTION_PORT}" \
    "https://${SERVER_IP}:${SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}${SUB_ID}" \
    | grep -Eq '^(proxies|proxy-groups|rules):'
}

verify_mihomo_domain() {
  curl -fsS --max-time 12 \
    -A 'mihomo/vps-init-verify' \
    --resolve "${NODE_DOMAIN}:443:127.0.0.1" \
    "https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}${SUB_ID}" \
    | grep -Eq '^(proxies|proxy-groups|rules):'
}

verify_all() {
  state_load
  local failed=0 out="" cc qdisc
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
    if sshd -T | grep -qi '^passwordauthentication no$'; then echo '[OK]   SSH password auth disabled'; else echo '[FAIL] SSH password auth still enabled'; failed=1; fi
    if sshd -T | grep -qi '^pubkeyauthentication yes$'; then echo '[OK]   SSH pubkey auth enabled'; else echo '[FAIL] SSH pubkey auth disabled'; failed=1; fi
    if sshd -T | grep -Eqi '^permitrootlogin (prohibit-password|without-password)$'; then echo '[OK]   root SSH is key-only'; else echo '[FAIL] root SSH policy is not key-only'; failed=1; fi
    check "UFW active" bash -c "ufw status | grep -q '^Status: active'"
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
      if [[ "$PROFILE" == "nginx-reality" ]]; then
        check "443 owned by nginx" bash -c "ss -H -ltnp 'sport = :443' | grep -qi nginx"
        check "Reality internal 1443 listening" bash -c "ss -H -ltnp 'sport = :1443' | grep -qi xray"
      elif [[ "$PROFILE" == "reality-only" || "$PROFILE" == "lucky-reality" ]]; then
        check "443 owned by Xray" bash -c "ss -H -ltnp 'sport = :443' | grep -qi xray"
      fi
      if is_true "$ENABLE_SUBSCRIPTION_RESOLVED"; then
        if [[ "$SUBSCRIPTION_EXPOSE_MODE_RESOLVED" == direct-ip-https ]]; then
          check "IP certificate valid >24h" openssl x509 -checkend 86400 -noout -in "$IP_CERT_FILE"
          if [[ -n "${SUB_ID:-}" ]]; then
            check "public IP HTTPS subscription" curl -fsS --max-time 10 --connect-to "${SERVER_IP}:${SUBSCRIPTION_PORT}:127.0.0.1:${SUBSCRIPTION_PORT}" -o /dev/null "https://${SERVER_IP}:${SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}${SUB_ID}"
            check "Mihomo UA receives Clash YAML" verify_mihomo_direct
          fi
          echo "Subscription: https://${SERVER_IP}:${SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}<client-sub-id>"
        else
          check "Wildcard certificate valid >7d" openssl x509 -checkend 604800 -noout -in "$DOMAIN_CERT_FILE"
          check "subscription backend loopback HTTP" curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${SUBSCRIPTION_PORT}${SUBSCRIPTION_PATH}${SUB_ID}"
          check "public HTTPS subscription through 443" curl -fsS --max-time 10 --resolve "${NODE_DOMAIN}:443:127.0.0.1" -o /dev/null "https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}${SUB_ID}"
          check "Mihomo UA receives Clash YAML" verify_mihomo_domain
          echo "Subscription: https://${NODE_DOMAIN}${SUBSCRIPTION_PATH}<client-sub-id>"
        fi
      fi
    fi
    if profile_has_domain && profile_has_xui; then
      check "public HTTPS panel through 443" curl -fsS --max-time 10 --resolve "${PANEL_DOMAIN}:443:127.0.0.1" -o /dev/null "https://${PANEL_DOMAIN}${XUI_WEB_BASE_PATH}"
    fi
    if [[ "$PROFILE" == nginx-reality ]]; then
      check "nginx syntax" nginx -t
      check "nginx active" systemctl is-active --quiet nginx
    fi
    if [[ "$PROFILE" == lucky-reality ]]; then
      check "Lucky active" systemctl is-active --quiet lucky
      check "Lucky HTTPS backend 8443 listening" bash -c "ss -H -ltn 'sport = :8443' | grep -q ."
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
