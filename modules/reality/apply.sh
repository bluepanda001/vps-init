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

  # On a fresh Reality inbound, show the 3x-ui scanner's top feasible results.
  # Non-interactive automation accepts the first ranked feasible result; an
  # interactive run gets one confirmation with default Yes.
  existing_count="$(python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" list-inbounds | jq '[.[] | select(.remark=="VPSINIT-Reality")] | length')"
  target_mode="$REALITY_TARGET_MODE"; target_value="$REALITY_TARGET"
  if [[ "$existing_count" == "0" && "$REALITY_TARGET_MODE" == "auto" ]]; then
    local scan selected
    scan="$(python3 "$ROOT_DIR/modules/3x-ui/xui_api.py" --base "$api" --token "$XUI_API_TOKEN" scan --candidates "$REALITY_CANDIDATES")"
    echo "3x-ui Reality Target 检测结果（前 3 个可用目标）："
    jq -r '[.[] | select(.feasible==true and (.privateTarget|not))][0:3][] | "  - \(.target)  latency=\(.latencyMs)ms  TLS1.3=\(.tls13)  h2=\(.h2)  X25519=\(.x25519)"' <<<"$scan" || true
    selected="$(jq -r '[.[] | select(.feasible==true and (.privateTarget|not))][0].target // empty' <<<"$scan")"
    [[ -n "$selected" ]] || die "3x-ui Reality Scanner 没有找到 feasible 目标。可改 REALITY_TARGET_MODE=manual 后指定目标。"
    if [[ -t 0 ]] && ! confirm "采用排名第一的 Reality Target：${selected}？" y; then
      die "已停止。请把 REALITY_TARGET_MODE 改为 manual，并在 REALITY_TARGET 填入你选择的目标。"
    fi
    target_mode="manual"; target_value="$selected"
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
  secret_set REALITY_UUID "$REALITY_UUID"
  secret_set REALITY_PUBLIC_KEY "$REALITY_PUBLIC_KEY"
  secret_set REALITY_SHORT_ID "$REALITY_SHORT_ID"
  secret_set REALITY_TARGET "$REALITY_TARGET_SELECTED"
  local public_addr public_port share_name share_name_enc share_link
  if [[ "$PROFILE" == "reality-only" ]]; then public_addr="$SERVER_IP"; public_port=443; else public_addr="$NODE_DOMAIN"; public_port=443; fi
  share_name="${SERVER_NAME:-VPSINIT-Reality}"
  share_name_enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$share_name")"
  share_link="vless://${REALITY_UUID}@${public_addr}:${public_port}?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${REALITY_SERVER_NAME}&sid=${REALITY_SHORT_ID}&flow=xtls-rprx-vision#${share_name_enc}"
  secret_set REALITY_SHARE_LINK "$share_link"

  log_ok "Reality 入站已就绪：listen=${listen}:${port}, target=${REALITY_TARGET_SELECTED}"
}
