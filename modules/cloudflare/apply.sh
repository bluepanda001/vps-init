#!/usr/bin/env bash
module_cloudflare() {
  profile_has_domain || return 0
  [[ "$DNS_PROVIDER" == "cloudflare" ]] || die "仅支持 Cloudflare。"
  mkdir -p /root/.secrets; chmod 700 /root/.secrets
  local token_file=/root/.secrets/cloudflare.ini
  if [[ ! -s "$token_file" ]]; then
    cat >&2 <<EOF2

Cloudflare 前置条件：
  1. ${ROOT_DOMAIN} 已添加到 Cloudflare；
  2. 域名注册商 Nameserver 已改为 Cloudflare 分配值；
  3. Cloudflare Zone 状态已经是 Active；
  4. 创建仅限 ${ROOT_DOMAIN} 的 API Token，权限至少：Zone Read + DNS Write。
EOF2
    if [[ ! -t 0 ]]; then die "缺少 $token_file；非交互模式无法安全读取 Token。"; fi
    local cf_token
    read -r -s -p "粘贴 Cloudflare API Token（输入不回显）: " cf_token; echo
    [[ -n "$cf_token" ]] || die "Token 为空。"
    umask 077
    printf 'dns_cloudflare_api_token = %s\n' "$cf_token" > "$token_file"
    unset cf_token
  fi
  chmod 600 "$token_file"
  python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" verify >/dev/null || die "Cloudflare Token 验证失败。"
  python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" upsert --zone "$ROOT_DOMAIN" --name "$PANEL_DOMAIN" --ip "$SERVER_IP" >/dev/null
  python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" upsert --zone "$ROOT_DOMAIN" --name "$NODE_DOMAIN" --ip "$SERVER_IP" >/dev/null
  log_ok "Cloudflare DNS 已写入（DNS only）：$PANEL_DOMAIN / $NODE_DOMAIN -> $SERVER_IP"
}
