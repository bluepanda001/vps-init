#!/usr/bin/env bash
module_cloudflare() {
  profile_has_domain || return 0
  [[ "$DNS_PROVIDER" == "cloudflare" ]] || die "仅支持 Cloudflare。"
  mkdir -p /root/.secrets
  chmod 700 /root/.secrets
  local token_file=/root/.secrets/cloudflare.ini

  # Validate against the actual target zone instead of /user/tokens/verify.
  # This works for both user-owned (cfut_) and account-owned (cfat_) tokens.
  # In interactive mode a bad token is recoverable: never persist it until
  # target-zone access has been proven, and keep prompting until Ctrl+C.
  while true; do
    if [[ -s "$token_file" ]]; then
      chmod 600 "$token_file"
      if python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" verify --zone "$ROOT_DOMAIN" >/dev/null 2>&1; then
        break
      fi
      log_warn "已保存的 Cloudflare Token 无法访问 Active Zone ${ROOT_DOMAIN}，将重新输入。"
      rm -f "$token_file"
    fi

    cat >&2 <<EOF2

Cloudflare 前置条件：
  1. ${ROOT_DOMAIN} 已添加到 Cloudflare；
  2. 域名注册商 Nameserver 已改为 Cloudflare 分配值；
  3. Cloudflare Zone 状态已经是 Active；
  4. Token 必须能读取 ${ROOT_DOMAIN} 并写 DNS（Zone Read + DNS Write）。
EOF2

    [[ -t 0 ]] || die "缺少有效 Cloudflare Token；非交互模式无法安全读取 Token。"

    local cf_token
    read -r -s -p "粘贴 Cloudflare API Token（输入不回显，Ctrl+C 可取消）: " cf_token
    echo
    if [[ -z "$cf_token" ]]; then
      log_warn "Token 为空，请重新输入。"
      continue
    fi

    if CLOUDFLARE_API_TOKEN="$cf_token" \
      python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" verify --zone "$ROOT_DOMAIN" >/dev/null 2>&1; then
      umask 077
      printf 'dns_cloudflare_api_token = %s\n' "$cf_token" > "$token_file"
      chmod 600 "$token_file"
      unset cf_token
      log_ok "Cloudflare Token 已验证，可访问目标 Zone：${ROOT_DOMAIN}"
      break
    fi

    unset cf_token
    log_warn "Token 验证失败；请检查 Token、Zone 范围、Zone Read/DNS Write 权限后重新粘贴。"
  done

  if [[ "$PROFILE" == "lucky-web" ]]; then
    python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" upsert --zone "$ROOT_DOMAIN" --name "$LUCKY_DOMAIN" --ip "$SERVER_IP" >/dev/null
    python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" upsert --zone "$ROOT_DOMAIN" --name "*.$ROOT_DOMAIN" --ip "$SERVER_IP" >/dev/null
    log_ok "Cloudflare DNS 已写入（DNS only）：$LUCKY_DOMAIN / *.$ROOT_DOMAIN -> $SERVER_IP"
  else
    python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" upsert --zone "$ROOT_DOMAIN" --name "$PANEL_DOMAIN" --ip "$SERVER_IP" >/dev/null
    python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" upsert --zone "$ROOT_DOMAIN" --name "$NODE_DOMAIN" --ip "$SERVER_IP" >/dev/null
    log_ok "Cloudflare DNS 已写入（DNS only）：$PANEL_DOMAIN / $NODE_DOMAIN -> $SERVER_IP"
  fi
}
