#!/usr/bin/env bash

source "$ROOT_DIR/proxy/common.sh"
source "$ROOT_DIR/proxy/nginx.sh"

proxy_show() {
  local id="$1"
  if ! proxy_state_load "$id"; then echo "反代 ${id} 不存在。"; return 1; fi
  echo "============================================================"
  echo "反向代理：${PROXY_NAME:-$id}"
  echo "============================================================"
  echo "ID：            ${PROXY_ID:-$id}"
  echo "Provider：      ${PROVIDER:-unknown}"
  echo "公网地址：      ${PUBLIC_URL:-https://${DOMAIN:-}}"
  echo "上游：          ${UPSTREAM_SCHEME:-http}://${UPSTREAM_HOST:-127.0.0.1}:${UPSTREAM_PORT:-}"
  echo "健康检查：      ${HEALTH_PATH:-/}"
  echo "WebSocket：     ${WEBSOCKET:-false}"
  echo "Host Header：   ${HOST_HEADER:-}"
  echo "上传大小：      ${CLIENT_MAX_BODY_SIZE:-0}"
  echo "超时：          ${TIMEOUT_SECONDS:-300}s"
  echo "Cloudflare：    ${CLOUDFLARE_MODE:-none}"
  echo "更新时间：      ${UPDATED_AT:-unknown}"
  echo "============================================================"
}

proxy_list() {
  local ids id found=0
  ids="$(proxy_list_ids)"
  if [[ -z "$ids" ]]; then echo "当前没有由 vps-init 管理的反向代理。"; return 0; fi
  printf "%-16s %-24s %-34s %s\n" "ID" "名称" "域名" "上游"
  printf "%-16s %-24s %-34s %s\n" "----------------" "------------------------" "----------------------------------" "--------------------------"
  while read -r id; do
    [[ -n "$id" ]] || continue
    (
      proxy_state_load "$id" || exit 0
      printf "%-16s %-24s %-34s %s://%s:%s\n" "$id" "${PROXY_NAME:-$id}" "${DOMAIN:-}" "${UPSTREAM_SCHEME:-http}" "${UPSTREAM_HOST:-127.0.0.1}" "${UPSTREAM_PORT:-}"
    )
    found=1
  done <<<"$ids"
  (( found == 1 )) || echo "当前没有由 vps-init 管理的反向代理。"
}

proxy_prompt_yesno_value() {
  local prompt="$1" default="$2"
  if wizard_yesno "$prompt" "$default"; then printf "true\n"; else printf "false\n"; fi
}

