#!/usr/bin/env bash

credential_prompt_secret_twice() {
  local label="$1" p1 p2
  while true; do
    read -r -s -p "$label: " p1
    echo >&2
    [[ ${#p1} -ge 8 ]] || { echo "密码至少 8 个字符。" >&2; continue; }
    read -r -s -p "再次输入密码: " p2
    echo >&2
    [[ "$p1" == "$p2" ]] || { echo "两次密码不一致，请重新输入。" >&2; continue; }
    printf '%s\n' "$p1"
    return 0
  done
}

credential_prompt_username() {
  local label="$1" current="$2" value
  while true; do
    read -r -p "$label [$current]: " value
    value="${value:-$current}"
    if [[ "$value" != *[[:space:]]* && ${#value} -ge 3 && ${#value} -le 64 ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    echo "用户名需为 3-64 个非空白字符。" >&2
  done
}

credential_change_xui() {
  [[ -x /usr/local/x-ui/x-ui ]] || die "未安装 3x-ui。"
  state_load
  [[ -n "${XUI_PANEL_PORT:-}" && -n "${XUI_WEB_BASE_PATH:-}" ]] || die "缺少 3x-ui 状态信息，请先运行一次部署/验收。"

  local current_user="${XUI_USERNAME:-vpsadmin}" new_user new_password token_out api
  echo
  echo "【修改 3x-ui 管理账号】"
  echo "当前用户名：$current_user"
  new_user="$(credential_prompt_username "新用户名，直接回车保持当前" "$current_user")"
  new_password="$(credential_prompt_secret_twice "新密码")"

  /usr/local/x-ui/x-ui setting -username "$new_user" -password "$new_password" >/dev/null
  systemctl restart x-ui
  sleep 2

  token_out="$(/usr/local/x-ui/x-ui setting -getApiToken -tokenName vps-init 2>/dev/null || true)"
  XUI_API_TOKEN="$(printf '%s\n' "$token_out" | awk -F'apiToken: ' '/apiToken:/{print $2}' | tail -1 | tr -d '[:space:]')"
  [[ -n "$XUI_API_TOKEN" ]] || die "3x-ui 密码已修改，但 API Token 刷新失败。请运行 vps-init verify 检查。"

  api="http://127.0.0.1:${XUI_PANEL_PORT}${XUI_WEB_BASE_PATH}"
  curl -fsS --max-time 5 -H "Authorization: Bearer ${XUI_API_TOKEN}" "${api}panel/api/server/status" >/dev/null ||
    die "3x-ui 密码已修改，但本地 API 验证失败。"

  XUI_USERNAME="$new_user"
  XUI_PASSWORD="$new_password"
  state_set XUI_USERNAME "$XUI_USERNAME"
  state_set XUI_PASSWORD "$XUI_PASSWORD"
  state_set XUI_API_TOKEN "$XUI_API_TOKEN"
  secret_set XUI_USERNAME "$XUI_USERNAME"
  secret_set XUI_PASSWORD "$XUI_PASSWORD"
  secret_set XUI_API_TOKEN "$XUI_API_TOKEN"
  log_ok "3x-ui 管理账号已修改，并已同步 state / secrets。"
}

credential_wait_lucky() {
  local i
  systemctl start lucky
  for i in $(seq 1 20); do
    curl -fsS --max-time 2 http://127.0.0.1:16601/version >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

credential_change_lucky() {
  [[ -x /opt/lucky/lucky ]] || die "未安装 Lucky。"
  [[ -f /etc/systemd/system/lucky.service || -f /lib/systemd/system/lucky.service || -f /usr/lib/systemd/system/lucky.service ]] ||
    die "未找到 Lucky systemd 服务。"

  state_load
  credential_wait_lucky || die "Lucky 无法启动或本地管理端口不可用。"

  local current_user="${LUCKY_USERNAME:-lucky}" current_password="${LUCKY_PASSWORD:-}"
  local new_user new_password authenticated=false
  echo
  echo "【修改 Lucky 管理账号】"
  echo "当前记录用户名：$current_user"
  new_user="$(credential_prompt_username "新用户名，直接回车保持当前" "$current_user")"
  new_password="$(credential_prompt_secret_twice "新密码")"

  if [[ -n "$current_password" ]] && python3 "$ROOT_DIR/modules/lucky/lucky_api.py"       --user "$current_user" --password "$current_password" status >/dev/null 2>&1; then
    authenticated=true
  fi

  if [[ "$authenticated" == true ]]; then
    python3 "$ROOT_DIR/modules/lucky/lucky_api.py"       --user "$current_user" --password "$current_password" set-admin       --new-user "$new_user" --new-password "$new_password" >/dev/null ||
      die "Lucky 修改管理账号失败。"
  else
    log_warn "保存的 Lucky 凭据无法认证；使用 Lucky 官方本机恢复命令后写入新凭据。"
    /opt/lucky/lucky -rUnlock >/dev/null 2>&1 || true
    /opt/lucky/lucky -rResetUser >/dev/null || die "Lucky 官方管理凭据恢复失败。"
    sleep 1
    python3 "$ROOT_DIR/modules/lucky/lucky_api.py"       --user "666" --password "666" set-admin       --new-user "$new_user" --new-password "$new_password" >/dev/null ||
      die "Lucky 恢复后写入新管理凭据失败。"
  fi

  sleep 1
  python3 "$ROOT_DIR/modules/lucky/lucky_api.py"     --user "$new_user" --password "$new_password" status >/dev/null ||
    die "Lucky 新凭据验证失败。"

  LUCKY_USERNAME="$new_user"
  LUCKY_PASSWORD="$new_password"
  state_set LUCKY_USERNAME "$LUCKY_USERNAME"
  state_set LUCKY_PASSWORD "$LUCKY_PASSWORD"
  secret_set LUCKY_USERNAME "$LUCKY_USERNAME"
  secret_set LUCKY_PASSWORD "$LUCKY_PASSWORD"
  log_ok "Lucky 管理账号已修改，并已同步 state / secrets。"
}

credential_menu() {
  require_root
  [[ -t 0 ]] || die "凭据管理需要交互式终端。"

  local choice
  while true; do
    echo
    echo "============================================================"
    echo "                  管理账号 / 密码"
    echo "============================================================"
    if [[ -x /usr/local/x-ui/x-ui ]]; then
      echo "  1. 修改 / 重置 3x-ui 用户名和密码"
    else
      echo "  1. 3x-ui（未安装）"
    fi
    if [[ -x /opt/lucky/lucky ]]; then
      echo "  2. 修改 / 重置 Lucky 用户名和密码"
    else
      echo "  2. Lucky（未安装）"
    fi
    echo "  0. 返回"
    read -r -p "请选择 [0-2]: " choice
    case "$choice" in
      1)
        [[ -x /usr/local/x-ui/x-ui ]] || { echo "3x-ui 未安装。"; continue; }
        credential_change_xui
        ;;
      2)
        [[ -x /opt/lucky/lucky ]] || { echo "Lucky 未安装。"; continue; }
        credential_change_lucky
        ;;
      0) return 0 ;;
      *) echo "输入无效。" ;;
    esac
  done
}

credential_command() {
  local target="${1:-}"
  case "$target" in
    "") credential_menu ;;
    xui|3x-ui) credential_change_xui ;;
    lucky) credential_change_lucky ;;
    *) die "passwd 用法：vps-init passwd [xui|lucky]" ;;
  esac
}
