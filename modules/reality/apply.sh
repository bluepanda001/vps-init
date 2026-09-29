#!/usr/bin/env bash
module_reality() {
  state_load
  local listen port fallback=""
  case "$PROFILE" in
    reality-only) listen="0.0.0.0"; port=443 ;;
    nginx-reality) listen="127.0.0.1"; port=1443 ;;
    lucky-reality) listen="0.0.0.0"; port=443; fallback="127.0.0.1:8443" ;;
    *) return 0 ;;
  esac

  local short email api out target_mode target_value existing_count
  SUB_ID="${SUB_ID:-$(random_b64url 18 16)}"
  state_set SUB_ID "$SUB_ID"
  short="${REALITY_SHORT_ID:-$(random_hex 8)}"
  email="vpsinit-$(random_hex 4)"
  api="$(xui_base_url)"

  # On a fresh Reality inbound, scan feasible targets. Interactive runs may
  # choose any of the top 3, rescan, enter a target manually, or cancel.
  # Non-interactive automation deterministically uses rank #1.
  existing_count="$(python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" list-inbounds | jq '[.[] | select(.remark=="VPSINIT-Reality")] | length')"
  target_mode="$REALITY_TARGET_MODE"; target_value="$REALITY_TARGET"
  if [[ "$existing_count" == "0" && "$REALITY_TARGET_MODE" == "auto" ]]; then
    local scan selected choice manual_target
    local -a target_rows=()
    while true; do
      scan="$(python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" scan --candidates "$REALITY_CANDIDATES")"
      mapfile -t target_rows < <(jq -r '[.[] | select(.feasible==true and (.privateTarget|not))][0:3][] | [.target, (.latencyMs|tostring), (.tls13|tostring), (.h2|tostring), (.x25519|tostring)] | @tsv' <<<"$scan")
      (( ${#target_rows[@]} > 0 )) || die "3x-ui Reality Scanner 没有找到 feasible 目标。可改 REALITY_TARGET_MODE=manual 后指定目标。"

      echo "3x-ui Reality Target 检测结果："
      local idx=1 row tgt latency tls13 h2 x25519
      for row in "${target_rows[@]}"; do
        IFS=$'\t' read -r tgt latency tls13 h2 x25519 <<<"$row"
        printf '  %d. %s  latency=%sms  TLS1.3=%s  h2=%s  X25519=%s\n' "$idx" "$tgt" "$latency" "$tls13" "$h2" "$x25519"
        ((idx++))
      done

      if [[ ! -t 0 ]]; then
        selected="${target_rows[0]%%$'\t'*}"
        target_mode="manual"; target_value="$selected"
        break
      fi

      echo "  r. 重新扫描"
      echo "  m. 手动填写"
      echo "  0. 取消部署"
      read -r -p "请选择 [1-${#target_rows[@]}/r/m/0，默认 1]: " choice
      choice="${choice:-1}"
      if [[ "$choice" =~ ^[1-3]$ ]] && (( choice <= ${#target_rows[@]} )); then
        selected="${target_rows[choice-1]%%$'\t'*}"
        target_mode="manual"; target_value="$selected"
        break
      fi
      case "${choice,,}" in
        r) continue ;;
        m)
          read -r -p "Reality Target（例如 www.example.com:443）: " manual_target
          [[ -n "$manual_target" ]] || { log_warn "Target 为空，请重新选择。"; continue; }
          target_mode="manual"; target_value="$manual_target"
          break
          ;;
        0) die "用户取消 Reality Target 选择。" ;;
        *) log_warn "无效选择，请重新输入。" ;;
      esac
    done
  fi

  out=$(python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" create-reality \
    --remark VPSINIT-Reality --listen "$listen" --port "$port" --email "$email" --sub-id "$SUB_ID" --short-id "$short" \
    --target-mode "$target_mode" --target "$target_value" --candidates "$REALITY_CANDIDATES" --fallback "$fallback")

  REALITY_TARGET_SELECTED="$(jq -r '.target // empty' <<<"$out")"
  REALITY_SERVER_NAME="$(jq -r '.serverName // empty' <<<"$out")"
  REALITY_UUID="$(jq -r '.uuid // empty' <<<"$out")"
  local returned_public returned_sub
  returned_public="$(jq -r '.publicKey // empty' <<<"$out")"
  REALITY_PUBLIC_KEY="${returned_public:-${REALITY_PUBLIC_KEY:-}}"
  returned_sub="$(jq -r '.subId // empty' <<<"$out")"
  [[ -n "$returned_sub" ]] && SUB_ID="$returned_sub"
  [[ -n "$REALITY_TARGET_SELECTED" ]] || REALITY_TARGET_SELECTED="${REALITY_TARGET:-}"
  [[ -n "$REALITY_SERVER_NAME" ]] || REALITY_SERVER_NAME="${REALITY_TARGET_SELECTED%:443}"
  REALITY_SHORT_ID="$(jq -r '.shortId // empty' <<<"$out")"; [[ -n "$REALITY_SHORT_ID" ]] || REALITY_SHORT_ID="$short"

  [[ -n "$REALITY_UUID" ]] || die "Reality UUID 未能读取。"
  [[ -n "$REALITY_PUBLIC_KEY" ]] || die "Reality Public Key 未能读取。"
  [[ -n "$REALITY_SHORT_ID" ]] || die "Reality Short ID 未能读取。"

  state_set SUB_ID "$SUB_ID"
  state_set REALITY_TARGET_SELECTED "$REALITY_TARGET_SELECTED"
  state_set REALITY_SERVER_NAME "$REALITY_SERVER_NAME"
  state_set REALITY_UUID "$REALITY_UUID"
  state_set REALITY_PUBLIC_KEY "$REALITY_PUBLIC_KEY"
  state_set REALITY_SHORT_ID "$REALITY_SHORT_ID"

  # The inbound listen address/port may be internal-only (nginx-reality uses
  # 127.0.0.1:1443). Register the actual public endpoint as a 3x-ui Host so
  # raw/Clash/Mihomo subscriptions never leak an internal listener.
  local inbound_id public_addr public_port
  inbound_id="$(jq -r '.id // empty' <<<"$out")"
  [[ "$inbound_id" =~ ^[0-9]+$ ]] || die "Reality inbound ID 未能读取，无法配置公网订阅端点。"
  if [[ "$PROFILE" == "reality-only" ]]; then
    public_addr="$SERVER_IP"
  else
    public_addr="$NODE_DOMAIN"
  fi
  public_port=443
  python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" ensure-host \
    --inbound-id "$inbound_id" --remark VPSINIT-Public-Endpoint \
    --address "$public_addr" --port "$public_port" --sni "$REALITY_SERVER_NAME" --fingerprint chrome >/dev/null
  log_ok "Reality 订阅公网端点：${public_addr}:${public_port}"

  secret_set REALITY_UUID "$REALITY_UUID"
  secret_set REALITY_PUBLIC_KEY "$REALITY_PUBLIC_KEY"
  secret_set REALITY_SHORT_ID "$REALITY_SHORT_ID"
  secret_set REALITY_TARGET "$REALITY_TARGET_SELECTED"
  local share_name share_name_enc share_link
  share_name="${SERVER_NAME:-VPSINIT-Reality}"
  share_name_enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$share_name")"
  share_link="vless://${REALITY_UUID}@${public_addr}:${public_port}?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${REALITY_SERVER_NAME}&sid=${REALITY_SHORT_ID}&flow=xtls-rprx-vision#${share_name_enc}"
  secret_set REALITY_SHARE_LINK "$share_link"

  log_ok "Reality 入站已就绪：listen=${listen}:${port}, target=${REALITY_TARGET_SELECTED}"
}