proxy_edit_interactive() {
  local id="${1:-}" existing=false
  proxy_load_core
  [[ "$PROFILE" == "nginx-reality" ]] || die "v1.3.0 MVP 先支持 nginx-reality 的反向代理中心。"

  local old_name="" old_domain="" old_scheme="http" old_host="127.0.0.1" old_port="" old_ws="true" old_header="" old_body="0" old_timeout="300" old_tls="true" old_health="/" old_cf="proxied"
  if [[ -n "$id" ]] && proxy_state_load "$id" 2>/dev/null; then
    existing=true
    old_name="${PROXY_NAME:-$id}"; old_domain="${DOMAIN:-}"; old_scheme="${UPSTREAM_SCHEME:-http}"; old_host="${UPSTREAM_HOST:-127.0.0.1}"; old_port="${UPSTREAM_PORT:-}"
    old_ws="${WEBSOCKET:-true}"; old_header="${HOST_HEADER:-}"; old_body="${CLIENT_MAX_BODY_SIZE:-0}"; old_timeout="${TIMEOUT_SECONDS:-300}"; old_tls="${UPSTREAM_TLS_VERIFY:-true}"; old_health="${HEALTH_PATH:-/}"; old_cf="${CLOUDFLARE_MODE:-proxied}"
  fi

  if [[ -z "$id" ]]; then
    while true; do
      read -r -p "反代 ID（如 ql / nav / vault）: " id
      if [[ "$id" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; then
        [[ ! -f "$(proxy_state_file "$id")" ]] || { echo "ID 已存在，请用编辑功能。"; continue; }
        break
      fi
      echo "ID 只允许小写字母、数字、_、-，长度 1-32。"
    done
  fi

  local name scheme host port domain websocket host_header body timeout tls_verify health cf_choice cf_mode exposure
  read -r -p "中文名称 [${old_name:-$id}]: " name; name="${name:-${old_name:-$id}}"
  echo "上游协议：1. HTTP  2. HTTPS"
  local scheme_default=1; [[ "$old_scheme" == "https" ]] && scheme_default=2
  read -r -p "请选择 [${scheme_default}]: " cf_choice; cf_choice="${cf_choice:-$scheme_default}"; [[ "$cf_choice" == 2 ]] && scheme=https || scheme=http
  read -r -p "上游地址 [${old_host}]: " host; host="${host:-$old_host}"
  while true; do
    read -r -p "上游端口${old_port:+ [$old_port]}: " port; port="${port:-$old_port}"
    [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535)) && break
    echo "端口无效。"
  done
  read -r -p "健康检查路径 [${old_health}]: " health; health="${health:-$old_health}"; [[ "$health" == /* ]] || health="/$health"

  proxy_upstream_reachable "$scheme" "$host" "$port" "$health" "$old_tls" || {
    echo "上游当前不可访问：${scheme}://${host}:${port}${health}"
    die "请先把应用本身安装并运行正常，再登记反向代理。"
  }

  if [[ "$host" == "127.0.0.1" || "$host" == "localhost" ]]; then
    exposure="$(proxy_port_exposure "$port" || true)"
    if grep -Eq '(^|\n)(0\.0\.0\.0|\*|\[::\]):' <<<"$exposure"; then
      log_warn "检测到端口 ${port} 可能同时监听公网地址。建议 Docker 使用 127.0.0.1:${port}:容器端口。"
    fi
  fi

  local default_domain="${old_domain:-${id}.${ROOT_DOMAIN}}"
  while true; do
    read -r -p "公网域名 [${default_domain}]: " domain; domain="${domain:-$default_domain}"
    proxy_domain_allowed "$domain" "$ROOT_DOMAIN" && break
    echo "当前 wildcard 证书只覆盖 ${ROOT_DOMAIN} 和一级子域名 *.${ROOT_DOMAIN}。"
  done

  websocket="$(proxy_prompt_yesno_value "需要 WebSocket？" "$(is_true "$old_ws" && echo y || echo n)")"
  read -r -p "上游 Host Header [${old_header:-$domain}]: " host_header; host_header="${host_header:-${old_header:-$domain}}"
  read -r -p "client_max_body_size [${old_body}]（0=不限）: " body; body="${body:-$old_body}"
  [[ "$body" =~ ^(0|[0-9]+[kKmMgG])$ ]] || die "client_max_body_size 格式无效，例如 0 / 100m / 2g。"
  read -r -p "反代超时秒数 [${old_timeout}]: " timeout; timeout="${timeout:-$old_timeout}"
  [[ "$timeout" =~ ^[0-9]+$ ]] && ((timeout>=10 && timeout<=86400)) || die "超时必须是 10-86400 秒。"

  tls_verify=true
  if [[ "$scheme" == "https" ]]; then
    tls_verify="$(proxy_prompt_yesno_value "验证上游 HTTPS 证书？" "$(is_true "$old_tls" && echo y || echo n)")"
  fi

  echo "Cloudflare DNS：1. 橙云代理  2. DNS Only  3. 不管理"
  case "$old_cf" in proxied) cf_choice=1;; dns-only) cf_choice=2;; *) cf_choice=3;; esac
  read -r -p "请选择 [${cf_choice}]: " cf_choice
  cf_choice="${cf_choice:-1}"
  case "$cf_choice" in 1) cf_mode=proxied;; 2) cf_mode=dns-only;; 3) cf_mode=none;; *) die "Cloudflare 选项无效。";; esac

  echo
  echo "------------ 即将配置 ------------"
  echo "名称：        $name"
  echo "公网：        https://${domain}"
  echo "上游：        ${scheme}://${host}:${port}"
  echo "健康路径：    $health"
  echo "WebSocket：   $websocket"
  echo "Host Header： $host_header"
  echo "上传大小：    $body"
  echo "超时：        ${timeout}s"
  echo "Cloudflare：  $cf_mode"
  echo "----------------------------------"
  wizard_yesno "确认写入反向代理？" y || return 0

  proxy_nginx_apply "$id" "$name" "$domain" "$scheme" "$host" "$port" "$websocket" "$host_header" "$body" "$timeout" "$tls_verify" "$health" "$cf_mode"
  proxy_nginx_verify_local "$id" || die "本机 443/SNI/反代链路验收失败。"
  if [[ "$cf_mode" != none ]]; then
    proxy_nginx_verify_public "$id" || die "公网 HTTPS 验收失败；Nginx 本机链路已通过，请检查 Cloudflare/DNS。"
  fi
  log_ok "反向代理已创建并验收：https://${domain}"
  proxy_show "$id"
}

proxy_remove_interactive() {
  local id="$1"
  proxy_state_load "$id" || die "反代 ${id} 不存在。"
  proxy_show "$id"
  wizard_yesno "确认删除这个反向代理？不会删除你的 Docker/应用。" n || return 0
  proxy_nginx_remove "$id"
  log_ok "反向代理已删除；应用本身未做任何修改。Cloudflare DNS 当前保留。"
}

proxy_manage_menu() {
  local id="$1" n
  while true; do
    echo
    proxy_show "$id" || return 0
    echo "  1. 编辑"
    echo "  2. 验收"
    echo "  3. 删除反代（不删除应用）"
    echo "  0. 返回"
    read -r -p "请选择 [0-3]: " n
    case "$n" in
      1) proxy_edit_interactive "$id" ;;
      2) proxy_nginx_verify_local "$id" && proxy_nginx_verify_public "$id" && echo "✅ 反向代理验收通过" || echo "❌ 反向代理验收失败" ;;
      3) proxy_remove_interactive "$id"; return 0 ;;
      0) return 0 ;;
      *) echo "输入无效。" ;;
    esac
  done
}

proxy_center_menu() {
  require_root
  [[ -t 0 ]] || die "反向代理中心需要交互式终端。"
  local n id
  while true; do
    echo
    echo "============================================================"
    echo "                   反向代理中心"
    echo "============================================================"
    echo "应用由你自己安装；这里仅管理 域名 / HTTPS / 443 / 反向代理。"
    echo
    proxy_list
    echo
    echo "  1. 新增反向代理"
    echo "  2. 管理已有反向代理"
    echo "  0. 返回"
    read -r -p "请选择 [0-2]: " n
    case "$n" in
      1) proxy_edit_interactive "" ;;
      2)
        read -r -p "输入反代 ID: " id
        [[ -f "$(proxy_state_file "$id" 2>/dev/null)" ]] || { echo "不存在：$id"; continue; }
        proxy_manage_menu "$id"
        ;;
      0) return 0 ;;
      *) echo "输入无效。" ;;
    esac
  done
}

proxy_command() {
  local action="${1:-menu}" id="${2:-}"
  case "$action" in
    menu|"") proxy_center_menu ;;
    list) proxy_load_core; proxy_list ;;
    add) proxy_edit_interactive "$id" ;;
    edit) [[ -n "$id" ]] || die "用法：vps-init proxy edit <id>"; proxy_edit_interactive "$id" ;;
    show) [[ -n "$id" ]] || die "用法：vps-init proxy show <id>"; proxy_show "$id" ;;
    verify) [[ -n "$id" ]] || die "用法：vps-init proxy verify <id>"; proxy_load_core; proxy_nginx_verify_local "$id" && proxy_nginx_verify_public "$id" ;;
    remove) [[ -n "$id" ]] || die "用法：vps-init proxy remove <id>"; proxy_load_core; proxy_remove_interactive "$id" ;;
    *) die "用法：vps-init proxy [list|add|edit|show|verify|remove] [id]" ;;
  esac
}
