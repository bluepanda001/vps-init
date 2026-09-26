#!/usr/bin/env bash
xui_base_url() { printf 'http://127.0.0.1:%s%s' "$XUI_PANEL_PORT" "$XUI_WEB_BASE_PATH"; }

module_xui() {
  command_exists python3 || die "python3 missing"
  local want_ver="3.8.5" have_ver=""
  if [[ -x /usr/local/x-ui/x-ui ]]; then
    have_ver="$(/usr/local/x-ui/x-ui -v 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ ! -x /usr/local/x-ui/x-ui || "$have_ver" != "$want_ver" ]]; then
    if [[ -n "$have_ver" ]]; then log_info "3x-ui 当前版本 ${have_ver}，切换到项目固定版本 ${want_ver}。"; else log_info "安装官方 3x-ui ${want_ver}（非交互模式；不安装独立 Xray）..."; fi
    curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/v3.8.5/install.sh -o /tmp/3x-ui-install.sh
    chmod 700 /tmp/3x-ui-install.sh
    XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none DEBIAN_FRONTEND=noninteractive bash /tmp/3x-ui-install.sh "v${want_ver}"
    rm -f /tmp/3x-ui-install.sh
  else
    log_info "3x-ui ${have_ver} 已安装，复用。"
  fi
  [[ -x /usr/local/x-ui/x-ui ]] || die "3x-ui 安装后未找到 /usr/local/x-ui/x-ui"
  have_ver="$(/usr/local/x-ui/x-ui -v 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$have_ver" == "$want_ver" ]] || die "3x-ui 版本校验失败：当前 ${have_ver:-unknown}，需要 ${want_ver}。"

  state_load
  XUI_PANEL_PORT="${XUI_PANEL_PORT:-$(random_port)}"
  # Backward compatible: an existing state value always wins. On a fresh VPS,
  # use the user-facing panel URI configured by the wizard/config (default /zhg/).
  if [[ -z "${XUI_WEB_BASE_PATH:-}" ]]; then
    XUI_WEB_BASE_PATH="${XUI_PANEL_URI_PATH:-/zhg/}"
  fi
  XUI_WEB_BASE_PATH="$(normalize_path "$XUI_WEB_BASE_PATH")"
  XUI_USERNAME="${XUI_USERNAME:-vpsadmin_$(random_hex 3)}"
  XUI_PASSWORD="${XUI_PASSWORD:-$(random_b64url 36 28)}"

  /usr/local/x-ui/x-ui setting -port "$XUI_PANEL_PORT" -username "$XUI_USERNAME" -password "$XUI_PASSWORD" -webBasePath "$XUI_WEB_BASE_PATH" -listenIP 127.0.0.1 >/dev/null
  systemctl enable --now x-ui
  systemctl restart x-ui
  sleep 2

  local token_out
  token_out=$(/usr/local/x-ui/x-ui setting -getApiToken -tokenName vps-init 2>/dev/null)
  XUI_API_TOKEN="$(printf '%s\n' "$token_out" | awk -F'apiToken: ' '/apiToken:/{print $2}' | tail -1 | tr -d '[:space:]')"
  [[ -n "$XUI_API_TOKEN" ]] || die "无法生成 3x-ui API Token。"

  state_set XUI_PANEL_PORT "$XUI_PANEL_PORT"
  state_set XUI_WEB_BASE_PATH "$XUI_WEB_BASE_PATH"
  state_set XUI_USERNAME "$XUI_USERNAME"
  state_set XUI_PASSWORD "$XUI_PASSWORD"
  state_set XUI_API_TOKEN "$XUI_API_TOKEN"
  state_set XUI_VERSION "$have_ver"
  secret_set XUI_USERNAME "$XUI_USERNAME"
  secret_set XUI_PASSWORD "$XUI_PASSWORD"
  secret_set XUI_PANEL_SSH_TUNNEL "ssh -L ${XUI_PANEL_PORT}:127.0.0.1:${XUI_PANEL_PORT} -p ${SSH_PORT} root@${SERVER_IP}"
  secret_set XUI_PANEL_LOCAL_URL "http://127.0.0.1:${XUI_PANEL_PORT}${XUI_WEB_BASE_PATH}"
  secret_set XUI_API_TOKEN "$XUI_API_TOKEN"

  local api
  api="$(xui_base_url)"
  for _ in $(seq 1 15); do
    if curl -fsS --max-time 2 -H "Authorization: Bearer ${XUI_API_TOKEN}" "${api}panel/api/server/status" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  curl -fsS --max-time 5 -H "Authorization: Bearer ${XUI_API_TOKEN}" "${api}panel/api/server/status" >/dev/null || die "3x-ui 本地 API 不可用。"

  local xray=/usr/local/x-ui/bin/xray-linux-amd64
  [[ -x "$xray" ]] || xray="$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray*' -perm -111 | head -1 || true)"
  [[ -n "$xray" && -x "$xray" ]] || die "未找到 3x-ui 自带 Xray。"
  XUI_XRAY_BIN="$xray"; state_set XUI_XRAY_BIN "$XUI_XRAY_BIN"
  log_ok "3x-ui ${have_ver} 已配置为 loopback-only；Xray 使用 3x-ui 自带版本。"
}
