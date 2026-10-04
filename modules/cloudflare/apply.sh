#!/usr/bin/env bash
module_cloudflare() {
  profile_has_domain || return 0
  [[ "$DNS_PROVIDER" == "cloudflare" ]] || die "仅支持 Cloudflare。"
  local token_file="${VPSINIT_CLOUDFLARE_TOKEN_FILE:-/root/.secrets/cloudflare.ini}"
  mkdir -p "$(dirname "$token_file")"
  chmod 700 "$(dirname "$token_file")"

  # Validate against the actual target zone instead of /user/tokens/verify.
  # This works for both user-owned (cfut_) and account-owned (cfat_) tokens.
  # In interactive mode a bad token is recoverable: never persist it until
  # target-zone access has been proven, and keep prompting until Ctrl+C.
  while true; do
    if [[ -s "$token_file" ]]; then
      chmod 600 "$token_file"
      local saved_rc=0
      if python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" verify --zone "$ROOT_DOMAIN" >/dev/null 2>&1; then
        break
      else
        saved_rc=$?
      fi
      case "$saved_rc" in
        11)
          die "Cloudflare 临时不可用/网络异常；已保留现有 Token 文件，不会覆盖。稍后直接重跑即可。"
          ;;
        10)
          log_warn "已保存的 Cloudflare Token 鉴权失败；旧文件暂时保留，只有新 Token 验证成功后才会替换。"
          ;;
        *)
          log_warn "已保存的 Cloudflare Token 无法访问 Active Zone ${ROOT_DOMAIN}；旧文件暂时保留，只有新 Token 验证成功后才会替换。"
          ;;
      esac
    fi

    cat >&2 <<EOF2

Cloudflare 前置条件：
  1. ${ROOT_DOMAIN} 已添加到 Cloudflare；
  2. 域名注册商 Nameserver 已改为 Cloudflare 分配值；
  3. Cloudflare Zone 状态已经是 Active；
  4. Token 必须能读取 ${ROOT_DOMAIN} 并写 DNS（Zone Read + DNS Write）。

Cloudflare API Token 创建页面：
  https://dash.cloudflare.com/profile/api-tokens

推荐创建方式：
  Create Token -> Edit zone DNS 模板
  Zone Resources -> 只选择 ${ROOT_DOMAIN}

需要权限：
  Zone / Zone / Read
  Zone / DNS / Edit

提示：大多数终端可直接 Ctrl+点击上面的 https:// 地址；如果不能，复制到本机浏览器打开。
EOF2

    [[ -t 0 ]] || die "缺少有效 Cloudflare Token；非交互模式无法安全读取 Token。"

    local cf_token
    read -r -s -p "粘贴 Cloudflare API Token（输入不回显，Ctrl+C 可取消）: " cf_token
    echo
    if [[ -z "$cf_token" ]]; then
      log_warn "Token 为空，请重新输入。"
      continue
    fi

    local new_rc=0
    if CLOUDFLARE_API_TOKEN="$cf_token" \
      python3 "$ROOT_DIR/modules/cloudflare/cloudflare.py" verify --zone "$ROOT_DOMAIN" >/dev/null 2>&1; then
      umask 077
      local token_tmp
      token_tmp="$(mktemp "$(dirname "$token_file")/.cloudflare.ini.new.XXXXXX")"
      printf 'dns_cloudflare_api_token = %s\n' "$cf_token" > "$token_tmp"
      chmod 600 "$token_tmp"
      mv -f "$token_tmp" "$token_file"
      unset cf_token
      log_ok "Cloudflare Token 已验证并原子替换，可访问目标 Zone：${ROOT_DOMAIN}"
      break
    else
      new_rc=$?
    fi

    unset cf_token
    if [[ "$new_rc" == 11 ]]; then
      log_warn "Cloudflare 当前网络/API 临时异常；旧 Token 文件保持不变。请稍后重试。"
    else
      log_warn "Token 验证失败；旧 Token 文件保持不变。请检查 Token、Zone 范围、Zone Read/DNS Write 权限后重新粘贴。"
    fi
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
